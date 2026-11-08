# 复现性实证 —— 别人 clone 下来能不能编出这个固件

问题来源：开源发布前必须回答「能不能从仓库编译复现出现在的固件和 u-boot」。
如果做不到，开源就没有意义（只能看不能用的代码不是开源，是展示）。

本文只记录**实测过**的结论，每条附判据。未验证的明确标 ⬜。

---

## 0. 结论摘要

| 问题 | 答案 | 状态 |
|---|---|---|
| 仓库是否完整描述了编译树的输入？ | **是**。全新树 apply 后与 `/root/ow2512` 零实质差异 | ✅ 已实证 |
| 依赖是否都能公开获取？ | **是**（上游 commit / feeds / 工具链 / Argon 全部可公开获取） | ✅ 已实证 |
| 全新树能不能编出可用的固件？ | **能**。两棵**完全独立**的树（一棵 clone --no-local 自母树、一棵从 git.openwrt.org 全新 clone）各编一遍，都是 190 包逐包一致、`OK=23 WARN=0 FAIL=0` | ✅ 已实测（§4） |
| 能不能编出 **md5 完全相同**的固件？ | **不能**，且这是 squashfs 的固有行为，非本项目缺陷 | ❌ 已实证不可能（§3） |
| u-boot 能不能复现？ | 槽镜像闭环可复现；`u-boot.bin` 编译依赖基座 commit（只到同代） | ⚠️ 部分 |

**一句话**：功能等价可复现（应该），逐字节可复现做不到（确定）。

---

## 1. 输入完整性实测（✅ 已实证）

### 1.1 方法

不看文档、不靠记忆，直接造一棵全新树然后比对：

```bash
git clone --no-local /root/ow2512 /root/repro-verify2   # 本地克隆，秒级
cd /root/repro-verify2
git checkout 64900e756efa667774214f9c6b17c113222e01f7     # v25.12.6
# 确认干净：git status --porcelain | wc -l  ->  0
cp <repo>/pin/ow2512-dot-config.txt .config
OWTREE=/root/repro-verify2 bash <repo>/deliver/apply-to-2512.sh
# APPLY_RC=0，耗时 52 秒
```

然后与真正编译过的 `/root/ow2512` 逐文件比对（排除 `build_dir`
`staging_dir` `dl` `tmp` `.git` `bin` `logs` `files` `package` `feeds`）。

### 1.2 结果

```
Only in /root/ow2512: feeds/*            ← feed 检出物，重新 update 即得
Only in /root/ow2512: private-key.pem    ← 构建期自动生成
Only in /root/ow2512: public-key.pem     ← 同上
Only in /root/ow2512/tools/zstd: wget-log ← 垃圾文件
Files .../lib/upgrade/platform.sh differ  ← 仅末尾换行
Files .../ipq50xx/config-default differ   ← 仅注释
```

**逐项判据**：

| 差异 | 实质影响 |
|---|---|
| `feeds/` | 无。由 `feeds.conf.default` 的 `^commit` 决定（§2） |
| `*-key.pem` | 无。构建期自动生成，不进固件 |
| `wget-log` | 无。垃圾 |
| `platform.sh` 末尾换行 | 无。`sh` 语义不变 |
| `config-default` 注释 | 无。实测 `grep '^CONFIG' \| diff` → **完全相同** |

⇒ **0 处实质差异**。仓库对编译输入的描述是完整的、可执行的。

### 1.3 顺带修掉的一个真问题

首次在全新树跑 `apply-to-2512.sh` 时，§5b 的 fstools 判据读到空值：

```bash
N=$(grep -c 'volume_find(dataname)' $OWTREE/build_dir/target-*/fstools-*/mount_root.c)
if [ "$N" != "2" ] || ...; then
    ( cd $OWTREE && make package/system/fstools/clean )   # ← 全新树上会触发整套工具链
fi
```

全新树没有 `build_dir`，`N` 为空 ⇒ 条件成立 ⇒ 执行 `make ... clean`。
实测未致死（52 秒内完成，clean 无 build 系统时空转），但这是隐患：
在工具链已就绪但 fstools 未编译的中间态，会做一次无谓的完整清理。

---

## 2. feeds 是钉死的（✅ 已实证）

