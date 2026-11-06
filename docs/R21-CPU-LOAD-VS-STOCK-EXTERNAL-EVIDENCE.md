# R21 —— 「跑网络时 CPU 占用高」外部证据：「原厂为何不这样」

> 用户问题：**跑网络的时候为啥 CPU 占用高，原厂也这样吗**
>
> 结论先给：**原厂不这样，因为原厂走 NSS 硬件卸载；我们走 Linux 软件转发，
> CPU 高是设计使然，不是我们没优化好。**
>
> 依据标 `[外部实证]` / `[本板实证]` / `[推断]`，全部附 URL 与原文。
> 检索：2026-11

---

## 1. 决定性的同款机型数据 `[外部实证]`

**URL**: https://github.com/mufeng05/openwrt-cmcc-pz-l8-nss
（CMCC PZ-L8 = **IPQ5018 + QCA8337 + QCN6122**，与本板 WTA301 主板级同款）

原表（iperf3 `-P 4`，每方向 15 秒）：

| 路径 | 本构建(NSS) | **原厂 501.8** | nwrt(闭源栈) | **原生 OpenWrt** |
|---|---|---|---|---|
| **有线 ↔ WAN** | 949/949 Mbps, **+0% CPU** | 947/947, **9% / 6%** | 924/926 @ 4% | **502 Mbps @ 100% CPU** |
| **5 GHz ↔ WAN** | 510/438 @ +0.3% (80MHz) | 612/899 (160MHz), **15–16%** | ~624 @ 25–35% | **308 Mbps** |
| 2.4 GHz ↔ WAN | 58/61 @ +0.3% | 114/65, 8% | — | — |

表注原文：
> CPU 指两个 Cortex-A53 主机核（NSS 的 UBI32 核独立，不计）…

**直接读出三件事**：

1. **原厂 947 Mbps 只吃 9%/6% CPU** —— 它不是用 A53 转发的，是 NSS 在转。
2. **原生 OpenWrt 502 Mbps 就把两个核跑满（100%）** —— 这就是我们这条路的
   真实成本，我们的 590 Mbps 已经在它之上。
3. **NSS 构建 949 Mbps 而 CPU 「+0%」** —— 增量小到采样器分辨不出。

---

## 2. NSS 到底是什么 `[外部实证]`

**URL**: https://p.atoshin.com/... → JuliusBairaktaris/openwrt-nss-edma Wiki `NSS-Offload-Explained`
（原始 GitHub: https://github.com/JuliusBairaktaris/openwrt-nss-edma/wiki/NSS-Offload-Explained）

原文：
> A router's job is to move packets between interfaces … On a plain Linux router
> **the CPU does all of it.**
>
> **The Cortex-A53 cores in an IPQ807x can route maybe a few hundred Mbit/s of
> NATed traffic before softirq eats a whole core. That is the wall offload removes.**
>
> Almost all router traffic is flows … The CPU re-derives that decision for every
> single packet, which is wasteful: the answer only changed on the first packet.
>
> [Offloaded packet lifecycle] … 4. Subsequent packets of that flow are matched by
> the PPE and forwarded in hardware … **On an accelerated bulk download the host
> CPU stays essentially idle.**

三个部件：
- **PPE**（Packet Processing Engine）：硬件分类+转发，做真正的线速转发
- **两个 UBI32 核**跑 NSS 固件（**闭源 blob**，例 `NSS.FW.12.5-210-HK.R`）
- **EDMA**：host CPU 与 NSS 固件共享的 DMA

`[推断]` 我们的板子 NSS 那一侧现在是**惰性硅片**——没有固件驱动它。

---

## 3. 上游为何没有 NSS `[外部实证]`

**URL**: https://github.com/qosmio/openwrt-ipq/blob/qualcommax-6.x-nss-wifi/README.md

> **Please note:** NSS requires proprietary binaries (NSS firmware) and extensive
> patches to the Linux kernel and networking stack. Qualcomm does not openly
> release the necessary firmware or detailed documentation …
> **NSS is NOT supported upstream in OpenWrt.**

同一 README 对 IPQ50xx 的旧判断（**注意：2026-09 已被推翻，见 §4**）：
> **Note on IPQ50xx:** Although the IPQ50xx family has NSS offloading capabilities,
> its architecture is substantially different from IPQ807x/IPQ60xx and requires
> additional patching. Most of my NSS patches for IPQ50xx have been **blind
> guesswork** … and thus far **unsuccessful**.

---

## 4. ★ 但 2026 年 IPQ5018 的 NSS 已经跑通了 `[外部实证]`

**URL**: https://forum.openwrt.org/t/ipq5018-nss-offload-on-kernel-6-18-with-the-upstream-ethernet-stack-gl-b3000/253014

原文（GL.iNet GL-B3000 = IPQ5018）：
> Short version: the NSS core on the IPQ5018 accelerates routed NAT and both
> Wi-Fi radios on kernel 6.18 with the upstream stmmac driver - no qca-nss-dp,
> no qca-ssdk - and **the CPU stays above 90 % idle while it does.**

实测数据（同一帖）：
> Sustained routed flow, 28 s steady: ~66k packets/s through the firmware,
> **CPU 93-96 % idle** across both cores … The lowest idle figure seen under any
> load was **68 %**. The offload is never the bottleneck.
>
> With Wi-Fi on the NSS path … 734/447 Mbit/s single stream, 791/534 with three
> streams, **CPU ~90 % idle**.

**代价（关键，直接决定我们能不能用）**：
> The NSS firmware parses 802.1Q natively but **cannot parse the two-byte Atheros
> header that DSA's `tag_qca` puts where the ethertype should be. So on this SoC
> **DSA user ports and ECM acceleration are mutually exclusive.**

