# P28 —— 为什么以前只能在 u-boot 里刷，以及怎么让系统内刷写工作

> 用户问：「为什么不能在 op 里面刷 op 或者原厂，还得进 uboot」
>
> 答案：**不是做不到，是上游 ipq50xx 的 `platform.sh` 里没写这块板的分支。**
> 本文记录根因（三层）、修法、以及为什么当初只能进 u-boot。

---

## 1. 现象

在 LuCI「系统 → 备份/刷写固件」里上传 `squashfs-sysupgrade.bin`，必失败。
以前每次刷机都走 u-boot 网页（`192.168.1.1`，按住 reset 40 秒到红灯）。

## 2. 根因（三层，逐层实测）

### 2.1 第一层：`platform_do_upgrade()` 落到了默认分支

`target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/platform.sh`
（v25.12.6，md5 `bf8e145b265335d818efed942a7c7fc9`）原文：

```sh
PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1
...
platform_do_upgrade() {
	case "$(board_name)" in
	cmcc,mr3000d-ci|cmcc,pz-l8|elecom,wrc-x3000gs2|iodata,wn-dax3000gr) ...
	glinet,gl-b3000) ...
	linksys,mr5500|... ...
	xiaomi,ax6000) ...
	yuncore,ax830|yuncore,ax850|zyxel,scr50axe) ...
	*)
		default_do_upgrade "$1"
		;;
	esac
}
```

`grep -nE "tplink|wta301|ipq50" /lib/upgrade/platform.sh` 在板上返回**空**。
`$(board_name)` = `tplink,wta301` ⇒ 落到 `*)`：

```sh
default_do_upgrade() {
	sync
	echo 3 > /proc/sys/vm/drop_caches
	get_image "$1" "$2" | mtd $MTD_ARGS write - "${PART_NAME:-image}"
}
```

`$2` 为空 ⇒ **把整个 13 MB tar 包往一个叫 `firmware` 的分区里写**。

本板分区表（`/proc/mtd` 实测 14 个）：

```
mtd0 factory_boot   mtd1 factory_info  mtd2 art       mtd3 config
mtd4 normal_boot    mtd5 kernel         mtd6 rootfs    mtd7 rootfs_data
mtd8 rootfs_data2   mtd9 normal_boot_bak mtd10 kernel_bak
mtd11 rootfs_bak    mtd12 rootfs_data3  mtd13 boot_flag
```

**没有 `firmware`。** `mtd` 直接报 `Could not find mtd device` 退出。

### 2.2 第二层（更致命）：kernel 分区的声明比实际镜像小

板上读 `/dev/mtd5` 前 8 字节：

```
00000000  d0 0d fe ed 00 41 52 6c   ← FIT magic + totalsize (大端 u32)
```

`totalsize = 0x0041526c = 4,280,940 B`。

而之前 DTS 声明的是：

```dts
kernel@4880000 {
	label = "kernel";
	reg = <0x4880000 0x400000>;      ← 4,194,304 B
};
```

**镜像比分区声明大 86,636 B。** 也就是说：

- 原厂 u-boot 按 TP 头（`0x04800000` 的 512 字节）里记录的 KERNEL_LEN 写和读，
  **不看分区表** ⇒ 一直工作正常，板子能启动
- 但 `mtd write - kernel` 会检查 `image_size <= partition_size` ⇒ **直接拒绝**

所以即使补上 `platform.sh` 分支，内核还是写不进去。

### 2.3 第三层：overlay 在哪决定了配置能不能保留

```
/dev/root        on /rom      squashfs   ← mtd6，写它会覆盖运行中的根
/dev/ubi0_0      on /overlay  ubifs      ← mtd12 的 UBI 卷 wta301data
overlayfs:/overlay on /       overlay    ← upperdir=/overlay/upper
```

`/proc/cmdline`：

```
... root=/dev/mtdblock6 rootfstype=squashfs rootwait coherent_pool=2M
    ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data
```

**overlay 在 mtd12，不在 kernel/rootfs 区。** 所以写 mtd5/mtd6 **不碰任何配置**，
UCI 设置和已装包全部自动保留。这是本板布局的一个额外好处。

### 2.4 顺带确认：原厂也能在系统内刷回去

