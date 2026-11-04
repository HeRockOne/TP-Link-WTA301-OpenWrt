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
ls -1 $T/patches-6.12/092*

echo "== 2. files/（驱动 + dt-binding + 板级 dts）=="
mkdir -p $T/files
cp -a $SRC/files/. $T/files/
find $T/files -name '*ipq5018*' -o -name 'pcs-qca-uniphy*' -o -name 'qca-uniphy.h' | sort

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
# PCS_QCA_UNIPHY must stay OFF: the upstream pcs-qca-uniphy.c calls
# clk_hw_recalc_rate(), which does not exist in 6.12 (nor in 6.18) - the file is
# latent-broken upstream because the 5 shipped ipq50xx profiles never build it.
# S7's own boot log proves the board runs without it:
#   ipq5018-gmac-dwmac 39d00000.ethernet: ... Ring mode enabled
#   rtl8365mb-mdio 90000.mdio-1:1d: configuring for fixed/sgmii link mode
#   rtl8365mb-mdio 90000.mdio-1:1d: Link is Up - 1Gbps/Full
# and dwmac-ipq5018.c returns 0 when the PCS is absent (fixed-link path).
# CONFIG_PCS_QCA_UNIPHY is not set

CONFIG_STMMAC_ETH=y
CONFIG_STMMAC_PLATFORM=y
EOF
fi
tail -12 $T/ipq50xx/config-default

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