一开始担心 `feeds.conf` 不在仓库里会导致 feed 漂移。查证后结论相反：

```bash
$ git -C /root/ow2512 ls-files --error-unmatch feeds.conf.default
✅ 是（随上游 commit 一起，天然钉死）
$ git -C /root/ow2512 status --porcelain feeds.conf.default
（空 = 未改动，与 64900e75 完全一致）
```

内容本身就是钉死的：

```
src-git packages  https://git.openwrt.org/feed/packages.git^093d551675b1119a06ef224d419905e8d6b2af1a
src-git luci       https://git.openwrt.org/project/luci.git^75a306df84a020c57a631ef5b4c02ace56d93387
src-git routing   https://git.openwrt.org/feed/routing.git^48c808034414a2112cf9d5261a20a320e8d0d170
src-git telephony https://git.openwrt.org/feed/telephony.git^2618106d5846a4a542fdf5809f0d3ed228ce439b
src-git video     https://github.com/openwrt/video.git^094bf58da6682f895255a35a84349a79dab4bf95
```

本轮补了两条实测（详见 `pin/README-FEEDS.md`）：

1. **官方服务器接受任意 sha 的 fetch** —— feed 脚本的做法是
   `git fetch --depth 1 origin <sha>`，不是 clone 再 checkout。
   实测 `git fetch --depth 1 origin 75a306df…` 直接拿到 commit 对象。
   ⇒ 不需要作者的本地缓存做中转。

2. **`video` feed 可以跳过** —— 它在 `github.com`，中国网络常不可达。
   但本固件 **0 个包**来自 video（核对发布版 190 包清单，
   `gstreamer/ffmpeg/qt5/ffplay/libv4l/v4l-utils/x264/x265` 一个都没有）。
   注释掉那行后 `apply-to-2512.sh` 不会拦（只检查 luci/packages）。

且实测 5 个 feed 检出后 `git status --porcelain` 全为 **0 改动**：

```
luci 75a306df · packages 093d5516 · routing 48c8080 · telephony 2618106 · video 094bf58
```

⇒ feed 版本由上游 commit 决定，不需要额外钉。

---

## 3. 逐字节复现：做不到（❌ 已实证）

### 3.1 判据

```bash
$ ls -l --time-style=+%F_%T build_dir/target-aarch64_cortex-a53_musl/root-qualcommax/bin/busybox
-rwxr-xr-x 421909 2026-10-18_05:45:38 .../bin/busybox     ← 构建时刻
$ date +%F_%T
2026-11-06_20:51:17                                        ← 现在
```

`TARGET_DIR` 里文件的 mtime **就是构建时刻**，而 squashfs 把文件 mtime 存进镜像。

### 3.2 为什么没归一化

```make
# include/image.mk:282
define Image/mkfs/squashfs-common
	$(STAGING_DIR_HOST)/bin/mksquashfs4 $(call mkfs_target_dir,$(1)) $@ \
		-nopad -noappend -root-owned \
		-comp $(SQUASHFSCOMP) $(SQUASHFSOPT)
endef
```

**没有 `-all-time`**。OpenWrt 对 `SOURCE_DATE_EPOCH` 的支持是局部的：
`include/image-commands.mk` 里 erofs 用 `--mtime`、ext4/f2fs 用 `-T`，
但 squashfs4 这条路径没有接。

⇒ 每次构建 mtime 不同 ⇒ squashfs 字节不同 ⇒ 镜像 md5 不同。

### 3.3 这条不该被当成缺陷

上游 OpenWrt 官方也不保证逐字节可复现。对使用者而言有意义的是
**「拿到源码能编出行为相同的固件」**，不是「编出同一个 md5」。
把这条如实写明，比假装能做到更负责。

### 3.4 要真做逐字节复现，代价是什么

给 `Image/mkfs/squashfs-common` 加 `-all-time $(SOURCE_DATE_EPOCH)`，
并在构建前 `export SOURCE_DATE_EPOCH=<固定值>`。

代价：**未来所有固件的 md5 都会变**，已发布的 p29 追不回来。
收益：从下一个版本起，任何人只要用同一个 `SOURCE_DATE_EPOCH` 就能得到同 md5。

