#!/bin/bash
# make-deliverable.sh —— 把 $PACK 变成最终交付目录并自检
#
# 用法：
#   bash deliver/make-deliverable.sh P29
#
# 产出（$OUT，默认 /root/rel/deliver）：
#   wta301-op-25.12.6-<VER>.bin            网页刷机包（紧凑 0x1060000）
#   wta301-op-25.12.6-<VER>-sysupgrade.bin 系统内升级包（OpenWrt 原生 tar）
#   wta301-uboot-p21c.bin                  u-boot 自身（一般不用刷）
#   rescue/wta301-op-25.12.6-<VER>-ttl.bin 串口救砖包（稀疏 0x1380000）
#   README-刷机说明.txt / FINGERPRINT.json / flash_cmds.txt / MD5SUMS.txt
#
# 本脚本**只用仓库内工具**（tools/mk_web_img.py · tools/mk_single_img.py），
# 不依赖仓库外的 work/ 目录。早期版本用 work/out-final/flash_release.py，
# 而那个文件不在仓库里 ⇒ 别人 clone 下来根本跑不了。已改。
set -u
_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/lib-paths.sh"

VER="${1:-}"
[ -n "$VER" ] || { echo "用法：make-deliverable.sh <版本号，如 P29>"; exit 1; }
die() { echo "*** FAIL: $*"; exit 1; }

[ -d "$PACK" ] || die "没有 $PACK（先跑 make-release.sh）"
need_tool mk_web_img.py    || exit 1
need_tool mk_single_img.py || exit 1

# ── 1. 生成两种整包 ────────────────────────────────────────────────
echo "== 1. 网页整包（紧凑 0x1060000）=="
# 不遮住输出：这个工具的检查项本身就是自检的一部分
python3 "$TOOLS/mk_web_img.py" --dir "$PACK" || die "mk_web_img 失败"
WEB="$PACK/op_wta301_firmware_web.bin"
[ -f "$WEB" ] || die "没有生成 $WEB"

echo "== 2. 串口整包（稀疏 0x1380000）=="
rm -rf "$REL/single"
python3 "$TOOLS/mk_single_img.py" --dir "$PACK" --outdir "$REL/single" >/dev/null 2>&1 || \
	die "mk_single_img 失败"
TTL="$REL/single/op_single_0x4800000.bin"
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
RD="$SRC/deliver/README-刷机说明.txt"
if [ -f "$RD" ]; then
	lf2crlf < "$RD" > "$OUT/README-刷机说明.txt"
else
	echo "  !! 找不到 $RD"
fi

# u-boot 槽镜像：优先用**仓库内的 u-boot kit** 从 u-boot.bin 现造（可复现），
# 找不到 u-boot.bin 才回落到历史交付包里那份（同样要过 md5 + 尺寸双校验）。
# 为什么要现造：现造能证明 patches/uboot/ 里的判据真的成立；
# 直接拿历史成品只是“看着对”，没验证过脚本。
UB=""
find_uboot_bin() {
	local c
	for c in "$WORK/images/kit-p21c/u-boot.bin" \
	         "$WORK/../src/u-boot-2016/u-boot.bin" \
	         "$(dirname "$WORK")/src/u-boot-2016/u-boot.bin"; do
		if [ -f "$c" ] && [ "$(stat -c%s "$c")" = "556032" ]; then
			echo "$c"; return 0
		fi
	done
	# 最后再全盘找一次（限大小，避免扫大目录）
	find "$(dirname "$WORK")" -maxdepth 4 -name 'u-boot.bin' -size 556032c 2>/dev/null | head -1
}
UBBIN=$(find_uboot_bin)
if [ -n "$UBBIN" ] && [ -f "$SRC/patches/uboot/build/mk_uboot_slot.py" ]; then
	python3 "$SRC/patches/uboot/build/mk_uboot_slot.py" \
		"$UBBIN" "$REL/uboot-slot" >/dev/null 2>&1 && \
		UB=$(find "$REL/uboot-slot" -name 'uboot_slot_*.bin' 2>/dev/null | head -1)
	[ -n "$UB" ] && echo "  u-boot 槽从 $UBBIN 现造"
fi
if [ -z "$UB" ] || [ ! -f "$UB" ]; then
	UB=$(find "$WORK" -name 'wta301-uboot-p21c.bin' 2>/dev/null | head -1)
	[ -n "$UB" ] && echo "  回落用历史槽镜像：$UB"
fi
if [ -n "$UB" ] && [ -f "$UB" ]; then
	# 期望 md5 就是 patches/uboot/README.md §3 的验收判据
	WANT_U="d0ada9f76e4f1aba9b96a559a5220cee"
	GOT_U=$(md5sum "$UB" | cut -d' ' -f1)
	if [ "$GOT_U" = "$WANT_U" ]; then
		# md5 对上了再看尺寸：槽长度是 u-boot 一级启动器的硬约束（TPIMG_UBOOT_SLOT_LEN）
		# 一级只读 0x40000 字节，多出来是垃圾、少了就解压失败。
		SZ_U=$(stat -c%s "$UB")
		if [ "$SZ_U" = "262144" ]; then
			cp "$UB" "$OUT/wta301-uboot-p21c.bin"
		else
			echo "  !! u-boot 槽尺寸 $SZ_U != 262144（0x40000），不放进交付"
		fi
	else
		echo "  !! u-boot 槽 md5 $GOT_U != $WANT_U，不放进交付（不影响固件刷写）"
	fi
else
	echo "  !! 找不到 wta301-uboot-p21c.bin（不影响固件刷写）"
fi

# ── 4. 自检 ────────────────────────────────────────────────────────
echo "== 4. 自检 =="
( cd "$OUT" && md5sum *.bin rescue/*.bin > MD5SUMS.txt )

python3 "$TOOLS/verify_single_bin.py" --dir "$OUT" || die "verify_single_bin 不通过"
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
