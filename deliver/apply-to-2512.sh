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
EOF
fi
tail -12 $T/ipq50xx/config-default

# 幂等强制：树里可能还留着 R18 时期的 "is not set"
sed -i 's|^# CONFIG_PCS_QCA_UNIPHY is not set$|CONFIG_PCS_QCA_UNIPHY=y|' $T/ipq50xx/config-default
grep -q '^CONFIG_PCS_QCA_UNIPHY=y$' $T/ipq50xx/config-default || echo 'CONFIG_PCS_QCA_UNIPHY=y' >> $T/ipq50xx/config-default
echo "PCS_QCA_UNIPHY => $(grep -n 'PCS_QCA_UNIPHY' $T/ipq50xx/config-default)"

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

echo "== DONE =="