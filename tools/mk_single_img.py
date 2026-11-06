#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk_single_img.py — 把 A 槽三个镜像拼成【一个】可一次刷完的大镜像。

为什么可以一次刷：
  真实布局（原厂 /proc/mtd + 一级 bootloader 的表）是
      0x4800000  tphdr    0x20000
      0x4880000  kernel   0x480000
      0x4fc0000  rootfs   0xbc0000   -> 结束于 0x5b80000
  三者连续，中间无空洞（0x4880000 = 0x4800000+0x20000，
  0x4fc0000 = 0x4880000+0x480000）。所以从 0x4800000 起把三块
  顺序拼接，就是一块连续可写的区域，长度 0x1380000 (19.5 MB)。

  一次 `nand erase 0x4800000 0x1380000` + `nand write` 即可，
  和刷原厂 2.0.2 那种单文件体验一致。

不包含 u-boot 槽：
  normal_boot 在 0x4700000，不在 firmware 连续区内，且它是 TTL 命脉，
  单独用 flash_uboot_direct.py 刷（6 秒）。若 u-boot 也要一起刷，
  用 --with-slot 生成 0x4700000 起、长 0x1580000 的超集镜像（见下）。

用法:
  python mk_single_img.py --dir ../images/out-op-v20
    -> op_single_0x4800000.bin   (0x1380000, 19.5 MB)
       op_single_0x4700000.bin   (0x1580000, 21.5 MB, 含 u-boot 槽，可选)
