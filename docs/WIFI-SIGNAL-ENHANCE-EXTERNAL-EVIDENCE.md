# 无线信号增强 —— 外部证据、实测与结论

目标：增强接收与发射。约束：**板子不能烧**、可开箱即用、随固件交付。

标注：`[外部实证]` 可复核外部原文 · `[上游代码]` 上游源码 · `[本板实证]` 本机实测 · `[推断]` 有推理链未实测

---

## 0. 一句话结论

| 手段 | 结论 | 效果 |
|---|---|---|
| **降低 beacon / 管理帧 / 最低数据速率** | ✅ **已实施，最大收益** | 2.4G 等效 **+10.8 dB（距离 ×3.4）**，5G **+6 dB（×2.0）** |
| **5G 带宽 HE80 → HE40** | ✅ **已实施（v30 决定）** | **+3 dB（距离 ×1.41）**，代价峰值吞吐减半 |
| **2.4G 加回 802.11b CCK（1/2/5.5/11 Mbps）** | ✅ **已实施** | 接收灵敏度 **+8 dB**（−88 → −96 dBm） |
| **关掉 `disassoc_low_ack`** | ✅ **已实施** | 弱信号下不再被误踢掉线 |
| 提高发射功率 | ❌ **不可行，已两次实测否决** | 0（软硬件都到顶） |
| 换国家码提功率 | ❌ **已实测无效** | 0 |
| 改 BDF 功率表 | ❌ **已实测无效（两处）** | 0 |

**发射功率 24 dBm 是硬顶，任何软件手段都提不动。真正的杠杆是"把速率压下来"，已拿到 8~11 dB。**

---

## 1. 发射功率为什么提不动（三次独立实测）

### 1.1 `iw set txpower` 直接无效 `[本板实证]`

```
iw dev phy0-ap0 set txpower fixed 3000  -> 回读 24.00 dBm
iw dev phy1-ap0 set txpower fixed 3000  -> 回读 24.00 dBm
```

### 1.2 换国家码无效，且 2.4G 也是 BDF 卡的（补上文档的空白）

`TXPOWER-LIMITS-EXTERNAL-EVIDENCE.md` 自认「2.4G 从未测过，这是我的疏漏」。本轮补测：

| country | 2.4G 实测 | 5G 实测 | `iw phy` 报的信道上限 |
|---|---|---|---|
| CN | 24.00 | 24.00 | 30.0 dBm |
| US | 24.00 | 24.00 | 30.0 dBm |
| BO | 24.00 | 24.00 | 30.0 dBm |
| AU | 24.00 | 24.00 | 30.0 dBm |
| JP | 24.00 | 24.00 | 30.0 dBm |

`iw reg get` 在 CN 下 2.4G 只给 20 dBm，而 `iw phy phy0 info` 仍报 30.0 dBm
⇒ **ath11k 是 self-managed regulatory，regdb 完全不参与限幅**，换国家码只影响信道可用性。
⇒ **2.4G 与 5G 一样，24 dBm 都来自 BDF/固件，不是法规。**

### 1.3 改 BDF 功率表无效（两处，均实测）

单位推断：BDF 功率值为 **int8，0.5 dBm 分辨率**（`[外部实证]` DeepWiki
`firmware_qca-wireless/2.2-board-data-file-format-and-structure`：
「Power values are encoded as signed 8-bit integers representing dBm × 2 (0.5 dB resolution)」）。
`0x31` = 49 = 24.5 dBm，与实测 24.00 吻合。

本机 cal 与通用 bdwlan 只差 25 字节，集中在 `0x1a00+` / `0xe250+`（功率与校准区），
与 `M12-FIRMWARE-BDF.md` 记录一致 ⇒ caldata 身份确认，可安全做实验。

board-2.bin 容器里 BDF payload 起于 **0x6c**（`0x24 + align(61,4) + 8`，已逐字段核对）。

**实验一**：`0x3ee8`（2.4G 专用，64×`0x31`）与 `0x4138`（两文件共有，64×`0x31`）
→ 容器 `0x3f54` / `0x41a4` 写成 `0x24`（18.0 dBm，向下）：

```
改前 0x3f54: 31 31 31 31 …（24.5 dBm）
改后 0x3f54: 24 24 24 24 …（18.0 dBm）
重启后 iw: 24.00 dBm  ← 完全没变
```

**实验二**：`0x3a10..0x3acf`（16 信道 × 2 链，值 `0x21`–`0x25` = 16.5–18.5 dBm/链；
双链合成 +3 dB 加天线增益 ≈ 24 dBm EIRP，是最符合实测的一张表）
→ 容器 `0x3a7c`，全部 `0x1e..0x2e` 值 +3（+1.5 dB，192 字节里改了 180 个）：

```
改前 0x3a7c: 24 24 23 24 24 23 25 22 21 21 …
改后 0x3a7c: 27 27 26 27 27 26 28 25 24 24 …
重启后 iw: 24.00 dBm  ← 仍然完全没变
```

