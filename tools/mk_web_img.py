#!/usr/bin/env python3
"""mk_web_img.py —— 生成 u-boot failsafe 网页可上传的 TPIMG 整包。

用法：
    python3 tools/mk_web_img.py --dir <pack 目录> [--out <输出文件>]

输入（`make-release.sh` 在 pack 目录里产出的三件）：
    op_tphdr_0x20000.bin            0x20000  固件头（分区表 + 校验链）
    op_kernel_0x480000.bin          0x480000 kernel（FIT）
    op_rootfs_0xbc0000.bin          0xbc0000 rootfs（squashfs）

输出：
    op_wta301_firmware_web.bin      0x1060000 = 0x20000 + 0x480000 + 0xbc0000

为什么整包就是三者拼接、不用另造头
----------------------------------
u-boot 的 `tpimg_parse()`（`include/failsafe/tplink_tpimg.h`）只接受一种布局：

    [0x20000 头][kernel 区 kernel_len][rootfs 区 rootfs_len]

而我们的 tphdr 前 8 字节恰好就是 TPIMG magic（`00 00 01 00 55 aa 9d d1`），
所以 `tphdr ‖ kernel ‖ rootfs` 天然满足。kit 端收到后会调
`tpimg_build_header()` **只重算** `+0x5c`/`+0x64`/`+0xa0`，不盲信上传的头。

本工具在写入前做的检查（全部离线，失败即不产出）
--------------------------------------------------
1. tphdr 前 8 字节 == TPIMG magic（8 字节，不是前 4 字节的 `55aa9dd1`）
2. 头里 `+0x5c` klen / `+0x64` rlen 与实际文件长度一致
3. klen 按 0x20000 对齐且 ≤ 0x740000（kit 的 TPIMG_KERNEL_MAX）
4. rlen 按 0x20000 对齐且在 0xB00000..0xC00000（kit 的 rootfs 上下界）
5. 头里 `+0xa0` == md5(kernel ‖ rootfs)
6. 5 个几何字段符合红线（uboot@/tphdr@/kernel@ 三个偏移不可变）
7. 若目录内有 FINGERPRINT.json，逐文件核 size / crc32 / md5

第 3 条的 0x740000 与 DTS 的 kernel 分区大小同源（P28 加宽后）；
两者必须一致，否则网页刷完 u-boot 能启动但系统内 mtd write 会被拒。
"""

import argparse
import hashlib
import io
import json
import os
import struct
import sys
import zlib

TPIMG_MAGIC = bytes.fromhex('0000010055aa9dd1')

# kit 端硬约束，来自 patches/uboot/files/include/failsafe/tplink_tpimg.h
ERASE_BLK = 0x20000
KERNEL_MAX = 0x740000        # P28: DTS kernel 分区同值
ROOTFS_MIN = 0xB00000
ROOTFS_MAX = 0x00C00000

# 头里不可变的三个基址 + 两个长度
TPHDR_GEOM = [
    (0x48, 0x04700000, 'G0 uboot@'),
    (0x4c, 0x00040000, 'uboot len'),
    (0x50, 0x04800000, 'G1 tphdr@'),
    (0x54, 0x00020000, 'tphdr len'),
    (0x58, 0x04880000, 'G2 kernel@'),
]

FILES = {
    'tphdr':  'op_tphdr_0x20000.bin',
    'kernel': 'op_kernel_0x480000.bin',
    'rootfs': 'op_rootfs_0xbc0000.bin',
}

WEB_NAME = 'op_wta301_firmware_web.bin'