"""
import argparse
import hashlib
import os
import sys

TPHDR_ADDR = 0x4800000
TPHDR_LEN = 0x20000
KERNEL_ADDR = 0x4880000
KERNEL_LEN = 0x480000
ROOTFS_ADDR = 0x4FC0000
ROOTFS_LEN = 0xBC0000
SLOT_ADDR = 0x4700000
SLOT_LEN = 0x40000

END = ROOTFS_ADDR + ROOTFS_LEN           # 0x5b80000
SINGLE_ADDR = TPHDR_ADDR                 # 0x4800000
SINGLE_LEN = END - SINGLE_ADDR           # 0x1380000 = 19.5 MB
SLOT_SINGLE_ADDR = SLOT_ADDR             # 0x4700000
SLOT_SINGLE_LEN = END - SLOT_ADDR        # 0x1580000 = 21.5 MB


def md5(b):
    return hashlib.md5(b).hexdigest()


def find_one(d, pat):
    import glob
    hits = sorted(glob.glob(os.path.join(d, pat)))
    if not hits:
        sys.exit('找不到 %s 于 %s' % (pat, d))
    return hits[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True, help='含 op_kernel_*/op_rootfs_*/op_tphdr_* 的目录')
    ap.add_argument('--slot', default=None,
                    help='可选：0x40000 的 u-boot 槽镜像，给了就顺手生成含槽的版本')
    ap.add_argument('--outdir', default=None)
    a = ap.parse_args()

    d = os.path.abspath(a.dir)
    out = os.path.abspath(a.outdir) if a.outdir else d
    os.makedirs(out, exist_ok=True)

    kp = find_one(d, 'op_kernel_*.bin')
    rp = find_one(d, 'op_rootfs_*.bin')
    hp = find_one(d, 'op_tphdr_*.bin')
    k = open(kp, 'rb').read()
    r = open(rp, 'rb').read()
    h = open(hp, 'rb').read()

    print('[输入]')
    print('  tphdr   %-34s %9d B  %s' % (os.path.basename(hp), len(h), md5(h)))
    print('  kernel  %-34s %9d B  %s' % (os.path.basename(kp), len(k), md5(k)))
    print('  rootfs  %-34s %9d B  %s' % (os.path.basename(rp), len(r), md5(r)))

    # 尺寸必须与真实分区严格一致，否则拼出来的偏移就错位
    bad = []
    if len(h) != TPHDR_LEN:
        bad.append('tphdr %d != 0x%x' % (len(h), TPHDR_LEN))
    if len(k) != KERNEL_LEN:
        bad.append('kernel %d != 0x%x' % (len(k), KERNEL_LEN))
    if len(r) != ROOTFS_LEN:
        bad.append('rootfs %d != 0x%x' % (len(r), ROOTFS_LEN))
    if bad:
        sys.exit('尺寸不符，拒绝拼接：\n  ' + '\n  '.join(bad))

    # 按绝对偏移落位，空隙填 0xFF（NAND 擦除态），这样一次 nand write
    # 与“先擦后写”等价，不会把旧数据残留在空隙里。
    # 真实空隙（已实测）：
    #   0x4820000..0x4880000  0x60000  （tphdr 分区 0x20000 之后到 kernel）
    #   0x4d00000..0x4fc0000  0x2c0000 （kernel 区 0x480000 之后到 rootfs）
    buf = bytearray(b'\xff' * SINGLE_LEN)
    for addr, blob, name in ((TPHDR_ADDR, h, 'tphdr'),
                             (KERNEL_ADDR, k, 'kernel'),
                             (ROOTFS_ADDR, r, 'rootfs')):
        off = addr - SINGLE_ADDR
        buf[off:off + len(blob)] = blob
        print('  %-7s 落位 0x%08x (镜像内 +0x%08x) %d B' % (name, addr, off, len(blob)))
    buf = bytes(buf)
    assert len(buf) == SINGLE_LEN, (len(buf), SINGLE_LEN)
    p = os.path.join(out, 'op_single_0x4800000.bin')
    open(p, 'wb').write(buf)
    print('\n[输出]')
    print('  %s' % p)
    print('    %d B = 0x%x  md5 %s' % (len(buf), len(buf), md5(buf)))
    print('    覆盖 0x%08x .. 0x%08x' % (SINGLE_ADDR, END))
    print('\n[u-boot 命令] —— 一次擦、一次写')
    print('  printenv ;tftpboot 0x44000000 %s' % os.path.basename(p))
    print('  printenv ;nand erase 0x%x 0x%x' % (SINGLE_ADDR, SINGLE_LEN))
    print('  printenv ;nand write 0x44000000 0x%x 0x%x' % (SINGLE_ADDR, SINGLE_LEN))

    if a.slot:
        s = open(a.slot, 'rb').read()
        if len(s) != SLOT_LEN:
            sys.exit('槽 %d B != 0x%x' % (len(s), SLOT_LEN))
        sbuf = bytearray(b'\xff' * SLOT_SINGLE_LEN)
        for addr, blob, name in ((SLOT_ADDR, s, 'uboot'),
                                 (TPHDR_ADDR, h, 'tphdr'),
                                 (KERNEL_ADDR, k, 'kernel'),
                                 (ROOTFS_ADDR, r, 'rootfs')):
            off = addr - SLOT_SINGLE_ADDR
            sbuf[off:off + len(blob)] = blob
            print('  %-7s 落位 0x%08x (镜像内 +0x%08x) %d B' % (name, addr, off, len(blob)))
        sbuf = bytes(sbuf)
        assert len(sbuf) == SLOT_SINGLE_LEN, (len(sbuf), SLOT_SINGLE_LEN)
        sp = os.path.join(out, 'op_single_0x4700000.bin')
        open(sp, 'wb').write(sbuf)
        print('\n[输出·含 u-boot 槽]')
        print('  %s' % sp)
        print('    %d B = 0x%x  md5 %s' % (len(sbuf), len(sbuf), md5(sbuf)))
        print('    覆盖 0x%08x .. 0x%08x' % (SLOT_SINGLE_ADDR, END))
        print('\n[u-boot 命令] —— 连 u-boot 一起一次刷完')
        print('  printenv ;tftpboot 0x44000000 %s' % os.path.basename(sp))
        print('  printenv ;nand erase 0x%x 0x%x' % (SLOT_SINGLE_ADDR, SLOT_SINGLE_LEN))
        print('  printenv ;nand write 0x44000000 0x%x 0x%x' % (SLOT_SINGLE_ADDR, SLOT_SINGLE_LEN))
        print('  注意：这条会先擦掉正在运行的 u-boot 槽 —— 擦完到写完之间断电就砖了，')
        print('        但 image_1(0x700000) 不动、一级会回退，仍可 TTL 救。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
