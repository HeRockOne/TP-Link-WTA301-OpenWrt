# P22 — 存储布局实测与「那 22 MB 空着」的决定

> 状态：**已实测**（2026-11-06，板上 `root@192.168.1.1`）
> 结论先行：mtd8 `rootfs_data2` 22 MB **保持不动**。装包空间 `/overlay` 还剩 27.7 MB，
> 没有任何空间压力，动它只有风险没有收益。本文记录为什么。

---

## 1. 实测数据（不是推算）

```
# df -h
Filesystem                Size      Used Available Use% Mounted on
/dev/root                 8.8M      8.8M         0 100% /rom
tmpfs                    87.2M    380.0K     86.9M   0% /tmp
/dev/ubi0_0              27.9M    180.0K     27.7M   1% /overlay
overlayfs:/overlay       27.9M    180.0K     27.7M   1% /
tmpfs                   512.0K         0    512.0K   0% /dev
```

```
# ubinfo -a
ubi0
Logical eraseblock size:                 126976 bytes, 124.0 KiB
Total amount of logical eraseblocks:     290 (36823040 bytes, 35.1 MiB)
Amount of available logical eraseblocks: 0 (0 bytes)
Count of bad physical eraseblocks:       0
Count of reserved physical eraseblocks:  20
Present volumes:                         0
Volume ID:   0 (on ubi0)
Type:        dynamic
Size:        266 LEBs (33775616 bytes, 32.2 MiB)
Name:        wta301data
```

```
# cat /proc/cmdline
console=ttyMSM0,115200,n8 rw rootwait root=/dev/mtdblock6 rootfstype=squashfs
rootwait coherent_pool=2M ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data
```

```
# du -sh /overlay/*
508.0K  /overlay/upper
0       /overlay/work

# apk --version   -> apk-tools 3.0.5, compiled for aarch64
# apk list --installed | wc -l   -> 190
```

**关键判读**：190 个已装包，overlay 只吃掉 **508 KB**。剩下的全是固件
（`ath11k-firmware-ipq5018-qcn6122`）和 base-files，本来就在 squashfs 里，不占
overlay。

---

## 2. 完整 128 MB 布局图（含空隙）

`/proc/mtd` 实测量 + DTS `ipq5018-wta301.dts` 分区表交叉核对：

| 起 | 止 | 大小 | 标签 | 状态 |
|---|---|---|---|---|
| `0x0000000` | `0x03c0000` | 3.75 M | `factory_boot` | 一级 u-boot，**永不写** |
| `0x0400000` | `0x0420000` | 128 K | `factory_info` | |
| `0x0480000` | `0x04a0000` | 128 K | `art` | caldata（BDF 来源） |
| `0x0500000` | `0x0700000` | 2 M | `config` | 原厂配置区 |
| `0x0700000` | `0x0740000` | 256 K | `normal_boot_bak` | image_1（二级 u-boot A） |
| `0x0880000` | `0x0c80000` | 4 M | `kernel_bak` | image_1 内核 |
| `0x0fc0000` | `0x1bc0000` | 12 M | `rootfs_bak` | image_1 根文件系统 |
| **`0x1bc0000`** | **`0x4000000`** | **36.25 M** | **`rootfs_data3`** | **overlay（UBI + UBIFS）** |
| `0x4000000` | `0x4020000` | 128 K | `boot_flag` | 魔数 `0x55aa4246`，**=2 先查 image_2** |
| `0x4020000` | `0x4700000` | 6.875 M | — | **空隙** |
| `0x4700000` | `0x4740000` | 256 K | `normal_boot` | image_2（运行中的二级 u-boot） |
| `0x4740000` | `0x4880000` | 1.25 M | — | **空隙** |
| `0x4880000` | `0x4c80000` | 4 M | `kernel` | 运行中的内核 FIT |
| `0x4c80000` | `0x4fc0000` | 3.25 M | — | **空隙** |
| `0x4fc0000` | `0x5880000` | 8.75 M | `rootfs`（squashfs） | `bytes_used 0x8ABA4C`，按 0x20000 对齐后正好 0x8C0000 |
| `0x5880000` | `0x5bc0000` | 3.25 M | `rootfs_data` | mtdsplit 自动切出的尾填充，**全 0xFF** |
| `0x5bc0000` | `0x6a00000` | 14.25 M | — | **空隙（最大一块）** |
| **`0x6a00000`** | **`0x8000000`** | **22 M** | **`rootfs_data2`** | **空着（本文主角）** |

合计正好 128 MB。

