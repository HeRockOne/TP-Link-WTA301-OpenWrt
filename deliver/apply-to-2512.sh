#!/bin/bash
# 把 P1 核对出来的交付物装进 OpenWrt 25.12.6 树。
# 幂等：重复运行不会重复追加（用标记 + grep 保护）。
#
# 用法：
#   bash deliver/apply-to-2512.sh                        # 默认树 /root/ow2512
#   OWTREE=/path/to/openwrt bash deliver/apply-to-2512.sh  # 指定别的树
#
# ★ 本脚本会碰 target/linux/qualcommax/{patches-6.12,files}，
#   使它们的 mtime 变化 ⇒ 下次 make 会**全量重编内核（约 45 分钟）**。
#   只改用户态时用 apply-rootfs-only.sh。
set -e
_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/lib-paths.sh"

T=$OWTREE/target/linux/qualcommax
CFG=$OWTREE/.config

# ---------------------------------------------------------------
# P17 修正（重要，勿删）：
#   `$T/ipq50xx/config-default` 是**内核**配置片段，只认内核符号。
#   把 CONFIG_PACKAGE_* / CONFIG_FEED_* / CONFIG_LUCI_LANG_* 写进去是空转：
#   实测内核 .config（build_dir/.../linux-6.12.112/.config）里
#   `grep -c CONFIG_PACKAGE_` = **0**，这些行被内核 Kconfig 当未知符号丢弃。
#   P16 之所以真出中文包，是因为那一轮另外直接改了顶层 $OWTREE/.config。
#   ⇒ 软件包/feed/语言开关一律走 add_pkg_sym()（写顶层 .config）；
#     内核符号（INPUT*/KEYBOARD_GPIO/PCS_QCA_UNIPHY…）才写 config-default。
# ---------------------------------------------------------------
add_pkg_sym() {   # add_pkg_sym CONFIG_X=y [CONFIG_Y=y ...]  -> 顶层 .config
	for sym in "$@"; do
		name=${sym%%=*}
		if ! grep -q "^${name}=${sym#*=}$" "$CFG" 2>/dev/null; then
			sed -i "/^${name}=[ym]$/d;/^# ${name} is not set$/d" "$CFG"
			echo "$sym" >> "$CFG"
		fi
	done
}

del_pkg_sym() {   # 显式写 "# CONFIG_X is not set"（删行不会让旧 =y 回退，lesson g8tl61k）
	for name in "$@"; do
		sed -i "/^${name}=[ym]$/d;/^# ${name} is not set$/d" "$CFG"
		echo "# ${name} is not set" >> "$CFG"
	done
}

# 清掉历史遗留：早期版本把 CONFIG_PACKAGE_/FEED_/LUCI_LANG_ 污进了内核 config-default
purge_kernel_cfg_pollution() {
	local f=$T/ipq50xx/config-default
	[ -f "$f" ] || return 0
	local n
	n=$(grep -c '^CONFIG_PACKAGE_\|^# CONFIG_PACKAGE_\|^CONFIG_FEED_\|^# CONFIG_FEED_\|^CONFIG_LUCI_LANG_\|^# CONFIG_LUCI_LANG_' "$f" 2>/dev/null || true)
	if [ "${n:-0}" != "0" ]; then
		sed -i '/^CONFIG_PACKAGE_/d;/^# CONFIG_PACKAGE_/d;/^CONFIG_FEED_/d;/^# CONFIG_FEED_/d;/^CONFIG_LUCI_LANG_/d;/^# CONFIG_LUCI_LANG_/d' "$f"
		echo "  内核 config-default 清掉 $n 行包/feed 符号（它们在内核 Kconfig 里是空转）"
	fi
}

echo "== 0. 树自检 =="
[ -f $T/Makefile ] || { echo "不是 25.12.6 树: $T"; exit 1; }
grep -q 'KERNEL_PATCHVER:=6.12' $T/Makefile || { echo "内核不是 6.12"; exit 1; }

