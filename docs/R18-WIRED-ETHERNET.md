# R18 — 有线不通：三方逐层比对结论（R17 之前的假设已作废）

> 本文取代 `R18-UNIPHY-CLOCKS-EXTERNAL-EVIDENCE.md` 的结论段。
> 原文档的两个结论（①UNIPHY 无驱动是真根因 ②有线不通是 25.12 迁移引入的回归）
> **都已被证伪**，见 §3。保留原文件仅为留痕。

本次唯一变量：**内核版本 6.12.112（25.12.6）vs 6.18.55（S7 r37669）**。
所有其它条件相同：同一块板、同一根网线、同一个 lan1 口、同一份 U-Boot。

---

## 1. 钉死的事实（每条都有本机证据）

| # | 事实 | 证据 |
|---|---|---|
| F1 | **S7 的 Linux 有线是通的** | `work/evidence/xfer3.txt`（S7 控制台 `root@wta301`）：`ping -c 2 192.168.8.100` → `2 packets transmitted, 2 packets received, 0% packet loss` |
| F2 | 我们的 25.12.6 有线不通 | 冷启动实测（`work/evidence/r18-coldboot1.log`）：`ping -c 3 192.168.1.100` → `100% packet loss`；`eth0` rx_packets=0 tx=41 |
| F5 | **`lan1` 的计数器是交换机硬件 MIB，不是软件计数** | rtl8365mb 提供 `.get_stats64`，DSA 用户口的 `/proc/net/dev` 取自交换机 MIB。冷启动 `lan1: rx=172(多播 139) tx=0` 只能说明「线缆/PHY 收到 172 个帧」，**不能**说明交换机把帧交给了 CPU（那是 `eth0 rx`）|
| F6 | CPU 口 SerDes 时钟确实为 0 | 冷启动实测 `gmac1_tx_clk_src=0` / `gcc_uniphy_{ahb,sys,rx,tx}_clk en=0`，而同族 `gmac0_tx_clk_src=125000000`；`/sys/bus/platform/devices/` 有 `98000.ethernet-pcs` 但**无驱动绑定**（只有 `qcom-uniphy-pcie`）|
| F3 | 两边 U-Boot 都成功初始化交换机和 SerDes | u-boot 原文：`rtk_switch_init ret = 0` · `Set RTL8367 SGMII 2.5Gbps` · `rtk_port_macForceLinkExt_set ret = 0` · `rtk_port_sgmiiNway_set ret = 0` |
| F4 | `CONFIG_PCS_QCA_UNIPHY` 在两版 `.config` 里**都是 n** | S7 的 `/root/kf/linux-6.18.55/.config:2598` 也是 `# CONFIG_PCS_QCA_UNIPHY is not set` |

## 2. 三层差异表（只列差异行）

### L2 — DTB（我们 FIT 内 DTB vs S7 实跑 DTB）

方法：从 `work/images/v25.12.6-P6/op_kernel_0x480000.bin` 抽出内嵌 DTB
（偏移 4251176，25,918 B）→ `dtc -I dtb -O dts` → 与 `patches/s7-actual-dtb.dts`
的 `ethernet-switch@1d` 子树规范化后逐行 diff。

| 差异 | 判定 |
|---|---|
| 我们的 mdio 子节点多一行 `compatible = "realtek,smi-mdio"` | **已知无害**（S7 无此属性，上行 SMI 总线由 rtl8365mb 自己驱动） |
| 其余端口/phy-handle/CPU 口/fixed-link/phy-mode **全部相同** | (无差异) |

`&uniphy0 { status = "okay"; assigned-clocks = UNIPHY_CLK_REF; rate = 25 MHz }`
与 S7 实跑 DTB 的 `ethernet-pcs@98000` 逐字段相同（`assigned-clock-rates = 0x17d7840`）。

### L3 — 内核 config 与前缀补丁

| 项 | S7 (6.18.55) | 我们 (6.12.112) | 判定 |
|---|---|---|---|
| `CONFIG_PCS_QCA_UNIPHY` | n | n（本轮改回） | (无差异) |
| `CONFIG_NET_DSA_REALTEK` | m | m | (无差异) |
| `CONFIG_NET_DSA_TAG_RTL8_4` | m | m | (无差异) |
| `patches-6.12/0722`（gmac1 rx/tx clk 父时钟按名解析 `uniphy_gcc_rx/rx`） | 6.18 树为 `.index = DT_UNIPHY_RX_CLK/TX_CLK` | 0722 改成按名 | **未验证**（见 §3.2） |

