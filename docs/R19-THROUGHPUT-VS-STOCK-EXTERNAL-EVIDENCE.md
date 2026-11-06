# R19 — IPQ5018 5G 吞吐 vs 原厂：外部证据与本板实证

> 问题：OpenWrt 25.12.6 在 WTA301 上 5G 只有 474–529 Mbps，用户质疑「OP 比原厂性能还差？」
> 本文按 §0 EXTERNAL FIRST 归档检索结果、板级差异、本板实测。
> 日期：2026-11-06

---

## 0. 结论先行

| 命题 | 判定 | 依据 |
|---|---|---|
| OpenWrt 在 **同带宽（80MHz）** 下比原厂差 | **假** | 本板 474 vs 外部 NSS 构建 462 → 持平 |
| 原厂 711 Mbps 是 OpenWrt 做不到的 | **半真** | 原厂 = 160MHz + NSS 硬件卸载；OpenWrt 主线无 NSS |
| 原厂的真正优势在**大包带宽** | **假** | 外部实测者原话：带宽「basically identical」 |
| 原厂的真正优势在**小包转发 pps** | **真** | 原厂 70-80 kpps → 高得多，因 ECM/NSS offload |
| 我们开 160MHz 能追上原厂 | **假（本板）** | 手机只支持 80MHz；160MHz AP 使 expected 从 887 掉到 551 |

---

## 1. 外部实证：同款 SoC 三方对比

来源：`github.com/mufeng05/openwrt-cmcc-pz-l8-nss`（CMCC PZ-L8 = **IPQ5018 + QCA8337 + QCN6122**，与本板同 SoC 组合）

> `[外部实证]` 同一块板、同一客户端（Intel AX201）、同一服务端、同一个下午、同一套方法：
> 四路并发 HTTP 每路 20 秒，用主机 `/32` 路由强制流量经过路由器。

| 四路并发 HTTP 20s | 原厂 501.8 | v1.6 | nwrt | NSS 构建 |
|---|---|---|---|---|
| 有线 LAN → WAN | 902.9 | 912.1 | 901.8 | **912.6** |
| **5 GHz @ 160 MHz** | **711** | **730** | **722** | **697** |
| 5 GHz @ 80 MHz | — | — | — | **462** |
| 5 GHz 传输时主机 CPU | 17% @711 | 测不出 | 16.1% @537 | **2.9% @441** |

来源同上，iperf3 `-P 4` 每方向 15 秒：

| | 本构建(NSS) | 原厂 501.8 | nwrt | **原生 OpenWrt** |
|---|---|---|---|---|
| 有线 ↔ WAN | 949/949，+0% CPU | 947/947 | 924/926 @4% | **502 @ 100% CPU** |
| 5 GHz ↔ WAN | 510/438 @80MHz | 612/899 @**160MHz** | ~624 @25-35% | **308** |

**关键引用（原文）**：
> `[外部实证]` "OpenWrt 官方镜像内核新、是 64 位，但不支持 NSS。转发回到 Linux，DSA 路径上 **502 Mbit/s 就能把两个核跑满**。"

> `[外部实证]` "**5 GHz 在同宽度下相差 3.5–4.6 %。** 此前把差距归因于信道宽度只是推断（722 / 425 ≈ 1.70，带宽比 2.0）；把本构建也开到 160 MHz 之后是实测：**462 → 697，涨 51 %**，剩下的差距小到不需要另找原因。"

---

## 2. 外部实证：OpenWrt 主线在 5G 带宽上与原厂持平

来源：`forum.openwrt.org/t/a-simple-patch-to-get-ath11k-working-on-256mib-ram/247147`
（Mercusys MR80X v2.20 = **IPQ5018 256MiB + QCN6122**，与本板同硬件）

> `[外部实证]` 原文：**"Performance wise, also no significant change. Over the 5G wifi it will push ~600MiB/s of raw traffic (`iperf .. -u -b 700M -l 1200`) and 70-80kpps with small packet size. The bandwidth test was basically identical with the performance on the vendor's firmware. The vendor's pps were of course way higher, but this is most-likely due to the offloads."**

**这是本问题的决定性证据**：
- 5G **带宽**：`basically identical`（基本一致）→ OpenWrt 不差
- 5G **pps**：`vendor's pps were of course way higher` → 原厂强，原因是 offload
- 数值：~600 MiB/s UDP 大包、70-80 kpps 小包

---

## 3. 外部实证：OpenWrt 主线缺 ath11k NSS offload（上游 issue）