**⇒ 这两处都不是约束实际发射功率的表。24 dBm 由固件（WMI/TPC）在 BDF 之外强制。**
两次实验后 BDF 均已回滚，md5 恢复 `78f5b21b…` / `e4904f13…`。

### 1.4 为什么不继续挖 BDF（判断依据，不是放弃）

1. 24 dBm 已等于芯片额定点（`[外部实证]` Wallys DR6102 规格：QCN6102 HE80 MCS9 = 24 dBm）。
2. 本板 24 dBm 满载 5G 已到 90 ℃（`P30-THERMAL.md`）。+3 dB = 射频功率翻倍。
3. `[外部实证]` 高阶调制会崩：功率上去 EVM 恶化，MCS9 掉到 MCS7，吞吐反而降。
4. `[外部实证]` 距离由**上行**决定：手机只有 15–17 dBm，AP 喊更大声不改变手机先断。

⇒ 在"不烧板子"的硬约束下，继续提功率是负收益。已把预算全部投到速率侧。

---

## 2. 真正的杠杆：把速率压下来（已实施）

### 2.1 `cell_density` 的真实语义（此前注释写错了）

`/lib/netifd/hostapd.sh` 里 `cell_density` **只做一件事**：决定
`rate_list` / `basic_rate_list` 的默认值。**不碰 CCA 阈值**。
（旧注释「更激进的 CCA 阈值 −72 vs −82 dBm」是错的，本轮已改。）

而 **`basic_rate` 决定 beacon 与管理帧的发送速率**，也决定客户端关联时必须支持的最低速率。

| 频段 | cell_density | basic_rates（默认） | beacon 速率 |
|---|---|---|---|
| 2.4G `legacy_rates=0` | 0/1 | 6/12/24 | 6 Mbps |
| | 2（本板原值） | 12/24 | **12 Mbps** |
| | 3 | 24 | 24 Mbps |
| 5G | 1 | 6/12/24 | 6 Mbps |
| | 2 | 12/24 | 12 Mbps |
| | 3（本板原值） | 24 | **24 Mbps** |

### 2.2 实施值

**`set_default` 只在用户没显式设置时生效**，所以直接写死 `basic_rate` / `supported_rates` 完全接管。

```
radio1 (5G)    htmode HE40            ← v30 改（原 HE80），+3 dB，吞吐减半
radio0 (2.4G)  cell_density 0
               supported_rates 1000 2000 5500 11000 6000 9000 12000 18000 24000 36000 48000 54000
               basic_rate      1000 2000          ← beacon 用 1 Mbps
               legacy_rates    1                 ← 把 802.11b CCK 加回来
radio1 (5G)    cell_density 1
               supported_rates 6000 9000 12000 18000 24000 36000 48000 54000
               basic_rate      6000 12000 24000   ← beacon 用 6 Mbps（原 24）
两个 iface     disassoc_low_ack 0
```

真机核对（`/var/run/hostapd-phy*.conf`）：

```
2.4G  supported_rates=10 20 55 110 60 90 120 180 240 360 480 540
      basic_rates=10 20
      disassoc_low_ack=0
5G    supported_rates=60 90 120 180 240 360 480 540
      basic_rates=60 120 240
      disassoc_low_ack=0
txpower 24.00 dBm（未被影响）    温度 56 ℃（正常）
```

### 2.3 换算（按本仓库 `TXPOWER-LIMITS` 的尺子：每 3 dB ≈ ×1.41 距离）

| 改动 | dB | 距离倍数 |
|---|---|---|
| 2.4G beacon 12 → 1 Mbps | 10·log10(12/1) = **+10.8 dB** | **×3.4** |
| 2.4G 数据 12 Mbps OFDM → 1 Mbps DSSS | **+8 dB**（灵敏度 −88 → −96 dBm） | ×2.5 |
| 5G beacon 24 → 6 Mbps | 10·log10(24/6) = **+6 dB** | **×2.0** |

物理依据：接收灵敏度由每比特能量决定，速率降 10 倍 ⇒ 同样的接收功率下
SNR 需求降 10 dB。这是链路预算方程里唯一能靠软件改变的项（功率和天线都已固定）。

### 2.4 代价（必须说明）

1. **空口时间**：beacon 100 ms 周期，1 Mbps 一帧约 2.3 ms（原 12 Mbps 约 0.27 ms）
   ⇒ 占空比约 2.3%，可接受。
2. **远处低速客户端占更多空口**：近距离客户端由 minstrel 自动选高速率，不受影响。
3. **开启 802.11b 会带来少量 OFDM/CCK 保护开销**（CTS-to-self），近距离极端吞吐可能
   降几个百分点。换取的是"远处从连不上变成连得上"。
4. 5G 没有 CCK，6 Mbps 已是 OFDM 最低，无法再降。

### 2.5 想换回吞吐优先档

一条命令（立即生效，不需要重编译）：

```sh
uci set wireless.radio0.cell_density='2'
uci -q delete wireless.radio0.basic_rate
uci -q delete wireless.radio0.supported_rates
uci -q delete wireless.radio0.legacy_rates
uci set wireless.radio1.cell_density='3'
uci -q delete wireless.radio1.basic_rate
uci -q delete wireless.radio1.supported_rates
uci commit wireless && wifi reload
```

