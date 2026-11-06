#!/bin/bash
# make-open-release.sh —— 组装对外发布包（固件 + u-boot kit）
#
# 为什么分两个子目录：这两样东西的**风险等级不同**。
#   固件     = 刷错会变砖，但包本身已自检（形状、crc32、md5、布局）
#   ubootkit = 刷错**串口直接死**（链接基址 / LZMA / 槽长度三重硬约束）
# 混在一个目录里迟早有人拿错，所以物理隔开，各自带 README + MD5SUMS。
#
# 用法（先跑过 make-release.sh 和 make-deliverable.sh）：
#   bash deliver/make-open-release.sh P29
#
# 产出：$REL/open/wta301-openwrt-<VER>/
# 之后：tar 打包 + 传到 Releases 页（仓库不存 *.bin）
set -u
_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/lib-paths.sh"

VER="${1:-}"
die() { echo "*** FAIL: $*"; exit 1; }

[ -n "$VER" ] || die "用法：make-open-release.sh <版本号，如 P29>"
VER=$(echo "$VER" | tr 'a-z' 'A-Z')

DELIVER=$REL/deliver
[ -d "$DELIVER" ] || die "没有 $DELIVER（先跑 make-release.sh + make-deliverable.sh）"

OUT=$REL/open/wta301-openwrt-$VER
echo "== 目标：$OUT =="
rm -rf "$OUT"
mkdir -p "$OUT/firmware/rescue" "$OUT/uboot-kit"

