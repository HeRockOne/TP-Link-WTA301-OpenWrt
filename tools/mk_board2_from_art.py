#!/usr/bin/env python3
"""mk_board2_from_art.py —— 从**你自己的** ART 分区生成 ath11k board-2.bin。

为什么需要这个工具
------------------
`patches/bdf/` 里**不再随仓库分发** board-2.bin。它装的是**逐台**射频校准数据
（从 ART 分区提取），属于厂商烧进 flash 的数据，不该由我们转手。

本工具用**你自己的** ART 分区生成等价文件。

注意：这不影响射频性能 —— 运行时 ath11k 的校准始终来自刷机者自己的 ART
（见 `files-base-files/etc/hotplug.d/firmware/12-wta301-caldata`），
board-2.bin 只负责板型/variant 匹配（必须有，否则 ath11k 报 -12）。

用法
----
    # 直接从板子上跑（推荐，读到的是本机真实校准）
    ssh root@192.168.1.1
    scp tools/mk_board2_from_art.py root@192.168.1.1:/tmp/
    python3 /tmp/mk_board2_from_art.py --art /dev/mtdblock2 --outdir /tmp/bdf
    # 板子没装 python 时，先 dump 到本地再跑：
    #   dd if=/dev/mtdblock2 of=/tmp/art.bin
    #   本机: python3 tools/mk_board2_from_art.py --art art.bin --outdir bdf

    # 只想核对（对比本仓库自带的参考文件，确认提取逻辑正确）
    python3 tools/mk_board2_from_art.py --art art.bin --outdir /tmp/bdf --verify

输入可以是三种形态之一，脚本自动识别：
  1. ART 分区 dump（0x20000 字节，gzip 流）        ← `dd if=/dev/mtdblock2`
  2. gzip 解压后的 tar（含 tmp/virtual_art.bin）
  3. virtual_art.bin 本身（0x80000 字节）
  4. 裸 128 KiB BDF（已经没有 ART 时）

真机校准偏移（实测自原厂 /lib/read_caldata_to_fs.sh 的 read_caldata()）
------------------------------------------------------------------------
    IPQ5018  2.4G : virtual_art.bin + 0x01000  len 0x20000
    qcn6122  5G   : virtual_art.bin + 0x26800  len 0x20000

容器格式见 tools/parse_board2.py 的文档注释。所有 u32 是**小端**。
"""

import argparse
import gzip
import hashlib
import io
import os
import struct
import sys
import tarfile
import zlib

MAGIC = b"QCA-ATH11K-BOARD"          # 16 字节；第 17 字节是 NUL
PAD = b"m"
VARIANT = "TP-Link-WTA301"
BOARD_NAME = "bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=" + VARIANT

# 射频 -> (ART 内偏移, 长度)
RADIOS = {
    "ipq5018-2g":  (0x01000, 0x20000),
    "qcn6122-5g":  (0x26800, 0x20000),
}

# 本工程作者那台机器的参考指纹。只用于 --verify，不参与生成。
# 换一台机器跑出来 md5 不同是**正常且正确**的（校准是逐台的）。
REFERENCE = {
    "ipq5018-2g": "78f5b21b2cd1dee8fb6155e1f74a1073",
    "qcn6122-5g": "e4904f1326df5edfd7842b319e0828da",
}
REF_BDF_MD5 = {
    "ipq5018-2g": "f15ca65305465749986f19662aaefb19",
    "qcn6122-5g": "c681908f261826dda8ff6c90e1ecbba5",
}


def md5(b):
    return hashlib.md5(b).hexdigest()


# --------------------------------------------------------------------------
# 输入解码
# --------------------------------------------------------------------------
def gunzip_stream(b):
    """解 gzip，忽略流结束后的 0xff 填充（ART 分区尾部就是 0xff）。

    gzip.decompress() 遇到尾部垃圾会抛 BadGzipFile，所以这里用
    decompressobj 逐段喂，读到 eof 就停。
    """
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)   # 16 = 强制 gzip 头
    out = d.decompress(b)
    out += d.flush()
    return out


