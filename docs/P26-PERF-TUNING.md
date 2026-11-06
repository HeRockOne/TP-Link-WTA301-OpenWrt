# P26 —— 性能优化：从「逐个试」到「一次成集」

> 用户指示：「你搜索联网看看 op 性能优化，比如无线，网线，cpu 占用，结合机器实际去优化，
> 再开始编译，**不要挤牙膏**」
>
> ⇒ 本文档是**一次性、成体系**的优化集，外部证据全部落档在
> `docs/R20-PERF-EXTERNAL-EVIDENCE.md`，每条都能追到 URL 与本板实测。

---

## 1. 结论先行：本板的瓶颈在哪（已实证）

| 层 | 事实 | 证据 |
|---|---|---|
| CPU | **2 核** Cortex-A53，**无 cpufreq**（频率锁定） | `/proc/cpuinfo`、无 `/sys/devices/system/cpu/cpufreq` |
| 内存 | 256 MB 物理 → **174 MB managed** → 可用 ~47 MB | P23 |
| 有线 | RTL8367S 交换机，CPU 口 **SGMII 1 Gbps**（HSGMII 起不来） | `eth0 speed=1000`；DTS 注释 |
| 有线转发 | **5 个口全在 `br-lan` 桥里，没有 WAN** | `uci show network` |
| 无线 | ath11k，**每射频只有 1 个 RX 队列** | `ls .../queues/rx-*` |
| 无线中断 | **32 个 IRQ（44~75）全部打在 CPU0**，eth0(22) 也在 CPU0 | `/proc/interrupts` |
| softirq | CPU0 **10,168 次**「一轮 poll 不完」，CPU1 1,293 次 | `/proc/net/softnet_stat` 第 3 列 |
| 吞吐 | 5G 板→手机 **590 avg / 675 峰值**，同期 CPU 79~80% | P24 |
| E2W 本质 | **有线→WiFi 路径天然单核**（论文结论 iii） | R20 §2 |

**⇒ 瓶颈是「单核被 E2W 打满」，不是空口、不是内存、不是法规。**

---

## 2. 优化集（只做有证据的）

### 2.1 `packet_steering='2'`（上游机制，取代自建脚本）

```
uci set network.globals.packet_steering='2'
uci set network.globals.steering_flows='4096'
```

- OpenWrt 25.12 自带 `/usr/libexec/network/packet-steering.uc`；`'2'` 走
  `all_cpus` → `cpu_mask(-1)` → `rps_cpus=3`（两核）。
- 上游默认 `'1'` 的语义是「亲和到处理中断那颗 CPU」；论坛原文：
  「**for routers with 2 or 4 cores this can be suboptimal** … this is why the
  "on all CPUs" option can be helpful.」
- **删掉我们自建的 `rps-watch`**：论坛原话「the steering scripts will overwrite them」，
  自己写 `rps_cpus` 是跟上游打架。上一版 rps-watch 就是这样失效的。

本板实测结果：
```
phy0-ap0 rps_cpus=3   phy1-ap0=3   eth0=3   phy*: rps_flow_cnt=4096
```

### 2.2 `eth0` 的 IRQ 从 CPU0 挪到 CPU1

这是本轮**最大的新杠杆**。

- 现状：32 个 ath11k IRQ + eth0 全在 CPU0，CPU1 只做 RPS 软处理。
- 同款双核 ath10k 实证（OpenWrt 论坛 221783）：
  「I assigned **core1 to eth0** and that made a boost to wifi speeds upto
  **350 mbps** *(from 250)* … all ethernet interrupts are now serviced by
  core 1 so **core 0 has more room**.」
- 学术同向（arXiv 2408.01013 结论 iii）：
  「E2W path does not utilize multi-core processing. This limitation can result in a
  throughput drop **if the core assigned to the Ethernet NIC cannot handle the
  maximum supported throughput of the two NICs**.」

**实现要点（踩过的坑）**
1. IRQ 号每次启动会变 ⇒ **按名字**从 `/proc/interrupts` 查，不写死。
2. DSA 交换机 probe 完成前 `eth0` 不存在 ⇒ 开机先等它出现。
3. `smp_affinity` 写 2 后 `effective_affinity` 才会变；只写 `smp_affinity` 不够。

本板实测（写入后）：
```
eth0 irq22: smp_affinity_list = 1, effective_affinity_list = 1
/proc/interrupts: 22:  13553(CPU0)   24(CPU1)    ← 已开始往 CPU1 走
```

### 2.3 `net.core.netdev_budget` 300 → 1000

