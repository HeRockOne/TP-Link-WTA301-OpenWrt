#!/bin/sh
# test-txpower.sh —— 2.4G 发射功率天花板对照实验（唯一变量：country + txpower）
#
# 目的：区分「2.4G 的 20 dBm 是 regdb 卡的还是 BDF 卡的」。
#   regdb 卡的 → 换 country 就能提
#   BDF   卡的 → 只有改 board-2.bin 才能提
#
# 安全性：
#   - 只改 uci wireless，不碰 flash、不碰 BDF、不碰 u-boot
#   - trap 保证任何退出路径（含 Ctrl-C）都恢复原 country / 原 txpower
#   - 无线会短暂中断（每次 wifi reload 约 10s），有线 SSH 不受影响
#
# 用法（在板子上跑，ppk/plink 灌入）：
#   sh test-txpower.sh > /tmp/txp.log 2>&1
#   sh test-txpower.sh CN US BO        # 自定义国家列表
#
# 判据：
#   看 [实际] 列。若 US 下 > CN 下 → regdb 是瓶颈，换国家码有效。
#   若 US/BO 下仍等于 CN 下 → BDF 是瓶颈，只能改 board-2.bin。

set -u

RADIO=radio0
PHY=phy0
TP_LIST="2000 2600 3000"
COUNTRY_LIST="${*:-CN US BO}"

log() { echo "$*"; }

# ---------- 环境检查 ----------
[ -f /etc/openwrt_release ] || { log "FATAL: 不是 OpenWrt"; exit 1; }
command -v iw >/dev/null 2>&1 || { log "FATAL: 无 iw"; exit 1; }
command -v iwinfo >/dev/null 2>&1 || { log "FATAL: 无 iwinfo"; exit 1; }
[ -d "/sys/class/ieee80211/$PHY" ] || { log "FATAL: 无 $PHY"; exit 1; }

# ---------- 保存原值 ----------
ORIG_COUNTRY=$(uci -q get wireless.$RADIO.country)
ORIG_TP=$(uci -q get wireless.$RADIO.txpower)
ORIG_CHAN=$(uci -q get wireless.$RADIO.channel)
ORIG_MODE=$(uci -q get wireless.$RADIO.htmode)
log "原配置: country=${ORIG_COUNTRY:-<未设>} txpower=${ORIG_TP:-<未设>} channel=${ORIG_CHAN:-<未设>} htmode=${ORIG_MODE:-<未设>}"

restore() {
	log ""
	log "=== 恢复原配置 ==="
	if [ -n "${ORIG_COUNTRY:-}" ]; then
		uci set wireless.$RADIO.country="$ORIG_COUNTRY"
	else
		uci -q delete wireless.$RADIO.country
	fi
	if [ -n "${ORIG_TP:-}" ]; then
		uci set wireless.$RADIO.txpower="$ORIG_TP"
	else
		uci -q delete wireless.$RADIO.txpower
	fi
	uci commit wireless
	wifi reload >/dev/null 2>&1
	sleep 8
	log "恢复后: country=$(uci -q get wireless.$RADIO.country) txpower=$(uci -q get wireless.$RADIO.txpower)"
	log "恢复后实际: $(iwinfo $PHY info 2>/dev/null | grep -i 'Tx-Power' | sed 's/^ *//')"
}
trap restore EXIT INT TERM

# ---------- 读实际功率 ----------
# iwinfo 报的是驱动实际生效值（已过 regdb × BDF × uci 三重取小）
actual_txpower() {
	iwinfo $PHY info 2>/dev/null | grep -i 'Tx-Power' | sed 's/.*Tx-Power: *//; s/dBm.*//' | tr -d ' '
}

# regdb 给这条信道的上限（iw phy 输出的括号值）
regdb_limit() {
	local ch=$1 freq
	# ch11=2462 ch6=2437 ch1=2412
	case $ch in
	1) freq=2412 ;; 6) freq=2437 ;; 11) freq=2462 ;;
	*) freq='' ;;
	esac
	[ -n "$freq" ] || { echo '?'; return; }
	iw phy $PHY info 2>/dev/null \
		| grep "^\s*\* $freq MHz" \
		| sed 's/.*(\([0-9.]*\) *dBm.*/\1/'
}

apply_and_measure() {
	local country=$1 tp=$2
	uci set wireless.$RADIO.country="$country" 2>/dev/null
	if [ "$tp" = "none" ]; then
		uci -q delete wireless.$RADIO.txpower
	else
		uci set wireless.$RADIO.txpower="$tp"
	fi
	uci commit wireless
	wifi reload >/dev/null 2>&1
	sleep 10

	local act reg up
	act=$(actual_txpower)
	reg=$(regdb_limit "$ORIG_CHAN")
	up=$(iwinfo $PHY info 2>/dev/null | grep -ci 'ESSID' )
	printf '  %-8s %-7s | regdb上限 %-6s | 实际 %-8s | %s\n' \
		"$country" "$tp" "${reg:-?}" "${act:-挂}" \
		"$( [ -n "$act" ] && echo OK || echo '⚠ 无线未起来' )"
}

# ---------- 跑 ----------
log ""
log "=== 基线 ==="
log "iw reg get:"; iw reg get 2>/dev/null | sed 's/^/  /'
log "信道上限:"; iw phy $PHY info 2>/dev/null | grep -E "2412|2437|2462 MHz" | sed 's/^/  /'
log "当前实际: $(actual_txpower) dBm"

log ""
log "=== 对照实验（信道 $ORIG_CHAN / $ORIG_MODE）==="
printf '  %-8s %-7s | %-13s | %-11s | %s\n' country txpower "regdb上限" "实际" 判定
log "  ------------------------------------------------------------------"

for c in $COUNTRY_LIST; do
	for tp in $TP_LIST; do
		apply_and_measure "$c" "$tp"
	done
done

# 也测一次「不设 txpower」（驱动默认）
for c in $COUNTRY_LIST; do
	apply_and_measure "$c" none
done

log ""
log "=== 解读 ==="
log "  若 US/BO 的实际值 > CN 的实际值  → regdb 是瓶颈，换国家码有效"
log "  若各国实际值都一样             → BDF 功率表是瓶颈，只能改 board-2.bin"
log ""
log "  （trap 将在退出时自动恢复原配置）"

