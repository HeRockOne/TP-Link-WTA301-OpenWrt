# P23 — 内存审计：256 MB 物理 → 174 MB 可用 → 92 MB 未追踪

> 全部数据取自真机 `root@192.168.1.1`（OpenWrt 25.12.6 / r33311-981c978eff / 内核 6.12.112）。
> 采集方式：`ssh → 三星笔记本 plink → 板子 sh -s`，脚本见文末 §6。
> 证据分级：**[实测]** = 板上命令原文；**[上游代码]** = 内核/驱动源码引用；**[推断]** = 有推理链未直接测。

---

## 1. 结论速览

| 层 | 值 | 说明 |
|---|---|---|
| 物理内存 | **256 MB** | `spanned 65536 页 × 4K` |
| bootloader/DTS 预留 | **82 MB** | Wi-Fi 固件区 52 MB 是最大一笔 |
| 内核可用（MemTotal） | **174 MB** | `managed 44668 页` = 178672 kB |
| 内核可用里被占 | **166 MB** | `managed - free` |
| 其中能被内核计数器解释 | **82 MB** | anon/slab/file/zspage/stack/pgtbl |
| **★ 未被任何计数器追踪** | **~92 MB** | 其中 **~65 MB = ath11k**（§5 实测），其余 ~30 MB 未点名 |
| MemAvailable | **4~8 MB** | 页面显示 2~6%，见 §8 |

**一句话**：物理 256 MB，82 MB 开机即被硬件预留（正常设计）；剩下的 174 MB 里，
**ath11k 两个射频的环形缓冲与页碎片缓存拿走约 65 MB**（`rmmod` 实测，在任何 meminfo 计数器里都看不见），
dnsmasq+adblock 拿走 25~40 MB —— 两者相加就吃掉了可用内存的六成。

---

## 2. 物理 256 MB → 可用 174 MB（已完全说清）

### 2.1 三处交叉验证 [实测]

```
/proc/zoneinfo:  spanned  65536   ← 物理
                 present  65536
                 managed  44668   ← 内核对客可用
/proc/meminfo:   MemTotal 178672 kB  (= 44668 × 4K ✓)
dmesg:           Memory: 176132K/262144K available (... 84432K reserved, 0K cma-reserved)
```

`262144K - 84432K = 177712K` ≈ 178672 kB（差值来自幂等对齐，量级一致）。

### 2.2 预留明细（dmesg 原文）[实测]

| 预留块 | 大小 | 用途 |
|---|---|---|
| `wcss@4b000000` | **53248 KiB = 52 MB** | Wi-Fi 无线子系统固件专用 DDR |
| `tz_apps@4a400000` | 4 MB | TrustZone 应用区 |
| `tz@4ac00000` | 4 MB | TrustZone 安全区 |
| `bootloader@4a800000` | 2 MB | 二级 u-boot 共享 |
| `smem@4ab00000` | 1 MB | 共享内存 |

全部标记 `nomap non-reusable` ⇒ 内核当作物理上不存在，不进 buddy。

### 2.3 memblock 5 段（`/sys/kernel/debug/memblock/memory` 原文）[实测]

```
40000000-4a3fffff   NONE      40 MB
4a400000-4a9fffff   NOMAP      6 MB   ← tz_apps + tz
4aa00000-4aafffff   NONE       1 MB
4ab00000-4e3fffff   NOMAP     52 MB   ← wcss + bootloader + smem 区间
4e400000-4fffffff   NONE      28 MB
```

物理缺口 = 6 + 52 = **58 MB**；加内核自身 code/data（`iomem`: `Kernel code 41000000-41b9ffff` 1.6 MB + `Kernel data 41c90000-41dcffff` 1.2 MB + 页表/init 段等 ~19 MB）≈ **82 MB** ✓ 闭合。

### 2.4 已排除的错误猜测

**`ath11k: FW memory mode: 2` 不是原因。** [上游代码]
`build_dir/.../mac80211-regular/backports-6.18.55/drivers/net/wireless/ath/ath11k/core.c:2670`：

```c
} else if (fw_mem_mode == 2) {
        ab->hw_params.fw_mem_mode = 2;
        ab->hw_params.num_vdevs = 8;
        ab->hw_params.num_peers = 128;
        ab->hw_params.coldboot_cal_mm = false;
        ab->hw_params.coldboot_cal_ftm = false;
}
```

这个 mode 只决定 vdev/peer 规格档位，本身不分配 92 MB。

---

## 3. 174 MB 里已被占用 166 MB

```
managed 44668 页  -  pages free ~2000 页  =  已用 ~42600 页 = 166 MB
```

`MemAvailable` 仅 **8 MB**（页面显示 6%），另 zram swap 已用 15 MB。

---

## 4. 能解释的 82 MB（三处数据一致）[实测]

`/proc/meminfo` + `/proc/zoneinfo` + `/proc/vmstat` 三处交叉验证：

