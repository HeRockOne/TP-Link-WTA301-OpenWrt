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

## 2. 待修问题（A/D 已查明不是问题）

### ~~问题 A：自动启动读错槽头~~ —— **误判，自动启动本来就是好的**

> 2026-11-05 更正。我先前在 u-boot 提示符里手敲 `bootipq`，看到它读 `0x800000`，
> 就判定「自动启动走原厂 B 槽」。**这是错的。**

`bootipq` 是一级 u-boot 里另一条独立命令（`cmd_bootqca.c` 的 `do_bootqca()`），
TP_HEADER 偏移在代码里写死：

```
0x4a9232ac  mov  r2, #0x800000
0x4a9232b0  mov  r3, #0x20000
```

它跟自动启动无关。真正的自动启动是 u-boot 的 `bootcmd` = **`tplboot`**，实测
（`work/evidence/p4-fullboot.log`）：

```
Hit any key to stop autoboot: 3 2 1 0
tplboot: image_2 kernel 0x480000 @0x04880000 -> 0x44000000
### nand read 0x44000000 0x4880000 0x480000
NAND read: device 0 offset 0x4880000, size 0x480000
 4718592 bytes read: OK
### bootm 0x44000000
## Loading kernel from FIT Image at 44000000 ...
   Using 'config@mp02.1' configuration
     Description:  ARM64 OpenWrt Linux-6.12.112
```

**→ 自动启动读的正是 A 槽 `0x4880000`，完全正确，拔电重启即可，无需任何额外操作。**
`boot_flag` 写 1 或写 2 都不改变 `tplboot` 的槽选择（两种值都实测过）。

保留的有用知识：`bootipq` 是**危险命令**（会去读原厂 B 槽头），排查时别用它，
用 `reset` 或断电重启。

### 问题 B：`rtl8365mb` 交换机 probe 失败 ⇒ 无以太网口
`rtl8365mb` 交换机 probe 失败 ⇒ 无以太网口

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

### 问题 C：overlay 没挂载（**真根因已改正**）

- `mount` 里只有 `/dev/root`(squashfs ro) / proc / sys / tmpfs / debugfs / bpffs
- `df -h /overlay` → `/dev/root 8.5M 100%`
- 但 **UBI 卷本身完全正常**：手动 `mount -t ubifs ubi0:rootfs_data /tmp/t` → `MOUNT_OK`，
  `UBIFS: mounted UBI device 0, volume 0, name "rootfs_data"`，31 MiB / 256 LEBs

**真根因**：25.12.6 的 fstools **本来就支持** `fstools_overlay_name`：

```c
/* fstools mount_root.c:42 */
if (get_var_from_file("/proc/cmdline", "fstools_overlay_name", dataparam, sizeof(dataparam)))
        dataname = dataparam;
data = volume_find(dataname);
```

而 bootargs 传的是 `fstools_overlay_name=wta301data`（跟 S7 逐字一致），
我却把 UBI 卷造成了 `rootfs_data` ⇒ `volume_find("wta301data")` 返回 NULL
⇒ 跳过 `volume_init(data)` / `mount_overlay()` ⇒ 没有 overlay。
`get_var_from_file` 按 `=` 取 value，所以卷名必须是 `wta301data`。

**修法**：`deliver/make-release.sh` 里 ubinize 的 `vol_name` 改回 `wta301data`（与 S7 一致），
**不需要给 fstools 打补丁**。

### ~~问题 D：watchdog 缺时钟~~ —— **S7 一模一样，不是回归，不修**

```
qcom_wdt b017000.watchdog: failed to get input clock
```

`drivers/watchdog/qcom-wdt.c:227` 里 `devm_clk_get_enabled()` 失败后直接
`return PTR_ERR(clk)` ⇒ 硬件看门狗不加载。**S7 的 dmesg 里同一行出现 9+ 次**
（`work/evidence/V3-boot.log`），两个内核的 `ipq5018.dtsi` watchdog 节点**逐字相同**
（都有 `clocks = <&sleep_clk>`，连行号都只差 14 行）。⇒ 本板两颗内核都没有可用的硬件看门狗，
行为等价，不修。

## 3. cmdline 观察

```
console=ttyMSM0,115200n8 ubi.mtd=rootfs root=mtd:ubi_rootfs rootfstype=squashfs rootwait
ubi.mtd=rootfs root=mtd:ubi_rootfs rootfstype=squashfs rootwait
root=/dev/mtdblock6 rootfstype=squashfs rootwait coherent_pool=2M
ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data
```

- 前两段是 u-boot 的 `set_fs_bootargs` 按 `flash_type=11` 注入的（重复两遍）
- 最后 `root=/dev/mtdblock6` 生效（last root= wins）
- `fstools_overlay_name=wta301data` 会被 fstools 的 mount_root 消费（见问题 C）

## 4. 下一步

1. ~~反汇编 mtd0 查自动启动~~ → 已查明：自动启动本来就对（见问题 A 更正）。
2. **问题 B**：搬 S7 的 RTL8367S SerDes 驱动（4 文件拆分版）——编译已通过，见 `docs/R17-RTL8367S-SERDES.md`。
3. **问题 C**：UBI 卷名改回 `wta301data`——改的是打包脚本，不用重编 fstools。
4. 问题 D 不修（与 S7 等价）。

> B/C 一起改完后重新打包刷写一次（kernel+rootfs+ubi+tphdr），再验一次首启。
