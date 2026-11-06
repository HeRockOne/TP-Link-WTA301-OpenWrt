# TP 双槽头实测验证（A/B slot header verified on hardware）

date: 2026-11-07
方法：TTL 串口 → 打断一级 u-boot → 进我们的 kit → `nand read` + `md.b` + `tplcheck`
前提：`0x4800000`（A 槽头）/ `0x800000`（B 槽头）**不在任何 mtd 分区内**，Linux 侧读不到，
只能从 u-boot 侧读。见 lesson `sqepa2q`。

证据分档：`[本板实证]` 本机串口原文 · `[外部实证]` 外部可复核 · `[推断]` 有推理链未实测。

---

## 1. 一级 u-boot 启动日志（`[本板实证]` 原文）

```
U-Boot 2016.01 (Aug 11 2021 - 17:24:59 +0800)
input <abort key> to stop autoboot in 500 ms
NAND read: device 0 offset 0x4000000, size 0x8
Dual image validation, to check image_1 now
NAND read: device 0 offset 0x800000, size 0xd0
verifying uboot partition...  0x700000/0x40000  ok
verifying kernel and romfs partition...
0x880000/0x400000  →  0xfc0000/0xc00000
```

关键点：

| 观察 | 含义 |
|---|---|
| `0x4000000 size 0x8` | 读 `boot_flag`，实测 `55aa4246 00000001` ⇒ **flag=1 = 先验 B 槽** |
| `to check image_1 now` | `image_1` = B 槽（`0x800000`） |
| `size 0xd0` | 只读槽头前 **208 字节**就够判（含 `+0x90` / `+0xa0`） |
| `verifying uboot partition` | 验 `+0x90`（u-boot 段 md5） |
| `verifying kernel and romfs` | 验 `+0xa0`（kernel+rootfs md5） |
| **从不 printk / 从不 bootm 内核** | 一级只验槽，验过就 LZMA 解压该槽 u-boot 跳 RAM |

⇒ **一级 u-boot 的职责只有「选槽 + 验槽 + 跳到该槽的 u-boot」**，不参与启动内核。

---

## 2. 我们的 kit 实测身份（`[本板实证]`）

```
U-Boot 2016.01-9ce3157-dirty (2026-11-06 13:33:07 +0800)
arm-openwrt-linux-muslgnueabi-gcc (OpenWrt GCC 5.2.0 6404588+r49254) 5.2.0
relocaddr   = 0x49900000          ← 与安全红线 §5.1 一致
bootcmd     = bootipq
bootdelay   = 3
ethact      = eth0
ipaddr      = 192.168.1.1
serverip    = 192.168.1.100
bootargs    = console=ttyMSM0,115200n8
```

**没有 `md5sum` 命令**。kit 自带三个私有命令：`tplcheck`（自检）、`tplflash`、`tpluboot`。

---

## 3. ★ `tplcheck` 结论（决定性）

```
=========== flash partition self-check ===========
[1/3] u-boot slots
  image_2  slot   0x4700000  OK  (md5 matches, decodes to 0x87c00)
  image_1  slot   0x700000   OK  (md5 matches, decodes to 0x87c00)
[2/3] image_2 kernel + rootfs
  kernel+rootfs md5 MISMATCH
       header : 46bec63b3926a3c7007c6158fe6e0f8f
       on flash: dca2c660f91fe27c6b7dffa151c95e29
[3/3] verdict: INCONSISTENT - see lines above
=================================================
```

⇒ **A 槽（`image_2`）的 kernel+rootfs 段 md5 与实际内容不符**
⇒ **B 槽（`image_1`）全通过**（一级启动日志也印证：验 B 槽后正常启动）
⇒ `verdict: INCONSISTENT` 指的是 A 槽，不是整机

---

## 4. A 槽头实测（`nand read 0x45000000 0x4800000 0x20000` + `md.b`）

