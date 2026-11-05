# P15 — ath11k DP ring 尺寸：内存差的真正归属（三方 + 外部）

> 一句话：**我们的 ath11k 用的是「大 ring」默认值，S7 用的是「256 MiB 档」**。
> 两个射频同时开时，这 5 个常量决定约 33 MiB 的差距 —— 也就是 P14 里
> 我们 MemAvailable 39 MB、S7 61 MB 的那段差。

## 0. 症状与判据（都是本板实测，可复现）

| 观测 | 值 | 证据 |
|---|---|---|
| 双射频开，改完 min_free+zram 后 MemAvailable | 39 200 kB（开机 34 s） | `work/evidence/p14-ours-mem-fixed.txt` |
| S7 双射频开 MemAvailable | 61 332 kB（开机 2 min） | `work/evidence/p14-s7-mem3.txt` |
| `rmmod ath11k_ahb` 前后 MemFree（我们） | 7 308 → **108 352 kB** | `work/evidence/p14-athsplit-ours2.txt` |
| 同一动作 `MemAvailable` | 28 024 → 125 224 kB | 同上 |
| `wifi down`（S7 与我们都试过） | 基本不回收（8 288 → 6 972 kB） | P14 §5 |

`rmmod` 一次性放掉 **约 101 MiB**，而这 101 MiB 在 `/proc/meminfo` 的任何
计数器里都看不见（既不是 AnonPages 也不是 Slab 的大头）——
它就是 ath11k 的 `dev_alloc_skb` 页碎片缓存 + coherent ring 内存。
**meminfo 里对不上帐的那 78~110 MB，就是它。**

## 1. 三方逐层表（只列差异行）

| 层 | 项 | 原厂 QSDK 4.4.60 | S7（r37669 / 6.18.55） | 我们（25.12.6 / 6.12.112） | 判定 |
|---|---|---|---|---|---|
| L3 | ath11k 来源 | QSDK 私有 `qca-wifi` + `ath11k` | **backports-7.2**（`mac80211-regular/backports-7.2`，从 .ko 内嵌路径实证） | **backports-6.18.55** | **必须对齐** |
| L3 | `DP_TX_COMP_RING_SIZE` | 未查（架构不同，无对照价值） | **8192** | **32768** | 必须对齐 |
| L3 | `DP_RXDMA_BUF_RING_SIZE` | — | **2048** | **4096** | 必须对齐 |
| L3 | `DP_RXDMA_MON_STATUS_RING_SIZE` | — | **512** | **1024** | 必须对齐 |
| L3 | `DP_RXDMA_MONITOR_BUF_RING_SIZE` | — | **128** | **4096** | 必须对齐 |
| L3 | `DP_RXDMA_MONITOR_DST_RING_SIZE` | — | **128** | **2048** | 必须对齐 |
| L3 | `DP_RXDMA_REFILL_RING_SIZE` | — | 2048 | 2048 | （无差异，**且不可动**，见 §4） |
| L3 | `hal.h` / `dp_rx.c` / `dp_tx.c` / `hal.c` | — | — | — | **逐字节相同**（`diff` 0 行） |
| — | `vm.min_free_kbytes` | 原厂未设 | 4096（`/etc/sysctl.d/99-wta301-mem.conf`） | 16384（OpenWrt 默认） | P14 已对齐 |
| — | zram 大小 | — | 48 MiB（`system.zram_size_mb`） | 89 MiB（`ram_size/2048`） | P14 已对齐 |

**L3 这一行是决定性的**：把两边的 ath11k 目录逐文件 `diff`，`dp.h` 只差这 5 个
常量，其余文件 0 行差异 ⇒ 内存差 **不可能**来自驱动代码差异，只可能来自这 5 个数字。
（复核命令见 §6）

## 2. 外部证据（`[外部实证]` / `[上游代码]`）

> 按 AGENTS §0：先联网、后本地。以下每条都附 URL 与原文常量。

1. **`[外部实证]` OpenWrt issue #24154 — 「ath11k: RX buffer pools exhaust RAM on
   low-memory ipq807x (MX4200) under sustained load -> OOM hang」**
   https://github.com/openwrt/openwrt/issues/24154
   原文（第三方 MX4200 v1，24.10.4 / backports 6.12.52）：
   > *"Stopping Wi-Fi did not reclaim memory, while unloading
   > `ath11k_ahb`/`ath11k` raised `MemAvailable` from 22,756 kB to 291,892 kB"*；
   > *"halving the RX/monitor ring sizes in
   > `drivers/net/wireless/ath/ath11k/dp.h` caps the footprint"*。
   ⇒ 与我们 `rmmod` 观测**完全同型**（stop wifi 不回收、rmmod 一次性放掉上百 MB）。
   该 issue 里还给出实测：`DP_RXDMA_BUF_RING_SIZE` 与 monitor ring 是主项。

