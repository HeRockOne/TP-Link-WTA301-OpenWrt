# 03 外部证据

每条标注：**[外部实证]**（别人的实测）· **[上游代码]**（可查源码）· **[本板实证]**（我们自己的）
· **[推断]**。附 URL 与原文关键字段。

---

## E-1 [上游代码] 正式版 25.12.x 才有 ipq50xx

```
releases/24.10.0 … 24.10.8   targets/qualcommax/  →  只有 ipq807x
releases/25.12.0 … 25.12.6   targets/qualcommax/  →  ipq50xx, ipq60xx, ipq807x
```

25.12.6 的 `ipq50xx` 目录含 5 个 profile（`profiles.json`）：`cmcc_mr3000d-ci`、`linksys_mx6200`、
`linksys_spnmx56`、`yuncore_ax830`、`yuncore_ax850` —— **无 TP-Link**。

**来源**：`https://downloads.openwrt.org/releases/25.12.6/targets/qualcommax/ipq50xx/`

---

## E-2 [上游代码] 25.12.6 的版本与内核

| 项 | 值 |
|---|---|
| 版本 | `25.12.6` |
| 内核 | **6.12.112** |
| kmods 目录名 | `6.12.112-1-175dffd337a18721108278990fd69f67` |
| toolchain | `gcc-14.3.0_musl` |
| 25.12.0 的内核 | `6.12.71`，kmods `6.12.71-1-592d0ef77704694d198540593694c92c` |
| 发布日期 | **2026-10-18 02:11**（`v25.12.6` tag 指向提交 `64900e75`） |
| 24.10.8 发布 | 2026-07-25 |
| 25.12.0 发布 | 2026-03-03 |

**本板对照**：`r37669-6c9452a35b` 构建于 **2026-10-25T20:35:35Z** ⇒ 晚于 25.12.6 发布 7 天。

---

## E-3 [上游代码] 7 个同硬件组合设备

`target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/` 中，同时含 `ipq5018` + `qca8337` +
`qcn6122` 的 DTS：

```
ipq5018-gl-b3000.dts       qca8337 qcn6122
ipq5018-mr3000d-ci.dts     qca8337 qcn6122
ipq5018-mx2000.dts         qca8337 qcn6122
ipq5018-pz-l8.dts          qca8337 qcn6122
ipq5018-scr50axe.dts       qca8337 qcn6122
ipq5018-wn-dax3000gr.dts   qca8337 qcn6122
ipq5018-wrc-x3000gs2.dts   qca8337 qcn6122
```

QCN6122 专用 ath11k 补丁（`package/kernel/mac80211/patches/ath11k/`）：

```
920-wifi-ath11k-add-hw-params-for-QCN6122.patch
921-wifi-ath11k-add-hal-regs-for-QCN6122.patch
922-wifi-ath11k-add-hw-ring-mask-for-QCN6122.patch
923-wifi-ath11k-update-hif_and-pci_ops-for-QCN6122.patch
924-wifi-ath11k-add-multipd-support-for-QCN6122.patch
925-wifi-ath11k-add-QCN6122-device-support.patch
931-wifi-ath11k-Support-to-assign-m3-dump-memory.patch
947-wifi-ath11k-fix-rssi-station-dump-for-IPQ5018-and-QC.patch
```

**关键**：补丁列表里**没有**任何 low-memory / ring 缩减补丁（号段 900–948 已逐一核对）。

---

## E-4 [外部实证] 256 MiB + 双射频会 OOM

### E-4a 上游 ath11k DP ring 默认值

```
DP_TX_COMP_RING_SIZE           32768
DP_RXDMA_BUF_RING_SIZE          4096
DP_RXDMA_MON_STATUS_RING_SIZE   1024
DP_RXDMA_MONITOR_BUF_RING_SIZE  4096
DP_RXDMA_MONITOR_DST_RING_SIZE  2048
```

**来源**：[PATCH ath-next] wifi: ath11k: use smaller DP rings on low-memory systems
<https://lore-kernel.gnuweeb.org/ath11k/20260930165052.4998-1-eduard.hart@etik.com/>

