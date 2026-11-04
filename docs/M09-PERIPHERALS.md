# M09 USB / PCIe / SDCC / 其它外设

**一句话结论：本板这些外设「全部关着」，而 25.12.6 的 6.12 dtsi 默认也全是 disabled ⇒ 迁移几乎零动作。
唯一要显式打开的是 `crypto`(+`cryptobam`) 与 `watchdog`（S7 里是 okay，6.12 vanilla 里是 disabled）。
★ 特别注意：`QCN6122` 不是 PCIe 设备，**不要**照抄上游板子去 `enable pcie0`。**

---

## 1. 逐节点三方对照

数据来源：
- **25.12.6** = `/tmp/dtsi_after.dtsi` = v6.12.112 原始 `ipq5018.dtsi`(399 行) 套完
  `target/linux/qualcommax/patches-6.12/*.patch` 全部 102 个补丁 + 我们的 0842 后的文件（1210 行）。
- **S7 实测** = `patches/s7-actual-dtb.dts`（从板上跑的 DT 反编译，25,978 B）。

| 节点 | compatible | 25.12.6 dtsi 默认 | S7 实测 | 驱动 config（ipq50xx+generic） | 动作 |
|---|---|---|---|---|---|
| `pcie1: pcie@80000000` | `qcom,pcie-ipq5018` | **disabled** | **disabled** | `CONFIG_PCIE_QCOM=y` `PCIE_DW=y` | **保持 disabled** |
| `pcie0: pcie@a0000000` | `qcom,pcie-ipq5018` | **disabled** | **disabled** | 同上 | **保持 disabled** |
| `pcie1_phy: phy@7e000` / `pcie0_phy: phy@86000` | `qcom,ipq5018-uniphy-pcie-phy` | okay（phy 无 status） | 无 status | `CONFIG_PHY_QCOM_UNIPHY_PCIE_28LP=y` | 由 pcie 控制，不动 |
| `usb: usb@8af8800` | `qcom,ipq5018-dwc3` | **disabled** | **disabled** | **`# CONFIG_USB_DWC3 is not set`** | 无动作（节点死了） |
| `usbphy0: phy@5b000` | `qcom,ipq5018-uniphy-usb3-phy` | okay | 无 status | `CONFIG_PHY_QCOM_M31_USB=y` | 无动作 |
| `sdhc_1: mmc@7804000` | `qcom,ipq5018-sdhci` | **disabled** | **disabled** | `CONFIG_MMC_SDHCI_MSM=y` | 无动作 |
| `prng: rng@e3000` | `qcom,prng-ee` | **disabled** | **disabled** | `CONFIG_HW_RANDOM`/`HW_RANDOM_QCOM` | **保持 disabled**（与 S7 一致） |
| `crypto: crypto@73a000` | `qcom,crypto-v5.1` | **disabled** | **okay（默认继承）** | `CONFIG_CRYPTO_DEV_QCE=y` | **❗ 板级显式 `status="okay"`** |
| `cryptobam: dma@704000`（crypto 子节点） | `qcom,bam-dma` | 随父节点 | S7 内 reg `<0x1000000 0x300000>` 存在 | 同上 | **❗ 随 crypto 一起 okay** |
| `watchdog: watchdog@b017000` | `qcom,apss-wdt-ipq5018`,`qcom,kpss-wdt` | **disabled** | **okay（默认继承）** | `CONFIG_QCOM_WDT=y` | **❗ 板级显式 `status="okay"`** |
| `tsens` | `qcom,ipq5018-tsens` | okay（无 status） | okay | `CONFIG_QCOM_TSENS=y` | 不动（M11 详查） |
| `q6v5_wcss` / `wifi@c000000` / `wifi@b00a040` | — | 见 M04/M07 | okay×2 | `CONFIG_ATH11K_AHB` | 见 M04 |
| SMMU | — | **不存在** | 不存在 | `ARM_SMMU` 未定义 | 无（IPQ5018 无 SMMU） |

> **crypto/watchdog 差异的成因**：6.18 上游把这两个节点改成默认 okay（无 `status` 属性），
> 而 6.12 上游写成 `status = "disabled"`，由**板级 dts 显式打开**。上游 25.12.6 全部 ipq5018
> 板子都写了 `&crypto { status = "okay"; }; &cryptobam {...}; &prng {...}`（`ipq5018-gl-b3000.dts:188-198`
> 等 8 处）⇒ 我们的板子照同一约定写 `&crypto`/`&cryptobam` 即可，`&prng` 按 S7 保持关。

---

## 2. ★★ QCN6122 不是 PCIe 设备（否则会误开 pcie 浪费/踩坑）

### 反直觉的事实
S7 实际 DTB 里 **两个 PCIe 控制器都是 `status = "disabled"`**，而 5G 射频是起着的：

```
phy1-ap0  addr 00:03:7f:12:b6:b6  OpenWrt-WTA301-5G  ch36 80MHz txpower 24.00 dBm
phy0-ap0  addr 00:03:7f:12:14:14  OpenWrt-WTA301      ch6  20MHz  txpower 24.00 dBm
```
（`work/docs/V19-WIFI-WORKS-WHY.md:84-86`，**已实证**）

