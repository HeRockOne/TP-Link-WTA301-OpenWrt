#!/bin/bash
# verify-repro.sh —— 复现性静态自检（不编译、不连板子，30 秒跑完）
#
# 为什么需要这个：
#   全量构建要 45 分钟，而且「构建成功」不等于「构建可复现」。
#   真正会让别人 clone 下来就跑不起来的问题，绝大多数是静态的：
#     · 脚本引用了仓库里不存在的文件
#     · 脚本里有本机绝对路径
#     · 补丁打不上（上游上下文变了）
#     · 文件缺失 / md5 变了
#     · 文档里写的判据与实际文件不符
#   这些问题都能离线查出来，不该等到编译失败或者刷砖才发现。
#
# 用法：
#   bash deliver/verify-repro.sh            # 全部检查
#   bash deliver/verify-repro.sh --quiet    # 只打印失败
#
# 退出码：0 全过 / 1 有失败
set -u
_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/lib-paths.sh"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

FAIL=0
WARN=0
n_ok=0

ok()   { n_ok=$((n_ok+1)); [ $QUIET -eq 1 ] || echo "  [OK  ] $*"; }
bad()  { FAIL=$((FAIL+1));    echo "  [FAIL] $*"; }
warn() { WARN=$((WARN+1));    echo "  [WARN] $*"; }
sec()  { [ $QUIET -eq 1 ] || { echo; echo "== $* =="; }; }

# ══════════════════════════════════════════════════════════════════
sec "1. 仓库结构完整性"
# ══════════════════════════════════════════════════════════════════
# 这些是构建链上真正被用到的输入，少一个就构建不出可用固件。
REQUIRED=(
	# 内核 / DTS
	files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts
	# 内核补丁（7 个，名字前缀固定）
	patches/kernel-6.12/0740-01-dt-bindings-net-ethernet-phy-increase-max-clock-count-to-two.patch
	patches/kernel-6.12/0740-03-arm64-qcom-ipq5018-add-gephy-rx-and-tx-clocks.patch
	patches/kernel-6.12/0740-04-net-phy-at803x-add-rx-and-tx-clock-management-for-ipq5018-phy.patch
	patches/kernel-6.12/0842-arm64-dts-qcom-ipq5018-add-uniphy-node.patch
	patches/kernel-6.12/0843-net-stmmac-add-get_interfaces-platform-method.patch
	patches/kernel-6.12/0951-net-pcs-add-uniphy-pcs.patch
	patches/kernel-6.12/0954-net-stmmac-Introduce-Qualcomm-IPQ5018-DWMAC-driver.patch
	patches/mac80211/0950-wifi-ath11k-reduce-DP-ring-sizes-256M.patch
	patches/fstools/0001-fstools-honor-fstools_overlay_name.patch
	# Wi-Fi 板型数据（board-2.bin）不在 REQUIRED 里：见 §8 —— 它装的是
	# 逐台校准数据，仓库故意不分发，由使用者用自己的 ART 生成。
	# u-boot kit
	patches/uboot/files/configs/ipq5018_tplink_wta301_defconfig
	patches/uboot/files/arch/arm/dts/ipq5018-tplink-wta301.dts
	patches/uboot/files/drivers/net/ipq5018/rtl8367s.c
	patches/uboot/build/build_j1.sh
	patches/uboot/build/mk_uboot_slot.py
	patches/uboot/README.md
	# 用户态 overlay
	files-rootfs/usr/sbin/net-tune
	files-rootfs/etc/init.d/net-tune
	files-rootfs/etc/sysctl.d/99-wta301-net.conf
	files-rootfs/usr/share/rpcd/ucode/wta301
	files-rootfs/usr/share/rpcd/acl.d/luci-mod-status-wta301.json
	files-rootfs/www/luci-static/resources/view/status/include/15_sensors.js
	files-base-files/etc/config/wireless
	files-base-files/etc/uci-defaults/99-wta301-wireless
	files-base-files/etc/uci-defaults/99-wta301-net
	files-ipq50xx-upgrade/lib/upgrade/platform.sh
	# 构建 / 出包 / 验收脚本
	deliver/lib-paths.sh
	deliver/apply-to-2512.sh
	deliver/apply-rootfs-only.sh
	deliver/make-release.sh
	deliver/make-deliverable.sh
	deliver/make-open-release.sh
	deliver/verify-repro.sh
	deliver/verify-p26.sh
	deliver/verify-p28.sh
	# 仓库内工具（出包必需；早期它们只在 work/ 里，别人 clone 下来跑不了）
	tools/mk_op_pack.py
	tools/mk_web_img.py
	tools/mk_board2_from_art.py
	tools/parse_board2.py
	tools/mk_single_img.py
	tools/mk_fingerprint.py
	tools/verify_single_bin.py
	# 许可与文档
	LICENSE
	README.md
	THIRD-PARTY.md
	docs/REPRODUCE.md
	docs/OPEN-SOURCE-RELEASE.md
)
miss=0
for f in "${REQUIRED[@]}"; do
	if [ ! -f "$SRC/$f" ]; then bad "缺文件：$f"; miss=1; fi
done
[ $miss -eq 0 ] && ok "${#REQUIRED[@]} 个必需文件全部存在"

# 仓库里不该有的东西
for junk in f; do
	[ -f "$SRC/$junk" ] && bad "仓库根有垃圾文件 '$junk'"
done
[ $FAIL -eq 0 ] && ok "无垃圾文件"

# ══════════════════════════════════════════════════════════════════
sec "2. 脚本无本机绝对路径"
# ══════════════════════════════════════════════════════════════════
# 允许出现在注释里（解释历史），不允许出现在可执行代码里。
BADSELF=0
for f in "$SRC"/deliver/*.sh; do
	# 去掉 # 开头的注释行、行尾注释，再看还剩什么
	hits=$(sed 's/#.*//' "$f" | grep -nE '/mnt/c/Users/Sophia|C:/Users/Sophia' || true)
	if [ -n "$hits" ]; then
		bad "$(basename "$f") 有本机绝对路径："
		echo "$hits" | sed 's/^/           /'
		BADSELF=1
	fi
done
# /root/ow2512 是约定默认值，允许出现在 lib-paths.sh 的默认赋值里，别处只许注释
for f in "$SRC"/deliver/*.sh; do
	[ "$(basename "$f")" = "lib-paths.sh" ] && continue
	hits=$(sed 's/#.*//' "$f" | grep -nE '/root/ow2512|/root/nss-edma|/root/rel' || true)
	if [ -n "$hits" ]; then
		bad "$(basename "$f") 有硬编码输出/源码路径（应用 \$OWTREE/\$REL）："
		echo "$hits" | sed 's/^/           /'
		BADSELF=1
	fi
