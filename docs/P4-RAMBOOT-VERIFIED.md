# P4 第一步：RAM 试跑（零写入）

**日期**：2026-11-05 · **唯一变量**：把 P5 的 `op_kernel_0x480000.bin` 用 `tftpboot` 装进 RAM 后 `bootm`，
**不写任何 flash**。

## 1. 为什么先 RAM 试跑

AGENTS §5.4：「能 `bootelf -p` 验证的，绝不先烧 flash」。
FIT 里的内核 + 我们的板级 DTB 是 P2 的全部产出，先证明它能在这块板上启动，
才能把「刷写」这个不可逆动作变成「验证一个已知能跑的东西」。

## 2. 前置核对（全部 PASS）

| 检查 | 结果 |
|---|---|
| 串口通道 | `lap.py --ensure` → `socket://127.0.0.1:7001` |
| TFTP 服务 | `192.168.1.100:69`（Windows 那台机的以太网口，板子直连） |
| TFTP 根目录 | `C:\Users\sophia\Downloads\wta\op` |
| 四件套双端 md5+size | **4/4 PASS**（kernel `7135b320…` / rootfs `99013958…` / tphdr `f384279b…` / ubi `ccda9ccf…`） |
| `ethact` | env 原为 `eth0`，`setenv ethact eth1` 后 `ping 192.168.1.100` → `host is alive` |
| TFTP 传输 | `Bytes transferred = 4718592 (0x480000)`，`filesize=480000` |
| **RAM crc32** | `crc32 for 44000000 ... 4447ffff ==> 0cfe65c5` = 本地文件 crc32 ✅ |

`ethact eth1` 是历史验证过的物理口（`work/evidence/flash-kernel-fix9b.log` 同款）；
`setenv` 只改 RAM env，**没有 `saveenv`**，断电即恢复。

## 3. 启动结果：全部关键项 PASS

```
Linux version 6.12.112 (root@DESKTOP-7V87KGU)
  (aarch64-openwrt-linux-musl-gcc (OpenWrt GCC 14.3.0 r33311-981c978eff) 14.…
Machine model: TP-Link WTA301
Kernel command line: console=ttyMSM0,115200n8 root=/dev/mtdblock6 rootfstype=squashfs
  rootwait coherent_pool=2M ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data
Memory: 175112K/262144K available (8896K kernel code, …)
```

| 验证点 | 证据 |
|---|---|
| 内核版本 | `6.12.112` + OpenWrt GCC 14.3.0 ✅ |
| 板级 model | `Machine model: TP-Link WTA301` ⇒ 我们的 DTS 被采用 ✅ |
| 内存 | `262144K` 总量、可用 175112K ⇒ `/memory` 256MiB 生效 ✅ |
| SMP | `Brought up 1 node, 2 CPUs` ✅ |
| 以太网 | `ipq5018-gmac-dwmac 39d00000.ethernet: Ring mode enabled` + `configuring for fixed/sgmii link mode` + `Link is Up - 1Gbps/Full` ✅ |
| rootfs | `VFS: Mounted root (squashfs filesystem) readonly on device 31:6` ✅ |
| UBI | `ubi0: attached mtd12 (name "rootfs_data3", size 36 MiB)`、`good PEBs: 290` ✅ |
| overlay | `UBIFS: mounted UBI device 0, volume 0, name "wta301data"` → `mount_root: switching to ubifs overlay` ✅ |
| init | `Run /sbin/init as init process` → `procd: - init -` ✅ |
| 崩溃 | 无 `Kernel panic` ✅ |

> 这一次跑的是 **6.12 内核 + S7 的旧 rootfs**（因为 flash 上还是 S7）。
> 所以 `rtl8365mb`（DSA 驱动）没 probe 是**预期**的：它是 S7 用 6.18 编的 `.ko`，
> vermagic 不匹配，6.12 加载不了。真正刷完之后 DSA 编在内核里（`kmod-dsa-rtl8365mb`）。

## 4. 已知差异（不是问题，但要记）

RAM 试跑 cmdline 是 `console=ttyMSM0,115200n8 root=…`，比 S7 实跑的
`console=ttyMSM0,115200,n8 rw rootwait root=…` 少 `rw rootwait`，且 `115200n8` 没有逗号。

原因：手工 `bootm` 时 cmdline = u-boot **env 的 `bootargs`**（`console=ttyMSM0,115200n8`）
+ DTB 的 `/chosen/bootargs-append`；而正常引导走 `tpl_boot_one()`，它自己会拼
`console=ttyMSM0,115200,n8 rw rootwait` 前缀。两边 DTB 的 `bootargs-append` 已核对**逐字相同**：

```
 root=/dev/mtdblock6 rootfstype=squashfs rootwait coherent_pool=2M ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data
```

⇒ **不需要改 DTS**。刷写后由 `tpl_boot_one` 引导，cmdline 会与 S7 一致。

## 5. 副作用（可接受）

RAM 试跑时新内核 attach 了 mtd12 上的旧 UBI，并做了 `recovery needed` / `recovery completed`，
即**写过 mtd12**。该区正是下一步要整区擦除重写的 UBI 区，无影响。
`kernel` / `rootfs` / `tphdr` / `boot_flag` / 一级与二级 u-boot **全部未写**（试跑全程无 `nand erase`/`nand write`）。

## 6. 复现命令

```
python work/out-final/lap.py --ensure
python work/out-final/rescue.py sh --port socket://127.0.0.1:7001 --cmds "printenv ;setenv ethact eth1"
python work/out-final/rescue.py sh --port socket://127.0.0.1:7001 --cmds "printenv ;tftpboot 0x44000000 op_kernel_0x480000.bin"
python work/out-final/rescue.py sh --port socket://127.0.0.1:7001 --cmds "printenv ;crc32 0x44000000 0x480000"
# 然后 bootm 0x44000000
```

日志：`work/evidence/p4-uboot-net.log` · `p4-tftp-kernel.log` · `p4-ram-crc.log` · **`p4-ramboot.log`**
