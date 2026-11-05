# P11 — overlay 每次启动被擦除（致命）· 根因与修复

日期：2026-11-05
状态：**已定位并已实证**（真机 P9 两次冷启动对比 + 源码逐行 + S7 日志对照）
证据：`work/evidence/p11-persist-boot.log`、`p9-coldboot.log`、`S7-reboot2.log`

---

## 0. 症状（真机实证）

在 P9（当时认为 9/9 全过）的板子上做持久化测试：

```
echo P11-MARKER-1793861057 > /root/persist.txt     # 成功，hexdump 可见
mkdir -p /etc/persist && echo hello > /etc/persist/a.conf   # 成功，ls 可见
uci set system.@system[0].hostname=wta301-home && uci commit
→ reboot
```

重启后：

```
cat /root/persist.txt        → No such file or directory
ls /etc/persist/             → No such file or directory
uci get system.@system[0].hostname → OpenWrt          （回到出厂值）
df -h /overlay               → /dev/ubi0_0 27.9M 72.0K 0%
dmesg | grep mount_root      → overlay filesystem has not been fully initialized yet
                               switching to ubifs overlay
```

**`/overlay/upper` 里只剩本轮启动时生成的文件**（`board.json`、`config/`、
`uci-defaults/`、`dropbear/`、`uhttpd.*`，时间戳都是本次开机时刻）。

⇒ **overlay 是"易失"的：每次启动都被整卷擦掉重建。用户改的任何东西都不过重启。**

这是 P4~P9 全部验证都没覆盖到的一格：每次验收都是"刷完 → 冷启动 → 当场测"，
而**当场测永远在"刚格式化过的空 overlay"上**，所以永远看起来正常。

---

## 1. 根因（源码逐行）

`fstools-2026.05.23~16718b6e/libfstools/overlay.c`

### (a) `mount_overlay()` 用 `.fs_state` 决定是否清空

```c
switch (fs_state_get(overlay_mp)) {          // 读 /tmp/overlay/.fs_state
case FS_STATE_UNKNOWN:
	fs_state_set(overlay_mp, FS_STATE_PENDING);
	if (fs_state_get(overlay_mp) != FS_STATE_PENDING) { ... break; }
	/* fall through */
case FS_STATE_PENDING:
	ULOG_INFO("overlay filesystem has not been fully initialized yet\n");
	overlay_delete(overlay_mp, true);         // ← 删除 overlay 上的一切
	break;
case FS_STATE_READY:
	break;                                    // ← 只有这个分支才保留内容
}
```

`fs_state_get()` 的实现是读 `<dir>/.fs_state` 文件里的一个数字；
文件不存在 ⇒ 返回 `FS_STATE_UNKNOWN`。

### (b) 谁负责把状态写成 READY

`mount_root.c` 有两个入口：

| 入口 | 查卷名的方式 |
|---|---|
| `start()`（L42） | **读 `/proc/cmdline` 的 `fstools_overlay_name`**，否则默认 `"rootfs_data"` |
| `done()`（L113→118） | **字面量 `volume_find("rootfs_data")`**，不读 cmdline |

`done()` 就是负责置 READY 的那个：

```c
static int
done(int argc, char *argv[1])
{
	struct volume *v = volume_find("rootfs_data");   /* ← 写死 */

	if (!v)
		return -1;                                    /* ← 直接返回，什么都不做 */

	case FS_UBIFS:
		fs_state_set("/overlay", FS_STATE_READY);      /* ← 永远到不了 */
```

### (c) 我们的组合恰好踩中

- bootargs：`ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data`
- UBI 卷名：`wta301data`
- ⇒ `start()` 找到卷 → **挂载成功**（所以表面完全正常）
- ⇒ `done()` 找 `"rootfs_data"` → **NULL** → 提前 return → `.fs_state` 永不写 READY
- ⇒ 下次启动读到 UNKNOWN → PENDING → `overlay_delete()` → **整卷擦掉** → 死循环

即：**能挂载，但永远记不住"已经初始化过"。**

---

## 2. 为什么不能简单把卷名改回 `rootfs_data`

`libfstools/rootdisk.c:166`：

```c
static struct volume *rootdisk_volume_find(char *name)
{
	if (strcmp(name, "rootfs_data") != 0)
		return NULL;
	...
```

`rootdisk` 驱动**硬编码只认这个名字**，而它会从 `/`（squashfs）的尾部
找 mtdsplit 切出来的 `rootfs_data` 分区（本板 = `mtd7`，size 随 squashfs 变）。
改回 `rootfs_data` 会让 `volume_find("rootfs_data")` 命中 **mtd7**（一个 3.6 MB 的
mtdsplit 分区，`FS_NONE`），走 jffs2 分支，把 overlay 建到错的地方。

