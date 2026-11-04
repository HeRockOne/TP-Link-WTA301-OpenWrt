# M06 时钟 / PLL / UNIPHY　（含 ★ P0 阻断项：以太网栈在 25.12.6 上不存在，已解）

**结论三句话：**
1. 时钟树在 25.12.6 上**已经完全够用**（102 个上游补丁套完，clocks 块与 S7 的 6.18.55 逐字一致）。
2. `uniphy0` 不只是以太网 PCS，它还是 gcc 两条 uniphy rx/tx 时钟的**提供者**，必须存在。
3. **25.12.6 的 ipq50xx 根本没有主线以太网栈**（走 QSDK ESS+NSS-DP），而 openwrt/qca-ssdk
   不支持 RTL8367S ⇒ 不补就只有「无有线」。补齐方案已找到并验证可用（上游 6.12 时代的同一批补丁）。

---

## 1. 时钟树三方对照

### 1.1 S7（6.18.55 上游 dtsi）的 clocks 块

```dts
clocks {
    gephy_rx_clk: gephy-rx-clk { compatible = "fixed-clock"; clock-frequency = <125000000>; };
    gephy_tx_clk: gephy-tx-clk { compatible = "fixed-clock"; clock-frequency = <125000000>; };

    ref_96mhz_clk: ref-96mhz-clk {
        compatible = "fixed-factor-clock";
        clocks = <&xo_clk>;  clock-div = <1>;  clock-mult = <2>;      /* 48M ×2 = 96M */
    };

    sleep_clk: sleep-clk { compatible = "fixed-clock"; };             /* ★ 无 clock-frequency */

    xo_board_clk: xo-board-clk {
        compatible = "fixed-factor-clock";
        clocks = <&ref_96mhz_clk>;                                   /* 96M，1:1 */
    };

    xo_clk: xo-clk { compatible = "fixed-clock"; clock-frequency = <48000000>; };
};
```

### 1.2 25.12.6 + 全部 qualify 补丁（实测套完后）的 clocks 块

**与上面逐字相同** —— 已用脚本验证（见 §5）。来源拆分：

| 时钟 | 谁提供（25.12.6） |
|---|---|
| `gephy_rx_clk` / `gephy_tx_clk` 125 MHz | 补丁 **0059**（Add GE PHY to internal mdio bus）—— 25.12.6 已有 ✅ |
| `ref_96mhz_clk`（48M×2） | 补丁 **0069**（Add CMN-PLL node 时顺带）—— 已有 ✅ |
| `xo_board_clk` 改为 fixed-factor 取 `ref_96mhz_clk` | 补丁 **0070** —— 已有 ✅ |
| `xo_clk` 48 MHz | 0069 —— 已有 ✅ |
| `a53pll` / `apcs_glb` / `gcc` / 定时器 | 6.12 dtsi 原生 ✅ |
| `cmn_pll` | 补丁 **0069**（节点）+ **0068**（驱动）+ **0818**（频率修正）—— 已有 ✅ |
| `uniphy0`（PCS + 时钟提供者） | 补丁 **0842** —— ❗ **25.12.6 缺，已补** |

### 1.3 `IPQ5018_ETH_50MHZ_CLK` 与 gcc 的名称引用

`uniphy0` 的 `clocks` 里第 5 项是 `<&cmn_pll IPQ5018_ETH_50MHZ_CLK>`（50 MHz 以太网参考）。
gcc 侧的两条 uniphy 时钟**按名字**引用 uniphy0：

| 补丁 | 作用 | 25.12.6 |
|---|---|---|
| 0721 | gcc-ipq5018 去掉不支持的 clk 组合 | ✅ 有 |
| 0722 | gcc 的 uniphy rx/tx **按 provider 名字**引用 | ✅ 有 |
| 0723 | 修 uniphy **软复位**问题 | ✅ 有 |