⚠️ 但即使加了这一行，**内核编译**仍可能因 `__DATE__`/`__TIME__`、
`KBUILD_BUILD_TIMESTAMP` 等产生差异，需要逐项验证才能称「可复现」。
**未验证的不要写进 README。**

---

## 4. 全新树全量构建（✅ 已实测）

```bash
cd /root/repro-verify2                  # 从 /root/ow2512 拷出来的全新树
cp ../wta301-2512/pin/ow2512-dot-config.txt .config
# 若无网络下载 feed，复用母树已 clone 的（内容与 feeds.conf 的 commit 一致）
cp -a /root/ow2512/feeds .
./scripts/feeds update -i && ./scripts/feeds install -a
ARGON_SRC=<luci-theme-argon-v3.1.0> bash deliver/apply-to-2512.sh
make -j6 world && make -j6 target/install
bash deliver/make-release.sh --version REPRO --stage P30
bash deliver/make-deliverable.sh P30
```

实测环境：`/root/repro-verify2`，6 核 / 7 GB 内存，
`make world` 耗时 **13 分 11 秒**（增量，`build_dir` 部分复用），
`target/install` 另有若干分钟。

| # | 判据 | 结果 |
|---|---|---|
| 1 | `WORLD_RC=0` | ✅ 0 |
| 2 | `INSTALL_RC=0` | ✅ 0 |
| 3 | `make-release.sh` 能出四区 + sysupgrade | ✅ 5 区 + sysupgrade 全在 |
| 4 | kernel 分区 DTS = `0x4880000 0x740000` | ✅ 一致 |
| 5 | FIT 内嵌 DTB reg 与 DTS 一致 | ✅ `ITB(image 1).dtb: 0x4880000 0x740000` |
| 6 | rootfs 里 `net-tune` md5 = `8eaaa52f11cc9a1e1e4c6e01edc421f9` | ✅ 一致 |
| 7 | rootfs 里 `15_sensors.js`、`rpcd/ucode/wta301` 在位 | ✅ 都在 |
| 8 | 产物尺寸与已发布一致 | ✅ 内核 4,718,592 / rootfs 12,320,768 / tphdr 131,072 / 网页包 17,170,432 **全部精确相同** |
| 9 | **固件里真有 LuCI**（与 `pin/p30-manifest.txt` 逐包比对） | ✅ **190 包 / 19 个 `luci*`**，与基线逐包 diff 无输出 |

```
final:  OK=23  WARN=0  FAIL=0           ← 零 WARN
manifest 190 包 —— 与 pin/p30-manifest.txt diff 完全无输出
sysupgrade 13,404,437 B（发布版 13,394,197 B，差 10,240 B = 0.076%，
             squashfs 时间戳，属预期；这不是「编错了」的判据）
```

### 4.0 两棵**完全独立**的树，结论一致

上面那轮跑在 `/root/repro-verify2`（`git clone --no-local` 自母树）。
为了排除「只对作者的树成立」，又跑了一棵真·上游树：

```bash
git clone --depth 1 --branch v25.12.6     https://git.openwrt.org/openwrt/openwrt.git /root/ow-upstream
#   HEAD = 64900e756efa667774214f9c6b17c113222e01f7   ← 与发布 pin 精确一致
#   10,316 个文件，103 MB
```

（`github.com` 国内连不上；`git.openwrt.org` 可达，是官方源。）

| | `/root/repro-verify2` | `/root/ow-upstream` |
|---|---|---|
| 树来源 | `clone --no-local` 自母树 | **从 git.openwrt.org 全新 clone** |
| apply-to-2512.sh | RC=0 | **RC=0**（7 个关键文件与已验证树 md5 全部相同） |
| `make world` | RC=0，13 分 | **RC=0，1 小时 17 分**（含从零编 host tools + gcc + 内核） |
| `make target/install` | RC=0 | **RC=0** |
| manifest | 190 包 / 19 `luci*` | **190 包 / 19 `luci*`** |
| 与基线 diff | 无输出 | **无输出** |
| 内核区 / rootfs / tphdr | 4,718,592 / 12,320,768 / 131,072 | **完全相同** |
| 网页包 / TTL 包 | 17,170,432 / 20,447,232 | **完全相同** |
| sysupgrade | 13,404,437 | **13,404,437**（同尺寸，md5 不同） |
| 九条判据 | `OK=23 WARN=0 FAIL=0` | **`OK=23 WARN=0 FAIL=0`** |

