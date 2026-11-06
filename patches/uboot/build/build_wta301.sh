#!/bin/bash
# ⚠️ LEGACY —— 这是当时在本机跑的原样记录，**路径是写死的**，别人拿去跑不了。
#   正路：用同目录的 build_j1.sh，它支持 UBOOT_TREE / TOOLCHAIN_BIN 环境变量。
#   保留本文件只为追溯「当时究竟跑了什么命令」。见 README.md §3。
#
# Incremental rebuild of WTA301 u-boot (never run distclean: it deletes our .dts)
set -e
cd /mnt/c/Users/Sophia/Downloads/Compressed/wta301e3tyv1_cn_1_0_10_up_boot/src
export ARCH=arm
export CROSS_COMPILE=arm-openwrt-linux-muslgnueabi-
export STAGING_DIR=$PWD/staging_dir
export PATH=$PWD/staging_dir/toolchain-arm_cortex-a7_gcc-5.2.0_musl-1.1.16_eabi/bin:$PATH
cd u-boot-2016
rm -f arch/arm/dts/ipq5018-tplink-wta301.dtb.comb.o \
      arch/arm/dts/.ipq5018-tplink-wta301.dtb.comb.o.cmd \
      arch/arm/dts/dtbtable.S arch/arm/dts/dtb_combined.bin
make -j6 2>&1 | tail -25
echo "---- result ----"
ls -l u-boot.bin dtb_combined.bin 2>/dev/null
md5sum u-boot.bin
