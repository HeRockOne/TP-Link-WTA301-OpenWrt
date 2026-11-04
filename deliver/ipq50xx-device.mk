# >>> wta301 (v25.12.6) begin >>>
# TP-Link WTA301 v1.1 (China Telecom "天翼" AX3000)
#   SoC    : IPQ5018 (2x Cortex-A53), 256 MiB DDR3, 128 MiB SPI-NAND (GD5F1GQ5REYIG)
#   Switch : Realtek RTL8367S, 5x GE, SGMII 1G trunk to gmac1 (mainline DWMAC + UNIPHY PCS)
#   WiFi   : IPQ5018 internal 2.4 GHz + QCN6122 5 GHz, both as WCSS user PDs (no PCIe)
#
# Deliberately NOT derived from the TP-Link Archer AX55/AX53/EX511 device blocks:
# those are UBI layouts ($(call Device/UbiFit) + KERNEL_IN_UBI := 1).  This board
# has raw fixed partitions, kernel and rootfs in separate NAND areas, and the
# stock u-boot loads a FIT straight out of the kernel partition.
#
# Factory geometry (from the 512-byte TP header at 0x04800000 / 0x00800000 of
# work/backup/flash_full_128M.bin, byte-identical to the partition table):
#   kernel 0x4880000, declared 0x400000, real cap 0x740000 (must end before
#   rootfs at 0x4fc0000)  |  rootfs 0x4fc0000, 0xc00000
#
# KERNEL_SIZE drives include/image-commands.mk Build/check-size.  It does NOT
# fail the build: it just deletes the kernel image, so the symptom of exceeding
# it is "a full build that produced no kernel".  0x740000 = 7424k.
define Device/tplink_wta301
	$(call Device/FitImageLzma)
	DEVICE_VENDOR := TP-Link
	DEVICE_MODEL := WTA301
	DEVICE_DTS := ipq5018-wta301
	# The stock image and this board's u-boot both select the IPQ5018/AP-MP02.1
	# machine configuration, i.e. the FIT config node must keep this exact name.
	DEVICE_DTS_CONFIG := config@mp02.1
	SOC := ipq5018
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	NAND_SIZE := 128m
	KERNEL_SIZE := 7424k
	SUPPORTED_DEVICES += wta301
	# No ipq-wifi-* subpackage: this board is not in the upstream ipq-wifi
	# database, and the two board-2.bin containers are shipped through
	# ipq50xx/base-files/lib/firmware/ath11k (byte-identical to the ones the
	# S7 build proved on this hardware, md5 78f5b21b… / e4904f13…).
	DEVICE_PACKAGES := \
		ath11k-firmware-ipq5018-qcn6122 \
		kmod-dsa-rtl8365mb
endef
TARGET_DEVICES += tplink_wta301
# <<< wta301 (v25.12.6) end <<<