两个 sysupgrade 尺寸精确相同到字节，但 md5 不同：

```
13,404,437  a28b1da77d7b60d73ff4c90bba633b66   (ow-upstream)
13,404,437  5de1ed184c7dec1092d3d1960f4ad0f6   (repro-verify2)
cmp -l 首个差异在偏移 1668（squashfs 时间戳区）
```

⇒ 印证 §3 的结论：**结构可复现到逐字节，内容不可**（时间戳等长、压缩率一致）。

### 4.0.1 上游树跑的这一个小时顺带证明了什么

`make world` 第一次运行时要从零编译：host tools（gcc/make/python/patchelf…）
→ toolchain → 内核 → 全部包。**零报错**跑完，说明：

- 我们的补丁对**纯净上游树**可应用（不是只能打在作者的树上）
- `feeds.conf.default` 的 5 个 commit pin 能直接取到（`feeds install -a` RC=0）
- 上游 feed 自身的 Kconfig 循环依赖（`luci-app-weechat` ↔ `weechat-full`
  ↔ `weechat-minimal`）只是个 error 提示，`make defconfig` 仍 RC=0，
  不影响本固件（这 3 个包都不在 .config 里）

---

两轮构建的差别只有一处输入：**Argon 主题源码给不给**。

| | 不给（`ARGON_SRC` 缺失） | 给了 |
|---|---|---|
| manifest | 188 包 / 17 个 `luci*` | **190 包 / 19 个 `luci*`** |
| 判据 | `OK=23 WARN=1 FAIL=0` | **`OK=23 WARN=0 FAIL=0`** |
| 固件 | 用 Bootstrap 主题 | 用 Argon 主题 |

这也说明判据 ⑨ 的分级是对的：缺 Argon 只是 WARN（功能降级、不是错误），
缺必需包才是 FAIL。

> 第 9 条是实测后加的。前八条里的尺寸判据能抓到「缺 LuCI」但只是间接的；
> ⑨ 直接读 manifest 并与基线逐包比对。背景见 §4.1。
>
> ⑧ 的「精确相同」不是必然结果 —— 网页包/TTL 包由已编译产物拼接，
> 不含 squashfs 压缩，所以只要输入一致就逐字节相同。
> 而 sysupgrade 内含 squashfs，有 mtime 参与，必然不同。

### 这批判据有脚本，不用手工

```bash
bash deliver/verify-scratch-build.sh \
     --log  /tmp/scratch-build.log   \   # 里面有 WORLD_RC= / INSTALL_RC=
     --tree /root/repro-verify2      \   # apply 过的那棵源码树
     --rel  /root/rel-repro               # make-release.sh 的 --out
#   → OK=20 WARN=0 FAIL=0
```

★ **别人 clone 下来自己编一遍，要判断「编的对不对」也直接跑这个**，
不用回头读上面那张表。它把九条判据都做成了检查项，并把
`FAIL` 区分成「结构错了（会变砖）」与「只是缺工具」。

脚本**有意不判 md5 相同** —— 那不可能，原因见 §3。
它判的是：分区偏移、内嵌 DTB、关键文件内容、区域尺寸、LuCI 是否真在。

### 4.1 首次从零构建时踩到的两个坑（已修）

第一次从零跑，`make world` 返回 **0**、零报错，产物也看着像回事。
但判据 ⑧⑨ 把它拦下来了：

```
manifest      163 个包（应 190）
luci*            0 个（应 19）
sysupgrade   12,677,397 B（应 13,394,197，小 5.4%）
.config 里 `CONFIG_PACKAGE_luci*` = 0 个（母树 19 个）
feeds/ 目录根本没建立
```

刷进去 = 没有 Web 界面。两条根因都是「不报错但结果错」：

