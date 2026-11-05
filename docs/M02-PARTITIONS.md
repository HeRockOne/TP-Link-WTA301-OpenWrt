# M02 分区表

**结论：原厂分区不在 DTB、也不在 `mtdparts` 命令里，而是从 flash 内 RedBoot 表读出来的。
我们的 14 项 DTS 分区与 RedBoot 表的地址全集一致，但 A/B 槽语义对调，且缺两个聚合分区。**

---

## 1. 原厂分区从哪来（三次尝试才查清）

### 1.1 不在 DTB

原厂 3 个 DTB（`patches/factory/`）里 **完全没有分区节点**：

```
$ rg -c "partition" patches/factory/*.dts
（无匹配）
```

### 1.2 不在 `mtdparts` 命令

u-boot 里确实有 `mtdparts` 字符串，但都是**通用框架代码**，不是本板数据：

```
@0x3c670  mtdparts=nand0
@0x3c67f  mtdparts=spi0.0
@0x3c68f  mtdparts=nand0:0x%x@0(rootfs),0x%x@0x%x(rootfs_1);nand1     ← 格式化字符串，%x 未填
@0x4008e  mtdparts variable not set, see 'help mtdparts'
```

`bootargs` 里也没有 `mtdparts=`：

```
@0x3b28b  bootargs=console=ttyMSM0,115200n8
```

原厂内核 cmdline 实测（`work/evidence/uart/abort_b.log`）：

```
[0.000000] Kernel command line: console=ttyMSM0,115200n8 root=/dev/mtdblock6
           rootfstype=squashfs ubi.mtd=7 ubi.mtd=3 rootwait swiotlb=1
```

### 1.3 在 flash 里 —— RedBoot 分区表

```
[0.841288] Booting from image_1(partition table)
[0.842414] Searching for RedBoot partition table
[0.846739] 15 RedBoot partitions found on MTD device qcom_nand.0
[0.851385] Creating 15 MTD partitions on "qcom_nand.0":
```

⇒ QSDK 的 NAND 驱动会去 flash 里搜 **RedBoot 分区表**然后建 MTD。
**mainline 6.12 没有这个功能**（那是 QSDK/`qcom_nandc` 自有实现），
所以 25.12.6 必须用 DTB `fixed-partitions` 或 `qcom,smem-part`。
我们的 u-boot 是 TP-Link 定制的，**不提供 smem-part**，故只能用 `fixed-partitions`。
⇒ **维持 S7 现有写法，正确。**

---

## 2. 原厂 15 项（RedBoot 表实测）

| # | 名称 | 起 | 止 | 大小 |
|---|---|---|---|---|
| 0 | `factory_boot` | `0x0000000` | `0x03c0000` | `0x3c0000` |
| 1 | `factory_info` | `0x0400000` | `0x0420000` | `0x20000` |
| 2 | `art` | `0x0480000` | `0x04a0000` | `0x20000` |
| 3 | `config` | `0x0500000` | `0x0700000` | `0x200000` |
| 4 | `normal_boot` | `0x0700000` | `0x0740000` | `0x40000` |
| 5 | `kernel` | `0x0880000` | `0x0c80000` | `0x400000` |
| 6 | `rootfs` | `0x0fc0000` | `0x1bc0000` | `0xc00000` |
| 7 | `rootfs_data` | `0x6a00000` | `0x8000000` | `0x1600000` |
| 8 | `firmware` | `0x0800000` | `0x2e20000` | `0x2620000` |
| 9 | `normal_boot_bak` | `0x4700000` | `0x4740000` | `0x40000` |
| 10 | `kernel_bak` | `0x4880000` | `0x4c80000` | `0x400000` |
| 11 | `rootfs_bak` | `0x4fc0000` | `0x5bc0000` | `0xc00000` |
| 12 | `rootfs_data_bak` | `0x6a00000` | `0x8000000` | `0x1600000` |
| 13 | `firmware_bak` | `0x4800000` | `0x6e20000` | `0x2620000` |
| 14 | `boot_flag` | `0x4000000` | `0x4020000` | `0x20000` |

**注意两个异常**：
- `rootfs_data` 与 `rootfs_data_bak` **完全同一区间**（`0x6a00000`/`0x1600000`）
- `firmware` / `firmware_bak` 各 `0x2620000`（38.125 MB），**跨越**了 kernel + rootfs。
  这是 TP-Link 官方整包升级/校验用的聚合分区。

---

## 3. S7 实际 14 项（`/proc/mtd` / 启动日志实测）

`work/evidence/V3-boot.log`：