def md5f(path):
    h = hashlib.md5()
    with open(path, 'rb') as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def crc32f(path):
    c = 0
    with open(path, 'rb') as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            c = zlib.crc32(b, c)
    return '%08x' % (c & 0xFFFFFFFF)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True, help='pack 目录（make-release.sh 的产出）')
    ap.add_argument('--out', default='', help='输出路径；默认写入 --dir 下')
    a = ap.parse_args()

    d = a.dir
    if not os.path.isdir(d):
        print('!! 目录不存在: %s' % d)
        return 1

    paths = {}
    for name, fn in FILES.items():
        p = os.path.join(d, fn)
        if not os.path.exists(p):
            print('!! 缺 %s (%s)' % (fn, name))
            return 1
        paths[name] = p

    # ---- 1. FINGERPRINT 交叉校验（有就查，没有不挡）----
    fp = os.path.join(d, 'FINGERPRINT.json')
    if os.path.exists(fp):
        with io.open(fp, encoding='utf-8') as f:
            meta = json.load(f)
        ok = True
        for name, fn in FILES.items():
            m = meta.get(fn)
            if m is None:
                print('  [FAIL] %s 不在 FINGERPRINT.json 里' % fn)
                ok = False
                continue
            sz = os.path.getsize(paths[name])
            if m.get('size') != sz:
                print('  [FAIL] %s size %d != FINGERPRINT %s' % (fn, sz, m.get('size')))
                ok = False
            if m.get('crc32') and crc32f(paths[name]) != m['crc32']:
                print('  [FAIL] %s crc32 不符' % fn)
                ok = False
            if m.get('md5') and md5f(paths[name]) != m['md5']:
                print('  [FAIL] %s md5 不符' % fn)
                ok = False
        if not ok:
            print('!! FINGERPRINT 校验未通过，拒绝打包')
            return 1
        print('  [OK  ] FINGERPRINT.json 逐文件核对通过')
    else:
        print('  (无 FINGERPRINT.json，跳过该步；仅做头部一致性检查)')

    h = open(paths['tphdr'], 'rb').read()
    k = open(paths['kernel'], 'rb').read()
    v = open(paths['rootfs'], 'rb').read()

    # ---- 2. magic ----
    if h[:8] != TPIMG_MAGIC:
        print('!! tphdr 前 8 字节 = %s，不是 TPIMG magic %s'
              % (h[:8].hex(), TPIMG_MAGIC.hex()))
        print('   （注意：magic 是 8 字节，不是前 4 字节的 55aa9dd1）')
        return 1
    print('  [OK  ] TPIMG magic %s' % TPIMG_MAGIC.hex())

    # ---- 3. klen / rlen 与实际文件一致 ----
    klen = struct.unpack('>I', h[0x5c:0x60])[0]
    rlen = struct.unpack('>I', h[0x64:0x68])[0]
    if klen != len(k) or rlen != len(v):
        print('!! 头里 klen=0x%x rlen=0x%x，实际 kernel=0x%x rootfs=0x%x'
              % (klen, rlen, len(k), len(v)))
        return 1
    print('  [OK  ] klen=0x%x rlen=0x%x 与文件长度一致' % (klen, rlen))

    # ---- 4. kit 端硬约束 ----
    errs = []
    if klen & (ERASE_BLK - 1):
        errs.append('klen 0x%x 未按 0x%x 对齐' % (klen, ERASE_BLK))
    if klen > KERNEL_MAX:
        errs.append('klen 0x%x > KERNEL_MAX 0x%x' % (klen, KERNEL_MAX))
    if rlen & (ERASE_BLK - 1):
        errs.append('rlen 0x%x 未按 0x%x 对齐' % (rlen, ERASE_BLK))
    if not (ROOTFS_MIN <= rlen <= ROOTFS_MAX):
        errs.append('rlen 0x%x 不在 0x%x..0x%x' % (rlen, ROOTFS_MIN, ROOTFS_MAX))
    if errs:
        for e in errs:
            print('  [FAIL] ' + e)
        return 1
    print('  [OK  ] klen/rlen 在 kit 接受范围内')

    # ---- 5. +0xa0 == md5(kernel‖rootfs) ----
    calc = hashlib.md5(k + v).hexdigest()
    stored = h[0xa0:0xb0].hex()
    if calc != stored:
        print('  [FAIL] tphdr +0xa0  calc %s' % calc)
        print('         包内       %s' % stored)
        print('  ⇒ 头里存的是别的 kernel/rootfs 的 md5，u-boot 会校验失败落 B 槽')
        return 1
    print('  [OK  ] tphdr +0xa0 == md5(kernel‖rootfs)')

    # ---- 6. 几何字段 ----
    for off, want, nm in TPHDR_GEOM:
        got = struct.unpack('>I', h[off:off + 4])[0]
        if got != want:
            print('  [FAIL] tphdr +0x%02x(%s) = 0x%08x，应为 0x%08x'
                  % (off, nm, got, want))
            return 1
    print('  [OK  ] tphdr 5 个几何字段符合红线')

    # ---- 7. 拼接输出 ----
    pkg = h + k + v
    expect = 0x20000 + klen + rlen
    if len(pkg) != expect:
        print('!! 拼装长度 %d != 预期 %d' % (len(pkg), expect))
        return 1

    out = a.out or os.path.join(d, WEB_NAME)
    with open(out, 'wb') as f:
        f.write(pkg)

    print('')
    print('  整包 = tphdr(%d) + kernel(%d) + rootfs(%d)' % (len(h), len(k), len(v)))
    print('  size  %d (0x%x)' % (len(pkg), len(pkg)))
    print('  crc32 %s' % crc32f(out))
    print('  md5   %s' % md5f(out))
    print('  -> %s' % out)

    # 网页包必须是紧凑布局；TTL 包是稀疏布局，两者不可混刷
    if len(pkg) != 0x1060000:
        print('  !! 注意：尺寸不是 0x1060000，用之前先确认布局')
        return 1
    print('  [OK  ] 紧凑布局 0x1060000')
    return 0


if __name__ == '__main__':
    sys.exit(main())