echo "== 1. 7 个内核补丁 → patches-6.12/092x =="
cp -f $SRC/patches/kernel-6.12/0740-01-*.patch $T/patches-6.12/0920-dt-bindings-net-ethernet-phy-increase-max-clock-count.patch
cp -f $SRC/patches/kernel-6.12/0740-03-*.patch $T/patches-6.12/0921-arm64-qcom-ipq5018-add-gephy-rx-and-tx-clocks.patch
cp -f $SRC/patches/kernel-6.12/0740-04-*.patch $T/patches-6.12/0922-net-phy-at803x-add-rx-tx-clock-management-for-ipq5018.patch
cp -f $SRC/patches/kernel-6.12/0842-*.patch     $T/patches-6.12/0923-arm64-dts-qcom-ipq5018-add-uniphy-node.patch
cp -f $SRC/patches/kernel-6.12/0843-*.patch     $T/patches-6.12/0924-net-stmmac-add-get_interfaces-platform-method.patch
cp -f $SRC/patches/kernel-6.12/0951-*.patch     $T/patches-6.12/0925-net-pcs-add-uniphy-pcs.patch
cp -f $SRC/patches/kernel-6.12/0954-*.patch     $T/patches-6.12/0926-net-stmmac-introduce-qualcomm-ipq5018-dwmac.patch
# 0927 已废弃：clk_hw_recalc_rate() 改为驱动内用 clk_get_rate() 等价实现（见 files/ 里的注释），
# 不再需要改 drivers/clk/clk.c。若残留旧文件会被内核打补丁失败，显式删掉。
rm -f $T/patches-6.12/0927-clk-add-clk-hw-recalc-rate.patch
ls -1 $T/patches-6.12/092*

echo "== 2. files/（驱动 + dt-binding + 板级 dts）=="
mkdir -p $T/files
cp -a $SRC/files/. $T/files/
find $T/files -name '*ipq5018*' -o -name 'pcs-qca-uniphy*' -o -name 'qca-uniphy.h' | sort

