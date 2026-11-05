# R17：RTL8367S SerDes（SGMII/HSGMII）支持 —— 直接搬 S7 驱动

> 状态：**已定位，修法已定，编译验证中**
> 关联：`docs/P4-FIRST-BOOT-RESULT.md` 问题 B

## 1. 症状（真机实测）

```
rtl8365mb-mdio 90000.mdio-1:1d: found an RTL8367S switch
rtl8365mb-mdio 90000.mdio-1:1d: missing child interrupt-controller node
rtl8365mb-mdio 90000.mdio-1:1d: no interrupt support
rtl8365mb-mdio 90000.mdio-1:1d: phylink: error: empty supported_interfaces
error creating PHYLINK: -22
rtl8365mb-mdio 90000.mdio-1:1d: error -EINVAL: unable to register switch
rtl8365mb-mdio 90000.mdio-1:1d: probe with driver rtl8365mb-mdio failed with error -22
```

结果：DSA 交换机注册失败 ⇒ 没有 lan1..lan5（只有 `eth0`，且 `eth0` 只能 bring up 到
`Link is Up - 1Gbps/Full`，但**不通**——因为 MAC 侧对端是没被配置的交换机 port6）。

## 2. 根因（外部实证 + 本地代码双证）

`rtl8365mb_phylink_get_caps()` 只对 **RGMII** 置位：

```c
if (extint->supported_interfaces & RTL8365MB_PHY_INTERFACE_MODE_RGMII)
        phy_interface_set_rgmii(config->supported_interfaces);
```

而 RTL8367S 的 extint 6（port6）只有 **SGMII | HSGMII**：

```c
{ .name = "RTL8367S", .chip_id = 0x6367, .chip_ver = 0x00A0,
  .extints = { { 6, 1, PHY_INTF(SGMII) | PHY_INTF(HSGMII) }, ... } },
```

⇒ 我们的 CPU 口 `port@6 phy-mode="sgmii"` 拿不到任何 supported_interface
⇒ `phylink_create()` 返回 `-EINVAL`（`drivers/net/phy/phylink.c` 里
`phy_interface_empty(config->supported_interfaces)` 那个检查）

`[外部实证]` 上游 OpenWrt PR #19187（Mercusys MR85X，同为 RTL8367S→IPQ5018）记录**完全相同**的症状，
维护者（Luiz Angelo Daros de Luca / dangowrt）确认：*"The driver is not responsible to warn if a mode is
supported or not: just to list what it supports (get_caps)... At this moment, no other dev has a device,
like MR85X, to implement the HSGMII/SGMII interface."*
URL: https://github.com/openwrt/openwrt/pull/19187

`[外部实证]` c127.dev 的 MR80X v2.20 逆向文章记录了同一失败链路（`empty supported_interfaces` →
`error creating PHYLINK: -22` → DSA setup abort），并给出上游补丁系列（v6 已合并）。
URL: https://www.c127.dev/posts/rtl8367s-sgmii-mr80x-v2-20/
其中关键一句：*"a Tested-by from Stanisław Pal, who ran the series on a TP-Link Archer AX55 v1: an
RTL8367S with the SerDes on external interface 1 running HSGMII to an IPQ5018, on OpenWrt's 6.12 kernel,
**needing only the `neg_mode` parameter dropped from `pcs_get_state()` for the older phylink API there**"*
⇒ 6.12 的移植成本 = 1 处函数签名。

## 3. 决定性证据：S7 用的是打了 SerDes 补丁的驱动

`[本板实证]` S7 rootfs 里的 `lib/modules/6.18.55/rtl8365mb.ko`（50,488 B）含这些字符串：

```
failed to force SerDes link: %pe
failed to force SerDes pause modes on port %d: %pe
failed to probe SerDes chip option: %pe
unsupported SerDes speed %s
unsupported SerDes tuning variant (chip option 0), disabling SerDes interface modes
```

而 25.12.6 的 `linux-6.12.112/drivers/net/dsa/realtek/rtl8365mb.c`（2222 行）和
`/root/kb/linux-6.18.55/.../rtl8365mb.c`（同样 2222 行、**逐行相同**）都**没有** SerDes 代码。

