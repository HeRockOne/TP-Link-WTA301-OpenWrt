# P6 sysupgrade 设计（平台内升级，必须在真机 P4/P5 通过后做）

> **状态：已实现（P28）。** 本文是当时的**方案推演**，不是最终做法。
> 最终落地：`docs/P28-SYSUPGRADE-IN-OS.md`，代码在 `files-ipq50xx-upgrade/lib/upgrade/platform.sh`。
>
> 本文§1对「为什么原厂 sysupgrade 会破启动链」的分析是对的；
> 但结论「tphdr 写不了 ⇒ 做不到」是错的 —— 只加宽 DTS 的 kernel 分区就绕过去了。

**为什么单列一阶段**：这块板的 kernel/rootfs **不在 UBI 里**，而是裸分区 + 一个
`tphdr`（0x4800000）里写着 `md5(kernel[0:0x480000] ‖ rootfs[0:0xbc0000])`，
secondary u-boot 的 `tpl_boot_one()` 每次都校验它。stock `sysupgrade` 只写分区、
不会重算这个头 ⇒ **升完下次必校验失败、自动落 B 槽**。所以 P6 不是"跑一下
`sysupgrade -n`"，而是必须补一个平台升级钩子。

## 1. 现状：25.12.6 的 ipq50xx 全族都不是这种布局

`target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/platform.sh`（246 行）里
`platform_do_upgrade()` 的每个分支（cmcc/elecom/iodata/glinet/linksys/xiaomi/yuncore/zyxel）
都是 `nand_do_upgrade` + `CI_UBIPART=rootfs`，即 kernel 与 rootfs 都在 UBI 卷内。
`tplink,wta301` 没有分支 ⇒ 会掉到文件末尾的默认分支，行为不适用本板。

## 2. 本板 mtd 编号（**现场实测**，S7 运行中的 `/proc/mtd` + `/sys/class/mtd/*`）

| mtd | 分区 | 偏移 | 长度 | 说明 |
|---|---|---|---|---|
| 0 | factory_boot | 0x0000000 | 0x3c0000 | 一级 u-boot（红线：不写） |
| 1 | factory_info | 0x0400000 | 0x20000 | MAC 在这（0x1c） |
| 2 | art | 0x0480000 | 0x20000 | caldata 源 |
| 3 | config | 0x0500000 | 0x200000 | |
| 4 | normal_boot | 0x4700000 | 0x40000 | 二级 u-boot（红线：不写） |
| **5** | **kernel** | 0x4880000 | 0x400000 | 实际写 0x480000（跨出到空隙，S7 同） |
| **6** | **rootfs** | 0x4fc0000 | 0xc00000 | `root=/dev/mtdblock6` |
| 7 | rootfs_data | 0x5b00000 | 0x00c0000 | **mtdsplit 自动生成**（见下） |
| 8 | rootfs_data2 | 0x6a00000 | 0x1600000 | 原厂 B 槽数据区（不用） |
| 9 | normal_boot_bak | 0x0700000 | 0x40000 | |
| 10 | kernel_bak | 0x0880000 | 0x400000 | 原厂回退内核 |
| 11 | rootfs_bak | 0x0fc0000 | 0xc00000 | 原厂回退 rootfs |
| **12** | **rootfs_data3** | 0x1bc0000 | 0x2440000 | 我们的 overlay（`ubi.mtd=rootfs_data3`） |
| 13 | boot_flag | 0x4000000 | 0x20000 | 红线：不写不擦（改它走 `rescue.py setflag`） |

### 重要：`rootfs_data`(mtd7) 不在 DTS 里，是内核自动切出来的

现场 dmesg 原文（`work/evidence` 同款）：

```
[    1.127063] 1 squashfs-split partitions found on MTD device rootfs
[    1.130582] 0x000005b00000-0x000005bc0000 : "rootfs_data"
[    2.060737] ubi0: attached mtd12 (name "rootfs_data3", size 36 MiB)
```

