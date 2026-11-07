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

## 2.95 7 个补丁的上下文冲突预判（离线查同文件竞争者）

| 我们的补丁 | 改的文件 | 25.12.6 里同文件的其它补丁 | 判断 |
|---|---|---|---|
| 0920 | `Documentation/…/ethernet-phy.yaml` | **无** | 干净 |
| 0921 | `ipq5018.dtsi`(ge_phy rx/tx clocks) | 102 个（p2dry 已全量实测通过） | 干净 |
| 0922 | `drivers/net/phy/qcom/at803x.c` | `0057`(Qualcomm IPQ5018 PHY 支持，**我们依赖它先应用**)、`backport-6.12/720-09`(constify mdio_device_id) | 0922 排在 0057 之后，上下文就是含 0057 的树 ⇒ 预期干净；720-09 只动 id 表，与时钟管理无关 |
| 0923 | `ipq5018.dtsi`(uniphy0) | 同上，p2dry 实测通过 | 干净 |
| 0924 | `stmmac_main.c` + `include/linux/stmmac.h` | **无** | 干净（文件是 virgin） |
| 0925 | `drivers/net/pcs/{Kconfig,Makefile}` | 无 | 干净 |
| 0926 | `stmmac/{Kconfig,Makefile}` | 无 | 干净 |

⇒ 唯一有理论风险的只有 0922（竞品是 backport 里的机械改动），其余 6 个都是干净应用面。

## 2.99 第一次构建的实际结果（2026-11-05）