| # | 漏了什么 | 为何静默 | 现状 |
|---|---|---|---|
| ① | `./scripts/feeds install -a` | LuCI 全部来自 luci feed；包不存在时 Kconfig 就当没这个选项 | README 列为显式步骤；`apply-to-2512.sh` 直接 `exit 1` |
| ② | `cp pin/ow2512-dot-config.txt .config` | 没有 `.config` 时 `apply-to-2512.sh` 会新建一个只有几行的，`make defconfig` 从最小集重算 | 同上，且检查 `CONFIG_PACKAGE_luci*` ≥ 10 |

两个拦截都实测验证过会 `exit 1`。这是「从零构建验证」真正吓人的地方：
**成功返回码不等于正确**。

### 4.2 第四处：Argon 主题（最隐蔽的一处）

九条判据全过之后，把 manifest 与发布版逐包比，才看出少 2 个：

```
- luci-theme-argon               3.1.0-r20261022
- luci-i18n-argon-config-zh-cn   3.1.0-r20261022
```

`pin/ow2512-dot-config.txt` 里明明写着 `CONFIG_PACKAGE_luci-theme-argon=y`，
但 Argon 是第三方主题（`jerrykuku/luci-theme-argon`，GPL），**不在任何 feed 里**，
必须单独下源码。`apply-to-2512.sh` §5d 缺源码时只 echo 一句警告就继续了 ——
而 OpenWrt 的 Kconfig 对不存在的包**直接忽略、不报错**。

为什么这处比前三处更难发现：

| | 前三处（feeds / .config / 全盘镜像） | 这一处（Argon） |
|---|---|---|
| 尺寸影响 | 掉 5%（13.39 → 12.68 MB） | 只差 **0.2%**（13,394,197 → 13,117,717 B） |
| 判据 ⑧ 能否抓到 | 能 | **不能** |
| 只有判据 ⑨ 能抓 | — | 是 |

"只差 0.2%" 恰好落在任何"合理波动"范围里，而 ⑧ 的容差是 ±3%。
所以 ⑨ 必须做成 **与基线 manifest 逐包比对**，不能用阈值 ——
我第一版写 `luci* ≥ 25`，而实际发布版只有 **19** 个，阈值太松等于没判。

修法两条（都在本仓）：
1. §5d 缺 `ARGON_SRC` → `exit 1` + 下载指令；
   确实要无 Argon 的构建 → `ALLOW_NO_ARGON=1`，此时把两个开关
   显式改成 `# ... is not set`，不留悬空 `=y`。
2. 判据 ⑨ 三级：必需包缺 → FAIL（带包名）；argon 缺 → WARN 且
   明确写「固件会用 Bootstrap」；比基线多 → WARN。
   基线 = `pin/p30-manifest.txt`（发布版 190 包实测清单）。

改动 `/root/repro-verify2/**` 前后 `diff -rq` 应只差时间戳相关字节。

---

## 5. u-boot 侧（⚠️ 部分）

| 环节 | 状态 |
|---|---|
| 槽镜像 `u-boot.bin` → 262,144 B | ✅ 闭环，逐字节对过板子实物 |
| 构建包装 commit | ✅ `9ce31573`，**产物自证**：`strings u-boot.bin` → `U-Boot 2016.01-9ce3157-dirty` |
| 内层 codelinaro commit | ⚠️ 只到 QSDK 发布标签 `AU_LINUX_QSDK_NHSS.QSDK.12.5_TARGET_ALL.12.5.2783.2994` |
| 从基座源码编出 `u-boot.bin` | ⬜ 未实跑（`build_j1.sh` 已参数化，本轮没跑） |
| 工具链 `arm_cortex-a7_gcc-5.2.0_musl-1.1.16_eabi` | ✅ 公开（QSDK 标准，`SWRT-dev/qca-toolchains` 有） |

### 5.1 槽镜像这一环已做成「行为判据」（不是查文档）

`wta301-uboot-kit/verify-kit.sh` 本轮从 30 条加到 **34 条**，
新增的 4 条会**实际执行** `build/mk_uboot_slot.py`，而不是只 grep README：

```
u-boot.bin   556,032 B  md5 3a4cb00e37065936e5ff89cb5710a519
槽镜像       262,144 B  md5 d0ada9f76e4f1aba9b96a559a5220cee  crc32 0xCB2D3108
```

第三次复验，与 README §3 验收判据逐字相同。
**为什么改**：原来两条判据只证明「文档里写了期望值」，文档和代码可以各说各话。

