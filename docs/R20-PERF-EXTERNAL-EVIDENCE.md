# R20 —— 性能优化外部证据汇总

> 本文档是「为 WTA301 做性能优化」的**外部证据台账**，遵循 AGENTS.md §0：
> 每条标 `[外部实证]` / `[上游代码]` / `[本板实证]` / `[推断]`，附 URL 与原文。
> 结论一律先外部、再对本地基线，**外部结论 ≠ 本板结论**，§9 是逐条板级差异表。

检索日期：2026-11（板子 OpenWrt 25.12.6 / 内核 6.12.112）

---

## 1. 同款 SoC / 同款交换机 —— 最重要的一篇

### 1.1 RTL8367S SerDes 与 MR80X v2.20（ipq5018 + qcn6122）`[外部实证]`

URL: https://www.c127.dev/posts/rtl8367s-sgmii-mr80x-v2-20/ （Johan Alvarado, 2026-08-05）

原文：
> The four LAN ports of the MR80X v2.20 did not work under OpenWrt because the
> RTL8367S is wired to the IPQ5018 over the SerDes, and `rtl8365mb` only implemented RGMII.
> … I implemented SGMII and HSGMII as a phylink PCS, keeping the embedded DW8051 in
> reset instead of loading firmware into it. **Merged into net-next, landing in 7.3.**

> In my device tree the CPU port is port 6 with `phy-mode = "2500base-x"` and a fixed
> link at 2500/full … At 2.5G the GMAC still runs in its 1000M/GMII register mode
> (the rate comes from the UNIPHY SGMII+ config done by SSDK).

**对本板的意义**：我们已把 SGMII PCS 移植进 6.12（`pcs-qca-uniphy.c` + `dwmac-ipq5018.c`
+ `rtl8365mb_*`），但本板 **HSGMII 起不来**，DTS 注释已写明 "2.5G HSGMII does not come
up on this board; every attempt to raise it lost the link"。⇒ 有线侧锁死 1G，是硬件/SerDes
限制，不是配置问题。

### 1.2 同 SoC 同交换机（RTL8367S-VB + 2.5G HSGMII）的 TP-Link AX55v1 实测 `[外部实证]`

URL: https://forum.openwrt.org/t/ipq5018-nss-offload-on-kernel-6-18-with-the-upstream-ethernet-stack-gl-b3000/253014/306

| 方向 | Mbit/s | 路由器 CPU |
|---|---|---|
| 有线 LAN→WAN 外 | 943 | ~2% |
| 有线反向 | 943 | ~2% |
| **Wi-Fi 5G 160MHz HE-NSS2，LAN→STA** | **915** | **1–3%** |
| Wi-Fi 5G，STA→LAN | 818 | 1–3% |

**关键**：那 915/818 是 **NSS 硬件卸载**（闭源 `qca-nss-dp` + `qca_ol`）的结果，CPU 只
1–3%。**纯 CPU 转发做不到**。我们放弃 NSS（见 §7），所以不能拿这组数字当目标。

---

## 2. 「2 核 AP 上 E2W 天然是单核」—— 学术论文 `[外部实证]`

URL: https://arxiv.org/abs/2408.01013
《Understanding and Enhancing Linux Kernel-based Packet Switching on WiFi Access Points》
（Zhang, Gupta, Dezfouli；Santa Clara University，2024-08）

原文（摘要第 iii 条）：
> Even when the two NICs are assigned to separate cores, packet switching in the
> **E2W path does not utilize multi-core processing**. This limitation can result in a
> throughput drop if the core assigned to the Ethernet NIC cannot handle the maximum
> supported throughput of the two NICs. In contrast, packet switching in the
> **W2E path inherently utilizes two cores.**

原文（Observation 9）：
> Among all the stages, the two most process-intensive stages are the **Poll Function
> stage and the Init Xmit stage**. For the WiFi interface in particular, the processing
> load of these stages is higher than that of the Ethernet interface.