```
[1.055006] Creating 13 MTD partitions on "spi0.0":
[1.061206] 0x000000000000-0x0000003c0000 : "factory_boot"
[1.073785] 0x000000400000-0x000000420000 : "factory_info"
[1.075419] 0x000000480000-0x0000004a0000 : "art"
[1.080525] 0x000000500000-0x000000700000 : "config"
[1.087597] 0x000004700000-0x000004740000 : "normal_boot"        ← 高地址
[1.089986] 0x000004880000-0x000004c80000 : "kernel"              ← 高地址
[1.101489] 0x000004fc0000-0x000005bc0000 : "rootfs"              ← 高地址
[1.122135] mtd: setting mtd6 (rootfs) as root device
[1.122835] 1 squashfs-split partitions found on MTD device rootfs
[1.126198] 0x000005b00000-0x000005bc0000 : "rootfs_data"         ← mtdsplit 切的
[1.133563] 0x000006a00000-0x000008000000 : "rootfs_data2"
[1.173996] 0x000000700000-0x000000740000 : "normal_boot_bak"     ← 低地址
[1.175784] 0x000000880000-0x000000c80000 : "kernel_bak"          ← 低地址
[1.186480] 0x000000fc0000-0x000001bc0000 : "rootfs_bak"          ← 低地址
[1.206944] 0x000001bc0000-0x000004000000 : "rootfs_data3"
[1.265569] 0x000004000000-0x000004020000 : "boot_flag"
```

| # | 名称 | 起 | 止 | 大小 | 来源 |
|---|---|---|---|---|---|
| 0 | `factory_boot` | `0x0000000` | `0x03c0000` | `0x3c0000` | DTS |
| 1 | `factory_info` | `0x0400000` | `0x0420000` | `0x20000` | DTS |
| 2 | `art` | `0x0480000` | `0x04a0000` | `0x20000` | DTS |
| 3 | `config` | `0x0500000` | `0x0700000` | `0x200000` | DTS |
| 4 | `normal_boot` | `0x4700000` | `0x4740000` | `0x40000` | DTS |
| 5 | `kernel` | `0x4880000` | `0x4c80000` | `0x400000` | DTS（B 区）|
| 6 | `rootfs` | `0x4fc0000` | `0x5bc0000` | `0xc00000` | DTS（B 区）|
| 7 | `rootfs_data` | `0x5b00000` | `0x5bc0000` | `0xc0000` | **mtdsplit 自动** |
| 8 | `rootfs_data2` | `0x6a00000` | `0x8000000` | `0x1600000` | DTS |
| 9 | `normal_boot_bak` | `0x0700000` | `0x0740000` | `0x40000` | DTS |
| 10 | `kernel_bak` | `0x0880000` | `0x0c80000` | `0x400000` | DTS |
| 11 | `rootfs_bak` | `0x0fc0000` | `0x1bc0000` | `0xc00000` | DTS |
| 12 | `rootfs_data3` | `0x1bc0000` | `0x4000000` | `0x2440000` | DTS |
| 13 | `boot_flag` | `0x4000000` | `0x4020000` | `0x20000` | DTS |

---

## 4. 差异表（四条）

### 差异 1：A/B 槽命名对调（地址集合相同）

| 地址 | 原厂名 | S7 名 |
|---|---|---|
| `0x0700000`/`0x40000` | `normal_boot` | `normal_boot_bak` |
| `0x0880000`/`0x400000` | `kernel` | `kernel_bak` |
| `0x0fc0000`/`0xc00000` | `rootfs` | `rootfs_bak` |
| `0x4700000`/`0x40000` | `normal_boot_bak` | `normal_boot` |
| `0x4880000`/`0x400000` | `kernel_bak` | `kernel` |
| `0x4fc0000`/`0xc00000` | `rootfs_bak` | `rootfs` |

**判定：无影响，已知无害。**
我们把 OpenWrt 装在原厂的 **B 槽**（高地址 `0x4880000`/`0x4fc0000`），
把原厂 **A 槽**（低地址 `0x0880000`/`0x0fc0000`）保留为回退资产。
`work/backup/mtd10_kernel_bak.bin`（= 原厂 `kernel_bak` @`0x4880000`）与
`work/backup/mtd5_kernel.bin`（= 原厂 `kernel` @`0x0880000`）**都已备份**，
FIT 结构与 3 个 DTB 两端完全一致（见 `evidence/factory-dtb-extract.txt`）。

### 差异 2：缺两个聚合分区（`firmware` / `firmware_bak`）