这就是当初选 `wta301data` 的原因（lesson `n1uvh1l`）。**卷名不能改，只能修 `done()`。**

---

## 3. S7 没有这个 bug（三方对照）

| | S7（r37669 / 6.18.55） | 我们（25.12.6） |
|---|---|---|
| bootargs | 同样有 `fstools_overlay_name=wta301data` | 同 |
| UBI 卷名 | `wta301data` | 同 |
| `work/evidence/S7-reboot2.log` 里 `overlay filesystem has not been fully initialized` | **0 条** | **每次启动 1 条** |
| 同日志里的 `mount_root: switching to ubifs overlay` | 有 | 有 |

### 指令级确认（S7 二进制反汇编）

S7 的 `/root/lp/tree/sbin/mount_root` 是 stripped、无 section header，
但可以按 PT_LOAD 切出 text 段反汇编
（`python3` 截 `[0:0xfdc]` + `aarch64-linux-gnu-objdump -D -b binary -m aarch64`）：

```asm
; 第 1 处（start）
 a10: add  x19, sp, #0x88          ; char dataparam[64]
 a14: mov  w3, #0x40
 a18: mov  x2, x19
 a1c: adrp x1, 0x0
 a20: add  x1, x1, #0xdc2          ; "fstools_overlay_name"
 a24: adrp x0, 0x0
 a28: add  x0, x0, #0xdd7          ; "/proc/cmdline"
 ...
 a34: adrp x1, 0x0
 a38: add  x0, x1, #0xdb0          ; "rootfs_data"  ← 默认值

; 第 2 处（done）
 c30: add  x20, sp, #0x88
 c34: mov  w3, #0x40
 c38: mov  x2, x20
 c3c: adrp x1, 0x0
 c40: add  x1, x1, #0xdc2          ; "fstools_overlay_name"
 c44: adrp x0, 0x0
 c48: add  x0, x0, #0xdd7          ; "/proc/cmdline"
 ...
 c54: adrp x1, 0x0
 c58: add  x0, x1, #0xdb0          ; "rootfs_data"
```

字符串偏移实测：`0xdb0="rootfs_data"` · `0xdc2="fstools_overlay_name"` ·
`0xdd7="/proc/cmdline"`。`get_var_from_file("/proc/cmdline","fstools_overlay_name",
buf,64)` 的完整指令序列在 S7 二进制里出现 **两次**，`rootfs_data` 两次都只是
"读不到时用的默认值"。

⇒ **S7 的 `done()` 认 `fstools_overlay_name`，25.12.6 上游版本是回归，我们的补丁与 S7 的实现等价。**

另一个排除项：S7 冻结的 UBI 镜像（`FROZEN-S7-20261105/ubi_..._wta301data.img`）
里 `.fs_state` 出现 **0 次**，我们的 P9 镜像也是 0 次 ⇒ S7 不是靠"镜像里预置标记"
过关的，确实是 `done()` 把它写进去的。
（S7 把 `network/system/wireless` 固化进 rootfs 的做法，现在看来不只是风格选择 ——
在 overlay 记不住东西的前提下，那是唯一能让配置存活的写法。我们的
P9「固化 wireless」出于同一个理由才有效。）

---

## 4. 修复

新增 `patches/fstools/0001-fstools-honor-fstools_overlay_name.patch`（由
`tools/mk_fstools_patch.py` 对 pristine 源码生成，`patch --dry-run` 通过），
修**两处**同类字面量，都改成用和 `start()` 完全相同的方式取卷名：

| 文件 | 位置 | 不修的后果 |
|---|---|---|
| `mount_root.c` | `done()` | overlay 每次启动被擦（本文 §0~§2） |
| `factoryreset.c` | `main()` | `factoryreset -y` / 重置按钮 直接报 `MTD partition 'rootfs_data' not found` 而**失效** |

`factoryreset.c` 还需要补一行 `#include "libfstools/common.h"`
（`get_var_from_file()` 的声明在那里，原文件只包含了 `libfstools.h`）。

```c
-	struct volume *v = volume_find("rootfs_data");
+	char dataparam[BUFLEN];
+	char *dataname = "rootfs_data";
+	struct volume *v;
+
+	if (get_var_from_file("/proc/cmdline", "fstools_overlay_name",
+			      dataparam, sizeof(dataparam)))
+		dataname = dataparam;
+
+	v = volume_find(dataname);
```

`factoryreset.c` 同理，另把错误信息从 `MTD partition 'rootfs_data' not found`
改成 `overlay volume not found`（原信息在卷名不同时会误导）。

`deliver/apply-to-2512.sh` 新增 §5b：把补丁投进
`/root/ow2512/package/system/fstools/patches/`，并以
`volume_find(dataname)` 出现次数为应用判据（`mount_root.c` 必须 2 次 =
`start`+`done`，`factoryreset.c` 必须 1 次），不符就先
`make package/system/fstools/clean`（OpenWrt 不会因为 `patches/` 变动自动重编）。

