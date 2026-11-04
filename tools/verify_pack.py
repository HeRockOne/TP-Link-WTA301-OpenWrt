#!/usr/bin/env python3
"""离线复核四件套（不接板子、不联网）。

用法：
    python tools/verify_pack.py --dir ../work/images/v25.12.6-P3 \
        [--uboot ../work/backup/mtd4_normal_boot.bin]

检查项（任何一条 FAIL 都以非 0 退出）：
  1. op_kernel_*.bin    FIT 魔数 / totalsize 自洽 / 尾部 0xFF 补齐 / 内含 model+config 串
  2. op_rootfs_*.bin    squashfs 魔数 / 尾部 0xFF 补齐 / 真实长度不超槽
  3. op_tphdr_*.bin     0x48..0x68 七字段符合本板契约
                        +0x90 = md5(二级 u-boot 槽)；+0xa0 = md5(kernel[0:KLEN] ‖ rootfs[0:RLEN])
  4. ubi_*.img          UBI# 魔数 / PEB 数 / 卷名 rootfs_data / vtable CRC

这些判据来自 docs/P3-PACK-CONTRACT.md，改动契约时必须同步改这里。
"""
import argparse
import glob
import hashlib
import os
import struct
import sys
import zlib

FIT_MAGIC = b'\xd0\x0d\xfe\xed'
SQ_MAGIC = b'hsqs'

# tphdr 契约（S7 实测）
TP = {
    0x48: ('UBOOT_OFF', 0x04700000),
    0x4c: ('UBOOT_LEN', 0x00040000),
    0x50: ('TPHDR_OFF', 0x04800000),
    0x54: ('TPHDR_LEN', 0x00020000),
    0x58: ('KERNEL_OFF', 0x04880000),
    0x60: ('ROOTFS_OFF', 0x04fc0000),
}
A_ROOTFS_SLOT = 0xc00000

ok = True


def bad(msg):
    global ok
    ok = False
    print('  *** FAIL %s' % msg)


def info(msg):
    print('  %s' % msg)


def only(pat, d):
    hits = sorted(glob.glob(os.path.join(d, pat)))
    if not hits:
        bad('找不到 %s' % pat)
        return None
    if len(hits) > 1:
        bad('%s 匹配到多个：%s' % (pat, [os.path.basename(h) for h in hits]))
    return hits[0]


def check_kernel(path):
    d = open(path, 'rb').read()
    info('%s  %d B' % (os.path.basename(path), len(d)))
    if d[:4] != FIT_MAGIC:
        return bad('不是 FIT（前4B %s）' % d[:4].hex(' ')), None, None
    ts = struct.unpack('>I', d[4:8])[0]
    if ts > len(d):
        return bad('FIT totalsize %d > 文件 %d' % (ts, len(d))), None, None
    info('FIT totalsize %d，尾部 0xFF 补齐 %d B' % (ts, len(d) - ts))
    tail = d[ts:]
    if tail and tail.count(b'\xff') != len(tail):
        bad('FIT 之后的补齐区不是全 0xFF')
    for s in (b'TP-Link-WTA301', b'config@mp02.1'):
        if s not in d[:ts]:
            bad('FIT 内缺少 %r' % s)
    return None, d, ts


def check_rootfs(path):
    d = open(path, 'rb').read()
    info('%s  %d B' % (os.path.basename(path), len(d)))
    if d[:4] != SQ_MAGIC:
        return bad('不是 squashfs（前4B %s）' % d[:4].hex(' ')), None
    # squashfs 4 的字节序/版本
    if d[28] not in (4,):
        info('（squashfs 主版本 %d）' % d[28])
    # 真实长度：superblock 里 bytes_used 是 u64 @ 40
    used = struct.unpack('<Q', d[40:48])[0]
    info('squashfs bytes_used %d，补齐 %d B' % (used, len(d) - used))
    if used > len(d):
        bad('bytes_used %d 超过文件长度' % used)
    # squashfs 自己会补 0x00 到块边界，之后才是 0xFF 擦除态（扫到首个 16×FF 串为止）
    pad = used
    while pad < len(d) and d[pad:pad + 16] != b'\xff' * 16:
        pad += 1
    if pad >= len(d):
        bad('找不到 0xFF 补齐起点')
    else:
        allff = d[pad:].count(b'\xff') == len(d) - pad
        info('0xFF 补齐起点 %d (0x%x)，之后 %d B %s'
             % (pad, pad, len(d) - pad, '全 0xFF ✓' if allff else '*** 非全 0xFF'))
        if not allff:
            bad('squashfs 之后的补齐区不是全 0xFF')
    return None, d