2. **`[上游代码]` [PATCH ath-next] wifi: ath11k: use smaller DP rings on low-memory
   systems（Eduard Hart, 2026-09-30）**
   https://lore-kernel.gnuweeb.org/ath11k/20260930165052.4998-1-eduard.hart@etik.com/
   原文 low-memory profile：
   ```
   tx_comp_ring_size         = 2048   (default 32768)
   rxdma_buf_ring_size       = 1024   (default  4096)
   rxdma_mon_status_ring_size=  512   (default  1024)
   rxdma_monitor_buf_ring_size= 128   (default  4096)
   rxdma_monitor_dst_ring_size= 128   (default  2048)
   ```
   触发条件 `total_ram < SZ_256M`（**保留内存不算 totalram，所以 512 MiB 板不会被误降**），
   `Tested-on: IPQ5018 hw1.0 AHB WLAN.HK.2.7.0.1-01744-QCAHKSWPL_SILICONZ-1` +
   `Tested-on: QCN6122 hw1.0` —— **与本板两颗射频、同一 FW 版本完全一致**。
   原文结论：*"both radios of a TP-Link RE700X (IPQ5018 + QCN6122, 256 MiB) stay up
   under load (4-6 clients) with 14-37 MiB of RAM available and no OOM"*。

3. **`[外部实证]` 该系列的另一处警告（同一 issue 的 follow-up）**
   > *"`DP_RXDMA_REFILL_RING_SIZE` is **not a ring depth**. In current ath11k it is
   > passed as the `rx_buf_size` field in `ath11k_dp_tx_htt_rx_filter_setup()`.
   > Reducing it does not save ring memory and instead advertises a 1024-byte buffer
   > while the host allocates 2048 bytes."*
   ⇒ 本补丁**故意不动**这个常量。

4. **`[本板实证]` S7 的 .ko 里内嵌的构建路径**
   ```
   $ strings /root/lp/tree/lib/modules/6.18.55/ath11k.ko | grep backports
   .../mac80211-regular/backports-7.2/include/net/cfg80211.h
   $ strings /root/ours/tree/lib/modules/6.12.112/ath11k.ko | grep backports
   backports-6.18.55/drivers/net/wireless/ath/ath11k/dp_rx.c   (等)
   ```
   ⇒ 两边 ath11k 来自**不同 backports 版本**，不是同一个二进制。

## 3. 本板取值：为什么用 S7 的 8192/2048/512/128/128，而不是上游的 2048/1024/...

| 方案 | ring 值 | 优点 | 风险 |
|---|---|---|---|
| **S7 实测值（本补丁采用）** | 8192/2048/512/128/128 | **这块板子自己跑过数周**，双射频 + 正常上网；`dp_rx.c` 与上游 ath-next 同源 | 比上游 low-mem 档多用约 6 MiB |
| 上游 ath-next low-mem 档 | 2048/1024/512/128/128 | 官方实测（RE700X，同芯片同 FW）14–37 MiB 可用；省更多 | 尚未进 mainline（2026-09 才 ath-next），且 rxdma_buf 只有 1024 |
| 升级 mac80211 到 backports-7.2 | 同 S7 | 一步到位 | 7.2 对 6.12 内 API 未必兼容，改 package 版本 = 动整条 wireless 栈，风险远大于收益 |

按「**长期稳定家用**」这条最高准则，取「本板已验证 + 与上游同源」的交集：
**S7 的数值**。

## 4. 预期收益（按结构算，不含玄学）

两个射频，`DP_RX_BUFFER_SIZE = 2048`：

| ring | 默认 → 新 | 每射频省 | 两射频 |
|---|---|---|---|
| `DP_RXDMA_BUF_RING_SIZE` | 4096 → 2048 | 2048×2 KiB = 4.0 MiB | **8.0 MiB** |
| `DP_RXDMA_MONITOR_BUF_RING_SIZE` | 4096 → 128 | 3968×2 KiB ≈ 7.75 MiB | **15.5 MiB** |
| `DP_RXDMA_MONITOR_DST_RING_SIZE` | 2048 → 128 | 1920×2 KiB ≈ 3.75 MiB | **7.5 MiB** |
| `DP_RXDMA_MON_STATUS_RING_SIZE` | 1024 → 512 | 512×2 KiB = 1.0 MiB | **2.0 MiB** |
| `DP_TX_COMP_RING_SIZE` | 32768 → 8192 | 24576×8 B ≈ 0.19 MiB | **0.4 MiB** |
| 合计 | | | **≈ 33.4 MiB** |

