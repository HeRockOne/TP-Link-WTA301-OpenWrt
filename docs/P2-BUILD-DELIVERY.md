# P2 交付清单（DTS / 以太网栈 / 设备定义 / base-files）

**状态**：已装进 `/root/ow2512`（25.12.6 tag `64900e75`，内核 6.12.112），构建已启动。
**唯一变量**：内核 + 用户空间从 6.18.55/r37669 → 6.12.112/25.12.6。其余一切（分区、DTS 内容、脚本、board-2.bin）与 S7 保持一致。

---

## 0. ★ R14 的结论修正（重要）

P1 阶段认为 R14（以太网栈缺失）的解法是「补 7 个上游补丁」。**那只对了一半。**

真正缺的是 **设备树节点本身**：

| | 25.12.6 的 `ipq5018-ess.dtsi` | S7 树里同名文件 |
|---|---|---|
| 内容 | QSDK **ESS 交换机**（`qcom,ess-switch-ipq50xx` + `qcom,nss-dp`） | 主**线 DWMAC**（`gmac0` / `gmac1`，77 行） |
| `&gmac0/&gmac1` 标签 | **不存在** | 定义在这里 |
| 大小 | 6.5 KB | 2,039 B |

`grep -rn "gmac1:" patches-6.12 files/` 在 25.12.6 全树**零命中**，而板级 DTS 里 `&gmac1 { phy-mode = "sgmii"; }`
必须有节点可覆盖 —— 所以只补补丁、不补 DT 的话，编译会直接失败在 `&gmac1` 未定义。

**处理**：把 S7 那份内容收为 `files/arch/arm64/boot/dts/qcom/ipq5018-gmac.dtsi`（**改名**，不覆盖 25.12.6 的
`ipq5018-ess.dtsi`，否则上游 5 个 profile 全部编译失败），板级 DTS 只 include 它。

7 个补丁仍然必须补，它们解决的是另外三件事：
| 补丁 | 解决什么 |
|---|---|
| `0920`(0740-01) | PHY 时钟数上限 1 → 2（ge_phy 有 rx/tx 两个 clock） |
| `0921`(0740-03) | `ipq5018.dtsi` 里 ge_phy 的 rx/tx clocks |
| `0922`(0740-04) | at803x PHY 驱动接管这两个时钟（`CONFIG_AT803X_PHY=y` 已有） |
| `0923`(0842) | `ipq5018.dtsi` 增加 `uniphy0: ethernet-pcs@98000` + `<dt-bindings/net/qca-uniphy.h>` |
| `0924`(0843) | stmmac `get_interfaces` 平台方法（DSA conduit 需要） |
| `0925`(0951) | `CONFIG_PCS_QCA_UNIPHY`（Kconfig/Makefile 各 +1 行，驱动本体在 `files/`） |
| `0926`(0954) | `CONFIG_DWMAC_IPQ5018`（同上） |

---

## 1. 文件清单（`deliver/apply-to-2512.sh` 一次装完，幂等）

### 1.1 内核补丁 → `target/linux/qualcommax/patches-6.12/092x-*.patch`
编号 0920–0926（25.12.6 原有最大 0912，不冲突）。

### 1.2 内核 `files/` → `target/linux/qualcommax/files/`
```
drivers/net/ethernet/stmicro/stmmac/dwmac-ipq5018.c
drivers/net/pcs/pcs-qca-uniphy.c
include/dt-bindings/net/qca-uniphy.h          (UNIPHY_CLK_REF / UNIPHY_REFCLK_25MHZ)
include/dt-bindings/net/qcom,ipq5018-gmac.yaml
include/linux/pcs/pcs-qca-uniphy.h
arch/arm64/boot/dts/qcom/ipq5018-gmac.dtsi    ← 新增（见 §0）
arch/arm64/boot/dts/qcom/ipq5018-wta301.dts   ← 本板
```

