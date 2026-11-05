# WTA301 使用手册 — 升级 / 刷写 / 回原厂 / 空间

日期：2026-11-05（P17 状态）
所有数字均为**本轮板子实测**，非估算。

---

## 1. LuCI 里的「刷写固件」能用吗？—— **不能**

### 1.1 实测证据

```
root@OpenWrt:~# cat /proc/mtd | grep -c firmware
0
root@OpenWrt:~# grep -n PART_NAME /lib/upgrade/platform.sh
3:PART_NAME=firmware
root@OpenWrt:~# mtd write /etc/openwrt_release firmware
Could not open mtd device: firmware
```

`default_do_upgrade()` 的实现是 `get_image "$1" | mtd write - "${PART_NAME:-image}"`
（`/lib/upgrade/common.sh:315`）。本板 `/proc/mtd` 14 项里**没有** `firmware`，
所以 `mtd` 在 `open()` 阶段就失败 —— **一个字节都没写**。

⇒ **在 LuCI「系统 → 备份/刷写固件」上传 `.bin`，结果 = 报错退出，机器不动。
不是砖，但也刷不进去。**

### 1.2 为什么本板没有 `firmware` 分区

本板固件是**三段分离**，不是单一分区：

| 偏移 | 长度 | 内容 | 是否在 `/proc/mtd` |
|---|---|---|---|
| `0x4800000` | `0x20000` | **tphdr**（分区表 + md5 校验链） | ❌ **不可寻址** |
| `0x4880000` | `0x480000` | kernel（FIT） | ✅ mtd5（但声明只有 `0x400000`） |
| `0x4fc0000` | `0xbc0000` | rootfs（squashfs） | ✅ mtd6 |

tphdr 里存着四个字段，换 kernel/rootfs 后必须重算：

| 偏移 | 内容 |
|---|---|
| `+0x5c` | `KERNEL_LEN` |
| `+0x60` | `ROOTFS_LEN` |
| `+0xa0` | `md5(kernel ‖ rootfs)` |
| `+0x90` | tphdr 自身 md5 |

⇒ 「只写 mtd5/mtd6、不动 tphdr」的 in-Linux 升级路径**在原理上不存在**：
tphdr 的 md5 必然失效 → u-boot 校验失败 → 落 B 槽。

### 1.3 想做 sysupgrade 需要什么（P18 可选任务，非必须）

**可行方案（不改任何 MTD 序号）**：把 DTS 的 kernel 分区从
`0x4880000/0x400000` 改成 `0x4800000/0x500000`，把 tphdr 包进分区头部。
这样 `mtd5` 序号不变、`root=/dev/mtdblock6` 不受影响，且 tphdr 变成可写。

然后写 `platform_do_upgrade()`：解出 kernel、拼 `tphdr(0x20000)+pad(0x60000)+kernel(0x480000)`、
`mtd write - kernel`、`mtd write - rootfs`。

代价：内核 crc32 会变（要重刷一次）、要实测序号、要掉电中断测试。约 1 天。
**当前收益不足**（家用一年升级几次，TTL 刷写 5 分钟可接受），见 `UPGRADE-POLICY.md`。

---

## 2. 固件类型：op 和原厂是**同一种**格式

这是本轮最重要的发现。**两者都是以 `0x4800000` 为起点、`tphdr + kernel + rootfs`
连续排列的单块镜像**，刷法完全相同。

### 2.1 原厂镜像（`work/backup/mtd8_firmware.bin` 前 `0x13c0000`）

```
rel 0x000000  tphdr    00 00 01 00 55 aa 9d d1 ...
rel 0x080000  kernel   d0 0d fe ed   ← FIT magic
rel 0x07c000  rootfs   68 73 71 73   ← "hsqs" squashfs magic
rel 0x13c000  全 FF                 ← 结束（= 0x5bc0000）
大小 20709376 B  crc32 6ce2f0e9  md5 ed3a8f9ea86107cb7f6b526487b1137f
```

原厂 tphdr 里 `KERNEL_LEN=0x400000`、`ROOTFS_LEN=0xc00000`。

### 2.2 我们的 op 镜像（`op_single_0x4800000.bin`，P17 已生成）

```
rel 0x000000  tphdr    00 00 01 00 55 aa 9d d1 ...
rel 0x080000  kernel   d0 0d fe ed
rel 0x07c000  rootfs   68 73 71 73
rel 0x138000  全 FF                 ← 结束（= 0x5b80000）
大小 20447232 B  crc32 5af01327  md5 2102f7ca25d5a4370a27584fa89bbf7f
```

我们的 tphdr 里 `KERNEL_LEN=0x480000`（内核比原厂大 512 KiB）、
`ROOTFS_LEN=0xbc0000`（比原厂小 256 KiB，让出 mtd7）。

