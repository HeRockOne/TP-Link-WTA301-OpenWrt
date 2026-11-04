# M10 MAC 地址 / ART / caldata 来源

**一句话结论：真 MAC 只存在于 `factory_info`(mtd1) 的 `M1CT` TLV 里（`@0x1c` = `98:97:cc:a8:1f:e7`），
ART 里没有 MAC；原厂自己也没把它交给内核；S7 上实际上**没人设 MAC**（br-lan 随机、Wi-Fi 是 QCA 默认）。
迁移动作落在 **rootfs 配置层**（`/etc/config/network` 的 `option macaddr`），与内核/DTS 无关。**

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

## 2. S7 现状：三处 MAC 各是什么

| 设备 | S7 用的是什么 | 依据 |
|---|---|---|
| `br-lan` | **随机**（每次启动变） | `work/../S7 rootfs /etc/config/network` **没有** `option macaddr`（全文仅 27 行，只有 ports 列表）；v19-fix5 曾有该行，S7 重建时丢了 |
| `eth0` / `lan1..5` | 继承/conduit 决定，`eth0` 在 fix5 实测是 label **+1** | 未在本板复核 ⇒ **P4 待验** |
| `phy0-ap0` / `phy1-ap0` | **`00:03:7f:12:*` = QCA 固件默认**，不是 factory_info | `work/docs/V19-WIFI-WORKS-WHY.md:84-86` 已实证 |

### 为什么 S7 的 Wi-Fi MAC 是 QCA 默认
OpenWrt 的标准 `etc/hotplug.d/firmware/11-ath11k-caldata` 会按 **board name** 分支
（`case "$board" in … ath11k_patch_mac $(macaddr_add $label_mac 2) 0`），我们的 board 名是
`tplink,wta301`（DTB `compatible = "tplink,wta301","qcom,ipq5018"`），**不在任何分支里**
⇒ 不 patch caldata ⇒ 固件用自己的默认 MAC。
而且 **故意不 patch**：`V19-FIX5-STABLE.md §5` 记录「静态改 caldata 里的 MAC 会让 Q6 崩溃」。

---

## 3. 上游 25.12.6 有没有现成机制可用？

| 机制 | 25.12.6 有吗 | 说明 |
|---|---|---|
| `ipq50xx/base-files/etc/board.d/02_network` 的 `ipq50xx_setup_macs()` | **没有** | `git show HEAD:…/02_network` 里**整个函数都不存在**（25.12.6 没有任何 ipq50xx MAC 处理） |
| `lib/preinit/09_mount_tp_data` + `/tmp/tp_data/default-mac`（TP-Link tp_data UBIFS 卷方案） | 树里**查不到**（`git ls-tree -r HEAD \| grep tp_data` 空） | 这是 **r37669 快照才有的新东西**（S7 rootfs 里确实有 `lib/preinit/09_mount_tp_data`） |
| `lib/preinit/09_mount_factory_data` | S7 有，只服务 `tplink,eap650-outdoor-v1` / `tplink,re700x` | 与本板无关 |
| `11-ath11k-caldata` 里 `tplink,archer-ax55-v1` 分支（`mtd_get_mac_binary 0:art 12`） | 有 | **本板无效**（ART 无 MAC），不能照抄 |

⇒ 结论：**上游没有任何可直接复用的「M1CT 取 MAC」逻辑**，两条路都要自己写：
① 只改 `/etc/config/network`（零风险，仅 br-lan）；
② 加一个 uci-defaults/hotplug 脚本从 `/dev/mtd1` @0x1c 读（覆盖 eth0 + Wi-Fi 可选）。

---

## 4. 迁移动作

### 4.1 第一版（P3 造包时必做，零风险，纯配置）
在 `/etc/config/network` 的 `config device 'br_lan_dev'` 里恢复：
```
option macaddr '98:97:cc:a8:1f:e7'
```
（这是 v19-fix5 已验证过的做法，`V19-FIX5-STABLE.md §3.2`；写死字面值，不依赖脚本）
—— 目的：让 br-lan 稳定，DHCP 租约/防火墙规则不因重启而失效。

### 4.2 第二版（P6 之后，独立改进项，不并入首次迁移）
新增 `/etc/uci-defaults/99-wta301-mac`（或 `board.d/02_network` 的 `tplink,wta301` 分支）：
1. `dd if=/dev/mtd1 bs=1 skip=0 count=32` → 校验 `M1CT`
2. 取 `@0x1c` 6 字节 → `base`
3. `eth0` = base+1（DSA conduit），`br-lan` = base，`lan*` 继承
4. Wi-Fi **不动**（改 caldata 会崩 Q6）
5. 任一步失败 → 静默退出，保持现状

> 为什么不并入首次迁移：首次迁移的唯一变量是「内核/用户空间 6.18→6.12/25.12.6」。
> 同时改 MAC 会让「有线通」的判定混入第二个变量，违反单一变量原则（AGENTS.md §2.1）。

### 4.3 迁移时**不得**做的事
- ❌ 不抄 AX55 的 `mtd_get_mac_binary 0:art 12`（ART 无 MAC）
- ❌ 不改 `caldata.bin` / `board-2.bin` 里的 MAC（Q6 会崩，已实证）
- ❌ 不指望 u-boot 填 `local-mac-address`（现有 u-boot 不改；即使改了也走 `tpl_boot_one()` 不走 `fdt_fixup_ethernet`）

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
| S7 上 `eth0` = label+1 的来源 | 🟡 | fix5 日志显示 `eth0 98:97:cc:a8:1f:e8`，但 S7 DTB 里没有 `local-mac-address`，无法解释；可能是 `br_lan_dev` 的 macaddr 在 bridge 上、eth0 是 DSA conduit 自动 +1。P4 一查即知 |
| `M1CT` 头 20 字节（`05 c0 00 01 3a ce 10 fc …`）含义 | ⚪ 不必 | 取 MAC 不需要解它 |
| TLV type 1–6 是否含 2.4G/5G MAC | 🟡 | 目前只解出 type0。原厂固件用 +2/+3 推算，说明后面的 type 可能存的是别的数据（或就是同一 base 的变体），对迁移无影响 |
