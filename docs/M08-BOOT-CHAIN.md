# M08 引导链 / chosen / bootargs

**结论：引导链不含任何可迁移组件（u-boot 不动）；三个 bootargs 拼接环节中，
唯一与 25.12.6 有关的是 kernel 侧的 `bootargs-append` 补丁 —— 已确认 6.12 里仍在。**

---

## 1. 三级引导链（全部在 u-boot 侧，迁移不动）

```
一级 u-boot（factory_boot @0x0，0x3c0000）
   "input <abort key> to stop autoboot in 500 ms"   ← 人手按不到
        │
        ▼
二级 u-boot（normal_boot，kit 版 = 我们自己编的 failsafe）
   "Hit any key to stop autoboot: 3 2 1 0"          ← 唯一的 3 秒窗口
        │
        ├─ 正常路径 → tpimg_boot_slot()
        │      先试 image_2（TP 头 @ WTA301_TPHDR_OFF = 0x04800000）
        │      再试 image_1（TP 头 @ TPIMG_B_HDR_ADDR = 0x00800000）
        │      → nand read 0x44000000 koff klen → bootm
        │
        └─ 失败 → 三级 failsafe（串行，无返回路径）
```

**与迁移的关系**：零。u-boot 二进制、链接基址（`0x49900000`）、TP 头格式全部不变。
25.12.6 内核只要满足 TP 头的校验条件就能被 boot 起来。

---

## 2. TP 头（`tplink_tpimg.h` 原文）

```c
#define TPIMG_F_UBOOT_OFF       0x48
#define TPIMG_F_UBOOT_LEN       0x4c
#define TPIMG_F_TPHDR_OFF       0x50
#define TPIMG_F_TPHDR_LEN       0x54
#define TPIMG_F_KERNEL_OFF      0x58
#define TPIMG_F_KERNEL_LEN      0x5c
#define TPIMG_F_ROOTFS_OFF      0x60
#define TPIMG_F_ROOTFS_VERIFY   0x64
#define TPIMG_F_MD5_UBOOT       0x90    /* md5(u-boot 槽)，16 字节 */
#define TPIMG_F_MD5_PAYLOAD     0xa0    /* md5(kernel 区 ‖ rootfs 前段)，16 字节 */

#define TPIMG_HDR_LEN           0x20000

#define WTA301_UBOOT_OFF        0x04700000u
#define WTA301_UBOOT_LEN        0x00040000u
#define WTA301_TPHDR_OFF        0x04800000u
#define WTA301_TPHDR_LEN        0x00020000u
#define WTA301_KERNEL_OFF       0x04880000u
#define WTA301_ROOTFS_OFF       0x04FC0000u
#define WTA301_ROOTFS_SLOT      0x00C00000u
#define WTA301_KERNEL_MAX       (WTA301_ROOTFS_OFF - WTA301_KERNEL_OFF)  /* 0x740000 */
#define WTA301_VERIFY_MIN       0x00B00000u
#define WTA301_VERIFY_MAX       WTA301_ROOTFS_SLOT
#define WTA301_IMAGE_MAX        (TPIMG_HDR_LEN + WTA301_KERNEL_MAX + WTA301_ROOTFS_SLOT)
```

### 2.1 `tpl_boot_one()` 实际校验什么（源码原文 `tplink_tpimg.c`）

```c
if (nand_read(nand, hdr_addr, &len, h) || len != TPIMG_HDR_LEN)  return -1;  /* 头 0x20000 可读 */
if (memcmp(h, tpimg_magic, 8))                                    return -1;  /* 前 8 字节 magic */
koff = be32(h + TPIMG_F_KERNEL_OFF);
klen = be32(h + TPIMG_F_KERNEL_LEN);
if (!klen || klen > WTA301_KERNEL_MAX)                            return -1;  /* 非零且 ≤ 0x740000 */
```

**只有这三条。`+0xa0`（`MD5_PAYLOAD`）不校验。**

⇒ 对迁移的含义：**改内核/rootfs 不需要重写 `+0xa0`**，只要
`kernel_len ≤ 0x740000`（7.25 MiB）。6.12 内核通常比 6.18 更小，风险低（R7）。

⇒ 但 `mk_op_pack.py` 仍会算 `+0xa0`，这是**为了自检**（`verify_op_pack.py` 用），
不是 bootloader 要求。

### 2.2 `WTA301_KERNEL_MAX = 0x740000` 的来源

不是拍脑袋：`ROOTFS_OFF(0x4FC0000) - KERNEL_OFF(0x4880000) = 0x740000`，
即 **kernel 区到 rootfs 起点的物理空隙**。DTS 里 `kernel@4880000` 声明的 `0x400000`
是过时值（`fix10.3` 已改成 `0x740000`）。

