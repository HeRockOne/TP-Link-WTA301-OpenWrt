#!/bin/bash
# make-deliverable.sh —— 把 /root/rel/pack 变成最终交付目录并自检
#
# 用法（WSL，root）：
#   bash wta301-2512/deliver/make-deliverable.sh P28
#
# 产出（/root/rel/deliver/，之后手动 scp 到笔记本桌面）：
#   wta301-op-25.12.6-<VER>.bin            网页刷机包（紧凑 0x1060000）
#   wta301-op-25.12.6-<VER>-sysupgrade.bin 系统内升级包（OpenWrt 原生 tar）
#   wta301-uboot-p21c.bin                  u-boot 自身（一般不用刷）
#   rescue/wta301-op-25.12.6-<VER>-ttl.bin 串口救砖包（稀疏 0x1380000）
#   README-刷机说明.txt / FINGERPRINT.json / flash_cmds.txt / MD5SUMS.txt
set -u
VER="${1:-P28}"
W=/mnt/c/Users/Sophia/Downloads/Compressed/wta301e3tyv1_cn_1_0_10_up_boot
PACK=/root/rel/pack
OUT=/root/rel/deliver
die() { echo "*** FAIL: $*"; exit 1; }

[ -d "$PACK" ] || die "没有 $PACK（先跑 make-release.sh）"

# ── 1. 生成两种整包 ────────────────────────────────────────────────
echo "== 1. 网页整包（紧凑 0x1060000）=="
python3 "$W/work/out-final/flash_release.py" --mk-web --dir "$PACK" >/dev/null 2>&1 || \
	die "mk-web 失败"
WEB="$PACK/op_wta301_firmware_web.bin"
[ -f "$WEB" ] || die "没有生成 $WEB"

echo "== 2. 串口整包（稀疏 0x1380000）=="
rm -rf /root/rel/single
python3 "$W/work/op-build/mk_single_img.py" --dir "$PACK" --outdir /root/rel/single >/dev/null 2>&1 || \
	die "mk_single_img 失败"
TTL="/root/rel/single/op_single_0x4800000.bin"
[ -f "$TTL" ] || die "没有生成 $TTL"

# ── 3. 组装 ────────────────────────────────────────────────────────
echo "== 3. 组装 $OUT =="
rm -rf "$OUT"; mkdir -p "$OUT/rescue"
cp "$WEB" "$OUT/wta301-op-25.12.6-${VER}.bin"
cp "$PACK/openwrt-qualcommax-ipq50xx-tplink_wta301-squashfs-sysupgrade.bin" \
   "$OUT/wta301-op-25.12.6-${VER}-sysupgrade.bin"
cp "$TTL" "$OUT/rescue/wta301-op-25.12.6-${VER}-ttl.bin"
cp "$PACK/FINGERPRINT.json" "$PACK/flash_cmds.txt" "$OUT/"

# README：仓库里存 LF，交付目录里必须是 CRLF（Windows 记事本打开才不断行）
RD="$W/wta301-2512/deliver/README-刷机说明.txt"
if [ -f "$RD" ]; then
	sed 's/\r$//; s/$/\r/' "$RD" > "$OUT/README-刷机说明.txt"
else
	echo "  !! 找不到 $RD"
fi

# u-boot 自身沿用 P21c（二级 u-boot 的修复版本，未再改动）
UB="$W/work/deliver-final-p26/wta301-uboot-p21c.bin"
[ -f "$UB" ] || UB=$(find "$W/work" -name "wta301-uboot-p21c.bin" 2>/dev/null | head -1)
[ -f "$UB" ] && cp "$UB" "$OUT/wta301-uboot-p21c.bin" || echo "  !! 找不到 wta301-uboot-p21c.bin（不影响刷机）"

# ── 4. 自检 ────────────────────────────────────────────────────────
echo "== 4. 自检 =="
( cd "$OUT" && md5sum *.bin rescue/*.bin > MD5SUMS.txt )

python3 "$W/wta301-2512/tools/verify_single_bin.py" --dir "$OUT" || die "verify_single_bin 不通过"
# 形状检查：两种包的长度必须严格是 0x1060000 / 0x1380000
python3 - "$OUT" "$VER" <<'PY' || exit 1
import sys, os, struct
d, ver = sys.argv[1], sys.argv[2]
def sz(p): return os.path.getsize(p)
ok = True
web = os.path.join(d, 'wta301-op-25.12.6-%s.bin' % ver)
ttl = os.path.join(d, 'rescue', 'wta301-op-25.12.6-%s-ttl.bin' % ver)
su  = os.path.join(d, 'wta301-op-25.12.6-%s-sysupgrade.bin' % ver)

for path, expect, name in ((web, 0x1060000, '网页包(紧凑)'),
                           (ttl, 0x1380000, 'TTL包(稀疏)')):
    n = sz(path)
    flag = 'OK' if n == expect else '*** 期望 0x%x' % expect
    print('  %-12s %10d B = 0x%-8x %s' % (name, n, n, flag))
    ok &= n == expect

# 网页包必须是 TPIMG：tphdr‖kernel‖rootfs，头里 klen/rlen 自洽
h = open(web,'rb').read()
if h[:8] != bytes.fromhex('0000010055aa9dd1'):
    print('  *** 网页包前 8 字节不是 TPIMG magic'); ok = False
else:
    klen = struct.unpack('>I', h[0x5c:0x60])[0]
    rlen = struct.unpack('>I', h[0x64:0x68])[0]
    print('  TPIMG magic OK, klen=0x%x rlen=0x%x, 0x20000+klen+rlen=0x%x'
          % (klen, rlen, 0x20000 + klen + rlen))
    ok &= 0x20000 + klen + rlen == len(h)

print('  sysupgrade  %10d B' % sz(su))
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || die "形状检查不通过"

echo
echo "== 完成：$OUT =="
ls -lR "$OUT" | sed 's/^/  /'
