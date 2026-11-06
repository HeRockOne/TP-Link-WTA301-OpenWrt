# 无线发射功率上限 —— 外部证据与结论

日期：2026-11-06
问题：能不能把无线信号增强到"最强最强那种"，且不烧设备。

**结论：5G 已经到顶（24 dBm 是 BDF 硬限，也正好是芯片 HE80 的额定点）；
2.4G 被中国法规锁在 20 dBm。软件层没有"再强一档"的空间。**

标注：`[外部实证]` 可复核外部原文 · `[上游代码]` 上游源码/规格书 · `[本板实证]` 本机实测 ·
`[推断]` 有推理链未实测

---

## 1. 本板当前实际功率（`[本板实证]`，P24 实测，国码 CN）

| 设置 `txpower` | 实际生效 | 判定 |
|---|---|---|
| 2000 (20 dBm) | **20.00 dBm** | 生效 ⇒ 可写 |
| 2400 / 2450 / 2500 / 2600 / 2700 / 3000 / 3300 | **全部 24.00 dBm** | 撞硬墙 |

`iw phy phy1 info`（country=CN）报的法规上限：

| 频段 | 信道 | 法规上限 | 实际生效 |
|---|---|---|---|
| U-NII-1 | 36 / 40 / 44 / 48 | 30 dBm | 24.00 |
| U-NII-2A | 52–64 | 30 dBm（DFS） | 24.00 |
| U-NII-2C | 100–144 | disabled（CN 不可用） | — |
| **U-NII-3** | **149 / 153 / 157 / 161 / 165** | **33 dBm** | **24.00** |

**⇒ 24 dBm 不是法规限制，是 BDF 校准表里的值。而 BDF 来自本机 ART（逐台出厂校准）。**

### 1.1 换国家码也提不动（决定性实验，`[本板实证]`）

| 国家 | 161 法规上限 | 设 33 dBm 实际 |
|---|---|---|
| AU | 30 dBm | 24.00 dBm |
| CN | 33 dBm | 24.00 dBm |

国家码只决定**信道可用性**（JP/DE 直接禁 161），不决定功率。

---

## 2. 硬件额定值 —— 24 dBm 到底算不算"被限"（`[外部实证]`）

同芯片的公开模块规格书（QCN6102 / QCN6122 系列，55 nm 同一家族）：

### 2.1 5 GHz（QCN6102-5G，Wallys DR6102-5G，PDF `wallystech.com/upload/DR6102.pdf`）

> Features: "Qualcomm Atheros QCN6102 · **5GHz, max 23dBm per chain**, up to 2402Mbps"

RF Parameter 表（5.15–5.95 GHz，2×2）：

| 模式 | 速率 | TX Power |
|---|---|---|
| 11a | 6 Mbps / 54 Mbps | 27 / 25 dBm |
| VHT80 | MCS0 / MCS7 / MCS8 / MCS9 | 26 / 25 / 24 / 23 dBm |
| **HE80** | **MCS0 / MCS9 / MCS10 / MCS11** | **26 / 24 / 22 / 20 dBm** |
| HE160 | MCS0 / MCS9 / MCS10 / MCS11 | 24 / 21 / 20 / 17 dBm |

**⇒ 本板的 24 dBm 正好等于 HE80 MCS9 的额定值。
也就是说 BDF 不是"被人为砍到 24"，而是把上限设在芯片在这个带宽下能线性工作的点。**

`[推断]` 上表是**模块级 2 链合计**值；本板 `iw` 报的 24.00 与之同量级，
说明观察到的 24 dBm 就是这一档。若按 per-chain 23 dBm 算，2 链合计上限约 26 dBm
—— **离 24 也只有 2 dB**。

### 2.2 2.4 GHz（IPQ5018 内置，Wallys DR5018，PDF `wallystech.com/upload/DR5018.pdf`）

> "On-board 2x2 2.4GHz ... **max 23dBm per chain** (2 IPEX Connectors)"

HE20 表：MCS0–MCS6 = 23 dBm/链（2 链 26 dBm），MCS11 = 17 dBm/链（2 链 20 dBm）。
同系列另一型号 DR5018M 标 **max 21 dBm per chain**（说明这档芯片个体/板级差异可达 2 dB）。

**但 2.4G 的约束不是硬件，是法律**：`[外部实证]` CN 2.4 GHz 上限 = 20 dBm（100 mW），
本板 regdb 也报 20。硬件能给 26，**法律只让给 20**。

### 2.3 本板有独立 FEM（`[外部实证]`，猫点饭 WTA301 参数页）

> 「信号放大器：**独立 4 路**」（FEM = PA + LNA 前端模组）
> 「空间流：2.4GHz 2x2 / 5GHz 2x2」「内存 256MB」「闪存 128MB」「千兆网口 ×4」

