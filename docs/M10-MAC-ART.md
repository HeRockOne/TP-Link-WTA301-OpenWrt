# M10 MAC 地址 / ART / caldata 来源

**一句话结论：真 MAC 只存在于 `factory_info`(mtd1) 的 `M1CT` TLV 里（`@0x1c` = `98:97:cc:a8:1f:e7`），
ART 里没有 MAC；原厂自己也没把它交给内核。
我们的 S7 移植早已在**用户态脚本**里解决了这件事：`board.d/90_wta301` 给 br-lan/eth0/label 设 MAC，
`hotplug.d/firmware/12-wta301-caldata` 从 ART 抽 caldata 并 patch 两个射频频段的 MAC（label+2 / label+3）。
迁移动作 = 把这 **两个脚本原样搬进 25.12.6**，与内核/DTS 无关。**

> ⚠ 本文 §2 曾得出「S7 上没人设 MAC」的错误结论。原因是只查了 `11-ath11k-caldata`
> （上游共享文件）和镜像里 **首次启动前** 的 `/etc/config/network`（由 board.d 在首启时重写）。
> 真正的实现是我们自己的 `90_wta301` / `12-wta301-caldata`（v24 树，`target/linux/qualcommax/ipq50xx/base-files/`）。
> 结论已更正，脚本已收入仓库 `deliver/ipq50xx-base-files/`。

---

## 1. MAC 来源链路（已实证）

### 1.1 ART 里没有 MAC

`0x480000` `art` 分区（128 KiB）是 **gzip 容器**，解出来是 board data（BDF/caldata），
**不含 MAC**。原厂内核启动时自己就在打：

```
[   …] MAC Address from ART is not valid
```
（`work/docs/ETH-MAC-FROM-FACTORY-INFO.md:11`，`work/out-final/boot_grab_20261102_153217.log` 同款）

### 1.2 真 MAC 在 `factory_info` 的 M1CT TLV

`0x400000` = `factory_info`（128 KiB），是个 **`M1CT` TLV 容器**：

```
0x400000  4d 31 43 54   "M1CT"          ← magic
0x400004  … 20 字节头 …
0x400018  TLV 区开始（type be16 | len be16 | value[len]）
0x400018  00 00 | 00 06 | 98 97 cc a8 1f e7    ← type=0 len=6 ⇒ 基础 MAC
0x400022  00 01 | …
…
```
⇒ **`/dev/mtd1` 偏移 `0x1c` 起 6 字节 = 基础 MAC = `98:97:cc:a8:1f:e7`**（与机壳标签一致，已实证）。
2.4G = +2，5G = +3（原厂做法，见 `work/docs/WIFI-BDF-CALDATA.md`）。

### 1.3 原厂为什么拿不到 MAC

原厂 u-boot 的 `board/qca/arm/common/ethaddr.c` 本应把 MAC 填进板级 DTB 的
`dp1/dp2 { local-mac-address = [00 00 00 00 00 00] }`：

```c
> U-Boot uses these to patch the 'local-mac-address' dts entry for the ethernet entries,
> which in turn will be picked up by the HLOS driver
```
但解压 gzip ART 的逻辑被 `#ifdef CONFIG_IPQ_TINY_SPI_NOR` 包住，本板是 NAND 走
`nand_read` 裸读分支 ⇒ 读到 `1f 8b`（gzip 头）当 MAC ⇒ `is_valid_ethaddr()` 失败 ⇒ 填不上。
（`work/docs/ETH-MAC-FROM-FACTORY-INFO.md:83-110`，与 `compressed_art` 是同一个 `CONFIG_IPQ_TINY` 坑）
⇒ **6 个原厂板级 DTB 全是 `local-mac-address = [00 00 00 00 00 00]`**。

---

## 2. S7 现状：MAC 是谁设的（已更正）

| 设备 | S7 用的是什么 | 谁设的 |
|---|---|---|
| `br-lan` | `factory_info@0x1c` = **label** | `90_wta301` → `ucidef_set_interface_macaddr "lan"` |
| `eth0`（DSA conduit = gmac1） | **label**（不是 +1） | `90_wta301` → `ucidef_set_network_device_mac "eth0"` |
| `lan1..lan5` | 跟随 master（br-lan） | DSA |
| `phy0-ap0`（2.4G） | label **+2** | `12-wta301-caldata` → `ath11k_patch_mac … 2` + `ath11k_set_macflag` |
| `phy1-ap0`（5G） | label **+3** | 同上，`QCN6122/hw1.0/cal-ahb-b00a040.wifi.bin` 分支 |

依据：`deliver/ipq50xx-base-files/etc/board.d/90_wta301`（80 行）与
`deliver/ipq50xx-base-files/etc/hotplug.d/firmware/12-wta301-caldata`（111 行）。

### 为什么 11-ath11k-caldata 帮不上忙
OpenWrt 的 `11-ath11k-caldata` 按 **board name** 分支（`tplink,archer-ax55-v1` 用的是
`mtd_get_mac_binary 0:art 12`），我们的 board 名 `tplink,wta301` 不在任何分支里；
更关键的是，那套 `caldata_extract` 是 **裸 dd**，而本板 ART 是 `gzip(tar(virtual_art.bin))`，
裸 dd 会把 gzip 头喂给 ath11k。所以需要我们自己的 `12-wta301-caldata`（12 > 11，跑在后面，不改共享文件）。

### fix5 §5 那条「改 caldata 会让 Q6 崩」说的是什么
说的是**静态**改镜像里烤进去的 `caldata.bin`（单一变量破坏 + 校验踩坑）。
**运行时**用 `ath11k_patch_mac` + `ath11k_set_macflag` 写是正确的做法：
caldata 里出厂 MAC 是 `00:03:7f:12:34:56`（Qualcomm 保留 OUI），且
`0x3e` 的“使用本地址”标志是 `00 00`，两个字节**都**必须改，否则 ath11k 仍回落到固件内置地址。

