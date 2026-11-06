#!/bin/sh
#
# verify-p28.sh —— 刷完 P28 固件后的验收判据（B1~B7）
#
# 用法（在板子上）：
#     ssh root@192.168.1.1 'sh -s' < verify-p28.sh
#   有 sysupgrade 包要一并干跑时：
#     ssh root@192.168.1.1 'sh -s' < verify-p28.sh  /tmp/op-sysupgrade.bin
#
# 判据来源：wta301-2512/docs/P28-SYSUPGRADE-IN-OS.md §4.3
# 每一行只输出 OK / FAIL / SKIP，末尾汇总个数；有任何 FAIL ⇒ 退出码 1。

IMG="${1:-}"
OK=0; FAIL=0; SKIP=0
ok()   { OK=$((OK+1));   echo "  [OK]   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
skip() { SKIP=$((SKIP+1)); echo "  [SKIP] $*"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: 期望 $2 实得 $3"; fi; }

echo "===== P28 验收 ($(date '+%F %T')) ====="
echo "固件: $(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_ID $DISTRIB_RELEASE $DISTRIB_REVISION")"
echo ""

# ── B1 kernel 分区已加宽 ──────────────────────────────────────────────
# 这是整件事的前提：FIT 是 4,280,940 B（0x41526c），比 factory 表的 0x400000
# 大 86,636 B。声明小了 mtd write 会直接拒绝，sysupgrade 写不进内核。
echo "B1. kernel 分区声明（必须 0x740000，否则内核写不进去）"
_k=$(cat /sys/class/mtd/mtd5/size 2>/dev/null)
chk "mtd5 size" "7602176" "$_k"
_o=$(cat /sys/class/mtd/mtd5/offset 2>/dev/null)
chk "mtd5 offset（不能变）" "76021760" "$_o"
echo "       kernel 区尾 = $(( _o + _k )) B（应 = 0x4fc0000 = rootfs 起点）"
echo ""

# ── B2 rootfs 仍是 mtd6（bootargs 硬编码 root=/dev/mtdblock6）─────────
echo "B2. 分区序号没被改动（root=/dev/mtdblock6 靠这个）"
_n=$(grep -c '"rootfs"' /proc/mtd 2>/dev/null)
chk "名为 rootfs 的分区" "1" "$_n"
_r=$(sed -n '8p' /proc/mtd 2>/dev/null | sed 's/.*"\(.*\)"/\1/')
chk "/proc/mtd 第 8 行 = mtd6 的名字" "rootfs" "$_r"
_cmd=$(cat /proc/cmdline)
case "$_cmd" in
	*"root=/dev/mtdblock6"*) ok "bootargs 仍是 /dev/mtdblock6" ;;
	*) bad "bootargs 变了: $_cmd" ;;
esac
echo ""

# ── B3 platform.sh 有 wta301 分支 ─────────────────────────────────────
echo "B3. sysupgrade 平台支持（上游 v25.12.6 本身没有这块板）"
_p=/lib/upgrade/platform.sh
if [ -f "$_p" ]; then
	_n=$(grep -c 'tplink,wta301' "$_p" 2>/dev/null)
	chk "platform.sh 里 tplink,wta301 出现次数" "2" "$_n"
	grep -q 'wta301_write_member' "$_p" && ok "wta301_write_member() 存在" \
		|| bad "wta301_write_member() 不存在"
	grep -q 'does not fit mtd' "$_p" && ok "尺寸检查存在（拒绝截断内核）" \
		|| bad "缺尺寸检查"
else
	bad "没有 $_p"
fi
[ -x /sbin/sysupgrade ] && ok "/sbin/sysupgrade 可执行" || bad "/sbin/sysupgrade 缺失"
echo ""

# ── B4 overlay 位置没变（配置能保留的前提）───────────────────────────
echo "B4. overlay 必须在 mtd12 的 UBI 卷（写 mtd5/mtd6 才不会丢配置）"
_m=$(mount | grep ' on /overlay ')
case "$_m" in
	*ubi0_0*) ok "/overlay = ubi0_0 ($_m)" ;;
	*) bad "/overlay 不是 ubi 卷: $_m" ;;
esac
# 注意：busybox/mtd-utils 的 ubinfo -N 需要同时给 -d，只给名字会失败；
# 直接读 sysfs 更省事，且不依赖 mtd-utils 版本。
_v=$(cat /sys/class/ubi/ubi0_0/name 2>/dev/null)
chk "UBI 卷名（sysfs）" "wta301data" "$_v"
case "$(cat /proc/cmdline)" in
	*"fstools_overlay_name=wta301data"*) ok "bootargs 指向 wta301data" ;;
	*) bad "bootargs 没有 fstools_overlay_name=wta301data" ;;
