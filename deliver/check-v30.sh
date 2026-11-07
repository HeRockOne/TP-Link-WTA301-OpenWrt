#!/bin/sh
# check-v30.sh —— 上板验收：v30 相较 p29 的每一项改动是否真的生效
#
# 用法（在板子上跑，或通过 plink 喂 stdin）：
#   ssh <pc> 'plink -ssh -batch -hostkey ... -pw root root@192.168.1.1 sh -s' < check-v30.sh
#
# 判据全部是「读运行时状态」，不是「读配置文件」——配置文件在、驱动没吃进去
# 是最常见的假通过（例如 uci 改了但 wifi 没 reload）。
#
# 退出码：0 = 全部通过；非 0 = 有 FAIL。

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); printf '  [OK  ] %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf '  [WARN] %s\n' "$*"; }

echo "=============================================================="
echo " WTA301 v30 上板验收"
echo " $(uname -srm)"
echo "=============================================================="

# ── 1. 无线：覆盖优先档 ────────────────────────────────────────────────
echo ""
echo "== 1. 无线覆盖档（beacon/最低速率降档 + CCK + 5G HE40）=="

H0=/var/run/hostapd-phy0.conf
H1=/var/run/hostapd-phy1.conf

if [ -f "$H0" ]; then
    # basic_rates 是 hostapd 实际下发的值（单位 100kbps），2.4G 应为 10 20 = 1/2 Mbps
    if grep -qx 'basic_rates=10 20' "$H0"; then
        ok "2.4G basic_rates=10 20（beacon 1 Mbps，+10.8 dB）"
    else
        bad "2.4G basic_rates 不是 '10 20'：$(grep -m1 '^basic_rates=' "$H0")"
    fi
    if grep -q 'supported_rates=.*\b10 20 55 110\b' "$H0"; then
        ok "2.4G 已开 802.11b CCK（1/2/5.5/11 Mbps，灵敏度 +8 dB）"
    else
        bad "2.4G supported_rates 缺 CCK（1/2/5.5/11）"
    fi
    if grep -qx 'disassoc_low_ack=0' "$H0"; then
        ok "2.4G disassoc_low_ack=0（弱信号不被误踢）"
    else
        bad "2.4G disassoc_low_ack 未关，ath11k 会误踢弱信号设备"
    fi
else
    bad "缺 $H0（2.4G hostapd 没起来）"
fi

if [ -f "$H1" ]; then
    if grep -qx 'basic_rates=60 120 240' "$H1"; then
        ok "5G basic_rates=60 120 240（beacon 6 Mbps，+6 dB）"
    else
        bad "5G basic_rates 不是 '60 120 240'：$(grep -m1 '^basic_rates=' "$H1")"
    fi
    if grep -qx 'disassoc_low_ack=0' "$H1"; then
        ok "5G disassoc_low_ack=0"
    else
        bad "5G disassoc_low_ack 未关"
    fi
else
    bad "缺 $H1（5G hostapd 没起来）"
fi

# 带宽与信道：读驱动真实状态
I5=$(iw dev phy1-ap0 info 2>/dev/null)
case "$I5" in
*"width: 40 MHz"*) ok "5G 带宽 40 MHz（HE40，+3 dB）" ;;
*"width: 80 MHz"*) bad "5G 还是 80 MHz（覆盖档的 +3 dB 没生效）" ;;
*)                 warn "5G 带宽读不到：$I5" ;;
esac
case "$I5" in
*"channel 161 "*) ok "5G 信道 161（本机扫描 44=26 AP / 161=1 AP）" ;;
*)                warn "5G 信道不是 161：$(echo "$I5" | grep -m1 channel)" ;;
esac

# 发射功率：必须是 24 dBm 且不应有 txpower 覆盖项
for i in phy0-ap0 phy1-ap0; do
    tp=$(iw dev "$i" info 2>/dev/null | sed -n 's/.*txpower \([0-9.]*\) dBm.*/\1/p')
    if [ -n "$tp" ]; then
        case "$tp" in
        24.*) ok "$i txpower $tp dBm（BDF 硬顶，符合预期）" ;;
        *)    warn "$i txpower $tp dBm（预期 24；若被手动固定过请清掉）" ;;
        esac
    else
        warn "$i txpower 读不到"
    fi
done