```
45000000: 00 00 01 00 55 aa 9d d1  a8 c8 83 31 c9 69 fb bf   magic + ?
45000010: bc f0 d4 32 70 c7 aa 55  41 08 00 00 41 08 00 00
45000020: 00 00 00 00 00 00 00 09  00 00 00 00 00 3c 00 00
45000030: 00 40 00 00 00 02 00 00  00 48 00 00 00 02 00 00
45000040: 00 50 00 00 00 20 00 00  04 70 00 00 00 04 00 00
45000050: 04 80 00 00 00 02 00 00  04 88 00 00 00 48 00 00
45000060: 04 fc 00 00 00 bc 00 00  06 a0 00 00 01 60 00 00
45000090: d0 ad a9 f7 6e 4f 1a ba  9b 96 a5 59 a5 22 0c ee
450000a0: 46 be c6 3b 39 26 a3 c7  00 7c 61 58 fe 6e 0f 8f
450000b0: 60 b2 4c 2b 2e 73 6e 27  20 2a 4a e4 d2 1a 68 b6
450000c0: 57 54 41 33 30 31 56 31  00 00 00 00 00 00 00 01   "WTA301V1" … 01
```

解码：

| 偏移 | 值 | 含义 |
|---|---|---|
| `+0x00` | `00 00 01 00 55 aa 9d d1` | magic（`55aa` 在第 4~5 字节） |
| `+0x48` | `0x04700000` / `0x00040000` | u-boot 槽地址 / 长度 |
| `+0x50` | `0x04800000` / `0x00020000` | 槽头自身地址 / 长度 |
| `+0x58` | `0x04880000` / `0x00480000` | **kernel 区 4.5 MiB**（原厂是 4 MiB） |
| `+0x60` | `0x04fc0000` / `0x00BC0000` | **rootfs 校验长 11.75 MiB**（原厂是 12 MiB） |
| `+0x90` | `d0ada9f7 6e4f1aba 9b96a559 a5220cee` | **= 我们的 u-boot** ✅ |
| `+0xa0` | `46bec63b 3926a3c7 007c6158 fe6e0f8f` | ≠ 实测 `dca2c660…` ⇒ **不匹配** |
| `+0xc0` | `"WTA301V1"` … `01` | 机型串 + 槽号 |

`+0x60/+0x64` 的 `0xBC0000` 正好等于我们 rootfs 分区实际占用
（`op_rootfs_0xbc0000.bin`），说明这个头是**我们刷机后重签的**，但重签时算错了 md5。

---

## 5. B 槽头实测（`nand read 0x45000000 0x800000 0x20000`）

```
45000040: 00 50 00 00 00 20 00 00  00 70 00 00 00 04 00 00
45000050: 00 80 00 00 00 02 00 00  00 88 00 00 00 40 00 00
45000060: 00 fc 00 00 00 c0 00 00  06 a0 00 00 01 60 00 00
45000090: d0 ad a9 f7 6e 4f 1a ba  9b 96 a5 59 a5 22 0c ee
450000a0: c5 c7 dc e6 b6 d4 c4 51  bf 5f 98 1f bd 40 64 f1
450000b0: 4e 4b 1b b2 c1 16 d6 2e  f2 d4 96 05 71 0d 84 65
450000c0: 57 54 41 33 30 31 56 31  00 00 00 00 00 00 00 00   "WTA301V1" … 00
```

