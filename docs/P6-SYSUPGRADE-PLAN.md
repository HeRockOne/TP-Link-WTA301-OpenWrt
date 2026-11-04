# P6 sysupgrade 设计（平台内升级，必须在真机 P4/P5 通过后做）

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

## 2. 本板 mtd 编号（从编译出的 FIT 内 DTB 解析，与 S7 实跑一致）

| mtd | 分区 | 偏移 | 长度 | 说明 |
|---|---|---|---|---|
| 0 | factory_boot | 0x0000000 | 0x3c0000 | 一级 u-boot（红线：不写） |
| 1 | factory_info | 0x0400000 | 0x20000 | MAC 在这（0x1c） |
| 2 | art | 0x0480000 | 0x20000 | caldata 源 |
| 3 | config | 0x0500000 | 0x200000 | |
| 4 | normal_boot | 0x4700000 | 0x40000 | 二级 u-boot（红线：不写） |
| **5** | **kernel** | 0x4880000 | 0x400000 | 实际写 0x480000（跨出到空隙，S7 同） |
| **6** | **rootfs** | 0x4fc0000 | 0xc00000 | `root=/dev/mtdblock6` |
| 7 | rootfs_data2 | 0x6a00000 | 0x1600000 | 原厂 B 槽数据区（不用） |
| 8 | normal_boot_bak | 0x0700000 | 0x40000 | |
| 9 | kernel_bak | 0x0880000 | 0x400000 | 原厂回退内核 |
| 10 | rootfs_bak | 0x0fc0000 | 0xc00000 | 原厂回退 rootfs |
| **11** | **rootfs_data3** | 0x1bc0000 | 0x2440000 | 我们的 overlay（`ubi.mtd=rootfs_data3`） |
| 12 | boot_flag | 0x4000000 | 0x20000 | 红线：不写不擦（改它走 `rescue.py setflag`） |

> 注意编号顺序 ≠ 物理顺序：`rootfs_data2` 排在 `normal_boot_bak` 之前，这是从原厂
> RedBoot 表搬过来时保留的原始次序。**改动分区节点顺序会改 mtd 编号**
> ⇒ `root=/dev/mtdblock6` 指错设备 ⇒ 直接不启动。

## 3. tphdr 目前没有 mtd 节点（P6 必须补）

`0x4800000`（tphdr）落在 `normal_boot`(0x4740000 止) 与 `kernel`(0x4880000 起) 之间的空隙，
不属任何分区 ⇒ **从 Linux 里无法通过 mtd 分区写它**，也就无法在 sysupgrade 里更新校验头。

P6 要做的最小改动（DTS）：

```dts
            tp_header@4800000 {
                label = "tp_header";
                reg = <0x04800000 0x00020000>;
                read-only;          /* 只在升级时由钩子临时接管 */
            };
```

- **必须追加在 partitions 节点末尾**（不能插在中间，理由见 §2 的编号警告）。
- 追加后：mtd 0–12 编号**全部不变**，新增 `mtd13 = tp_header`，全部物理区不重叠
  （0x4800000+0x20000 = 0x4820000，远在 kernel 起点 0x4880000 之前）。
- 代价：板级 DTB 节点数从 174 变 175，与 S7 的 `fdtdiff` 比对会多一条**已知**差异，
  需在 `tools/fdtdiff.py` 的期望差异表里登记。

## 4. 升级钩子（`platform.sh` 加 `tplink,wta301` 分支）

伪代码，长度全部**从当前 tphdr 读**，不写死：

```sh
tplink_wta301_do_upgrade() {
	local tar="$1" klen rlen mtdk mtdr mtdt tmpd
	mtdk=$(find_mtd_index kernel); mtdr=$(find_mtd_index rootfs)
	mtdt=$(find_mtd_index tp_header)          # §3 才有
	[ -n "$mtdk" ] && [ -n "$mtdr" ] && [ -n "$mtdt" ] || return 1

	tmpd=$(mktemp -d)
	tar -xf "$tar" -C "$tmpd"                 # 里面是 kernel(ITB) + root( squashfs )

	# 1) 长度取自闪存上的 tphdr：+0x5c = kernel 长度、+0x64 = rootfs 长度
	klen=$(( 0x$(dd if=/dev/mtd$mtdt bs=1 skip=$((0x5c)) count=4 2>/dev/null | hexdump -e '4/1 "%02x"') ))
	rlen=$(( 0x$(dd if=/dev/mtd$mtdt bs=1 skip=$((0x64)) count=4 2>/dev/null | hexdump -e '4/1 "%02x"') ))

	# 2) 按 NAND 擦除态 0xFF 补齐到 klen / rlen
	mkpad() { size=$1; f=$2; cur=$(stat -c%s "$f"); \
	          [ "$cur" -le "$size" ] || return 1; \
	          head -c $((size-cur)) /dev/zero | tr '\0' '\377' >> "$f"; }
	mkpad "$klen" "$tmpd/kernel"; mkpad "$rlen" "$tmpd/root"

	# 3) 算 payload md5 并写进 tphdr 的 +0xa0（16 字节 ASCII hex）
	hash=$(cat "$tmpd/kernel" "$tmpd/root" | md5sum | cut -d' ' -f1)
	cp /dev/mtd$mtdt "$tmpd/tphdr"
	printf '%s' "$hash" | dd of="$tmpd/tphdr" bs=1 seek=$((0xa0)) conv=notrunc 2>/dev/null

	# 4) 先写两个大区，最后才写头（头一改校验就生效，写坏前面还能靠旧头认出来）
	nandwrite -p /dev/mtd$mtdk "$tmpd/kernel" || return 1
	nandwrite -p /dev/mtd$mtdr "$tmpd/root"  || return 1
	nandwrite -p /dev/mtd$mtdt "$tmpd/tphdr" || return 1
	rm -rf "$tmpd"
}
```

要点：
- **`+0xa0` 是 16 字节 ASCII**（md5 的 hex 文本），不是二进制 —— 与 S7 冻结产物一致
  （`+0xa0` 实测值 `8a45889a…`，我们已在 P3 复核脚本里用同样写法复现）。
- **不得改 `+0x90`**（那是 secondary u-boot 自己的 md5，对应 mtd4，不随系统升级变）。
- **不得写 mtd0/mtd4/mtd12**（红线）。
- overlay（mtd11 `rootfs_data3`）默认保留；`sysupgrade -n` 时是否清理由 `-n` 语义决定，
  钩子里不做额外擦除（少一个变量）。

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
