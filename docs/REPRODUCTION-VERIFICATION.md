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
| 全新树能不能编出可用的固件？ | 见 §4 | ⬜ 实测中 |
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
src-git luci      https://git.openwrt.org/project/luci.git^75a306df84a020c57a631ef5b4c02ace56d93387
src-git routing   https://git.openwrt.org/feed/routing.git^48c808034414a2112cf9d5261a20a320e8d0d170
src-git telephony https://git.openwrt.org/feed/telephony.git^2618106d5846a4a542fdf5809f0d3ed228ce439b
src-git video     https://github.com/openwrt/video.git^094bf58da6682f895255a35a84349a79dab4bf95
```

且实测 5 个 feed 检出后 `git status --porcelain` 全为 **0 改动**：

```
luci 75a306df 0 · packages 093d551 0 · routing 48c8080 0 · telephony 2618106 0 · video 094bf58 0
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

## 4. 全新树全量构建（⬜ 实测中）

```bash
cd /root/repro-verify2
ln -s /root/ow2512/dl dl          # 上游源码 tarball，复用省 2 GB 下载
./scripts/feeds update -i && ./scripts/feeds install -a
make defconfig                    # DEFCONFIG_RC=0
make -j6 world
make -j6 target/install
```

判据（构建完成后逐条填）：

| # | 判据 | 结果 |
|---|---|---|
| 1 | `WORLD_RC=0` | ⬜ |
| 2 | `INSTALL_RC=0` | ⬜ |
| 3 | `make-release.sh` 能出四区 + sysupgrade | ⬜ |
| 4 | kernel 分区 DTS = `0x4880000 0x740000` | ⬜ |
| 5 | FIT 内嵌 DTB 与已发布一致 | ⬜ |
| 6 | rootfs 里 `net-tune` md5 = `8eaaa52f11cc9a1e1e4c6e01edc421f9` | ⬜ |
| 7 | rootfs 里 `15_sensors.js`、`rpcd/ucode/wta301` 在位 | ⬜ |
| 8 | 产物尺寸与已发布一致（±UBI 时间戳带来的膨胀） | ⬜ |

### 这八条有脚本，不用手工判

```bash
bash deliver/verify-scratch-build.sh \
     --log  /tmp/scratch-build.log   \   # 里面有 WORLD_RC= / INSTALL_RC=
     --tree /root/repro-verify2      \   # apply 过的那棵源码树
     --rel  /root/rel-repro               # make-release.sh 的 --out
#   → OK=20 WARN=0 FAIL=0
```

★ **别人 clone 下来自己编一遍，要判断「编的对不对」也直接跑这个**，
不用回头读上面那张表。它把八条判据都做成了检查项，并把
`FAIL` 区分成「结构错了（会变砖）」与「只是缺工具」。

脚本**有意不判 md5 相同** —— 那不可能，原因见 §3。
它判的是：分区偏移、内嵌 DTB、关键文件内容、区域尺寸。

改动 `/root/repro-verify2/**` 前后 `diff -rq` 应只差时间戳相关字节。

---

## 5. u-boot 侧（⚠️ 部分）

| 环节 | 状态 |
|---|---|
| 槽镜像 `u-boot.bin` → 262,144 B | ✅ 闭环，逐字节对过板子实物 |
| 构建包装 commit | ✅ `9ce31573`，**产物自证**：`strings u-boot.bin` → `U-Boot 2016.01-9ce3157-dirty` |
| 内层 codelinaro commit | ⚠️ 只到 QSDK 发布标签 `AU_LINUX_QSDK_NHSS.QSDK.12.5_TARGET_ALL.12.5.2783.2994` |
| 从基座源码编出 `u-boot.bin` | ⬜ 未实跑 |
| 工具链 `arm_cortex-a7_gcc-5.2.0_musl-1.1.16_eabi` | ✅ 公开（QSDK 标准，`SWRT-dev/qca-toolchains` 有） |

⇒ u-boot 是**「同代基座 + overlay」可复现**，不是「同一棵树」。
详见 `patches/uboot/README.md` §1、§3.1，`patches/uboot/CHANGES.md` §3。

---

## 6. 这篇文档的用途

对外发布时，`README.md` 里关于复现的说法必须与本文一致：

- ✅ 可以说「全部输入在仓库内，`apply-to-2512.sh` 在全新树上 52 秒铺完，零实质差异」
- ✅ 可以说「上游 commit / feeds / Argon / 工具链全部可公开获取」
- ❌ **不能**说「可逐字节复现」
- ⬜ 在 §4 跑完之前，**不能**说「已从零验证可编译」


---

## 7. 「能编」≠「能刷」：两条独立的门槛

被问到「别人拿到仓库能不能构建出固件**并刷入成功**」时，
这是一个**与**关系，两边都要成立。上面 §1–§4 只覆盖左边。

| 门槛 | 内容 | 证据状态 |
|---|---|---|
| **A. 能构建** | 输入完整 + 依赖公开 + 出包脚本能跑 | §1/§2 ✅ 已实证；§4 端到端 ⬜ |
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

