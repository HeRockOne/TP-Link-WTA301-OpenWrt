#!/bin/sh
#
# verify-p26.sh —— 刷完 P26 固件后的验收判据（A1~A6）
#
# 用法（在板子上）：
#     ssh root@192.168.1.1 'sh -s' < deliverables/verify-p26.sh
#   WSL 中转（本机没有 192.168.1.x 网口时）：
#     ssh -i ~/.ssh/wta301 null@192.168.112.222 \
#       "plink.exe -ssh -batch -pw root root@192.168.1.1 sh -s" < verify-p26.sh
#
# 判据来源：wta301-2512/docs/P26-PERF-TUNING.md §5
# 每一行只输出 OK / FAIL / SKIP，末尾汇总个数；有任何 FAIL ⇒ 退出码 1。

OK=0; FAIL=0; SKIP=0
ok()   { OK=$((OK+1));   echo "  [OK]   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
skip() { SKIP=$((SKIP+1)); echo "  [SKIP] $*"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: 期望 $2 实得 $3"; fi; }

echo "===== P26 验收 ($(date '+%F %T')) ====="
echo "固件: $(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_ID $DISTRIB_RELEASE $DISTRIB_REVISION")"
echo ""

# ── A1 packet steering ────────────────────────────────────────────────
echo "A1. packet steering（上游脚本，两核必须都参与）"
chk "packet_steering"      "2"    "$(uci -q get network.globals.packet_steering)"
chk "steering_flows"       "4096" "$(uci -q get network.globals.steering_flows)"
chk "packet_steering 已启用" "S25packet_steering" "$(ls /etc/rc.d/ 2>/dev/null | grep packet_steering | sed 's/^/S25/;s/S25S25/S25/')"
for i in phy0-ap0 phy1-ap0 eth0; do
	_v=$(cat /sys/class/net/$i/queues/rx-0/rps_cpus 2>/dev/null)
	chk "$i rps_cpus" "3" "$_v"
done
# br-lan 有 lower_* 属性，上游脚本会跳过，rps 保持 0 —— 这是正常的
_b=$(cat /sys/class/net/br-lan/queues/rx-0/rps_cpus 2>/dev/null)
[ "$_b" = "0" ] && ok "br-lan rps_cpus=0（上游有意跳过主设备，正常）" \
                 || skip "br-lan rps_cpus=$_b（非预期但无害）"
echo ""

# ── A2 eth0 IRQ 在 CPU1 ──────────────────────────────────────────────
echo "A2. eth0 中断挪到 CPU1（本板最大的单核瓶颈）"
_irq=$(awk '/eth0$/ { sub(":", "", $1); print $1; exit }' /proc/interrupts 2>/dev/null)
if [ -n "$_irq" ]; then
	_eff=$(cat /proc/irq/$_irq/effective_affinity_list 2>/dev/null)
	chk "eth0 irq$_irq effective_affinity" "1" "$_eff"
	# 中断计数：CPU0 那列应远小于 CPU1 那列（刚开机可能都少，允许零）
	_cnt0=$(awk -v n="$_irq" '$1==n":" {print $2; exit}' /proc/interrupts)
	_cnt1=$(awk -v n="$_irq" '$1==n":" {print $3; exit}' /proc/interrupts)
	echo "       计数 CPU0=$_cnt0 CPU1=$_cnt1（CPU1 应随流量增长）"
else
	bad "找不到 eth0 的 IRQ 行"
fi
echo ""

# ── A3 netdev_budget ─────────────────────────────────────────────────
echo "A3. NAPI 预算（CPU0 曾在 300 时欠债 10168 次）"
chk "netdev_budget"           "1000" "$(cat /proc/sys/net/core/netdev_budget)"
chk "rps_sock_flow_entries"   "4096" "$(cat /proc/sys/net/core/rps_sock_flow_entries)"
echo "       softnet_stat（第3列=一轮poll没取完的次数）:"
awk '{ printf "       CPU%d dropped=%s time_squeeze=%s\n", NR-1, $2, $3 }' /proc/net/softnet_stat 2>/dev/null
echo ""

# ── A4 服务在跑 ──────────────────────────────────────────────────────
echo "A4. net-tune 服务（IRQ 看护，5 秒自检 + procd respawn）"
if pgrep -f "/usr/sbin/net-tune" >/dev/null 2>&1; then
	ok "net-tune 进程存活 pid=$(pgrep -f /usr/sbin/net-tune | head -1)"
else
	bad "net-tune 进程不在（查 logread -e net-tune）"
fi
_l=$(logread -e net-tune 2>/dev/null | tail -3)
[ -n "$_l" ] && echo "$_l" | sed 's/^/       /' || echo "       (无 net-tune 日志：开机时若已经是 CPU1 就不会打印，属正常)"
echo ""

# ── A5 无线 ──────────────────────────────────────────────────────────
echo "A5. 无线出厂值（开箱即用，不需要人 shell）"
chk "5G channel"   "161"  "$(uci -q get wireless.radio1.channel)"
chk "5G htmode"    "HE80" "$(uci -q get wireless.radio1.htmode)"
chk "5G country"   "CN"   "$(uci -q get wireless.radio1.country)"
chk "2.4G channel" "11"   "$(uci -q get wireless.radio0.channel)"
chk "2.4G htmode"  "HT20" "$(uci -q get wireless.radio0.htmode)"
_n=$(uci -q get wireless.radio0.noscan)
if [ -z "$_n" ]; then ok "2.4G noscan 未设置（稳妥档，符合决策）"; else bad "2.4G noscan=$_n（应为空）"; fi
# 实际生效值（不是 uci 声明值）
_w0=$(iw dev phy0-ap0 info 2>/dev/null | grep -c "channel 11 .*width: 20 MHz")
[ "$_w0" = "1" ] && ok "2.4G 实际 20 MHz @ ch11" || bad "2.4G 实际不是 ch11/20MHz"
_w1=$(iw dev phy1-ap0 info 2>/dev/null | grep -c "channel 161 .*width: 80 MHz")
[ "$_w1" = "1" ] && ok "5G 实际 80 MHz @ ch161" || bad "5G 实际不是 ch161/80MHz"
echo ""

# ── A6 无残留 ────────────────────────────────────────────────────────
echo "A6. 旧自建脚本必须全部消失（它和上游 packet_steering 互相覆盖）"
for f in /usr/sbin/rps-watch /etc/init.d/rps /etc/rc.d/S99rps /etc/sysctl.d/99-wta301-rps.conf; do
	[ -e "$f" ] && bad "残留 $f" || ok "已清除 $f"
done
pgrep -f rps-watch >/dev/null 2>&1 && bad "rps-watch 进程仍在" || ok "无 rps-watch 进程"
echo ""

echo "===== 汇总: OK=$OK FAIL=$FAIL SKIP=$SKIP ====="
[ "$FAIL" -eq 0 ] || exit 1