⇒ 25.12.6 的 gcc 驱动已经准备好接收 uniphy0，只是 dtsi 里没有 uniphy0 节点。补上 0842 即闭环。

---

## 2. ★ 纠正一处我自己的误读：CMN PLL 是 **4.8 GHz**，不是 505 MHz

S7 反编译里 gcc 之外的 `clock-controller@9b000` 有个属性：

```
assigned-clock-rates-u64 = <0x01 0x1e1a3000>;
```

我早先按 32 位读成 `0x1e1a3000` = 505 MHz —— **错**。u64 在 DTB 里是两个大端 u32：

```
0x00000001 0x1e1a3000  →  0x1_1E1A3000 = 4,800,000,000 = 4.8 GHz
```

补丁 **0818** 的 commit message 原文（25.12.6 已有）确认：
> In IPQ5018, the reference clock to the CMN PLL block from the on-board Wi-Fi has its divider set to 2.
> …correct the assigned clock rate to **4.8GHz**. （原来是 9.6 GHz）

⇒ 这条纯 SoC 级，板级无需改动。

---

## 3. `uniphy0` = 以太网 PCS + 时钟提供者

补丁 0842 加的节点（25.12.6 需补）：

```dts
uniphy0: ethernet-pcs@98000 {
    compatible = "qualcomm,ipq5018-uniphy";
    reg = <0x00098000 0x800>;
    #clock-cells = <1>;
    clocks = <&gcc GCC_UNIPHY_AHB_CLK>,
             <&gcc GCC_UNIPHY_SYS_CLK>,
             <&gcc GCC_UNIPHY_RX_CLK>,
             <&gcc GCC_UNIPHY_TX_CLK>,
             <&cmn_pll IPQ5018_ETH_50MHZ_CLK>;
    clock-names = "ahb", "sys", "port5_rx", "port5_tx", "ref";
    clock-output-names = "uniphy0_gcc_rx_clk", "uniphy0_gcc_tx_clk", "uniphy0_ref_clk";
    resets = <&gcc GCC_UNIPHY_SOFT_RESET>;
    reset-names = "soft";
    #pcs-cells = <0>;
    status = "disabled";
};
```

并且把 gcc 节点的最后两项时钟从 `<0>, <0>` 改成 `<&uniphy0 UNIPHY_CLK_RX>, <&uniphy0 UNIPHY_CLK_TX>`。

与 S7 反编译的 `ethernet-pcs@98000` 对齐结果：

| 属性 | S7 实际 DTB | 25.12.6+0842 | 一致？ |
|---|---|---|---|
| compatible | `qualcomm,ipq5018-uniphy` | 同 | ✅ |
| reg | `0x98000 0x800` | 同 | ✅ |
| #clock-cells / #pcs-cells | `1` / `0` | 同 | ✅ |
| clock-names | `ahb sys port5_rx port5_tx ref` | 同 | ✅ |
| clock-output-names | 三个 | 同 | ✅ |
| resets / reset-names | `soft` | 同 | ✅ |

**唯一差异**：S7 的 DTB 里该节点多了板级的三行
```dts
assigned-clocks = <&uniphy0 2>;        /* index 2 = uniphy0_ref_clk */
assigned-clock-rates = <25000000>;     /* 25 MHz */
status = "okay";
```
⇒ 这三行属于**板级 DTS**（P2 写进去），不是 dtsi。

---

## 4. ★★ P0 阻断项：25.12.6 的 ipq50xx 没有主线以太网栈

### 4.1 证据（全部本地可复现）

**① 25.12.6 的以太网是 QSDK ESS + NSS-DP，不是 stmmac/DSA**