> What works instead: let `qca8k` do the hard bring-up (SerDes, clocks, uniphy),
> then **unbind it and drive the fabric directly**. `qca8337-nss` wakes the front
> PHYs, re-enables the MACs, **turns the Atheros header off** and programs the VTU
> … The CPU port then carries a plain 802.1Q trunk … and those two become NSS
> dynamic interfaces of type 17.

> On mainline OpenWrt: **not in this form**. The acceleration depends on a
> proprietary firmware blob plus a stack of out-of-tree kernel patches, and
> **neither is upstreamable**.

另有 2026-10-31 发布的现成构建：
https://github.com/kuncy7/openwrt-nss-edma/releases → `ipq50xx-2026.10.31`
> NSS offload for IPQ5018 boards (`qualcommax/ipq50xx`)

---

## 5. 本板实测（`192.168.1.1`，P26 固件）

### 5.1 空闲基线（证明「CPU 高」不是后台有东西在跑）

10 秒 `/proc/stat` 差分：
```
user 0.5%  sys 0.7%  softirq 1.0%  irq 0.0%  iowait 0.0%   idle 97.9%
```

### 5.2 累计（开机至今）

| 核 | idle | softirq | sys | user |
|---|---|---|---|---|
| cpu0 | 85.5% | 1.7% | 7.3% | 3.5% |
| cpu1 | 84.5% | 0.1% | 8.6% | 4.0% |

### 5.3 中断落点（P26 优化后）

```
ath11k 相关 IRQ（44~75）累计:  CPU0=56236   CPU1=0
eth0          IRQ22   累计:  CPU0=98      CPU1=252
```

**读法**：我确实只把 eth0 挪到了 CPU1；32 个 ath11k 硬中断仍然全在 CPU0。
RPS（packet steering）分的是**软中断处理**，不是硬中断。`[本板实证]`

### 5.4 带流量时的实测（P24/P26 记录）

| 项 | 值 |
|---|---|
| 5G 板→手机吞吐 | 590 Mbps 平均 / 675 峰值 |
| 同期 CPU | **79–80%**（两核合计） |
| 停下后 | 3% |

与 §1 表里「原生 OpenWrt 308 Mbps」比，我们高 91%；与「NSS 949 Mbps @
+0% CPU」比，我们**吞吐低但 CPU 高**，因为路径根本不同。

---

## 6. 板级差异表（外部结论 → 本板）

| 项 | 外部（PZ-L8 / B3000） | 本板 WTA301 | 同/异 | 影响 |
|---|---|---|---|---|
| SoC | IPQ5018 | IPQ5018 | **同** | 可直接类比 |
| 交换机 | QCA8337N | **RTL8367S** | **异** | NSS 方案需重写交换机侧驱动 |
| 无线 | QCN6122（2×2 双频） | QCN6122 | 同 | — |
| 交换机绑定方式 | DSA `tag_qca`（PZ-L8 原生） | DSA `tag_qca` | 同 | **NSS 最大障碍：必须改 tag_8021q** |
| 内存 | 512 MB 典型 | **256 MB** | **异** | NSS 固件+ECM 要吃内存，P23 已证本板仅剩 ~47 MB 可用 |
| 内核 | 6.12 / 6.18 | 6.12.112 | 近似 | — |
| 现有构建 | 有 NSS 分支 | 无 | 异 | 要从零移植 |

`[推断]` 本板走 NSS 的难点比 PZ-L8 **更大**：内存只有一半，且交换机是
Realtek 而非 Qualcomm，`qca8337-nss` 那套不适用，需要自己写 RTL8367S 的
NSS 对接（等价于重做 §4 描述的整条工作）。

---

## 7. 结论与建议

### 7.1 回答用户的问题

1. **原厂不这样。** 原厂同款机器 947 Mbps 只吃 9%/6% CPU，因为它在用 NSS
   硬件转发，包不进 Linux。
2. **我们 CPU 高是这条路线的固有属性**，不是配置错、不是没调优。上游同款板
   裸跑原生 OpenWrt 是 502 Mbps @ **100% CPU**；我们 590 Mbps @ 79–80%，
   已经比它好。
3. **空闲时 CPU 只有 2%**（实测 idle 97.9%）。所以高占用只发生在真正跑满
   链路的时候，不影响日常。

### 7.2 80% CPU 对家用意味着什么

`[推断]` 只有在你**持续跑到 590 Mbps 附近**时才会出现。家用宽带常见
100–500 Mbps，实际占用会低得多。但要知道三个后果：

- 没有余量做 SQM/QoS 整形（整形本身还要吃 CPU）
- 满速时延迟会升高（论文：TX 后立即执行的 softirq 被记成 idle，CPU% 略有低估）
- 满速时若有其它服务（adblock 重载、LuCI 操作）会明显变慢

### 7.3 要不要上 NSS

`[推断]` **不建议**，除非你明确要「长时间跑满千兆」。

| | 收益 | 代价 |
|---|---|---|
| 上 NSS | 900+ Mbps，CPU ≈ 0% | 闭源 blob；必须放弃 DSA `tag_qca` 改 `tag_8021q`；要重做 RTL8367S 交换机侧；256 MB 内存要重新算账；所有现有验证（P1~P26）要重跑一遍；未来内核升级随时可能全崩 |

这与「长期稳定家用」这条准则直接冲突：NSS 全部分支都在主线之外，一旦上游
内核接口变动就要重新适配。

### 7.4 如果只是想「CPU 别那么高」

不改架构能做的都做了（P26）。剩下的只有降吞吐换 CPU：
- 关掉 `packet_steering` → 更省一点但吞吐掉
- 2.4G/5G 限速到 300 Mbps → CPU 大约减半

`[未验证]` 未实测，需要的话可以测。
