#!/usr/bin/env python3
# 迁移仓库内的规范副本（2026-11-05 从 work/op-build/mk_op_pack.py 同步，并加入 --rlen）。
# 改动只改这里，work/ 侧那份视为历史。
# -*- coding: utf-8 -*-
"""
mk_op_pack.py —— 把 ImageBuilder 产物打包成 A 槽可直接刷的三个镜像。

设计依据（全部来自反汇编 work/ub_proper.bin，base 0x4a920000）：
  checkFirmwarePartition 0x4a960ffc 只校验 5 个字段，然后 bx lr：
      +0x48 == G0 (A:0x4700000)  +0x4c == 0x40000(BE)
      +0x50 == G1 (A:0x4800000)  +0x54 == 0x20000(BE)
      +0x58 == G2 (A:0x4880000)
  => +0x5c(内核长度) / +0x60 / +0x64 完全不被这个函数读取。
  checkImage 0x4a961298 的 item3 用 +0x5c 当内核读长度、+0x60/+0x64 当 rootfs
  地址/长度，md5 结果与 +0xa0 比对；item2 用 +0x48/+0x4c 与 +0x90 比对。

所以内核区可以安全地从 4MiB 扩到最多 0x740000（rootfs 起点 0x4FC0000）。

用法:
    python mk_op_pack.py --kernel <IB的kernel> --root <IB的root> --outdir out-op
"""
import argparse
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _find_backup():
    """全盘镜像的候选路径（目录重整后 backup/ 从 op-build/ 下移到了 work/）。

    返回 None 表示没有 —— 这不是错误，模板会从 patches/tphdr/tphdr-head.hex 读。
    以前这里返回 cands[0]（不存在的路径），调用方只好硬失败；
    但 128 MB 全盘镜像不可能进仓库（含 ART 校准数据），
    而真正需要的只有 122 字节的头部字段 —— 见 patches/tphdr/README.md。
    """
    cands = [
        os.environ.get('FLASH_FULL', ''),
        os.path.join(HERE, 'backup', 'flash_full_128M.bin'),
        os.path.join(HERE, '..', 'backup', 'flash_full_128M.bin'),
        os.path.join(HERE, '..', '..', 'work', 'backup', 'flash_full_128M.bin'),
    ]
    for c in cands:
        if c and os.path.isfile(os.path.normpath(c)):
            return os.path.normpath(c)
    return None


BACKUP = _find_backup()

# TP 头模板：只有前 0x120 字节有意义（非零 122 个），后面全 0。
# 有全盘镜像时用镜像里的原件（便于逐字节核对）；没有就用仓库里这份，
# 两者内容一致 —— 否则外部用户无法出包。
TPHDR_HEX = os.path.join(HERE, '..', 'patches', 'tphdr', 'tphdr-head.hex')


def _load_tphdr():
    """返回 (tphdr 前 0x120 字节, 来源描述)。读不到则抛 RuntimeError。"""
    if BACKUP:
        with open(BACKUP, 'rb') as f:
            f.seek(A_TPHDR)
            return f.read(0x120), '全盘镜像 %s +0x%x' % (BACKUP, A_TPHDR)
    p = os.path.normpath(TPHDR_HEX)
    if not os.path.isfile(p):
        raise RuntimeError('既没有全盘镜像，也没有模板 %s' % p)
    hexs = ''.join(l.strip() for l in open(p) if l.strip())
    data = bytes.fromhex(hexs)
    if len(data) < 0x120:
        raise RuntimeError('模板 %s 只有 %d 字节，需要 0x120' % (p, len(data)))
    return data[:0x120], '模板 %s' % p

# A 槽几何（来自真机备份 + 反汇编）
A_TPHDR = 0x4800000
A_UBOOT = 0x4700000
A_KERNEL = 0x4880000
A_ROOTFS = 0x4FC0000
UBOOT_LEN = 0x40000
TPHDR_LEN = 0x20000
ROOTFS_LEN = 0xBC0000            # 头字段 +0x64。= RedBoot 表 rootfs 真实长度
                                 # (0x4fc0000-0x5b80000)。旧值 0xC00000 超出 256 KB；
                                 # v19 实际用的 tphdr 写的是 0xB00000，白浪费 768 KB。
KERNEL_MAX = A_ROOTFS - A_KERNEL  # 0x740000
ROOTFS_SLOT = 0xC00000           # DTB 里 rootfs 分区长度（上限，不能越过）
A_ROOTFS_MAX_LEN = ROOTFS_SLOT