| 偏移 | B 槽值 | A 槽值 | 说明 |
|---|---|---|---|
| `+0x48` | `0x00700000` | `0x04700000` | u-boot 槽地址（B=0x700000） |
| `+0x58` | `0x00880000` /**`0x00400000`** | `0x04880000` / `0x00480000` | **B 槽 kernel 区 = 原厂 4 MiB** |
| `+0x60` | `0x00fc0000` /**`0x00C00000`** | `0x04fc0000` / `0x00BC0000` | **B 槽 rootfs 校验 = 原厂 12 MiB** |
| `+0x90` | `d0ada9f7…` | 同 | 都是我们的 u-boot（**B 槽头也被重签过**） |
| `+0xa0` | `c5c7dce6…` | `46bec63b…` | B 槽与全盘备份**逐字节相同** ✅ |
| `+0xb0` | `4e4b1bb2…` | `60b24c2b…` | 同上 |
| `+0xc0` | `"WTA301V1"` … **`00`** | … `01` | 槽号：A=1, B=0 |

⇒ **B 槽是一套完整的原厂槽**：原厂 kernel + 原厂 rootfs + `+0xa0`/`+0xb0` 两个 md5 全对，
只有 `+0x90` 被换成了我们的 u-boot（这是刷 kit 时必须做的事，无害）。

---

## 6. 当前真实引导链

```
一级 u-boot (mtd0, 2021)
  ├ 读 boot_flag@0x4000000 = 55aa4246 00000001   → flag=1 → 先验 B 槽
  ├ 验 B 槽（0x800000）：+0x90 ✔  +0xa0 ✔          → 通过
  └ LZMA 解压 B 槽 u-boot (0x700000) 跳 RAM = 我们的 kit
        ↓
我们的 kit (relocaddr 0x49900000, bootcmd=bootipq)
  ├ tpimg_boot_slot() 只验 magic + klen，【不验 +0x90 / +0xa0】
  ├ 试 A 槽 (0x4700000 → bootm mtd5)  → 起 OpenWrt ✅
  └ A 槽失败则退 B 槽 (0x700000 → bootm mtd10)
```

**A 槽 md5 是错的却照样能启动** —— 因为 kit 不验 md5。这是 feature 不是 bug
（否则每次 `mtd write` 后都得重算头），但也意味着：

> **不能靠「能启动」推断槽头是对的。** 见 lesson `sqepa2q`。
> 判断槽头必须用 `tplcheck` 或直接读头。

---

## 7. ★ 零写入实验：原厂内核能否被 kit 拉起

```
nand read 0x44000000 0x880000 0x400000        # B 槽原厂内核 → RAM
iminfo 0x44000000
```
```
## Checking Image at 44000000 ...
   FIT image found
   FIT description: ARM OpenWrt FIT (Flattened Image Tree)
    Image 0 (kernel@1)
     Description:  ARM OpenWrt Linux-4.4.60
     Compression:  lzma compressed
     Data Size:    2469277 Bytes = 2.4 MiB
     Load Address: 0x41208000
     Hash algo:    crc32 / sha1  ✔
    Image 1 (fdt@mp03.3) / Image 2 (fdt@mp03.1) / Image 3 (fdt@mp02.1)  全 ✔
    Default Configuration: 'config@mp02.1'
## Checking hash(es) for FIT Image at 44000000 ...
   Hash(es) for Image 0 (kernel@1): crc32+ sha1+
   （其余 FDT 同样全过）
```

然后故意传**不带 `root=` 的 bootargs**：

```
setenv bootargs console=ttyMSM0,115200,n8 rw rootwait
bootm 0x44000000
```

**结果：原厂 4.4.60 完整启动到用户态**
```
wlan_cfg80211_set_country: Country: CN
ChinaNet-1FE7 / ChinaNet-1FE7-5G-WiFi5 / CMCC-烤番薯
ctcapd / meshImple_SetWorkform / tp_wlan_set_wifi5_bss
starting pid 272, tty '/dev/ttyMSM0': '/bin/login'
(none) login:
mount: mounting /dev/mtdblock7 on /rom/overlay failed: No such device
downloadError(531). > @ERROR(No DNS.) occur at step(INIT)
```

⇒ **原厂内核完全忽略 u-boot 传的 bootargs**，用自己内置的 cmdline
（含 `root=/dev/mtdblock6`）启动了原厂 rootfs。

**这个实验的价值**：
1. 证明「从 op 刷回原厂」只需要 `dd` 写 mtd5/mtd6，**槽头不用改、TTL 不用插**
2. 提供了一条**无写入**试启动原厂的路（刷之前先验）

**副作用（必记）**：这种 RAM 启动实例 **overlay 挂不上**
（`/dev/mtdblock7 -> /rom/overlay failed`），因此：
- `/proc` 不完整 → `cat /proc/mtd`、`ps` 失效
- `/dev/null` 只读 → `cmd 2>/dev/null` 报错
- 网络起不来 → 在这个实例里 getroot 也难做

---

## 8. 附：`mtd0` 里 u-boot 有两份（未验证项收窄）

一级 u-boot 镜像 `mtd0_factory_boot.bin` 里 `strings` 命中两处，偏移差正好 `0x80000`：
`0x2fd8e6` / `0x37d8e6`。结合本轮实测「flag=1 → 先验 B 槽」，
`[推断]` 这两份对应 A/B 两槽各自的 u-boot 校验逻辑（或互为备份），
**但真正决定选槽的是 `boot_flag`，不是这份镜像内部的两份**。
仍标 **未验证**：没有测试 flag=2 时的选槽行为。

---

## 9. 复现命令清单

```text
# 打断一级（500ms 窗口，需要洪泛）
# 进 kit 后：
help tplcheck
tplcheck
nand read 0x45000000 0x4800000 0x20000
md.b 0x45000000 0x100
nand read 0x45000000 0x800000 0x20000
md.b 0x45000000 0x100
nand read 0x44000000 0x880000 0x400000
iminfo 0x44000000
```

⚠️ 打断一级的窗口只有 **500 ms**（不是 3 s），必须用连续字符洪泛，
不能靠人手按键。本次实现见 `C:\Users\null\grab2.py`（reboot 后延迟 1.2 s 起洪泛 `#`）。

---

## 10. ★ 已实测的完整刷写流程（2026-11-07，从 OpenWrt 回原厂）

本节记录**实际执行过并成功**的一条路径。前置：板子当前跑 OpenWrt（A 槽），
我们的 kit 在两处 u-boot。全程不插 TTL 之外的工具、不用 TFTP。

### 10.1 为什么不用 sysupgrade

`platform_check_image` 要求 tar 成员 `kernel` / `root`，原厂包是 TP 容器格式
⇒ **版本校验就否掉了，`-F` 也绕不过**（`platform_do_upgrade` 里还会再 check 一次）。

### 10.2 关键洞察：原厂内核本来就在板上

`0x880000` 是原厂主槽内核（`boot_flag=1` 选的就是它），我们**从没写过那一片**。
所以不需要从电脑传 4 MB，直接在 u-boot 里把它搬一个位置即可。

### 10.3 实际操作（在 kit 提示符下）

```text
printenv ; nand read 0x44000000 0x880000 0x400000   # 原厂内核 -> RAM
crc32 0x44000000 0x400000                           # 必须等于本地文件 crc32
printenv ; nand erase 0x4880000 0x480000            # 只清 A 槽内核区
printenv ; nand write 0x44000000 0x4880000 0x400000
printenv ; nand read 0x45000000 0x4880000 0x400000  # 回读到【不同】地址
crc32 0x45000000 0x400000                           # 再算一次
```

**实测输出（`[本板实证]`）**：

```
crc32 for 44000000 ... 443fffff ==> 7d03d5fb     ← RAM 源
crc32 for 45000000 ... 453fffff ==> 7d03d5fb     ← 回读
本地 mtd10_kernel_bak.bin                       7d03d5fb
```

三段一致才继续。`0x480000` 是写到 `0x4C80000` 为止，**不碰 `0x4fc0000` 的 rootfs**。

⚠️ 所有写命令都必须带 `printenv ;` 前缀（`guard.py` 白名单要求），
且 `0x4880000/0x480000` 在 `guard.py` 里是 **OPEN** 区，无需 override 标志。

### 10.4 复位后的启动链（实测日志）

```
Dual image validation, image_1 pass. So boot to image_1     ← 一级选 B 槽
U-Boot 2016.01-9ce3157-dirty                                 ← 我们的 kit
tplboot: image_2 kernel 0x480000 @0x04880000 -> 0x44000000   ← kit 试 A 槽
tplboot: bootargs="console=ttyMSM0,115200,n8 rw rootwait"
Starting kernel ...
[0.000000] Kernel command line: console=ttyMSM0,115200n8 root=/dev/mtdblock6 ...
```

⇒ kit 传给 u-boot 的 `bootargs` **被原厂内核完全忽略**，
内核用它编译进 vmlinux 的内置 cmdline。

### 10.5 分区命名陷阱（最容易搞错的地方）

原厂和我们的 mtd 编号**互为主备**：

| 偏移 | 原厂叫法 | 我们的 OpenWrt 叫法 |
|---|---|---|
| `0x700000` | **normal_boot** | normal_boot_bak |
| `0x880000` | **kernel** | kernel_bak |
| `0xfc0000` | **rootfs** | rootfs_bak |
| `0x4700000` | normal_boot_bak | normal_boot |
| `0x4880000` | **kernel_bak** | kernel |
| `0x4fc0000` | **rootfs_bak** | rootfs |

来源：原厂内核启动时的分区打印（`bootm_test.log`），不是推断：

```
[0.905953] 0x000000700000-0x000000740000 : "normal_boot"
[0.907586] 0x000000880000-0x000000c80000 : "kernel"
[0.925939] 0x000000fc0000-0x000001bc0000 : "rootfs"
[1.025914] 0x000004880000-0x000004c80000 : "kernel_bak"
[1.029967] 0x000004fc0000-0x000005bc0000 : "rootfs_bak"
```

⇒ 在原厂 root shell 里回刷 OpenWrt，目标应是 `/dev/mtdblock5`(`kernel_bak`)
和 `/dev/mtdblock6`(`rootfs_bak`)。**这一条尚未实测**，标为未验证。

---

## 11. ★ 擦 `rootfs_data` 让原厂重建可写层（已实测）

### 11.1 症状

原厂启动后 `/proc` 整个不可用：

```
cat /proc/mtd        -> No such file or directory
ls /dev/mtdblock*    -> No such file or directory
ls /dev              -> 只有 console 一个
mount                -> no /proc/mounts
```

内核日志：

```
[3.638076] UBIFS error (ubi0:0 pid 227): ubifs_read_superblock:
           on-flash format version is w5/r0, but software only supports up to version w4/r0
[3.639...] UBIFS (ubi0:0): only R/O mounting is possible
switching to jffs2
jffs2 not ready yet; using ramdisk
mount: mounting /dev/mtdblock7 on /rom/overlay failed: No such device
```

`/dev/mtdblock7` 挂不上 `/rom/overlay` ⇒ preinit 无法建立 `/dev` `/proc`。

### 11.2 原因

OpenWrt 6.12 的 UBIFS 把 `0x6a00000` 那 22 MB 写成了 **w5/r0** 格式；
原厂 4.4.60 的 UBIFS 只支持到 **w4/r0**。两者不兼容。

### 11.3 修复（在 kit 提示符下）

```text
printenv ; nand erase 0x6a00000 0x1600000
```

`0x6a00000 + 0x1600000 = 0x8000000` = flash 末尾，正好擦干净。
`guard.py` 判为 OPEN，无需 override。实测擦除耗时 < 1 s。

### 11.4 结果（`[本板实证]`）

```
[4.021994] UBIFS (ubi0:0): default file-system created
[4.047298] UBIFS (ubi0:0): mounted UBI device 0, volume 0, name "0"
[4.073400] UBIFS (ubi0:0): media format: w4/r0 (latest is w4/r0), ...
```

`mount /rom/overlay failed` 与 `jffs2 not ready yet` **两条都消失**。
随后 `/proc/mtd` 列出 15 个分区、`/dev/mtdblock0..16` 齐全。

### 11.5 但写层仍在 RAM（重要，别误解）

卷名是 `"0"` 而不是 `rootfs_data`，原厂 init 没认：

```
overlayfs:/tmp/overlay/root on /etc type overlay (rw, upperdir=/tmp/overlay/root, ...)
cat /sys/class/ubi/ubi0_0/name  ->  0
```

⇒ `/etc` 的修改**重启即丢**。要真正持久化，还需要把 UBI 卷建成
`rootfs_data` 这个名字并格式化为 UBIFS。**这条未做，标为未验证。**

### 11.6 附带发现：这台机器本来就没有可写层

`boot_cart2.log`（我们动手**之前**的原厂首次启动）里同样报错：

```
[3.624138] UBIFS error (ubi0:0 pid 226): init_constants_early: too few LEBs (2), min. is 17
jffs2 not ready yet; using ramdisk
mount: mounting /dev/mtdblock7 on /rom/overlay failed: No such device
```

⇒ 不能把「没有持久 overlay」归因于我们的移植。

