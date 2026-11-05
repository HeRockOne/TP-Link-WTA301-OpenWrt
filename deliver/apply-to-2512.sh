#!/bin/bash
# 把 P1 核对出来的交付物装进 25.12.6 树 (/root/ow2512)。
# 幂等：重复运行不会重复追加（用标记 + grep 保护）。
set -e
SRC=/mnt/c/Users/Sophia/Downloads/Compressed/wta301e3tyv1_cn_1_0_10_up_boot/wta301-2512
T=/root/ow2512/target/linux/qualcommax

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
for kd in /root/ow2512/build_dir/target-*/linux-*/linux-6.12.*; do
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
# 25.12.6 的 qualcommax/ipq50xx config-default 把 CONFIG_INPUT 关掉了，
# 导致 dts 里的 `keys { compatible = "gpio-keys"; }` 根本不会注册：
#   dmesg 无 gpio-keys、/proc/bus/input/devices 不存在
#   ⇒ /etc/rc.button/{reset,wps} 虽然存在但永远不被触发
# 三方实情（docs/M05-KEYS-THREE-WAY.md）：原厂走私有 slp_gpio 字符设备；
# S7 的 .config 有 INPUT=m 但 rootfs 一个 input 模块都没有 ⇒ S7 按键也从未工作。
# 所以这里是「超越基线的改进」（用户已明确选 B），不是恢复基线。
for sym in CONFIG_INPUT=y CONFIG_INPUT_EVDEV=y CONFIG_KEYBOARD_GPIO=y CONFIG_INPUT_MISC=y; do
	name=${sym%%=*}
	if ! grep -q "^${name}=y$" $T/ipq50xx/config-default; then
		sed -i "/^# ${name} is not set$/d" $T/ipq50xx/config-default
		echo "$sym" >> $T/ipq50xx/config-default
	fi
done
echo "KEY/INPUT => $(grep -cE '^CONFIG_(INPUT|INPUT_EVDEV|KEYBOARD_GPIO|INPUT_MISC)=y$' $T/ipq50xx/config-default)/4"

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
for sym in CONFIG_FEED_packages=y CONFIG_FEED_luci=y CONFIG_FEED_routing=y \
           CONFIG_FEED_telephony=y \
           CONFIG_PACKAGE_luci-i18n-base-zh-cn=y \
           CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y \
           CONFIG_PACKAGE_luci-i18n-package-manager-zh-cn=y \
           CONFIG_PACKAGE_luci-i18n-dashboard-zh-cn=y \
           CONFIG_PACKAGE_luci-i18n-sqm-zh-cn=y \
           CONFIG_PACKAGE_kmod-ifb=y CONFIG_PACKAGE_kmod-sched-cake=y \
           CONFIG_PACKAGE_sqm-scripts=y CONFIG_PACKAGE_luci-app-sqm=y \
           CONFIG_PACKAGE_tc-tiny=y; do
	name=${sym%%=*}
	if ! grep -q "^${name}=y$" $T/ipq50xx/config-default; then
		sed -i "/^# ${name} is not set$/d" $T/ipq50xx/config-default
		echo "$sym" >> $T/ipq50xx/config-default
	fi
done
echo "FEED   => $(grep -cE '^CONFIG_FEED_[a-z]+=y$' $T/ipq50xx/config-default)/4"
echo "ZH-CN  => $(grep -cE '^CONFIG_PACKAGE_luci-i18n-[a-z-]+-zh-cn=y$' $T/ipq50xx/config-default)/5"
echo "SQM    => $(grep -cE '^CONFIG_PACKAGE_(kmod-ifb|kmod-sched-cake|sqm-scripts|luci-app-sqm|tc-tiny)=y$' $T/ipq50xx/config-default)/5"

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
mkdir -p $T/ipq50xx/base-files/lib/firmware/ath11k/IPQ5018/hw1.0 \
         $T/ipq50xx/base-files/lib/firmware/ath11k/QCN6122/hw1.0
BDF=$SRC/../work/op-build/assets/bdf
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
mkdir -p /root/ow2512/package/system/fstools/patches
cp -f $SRC/patches/fstools/0001-fstools-honor-fstools_overlay_name.patch \
      /root/ow2512/package/system/fstools/patches/
rm -f /root/ow2512/package/system/fstools/patches/0001-mount_root-done-honor-fstools_overlay_name.patch
ls -l /root/ow2512/package/system/fstools/patches/

# 补丁变了要强制重编 fstools（OpenWrt 不会因为 patches/ 变动自动 clean）
# 判据：打完补丁后 volume_find(dataname) 在 mount_root.c 里 **2 次**
# （start() 一次 + done() 一次）、在 factoryreset.c 里 **1 次**。
# 不要用 'dataname = dataparam' 判，因为 start() 里本来就有。
N=$(grep -c 'volume_find(dataname)' /root/ow2512/build_dir/target-*/fstools-*/mount_root.c 2>/dev/null | head -1)
M=$(grep -c 'volume_find(dataname)' /root/ow2512/build_dir/target-*/fstools-*/factoryreset.c 2>/dev/null | head -1)
if [ "$N" != "2" ] || [ "$M" != "1" ]; then
	echo "fstools 源码尚未含补丁 (mount_root x$N / factoryreset x$M) -> clean 以便重新应用"
	( cd /root/ow2512 && make package/system/fstools/clean >/dev/null 2>&1 )
fi

 echo "== DONE =="