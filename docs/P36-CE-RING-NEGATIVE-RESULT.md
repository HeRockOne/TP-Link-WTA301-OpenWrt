# P36 — ath11k 内存：p34/p35/p36 三轮实测与**负结果**

> 一句话：**缩 ring 深度（dp.h 的五个常量、ce.c 的 CE 表）都治不了这块板子的
> 内存增长。** 根因不是「环太深」，而是 CE 接收路径上 tasklet 逐包 replenish
> 走共享 `page_frag` 缓存造成的整页钉死。本文记录三轮改动、判据、和为什么无效 ——
> 主要是为了**别再有人重走这三步**。

相关：`P15-ATH11K-RINGS.md`（ring 尺寸归属）、`P21-DECODE-OOM.md`（早期 OOM 解码）、
`P14-MEMORY-THREE-WAY.md`（三方内存对比）。

---

## 0. 症状

每天早上 Wi-Fi 全灭，**灯常亮**（LED 是 netdev trigger，灯亮 = netdev 在 =
Linux 活着），两个 SSID 同时消失，`/proc/interrupts` 里 `qf`/`pd1f`/`pd2f`
全程 0（Q6 固件没崩）。断电或重启才恢复。

## 1. 先定案：是内核 OOM killer 杀了 hostapd

`/overlay/log/messages`（持久化在 ubifs，断电不丢）：

```
hostapd invoked oom-killer
  Call trace: do_swap_page -> __alloc_pages_noprof -> out_of_memory
Out of memory: Killed process 1772 (netifd)
Out of memory: Killed process 1733 (hostapd)
```

**hostapd 一个进程服务两个射频**，所以杀它 = 2.4G 与 5G 一起没。
netdev 还在 ⇒ 灯常亮。症状与机制对上了。

### 算术：约 140 MB 没有任何 meminfo 计数器认领

| 项 | 值 |
|---|---|
| `65536 pages RAM` | 256 MiB |
| `- 20868 pages reserved` | 81.5 MiB |
| `= managed` | **178672 kB（174 MiB）** |
| `DMA free` | 8620 kB |
| 内核自报 slab | 23 MiB |
| file | 1 MiB |
| anon | 0 |
| stack + pagetables | 1.4 MiB |
| **无主部分** | **≈ 140 MB** |

这正是 `page_frag` 缓存特征：`dev_alloc_skb()` 从 order-3（32 KiB）页切
2 KiB 片段，**16 个片段里只要还有 1 个被引用，整页就钉住**。所以
slabinfo / kmemleak 都看不见它，只有 `page_owner` 按栈聚合能看到。

上游 `openwrt/openwrt#24154` 逐条一致，其定性是
**「bounded but oversized for the RAM，不是无界泄漏」**。
注：MX4200 是 372 MB 也会耗尽，本板只有 174 MB `managed`。

## 2. 三轮改动

### p34 —— 只动 `dp.h` 五个常量

`patches/mac80211/0950-wifi-ath11k-reduce-DP-ring-sizes-256M.patch`

| 常量 | 默认 | p34 |
|---|---|---|
| `DP_TX_COMP_RING_SIZE` | 32768 | 2048 |
| `DP_RXDMA_BUF_RING_SIZE` | 4096 | 1024 |
| `DP_RXDMA_MON_STATUS_RING_SIZE` | 1024 | 512 |
| `DP_RXDMA_MONITOR_BUF_RING_SIZE` | 4096 | 128 |
| `DP_RXDMA_MONITOR_DST_RING_SIZE` | 2048 | 128 |

取值同 OpenWrt PR #21495（`CONFIG_ATH11K_SMALLBUFFERS`），不是自己编的。
`DP_RXDMA_REFILL_RING_SIZE` 保持 2048 —— 它是 `rx_buf_size` 不是深度。

