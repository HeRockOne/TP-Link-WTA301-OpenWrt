#!/usr/bin/env python3
"""解析 ath11k board-2.bin 容器，核对 variant 名 / BDF 大小 / 内容 md5。

用法:
    python3 tools/parse_board2.py <board-2.bin> [期望BDF文件]

容器格式（本节格式逐字节实测自仓库内两个文件）
------------------------------------------------
    0x00  17 B  "QCA-ATH11K-BOARD\\0"     magic 含结尾 NUL，共 17 字节
          pad→4B 用 'm' 填充（0x10 是 NUL，0x11..0x13 是 "mmm"）
    0x14  u32   0
    0x18  u32   文件总长 − 0x1c
    0x1c  u32   0
    0x20  u32   name_len
    0x24  name_len B  "bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=..."
    之后  pad→4B 用 'm' 填充
          u32   count（本板 = 1）
          每项：u32 size + size 字节 BDF 数据
    末尾可留少量未用字节

★ 所有 u32 都是**小端**。
  之前本文件用大端（`>I`）解析，跑仓库自带的两个 BDF 直接
  `struct.error: unpack requires a buffer of 4 bytes` —— 工具是坏的。
  `docs/M12-FIRMWARE-BDF.md` §2.1 早就写对了「所有 u32 是小端」，
  代码没跟上。已修正。

★ magic 的坑：`b"QCA-ATH11K-BOARD"` 是 16 字节，第 17 字节是 NUL
  （`ATH11K_BOARD_MAGIC_LEN = 17`）。按 16 字节比能对上，
  按 18 字节比会全部错位（早期踩过）。
"""
import sys
import struct
import hashlib

MAGIC16 = b"QCA-ATH11K-BOARD"
PAD = b"m"


def parse(path):
    b = open(path, "rb").read()
    out = {"path": path, "size": len(b), "md5": hashlib.md5(b).hexdigest()}

    if b[:16] != MAGIC16:
        out["error"] = "magic mismatch: %r" % b[:16]
        return out
    if b[16:17] != b"\x00":
        out["error"] = "magic 后第 17 字节不是 NUL: %r" % b[16:17]
        return out
    out["magic_len"] = 17

    f14 = struct.unpack("<I", b[0x14:0x18])[0]
    length = struct.unpack("<I", b[0x18:0x1c])[0]
    f1c = struct.unpack("<I", b[0x1c:0x20])[0]
    out["hdr"] = {"0x14": f14, "0x18_len": length, "0x1c": f1c,
                  "len_check": length == len(b) - 0x1c}

    name_len = struct.unpack("<I", b[0x20:0x24])[0]
    out["name_len"] = name_len
    name = b[0x24:0x24 + name_len]
    out["name"] = name.decode("ascii", "replace")

    off = 0x24 + name_len
    pad = b[off:(off + 3) & ~3]
    if pad and set(pad) != {ord(PAD)}:
        out["pad_warn"] = "名字后填充不是 'm'：%r" % pad
    off = (off + 3) & ~3
    out["pad_to"] = off

    count = struct.unpack("<I", b[off:off + 4])[0]
    off += 4
    out["count"] = count

    entries = []
    for i in range(count):
        size = struct.unpack("<I", b[off:off + 4])[0]
        off += 4
        data = b[off:off + size]
        off += size
        entries.append({"i": i, "size": size, "off": off - size,
                        "md5": hashlib.md5(data).hexdigest()})
    out["entries"] = entries
    out["tail_unused"] = len(b) - off

    # variant 名单独拎出来，方便和 DTS 的 qcom,ath11k-calibration-variant 比
    for tok in out["name"].split(","):
        if tok.startswith("variant="):
            out["variant"] = tok[len("variant="):]
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    r = parse(sys.argv[1])
    print("== %s" % r["path"])
    print("   size   %d   md5 %s" % (r["size"], r["md5"]))
    if "error" in r:
        print("   ERROR %s" % r["error"])
        return 1

    h = r["hdr"]
    print("   0x18 len %d  (= 文件总长 − 0x1c)  %s"
          % (h["0x18_len"], "OK" if h["len_check"] else "*** 不符"))
    print("   name_len %d   variant %r" % (r["name_len"], r.get("variant")))
    print("   count %d" % r["count"])
    for e in r["entries"]:
        print("     [%d] size %d  off 0x%x  md5 %s"
              % (e["i"], e["size"], e["off"], e["md5"]))
    if r["tail_unused"]:
        print("   尾部未用 %d 字节" % r["tail_unused"])

    ok = True
    if not h["len_check"]:
        ok = False
    if r.get("pad_warn"):
        print("   WARN %s" % r["pad_warn"])

    if len(sys.argv) >= 3:
        want = sys.argv[2]
        w = open(want, "rb").read()
        wmd5 = hashlib.md5(w).hexdigest()
        print("   期望 BDF %s  size %d  md5 %s" % (want, len(w), wmd5))
        hit = [e for e in r["entries"] if e["md5"] == wmd5]
        if hit:
            print("   -> 容器内含该 BDF（第 %d 项）OK" % hit[0]["i"])
        else:
            print("   -> *** 容器内不含该 BDF")
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())