> 判据坑：最初用 `grep -q 'dataname = dataparam'` 判，结果 `start()` 里本来就有这一行，
> 补丁没打上也照样"通过"。教训见 `docs/AGENTS-CASES.md` 式的一次自纠记录。

副作用：`fstools` 变了 ⇒ rootfs / tphdr 的 crc32 会变，kernel 不变。

---

## 5. 验证方案（必须是「两次重启」）

单次冷启动**永远**看不出这个 bug（新格式化的空 overlay 当然能写）。
正确的判据是：

1. 刷完 → **启动 #1**（此时 `.fs_state` 还没有，会格式化一次，正常）
2. 在启动 #1 里写标记：`echo MARK > /root/persist.txt`、`uci set system.@system[0].hostname=wta301-home; uci commit`
3. `reboot` → **启动 #2**
4. 检查三件事：
   - `dmesg | grep 'not been fully initialized'` **必须 0 条**
   - `cat /root/persist.txt` **必须还在**
   - `uci get system.@system[0].hostname` **必须还是 wta301-home**
   - `cat /overlay/.fs_state` 必须存在且为 READY

---

## 6. 外部证据（AGENTS §0）

这条不是我们自己逆向出来的，**上游已经报过同一个 bug，而且至今没合入修复**：

| 来源 | 内容 | 与本板关系 |
|---|---|---|
| [openwrt/fstools issue #18](https://github.com/openwrt/fstools/issues/18) | 标题即 "Overlay reformats on reboot with fstools_overlay_name bootparam"；正文："during the `mount_root done` phase, `mount_root` does not pick up the overlay name from the `fstools_overlay_name` boot parameter, so it fails to locate the correct partition. As a result, the `.fs_state` file is not created." 并附了 7 行补丁，**与我们生成的补丁等价** | **同症状、同根因、补丁一致** [外部实证] |
| [fstools commit 0b60224](https://git.cdn.openwrt.org/project/fstools/commit/?id=0b6022439cadf5928d0c657f16cf5af354eff3ff) | 引入 `fstools_overlay_name`（"The name is resolved by the regular stack of fstools drivers"） | 说明参数本来**设计给全流程用**，`done()` 漏读属实现疏漏 [上游代码] |
| [openwrt/fstools master mount_root.c](https://github.com/openwrt/fstools/blob/master/mount_root.c) | 抓取时 master 的 `done()` 仍然是 `volume_find("rootfs_data")` | **上游没修**，所以我们必须长期自带这个补丁 [上游代码] |
| [openwrt-devel 2020-12 邮件](https://lists.openwrt.org/pipermail/openwrt-devel/2020-December/032810.html) | "mount_root … has logic that will wipe your entire overlay FS if there isn't a `.fs_state` … wait until `/etc/rc.d/S95done` is run, as this runs `mount_root done` which will set the `.fs_state`" | 独立确认「S95done → 置 READY」是唯一免擦机制 [外部实证] |
| [OpenWrt 论坛帖](https://forum.openwrt.org/t/factory-reset-results-in-overlay-filesystem-has-not-been-fully-initialized-yet-error/14653) | 同一 `S95done` 未生效导致配置不持久 | 同症状（非本板） [外部实证] |

### 板级差异表（外部结论≠本板结论）

| 项 | 上游讨论的那个板 | 本板 WTA301 | 是否相同 |
|---|---|---|---|
| 触发条件 | 设了 `fstools_overlay_name=` 且卷名 ≠ `rootfs_data` | 同（`wta301data`） | **相同** |
| overlay 介质 | 未说明 | UBIFS on `ubi0:0`（mtd12 `rootfs_data3`） | 不同（不影响机理） |
| `/etc/init.d/done` | S95done 调 `mount_root done` | 同（已核 `/root/ours/tree/etc/init.d/done`：`START=95`、`mount_root done`） | **相同** |
| 是否有 mtdsplit `rootfs_data` 冲突 | 未提及 | **有**（mtd7），所以不能改回默认卷名 | 不同（决定修法） |
| 症状表现 | 每次启动 overlay 被重格式化 | 同（0 号证据 §0） | **相同** |

⇒ 结论：机理与上游完全一致，本板的特殊性只在「不能改回卷名」，因此采用上游提案的补丁而非改卷名。

## 7. 教训

**验收判据里必须有「重启后还在」这一条。** 本次 P4~P9 的九项判据全部是
"当场观测"，而"当场"恰好是这个 bug 唯一不发作的时刻。凡是涉及
可写存储、配置、证书、密钥（dropbear host key 每次重启都变 ⇒ 客户端报
HOST KEY CHANGED）的功能，判据都要写成「写 → 重启 → 还在」。