原文：
> On IPQ5018 boards with 256 MiB of RAM and a second radio (e.g. QCN6122), the RX buffers and
> TX completion rings of both radios take so much memory that the system runs out of memory
> shortly after bringing up both interfaces.

低内存档：
> TX completion ring: 32768 -> 2048 / RXDMA buffer ring: 4096 -> 1024 /
> RXDMA monitor status: 1024 -> 512 / RXDMA monitor buffer: 4096 -> 128 /
> RXDMA monitor dest: 2048 -> 128

实测环境正是 **TP-Link RE700X（IPQ5018 + QCN6122, 256 MiB）**：
> both radios of a TP-Link RE700X ... stay up under load (4-6 clients) with 14-37 MiB of RAM
> available and no OOM

### E-4b 论坛实测（Mercusys MR80X v2，同 SoC + 同 5G 芯片）

<https://forum.openwrt.org/t/a-simple-patch-to-get-ath11k-working-on-256mib-ram/247147>

> The driver ... would allocate 3 rings of 4096, 1024 and 4096 of a little over 2KiB skbs.
> Of those 3 rings only the first one is an actual RX ring

修改前后 `free`（原文）：
```
Before: Mem: 185132 total, 10604 available
After:  Mem: 185132 total, 68884 available
```

### E-4c 上游把同规格设备设为 wifi disabled

`ipq5018-wrc-x3000gs2.dts`（ELECOM，256 MiB，QCA8337+QCN6122）：

```dts
&wifi  { status = "disabled"; };
&wifi1 { status = "disabled"; };
```

论坛同帖：
> Wired only, against current main. Wi-Fi stays disabled, 256 MB is too little for ath11k,
> same as the ELECOM WRC-X3000GS2.

### E-4d 一个重要的反例

<https://forum.openwrt.org/t/mercusys-mr80x-v2-working-openwrt-with-patched-ath11k/252380>

> I have to walk back what I wrote at the top of this thread. Memory was never the problem on
> this device. There were no OOM kills, and the box idles at ~50 MB available with both radios
> loaded. ... it is not what made this device work.

⇒ 同规格硬件上，**是否 OOM 取决于具体 BDF/固件内存模式/负载**，不能一概而论。

---

## E-5 [外部实证] `EXTRA_CFLAGS` 在 6.18 起失效

<https://forum.openwrt.org/t/xiaomi-ax3000t-rd03v2-ipq5018-working-openwrt-installs-to-nand/252985>

> it passes its define via `EXTRA_CFLAGS`, and 6.18's kbuild no longer honours `EXTRA_CFLAGS`
> (6.12 does), so the variant silently builds with full rings and keeps OOMing ... One-liner
> fix: pass the defines through `KCPPFLAGS` instead

**对我们的意义**：25.12.6 是 **6.12**，`EXTRA_CFLAGS` 仍有效；但若将来升 6.18，任何依赖
`EXTRA_CFLAGS` 的 ath11k 补丁会**静默失效**（编出来是全尺寸 ring，不报错）。

---

## E-6 [外部实证] TP-Link RE700X 移植（同 SoC 同 5G 芯片，同厂商）

<https://git.openwrt.org/openwrt/staging/stintel/plain/target/linux/qualcommax/dts/ipq5018-re700x.dts>

原文注释（关键，直接对应我们的 RTL8367S 场景与 button/GPIO 陷阱）：

> No reset-gpios: the stock DTB claimed gpio33 as the PHY reset, but gpio33 is actually the
> 2.4G LED (confirmed by GPIO sweep). U-Boot brings the PHY up and the link is stable without
> a Linux-side reset.

> nand-ecc-strength = <4>;  /* strength=8 breaks NAND I/O, use 4 instead */

> mdio0 ... Not used for a port, but its probe sets TCSR ETH_LDO_RDY, which tells the CMN PLL
> that the ethernet LDO is up. All other ipq5018 boards enable it; with it disabled the
> RTL8211F on MDIO1 did not answer

`q6v5_wcss` boot-args 格式（6 元组/射频）：
> Format per radio: <PCIE-index, length, userPD-id, reset-gpio, resv, resv>