⇒ 2+2 四链各一个独立 FEM，与"4 路"吻合。功率天花板由 FEM 器件决定，不由 SoC 决定。
**FEM 型号未拆机确认** ⇒ 具体额定值未验证。

---

### 2.4 板级差异表（外部参考模块 vs 本板，逐条确认）

| 项 | 外部参考（Wallys DR6102-5G / DR5018） | 本板 WTA301 | 同/不同 | 影响 |
|---|---|---|---|---|
| 5G 射频芯片 | QCN6102 | **QCN6122**（dmesg `qcn6122 hw1.0`） | **不同** | 同家族同工艺，功率档位按家族规格参考 |
| 2.4G 射频 | IPQ5018 内置 | IPQ5018 内置 | **同** | 可直接参考 |
| 5G 链路数 | 2×2 | 2×2 | **同** | 合计功率换算方式相同 |
| 2.4G 链路数 | 2×2 | 2×2 | **同** | 同上 |
| 天线 | 2×UFL 外接 IPEX | **内置 4 路独立 FEM + 内置天线** | **不同** | 天线增益不同 ⇒ EIRP ≠ 参考模块；本板增益**未知** |
| 板级输出功率 | 23 dBm/链（标称） | 24 dBm（`iw` 实测封顶） | **不同（+1 dB）** | 本板不劣于参考，或换算口径不同 |
| 供电 | 5 V / M.2 E key | 12 V 1 A / 板载 | **不同** | 不影响单链功率上限 |
| 工作温度上限 | −20 … 70 °C | 商用 0 … 40 °C（同系列公开规格） | **不同** | **本板环境余量更小** ⇒ §4.1 的 90 °C 更值得警惕 |
| 散热 | 金属屏蔽盖/散热片 | 塑料外壳、无主动散热（面板尺寸限制） | **不同** | 同上 |
| 校准数据来源 | 「Caldata saved in DR5018's Flash」 | **本机 ART 逐台校准**（`f15ca653…` / `c681908f…`） | **同（各自逐台）** | 功率表反映的是本机实测，不能跨机套用 |
| 国码 / 法规 | 参考表未指定 | **CN** | **不同** | 2.4G 上限 20 dBm 由 CN 法规决定 |

**冲突记录**：外部表 HE80 MCS0 标 26 dBm，本板实测封顶 24 dBm（低 2 dB）。
两种解释：① 本板 FEM/天线比参考模块低一档；② `iw` 报的是 per-chain 目标功率，
26 dBm 是 2 链合计。**未验证，不择一采信**（见 §7）。

---

## 3. 为什么"往上顶"拿不到收益（`[外部实证]`，三条独立来源）

### 3.1 高阶调制会崩（ath11k 直接后果）

OpenWrt 论坛专家原文（`forum.openwrt.org/t/how-to-use-the-maximum-tx-power-of-2-4ghz-wi-fi/157461`）：

> "Inside the radio firmware there are some power levels **for each data rate/modulation**.
> These values are likely some sort of fail-safe, but **if you increase the target power,
> there is a high chance to transmit just junk when using the higher data rates, causing
> interference without any improvement** (even under the regulatory power levels),
> so I wouldn't recommend wasting your time with any patched firmware."

⇒ 1095/1201 Mbps 这些速率需要 4096-QAM，对 EVM 极敏感。硬顶功率 = 削掉高速率档，
**近处掉速、远处照样掉线**。

### 3.2 距离由上行决定，不由 AP 决定

Cisco 高密度部署白皮书（`cisco.com/.../high_density_and_high_availability_in_wireless_deployment.pdf`）：

> "Signal Quality Issue – **Higher Tx Power means better coverage?** **Not always.** …
> **WiFi coverage characteristic is determined by uplink link budget (Handset dependent)**"

SmallNetBuilder 实测（`smallnetbuilder.com/basics/wireless-basics/an-experiment-in-wireless-power-and-range/`）：

> "Changing router transmit power affects downlink throughput, **but does not affect uplink throughput**"
> "Range is always the same for transmit and receive, downlink and uplink"

internetnews（`internetnews.com/communications/uplink-signal-strength-matters/`）：

> "most APs have a significantly higher EIRP compared to wireless clients …
> **the effective range between the AP and the client device is governed by the uplink signal strength**"

⇒ 手机发射约 15–17 dBm，AP 24 dBm。**上行先断**，AP 再喊大声也没用。

### 3.3 一把尺子：每 3 dB 只换来 ×1.41 距离

| 功率 | mW | 相对 24 dBm | 自由空间距离 |
|---|---|---|---|
| 20 dBm | 100 | −4 dB | ×0.63 |
| **24 dBm（当前）** | **250** | **基准** | **×1.00** |
| 27 dBm | 500 | +3 dB | ×1.41 |
| 30 dBm | 1000 | +6 dB | ×2.00 |