---

## 3. bootargs 三段拼接（实测复现）

### 3.1 拼接链

```
① u-boot 侧：tpl_boot_one()
   const char *ba = getenv("tplbootargs");
   if (!ba) ba = TPIMG_BOOT_ARGS_DEFAULT;      ← "console=ttyMSM0,115200,n8 rw rootwait"
   setenv("bootargs", ba);
   → bootm 0x44000000

② kernel 侧：drivers/of/fdt.c early_init_dt_scan_chosen()
   p = of_get_flat_dt_prop(node, "bootargs", &l);        ← DTB 的 chosen/bootargs（我们没有）
   p = of_get_flat_dt_prop(node, "bootargs-append", &l); ← 有的，追加进去
   strlcat(cmdline, p, ...)

③ 结果（板上实测 /proc/cmdline 原文）
```

### 3.2 实测 cmdline（`work/evidence/V3-boot.log:125`）

```
[    0.000000] Kernel command line: console=ttyMSM0,115200,n8 rw rootwait \
    root=/dev/mtdblock6 rootfstype=squashfs rootwait coherent_pool=2M \
    ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data
```

拆开正好是：

| 来源 | 片段 |
|---|---|
| `TPIMG_BOOT_ARGS_DEFAULT` | `console=ttyMSM0,115200,n8 rw rootwait` |
| DTB `chosen/bootargs-append` | ` root=/dev/mtdblock6 rootfstype=squashfs rootwait coherent_pool=2M ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data` |

（前一段的 `rootwait` 和 append 段里的 `rootwait` 是两次，原样保留）

### 3.3 S7 DTB 原文（`patches/s7-actual-dtb.dts:1229-1232`）

```dts
chosen {
    stdout-path = "serial0:115200n8";
    bootargs-append = " root=/dev/mtdblock6 rootfstype=squashfs rootwait coherent_pool=2M ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data";
};
```

**注意**：`bootargs-append`（连字符在前）是 **kernel 侧**属性；
u-boot 的 TP-Link 代码里读的是 `append-bootargs`（顺序相反），两者是不同的东西。
我们的 FIT 根节点没有 `append-bootargs`，所以 u-boot 那条路径不触发。

---

## 4. 原厂对照

`patches/factory/fdt_mp03.1.dts:2438`：

```dts
chosen {
    bootargs = "console=ttyMSM0,115200,n8 rw init=/init";
    bootargs-append = " swiotlb=1";
    stdout-path = "serial0";
};
```

| 项 | 原厂 | S7 |
|---|---|---|
| `bootargs` | **有**（`init=/init`） | 无（由 u-boot 提供） |
| `bootargs-append` | 有（` swiotlb=1`） | 有（rootfs/overlay 参数） |
| `init=` | **`/init`** | **不指定** |
| `swiotlb=1` | 有 | 无（用 `coherent_pool=2M` 替代） |

### 4.1 `init=/init` 是坑（已实证，写在 `tplink_tpimg.h:150-158`）

```
原厂 rootfs 里有 /init（OpenWrt 系老布局），但我们跑的 OpenWrt 主线
rootfs 只有 /sbin/init，没有 /init。硬写 init=/init 会让内核走到
    Run /init as init process
    Kernel panic - not syncing: Requested init /init failed (error -2)
因为 kernel_init() 对 cmdline 指定的 init 失败是直接 panic，不 fallback。
故此处不指定 init=，让内核用默认搜索顺序
(/sbin/init, /etc/init, /bin/init, /bin/sh)。
```

**25.12.6 同样只有 `/sbin/init`** ⇒ 这条规则继续有效，迁移时**不要**加 `init=`。

### 4.2 `swiotlb=1` vs `coherent_pool=2M`

原厂（32 位 QSDK）用 `swiotlb=1`（1 MiB 软件 IO TLB 池，36 位寻址）。
我们用 `coherent_pool=2M`（arm64 DMA coherent 池，ath11k 需要大连续缓冲区）。

**25.12.6（arm64/6.12）沿用 `coherent_pool=2M`**，不要换成 `swiotlb=1`。

### 4.3 `CONFIG_CMDLINE` 里嵌着原厂 cmdline（观察，非问题）

我们编出的 6.18.55 Image 反解后，`drivers/of/fdt.c` 的字符串区出现：

```
bootargs-append
console=ttyMSM0,115200n8 root=/dev/mtdblock6 rootfstype=squashfs ubi.mtd=7 ubi.mtd=3  rootwait swiotlb=1
```

后面那条是 **`CONFIG_CMDLINE` 的默认值**（原厂 cmdline 被继承进了配置）。
`CONFIG_CMDLINE` 只在「DTB 与 u-boot 都没给 bootargs」时生效，我们有 bootargs，
所以**不会触发**。但迁移时应确认 25.12.6 的 `ipq50xx/config-6.12` 里
`CONFIG_CMDLINE` 不是硬编码了原厂那一串（否则万一触发会启动到错误 rootfs）。