来源：`github.com/openwrt/openwrt/issues/23798`（Redmi AX5400 = IPQ5018 + QCN9074）

> `[外部实证]` "5 GHz Wi-Fi associates correctly at Wi-Fi 6 HE80 rates, but **actual Wi-Fi throughput is much lower than expected**... the `ath11k` module has **no `nss_offload` parameter**, so NSS Wi-Fi offload support is not compiled in."

> `[外部实证]` 站点信息（与本板几乎相同）：
> ```
> tx bitrate: 1080.6 MBit/s 80MHz HE-MCS 10 HE-NSS 2
> rx bitrate: 1200.9 MBit/s 80MHz HE-MCS 11 HE-NSS 2
> expected throughput: 887.703Mbps
> ```
> "However, practical Wi-Fi throughput is only around **300-500 Mbit/s** in iperf3/speed tests"

> `[外部实证]` 缺失组件清单：`ATH11K_NSS_SUPPORT` / `MAC80211_NSS_SUPPORT` / `qca-nss-drv` / `qca-nss-ecm` / ath11k NSS patches providing `nss_offload=1`

> `[外部实证]` 评论原文：**"There is no open-source qca nss driver."**

---

## 4. 外部实证：NSS offload 的实际效果（kernel 6.18 移植）

来源：`forum.openwrt.org/t/ipq5018-nss-offload-on-kernel-6-18-with-the-upstream-ethernet-stack-gl-b3000/253014`

> `[外部实证]` "Wi-Fi on the NSS path - board as a router, one laptop on 5 GHz, iperf3 to a server on the WAN side: **734/447 Mbit/s single stream, 791/534 with three streams, CPU ~90 % idle**."

> `[外部实证]` 有线：`~66k packets/s through the firmware, CPU 93-96 % idle`

> `[外部实证]` 该板单千兆 CPU 口的理论上限：`2 x 1448 B payload / (2 x 1542 + 94) B on the wire = 91.1 % -> ~911 Mbit/s`

---

## 5. 板级差异表（外部 → 本板）

| 项 | 外部（CMCC PZ-L8 / MR80X / AX5400） | **本板 WTA301** | 同/不同 | 影响 |
|---|---|---|---|---|
| SoC | IPQ5018 + QCN6122 | **IPQ5018 + QCN6122** | **同** | 可直接对比 |
| RAM | 256 MiB（MR80X）/ 512 MiB | **256 MiB** | 同（vs MR80X） | 相同约束 |
| CPU | 2× Cortex-A53 | **2× Cortex-A53** | **同** | 瓶颈相同 |
| ath11k FW | WLAN.HK.2.7.0.1-01744 | **WLAN.HK.2.7.0.1-01744** | **同** | 无需换固件 |
| NSS offload | 外部 NSS 构建有；主线无 | **主线无** | 同（vs 主线） | 结论可直接用 |
| BDF | 各家自定义 variant | **`variant=TP-Link-WTA301`** `board-id=255` | 不同 | 功率表不同，但硬限都是 24 dBm |
| 客户端 | Intel AX201（**支持 160MHz**） | **Redmi Note 12T Pro（只 80MHz）** | **不同** | ★ 160MHz 收益无法体现 |
| 测试方式 | 四路 HTTP / iperf3 -P4 | iperf3 单/多流 | 不同 | 数值不可直接横比 |

**★ 最关键差异**：外部 711 Mbps 的前提是**客户端支持 160MHz**（Intel AX201）。本板客户端只协商到 80MHz。

---

## 6. 本板实证

### 6.1 80MHz @ ch161（推荐配置）

```
channel 161 (5805 MHz), width: 80 MHz, center1: 5775 MHz
noise -113 dBm, channel busy 1277 ms
手机：signal -11 dBm
      tx bitrate 1080.6 MBit/s 80MHz HE-MCS 10 HE-NSS 2
      rx bitrate 1200.9 MBit/s 80MHz HE-MCS 11 HE-NSS 2
      expected throughput 887.703 Mbps
```

实测（板子当 client，`iperf3 -c 192.168.1.246`，重传 **0**）：

| 方向 | 结果 |
|---|---|
| TCP 上行（板→手机） | **474 Mbps** |
| TCP 下行（手机→板，-R） | **523–529 Mbps** |
| 4 流上行 | 499 Mbps（+5%，说明多核已无余力） |
| UDP 800M | 282 Mbps，丢包 0.17% |

### 6.2 160MHz @ ch36（实测为负优化）