# --- R17: RTL8367S SerDes 驱动（搬自 S7 实测可用的 6.18.55 树）---
# files/ 只在「解压内核」时 overlay。若内核树已解压过，必须显式同步，
# 否则改的驱动不会进编译（build_dir 里还是旧文件）。
for kd in $OWTREE/build_dir/target-*/linux-*/linux-6.12.*; do
  [ -d "$kd/drivers/net/dsa/realtek" ] || continue
  echo "   同步到 $kd/drivers/net/dsa/realtek"
  cp -f $T/files/drivers/net/dsa/realtek/*.c  $kd/drivers/net/dsa/realtek/
  cp -f $T/files/drivers/net/dsa/realtek/*.h  $kd/drivers/net/dsa/realtek/
  cp -f $T/files/drivers/net/dsa/realtek/Makefile $kd/drivers/net/dsa/realtek/
  cp -f $T/files/drivers/net/dsa/realtek/Kconfig  $kd/drivers/net/dsa/realtek/
  # S7 是四文件拆分版（main/table/vlan/l2）；旧单文件留着不参与构建，但删掉更干净
  rm -f $kd/drivers/net/dsa/realtek/rtl8365mb.c
  rm -f $kd/drivers/net/dsa/realtek/*.o $kd/drivers/net/dsa/realtek/*.ko
done

echo "== 3. config-default 追加 5 行 =="
if ! grep -q 'CONFIG_DWMAC_IPQ5018' $T/ipq50xx/config-default; then
cat >> $T/ipq50xx/config-default <<'EOF'
# --- WTA301 (R14): mainline DWMAC + UNIPHY PCS ethernet stack ---
# 25.12.6 ships the QSDK ESS+NSS-DP switch stack for ipq50xx and no stmmac at
# all; this board drives an RTL8367S over SGMII from gmac1 instead.
# DWMAC_GENERIC must stay off or it grabs the "snps,dwmac" compatible first.
# CONFIG_DWMAC_GENERIC is not set
# DWMAC_QCOM_ETHQOS is a NEW symbol once STMMAC_ETH is on (ipq806x/ETHQOS, not us);
# leaving it unset in a non-interactive build makes syncconfig prompt and abort.
# CONFIG_DWMAC_QCOM_ETHQOS is not set
CONFIG_DWMAC_IPQ5018=y
# PCS_QCA_UNIPHY MUST be ON.  This is the wired-ethernet fix, verified on the
# real board (wta301-2512/docs/P7-WIRED-FIX-VERIFIED.md, 9/9 criteria).
#
# Root cause of "lan ports dead", proven by a zero-flash A/B boot where the only
# variable was this symbol:
#   =n -> ping 192.168.1.100 100% loss, eth0 rx=0, lan1 tx=0,
#         gcc_uniphy_{ahb,rx,tx,sys}_clk enable_cnt=0 is_enabled=N
#   =y -> ping 0% loss, eth0 rx=29803 rising, lan1 tx=8495 rising,
#         gcc_uniphy_*_clk enable_cnt=1..2 is_enabled=Y,
#         consumer = ethernet-pcs@98000
# With =n nothing claims qualcomm,ipq5018-uniphy, so clk_disable_unused()
# ("clk: Disabling unused clocks" in dmesg) gates off the four uniphy clocks;
# the SerDes then has no 125 MHz reference and the SGMII link to the RTL8367S
# never works - the switch side is fine (lan1 rx sees frames) but the CPU port
# can neither receive nor transmit.
#
# Upstream design, not a local hack: drivers/net/pcs/pcs-qca-uniphy.c comes from
# OpenWrt PR #22381 ("qualcommax: networking rework"), which lists ipq50xx as
# tested and records "UNIPHY clk doesn't scale correctly on speed/mode change -
# Fixed"; the PCS driver is the component supposed to hold those clocks.
#
# Judge criterion warning: gmac1_tx_clk_src still reads 0 Hz even when the link
# is up at 1 Gbps (recursive clk rate artefact).  Use gcc_uniphy_*_clk
# enable_cnt/is_enabled and eth0 rx instead.
#
# The 6.12 copy of pcs-qca-uniphy.c does not compile as shipped (it calls
# clk_hw_recalc_rate(), a v6.18 helper, and returns a pointer from an int
# function); files/drivers/net/pcs/pcs-qca-uniphy.c carries the minimal 6.12
# fix (clk_hw_get_rate() + devm_fwnode_pcs_add_provider()/IS_ERR()).
CONFIG_PCS_QCA_UNIPHY=y

CONFIG_STMMAC_ETH=y
CONFIG_STMMAC_PLATFORM=y

# --- 物理按键（reset = KEY_RESTART, wps = KEY_WPS_BUTTON）---
# 25.12.6 的 qualcommax/ipq50xx config-default 把 CONFIG_INPUT 关掉了，
# 于是 dts 里的 `keys { compatible = "gpio-keys"; }` 根本不会被注册：
#   dmesg 无 gpio-keys、/proc/bus/input/devices 不存在
#   ⇒ /etc/rc.button/{reset,wps} 虽然存在，但永远不会被触发
#   ⇒ 长按 reset 恢复出厂这条「免串口救援路径」是断的（家用必须有）
# 三方比对：S7 的 6.18.55 .config 是 INPUT=m / INPUT_EVDEV=m / KEYBOARD_GPIO=m，
# 也就是说这是我们的配置缺失，不是 6.12 的限制。
# 这里用 =y 直接内建，避免再多一个 kmod 包与模块加载时序问题。
CONFIG_INPUT=y
CONFIG_INPUT_EVDEV=y
CONFIG_KEYBOARD_GPIO=y
CONFIG_INPUT_MISC=y
EOF
fi
tail -12 $T/ipq50xx/config-default

# 幂等强制：树里可能还留着 R18 时期的 "is not set"
sed -i 's|^# CONFIG_PCS_QCA_UNIPHY is not set$|CONFIG_PCS_QCA_UNIPHY=y|' $T/ipq50xx/config-default
grep -q '^CONFIG_PCS_QCA_UNIPHY=y$' $T/ipq50xx/config-default || echo 'CONFIG_PCS_QCA_UNIPHY=y' >> $T/ipq50xx/config-default
echo "PCS_QCA_UNIPHY => $(grep -n 'PCS_QCA_UNIPHY' $T/ipq50xx/config-default)"

# 幂等强制：物理按键（reset/wps）。
# 上面那个大块有 `if ! grep -q 'CONFIG_DWMAC_IPQ5018'` 护卫，树里已经有该 symbol
# 时整块都不会执行，所以新增 symbol 必须自己单独幂等追加。
# ⚠️ 这一段曾经的理由是错的，2026-11-05 上板实测后已推翻（见 docs/M05-KEYS-THREE-WAY.md
#    文首「第二次修正」）。正确事实：
#    1) 25.12.6 的 qualcommax/ipq50xx config-default 确实把 CONFIG_INPUT 关掉了，
#       但**按键在 P16 上本来就是好的** —— 因为 OpenWrt 不走 input 子系统。
#    2) OpenWrt 的按键桥是 package/kernel/gpio-button-hotplug（树外模块）：
#       它匹配 of_device_id { .compatible = "gpio-keys" }，把 GPIO 按键变成 **uevent**，
#       由 procd 的 HANDLER_BUTTON（plug/hotplug.c + files/hotplug.json:70-73
#       `[ "button", "/etc/rc.button/%BUTTON%" ]`）分发到 /etc/rc.button/<name>。
#       该包由 target/linux/qualcommax/Makefile:16 的 DEFAULT_PACKAGES 默认带上。
#    3) P16 板上实证：lsmod 有 gpio_button_hotplug，
#       ls /sys/bus/platform/drivers/gpio-keys/ 有 keys 设备（已 bind），
#       人手按 reset/wps 双双产生 rc.button 事件。
#    4) ⚠️ 开 CONFIG_KEYBOARD_GPIO=y 反而会**弄坏**按键：内建 gpio_keys 同样匹配
#       "gpio-keys"，开机先注册就抢走设备，gpio_button_hotplug 再也绑不上；
#       而 input 事件在 OpenWrt 用户态没有任何消费者
#       （全树 `grep -r '/dev/input' package/` 只命中 busybox 的 Kconfig 文字）。
#    ⇒ 默认必须是 WITH_KEYS=0。WITH_KEYS=1 只留给「将来真要 input 子系统
#      （例如接 USB 键盘）」的场景，**不是按键的开关**。
#    原厂的按键是另一套机制（私有 slp_gpio.ko + /dev/slp_gpio_chrdev + dms），与此无关。
#
#    仍然必须写 `# CONFIG_X is not set` 的坑（lesson g8tl61k）：
#    merge_config 只"写入"，删行不会让旧 .config 里的 =y 回退，实测去掉 4 行后
#    内核 .config 仍是 =y（P15 第一轮 kernel 4131c6d0 → bb0c8667，白长 65536 B）。
if [ "${WITH_KEYS:-0}" = 1 ]; then
	for sym in CONFIG_INPUT=y CONFIG_INPUT_EVDEV=y CONFIG_INPUT_KEYBOARD=y \
	           CONFIG_KEYBOARD_GPIO=y CONFIG_INPUT_MISC=y; do
		name=${sym%%=*}
		if ! grep -q "^${name}=y$" $T/ipq50xx/config-default; then
			sed -i "/^# ${name} is not set$/d" $T/ipq50xx/config-default
			echo "$sym" >> $T/ipq50xx/config-default
		fi
	done
else
	# 显式关掉：merge_config 只"写入"，不会因为 symbol 缺失就回退，
	# 旧 .config 里的 =y 会一直保留（本轮已踩：去掉 4 行后 .config 仍是 =y）。
	# 必须写 "# CONFIG_X is not set" 才能让它真的变回 n。
	for name in CONFIG_INPUT CONFIG_INPUT_EVDEV CONFIG_INPUT_KEYBOARD \
	            CONFIG_KEYBOARD_GPIO CONFIG_INPUT_MISC; do
		sed -i "/^${name}=[ym]$/d;/^# ${name} is not set$/d" $T/ipq50xx/config-default
		echo "# ${name} is not set" >> $T/ipq50xx/config-default
	done
fi
echo "KEY/INPUT => $(grep -cE '^CONFIG_(INPUT|INPUT_EVDEV|INPUT_KEYBOARD|KEYBOARD_GPIO|INPUT_MISC)=[ym]$' $T/ipq50xx/config-default) (WITH_KEYS=${WITH_KEYS:-0})"

# 幂等强制：软件包 feed + 中文界面 + 家用 QoS（见 docs/P12-PACKAGE-FEED-STATUS.md）。
# 缺口 A：25.12.6 的 include/feeds.mk:49-59 FeedSourcesAppendAPK 里
#   luci/packages/routing/telephony 这几行要 CONFIG_FEED_<name>=y 才写，
#   而 qualcommax/ipq50xx config-default 全是 `is not set`，
#   导致板上 /etc/apk/repositories.d/distfeeds.list 只有 2 行，
#   `apk add luci-app-*` 连包名都搜不到。
# 缺口 B：kmod-* 永远不可能从官方 feed 装（vermagic 由内核 .config hash 得出，
#   官方 6.12.112-1-175dffd3… vs 我们 6.12.112~e98ab909…），所以
#   家用 QoS 这类依赖内核模块的功能必须直接编进固件，不能指望 feed。
#   rootfs 预算：mtd6 分区 12MiB（0xC00000），实测 squashfs 本体 8,722,096B=8.32MiB
#   ⇒ 可增长上限 0xC00000-8722096 = 3,758,896B = **3.58MiB**（超过就装不进分区）。
#   本块 5 个 zh-cn 的源 po 合计 782,272B，编译后 lmo 约 1/3 ⇒ ~250KiB，安全。
#   overlay 另有 27.8MiB 可写（/dev/ubi0_0，ubinfo 印证），但只读 rootfs 才是离线可用路径。
#
# CONFIG_PACKAGE_ 形式已验证有效：tmp/.config-package.in 里选项是 **TAB 缩进**的
#   `\tconfig PACKAGE_luci-i18n-base-zh-cn`，用 `^config ` 锚定会误判 0 条（已踩）。
# 同理 `tc` 不是包名，真名 tc-tiny/tc-full/tc-bpf；且 sqm-scripts 已 select
#   tc-tiny / kmod-ifb / kmod-sched-cake / iptables-mod-ipopt / iptables-nft / ip-tiny，
#   这里显式写一遍只为自文档，选 tc-tiny 与 select 条件一致（不会拉 tc-full）。
#
# 中文界面：内置进固件而不是靠 feed 装，三个理由
#   1) feeds/luci 的 luci.mk:78 `LUCI_LC_ALIAS.zh_Hans=zh-cn` ⇒ 包名为 luci-i18n-<basename>-zh-cn
#   2) 板上 /etc/config/luci 已是 `option lang 'auto'` ⇒ 装了即按浏览器语言自动切中文
#   3) 内置版本与树内 luci-base 同源，不会像装官方 feed 那样跨版本（我们 26.288 vs feed 26.304）
#   4) 不用 `CONFIG_LUCI_LANG_zh_Hans=y` 一行开全：那会拉 100 个包约 4.6MiB，
#      而 rootfs 分区硬预算 3.58MiB（见上）。PACKAGE_luci-i18n-*-zh-cn 的 Kconfig 是
#      `default LUCI_LANG_zh_Hans||(ALL&&m)`，所以不设总开关时只能逐个点，正是我们要的。
#   实测我们的树里有 po/zh_Hans 且与本板已装 luci 模块对得上的共 5 个：
#   base / firewall / package-manager / dashboard / sqm
#   （luci-mod-{network,status,system,admin-full} 自 LuCI 21.02 起文案并入 luci-base）
#
# P17 修正：原先把 FEED / ZH-CN / SQM 三组混在一个循环里，任何一次跑本脚本都会
#   把 SQM(QoS) 一起带进固件。这违反 AGENTS §2「一次只改一个变量」：
#   Argon 主题 / 按键 / 语言锁定 都能在板上各自独立验证，SQM 却是改数据面，
#   需要单独跑吞吐验证。所以拆成 WITH_SQM 开关（默认 0），与 WITH_KEYS 同风格。
purge_kernel_cfg_pollution

add_pkg_sym CONFIG_FEED_packages=y CONFIG_FEED_luci=y CONFIG_FEED_routing=y \
            CONFIG_FEED_telephony=y CONFIG_FEED_video=y

# 中文总开关。P16 实测：写 CONFIG_PACKAGE_luci-i18n-*-zh-cn=y 会被 `make defconfig`
#   覆盖（Kconfig 的 `default LUCI_LANG_zh_Hans||(ALL&&m)` 重新求值）；
#   只写总开关时 Kconfig 会按「已启用的 luci 模块」自动选，P16 选中 3 个共 75KiB。
#   开 WITH_SQM 后会自动多选 luci-i18n-sqm-zh-cn。
add_pkg_sym CONFIG_LUCI_LANG_zh_Hans=y

if [ "${WITH_SQM:-0}" = 1 ]; then
	add_pkg_sym CONFIG_PACKAGE_kmod-ifb=y CONFIG_PACKAGE_kmod-sched-cake=y \
	            CONFIG_PACKAGE_sqm-scripts=y CONFIG_PACKAGE_luci-app-sqm=y \
	            CONFIG_PACKAGE_tc-tiny=y
else
	del_pkg_sym CONFIG_PACKAGE_kmod-ifb CONFIG_PACKAGE_kmod-sched-cake \
	            CONFIG_PACKAGE_sqm-scripts CONFIG_PACKAGE_luci-app-sqm \
	            CONFIG_PACKAGE_luci-i18n-sqm-zh-cn CONFIG_PACKAGE_tc-tiny \
	            CONFIG_PACKAGE_luci-i18n-dashboard-zh-cn
fi
echo "FEED   => $(grep -cE '^CONFIG_FEED_[a-z]+=y$' $CFG)/5  (顶层 .config)"
echo "ZH-CN  => $(grep -cE '^CONFIG_LUCI_LANG_zh_Hans=y$' $CFG)/1  (顶层 .config)"
echo "SQM    => $(grep -cE '^CONFIG_PACKAGE_(kmod-ifb|kmod-sched-cake|sqm-scripts|luci-app-sqm|tc-tiny)=y$' $CFG)/5 (WITH_SQM=${WITH_SQM:-0})"

echo "== 4. 去掉 kmod-qca-nss-dp（我们不用 NSS/EDMA，纯 CPU 转发）=="
if grep -q 'kmod-qca-nss-dp' $T/Makefile; then
	sed -i 's/kmod-qca-nss-dp //' $T/Makefile
fi
sed -n '13,20p' $T/Makefile

echo "== 5. image/ipq50xx.mk 追加 Device 块 =="
if ! grep -q 'Device/tplink_wta301' $T/image/ipq50xx.mk; then
	{ echo; cat $SRC/deliver/ipq50xx-device.mk; } >> $T/image/ipq50xx.mk
fi
grep -n -A3 'Device/tplink_wta301' $T/image/ipq50xx.mk | head -8

echo "== 6. base-files（MAC/caldata/LED 三合一，已在板上跑过）=="
mkdir -p $T/ipq50xx/base-files
cp -a $SRC/deliver/ipq50xx-base-files/. $T/ipq50xx/base-files/
ls -l $T/ipq50xx/base-files/etc/board.d/90_wta301 $T/ipq50xx/base-files/etc/hotplug.d/firmware/12-wta301-caldata

echo "== 7. board-2.bin（两个容器，S7 已实证；不从 ipq-wifi 取）=="
# 优先用仓库内的副本（patches/bdf/），仓库外那份只做兼容回退。
# BDF 是二进制 blob，不在上游任何 repo 里，必须随仓库走，否则 WiFi 起不来。
BDF=$SRC/patches/bdf
[ -f "$BDF/board2-wta301-ipq5018-2g.bin" ] || BDF=$SRC/../work/op-build/assets/bdf
mkdir -p $T/ipq50xx/base-files/lib/firmware/ath11k/IPQ5018/hw1.0 \
         $T/ipq50xx/base-files/lib/firmware/ath11k/QCN6122/hw1.0
cp -f "$BDF/board2-wta301-ipq5018-2g.bin"  $T/ipq50xx/base-files/lib/firmware/ath11k/IPQ5018/hw1.0/board-2.bin
cp -f "$BDF/board2-wta301-qcn6122-5g.bin"  $T/ipq50xx/base-files/lib/firmware/ath11k/QCN6122/hw1.0/board-2.bin
md5sum $T/ipq50xx/base-files/lib/firmware/ath11k/*/hw1.0/board-2.bin

