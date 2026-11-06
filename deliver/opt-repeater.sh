#!/bin/sh
# opt-repeater.sh —— 弱信号中继优化实验（上游 5G，不可控）
#
# 目的：找出让 STA 在弱信号下"更稳、能连更远"的本地参数组合。
# 唯一变量：一次只改一项，每项测完恢复。
#
# 安全性：
#   - 只改 uci wireless，不碰 flash
#   - 完整备份到 /etc/config/wireless.bak.opt
#   - trap 保证退出/中断都恢复
#   - 有线（br-lan 192.168.1.1）不受影响，SSH 控制不断
#
# 用法：
#   sh opt-repeater.sh baseline   # 只记录基线，不改
#   sh opt-repeater.sh distance   # 测 distance 参数
#   sh opt-repeater.sh width      # 测带宽变体
#   sh opt-repeater.sh cell       # 测 cell_density
#   sh opt-repeater.sh all        # 全测
#   sh opt-repeater.sh restore    # 恢复备份

set -u

BAK=/etc/config/wireless.bak.opt
STA=radio1
IFC=phy1-sta0

log() { echo "$*"; }
hr()  { log "────────────────────────────────────────────"; }

# ---------- 备份 / 恢复 ----------
do_backup() {
	[ -f "$BAK" ] || cp /etc/config/wireless "$BAK"
	log "备份: $BAK"
}

do_restore() {
	if [ -f "$BAK" ]; then
		cp "$BAK" /etc/config/wireless
		wifi reload >/dev/null 2>&1
		sleep 10
		log "已从备份恢复"
	fi
}

# ---------- 测量 ----------
measure() {
	local tag="$1"
	sleep 12
	local link sig rate bssid fail
	link=$(iw dev $IFC link 2>/dev/null)
	if echo "$link" | grep -q "Not connected"; then
		log "  [$tag] ✗ 未连接"
		return 1
	fi
	sig=$(echo "$link" | grep -o 'signal:.*' | awk '{print $2}')
	rate=$(echo "$link" | grep 'rx bitrate' | awk '{print $3, $4}')
	bssid=$(echo "$link" | grep -o 'Connected to [0-9a-f:]*' | awk '{print $3}')
	fail=$(iw dev $IFC station dump 2>/dev/null | awk '/tx failed/{print $3}')
	log "  [$tag] ✓ $bssid  signal $sig dBm  rate $rate  tx_failed ${fail:-0}"
	return 0
}

# ---------- 实验 ----------
run_baseline() {
	hr; log "基线（当前配置，不做任何修改）"
	log "  distance   : $(uci -q get wireless.$STA.distance || echo '<未设>')"
	log "  htmode     : $(uci -q get wireless.$STA.htmode)"
	log "  cell_density: $(uci -q get wireless.$STA.cell_density || echo '<未设>')"
	log "  channel    : $(uci -q get wireless.$STA.channel)"
	log "  country    : $(uci -q get wireless.$STA.country)"
	measure baseline
}

run_distance() {
	hr; log "实验 1：distance 参数（ACK timeout）"
	local orig; orig=$(uci -q get wireless.$STA.distance || echo "")
	for d in 100 300 1000 3000; do
		uci set wireless.$STA.distance="$d"
		uci commit wireless
		wifi reload >/dev/null 2>&1
		measure "distance=$d"
	done
	# 恢复
	if [ -n "$orig" ]; then
		uci set wireless.$STA.distance="$orig"
	else
		uci -q delete wireless.$STA.distance
	fi
	uci commit wireless; wifi reload >/dev/null 2>&1
}

run_width() {
	hr; log "实验 2：带宽变体（能否用窄带宽连宽带宽 AP）"
	local orig; orig=$(uci -q get wireless.$STA.htmode)
	for m in HE80 VHT80 VHT40 HT40 HT20; do
		uci set wireless.$STA.htmode="$m"
		uci commit wireless
		wifi reload >/dev/null 2>&1
		measure "htmode=$m"
	done
	uci set wireless.$STA.htmode="$orig"
	uci commit wireless; wifi reload >/dev/null 2>&1
}

run_cell() {
	hr; log "实验 3：cell_density（CCA 阈值）"
	local orig; orig=$(uci -q get wireless.$STA.cell_density || echo "")
	for c in 0 1 2 3; do
		uci set wireless.$STA.cell_density="$c"
		uci commit wireless
		wifi reload >/dev/null 2>&1
		measure "cell_density=$c"
	done
	if [ -n "$orig" ]; then
		uci set wireless.$STA.cell_density="$orig"
	else
		uci -q delete wireless.$STA.cell_density
	fi
	uci commit wireless; wifi reload >/dev/null 2>&1
}

run_scan() {
	hr; log "当前所有 5G AP（按信号排序）"
	iw dev $IFC scan 2>/dev/null \
		| awk '/^BSS/{b=$2} /signal:/{s=$2} /SSID:/{if(s!=""){n=$0; sub(/.*SSID: */,"",n); print s, b, n; s=""}}' \
		| sort -rn | head -20 | sed 's/^/  /'
}

# ---------- 主 ----------
do_backup
trap 'do_restore' INT TERM

case "${1:-all}" in
baseline) run_baseline; run_scan ;;
distance) run_distance ;;
width)    run_width ;;
cell)     run_cell ;;
all)      run_baseline; run_scan; run_distance; run_width; run_cell ;;
restore)  do_restore; exit 0 ;;
*)        log "用法: $0 [baseline|distance|width|cell|all|restore]"; exit 1 ;;
esac

hr
log "实验完成。恢复配置：sh $0 restore"