`target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-ess.dtsi`（25.12.6 实际文件）：
```dts
switch: ess-switch@39c00000 { compatible = "qcom,ess-switch-ipq50xx"; ... };
ess-uniphy@98000 { compatible = "qcom,ess-uniphy"; };
dp1: dp1 { compatible = "qcom,nss-dp"; reg = <0x39C00000 0x10000>; };
dp2: dp2 { compatible = "qcom,nss-dp"; reg = <0x39D00000 0x10000>; };
```
`target/linux/qualcommax/ipq50xx/config-default`（25.12.6 实际文件）：没有 `STMMAC_ETH` /
`STMMAC_PLATFORM` / `DWMAC_IPQ5018`；有 `NET_DSA_QCA8K`、`MAXLINEAR_GPHY`、`QCA83XX_PHY`。
`target/linux/qualcommax/Makefile` 的 `DEFAULT_PACKAGES` 里带 `kmod-qca-nss-dp`。

**② 全树 grep 不到任何主线以太网符号**
```
grep -rln "ipq5018-gmac|pcs-qca-uniphy|dwmac-ipq5018" 25.12.6/target/  → 空
```

**③ 5 个 ipq50xx 板级 DTS 全是 ess 写法**（`grep -ln "gmac|ethernet@" ipq5018-*.dts` → 空）

**④ SSDK 不支持 Realtek**
`openwrt/qca-ssdk` @ `446db12b`（PKG_SOURCE_VERSION 原文）= **953 个文件，0 个**匹配
`rtl|realtek|8367|8369`（GitHub tree API 全量拉取核对）。

⇒ **SSDK 路径无法驱动本板的 RTL8367S。**

### 4.2 为什么 S7 有、25.12.6 没有

| 事件 | 日期 | 出处 |
|---|---|---|
| OpenWrt **25.12.0 发布**（分支起点） | 2026-03-03 | 已知 |
| 上游 `qualcommax: ipq50xx: convert to UNIPHY PCS and DWMAC stack` | author 2026-05-05 / fork 提交 2026-07-05 | commit `16ac5736c178c36d4cb7ae0f791f8bd2a5af095a` |
| **S7 snapshot r37669 构建** | 2026-10-25（6.18.55） | 板上实测 |

⇒ 迁移方向其实是**内核回退**：snapshot(6.18.55，已切主线) → 25.12.6(6.12.112，尚未切)。
这也是本模块把「完美迁移」从"照抄上游板级 DTS"变成"补一小批上游补丁"的原因。

### 4.3 ★ 关键好消息：上游做过 6.12 版的同一批补丁

那个 conversion commit 改的文件里包含 `patches-6.12/0722-…` 与 `patches-6.12/0912-…`
⇒ **切换发生时，上游树还是 6.12**。所以 6.12 可用的版本在上游历史里存在：

| 补丁（父提交 `763d32b8d0a816e9a55de6464958b8d5597f66b3` 的 `patches-6.12/`） | 25.12.6 状态 |
|---|---|
| `0740-01-dt-bindings-net-ethernet-phy-increase-max-clock-count-to-two.patch` | ❗ 缺 |
| `0740-03-arm64-qcom-ipq5018-add-gephy-rx-and-tx-clocks.patch` | ❗ 缺 |
| `0740-04-net-phy-at803x-add-rx-and-tx-clock-management-for-ipq5018-phy.patch` | ❗ 缺 |
| `0842-arm64-dts-qcom-ipq5018-add-uniphy-node.patch` | ❗ 缺 |
| `0843-net-stmmac-add-get_interfaces-platform-method.patch` | ❗ 缺 |
| `0951-net-pcs-add-uniphy-pcs.patch`（Kconfig/Makefile 钩子） | ❗ 缺 |
| `0954-net-stmmac-Introduce-Qualcomm-IPQ5018-DWMAC-driver.patch`（Kconfig/Makefile 钩子） | ❗ 缺 |
| 0715 / 0721 / 0722 / 0723 | ✅ 已有 |
| 0048 / 0056 / 0057 / 0058 / 0059 / 0067 / 0068 / 0069 / 0070 / 0189 / 0816 / 0817 / 0818 | ✅ 已有 |