⇒ 目标：双射频开、空载时 MemAvailable 从 **39 MB → 65~70 MB**，逼近 S7 的 61 MB
（考虑我们自己 rootfs 略小、daemon 略多，二者不必逐字节相同）。

## 5. 落地方式

- 补丁：`patches/mac80211/0950-wifi-ath11k-reduce-DP-ring-sizes-256M.patch`
  （只改 `dp.h` 的 5 行，附完整理由与外部引用）
- `deliver/apply-to-2512.sh` §5c：拷进
  `package/kernel/mac80211/patches/ath11k/`，并**按解包源里的常量值**判断是否需要
  `make package/kernel/mac80211/clean`（OpenWrt 不会因 patches/ 变化自动重编 —— 与 §5b fstools 同一个坑）。
- 验证顺序（一次一个变量）：
  1. 构建产物里 `strings`/`objdump` 无法看常量 ⇒ 用**真机行为**判：刷写后
     `rmmod ath11k_ahb` 的释放量应从 ~101 MiB 降到 ~68 MiB，空载 MemAvailable
     ≥ 60 MB。
  2. dmesg 不得出现 `failed to setup rx_refill_buf_ring` / `failed to configure
     monitor status ring` 等 ring 分配失败。
  3. 吞吐与稳定性：`iperf3` 有线→无线、无线→无线各跑一遍，再挂 12 h soak。

## 6. 复核命令（离线，3 秒）

```bash
# 两边 ath11k 逐文件 diff
S=/root/kf/linux-6.18.55/drivers/net/wireless/ath/ath11k
O=/root/ow2512/build_dir/target-*/linux-qualcommax_ipq50xx/mac80211-regular/backports-6.18.55/drivers/net/wireless/ath/ath11k
for f in dp.h hal.h dp_rx.c dp_tx.c hal.c dp.c; do
  printf '%-10s ' $f; diff $S/$f $O/$f | grep -c '^[<>]'
done
# 期望：dp.h 10 行（5 对），其余 0
```

## 6b. 会不会影响 Wi-Fi 性能？（逐条论证）

### 6b.1 先看这 5 个常量**是什么**，不是什么

DP ring 是**描述符环的深度**（能同时挂多少个在途 buf / 完成项），不是带宽、
不是窗口大小、不是任何速率参数。深度不足才影响性能，判据是「环被打满」。

| ring | 谁在用 | 打满会怎样 | 2048/8192 档够不够 |
|---|---|---|---|
| `RXDMA_BUF` 4096→2048 | RX 缓冲池（2 KiB/个） | 新包无处落脚 → `RXDMA Overflow` | 2048×2 KiB = **4 MiB/射频**；2.4G HE40 峰值 ~600 Mbps ⇒ 55 ms 缓冲，5G HE80 ~1200 Mbps ⇒ 27 ms。WMM/AMPDU 在途窗口 <10 ms ⇒ **3~5 倍余量** |
| `TX_COMP` 32768→8192 | TX 完成项（1 包/项） | 无法继续投递 → 停发 | 8192 个在途包 ×1500 B = **12 MB**，等于 5G 满速发 62 ms。硬件 TX FIFO/BA 窗口远小于此 ⇒ **打不满** |
| `RXDMA_MONITOR_BUF` 4096→128 | **仅 monitor 模式**（抓包） | 抓包丢帧 | 正常数据路径**完全不经过**这两个 ring ⇒ 对上网零影响 |
| `RXDMA_MONITOR_DST` 2048→128 | 同上 | 同上 | 同上 |
| `RXDMA_MON_STATUS` 1024→512 | monitor 状态上报 | 抓包元数据丢 | 同上 |

关键点：**monitor ring 占掉的一大半（15.5 + 7.5 ≈ 23 MiB）与正常联网毫无关系**，
只有打开 monitor 模式抓包时才填。

### 6b.2 最强的证据是本板自己：S7 用的就是这套小值

| 事实 | 证据 |
|---|---|
| S7 的 `ath11k.ko` 编译自 `backports-7.2`，`dp.h` 是 8192/2048/512/128/128 | `strings` + 逐文件 diff（§1） |
| S7 在这块板上**双频同时开、跑过数周**，有线无线都正常 | `work/evidence/coldboot-S7-1.log` 有 `port 6(phy0-ap0)/7(phy1-ap0) entered forwarding`；longrun 20 样本 ping 0.9 ms |
| S7 的 `MemAvailable` 61 MB，我们的（大 ring）39 MB | `work/evidence/p14-s7-mem3.txt` |

⇒ 这不是「未经验证的新配置」，而是**把这块板上验证过数周的配置搬回来**。