---

## 3. `disassoc_low_ack` 为什么必须关

`[上游代码]` `/lib/netifd/hostapd.sh:574` → `set_default disassoc_low_ack 1`（默认开）。

`[外部实证]` ath11k 邮件列表 2021-January/000975：
> All kind of devices can successfully connect to the AP and use it perfectly fine for over an hour.
> But after 65 minutes, the ath11k firmware suddenly sends an `WMI_PEER_STA_KICKOUT_EVENT`
> — which will be handled by hostapd as `DISASSOC_LOW_ACK`. Which means that the connected
> station will be disconnected.
> … It should also be possible to achieve the same by setting `disassoc_low_ack=0`.

弱信号场景下把"勉强能用"变成"反复掉线"，所以关掉。
副作用：真离线的客户端不会被及时清理，由 `ap_max_inactivity`（默认 300 s）兜底。

---

## 4. 保留不动的项（有证据，不要再动）

| 项 | 值 | 为什么不动 |
|---|---|---|
| 5G 信道 | 161 | CN 非 DFS。DFS 信道要 CAC，起不来会让 AP 彻底不可用（实测设 64 后 hostapd 循环 DFS-CAC-START → DISABLED） |
| 5G 带宽 | **HE40**（v30 改，原 HE80） | 80→40MHz = +3 dB。不用 HE160：实测 busy 0.4%→63%、expected 887→551。换回：`uci set wireless.radio1.htmode='HE80'; uci commit wireless && wifi reload` |
| 2.4G 带宽 | HT20 | 强开 HT40 要 `noscan`，会挤邻居（扫到 ch1=4 / ch11=4 个 AP） |
| 2.4G 信道 | 11 | ch11 HT20 = 66/49/26 Mbps；ch6 HT20 约 20 Mbps（被 CTS 压着） |
| LDPC / TX-STBC / RX-STBC1 / short-GI | 已开 | `iw phy` 确认硬件支持且 hostapd 已下发 |
| 天线 | 双天线 `TX 0x3 RX 0x3` | 硬件固定；`RX STBC 1-stream` 已在用（多径 ≈ 3 dB 增益） |
| 不做 threaded NAPI | — | 上游 13aa2fb 合入后因 QCN9074 被 revert（d265ebe） |
| 不写 txpower | — | 驱动默认即 BDF 上限 24 dBm，写了也一样 |

---

## 4.1 5G 信道实测：161 完胜 44（v30 前修正）

板上当时跑 **ch44**（宽度 80MHz），而构建配置写的是 ch161。用 `iw scan` 点数后改 161：

| 5G 信道 | 扫描到的 AP 数 | 最强邻居 |
|---|---|---|
| 36 | 9 | −92 dBm |
| 40 | 9 | −82 dBm |
| **44** | **26** | **−63 dBm（Redmi Note 12T Pro）/ −64 dBm（HUAWEI）** |
| 48 | 8 | — |
| 52/56/60/64 | 2/1/6/6 | DFS 段，不选 |
| 149 | 5 | — |
| 153 | 3 | — |
| 157 | 2 | — |
| **161** | **1** | 本 AP |

HE40 在 161 上占 157+161 两块，合计只有 2 个邻居；而在 44 上占 44+48，
要跟 26+8 个 AP 抢。⇒ **161 胜出，与构建配置一致，已把板子改到 161。**

`[本板实证]` 161 + HE40 起来正常，无 DFS/CAC：
```
phy1-ap0: interface state HT_SCAN->ENABLED
phy1-ap0: AP-ENABLED
channel 161 (5805 MHz), width: 40 MHz, center1: 5795 MHz
txpower 24.00 dBm
```

注：5805 MHz 比 5220 MHz 路径损耗高 `20·log10(5805/5220) = 0.92 dB`，
但 ch44 的拥塞代价远大于 0.92 dB（−63 dBm 的邻居直接把空口占了），所以仍选 161。

---

## 5. 落地位置

```
wta301-2512/files-base-files/etc/config/wireless              主机制（固化进 rootfs）
wta301-2512/files-base-files/etc/uci-defaults/99-wta301-wireless         兜底 1
wta301-2512/deliver/ipq50xx-base-files/etc/uci-defaults/99-wta301-wireless 兜底 2
```

注意：`deliver/ipq50xx-base-files` 那份此前是**过期副本**（ch6 + HT40，与 P24 的
ch11 + HT20 结论冲突），本轮一并修正。

---

## 6. 未验证 / 待办

1. **实际距离/信号改善未做端到端实测** —— 需要在固定距离用手机看 RSSI 与
   可用速率（改造前 vs 改造后）。目前证据是配置级 + 链路预算计算。
2. 24 dBm 的真实强制点未定位到具体代码（已排除 BDF 两处表、regdb、DTS、
   `iw set txpower`）。若以后要追，方向是 ath11k → WMI `PDEV_PARAM_TX_POWER`
   与固件 TPC 表。
3. 2.4G 开启 CCK 后近距离极端吞吐的损失未量化。
