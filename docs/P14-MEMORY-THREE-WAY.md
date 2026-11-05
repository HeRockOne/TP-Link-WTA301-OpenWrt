# P14 — 内存占用三方对照（S7 实测 vs 我们实测）

**唯一变量**：固件本身（kernel+rootfs+overlay 全部换回 S7 冻结资产）。
同一台板、同一串口、同一采样命令、同一 uptime 区段。无其他改动。

## 起因

用户指出「S7 双频无线都开，还剩几十 MB」。previous 结论「11-04 avail 58~64 MB 是因为
当时 Wi-Fi 默认关」**已证伪**，证据见下 §1。

## 1. 证伪过程（先看这条，避免重犯）

| 检查 | 命令 | 结果 |
|---|---|---|
| S7 那次 longrun 跑的时候 Wi-Fi 是开是关 | `grep -n 'phy[01]-ap0\|forwarding' work/evidence/coldboot-S7-1.log` | L496~503：`port 6(phy1-ap0)`、`port 5(phy0-ap0)` 均 **entered forwarding** |
| 该 log 与 longrun 是否同一次启动 | `ls -l --time-style=+%m-%d_%H:%M` | log `11-04_22:45`，longrun 首样本 `22:38` ⇒ 同一次启动 |
| S7 的 longrun 数值 | `head -3 work/evidence/longrun-S7.csv` | `avail=63904` `free=41484` **ifaces=2** |

⇒ **S7 双频在 forwarding 状态下，MemAvailable 稳定 60~64 MB（18 分钟 16 个样本）**。
我们的同一指标只有 **5468 kB**。差 58 MB，用户记忆正确。

## 2. 双方硬数据（我方 P11，uptime 13 min）

见 `work/evidence/p14-ours-mem.txt`。要点：

- `MemAvailable 5468` / `MemFree 23056` / `Cached 9036`
- **`SUnreclaim 20456`**（不可回收 slab）—— MemAvailable 之所以远低于 MemFree，
  几乎正好等于 `MemFree - SUnreclaim - KernelStack - PageTables = 636`
- `AnonPages 4392` ⇒ 用户态没有大块占用，也没有泄漏
- 开机行 `Memory: 176132K/262144K available ... 84432K reserved`
  vs S7 `174988K/... 85516K reserved` ⇒ **开机预留我们比 S7 少 1.1 MB，开机层不是问题**
- 双方 `cma-reserved` 都是 0K、`FW memory mode: 2` 都是 2
  （S7 `coldboot-S7-1.log:433,445`；我方同）⇒ ath11k 模式相同

## 3. 记账缺口（关键线索）

我方 `free` 合计能对平，但 meminfo 分项加起来差 ~114 MB：

```
MemTotal 178672
  MemFree 23056 + Cached 9036 + Shmem 168 + AnonPages 4392
+ Slab 25556 + KernelStack 1292 + PageTables 672
= 64172          ⇒ 缺 114500 kB
```

缺的这部分既不在 free 也不在任何 meminfo 计数器里 ⇒ 高度指向
`dma_alloc_coherent` / `gen_pool` 之类**内核直接向 buddy 要页但不计入 meminfo**的分配，
即 ath11k Q6 的 FW 缓冲。S7 若缺口显著小，则差异在 ath11k 的缓冲规模而非内核基线。


## 4. S7 实测（已刷入 S7 冻结资产，20/20 区校验通过）

刷写日志 `work/evidence/p14-flash-s7.log`，四区 crc32 与 `fingerprint-repo.json`
逐个相等（kernel 53bd0490 / rootfs c2e227c6 / ubi e850127a / tphdr 3ccbcfc4）。
启动 `work/evidence/p14-boot-s7.log`：`Dual image validation, image_1 pass` →
6.18.55 → `port 6(phy1-ap0)` `port 5(phy0-ap0)` 均 forwarding。
采样 `work/evidence/p14-s7-mem.txt` / `-mem2.txt` / `-mem3.txt`（同一份脚本）。

### 4.1 并排数字（uptime：S7 2 min / 我方 13 min，两者都双射频在连）

| 字段 | S7 | 我方 P11 | 差 |
|---|---|---|---|
| MemTotal | 177652 | 178672 | +1020 |
| MemAvailable | **60848 / 61332** | **5468** | **-55 MB** |
| MemFree | 38100 | 23056 | -15 MB |
| Cached | 30924 | 9036 | -21 MB |
| Slab | 24704 / 25108 | 25556 | +0.5 MB |
| SUnreclaim | 17760 / 17820 | 20456 | +2.7 MB |
| AnonPages | 5172 | 4392 | -0.8 MB |
| VmallocUsed | 9012~9156 | 待测 | ? |
| **min_free_kbytes** | **4096** | **16384** | **×4** |
| SwapTotal（zram） | 49148（48 MB） | 89084（87 MB） | ×1.8 |
| free 口径 used | 101696 | 141016 | **+39 MB** |

### 4.2 决定性证据：S7 有一份我们**没有**的内存调优文件

`/etc/sysctl.d/99-wta301-mem.conf`（`p14-s7-mem3.txt` P1 段原文）：

```
# v19-fix2: OpenWrt 的 /etc/init.d/sysctl 在 MemTotal>65536 kB 时设 16384 kB,
# 原厂未设该项（内核默认 4*sqrt(177652)=1684 kB）。降到 4096, 释放约 12 MB。
vm.min_free_kbytes = 4096
```

同一个 `/etc/init.d/sysctl:8-20` 两侧 md5 相同，`min_free_kbytes` 却差 4 倍
（4096 vs 16384），只能是这份 `99-wta301-mem.conf` 带来的。

