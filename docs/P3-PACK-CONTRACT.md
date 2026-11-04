# P3 打包契约（从源码构建产物 → 可刷四件套）

**已用 S7 产物现场复核**（`work/images/out-op-v19-fix10.1-S7/`，2026-11-05）：
`op_tphdr_0x20000.bin` 的字段与哈希全部与下面一致，不是抄来的常量，是 parse 出来的。

---

## 1. TP 头几何（大端 u32，实测值）

| 偏移 | 字段 | S7 实测 | 含义 |
|---|---|---|---|
| `0x48` | UBOOT_OFF | `0x4700000` | 二级 u-boot（normal_boot） |
| `0x4c` | UBOOT_LEN | `0x40000` | |
| `0x50` | TPHDR_OFF | `0x4800000` | 本头自己 |
| `0x54` | TPHDR_LEN | `0x20000` | |
| `0x58` | KERNEL_OFF | `0x4880000` | kernel 区起点 |
| `0x5c` | KERNEL_LEN | `0x480000` | **写入长度**（不是真实内核大小） |
| `0x60` | ROOTFS_OFF | `0x4fc0000` | rootfs 区起点 |
| `0x64` | ROOTFS_LEN | `0xbc0000` | 写入长度 |
| `0x90` | MD5_UBOOT | `94867ec5…` | md5(normal_boot 那 0x40000) |
| `0xa0` | MD5_PAYLOAD | `cb482b47…` | **md5(kernel[0:0x480000] ‖ rootfs[0:0xbc0000])** |

`+0xa0` 已验证：四种截取口径全等（因为两个文件本来就只有这么长），
即 **md5 覆盖的是补齐到写入长度的整块**，不是真实长度。
`tpl_boot_one()` 只校验头可读 + magic + `klen ≤ 0x740000`，**不校验 `+0xa0`**；
`+0xa0` 是原厂 `checkImage` 用的，我们刷完自检时用它当"整包指纹"。

## 2. 四件套与刷写顺序

| 文件 | 区 | NAND 偏移 | 写入长度 | RAM | 顺序 |
|---|---|---|---|---|---|
| `op_kernel_0x480000.bin` | kernel | `0x4880000` | `0x480000` | `0x44000000` | 10 |
| `op_rootfs_0xbc0000.bin` | rootfs | `0x4FC0000` | `0xBC0000` | `0x45000000` | 20 |
| `ubi_rootfs_data3_wta301data.img` | ubi | `0x1BC0000` | 文件大小 | `0x44000000` | 30 |
| `op_tphdr_0x20000.bin` | tphdr | `0x4800000` | `0x20000` | `0x46000000` | 40 |

**tphdr 必须最后写**（它的 `+0xa0` 是整包提交哈希）。
校验 RAM 落点 `0x43000000`；每区必须 **本地 crc32 = RAM crc32 = `nand read` 到另一址的 crc32**。

## 3. 从 25.12.6 源码构建产物取料

| 目标 | 源 |
|---|---|
| kernel（FIT/ITB） | `build_dir/target-aarch64_cortex-a53_musl/linux-qualcommax_ipq50xx/image-ipq5018-wta301/` 下的 FIT（`FitImageLzma` 产物），或 `bin/targets/…/…-fit.itb` |
| rootfs（squashfs） | `build_dir/…/root.squashfs`（未 strip 的裸 squashfs，不是 sysupgrade.bin 里的那层包装） |
| ubi（overlay） | `mkfs.ubifs -F` 造 → `ubinize`（卷名 `wta301data`），**必须 `-F`**，BIGLPT 会 bad master node |
| tphdr | 由 `work/op-build/mk_op_pack.py` 从 kernel+rootfs 生成（`+0xa0` 自动算） |

### 3.1 硬约束
- kernel 真实长度 ≤ `0x740000`（否则撞 rootfs@`0x4fc0000`）——
  `KERNEL_SIZE := 7424k` 触发 `Build/check-size`，超限**只是删产物不报错**。
- rootfs 真实长度 ≤ `0xbc0000`（12 MiB 槽），且 `VERIFY_MIN 0xb00000`。
  S7 实测 squashfs `0xb28000` 左右，余量只剩 ~600 KB —— 加 luci 后必须复核（`work/out-final/verify_release.py`）。
- UBI 镜像写入长度用**文件大小**，擦除长度 `0x2440000`。

## 4. 打包后自检（不过不许上板）
1. `python work/out-final/verify_release.py --dir <outdir>` —— 四区 crc32 / md5 / 几何全查
2. 手工再算一次 `md5(kernel‖rootfs) == tphdr[0xa0:0xb0]`
3. `s3_check.py` 的 `check_ubifs()`（收 bytes）验 UBIFS superblock：必须带 `SPACE_FIXUP(0x04)`，不得有 `BIGLPT(0x02)`