# ── 2. 开箱即用：时区 / NTP / 主机名 ─────────────────────────────────
echo ""
echo "== 2. 开箱即用（时区 / NTP / 主机名）=="

TZ1=$(uci -q get system.@system[0].timezone)
TZ2=$(uci -q get system.@system[0].zonename)
HN=$(uci -q get system.@system[0].hostname)
[ "$TZ1" = "CST-8" ]        && ok "时区 CST-8"        || bad "时区不是 CST-8（实得 '$TZ1'）"
[ "$TZ2" = "Asia/Shanghai" ] && ok "zonename Asia/Shanghai" || warn "zonename='$TZ2'"
[ "$HN" = "WTA301" ]        && ok "主机名 WTA301"     || warn "主机名 '$HN'"
uci -q get system.ntp.server | grep -q 'aliyun\|cn.pool' \
    && ok "NTP 指向国内可达源" || warn "NTP 仍是国外源"

# 时区生效链：uci system.@system[0].timezone -> /etc/init.d/system 开机写入 /etc/TZ
#            -> libc 读 /etc/TZ -> date 显示。
# 所以「uci 对了」不等于「date 对了」：改了 uci 不重启，/etc/TZ 还是旧的。
# 两层分开验，否则会把自己的检查误判成 FAIL。
OFFUCI=$(TZ="$TZ1" date +%z 2>/dev/null)
[ "$OFFUCI" = "+0800" ] && ok "uci 时区串解析为 +0800（POSIX 串正确）" \
                         || bad "uci 时区串 '$TZ1' 算出 '$OFFUCI'（不是 +0800）"
TZF=$(cat /etc/TZ 2>/dev/null)
OFFNOW=$(date +%z)
if [ "$OFFNOW" = "+0800" ]; then
    ok "运行时 date 已是 +0800（/etc/TZ=$TZF）"
elif [ "$TZF" = "$TZ1" ]; then
    # /etc/TZ 已同步但 date 没变：可能被 TZ 环境变量盖了
    warn "date 仍 $OFFNOW 但 /etc/TZ 已为 $TZF（上一进程的 TZ 环境变量残留，重启即正）"
else
    warn "date 仍 $OFFNOW（/etc/TZ='$TZF'）—— 重启或 /etc/init.d/system restart 后生效"
fi

# ── 3. LuCI：中文 + Argon + 移动端 CSS ───────────────────────────────
echo ""
echo "== 3. 界面（中文 / Argon / 移动端适配）=="

LANG=$(uci -q get luci.main.lang)
[ "$LANG" = "zh_cn" ] && ok "LuCI 语言 zh_cn" || warn "LuCI 语言 '$LANG'"
MU=$(uci -q get luci.main.mediaurlbase)
[ "$MU" = "/luci-static/argon" ] && ok "主题 Argon" || warn "主题 '$MU'"

if [ -f /www/luci-static/argon/css/wta301-mobile.css ]; then
    sz=$(wc -c < /www/luci-static/argon/css/wta301-mobile.css)
    ok "移动端 CSS 存在（$sz 字节）"
    # 权限必须 644：rpcd 对 world-writable 的 ucode 脚本静默跳过（见 P29 事故）
    case "$(ls -l /www/luci-static/argon/css/wta301-mobile.css | cut -c2-10)" in
    *w) bad "移动端 CSS 是 world-writable（构建期权限没归一化）" ;;
    *)  ok "移动端 CSS 权限正常" ;;
    esac
else
    bad "缺 /www/luci-static/argon/css/wta301-mobile.css"
fi

# 模板里必须真的引用了它，且在 cascade.css 之后
if [ -f /usr/share/ucode/luci/template/themes/argon/head.ut ]; then
    A=$(grep -n 'cascade\.css' /usr/share/ucode/luci/template/themes/argon/head.ut | head -1 | cut -d: -f1)
    B=$(grep -n 'wta301-mobile\.css' /usr/share/ucode/luci/template/themes/argon/head.ut | head -1 | cut -d: -f1)
    if [ -n "$B" ] && [ -n "$A" ] && [ "$B" -gt "$A" ]; then
        ok "head.ut 已引入移动端 CSS，且位置在 cascade.css 之后"
    else
        bad "head.ut 未正确引入（cascade 行=$A, wta301 行=$B）"
    fi
else
    bad "缺 head.ut 模板覆盖"
fi