### 1.3 配置
`ipq50xx/config-default` 追加：
```
# CONFIG_DWMAC_GENERIC is not set
CONFIG_DWMAC_IPQ5018=y
CONFIG_PCS_QCA_UNIPHY=y
CONFIG_STMMAC_ETH=y
CONFIG_STMMAC_PLATFORM=y
```
`target/linux/qualcommax/Makefile`：`DEFAULT_PACKAGES` 去掉 `kmod-qca-nss-dp`（纯 CPU 转发）。

### 1.4 设备定义 → `image/ipq50xx.mk`（追加 `Device/tplink_wta301`）
`FitImageLzma` · `DEVICE_DTS := ipq5018-wta301` · `DEVICE_DTS_CONFIG := config@mp02.1` ·
`KERNEL_SIZE := 7424k` · `SUPPORTED_DEVICES += wta301` ·
`DEVICE_PACKAGES := ath11k-firmware-ipq5018-qcn6122 kmod-dsa-rtl8365mb`
（**不用** `ipq-wifi-*`：本板不在上游数据库，board-2.bin 走 base-files 直供）

### 1.5 base-files → `ipq50xx/base-files/`
| 文件 | 作用 |
|---|---|
| `etc/board.d/90_wta301` | 5 口全进 br-lan；br-lan/eth0/label 设 MAC（`factory_info@0x1c`）；3 个 LED 绑 netdev |
| `etc/hotplug.d/firmware/12-wta301-caldata` | 从 ART `gzip(tar(virtual_art.bin))` 抽 caldata（2.4G@0x1000、5G@0x26800，各 0x20000）；patch MAC = label+2/+3 + `ath11k_set_macflag` |
| `lib/firmware/ath11k/IPQ5018/hw1.0/board-2.bin` | md5 `78f5b21b…`（S7 实证） |
| `lib/firmware/ath11k/QCN6122/hw1.0/board-2.bin` | md5 `e4904f13…`（S7 实证） |

两个脚本都自带 `board_name == tplink,wta301` 护卫。

---

## 2. 板级 DTS：以 S7 实跑的 540 行源文件为基线，只改 5 处

| # | 改动 | 原因 |
|---|---|---|
| **A1** | `#include "ipq5018-ess.dtsi"` → `"ipq5018-gmac.dtsi"` | 见 §0 |
| **A2** | 去掉 `"ipq5018-nss.dtsi"` 与 `&nss_region` 覆写 | 25.12.6 无 NSS/EDMA，已决定纯 CPU 转发 |
| **A3** | 显式 `&crypto` / `&cryptobam` / `&watchdog` = okay | 6.18 dtsi 默认开、6.12 默认关，S7 是开着的（docs/M09） |
| **A4** | 显式 `&pcie0` / `&pcie1` = disabled | QCN6122 是 WCSS user PD，不是 PCIe 设备（docs/M09） |
| **A5** | `coherent_pool` **2M**（v24 源文本写 512K，但实际跑的 DTB 是 2M） | 跟 DTB，不跟源文本 |
| **A6** | 分区表与 bootargs 取自 **S7 实际 DTB**：`rootfs_data`→`rootfs_data2`、**新增 `rootfs_data3`(0x1bc0000+0x2440000)**、**删除 `tp_header`/`tp_header_bak`**、bootargs 补 `ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data` | v24 源 dts 与实跑 DTB 又不一致（第 3 次踩同一个坑）。13 个分区，rootfs 仍 index 6 |