### L4 — 模块清单

| 项 | S7 | 我们 | 判定 |
|---|---|---|---|
| `rtl8365mb.ko` 大小 / md5 | 50,488 / `67b802fd2b38d9e1e230b201ec1fbd9e` | 49,248 / `0b34c3a217482cfddfb770bcb99b57f1` | 大小差 = 内核版本；**SerDes 字符串两边齐全**（`unsupported SerDes tuning variant` 等 5 条）⇒ 同一份 OpenWrt 四文件 SerDes 驱动 |
| 其余 74 个模块 | — | 差异 8 条全是 crypto 改名 | 已知无害 |

### L5 / L6 — 用户态脚本与 UCI

| 项 | S7 | 我们 | 判定 |
|---|---|---|---|
| `90_wta301` / `12-wta301-caldata` | 无（S7 的 network/wireless 固化在 rootfs） | 有 | **等价**（生成同样的 br-lan + lan1..lan5） |
| `/etc/config/network` | `device br-lan type bridge, ports lan1..lan5` + `lan 192.168.8.1/24` | 由 `90_wta301` 生成同结构（192.168.1.1） | (无差异，仅网段) |
| 交换机初始化脚本 | 无（`grep -ril 'rtl8367\|hsgmii\|sgmii'` 只命中 `stock_fit.bin` 与 `config/network`） | 无 | (无差异) |

### 运行时 dmesg（两轮冷启动逐行 diff，去时间戳）

```text
work/evidence/coldboot-S7-1.log   vs   work/evidence/p6-dmesg-full.log
```

| S7 有 / 我们没有 | 判定 |
|---|---|
| 12 条 `Fixed dependency cycle(s) with /soc@0/ethernet-pcs@98000` | **已知无害**（6.18 fw_devlink 才打印；我们的 DTB 里该节点存在——`qualcomm,ipq5018-uniphy` 与 `uniphy0_gcc_rx_clk` 都能在 P6 kernel 镜像里找到） |
| `pps_core` / `PTP clock support registered` / `arch-timer-mmio` / `br_netfilter` 提示 | 已知无害（config 选择差异，不影响转发） |

| 我们有 / S7 没有 | 判定 |
|---|---|
| `clk: Disabling unused clocks` | **未验证**（6.18 同行文可能不再打印；需 S7 侧 clk_summary 对照） |
| `lan1: Link is Down` / `DSA: tree 0 torn down` / `left promiscuous mode` … | 我的实验痕迹（unbind/bind），非启动差异 |

**以太网栈的 25 条 rtl8365mb/DSA 日志两边逐条相同**，含
`found an RTL8367S switch` · `configuring for fixed/sgmii link mode` ·
`Link is Up - 1Gbps/Full` · `lan1 (uninitialized): PHY [...user_mii:00]` ·
`lan1: Link is Up - 100Mbps/Full`。

## 3. 被证伪的两个旧结论

### 3.1「有线不通是 25.12 迁移引入的回归」—— 错

`work/evidence/xfer3.txt` 证明 S7 的 Linux 有线通（F1）。同时我早前用
`grep "bytes from"` 搜证据目录得出「0 条成功记录」也是方法错误：busybox ping
只在结尾打 `N packets transmitted, N packets received, 0% packet loss`。

### 3.2「UNIPHY 无驱动 ⇒ gmac1 时钟 0 Hz ⇒ 真根因」—— 错（至少不是差异）

本板实测（P6，`/sys/kernel/debug/clk/clk_summary`）：

```
gmac0_tx_clk_src    = 125000000     <- 内部 GEPHY 路径，正常
gmac1_tx_clk_src    = 0             <- SerDes 路径
gcc_uniphy_{ahb,sys,rx,tx}_clk  en=0
```

机制上确实存在：`gcc-ipq5018.c` 里 `gmac1_{rx,tx}_clk_src` 的父时钟是
`<&uniphy0 UNIPHY_CLK_RX/TX>`（`ipq5018.dtsi` gcc 节点 clocks 第 6/7 项）。
`CONFIG_PCS_QCA_UNIPHY=n` 时 uniphy0 没有驱动 ⇒ 没有 clock provider ⇒
该父时钟解析不到 ⇒ `rate=0`，且 `gcc_uniphy_*` 因无消费者被
`clk_disable_unused()` 关掉。

