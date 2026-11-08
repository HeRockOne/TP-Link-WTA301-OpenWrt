#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════
# 从零构建的八条判据 —— docs/REPRODUCTION-VERIFICATION.md §4.3 的执行版
#
#   用途：别人 clone 本仓库、自己从零编一遍之后，用这个脚本判定
#         「我编出来的东西跟发布版是不是一回事」。
#         本工程的 docs/REPRODUCTION-VERIFICATION.md §4 那七条 ⬜ 也是靠它填的。
#
#   用法：
#     bash deliver/verify-scratch-build.sh \
#          --log  /tmp/scratch-build.log \
#          --tree /root/scratch-tree \
#          --rel  /root/scratch-rel
#
#     --log   构建日志（必须含 WORLD_RC= / INSTALL_RC= 两行）
#     --tree  OpenWrt 源码树（apply-to-2512.sh 已经铺过的那棵）
#     --rel   make-release.sh 的 --out 目录（里面应有 pack/）
#
#   退出码：0 = 八条全过；1 = 有 FAIL 或 WARN
#
#   ⚠️ 本脚本**不**判断 md5 是否与发布版相同 —— 不可能相同，原因见
#      docs/REPRODUCTION-VERIFICATION.md §3（squashfs 时间戳）。
#      要判的是：结构、尺寸、关键文件内容。
# ══════════════════════════════════════════════════════════════════════════
set -u

RED=''; GRN=''; YLW=''; RST=''
if [ -t 1 ]; then RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RST=$'\e[0m'; fi
OK=0; WARN=0; FAIL=0; BADLINES=()
ok()   { OK=$((OK+1));   printf '  %s[OK]%s   %s\n'   "$GRN" "$RST" "$*"; }
warn() { WARN=$((WARN+1)); BADLINES+=("WARN  $*"); printf '  %s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
bad()  { FAIL=$((FAIL+1)); BADLINES+=("FAIL  $*"); printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$*"; }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '%s\n' "$*" >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)

LOG=""; TREE=""; REL=""
while [ $# -gt 0 ]; do
	case "$1" in
		--log)  LOG=$2;  shift 2 ;;
		--tree) TREE=$2; shift 2 ;;
		--rel)  REL=$2;  shift 2 ;;
		-h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "未知参数：$1（用 --log / --tree / --rel，-h 看帮助）" ;;
	esac
done
[ -n "$LOG" ]  || die "缺 --log"
[ -n "$TREE" ] || die "缺 --tree"
[ -n "$REL" ]  || die "缺 --rel"
[ -f "$LOG" ]  || die "日志不存在：$LOG"
[ -d "$TREE" ] || die "源码树不存在：$TREE"
[ -d "$REL/pack" ] || die "发行目录里没有 pack/：$REL/pack"

PACK=$REL/pack

# ── 已发布 v1.0.0 / p30 的基线（用来判「是不是一回事」）──────────────
# 把 "<0x04880000 0x00740000>" 归一化成 "0x4880000 0x740000"
# （dtc 会把 0x4880000 补成 0x04880000，DTS 源里则不补 —— 两边要能直接比）
norm_reg() {
	sed 's/.*reg = <//; s/>.*//; s/,/ /g' | tr -s ' ' '\n' \
		| while read -r v; do [ -n "$v" ] && printf '0x%x\n' "$v"; done \
		| paste -sd' ' -
}

#   这些常量来自真机上刷过并验收 PASS=30 FAIL=0 的那一份。
BASE_NETTUNE_MD5=8eaaa52f11cc9a1e1e4c6e01edc421f9
BASE_KERNEL_REG="0x4880000 0x740000"
BASE_KLEN=0x480000     # 内核区（含 0xFF 补齐到整区）
BASE_RLEN=0xbc0000     # rootfs 区
BASE_TPHDR=0x20000     # tphdr 区
BASE_WEB=0x1060000     # 网页包 = tphdr + kernel + rootfs
BASE_TTL=0x1380000     # TTL 救砖包（网页包 + u-boot 槽 + 尾部）
BASE_SYSUP=13394197    # sysupgrade（squashfs 有压缩率浮动，只判量级）

echo "══════════════════════════════════════════════════════════════"
echo " 从零构建判据 —— REPRODUCTION-VERIFICATION §4.3"
echo "   log  = $LOG"
echo "   tree = $TREE"
echo "   rel  = $REL"
echo "══════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════
sec "① / ② 构建与安装的返回码"

