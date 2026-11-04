# P4 首验方案（真机）

**前提**：构建产出 `op_kernel`（FIT/ITB）+ `op_rootfs`（squashfs）+ `op_tphdr`，且三方 crc32 校验通过。
**唯一变量**：内核 6.18.55→6.12.112、用户空间 r37669→25.12.6。分区表、DTS 内容、board-2.bin、脚本全部与 S7 一致。

---

## P4a 回退演练（**先做，不通过不进 P4b**）

| 步骤 | 命令 | 通过判据 |
|---|---|---|
| 1. 冻结归档完好 | `cd work/backup/FROZEN-S7-20261105 && sha256sum -c SHA256SUMS` | 7/7 OK（2026-11-05 已验过一次，全 OK） |
| 2. 回退包可用 | `work/out-final/flash_release.py` 指向 `op_wta301_firmware_web.bin`，`--dry-run` | 四区地址/长度与常量表一致 |
| 3. 串口通路 | `python work/net/lap.py --ensure` → `socket://127.0.0.1:7001` | 能收到 u-boot/内核输出 |
| 4. 抢 u-boot 窗口 | `python work/out-final/reboot2uboot.py` 或 `catch2nd.py` | 进到 `IPQ5018#` 提示符 |
| 5. 回退口径 | kernel `0x44000000` / rootfs `0x45000000` / ubi `0x44000000` / tphdr `0x46000000`，校验 `0x43000000` | 每区 `本地 crc32 = RAM crc32 = nand read 到另一址的 crc32` |

> 红线（AGENTS §5）：`factory_boot`(0x0–0x3c0000)、`normal_boot`(0x4700000/0x700000)、`boot_flag`(0x4000000)
> **不写、不擦**。刷写顺序固定 **kernel → rootfs → ubi → tphdr**。

---

## P4b 首启 checklist（串口全程抓 `work/out-final/capture.py`）

### 1. 引导（0–10 s）
- [ ] u-boot 打 banner，`tpl_boot_one()` 校验通过（只验 magic + klen ≤ 0x740000，**不验 +0xa0**）
- [ ] `Starting kernel ...` 后无 "FDT_ERR" / "Bad FIT" / 解压失败

### 2. 存储（最关键的地基）
- [ ] `/proc/mtd` **15 项**，`mtd5=kernel 0x4880000/0x400000`、`mtd6=rootfs 0x4fc0000/0xc00000`
- [ ] `qcom_snand` 无 `tx DMA channel request failed`（= `&qpic_bam` okay 生效）
- [ ] `rootfs` 挂上：`mount | grep squashfs`，overlay = `wta301data`（`ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data`）

### 3. 以太网（R14 成败点）
- [ ] `dwmac-ipq5018` 内建、`stmmac-platform` 起来；`gmac1` probe，无 `pcs`/`uniphy` 报错
- [ ] `pcs-qca-uniphy` 打印 SGMII link up 1G
- [ ] `rtl8365mb` `found an RTL8367S switch`，`lan1..lan5` 五个 netdev 全部出现
- [ ] `br-lan` 起来、拿到 MAC `98:97:cc:a8:1f:e7`
- [ ] 插网线：`ip -d link` 显示 carrier，`ping 192.168.8.1` 通、能 SSH

### 4. Wi-Fi（第二闸门）
- [ ] `/lib/firmware/ath11k/IPQ5018/hw1.0/cal-ahb-c000000.wifi.bin` 与 `QCN6122/hw1.0/cal-ahb-b00a040.wifi.bin` 由 `12-wta301-caldata` 生成（md5 `f15ca653…` / `c681908f…`）
- [ ] `dmesg | grep -c "qcom-q6v5-mp"` 正常，`err_smem 0`，无 OOM
- [ ] `iw dev` 出现 `phy0-ap0`(2.4G) 与 `phy1-ap0`(5G)，`phy1-ap0` 是 ch36 80MHz
- [ ] `/sys/class/ieee80211/phy*/macaddress` = `98:97:cc:a8:1f:e9`(2.4G) / `:ea`(5G)
- [ ] 手机能扫到并连上（开放/WPA 默认）

### 5. 稳定性（10 min）
- [ ] `free`：MemAvailable > 20 MB；无 `oom-kill`
- [ ] `dmesg | grep -c err_smem` = 0
- [ ] `uptime` 10 min 无重启、无 watchdog reset

---

## 回退触发条件（任一命中立即回退）

| 现象 | 判定 |
|---|---|
| 20 s 内无 `Starting kernel`，或 30 s 内无 console 输出 | TTL 风险 → 回退 |
| kernel panic / 反复 reboot | 回退 |
| `/proc/mtd` 少于 15 项或偏移不符 | 分区错了 → 回退 |
| 有线不通且 `rtl8365mb` 未 probe | R14 未解决 → 回退后改 DTS |
| 双射频起不来且 Q6 报 `err_smem` | 固件/内存布局问题 → 回退 |

回退 = 用 `work/out-final/flash_release.py` 刷 `work/backup/FROZEN-S7-20261105/op_wta301_firmware_web.bin`，
刷完核对四个指纹：kernel `53bd0490` / rootfs `c2e227c6` / tphdr `3ccbcfc4` / ubi `e850127a`。

---

## P4 要顺手采集的证据（为 P5/P6 铺路）

```
cat /proc/mtd ; cat /proc/cmdline ; cat /proc/device-tree/model
dmesg > /tmp/dmesg.txt
ip -d link ; ip addr ; bridge link
for p in /sys/class/ieee80211/phy*/macaddress; do echo -n "$p="; cat $p; done
iw dev ; iw phy | head -60
cat /proc/meminfo | head ; cat /proc/interrupts | grep -iE "gmac|mdio|wcss|q6"
ls -l /lib/firmware/ath11k/*/hw1.0/ | head -30
```