RedHat 官方判据：`/proc/net/softnet_stat` 第 3 列持续增长 ⇒ 提高 budget。
本板 CPU0 第 3 列 = **10,168** ⇒ 明确超预算。

配套 `rps_sock_flow_entries = 4096`（与 `steering_flows` 对齐，防哈希冲突退化）。

---

## 3. 明确不做的事（都查过，理由写清）

| 项 | 为什么不做 | 出处 |
|---|---|---|
| **NSS 硬件卸载** | 能到 915 Mbps 但需闭源 `qca-nss0.bin` + ECM，与 DSA 冲突（`tag_qca` 与 ECM 互斥），25.12 主线无集成；违背「长期稳定家用」 | R20 §7 |
| **threaded NAPI** | 上游 `13aa2fb` 合入后因 QCN9074 破坏被 `d265ebe` revert；本板 NAPI 挂在未注册 dummy netdev 上，sysfs 写不进去，只能改驱动 ⇒ `[未验证]` 高风险 | R20 §5 |
| **AQL / airtime fairness** | `iw phy` 无该 feature 位，mac80211 内相关逻辑全被 feature bit 门控 ⇒ **机制 inert** | R20 §6 |
| **BBR** | 论坛实证：开 BBR 后 WiFi 下行显著变慢（BBR v1 对 WiFi 的延迟 ACK 不友好），改回 cubic 即恢复 | R20 §8.5 |
| **CONFIG_HZ / 抢占模型** | 上游 `3326b5e` 明确统一 100Hz 并给了理由；本板无 cpufreq 无法提频；无本板 A/B 数据 | R20 §8.4 |
| **`gro_normal_batch=16`** | 上游提案被否，理由是「16 比 8 慢 2%」 | R20 §8.2 |
| **flow offloading** | 只作用于 **forward（路由）**；本板无 WAN、全桥，对 bridged 流量与 AP 自身收发无效 | R20 §8.7 |
| **`br_netfilter`** | 本板未加载该模块，无桥转发开销，无需处理 | R20 §8.6 |
| **zram / min_free_kbytes 加码** | 本板可用内存仅 ~47 MB，调大 `min_free_kbytes` 是净损失；P23 已闭合无 OOM | R20 §8.8 |
| **2.5G HSGMII** | DTS 已记「every attempt to raise it lost the link」，硬件/SerDes 限制 | DTS 注释 |
| **HE160** | 客户端只支持 80MHz；实测开 160 后 busy 0.4%→63%、expected −19% | P24 |
| **改 txpower / 国家码提功率** | BDF 硬限 24 dBm，与法规无关 | P24 |

---

## 4. 固件落地位置（开箱即用，不靠用户 shell）

| 文件 | 内容 | 归属 |
|---|---|---|
| `files-base-files/etc/config/wireless` | 5G `161/HE80/cell_density 2`；2.4G `11/HT20/cell_density 2`（**无 noscan**）；不设 txpower（驱动默认=上限） | base-files |
| `files-base-files/etc/uci-defaults/99-wta301-wireless` | 上述配置的第二层兜底 | base-files |
| `files-base-files/etc/uci-defaults/99-wta301-net` | `packet_steering=2` + `steering_flows=4096` | base-files |
| `files-rootfs/etc/sysctl.d/99-wta301-net.conf` | `netdev_budget=1000`、`rps_sock_flow_entries=4096` | rootfs |
| `files-rootfs/usr/sbin/net-tune` | eth0 IRQ → CPU1 看护（按名字查 IRQ，5 秒自检） | rootfs |
| `files-rootfs/etc/init.d/net-tune` | procd 服务（respawn） | rootfs |
| `/etc/rc.d/S99net-tune` | 开机启用（构建期建链接） | 构建期 |

**为什么 IRQ 那项必须用常驻脚本**：IRQ 号每次启动会变，且 DSA probe 早于/晚于
不一定；`sysctl` 和 `uci` 都表达不了「按名字找 IRQ 再写位图」。其余两项都是声明式的。

---

## 5. 验收判据（刷机后不做任何 shell 操作）