# ── 1. 固件 ────────────────────────────────────────────────────────
echo "== 1. 固件 =="
# make-deliverable.sh 的文件名是小写 p29，这里统一成大写的版本号
for f in "$DELIVER"/wta301-op-25.12.6-*-sysupgrade.bin \
         "$DELIVER"/wta301-op-25.12.6-*.bin \
         "$DELIVER"/rescue/wta301-op-25.12.6-*-ttl.bin; do
	[ -f "$f" ] || continue
	base=$(basename "$f")
	# wta301-op-25.12.6-p29-sysupgrade.bin -> wta301-op-25.12.6-P29-sysupgrade.bin
	new=$(echo "$base" | sed -E "s/-p[0-9]+/-$VER/")
	case "$f" in
	*/rescue/*) cp "$f" "$OUT/firmware/rescue/$new" ;;
	*)          cp "$f" "$OUT/firmware/$new" ;;
	esac
done

for f in FINGERPRINT.json README-刷机说明.txt flash_cmds.txt; do
	[ -f "$DELIVER/$f" ] && cp "$DELIVER/$f" "$OUT/firmware/$f"
done

# 固件目录的 MD5SUMS 重新算（不信旧的，按实际文件内容生成）
# 注意：先写 .tmp 再 mv。直接 `> MD5SUMS.txt` 会在 find 之前就把这个文件建出来
# （哪怕内容是空的），find 于是把它自己也收进清单，算出的 md5 是全空文件的，
# 等文件被填上内容后复核必然失败。第一版踩过这个坑。
md5sums_of() { # $1=目录 $2=输出文件名 $3=文件名正则（grep -E），可空
	local d=$1 out=$2 pat=${3:-}
	(
		cd "$d" || exit 1
		find . -type f | sed 's|^\./||' | sort
	) | {
		if [ -n "$pat" ]; then grep -E "$pat"; else cat; fi
	} | grep -v -x "$out" | grep -v '\.tmp$' | while read -r f; do
		printf '%s  %s\n' "$(md5sum "$d/$f" | cut -d' ' -f1)" "$f"
	done > "$d/$out.tmp"
	mv -f "$d/$out.tmp" "$d/$out"
	echo "  $out: $(wc -l < "$d/$out") 个文件"
}

md5sums_of "$OUT/firmware" MD5SUMS.txt '\.(bin|json|txt)$'

# ── 2. u-boot kit ──────────────────────────────────────────────────
echo "== 2. u-boot kit =="
[ -d "$SRC/patches/uboot" ] || die "没有 patches/uboot"
cp -a "$SRC/patches/uboot/README.md" "$OUT/uboot-kit/README.md"
# CHANGES.md 是 GPL-2.0 §2(a)/§3 的合规文件，**必须进发布包**。
# 少它一个，发布包就变成“分发二进制但没修改声明也没对应源码声明”。
cp -a "$SRC/patches/uboot/CHANGES.md" "$OUT/uboot-kit/CHANGES.md" \
	|| die "缺 patches/uboot/CHANGES.md（GPL-2.0 合规必需）"
cp -a "$SRC/patches/uboot/files"     "$OUT/uboot-kit/files"
cp -a "$SRC/patches/uboot/build"     "$OUT/uboot-kit/build"
[ -f "$DELIVER/wta301-uboot-p21c.bin" ] && \
	cp "$DELIVER/wta301-uboot-p21c.bin" "$OUT/uboot-kit/"

# p18~p21 历史快照**不进发布包**：README §5 明说「同名文件内容不同，不要直接用」，
# 放进去只会让人拿错。要追溯请去仓库。
md5sums_of "$OUT/uboot-kit" MD5SUMS.txt

# ── 3. 顶层文件 ────────────────────────────────────────────────────
echo "== 3. 顶层 =="
cp "$SRC/LICENSE"             "$OUT/LICENSE"
cp "$SRC/THIRD-PARTY.md"      "$OUT/THIRD-PARTY.md"
cp "$SRC/deliver/RELEASE-README.md" "$OUT/README.md" 2>/dev/null || \
	die "缺 deliver/RELEASE-README.md"

# ── 4. 自检 ────────────────────────────────────────────────────────
echo "== 4. 自检 =="
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  [OK  ] $1  $3"; else echo "  [FAIL] $1  期望 $2 实际 $3"; fail=1; fi; }

chk "网页包尺寸"      17170432 "$(stat -c%s "$OUT/firmware/wta301-op-25.12.6-$VER.bin" 2>/dev/null || echo 0)"
chk "TTL 包尺寸"      20447232 "$(stat -c%s "$OUT/firmware/rescue/wta301-op-25.12.6-$VER-ttl.bin" 2>/dev/null || echo 0)"
chk "u-boot 槽尺寸"   262144   "$(stat -c%s "$OUT/uboot-kit/wta301-uboot-p21c.bin" 2>/dev/null || echo 0)"
# 用 od 不用 hexdump：WSL 默认装的无关卡精简版没有 hexdump
chk "TPIMG magic"     0000010055aa9dd1 \
	"$(od -An -tx1 -N8 "$OUT/firmware/wta301-op-25.12.6-$VER.bin" | tr -d ' \n')"
chk "u-boot 槽 LZMA"  5d0000 \
	"$(od -An -tx1 -N3 "$OUT/uboot-kit/wta301-uboot-p21c.bin" | tr -d ' \n')"

# 每个 MD5SUMS 里的条目都要真的对得上
for d in firmware uboot-kit; do
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		want=${line%%  *}; file=${line#*  }
		got=$(md5sum "$OUT/$d/$file" 2>/dev/null | cut -d' ' -f1)
		[ "$want" = "$got" ] || { echo "  [FAIL] $d/$file md5"; fail=1; }
	done < "$OUT/$d/MD5SUMS.txt"
	echo "  [OK  ] $d/MD5SUMS.txt 逐条复核通过"
done

# 发布包里绝不能出现的东西
for bad in "uboot/p18" "uboot/p19" "uboot/p20" "uboot/p21" "ub_0"; do
	if find "$OUT" -path "*$bad*" | grep -q .; then
		echo "  [FAIL] 发布包里混进了 $bad（历史快照不要外发）"; fail=1
	fi
done
echo "  [OK  ] 无历史快照残留"

if [ $fail -ne 0 ]; then die "自检未通过"; fi

echo ""
echo "== 完成 =="
du -sh "$OUT"
find "$OUT" -maxdepth 2 -type f -printf '%12s  %p\n' | sed "s|$OUT/||" | sort -k2