原文（Observation 10，关于 CPU 统计失真）：
> the SoftIRQ instances handled closely following the Top Half interrupt processing
> and before running a `ksoftirqd` thread may be considered part of the `idle` processor
> utilization instead of SoftIRQ utilization.

**对本板的意义（三条，全部重要）**
1. 我们测的「板→手机 590 Mbps / CPU 79-80%」是 **E2W**，按论文**本来就只有一核在干**。
   ⇒ 单核被打满 = 592 Mbps 这个量级，与我们实测吻合。
2. 「CPU 79-80%」可能是**低估**（论文说 TH 后立即执行的 softirq 会被记成 idle）。
   ⇒ 不要用 top 百分比当瓶颈判据，要用 `softnet_stat` + 实测吞吐。
3. 想突破单核，只能减少单核工作（RPS 把收包挪走、减少每包 CPU 周期），或上硬件卸载。

---

## 3. OpenWrt 自带 packet steering 才是 RPS 的正解 `[上游代码]`

URL: https://raw.githubusercontent.com/openwrt/openwrt/v25.12.6/package/network/config/netifd/files/usr/libexec/network/packet-steering.uc
本地同源：`/usr/libexec/network/packet-steering.uc`（5980 B，板上存在）
调度器：`/etc/init.d/packet_steering`（START=25）

关键代码：
```uc
case '0': disable = true; break;
case '2': all_cpus = true; break;
...
function cpu_mask(cpu) {
    if (cpu < 0) mask = (1 << length(cpus)) - 1;   // = 0b11 = 3
    else         mask = (1 << int(cpu));
    return sprintf("%x", mask);
}
...
if (all_cpus) cpu = -1;           // → rps_cpus = 3
```

`/etc/init.d/packet_steering` 原文：
```sh
packet_steering="$(uci -q get "network.@globals[0].packet_steering")"
steering_flows="$(uci -q get "network.@globals[0].steering_flows")"
[ "${steering_flows:-0}" -gt 0 ] && opts="-l $steering_flows"
/usr/libexec/network/packet-steering.uc $opts "$packet_steering"
```
```sh
service_triggers() {
	procd_add_reload_trigger "network"
	procd_add_reload_trigger "firewall"
	procd_add_raw_trigger "interface.*" 1000 /etc/init.d/packet_steering reload
}
```

社区解释（OpenWrt 论坛 packet steering 主贴，moeller0）`[外部实证]`：
> OpenWrt packet steering defaulted to exempting the CPUs involved in processing
> interfaces interrupts from packet steering. This is a decent approach for devices
> with many CPUs, but **for routers with 2 or 4 cores this can be suboptimal.
> Especially on dual core devices that often means only one CPU can be used for
> packet steering … this is why the "on all CPUs" option can be helpful.**

> Your `rps_cpus` won't survive long, as the **steering scripts will overwrite them**.

URL: https://forum.openwrt.org/t/packet-steering/199045

**对本板的意义**
- 本板 `packet_steering` **未设置 ⇒ 默认 1**，在 2 核上就是「次优」那种情况。
- 设成 **`2`** 后实测（本板）：
  ```
  phy0-ap0 rps_cpus=3   phy1-ap0=3   eth0=3   br-lan=0（桥，不参与）
  phy*: rps_flow_cnt=4096
  ```
  ⇒ **完全覆盖我们自建的 rps-watch**，且是上游维护的，不必自己写守护进程。
- 「steering scripts 会覆盖你的 rps_cpus」= 我们的自建脚本在跟上游打架。

---

## 4. 双核 WiFi AP 的 CPU 亲和性调优实例 `[外部实证]`

URL: https://forum.openwrt.org/t/improved-mt7621-mt7915e-wi-fi-throughput-with-cpu-affinity-tuning/253760

原文：
> Initial LAN → WLAN throughput was around: **~634 Mbps**
> Enabling `option packet_steering '2'` improved it to roughly **~663 Mbps**
> After tuning I got **~732 Mbps** average LAN → WLAN with 780 Mbps spikes