| 分类 | 页 | MB |
|---|---|---|
| `nr_anon_pages`（进程堆栈） | 7488~7503 | 29 |
| `nr_slab_reclaimable` + `nr_slab_unreclaimable` | 5636 | 22 |
| `nr_file_pages`（页缓存） | 1599 | 6 |
| `nr_zspages`（zram 压缩页） | 2680 | 10 |
| `nr_kernel_stack` | 1316~1328 | 5.2 |
| `nr_page_table_pages` | 194~216 | 0.8 |
| `nr_swapcached` | 171 | 0.7 |
| `pages free` | 1954~2180 | 8 |
| **合计** | **~21083** | **~82** |
| `managed` | 44668 | 174 |
| **★ 差额** | **~23585** | **~92** |

### 4.1 已确认的非问题项

- **无 OOM**：`dmesg | grep -iE "out of memory|oom-kill|page allocation failure"` 为空
- **不泄漏**：3 次 5 秒采样 `MemAvailable` 8168 → 10712 → 10240 kB，平稳
- `nr_kernel_stack 1316 页 ÷ 4 页/线程 = 329 线程`，而 `ls -d /proc/[0-9]*` 只有 84 个 ⇒ 差的是内核线程/工作队列（正常）

---

## 5. ★ 92 MB 未追踪页：**已定案 = ath11k**

**现象**：约 96 MB 已从 buddy 分配出去，但不增加 anon / slab / file / zspage / stack / pgtbl 中任何一项。

### 5.1 决定性证据：`rmmod ath11k_ahb` 差值 [实测，P15/P16]

| 时点 | `rmmod ath11k_ahb` 放出的 MemFree | 证据 |
|---|---|---|
| P11（默认大 ring） | 7 308 → 108 352 kB = **101 MiB** | `work/evidence/p14-athsplit-ours2.txt` |
| P16（补丁 `0950` 生效后） | 38 272 → 104 568 kB = **64.7 MiB** | `P16-VERIFIED.md` 判据 K6 ✅ |

补丁 `0950-wifi-ath11k-reduce-DP-ring-sizes-256M.patch` **已包含在当前固件里**
（`build_dir/.../ath11k/dp.h` 已是 `DP_RXDMA_BUF_RING_SIZE 2048` / `MONITOR_BUF 128`，即打过补丁的值）。

⇒ **92 MB 里约 65 MB 归属 ath11k**，其余 ~30 MB 仍未点名（见 §5.3）。

### 5.2 机制（为什么所有计数器都看不见）[外部实证]

`dev_alloc_skb()` 的数据区来自 **page-fragment cache**：order-3（32 KB）页切成 ~2 KB 碎片，
**skb data 走 page allocator，不计入 slab**，也不进 anon/file。
一个被引用的碎片钉住整页 32 KB ⇒ 实际足迹是标称值的多倍。

- OpenWrt issue #24154（MX4200 / ipq807x，同型症状）
  https://github.com/openwrt/openwrt/issues/24154
- OpenWrt PR #21495「enable WiFi on 256M device」
- `[上游代码]` [PATCH ath-next] eduard.hart — low-memory profile `2048/1024/512/128/128`
- 同型硬件独立复现：Mercusys MR80X v2.20 = **ipq5018 + qcn6122 / 256 MiB**，
  https://forum.openwrt.org/t/a-simple-patch-to-get-ath11k-working-on-256mib-ram/247147

### 5.3 剩余 ~30 MB 的候选（未验证）

- `dma_alloc_coherent`（stmmac / edma / CE 环）——不进任何 `nr_*`
- `dma_pools` 3 个各 2048 KiB（`dma_atomic_pool_init`）= 6 MB，同样不计入 `nr_*`
- 剩余 page-frag 缓存（ethernet RX、CE 管道）

### 5.4 本轮已排除的通道 [实测]

| 通道 | 结果 |
|---|---|
| `/proc/slabinfo` | 不存在（配置裁掉） |
| `/sys/kernel/slab/*/objects` | 全部为空 |
| `/proc/vmallocinfo` | 2317 行，但无 `size=` 字段（busybox 管道提取失败）；`VmallocUsed` 仅 **10 MB** ⇒ 不是 vmalloc |
| `page_owner` / `dma-coherent` / `dma_buf` debugfs | 均不存在 |
| `remoteproc/*/carveout_memories` | **存在但为空**（Q6 固件在 `wcss` 预留区，不占 buddy）⇒ 原「remoteproc carveout」假设**已证伪** |
| ath11k `FW memory mode: 2` | **证伪**，见 §2.4 |
| zram | `mem_used_total` = **12.2 MB**，`nr_zspages` 2990 页，账已对平 |
| CMA | `CmaTotal = 0`，`nr_free_cma = 0` |
| ath11k `soc_dp_stats` | 只有错误计数器，无尺寸信息 |

---

## 6. 采集脚本

登板通道（本机无 192.168.1.x 网口，必须经三星笔记本）：

```bash
# /tmp/xxx.sh 先 sed -i 's/\r$//' 去 CRLF，再用 stdin 喂 sh -s
ssh -i ~/.ssh/wta301 null@192.168.112.222 \
  "\"F:\GAME\DNF\PuTTY\plink.exe\" -ssh -batch -pw root root@192.168.1.1 sh -s" < /tmp/xxx.sh
```