> `0951`/`0954` 只加 Kconfig + Makefile 一行，驱动本体不在补丁里，而在上游的
> `target/linux/qualcommax/files/`（OpenWrt 的 files/ 机制会把它们拷进内核树）：
> ```
> files/drivers/net/ethernet/stmicro/stmmac/dwmac-ipq5018.c     4,964 B
> files/drivers/net/pcs/pcs-qca-uniphy.c                       26,045 B
> files/include/linux/pcs/pcs-qca-uniphy.h                      4,581 B
> files/include/dt-bindings/net/qca-uniphy.h                      329 B
> files/include/dt-bindings/net/qcom,ipq5018-gmac.yaml          3,393 B
> ```

### 4.4 前置 API：25.12.6 已经具备

`pcs-qca-uniphy.c` 依赖 PCS-provider（fwnode）框架与 phylink 新 API。
25.12.6 的 `target/linux/generic/pending-6.12/` 里**恰好有一整套**：

```
737-01-net-phylink-keep-and-use-MAC-supported_interfaces-in.patch
737-02-net-phylink-introduce-internal-phylink-PCS-handling.patch
737-03-net-pcs-implement-Firmware-node-support-for-PCS-driv.patch
737-04-net-phylink-save-phylink-instance-fwnode-on-phylink_.patch
737-05-net-phylink-support-PCS-provider-release.patch
737-06-net-phylink-support-late-PCS-provider-attach.patch
737-07-net-phylink-add-.pcs_link_down-PCS-OP.patch
```
`target/linux/generic/config-6.12:2169` = `# CONFIG_FWNODE_PCS is not set`（符号存在，只是没开）。
`generic/backport-6.12` 还有 `601-09-v6.14-net-phylink-add-pcs_inband_caps-method.patch` 等。

⇒ 驱动所需的全部内核 API 都在 25.12.6 里，**不是猜的**。

---

## 5. ★★ 实测验证：补丁序列在 6.12.112 上能不能套

做法（脚本 `p2dry`，可复现）：取 `v6.12.112` 原始 `arch/arm64/boot/dts/qcom/ipq5018.dtsi`（399 行），
按序号把 25.12.6 的 `patches-6.12/*.patch` 全部 `git apply --include='*ipq5018.dtsi'`，
再套我们新增的 4 个 dtsi 相关补丁。

**结果：**

| 项 | 结果 |
|---|---|
| 25.12.6 上游补丁应用 | **102 个，成功 102，失败 0** |
| 新增补丁 0842（改 dtsi） | ✅ 干净应用 |
| 最终行数 | **1,210** |
| 与 6.18.55 上游 dtsi 的节点/compatible 集合对比 | **无缺失**（diff `>` 方向为空） |
| clocks 块 | 逐字一致 |
| `uniphy0` 节点 | 与 S7 实际 DTB 的 7 个关键属性全一致 |

⇒ **SoC 级 DTB 在 25.12.6 + 这 7 个补丁下与 S7 等价**。这是「完美迁移」在 dtsi 层的硬证据。

残留差异（全部已知、无害，逐条记录）：

| 差异 | 说明 |
|---|---|
| `mdio0 compatible` 多一个 `qcom,ipq40xx-mdio` 兜底 | 25.12.6 的 0715；6.18 上游已去掉兜底，两者都能 probe |
| `tsens compatible` 无 `qcom,tsens-v1` 兜底 | 25.12.6 的 0180 主动删掉（驱动已正确 probe） |
| `opp-800000000` / `opp-1008000000` CPU OPP 表 | 25.12.6 的 0912 去掉 cpufreq scaling；不影响功能 |
| `tz_apps@4a400000`(4MiB) / `q6_region` / `uniphy0` 在 6.18.55 **原版** dtsi 里没有 | 6.18 上游把它们分散到别处；我们要的就是 6.12 版这几个节点（M07 已裁决 `tz` 必须 4 MiB） |

---

## 6. 需要的 config / target 变更（逐行，来自上游 conversion commit）