做法 = 把 eth0 的 rps 指到一个核、WiFi NAPI 线程 taskset 到另一个核。

**对本板的意义**：`packet_steering='2'` 单独就 +4.6%，亲和性再 +10%。
但那个例子是 4 核且有 `napi/phy0-*` 线程；**本板 ath11k 没有 NAPI 线程**（§5），
只能对 IRQ 做亲和性，不能对线程做。

---

## 5. ath11k 的 threaded NAPI：上游合过、又 revert、现在没有 `[上游代码]`

合入：`13aa2fb692d3` *wifi: ath11k: Enable threaded NAPI*（2022-09，Kalle Valo 树）
> In the case of WCN6750, enabling threaded NAPI has improved **160 MHz RX throughput
> by nearly 400 Mbps**.

URL: http://lists.infradead.org/pipermail/ath11k/2022-September/003453.html

被 revert：`d265ebe41c91`（2023-07，进 v6.5-rc5）
> This commit broke QCN9074 initialisation:
> `ath11k_pci 0000:04:00.0: ce desc not available for wmi command 36866`
> … As there's no fix available let's just revert it to get QCN9074 working again.

URL: https://github.com/linux-mm/linux-mm/commit/d265ebe41c911314bd273c218a37088835959fa1
回归跟踪：https://linux-regtracking.leemhuis.info/regzbot/regression/bugzilla.kernel.org/217536/

被反向 revert 的尝试：`[PATCH] Revert "Revert "wifi: ath11k: Enable threaded NAPI""`（Johan Hovold）
> Disabling threaded NAPI causes the Lenovo ThinkPad X13s to hang … almost immediately during RX.

**本地核对（本板实证）**：6.18.55 源码 `ath11k/ahb.c:373 ath11k_ahb_ext_irq_enable()`
里**没有** `dev_set_threaded()`；`grep -rn threaded` 整个 ath11k 目录**零命中**。
`/proc/interrupts` 只有 `irq/*` 内核线程，**无 `napi/*` 线程** ⇒ threaded NAPI 未启用。

**运行时开关（本板实证）**
- `/sys/class/net/phy1-ap0/threaded` 存在，**写入失败**（只读/无效）。
  原因：ath11k 的 NAPI 注册在 `alloc_netdev_dummy(0)` 的匿名 netdev 上
  （`ahb.c:538`），该 netdev 未注册 ⇒ 没有对应 sysfs 节点。
- ⇒ 想开 threaded NAPI **只能改驱动**（加一行 `dev_set_threaded`）。

`[未验证]` 风险：revert 的理由是 QCN9074（PCIe）CE 描述符问题。本板是 AHB 且
2.4G 是 IPQ5018 内建、5G 是 QCN6122，与 QCN9074 不同 ⇒ **可能安全**，但未在本板验证。

---

## 6. AQL / TXQS / airtime fairness 在本板的真实状态 `[本板实证]`

`iw phy phy1 info` 只报：
```
* [ TXQS ]: FQ-CoDel-enabled intermediate TXQs
```
**没有** `[AQL]`、**没有** `[AIRTIME_FAIRNESS]`。

交叉印证（LWN 2026-08-24，https://lwn.net/Articles/1090342/）`[外部实证]`：
> ath11k advertises neither `NL80211_EXT_FEATURE_AQL` nor
> `NL80211_EXT_FEATURE_AIRTIME_FAIRNESS`, and every user of either inside mac80211
> is gated on the corresponding bit. **Both mechanisms are inert on this driver**,
> and the driver keeps no queue of its own, so **on a saturated download every queued
> byte sits in the hardware queue**.