**差别只在长度**：op 刷 `0x1380000`，原厂刷 `0x13c0000`。

---

## 3. 怎么进 ubootkit（不死 u-boot）刷写

### 3.1 两级 u-boot

| 槽 | 偏移 | 名字 | 作用 |
|---|---|---|---|
| 一级 | `0x0000000` | `factory_boot` | 原厂 u-boot。**校验 A 槽 tphdr 后跳转**；TTL 命脉，永不写 |
| **A 槽** | `0x4700000` | `normal_boot` = **ubootkit** | **我们用来刷写的 u-boot**，认 TP 头 |
| B 槽 | `0x700000` | `normal_boot_bak` | 原厂备份。**不能擦**（一级先校验它才启动） |
| 标志 | `0x4000000` | `boot_flag` | 第 8 字节 `01`=B 槽 / `02`=A 槽 |

### 3.2 进入步骤

1. TTL 串口接好（115200 8N1）→ `python work/net/lap.py --ensure` 得到 `socket://127.0.0.1:7001`
2. **断电 → 上电**
3. 出现 `Hit any key to stop autoboot: 3` 时**立刻按任意键**
   （⚠️ 串口任何字节都会打断，包括脚本的探测字节 —— lesson `5wavh1b`）
4. 判据：看到 `U-Boot 2016.01-9ce3157-dirty` + `Device Size: 128 MiB` = **已进 ubootkit**
   （若看到 `Device Size:256 MiB` + `Set RTL8367 SGMII 2.5Gbps` = 在一级，需要走 §3.3）
5. 提示符 `IPQ5018#`

一键脚本：`python work/scratch/into_ubootkit.py`

### 3.3 已经错过 3 秒窗口怎么办

不用重来 —— 在一级 `IPQ5018#` 里执行 `setflag --value 2` 后 `reset`，
一级会校验 A 槽并把控制权交给它。前提是 A 槽 tphdr 自洽（P17 是自洽的）。

### 3.4 ★ 刷完必须手动 boot，不能放手

u-boot 的 autoboot 是 3 秒倒计时，**任何串口字节都会打断**。
刷完若只是 `reset`，脚本的后续输出可能刚好撞上倒计时 ⇒ 卡在 u-boot。

⇒ 刷完最后一条命令一律是 `printenv ; bootipq`（`bootcmd=bootipq`）。
`coldflash.py` 已加 `--boot` 参数自动做这件事。

### 3.5 刷写命令（op 升级，P17）

```sh
setenv ethact eth1
setenv ipaddr 192.168.1.1
setenv serverip 192.168.1.100
tftpboot 0x44000000 op_single_0x4800000.bin
crc32    0x44000000 0x1380000            # 必须 = 5af01327
nand erase 0x4800000 0x1380000
nand write 0x44000000 0x4800000 0x1380000
nand read  0x43000000 0x4800000 0x1380000
crc32      0x43000000 0x1380000          # 必须也 = 5af01327
bootipq
```

文件 `work/images/v25.12.6-P17/flash_cmds_single.txt`（每行带 `printenv ;` 前缀）。
脚本：`python work/scratch/flash_single.py`

**这一条路不碰**：`factory_boot` / `normal_boot`(A 槽) / `normal_boot_bak`(B 槽) / `boot_flag`。
⇒ 刷坏了也能进 ubootkit 重刷，不会变砖。

### 3.6 彻底重刷（含 overlay 重置，四件套）

若要从原厂/S7 切过来，或 overlay 有脏数据，用四件套：

```sh
python work/scratch/coldflash.py --cmds work/images/v25.12.6-P17/flash_cmds.txt \
  --fp work/images/v25.12.6-P17/FINGERPRINT.json --log <log> --reboot --boot
```

多写一个 `ubi_rootfs_data3_wta301data.img`（overlay 卷，1.9 MB）。

---

## 4. 连上网能装软件包吗？—— **不能（没有 WAN）**

### 4.1 现状实测

```
ip -4 addr show br-lan  →  inet 192.168.1.1/24
ip route                →  192.168.1.0/24 dev br-lan
                        →  ping 223.5.5.5: Network unreachable
uci get network.wan.proto  →  Entry not found
```

### 4.2 配置本身是对的

`/etc/apk/repositories.d/distfeeds.list` **7 行全在**（P16 修好了）：

```
releases/25.12.6/targets/qualcommax/ipq50xx/packages/packages.adb
releases/25.12.6/packages/aarch64_cortex-a53/{base,luci,packages,routing,telephony,video}/packages.adb
```

⇒ **一旦有 WAN，`apk update` 立刻能用。** 缺的只是路由。

### 4.3 为什么没 WAN（有意设计）

本板（TP-Link XDR3010 换壳）是 **4×1GbE WAN/LAN 盲插** —— 没有物理独立 WAN 口。
`deliver/ipq50xx-base-files/etc/board.d/90_wta301:31` 把 DSA 的 5 个口全桥进 `br-lan`：