⇒ 就算真能从 24 顶到 27，穿过两堵墙后也就多走 4 成；
而 3.1 的 EVM 崩塌会把这个收益吃掉。

---

## 4. 安全边界（"不烧设备"）

### 4.1 温度（`[本板实证]`，P30 满载 60 秒单流 TCP 上行 414 Mbps）

| 传感器 | 静置 | 峰值 | 判定 |
|---|---|---|---|
| CPU | 53 °C | 55 °C | 降频点 100 °C，余一半 |
| 2.4G (phy0) | 62 °C | 64 °C | — |
| **5G (phy1)** | 56 °C | **90 °C** | `ath11k_thermal cur_state=0/100` |
| gephy | 54 °C | 56 °C | — |

**24 dBm 下 5G 已经跑到 90 °C。** +3 dB = 射频功率翻倍，热是可预期的最大受害项。
`cur_state=0/100` 说明驱动自带的热降额一级没用（有保护），
但一旦触发降额，**功率会被自己降回去** —— 等于白折腾，还多了 90 °C 的持续应力。

### 4.2 法规

| 频段 | CN 上限 | 本板当前 | 还能提吗 |
|---|---|---|---|
| 5G 149–165 | 33 dBm | 24 dBm | 法理上到 33 都合法，但要过 BDF |
| **2.4G** | **20 dBm** | 20 dBm | **❌ 已到顶，超了违法** |

---

## 5. 若要真的改 BDF，需要什么、代价是什么（未做）

| 项 | 内容 |
|---|---|
| 工具 | `ath11k_bdf_tool.py`（`-e/-u/-p`）+ `ath11k-bdencoder` |
| 已知功率偏移 | `0x1eb` / `0x1ec` / `0x1ed`（IPQ5018，外部证据） |
| 本板 5G | `0x1eb=03` / `0x1ec=01` / `0x1ed=02` |
| 本板 2.4G | `0x1eb=03` / `0x1ec=01` / `0x1ed=00` |
| 容器内名 | `bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=TP-Link-WTA301` |
| 内嵌 regdb | 无（`0x45c=0x00`，已是修好的状态） |
| **约束** | BDF 版本必须严格匹配固件 `WLAN.HK.2.7.0.1-01744`，改错射频不工作 |

**不建议改**，理由已如 §3：收益 ≤3 dB 且被 EVM 吃掉，代价是热 + 潜在射频不启动。

---

## 6. 真正能提升覆盖的杠杆（按性价比排序，均未在本板实测）

| # | 杠杆 | 预期收益 | 依据/状态 |
|---|---|---|---|
| 1 | **位置**：抬高、离开墙体/金属/微波炉 | 10–20 dB | 物理决定，远大于任何软件项 |
| 2 | **5G 换低频信道**：ch36(5180) vs ch161(5805) | 约 1–1.5 dB | 自由空间差 `20log10(5805/5180)=0.98 dB` + 穿透差；**未实测** |
| 3 | 客户端侧（换支持 2×2 / 更好天线的网卡） | 上行 +3 dB | §3.2，上行是瓶颈 |
| 4 | 加第二个 AP / 有线回程 | 覆盖面积翻倍 | 比堆功率划算得多 |
| 5 | `rts`/`frag` 阈值 | 密集环境减少碰撞 | 本板未测；家庭单 AP 收益不明 |
| 6 | Beamforming / MU-MIMO | 容量，不是覆盖 | hostapd 默认已开，未单独验证 |

**已确认无效/不可用**：改国家码提功率（§1.1 实证）、HE160（P24 实测 -19%）、
`txpower` 写 24 以上（§1 实证）。

---

## 7. 未验证项

| 项 | 状态 |
|---|---|
| 本板 FEM 具体型号与额定输出功率 | ⬜ 未拆机 |
| 2 链合计 vs `iw` 报值的换算关系 | ⬜ `[推断]` 未实测 |
| ch36 HE80 与 ch161 HE80 同位置对比 | ⬜ 未测（P24 只测过 ch36 **HE160**） |
| 24 dBm 属下 5G 90 °C 是否已在降额边缘 | ⬜ 只看过 `cur_state`，未看历史最大 |
| BDF 提功率后的实际 EVM 变化 | ⬜ 无仪器，做不了 |

---

## 8. 收口

- **不做**：改 BDF、改国家码、写 txpower > 24。
- **可做**：把 5G 信道从 161 换到 36–48 做同位置对比（唯一还没试过的免费项，收益预期 ~1 dB）。
- **不改**：2.4G 已到法律上限。
- 对外口径：本板最大发射功率 **5G 24 dBm / 2.4G 20 dBm**，与出厂一致，不虚标。