done
[ $BADSELF -eq 0 ] && ok "deliver/*.sh 全部参数化"

# 所有 shell 脚本语法
SYN=0
for f in "$SRC"/deliver/*.sh "$SRC"/patches/uboot/build/*.sh; do
	bash -n "$f" 2>/dev/null || { bad "语法错误：${f#$SRC/}"; SYN=1; }
done
[ $SYN -eq 0 ] && ok "所有 .sh 语法通过"

# python 工具语法 + 能跑 --help
PYN=0
for f in "$SRC"/tools/*.py; do
	python3 -m py_compile "$f" 2>/dev/null || { bad "python 语法错误：${f#$SRC/}"; PYN=1; }
done
[ $PYN -eq 0 ] && ok "tools/*.py 全部可编译"
rm -rf "$SRC"/tools/__pycache__ 2>/dev/null

# ══════════════════════════════════════════════════════════════════
sec "3. 文件末尾换行（heredoc 静默吞命令的根源）"
# ══════════════════════════════════════════════════════════════════
# 没有末尾换行时，`cat > f << 'EOF'` 的结束标记会粘到最后一行，
# 后面的 shell 命令被整段吞进目标文件。已经踩过两次。
NONL=0
# 注意：必须把路径搞成绝对路径（或先 cd），否则相对的 $f 会按**调用者的 cwd**
# 解析 —— 不在 $SRC 下时会一律不存在、被 `[ -s ]` 默默 continue 跳过，
# 结果就是该项永远报 PASS。第一版就在这里假通过过。
while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	case "$rel" in *.bin|*.png|*.jpg|*.gz|*.apk|*.ipk|*.dtb|*.pyc) continue ;; esac
	f="$SRC/$rel"
	[ -f "$f" ] || continue
	[ -s "$f" ] || continue
	last=$(tail -c 1 "$f" | od -An -c | tr -d ' \n')
	if [ "$last" != '\n' ]; then
		bad "缺末尾换行：$rel"
		NONL=$((NONL+1))
	fi
done < <( cd "$SRC" && { git ls-files 2>/dev/null || find . -type f -printf '%P\n'; } )
[ $NONL -eq 0 ] && ok "所有文本文件都有末尾换行"

# ══════════════════════════════════════════════════════════════════
sec "4. 上游版本固定"
# ══════════════════════════════════════════════════════════════════
if [ -f "$OWTREE/.git/HEAD" ] || [ -d "$OWTREE/.git" ]; then
	cd "$OWTREE" || true
	HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
	WANT="64900e756efa667774214f9c6b17c113222e01f7"
	if [ "$HEAD" = "$WANT" ]; then
		ok "OpenWrt 树在固定 commit ${WANT:0:12}（v25.12.6）"
	else
		warn "OpenWrt 树 HEAD ${HEAD:0:12} != 文档记载的 ${WANT:0:12}"
		echo "           若不是 v25.12.6，补丁可能打不上（这是预期内的硬约束）"
	fi
	grep -q 'KERNEL_PATCHVER:=6.12' "$OWTREE/target/linux/qualcommax/Makefile" 2>/dev/null \
		&& ok "内核分支 6.12" || bad "内核分支不是 6.12"
else
	warn "没有 OpenWrt 树（$OWTREE），跳过上游核对"
	echo "           设置 OWTREE=/path/to/openwrt 后重跑本节"
fi

# ══════════════════════════════════════════════════════════════════
sec "5. 补丁能否干净应用（对上游原文做 dry-run）"
# ══════════════════════════════════════════════════════════════════
# 这是复现性最关键的一步：别人的树里补丁打不上，整个构建就废了。
# 做法：用 git show 取上游原文，再看补丁的上下文能否对上。
if [ -d "$OWTREE/.git" ]; then
	cd "$OWTREE" || true
	PATCH_OK=0
	PATCH_N=0
	for p in "$SRC"/patches/kernel-6.12/*.patch; do
		PATCH_N=$((PATCH_N+1))
		if git apply --check --directory=. "$p" 2>/dev/null; then
			:
		else
			# 内核补丁是给 linux 源码树用的，OpenWrt 树里没有那个路径，
			# 会报 "No such file"。这不算失败，只是不能在这里 dry-run。
			:
		fi
	done
	ok "内核补丁 $PATCH_N 个（路径属于 linux 树，在 OpenWrt 树内无法 dry-run，构建时由 quilt 应用）"

	# 真正能在这里 dry-run 的是对 OpenWrt 自身文件的替换类 overlay
	# files-ipq50xx-upgrade 是整份替换，不是 patch，检查它是否被上游改过
	UP="$OWTREE/target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/platform.sh"
	OURS="$SRC/files-ipq50xx-upgrade/lib/upgrade/platform.sh"
	# 比字节时要忽略**末尾换行差异**。仓库侧刻意保证有末尾换行（heredoc 坑），
	# 而已经铺进树里的副本可能还是旧的无换行版本 —— 逐字节比会报假 FAIL。
	norm() { printf '%s' "$(cat "$1")"; }
	if [ -f "$UP" ] && [ -f "$OURS" ]; then
		if [ "$(norm "$UP")" = "$(norm "$OURS")" ]; then
			ok "platform.sh 已就位（与仓库副本内容一致）"
		else
			# 树里是上游原版时，说明还没 apply —— 这不是错误
			git show HEAD:target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/platform.sh \
				> /tmp/_up_platform.sh 2>/dev/null
			if [ "$(norm /tmp/_up_platform.sh)" = "$(norm "$UP")" ]; then
				warn "platform.sh 还是上游原版（apply-to-2512.sh 尚未运行）"
			else
				bad "platform.sh 既不是上游原版也不是我们的版本 —— 被谁改过？"
				diff -u /tmp/_up_platform.sh "$UP" 2>/dev/null | head -20 | sed 's/^/           /'
			fi
			rm -f /tmp/_up_platform.sh
		fi
	fi
else
	warn "没有 OpenWrt 树，跳过补丁 dry-run"
fi

# ══════════════════════════════════════════════════════════════════
sec "6. 关键常量自洽（改一个必须改一片的地方）"
# ══════════════════════════════════════════════════════════════════
DTS="$SRC/files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts"
if [ -f "$DTS" ]; then
	# P28：kernel 分区加宽到 0x740000，必须等于 0x4fc0000-0x4880000
	KREG=$(grep -A3 'kernel@4880000' "$DTS" | grep -o '0x4880000 0x[0-9a-f]*' | awk '{print $2}')
	if [ "$KREG" = "0x740000" ]; then
		ok "DTS kernel 分区 0x740000（= 0x4fc0000 - 0x4880000）"
	else
		bad "DTS kernel 分区是 '$KREG'，应为 0x740000（否则系统内 sysupgrade 会被 mtd 拒绝）"
	fi
	# 同一常数必须和 tools/mk_web_img.py 的 KERNEL_MAX 一致
	if grep -q 'KERNEL_MAX = 0x740000' "$SRC/tools/mk_web_img.py" 2>/dev/null; then
		ok "mk_web_img.py KERNEL_MAX 与 DTS 一致"
	else
		bad "mk_web_img.py 的 KERNEL_MAX 与 DTS 的 0x740000 不一致"
	fi
else
	bad "缺 DTS：$DTS"
fi

# platform.sh 里必须有两个 case，且不预作废 kernel
PS="$SRC/files-ipq50xx-upgrade/lib/upgrade/platform.sh"
if [ -f "$PS" ]; then
	grep -q 'tplink,wta301' "$PS" && ok "platform.sh 有 tplink,wta301 分支" \
		|| bad "platform.sh 缺 tplink,wta301 分支（会落 default_do_upgrade 写不存在的分区）"
	grep -q 'wta301_write_member' "$PS" && ok "platform.sh 有 wta301_write_member" \
		|| bad "platform.sh 缺写入函数"
	# 刻意不做的事：预作废 kernel 会让断电后无法回退
	if grep -qE 'mtd erase.*kernel|^\s*ci_erase' "$PS"; then
		warn "platform.sh 里出现了 erase kernel —— 本板无可靠回退槽，这可能导致断电后无法启动"
	else
		ok "platform.sh 未预作废 kernel（刻意为之）"
	fi
fi

# ══════════════════════════════════════════════════════════════════
sec "7. u-boot kit 判据"
# ══════════════════════════════════════════════════════════════════
UBR="$SRC/patches/uboot/README.md"
if [ -f "$UBR" ]; then
	# README §3 写的 md5 必须和 make-deliverable.sh 里的硬比对一致
	RMD5=$(grep -oE '\bd0ada9f76e4f1aba9b96a559a5220cee\b' "$UBR" | head -1)
	DMD5=$(grep -oE '\bd0ada9f76e4f1aba9b96a559a5220cee\b' "$SRC/deliver/make-deliverable.sh" | head -1)
	if [ -n "$RMD5" ] && [ "$RMD5" = "$DMD5" ]; then
		ok "u-boot 槽 md5 判据两处一致（${RMD5:0:16}…）"
	elif [ -z "$RMD5" ]; then
		warn "patches/uboot/README.md 里找不到槽 md5 判据"
	else
		bad "u-boot 槽 md5：README=$RMD5 与 make-deliverable.sh=$DMD5 不一致"
	fi
	# 章节 §5 警告的历史快照必须还在（否则说明有人删了追溯材料）
	[ -d "$SRC/patches/uboot/p21" ] && ok "历史快照 p18~p21 仍在仓库（可追溯，不进发布包）" \
		|| warn "patches/uboot/p18~p21 缺失（不影响构建，只影响追溯）"
fi

# files/ 必须是整份 overlay，不是 diff —— 靠「文件数 > 20」粗略判
NF=$(find "$SRC/patches/uboot/files" -type f 2>/dev/null | wc -l)
if [ "$NF" -ge 20 ]; then
	ok "u-boot files/ 是整份 overlay（$NF 个文件）"
else
	bad "u-boot files/ 只有 $NF 个文件，像是残留的 diff 而非整份 overlay"
fi

# ★ 上游归属：每个文件的原作者版权头都不能少。
#   删掉即违反 GPL-2.0 §1（保留版权声明）。这是整个仓库最容易
#   在某次“清理注释”中被无意破坏、而且破了不会报错的东西。
#
#   注意：这些文件不是同一个上游的！第一版检查假设“全部是 chenxin527”
#   就直接报了假 FAIL（upgrade.c 实际是 MediaTek 的代码）。必须逐文件声明。
CHK_OWNER() {
	# $1 = 相对路径  $2 = 应包含的版权串（空 = 只查有版权头即可）
	local f="$SRC/patches/uboot/files/$1" want="$2"
	if [ ! -f "$f" ]; then
		bad "u-boot 归属：缺 $1"; return
	fi
	if [ -z "$want" ]; then
		grep -qiE 'copyright' "$f" && ok "归属在位：$1" \
			|| warn "$1 无版权头（见 THIRD-PARTY.md §3.1 的来历说明）"
		return
	fi
	if grep -qF "$want" "$f"; then
		ok "归属在位：$1 ← $want"
	else
		bad "$1 丢了版权头「$want」（违反 GPL-2.0 §1）"
	fi
}

CHK_OWNER board/qca/arm/common/failsafe.c "Copyright (C) 2026 chenxin527"
CHK_OWNER board/qca/arm/common/fw_dec.c  "Copyright (C) 2026 chenxin527"
CHK_OWNER failsafe/failsafe.c            "Copyright (C) 2026 chenxin527"
CHK_OWNER failsafe/modules/modules.h     "Copyright (C) 2026 chenxin527"
CHK_OWNER include/failsafe/fw_dec.h      "Copyright (C) 2026 chenxin527"
# upgrade.c 是 OpenWrt 原版 failsafe，来自 MediaTek —— 与 chenxin527 无关
CHK_OWNER failsafe/modules/upgrade.c     "Copyright (C) 2022 MediaTek Inc."
# 这 4 个文件无 copyright 头（来历不确定），但必须有 SPDX 声明许可
for rel in board/qca/arm/common/tplink_tpimg.c drivers/net/ipq5018/rtl8367s.c \
           failsafe/modules/tplinkinfo.c include/failsafe/tplink_tpimg.h; do
	f="$SRC/patches/uboot/files/$rel"
	if [ ! -f "$f" ]; then
		bad "u-boot 归属：缺 $rel"
	elif grep -q 'SPDX-License-Identifier' "$f"; then
		ok "SPDX 在位：$rel"
	else
		bad "$rel 没有 SPDX-License-Identifier（发布包不应有完全无许可声明的文件）"
	fi
done

# THIRD-PARTY.md 必须同时声明两个上游，否则对外发布时无人知晓
for who in chenxin527 MediaTek; do
	if grep -qi "$who" "$SRC/THIRD-PARTY.md" 2>/dev/null; then
		ok "THIRD-PARTY.md 已声明 $who 归属"
	else
		bad "THIRD-PARTY.md 没提 $who —— 对外发布缺 GPL 归属"
	fi
done

# GPL-2.0 §2(a)：改过的文件要有修改声明。
# §3：分发二进制要有对应源码声明。两者都在 CHANGES.md。
CH="$SRC/patches/uboot/CHANGES.md"
if [ ! -f "$CH" ]; then
	bad "缺 patches/uboot/CHANGES.md —— GPL-2.0 §2(a)/§3 要求修改声明与对应源码声明"
else
	grep -q '§2(a)\|2(a)' "$CH" && grep -q '对应源码\|Corresponding Source' "$CH" \
		&& ok "CHANGES.md 含 §2(a) 修改声明 + §3 对应源码声明" \
		|| bad "CHANGES.md 缺 §2(a) 或 §3 声明"
	# 23 个 overlay 文件是否在 CHANGES.md 里都有逐文件说明
	MISS=0
	while IFS= read -r rel; do
		grep -qF "\`$rel\`" "$CH" || { MISS=$((MISS+1)); warn "CHANGES.md 未描述 $rel"; }
	done < <(cd "$SRC/patches/uboot/files" && find . -type f | sed 's|^\./||')
	[ "$MISS" -eq 0 ] && ok "CHANGES.md 覆盖全部 23 个 overlay 文件"
fi

# 如果能找到本机 u-boot 源树（不在仓库内），校验 files/ 与它无内容差异。
# 为什么忽略末尾换行：仓库侧按 POSIX 习惯给 19 个文件补了末尾换行，
# 源树里是从 tar 解出来的无换行版本。两者内容一致、编译产物一致，
# 逐字节比会报 19 个假 FAIL（我在 e33c9a7 就制造过这个坑）。
UBT=""
for c in "$(dirname "$SRC")/src/u-boot-2016" "$WORK/../src/u-boot-2016"; do
	[ -d "$c" ] && { UBT="$c"; break; }
done
if [ -n "$UBT" ]; then
	CNT=0; DIFFS=0; REALS=0
	while IFS= read -r rel; do
		a="$UBT/$rel"; b="$SRC/patches/uboot/files/$rel"
		[ -f "$a" ] || { REALS=$((REALS+1)); bad "u-boot: $rel 在源树里不存在"; continue; }
		CNT=$((CNT+1))
		if [ "$(printf '%s' "$(cat "$a")")" != "$(printf '%s' "$(cat "$b")")" ]; then
			REALS=$((REALS+1)); bad "u-boot: $rel 与源树**内容**不同（不只是行尾）"
		fi
	done < <(cd "$SRC/patches/uboot/files" && find . -type f | sed 's|^\./||')
	if [ "$REALS" -eq 0 ]; then
		ok "u-boot files/ 与源树内容一致（$CNT 个文件，已忽略末尾换行）"
	fi
else
	warn "未找到 u-boot 源树（正常：树不进仓库），files/ 与源树的比对已跳过"
fi

# ══════════════════════════════════════════════════════════════════
sec "8. BDF 与板级匹配（Wi-Fi 起不来的经典原因）"
# ══════════════════════════════════════════════════════════════════
# board-2.bin 装的是**逐台**射频校准数据（从 ART 分区提取），
# 属于厂商烧进 flash 的数据 —— 本仓库故意不分发（THIRD-PARTY §2）。
# 所以这里的分支是：
#   文件不在 → WARN 且给出生成方法（这是正常的、预期的状态）
#   文件在   → 必须过完整校验（variant 名 / 小端结构），错了一样是 BAD
BDF_MISSING=0
for b in patches/bdf/board2-wta301-ipq5018-2g.bin patches/bdf/board2-wta301-qcn6122-5g.bin; do
	f="$SRC/$b"
	if [ ! -f "$f" ]; then
		BDF_MISSING=1
		warn "未生成 $b（正常：仓库不分发校准数据）。"
		continue
	fi
	# variant 名必须与 DTS 的 qcom,ath11k-calibration-variant 逐字节一致
	if grep -qa 'variant=TP-Link-WTA301' "$f"; then
		ok "$(basename "$b") variant=TP-Link-WTA301"
	else
		bad "$(basename "$b") 里没有 variant=TP-Link-WTA301（ath11k 会 -12 加载失败）"
	fi
	# 容器结构必须能被仓库自带的解析器读通。
	# parse_board2.py 曾在用大端（`>I`）解析小端字段，跑仓库自带的两个 BDF
	# 直接 `struct.error` —— 工具是坏的而没人发现，因为它不在任何脚本路径上。
	# 把它接进自检，以后改坏了会立刻报。
	if python3 "$SRC/tools/parse_board2.py" "$f" >/dev/null 2>&1; then
		ok "$(basename "$b") 能被 parse_board2.py 解通（小端结构正确）"
	else
		bad "$(basename "$b") parse_board2.py 解不通 —— 容器结构或字节序有问题"
	fi
done
# DTS 里两个射频各一行 calibration-variant，两行必须相同；用 sort -u 合并
distinct=$(grep -o 'qcom,ath11k-calibration-variant = "[^"]*"' "$DTS" 2>/dev/null \
	| sed 's/.*"\(.*\)"/\1/' | sort -u)
if [ "$distinct" = "TP-Link-WTA301" ]; then
	ok "DTS calibration-variant = $distinct（与 board-2.bin 对得上）"
elif [ -z "$distinct" ]; then
	bad "DTS 里没有 qcom,ath11k-calibration-variant（ath11k 会 -12）"
else
	bad "DTS calibration-variant = '$(echo $distinct)'，应为 TP-Link-WTA301"
fi

# 缺 BDF 时给一条可直接复制的用法（WARN 已计过，这里只补操作指引）
if [ "${BDF_MISSING:-0}" = "1" ]; then
	warn "生成方法：python3 tools/mk_board2_from_art.py --art <你的art.bin> --outdir patches/bdf"
	warn "            先 dump：ssh root@192.168.1.1 'dd if=/dev/mtdblock2 of=/tmp/art.bin' 再 scp 回来"
	warn "            详见 patches/bdf/README.md 与 THIRD-PARTY.md §2"
fi

# ══════════════════════════════════════════════════════════════════
sec "9. 交付包判据（尺寸是不可变的硬约束）"
# ══════════════════════════════════════════════════════════════════
# 这三个数字改了就说明布局变了，文档必须同步更新
for pair in "0x1060000:网页包紧凑布局:" \
            "0x1380000:TTL包稀疏布局:" \
            "0x40000:u-boot 槽长度:262144"; do
	v=$(echo "$pair" | cut -d: -f1)
	desc=$(echo "$pair" | cut -d: -f2)
	alt=$(echo "$pair" | cut -d: -f3)
	if grep -q "$v" "$SRC/deliver/make-deliverable.sh" 2>/dev/null || \
	   grep -q "$v" "$SRC/deliver/make-open-release.sh" 2>/dev/null || \
	   { [ -n "$alt" ] && { grep -q "$alt" "$SRC/deliver/make-deliverable.sh" 2>/dev/null || \
	                        grep -q "$alt" "$SRC/deliver/make-open-release.sh" 2>/dev/null; }; }; then
		ok "$desc $v 在出包脚本里有判据"
	else
		warn "$desc $v 在出包脚本里没有判据"
	fi
done

# ══════════════════════════════════════════════════════════════════
sec "10. 一键工具刷写正确性（防回退：裸 mtd / 无同槽保护 / 无回读）"
# ══════════════════════════════════════════════════════════════════
KITPS="$SRC/deliver/kit/wta301.ps1"
if [ ! -f "$KITPS" ]; then
	bad "deliver/kit/wta301.ps1 不存在"
else
	# 原厂 4.4.60 内核下写 /dev/mtdblockN 可用（本工具唯一路径：跑 B 槽写 A 槽）；
	# OpenWrt 6.12.112 下 mtdblock 报 I/O error，那边必须 mtd erase + mtd -q write。
	# 无论哪种，绝不能写裸 /dev/mtdN —— 内核不参与就不写 ECC，分区直接报废。
	if grep -nE 'dd [^|]*of=/dev/mtd[0-9]' "$KITPS" | grep -v 'mtdblock' | grep -qv '#'; then
		bad "ps1 里在写裸 /dev/mtdN（不写 ECC，分区会报废）"
	else
		ok "没有写裸 /dev/mtdN（只写 mtdblock，由内核算 ECC）"
	fi
	# 同槽保护：擦运行中的槽会持 MTD 全局锁把系统卡死
	# 判据不能只看「函数存在」，要看调用点真把会话传进去了 —— 上一版就是
	# 函数写对了、调用点漏上 -Sess，结果 $null.Kind 抛 Null 方法调用。
	if grep -q 'function Test-SameSlot' "$KITPS" && \
	   grep -q 'Test-SameSlot -Sess' "$KITPS"; then
		ok "有同槽保护（Test-SameSlot，且调用点传了会话）"
	else
		bad "缺同槽保护，或调用点没传 -Sess（会报 Null 值方法调用）"
	fi
	# 任何需要会话的内部函数，调用点必须传 -Sess；漏传必报 Null 方法调用。
	# 只抓真带参数的调用形态（Get-LiveRootOffset -Xxx），注释和提示文字里的
	# 字样不算，否则会把 Write-Err2 里的提示当成调用点误报。
	calls=$(grep -oE 'Get-LiveRootOffset -[A-Za-z]+' "$KITPS" | sort -u)
	if [ -z "$calls" ] || echo "$calls" | grep -qv -- '-Sess'; then
		bad "有 Get-LiveRootOffset 调用点没传 -Sess（会报 Null 值方法调用）"
	else
		ok "Get-LiveRootOffset 所有调用点都传了 -Sess"
	fi
	# 永不写的分区必须按绝对偏移挡
	if grep -q "0x4000000' = 'boot_flag" "$KITPS" && \
	   grep -q "0x0'       = 'factory_boot" "$KITPS"; then
		ok "写入门禁按绝对偏移（含 mtd0 / boot_flag）"
	else
		bad "缺按绝对偏移的写入门禁（mtd0 / boot_flag）"
	fi
	# 回读校验必须存在
	if [ "$(grep -c '回读' "$KITPS")" -ge 3 ]; then
		ok "写入后有回读 md5 校验"
	else
		bad "写入后没有回读校验"
	fi
	# 只保留原厂 -> OpenWrt 一条路
	if grep -q "kind = 'stock'" "$KITPS" && ! grep -q 'Invoke-FullOpenWrtToStock' "$KITPS"; then
		ok "只有原厂 -> OpenWrt 一条路径（无 OpenWrt -> 原厂 分支）"
	else
		bad "路径未收敛到原厂 -> OpenWrt 单一路径"
	fi
fi

# ══════════════════════════════════════════════════════════════════
sec "11. files-rootfs 权限（rpcd 会静默跳过 world-writable 的 ucode 脚本）"
# ══════════════════════════════════════════════════════════════════
FR="$SRC/files-rootfs"
if [ ! -d "$FR" ]; then
	bad "缺 files-rootfs/"
else
	# WSL 的 /mnt/c 是 DrvFs，默认不启用 metadata，所有文件都显示 777。
	# cp -a 会把这个假 777 带进 squashfs。rpcd 的 ucode 插件对 world-writable
	# 零容忍（上游 rpcd/ucode.c：`if (s.st_mode & S_IWOTH) { "Ignoring..." ; continue; }`），
	# 结果是 ubus 里没有 wta301 对象，LuCI 概览页 CPU/温度整段消失，
	# 前端只报 Not found，完全看不出是权限问题。所以这里在 WSL 里看到的 777
	# 不算失败（那是挂载假象），真正要查的是构建脚本有没有归一化。
	if grep -q 'chmod 0755 {} +' "$SRC/deliver/apply-rootfs-only.sh" && 	   grep -q 'find $ROOTFILES -type f -exec chmod 0644' "$SRC/deliver/apply-rootfs-only.sh"; then
		ok "apply-rootfs-only.sh 复制后做了权限归一化（目录 755 / 文件 644）"
	else
		bad "apply-rootfs-only.sh 没有权限归一化 —— /mnt/c 的假 777 会进 squashfs，rpcd 静默跳过 ucode 脚本"
	fi
	if grep -q 'find $ROOTFILES -type f -exec chmod 0644' "$SRC/deliver/apply-to-2512.sh"; then
		ok "apply-to-2512.sh 同样做了权限归一化"
	else
		bad "apply-to-2512.sh 缺权限归一化"
	fi
	# 无线覆盖档（见 docs/WIFI-SIGNAL-ENHANCE-EXTERNAL-EVIDENCE.md）
	# 发射功率 24 dBm 是硬顶：iw set txpower / 换国码 / 改 BDF 两处表 都实测无效。
	# 唯一有效杠杆是 basic_rate —— 它决定 beacon 与管理帧速率。
	#   2.4G basic 12 -> 1 Mbps = +10.8 dB（距离 x3.4）
	#   2.4G 加回 CCK     = 灵敏度 +8 dB
	#   5G   basic 24 -> 6 Mbps = +6 dB（x2.0）
	WCFG="$SRC/files-base-files/etc/config/wireless"
	if [ -f "$WCFG" ]; then
		if grep -q "option legacy_rates '1'" "$WCFG" && 		   grep -q "option basic_rate '1000 2000'" "$WCFG"; then
			ok "2.4G 覆盖档已固化：CCK 打开 + beacon 1 Mbps"
		else
			bad "2.4G 覆盖档缺失（beacon 会退回 12 Mbps，损失 10.8 dB 链路预算）"
		fi
		if grep -q "option basic_rate '6000 12000 24000'" "$WCFG"; then
			ok "5G 覆盖档已固化：beacon 6 Mbps（原 24 Mbps，+6 dB）"
		else
			bad "5G basic_rate 缺失（beacon 会退回 24 Mbps）"
		fi
		n=$(grep -c "option disassoc_low_ack '0'" "$WCFG")
		if [ "$n" -ge 2 ]; then
			ok "两频段均 disassoc_low_ack=0（ath11k 不会因弱信号误踢客户端）"
		else
			bad "disassoc_low_ack 未关（$n 处），弱信号客户端会被反复踢下线"
		fi
		# 5G 带宽 HE40（v30 决定）：80->40MHz = +3 dB，代价峰值吞吐减半。
		# 信道 161：本板扫描 44=26个AP(最强 -63dBm) / 161=1个AP，161 完胜。
		if grep -q "option htmode 'HE40'" "$WCFG"; then
			ok "5G 带宽 HE40（+3 dB 覆盖，峰值吞吐约减半）"
		else
			bad "5G htmode 不是 HE40（覆盖档的 +3 dB 丢失）"
		fi
		# 用 sed 取 radio1 段（awk 的区间若首尾同行会立刻结束，不能这么写）
		R1=$(sed -n "/config wifi-device 'radio1'/,/^config wifi-iface/p" "$WCFG")
		if echo "$R1" | grep -q "option channel '161'"; then
			ok "5G 信道 161（扫描实测本机 44=26 AP / 161=1 AP）"
		else
			warn "5G 信道不是 161（44 在本机实测有 26 个 AP，含 -63 dBm 强邻居）"
		fi
		# 不许写死 txpower：驱动默认即 BDF 上限，写了也不会更高，只会误导
		if grep -q "option txpower" "$WCFG"; then
			warn "wireless 里写了 txpower —— BDF 硬限 24 dBm，写了无用（建议删）"
		else
			ok "未写 txpower（驱动默认 = BDF 上限 24 dBm，正确）"
		fi
	else
		bad "缺 files-base-files/etc/config/wireless"
	fi
	# 开箱即用：时区 / NTP / 主机名。默认固件是 GMT0 + 国外 NTP，
	# 国内装完时间就是错的（日志时间戳错位、证书校验失败、计划任务错点）。
	SYS="$SRC/files-base-files/etc/uci-defaults/99-wta301-system"
	if [ -f "$SYS" ]; then
		grep -q "timezone='CST-8'" "$SYS" && grep -q "zonename='Asia/Shanghai'" "$SYS" 			&& ok "开箱时区 CST-8 / Asia/Shanghai" 			|| bad "时区没设成 CST-8（会显示 UTC 时间）"
		grep -q "ntp.aliyun.com" "$SYS" && ok "NTP 用国内可达源" 			|| warn "NTP 未指向国内源（openwrt.pool.ntp.org 在国内常不可达）"
		grep -q "hostname='WTA301'" "$SYS" && ok "主机名 WTA301" 			|| warn "主机名仍是默认 OpenWrt"
		bash -n "$SYS" 2>/dev/null && ok "99-wta301-system 语法 OK" 			|| bad "99-wta301-system 语法错误"
	else
		bad "缺 files-base-files/etc/uci-defaults/99-wta301-system"
	fi
	# uci-defaults 必须被 apply 脚本设成 0755，否则开机不执行
	grep -q "99-wta301-system" "$SRC/deliver/apply-to-2512.sh" 		&& ok "apply 脚本已复制 system 档" 		|| bad "apply-to-2512.sh 未复制 99-wta301-system（改完等于没生效）"
	# 打 kit 的脚本不许硬编码阶段号与镜像 md5。
	# 以前写死 p29 的 md5：出 v30 时忘了改，就会拿 p29 的哈希去校验 v30 的文件，
	# 表面上「校验通过」，实际装进包里的是别的东西（或者直接 die 掉）。
	KITSH="$SRC/deliver/make-getroot-kit.sh"
	if [ -f "$KITSH" ]; then
		if grep -qE 'check_md5 [0-9a-f]{32} .*wta301-op-25' "$KITSH"; then
			bad "make-getroot-kit.sh 里镜像 md5 是硬编码的（出下一版必忘改）"
		else
			ok "make-getroot-kit.sh 从 MD5SUMS.txt 取期望值，无硬编码镜像哈希"
		fi
		grep -q -- '--stage' "$KITSH" 			&& ok "make-getroot-kit.sh 支持 --stage（默认自动挑最新 deliver-final-*）" 			|| warn "make-getroot-kit.sh 不支持 --stage"
		bash -n "$KITSH" 2>/dev/null && ok "make-getroot-kit.sh 语法 OK" 			|| bad "make-getroot-kit.sh 语法错误"
	fi
	# 上板验收脚本存在且语法正确（v30 的每一项改动都要能在板上复核）
	if [ -f "$SRC/deliver/check-v30.sh" ]; then
		sh -n "$SRC/deliver/check-v30.sh" 2>/dev/null 			&& ok "check-v30.sh 语法 OK（上板逐项验收 v30 改动）" 			|| bad "check-v30.sh 语法错误"
	else
		bad "缺 deliver/check-v30.sh（没有可复现的上板验收）"
	fi
	# 移动端修复：Argon 主题的 .table 是真表格 + .th 是 nowrap，手机上必撑爆；
	# 而且 hide-xs / hide-sm 在 Argon 里根本没定义（只有 bootstrap/mobile.css 有）。
	# 修法是单独的 CSS + 在 head.ut 里多一行 <link>，必须在 cascade.css 之后。
	if [ -f "$FR/www/luci-static/argon/css/wta301-mobile.css" ]; then
		ok "有移动端修复 CSS：www/luci-static/argon/css/wta301-mobile.css"
	else
		bad "缺 wta301-mobile.css（手机上看无线列表会挤成一条）"
	fi
	if grep -q 'wta301-mobile.css' "$FR/usr/share/ucode/luci/template/themes/argon/head.ut" && 	   grep -q 'hide-xs' "$FR/www/luci-static/argon/css/wta301-mobile.css"; then
		ok "head.ut 已注入 <link>，且 CSS 补上了 Argon 缺失的 hide-xs"
	else
		bad "head.ut 没注入 wta301-mobile.css，或 CSS 没补 hide-xs"
	fi
	# rpcd ucode 脚本与 ACL 是这套机制的关键文件，必须存在
	for f in usr/share/rpcd/ucode/wta301 	         usr/share/rpcd/acl.d/luci-mod-status-wta301.json 	         www/luci-static/resources/view/status/include/15_sensors.js; do
		if [ -f "$FR/$f" ]; then
			ok "rpcd 三件套存在：$f"
		else
			bad "缺 $f（概览页 CPU/温度不会出现）"
		fi
	done
fi

# ══════════════════════════════════════════════════════════════════
sec "12. getroot 脚本（免拆机拿原厂 root）"
# ══════════════════════════════════════════════════════════════════
# 这套脚本是「普通用户不进 TTL 就能拿 root」的唯一现成路径，但它们
#   a) 含中文，必须是 UTF-8
#   b) 由 Windows CRLF 环境搬来，必须 LF（否则板上/python3 都别扭）
#   c) 会临时改本机网络，README 里写明了还原方式
#   d) negative/ 是故意保留的失败记录，删了就有人再撞一次
GR="$SRC/tools/getroot"
if [ -d "$GR" ]; then
	ok "存在 tools/getroot/"

	# 唯一推荐的主脚本：自包含（只依赖 scapy），且在 README 里被点名
	if [ -f "$GR/rawtcp_gw.py" ]; then
		ok "rawtcp_gw.py 在位（推荐路径）"
		if grep -q 'rawtcp_gw.py' "$GR/README.md"; then
			ok "README 点名了 rawtcp_gw.py"
		else
			bad "README 没提 rawtcp_gw.py，别人不知道该用哪个"
		fi
		# 关键设计不能被人「优化」掉：不加别名 / 每条连接重建 Elink
		if grep -q 'skipassource' "$GR/rawtcp_gw.py" && 		   grep -qiE '一律不碰|不给本机加|不断本机网' "$GR/rawtcp_gw.py"; then
			ok "rawtcp_gw.py 保留了「不加 IP 别名」的设计说明"
		else
			warn "rawtcp_gw.py 里找不到「不加别名」的说明，改代码时容易退回断网版本"
		fi
	else
		bad "缺 tools/getroot/rawtcp_gw.py"
	fi

	# 反面证据必须保留：SSDP 与「只毒化不加别名」两条路已被实测否定
	for f in negative/getroot2.py negative/ssdpbrute.py; do
		if [ -f "$GR/$f" ]; then
			ok "反面证据在位：$f"
		else
			bad "缺 $GR/$f（删了它，后来的人会再撞一次同样的墙）"
		fi
	done

	# legacy 四件套被 docs/GETROOT-AND-NORMAL-USER-FLASH.md §1.1 按名引用
	for f in legacy/getroot.py legacy/poison.py legacy/elink_gw4.py legacy/srv.py; do
		if [ -f "$GR/$f" ]; then
			ok "legacy 在位：$f"
		else
			warn "缺 $GR/$f（docs/GETROOT-AND-NORMAL-USER-FLASH.md §1.1 会变成断链）"
		fi
	done

	# 编码 / 换行 / 末尾换行 / 语法：全部 .py 逐个查
	npy=0
	for f in "$GR"/*.py "$GR"/negative/*.py "$GR"/legacy/*.py; do
		[ -f "$f" ] || continue
		npy=$((npy + 1))
		rel=${f#$SRC/}
		if grep -q $'\r' "$f" 2>/dev/null; then
			bad "$rel 含 CRLF（应统一 LF）"
		fi
		if [ -n "$(tail -c1 "$f")" ]; then
			bad "$rel 缺末尾换行"
		fi
		if command -v python3 >/dev/null 2>&1; then
			if ! python3 -c "import ast,sys
ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$f" 2>/dev/null; then
				bad "$rel 语法不通过（python3 ast.parse 失败）"
			fi
		fi
	done
	ok "getroot 下 $npy 个 .py 编码/换行/语法全过"

	# 危险动作必须在文档里被写明，不能只活在代码注释里
	if grep -qE 'ARP|毒化|断网|alias|别名' "$GR/README.md"; then
		ok "README 写明了 ARP 毒化 / 别名 / 断网风险"
	else
		bad "README 没写风险（ARP 毒化与别名都会改本机网络）"
	fi
	if grep -qE '自己(拥有|的)设备|仅限|只在你自己' "$GR/README.md"; then
		ok "README 有限用声明（只在自己的设备上用）"
	else
		warn "README 缺限用声明"
	fi
else
	bad "缺 tools/getroot/（免拆机拿 root 的脚本没进仓库）"
fi

# ══════════════════════════════════════════════════════════════════
sec "13. 从零构建判据脚本（回答「别人能否构建+刷入」）"
# ══════════════════════════════════════════════════════════════════
# 这个脚本本身不跑构建（要几小时），只做静态判据：
# 它在位、可执行、语法正确、判据条目数对得上、基线常量与已发布版一致。
VS=$SRC/deliver/verify-scratch-build.sh
if [ ! -f "$VS" ]; then
	bad "缺 deliver/verify-scratch-build.sh"
else
	ok "verify-scratch-build.sh 在位（$(wc -l < "$VS") 行）"
	[ -x "$VS" ] && ok "可执行位正确" || bad "verify-scratch-build.sh 没有可执行位"
	bash -n "$VS" 2>/dev/null && ok "语法通过" || bad "verify-scratch-build.sh 语法错误"

	# 八条判据必须都还在（有人删判据 = 自检形同虚设）
	miss=""
	for k in '①' '②' '③' '④' '⑤' '⑥' '⑦' '⑧'; do
		grep -q "\"$k" "$VS" || miss="$miss $k"
	done
	[ -z "$miss" ] && ok "八条判据齐全（①~⑧）" || bad "判据被删：$miss"

	# 基线常量必须与已发布的 v1.0.0/p30 一致，
	# 否则「别人编出来的和发布版比」就没有参照物。
	WANT_MD5=8eaaa52f11cc9a1e1e4c6e01edc421f9
	WANT_REG='0x4880000 0x740000'
	grep -q "$WANT_MD5" "$VS" && ok "基线 net-tune md5 与发布版一致" \
		|| bad "基线 net-tune md5 被改（应为 $WANT_MD5）"
	grep -q "$WANT_REG" "$VS" && ok "基线 kernel reg 与发布版一致" \
		|| bad "基线 kernel reg 被改（应为 $WANT_REG）"

	# 必须明确写着「md5 不可能相同」，否则等于对外撒谎
	grep -q 'md5 是否与发布版相同.*不可能相同\|不能.*逐字节\|不可能相同' "$VS" \
		&& ok "写明「做不到 md5 相同」（避免误导）" \
		|| warn "脚本里没写明 md5 不可能相同"

	# 复现文档必须指向它（否则别人不知道有这个工具）
	grep -q 'verify-scratch-build' "$SRC/docs/REPRODUCTION-VERIFICATION.md" \
		&& ok "REPRODUCTION-VERIFICATION.md 指向它" \
		|| bad "REPRODUCTION-VERIFICATION.md 没提这个判据脚本"
fi

# ══════════════════════════════════════════════════════════════════
sec "14. 出包链路不能硬依赖仓库外的文件"
# ══════════════════════════════════════════════════════════════════
# 实测踩过：make-release.sh 原来写
#     python3 mk_op_pack.py ... --uboot $WORK/backup/mtd4_normal_boot.bin || die
# 而 $WORK 是仓库的**上级目录**，别人 clone 下来一定没有那个文件 ⇒
# 出包在第 4 步直接死，报 FileNotFoundError，看不出是「可选输入缺失」。
#
# 判据：凡引用仓库外 $WORK/ 的地方，必须有回落或明确降级，不能 || die。
MR=$SRC/deliver/make-release.sh
if [ ! -f "$MR" ]; then
	bad "缺 deliver/make-release.sh"
else
	# --uboot 必须是可选的（通过数组拼参数）
	if grep -q 'UB_ARGS=(' "$MR" && grep -q 'UB_SLOT=' "$MR"; then
		ok "make-release.sh 的 --uboot 是可选的（UB_SLOT + UB_ARGS 回落）"
	else
		bad "make-release.sh 的 --uboot 又变回硬依赖了（外部用户会 FileNotFoundError）"
	fi
	# 直接 --uboot \$WORK 后面跟 die 的老写法必须消失
	if grep -qE -- '--uboot \$WORK/[^ ]* *\|\| *die' "$MR"; then
		bad "make-release.sh 又出现「--uboot \$WORK/... || die」硬依赖"
	else
		ok "没有 --uboot \$WORK/... || die 硬依赖"
	fi
	# mk_op_pack.py 的 --uboot 参数本身必须 optional
	if grep -q "add_argument('--uboot'" "$SRC/tools/mk_op_pack.py" 2>/dev/null; then
		grep -q "add_argument('--uboot', default=None" "$SRC/tools/mk_op_pack.py" \
			&& ok "mk_op_pack.py 的 --uboot 默认 None（可选）" \
			|| warn "mk_op_pack.py 的 --uboot 可能不是可选"
	else
		warn "找不到 tools/mk_op_pack.py，跳过"
	fi
fi

# make-deliverable.sh 的 u-boot 相关步骤必须降级而不是失败
MD=$SRC/deliver/make-deliverable.sh
if [ -f "$MD" ]; then
	if grep -q '不影响固件刷写' "$MD"; then
		ok "make-deliverable.sh 对缺 u-boot 明确降级（标注不影响刷写）"
	else
		bad "make-deliverable.sh 缺 u-boot 时可能硬失败"
	fi
fi

# 构建前两步（feeds / 权威 .config）必须被 apply-to-2512.sh 拦住
AP=$SRC/deliver/apply-to-2512.sh
if [ -f "$AP" ]; then
	grep -q 'feeds 没装全' "$AP" && ok "apply-to-2512.sh 拦 feeds 未装" \
		|| bad "apply-to-2512.sh 不拦 feeds 未装（会编出没 WebUI 的固件）"
	grep -q 'pin/ow2512-dot-config.txt' "$AP" && ok "apply-to-2512.sh 拦权威 .config 未铺" \
		|| bad "apply-to-2512.sh 不拦 .config 未铺（luci 包会全丢）"
fi

# ③ TP 头模板：mk_op_pack 不许再硬依赖 128 MB 全盘镜像
TH=$SRC/patches/tphdr/tphdr-head.hex
if [ ! -f "$TH" ]; then
	bad "缺 patches/tphdr/tphdr-head.hex（外部用户会卡在 make-release 第 4 步）"
else
	nl=$(wc -l < "$TH")
	h1=$(head -1 "$TH")
	[ "$nl" = "18" ] && ok "tphdr 模板 18 行" || bad "tphdr 模板应 18 行，实为 $nl"
	[ "$h1" = "0000010055aa9dd1a8c88331c969fbbf" ] \
		&& ok "tphdr 模板 magic 正确" || bad "tphdr 模板首行不符（magic 错）"
	# 关键字段（第 5、7 行 起）
	if sed -n '6p' "$TH" | grep -q '^04800000000200000488000000400000$'; then
		ok "tphdr +0x50/+0x58 = tphdr 0x4800000/0x20000 + kernel 0x4880000/0x400000"
	else
		bad "tphdr +0x50/+0x58 字段不符"
	fi
	if sed -n '7p' "$TH" | grep -q '^04fc000000c00000'; then
		ok "tphdr +0x60 = rootfs 0x4fc0000/0xC00000"
	else
		bad "tphdr +0x60 字段不符"
	fi
	# 机型字符串在 hex 文件里是 ASCII "WTA301V1" 的十六进制
	if grep -qi '5754413330315631' "$TH"; then
		ok "tphdr 含机型字符串 WTA301V1（hex 5754413330315631）"
	else
		bad "tphdr 缺机型字符串 WTA301V1"
	fi
	[ -f "$SRC/patches/tphdr/README.md" ] && ok "tphdr README 在位" \
		|| bad "缺 patches/tphdr/README.md（字段含义无人可查）"
	# 脚本必须能走模板分支
	grep -q '_load_tphdr' "$SRC/tools/mk_op_pack.py" 2>/dev/null \
		&& ok "mk_op_pack.py 有 _load_tphdr（模板回落）" \
		|| bad "mk_op_pack.py 没有模板回落，外部用户出不了包"
	grep -q 'flash_full_128M.bin' "$SRC/tools/mk_op_pack.py" 2>/dev/null && {
		# 允许出现在候选路径里，但不许当唯一来源后 return 1
		grep -q "if not os.path.isfile(BACKUP):" "$SRC/tools/mk_op_pack.py" \
			&& bad "mk_op_pack.py 又出现「BACKUP 不存在就失败」" \
			|| ok "mk_op_pack.py 没有把全盘镜像当硬依赖"
	}
fi

# ══════════════════════════════════════════════════════════════════
sec "总结"
# ══════════════════════════════════════════════════════════════════
echo ""
echo "  OK=$n_ok  WARN=$WARN  FAIL=$FAIL"
if [ $FAIL -ne 0 ]; then
	echo ""
	echo "  有 $FAIL 项失败 —— 别人 clone 下来会构建不出来，或者刷出来起不来。"
	echo "  逐条修掉再发版。"
	exit 1
fi
echo ""
echo "  静态检查全过。剩下的必须靠真机构建与刷写验证："
echo "    1) bash deliver/apply-to-2512.sh && make -j\$(nproc) world"
echo "    2) bash deliver/make-release.sh --version <VER>-2512 --stage <VER>"
echo "    3) bash deliver/make-deliverable.sh <ver>"
echo "    4) bash deliver/make-open-release.sh <VER>"
echo "    5) 上板：verify-p26.sh / verify-p28.sh"
exit 0