> boot-args = <1 4 3 15 0 0 2 4 2 27 0 0>;

**对我们**：说明 vendor DTB 里的 GPIO 分配**不可信**，必须 GPIO 扫描实测。

---

## E-7 [外部实证] QCN6122 的 PD 编号与固件变体

<https://github.com/openwrt/openwrt/pull/20928>

> IPQ5018 based boards come in multiple wireless architectures. The SOC itself provides 2.4G
> wifi while 5G wifi is added by either an IPQ5018-specific QCN6122 (2x2) solution or by the
> more generally available PCIe-based QCN9074 (4x4) wifi chip.

> only two devices have two qcn6122 radios: linksys_mx6200, zyxel_scr50axe. Other devices with
> one qcn6122 radio should use `IPQ5018_QCN6122` firmware instead of `IPQ5018_QCN6122_QCN6122`.

---

## E-8 [外部实证] 同规格设备的 sysupgrade A/B 布局

<https://forum.openwrt.org/t/ipq5018-adding-cudy-p5-support/252655>

> Sysupgrade works, device has A/B layout. OpenWrt currently uses only one slot, while the
> stock firmware slot is left untouched and read-only.

**对我们**：我们的双槽（`kernel`/`kernel_bak`、`rootfs`/`rootfs_bak`）与之一致，
可以考虑只在 A 槽跑、B 槽保留原厂。

---

## E-9 [本板实证] S7 上双射频在跑，可用内存 63 MB

板上 `free -m`：

```
              total        used        free      shared  buff/cache   available
Mem:         177652       98212       37832         280       41608       63940
Swap:         49148           0       49148
```

`iwinfo`：`phy0-ap0 ESSID "OpenWrt-WTA301" Channel 6 (2.437 GHz) HT40`，`/sys/class/ieee80211/`
下有 **phy0 与 phy1**（双射频都起来了）。

`dmesg`：

```
ath11k c000000.wifi: ipq5018 hw1.0
ath11k c000000.wifi: FW memory mode: 2
ath11k b00a040.wifi: Multipd architecture - userpd: 2
ath11k b00a040.wifi: qcn6122 hw1.0
ath11k b00a040.wifi: FW memory mode: 2
fw_build_id WLAN.HK.2.7.0.1-01744-QCAHKSWPL_SILICONZ-1   (两个射频同)
```

**关键**：`FW memory mode: 2`（最省内存档）+ 默认 DP ring ⇒ **本板 256 MiB 够用，无 OOM**。

**但**：这是 **6.18.55** 的观测，25.12.6 是 **6.12.112**，需重验（R1）。

---

## E-10 [本板实证] 实际 DTB ≠ 源 dts

从 `op_kernel_0x480000.bin` 偏移 `0x46eb48`（25,978 B，md5 `dff6e3c9168e168a0b12c1c2c685cbfc`）
反编译：

```dts
model = "TP-Link WTA301";
wifi@c000000 { status = "okay"; qcom,ath11k-fw-memory-mode = <0x02>; qcom,bdf-addr = "L@"; };
wifi@b00a040 { status = "okay"; qcom,ath11k-fw-memory-mode = <0x02>;
               qcom,bdf-addr = "M0"; qcom,m3-dump-addr = "N "; };
wifi@b00b040 { status = "disabled"; };
```

仓库里 `wta301-s7/rootfs/ib-patches/ipq5018-wta301.dts` 写的是：

```dts
&wifi  { status = "okay";    qcom,ath11k-fw-memory-mode = <1>; };
&wifi1 { status = "disabled"; qcom,ath11k-fw-memory-mode = <1>; };
```

⇒ **不一致**：mode 1 vs 2、wifi1 disabled vs okay。实际 DTB 是另一次改动的产物，未回写源。

**处置**：P1.1 把实际 DTB 反编译入仓作为基线（`patches/s7-actual-dtb.dts`），
不再信任源 dts。

---

## 待补证据（P1 阶段）