⇒ u-boot 是**「同代基座 + overlay」可复现**，不是「同一棵树」。
详见 `patches/uboot/README.md` §1、§3.1，`patches/uboot/CHANGES.md` §3。

---

## 6. 这篇文档的用途

对外发布时，`README.md` 里关于复现的说法必须与本文一致：

- ✅ 可以说「全部输入在仓库内，`apply-to-2512.sh` 在全新树上 52 秒铺完，零实质差异」
- ✅ 可以说「上游 commit / feeds / Argon / 工具链全部可公开获取」
- ❌ **不能**说「可逐字节复现」
- ✅ §4 已跑完：从零构建 + 出包，九条判据 `OK=23 WARN=0 FAIL=0`


---

## 7. 「能编」≠「能刷」：两条独立的门槛

被问到「别人拿到仓库能不能构建出固件**并刷入成功**」时，
这是一个**与**关系，两边都要成立。上面 §1–§4 只覆盖左边。

| 门槛 | 内容 | 证据状态 |
|---|---|---|
| **A. 能构建** | 输入完整 + 依赖公开 + 出包脚本能跑 | ✅ 已实证（§4 端到端 `OK=23 FAIL=0`） |
| **B. 能刷入** | 镜像布局与分区贴边 + 刷写手法 + 回退路径在 | ✅ 已实证（真机 `PASS=30 FAIL=0`） |

B 侧不依赖「谁编的」，只依赖镜像结构和刷写手法 —— 但**踩了就是变砖**，
所以单独列在这里。

### 7.1 六条硬约束（每一条都有真机事故或反汇编依据）

| # | 约束 | 违反后果 | 依据 |
|---|---|---|---|
| 1 | OpenWrt 只能住 **A 槽** | 内核写不进去 / 覆盖原厂回退 | B 槽 `kernel_bak` = 4 MiB < OpenWrt 内核 4,280,940 B |
| 2 | 写 flash 必须走**内核 MTD**：`mtd erase <label>` + `mtd -q write <file> <label>` | `dd of=/dev/mtdN` = 分区报废；`/dev/mtdblockN` 在 OpenWrt 下 I/O error | NAND = GigaDevice GD5F1GQ5REYIG，page 2048 / erase 128 KiB / ECC 8-bit |
| 3 | 必须**交叉刷**（擦的不是当前正在跑的那一槽） | 擦当前槽 → MTD 全局锁 → 22/80 全断，只能断电重启 | 实测事故 |
| 4 | 刷前确认 B 槽原厂完好 | 失去唯一回退路径 | `mtd11` md5 `bf2f92ce…` / `mtd10` md5 `2868d8e9…` |
| 5 | 二级 u-boot 必须链接到 `0x49900000` | 一级 u-boot 跳过去找不到东西，**TTL 直接死** | 反汇编实证；`0x4a920000` 只能 RAM 试跑 |
| 6 | 一级 u-boot（`factory_boot` `0x0`–`0x3c0000`）永不可写 | 彻底无法恢复（只能拆机写 NAND） | 分区表 |

### 7.2 三个包不能混刷

```
网页包（0x1060000 紧凑布局）  ← u-boot 自带 HTTP 页面上传    17,170,432 B
TTL 包（0x1380000 稀疏布局）  ← 串口 + tftp 救砖            20,447,232 B
sysupgrade（原生 tar）        ← LuCI「备份/刷写固件」       13,394,197 B
```

网页包与 TTL 包**布局不同**，互相刷会写错偏移。详见 `README.md` §刷机流程。

### 7.3 别人最可能踩的三个坑

1. **忘了先生成 `board-2.bin`** —— 仓库故意不分发（逐台校准数据）。
   `apply-to-2512.sh` 会停下来给生成步骤，但容易被当成脚本坏了。
2. **手工 `dd` 到 `/dev/mtdN`** —— 分区报废。必须用 `mtd` 工具。
3. **刷到 B 槽** —— 内核装不下。`platform.sh` 的 `tplink,wta301` 分支写死 A 槽，
   但手工操作的人不受保护。

### 7.4 所以那句话该怎么说