def find_art_member(blob):
    """从 tar 里找出 virtual_art.bin。返回其内容。

    ART 里的 tar 只有一个成员 `tmp/virtual_art.bin`，所以先用 tarfile 正规
    解析；失败时回落到「跳过第一个 512 字节头直接取成员」——因为成员大小
    写在头偏移 +124 的 11 字节八进制字段里。
    """
    try:
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:") as t:
            for m in t.getmembers():
                if not m.isfile():
                    continue
                f = t.extractfile(m)
                if f is not None:
                    return f.read(), m.name
    except (tarfile.TarError, OSError):
        pass

    # 回落：手读 ustar 头
    if len(blob) < 512:
        raise SystemExit("tar 太小，不是有效 tar")
    size_field = blob[124:136].rstrip(b"\x00 ")
    try:
        size = int(size_field, 8) if size_field else 0
    except ValueError:
        size = 0
    if size <= 0:
        raise SystemExit("tar 头里成员大小解析失败：%r" % size_field)
    name = blob[0:100].rstrip(b"\x00").decode("ascii", "replace")
    return blob[512:512 + size], name


def load_art(path):
    """把任意形态的输入统一成 (kind, payload)。

    kind:
      'art'  -> payload 是 0x80000 的 virtual_art.bin
      'bdf'  -> payload 是 128 KiB 裸 BDF（没法再分射频，只适用于单射频场景）
    """
    b = open(path, "rb").read()

    if b[:2] == b"\x1f\x8b":                       # gzip（ART 分区原文）
        raw = gunzip_stream(b)
        art, name = find_art_member(raw)
        return "art", art, "gzip → tar → %s" % name

    if len(b) >= 512 and b[257:262] == b"ustar":   # 已解压的 tar
        art, name = find_art_member(b)
        return "art", art, "tar → %s" % name

    if len(b) == 0x80000:                          # virtual_art.bin 本身
        return "art", b, "直接是 virtual_art.bin"

    if len(b) == 0x20000:                          # 裸 128 KiB
        return "bdf", b, "裸 128 KiB BDF（无 ART 结构）"

    raise SystemExit(
        "无法识别的输入：%d 字节，头 4 字节 %s\n"
        "  预期：gzip 的 ART(0x20000) / tar / virtual_art.bin(0x80000) / 裸BDF(0x20000)"
        % (len(b), b[:4].hex()))


# --------------------------------------------------------------------------
# 容器构造
# --------------------------------------------------------------------------
def build_container(bdf):
    """拼出一个单成员的 board-2.bin。布局与上游 ath11k 解析器一致。"""
    assert len(bdf) == 0x20000, "BDF 必须是 128 KiB"

    name = BOARD_NAME.encode("ascii")
    buf = bytearray()
    buf += MAGIC                      # 16 B
    buf += b"\x00"                    # 第 17 字节 NUL（magic_len = 17）
    while len(buf) % 4:               # 对齐到 4，用 'm' 填
        buf += PAD
    # 此刻 len(buf) == 0x14
    assert len(buf) == 0x14, hex(len(buf))

    buf += struct.pack("<I", 0)                 # 0x14
    # 0x18 = 文件总长 − 0x1c。总长 = 0x1c + 4 + 4 + len(name)对齐 + 4 + 4 + len(bdf)
    # 直接把「0x18 之后的所有内容」算出来更稳妥，避免手算错。
    tail = bytearray()
    tail += struct.pack("<I", 0)                # 0x1c
    tail += struct.pack("<I", len(name))        # 0x20 name_len
    tail += name
    while (0x1c + len(tail)) % 4:               # 名字后对齐（按文件绝对偏移算）
        tail += PAD
    tail += struct.pack("<I", 1)                # count
    tail += struct.pack("<I", len(bdf))         # size
    tail += bdf

    buf += struct.pack("<I", len(tail))         # 0x18 = 0x1c 之后的总长
    buf += tail

    # 自校验：用仓库自带的解析器读回来
    return bytes(buf)