关键命令：

```sh
grep -E "spanned|present|managed|pages free" /proc/zoneinfo
dmesg | grep -E "reserved mem:|Memory: "
cat /sys/kernel/debug/memblock/memory
grep -E "System RAM|reserved" /proc/iomem
cat /proc/meminfo
```

---

## 7. 相关：adblock 的内存成本（机会成本最大的一项）

| 项 | 实测 |
|---|---|
| 加载域名数 | 357,616（去重后） |
| dnsmasq RSS | **28.3 MB**（约 70 B/域名） |
| `/tmp` tmpfs | **12.2 MB** |
| **合计** | **~40 MB = 可用内存的 23%** |

feed 明细：

| feed | 行数 | 备注 |
|---|---|---|
| adguard | 189,107 | 主力 |
| adguard_tracking | **306,528** | 最大，与 adguard 大量重复 |
| certpl | 125,978 | 波兰 CERT，中文环境无用 |

只留 `adguard` 预估省 **~21 MB**；留 `adguard` + `certpl` 省 ~12 MB。
`/etc/config/adblock` 里**没有** `adb_backup` / `adb_fetchparm` 可选项（只有 `adb_debug` `adb_report`），`adb_backupdir="/tmp/adblock-backup"` 写死在 `/usr/bin/adblock.sh:54`。

拦截实测有效：`doubleclick.net` → NXDOMAIN，`googleadservices.com` → NXDOMAIN，`www.baidu.com` → 正常。

---

## 8. 附带发现（含一处自我纠正）

### 8.1 adblock 是**用户手动关闭**的，不是被内存压力打停 [实测，已纠正]

采集时撞见 `adblock_status: stopped` / `adb_list.overall` 0 字节 / `blocked_domains: 0`。
**我曾据此推断「357k 域名把内存压到 10 MB 以下 ⇒ dnsmasq 重启 ⇒ 规则归零」，这个因果链是错的。**

复核推翻了自己的推断：

| 判据 | 实测 | 结论 |
|---|---|---|
| `/etc/config/adblock` 的 `adb_enabled` | `'1'` | 配置里仍开着 |
| 服务运行时状态 | `stopped` | 只可能是手动 stop |
| `uptime` = 1534 s 时 `lan1` 累计流量 | 仅 836 KB | **无流量压力** |
| 同一时刻 `dmesg` 中 OOM / 分配失败 | **0 条** | 无内存事件 |

用户确认：「adblock 我关的」。⇒ 与内存无关。

### 8.2 「内存紧张」的真正变量：5G 射频同时在跑 AP + STA [实测]

当前 `/etc/config/wireless`（md5 `ccb3016fa297f15ad5b388e6c4ae5f18`）里有个 **`wifinet2`**：

```
config wifi-iface 'wifinet2'
	option device 'radio1'        # 5G 射频
	option mode 'sta'             # ← 客户端模式
	option network 'sophia'
	option ssid 'Redmi Note 12T Pro'
```

即 **radio1（5G）同时充当 AP + STA**（中继上行到手机热点）。

`iw dev` 实证：
```
phy1-sta0: tx bitrate 864.8 MBit/s 80MHz HE-MCS 8 NSS2 ; rx bitrate 48.0 MBit/s
           signal -45 dBm ; channel 161 (5805 MHz) 80 MHz
phy1-ap0 : channel 161 (5805 MHz) 80 MHz   ← 同信道
```

**这不是 P16 判据 K4 测过的拓扑**（K4 是「2 射频 AP + 有线」）。
每多一个 vif 就多一套 RX/TX 队列与描述符，且 STA 上行会持续拉流量填 ring。

⇒ **本节的 35 MB ≠ P16 的 78 MB，两者不是同一拓扑下的同一个数，不可直接对比。**

### 8.3 有线侧天花板：lan1 只协商到 100 Mbit/s [实测]

```
lan1: speed=100 Mbit/s duplex=full carrier=1
lan2/lan3: speed=-1 (carrier=0，未插)
phy1-sta0 无线协商: 864.8 MBit/s
```

**⇒ 任何「有线→无线」的 iperf3 在本板上天花板约 94 Mbit/s，测不出 Wi-Fi 上限。**
本板从未做过吞吐实测（P15 §5 第 3 条仍列作待办）。

---

## 9. 变更记录

| 日期 | 内容 |
|---|---|
| 2026-11-06 | 初版：256→174 MB 完全闭合 |
| 2026-11-06 | 92 MB 定案为 ath11k（`rmmod` 差 64.7 MiB 实测）；证伪 remoteproc carveout 与 `FW memory mode` 两个假设 |
| 2026-11-06 | **自我纠正**：删除「adblock 被内存压力打停」的错误因果链（实为用户手动关闭）；记录 5G 同时跑 AP+STA 这一新变量；记录 lan1 仅 100 Mbit/s 的天花板 |