| # | 需查 | 途径 |
|---|---|---|
| E-11 | RTL8367S 在 6.12 的驱动支持（`drivers/net/dsa/rtl8366*`？） | 内核源码 grep |
| E-12 | 6.12 的 `ipq5018.dtsi` 里 uniphy/gmac 节点名是否与 6.18 一致 | 25.12.6 源码 |
| E-13 | `qcom,smem-part` 与 `fixed-partitions` 在本 U-Boot 下是否冲突 | 25.12.6 源码 + 实测 |
| E-14 | 25.12.6 IB tarball 的实际结构与是否含 wta301 | 下载后 grep |
| E-15 | RTL8367S 是否有上游 DSA 驱动 | lore / kernel git |

---

## E-11 ★★ OpenWrt 上游把 ipq50xx 从 QSDK ESS 迁到主线 DWMAC/PCS 的提交（时间晚于 25.12 分支）

**[外部实证]** commit `16ac5736c178c36d4cb7ae0f791f8bd2a5af095a`
`qualcommax: ipq50xx: convert to UNIPHY PCS and DWMAC stack`
作者 georgemoussalem；author date **2026-05-05**；fork 提交 date 2026-07-05
URL: https://github.com/JuliusBairaktaris/openwrt-nss-edma/commit/16ac5736c178c36d4cb7ae0f791f8bd2a5af095a

变更（+180/−456，22 文件）关键部分原文：
```
 target/linux/qualcommax/files/include/dt-bindings/net/qcom-ipq-ess.h | removed | 0 | 42
 target/linux/qualcommax/ipq50xx/config-default                        | modified | 5 | 0
 target/linux/qualcommax/ipq50xx/target.mk                             | modified | 0 | 1
 target/linux/qualcommax/patches-6.12/0722-...-clk-providers-by-name.patch | removed | 0 | 40
```
config-default 增量（原文）：
```
+# CONFIG_DWMAC_GENERIC is not set
+CONFIG_DWMAC_IPQ5018=y
+CONFIG_PCS_XPCS=y
+CONFIG_STMMAC_ETH=y
+CONFIG_STMMAC_PLATFORM=y
```
target.mk 减量（原文）：
```
-DEFAULT_PACKAGES += kmod-qca-nss-dp
```
commit message 原文：
> Convert to UNIPHY PCS and DWMAC ethernet stack from qca-ssdk.
> Since we are not using SSDK anymore, we dont need to patch in the UNIPHY clock names anymore so drop the patch.

**板级差异表**（对 WTA301 的意义）：

| 项 | 上游该提交 | 本板 | 同/不同 |
|---|---|---|---|
| SoC 以太网 IP | IPQ5018 GMAC0/GMAC1 + UniPHY | 同 | 同 |
| 驱动栈 | stmmac(DWMAC_IPQ5018) + PCS_QCA_UNIPHY + DSA | S7 已在用同一套（6.18.55） | 同 |
| 交换机 | QCA8337（qca8k） | **RTL8367S**（rtl8365mb） | **不同** |
| 是否在 25.12.6 里 | ❌（25.12.0 分支于 2026-03-03） | — | 需自行补 |

**结论**：25.12.6 必须补这批补丁才有有线；补齐方式 = 取该提交父提交
`763d32b8d0a816e9a55de6464958b8d5597f66b3` 的 `patches-6.12/` 与 `files/`（那时上游树仍是 6.12）。

---

## E-12 ★ openwrt/qca-ssdk 不支持 Realtek 交换机（SSDK 路径不可行）

**[外部实证]** `package/kernel/qca-ssdk/Makefile` 原文：
```
PKG_SOURCE_URL:=https://github.com/openwrt/qca-ssdk.git
PKG_SOURCE_DATE:=2025-05-30
PKG_SOURCE_VERSION:=446db12b1fd3bca2e61e45cb01c4ad52cfddd95b
```
GitHub tree API 拉全量 `?recursive=1`：**953 个文件**，
用 `rtl|realtek|8367|8369` 正则匹配 → **0 命中**。