`/dev/mtd13`（`boot_flag`，`0x4000000`）实测：

```
00000000  55 aa 42 46 00 00 00 02     magic "U.BF" + 大端 u32 = 2
```

`2` = 从 A 槽启动 = mtd5(kernel) + mtd6(rootfs)。原厂固件就在 A 槽里。
所以把 `flash_full_128M.bin` 的对应区间 dd 回 mtd5/mtd6 即可回原厂，`boot_flag` 不用改。

### 2.5 ★ 一个必须说清的副作用：overlay 会被完整保留（不是被清空）

上游普通 mtdsplit 机型的 sysupgrade 会**顺带清掉 overlay**：写新 squashfs 时
把 `rootfs_data` 那块尾部一起覆盖了，旧数据自然没了。

本板不一样：真正的 overlay 在 **mtd12** 的 UBI 卷 `wta301data`，我们只写 mtd5/mtd6，
**碰不到它**。再看 fstools `mount_root.c` 的 `done()`（实测源码
`fstools-2026.05.23~/mount_root.c:117`）：

```c
	v = volume_find(dataname);           // dataname = fstools_overlay_name = wta301data
	if (!v) return -1;
	switch (volume_identify(v)) {
	case FS_NONE:
	case FS_DEADCODE:
		return jffs2_switch(v);      // 只有卷坏了才格式化
	case FS_EXT4: case FS_F2FS: case FS_JFFS2: case FS_UBIFS:
		fs_state_set("/overlay", FS_STATE_READY);   // 卷正常 → 直接用
		break;
	}
```

⇒ 卷正常就不格式化。**升级后 UCI 配置和全部已装包都还在。**

| | 本板 sysupgrade | 上游普通机型 sysupgrade |
|---|---|---|
| squashfs | 覆盖 | 覆盖 |
| overlay | **保留**（在 mtd12） | 被写 rootfs 时连带销毁 |
| 已装包 | **保留** | 丢失 |
| /etc/config | **保留** | 仅靠 config 备份恢复 |

`[推断]` 风险：如果新旧固件的 squashfs 里同一个路径都有同名文件，overlay upperdir 里的
旧文件会遮蔽新文件（overlayfs 语义）。本文这一版 P28 与板上运行的固件**同源同版本**，
不存在这个问题；但若以后跳大版本，建议要么用 u-boot 网页包重刷（会重做 UBI）
要么先 `rm -rf /overlay/upper/* /overlay/work/*` 再 sysupgrade。
`[未验证]` 这个手工清 overlay 的路径还没在板上跑过。

---

## 3. 修法

### 3.1 DTS：kernel 分区 0x400000 → 0x740000

`files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts`

```dts
kernel@4880000 {
	label = "kernel";
	reg = <0x4880000 0x740000>;
};
```

- `0x4880000 + 0x740000 = 0x4fc0000` = rootfs 起始，**正好接上，无重叠**
- 偏移不变、`/proc/mtd` 序号不变 ⇒ `root=/dev/mtdblock6` 照旧
- 0x740000 本来就是 `.mk` 里 `KERNEL_SIZE := 7424k` 记录的「real cap」
- 这块区域**早就在被用**（当前运行的 FIT 就跑在上面），只是之前没在分区表里声明

### 3.2 `platform.sh`：加 `tplink,wta301` 分支

整份替换（与 base-files 同样理由：可复现、抗上游上下文漂移），
只新增三个函数与两个 case 分支：

```sh
wta301_board_dir()        # 从 tar 里找 sysupgrade-<board>/
wta301_member_size()      # 取成员字节数
wta301_write_member()     # tar 成员 → mtd write - <分区名>

platform_check_image() 里的 tplink,wta301) 分支：
    - 必须是 sysupgrade tar
    - kernel 成员 > 0 且 <= /sys/class/mtd/mtdN/size
    - root 成员   > 0 且 <= /sys/class/mtd/mtdN/size
    - root 前 4 字节必须是 "hsqs"（squashfs）

platform_do_upgrade() 里的 tplink,wta301) 分支：
    wta301_write_member "$1" "$dir" root   rootfs   # 先 rootfs（9 MB）
    wta301_write_member "$1" "$dir" kernel kernel   # 后 kernel（4 MB）
```