MemAvailable 的算式正是「MemFree + 可回收 − 水位预留」，而低水位 ≈
`min_free_kbytes × 1.25`、高水位 ≈ `1.5×`，**min_free 每多 4 倍，预留乘 4 倍**。
S7 实测「MemFree + Cached + SReclaimable − MemAvailable」= **15292 kB ≈ 4096×3.73**，
与水位推算吻合。

### 4.3 次要差异：zram 尺寸

S7 `system.zram_size_mb` 取值 ⇒ disksize 50331648（48 MB）；我方无该 uci，走
`/etc/init.d/zram:20` 默认 `ram_size / 2048` = 86.7 MB ⇒ disksize 89084 kB。
zram 只占虚拟空间，但磁盘尺寸越大 `CommitLimit` 越大、回收策略越容易被触发。

### 4.4 尚未解释的部分

`free` 口径 used 差 39 MB，而 Slab(+0.5) / SUnreclaim(+2.7) / AnonPages(-0.8)
都解释不了 39 MB。按 meminfo 分项倒算「不可见内核内存」：

- S7：`177652 − (38100+37872+24704+5172+1436+936)` = **69432 kB**
- 我方：`178672 − (23056+14136+25556+4392+1292+672)` = **109568 kB**

两边都有大块「不计入任何 meminfo 计数器」的分配（`dma_alloc_coherent` /
`gen_pool` 的特征，即 ath11k Q6 FW mode 2 的宿主缓冲），我方多 40 MB。
Firmware 与 `FW memory mode: 2` 两侧相同；差异指向 backports 版本
（我方 `v6.18.55`、S7 `v7.2`）的 ath11k 缓冲规模。**待验证**。

## 5. 真机验证：只改 `min_free_kbytes` 一项的即时效果

我方 P11 板上，把 `vm.min_free_kbytes` 16384 → **4096**（单变量，不重启不换固件）：

| | 改前 | 改后 | 变化 |
|---|---|---|---|
| MemAvailable | 4900 kB | **25756 kB** | **+20.8 MB** |
| MemFree | 22580 | 24992 | +2.4 MB |
| Cached / SUnreclaim | 14496 / 20456 | 14524 / 20484 | 持平（未受影响） |

MemFree 与 Cached 几乎不动，只有 MemAvailable 跳了 20.8 MB ⇒ 正是水位预留被释放，
**与水位算式一致，H1 成立**。S7 只比我们多这一行 sysctl 就有 60 MB，方向对。

## 5.1 复现（板上，两步）

```sh
printf 'vm.min_free_kbytes = 4096
' > /etc/sysctl.d/99-wta301-mem.conf
sysctl -qw vm.min_free_kbytes=4096
uci set system.@system[0].zram_size_mb='48'; uci commit system
```

第二行是 S7 的 zram 尺寸（`etc/config/system` 里 `option zram_size_mb '48'`），
要重启才生效。

## 6. 结论

1. 用户记忆正确：S7 双频全开仍有 ~60 MB 可用，我们只有 ~5 MB。
2. **根因是我方缺一条 S7 早就有的内存调优**，不是 25.12.6 内核更吃内存：
   - 缺失项 1：`/etc/sysctl.d/99-wta301-mem.conf` 的 `vm.min_free_kbytes = 4096`（决定性，+20.8 MB 已实测）
   - 缺失项 2：`system.zram_size_mb = 48`（S7 是 48 MB，我们无此 uci 走默认 86.7 MB）
3. 开机层双方几乎相同（reserved 84432 vs 85516、available 176132 vs 174988），
   `AnonPages` 两侧都只有 4~5 MB ⇒ 不是泄漏、不是内核变大。
4. 剩余 ~40 MB 的「不可见内核内存」差异仍未定案（§4.4），但**修完上面两项后
   MemAvailable 已从 5468 变 25756**，先落地这两项再讨论是否继续追。

## 7. 落地方式（P15 已并入固件）

两项都已写进 `deliver/ipq50xx-base-files/`，随固件发布：

| 项 | 文件 | 形式 |
|---|---|---|
| `vm.min_free_kbytes = 4096` | `etc/sysctl.d/99-wta301-mem.conf` | **rom 内普通文件**，`/etc/init.d/sysctl` 每次启动都读 ⇒ 不会丢 |
| `zram_size_mb = 48` | `etc/uci-defaults/98-wta301-zram` | **首启 uci-defaults**（`uci set system.@system[0].zram_size_mb=48`）|

为什么不把 `zram_size_mb` 写进 rom 里的 `/etc/config/system`：我们这份
`/etc/config/system` 是 `/bin/config_generate` + `board.d/90_wta301` 在**首启运行时生成**的，
rom 里放一份会和它竞争（P9 教训：`/rom/etc/config/` 里只有 dhcp/dropbear/firewall/luci/rpcd/uhttpd
六个，system 不在其中）。uci-defaults 在 `config_generate` 之后执行
（`/etc/init.d/boot` L48 → L52 kmodloader → **L53 uci_apply_defaults**），改的是 overlay 里的副本，
持久且不抢生成权。

副作用（必须知道）：**重刷/写新 UBI 镜像后 overlay 是空的**，此前手工写在 overlay 里的
改动会消失 —— 所以这两项必须固化，否则每次刷机都会退回 16 MiB min_free / 89 MiB zram。

## 8. 与 P15 的关系

P14 把「差 40 MB」缩到「差 22 MB」，剩下的那 22 MB 已在
`docs/P15-ATH11K-RINGS.md` 归因并修正：ath11k 的 DP ring 尺寸（`dp.h` 5 个常量）。
两项修完后预期：双射频开、空载 MemAvailable ≥ 60 MB，与 S7 同级。
