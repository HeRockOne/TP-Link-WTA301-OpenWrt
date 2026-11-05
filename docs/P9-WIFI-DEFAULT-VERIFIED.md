# P9 — 出厂默认启用 Wi-Fi + 有线保持，真机验证通过

日期：2026-11-05
包：`work/images/v25.12.6-P9/`
刷写日志：`work/evidence/p9-flash.log`　启动日志：`work/evidence/p9-coldboot.log`
模块复核：`work/evidence/p9-sweep12.log`

---

## 0. 本次唯一变量

```
新增 base-files/etc/config/wireless（固化进 rootfs）
uci-defaults/99-wta301-wireless 降级为兜底
```

**kernel crc32 与 P7/P8 完全相同 = `4131c6d0`** ⇒ 内核一行未动，变量干净。

| 文件 | P8 | P9 |
|---|---|---|
| kernel | `4131c6d0` | `4131c6d0`（不变） |
| rootfs | `0b6efbcb` | `04a0be1c` |
| ubi | `56ac6282` | `66e210d0` |
| tphdr | `c94a5c83` | `f487269c` |

---

## 1. 刷写：20/20 真校验通过

| 区 | 期望 | RAM/NAND 回读 |
|---|---|---|
| kernel | `4131c6d0` | `4131c6d0` ✅ |
| rootfs | `04a0be1c` | `04a0be1c` ✅ |
| ubi overlay | `66e210d0` | `66e210d0` ✅ |
| tphdr | `f487269c` | `f487269c` ✅ |

刷写方式改为 **`reboot` + 洪泛抢 u-boot**（`work/scratch/coldflash.py --reboot`），
不再依赖智能插座。原因见 §5。

---

## 2. 判据

| # | 判据 | 实测 | 结论 |
|---|---|---|---|
| 1 | 内核 | `Linux version 6.12.112` | ✅ |
| 2 | 有线连通 | `ping -c 3 192.168.1.100` → **0% packet loss** | ✅ |
| 3 | 交换机 | `found an RTL8367S switch`，`Link is Up - 1Gbps/Full` | ✅ |
| 4 | PCS 驱动绑定 | `/sys/bus/platform/drivers/qca-uniphy` 存在；5 条时钟 consumer = `ethernet-pcs@98000`；`gcc_uniphy_{rx,sys,ahb}_clk is_enabled=Y` | ✅ |
| 5 | **Wi-Fi 默认启用** | 启动日志即出现 `br-lan: port 6(phy0-ap0) entered forwarding state` / `port 7(phy1-ap0) ... forwarding` | ✅ |
| 6 | Wi-Fi 参数 | `phy0-ap0` ssid `OpenWrt-WTA301` ch6 20MHz；`phy1-ap0` ssid `OpenWrt-WTA301-5G` ch36 80MHz | ✅ |
| 7 | `/etc/config/wireless` | 两个 `default_radioN` 都是 `option disabled '0'` | ✅ |
| 8 | overlay | `/dev/ubi0_0 27.9M，68.0K 已用` | ✅ |
| 9 | MAC | `eth0`/`br-lan` = `98:97:cc:a8:1f:e7`（mtd1 标签值） | ✅ |

对比 P8：P8 启动日志**没有任何** `phyN-ap0` 行，P9 有一对并进 forwarding。
即使把 overlay 清空（本次 ubi 区重刷为空卷），Wi-Fi 依然默认开 ⇒ 配置真的固化了。

---

## 3. 根因与修法（已实证）

`/etc/init.d/boot`：

```
 48:  [ -f /etc/board.json ] && /sbin/wifi config     ← 先
 52:  /sbin/kmodloader
 53:  uci_apply_defaults                              ← 后
```

ath11k 是**模块**，dmesg 显示两个 phy 到 16~22 秒才 probe
（`ath11k c000000.wifi: ipq5018 hw1.0`、`ath11k b00a040.wifi: qcn6122 hw1.0`）。
第 48 行执行的那一刻，phy 还不存在，`wifi config` 不生成任何文件，
`/etc/config/wireless` **根本不存在** ⇒ uci-defaults 脚本首行
`[ -f /etc/config/wireless ] || exit 0` 直接退出。

