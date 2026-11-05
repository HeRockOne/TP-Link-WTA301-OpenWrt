# P4 首验结果（2026-11-05，真机）

> **结论先行**：25.12.6 / 6.12.112 **已经在真机上跑起来并给出 shell**。
> 但还差三件事才算「完美迁移」：自动启动、以太网口、overlay。

## 1. 已完成（全部真机实证）

### 1.1 四区刷写 + 逐区校验 PASS

`work/out-final/flash_p5.py --go`，顺序 kernel→rootfs→ubi→**tphdr**，
每区 `tftpboot` → RAM crc32 与本地比 → `nand erase` → `nand write` → `nand read` 到
`0x43000000` → 再 crc32（**不是**与 RAM 同比，避免同源自证）。

| 区 | nand 偏移 | 长度 | crc32 | 结果 |
|---|---|---|---|---|
| kernel | 0x4880000 | 0x480000 | `0cfe65c5` | ✓ |
| rootfs | 0x4fc0000 | 0xbc0000 | `35677c50` | ✓ |
| ubi | 0x1bc0000（擦 0x2440000） | 0x1e0000 | `5d76aa78` | ✓ |
| tphdr | 0x4800000 | 0x20000 | `9acfa8f4` | ✓ |

日志 `work/evidence/p4-flash.log`。

### 1.2 系统启动成功

从 A 槽手动 `nand read 0x44000000 0x4880000 0x480000` + `bootm`：

```
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.6'
DISTRIB_REVISION='r33311-981c978eff'
DISTRIB_TARGET='qualcommax/ipq50xx'
uname -r = 6.12.112
root@(none):~#
```

- `Linux version 6.12.112 (root@DESKTOP-7V87KGU) ... OpenWrt GCC 14.3.0 r33311-981c978eff`
- `Machine model: TP-Link WTA301` ⇒ 我们的板级 DTB 生效
- `/memory` 256MiB、2 CPU SMP
- `ipq5018-gmac-dwmac 39d00000.ethernet`：DWMAC1000、Ring mode、fixed/sgmii、`Link is Up - 1Gbps/Full`
- rootfs：`VFS: Mounted root (squashfs filesystem) readonly on device 31:6`
- `procd: - early -` / `- ubus -` / `- init -` 全过
- `/proc/mtd` 14 项，编号与 S7 逐个一致

证据：`work/evidence/p4-manual-a-boot.log` · `p4-p5-live.log` · `p4-p5-diag.log`

## 2. 三个待修问题（都已定位到原因）

### 问题 A：自动启动读错槽头（**最关键**）

现象：在 u-boot 敲 `bootipq`（= `bootcmd`）会读 **`0x800000`** 的头：

```
NAND read: device 0 offset 0x800000, size 0x20000
get kernel from TP_HEADER  kernel_addr=0x00880000 load_size=0x00500000
```

而 `0x800000` 是**原厂 B 槽头**。对照冻结全盘镜像（`work/backup/flash_full_128M.bin`）：

| 位置 | UBOOT_OFF | KERNEL_OFF | ROOTFS_OFF | +0x90 md5 | 归属 |
|---|---|---|---|---|---|
| `0x800000` | 0x700000 | **0x880000** | 0xfc0000 | `76058d14…` | 原厂 B 槽（normal_boot_bak/kernel_bak/rootfs_bak） |
| `0x4800000` | 0x4700000 | **0x4880000** | 0x4fc0000 | `94867ec5…`＝mtd4 md5 | **A 槽（我们刷的）** |

- `boot_flag` 两个合法值都试过（写 2 / 写 1），`bootipq` **都读 0x800000** ⇒ flag 在这条路径上不参与。
- 因此**自动启动会走原厂 B 槽**，而 B 槽 md5 校验不过 ⇒ 回落提示符（实测如此）。
- 但 S7（原快照）明明自动启动了 A 槽。⇒ S7 时代的自动启动走的是**另一条代码路径**，
  不是 shell 里的 `bootipq` 命令。
- **注意**：先前 `docs/P6` 里那段槽选择反汇编（`0x4990337c cmp r0,#2 / moveq r3,#0x4800000`）
  来自 `mtd4_normal_boot.uboot.bin`，而真机上跑 `bootipq` 的是 **mtd0 一级 u-boot**
  （`rtk_switch_init` / `TP_HEADER` / `get kernel from TP_HEADER` 三个字符串只在
  `mtd0_factory_boot.bin` 里，mtd4 里**都没有**）。**下一步必须反汇编 mtd0**。