`mtdsplit_squashfs` 在 `rootfs` 分区里找到 squashfs 后，**把尾部剩余空间自动注册成
`rootfs_data`（插在父分区后面 ⇒ 之后所有编号 +1）**。

两条推论，都影响 P6：
1. **它的偏移/大小随 squashfs 实际长度变**：S7 的 squashfs 约 0xB40000 ⇒ 剩余 0xC0000；
   我们的 P5 squashfs 8,713,216 B（0x84F000）⇒ `rootfs_data` 会是 `0x580f000` 长 `0x3b1000`。
   **不要把这个长度写进任何脚本。**
2. **静态分区编号必须按 14 项算**（13 个 DTS 节点 + 1 个 split 出来的）：
   `rootfs=6`、`rootfs_data3=12`、`boot_flag=13`。之前文档写成 11/12 是漏算了 split，已更正。

> 编号顺序 ≠ 物理顺序：`rootfs_data2` 排在 `normal_boot_bak` 之前，这是从原厂 RedBoot 表
> 搬过来时保留的原始次序。**改动分区节点顺序会改 mtd 编号** ⇒ `root=/dev/mtdblock6`
> 指错设备 ⇒ 直接不启动。钩子里一律用 `find_mtd_part <name>` 取，不写死编号。

## 3. DTS 需要两处改动（都是为了「Linux 侧可写」）

### 3.1 tphdr 没有 mtd 节点

`0x4800000`（tphdr）落在 `normal_boot`(0x4740000 止) 与 `kernel`(0x4880000 起) 之间的空隙，
不属任何分区 ⇒ **从 Linux 无法通过 mtd 分区写它**，也就无法在 sysupgrade 里更新校验头。

```dts
/* 追加在 partitions 节点【末尾】，不能插中间（见 §2 编号警告） */
tp_header@4800000 {
    label = "tp_header";
    reg = <0x04800000 0x00020000>;
};
```

### 3.2 kernel 分区装不下要写的内核区

`kernel` 分区是 `0x4880000` 长 **0x400000**（RedBoot 表原样），但 u-boot 实际校验/使用的是
**0x480000**（`tphdr +0x5c`），比分区多出 `0x80000`，跨进 `kernel` 与 `rootfs` 之间的空隙
`0x4c80000–0x4fc0000`（这段没人声明，S7 也一样）。所以在 Linux 里 `mtd write ... kernel`
写满 4 MiB 就会被分区边界截断 ⇒ 必须把分区长度改成与实际写区一致：

```dts
kernel@4880000 {
    label = "kernel";
    reg = <0x04880000 0x00480000>;   /* 0x400000 -> 0x480000 */
};
```

- **只改长度不改基址** ⇒ mtd 编号不变；`0x4c80000–0x4fc0000` 仍然空闲，无重叠。
- u-boot 不解析 DTS，改这里对它零影响。
- `0x4880000 + 0x480000 = 0x4d00000 < 0x4fc0000` ✓ 不会碰到 rootfs。

改动后分区表 = 14 项（0–12 编号与 S7 完全一致，新增 `mtd13 = tp_header`），物理区两两不重叠。
与 S7 的 `fdtdiff` 会比出这两条**已知**差异，登记进期望差异表。

## 4. 升级钩子（`platform.sh` 加 `tplink,wta301` 分支）

**关键决定：不在路由器上算 md5。** 补齐（0xFF）与 `md5(kernel‖rootfs)` 全部由
`tools/mk_op_pack.py` 在造包时算好，`+0x5c/+0x64/+0xa0` 直接进产物。
理由：busybox 没有 `xxd`，把 32 字符 hex 变成 16 字节原始 md5 要绕一圈（`printf` 的 `\xHH`
在部分 busybox 上不支持）；而且设备上现算 13 MB 的 md5 既慢又没法离线复核。
这样钩子退化成**三条纯写操作**，与 P4 手工刷写用的是**同一份字节**，风险最低。