esac
echo "       当前 overlay 占用: $(df -h /overlay 2>/dev/null | tail -1)"
echo ""

# ── B5 镜像干跑 ──────────────────────────────────────────────────────
echo "B5. sysupgrade 干跑（只检查，不写 flash）"
if [ -z "$IMG" ]; then
	skip "没传镜像参数（用法: verify-p28.sh <sysupgrade.bin>）"
elif [ ! -f "$IMG" ]; then
	bad "镜像不存在: $IMG"
else
	echo "       包: $IMG ($(ls -l "$IMG" | awk '{print $5}') B)"
	# 包里三个成员
	_d=$(cat "$IMG" | tar tf - 2>/dev/null | grep -m 1 '^sysupgrade-.*/$')
	_d=${_d%/}
	[ -n "$_d" ] && ok "tar 目录 $_d" || bad "不是 sysupgrade tar"
	if [ -n "$_d" ]; then
		_ks=$(cat "$IMG" | tar xOf - "$_d/kernel" | wc -c)
		_rs=$(cat "$IMG" | tar xOf - "$_d/root" | wc -c)
		_rm=$(cat "$IMG" | tar xOf - "$_d/root" | head -c 4)
		echo "       kernel=$_ks B  root=$_rs B  root magic=$_rm"
		[ "$_ks" -le "$_k" ] && ok "kernel 放得下 mtd5 ($_ks <= $_k)" \
			|| bad "kernel $_ks > mtd5 $_k"
		_rsz=$(cat /sys/class/mtd/mtd6/size)
		[ "$_rs" -le "$_rsz" ] && ok "root 放得下 mtd6 ($_rs <= $_rsz)" \
			|| bad "root $_rs > mtd6 $_rsz"
		[ "$_rm" = "hsqs" ] && ok "root 是 squashfs" || bad "root 不是 squashfs"
		_c=$(cat "$IMG" | tar xOf - "$_d/CONTROL")
		echo "       CONTROL: $_c"
	fi
	if sysupgrade -T "$IMG" >/tmp/p28-su.log 2>&1; then
		ok "sysupgrade -T 通过"
		sed 's/^/       /' /tmp/p28-su.log
	else
		bad "sysupgrade -T 失败（见下）"
		sed 's/^/       /' /tmp/p28-su.log
	fi
fi
echo ""

# ── B6 fwtool 元数据（决定会不会被要求 --force）──────────────────────
echo "B6. 镜像元数据（supported_devices 必须匹配 tplink,wta301）"
if [ -n "$IMG" ] && [ -f "$IMG" ]; then
	if fwtool -q -i /tmp/p28.meta "$IMG" 2>/dev/null; then
		ok "有 fwtool 元数据"
		grep -o '"supported_devices":\[[^]]*\]' /tmp/p28.meta 2>/dev/null | sed 's/^/       /'
		grep -q 'tplink,wta301' /tmp/p28.meta && ok "元数据含 tplink,wta301" \
			|| bad "元数据不含 tplink,wta301"
	else
		bad "没有 fwtool 元数据（会被要求 --force）"
	fi
else
	skip "没传镜像，跳过"
fi
echo "       本板 board_name: $(cat /tmp/sysinfo/board_name 2>/dev/null)"
echo ""

# ── B7 u-boot 救砖路径仍在 ───────────────────────────────────────────
echo "B7. 救砖路径未被破坏（B 槽 / 二级 u-boot 锚点）"
_bm=$(cat /sys/class/mtd/mtd4/offset 2>/dev/null)
chk "mtd4 normal_boot offset" "74448896" "$_bm"
_bs=$(cat /sys/class/mtd/mtd4/size 2>/dev/null)
chk "mtd4 size" "262144" "$_bs"
_bk=$(cat /sys/class/mtd/mtd10/offset 2>/dev/null)
chk "mtd10 kernel_bak offset" "8912896" "$_bk"
# boot_flag 只读检查，不写
_bf=$(hexdump -C -n 8 /dev/mtd13 2>/dev/null | head -1 | awk '{print $2$3$4$5" "$6$7$8$9}')
echo "       boot_flag 前 8 字节: $_bf （55aa4246 = 'U.BF'）"
case "$_bf" in
	55aa4246*) ok "boot_flag magic 'U.BF' 完好" ;;
	*) bad "boot_flag magic 异常: $_bf" ;;
esac
echo ""

echo "===== 汇总: OK=$OK FAIL=$FAIL SKIP=$SKIP ====="
[ "$FAIL" -eq 0 ] || exit 1