**指令级证据**：新旧 `ath11k.ko` 反汇编 81122 行只有 36 行不同，全部对应
那两个常量（`0x2000->0x800`、`0x800->0x400` 及掩码 `0x1fff->0x7ff`），
无第三处改动。

结果：OOM 仍然发生。

### p35 —— 打开 `page_owner` 做诊断

`.config` 启用 `SLUB_DEBUG / PAGE_OWNER / PROC_PAGE_MONITOR / IKCONFIG(_PROC)`，
DTS bootargs-append 加 `page_owner=on`。**代价：page_owner 自己吃 4.7 MiB，
更容易 OOM，是刻意的。**

拿到完整账本（143 MiB / 24482 页）：

| 占用 | 栈 | 性质 |
|---|---|---|
| 24.0 MiB | `shmem_get_folio` ← tmpfs | 可回收（诊断时自己写文件造成）|
| **22.2 MiB** | `__page_frag_alloc_align` ← `__netdev_alloc_skb` ← **CE 路径** | ath11k |
| 16.0 MiB | `squashfs_readahead` | 可回收 |
| 11.6 MiB | `page_cache_ra` | 可回收 |
| 11.9 MiB | `dma_alloc_attrs` | ath11k DMA 一致内存 |
| 7.3 MiB | ← `ath11k_dp_rxbufs_replenish` | |
| 6.5 MiB | ← `ath11k_dp_tx_htt_monitor_mode_ring_config` | monitor ring，放大 12× |
| 4.7 MiB | `init_page_owner` | 诊断开销 |
| 11.7 MiB | `new_slab` | 与 meminfo 一致 |

时间序列（5 轮 × 92 秒）：CE 项 **21.8 → 31.1 MiB 单调上升**（+9.3 MiB / 6 分钟），
而 `Slab` 恒定 23000、`LINK` 恒定 10.0 ⇒ **不是 slab，不是 DP ring，不是链路描述符环**。

⇒ 结论指向 CE。**这是唯一一个还在涨的项。**

### p36 —— 动 CE 表

`patches/mac80211/951-wifi-ath11k-ipq5018-reduce-CE-ring-depths.patch`

原来看漏了：`dp.h` 只管 DP 环，**CE 的每 pipe 深度在 `ce.c` 的
`ath11k_host_ce_config_ipq8074[]` 里**（ipq5018 复用此表），从没动过：

```
CE1/CE2/CE5/CE10  各 dest_nentries = 512   ← 4 个接收 pipe
共 2048 buffer × 2 KiB = 名义 4 MiB，实测 22 MiB（放大 5.5×）
```

所以新增 `ath11k_host_ce_config_ipq5018`，只把 CE1 512→256、CE5 512→128，
其余（CE2=32、CE3、CE4、CE0）逐字段照抄；`qcn9074` 表保持原样，
不让真实 QCN9074 网卡受影响。

**构建期踩的坑**：`Hunk #2 FAILED at 939`。原因是 OpenWrt **按文件名字符串
（C locale）排序**应用补丁，`"0951-x"` 排在 `"900-y"` **之前**（`'0' < '9'`），
所以 09xx 会在 9xx 系列之前执行；要改 920-948 引入的代码，必须命名 **95x**。
改名后干净应用。

**二进制级验证**（`.rodata` 逐字节）：新表 CE1 = `0x100`(256)、CE5 = `0x80`(128)；
未动的 `qcn9074` 表仍 `0x200`(512)。三个 SSID 在，`.ko` md5 `39381f80…`。

## 3. 结果：**无效**

```
CE 项   p35: 22.2 MiB   →   p36: 22.9 MiB
```

一点没降。打满 **8 帧**的调用栈给出原因：

```
10.7 MiB  <- ath11k_ce_cleanup_pipes <- ath11k_ce_per_engine_service <- tasklet_action_common
 3.2 MiB  <- ath11k_ce_cleanup_pipes <- ath11k_ce_per_engine_service <- 0xffffffc078f69fc0 <- tasklet
 0.3 MiB  <- ath11k_ce_rx_post_buf  <- ath11k_core_qmi_firmware_ready
```