⇒ S7 能跑通 lan1-5，是因为它用的是 **OpenWrt backport 6.18 的 943/777/778 补丁系列**之后的
`drivers/net/dsa/realtek/` 目录（`rtl8365mb_main.c` + `_table` + `_vlan` + `_l2` 四文件拆分版），
不是上游原版单文件。

`[本板实证]` S7 dmesg 印证交换机真的工作了：
```
rtl8365mb-mdio 90000.mdio-1:1d: configuring for fixed/sgmii link mode
rtl8365mb-mdio 90000.mdio-1:1d: Link is Up - 1Gbps/Full - flow control off
rtl8365mb-mdio 90000.mdio-1:1d lan1 (uninitialized): PHY [...:user_mii:00] driver [RTL8365MB-VC Gigabit Ethernet]
...lan2 lan3 lan4 lan5 同
[39.8] lan1: Link is Up - 100Mbps/Full - flow control rx/tx
```

## 4. 修法：**直接搬 S7 那份驱动**（不是自己移植补丁）

理由是 AGENTS §2.2「未在真机验证过的组件不得叠加进实验」：S7 这套 11 个文件是
**这块板上已经跑通过 lan1-5 的**，而上游补丁需要移植到 6.12（943-01 就 511 行新增）且无人在这块板验证过。

搬运清单（`/root/kf/linux-6.18.55/drivers/net/dsa/realtek/` → 6.12 树）：

| 文件 | 说明 |
|---|---|
| `rtl8365mb_main.c` | 107,084 B，核心（替换原 67,018 B 单文件 `rtl8365mb.c`） |
| `rtl8365mb_table.c` / `.h` | 表访问 |
| `rtl8365mb_vlan.c` / `.h` | VLAN |
| `rtl8365mb_l2.c` / `.h` | L2 LUT（family D） |
| `realtek.h` | 共享头（6,386 B vs 4,448 B） |
| `rtl83xx.c` / `.h` | 总线层（23,136 B vs 8,314 B） |
| `Makefile` / `Kconfig` | 四文件拆分后的构建规则 |

**唯一需要的 API 适配（实测编译报出，且与上游文章一致）**：

```c
/* 6.18 */  static void rtl8365mb_pcs_get_state(struct phylink_pcs *pcs,
                                               unsigned int neg_mode,
                                               struct phylink_link_state *state)
/* 6.12 */  static void rtl8365mb_pcs_get_state(struct phylink_pcs *pcs,
                                               struct phylink_link_state *state)
```

依据：`include/linux/phylink.h` 里 6.12 的 `struct phylink_pcs_ops`：
`pcs_config` 和 `pcs_link_up` **有** `neg_mode`，`pcs_get_state` **没有**。
函数体内未使用 `neg_mode`，所以只改签名即可。

已收进仓库：`files/drivers/net/dsa/realtek/`（10 个 .c/.h，已含上述适配）。

## 5. 板级差异表（AGENTS §0.2 要求）

| 项 | S7（6.18.55） | 本板（6.12.112） | 同/不同 | 处置 |
|---|---|---|---|---|
| 交换机型号 | RTL8367S `0x6367` ver `0x00a0` | 同（真机 `found an RTL8367S switch`） | **同** | 无需改 |
| MDIO 总线 / 地址 | `mdio1` @ `0x1d` | 同 | **同** | 无需改 |
| CPU 口 | port6，`phy-mode="sgmii"`，fixed-link 1000 | 同 | **同** | 无需改 |
| 面板口 | port0-4 = lan1-5，各 `phy-handle` 指向内置 PHY | 同 | **同** | 无需改 |
| `mdio` 子节 compatible | 无（S7） | `realtek,smi-mdio`（我们多写） | 不同 | 需确认是否影响；S7 没有该属性也能工作，先保持 |
| 内核版本 | 6.18.55 | 6.12.112 | 不同 | `pcs_get_state` 签名差异 |
| 驱动来源 | OpenWrt backport 6.18（943/777/778 后状态） | 上游 6.12 原版 | 不同 | **搬 S7 的** |

## 6. 待验证

- [ ] 完整 `target/linux/compile` 通过（编译中）
- [ ] 真机：`rtl8365mb-mdio ... configuring for fixed/sgmii link mode` + `Link is Up` + `lan1..lan5` 出现
- [ ] lan1-5 全部进 `br-lan`
- [ ] 有线连通（ping 网关）