```sh
# A1 packet steering
uci get network.globals.packet_steering          # 2
cat /sys/class/net/phy1-ap0/queues/rx-0/rps_cpus # 3
cat /sys/class/net/phy1-ap0/queues/rx-0/rps_flow_cnt # 4096

# A2 eth0 IRQ 在 CPU1
EIRQ=$(awk '/eth0$/ { sub(":","",$1); print $1; exit }' /proc/interrupts)
cat /proc/irq/$EIRQ/effective_affinity_list      # 1

# A3 budget
cat /proc/sys/net/core/netdev_budget             # 1000

# A4 服务在跑
ps w | grep net-tune                             # /bin/sh /usr/sbin/net-tune
ls -l /etc/rc.d/S99net-tune                      # -> ../init.d/net-tune

# A5 无线
iw dev phy1-ap0 info | grep -E 'channel|width'   # 161 (5805 MHz), 80 MHz
iw dev phy0-ap0 info | grep -E 'channel|width'   # 6 (2437 MHz), 40 MHz, center1 2447

# A6 无残留（旧 rps 三件套必须都消失）
ls /usr/sbin/rps-watch /etc/init.d/rps 2>&1 | head  # No such file
```

---

## 6. 测量注意事项（血泪）

1. **信号必须可比**。同一台手机，`-19 dBm` 与 `-56 dBm` 的 expected 差 887 vs 609，
   拿来比吞吐毫无意义。每次测试**先记 `iw station dump` 的 signal 与 expected**。
2. **不要用 `tx bytes` 差分算吞吐**（含重传，曾算出 1549 Mbps 超协商上限）。用 iperf3 数字。
3. **CPU 79~80% 可能是低估**：论文 Observation 10 指出 TH 后立即执行的 softirq
   会被记成 idle。判断瓶颈要看 `softnet_stat` + 实测吞吐，不看 top。
4. 手机侧上行（173.4 Mbps）是手机限制，测不出来；只测板→手机方向。
5. 笔记本 lan1 只协商 100 Mbps，**不能用笔记本做有线端打流**。

---

## 7. 待补的 A/B 数据（下一轮）

| 实验 | 单一变量 | 判据 |
|---|---|---|
| E1 | 本轮全开 vs 上轮基线（590） | 同信号下 iperf3 平均 |
| E2 | eth0 IRQ CPU0 vs CPU1 | 同上 |
| E3 | `netdev_budget` 300 vs 1000 | 同上 + `softnet_stat` 第3列增量 |
| E4 | `packet_steering` 1 vs 2 | 同上 |

**一个变量一次（AGENTS §2）**，每次只改一项，记信号与 expected。
---

## 8. 决策变更记录：2.4G 回退 HT20（用户拍定）

**原方案**：`ch6 / HT40 / noscan=1`（速度优先）
**现值**：`ch11 / HT20 / 无 noscan`（稳定优先）

### 为什么换信道（6 → 11）

同为 HT20，实测差距很大：

| 信道 | 模式 | 实测吞吐 |
|---|---|---|
| ch6 | HT20 | 约 **20 Mbps**（被 CTS protection 压着，邻频一堆） |
| ch11 | HT20 | **66 / 49 / 26 Mbps**（expected 126.6） |

⚠️ 早期「ch11 比 ch6 干净 97 倍」的结论是**方法错误**——拿「在用信道的累计 busy」
去比「非在用信道的 150ms 采样」。正确做法是**同信道两次 survey 差分**。
修正后 ch6 空载 10 秒：busy 95%，其中自身 rx+tx 只占 48%，**他人占 46%**。

### 为什么放弃 HT40

- 不加 `noscan`：hostapd 直接报
  `20/40 MHz operation not permitted on channel pri=6 based on overlapping BSSes`
  → 回落到 20MHz + CTS protection，等于白折腾
- 加 `noscan=1` 能强开 40MHz，但会挤邻居（扫到 ch1=4 个、ch11=4 个 AP）
- **家用长期稳定优先** ⇒ 选 HT20

### 想要 40MHz 自己改（uci-defaults 幂等，重启不会改回去）

```sh
uci set wireless.radio0.htmode='HT40'
uci set wireless.radio0.noscan='1'
uci commit wireless && wifi reload
```

### 本次改动实测确认（板上 192.168.1.1）

```
channel 11 (2462 MHz), width: 20 MHz, center1: 2462 MHz   ✓
5G 不受影响: channel 161 (5805 MHz), width: 80 MHz        ✓
```

### ★ 附带发现：`rps_cpus` 扛住了 `wifi reload`

改完 2.4G 后跑 `wifi reload`，复查：

```
phy0-ap0 rps=3   phy1-ap0 rps=3   eth0 rps=3   br-lan rps=0
```

**全部保持 3**。这推翻了我原来的判断（需要自建 `rps-watch` 看护）。
根因：上游 `packet_steering` 注册了 `procd_add_reload_trigger network wireless`，
`wifi reload` 会重新跑它。**自建的 rps-watch 反而是多余且有害的**（两边互相覆盖）。

`br-lan rps=0` 是正常：上游脚本跳过带 `lower_*` 属性的主设备。
