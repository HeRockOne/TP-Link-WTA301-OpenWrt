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