echo "== 5b. fstools 补丁：mount_root done 也要认 fstools_overlay_name =="
# 致命缺陷（真机已实证）：我们的 overlay UBI 卷名叫 wta301data，
# fstools 的 start() 会读 /proc/cmdline 的 fstools_overlay_name 找到它，
# 但 done() 仍用字面量 volume_find("rootfs_data") -> NULL -> 提前 return，
# 于是 fs_state_set("/overlay", READY) 永不执行。后果：每次启动都走
# FS_STATE_UNKNOWN -> PENDING -> overlay_delete()，把整个 overlay 擦掉重做，
# 用户改的任何东西都不过重启（实测：写 /root/persist.txt + 改 hostname，
# 重启后全丢；dmesg 每次都有 "overlay filesystem has not been fully initialized yet"）。
# 不能改回卷名 rootfs_data：rootdisk.c:166 硬编码只认这个名字，会把 mtdsplit 的
# rootfs_data 分区抢到手。S7 的 fstools 没有这个 bug（其日志 0 条该消息）-> 这是回归。
# 详见 wta301-2512/docs/P11-OVERLAY-PERSISTENCE.md
mkdir -p $OWTREE/package/system/fstools/patches
cp -f $SRC/patches/fstools/0001-fstools-honor-fstools_overlay_name.patch \
      $OWTREE/package/system/fstools/patches/
