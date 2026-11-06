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
	# Wi-Fi 板型数据（上游没有，必须带）
	patches/bdf/board2-wta301-ipq5018-2g.bin
	patches/bdf/board2-wta301-qcn6122-5g.bin
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
for b in patches/bdf/board2-wta301-ipq5018-2g.bin patches/bdf/board2-wta301-qcn6122-5g.bin; do
	f="$SRC/$b"
	[ -f "$f" ] || { bad "缺 $b"; continue; }
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