---

## 5. 对 25.12.6 迁移的裁决

### 5.1 必须确认的一条（已确认 ✅）

`bootargs-append` 是 **OpenWrt generic 补丁**，不是 QSDK 专有：

- 起源：ipq40xx → ipq806x → 2022-01-24 移到 generic
  commit `81a561b4` "kernel: move bootargs-append patch to generic"
  <https://github.com/openwrt/openwrt/commit/81a561b4a64d3d0107e82f49e52d4d0ff1a29719>
- **25.12.6 里确实存在**：
  `target/linux/generic/hack-6.12/920-device_tree_cmdline.patch`（703 字节，原文）：

```diff
--- a/drivers/of/fdt.c
+++ b/drivers/of/fdt.c
@@ -1049,6 +1049,9 @@ int __init early_init_dt_scan_chosen(cha
 	p = of_get_flat_dt_prop(node, "bootargs", &l);
 	if (p != NULL && l > 0)
 		strscpy(cmdline, p, min(l, COMMAND_LINE_SIZE));
+	p = of_get_flat_dt_prop(node, "bootargs-append", &l);
+	if (p != NULL && l > 0)
+		strlcat(cmdline, p, min_t(int, strlen(cmdline) + (int)l, COMMAND_LINE_SIZE));
```

⇒ **`bootargs-append` 机制在 25.12.6 上可用**。这是 M8 的最大不确定性，已消除。

### 5.2 迁移动作清单

| # | 动作 | 说明 |
|---|---|---|
| 1 | u-boot **不改** | 二级 u-boot 二进制、链接基址、TP 头格式全不变 |
| 2 | DTB `chosen` **原样搬** | `stdout-path = "serial0:115200n8"` + 同一条 `bootargs-append` |
| 3 | **不加** `init=` | 6.12 的 rootfs 只有 `/sbin/init` |
| 4 | 保留 `coherent_pool=2M` | arm64 上 ath11k 需要 |
| 5 | 保留 `ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data` | overlay 机制不变 |
| 6 | 核对 `ipq50xx/config-6.12` 的 `CONFIG_CMDLINE` | 确认不是原厂那串 |
| 7 | 核对 `kernel_len ≤ 0x740000` | 编译后立即查 |
| 8 | **不需要**重写 TP 头 `+0xa0` | `tpl_boot_one()` 不校验 |

### 5.3 6.12 vs 6.18 潜在差异（逐条待核，P2 做）

| # | 项 | 风险 | 核法 |
|---|---|---|---|
| a | `strscpy` vs `strlcpy` 语义 | 低（6.12 已是 `strscpy`） | 补丁已按 6.12 编写，`hack-6.12/` 目录名即证据 |
| b | `early_init_dt_scan_chosen()` 签名 | 低 | 补丁 context 行是 `(cha` => `(char *cmdline)`，与 6.12 一致 |
| c | `/sbin/init` 存在性 | 中 | P3 重拼 rootfs 后 `unsquashfs -l \| grep sbin/init` |
| d | overlay 参数名 `fstools_overlay_name` | 中 | 6.12 的 `fstools`/`libfstools` 是否仍认这个变量名 |
| e | `CONFIG_CMDLINE` 默认值 | 低 | 读 `config-6.12` |

**d 是新的待验项**：`fstools_overlay_name=wta301data` 让 overlay 卷名叫 `wta301data`。
6.12 的 fstools 是否仍支持这个 cmdline 参数，P3/P4 要验（`mount` 输出即可确认）。

---

## 6. P4 上电必测（M08 部分）

| # | 测什么 | 通过判据 |
|---|---|---|
| 1 | 串口出 `Starting kernel ...` 后 3 秒内有输出 | 内核起来了 |
| 2 | `cat /proc/cmdline` | 与 §3.2 一致（含 `ubi.mtd=rootfs_data3`） |
| 3 | `dmesg \| head -1` | 有 `Linux version 6.12.112` |
| 4 | `mount \| grep overlay` | `wta301data` 或 `ubi0_0` 挂到 `/overlay` |
| 5 | 无 `Requested init ... failed` | 无 panic |
| 6 | `cat /proc/mtd` | 14 项（M02） |

---

## 7. 一句话

**引导链与 TP 头完全不参与迁移；bootargs 靠 u-boot 默认串 + DTB 的
`bootargs-append`（OpenWrt generic 补丁，25.12.6 的 `hack-6.12/920` 里在），
迁移时原样搬 DTB 的 chosen 段，不写 `init=`，`coherent_pool=2M` 保留。**