### 为什么不需要 PCIe
`patches/s7-actual-dtb.dts:1104` 起：
```dts
wifi@b00a040 {
    compatible = "qcom,qcn6122-wifi";
    reg = <0xb00a040 0>;                     /* size = 0，不是 PCI 配置空间 */
    userpd-subsys-name = "q6v5_wcss_userpd2";
    qcom,rproc = <&q6v5_wcss>;               /* 挂在 WCSS remoteproc 下 */
    fw-memory-mode = <2>;
};
```
它挂在 `remoteproc@cd00000`（`qcom,ipq5018-q6-mpd`）下面，靠 **WCSS 的 user PD** 启动，
固件是 `QCN6122/hw1.0/m3_fw.mdt`。数据面走 ath11k 的 ring，不经过 PCIe 枚举。

### 上游对照（证明「用 qcn6122 的板子一律不碰 PCIe」）

| 板 | `&pcie0` | PCIe 上挂的是什么 | 用 qcn6122 吗 |
|---|---|---|---|
| **spnmx56 / mx5500** | status=okay, `perst-gpios=<&tlmm 15 …>` | `wifi@0,0` = `pci17cb,1104` = **QCN9074 网卡** | ❌（`fw-name` 只有 q6_fw+m3_fw，无 QCN6122） |
| ax850 / ax6000 / mr5500 | pcie0 okay | 各板自带（QCN9074 或 2.5G PHY） | ❌ |
| **gl-b3000 / mx2000 / scr50axe / wn-dax3000gr** | **不出现 `&pcie*`** | — | ✅ 走 userpd |
| **本板 WTA301** | **disabled（双控制器）** | — | ✅ 走 userpd |

来源：`grep -rn "&pcie0\|&pcie1" target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-*.dts`
只有 5 个文件命中，且**不含**上面三个用 qcn6122 的板。
`ipq5018-qcn6122.dtsi:99/119` 的两个 `qcom,qcn6122-wifi` 节点默认就是 `status = "disabled"`，由板级打开。

### boot-args 里那两对 gpio 的真实含义
`boot-args = <1 4 3 15 0 0  2 4 2 27 0 0>`（M07 已确认）。原厂 DTB 里：
```
pcie_x2_rp { perst-gpio = <27 …> }   /* = pcie1 @0x80000000 */
pcie_x1_rp { perst-gpio = <15 …> }   /* = pcie0 @0xa0000000 */
```
⇒ 这两个域在**硬件上有布线**（原厂 QSDK 会去拉），但本 SKU 上没有可枚举的 PCIe 设备；
我们的做法（不 enable pcie、PERST 由固件/userpd 自己处理）已被 S7 双射频跑通**实证**。
**动作：保持 disabled；不申请 gpio15/27（M05 已有此结论，两模块互证）。**

---

## 3. 迁移动作（P2 板级 DTS 要写的行）

```dts
/* 与 S7 对齐：6.12 vanilla 里 crypto/watchdog 默认关，6.18 里默认开 */
&crypto {
	status = "okay";
};

&cryptobam {
	status = "okay";
};

&watchdog {
	status = "okay";
};

/* 明确写死「不要」，避免以后有人照抄上游板子把 PCIe 打开 */
&pcie0 {
	status = "disabled";
};

&pcie1 {
	status = "disabled";
};
```
USB / SDCC / PRNG / rng 一概不写（保持 dtsi 默认 disabled）。

---

## 4. 风险与未验证项

| 项 | 级别 | 说明 |
|---|---|---|
| `&watchdog` 的 `sleep_clk` **没有 `clock-frequency`** | 🟡 未验证 | 6.18.55 dtsi、6.12.112+补丁、S7 实际 DTB **三者一致都是无频率**（`clocks = <&sleep_clk>`，phandle 0x21）。S7 上 `qcom-wdt` probe 到没有、`/dev/watchdog` 是否可用**未验证**；迁移沿用同一写法，行为不变 |
| `CONFIG_USB_DWC3` 未开 | ⚪ 无影响 | 25.12.6 的 ipq50xx 根本没编 dwc3 ⇒ `usb@8af8800` 是死节点。若将来要 USB，需自己开 config（不在本次范围） |
| PCIe 驱动已编入但节点 disabled | ⚪ 无影响 | `CONFIG_PCIE_QCOM=y` 只增加镜像体积，不 probe |
| PRNG 保持 disabled 与上游 8 板都相反 | 🟡 有意 | 上游全部板子都 `&prng { status="okay" }`；本板 S7 是 disabled。按「与已验证基线一致」原则保持关；entropy 由内核 jitter 提供，S7 已实证无问题 |
| NSS/EDMA 加速器 | ⚪ 已知放弃 | IPQ5018 有 NSS/EDMA，但 25.12.6 只有 out-of-tree `qca-nss-dp`，我们已决定移除以走主线 DSA（R14）⇒ 无硬件加速，纯 CPU 转发 |

---

## 5. 复现命令

```bash
# 25.12.6 dtsi + 全部补丁 → 各节点默认 status
grep -nE "^\s+[a-z0-9_-]+: (pcie|usb|mmc|sdcc|tsens|watchdog|rng|crypto|phy)" /tmp/dtsi_after.dtsi
# S7 实测 status
python3 - <<'PY'   # 见会话内 m09c.sh
PY
# 上游板子是否碰 pcie
grep -rn "&pcie0\|&pcie1" <25.12.6>/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-*.dts
```
