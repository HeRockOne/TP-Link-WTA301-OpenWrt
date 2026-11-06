# 原厂镜像（用于 `--flash-stock auto`）

只认 md5，文件名可以改但 md5 必须一致，否则脚本拒绝使用。

| 文件 | 大小 | md5 | 说明 |
|---|---|---|---|
| `mtd5_kernel.bin` | 4194304 (0x400000) | `170b2188884cc040d64ac5bed7ddc365` | 原厂 2.0.2 (2024-12-04) 内核，A 槽出厂内容 |
| `mtd6_rootfs.bin` | 12582912 (0xC00000) | `30f487419d90b2239b65035390f3b73f` | 上面那版配套 rootfs |

备用一组（B 槽备份，旧版 4.4.60 / 2024-11-28）：

| 文件 | md5 |
|---|---|
| `mtd10_kernel_bak.bin` | `2868d8e975da7c641e54c72b6beb8f26` |
| `mtd11_rootfs_bak.bin` | `bf2f92ceaf509093c8854825f2dc8d5e` |

四个 md5 都是从原厂全盘镜像 `flash_full_128M.bin`
（`04cd7aaf36e464479d5e12af1ce75f13`）按偏移 dd 出来逐段核对的：

```
0x0488000 / 0x400000  A_kernel  170b2188…
0x04fc0000 / 0xC00000 A_rootfs  30f48741…
0x00880000 / 0x400000 B_kernel  2868d8e9…
0x00fc0000 / 0xC00000 B_rootfs  bf2f92ce…
```

写入目标（两种固件下编号一致）：

```
A 槽 = mtd5  0x04880000  ← 脚本只写这里
A 槽 = mtd6  0x04FC0000
B 槽 = mtd10 0x00880000  ← 只读
B 槽 = mtd11 0x00FC0000  ← 只读
```
