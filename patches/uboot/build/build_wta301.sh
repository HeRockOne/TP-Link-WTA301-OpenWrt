#!/bin/bash
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