def check_tphdr(path, k, r, uboot):
    d = open(path, 'rb').read()
    info('%s  %d B' % (os.path.basename(path), len(d)))
    if len(d) != 0x20000:
        bad('长度应为 0x20000')
    for off, (name, want) in TP.items():
        got = struct.unpack('>I', d[off:off + 4])[0]
        mark = '' if got == want else '  *** 期望 0x%x' % want
        info('+0x%02x %-10s 0x%08x%s' % (off, name, got, mark))
        if got != want:
            bad('%s 与契约不符' % name)
    klen = struct.unpack('>I', d[0x5c:0x60])[0]
    rlen = struct.unpack('>I', d[0x64:0x68])[0]
    info('+0x5c KERNEL_LEN 0x%08x (+0xa0 覆盖的字节数)' % klen)
    info('+0x64 ROOTFS_LEN 0x%08x (+0xa0 覆盖的字节数)' % rlen)
    if rlen > A_ROOTFS_SLOT:
        bad('rootfs 长度 0x%x 超过分区上限 0x%x' % (rlen, A_ROOTFS_SLOT))
    if klen > len(k) or rlen > len(r):
        bad('头里的长度超过实际文件（kernel %d/%d, rootfs %d/%d）' % (klen, len(k), rlen, len(r)))
        return
    # 注意：+0x90/+0xa0 存的是 16 字节「原始 md5」，不是 32 字符 ASCII
    got = d[0xa0:0xb0].hex()
    want = hashlib.md5(k[:klen] + r[:rlen]).hexdigest()
    info('+0xa0 payload md5 %s %s' % (got, '✓' if got == want else '*** 期望 %s' % want))
    if got != want:
        bad('+0xa0 与 kernel+rootfs 实算不符')
    if uboot:
        u = open(uboot, 'rb').read()
        got9 = d[0x90:0xa0].hex()
        want9 = hashlib.md5(u[:0x40000]).hexdigest()
        info('+0x90 u-boot md5 %s %s' % (got9, '✓' if got9 == want9 else '*** 期望 %s' % want9))
        if got9 != want9:
            bad('+0x90 与给出的 u-boot 槽不符（刷写后会校验失败）')
    else:
        info('+0x90 u-boot md5 %s（未给 --uboot，跳过比对）' % d[0x90:0xa0].hex())


def check_ubi(path):
    d = open(path, 'rb').read()
    info('%s  %d B  %d PEB' % (os.path.basename(path), len(d), len(d) // 0x20000))
    if len(d) % 0x20000:
        bad('长度不是 0x20000 的整数倍')
    for p in (0, 1):
        if d[p * 0x20000:p * 0x20000 + 4] != b'UBI#':
            bad('PEB%d 不是 UBI# 魔数' % p)
    rec = d[0x1000:0x1000 + 172]
    res, align, pad, vt, upd, nlen = struct.unpack('>IIIBBH', rec[:16])
    name = rec[16:16 + nlen].decode('ascii', 'replace')
    flags = rec[144]
    crc = struct.unpack('>I', rec[168:172])[0]
    calc = zlib.crc32(rec[:168]) & 0xffffffff ^ 0xffffffff
    info('vtable: 卷名 %r  reserved_pebs %d  alignment %d  data_pad %d  '
         'vol_type %d  flags 0x%02x  crc %s'
         % (name, res, align, pad, vt, flags, '✓' if crc == calc else '*** 不符'))
    if name != 'rootfs_data':
        bad('卷名必须是 rootfs_data（25.12.6 的 fstools 写死只认这个名字）')
    if crc != calc:
        bad('vtable CRC 不符')
    if not (flags & 0x01):
        bad('卷缺 autoresize 标志（不会长满整个 mtd）')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True)
    ap.add_argument('--uboot', default=None, help='二级 u-boot 槽镜像（0x40000 B）')
    a = ap.parse_args()
    d = a.dir
    print('== 1. kernel ==')
    kp = only('op_kernel_0x*.bin', d)
    _, k, _ = check_kernel(kp) if kp else (None, None, None)
    print('== 2. rootfs ==')
    rp = only('op_rootfs_0x*.bin', d)
    _, r = check_rootfs(rp) if rp else (None, None)
    print('== 3. tphdr ==')
    tp = only('op_tphdr_0x*.bin', d)
    if tp and k and r:
        check_tphdr(tp, k, r, a.uboot)
    elif tp:
        bad('kernel/rootfs 不可用，跳过 +0xa0 实算')
    print('== 4. ubi ==')
    up = only('ubi_*.img', d)
    if up:
        check_ubi(up)
    print('\n== 结果 ==')
    print('  PASS' if ok else '  FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())