---

## 3. 上游 25.12.6 有没有现成机制可用？

| 机制 | 25.12.6 有吗 | 说明 |
|---|---|---|
| `ipq50xx/base-files/etc/board.d/02_network` 的 `ipq50xx_setup_macs()` | **没有** | `git show HEAD:…/02_network` 里**整个函数都不存在**（25.12.6 没有任何 ipq50xx MAC 处理） |
| `lib/preinit/09_mount_tp_data` + `/tmp/tp_data/default-mac`（TP-Link tp_data UBIFS 卷方案） | 树里**查不到**（`git ls-tree -r HEAD \| grep tp_data` 空） | 这是 **r37669 快照才有的新东西**（S7 rootfs 里确实有 `lib/preinit/09_mount_tp_data`） |
| `lib/preinit/09_mount_factory_data` | S7 有，只服务 `tplink,eap650-outdoor-v1` / `tplink,re700x` | 与本板无关 |
| `11-ath11k-caldata` 里 `tplink,archer-ax55-v1` 分支（`mtd_get_mac_binary 0:art 12`） | 有 | **本板无效**（ART 无 MAC），不能照抄 |

⇒ 结论：**上游没有任何可直接复用的「M1CT 取 MAC」逻辑**。我们自己已经写好了，且已在板上跑过。

---

## 4. 迁移动作（定案）

把两个脚本 **原样** 搬进 25.12.6 的 `target/linux/qualcommax/ipq50xx/base-files/`
（仓库已存：`deliver/ipq50xx-base-files/`）：

| 文件 | 作用 | 迁移要改的地方 |
|---|---|---|
| `etc/board.d/90_wta301` | 5 口全进 br-lan；br-lan/eth0/label 设 MAC；3 个 LED 绑 netdev | 无（逻辑与内核版本无关） |
| `etc/hotplug.d/firmware/12-wta301-caldata` | 从 ART 解 `gzip(tar(virtual_art.bin))` 抽两段 caldata；写 MAC 和 macflag | 无（只依赖 `caldata.sh` 的 `caldata_from_file`/`ath11k_patch_mac`/`ath11k_set_macflag`，25.12.6 全有） |

两个脚本都自带 `[ "$(board_name)" = "tplink,wta301" ] || exit 0` 护卫，对其它 5 个 profile 零影响（但脚本文件仍会进它们的 rootfs，是已知无宓）。

### 4.1 为什么不写成 `02_network` / `11-ath11k-caldata` 分支
- 那两个是 subtarget 共享文件（38 个 device），改一次就背上一个补丁，每次 rebase 都可能静默丢掉（就是当年 dts 跑偏的成因）。
- 后编号的 `board.d` / `hotplug.d` 可以独立整存，不碰它们。

### 4.2 为什么写 MAC 要同时改 `0x3e` 的 flag
caldata 里出厂 MAC 是 `00:03:7f:12:34:56`（Qualcomm 保留 OUI），且 `0x3e` 的“使用本地址”标志为 `00 00`。
只改 MAC 不改 flag，ath11k 仍回落固件内置地址（v23 就是这么得到 `00:03:7f:12:xx` 的）。
所以脚本里 `ath11k_patch_mac` 后面必跟 `ath11k_set_macflag`。

### 4.3 迁移时**不得**做的事
- ❌ 不抄 AX55 的 `mtd_get_mac_binary 0:art 12`（ART 无 MAC，且本板 ART 是 gzip 容器）
- ❌ 不用 `caldata_extract`（裸 dd 会把 gzip 头喂给 ath11k）
- ❌ 不**静态**改镜像里的 `caldata.bin`（fix5 §5 踩过）
- ❌ 不指望 u-boot 填 `local-mac-address`（走 `tpl_boot_one()` 不走 `fdt_fixup_ethernet`）

---

## 5. P4 待验清单（用真机一问就清楚）

```sh
# 1. MAC 到底有没有被 u-boot 填进去
hexdump -C /proc/device-tree/soc@0/ethernet@39d00000/local-mac-address 2>/dev/null
# 2. 板上实际 MAC
ip -d link show eth0 | grep -i addr
ip -d link show br-lan | grep -i addr
for p in /sys/class/ieee80211/phy*/macaddress; do echo -n "$p = "; cat $p; done
# 3. factory_info 能否读（这是 Linux 不写、但可读来校验的）
dd if=/dev/mtd1 bs=1 skip=24 count=12 2>/dev/null | hexdump -C
#   期望: 00 00 00 06 98 97 cc a8 1f e7 …
```

---

## 6. 未验证项

| 项 | 级别 | 说明 |
|---|---|---|
| `eth0` 实际地址（应为 label，而不是 fix5 的 label+1） | 🟡 | fix5 日志显示 `eth0 98:97:cc:a8:1f:e8`，而 `90_wta301` 写的是 `ucidef_set_network_device_mac "eth0" "$label_mac"`（= label 本身）。两者矛盾，P4 用 `ip -d link show eth0` 一查即知；两种都不影响连通 |
| `M1CT` 头 20 字节（`05 c0 00 01 3a ce 10 fc …`）含义 | ⚪ 不必 | 取 MAC 不需要解它 |
| TLV type 1–6 是否含 2.4G/5G MAC | 🟡 | 目前只解出 type0。原厂固件用 +2/+3 推算，说明后面的 type 可能存的是别的数据（或就是同一 base 的变体），对迁移无影响 |