rc_of() {  # rc_of <名字> → 打印日志里该 RC 的值；找不到打印空
	sed -n "s/^$1=\([0-9][0-9]*\).*/\1/p" "$LOG" | tail -1
}
WRC=$(rc_of WORLD_RC)
IRC=$(rc_of INSTALL_RC)

if [ -z "$WRC" ]; then
	bad "日志里没有 WORLD_RC=（构建没跑完，或日志不是本脚本期待的那种）"
elif [ "$WRC" = "0" ]; then
	ok "① make world 返回 0"
else
	bad "① make world 返回 $WRC —— 查日志里的 ERROR：grep -n 'ERROR:' $LOG | tail"
fi

if [ -z "$IRC" ]; then
	bad "日志里没有 INSTALL_RC=（target/install 没跑完）"
elif [ "$IRC" = "0" ]; then
	ok "② make target/install 返回 0"
else
	bad "② make target/install 返回 $IRC"
fi

# 顺手把失败包定位出来（README 里说过：不要盲目重跑全量）
if [ "${WRC:-1}" != "0" ] || [ "${IRC:-1}" != "0" ]; then
	last=$(grep -n 'ERROR:\|Error [0-9]\|make\[[0-9]\]: \*\*\*' "$LOG" 2>/dev/null | tail -3)
	if [ -n "$last" ]; then
		printf '         最近的报错行：\n'
		printf '%s\n' "$last" | sed 's/^/           /'
	fi
fi

# ══════════════════════════════════════════════════════════════════
sec "③ 出包：五个区域 + sysupgrade 都在"