| 阶段 | 结果 |
|---|---|
| tools/* | ✅ 全部过（`FORCE_UNSAFE_CONFIGURE=1` 之后） |
| toolchain: gcc initial / kernel-headers / musl / gcc final / gdb / fortify-headers | ✅ 全部过（`toolchain-aarch64_cortex-a53_gcc-14.3.0_musl` 就绪） |
| target/linux | ❌ → 已修，见下 |

**失败原因不是补丁，是 Kconfig 少一个 NEW 符号**：

```
Qualcomm ETHQOS support (DWMAC_QCOM_ETHQOS) [Y/n/m/?] (NEW) make[7]: *** scripts/kconfig/Makefile:85: syncconfig Error 1
```

`CONFIG_STMMAC_ETH=y` 一开，`DWMAC_QCOM_ETHQOS` 就变成新符号（ipq806x/ETHQOS 用的，不是我们）。
非交互构建里没有答案 ⇒ `syncconfig` 直接失败。**已在 `ipq50xx/config-default` 补一行**
`# CONFIG_DWMAC_QCOM_ETHQOS is not set`（`apply-to-2512.sh` 同步更新），重跑后 `SYNC include/config/auto.conf.cmd` 正常。

**补丁应用（R15 的第一关）已实证通过**——在 `linux-6.12.112` 树里逐个查到：

| 检查项 | 结果 |
|---|---|
| `drivers/net/ethernet/stmicro/stmmac/dwmac-ipq5018.c` | 存在，4,964 B |
| `drivers/net/pcs/pcs-qca-uniphy.c` | 存在，26,045 B |
| `arch/arm64/boot/dts/qcom/ipq5018-gmac.dtsi` | 存在，2,039 B |
| `ipq5018.dtsi` 里的 `uniphy0` | 6 处（0923 生效） |
| `include/linux/stmmac.h` 里的 `get_interfaces` | 1 处（0924 生效） |

⇒ 7 个补丁 + 5 个 files 在其应在的位置，无一被拒。剩下要看的只是**编译**结果。

## 2.999 R15 落地：pcs-qca-uniphy.c 在 6.12 编不过 ⇒ 按 S7 实证关掉它

**错误原文**（`/root/tl3.log`，`target/linux/compile`）：

```
drivers/net/pcs/pcs-qca-uniphy.c:567:9: error: implicit declaration of function 'clk_hw_recalc_rate';
                                          did you mean 'clk_hw_round_rate'?
drivers/net/pcs/pcs-qca-uniphy.c:985:16: error: returning 'struct fwnode_pcs_provider *'
                                          from a function with return type 'int'
```

**查证链**（每条都可复现）：

1. `clk_hw_recalc_rate` 在 **6.12.112 没有**，在 **6.18.55 也没有**（`grep -rln` 全树：只有 pcs-qca-uniphy.c 自己引用）。
2. 我们的 `pcs-qca-uniphy.c` = 上游 `16ac5736c178…` 原版（26,045 B，md5 `d4918287…`，与 GitHub raw 下载逐字节一致）。
3. 25.12.6 的 5 个 ipq50xx profile 走 ESS+NSS-DP，**从不打开 `CONFIG_PCS_QCA_UNIPHY`，这个文件在上游是死代码**——所以没人发现它编不过。
4. **S7 实跑日志（`work/evidence/V3-boot.log`）证明本板不需要它**：
   ```
   ipq5018-gmac-dwmac 39d00000.ethernet: Ring mode enabled
   rtl8365mb-mdio 90000.mdio-1:1d: configuring for fixed/sgmii link mode
   rtl8365mb-mdio 90000.mdio-1:1d: Link is Up - 1Gbps/Full - flow control off
   ```
   全文无 uniphy/PCS 字样；S7 的 `.config` 里 `CONFIG_FWNODE_PCS=y` / `CONFIG_PCS_XPCS=y`，
   但 `drivers/net/pcs/*.o` 里**没有** `pcs-qca-uniphy.o`，`System.map` 里**没有** `qca_uniphy` 符号。
5. `dwmac-ipq5018.c` 对缺失 PCS 是**优雅降级**：`pcs = fwnode_pcs_get(...); if (!pcs) return 0; ... -ENOENT → return 0;`
   ⇒ 没有 PCS 就走 `fixed-link`，与 S7 的行为逐条一致。

**动作**：`ipq50xx/config-default` 改成 `# CONFIG_PCS_QCA_UNIPHY is not set`（原来误设为 =y）。
DTS 里的 `pcs-handle = <&uniphy0>` 与 `uniphy0` 节点**保持**（与 S7 的 DTB 逐字一致，只是 provider 不注册）。

**为什么不是「把驱动移植到 6.12」**：
- 单变量原则——S7 在这块板子上验证过的就是「无 PCS + fixed-link」，移植版是**未验证组件**（AGENTS §2.2 明令禁止叠加）
- 上游这份文件本身是坏的，移植等于替上游修 bug，风险与收益不成比例
- 若将来真要走 SGMII 自协商（而非 fixed-link），再单独做 PCS 移植，并单独验证

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

## 7. feeds 现状（决定第一版包集）

`/root/ow2512/feeds/` 只有 **`base`** 一个 feed。`luci` / `packages` / `routing` / `telephony` 都没安装
⇒ 本 build 出 149 包、**无 LuCI**，这是**第一版故意的**（P4 单一变量：只验启动/有线/Wi-Fi 射频，
不把 Web UI 的 30+ 依赖混进首次真机验证）。

P5 补包集的准确动作（未执行）：
```bash
cd /root/ow2512 && ./scripts/feeds update -a && ./scripts/feeds install -a
# 然后 echo 目标包进 .config 再 make -j8（增量，只需编 luci 一族）
```
已确认 `package/system/zram-swap` 在 core 里（不需要 feeds）；`cgi-io`/`kmod-zram` 来自 `packages` feed，
`luci*` 来自 `luci` feed，三者都要等 `feeds update` 之后才可见。

## 8. 构建收尾结果（2026-11-05 05:08，全部 EXIT=0）

| 阶段 | 结果 |
|---|---|
| `target/linux/compile` | **EXIT=0**（vmlinux 75,204,472 B；`dwmac-ipq5018.o` 32,280 B） |
| `make -j8` world | **EXIT=0**，147 包 |
| 产物 | `...tplink_wta301-squashfs-sysupgrade.bin` 12,534,037 B；`...initramfs-uImage.itb` 12,229,176 B |
| 包内 kernel(ITB) | 4,276,536 B ≤ 0x740000 ✓ |
| 包内 root(squashfs4) | 8,244,224 B ≤ 0xbc0000 ✓（余量 4,338,688 B ≈ 4.1 MB，够放 LuCI） |

**镜像内已核实（不是"应该"）**：
- `/etc/board.d/90_wta301` 3,310 B ✓
- `/etc/hotplug.d/firmware/12-wta301-caldata` 4,586 B ✓
- `lib/firmware/ath11k/IPQ5018/hw1.0/board-2.bin` = `78f5b21b2cd1dee8fb6155e1f74a1073`（与 S7 `lib/` 逐字节一致）
- `lib/firmware/ath11k/QCN6122/hw1.0/board-2.bin` = `e4904f1326df5edfd7842b319e0828da`（同上）
- 关键包：`kmod-dsa-rtl8365mb` `kmod-ath11k 6.12.112.6.18.55-r2` `ath11k-firmware-ipq5018-qcn6122` `uboot-envtools` `fstools` ✓

**注意**：包里**没有** `kmod-qca-nss-dp`（按 R14 已从 DEFAULT_PACKAGES 移除）⇒ 纯 CPU 转发。