### 6b.3 上游同款改动已进 ath-next
`[PATCH ath-next] wifi: ath11k: use smaller DP rings on low-memory systems`
—— 在 `total_ram < 256 MiB` 时自动切低内存档，`Tested-on: IPQ5018 + QCN6122`
（与我们同一颗芯片组合、同一 FW mode 2）。OpenWrt issue #24154 里 MX4200 用
同思路解决（且它取的是比我们更激进的 2048/1024 档）。

### 6b.4 反过来说：大 ring 本身就在拖性能
256 MiB 板上被 Wi-Fi 悄悄拿走 101 MiB MemFree，代价是：
- 页缓存只剩 9 MB（S7 是 35 MB）⇒ 读配置/固件/日志更容易回 flash
- 可用内存只有 5~8 MB ⇒ 一旦流量突发或装包，直接逼近 reclaim / OOM 边缘
**内存不足比 ring 浅得多更容易掉吞吐**，这才是有实测支撑的性能风险。

### 6b.5 万一真不够，会看到什么（可观测，不靠猜）
板上 `soc_dp_stats` 可读（已采基线，空载全 0：
`work/evidence/prep15-ath11k-stats.txt`）。P15 验收必须带真实流量复采：

| 计数器 | 含义 | 合格值 |
|---|---|---|
| `RXDMA errors: Overflow` | RX ring 打满丢包 | **0**（非 0 ⇒ RX 环不够，立刻回滚到 4096） |
| `err ring pkts` | 错误环收包 | 0 |
| `REO errors: Desc blocked` | 重排环堵塞 | 0 |

另有 `dmesg` 里 ring 分配失败、`iwinfo … assoclist` 的速率/信号。

### 6b.6 风险与回退成本
- 单改一个常量 = 1 行 + 重编 30~40 min + 重刷 5 min。
- 折中档（怕极端场景）可只把 `TX_COMP` 保留 16384，其余照 S7 —— 但**目前没有证据需要**，
  先按 S7 逐字节对齐，真出了问题再调（一个变量一次，AGENTS §2）。

## 7. 结论

- P14 里「差 40 MB 归属不明」的那笔帐，**归属已定**：ath11k 的 DP ring。
- 不是 backports 版本玄学，也不是 `FW memory mode` 差异（两边 dmesg 都是 mode 2）。
- 改动面 = `dp.h` 5 个常量，与 S7 逐字节对齐，且有 OpenWrt issue + ath-next 双重外部佐证。

## 8. 第一轮构建的「多出来的变量」（已归因并剔除）

第一轮产物 kernel crc32 = `bb0c8667`（P11 是 `4131c6d0`）。**只改 dp.h 不该动内核**，
所以按 AGENTS §2 先查多出来的变量，再决定刷不刷。

### 8.1 归因过程（离线，5 分钟）

| 检查 | 结果 | 结论 |
|---|---|---|
| 内核里有没有 ath11k 符号（`System.map`） | `grep -c ath11k` = **0** | ath11k 是模块，dp.h 不影响 vmlinux |
| FIT 里 `fdt-1` 节点 | 两版 crc 完全相同 `0x06a4a005` | DTS 没变 |
| FIT 里 `kernel-1` 解 lzma 后 | P11 14 100 488 B / P15 **14 166 024 B**（+65 536） | 内核本体真的长大了 64 KiB |
| `Linux version` 横幅 | 两版完全一致（`#0 SMP Sat Oct 17 21:45:38 2026`） | 不是时间戳不可复现 |
| 内核 `.config` 的 input 符号 | `CONFIG_INPUT=y` `INPUT_EVDEV=y` `INPUT_MISC=y` | **这就是那 64 KiB** |

⇒ 第一轮把「按键」那 4 行 input 符号也编进内核了（`apply-to-2512.sh` 里那次
`WITH_KEYS` 之前的无条件追加）。**而且只生效了 3 行：`CONFIG_KEYBOARD_GPIO` 没进
`.config` ⇒ 没有 gpio-keys 驱动 ⇒ 按键照样不工作** —— 即「多了风险、零收益」。

### 8.2 处理
- `apply-to-2512.sh` 加了开关：`WITH_KEYS=1` 才编 input；默认 0 时**显式写
  `# CONFIG_INPUT is not set` 等 5 行**（坑见 lesson `g8tl61k`：从 config-default
  删行不会让旧 `.config` 的 `=y` 回退）。
- 重编后 `build_dir/.../linux-6.12.112/.config` 里 input 符号全无 ⇒ 内核应回到
  `4131c6d0`。**这是本轮的自校验控制项**：crc 若回到 `4131c6d0`，就证明
  「内核变化 = 那 4 行 input」，其余改动全部只落在 rootfs。

### 8.3 本轮唯一变量
`dp.h` 5 个常量（+ `min_free_kbytes` / `zram_size_mb` 两项 rootfs 文件）。
按键留给单独一轮，等用户在现场时再开 `WITH_KEYS=1`。