need_list=(
	"op_kernel_0x480000.bin|内核区"
	"op_rootfs_0xbc0000.bin|rootfs 区"
	"op_tphdr_0x20000.bin|tphdr 区"
	"ubi_rootfs_data3_wta301data.img|UBI overlay 卷（卷名必须是 wta301data）"
	"flash_cmds.txt|刷写指令"
	"FINGERPRINT.json|指纹"
)
for item in "${need_list[@]}"; do
	f=${item%%|*}; d=${item##*|}
	if [ -f "$PACK/$f" ]; then
		ok "③ $d  [$f  $(stat -c%s "$PACK/$f") B]"
	else
		bad "③ 缺 $d  [$f]"
	fi
done

# sysupgrade 名字带 board，用通配
SYSUP=$(ls -1 "$PACK"/*tplink_wta301*squashfs-sysupgrade.bin 2>/dev/null | head -1)
if [ -n "$SYSUP" ] && [ -f "$SYSUP" ]; then
	ok "③ sysupgrade  [$(basename "$SYSUP")  $(stat -c%s "$SYSUP") B]"
else
	bad "③ 没有 sysupgrade 包"
fi

# 网页包（网页刷写用）—— 由 make-deliverable.sh 产出，不是 make-release.sh。
# 所以这里分两级：make-release 阶段缺它只是 WARN（还没到那一步）。
#
# 文件名是 wta301-op-<ver>.bin（不是 *firmware_web.bin —— 那是我一开始猜的，
# 实际看 make-deliverable.sh 的产物命名）。排除掉 sysupgrade 与 rescue/ 下的 ttl。
WEB=$(ls -1 "$REL"/deliver/wta301-op-*.bin 2>/dev/null | grep -v sysupgrade | head -1)
if [ -n "$WEB" ] && [ -f "$WEB" ]; then
	ok "③ 网页包  [$(basename "$WEB")  $(stat -c%s "$WEB") B]"
	TTL=$(ls -1 "$REL"/deliver/rescue/*ttl*.bin 2>/dev/null | head -1)
	if [ -n "$TTL" ] && [ -f "$TTL" ]; then
		ok "③ TTL 包  [$(basename "$TTL")  $(stat -c%s "$TTL") B]"
	else
		warn "③ 还没有 TTL 包（rescue/*ttl*.bin）"
	fi
else
	warn "③ 还没有网页包 —— 它由 make-deliverable.sh 产出（下一步）：bash deliver/make-deliverable.sh <VER>"
fi

# ══════════════════════════════════════════════════════════════════
sec "④ DTS 源里的 kernel 分区必须是 0x4880000 / 0x740000"

DTSF=$TREE/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts
if [ ! -f "$DTSF" ]; then
	bad "④ 找不到 $DTSF"
else
	regline=$(grep -A3 'kernel@4880000' "$DTSF" 2>/dev/null \
		| grep -o 'reg = <[^>]*>' | head -1 | norm_reg)
	if [ "$regline" = "$BASE_KERNEL_REG" ]; then
		ok "④ DTS: kernel@4880000 reg = <$regline>"
	else
		bad "④ DTS: kernel@4880000 reg = <${regline:-未解析到}>（期望 <$BASE_KERNEL_REG>）"
		printf '         这会导致内核写进错误偏移 → 直接变砖。\n'
	fi
fi

# ══════════════════════════════════════════════════════════════════
sec "⑤ FIT 内嵌 DTB 的 reg 必须与 DTS 一致"

ITB=""
for c in "$TREE/bin/targets/qualcommax/ipq50xx/openwrt-qualcommax-ipq50xx-tplink_wta301-squashfs-kernel.bin" \
         "$TREE/bin/targets/qualcommax/ipq50xx/openwrt-qualcommax-ipq50xx-tplink_wta301-initramfs-kernel.bin" \
         "$PACK/op_kernel_0x480000.bin"; do
	[ -f "$c" ] && { ITB=$c; break; }
done

if [ -z "$ITB" ]; then
	warn "⑤ 找不到 kernel 镜像（ITB），跳过内嵌 DTB 核对"
elif ! command -v dumpimage >/dev/null || ! command -v fdtdump >/dev/null; then
	warn "⑤ 缺 dumpimage/fdtdump（apt install u-boot-tools device-tree-compiler），跳过"
else
	TMPD=$(mktemp -d)
	# FIT 里 fdt 通常是 image 1，但不能假设；先看有几个 image
	n=$(dumpimage -l "$ITB" 2>/dev/null | grep -c '^ Image ')
	found=""
	for i in $(seq 0 4); do
		dumpimage -T flat_dt -p "$i" -o "$TMPD/d$i.dtb" "$ITB" >/dev/null 2>&1 || continue
		# 只认含 kernel@4880000 的那个（那就是本板的 DTB）
		if fdtdump "$TMPD/d$i.dtb" 2>/dev/null | grep -q 'kernel@4880000'; then
			found=$i; break
		fi
	done
	if [ -z "$found" ]; then
		bad "⑤ ITB 里有 $n 个 image，但没一个 DTB 含 kernel@4880000"
	else
		regline=$(fdtdump "$TMPD/d$found.dtb" 2>/dev/null \
			| grep -A3 'kernel@4880000' | grep -o 'reg = <[^>]*>' | head -1 | norm_reg)
		if [ "$regline" = "$BASE_KERNEL_REG" ]; then
			ok "⑤ ITB(image $found).dtb: kernel@4880000 reg = <$regline>"
		else
			bad "⑤ ITB(image $found).dtb: reg = <${regline:-未解析到}>（期望 <$BASE_KERNEL_REG>）"
		fi
	fi
	rm -rf "$TMPD"
fi

# ══════════════════════════════════════════════════════════════════
sec "⑥ rootfs 里 usr/sbin/net-tune 的 md5"

SQ=""
for c in "$PACK/op_rootfs_0xbc0000.bin"; do
	[ -f "$c" ] && SQ=$c && break
done
if [ -z "$SQ" ]; then
	# 退一步：从 sysupgrade 包里取 root
	if [ -n "${SYSUP:-}" ] && [ -f "$SYSUP" ]; then
		TMPR=$(mktemp -d); tar -xf "$SYSUP" -C "$TMPR" 2>/dev/null
		SQ=$(find "$TMPR" -name root -type f 2>/dev/null | head -1)
	fi
fi

if [ -z "$SQ" ] || [ ! -f "$SQ" ]; then
	bad "⑥ 找不到 squashfs rootfs"
elif ! command -v unsquashfs >/dev/null; then
	warn "⑥ 缺 unsquashfs（apt install squashfs-tools），跳过"
else
	m=$(unsquashfs -cat "$SQ" usr/sbin/net-tune 2>/dev/null | md5sum | cut -d' ' -f1)
	if [ "$m" = "$BASE_NETTUNE_MD5" ]; then
		ok "⑥ net-tune md5 = $m"
	else
		bad "⑥ net-tune md5 = ${m:-取不到}（期望 $BASE_NETTUNE_MD5）"
		printf '         ★ 这一条最敏感：net-tune 是 net-tune 系列调优的落点，\n'
		printf '           变了说明 apply-to-2512.sh 铺的文件不是发布版那份。\n'
	fi
fi

# ══════════════════════════════════════════════════════════════════
sec "⑦ rootfs 里必须有的两个自研文件"

if [ -z "$SQ" ] || [ ! -f "$SQ" ] || ! command -v unsquashfs >/dev/null; then
	warn "⑦ 前置不足，跳过"
else
	LST=$(unsquashfs -l "$SQ" 2>/dev/null)
	for f in "usr/share/rpcd/ucode/wta301" "www/luci-static/resources/view/status/include/15_sensors.js"; do
		if printf '%s\n' "$LST" | grep -q "$f"; then
			ok "⑦ 在位：$f"
		else
			bad "⑦ 缺失：$f"
		fi
	done
fi

# ══════════════════════════════════════════════════════════════════
sec "⑨ 固件里真的有 LuCI 吗（feeds/.config 漏步的直接证据）"
# ⑧ 是间接证据（尺寸偏小）。这条是直接证据：看 manifest。
# 背景：实测踩过 —— 没跑 feeds install 或没铺 pin/ow2512-dot-config.txt 时，
# make world 返回 0、零报错，但 manifest 163 行（应190）、luci 包全无。
MAN=$(ls -1 "$TREE"/bin/targets/qualcommax/ipq50xx/*tplink_wta301*.manifest 2>/dev/null | head -1)
if [ -z "$MAN" ]; then
	# 退一步：从 rootfs 里看 /usr/share/luci 在不在
	if [ -n "$SQ" ] && [ -f "$SQ" ] && command -v unsquashfs >/dev/null; then
		if unsquashfs -l "$SQ" 2>/dev/null | grep -q 'usr/share/luci/menu.d'; then
			ok "⑨ rootfs 里有 usr/share/luci/menu.d（manifest 不在但有 LuCI）"
		else
			bad "⑨ rootfs 里没有 usr/share/luci/menu.d —— 没有 Web 界面"
		fi
	else
		warn "⑨ 找不到 manifest 也读不了 rootfs，跳过"
	fi
else
	npkg=$(wc -l < "$MAN")
	nluci=$(grep -c '^luci' "$MAN" 2>/dev/null || :)
	nluci=${nluci:-0}

	# ★ 不用拍脑袋的阈值，而是与 pin/p30-manifest.txt（发布版190 包）逐包比对。
	# 阈值太松会放过真问题（我一开始写 ≥25 个 luci，而实际发布版只有 19 个）；
	# 太紧会把合法选择当错误（ALLOW_NO_ARGON=1 时 argon 两个包确实不该在）。
	BASELINE=$SRC/pin/p30-manifest.txt
	if [ ! -f "$BASELINE" ]; then
		warn "⑨ 找不到 pin/p30-manifest.txt，只能报总数"
		ok "⑨ manifest：$npkg 个包，其中 luci* $nluci 个"
	else
		# 只比包名，不比版本（版本会因 feed 漂移而不同，那不是错误）
		cut -d' ' -f1 "$BASELINE" | sort > /tmp/.baseline_names
		cut -d' ' -f1 "$MAN"      | sort > /tmp/.actual_names
		MISSING=$(comm -23 /tmp/.baseline_names /tmp/.actual_names)
		EXTRA=$(comm -13 /tmp/.baseline_names /tmp/.actual_names)

		# argon 两个包是「可选输入」：argon 源码不在任何 feed 里，
		# 要用 ALLOW_NO_ARGON=1 才能跳过。缺了只是换个主题，不算错误。
		OPTIONAL=$(printf '%s\n' "luci-theme-argon" "luci-i18n-argon-config-zh-cn")
		missing_req=$(printf '%s\n' "$MISSING" | grep -vxF "$OPTIONAL" | grep . || :)
		missing_opt=$(printf '%s\n' "$MISSING" | grep -xF "$OPTIONAL" | grep . || :)

		if [ -z "$missing_req" ]; then
			ok "⑨ manifest $npkg 包：发布版基线里的必需包全在"
		else
			bad "⑨ 缺 $(printf '%s\n' "$missing_req" | wc -l) 个必需包（发布版 Manifest 里有）"
			printf '%s\n' "$missing_req" | sed 's/^/         - /'
			printf '         ★ feeds 没装全，或没铺 pin/ow2512-dot-config.txt。\n'
			printf '           两者都不会让 make world 报错 —— 见 README 构建章节的表。\n'
		fi
		if [ -n "$missing_opt" ]; then
			warn "⑨ 缺 Argon 主题（2 个包）—— 固件会用 Bootstrap。这不是错误，但要知道"
			printf '         %s\n' "$missing_opt"
			printf '         要 Argon：下载 luci-theme-argon v3.1.0 后用 ARGON_SRC=<路径> 重新 apply。\n'
		fi
		[ -n "$EXTRA" ] && warn "⑨ 比发布版多 $(printf '%s\n' "$EXTRA" | wc -l) 个包（一般无妨）"
	fi
	# luci-base 必须在（没它就是真没 WebUI）
	grep -q '^luci-base ' "$MAN" && ok "⑨ manifest 里有 luci-base" \
		|| bad "⑨ manifest 里没有 luci-base"
fi

# ══════════════════════════════════════════════════════════════════
sec "⑧ 尺寸必须与发布版同一量级（结构正确性）"

chk_size() {  # chk_size <文件> <期望字节(可写 0x) > <名字> <容差百分比>
	local f=$1 want=$2 name=$3 tol=${4:-0}
	# want 可能是 0x1060000 这种写法，先转成十进制再比（否则 "4718592" != "0x480000"）
	case "$want" in 0[xX]*) want=$(( want ));; esac
	[ -f "$f" ] || { bad "⑧ 缺 $name"; return; }
	local got; got=$(stat -c%s "$f")
	if [ "$tol" = "0" ]; then
		if [ "$got" -eq "$want" ]; then ok "⑧ $name = $got B（精确）"
		else bad "⑧ $name = $got B，期望 $want B"; fi
	else
		local lo=$(( want * (100 - tol) / 100 )) hi=$(( want * (100 + tol) / 100 ))
		if [ "$got" -ge "$lo" ] && [ "$got" -le "$hi" ]; then
			ok "⑧ $name = $got B（期望 $want ±${tol}%）"
		else
			bad "⑧ $name = $got B，超出 $want ±${tol}%"
		fi
	fi
}

chk_size "$PACK/op_kernel_0x480000.bin" "$BASE_KLEN" "内核区" 0
chk_size "$PACK/op_rootfs_0xbc0000.bin" "$BASE_RLEN" "rootfs 区" 0
chk_size "$PACK/op_tphdr_0x20000.bin"   "$BASE_TPHDR" "tphdr 区" 0
[ -n "${WEB:-}" ] && [ -f "${WEB:-}" ] && chk_size "$WEB" "$BASE_WEB" "网页包" 0
[ -n "${SYSUP:-}" ] && [ -f "${SYSUP:-}" ] && chk_size "$SYSUP" "$BASE_SYSUP" "sysupgrade" 3

# ══════════════════════════════════════════════════════════════════
sec "汇总"
printf '  OK=%d  WARN=%d  FAIL=%d\n' "$OK" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
	printf '\n%s判据未全过 —— 不要对外说「已从零验证可编译」。%s\n' "$RED" "$RST"
	printf '先把下面这些逐条查清（README §4.3 / REPRODUCTION-VERIFICATION.md §4）：\n'
	for l in "${BADLINES[@]}"; do printf '  %s\n' "$l"; done
	exit 1
fi

if [ "$WARN" -gt 0 ]; then
	printf '\n全部硬判据通过（%d 项），但有 %d 条跳过（缺工具或前置）。\n' "$OK" "$WARN"
	printf '补上工具后重跑才算完整：\n'
	for l in "${BADLINES[@]}"; do printf '  %s\n' "$l"; done
	exit 1
fi

cat <<'EON'

══════════════════════════════════════════════════════════════
 八条全过。可以这么说：

   「本仓库在全新树上 apply 后能从零编出结构正确的固件，
     内核/rootfs/tphdr 三区尺寸与分区偏移与发布版一致，
     内嵌 DTB 的 kernel@4880000 = 0x4880000/0x740000，
     rootfs 关键文件内容一致。」
   —— 但**不能**说 md5 相同（squashfs 时间戳，见 §3）。

 剩下的、脚本替代不了的：
   · 真机刷入并验收（deliver/check-v30.sh，期望 PASS=30/30）
   · 交叉刷保护（别擦当前所在槽）
══════════════════════════════════════════════════════════════
EON
exit 0