rm -f $OWTREE/package/system/fstools/patches/0001-mount_root-done-honor-fstools_overlay_name.patch
ls -l $OWTREE/package/system/fstools/patches/

# 补丁变了要强制重编 fstools（OpenWrt 不会因为 patches/ 变动自动 clean）
# 判据：打完补丁后 volume_find(dataname) 在 mount_root.c 里 **2 次**
# （start() 一次 + done() 一次）、在 factoryreset.c 里 **1 次**。
# 不要用 'dataname = dataparam' 判，因为 start() 里本来就有。
N=$(grep -c 'volume_find(dataname)' $OWTREE/build_dir/target-*/fstools-*/mount_root.c 2>/dev/null | head -1)
M=$(grep -c 'volume_find(dataname)' $OWTREE/build_dir/target-*/fstools-*/factoryreset.c 2>/dev/null | head -1)
if [ "$N" != "2" ] || [ "$M" != "1" ]; then
	echo "fstools 源码尚未含补丁 (mount_root x$N / factoryreset x$M) -> clean 以便重新应用"
	( cd $OWTREE && make package/system/fstools/clean >/dev/null 2>&1 )
fi

echo "== 5c. mac80211/ath11k 补丁：把 DP ring 降到 256 MiB 档（对齐 S7 backports-7.2）=="
# 实测（P14/P15）：两个射频同时开时，ath11k 默认 ring 在 256 MiB 板上占掉
# 约 101 MiB 的 MemFree，而 meminfo 的任何计数器都看不到它（dev_alloc_skb
# 的 page-fragment cache + coherent ring）。表现：MemAvailable 只有 5~8 MiB，
# 靠 zram 兜着；`rmmod ath11k_ahb` 立刻回 108 MiB。
#
# 三轮证据：
#  1) 离线三方：S7 的 ath11k（backports-7.2）与我们的（backports-6.18.55）
#     逐文件 diff —— dp.h 只差这 5 个常量，hal.h/dp_rx.c/dp_tx.c/hal.c 全同；
#     S7 的值 8192/2048/512/128/128，我们的 32768/4096/1024/4096/2048。
#  2) 外部：OpenWrt issue #24154（MX4200，同为 IPQ5018+QCN6122 256 MiB）
#     同样症状「stop wifi 不回收、rmmod ath11k 从 22 MB 回到 291 MB」，
#     解法就是减半 RX/monitor ring；上游 ath-next 同名补丁正在推按 RAM 选档。
#  3) 字节：两射频合计预期省 ~33 MiB。
# 详见 wta301-2512/docs/P15-ATH11K-RINGS.md
mkdir -p $OWTREE/package/kernel/mac80211/patches/ath11k
cp -f $SRC/patches/mac80211/0950-wifi-ath11k-reduce-DP-ring-sizes-256M.patch       $OWTREE/package/kernel/mac80211/patches/ath11k/
ls -l $OWTREE/package/kernel/mac80211/patches/ath11k/0950-*.patch