但 debugfs **有** `aql_enable=1` / `aql_threshold=24000` / `aql_txq_limit`：
```
AC	AQL limit low	AQL limit high
VO	5000		12000
BE	5000		12000
```
⇒ 这些文件是 mac80211 无条件创建的，**feature bit 没开 ⇒ 写了也无效**。
`[推断]` 对吞吐无影响；对延迟（bufferbloat）也无法通过这里调，因为机制本身是 inert。

**TXQS = 开**，mac80211 侧有 fq_codel 中间队列 ⇒ 有 CPU 成本，但这是 OpenWrt 默认，
也是 AQL 缺失情况下唯一能压延迟的东西。**不建议关**（关掉会显著恶化满载延迟）。

---

## 7. NSS 硬件卸载：能翻倍，但不可用于「长期稳定家用」`[外部实证]`

URL: https://github.com/openwrt/openwrt/issues/23798
（Redmi AX5400，ipq5018 + QCN9074，与我们是同 target）
> 5 GHz Wi-Fi associates correctly at HE80 rates, but actual Wi-Fi throughput is much
> lower than expected … `ath11k` module has no `nss_offload` parameter, so NSS Wi-Fi
> offload support is not compiled in. … practical Wi-Fi throughput is only around
> **300-500 Mbit/s** … while wired networking is normal.

> There is no open-source qca nss driver.

对照 §1.2 的 915 Mbps：那是 **NSS 闭源固件**（`qca-nss-drv` + `qca-nss-ecm` + ath11k NSS
补丁）才能达到。上游 OpenWrt 明确不支持。

**决策：不做 NSS。** 理由：
1. 闭源固件（`qca-nss0.bin`）、与 `qca-nss-dp`/ECM 深度耦合，25.12 主线无集成；
2. 与 DSA 冲突（该 thread 里 `tag_qca` 与 ECM 加速互斥，需换 `tag_8021q` tagger）；
3. 用户准则「**长期稳定家用**」—— 逐版本跟进 NSS 补丁是长期负担，且一旦内核升级就断。

---

## 8. 其余可调项的外部依据

### 8.1 `net.core.netdev_budget` / `netdev_budget_usecs` `[外部实证]`

URL: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/monitoring_and_managing_system_status_and_performance/tuning-the-network-performance_monitoring-and-managing-system-status-and-performance

> If `softirqd` processes could not retrieve all packets from interfaces in one NAPI
> polling cycle, it is an indicator that the SoftIRQs do not have enough CPU time.
> … you can control the time and number of packets `softirqd` can process in a polling
> cycle [by raising `net.core.netdev_budget` and `net.core.netdev_budget_usecs`].
> Relevant column: **Third column: the number of times `softirqd` processes that could
> not retrieve all packets from interfaces in one NAPI polling cycle.**
> If the counters in the third column … increment over time, tune the system.

**本板实测（`/proc/net/softnet_stat`，十六进制）**
```
CPU0: 0030cfb3 00000000 000027b8 ...   → 第3列 = 0x27b8 = 10168
CPU1: 0020b751 00000000 0000050d ...   → 第3列 = 0x050d = 1293
```
⇒ **CPU0 有 10,168 次「一轮没 poll 完」**，按官方判据**应该提高 budget**。
当前 `netdev_budget=300`（内核默认）、`netdev_budget_usecs=20000`。

### 8.2 `dev_weight` / `gro_normal_batch` `[外部实证]`

- `dev_weight` 默认 64（每 CPU、每次 NAPI 处理上限）。官方文档：
  https://docs.kernel.org/admin-guide/sysctl/net.html
- `gro_normal_batch` 默认 8。上游曾有提案改 16，**被否决**：
  > I found **16 to be 2% slower than 8** with my setup, so any tweaking of the default
  > is likely only worthwhile if we have data over lots of different hardware combinations.
  URL: https://lists.openwall.net/netdev/2019/10/10/239
  ⇒ **不动 `gro_normal_batch`**（无本板证据，上游有反例）。

### 8.3 NAPI 中断抑制 `napi_defer_hard_irqs` / `gro_flush_timeout` `[外部实证]`