```sh
# Interfaces: all five switch ports into one bridge, no dedicated WAN.
```

好处：随便插哪个口都是 192.168.1.1，家用不会「插错口上不了网」。
代价：**板子自己是终端设备，不做 NAT 网关**。

### 4.4 想要能装包有两条路

| 方案 | 做法 | 代价 |
|---|---|---|
| A. 加 WAN 口（推荐） | 留一个口做 `network.wan`（DHCP），其余 4 口桥 | 一轮 P18，改 `board.d` + 实测 4 口 |
| B. 临时装包 | 手动配 route + 上游路由器的 LAN 口接到本板 | 无需改固件，但每次重启要重配 |

现成可用（方案 B）：
```sh
# 把板子当一个「有默认网关的客户端」，不启用 NAT
uci set network.wan=interface
uci set network.wan.proto=dhcp
uci set network.wan.device=<某个 lan 口>
uci add_list network.wan.device=...  # 或从 br-lan 摘一个口
uci commit network && /etc/init.d/network reload
```

---

## 5. 空间占用

### 5.1 Flash 128 MB（`0x0000000` .. `0x8000000`）— 实测偏移表

| 区 | 起始 | 长度 | 结束 | 内容 | 状态 |
|---|---|---|---|---|---|
| mtd0 | `0x0000000` | `0x03c0000` | `0x03c0000` | factory_boot（一级 u-boot） | 3.75 MB，**永不写** |
| mtd1 | `0x0400000` | `0x0020000` | `0x0420000` | factory_info（MAC 等） | 128 KB，只读 |
| mtd2 | `0x0480000` | `0x0020000` | `0x04a0000` | art（射频校准） | 128 KB，只读 |
| mtd3 | `0x0500000` | `0x0200000` | `0x0700000` | config（原厂配置） | 2 MB，未用 |
| mtd9 | `0x0700000` | `0x0040000` | `0x0740000` | normal_boot_bak（B 槽 u-boot） | 256 KB，**不能擦** |
| mtd10 | `0x0880000` | `0x0400000` | `0x0c8000` | kernel_bak（B 槽内核） | 4 MB，不动 |
| mtd11 | `0x0fc0000` | `0x0c00000` | `0x1bc0000` | rootfs_bak（B 槽 rootfs） | 12 MB，不动 |
| mtd12 | `0x1bc0000` | `0x2440000` | `0x4000000` | **rootfs_data3（我们的 overlay）** | **36.25 MB，用 72 KB** |
| mtd13 | `0x4000000` | `0x0020000` | `0x4020000` | boot_flag | 128 KB |
| mtd4 | `0x4700000` | `0x0040000` | `0x4740000` | normal_boot（**A 槽 ubootkit**） | 256 KB |
| — | `0x4800000` | `0x0020000` | `0x4820000` | **tphdr** | 128 KB，**不在 /proc/mtd** |
| mtd5 | `0x4880000` | 声明 `0x400000`<br>实写 `0x480000` | `0x4d00000` | kernel | 已用 |
| mtd6 | `0x4fc0000` | 声明 `0xc00000`<br>实写 `0xbc0000` | `0x5b80000` | rootfs（squashfs 8.8 MB） | 已用 |
| mtd7 | `0x5880000` | `0x0340000` | `0x5bc0000` | rootfs_data（原厂 overlay） | **与我们 rootfs 重叠，未挂载** |
| mtd8 | `0x6a00000` | `0x1600000` | `0x8000000` | rootfs_data2 | **22 MB 空着，未挂载** |

**合计 128 MB。其中真正被我们使用的只有 16.55 MB（kernel 4.5 + rootfs 11.75 + overlay 0.07），
空着 22 MB（mtd8）+ 36.25 MB 里只用 72 KB（mtd12）。**

⚠️ `mtd7` 与 `mtd6` 起始重叠（`0x5880000` 落在 `0x4fc0000..0x5b80000` 内）。
这是原厂布局：原厂 rootfs 只有 8 MB 左右，尾部 `0x340000` 划给 overlay。
我们把 rootfs 写满到 `0xbc0000`，所以 mtd7 那块被覆盖了 —— **我们不用 mtd7，无害**。

### 5.2 RAM 256 MB — 实测

```
Mem:   total 178672 kB   used 94352   free 41896   buff/cache 42424   available 68360
Swap:  total  49148 kB   used     0
```