升级包格式（我们自己的，不是 stock `*sysupgrade.bin`）：tar，含三个已补齐的文件

| 成员 | 大小 | 写到哪里 |
|---|---|---|
| `kernel` | 0x480000 | `mtd kernel`（0x4880000） |
| `root` | 0xbc0000 | `mtd rootfs`（0x4fc0000） |
| `tp_header` | 0x20000 | `mtd tp_header`（0x4800000） |

```sh
tplink_wta301_do_upgrade() {
	local tar="$1" tmpd mtdk mtdr mtdt
	mtdk=$(find_mtd_part kernel); mtdr=$(find_mtd_part rootfs); mtdt=$(find_mtd_part tp_header)
	[ -n "$mtdk" ] && [ -n "$mtdr" ] && [ -n "$mtdt" ] || {
		echo "wta301: 缺 tp_header 分区，DTS 没打补丁？" >&2; return 1; }

	tmpd=$(mktemp -d)
	tar -xf "$tar" -C "$tmpd" kernel root tp_header || return 1

	# 尺寸必须与头里的字段吻合（防止把没补齐的包写进去）
	[ "$(stat -c%s "$tmpd/kernel")"    = $((0x480000)) ] || { echo "kernel 长度不对" >&2; return 1; }
	[ "$(stat -c%s "$tmpd/root")"      = $((0xbc0000)) ] || { echo "root 长度不对" >&2; return 1; }
	[ "$(stat -c%s "$tmpd/tp_header")" = $((0x20000))  ] || { echo "头长度不对" >&2; return 1; }

	# 顺序：先两个大区，最后才写头。中途失败 ⇒ 新头未写 ⇒ 旧头校验必然失败
	# ⇒ u-boot 自动落 B 槽，可 TTL 抢救。
	mtd write "$tmpd/kernel"    "$mtdk" || return 1
	mtd write "$tmpd/root"      "$mtdr" || return 1
	mtd write "$tmpd/tp_header" "$mtdt" || return 1

	rm -rf "$tmpd"
}
```

要点（都是硬约束）：
- **`+0xa0`/`+0x90` 是 16 字节原始 md5**，不是 ASCII；`+0xa0` 已在造包时算好 ⇒ 钩子不许重算。
- **不得改 `+0x90`**（那是 secondary u-boot 自身 md5，对应 mtd4，不随系统升级变）。
- **不得写 mtd0 / mtd4 / mtd12**（红线：一级 u-boot、二级 u-boot、boot_flag）。
- overlay（`mtd11 rootfs_data3`）默认保留；不做额外擦除（少一个变量）。
- 三个写入长度都是 128 KiB 的整数倍 ✓（0x480000 / 0xbc0000 / 0x20000）。
- 首次实施：先 `mtd verify <file> <device>`（`mtd` 工具支持 `verify` 子命令）再断电重启；
  `boot_flag` 保持 2 不动。

## 5. 验收

1. 真机 P4/P5 通过、且 `sysupgrade` 一次后仍能启动 ⇒ 看 `tpl_boot_one` 是否校验通过
   （串口无 `md5 mismatch` 而直接进内核）。
2. 升级前后 `md5sum /dev/mtdblock6`（rootfs）改变、`mtd5`（kernel）改变、
   `mtd11`（overlay）不变。
3. 升级后 `/etc/config/` 保留（overlay 未清）。
4. 故意把 `+0xa0` 写错一次，验证 B 槽回退仍然工作（**做完立刻恢复**）——这是
   "可回退"判据的最后一块。

## 6. 不做的事

- 不做双 A/B sysupgrade（B 槽是原厂资产，动它等于毁回退路径）。
- 不改 `normal_boot`/`factory_boot`/`boot_flag`。
- 不把 kernel/rootfs 搬进 UBI（那是另一个大工程，且与 S7 布局不再可比）。
