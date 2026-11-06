#!/bin/bash
# Incremental rebuild of an arbitrary ipq5018 board in this tree.
# NEVER run distclean/mrproper: it deletes our hand-added .dts files.
# Usage: build_board.sh <defconfig-name-without-"_defconfig">
set -e
B="$1"
ROOT=/mnt/c/Users/Sophia/Downloads/Compressed/wta301e3tyv1_cn_1_0_10_up_boot/src
cd "$ROOT"
export ARCH=arm
export CROSS_COMPILE=arm-openwrt-linux-muslgnueabi-
export STAGING_DIR="$ROOT/staging_dir"
export PATH="$ROOT/staging_dir/toolchain-arm_cortex-a7_gcc-5.2.0_musl-1.1.16_eabi/bin:$PATH"
cd u-boot-2016

echo "== defconfig: $B =="
make "$B"_defconfig >/dev/null

# purge every generated DTB/table artefact so the combine step is idempotent
rm -f arch/arm/dts/*.dtb.comb.o arch/arm/dts/.*.dtb.comb.o.cmd
rm -f arch/arm/dts/*.dtb.comb.S arch/arm/dts/dtb_combined.bin
rm -f arch/arm/dts/dtb_combined.bin.gz arch/arm/dts/dtbtable.S
rm -f arch/arm/dts/*.dtb

# `set -e` above would kill this script the instant make returns non-zero,
# before the report below could run - which is exactly what happened twice:
# the log showed only "== defconfig ==" and the real cause stayed hidden.
set +e
make -j6 > build.log 2>&1
rc=$?
set -e
if [ $rc -ne 0 ]; then
	echo "!! make FAILED rc=$rc - real error lines:"
	grep -n -i -m 20 'error\|undefined\|No rule\|not found\|No such file' build.log
	echo "!! last 8 lines:"
	tail -8 build.log
	exit $rc
fi
tail -4 build.log
ls -l u-boot.bin
md5sum u-boot.bin