**结论**：25.12.6 的 SSDK 无法驱动本板的 RTL8367S。
TP-Link 原厂用的是 QSDK 私有 `qualcomm,rtk-gsw`（见 `patches/factory/fdt_mp02.1.dts` 的
`rtl-instace` 节点），主line 与 openwrt/qca-ssdk 都没有。

---

## E-13 25.12.6 的 ipq50xx 前身就是 QSDK ESS（本地实证，附原文）

**[本板实证/本地文件]** `target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-ess.dtsi`：
```dts
switch: ess-switch@39c00000 {
    compatible = "qcom,ess-switch-ipq50xx";
    device_id = <0>;
    switch_access_mode = "local bus";
    ...
};
ess-uniphy@98000 { compatible = "qcom,ess-uniphy"; };
dp1: dp1 { compatible = "qcom,nss-dp"; qcom,id = <1>; reg = <0x39C00000 0x10000>; };
dp2: dp2 { compatible = "qcom,nss-dp"; qcom,id = <2>; reg = <0x39D00000 0x10000>; };
```
`target/linux/qualcommax/ipq50xx/config-default` 全文 30 行，含
`CONFIG_NET_DSA_QCA8K=y` / `CONFIG_MAXLINEAR_GPHY=y` / `CONFIG_QCA83XX_PHY=y`，
**不含** `STMMAC_ETH` / `DWMAC_IPQ5018`。

---

## E-14 25.12.6 已具备 PCS-provider 框架（前置 API 不需要自己补）

**[本地文件]** `target/linux/generic/pending-6.12/`：
```
737-01-net-phylink-keep-and-use-MAC-supported_interfaces-in.patch
737-02-net-phylink-introduce-internal-phylink-PCS-handling.patch
737-03-net-pcs-implement-Firmware-node-support-for-PCS-driv.patch
737-04-net-phylink-save-phylink-instance-fwnode-on-phylink_.patch
737-05-net-phylink-support-PCS-provider-release.patch
737-06-net-phylink-support-late-PCS-provider-attach.patch
737-07-net-phylink-add-.pcs_link_down-PCS-OP.patch
```
`target/linux/generic/config-6.12:2169` = `# CONFIG_FWNODE_PCS is not set`（符号存在）
`target/linux/generic/backport-6.12/601-09-v6.14-net-phylink-add-pcs_inband_caps-method.patch` 等。

---

## E-15 CMN PLL 频率是 4.8 GHz（纠正误读，引上游 commit message 原文）

**[上游代码]** `patches-6.12/0818-arm64-dts-qcom-ipq5018-fix-assigned-cmn-pll-clock-rate.patch` 原文：
> In IPQ5018, the reference clock to the CMN PLL block from the on-board Wi-Fi has its
> divider set to 2. This divider wasn't taken into consideration when calculating the
> CMN PLL clock rate which meant the resulting clock rate was doubled.
> With the reference clock divider being accounted for in the driver, correct the
> assigned clock rate to **4.8GHz**.
```
-			assigned-clock-rates-u64 = /bits/ 64 <9600000000>;
+			assigned-clock-rates-u64 = /bits/ 64 <4800000000>;
```
DTB 里表现为两个大端 u32 `<0x01 0x1e1a3000>` = 0x1_1E1A3000 = 4,800,000,000。
**按 32 位读成 505 MHz 是错的。**

---

## E-16 6.12 内核本身没有 uniphy PCS / ipq5018 DWMAC（线上核实）

**[外部代码]** `v6.12.112` 的 `drivers/net/pcs/Kconfig` 尾（git.kernel.org plain view）：
```
config PCS_RZN1_MIIC
	tristate "Renesas RZ/N1 MII converter"
	...
endmenu
```
—— 没有 `PCS_QCA_UNIPHY`；`arch/arm64/boot/dts/qcom/ipq5018.dtsi`（399 行）也没有任何
`ethernet@` / `ethernet-pcs@` / `mdio@` 节点。
URL: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/net/pcs/Kconfig?h=v6.12.112

⇒ 有线能力**完全来自 OpenWrt 的 files/ + patches**，不在内核本体里。这也解释了为什么
25.12.6 分支要等上游 conversion commit 才有主线以太网。
