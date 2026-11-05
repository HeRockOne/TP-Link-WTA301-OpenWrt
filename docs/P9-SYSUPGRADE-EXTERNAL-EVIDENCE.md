# sysupgrade 在本板的可行性 —— 外部实证 + 板级差异表

日期：2026-11-05
触发：P9 期间核查「剩余待办 3：尚无 sysupgrade 在线升级路径验证」

标注约定：`[外部实证]` 有原文引用 · `[上游代码]` 直引上游源码 · `[本板实证]` 本板实测 · `[推断]` 推理链

---

## 0. 先看本板现实：标准 sysupgrade **结构性不兼容**

### 0.1 `[本板实证]` 本板的 flash 布局

```
mtd4  normal_boot   0x4700000 / 0x40000    二级 u-boot（不动）
mtd5  kernel        0x4880000 / 0x400000   实写 0x480000
mtd6  rootfs        0x4fc0000 / 0xc00000   实写 0xbc0000（squashfs，非 UBI）
mtd12 rootfs_data3  0x1bc0000 / 0x2440000  UBI 卷 wta301data
       tphdr        0x4800000 / 0x20000    ← 独立分区！不在 mtd 表里暴露给内核
```

`kernel` 与 `rootfs` 是**两个独立的裸 MTD 分区**，另有**独立的 0x20000 引导头分区**。

### 0.2 `[上游代码]` 默认升级路径要求一个叫 `firmware` 的分区

`package/base-files/files/lib/upgrade/platform.sh`（qualcommax，我们树里那份）：

```sh
PART_NAME=firmware
...
platform_check_image() {
	return 0;
}
...
platform_do_upgrade() {
	case "$(board_name)" in
	... 各种板子 ...
	*)
		default_do_upgrade "$1"
		;;
	esac
}
```

`package/base-files/files/lib/upgrade/common.sh:309`：

```sh
default_do_upgrade() {
	sync
	echo 3 > /proc/vm/drop_caches
	...
	get_image "$1" "$2" | mtd $MTD_ARGS write - "${PART_NAME:-image}"
	[ $? -ne 0 ] && exit 1
}
```

⇒ 整包写进名字叫 `firmware` 的分区。**我们板上没有这个分区**（`cat /proc/mtd` 14 项里没有 `firmware`）。

### 0.3 `[外部实证]` 同症状、同结论

OpenWrt 论坛「Adding support for Extreme ap-7612」帖：

> "Based on my knowledge, `sysupgrade -n /tmp/firmware.bin` fails to upgrade because
> there is no partition called 'firmware'. So you should let the `sysupgrade` know where
> the partition is. I'm not an expert on this, but I would suggest adding your device to
> the `platform_do_upgrade()`."
>
> <https://forum.openwrt.org/t/adding-support-for-extreme-ap-7612/233570?page=2>

⇒ 与本板是**同一症状**，解法也是同一处（`platform_do_upgrade()`）。

---

## 1. 上游可复用的机制：kernel 可以写裸 MTD 分区

### 1.1 `[上游代码]` `nand_upgrade_tar()` 的两条路径

`package/base-files/files/lib/upgrade/nand.sh`：

```sh
CI_KERNPART="${CI_KERNPART:-kernel}"
CI_UBIPART="${CI_UBIPART:-ubi}"
CI_ROOTPART="${CI_ROOTPART:-rootfs}"
```

```sh
nand_upgrade_tar() {
	...
	local kernel_mtd
	if [ "$CI_KERNPART" != "none" ]; then
		kernel_mtd="$(find_mtd_index "$CI_KERNPART")"
		kernel_length=$( (tar xO${gz}f "$tar_file" "$board_dir/kernel" | wc -c) 2> /dev/null)
		[ "$kernel_length" = 0 ] && kernel_length=
	fi
	...
	if [ "$kernel_length" ]; then
		if [ "$kernel_mtd" ]; then
			... tar xO${gz}f "$tar_file" "$board_dir/kernel" | \
			    mtd write - "$CI_KERNPART"
		else
			... ubiupdatevol /dev/$kern_ubivol -s "$kernel_length" -
		fi
	fi
}
```

要点：**kernel 走 `mtd write - "$CI_KERNPART"` 当且仅当存在同名 MTD 分区**。

### 1.2 `[上游代码]` rootfs 只认 UBI 卷

同一函数里 rootfs 分支只有一条：

```sh
	if [ "$rootfs_length" ]; then
		local ubidev="$( nand_find_ubi "${CI_ROOT_UBIPART:-$CI_UBIPART}" )"
		local root_ubivol="$(nand_find_volume $ubidev "$CI_ROOTPART" )"
		tar xO${gz}f "$tar_file" "$board_dir/root" | \
			ubiupdatevol /dev/$root_ubivol -s "$rootfs_length" -
	fi
```

⇒ **裸 squashfs 写 MTD 分区的 rootfs，`nand_do_upgrade` 不支持。**

### 1.3 `[外部实证]` 这正是本类问题的公认难点

OpenWrt 论坛「Fixed position partition splitting and bad blocks on nand flash」：

> "The basic problem is installation of OpenWrt on a device with NAND flash where the OEM
> firmware provides no writable rootfs, and the bootloader has no UBI support. So we want to
> split the OEM firmware partition in a kernel mtd the bootloader can read and a UBI mtd for
> the rootfs..."
>
> "…the problem has been observed with R7800 earlier. So far, the initramfs+sysupgrade
> approach is the easiest fix, as it allows writing kernel and rootfs to the correct places
> separately."
>
> <https://forum.openwrt.org/t/fixed-position-partition-splitting-and-bad-blocks-on-nand-flash/94305>