`ath11k_ce_per_engine_service` 是 **tasklet**，每收一包就补一个新 skb
（`ce.c:389` 的 `dev_alloc_skb`）。

- **只有 0.3 MiB 是开机按 `dest_nentries` 预挂的** —— 那才是 ring 深度能控制的
- **13.9 MiB 来自逐包 replenish** —— ring 深度管不到

**警示信号（早该警觉）**：`ath11k_ce_cleanup_pipes` **只释放、不分配**，
它出现在**分配栈**里本身就说明符号归因不可靠 —— 原因是只打 3 帧时，
内联后的帧会被错认成分配者。

## 4. 为什么无法靠改常量根治

1. **是 page_frag 钉页，不是泄漏。** 一个字节都没丢，是碎片。
2. **ring 深度 ≠ 占用。** 深度只决定开机预挂的那 0.3 MiB。
3. **上游修复不覆盖 CE。** `eisbaw/ath11k-page-frag-fix`（patch 949）给每个
   RXDMA 环独立 `struct page_frag_cache`，但**明确写着
   「leaving CE/HTC on the existing allocator」** —— 而 CE 恰恰是钉得最重的那个
   （13.9 MiB vs RXDMA 的 ~6 MiB）。
4. **要根治 = 驱动改造**：把同样的 per-ring `page_frag_cache` 移植到 CE 的
   `rx_post` 路径（`ce.c`/`ce.h`），并且**先要证明 CE 的 skb 生命周期是
   pipe-local 的** —— 若不成立，换 cache 照样钉。内核侧接口是现成导出的
   （`__page_frag_alloc_align` / `page_frag_cache_drain` 都 `EXPORT_SYMBOL`），
   分配点也只有一个（`ce.c:389`），所以代码量不大，**大的是验证和风险**：
   CE 是固件通信路径，改坏了直接没 Wi-Fi，且 `wifi reload` /
   `wifi down/up` / `ath11k unbind-bind` 三级自救**实测全灭**，只能重刷。

## 5. 原厂参考价值有限

原厂 rootfs（`lib/modules/4.4.60/`）里：

| 原厂 | 我们 |
|---|---|
| kernel **4.4.60** | 6.12.112 |
| **`qca_ol.ko`** 1.6 MB（QSDK 私有，**ELFCLASS32 / EM_ARM**）| mainline `ath11k.ko` |
| `qca-nss-drv.ko` 753 KB（NSS 硬件 offload）| 无 |

**原厂连 `ath11k.ko` / `ath10k.ko` 都没有**，且模块是 32 位 ARM，
本板是 aarch64 ⇒ **指令集层面就不能加载**，不是版本不匹配。

原厂不 OOM 的真正原因是 **NSS 协处理器转发数据包，主机 CPU 根本不碰包** ——
我们看的那个问题在原厂架构里不存在。

有两个东西值得借鉴，但都拿不到代码：

1. `/etc/uci-defaults/skb_recycler`：把回收池设成**有界**
   （`max_skbs=1024`、`max_spare_skbs=256`，MemTotal<131072 时减半）。
   方向与「per-ring cache」一致 —— **Qualcomm 自己的答案是有界回收池，
   而不是每包 alloc/free**。
2. `wireless_start` 的 `set_nss_buffer_pool()`：显式算并压低缓冲池
   （`extra_pbuf_core0 = (high_water_core0 - (NSS+OCM)) * pbuf_size`）。

## 6. p36 产物

| 文件 | 大小 | md5 |
|---|---|---|
| `wta301-op-25.12.6-P36-sysupgrade.bin` | 13,465,877 | `7d7315c13a8d62ded582e2e73634520d` |
| `wta301-op-25.12.6-P36.bin` | 17,170,432 | — |
| `rescue/...-P36-ttl.bin` | 20,447,232 | — |