> 补充事实：`/bin/config_generate` + board.d 只在**运行时**生成
> network / system / wireless 到 overlay；`/rom/etc/config/` 里只有
> dhcp / dropbear / firewall / luci / rpcd / uhttpd 这 6 个。
> 所以想"出厂即启用"就必须自己把 `etc/config/wireless` 打进 rootfs。

### 预验证（刷写前就在真机做过）

在 P8 的板子上手工设成 S7 的值，然后跑 `/sbin/wifi config`：

```
wireless.radio0.channel='6'   wireless.radio0.htmode='HT40'
wireless.radio0.country='CN'  wireless.default_radio0.ssid='OpenWrt-WTA301'
wireless.default_radio0.encryption='psk2'  wireless.default_radio0.disabled='0'
→ wifi config 执行后 uci show 逐项保持原值，未被重建覆盖
→ wifi reload 后 iwinfo: ch6 HT40 WPA2-CCMP 24dBm 802.11ax
```

⇒ 固化版配置不会被 `wifi config` 冲掉（它按 `option path` 匹配已有段）。

---

## 4. 与 S7 基线的一致性

| 项 | S7 | 我们（P9） |
|---|---|---|
| radio0 band/channel/htmode | 2g / 6 / HT40 | 同 |
| radio1 band/channel/htmode | 5g / 36 / HE80 | 同 |
| country | CN | 同 |
| ssid | `OpenWrt-WTA301` / `OpenWrt-WTA301-5G` | 同 |
| encryption / key | psk2 / `123456789` | 同 |

> ⚠ 默认 PSK 与 S7 相同，属"已知密码"。首次登录后应改成自己的：
> `uci set wireless.default_radio0.key='新密码'` / `..._radio1.key=...` /
> `uci commit wireless && wifi reload`

**有意不抄 S7 的部分**：S7 的 `/etc/config/system`（214 B）**没有 LED 段**，
即 S7 的 LED 实际不工作。我们由 board.json 生成了 3 个 LED 段
（`green:lan`/`green:wlan2g`/`green:wlan5g`，`netdev` + `link tx rx`），
保留不动 —— 这是我们的**改进**，不是差异缺陷。

---

## 5. 刷写方式改进：不再依赖智能插座

### 问题

米家插座频繁返回 `MiOT code -704083036`（限流）或 `device offline`，
`cycle` 内嵌的 `off` 被拒后重试要 20~60 秒；等插座成功再抓 u-boot，
**窗口已经过了**（RTL8367S 上电 1~2 分钟后就不再转发）。P12 期间连踩两次。

### 解法

`work/scratch/coldflash.py --reboot`：

1. 串口上等 `root@` 提示符，敲 `reboot`
2. 同一连接里每 0.35 s 补一个单字节 `s`（不是 `slp` 洪泛，避免打挂 u-boot）
3. 一看到 `IPQ5018#` 立即停发，设 `ethact eth1` / `ipaddr` / `serverip`
4. 按 cmd 清单执行，每区 `nand read` + `crc32` 与 `FINGERPRINT.json` **数值相等**才通过

实测：从敲 reboot 到拿到提示符约 25 秒，全程无人干预。
插座只在"板子真的挂了、要硬断电"时才用。

---

## 6. 仍未做/未验证

1. **M05 物理按键**（reset gpio20 / wps gpio17）：无法远程触发，需现场按一下确认
2. **M07 内存**：`MemAvailable` 波动 3~16 MB，需长时间 soak 确认不继续下降
   （`work/evidence/p7-soak.log` 已有 20 个样本，均为 40 分钟内数据）
3. **系统时区/NTP**：S7 用 `CST-8`/`Asia/Shanghai` + 阿里云 NTP，
   我们仍是 `GMT0`/UTC + openwrt.pool。属体验差异，未改（见 §7）