| 项 | 值 | 说明 |
|---|---|---|
| 物理 DRAM | 262144 kB = **256 MB** | |
| **reserved（开机被拿走）** | **84432 kB = 82.5 MB (32.2%)** | `84432K reserved` 内核横幅。wcss 53 MB（Wi-Fi 固件 DMA）+ TZ + SMEM + 安全区。**DTS 固定件，动不得** |
| Linux 可见 | 178672 kB = **174 MB** | 256 − 82.5 |
| 当前 used | 94352 kB = 92 MB | 含内核 + 驱动 + 用户态 |
| buff/cache | 42424 kB = 41 MB | 页缓存，可回收 |
| **available** | **68360 kB = 67 MB** | 真正可用 |
| zram swap | 49148 kB = 48 MB | 压缩内存盘（`98-wta301-zram` 设置） |
| `/tmp`（tmpfs） | 87.2 MB | 半内存，按需 |

**内存是怎么从 5.3 MB 抠到 67 MB 的**（三件套，见 `P14`/`P15`）：

| 措施 | 收益 |
|---|---|
| `ath11k` DP ring 缩到 256 MiB 档（`0950-*` 补丁） | **+33 MB** |
| `vm.min_free_kbytes = 4096`（`sysctl.d/99-wta301-mem.conf`） | +25 MB |
| zram 48 MB（`uci-defaults/98-wta301-zram`） | 让内存压力有缓冲 |

对照：出厂 P11 空载 `MemAvailable = 5468 kB`，S7 是 `60848~61332 kB`，**P17 是 69712 kB**。

---

## 6. 一键刷入 op / 回原厂

### 6.1 一键刷 op（**已就绪**）

```
work/images/v25.12.6-P17/
  op_single_0x4800000.bin   20,447,232 B   crc32 5af01327   md5 2102f7ca…
  flash_cmds_single.txt     6 行命令
```

在 ubootkit 提示符下：
```sh
python work/scratch/flash_single.py        # 或走 coldflash.py --cmds flash_cmds_single.txt
```

重新生成：`python work/op-build/mk_single_img.py --dir <含三件套的目录>`

### 6.2 一键回原厂（**资产已有，未实测**）

```
work/backup/mtd8_firmware.bin  前 0x13c0000
  20,709,376 B   crc32 6ce2f0e9   md5 ed3a8f9ea86107cb7f6b526487b1137f
```

验证过：`rel 0`=tphdr、`rel 0x80000`=`d00dfeed`(FIT)、`rel 0x7c0000`=`hsqs`(squashfs)。

在 ubootkit 提示符下：
```sh
setenv ethact eth1
setenv ipaddr 192.168.1.1
setenv serverip 192.168.1.100
tftpboot 0x44000000 mtd8_firmware.bin
crc32    0x44000000 0x13c0000            # 必须 = 6ce2f0e9
nand erase 0x4800000 0x13c0000
nand write 0x44000000 0x4800000 0x13c0000
nand read  0x43000000 0x4800000 0x13c0000
crc32      0x43000000 0x13c0000          # 必须也 = 6ce2f0e9
bootipq
```

⚠️ **状态：命令与资产已验证，但「回原厂」这条路本轮没有真机跑过。**
要动之前必须：
1. 先确认 `work/backup/flash_full_128M.bin`（128 MB 全盘）md5 完好
2. 记下现在的 `boot_flag`（`0x4000000` 第 8 字节）
3. 回原厂后若起不来，用 §6.3 刷回 op

### 6.3 回退到 S7（已验证，作为兜底）

```
work/backup/FROZEN-S7-20261105/
  op_kernel_0x480000.bin   crc32 53bd0490
  op_rootfs_0xbc0000.bin   crc32 c2e227c6
  op_tphdr_0x20000.bin     crc32 3ccbcfc4
  ubi_rootfs_data3_wta301data.img   crc32 e850127a
```

刷法 = §3.6 四件套。**这是已验证过的路径，出任何问题都走这条。**

---

## 7. 一句话总结

| 问题 | 答案 |
|---|---|
| LuCI sysupgrade | ❌ 不能用，但**安全失败**（不写盘）。要做需一轮 P18 |
| 固件类型 | op 和原厂**同格式**：`0x4800000` 起的连续块，一次 `nand erase+write` |
| 进 ubootkit | 上电 3 秒内按键 → `U-Boot 2016.01-9ce3157-dirty` + `Device Size: 128 MiB` |
| 能刷 op + 原厂 | ✅ 都能，同一种操作，差别只在擦写长度（`0x1380000` vs `0x13c0000`） |
| 联网装包 | ❌ 无 WAN。feed 配置**已正确**，只缺路由 |
| Flash 128 MB | 用了 16.55 MB，空着 22 MB（mtd8）+ 36 MB 里的绝大部分（mtd12） |
| RAM 256 MB | reserved 82.5 MB（DTS 固定）→ Linux 174 MB → available **67 MB** |
| 一键刷 op | ✅ `op_single_0x4800000.bin` + `flash_cmds_single.txt` 已就绪 |
| 回原厂 | ⚠️ 资产与命令已验证，**未真机实测** |
