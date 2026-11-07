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

## 9. 待执行（P3 产物已就绪，等用户在场）

产物：`work/images/v25.12.6-P3/`（四件套 + `flash_cmds.txt` + `FINGERPRINT.json` + `SHA256SUMS`）

### 9.1 先演练回退（必做，P4-a）
B 槽（`mtd10_kernel_bak`/`mtd11_rootfs_bak`）与一级 u-boot 全程不动 ⇒ 新 A 槽校验失败会自动落 B 槽。
演练判据：串口确认 `boot_flag`/槽位选择逻辑可读，`rescue.py setflag --value 2` 可用，串口 7001 通道稳定。

### 9.2 刷写（顺序不可变）
`kernel 0x4880000/0x480000 → rootfs 0x4fc0000/0xbc0000 → ubi 0x1bc0000(擦 0x2440000) → tphdr 0x4800000/0x20000`，
RAM 分别 `0x44000000 / 0x45000000 / 0x44000000 / 0x46000000`，校验址 `0x43000000`，每条命令前缀 `printenv ;`。
刷完 `boot_flag=2`。

### 9.3 首启必须观察的 5 个点
1. 内核版本 `6.12.112`，`DISTRIB_REVISION` 为 25.12.6
2. `ipq5018-gmac-dwmac 39d00000.ethernet` 起来 + `rtl8365mb-mdio 90000.mdio-1:1d: found an RTL8367S`
3. `Link is Up - 1Gbps/Full` + lan1-5 全进 br-lan（`swconfig`/`bridge link`）
4. 双射频 `phy0-ap0`(2.4G) / `phy1-ap0`(5G) 起、`ath11k` 无 cal/board 报错
5. overlay `ubi0_0` 挂载、`/dev/ubi0_0` 可用空间 ≈26MB

任一条不符：先留串口全文（乱码则该轮作废），再决定回退 S7 冻结四件套。

## 10. 回退到 S7 的完整四件套（失败时用）

`work/backup/FROZEN-S7-20261105/` 里必须有、也必须用**它自己的** UBI 镜像
（`ubi_rootfs_data3_wta301data.img`，卷名 `wta301data`，crc32 `e850127a`）——
S7 的 fstools 认这个名字，25.12.6 的那份（`rootfs_data`）不能拿来回退。
回退顺序同样是 **kernel → rootfs → ubi → tphdr**，命令地址与 P4 相同，只换文件名。

## 11. 刷写指令（`work/images/v25.12.6-P5/flash_cmds.txt` 原样，已含四区 + 逐区校验）

**刷哪一版**：优先刷 **P5**（182 包，含 LuCI+zram）。它是 P3 的严格超集，内核/rootfs/DTS
结构未变，只是 squashfs 多了 469 KB；首验有 Web UI 更方便。P3 归档（147 包）保留作对照回退。

四区顺序 **kernel → rootfs → ubi → tphdr**（tphdr 最后：头一改 `+0xa0` 就变，前面写坏还能靠旧头认出来）。

```
printenv ;tftpboot 0x44000000 op_kernel_0x480000.bin
printenv ;nand erase 0x4880000 0x480000
printenv ;nand write 0x44000000 0x4880000 0x480000
printenv ;nand read  0x43000000 0x4880000 0x480000
printenv ;crc32 0x43000000 0x480000          # 期望 7678e6d7

printenv ;tftpboot 0x45000000 op_rootfs_0xbc0000.bin
printenv ;nand erase 0x4fc0000 0xbc0000
printenv ;nand write 0x45000000 0x4fc0000 0xbc0000
printenv ;nand read  0x43000000 0x4fc0000 0xbc0000
printenv ;crc32 0x43000000 0xbc0000          # 期望 9dd9d9d3

printenv ;tftpboot 0x44000000 ubi_rootfs_data3_rootfs_data.img
printenv ;nand erase 0x1bc0000 0x2440000
printenv ;nand write 0x44000000 0x1bc0000 0x1e0000
printenv ;nand read  0x43000000 0x1bc0000 0x1e0000
printenv ;crc32 0x43000000 0x1e0000          # 期望 c0f276a6

printenv ;tftpboot 0x46000000 op_tphdr_0x20000.bin
printenv ;nand erase 0x4800000 0x20000
printenv ;nand write 0x46000000 0x4800000 0x20000
printenv ;nand read  0x43000000 0x4800000 0x20000
printenv ;crc32 0x43000000 0x20000           # 期望 5a8b3e89
```

**擦除长度差异是有意的**：UBI 区擦 `0x2440000`（整区）但只写 `0x1e0000`（镜像长），
因为必须把 S7 残留的 PEB 全部擦掉，否则 overlay 会残留旧 master node / 旧 LEB。

**UBI 区为什么必须刷**：S7 的 overlay 里有 `/etc/config/*`（network/wireless/fstab），
留着会让 25.12.6 首启读进 S7 的网络配置 ⇒ 有线可能起不来。新造的空卷（卷名 `rootfs_data`，crc32 `c0f276a6`）—— **不能**沿用 S7 冻结镜像的 `wta301data` 卷名，
25.12.6 的 fstools 写死只认 `rootfs_data`（见 `P3-PACK-CONTRACT.md` §10）。

**刷完**：`rescue.py setflag --value 2` 设 boot_flag，再断电重启。