### 3.3 两个刻意不做的事

1. **不先「作废」kernel**。
   上游 `nand_upgrade_tar()` 对某些重叠布局会先写 4 KB 零把 kernel 打成无效，
   好让 bootloader 回退。本板没有可靠的 u-boot 回退槽逻辑，清零只会让板子
   停在「无内核可启动」。所以直接覆盖写。

2. **不改 `platform_check_image` 的 74 语义**。
   返回 74 = `notify_firmware_broken`（连 `--force` 都不行），
   其他非 0 = `notify_firmware_invalid`（可 `--force`）。
   这里只用后者：判据失败时用户还能 `-F` 强刷。

---

## 4. 验证

### 4.1 离线（编译树）

```bash
sh -n target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/platform.sh
# 用真实 tar 模拟
SU=bin/targets/qualcommax/ipq50xx/openwrt-*-tplink_wta301-squashfs-sysupgrade.bin
dir=$(cat $SU | tar tf - | grep -m 1 '^sysupgrade-.*/$'); dir=${dir%/}
cat $SU | tar xOf - "$dir/kernel" | wc -c   # 4280940
cat $SU | tar xOf - "$dir/root"   | wc -c   # 9098240
cat $SU | tar xOf - "$dir/root" | head -c 4 # hsqs
cat $SU | tar xOf - "$dir/CONTROL"          # BOARD=tplink_wta301
```

实测输出全部符合。

### 4.2 fwtool 元数据（决定会不会被要求 `--force`）

`validate_firmware_image` 先跑 `fwtool_check_signature` / `fwtool_check_image`：

- `target/linux/qualcommax/image/Makefile` 的 `Device/Default` 已有
  `IMAGES := sysupgrade.bin` 与 `IMAGE/sysupgrade.bin = sysupgrade-tar | append-metadata`
- `include/image.mk:543` 的默认值是 `SUPPORTED_DEVICES := $(subst _,$(comma),$(1))`
  ⇒ 对 `Device/tplink_wta301` 得到 `tplink,wta301`
- 我们额外 `SUPPORTED_DEVICES += wta301`，最终 `["tplink,wta301","wta301"]`
- `fwtool_check_image()` 拿 `/tmp/sysinfo/board_name` = `tplink,wta301` 逐项比对 ⇒ **匹配**

### 4.3 上板（刷入 P28 后）

```sh
# 1) 分区已加宽
cat /sys/class/mtd/mtd5/size          # 7602176 = 0x740000

# 2) 分支已生效
grep -c 'tplink,wta301' /lib/upgrade/platform.sh   # 2

# 3) 干跑（只检查不刷）
sysupgrade -T /tmp/op-sysupgrade.bin && echo "check OK"

# 4) 真刷（保留配置）
sysupgrade -v /tmp/op-sysupgrade.bin
```

### 4.4 ★ 实测结果（2026-10-17，真机）

首次刷 P28 走 u-boot 网页包，重启后实测：

```
# cat /sys/class/mtd/mtd5/size
7602176                      ← 0x740000，分区表已生效

# hexdump -C -n 8 /dev/mtd5
d0 0d fe ed 00 41 52 6c      ← FIT totalsize 0x0041526c = 4,280,940 B
                               ≤ 7,602,176 ⇒ 系统内刷写不再被拒
```

#### verify-p28.sh（B1~B7）

```
B1 kernel 分区声明          OK  mtd5 size 7602176 / offset 76021760
B2 分区序号未变              OK  /proc/mtd 第 8 行 = mtd6 "rootfs"
B3 platform.sh wta301 分支  OK  tplink,wta301 ×2 / wta301_write_member 存在
B4 overlay 在 mtd12 UBI 卷  OK  ubi0_0 → wta301data，27.9M/76K
B5 sysupgrade 干跑          OK  kernel 4280940<=7602176  root 9100288<=12582912
B6 fwtool 元数据            OK  supported_devices=["tplink,wta301","wta301"]
B7 救砖路径                OK  boot_flag 55aa4246 00000002 完好

汇总: OK=23  FAIL=0  SKIP=0
```

`sysupgrade -T` 自己在板上的原话：
```
upgrade: wta301 kernel 4280940 / 7602176, rootfs 9100288 / 12582912
```

