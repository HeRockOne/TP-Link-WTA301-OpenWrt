#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk_fingerprint.py <dir> —— 为发布目录生成 FINGERPRINT.json。

flash_release.py 只认文件名 → {size, crc32, md5} 这个扁平结构：
    meta.get('op_kernel_0x480000.bin')['crc32']
其余字段（version/stage/purpose/bootargs/rollback）纯给人看，工具不读。

用法：
    python tools/mk_fingerprint.py work/images/v25.12.6-P3 \
        --version v25.12.6-P3 --stage P3 \
        --purpose "25.12.6 / kernel 6.12.112 首次真机验证" \
        --rollback-to S7 --rollback-kernel 53bd0490 --rollback-rootfs c2e227c6
"""
import argparse
import hashlib
import json
import os
import sys
import zlib

FILES = ['op_kernel_0x480000.bin', 'op_rootfs_0xbc0000.bin',
         'op_tphdr_0x20000.bin', 'ubi_rootfs_data3_wta301data.img']


def f(path):
    b = open(path, 'rb').read()
    return dict(size=len(b),
                crc32='%08x' % (zlib.crc32(b) & 0xffffffff),
                md5=hashlib.md5(b).hexdigest())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('--version', required=True)
    ap.add_argument('--stage', default='')
    ap.add_argument('--purpose', default='')
    ap.add_argument('--bootargs', default='')
    ap.add_argument('--rollback-to', default='')
    ap.add_argument('--rollback-kernel', default='')
    ap.add_argument('--rollback-rootfs', default='')
    ap.add_argument('--rollback-tphdr', default='')
    a = ap.parse_args()

    fp = {}
    missing = []
    for fn in FILES:
        p = os.path.join(a.dir, fn)
        if not os.path.exists(p):
            missing.append(fn)
            continue
        fp[fn] = f(p)
        print('  %-34s %10d B  crc32=%s  md5=%s'
              % (fn, fp[fn]['size'], fp[fn]['crc32'], fp[fn]['md5']))
    if missing:
        raise SystemExit('缺文件: %s' % ', '.join(missing))

    fp['version'] = a.version
    fp['stage'] = a.stage
    fp['purpose'] = a.purpose
    fp['bootargs'] = a.bootargs
    fp['rollback'] = {'to': a.rollback_to, 'kernel_crc32': a.rollback_kernel,
                      'rootfs_crc32': a.rollback_rootfs, 'tphdr_crc32': a.rollback_tphdr}

    # 自洽性：tphdr +0xa0 必须等于 md5(kernel‖rootfs)
    t = open(os.path.join(a.dir, FILES[2]), 'rb').read()
    k = open(os.path.join(a.dir, FILES[0]), 'rb').read()
    r = open(os.path.join(a.dir, FILES[1]), 'rb').read()
    calc = hashlib.md5(k + r).hexdigest()
    stored = bytes(t[0xa0:0xb0]).hex()
    print('  +0xa0 %s vs %s -> %s' % (calc, stored, 'OK' if calc == stored else 'BAD'))
    if calc != stored:
        raise SystemExit('+0xa0 不符，包不能用')

    out = os.path.join(a.dir, 'FINGERPRINT.json')
    with open(out, 'w', encoding='utf-8') as fh:
        json.dump(fp, fh, indent=2, ensure_ascii=False)
    print('  -> %s' % out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