⚠ 但那条路（initramfs 里 sysupgrade）**仍然要求**升级脚本知道 kernel/rootfs 落点，
对我们要么改 `platform_do_upgrade`，要么自己写升级器。

---

## 2. 板级差异表（外部方案 vs 本板）

| 项 | 外部/上游做法 | 本板实际 | 同/不同 | 影响 |
|---|---|---|---|---|
| 分区名 | 单一 `firmware` | 无 `firmware`；`kernel`/`rootfs` 两个裸 mtd + 隐藏 tphdr | **不同** | 默认路径必失败 |
| rootfs 介质 | UBI 卷或 `firmware` 内 squashfs | **裸 squashfs 在 mtd6** | **不同** | `nand_do_upgrade` 不可直接用 |
| 引导头 | 无（分区表由 bootloader 固定） | **独立 0x20000 tphdr @0x4800000**，含 LEN/md5 四字段 | **不同** | 升级必须重建 tphdr，否则 u-boot 校验失败落 B 槽 |
| kernel 区长度 | 分区实际长度 | 必须按 **0x480000 整区补齐**（S7 tphdr `+0x5c KERNEL_LEN=0x480000`） | **不同** | 只写实际长度 ⇒ 尾部旧数据 ⇒ md5 必失败 |
| rootfs 区长度 | 分区实际长度 | 必须按 **0xbc0000** 补齐 | **不同** | 同上 |
| overlay | `rootfs_data` 在 rootfs 分区内 | **独立 mtd12，UBI 卷名必须 `wta301data`**（bootargs `fstools_overlay_name`） | **不同** | 不能动 mtd7（3.6MB）与 mtd8 |
| 双槽 | 多数无 | A 槽 = mtd5/6/tphdr；B 槽 = mtd10/11（原厂，**有完整回退能力**） | **不同** | 升级失败可落 B 槽，是安全网 |
| u-boot env | 用 `fw_setenv` 控制启动槽 | 本板二级 u-boot **无 env 分区写入权**（红线 §5.2），`boot_flag`(mtd13) 决定 A/B | **不同** | 不能靠 `fw_setenv` 切槽 |

结论：**外部所有现成路径都不能直接套用**，必须为本板写专属 `platform_do_upgrade`。

---

## 3. 决策

### 3.1 不做的事

- ❌ 不改 `PART_NAME` 硬指某个分区（分区不匹配 ⇒ 写错位置 ⇒ 可能砖）
- ❌ 不用 `nand_do_upgrade` 写 rootfs（它只会写 UBI 卷）
- ❌ 不在 Linux 里重新实现 tphdr 生成（md5 四字段 + 长度字段，任何一处算错就落 B 槽；风险/收益不划算）

### 3.2 要做的事（两步，分开验证，遵守单一变量）

**第一步（安全护栏，最高优先）**：让本板的 stock `sysupgrade` **显式拒绝**，
输出明确指引，避免家里误用 `sysupgrade -n xxx.bin` 把机器写坏。

**第二步（真正的升级路径）**：新增 `/sbin/wta301-upgrade`，复用已验证的
`FINGERPRINT.json` + 四区三列 crc32 逻辑，从 Linux 侧写 mtd5/mtd6/tphdr/mtd12，
每区写后 `nanddump`/回读 crc32 与 `FINGERPRINT.json` 比对，任何一条不符即中止
（此时 A 槽可能已坏，但 B 槽完好，可 TTL 抢救）。

> 不引入 UBI 卷级别的花活：mtd5/mtd6 本来就是裸分区，直接 `mtd write` 最接近
> 已验证的 u-boot 路径（`nand erase` + `nand write`），可对照性最强。

---

## 4. 未验证 / 待确认

- [ ] `CONFIG_MTD` 的 `/dev/mtdblock5`、`/dev/mtd5` 在运行态可写（当前 rootfs 从
      `/dev/mtdblock6` 挂载，写 mtd6 需要先确认没有写保护/只读挂载冲突）
- [ ] tphdr 分区在 Linux 侧是否可寻址（`/proc/mtd` 里**没有** tphdr 条目 ⇒
      `[推断]` 需要用绝对偏移写，或者 DTS 补一个 `tphdr` 分区节点）
- [ ] 写 mtd5/mtd6 期间 A 槽不可用，掉电 = 必须靠 B 槽，需实测一次 `boot_flag` 切换

---

## 5. 参考链接

1. OpenWrt `nand.sh`（`nand_upgrade_tar` / `CI_KERNPART` 语义）
   <https://github.com/openwrt/openwrt/blob/master/package/base-files/files/lib/upgrade/nand.sh>
2. OpenWrt `common.sh`（`default_do_upgrade` / `PART_NAME`）
   <https://github.com/openwrt/openwrt/blob/master/package/base-files/files/lib/upgrade/common.sh>
3. 论坛：无 `firmware` 分区导致 sysupgrade 失败（同症状）
   <https://forum.openwrt.org/t/adding-support-for-extreme-ap-7612/233570?page=2>
4. 论坛：NAND 定长分区切分 + R7800 同类问题
   <https://forum.openwrt.org/t/fixed-position-partition-splitting-and-bad-blocks-on-nand-flash/94305>
5. OpenWrt 平台升级模式综述（NAND/UBI/eMMC/双槽）
   <https://deepwiki.com/openwrt/openwrt/5.3.2-platform-upgrade-patterns-(nandubiemmc-dualboot-oem-layouts)>
