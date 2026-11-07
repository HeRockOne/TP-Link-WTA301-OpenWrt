# Go 版工具刷写事故与正确配方（2026-11-07）

**本次唯一变量**：把 `writeChunk` 从 `dd of=/dev/mtdblockN` 换成内核 MTD 工具。

---

## 1. 三次尝试，两次错的，一次对的

| # | 写入方式 | 结果 | 判据 |
|---|---|---|---|
| 1 | `dd of=/dev/mtd5`（裸字符设备） | **分区报废** | dd 报 `32+0 records out` 一切正常，回读 md5 `e5c55a50` ≠ `2868d8e9`；之后 `/dev/mtdblock5` 一律 `I/O error` |
| 2 | `dd of=/dev/mtdblock5`（块设备） | 读不了 | `dd: /dev/mtdblock5: I/O error`；dmesg: `MTD device 'kernel' is NAND, please consider using UBI block devices instead` |
| 3 | `mtd erase <label>` + `mtd -q write <file> <label>` | **✅ 正确** | 4 MiB 用时 1.84 s，回读 md5 `2868d8e9` 与源完全一致；`mtdblock5` 恢复正常 |

### 为什么 #1 必坏
这颗 NAND 是 GigaDevice GD5F1GQ5REYIG（page 2048 / erase 128 KiB / **ECC 8-bit**）。
每页的 ECC 校验码由**内核 MTD 层**算出并写进 OOB。
`dd` 直接写 `/dev/mtdN` 绕过内核，写进去的是没有校验码的裸数据 ⇒ 之后读全部 ECC 校验失败。

文档早有记录，我没先查：
- `work/docs/11-事故复盘与正确刷写配方.md:389` —「`nand write.raw` / 改 ECC 参数 → OOB 布局被写乱，整片读不出来。**只用 `nand write`，不用 `.raw`**」
- `work/docs/10-单镜像模式与新刷写方案.md:119` —「`mtd erase` → `mtd write 原厂FIT` → **回读 md5 校验，通过才 reboot**」

### 为什么 #2 在本板不可用
`ps1` 版当时就是用 `dd of=/dev/mtdblockN` 刷成功的 —— 但那是在**原厂 4.4.60** 下。
`OpenWrt 6.12.112` 的 `mtdblock` 对未做 UBI 的 NAND 分区会直接拒绝读。

### busybox 的 `mtd` 不认 `-e`
mtd-utils 的 `mtd -e write` 在 busybox 上报 `Usage:` —— `-e` 是布尔开关但实现不同。
必须两条命令：`mtd erase <label>` 然后 `mtd -q write <file> <label>`。

---

## 2. 更严重的事故：同槽擦写把系统卡死

擦对的分区、用对的方式，**但擦的是自己正在运行的那个槽**：

```
板子在 A 槽跑 OpenWrt：kernel 0x4880000 / rootfs 0x4fc0000
--flash-op 也写 A 槽（0x4880000）
→ mtd erase kernel   ← 擦自己正在用的内核
→ ping 通（内核网络栈活着），但 SSH 22 / HTTP 80 全部连不上
→ 用户态进程全部卡在 MTD 全局锁上，只能断电重启
```

**机理**：`mtd erase` 持有 MTD 全局锁，而 rootfs（squashfs）的读也走 MTD。
擦除期间所有要读 rootfs 的进程（dropbear、uhttpd、busybox）全部阻塞。

**这是概率性的**：同样的操作前一次成功（`--flash-stock` 写 A 槽，2.0 s + 5.9 s 都过了），
再跑一次就卡死。所以不能靠"上次行"来判断。

### 铁律
```
原厂跑 B 槽（0x880000 / 0xfc0000） → 写 A 槽（0x4880000 / 0x4fc0000） ✓ 交叉，安全
OpenWrt 跑 A 槽（0x4880000 / 0x4fc0000） → 写 B 槽 ✓ 交叉，安全
OpenWrt 跑 A 槽 → 写 A 槽 ✗ 概率性死锁
```