# u-boot 里 TFTP 的落点（已实测可用）
RAM_KERNEL = 0x44000000
RAM_ROOT = 0x45000000
RAM_TPHDR = 0x46000000

FIT_MAGIC = b'\xd0\x0d\xfe\xed'
SQ_MAGIC = b'hsqs'


def log(m=''):
    print(m, flush=True)


def be32(v):
    return struct.pack('>I', v)


def roundup(v, a):
    return (v + a - 1) // a * a


def md5(b):
    return hashlib.md5(b).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kernel', required=True)
    ap.add_argument('--root', required=True)
    ap.add_argument('--outdir', default=os.path.join(HERE, 'out-op'))
    ap.add_argument('--kblk', type=lambda x: int(x, 0), default=0x20000,
                    help='内核区对齐块（默认 0x20000，NAND 擦除块）')
    ap.add_argument('--rlen', type=lambda x: int(x, 0), default=ROOTFS_LEN,
                    help='rootfs 区长度（头字段 +0x64，默认 0xbc0000）。'
                         'LuCI 包集变大超槽时可用 0xc00000（= 分区上限）')
    ap.add_argument('--uboot', default=None,
                    help='0x40000 字节的 u-boot 槽镜像；给了就把它 md5 写进 +0x90，'
                         '使头自洽（不刷 u-boot 时可省）')
    args = ap.parse_args()
    if args.rlen > A_ROOTFS_MAX_LEN:
        ap.error('--rlen 0x%x 超过分区上限 0x%x' % (args.rlen, A_ROOTFS_MAX_LEN))
    if args.rlen % 0x20000:
        ap.error('--rlen 0x%x 必须是 0x20000 的整数倍' % args.rlen)

    os.makedirs(args.outdir, exist_ok=True)
    log('=' * 66)
    log(' 从 ImageBuilder 产物打包 A 槽 OpenWrt 镜像')
    log('=' * 66)

    # ---------- 1. 读入并校验输入 ----------
    log('\n[1/6] 读入并校验输入')
    k = open(args.kernel, 'rb').read()
    r = open(args.root, 'rb').read()
    log('  kernel %d B  md5 %s' % (len(k), md5(k)))
    log('  root   %d B  md5 %s' % (len(r), md5(r)))

    ok = True
    if k[:4] != FIT_MAGIC:
        log('  *** kernel 不是 FIT（前4B %s）***' % k[:4].hex(' '))
        ok = False
    else:
        ts = struct.unpack('>I', k[4:8])[0]
        if ts == len(k):
            log('  kernel FIT totalsize 自洽 = %d ✓' % ts)
        else:
            log('  *** kernel FIT totalsize %d != 文件 %d ***' % (ts, len(k)))
            ok = False
    if r[:4] != SQ_MAGIC:
        log('  *** root 不是 squashfs（前4B %s）***' % r[:4].hex(' '))
        ok = False
    else:
        log('  root squashfs 4.%d ✓' % r[28])

    # ---------- 2. 决定内核区长度 ----------
    log('\n[2/6] 决定内核区长度（头字段 +0x5c）')
    klen = roundup(len(k), args.kblk)
    log('  内核实际 %d B，按 0x%x 对齐 -> 0x%x' % (len(k), args.kblk, klen))
    if klen > KERNEL_MAX:
        log('  *** 0x%x 超过上限 0x%x（会踩到 rootfs 起点）***' % (klen, KERNEL_MAX))
        ok = False
    else:
        log('  上限 0x%x = %d B  ✓ 余量 %d B'
            % (KERNEL_MAX, KERNEL_MAX, KERNEL_MAX - klen))
    if len(r) > args.rlen:
        log('  *** rootfs %d B 超过槽 %d B ***' % (len(r), args.rlen))
        ok = False
    else:
        log('  rootfs 槽 0x%x，余量 %d B ✓' % (args.rlen, args.rlen - len(r)))

    if not ok:
        log('\n  输入不合格，中止（未写任何文件）')
        return 1

    # ---------- 3. 造出与 flash 上完全一致的字节流 ----------
    log('\n[3/6] 生成补齐后的镜像（尾部填 0xFF，与 NAND 擦除态一致）')
    kpad = k + b'\xff' * (klen - len(k))
    rpad = r + b'\xff' * (args.rlen - len(r))
    log('  kernel 区 0x%x B，尾部补 0xFF %d B' % (len(kpad), klen - len(k)))
    log('  rootfs 区 0x%x B，尾部补 0xFF %d B' % (len(rpad), args.rlen - len(r)))

    # ------------- 4. 造新的 TP 头 -------------
    log('\n[4/6] 生成新的 TP 头（只改 +0x5c / +0x64 / +0x90 / +0xa0）')
    # 只需要前 0x120 字节；有全盘镜像用镜像原件，没有就用仓库里那份模板。
    # 两者内容一致（后者就是从前者取出来的），所以产出的 tphdr 逐字节相同。
    try:
        head, src = _load_tphdr()
    except RuntimeError as e:
        log('  *** %s ***' % e)
        return 1
    log('  TP 头来源：%s' % src)
    # 后面全部补 0（与 NAND 上的实际情况一致：0xe0 之后全 0，不是 0xFF）
    tph = bytearray(TPHDR_LEN)
    tph[:len(head)] = head
    orig = bytes(tph)

    if tph[:8] != b'\x00\x00\x01\x00\x55\xaa\x9d\xd1':
        log('  *** 原厂 TP 头 magic 不符: %s ***' % bytes(tph[:8]).hex(' '))
        return 1
    log('  原厂头 magic 00 00 01 00 55 aa 9d d1 ✓')

    # 先核对 checkFirmwarePartition 要的 5 个字段（必须保持原值）
    expect = [(0x48, A_UBOOT, 'G0 uboot addr'),
              (0x4c, UBOOT_LEN, 'uboot len'),
              (0x50, A_TPHDR, 'G1 tphdr addr'),
              (0x54, TPHDR_LEN, 'tphdr len'),
              (0x58, A_KERNEL, 'G2 kernel addr')]
    for fo, want, label in expect:
        got = struct.unpack('>I', tph[fo:fo + 4])[0]
        flag = '✓' if got == want else '*** 不符 ***'
        log('  +0x%02x %-16s = 0x%08x  期望 0x%08x  %s' % (fo, label, got, want, flag))
        if got != want:
            log('  原厂头本身就不符合校验条件，中止')
            return 1

    # 旧值记录
    old_klen = struct.unpack('>I', tph[0x5c:0x60])[0]
    old_rlen = struct.unpack('>I', tph[0x64:0x68])[0]
    old_md5 = bytes(tph[0xa0:0xb0]).hex()
    log('  +0x5c 内核长度  0x%08x -> 0x%08x' % (old_klen, klen))
    log('  +0x64 rootfs 长度 0x%08x -> 0x%08x' % (old_rlen, args.rlen))

    tph[0x5c:0x60] = be32(klen)

    # 必须同时改 +0x64！原因（实测定案，2026-11-03）：
    #   用原厂全盘 dump 反推 +0xa0 的 md5 覆盖范围，唯一命中的组合是
    #     kernel 0x400000 (= 原厂 +0x5c) + rootfs 0xC00000 (= 原厂 +0x64)
    #   => checkImage 的 item3 就是按“+0x5c 读内核、+0x64 读 rootfs”取字节流再 md5。
    #   原厂头 +0x64=0xC00000 比真分区 0xBC0000 多 256 KB，等于故意多读一段
    #   分区外区域（凑巧稳定才会过校验）。我们把它改成真分区长度，让
    #   “读多少 = 写多少 = md5 覆盖多少”三者一致，不依赖分区外的内容。
    #   安全性：checkFirmwarePartition 的 5 个校验字段不含 +0x64，改它不会被挡。
    tph[0x64:0x68] = be32(args.rlen)

    # md5 覆盖「内核区 ‖ rootfs 区」，顺序与 checkImage 的两段读一致
    blob = kpad + rpad
    new_md5 = md5(blob)
    log('  +0xa0 md5(kernel‖rootfs)')
    log('        旧 %s' % old_md5)
    log('        新 %s' % new_md5)
    log('        覆盖 0x%x + 0x%x = 0x%x B' % (klen, args.rlen, len(blob)))
    tph[0xa0:0xb0] = bytes.fromhex(new_md5)

    # ---- +0x90：u-boot 槽的 md5（checkImage item2）----
    # 一级会 nand_read(0x4700000, 0x40000) 然后跟 +0x90 比 md5。所以这个值必须是
    # 『最终会存在于 0x4700000 的那 262144 字节』的 md5。
    # 注意顺序陷阱：先刷 u-boot 再刷 tphdr，会把 flash_uboot_direct.py 刚更新好的
    # +0x90 又盖回原厂值 -> item2 校验失败 -> 掉 B 槽。两种做法都对：
    #   (a) 打包时用 --uboot 传入槽文件，头里一次写对（推荐）；
    #   (b) 先刷 kernel/rootfs/tphdr，最后刷 u-boot（它自己会回写 +0x90）。
    old_ub = bytes(tph[0x90:0xa0]).hex()
    if args.uboot:
        ub = open(args.uboot, 'rb').read()
        log('  +0x90 md5(u-boot 槽)')
        if len(ub) != UBOOT_LEN:
            log('  *** 槽文件 %d B != 0x%x ***' % (len(ub), UBOOT_LEN))
            ok = False
        else:
            ub_md5 = md5(ub)
            log('        槽 %s' % args.uboot)
            log('        旧 %s（原厂）' % old_ub)
            log('        新 %s' % ub_md5)
            tph[0x90:0xa0] = bytes.fromhex(ub_md5)
    else:
        log('  +0x90 md5(u-boot 槽) 未指定 --uboot，保留原厂值 %s' % old_ub)
        log('        ⚠️ 若 u-boot 槽已被换成自编译版，必须先刷 kernel/rootfs/tphdr')
        log('           再最后刷 u-boot（flash_uboot_direct.py 会回写 +0x90），否则掉 B 槽')

    # 逐字节 diff，确认只动了该动的
    diffs = [i for i in range(len(tph)) if tph[i] != orig[i]]
    log('  与原件差异字节数: %d（应为 4+4+16 = 24 或更少，超过说明动到了别的字段）' % len(diffs))
    ranges = []
    for i in diffs:
        if ranges and i == ranges[-1][1] + 1:
            ranges[-1][1] = i
        else:
            ranges.append([i, i])
    for a, b in ranges:
        log('    0x%03x..0x%03x  (%d 字节)' % (a, b, b - a + 1))

    # ---------- 5. 落盘 ----------
    log('\n[5/6] 写出镜像文件')
    files = {
        'op_kernel_0x%x.bin' % klen: kpad,
        'op_rootfs_0x%x.bin' % args.rlen: rpad,
        'op_tphdr_0x%x.bin' % TPHDR_LEN: bytes(tph),
    }
    for name, data in files.items():
        p = os.path.join(args.outdir, name)
        with open(p, 'wb') as f:
            f.write(data)
        log('  %-28s %9d B  md5 %s' % (name, len(data), md5(data)))

    # ---------- 6. 生成刷写脚本 ----------
    log('\n[6/6] 生成 u-boot 指令序列')
    cmds = [
        # 内核
        'tftpboot 0x%x op_kernel_0x%x.bin' % (RAM_KERNEL, klen),
        'nand erase 0x%x 0x%x' % (A_KERNEL, klen),
        'nand write 0x%x 0x%x 0x%x' % (RAM_KERNEL, A_KERNEL, klen),
        # rootfs
        'tftpboot 0x%x op_rootfs_0x%x.bin' % (RAM_ROOT, args.rlen),
        'nand erase 0x%x 0x%x' % (A_ROOTFS, args.rlen),
        'nand write 0x%x 0x%x 0x%x' % (RAM_ROOT, A_ROOTFS, args.rlen),
        # 头（最后写：头一改校验就变了，前面写坏还能靠旧头认出来）
        'tftpboot 0x%x op_tphdr_0x%x.bin' % (RAM_TPHDR, TPHDR_LEN),
        'nand erase 0x%x 0x%x' % (A_TPHDR, TPHDR_LEN),
        'nand write 0x%x 0x%x 0x%x' % (RAM_TPHDR, A_TPHDR, TPHDR_LEN),
    ]
    cmds = ['printenv ;' + c for c in cmds]   # 白名单绕过
    p = os.path.join(args.outdir, 'flash_cmds.txt')
    with open(p, 'w', newline='\n') as f:
        f.write('\n'.join(cmds) + '\n')
    for c in cmds:
        log('  ' + c)

    log()
    log('  关键顺序：先写 kernel、再写 rootfs、最后写头。')
    log('  头写坏/写前中断 => 校验失败 => 落 B 槽（完好），仍可 TTL 抢救。')
    log('  刷完 boot_flag 必须为 2（A 优先）：rescue.py setflag --value 2')
    return 0


if __name__ == '__main__':
    sys.exit(main())