#### verify-p26.sh（调优项未被刷机丢掉）

```
A1 packet_steering=2, phy0/phy1/eth0 rps_cpus=3, br-lan=0     OK
A2 eth0 irq22 effective_affinity=1，计数 CPU0=7 CPU1=6089     OK
A3 netdev_budget=1000, rps_sock_flow_entries=4096             OK
A4 net-tune 存活，日志：rps phy0-ap0 0→3 / eth0 irq22 0-1→1 /
                      rps phy1-ap0 0→3                       OK
A5 5G 161/HE80/CN 实际 80MHz；2.4G 11/HT20 实际 20MHz        OK
A6 旧 rps-watch / init.d/rps / S99rps 全部不存在               OK

汇总: OK=24  FAIL=0  SKIP=0
```

`A4` 那三条日志就是 R26-1 修复的行为证据：冷启动时 `phy1-ap0` 先被建为 `rps_cpus=0`，
`net-tune` 的自检循环 6 秒后把它补成 3。

#### 首次跑验收时踩到的两个脚本 bug（已修）

| 症状 | 真因 | 修法 |
|---|---|---|
| `[FAIL] /proc/mtd 第 7 行 = mtd6 的名字` | `/proc/mtd` 第 1 行是表头 `dev: size erasesize name`，所以 mtd6 在第 8 行 | `sed -n '8p'` |
| `[FAIL] 找不到 UBI 卷 wta301data` | `ubinfo -N <name>` 必须同时给 `-d <dev>`，只给名字返回空 | 改读 `/sys/class/ubi/ubi0_0/name`（不依赖 mtd-utils 版本） |

两个都是脚本错，板子状态本身是对的（`sed -n '8p'` 与 `ubinfo -a` 实测确认为 `rootfs` / `wta301data`）。

### 4.5 ★ 系统内真刷一次（端到端闭环实证）

#### 第一次尝试：SSH 被捉断，但拿不到内容证据

`sysupgrade -v /tmp/su.bin` 在板子上启动后，SSH 在 12 秒内直接被断：

```
FATAL ERROR: Remote side unexpectedly closed network connection
```

这是 `sysupgrade` 调 `reboot -f` 杀掉 sshd 的特征（若 check 不过，它会报错并留在系统里，SSH 不会断）。
但重启后比对 mtd5/mtd6 的 md5：

| | 刷前 | 刷后 |
|---|---|---|
| mtd5 前 128B | `b9b5541f…` | `b9b5541f…` |
| mtd6 前 128B | `8e0917ec…` | `8e0917ec…` |
| mtd5 @0/1M/2M/…/7M | 8 个采样 md5 | **全部相同** |

**同包刷同包，内容必然相同 ⇒ 内容比对只能证明「没写坏」，不能证明「写过」。**
这是本节最容易走错的判断，必须避开。

#### 第二次：把日志落 /overlay 拿铁证

`/tmp` 是 tmpfs，重启就清，所以直接把 `sysupgrade` 的输出重定向到 overlay：

```sh
pscp wta301-op-25.12.6-p28-sysupgrade.bin root@192.168.1.1:/overlay/su.bin
setsid sh -c 'sysupgrade -v /overlay/su.bin > /overlay/su2.log 2>&1; sync' </dev/null >/dev/null 2>&1 &
```

**3 秒后就在板上读到了原始输出**（由 `platform_do_upgrade` 自己的 `echo` 打出，不是我们编的）：

```
Sat Oct 17 21:51:44 GMT 2026 upgrade: Image not in /tmp, copying...
Sat Oct 17 21:51:46 GMT 2026 upgrade: wta301 kernel 4280940 / 7602176, rootfs 9100288 / 12582912
```

这行字就是铁证：
- `wta301` = 走的是**我们新加的分支**，不是 `default_do_upgrade`
- `kernel 4280940 / 7602176` = 内核尺寸 / mtd5 分区尺寸，**放得下**（旧分区 4194304 会在这里报错）
- `rootfs 9100288 / 12582912` = 同上

#### 为什么不能用 `/tmp` 存日志

第一次刷机日志写在 `/tmp/su.log`，重启后：
```
ls: /tmp/su.log: No such file or directory
```
⇒ 验证剧本里**任何想跨重启保留的证据都必须放 `/overlay`**。

