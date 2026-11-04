# M01 NAND 控制器 / ECC 参数

**结论：三方不一致，而且我们现行的选择与一份旧文档的结论相反 —— 必须定案。**

---

## 1. 事实对照

| 项 | 原厂 DTB（`fdt_mp03.1`） | S7 实际 DTB | 25.12.6 上游 |
|---|---|---|---|
| 控制器节点 | `qpic-nand@79b0000` | `spi@79b0000` | `nand-controller@79b0000`（`ipq5018.dtsi`） |
| `compatible` | **`qcom,ebi2-nandc-bam-v2.1.1`** | **`qcom,ipq5018-snand`**, `qcom,ipq9574-snand` | `qcom,ipq5018-snand`, `qcom,ipq9574-snand` |
| 子节点 | `nandcs@0 { compatible="qcom,nandcs" }` | `nand@0 { compatible="spi-nand" }` | `flash@0 { compatible="spi-nand" }` |
| **ECC strength** | **4** | **8** | 由板级 DTS 指定 |
| ECC step | `0x200`（512） | `0x200` | 同 |
| bus-width | 8 | 8 | 8 |
| DMA | `tx/rx/cmd/status`（4 条，BAM v1.7） | `tx/rx/cmd`（3 条） | 3 条 |
| clock-names | `core/aon/io_macro` | `core/aon/iom` | `core/aon/iom` |
| 分区 | **无节点** | `fixed-partitions` 14 项 | 板级 DTS 定 |

**驱动来源**：
- 原厂 = QSDK **`qcom_nandc`**（raw NAND 框架），原厂 dmesg 原文：
  `QPIC controller support serial nand.` / `nand: GigaDevice GD5F1GQ5REYIG SPI NAND 1G`
- S7 = mainline **`spi-nand`**（spinand 框架）
- 两者都驱动**同一片 SPI-NAND 颗粒**，只是框架与 ECC 布局不同

**颗粒（原厂 dmesg 实测，`work/docs/dev_boot_stock.log`）**：

```
[    0.806280] nand: device found, Manufacturer ID: 0xc8, Chip ID: 0x41
[    0.810826] nand: GigaDevice GD5F1GQ5REYIG SPI NAND 1G
[    0.817188] nand: 128 MiB, SLC, erase size: 128 KiB, page size: 2048, OOB size: 128
[    0.846805] 15 RedBoot partitions found on MTD device qcom_nand.0
```

---

## 2. 冲突点：ECC 到底 4 还是 8

### 2.1 支持 4 的理由（`work/docs/final2/17-真机实测-芯片与取root原理.md`，2026-10-29）

| 来源 | ECC | 依据 |
|---|---|---|
| 原厂设备树 `nandcs@0` | **4** / 512 | 真机 flash 就是用这个参数写进去的 |
| mainline `spinand/gigadevice.c` 的 `GD5F1GQ5RExxG` 条目 | `NAND_ECCREQ(4, 512)` | 芯片要求的**最低**纠错能力 |
| 上游 `ipq5018-mr3000d-ci.dts`（**同一颗粒**） | 8 / 512 | 那台机的 flash 是 OpenWrt 自己写的，可随便选更强 ECC |

该文档结论原文：
> **结论：我们必须用 4/512。** 因为我们的内核要去读**原厂写进去的** mtd6/mtd11 内容；
> ECC 强度/layout 一变，读出来的 OOB 就按错误的布局解析，`squashfs` 会直接读挂。

### 2.2 但 S7 实际用的是 8

从 `op_kernel_0x480000.bin` 偏移 `0x46eb48` 反编译出的实际 DTB（`patches/s7-actual-dtb.dts` 第 707-727 行）：

```dts
spi@79b0000 {
    nand-ecc-strength = <0x08>;
    nand-ecc-step-size = <0x200>;
    compatible = "qcom,ipq5018-snand\0qcom,ipq9574-snand";
    ...
    nand@0 {
        compatible = "spi-nand";
        nand-ecc-engine = <0x2b>;
        nand-ecc-strength = <0x08>;      ← 8，不是 4
        nand-ecc-step-size = <0x200>;
```

**而 S7 在真机上正常工作**：内核/rootfs/overlay 全部读写正常，冷启动 ×2 PASS，
overlay 9/9 通过，逐字节校验过 kernel mtd5 与 rootfs mtd6。

### 2.3 两者为什么能同时"成立"

关键：**S7 的 Linux 从不读原厂写的那几个分区**。

| 分区 | 谁读 | ECC 由谁决定 |
|---|---|---|
| `factory_boot`（一级 u-boot） | **bootloader 自己** | bootloader 内的代码（ECC 4） |
| `normal_boot`（二级 u-boot） | **bootloader 自己** | 同上 |
| `art` / `config` | **u-boot 读**，把 caldata/MAC 放到内存，再由 `bdf-addr`/cmdline 交给内核 | 同上 |
| `kernel` / `rootfs` / `rootfs_data3` | **Linux** | Linux DTB（ECC 8） |