> 注意：mtd7 `rootfs_data`（3.25 M，`0x5880000`）**不是** DTS 里的分区，是
> mtdsplit 从 `rootfs` 尾部切出来的填充区。`squashfs bytes_used = 0x8ABA4C`
> = 8.670 M，按 erase block（`0x20000`）向上对齐到 `0x8C0000` = 8.750 M，
> `0x4FC0000 + 0x8C0000 = 0x5880000` —— 正好是 mtd7 的起点，交叉验证成立。
> 所以它永远是 0xFF，且大小随 `bytes_used` 变，不可用作持久存储
> （每次刷 rootfs 都被重算）。
>
> 地址来源：`/sys/class/mtd/mtd{6,7,8,12}/{offset,size}` 十进制实测值
> （`83623936` / `92798976` / `111149056` / `29097984`），不是按分区表推算。
> 早期版本本文按「rootfs 分区 12 M 全归 squashfs」推算，把 mtd7 放在了
> `0x5BC0000`，错了 3.25 M —— 已按 sysfs 修正。

分区占用合计 **100.125 M**。**未被任何分区占用的空隙 = 31.125 M**（9 段）：

| 空隙 | 大小 |
|---|---|
| `0x03C0000..0x0400000` | 0.250 M |
| `0x0420000..0x0480000` | 0.375 M |
| `0x04A0000..0x0500000` | 0.375 M |
| `0x0740000..0x0880000` | 1.250 M |
| `0x0C80000..0x0FC0000` | 3.250 M |
| `0x4020000..0x4700000` | 6.875 M |
| `0x4740000..0x4880000` | 1.250 M |
| `0x4C80000..0x4FC0000` | 3.250 M |
| `0x5BC0000..0x6A00000` | 14.250 M |

**闲置总计 = 31.125 M（空隙）+ 3.25 M（mtd7 填充）+ 22 M（mtd8）= 56.375 M**。

> 注意：这 31.125 M 空隙**全是碎片**，最大一块是 14.25 M（`0x5BC0000..0x6A00000`，
> 紧接 mtd8 前面），其余 8 块加起来 16.875 M 且被固件槽夹开。
> 真正连续可用的大块只有 mtd8 那 22 M。

---

## 3. mtd8 里到底有什么

```
# head -c 64 /dev/mtd8 | hexdump -C
00000000  55 42 49 23 01 00 00 00  00 00 00 00 00 00 00 16  |UBI#............|
00000010  00 00 08 00 00 00 10 00  ce 35 94 bd 00 00 00 00  |.........5......|
00000020  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
00000030  00 00 00 00 00 00 00 00  00 00 00 00 e9 b4 a1 c4  |................|
```

按 `struct ubi_ec_hdr`（大端）解析：

| 字段 | 偏移 | 值 |
|---|---|---|
| `magic` | 0x00 | `"UBI#"` ✓ 合法 |
| `version` | 0x04 | 1 |
| `ec`（erase count） | 0x08 | **22** |
| `vid_hdr_offset` | 0x10 | `0x800` = 2048 |
| `data_offset` | 0x14 | `0x1000` = 4096 |
| `image_seq` | 0x18 | `0xCE3594BD` |
| `hdr_crc` | 0x3C | `0xE9B4A1C4` |

`data_offset = 0x1000`，PEB 131072 → LEB = 131072 − 4096 = **126976**，与 mtd12
的 UBI 参数完全一致。所以它**曾是一个可用的 UBI 设备**（erase count 22 说明
被写过若干次），属于更早固件留下的残留。

**当前状态：未 attach、未 mount。**

```
# mount | grep ubi
/dev/ubi0_0 on /overlay type ubifs (rw,...)
# dmesg | grep -i 'mtd8\|rootfs_data2'
（无输出）
# grep -rl 'mtd8\|rootfs_data2' /etc/ /lib/
（无输出）
```

`dmesg` 里只有 `ubi0`（来自 mtd12），没有 ubi1 —— 确认 mtd8 整个启动过程
没被碰过。`/etc`、`/lib` 里也没有任何脚本引用它。

---

## 4. 为什么**不能**直接当装包空间

这是本节的核心，避免以后重复讨论。

### 4.1 OpenWrt 装包不是「找个空分区放文件」

```
/        = overlayfs(lowerdir=/rom  [squashfs 只读],  upperdir=/overlay/upper)
/overlay = ubifs on /dev/ubi0_0   ← 装到这里的才是「已安装」
```

`apk add` 安装的文件、apk 数据库（`/lib/apk/db/`）、依赖索引**全在
overlayfs 的 upper 层**。要让包装到别处，得改 apk 的根目录
（`--root` / `etc/apk/architecture` 那一套），属于魔改：

- apk 的 `--root` 是给 chroot 用的，不是给「换个地方装」用的
- 强行做会让 `/usr/lib/*.so` 与 squashfs 里的东西脱节，
  `ldd` / 依赖解析 / 升级都会错

⇒ 与「长期稳定家用」直接冲突。**不做。**

### 4.2 也**不能**直接把它扩进 overlay —— 两者不相邻