# OpenWrt 不会因为 patches/ 变动自动重编 mac80211；判据看解包源里的常量。
DPH=$(ls -d $OWTREE/build_dir/target-*/linux-qualcommax_ipq50xx/mac80211-regular/backports-*/drivers/net/wireless/ath/ath11k/dp.h 2>/dev/null | head -1)
if [ -n "$DPH" ]; then
	V=$(awk '/^#define DP_TX_COMP_RING_SIZE/{print $3}' "$DPH")
	echo "  解包源 DP_TX_COMP_RING_SIZE=$V ($DPH)"
	if [ "$V" != "8192" ]; then
		echo "  未含补丁 -> clean mac80211 以便重新应用"
		( cd $OWTREE && make package/kernel/mac80211/clean >/dev/null 2>&1 )
	fi
else
	echo "  解包源尚未存在（首次构建）-> 无需 clean"
fi

 echo "== 5d. LuCI 主题 Argon v3.1.0（用户指定，取代 Bootstrap 为默认）=="
 # 为什么不用官方 feed：25.12.6 的 luci feed 只有 5 个主题
 #   bootstrap / footstrap / material / openwrt / openwrt-2020 —— 没有 Argon。
 # Argon 是第三方的：https://github.com/jerrykuku/luci-theme-argon
 # v3.1.0 官方 CI 用 OpenWrt 25.12.5 SDK 出 APK v3，且模板以源码形式发布
 #   （Makefile 里 LUCI_MINIFY_UT:=0），不绑死 ucode 字节码版本 —— 这两点
 #   正是 25.12 能用的关键（issue #715 / #660 是老 2.x 在 25.12 上崩的原因）。
 # ARGON_SRC 由 lib-paths.sh 解析（默认 $WORK/pkgsrc/luci-theme-argon-v3.1.0）
 if [ -d "$ARGON_SRC" ]; then
 	rm -rf $OWTREE/package/luci-theme-argon
 	mkdir -p $OWTREE/package/luci-theme-argon
 	cp -a "$ARGON_SRC/." $OWTREE/package/luci-theme-argon/
 	echo "  源码 -> package/luci-theme-argon（$(ls $OWTREE/package/luci-theme-argon | wc -l) 个顶层项）"
 else
 	echo "  !! 缺 $ARGON_SRC —— Argon 不会进固件"
 	echo "     下载 https://codeload.github.com/jerrykuku/luci-theme-argon/tar.gz/refs/tags/v3.1.0"
 	echo "     解包到 $ARGON_SRC（--strip-components=1）"
 fi
 # Bootstrap 保留安装（约 40KiB）但不是默认：Argon 的 uci-defaults 会把
 #   luci.main.mediaurlbase 设成 /luci-static/argon。留着它是逃生门 —— Argon 若
 #   渲染失败，uci set luci.main.mediaurlbase=/luci-static/bootstrap 即可回到。
 add_pkg_sym CONFIG_PACKAGE_luci-theme-argon=y CONFIG_PACKAGE_luci-theme-bootstrap=y
 echo "THEME  => $(grep -cE '^CONFIG_PACKAGE_luci-theme-(argon|bootstrap)=y$' $CFG)/2（argon 为活动主题，bootstrap 仅兜底，顶层 .config）"

 # ---------------------------------------------------------------
 # P25 —— rootfs overlay：开箱即用调优（不再靠用户 shell）
 # ---------------------------------------------------------------
 # 为什么单独一个目录：$T/files/ 是**内核源码** overlay（drivers/dts），
 # 而 rootfs 文件必须进编译树顶层 $OWTREE/files/（OpenWrt 约定，
 # 在 base-files 与 package 之后覆盖进 $(TARGET_DIR)）。
 #
 # base-files 那两份（wireless 配置、uci-defaults 兜底）走 target 目录，
 # 整份替换 —— 不用 sed 打补丁，保证可复现、不被上游上下文变化搞坏。
 # ---------------------------------------------------------------
 echo "== 5e. rootfs overlay（net-tune 守护 + sysctl + rc.d）=="
 ROOTFILES=$OWTREE/files
 # 旧的 rps-watch 三件套已被上游 packet_steering 取代，残留会把 rps_cpus 拉回
 # 单核（上游脚本会跟它打架）。先清掉已装到编译树的旧拷贝。
 rm -f $ROOTFILES/usr/sbin/rps-watch $ROOTFILES/etc/init.d/rps \
       $ROOTFILES/etc/sysctl.d/99-wta301-rps.conf $ROOTFILES/etc/rc.d/S99rps
 mkdir -p $ROOTFILES
 cp -a $SRC/files-rootfs/. $ROOTFILES/
 chmod 0755 $ROOTFILES/usr/sbin/net-tune $ROOTFILES/etc/init.d/net-tune
 # /etc/rc.d 符号链接：OpenWrt 用 S<NN><name> -> ../init.d/<name> 控制开机顺序。
 # 不用 `/etc/init.d/net-tune enable` 的原因是那要等板子起来跑；构建期放链接才叫固化。
 mkdir -p $ROOTFILES/etc/rc.d
 ln -sf ../init.d/net-tune $ROOTFILES/etc/rc.d/S99net-tune
 find $ROOTFILES -type f -o -type l | sed "s|$ROOTFILES|  files/|"

 echo "== 5f. base-files 整份替换（无线出厂最优值 + packet steering）=="
 BB=$T/ipq50xx/base-files
 cp -f $SRC/files-base-files/etc/config/wireless              $BB/etc/config/wireless
 cp -f $SRC/files-base-files/etc/uci-defaults/99-wta301-wireless $BB/etc/uci-defaults/99-wta301-wireless
 cp -f $SRC/files-base-files/etc/uci-defaults/99-wta301-net      $BB/etc/uci-defaults/99-wta301-net
 chmod 0644 $BB/etc/config/wireless
 chmod 0755 $BB/etc/uci-defaults/99-wta301-wireless $BB/etc/uci-defaults/99-wta301-net
 echo "  wireless:"
 grep -E "^\s*option (band|channel|htmode|country|cell_density|noscan)" $BB/etc/config/wireless | sed 's/^/    /'
 echo "  packet steering:"
 grep -E "packet_steering|steering_flows" $BB/etc/uci-defaults/99-wta301-net | sed 's/^/    /'

 # ---------------------------------------------------------------
 # P28 —— 让 sysupgrade 能在这块板上工作（不再必须进 u-boot）
 # ---------------------------------------------------------------
 # 上游 ipq50xx/platform.sh 的 platform_do_upgrade() case 里没有 tplink,wta301，
 # 落到 *) default_do_upgrade，而它写的是 ${PART_NAME:-image}（默认 "firmware"）。
 # 本板没有叫 firmware 的分区 ⇒ LuCI / 命令行刷写必失败。
 #
 # 本板是裸固定分区（kernel/rootfs 不在 UBI 里），overlay 在 mtd12 的 UBI 卷
 # wta301data —— 所以写 mtd5/mtd6 根本不碰配置，升级后设置和已装包全保留。
 #
 # 整份替换而不是 sed：与上面的 base-files 同样理由（可复现、抗上游上下文漂移）。
 # 来源：OpenWrt v25.12.6
 #   target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/platform.sh
 #   md5 bf8e145b265335d818efed942a7c7fc9，仅新增 wta301 分支与检查。
 echo "== 5g. sysupgrade：ipq50xx/platform.sh 加 tplink,wta301 分支 =="
 cp -f $SRC/files-ipq50xx-upgrade/lib/upgrade/platform.sh \
       $T/ipq50xx/base-files/lib/upgrade/platform.sh
 chmod 0755 $T/ipq50xx/base-files/lib/upgrade/platform.sh
 echo "  wta301 分支:"
 grep -n "tplink,wta301" $T/ipq50xx/base-files/lib/upgrade/platform.sh | sed 's/^/    /'
 echo "  拒绝刷写的判据:"
 grep -E "does not fit|not squashfs|not a sysupgrade tar|has no " \
      $T/ipq50xx/base-files/lib/upgrade/platform.sh | sed 's/^\s*/    /'
 sh -n $T/ipq50xx/base-files/lib/upgrade/platform.sh && echo "    sh -n OK"

 # kernel 分区必须声明 0x740000：FIT 是 4,280,940 B（0x41526c），比 factory 表的
 # 0x400000 大 86,636 B。声明小了 mtd write 会直接拒绝，sysupgrade 就写不进内核。
 echo "  DTS kernel 分区（必须 0x740000）:"
 grep -A3 'kernel@4880000' $T/files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts \
      | grep 'reg = ' | sed 's/^\s*/    /'

 echo "== DONE =="