https://docs.kernel.org/networking/napi.html
> `gro_flush_timeout` sysfs configuration of the netdevice is reused to control the
> delay of the timer, while `napi_defer_hard_irqs` controls the number of consecutive
> empty polls before NAPI gives up and goes back to using hardware IRQs.

**本板实测**：这两个文件在 `phy1-ap0` 上**可写**（写 1 成功）。但 ath11k 的 NAPI 挂在
匿名 dummy netdev 上（§5），写 `phy*-apN` 的属性**很可能不作用于 ath11k 的 NAPI**
⇒ 标 `[未验证]`，不纳入固化。

### 8.4 `CONFIG_HZ` / 抢占模型 `[上游代码]` + `[外部实证]`

本板内核 `.config`：`CONFIG_HZ_100=y`、`CONFIG_PREEMPT_NONE=y`。

上游明确决策：`3326b5e7` *treewide: switch the timer frequency to 100 Hz*
> Some targets select HZ=100, others HZ=250. **There's no reason to select a higher
> timer frequency** (and 100 Hz are available in every architecture), so change all
> targets to 100 Hz.

反向证据（论坛经验帖，"like Linksys did"）`[外部实证]`
> - elevate the CPU frequency to reduce latency
> - build a **preemptive kernel**
> - build an idle tickless kernel at **500 Hz**
> - enable and use BBR congestion control as default

**结论：不改。** 理由：① 上游有明确理由选 100；② 本板无 cpufreq（频率锁定），
「提频」做不到；③ 抢占模型影响延迟不影响吞吐，而「长期稳定家用」优先稳定性；
④ 无本板 A/B 数据。`[推断]` 收益低于风险。

### 8.5 BBR 对 WiFi 是**负优化** `[外部实证]`

URL: https://forum.openwrt.org/t/tcp-bbr-impacts-the-wifi-performance/11307
> I tested … the download throughput is always significantly lower than the upload …
> Finally, I remember I've changed the TCP congestion algorithm to **BBR** … After
> changed it back to "cubic". The performance also come back.
> … BBR 开发组原文：where the current upstream BBR parameters for provisioning cwnd
> need to be **more generous for paths like wifi LAN paths**, which have ACKs that are
> often delayed much longer than the minimum RTT observed over the path

**结论：不启用 BBR。** 本板当前 `tcp_congestion_control=cubic` 保持不变。

### 8.6 `br_netfilter` 桥转发开销 `[上游代码]`

URL: https://git.cdn.openwrt.org/openwrt/openwrt/plain/package/kernel/linux/files/sysctl-br-netfilter.conf
OpenWrt 默认就关：
```
net.bridge.bridge-nf-call-arptables=0
net.bridge.bridge-nf-call-ip6tables=0
net.bridge.bridge-nf-call-iptables=0
```
**本板实测**：`lsmod | grep br_netfilter` 为空 ⇒ 模块未加载，`/proc/sys/net/bridge/*`
不存在。⇒ **无桥转发开销，无需处理**。

### 8.7 flow offloading 对本板无用（已知）`[本板实证]`

本板 `uci show network` 里**没有 WAN**，5 个口全在 `br-lan` 桥里。
flow offloading 只作用于 **forward（路由）**，对 bridged 流量与 AP 自身收发无效。
⇒ 与 `docs/P24-WIFI-5G-PERF.md` 的既有结论一致，**不启用**。

### 8.8 zram / swappiness `[外部实证]`

本板已有 zram swap 49 MB（`swap 49148 / used 2800`）、`vm.min_free_kbytes=4096`。
社区 256MB 优化脚本常设 `vm.min_free_kbytes=8192` + `vfs_cache_pressure=200`：
https://www.nodeloc.com/t/topic/95974

`[推断]` 这是为「跑代理/Rule 集」的弱机准备的，本板内存审计（P23）已闭合且无 OOM。
**不盲改**：`min_free_kbytes` 调大会减少可用内存，本板可用内存本来就只有 47 MB。

