#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_single_bin.py —— 交付前最后一道：把两个单 bin 按 u-boot 后端的判据验一遍。

为什么要它：
  `verify_pack.py` 验的是**四件套**（TTL 口径），网页刷用的是**单文件紧凑包**，
  两者判据不同，拿错检查器会漏掉 rootfs_too_big 这类问题（P18 §9 实测踩过）。

它模拟的是 C 代码里两个函数的**全部前置判据**，判据逐条抄自源码，
不做任何"大概齐"的放宽：

  tpimg_parse_image()   board/qca/arm/common/tplink_tpimg.c:90..175
  tpimg_uboot_write()   board/qca/arm/common/tplink_tpimg.c:592..

用法：
    python verify_single_bin.py --op <网页包.bin> [--uboot <槽镜像.bin>]
    python verify_single_bin.py --dir work/deliver-final

任何一条 FAIL 都以非 0 退出。
"""
import argparse
import hashlib
import lzma
import os
import struct
import sys
import zlib

# ---- 常量，逐条对照 include/failsafe/tplink_tpimg.h ----
TPIMG_HDR_LEN      = 0x20000
TPIMG_ERASE_BLOCK  = 0x20000
TPIMG_UBOOT_SLOT_LEN = 0x40000
TPIMG_UBOOT_DEC_CAP  = 0xA0000
WTA301_ROOTFS_SLOT = 0x00C00000
WTA301_KERNEL_MAX  = 0x740000        # WTA301_ROOTFS_OFF - WTA301_KERNEL_OFF
WTA301_VERIFY_MIN  = 0x00B00000
WTA301_VERIFY_MAX  = WTA301_ROOTFS_SLOT
TPIMG_MAGIC        = bytes.fromhex('0000010055aa9dd1')

# 头部几何字段偏移（大端，be32）
F = dict(UBOOT_OFF=0x48, UBOOT_LEN=0x4c, TPHDR_OFF=0x50, TPHDR_LEN=0x54,
         KERNEL_OFF=0x58, KERNEL_LEN=0x5c, ROOTFS_OFF=0x60, ROOTFS_VERIFY=0x64,
         MD5_UBOOT=0x90, MD5_PAYLOAD=0xa0)

ok_all = True


def chk(cond, label, detail=''):
    global ok_all
    mark = 'OK  ' if cond else 'FAIL'
    if not cond:
        ok_all = False
    print('  [%s] %s%s' % (mark, label, ('  ' + detail) if detail else ''))
    return cond


def md5(b):
    return hashlib.md5(b).hexdigest()


def verify_op(path):
    print('\n=== OpenWrt 网页单包: %s ===' % os.path.basename(path))
    b = open(path, 'rb').read()
    size = len(b)
    print('  size %d (0x%X)  md5 %s  crc32 %08x'
          % (size, size, md5(b), zlib.crc32(b) & 0xffffffff))

    # 1) 魔数（memcmp(out, tpimg_magic, 8)）
    chk(b[:8] == TPIMG_MAGIC, 'magic 55aa9dd1',
        b[:8].hex() if b[:8] != TPIMG_MAGIC else '')

    h = b[:TPIMG_HDR_LEN]
    def be(o): return struct.unpack_from('>I', h, o)[0]
    g = {k: be(o) for k, o in F.items() if k not in ('MD5_UBOOT', 'MD5_PAYLOAD')}
    for k in ('UBOOT_OFF', 'UBOOT_LEN', 'TPHDR_OFF', 'TPHDR_LEN',
              'KERNEL_OFF', 'KERNEL_LEN', 'ROOTFS_OFF', 'ROOTFS_VERIFY'):
        print('    %-14s 0x%08X' % (k, g[k]))

    klen, vlen = g['KERNEL_LEN'], g['ROOTFS_VERIFY']

    # 2) klen 三条（if (!klen || klen & (BLOCK-1) || klen > KERNEL_MAX)）
    chk(klen != 0, 'kernel_len 非零')
    chk(klen % TPIMG_ERASE_BLOCK == 0, 'kernel_len 0x20000 对齐')
    chk(klen <= WTA301_KERNEL_MAX, 'kernel_len <= 0x740000', '0x%X' % klen)

    # 3) vlen 三条
    chk(vlen % TPIMG_ERASE_BLOCK == 0, 'rootfs_verify 0x20000 对齐')
    chk(WTA301_VERIFY_MIN <= vlen <= WTA301_VERIFY_MAX,
        'rootfs_verify 在 0xB00000..0xC00000', '0x%X' % vlen)

    # 4) avail / rlen（info->kernel = h + HDR_LEN; info->rootfs = kernel + klen）
    avail = size - TPIMG_HDR_LEN
    if not chk(avail >= klen, 'avail >= kernel_len',
               '0x%X vs 0x%X' % (avail, klen)):
        return
    rlen = avail - klen
    chk(rlen >= vlen, 'rlen >= rootfs_verify', '0x%X vs 0x%X' % (rlen, vlen))
    chk(rlen <= WTA301_ROOTFS_SLOT, 'rlen <= 槽 0xC00000（防 rootfs_too_big）',
        '0x%X' % rlen)

    # 5) 内容魔数（代码只打印不拒绝，但交付前要确认没装错文件）
    koff, roff = TPIMG_HDR_LEN, TPIMG_HDR_LEN + klen
    chk(b[koff:koff + 4] == bytes.fromhex('d00dfeed'), 'kernel FIT 头 d00dfeed',
        b[koff:koff + 4].hex())
    chk(b[roff:roff + 4] == b'hsqs', 'rootfs squashfs 头 hsqs',
        b[roff:roff + 4].hex())

    # 6) 包内 payload md5 是否自洽（写盘时会被重算，但自洽说明包没被改坏）
    want = h[F['MD5_PAYLOAD']:F['MD5_PAYLOAD'] + 16].hex()
    calc = md5(b[koff:koff + klen + vlen])
    chk(calc == want, '头部 @0xa0 payload md5 自洽', calc if calc != want else '')

    # 7) 与"刷完能启动"直接相关：rootfs 真实字节数 <= verify 长度
    #    squashfs superblock +0x28 是 bytes_used（小端 u64）
    if b[roff:roff + 4] == b'hsqs':
        used = struct.unpack_from('<Q', b, roff + 0x28)[0]
        chk(used <= vlen, 'squashfs bytes_used <= verify 长度',
            '0x%X vs 0x%X' % (used, vlen))
        print('    squashfs bytes_used 0x%X, 尾部 0xFF 填充 %d B'
              % (used, vlen - used))

    # 8) 指纹对照（P17 规范值）
    want_md5 = '837a9a553886426ac8b184109bf1b913'
    if md5(b) == want_md5:
        print('    → 与 P17 规范指纹一致')
    else:
        print('    → 注意：md5 与 P17 记录值不同（若是有意改动请更新指纹）')


def verify_uboot(path):
    print('\n=== U-Boot 槽镜像: %s ===' % os.path.basename(path))
    s = open(path, 'rb').read()
    print('  size %d (0x%X)  md5 %s  crc32 %08x'
          % (len(s), len(s), md5(s), zlib.crc32(s) & 0xffffffff))

    chk(len(s) == TPIMG_UBOOT_SLOT_LEN, '尺寸 == 槽 0x40000', '%d' % len(s))
    chk(s[:3] == b'\x5d\x00\x00', 'LZMA-Alone 头 5d 00 00', s[:3].hex())

    try:
        d = lzma.decompress(s, format=lzma.FORMAT_ALONE)
    except Exception as e:
        chk(False, 'LZMA 解压', str(e))
        return
    print('  解压后 %d B (0x%X)  md5 %s' % (len(d), len(d), md5(d)))

    chk(len(d) <= TPIMG_UBOOT_DEC_CAP, '解压尺寸 <= 一级缓冲 0xA0000',
        '%d / 余量 %d B' % (len(d), TPIMG_UBOOT_DEC_CAP - len(d)))

    # 首字必须是 ARM 分支指令（u-boot 入口），不是垃圾
    first = struct.unpack_from('<I', d, 0)[0]
    chk((first >> 24) == 0xEA, '首字是 ARM 分支指令',
        '0x%08X' % first)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--op')
    ap.add_argument('--uboot')
    ap.add_argument('--dir', help='目录模式：自动找 *.bin（17MB 当系统包，256KB 当 U-Boot）')
    a = ap.parse_args()

    if a.dir:
        for n in sorted(os.listdir(a.dir)):
            p = os.path.join(a.dir, n)
            if not (os.path.isfile(p) and n.endswith('.bin')):
                continue
            sz = os.path.getsize(p)
            if sz == TPIMG_UBOOT_SLOT_LEN:
                verify_uboot(p)
                continue
            # 裸 tphdr（只有 0x20000 头、没载荷）不是网页整包。
            # 它的头 8 字节也是合法 TPIMG magic，若不先拦住，verify_op 会
            # 在 “avail >= kernel_len” 上假报 FAIL。
            if sz <= TPIMG_HDR_LEN:
                print('\n=== 跳过 %s (%d B) ===' % (n, sz))
                print('  裸 tphdr（只有头，无 kernel/rootfs 载荷），不是网页整包。')
                continue
            # 判据改成「看 magic」而不是「看大小」。
            # 原逻辑 sz > 1MB 就当网页包，会误判 op_kernel_0x480000.bin /
            # op_rootfs_0xbc0000.bin 这类**分区载荷**（它们以 d00dfeed / hsqs
            # 开头），从而刷一屏假 FAIL。
            # ★ TPIMG magic 是 **8 字节** 0000010055aa9dd1，不是 4 字节的
            #  55aa9dd1（后者只是它的后 4 字节）——这一条先钐过：
            #  用前 4 字节判会把真正的网页包也跳过去。
            with open(p, 'rb') as f:
                head8 = f.read(8)
            if head8 == TPIMG_MAGIC:
                verify_op(p)
            elif sz > 1024 * 1024:
                print('\n=== 跳过 %s (%d B) ===' % (n, sz))
                print('  头 8 字节 %s 不是 TPIMG magic %s'
                      % (head8.hex(), TPIMG_MAGIC.hex()))
                print('  ⇒ 分区载荷/UBI 镜像，不是网页整包，本工具不检查。')
        rdir = os.path.join(a.dir, 'rescue')
        if os.path.isdir(rdir):
            for n in sorted(os.listdir(rdir)):
                p = os.path.join(rdir, n)
                if os.path.isfile(p) and n.endswith('.bin'):
                    print('\n=== (rescue, 仅供参考, TTL 口径不是网页口径) ===')
                    print('  %s  %d B  md5 %s'
                          % (n, os.path.getsize(p), md5(open(p, 'rb').read())))
    else:
        if a.op:
            verify_op(a.op)
        if a.uboot:
            verify_uboot(a.uboot)

    print('\n' + ('全部 PASS' if ok_all else '有 FAIL'))
    return 0 if ok_all else 1


if __name__ == '__main__':
    sys.exit(main())