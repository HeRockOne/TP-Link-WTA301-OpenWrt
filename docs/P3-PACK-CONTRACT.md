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

## 2.5 UBI（overlay）区：**直接复用冻结的 S7 镜像，不重建**

`work/backup/FROZEN-S7-20261105/ubi_rootfs_data3_wta301data.img` = **1,966,080 B = 15 个 PEB**
（PEB 128 KiB，LEB 126,976）。逐 PEB 看过：15 个块 EC 头全 `UBI#`，载荷只有 128–22,142 字节 ⇒
就是「刚 `mkfs.ubifs -F` + `ubinize` 出来、还没写多少东西」的空 overlay（卷名 `wta301data`）。

这个镜像的内容**与新内核/新 rootfs 无关**（overlay 里只有空 ubifs 的骨架 + volume table），
所以 P3 **不重新生成**：

- 单一变量原则：S7 上这份镜像已实证能被 `ubiattach` + `fstools_overlay_name=wta301data` 正常挂载
- 自己重跑 `mkfs.ubifs -F` + `ubinize` 只会引入「BIGLPT / vid 偏移 / 时间戳」这三个已知雷点
- 刷写仍按红线擦 `0x2440000`（8 个 PEB 余量留给坏块与增长），只写前 0x1e0000

## 3. 从源码构建产出取哪两个文件

| 目标 | 源码构建里的来源 |
|---|---|
| FIT/ITB kernel | `build_dir/target-aarch64_cortex-a53_musl/linux-qualcommax_ipq50xx/image-ipq5018-wta301/` 下的 itb（`FitImageLzma` 生成）；`DEVICE_DTS_CONFIG` 必须与 u-boot 期待的 config 名一致 |
| rootfs squashfs | 同目录 `root.squashfs`（未 strip 版）；或 `bin/targets/.../*-squashfs-sysupgrade.bin` 拆包 |
| tphdr | 用 `work/op-build/mk_op_pack.py` 现生成（它按 §1 的几何写死并算 `+0xa0`） |

## 9. P3 实际产物（2026-11-05，`work/images/v25.12.6-P3/`）

| 文件 | 大小 | crc32 | md5 / sha256 |
|---|---|---|---|
| `op_kernel_0x480000.bin` | 4,718,592 | 7678e6d7 | md5 `dd6c716107be490c3606e7ec28126da2` |
| `op_rootfs_0xbc0000.bin` | 12,320,768 | 9dd9d9d3 | md5 `6bd248c27dfbae75dd57b50b985ed41d` |
| `op_tphdr_0x20000.bin` | 131,072 | 5a8b3e89 | md5 `b9e0858537eb6338409ce7131929ec6c` |
| `ubi_rootfs_data3_wta301data.img` | 1,966,080 | e850127a | 冻结复用（crc32 与 S7 完全一致） |

来源 sysupgrade：`openwrt-qualcommax-ipq50xx-tplink_wta301-squashfs-sysupgrade.bin` 12,534,037 B
（内 `kernel` ITB 4,276,536 B / `root` squashfs4 8,244,224 B）

**独立复核（不只信打包器）全部 PASS**：tphdr 八字段 = S7 契约值；`+0x90` = md5(mtd4) = `94867ec5c85a92567405516651935691`；
`+0xa0` = 本地重算 md5(kernel‖rootfs) = `8a45889a2355038fbec1f65f95a23602`；kernel 文件 = FIT(4,276,536) + 全 `0xFF` 补齐到 0x480000；
rootfs `hsqs` v4.0；FIT 内含 `TP-Link-WTA301` 与 `config@mp02.1`。

**`--kblk 0x480000` 是硬要求**：内核区必须按整区长度补齐（不是只对齐 0x20000 擦除块）。若只写 0x420000，
NAND 尾部 0x60000 残留旧数据而 `+0x5c KERNEL_LEN` 仍为 0x480000 ⇒ u-boot 的 md5 校验必然失败 ⇒ 落 B 槽。

## 10. ★ UBI 卷名必须是 `rootfs_data`（不能用 S7 的冻结镜像）

**发现（读 25.12.6 源码，非猜测）**：`fstools-2026.05.23~16718b6e/libfstools/rootdisk.c:166`

```c
static struct volume *rootdisk_volume_find(char *name)
{
	if (strcmp(name, "rootfs_data") != 0)
		return NULL;
```

且全树 `grep -rn 'fstools_overlay_name\|overlay_name'` **零命中**，`libfstools/ubi.c` 里**没有** `volume_create`。

⇒ 后果链：
1. S7 的冻结镜像卷名是 `wta301data`（S7 的 fstools 打了 `fstools_overlay_name` 补丁，与 bootargs 里那行配套）；
2. 25.12.6 **不认**这个补丁，也不会自己造卷；
3. 卷名不对 ⇒ `volume_find("rootfs_data")` 返回 NULL ⇒ **首启没有 overlay**（只读系统、配置写不进、`sysupgrade` 保留配置失效）。

**解决**：现造空卷，卷名 `rootfs_data`，几何与冻结镜像**逐字段一致**（只差名字）：

| 字段 | 冻结镜像 | 新镜像 |
|---|---|---|
| 大小 / PEB 数 | 1,966,080 / 15 | 同 |
| `reserved_pebs` | 13 | 13 |
| `alignment` / `data_pad` | 1 / 0 | 同 |
| `vol_type` / `flags` | 1(dynamic) / 1(autoresize) | 同 |
| `name_len` / `name` | 10 / `wta301data` | **11 / `rootfs_data`** |

生成命令（在 `deliver/make-release.sh` §5 里，可复现）：

```bash
mkfs.ubifs -m 2048 -e 126976 -c 289 -F -x zlib -r <空目录> -o ubifs.img
printf '[rootfs_data]
mode=ubi
image=%s
vol_id=0
vol_type=dynamic
vol_name=rootfs_data
vol_flags=autoresize
'     ubifs.img > ubinize.cfg
ubinize -o ubi.img -m 2048 -p 131072 -s 2048 -O 2048 ubinize.cfg
```

**vtbl CRC 校验公式**（离线可验，两镜像都通过）：
`crc = zlib.crc32(vtbl_rec[0:168], 0) ^ 0xFFFFFFFF`，记录在 PEB0 + `0x1000`，长 172 B，`crc` 为末尾 BE32。
（注意：**不是** zlib 默认那套 init=0/xor=0，也不是 `crc32(data, ~0)`。）

**bootargs 里的 `fstools_overlay_name=wta301data` 保留不动**：对 25.12.6 是惰性字符串（没人解析），
保留可让板级 DTS 与 S7 实跑 DTB 保持逐字一致（R16 教训：不要为"好看"去动已对拍一致的 DTS）。
