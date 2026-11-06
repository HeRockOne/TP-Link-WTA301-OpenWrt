# 原厂镜像（供 `--flash-stock` / `--restore-bslot` 使用）

只认 md5，文件名可以改，md5 不符直接拒绝。

## 两组镜像

### A 槽 · 原厂 2.0.2（2024-12-04）

| 文件 | 大小 | md5 |
|---|---|---|
| `mtd5_kernel.bin` | 4194304 (0x400000) | `170b2188884cc040d64ac5bed7ddc365` |
| `mtd6_rootfs.bin` | 12582912 (0xC00000) | `30f487419d90b2239b65035390f3b73f` |

### B 槽 · 原厂 4.4.60（2024-11-28）

| 文件 | 大小 | md5 |
|---|---|---|
| `mtd10_kernel_bak.bin` | 4194304 (0x400000) | `2868d8e975da7c641e54c72b6beb8f26` |
| `mtd11_rootfs_bak.bin` | 12582912 (0xC00000) | `bf2f92ceaf509093c8854825f2dc8d5e` |

> 文件名的 mtdN 用的是 **OpenWrt 视角**编号：
> OpenWrt 里 mtd5=0x4880000(A 槽)、mtd10=0x880000(B 槽)。
> 原厂固件视角正好相反。**永远按物理偏移判断，不要按名字/编号。**

## 来源与核对

四个 md5 都是从原厂全盘镜像 `flash_full_128M.bin`
（`04cd7aaf36e464479d5e12af1ce75f13`）按偏移 dd 出来逐段核对的：

```
0x04880000 / 0x400000   A 槽 kernel   170b2188…
0x04FC0000 / 0xC00000   A 槽 rootfs   30f48741…
0x00880000 / 0x400000   B 槽 kernel   2868d8e9…
0x00FC0000 / 0xC00000   B 槽 rootfs   bf2f92ce…
```

## 写入落点

| 操作 | 源 | 目标 |
|---|---|---|
| `--flash-stock auto`（跑在原厂） | A 槽那组（2.0.2） | mtd13+0x80000 / mtd11 |
| `--flash-stock auto`（跑在 OpenWrt） | A 槽那组（2.0.2） | mtd5 / mtd6 |
| `--restore-bslot` | B 槽那组（4.4.60） | mtd5 / mtd6 |

`.gitignore` 排除了 `*.bin`，仓库里只留本说明。实际使用请把四个文件放这个目录。