**原样保留（逐字未动）**：`tz_region` 4 MiB、`q6_region` 52 MiB、NAND 8/512 + 15 个 fixed-partitions、
`mdio0`(ge_phy@7) / `mdio1`(rtl8365mb@0x1d, 5×GE + port6 sgmii cpu)、`&uniphy0`(ref 25MHz)、
`&gmac1`(sgmii + fixed-link 1G)、`&q6v5_wcss` boot-args（UPD3/gpio15、UPD2/gpio27）、
`&wifi`(2.4G, `bdf-addr=0x4c400000`)、`&wifi1`(5G, `bdf-addr=0x4d300000`, `m3-dump=0x4e200000`)、
两射频 `fw-memory-mode=<2>` + variant `"TP-Link-WTA301"`、
keys(gpio17/20) + 5×LED(gpio19/10/11/13/**38**) + LED 别名 `led-19`、
`serial0`(gpio28/29 = blsp0_uart1)、`mdio_ahb_clk` 100 MHz。

---

## 2.5 构建环境（踩过的坑）

WSL 里以 **root** 身份构建时，`tools/tar` 的 configure 会直接拒绝：

```
configure: error: you should not run configure as root
           (set FORCE_UNSAFE_CONFIGURE=1 in environment to bypass this check)
```

⇒ 必须 `FORCE_UNSAFE_CONFIGURE=1 make -j8`。
另一个坑：`make -j8 2>&1 | tail -400` 会让日志**攒到结束才出现**，构建期间看不到进度，
所以改成 `make -j8 > /root/build.log 2>&1` 再另开一个窗口 `tail -f`。

---

## 2.8 FIT 的 config 名（已从 S7 冻结内核里 parse 确认）

`work/backup/FROZEN-S7-20261105/op_kernel_0x480000.bin` 就是 FIT/ITB（偏移 0 即 `d0 0d fe ed`）。
结构块里可见：

```
configurations → config@mp02.1 → { kernel = "kernel-1"; fdt = "fdt-1"; hash-1 { algo = "crc32" } }
description = "OpenWrt tplink_wta301"
images: kernel-1 (type=kernel) / fdt-1 (type=flat_dt, arch=arm64, compression=none)
```

⇒ `DEVICE_DTS_CONFIG := config@mp02.1` 与 S7 **逐字一致**，不是猜的。
顺带确认了 fdt-1 里的 bootargs（`root=/dev/mtdblock6 … coherent_pool=2M ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data`）、
`ethernet@39c00000` disabled / `ethernet@39d00000` okay+sgmii+fixed-link、`wifi@b00a040` okay / `wifi@b00b040` disabled、
5 个 LED（19/10/11/13/38）、`mdio-ahb-clk` —— 与本次 A1–A6 完全吻合。

## 2.9 对上游树的四类偏离（记录在案，便于日后回退/上游化）

| # | 偏离 | 影响面 | 回退方式 |
|---|---|---|---|
| D1 | `target/linux/qualcommax/Makefile` 的 `DEFAULT_PACKAGES` 去掉 `kmod-qca-nss-dp` | **会影响同 subtarget 的其它 5 个 profile**（它们的 ESS+NSS-DP 有线要靠这个 kmod） | 加回该包即可；我们不需要它（`ipq5018-gmac.dtsi` 走主线 stmmac） |
| D2 | 新增 `files/…/ipq5018-gmac.dtsi`（不改名覆盖 `ipq5018-ess.dtsi`） | 无（新增文件） | 删文件 |
| D3 | `ipq50xx/config-default` 追加 5 行 STMMAC/PCS config | 无（只是多编进主线以太网驱动） | 删 5 行 |
| D4 | 新增 `Device/tplink_wta301` + 板级 dts + base-files | 无（纯新增） | 删块 |

D1 是唯一会波及别人的偏离。我们不做上游提交，但**将来若要上游化**，正确做法是保留 `kmod-qca-nss-dp`
并用 `DEVICE_PACKAGES` 的负号语法（`-kmod-qca-nss-dp`）在我们的 Device 块里摘掉，而不是从 DEFAULT_PACKAGES 全局删。

## 2.85 FIT/ITB 全字段核对（S7 内核 ITB vs 25.12.6 的 `Device/FitImageLzma`）

用 FDT 解析器逐属性读出 S7 `op_kernel_0x480000.bin` 的 ITB 结构：

```
/images/kernel-1   type=kernel arch=arm64 os=linux compression=lzma
                   load=0x41000000 entry=0x41000000   hash-1=crc32
/images/fdt-1      type=flat_dt arch=arm64 compression=none
/configurations   default=config@mp02.1  →  { kernel-1, fdt-1 }
```

25.12.6 的 `target/linux/qualcommax/image/Makefile`：

```make
define Device/FitImageLzma
	KERNEL_SUFFIX := -uImage.itb
	KERNEL = kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(DEVICE_DTS).dtb
	KERNEL_NAME := Image
endef
define Device/Default
	KERNEL_LOADADDR := 0x41000000          ← 与 S7 一致
	DEVICE_DTS_CONFIG := config@1          ← 我们覆盖成 config@mp02.1（与 S7 一致）
```

⇒ `load/entry 0x41000000`、`compression=lzma`、`config@mp02.1` 三个量**逐项对上**，
产物文件名是 `<...>-uImage.itb`（P3 从这里取 kernel）。

## 3. 构建阶段要盯的量（P2.4–P2.6）

| 项 | 判据 | 怎么查 |
|---|---|---|
| P2.4 内核体积 | ≤ `0x740000` (7424 KiB)，否则撞 rootfs@0x4fc0000 | `ls -l bin/targets/qualcommax/ipq50xx/*-fit*.itb`；超限时 `Build/check-size` 会**静默删除**产物 |
| P2.5 vermagic | 所有 kmod 与内核一致 | `strings` 比对 `vermagic=` |
| P2.6 ath11k/dsa 符号 | `ath11k_ahb`、`rtl8365mb`、`dwmac-ipq5018`(内建)、`pcs-qca-uniphy`(内建) 齐全 | `ls kmod/*.ko`、`grep -i stmmac .config` |
| DTS 编译 | 无 `&gmac1` / `uniphy0` undefined 报错 | 构建日志 |

---

## 4. 未验证项（诚实登记）

| 项 | 级别 | 说明 |
|---|---|---|
| `dwmac-ipq5018.c` / `pcs-qca-uniphy.c`（来自 6.18 树）能否在 6.12.112 编译 | 🟠 R15 | 依赖 API：`pcs_inband_caps`(backport-6.12/601-09 已有)、`fwnode_pcs`(pending-6.12/737-*已有)。首次编译即知 |
| 6.12 的 stmmac + PCS 组合在 SGMII/1G 上是否与 6.18 同行为 | 🟠 R15 | 只能真机验（P4） |
| `coherent_pool=2M` 是否足够 6.12 ath11k | 🟡 | S7 用 512K 成功，但那走 `request_firmware_into_buf`；2M 是保守取法 |
| RTL8367S 在 25.12.6 的 rtl8365mb 驱动版本下 5 口全 probe | 🟡 | DSA 驱动同名同源，风险低 |

---

## 5. ★ 离线 DTS 验证结果（不等构建，先验）

用 cpp + dtc（`-I` 指向 6.18.55 的 dt-bindings，dtsi 用已套完全部补丁的 6.12 版本）先编一遍板级 DTS：

```
cpp OK → 1921 行；dtc OK → 25,918 B（S7 实跑 DTB 25,978 B）
4 个 warning，全是上游 dtsi 自带（qfprom 重复 unit-address、mdio 无 ranges）
```

再和 `pin/s7-actual-dtb.dtb` 做全树对比（`tools/fdtdiff.py`）：

| 指标 | 结果 |
|---|---|
| 节点总数 | **174 = 174**（修完 A6 之后；修之前是 175 vs 174） |
| 只在我们的：| `usb@8af8800` 包装节点 + 其子节点 —— 6.12 与 6.18 的 USB 节点组织不同，两者都 `disabled` |
| 只在 S7 的：| `phy@5d000`（`qcom,ipq5018-uniphy-usb3-phy`，`disabled`）—— 6.12 的 dtsi 还没这个节点；USB 关闭，无害 |
| 属性差异 | 49 处，**全部**是 phandle 重新编号（0x22 vs 0xb 之类）或 gcc 时钟表条数不同 |
| `status okay` 3 处 | `crypto` / `cryptobam` / `watchdog`：我们显式写，S7 是 6.18 dtsi 默认开 ⇒ 等价 |
| 分区表 / bootargs / wifi / memory / nand-ecc | **零差异** |

⇒ 板级 DTB 已与 S7 运行态结构等价，剩余差异全部可解释。