```
0x1bc0000 ├─ rootfs_data3 (36.25 M, overlay) ─┤ 0x4000000
0x4000000 ├─ boot_flag ─┤ 0x4020000
          │ 6.875 M 空隙 │  ← 不是空闲，只是没分区，且夹着 boot_flag
0x4700000 ├─ image_2 ─┤ 0x4740000
...
0x6a00000 ├─ rootfs_data2 (22 M, 空) ─┤ 0x8000000
```

`rootfs_data3` 在 **64 MB 处就结束了**（`0x4000000`，后面紧接 `boot_flag`），
`rootfs_data2` 在 **106 MB 处才开始**（`0x6a00000`）。中间隔着 `boot_flag`
和整套 image_2 固件槽（kernel + rootfs）。

扩 overlay 必须让 `rootfs_data3` 连续变大 → 只能向前吃 `rootfs_bak`
（12 M，**image_1 的回退资产，不能动**）或向后吃 `boot_flag` + 固件槽
（**等于自毁**）。

唯一可行路径是**重排整张分区表 → 重刷内核 DTB → 迁移现有 overlay 数据**。
为一个还剩 27.7 MB 空着的分区付这个代价，**收益为负**。

---

## 5. 决定（2026-11-06，用户确认）

**mtd8 `rootfs_data2` 保持不动。不改分区表，不 attach，不格式化。**

理由按优先级：

1. **没有需求**。27.7 MB 空闲，190 个包只占 508 KB。
2. **改动代价高**。任何用法都要么魔改 apk，要么重排分区表。
3. **风险不对等**。分区表改动 = 重刷内核 DTB，出问题要 TTL 救砖，
   而收益只是「多一块用不上的空间」。

### 5.1 什么时候该重新考虑

出现以下任一情况再回来看本文：

| 触发条件 | 建议动作 |
|---|---|
| `/overlay` 剩余 < 5 MB | 先 `du -sh /overlay/upper/*` 找大件，能删就删 |
| 想装 Docker / 容器类 | **放弃** —— 256 MB 内存跑不动，与空间无关 |
| 想装大型规则库（如大体积 adblock 源） | 改用 `uhttpd`/`dnsmasq` 外部规则 + `/tmp`（tmpfs 87 MB） |
| 真的需要 40 MB+ 持久空间 | 那才考虑重排分区表，届时按 §4.2 评估 |

### 5.2 如果将来要用，正确做法（仅供参考，本次不做）

不是扩 overlay，而是**当独立数据盘**：

```
ubiformat /dev/mtd8 -y                    # 先清掉残留的旧 UBI（image_seq 0xCE3594BD）
ubiattach -m 8                            # → ubi1
ubimkvol /dev/ubi1 -N store -s 19MiB
mount -t ubifs ubi1:store /mnt/store
```

可用约 19 MiB（176 PEB − 20 保留 = 156 × 124 KiB ≈ 18.9 MiB）。
用途仅限：配置备份、日志归档、离线 `.apk` 仓库。**装包仍然走 `/overlay`。**

用 `uci-defaults` 落成开机自动挂载才叫"稳"，但这属于新功能，需要单独验证
（重启两次确认不丢、确认 `mount_root` 不跟它抢），本次不做。

---

## 6. 本次**没有**改动的东西（明确记录）

- 分区表 / DTS：**一行未改**
- `/etc/config/fstab`：空（实测），未创建
- mtd8：**未格式化，未 attach**，残留 UBI 头原样保留
- `/overlay`：未扩容，未清理

⇒ 板子当前状态与本文实测数据完全一致，随时可复查。

---

## 7. 复查方法（一条命令）

```bash
ssh root@192.168.1.1 "df -h /overlay; ubinfo -a | head -12; cat /proc/mtd"
```

期望看到：

- `/dev/ubi0_0  27.9M  180.0K  27.7M  1%  /overlay`
- `ubi0` 只有一个卷 `wta301data`，**没有 ubi1**
- `mtd8: 01600000 00020000 "rootfs_data2"`

---

## 8. 教训

1. **「有空闲分区」≠「能用来装包」**。OpenWrt 的装包空间是 overlayfs 的
   upper 层，位置由 `mount_root` 决定，不是「哪块空就放哪」。
2. **看剩余空间要看 `df /overlay`，不是看分区表空位**。分区表里 56.4 M 闲置，
   但真正能装包的只有 27.7 M —— 而且实际只用了 508 KB。
3. **`/proc/mtd` 里出现的分区不一定来自 DTS**。mtd7 `rootfs_data` 是 mtdsplit
   从 squashfs 尾部切出来的，大小随 `bytes_used` 变，不能当持久存储用。
4. **残留 UBI 头要认出来**。mtd8 开头 `55 42 49 23` 说明这块曾被 UBI 用过，
   将来要用必须先 `ubiformat`，否则 `ubiattach` 会挂上别人的旧数据。