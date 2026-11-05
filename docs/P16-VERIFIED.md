# P16 真机验证报告（归档指纹 + 逐条判据）

> 日期 2026-11-05 · 板子 WTA301（MAC `98:97:cc:a8:1f:e7`）
> 刷写日志 `work/evidence/p16-flash.log` · 验收 `work/evidence/p16-verify.txt`
> 稳定采样 `work/evidence/p16-soak.txt`

## 0. 本次唯一变量

相对 P11（唯一真机验收过的版本）**只改用户态**：中文界面 3 个包 + 5 个 feed。
内核、驱动、DTS、fstools 一字未动。

## 1. 归档指纹（四区三列 crc32 全一致，20/20 通过）

| 区 | u-boot 写入 | crc32 | 说明 |
|---|---|---|---|
| kernel | `0x480000` @ `0x4880000` | **`4131c6d0`** | **与 P11 完全相同** ⇒ 自校验成功 |
| rootfs | `0xbc0000` @ `0x4fc0000` | `51a8d52d` | 含 3 个 zh-cn 包 + 7 行 distfeeds |
| rootfs_data3 (ubi) | `0x1e0000` @ `0x1bc0000` | `c212ff9a` | 干净 overlay |
| tphdr | `0x20000` @ `0x4800000` | `fed69cb4` | |

**内核 crc32 未变是本轮最重要的自校验**：证明 P15 的 ath11k 补丁其实没进内核
（ath11k 是模块，走 rootfs），也证明上一轮误加的 4 行 `CONFIG_INPUT*` 已被
`WITH_KEYS=0` 彻底剔除。

## 2. 判据逐条

| # | 判据 | 目标 | 实测 | 结论 |
|---|---|---|---|---|
| K0 | 版本 | 25.12.6 / 6.12.112 | `DISTRIB_RELEASE='25.12.6'` `r33311-981c978eff` / `6.12.112` | ✅ |
| K1 | 中文界面 | 3 个 `.lmo` | `base.zh-cn.lmo` `firewall.zh-cn.lmo` `package-manager.zh-cn.lmo` | ✅ |
| K2 | 包仓库 | 7 行 distfeeds | 7 行，全部 `releases/25.12.6/` | ✅ |
| K3a | `min_free_kbytes` | 4096 | 4096 | ✅ |
| K3b | zram | 48 MiB | `50331648` | ✅ |
| K3c | **MemAvailable（稳态）** | ≥54 MB | **76 MB**（开机 0 min）/ 61 MB（1 min 含 uci-defaults） | ✅ 超预期 |
| K4 | 双射频 forwarding | 2 射频 + 有线 | `lan1` + `phy1-ap0` + `phy0-ap0` 三条 | ✅ |
| K5 | `RXDMA Overflow` | =0 | `Overflow: 0`，REO errors 全 0 | ✅ |
| K6 | `rmmod ath11k_ahb` 差值 | ≤70 MB | **64.7 MB**（38272 → 104568 kB） | ✅（P11 是 101 MB） |
| K7 | 无 ring 分配失败 | 0 条 | dmesg 仅 S7 也有的 `qcom,m3-dump-addr` 提示 | ✅ |

## 3. 内存三方终值

| 项 | P11 出厂 | **P16** | S7（r37669） |
|---|---|---|---|
| MemAvailable（双频开，空载） | 5 468 kB | **78 196 kB** | 60 848 / 61 332 kB |
| MemFree | 22 580 kB | 57 652 kB | — |
| Cached | 9 036 kB | 28 972 kB | ~31 MB |
| `vm.min_free_kbytes` | 16 384 | **4 096** | 4 096 |
| SwapTotal | 89 084 kB | **49 148 kB** | 49 148 kB |
| `rmmod` 差值 | 101 MB | **64.7 MB** | 未测 |

**P16 的 MemAvailable 比 S7 还高约 18 MB**，原因待查（`[推断]` 可能是 S7 那批
采样时客户端在传数据，或 backports-7.2 与 6.18.55 的 DMA 池策略差异）。
不追——已经达到「双频开还剩几十 MB」的用户目标。

## 4. 安装空间（不变）

| 项 | 值 |
|---|---|
| `/overlay`（ubifs，来自 mtd12 36.25 MiB） | **27.9 MiB**，本版用 28 KB |
| rootfs 分区 12 MiB 内 squashfs | 8.72 MiB，空白 ~3.6 MiB（运行时只读，**不能装包**） |
| 中文 3 包占用 | **75 KiB** |
| 装完中文 + adblock(~1.1 MiB) 剩余 | **≈26 MiB** |

## 5. 本轮新增的两个坑（已存 lesson）

1. **`5wavh1b`** u-boot 有 `Hit any key to stop autoboot: 3`，串口上任何发送
   （包括 probe 脚本收尾的 `\r\n`）都会打断自启落进 `IPQ5018#`。
   刷完必须显式 `printenv ; bootipq`（`bootcmd=bootipq`）。
   **已在 `coldflash.py` 加 `--boot` 开关自动完成此步。**
2. **`hrn0bod`** `make world` 改了包选择后可能只编包不重建镜像 ⇒ 必须
   `make -j8 target/install`，判据 `image mtime > .apk mtime` 且 manifest 有新包。

## 6. 已知非回归现象

`rmmod ath11k_ahb` 后再 `modprobe` 报 `-110`（`failed to power up`）：
Q6 固件需要冷复位才能重载，与 DP ring 改动无关，`reboot` 后完全恢复。
验收时用过 rmmod 的话，**必须重启再交付**。

## 7. 回退路径（未动）

`work/backup/FROZEN-S7-20261105/` 四件套：kernel `53bd0490` · rootfs `c2e227c6` ·
tphdr `3ccbcfc4` · ubi `e850127a`（卷名 `wta301data`）。B 槽（`0x880000`/`0xfc0000`）
全程未动，`Dual image validation` 兜底有效。