- ✅ 「别人按 README 走，能编出**结构正确**的固件（八条判据可自查），
   并按 kit 的流程刷入 —— 这条路径已真机验证 `PASS=30 FAIL=0`。」
- ❌ 不能说「别人编出来的和发布版 md5 一样」（squashfs 时间戳）。
- ❌ 在 §4 跑完之前，不能说「已从零验证可编译」（输入完整 ≠ 端到端跑通）。

---

## 8. 外部用户模拟：三处「别人 clone 下来必然失败」

「输入完整」和「能跑通」是两件事。为了验证后者，把仓库 clone 到一个
**没有 `work/` 上级目录**的地方（`/root/extern-sim`），然后照 README 跑完整链路。
三轮都炸在「不报输入缺失、直接抛异常」的地方。

### 8.1 三处硬依赖（都已修）

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| ① | `make world` **返回 0**、零报错，但固件少 27 个 LuCI 包、没 Web 界面 | 漏 `./scripts/feeds install -a`；且没铺 `pin/ow2512-dot-config.txt` | README 列为显式步骤；`apply-to-2512.sh` 遇到两种情形都 `exit 1` |
| ② | `make-release.sh` 第 4 步 `FileNotFoundError` | `--uboot $WORK/backup/mtd4_normal_boot.bin \|\| die`，`$WORK` 是仓库**上级**目录 | `UBOOT_SLOT` → `$WORK/backup` → `patches/uboot/` 三级回落；全缺则降级并打印三种处理方式 |
| ③ | `*** 找不到 .../flash_full_128M.bin ***` → `FAIL: mk_op_pack 失败` | 为了从 128 MB 全盘镜像里取 A 槽 TP 头，而真正有用的只有 **122 字节** | 新增 `patches/tphdr/tphdr-head.hex`（前 0x120 字节）+ `_load_tphdr()` 回落 |

### 8.2 关于 ③ 的量化（为什么 128 MB 可以不要）

```
TP 头占 NAND 0x4800000 起 0x20000 = 131,072 B
其中非零字节：122 个
最后一个非零字节偏移：+0xdf
+0xe0 之后：全是 0x00（不是 0xFF —— NAND 上实际如此）
```

`mk_op_pack.py` 只覆盖 4 个字段（`+0x5c` 内核长度 / `+0x64` rootfs 长度 /
`+0x90` u-boot 槽 md5 / `+0xa0` kernel‖rootfs md5），其余逐字节保持。

**受控对照**（同一对 kernel/rootfs、同一 u-boot 槽，只换 TP 头来源）：

| 输入 | `op_tphdr_0x20000.bin` md5 |
|---|---|
| A 用 128 MB 全盘镜像 | `fd107705871c368299046f9d35b326ec` |
| B 只用仓库内 122 字节模板 | `fd107705871c368299046f9d35b326ec` |

✅ 逐字节相同；kernel/rootfs 两份产物也完全相同。
⇒ 不是「退而求其次」，是**等价**。

### 8.3 修完之后的端到端结果

在 `/root/extern-sim`（裸仓库，无 `work/`、无全盘镜像、无 `u-boot.bin`）：

```
make-release.sh       RC=0
  网页包      17,170,432 B   （与发布版尺寸精确相同）
  TTL 包      20,447,232 B   （同上）
  sysupgrade  依 squashfs 压缩率浮动
make-deliverable.sh   RC=0
  唯一降级：u-boot 槽镜像不放进交付（脚本明确打印，标注不影响刷写）
```

### 8.4 这类 bug 的共性，以及为什么判据要这么写

三处都是同一个模式：**「可选输入缺失」被写成了「致命错误」，
而且错误信息指向文件路径、不指向设计意图。**
外部用户看到 `FileNotFoundError: .../flash_full_128M.bin` 只会以为仓库缺文件，
不会是「我需要用自己板子的 ART 生成」或「这个字段是可选的」。

所以 `deliver/verify-repro.sh` 第 14 节把这些变成可回归的静态判据：
`--uboot` 必须是可选形式、不许出现 `--uboot $WORK/... || die`、
`mk_op_pack.py` 必须有 `_load_tphdr`、模板的 magic 与关键字段必须对得上、
`apply-to-2512.sh` 必须拦 feeds 与 `.config`。