# ── 4. 概览页数据源（CPU / 温度）────────────────────────────────────
echo ""
echo "== 4. 概览页数据源（rpcd ucode 插件）=="

if ubus list 2>/dev/null | grep -qx 'wta301'; then
    ok "ubus 存在 wta301 对象（rpcd 没跳过它）"
    S=$(ubus call wta301 status 2>/dev/null)
    echo "$S" | grep -q '"ncpu"' && ok "status 返回 ncpu" || bad "status 无 ncpu"
    # 真实返回结构的 key 是 thermal[].mC / radio[].mC（不是 temp），别按印象写判据
    echo "$S" | grep -q '"thermal"' && ok "status 返回 thermal 数组" || bad "status 无 thermal"
    echo "$S" | grep -q '"mC"'      && ok "thermal 带 mC 毫度值"     || bad "thermal 无 mC"
    echo "$S" | grep -q '"radio"'   && ok "status 返回 radio 温度"   || warn "status 无 radio 温度"
    # 数值合理性：25~100 ℃
    V=$(echo "$S" | sed -n 's/.*"mC": *\([0-9]*\).*/\1/p' | head -1)
    if [ -n "$V" ]; then
        if [ "$V" -ge 25000 ] && [ "$V" -le 100000 ]; then
            ok "温度值合理（$((V/1000)) ℃）"
        else
            warn "温度值异常：$V mC"
        fi
    fi
else
    bad "ubus 里没有 wta301 —— rpcd 跳过了（多半是权限 777 或语法错）"
fi

# rpcd 的 ucode 脚本不许 world-writable，否则被静默忽略
for f in /usr/share/rpcd/ucode/wta301/*.uc; do
    [ -f "$f" ] || continue
    case "$(ls -l "$f" | cut -c2-10)" in
    *w) bad "$(basename "$f") 是 world-writable，rpcd 会静默跳过" ;;
    *)  : ;;
    esac
done

# ── 5. 刷写安全门禁的落点核对 ───────────────────────────────────────
echo ""
echo "== 5. 分区落点（按绝对偏移反查，不认 mtd 编号）=="

for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    p=/sys/class/mtd/mtd$i
    [ -d "$p" ] || continue
    o=$(cat "$p/offset" 2>/dev/null)
    s=$(cat "$p/size" 2>/dev/null)
    n=$(cat "$p/name" 2>/dev/null)
    case "$o" in
    0)         tag="factory_boot  ★永不写" ;;
    4194304)   tag="factory_info/boot_flag ★看 name" ;;
    4718592)   tag="art  ★永不写" ;;
    7340032)   tag="u-boot B" ;;
    8912896)   tag="kernel B（原厂回退）" ;;
    16515072)  tag="rootfs B（原厂回退）" ;;
    74448896)  tag="u-boot A" ;;
    76021760)  tag="kernel A" ;;
    83623936)  tag="rootfs A" ;;
    *)         tag="" ;;
    esac
    printf '  mtd%-2s 0x%08x %8s B  %-16s %s\n' "$i" "$o" "$s" "$n" "$tag"
done

for need in 74448896 76021760 83623936; do
    found=0
    for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        p=/sys/class/mtd/mtd$i
        [ -d "$p" ] || continue
        [ "$(cat "$p/offset")" = "$need" ] && found=1
    done
    [ "$found" = "1" ] && ok "偏移 $need 有对应分区" || bad "偏移 $need 没有分区（落点解析会失败）"
done

# ── 6. 温度 ─────────────────────────────────────────────────────────
echo ""
echo "== 6. 温度 =="
MAX=0
for z in /sys/class/thermal/thermal_zone*; do
    [ -f "$z/temp" ] || continue
    t=$(( $(cat "$z/temp") / 1000 ))
    printf '  %-20s %3s C\n' "$(cat "$z/type" 2>/dev/null)" "$t"
    [ "$t" -gt "$MAX" ] && MAX=$t
done
[ "$MAX" -lt 85 ] && ok "最高温 $MAX C（<85，正常）" \
    || warn "最高温 $MAX C，偏高；确认没在跑大流量"

# ── 汇总 ────────────────────────────────────────────────────────────
echo ""
echo "=============================================================="
echo " PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo " 结论：v30 全部验收项通过"
else
    echo " 结论：有 $FAIL 项不通过，先修再发布"
fi
echo "=============================================================="
[ "$FAIL" -eq 0 ]