### 问题 B：`rtl8365mb` 交换机 probe 失败 ⇒ 无以太网口

```
rtl8365mb-mdio 90000.mdio-1:1d: found an RTL8367S switch
rtl8365mb-mdio 90000.mdio-1:1d: missing child interrupt-controller node
rtl8365mb-mdio 90000.mdio-1:1d: no interrupt support
rtl8365mb-mdio 90000.mdio-1:1d: phylink: error: empty supported_interfaces
rtl8365mb-mdio 90000.mdio-1:1d: error -EINVAL: unable to register switch
rtl8365mb-mdio 90000.mdio-1:1d: probe with driver rtl8365mb-mdio failed with error -22
```

DSA 已找到芯片（`found an RTL8367S`），但每个端口没有 `phy-mode` ⇒
`supported_interfaces` 为空 ⇒ 注册失败。这是**我们 DTS 的 `ports` 写法**问题，
S7 的 DTB 里有能工作的写法（`patches/s7-actual-dtb.dts` 的 `ethernet-switch@1d`），
需要逐字比对端口属性。

### 问题 C：overlay 没挂载

- `mount` 里只有 `/dev/root`(squashfs ro) / proc / sys / tmpfs / debugfs / bpffs
- `df -h /overlay` → `/dev/root 8.5M 100%`
- 但 **UBI 卷本身完全正常**：手动 `mount -t ubifs ubi0:rootfs_data /tmp/t` → `MOUNT_OK`，
  `UBIFS: mounted UBI device 0, volume 0, name "rootfs_data"`，31 MiB / 256 LEBs
- 根因：25.12.6 的 `fstools` 用 `volume_find("rootfs_data")` 按 **driver 注册顺序**找，
  `rootdisk` driver 会先命中（它把「squashfs 之后的剩余空间」当作 `rootfs_data`），
  于是选了 mtdsplit 切出来的 `mtd7`（只有 0x3a0000 = 3.6 MB），而没有用 UBI 卷；
  然后格式化/挂载那一段没成功，最终没有 overlay。
- S7 的 fstools 有 `fstools_overlay_name=` 补丁（bootargs 显式指定卷名），25.12.6 **没有**
  （cmdline 里原样保留 `fstools_overlay_name=wta301data`，内核报 *Unknown kernel command
  line parameters*，说明没人消费它）。
- 修法二选一：给 fstools 打补丁支持 `fstools_overlay_name`（与 S7 一致），
  或调整 driver 顺序/分区让 UBI 卷优先。

### 问题 D（次要）：watchdog 缺时钟

```
qcom_wdt b017000.watchdog: failed to get input clock
platform b017000.watchdog: deferred probe pending
```

6.12 的 `ipq5018.dtsi` 里 watchdog 节点没有可用的 input clock（6.18 有）。
要么在板级 DTS 里补 `clocks`，要么改回 disabled（S7 是 okay 的，所以要补）。

## 3. cmdline 观察

```
console=ttyMSM0,115200n8 ubi.mtd=rootfs root=mtd:ubi_rootfs rootfstype=squashfs rootwait
ubi.mtd=rootfs root=mtd:ubi_rootfs rootfstype=squashfs rootwait
root=/dev/mtdblock6 rootfstype=squashfs rootwait coherent_pool=2M
ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data
```

- 前两段是 u-boot 的 `set_fs_bootargs` 按 `flash_type=11` 注入的（重复两遍）
- 最后 `root=/dev/mtdblock6` 生效（last root= wins）
- `fstools_overlay_name=wta301data` 被传给 userspace 但没人用（见问题 C）

## 4. 下一步（按优先级）

1. **反汇编 `mtd0_factory_boot.bin`**，找到真正的自动启动槽选择逻辑（问题 A）。
   这是唯一挡住「断电自启」的事。
2. **逐字比对 S7 DTB 的 `ethernet-switch@1d` 端口属性**，修 `phy-mode`（问题 B）。
3. fstools 补丁或 driver 顺序（问题 C）。
4. watchdog clocks（问题 D）。

> 注意：问题 B/C/D 的修法都要重新编内核/镜像，所以**先全部定位清楚再一次重编**，
> 避免反复刷写（单一变量原则）。