#### ★ 一个源码级的附带实证：`/overlay/.fs_state -> 2`

重启后查：

```
# ls -la /overlay/
lrwxrwxrwx    1 root root 1 Oct 17 21:46 .fs_state -> 2
```

这就是 §2.5 引的 `mount_root.c` 里那几行的落点：

```c
case FS_EXT4: case FS_F2FS: case FS_JFFS2: case FS_UBIFS:
	fs_state_set("/overlay", FS_STATE_READY);   // 2
	break;
```

`2 = FS_STATE_READY`。所以「overlay 没被格式化」不再是「看起来没丢」，
而是有**源码级判据**可读：`.fs_state` 为 `2` 就是走了 READY 分支，
只有 `jffs2_switch()`（格式化）才会把它改成别的状态。

这条可以当以后任何机型的通用判据：**一个符号链接顶一整段推理**。

#### ⚠ 板子没有 RTC，不能用时间戳判断先后

刷机后立刻查到的矛盾：

```
# date          → Sat Oct 17 21:49:07      （现在）
# /proc/uptime  → 54.70                     （54 秒前启动）
# ls -l /overlay/su2.log → Oct 17 21:51      （比「现在」还晚）
# dmesg 里内核构建时间 → SMP Sat Oct 17 21:45:38
```

**重启后系统时钟会倒退**（无 RTC / 无 NTP），所以板上任何基于 mtime 或 logread
时间戳的「先发生 vs 后发生」判断都不可靠，**必须改用 `/proc/uptime` 或事件序列本身**。
这次只是虚惊（差点把正常重启当成时钟异常），但很容易引人走错。


---

## 5. 现在两条路各自的适用范围

| 能修的地方 | u-boot 网页包 | 系统内 sysupgrade |
|---|---|---|
| mtd5 kernel | ✅ | ✅ |
| mtd6 rootfs | ✅ | ✅ |
| **mtd4 normal_boot（二级 u-boot）** | ✅ | ❌ |
| **mtd12 UBI 重新格式化** | ✅ | ❌ |
| 变砖后救回 | ✅ | ❌（板子都起不来） |
| 要不要按 40 秒按键 | 要 | 不要 |
| 配置保留 | ❌（重造 UBI） | ✅（overlay 在 mtd12） |

**结论：日常升级用 sysupgrade（LuCI 点一下）；救砖和换 u-boot 仍然走 u-boot 网页。**
两个包都要留在交付目录里。

### 5.1 ⚠ 第一次必须是 u-boot

P28 的 DTS 改动（kernel 分区 0x740000）**藏在 FIT 里的 DTB**，而 DTB 只有刷进去才生效。
所以：

```
现在这块板（P26 固件）        → 必须用 u-boot 网页包刷 P28
P28 之后所有版本              → 都可以在 LuCI 里直接刷
```

刷完 P28 后，验证一句就行：`cat /sys/class/mtd/mtd5/size` 应是 `7602176`。

---

## 6. 落地位置

| 改动 | 仓库路径 | 构建脚本 |
|---|---|---|
| DTS kernel 分区 | `files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts` | `apply-to-2512.sh` §2 |
| sysupgrade 分支 | `files-ipq50xx-upgrade/lib/upgrade/platform.sh` | `apply-to-2512.sh` §5g |
| 出 sysupgrade 包 | — | `make-release.sh` §7 |
| 出交付四件套 | `deliver/README-刷机说明.txt` | `make-deliverable.sh` |
| 刷后验收 | — | `verify-p28.sh`（B1~B7） |

完整流水线（P28 实测跑通）：

```bash
bash deliver/apply-to-2512.sh          # 铺源码（DTS 改动会触发内核重编）
make -j6 world && make -j6 target/install
bash deliver/make-release.sh           # 出 u-boot 四区 + sysupgrade 包
bash deliver/make-deliverable.sh p28   # 出网页/串口/系统内三种包 + 自检
```
`make-deliverable.sh` 末尾会自动跑 `verify_single_bin.py`，并硬校验
0x1060000 / 0x1380000 两个长度与 TPIMG 头 +0x5c/+0x64 自洽。
