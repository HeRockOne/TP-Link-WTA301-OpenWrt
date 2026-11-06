#!/bin/sh
# scan-txpower.sh —— 逐档扫描 txpower，测出真实的硬件天花板
#
# 前提（已实测，见 docs/TXPOWER-LIMITS-EXTERNAL-EVIDENCE.md）：
#   phy0(2.4G) regdb 上限 30 dBm，实际 24 dBm → 不是 regdb 卡的
#   phy1(5G)   regdb 上限 30~33   ，实际 24 dBm → 不是 regdb 卡的
#   ⇒ 24 来自 BDF 功率表或驱动上限。本脚本用扫描确认它是不是硬顶。
#
# 安全性：只改 uci txpower，可逆；trap 恢复原值。
#
# 用法：
#   sh scan-txpower.sh phy0        # 只测 2.4G（推荐先跑）
#   sh scan-txpower.sh phy1        # 只测 5G（注意：会打断 phy1-sta0 的上连）
#   sh scan-txpower.sh both

set -u

TARGET="${1:-phy0}"
TP_LIST="1000 1500 2000 2200 2400 2500 2600 2700 2800 3000 3300 0"

case "$TARGET" in
phy0) RADIOS="radio0" ;;
phy1) RADIOS="radio1" ;;
both) RADIOS="radio0 radio1" ;;
*) echo "用法: $0 phy0|phy1|both"; exit 1 ;;
esac

[ -f /etc/openwrt_release ] || { echo "FATAL: 不是 OpenWrt"; exit 1; }

# ---------- 接口名 & 原值 ----------
iface_of() {
	case "$1" in
	radio0) echo phy0-ap0 ;;
	radio1) echo phy1-ap0 ;;
	esac
}

# 保存原值
for r in $RADIOS; do
	eval "ORIG_${r}=\$(uci -q get wireless.$r.txpower)"
done

restore() {
	echo ""
	echo "=== 恢复原 txpower ==="
	for r in $RADIOS; do
		eval "v=\${ORIG_$r:-}"
		if [ -n "$v" ]; then
			uci set wireless.$r.txpower="$v"
		else
			uci -q delete wireless.$r.txpower
		fi
	done
	uci commit wireless
	wifi reload >/dev/null 2>&1
	sleep 8
	for r in $RADIOS; do
		local ifc; ifc=$(iface_of "$r")
		printf '  %-8s txpower=%s → 实际 %s dBm\n' "$r" \
			"$(uci -q get wireless.$r.txpower || echo '<未设>')" \
			"$(iwinfo $ifc info 2>/dev/null | grep -i 'Tx-Power' | sed 's/.*Tx-Power: *//; s/dBm.*//' | tr -d ' ')"
	done
}
trap restore EXIT INT TERM

# ---------- 主循环 ----------
for r in $RADIOS; do
	ifc=$(iface_of "$r")
	phy=$(echo "$ifc" | sed 's/-ap0//')
	band=$([ "$r" = radio0 ] && echo 2.4G || echo 5G)
	chan=$(uci -q get wireless.$r.channel)

	echo ""
	echo "════════════════════════════════════════════════════════"
	echo "  $r ($band, $phy, 信道 $chan)"
	echo "════════════════════════════════════════════════════════"
	printf '  %-10s | %-10s | %s\n' "设置值" "实际值" "判定"
	echo "  -------------------------------------------"

	PREV=""
	for tp in $TP_LIST; do
		if [ "$tp" = "0" ]; then
			uci -q delete wireless.$r.txpower
			label="<未设>"
		else
			uci set wireless.$r.txpower="$tp"
			label="$tp"
		fi
		uci commit wireless
		wifi reload >/dev/null 2>&1
		sleep 9

		act=$(iwinfo $ifc info 2>/dev/null | grep -i 'Tx-Power' | sed 's/.*Tx-Power: *//; s/dBm.*//' | tr -d ' ')

		if [ -z "$act" ]; then
			judge="⚠ 接口没起来"
		elif [ -z "$PREV" ]; then
			judge="基准"
		elif [ "$act" = "$PREV" ]; then
			judge="= 无变化"
		else
			judge="↑ 变了"
		fi

		printf '  %-10s | %-10s | %s\n' "$label" "${act:-挂} dBm" "$judge"
		[ -n "$act" ] && PREV="$act"
	done
	echo ""
	echo "  解读：如果 2600 以上全是同一个值且不再上升，该值就是 BDF 硬顶。"
done

