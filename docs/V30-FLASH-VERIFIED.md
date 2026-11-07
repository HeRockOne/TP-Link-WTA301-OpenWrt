# v30 上板实证（2026-11-07）

本文件只记**实机证据**，不写推断。上游依据见
`WIFI-SIGNAL-ENHANCE-EXTERNAL-EVIDENCE.md`。

---

## 1. 产物

| 文件 | 大小 | md5 |
|---|---|---|
| `wta301-op-25.12.6-p30.bin`（网页整包，0x1060000） | 17,170,432 | `c823af1d54403ff811f8876dd1190101` |
| `wta301-op-25.12.6-p30-sysupgrade.bin` | 13,394,197 | `8980eb34f1652e6c78a700ce7f778d47` |
| `wta301-uboot-p21c.bin` | 262,144 | `d0ada9f76e4f1aba9b96a559a5220cee` |
| `rescue/wta301-op-25.12.6-p30-ttl.bin`（串口救砖） | 20,447,232 | `9218fb43672a08e37669873e0c93ea0a` |

内核成员与 p29 **完全相同**（`94d7e2a76d3c113a8e115bfd722c151b`）——这一版内核配置一行没动，
只有 rootfs 变了。rootfs 成员 `85677ba0d9c5d152db0ba7c4adedfe65` ≠ p29 的
`3df05b56440aaa7210aa2e16dfd2573a`，符合预期。

构建：`/root/ow2512`，`make -j$(nproc) world`，EXIT=0，14 分钟。
日志 `build-v30.log`，`grep -icE '^make.*Error|ERROR:'` = **0**。

---

## 2. 镜像内容离线核对（从 squashfs 解出，不靠"构建说成功了"）

`unsquashfs` 解 `op_rootfs_0xbc0000.bin` 后逐项检查：

| 项 | 实得 | 判定 |
|---|---|---|
| 2.4G `channel`/`htmode` | `11` / `HT20` | OK |
| 2.4G `basic_rate` | `1000 2000` | OK（beacon 12→1 Mbps） |
| 2.4G `legacy_rates` | `1` | OK（加回 802.11b CCK） |
| 5G `channel`/`htmode` | `161` / `HE40` | OK |
| 5G `basic_rate` | `6000 12000 24000` | OK（beacon 24→6 Mbps） |
| 两频段 `disassoc_low_ack` | `0` | OK |
| `themes/argon/head.ut` | `cascade.css` 在 83 行，`wta301-mobile.css` 在 88 行 | OK（顺序正确） |
| `99-wta301-system` | `CST-8` / `Asia/Shanghai` / `WTA301` / 阿里+cn.pool+cloudflare | OK |
| 权限 `head.ut` / `wta301-mobile.css` | `644` / `644` | OK（rpcd 不会跳过） |
| 权限 `99-wta301-*`（3 个） | `755` | OK（开机真会执行） |
| 权限 `/etc/config/wireless` | `644` | OK |

---

## 3. 上板刷写（干净刷，验证「开箱即用」）

板上原为 p29，跑在 A 槽。用 `sysupgrade -n`（不保留配置）。

**刷前验包**：`sysupgrade -T` → rc=0
`upgrade: wta301 kernel 4280940 / 7602176, rootfs 9108480 / 12582912`

**刷写**：`sysupgrade -n /tmp/p30.bin` → `Commencing upgrade. Closing all shell sessions.`
（连接如预期断开；`SYSUP_RC=246` 是掉链路，不是失败）

**回来**：约 50 秒后 SSH 就绪
```
uname -r  = 6.12.112
RELEASE   = OpenWrt 25.12.6 r33311-981c978eff
HOST      = WTA301          ← 新的 99-wta301-system 在干净刷后自动跑了
```

### 为什么必须干净刷才能验这个
`-n` 丢掉 `/etc/config`，`/etc/config` 全部来自镜像里的 uci-defaults。
hostname 从默认的 `OpenWrt` 变成 `WTA301`，就是「uci-defaults 真的执行了」的直接证据。