而 BDF 的传递路径在 S7 DTB 里是**内存地址**：

```
wifi@c000000: qcom,bdf-addr = "L@"   → 0x4c400000
wifi@b00a040: qcom,bdf-addr = "M0"   → 0x4d100000
              qcom,m3-dump-addr = "N " → 0x4e000000
```

这些是 `reserved-memory` 地址，由 **u-boot** 从 `art` 读出后填进去的。
所以 Linux 侧不需要用 ECC 8 去解 ECC-4 编码的 `art`。

⇒ **两个结论都对，只是各自的前提不同**：
- 「必须 4」成立的前提是：Linux 要直接读**原厂写得进去的**分区
- 「用 8」成立的前提是：Linux 只读写自己写的分区（= S7 现状）

### 2.4 遗留待验（M10 会一起做）

| # | 待验证 | 方法 |
|---|---|---|
| a | S7 下 `hexdump /dev/mtd2`（art）能否读出内容、有无 ECC 错 | 板上只读操作 |
| b | S7 下 `hexdump /dev/mtd3`（config）同上 | 同上 |
| c | MAC 地址实际来源：u-boot env / cmdline / `config` 分区 | 看 `/proc/cmdline`、`dmesg`、`ip link` |
| d | 若 a/b 读到 ECC 错，确认「不读也不影响运行」这个判断 | 交叉验证 Wi-Fi 与 MAC 均正常 |

---

## 3. 对 25.12.6 迁移的裁决

**决定：保持 ECC 8**（= 与 S7 一致）。

理由：
1. **单变量原则**。迁移的唯一变量是「OpenWrt 版本」，不是 NAND 编码方式。
   改 ECC 会同时改变所有已写分区的可读性，把「迁移失败」与「ECC 变化失败」搅在一起。
2. **S7 已实证可行**：ECC 8 + 我们自己的分区布局 + u-boot 供 caldata，真机长时间稳定。
3. 改 ECC 4 的好处（能读原厂分区）在本板上**没有使用场景** ——
   原厂分区内容我们已在 `work/backup/` 有完整快照，且全盘镜像 `flash_full_128M.bin` 也在。

**风险与对策**：

| 风险 | 后果 | 对策 |
|---|---|---|
| 256MiB 板上 ECC 8 的 OOB 占用更大 | 可用容量略减（不影响，128MiB 用得远没满） | — |
| 换 ECC 时已写数据变不可读 | 若将来必须换，所有分区要重刷 | 迁移前先把 S7 产物与全盘镜像备好（已完成） |
| 原厂 `art`/`config` 读不出 → MAC 丢失 | 网口无 MAC | u-boot 侧的 `bdf-addr` 机制不受 Linux ECC 影响；P4 上电后逐项验证 |

**必做**：P4 上电验证时，把 §2.4 的 a/b/c/d 四项一起测，登记进 `evidence/`。

---

## 4. 25.12.6 侧要动的地方

```dts
/* target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts */
/* 沿用 &qpic_nand（ipq5018.dtsi 已定义 spi@79b0000 / nand-controller@79b0000） */

&qpic_nand {
	status = "okay";
	pinctrl-0 = <&qspi_nand_pins>;
	pinctrl-names = "default";

	nand@0 {
		compatible = "spi-nand";
		reg = <0>;
		nand-ecc-engine = <&qpic_nand>;
		nand-ecc-strength = <8>;       /* ← 与 S7 一致 */
		nand-ecc-step-size = <512>;
		nand-bus-width = <8>;
		partitions { compatible = "fixed-partitions"; /* 14 项，见 M02 */ };
	};
};
```

**核对点**（P2 时逐条确认）：
1. 6.12 的 `ipq5018.dtsi` 里 NAND 节点 label 叫什么（`qpic_nand`? `nand_controller`?）
2. `qcom,ipq5018-snand` / `qcom,ipq9574-snand` 这两个 compatible 在 6.12 的
   `drivers/mtd/nand/spi/` 与 `qcom_nandc` 里是否都还在
3. `nand-ecc-engine` 的引用方式：6.12 用 phandle 指回控制器（S7 是 `<0x2b>`）
4. `nand-ecc-strength` 写在控制器节点还是 `nand@0` 节点 —— S7 **两处都写了**（8/8），
   上游一般只写 `nand@0`。需确认 6.12 读哪个（**写两处不会错，但不清楚哪个生效**）

---

## 5. 一句话

**原厂用 QSDK raw-NAND 框架 + ECC 4；S7 用 mainline spi-nand 框架 + ECC 8；
两者都正确，只是服务对象不同。迁移沿用 ECC 8，并把「原厂分区是否可读」列为 P4 待验项。**