def verify_container(blob, bdf, radio):
    """解析回读，逐字段核对。失败就抛，不产出坏文件。"""
    if blob[:16] != MAGIC or blob[16:17] != b"\x00":
        raise SystemExit("[%s] magic 错" % radio)
    f14 = struct.unpack("<I", blob[0x14:0x18])[0]
    ln = struct.unpack("<I", blob[0x18:0x1c])[0]
    if f14 != 0:
        raise SystemExit("[%s] 0x14 应为 0，实际 %d" % (radio, f14))
    if ln != len(blob) - 0x1c:
        raise SystemExit("[%s] 0x18=%d 应等于 总长-0x1c=%d"
                         % (radio, ln, len(blob) - 0x1c))
    name_len = struct.unpack("<I", blob[0x20:0x24])[0]
    name = blob[0x24:0x24 + name_len].decode("ascii")
    if name != BOARD_NAME:
        raise SystemExit("[%s] 名字不符：%r" % (radio, name))
    off = (0x24 + name_len + 3) & ~3
    count = struct.unpack("<I", blob[off:off + 4])[0]
    if count != 1:
        raise SystemExit("[%s] count 应为 1，实际 %d" % (radio, count))
    size = struct.unpack("<I", blob[off + 4:off + 8])[0]
    if size != len(bdf):
        raise SystemExit("[%s] 声明 size %d != BDF %d" % (radio, size, len(bdf)))
    data = blob[off + 8:off + 8 + size]
    if data != bdf:
        raise SystemExit("[%s] 容器内 BDF 与源数据不一致" % radio)
    if len(blob) != off + 8 + size:
        raise SystemExit("[%s] 尾部多余 %d 字节"
                         % (radio, len(blob) - (off + 8 + size)))
    return off + 8


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="从 ART 分区生成 ath11k board-2.bin")
    ap.add_argument("--art", required=True,
                    help="ART 分区 dump / tar / virtual_art.bin / 裸 BDF")
    ap.add_argument("--outdir", required=True, help="输出目录")
    ap.add_argument("--verify", action="store_true",
                    help="与仓库自带的参考指纹对比（仅在本机硬件上应相同）")
    ap.add_argument("--variant", default=VARIANT,
                    help="变体名，必须与 DTS 的 qcom,ath11k-calibration-variant 一致")
    a = ap.parse_args()

    global BOARD_NAME
    if a.variant != VARIANT:
        BOARD_NAME = "bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=" + a.variant

    kind, payload, how = load_art(a.art)
    print("== 输入 %s" % a.art)
    print("   %d 字节，识别为：%s" % (os.path.getsize(a.art), how))
    print("   载荷 %d 字节 (0x%x)，md5 %s"
          % (len(payload), len(payload), md5(payload)))

    if kind == "bdf":
        print("\n!! 输入是裸 BDF，无法区分射频 —— 只作为单一射频数据使用。")
        print("   正常情况下应给 ART 分区或 virtual_art.bin。")
        radios = {"bdf": payload}
    else:
        if len(payload) != 0x80000:
            raise SystemExit("virtual_art.bin 应为 0x80000 字节，实际 0x%x" % len(payload))
        radios = {}
        for name, (off, ln) in RADIOS.items():
            blk = payload[off:off + ln]
            if len(blk) != ln:
                raise SystemExit("[%s] ART 越界" % name)
            radios[name] = blk
            if set(blk) == {0xff} or set(blk) == {0x00}:
                raise SystemExit("[%s] ART 该区全为 0x%02x —— 分区可能被擦过"
                                 % (name, blk[0]))

    os.makedirs(a.outdir, exist_ok=True)
    fail = 0
    for name, bdf in radios.items():
        print("\n-- %s --" % name)
        print("   BDF %d 字节  md5 %s" % (len(bdf), md5(bdf)))
        blob = build_container(bdf)
        bdf_off = verify_container(blob, bdf, name)
        out = os.path.join(a.outdir, "board2-wta301-%s.bin" % name)
        with open(out, "wb") as f:
            f.write(blob)
        print("   容器 %d 字节  md5 %s  （BDF 起于 0x%x）"
              % (len(blob), md5(blob), bdf_off))
        print("   -> %s" % out)

        if a.verify:
            exp_bdf = REF_BDF_MD5.get(name)
            exp_c = REFERENCE.get(name)
            if exp_bdf and md5(bdf) != exp_bdf:
                print("   [差异] BDF 与本工程参考机不同（%s）" % exp_bdf)
                print("          换一台机器这是**正常**的：校准逐台不同。")
            elif exp_bdf:
                print("   [一致] BDF 与参考机相同 %s" % exp_bdf)
            if exp_c:
                got = md5(blob)
                if got == exp_c:
                    print("   [一致] 容器 md5 = 参考 %s ✅" % exp_c)
                else:
                    print("   [差异] 容器 md5 %s != 参考 %s" % (got, exp_c))

    print("\n== 完成 ==")
    print("把 board2-wta301-ipq5018-2g.bin 放到")
    print("  /lib/firmware/ath11k/IPQ5018/hw1.0/board-2.bin")
    print("把 board2-wta301-qcn6122-5g.bin 放到")
    print("  /lib/firmware/ath11k/QCN6122/hw1.0/board-2.bin")
    print("然后 `wifi reload`（或重启）。")
    print("")
    print("注意：运行时真正的射频校准来自 caldata hotplug 从 ART 现提取的")
    print("      cal-ahb-*.wifi.bin；board-2.bin 只负责 variant 匹配。")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())