| 名称 | 区间 | 大小 | 用途 |
|---|---|---|---|
| `firmware` | `0x0800000`–`0x2e20000` | `0x2620000`（38.125 MB）| 原厂 A 槽整包 |
| `firmware_bak` | `0x4800000`–`0x6e20000` | `0x2620000` | 原厂 B 槽整包 |

**判定：无影响，已知无害。**
这两个分区与 `kernel`+`rootfs` **重叠**，只供 TP-Link 自家升级流程做「整包写+整体校验」。
我们按区分别写、按区分别校验（三重 crc32），不需要聚合分区。
**但**：如果将来想做 sysupgrade 的「老固件整包」路径，需要知道有这两个区间存在（P6 再看）。

### 差异 3：`rootfs_data3` 取代了 `rootfs_data_bak`

| | 区间 | 大小 |
|---|---|---|
| 原厂 `rootfs_data_bak` | `0x6a00000`–`0x8000000` | `0x1600000` |
| S7 `rootfs_data2` | `0x6a00000`–`0x8000000` | `0x1600000` |
| S7 `rootfs_data3` | `0x1bc0000`–`0x4000000` | `0x2440000` |

原厂的 `rootfs_data_bak` 与 `rootfs_data` **是同一段物理区间**（原厂 bug 或故意别名）。
我们把这段改名为 `rootfs_data2`（`0x6A00000`，152 LEB），
另外在原厂 `rootfs` 结束（`0x1bc0000`）到 `boot_flag`（`0x4000000`）之间
开辟 `rootfs_data3` 作为 **UBIFS overlay**。

**判定：有意改动，已实证可行。** `rootfs_data3` 正好填满原厂 `rootfs_bak` 之后的空隙，
不与任何原厂分区重叠。

#### ⚠️ 修正（2026-11-05）：`rootfs_data2` 并非「一字节未写」

本文早期版本写「`rootfs_data2` 一字节未写 = 回退路径」，**这个说法已不成立**。
2026-11-05 P17 实况核对：

```
# 备份（2026-10-26 原厂全盘 flash_full_128M.bin @0x6a00000）
55 42 49 23 01 00 00 00 | ec=0x01            | image_seq=0x03f15a1d
# 现役 P17 板子 /dev/mtd8 首 64 字节
55 42 49 23 01 00 00 00 | ec=0x16 (22)       | image_seq=0xce3594bd
```

`image_seq` 不同 ⇒ **不是同一个 UBI 实例**，即 `0x6a00000` 在 10-26 之后
被某次早朝 OpenWrt 构建重新 `ubiformat` 过（`ec=22` 说明被挂载/写过约 22 次）。
当前 `mount` 里没有它、`ubinfo -a` 只有 `ubi0`（= mtd12）⇒ **P17 不挂它、不写它**，
但它里面**存着旧固件遗留的 UBIFS 数据（约 3.1 MB，压缩态无明文字符串）**。

⇒ 结论修正为：

| 项 | 原说法 | 实情 |
|---|---|---|
| `rootfs_data2` 内容 | 一字节未写（原厂干净） | 旧固件遗留 UBI，**不是干净原厂数据** |
| 能否当「原厂回退资产」 | 是 | **否**。回退靠 PC 上的 `work/backup/` 里的文件 |
| 能否当可用空空间 | 22 MB | **是**，22 MB，P17 不用它 |

原厂数据真正存在的地方是 PC 上的文件：`work/backup/mtd8_firmware.bin`（原厂固件区）、
`work/backup/flash_full_128M.bin`（10-26 全盘）。板子上的 `mtd8` 不是。

### 差异 4：`rootfs_data` 来自 mtdsplit

```
[1.122835] 1 squashfs-split partitions found on MTD device rootfs
[1.126198] 0x000005b00000-0x000005bc0000 : "rootfs_data"
```

`CONFIG_MTD_SPLIT_SQUASHFS_ROOT=y` 会在 rootfs 尾部按 squashfs 实际大小向上取整到
erase block（`0x20000`）后补出一个覆盖分区。

**重要**：这是**额外新增**的分区，`rootfs`（mtd6）本身尺寸仍是完整 `0xC00000`，
**没有缩小**。（旧笔记「mtd6 被缩成 0xB40000」是错的，已在 lesson `t9uohkh`/`a8hahkr` 纠正。）

---

## 5. 完整地址图（128 MiB）