p36 相对 p31 = `0950` + `951` + 守护三件套。**p36 本身无害**
（ring 更小、静态占用更低、对 13-26 Mbit/s 的 5G 中继吞吐无可测影响），
但它不修问题。

## 7. 兜底：守护脚本（不是定时重启）

`files-rootfs/usr/sbin/wta301-wifi-guard` + `etc/init.d/wta301-guard`
（`START=95`，`S95wta301-guard` 自启，procd 托管）：

```
每分钟测一次 MemAvailable
  < 12288 kB（12 MB）        -> hits +1
  hits >= 2（连续两分钟）     -> snapshot -> sync -> /sbin/reboot
  回到 12 MB 以上            -> hits 归零
```

**板上无 cron / timer，正常运行永不重启。** 关闭：
`uci set wta301-guard.settings.autoreboot=0 && uci commit`。

**它不保 Wi-Fi**，只在快 OOM 时重启。三级自救（L1 `wifi reload` /
L2 `wifi down;up` / L3 ath11k unbind/bind）实测全灭，只在 `recovery.log` 留记录。

心跳字段：`ts up= memavail= swapfree= slab= sunre= ap=N sta=up,-NN qf= pd1f= pd2f= e105= ewmi=`
（`qf`/`pd1f`/`pd2f` 取自 `/proc/interrupts`，非 0 = Q6 固件崩过）。

## 8. 观测现状（2026-11-13）

计数基线 2026-11-12 01:04 清零，到 11-13 12:14：

| 项 | 值 |
|---|---|
| uptime | 35.5 小时（跨两个早上）|
| `recovery.log` | **0 行**（无 LOWMEM、无故障）|
| MemAvailable | 42-51 MB 振荡，**无单调下滑** |
| Slab | 22448 → 23876 kB（+1.4 MB / 35.5h）|
| `qf/pd1f/pd2f` | 全 0 |

**不能据此说「已修好」**：当前跑的是 p36，且之前的 OOM 都发生在我跑
`page_owner` 诊断期间（每次 `cat` 产生 17 MB dump 写进 `/tmp`，而 `/tmp`
是 tmpfs 即 RAM）。**无法排除当初的 OOM 是诊断本身造成的。**
需要更长的干净观测窗口才能区分。

## 9. 读 `page_owner` 的方法论（反复踩过）

1. **不能直接 `awk` 读 `/sys/kernel/debug/page_owner`** —— 它是 debugfs
   seq_file，busybox awk 的大块读会让内核一次性生成全部内容（367k-433k 行 /
   17 MB），板上只剩 38 MB ⇒ `awk: Out of memory`。
   **用 `cat` 流式落盘到 `/tmp`，再用 awk 读普通文件。**
2. **`grep -A9` 会跨记录串台** —— 某条记录栈不足 9 行时会带出下一条记录的头行，
   产生伪栈。**必须按空行严格切记录。**
3. **必须打满 8 帧**（见 §3 的警示信号）。
4. 特殊行：`Charged to memcg: ...`（跳过）、纯地址 `0xffffffc078f73e34`（当帧保留）。
5. 校验：`FIRST + LAST 应等于 PFN`（实测 24482 = 24482）。
6. 诊断完记得把 `.config` 的 `CONFIG_KERNEL_*`、`ipq50xx/config-default`、
   DTS bootargs 回退 —— page_owner 白吃 4.7 MB。

## 10. 下一步（都还没做）

1. **CE 的 per-ring page_frag_cache**（真正的修法，见 §4）。
2. **降负载**：中继改走 2.4G、5G 只做 AP —— 现在同一射频上 STA+AP 并行，
   peer 数翻倍，CE churn 也翻倍。零风险，可先试。
3. **干净观测 3-5 天**，确认「每天早上」是真规律还是诊断期自造。