`target/linux/qualcommax/ipq50xx/config-default` 追加：
```
# CONFIG_DWMAC_GENERIC is not set
CONFIG_DWMAC_IPQ5018=y
CONFIG_PCS_XPCS=y
CONFIG_STMMAC_ETH=y
CONFIG_STMMAC_PLATFORM=y
```
`target/linux/qualcommax/ipq50xx/target.mk` 删除：
```
DEFAULT_PACKAGES += kmod-qca-nss-dp
```
（同时 `package/kernel/qca-ssdk` / `qca-nss-dp` 对本板不再安装）

---

## 7. 迁移动作清单（M06）

| # | 动作 | 状态 |
|---|---|---|
| 1 | 抄入 7 个补丁到 `patches/kernel-6.12/` | ✅ 已做 |
| 2 | 抄入 5 个驱动/头文件到 `files/` | ✅ 已做 |
| 3 | 交付到 25.12.6 树的 `target/linux/qualcommax/`（P2） | ⬜ |
| 4 | 追加 5 行 config、删 `kmod-qca-nss-dp`（P2） | ⬜ |
| 5 | 板级 DTS 写 `uniphy0 { status="okay"; assigned-clocks=<&uniphy0 2>; assigned-clock-rates=<25000000>; }` | ⬜ P2 |
| 6 | 板级 DTS 写 `&gmac1 { status="okay"; phy-mode="sgmii"; pcs-handle=<&uniphy0>; fixed-link{1000,full} }`、`&gmac0 disabled` | ⬜ P2（M03 已定） |
| 7 | 板级 DTS 写 `&mdio1 { status="okay" }` + RTL8367S 子节点（M03 已定） | ⬜ P2 |
| 8 | 时钟类不做任何板级改动（SoC 级全由 dtsi/补丁提供） | ✅ 结论 |

---

## 8. P2/P4 验证判据

| # | 检查 | 通过判据 |
|---|---|---|
| 1 | `make target/linux/prepare` | 7 个补丁全部应用，无 fuzz 警告 |
| 2 | 编译 | `dwmac-ipq5018.ko`、`pcs-qca-uniphy.ko` 产出，无编译错误 |
| 3 | `vmlinux` 符号 | 含 `ipq5018_gmac_probe`、`ipq5018_uniphy_pcs_create` |
| 4 | `dmesg` | `uniphy` / `ipq5018-gmac` probe 成功；`mdio_bus 90000.mdio-1:1d` 存在 |
| 5 | `ip -br link` | `eth0`（gmac1/DSA conduit）+ `lan1..lan5` 出现 |
| 6 | `ethtool eth0` | `Speed: 1000Mb/s`、`Link detected: yes` |
| 7 | `cat /sys/kernel/debug/clk/clk_summary \| grep -E "uniphy\|gmac"` | 速率非 0，25 MHz ref 就位 |

---

## 9. 未验证项（诚实边界）

1. **`sleep_clk` 没有 `clock-frequency`** —— 两版 dtsi 与 S7 实际 DTB 都一样。watchdog
   (`qcom,kpss-wdt`) 的 `clocks = <&sleep_clk>` 会拿到 0 速率。S7 上 watchdog 表现正常（未专门测），
   但严格说这是**上游遗留的空白**，不是我们引入的。
2. 驱动 `.c` 用的是上游父提交（6.12 时代）的版本，**未与 6.18 版逐行比对**。理由：6.12 版是
   上游针对 6.12 编译验证过的（conversion commit 在 6.12 树上合入）。
3. `pcs-qca-uniphy.c`/`dwmac-ipq5018.c` 在 6.12.112 上**尚未实际编译**（P2 才做）。
4. 2.5G 速率能力：`dwmac-ipq5018.c` 里 `plat_dat->max_speed = 2500`、`MAC_2500FD`。本板
   SGMII 连 RTL8367S 走 `fixed-link 1000`，2.5G 是否真能用**未验证**（M03 遗留项）。