**但这在 S7 上同样成立**：S7 也是 n，且 6.18 树同样引用 `<&uniphy0 …>`
（只是用 `.index` 而不是 0722 的名字），解析不到的结果相同。而 S7 有线通（F1）。
⇒ 该 0 Hz 是**两版共有的报告/门控现象，不是 S7↔我们的差异**。
判定：**未验证但不足以解释差异**；唯一能证实/证伪的动作是跑 S7 内核读同一份
`clk_summary`（见 §5 实验 E1）。

## 4. 仍未排除的候选（按可能性排序）

| 代号 | 候选 | 状态 |
|---|---|---|
| H1 | 之前的"不通"测量被我们自己的实验污染（`vlan_filtering=1`、unbind/bind、br-lan 双 IP…） | **已排除**：2026-11-05 断电冷启动、未改任何配置，E0 仍 `100% packet loss`、`eth0 rx=0` / `lan1 tx=0`（`work/evidence/r18-coldboot1.log`） |
| H2 | 6.18 的 rtl8365mb 四文件 SerDes 驱动在 6.12 DSA 核心下 CPU 口 SerDes 未被正确编程（源码同、核心不同） | 未验证。`net/dsa/switch.c` 的 VLAN/CPU-port 路径两版逐行相同（已比对），嫌疑下降 |
| H3 | 时钟父链：`gmac1_{rx,tx}_clk_src` 父时钟解析不到 ⇒ SGMII 侧无 125 MHz ⇒ CPU 口物理上收发全死 | **当前主嫌**（F6 有硬件证据，与"交换机 MIB 收到 173 帧但 eth0 rx=0"一致）。PCS=y 的实验从未真跑过，见 E4 |

## 5. 板子回来后的实验序列（一次一个变量）

**E0 — 已执行（2026-11-05）**：断电冷启动、未改任何配置：

```
eth0:  rx 0        tx 41
lan1:  rx 172(多播139)  tx 0      # 交换机硬件 MIB
ping -c 3 192.168.1.100 -> 100% packet loss
```

⇒ H1 排除；`lan1 rx` 不能证明"交换机→CPU 通"（它是交换机 MIB，见 F5）。

**E4（下一步，零 flash 写入）**：用 `CONFIG_PCS_QCA_UNIPHY=y` 重编内核，
把生成的 **initramfs ITB** 放 TFTP 根，U-Boot 里 `tftpboot 0x46000000 …; bootm 0x46000000`。
判据（三条，逐条看）：
1. dmesg 出现 `qca-uniphy` probe 成功、`98000.ethernet-pcs` 绑上驱动
2. `clk_summary` 里 `gmac1_tx_clk_src` 从 0 变 125000000、`gcc_uniphy_*` en>0
3. `ping 192.168.1.100` 通、`eth0 rx` 开始涨
三条全成立 ⇒ H3 定案，把它合入正式构建（并同步三处：config-default、apply-to-2512.sh、
`files/pcs-qca-uniphy.c` 的 6.12 补丁，后者已在仓库里）。
若不成立 ⇒ H3 否掉，转 H2。

**E1（区分内核/用户态）** U-Boot 里 `tftpboot 0x44000000 s7k.bin ; bootm 0x44000000`
（S7 内核 + 我们 rootfs；TFTP 根已放 `s7k.bin`）。注意：S7 内核版本与我们的
`rtl8365mb.ko` vermagic 不匹配 ⇒ 该实验只能观察 `clk_summary` 与 gmac 行为，
不适合验证交换机转发。

**E2** 只回退 `0722`（恢复 6.18 的 `.index = DT_UNIPHY_RX_CLK/TX_CLK`），重编内核，
看 `gmac1_tx_clk_src` 是否变 125 MHz、有线是否通。单一变量。

**E3** 用 S7 的 `/etc/config/network` 覆盖（走 overlay，不刷机）：

```sh
cat > /overlay/etc/config/network   # 内容取自 /root/lp/tree/etc/config/network
reboot
```

## 6. 当前仓库状态（本轮对齐）

- `deliver/apply-to-2512.sh`：`CONFIG_PCS_QCA_UNIPHY` 已改回 **`is not set`**，与 S7 基线一致。
- `files/drivers/net/pcs/pcs-qca-uniphy.c`：保留 6.12 可编译补丁
  （`clk_hw_recalc_rate()` → `clk_hw_get_rate()`，两者在 `CLK_GET_RATE_NOCACHE`
  下等价），但**不编译**（config off）。
- 本次唯一变量恢复为「内核版本」。