---

## 9. 板级差异表（外部结论 → 本板是否成立）

| # | 外部环境 | 外部结论 | 本板 | 同/不同 | 处理 |
|---|---|---|---|---|---|
| 1 | MR80X v2.20（ipq5018+qcn6122，RTL8367S HSGMII 2.5G） | CPU 口跑 2.5G | **SGMII 1G**（HSGMII 起不来，DTS 已记） | **不同** | 有线上限 1G，不追求 2.5G |
| 2 | AX55v1 + NSS | WiFi 915 Mbps / CPU 1-3% | 无 NSS，纯 CPU | **不同** | 不以 915 为目标 |
| 3 | 论文平台 RPi4（4 核 A72，iwlwifi） | E2W 单核瓶颈 | 2 核 A53，ath11k | **核数不同，结论同向** | 认领该结论，但量级按本板重测 |
| 4 | 论文平台 | WiFi 驱动用 **threaded IRQ** | ath11k 用普通 IRQ + 无 NAPI 线程 | **不同** | 论文的线程亲和性做法**不适用**本板 |
| 5 | MT7621+MT7915（4 核，有 `napi/phy-*` 线程） | 亲和性 634→732 | 无 NAPI 线程，只能调 IRQ | **不同** | 只采用 `packet_steering='2'` |
| 6 | 上游 packet-steering.uc | `'2'` → `rps_cpus=3` | 本板实测一致 | **同** | ✅ 采纳 |
| 7 | ath11k threaded NAPI | 曾 +400 Mbps（WCN6750 160MHz） | 被 revert；本板未启用；可写但需改驱动 | **部分同** | `[未验证]` 不纳入首批 |
| 8 | LWN：ath11k 无 AQL/ATF | 机制 inert | `iw phy` 确认无 AQL 位 | **同** | 不调 AQL |
| 9 | RedHat：提高 netdev_budget | 第3列增长则调大 | 第3列 CPU0=10168 | **同** | ✅ 采纳 |
| 10 | 上游：gro_normal_batch 16 被否 | 保持 8 | 8 | **同** | 不动 |
| 11 | 上游：HZ=100 treewide | 100 足够 | 100 | **同** | 不动 |
| 12 | 论坛：BBR 伤 WiFi | 用 cubic | cubic | **同** | 不动 |
| 13 | OpenWrt br_netfilter 默认关 | 无桥开销 | 模块未加载 | **同** | 无需处理 |
| 14 | 本板无 WAN，全桥 | flow offload 只作用 forward | 同 | — | 不启用 |

---

## 10. 由本表导出的优化集（按证据强度排序）

| 优先级 | 项 | 证据 | 状态 |
|---|---|---|---|
| **P0** | `network.globals.packet_steering='2'` + `steering_flows=4096` | 上游代码 + 同款双核案例 + 本板实测 rps=3 | 已在本板验证 |
| **P0** | 删掉自建 `rps-watch`（与上游打架） | 上游脚本会覆盖 rps_cpus | 待改 |
| **P1** | `net.core.netdev_budget` 300→1000 | RedHat 判据 + 本板 time_squeeze=10168 | 待验证 |
| **P1** | ath11k 32 个 IRQ 全在 CPU0 → 部分移到 CPU1 | 本板实测可移动 + 论文 E2W 单核瓶颈 | 待 A/B |
| **P2** | `dev_weight` 64→128 | 内核文档语义 | 待 A/B，收益不确定 |
| **P3** | threaded NAPI（改驱动 +1 行） | 上游曾 +400Mbps，但被 revert | `[未验证]` 风险项 |
| — | 无线 161/HE80/cell_density2、2.4G ch6 HT40 noscan | P24 已实证 | 已完成 |
| ✗ | NSS、BBR、HZ、PREEMPT、gro_normal_batch、AQL、flow offload | 见 §6~§8 | 明确不做 |