已落到代码：`guard.go` 的 `ActiveSlot()` / `TargetSlot()` / `CheckSameSlot()`。
同槽默认拒绝，必须显式 `-allow-same-slot` 才过，且会打印后果。

### 断电重启后为什么不会变砖
一级 u-boot 有双向回退（`mtd0` 内字符串，两份副本 0x2fcbc2 / 0x37cbc2）：
```
Image_1 check failed, to check image_2 now
Image_2 check failed, to check image_1 now
```
A 槽内核被擦坏 ⇒ 校验不过 ⇒ 自动跳 B 槽。
而这次事故中 **B 槽（0x880000 kernel + 0xfc0000 rootfs）一行没动，是完整的原厂 4.4.60**。

---

## 3. 分区表会随固件变（不只是编号错位）

OpenWrt 6.12.112 实测 `/sys/class/mtd/mtdN/`：

```
mtd0  0x0000000 0x3C0000 factory_boot
mtd1  0x0400000 0x020000 factory_info
mtd2  0x0480000 0x020000 art
mtd3  0x0500000 0x200000 config
mtd4  0x4700000 0x040000 normal_boot      A 槽 u-boot
mtd5  0x4880000 0x740000 kernel            A 槽 kernel ★ 7.25 MiB，不是 4 MiB
mtd6  0x4FC0000 0xC00000 rootfs            A 槽 rootfs
mtd7  0x5880000 0x340000 rootfs_data       overlay
mtd8  0x6A00000 0x1600000 rootfs_data2
mtd9  0x700000  0x040000 normal_boot_bak   B 槽 u-boot
mtd10 0x880000  0x400000 kernel_bak        B 槽 kernel
mtd11 0xFC0000  0xC00000 rootfs_bak        B 槽 rootfs
mtd12 0x1BC0000 0x2440000 rootfs_data3     overlay 数据
mtd13 0x4000000 0x020000 boot_flag         ★ 永不写
```

**关键**：OpenWrt 下 `mtd5 kernel` 是 `0x740000`（7.25 MiB），
所以 4.28 MiB 的 OpenWrt FIT **直接写 mtd5 就够**，不需要"写 mtd13 容器 +seek 8"。
那个容器方案是**原厂分区表**下的说法（原厂 mtd13 = firmware_bak 0x0800000 长 0x2620000）。

⇒ `ResolveTarget()` 按「绝对偏移 + 长度」自动挑分区，两种固件下都对。
⇒ 但**永远按绝对偏移反查**，绝不按编号或名字 —— OpenWrt 下 `mtd13` 是 `boot_flag`，
  原厂下 `mtd13` 是 `firmware_bak`。按编号判会往"永不写"的区域写。

---

## 4. 传输与校验（已验证）

```
上传 17 MB 包   SSH 管道 cat >          3.1 s
上传 4 MB 内核  SSH 管道 cat >          0.8 s
上传 12 MB rootfs                       2.3 s
mtd erase + write 4 MB                  2.0 s
mtd erase + write 12 MB                 5.9 s
回读校验（裸 mtdN 读 + md5sum）          已含在上面
```

回读**用裸字符设备**（`/dev/mtdN`）而不是 `mtdblockN`：
读不需要解 ECC，快，且能暴露写坏的情况；`mtdblock` 还会读到缓存脏数据
（实测刚写完读 `mtdblock6` 得到 `df4c963d`，过一会儿再读才对 `bf2f92ce`）。

---

## 5. 当前板子状态（断电重启前）

```
A 槽 kernel 0x4880000  可能半擦（事故点）
A 槽 rootfs 0x4fc0000  OpenWrt 6.12.112
A 槽 u-boot 0x4700000  kit d0ada9f7
B 槽 kernel 0x880000   原厂 4.4.60 2868d8e9   ★ 完好
B 槽 rootfs 0xFC0000   原厂 4.4.60 bf2f92ce   ★ 完好
B 槽 u-boot 0x700000   kit d0ada9f7
mtd0/mtd1/mtd2/mtd14   从未被写过
```

断电重启预期：一级 u-boot 验 A 槽失败 → 跳 B 槽 → 起原厂 4.4.60 → `192.168.1.175` 回来。