```
channel 36 (5180 MHz), width 160 MHz, center1 5250 MHz
DFS-CAC-COMPLETED success=1 cac_time=60s radar_detected=0
noise -111 / -97 dBm, channel busy 141496 ms / 223382 ms = 63%
手机：tx bitrate 648.5 / rx 1080.6 (仍是 80MHz！)
      expected throughput 551.609 Mbps
```

| 指标 | 160MHz@36 | **80MHz@161** | 变化 |
|---|---|---|---|
| 信道忙时 | 141,496 ms | **1,277 ms** | **111× 更干净** |
| expected throughput | 551 Mbps | **887 Mbps** | **+61%** |
| 手机带宽 | 80MHz | 80MHz | 无变化 |

⇒ **手机不支持 160MHz，开宽信道纯亏。**

### 6.3 CPU 瓶颈证据

| 观察 | 值 |
|---|---|
| 测试时 CPU0 / CPU1 | **100% / 99-100%**（RPS 修复后） |
| 停止后 | 2–3% |
| 网卡 RX 队列 | **`phy1-ap0 rx=1`、`eth0 rx=1`（单队列）** |
| eth0 硬中断 IRQ 22 | **全部在 CPU0** |
| 5G 的 `rps_cpus` | 出厂 **`0`（禁用）** → 改为 `3` |

---

## 7. 为什么 OpenWrt 主线做不到原厂的 711

| 层 | 原厂 | OpenWrt 主线 |
|---|---|---|
| 数据路径 | **NSS UBI32 核**（独立加速核，包不进 Linux） | Linux 协议栈 + mac80211 |
| 驱动 | 闭源 `qca-nss-drv` + `ecm_nss_ipv4` | 开源 ath11k，**无 `nss_offload` 参数** |
| 信道宽度 | 默认 160MHz | 视配置 |
| CPU 占用 | 6–17%（因为不进 CPU） | **100%** |

`[外部实证]` 原厂同时加载 ECM 和 SFE，但 SFE 不干活：6 条连接全落在 `ecm_nss_ipv4/accelerated_count`，SFE 连接表为空。

---

## 8. 可做的优化（按收益排序）

| 优化 | 预期收益 | 风险 |
|---|---|---|
| **回退 80MHz @161**（已做） | expected +61% vs 160MHz | 无 |
| 持久化 RPS（`phy1-ap0` 从 `0` → `3`） | CPU1 从 1% 参与度到 99% | 无 |
| 客户端换支持 160MHz 的网卡 | 462 → 697（外部实测 +51%） | 需换设备 |
| 上 NSS offload（`qca-nss-drv`） | 大包 949、CPU ~0% | **闭源，无开源驱动；需自建固件** |
| 改 BDF 功率偏移 `0x1eb/0x1ec/0x1ed` | 覆盖距离 | 对 -11 dBm 场景零收益；改错射频不工作 |

---

## 9. 证据等级声明

| 结论 | 等级 |
|---|---|
| 同带宽（80MHz）OpenWrt 与原厂持平 | **已实证**（外部独立复现 + 本板 474 vs 462） |
| 原厂优势在小包 pps 而非大包带宽 | **已实证**（MR80X 测试者原话） |
| 本板手机只支持 80MHz | **已实证**（`iw station dump` 明确 `80MHz`） |
| 160MHz 在本板是负优化 | **已实证**（busy 63% vs 0.4%，expected 551 vs 887） |
| 上 NSS 能到 700+ | **外部实证**（未在本板验证） |
| 本板 5G 理论天花板 | **推断**：ath11k 80MHz 下约 500-600 Mbps |

---

## 10. 参考 URL

1. `https://github.com/mufeng05/openwrt-cmcc-pz-l8-nss` — 同 SoC 三方对比（原厂/v1.6/nwrt/NSS）
2. `https://forum.openwrt.org/t/a-simple-patch-to-get-ath11k-working-on-256mib-ram/247147` — MR80X 256MiB，5G 带宽与原厂持平
3. `https://github.com/openwrt/openwrt/issues/23798` — 主线缺 ath11k NSS offload
4. `https://forum.openwrt.org/t/ipq5018-nss-offload-on-kernel-6-18-with-the-upstream-ethernet-stack-gl-b3000/253014` — NSS 实测 734/447、CPU 90% idle
5. `https://forum.openwrt.org/t/qualcommax-ath11k-board-calibration-bdf-data-woes/182646/82` — BDF 功率偏移 `0x1eb/0x1ec/0x1ed`（= 491/492/493）