---

## 4. 字节级核对：刷进去的 == 包里的

从 sysupgrade（POSIX tar，未压缩）解出成员，与板上分区逐字节比 md5。

| 分区 | 长度 | 实得 | 期望（包内成员） |
|---|---|---|---|
| mtd5 kernel A | 4,280,940 | `0017c5329525ec2022a4e1ceb590983d` | `0017c5329525ec2022a4e1ceb590983d` |
| mtd6 rootfs A | 9,108,480 | `3009bb3f4dc3abf24d9f33c01adc3c94` | `3009bb3f4dc3abf24d9f33c01adc3c94` |

未受影响的区（证明没误写）：

| 分区 | 实得 | 说明 |
|---|---|---|
| mtd4 u-boot A | `d0ada9f76e4f1aba9b96a559a5220cee` | kit 版，未变 |
| mtd9 u-boot B | `d0ada9f76e4f1aba9b96a559a5220cee` | kit 版，未变 |
| mtd10 kernel B | `2868d8e975da7c641e54c72b6beb8f26` | **原厂 4.4.60 完好** |
| mtd11 rootfs B | `bf2f92ceaf509093c8854825f2dc8d5e` | **原厂 4.4.60 完好** |
| mtd0 factory_boot | `50dec7df50f2a6ca84acc0d135e6a414` | 从未被写 |
| mtd2 art | `9ae65be91a632bc52bb8e0567252bbe8` | 从未被写 |

---

## 5. 上板验收：`deliver/check-v30.sh`

干净刷后直接跑，**PASS=30 WARN=0 FAIL=0**。

覆盖六节：无线覆盖档（9 条）/ 开箱即用（6 条）/ 界面（5 条）/
概览数据源（6 条）/ 分区落点（3 条）/ 温度（1 条）。

判据一律读**运行时状态**，不是读配置文件：

| 项 | 运行时证据 |
|---|---|
| 5G 带宽 | `iw dev phy1-ap0 info` → `width: 40 MHz` |
| 5G 信道 | `channel 161 (5805 MHz)` |
| beacon 速率 | `/var/run/hostapd-phy*.conf` 的 `basic_rates` |
| 时区 | `/etc/TZ=CST-8` + `date +%z=+0800` + `date` 显示 `CST` |
| 概览数据 | `ubus call wta301 status` → `thermal[].mC=56~58℃`、`radio[].mC` |
| 移动端 CSS | HTTP 取回 200 / 5258 字节 + `head.ut` 里位置正确 |

---

## 6. sysupgrade 行为的一个坑（本板特有）

`/lib/upgrade/platform.sh` 的 `tplink,wta301` 分支**硬编码写 A 槽**
（`wta301_write_member ... root rootfs` / `... kernel kernel`），顺序是
**先 rootfs 后 kernel**。

所以本板**不存在「交叉刷」选项**：

- B 槽 `kernel_bak` 只有 4 MiB（0x400000）
- v30 的 kernel 成员是 4,280,940 B ≈ 4.08 MiB

⇒ OpenWrt 只能住 A 槽。从 OpenWrt 升 OpenWrt 必然是「写当前槽」。
回退靠的是：B 槽留着原厂 4.4.60，A 槽启动失败时一级 u-boot 跳 B。

这也解释了为什么从**原厂**刷 OpenWrt 是安全的（跑 B 写 A = 交叉刷），
而从 **OpenWrt 升 OpenWrt** 只能原地写——所以必须先确认 B 槽完好再动手。

---

## 7. 复现命令

```bash
# 构建（WSL，root 需 FORCE_UNSAFE_CONFIGURE=1）
cd /root/ow2512
bash deliver/apply-to-2512.sh && make -j$(nproc) world

# 打包
bash deliver/make-release.sh --version p30-2512 --stage p30
bash deliver/make-deliverable.sh p30
bash deliver/make-getroot-kit.sh            # 自动挑最新 deliver-final-*

# 上板验收
plink ... root@192.168.1.1 sh -s < deliver/check-v30.sh
```
