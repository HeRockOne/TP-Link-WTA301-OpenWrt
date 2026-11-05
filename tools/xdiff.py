#!/usr/bin/env python3
"""xdiff.py -- 三方/逐层差异表（原厂 / S7 / 25.12）

目的：把「上板抓日志猜」换成「离线出表 → 差异表决定改什么」。
每一层（L0..L7）产出可直接判读的行；有差异即列，无差异即绿。

用法：
  python3 xdiff.py --s7 /root/lp/tree --ours /root/ours/tree \
                    --s7cfg /root/kf/linux-6.18.55/.config \
                    --ourscfg <25.12 .config> \
                    --out docs/DIVERGENCE-MATRIX.md [--layer L4,L6]

层定义（按引导链顺序）：
  L3  kernel .config   网络/驱动相关 CONFIG_
  L4  kernel modules   .ko 清单 + vermagic
  L5  用户态脚本       /etc/board.d /etc/hotplug.d /etc/init.d
  L6  UCI 配置         /etc/config/*
  L7  关键二进制/固件  校验和对照（只列不同）
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys

NET_CFG = re.compile(
    r'CONFIG_(NET|DSA|STMMAC|DWMAC|PCS_|PHY|MDIO|BRIDGE|VLAN|ATH11K|QCA|'
    r'REALTEK|PACKET|INET|IPV6|SWCONFIG)')
INTEREST = ('/etc/board.d', '/etc/hotplug.d', '/etc/init.d', '/etc/uci-defaults')


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True,
                              text=True, timeout=120).stdout
    except Exception:
        return ''


def ko_list(root):
    out = {}
    moddir = os.path.join(root, 'lib/modules')
    if not os.path.isdir(moddir):
        return out
    for dirpath, _, files in os.walk(moddir):
        for f in files:
            if f.endswith('.ko'):
                p = os.path.join(dirpath, f)
                out[f] = os.path.getsize(p)
    return out


def read_cfg(p):
    if not p or not os.path.isfile(p):
        return {}
    d = {}
    with open(p, 'r', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            m = re.match(r'^(CONFIG_[A-Z0-9_]+)=(.*)$', line)
            if m:
                d[m.group(1)] = m.group(2)
            m = re.match(r'^# (CONFIG_[A-Z0-9_]+) is not set$', line)
            if m:
                d[m.group(1)] = 'n'
    return d


def uci_files(root):
    out = {}
    d = os.path.join(root, 'etc/config')
    if not os.path.isdir(d):
        return out
    for f in sorted(os.listdir(d)):
        p = os.path.join(d, f)
        if os.path.isfile(p):
            out['etc/config/' + f] = open(p, 'rb').read()
    return out


def script_files(root):
    out = {}
    for sub in INTEREST:
        base = os.path.join(root, sub.lstrip('/'))
        for dirpath, _, files in os.walk(base):
            for f in files:
                p = os.path.join(dirpath, f)
                rel = os.path.relpath(p, root)
                try:
                    out[rel] = open(p, 'rb').read()
                except OSError:
                    pass
    return out


def norm_uci(data):
    """去掉注释与空行，便于判实质差异。"""
    out = []
    for line in data.decode('utf-8', 'replace').splitlines():
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        out.append(re.sub(r'\s+', ' ', s))
    return out


class Report:
    def __init__(self):
        self.md = []
        self.rows = 0

    def h(self, t):
        self.md.append('\n## ' + t + '\n')

    def p(self, t=''):
        self.md.append(t)

    def table(self, cols, rows):
        if not rows:
            self.p('_(无差异)_')
            self.rows += 0
            return
        self.p('| ' + ' | '.join(cols) + ' |')
        self.p('|' + '|'.join(['---'] * len(cols)) + '|')
        for r in rows:
            self.p('| ' + ' | '.join(str(x) for x in r) + ' |')
            self.rows += len(rows)

    def done(self, path, extra=''):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write('\n'.join(self.md) + '\n')
        return path


def layer_l3(rep, s7cfg, ourscfg):
    """内核 config：只看网络/驱动相关符号。"""
    a = {k: v for k, v in read_cfg(s7cfg).items() if NET_CFG.search(k)}
    b = {k: v for k, v in read_cfg(ourscfg).items() if NET_CFG.search(k)}
    rep.h('L3 内核 .config（仅网络/驱动相关符号）')
    rep.p('S7 命中 %d 项，25.12 命中 %d 项。' % (len(a), len(b)))
    diff = []
    for k in sorted(set(a) | set(b)):
        va, vb = a.get(k, '(缺)'), b.get(k, '(缺)')
        if va != vb:
            diff.append((k, va, vb))
    rep.table(['CONFIG', 'S7 (r37669/6.18.55)', '25.12 (6.12.112)'], diff)
    return len(diff)


def layer_l4(rep, s7, ours):
    rep.h('L4 内核模块 .ko 清单')
    a, b = ko_list(s7), ko_list(ours)
    rep.p('S7 %d 个，25.12 %d 个。' % (len(a), len(b)))
    rows = []
    for k in sorted(set(a) | set(b)):
        if k not in a:
            rows.append((k, '(无)', '%d B' % b[k], '25.12 独有'))
        elif k not in b:
            rows.append((k, '%d B' % a[k], '(无)', 'S7 独有'))
    rep.table(['模块', 'S7', '25.12', '判定'], rows)
    return len(rows)


def layer_l6(rep, s7, ours):
    rep.h('L6 UCI 配置 /etc/config/*')
    a, b = uci_files(s7), uci_files(ours)
    rows = []
    for k in sorted(set(a) | set(b)):
        if k not in a:
            rows.append((k, '(无)', '存在', '25.12 独有'))
        elif k not in b:
            rows.append((k, '存在', '(无)', 'S7 独有'))
        elif a[k] != b[k]:
            na, nb = norm_uci(a[k]), norm_uci(b[k])
            if na == nb:
                rows.append((k, '同(仅注释/空白)', '同(仅注释/空白)', '等价'))
            else:
                rows.append((k, '%d 行' % len(na), '%d 行' % len(nb), '实质不同'))
    rep.table(['文件', 'S7', '25.12', '判定'], rows)
    return rows


def layer_l5(rep, s7, ours):
    rep.h('L5 用户态脚本（board.d / hotplug.d / init.d / uci-defaults）')
    a, b = script_files(s7), script_files(ours)
    rows = []
    for k in sorted(set(a) | set(b)):
        if k not in a:
            rows.append((k, '(无)', '存在', '25.12 独有'))
        elif k not in b:
            rows.append((k, '存在', '(无)', 'S7 独有'))
        elif a[k] != b[k]:
            rows.append((k, '存在', '存在', '内容不同'))
    rep.table(['脚本', 'S7', '25.12', '判定'], rows)
    return rows


def layer_l7(rep, s7, ours):
    rep.h('L7 关键固件校验和')
    keys = ['lib/firmware/ath11k/IPQ5018/hw1.0/board-2.bin',
            'lib/firmware/ath11k/QCN6122/hw1.0/board-2.bin',
            'etc/openwrt_release']
    rows = []
    for k in keys:
        pa, pb = os.path.join(s7, k), os.path.join(ours, k)
        def md5(p):
            if not os.path.isfile(p):
                return '(无)'
            return hashlib.md5(open(p, 'rb').read()).hexdigest()
        ma, mb = md5(pa), md5(pb)
        rows.append((k, ma[:12], mb[:12], '同' if ma == mb and ma != '(无)' else '不同'))
    rep.table(['文件', 'S7 md5', '25.12 md5', '判定'], rows)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--s7', default='/root/lp/tree')
    ap.add_argument('--ours', default='/root/ours/tree')
    ap.add_argument('--s7cfg', default='/root/kf/linux-6.18.55/.config')
    ap.add_argument('--ourscfg', default='')
    ap.add_argument('--out', default='docs/DIVERGENCE-MATRIX.md')
    ap.add_argument('--layer', default='L3,L4,L5,L6,L7')
    a = ap.parse_args()

    want = set(x.strip() for x in a.layer.split(','))
    rep = Report()
    rep.p('# 三方逐层差异表（自动生成）\n')
    rep.p('- S7   = `%s`（r37669 / 6.18.55）' % a.s7)
    rep.p('- 25.12 = `%s`（25.12.6 / 6.12.112）' % a.ours)
    rep.p('\n只列有差异的行；`(无差异)` 表示该层逐项一致。\n')

    n = {}
    if 'L3' in want:
        n['L3'] = layer_l3(rep, a.s7cfg, a.ourscfg)
    if 'L4' in want:
        n['L4'] = layer_l4(rep, a.s7, a.ours)
    if 'L5' in want:
        n['L5'] = layer_l5(rep, a.s7, a.ours)
    if 'L6' in want:
        n['L6'] = layer_l6(rep, a.s7, a.ours)
    if 'L7' in want:
        n['L7'] = layer_l7(rep, a.s7, a.ours)

    p = rep.done(a.out)
    print('落盘:', p)
    for k in sorted(n):
        print('  %s: %s' % (k, n[k]))


if __name__ == '__main__':
    main()