```
0x0000000 ┌─────────────────────────┐
          │ factory_boot  0x3c0000  │  🔴 永不写（TTL 命脉）
0x03c0000 ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤  空隙 0x40000
0x0400000 │ factory_info  0x20000    │
0x0420000 ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤  空隙 0x60000
0x0480000 │ art           0x20000    │  （原厂 fdt_mp03.1 这里是 NAND 起点）
0x04a0000 ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤  空隙 0x60000
0x0500000 │ config        0x200000   │
0x0700000 ├─────────────────────────┤
          │ normal_boot_bak 0x40000 │  （原厂 normal_boot）
0x0740000 ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤  空隙 0xC0000
0x0800000 │ [原厂 firmware 起]       │
0x0880000 │ kernel_bak    0x400000  │  （原厂 kernel）
0x0c80000 ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤  空隙 0x340000
0x0fc0000 │ rootfs_bak    0xc00000  │  （原厂 rootfs）
0x1bc0000 ├─────────────────────────┤
          │ rootfs_data3  0x2440000 │  ★ 我们的 UBIFS overlay
0x4000000 ├─────────────────────────┤
          │ boot_flag     0x20000   │  🔴 不写
0x4020000 ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤  空隙 0x6E0000
0x4700000 │ normal_boot   0x40000   │  （原厂 normal_boot_bak）🔴
0x4740000 ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤  空隙 0x140000
0x4880000 │ kernel        0x400000  │  ★ OPEN 区，实际写 0x480000
          │ (+ tphdr 在 0x4800000)  │
0x4c80000 ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤  空隙 0x340000
0x4fc0000 │ rootfs        0xc00000  │  ★ OPEN 区
          ├─────────────────────────┤
0x5b00000 │ └ rootfs_data 0xC0000   │  mtdsplit 自动
0x5bc0000 ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤  空隙 0xE40000
0x6a00000 │ rootfs_data2  0x1600000 │  一字节未写 = 回退路径
0x8000000 └─────────────────────────┘  128 MiB
```

**注意 `tphdr` 的位置**：`0x4800000`，**不属于任何 mtd 分区**，落在
`0x4740000`–`0x4880000` 的 0x140000 空隙里。所以 Linux 侧无法验证它的内容，
只能靠「刷写时 RAM 回读 crc32」和「能启动」间接证明。这是**已知的验证盲区**。

---

## 6. 对 25.12.6 迁移的裁决

**决定：14 项分区表原样搬到 25.12.6 DTS，一个字不改。**

理由：
1. 地址全集与原厂 RedBoot 表一致 ⇒ 不碰任何原厂保留区
2. S7 已实证 UBI overlay 在 `rootfs_data3` 正常工作（290 LEB / 27.9 MB 可用）
3. 分区表是「单变量」的基底，改它等于把所有已刷数据作废

**唯一待确认（P2）**：

| # | 项 | 怎么核 |
|---|---|---|
| a | 6.12 是否仍需 `CONFIG_MTD_SPLIT_SQUASHFS_ROOT`，默认开否 | `target/linux/qualcommax/config-6.12` |
| b | 6.12 的 `nand@0` 子节点名是否影响 mtdsplit 行为 | 不需要，mtdsplit 只看 label |
| c | `kernel` 分区大小：DTS 写 `0x400000` 还是 `0x740000` | fix10.3 已证明 `0x740000` 合法且更准确（`WTA301_KERNEL_MAX`）；**P2 采用 `0x740000`** |
| d | `fixed-partitions` 的 `partitions` 是否要 `compatible = "fixed-partitions"` | 要（S7 有） |

**不做的事**：
- 不采用上游 `qcom,smem-part`（我们的 u-boot 不提供）
- 不采用上游 `append-ubi`（保持 raw squashfs + 独立 overlay）
- 不新增 `firmware`/`firmware_bak` 聚合分区（无用途，且与 kernel/rootfs 重叠）

---

## 7. P4 上电必测（M02 部分）

| # | 测什么 | 通过判据 |
|---|---|---|
| 1 | `cat /proc/mtd` | 14 项，偏移/大小与本表 §3 逐行一致 |
| 2 | 是否有 `rootfs_data`（mtdsplit）| 存在且 `0x5b00000`/`0xC0000` |
| 3 | `cat /proc/partitions` | 与 `/proc/mtd` 对齐 |
| 4 | `mount \| grep overlay` | overlay 挂在 `rootfs_data3` 对应的 ubi 卷上 |
| 5 | `df -h /` | overlay 可用空间 > 25 MB |
| 6 | `cat /proc/cmdline` | `root=/dev/mtdblock6` + `ubi.mtd=rootfs_data3` |

---

## 8. 一句话

**原厂分区表是 RedBoot 表（在 flash 里，不是 DTB，不是 mtdparts）；我们的 14 项 DTS
覆盖了它的地址全集，只把 A/B 槽命名对调（OpenWrt 装 B 槽），并补了 `rootfs_data3`
做 overlay。迁移原样搬，一个字不改。**