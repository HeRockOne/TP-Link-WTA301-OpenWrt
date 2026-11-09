# 开源发布清单

这份文档回答两件事：**这个仓库放什么、不放什么**，以及**每次发版要走哪几步**。
不是给人看的宣传材料，是给自己下次发版时照着做的检查表。

---

## 1. 仓库里放什么

### 1.1 放

| 类别 | 路径 | 理由 |
|---|---|---|
| DTS / 内核补丁 / 板级 overlay | `files/` `patches/kernel-6.12/` | 移植的**全部实质内容**。没有这些就是一堆没用的二进制 |
| u-boot 新增代码 | `patches/uboot/files/` | 整份 overlay 而非 diff，见 `patches/uboot/README.md` §1.1 |
| 用户态 overlay | `files-rootfs/` `files-base-files/` `files-ipq50xx-upgrade/` | 开箱即用与系统内升级的落地文件 |
| 构建/出包/验收脚本 | `deliver/` `tools/` | 可复现性 |
| Wi-Fi 板型数据 | `patches/bdf/` | **构建的必要输入**，上游任何仓库都没有。IP 问题见 `THIRD-PARTY.md` §2 |
| 分析文档 + 外部证据 | `docs/` | 每个「不这样做」的决定都有出处 |
| 事实快照 | `pin/` | 上游 `.config`、S7 基线、板级实测值 |
| 实测日志 | `evidence/` | 结论的可核验性 |

### 1.2 不放

| 类别 | 处理方式 |
|---|---|
| 固件二进制 `*.bin` | `.gitignore` 排除；走 **Releases** 页 |
| OpenWrt / u-boot 源码树 | 不进来（14 GB / 133 MB）。只记 tag + commit，见 `docs/REPRODUCE.md` |
| 工具链 | 同上 |
| 个人环境的绝对路径 | 已尽量参数化；遗留的在文件内注明 |
| u-boot p18~p21 历史快照 | **留在仓库**供追溯，但**不进发布包**（同名文件内容不同，见 §3.2） |

---

## 2. 发版步骤

### 2.1 前置：板子必须已经验证过这一版

顺序不可颠倒。**没上板验证的构建不许发**。

```bash
# WSL，root
cd /root/ow2512
bash <repo>/deliver/apply-to-2512.sh        # 全量（碰内核 → 重编约 45 min）
#   只改用户态时改用 apply-rootfs-only.sh，不触发内核重编
make -j$(nproc) world
make -j$(nproc) target/install
```

### 2.2 出包（三个脚本，按序）

```bash
VER=P30    # ← 改这里

bash <repo>/deliver/make-release.sh     --version ${VER}-2512 --stage $VER
bash <repo>/deliver/make-deliverable.sh ${VER,,}      # 小写，脚本内部用
bash <repo>/deliver/make-open-release.sh $VER         # 大写，产出对外发布包
```

| 脚本 | 产出 | 关键自检 |
|---|---|---|
| `make-release.sh` | `/root/rel/pack/`：kernel / rootfs / tphdr / UBI 卷 + `FINGERPRINT.json` + sysupgrade 包 | tphdr md5 自洽、squashfs `bytes_used` ≤ verify 长度、每区 crc32 |
| `make-deliverable.sh` | `/root/rel/deliver/`：三种成品包 + `MD5SUMS.txt` | 网页包 `0x1060000`、TTL 包 `0x1380000`、FIT `d00dfeed`、squashfs `hsqs`、LZMA 往返 |
| `make-open-release.sh` | `/root/rel/open/wta301-openwrt-<VER>/`：固件 + u-boot kit + 许可 + 自检 | TPIMG magic、槽 LZMA 头、两个 MD5SUMS 逐条复核、**无历史快照残留** |

三个脚本任一自检失败都会 `*** FAIL` 退出，不会产出半成品。

### 2.3 上板验收

```bash
# 网页刷 P29+ → 验证分区加宽生效
cat /sys/class/mtd/mtd5/size        # 必须 7602176
bash <repo>/deliver/verify-p28.sh   # B1~B7
bash <repo>/deliver/verify-p26.sh   # A1~A6（OK=24 FAIL=0）
```

### 2.4 发布

```bash
# 1. Windows 侧取包（WSL 写 /mnt/c 有权限问题，用 cp 后 chmod）
wsl -e bash -c 'cp -a /root/rel/open/wta301-openwrt-$VER /mnt/c/.../work/'

# 2. 打 tar 包（保留权限）
tar -czf wta301-openwrt-P30.tar.gz wta301-openwrt-P30/

# 3. 传到笔记本 → 本机 → Releases
```

GitHub Release 需要上传的文件（**只上传，不入库**）：

- `wta301-op-25.12.6-<VER>.bin`
- `wta301-op-25.12.6-<VER>-sysupgrade.bin`
- `wta301-op-25.12.6-<VER>-ttl.bin`
- `MD5SUMS.txt` · `FINGERPRINT.json`
- 可选：`wta301-openwrt-<VER>.tar.gz`（含 u-boot kit 全套）

---

## 3. 每次发版要复查的三处

### 3.1 文档里的版本号与状态

以下文档写过「某功能不行」，后来功能做出来了，**必须回去改**，否则等于对外说谎：

| 文档 | 曾经的错误说法 | 现状 |
|---|---|---|
| `docs/USER-MANUAL.md` §1 | 「LuCI 刷写固件不能用」 | P28 之后**能用**（sysupgrade 已实现）。该节已改指向 P28 |
| `README.md` 旧版 | 「P6 sysupgrade ⛔ 不做」 | 已重写 |
| `docs/P6-SYSUPGRADE-PLAN.md` | 早期的方案推演 | 已被 `P28-SYSUPGRADE-IN-OS.md` 取代，保留作为过程记录 |

**发版前跑一遍**：

```bash
grep -rn "⛔\|不能\|不支持\|不做" docs/USER-MANUAL.md README.md | head -20
```

逐条确认是否还有效。

### 3.2 历史快照不能进发布包

`patches/uboot/{p18,p19,p20,p21}/` 里是同一批文件的旧版本，**同名不同内容**。
`patches/uboot/README.md` §5 列了哪份是旧版。放进发布包一定会有人拿错。
`make-open-release.sh` 有专门的检查项拦这个。

### 3.3 u-boot 产物指纹

只要改了 `patches/uboot/files/` 任何一行，槽镜像 md5 就会变，此时：

1. 重跑 `mk_uboot_slot.py`
2. 核对两个余量：压缩后 ≤ 262,144（当前余 43,864）、解压后 ≤ 655,360（当前余 99,328）
3. 更新 `patches/uboot/README.md` §3 的验收判据表
4. 更新 `deliver/make-deliverable.sh` 里对 `d0ada9f7…` 的硬比对

---

## 4. 未解决的开源问题（诚实清单）

| # | 问题 | 影响 | 可能的解法 |
|---|---|---|---|
| 1 | ~~`patches/bdf/` 里是**本机 ART 校准数据**~~ | ✅ **已解决**：`tools/mk_board2_from_art.py` 可从使用者自己的 ART 生成，已逐字节验证与仓库自带文件相同 | — |
| 2 | ~~u-boot 基座 **commit 未固定**~~ | ⚠️ **已大幅收敛**（详见下表）。构建包装钉到 `9ce31573` **由二进制自证**；codelinaro 裸树仍只到同代（QSDK 发布标签已写明） | 只剩「本机树 vs 公开镜像是否逐字节相同」未对过，影响小 |
| 3 | `patches/factory/*.dtb`、`pin/s7-actual-dtb.dtb` 是厂商固件内容 | 仅分析对照用，不参与构建 | 也可删掉，代价是失去 `fdtdiff.py` 的对照基线 |
| 4 | `patches/uboot/build/build_wta301.sh` 里是早期硬编码绝对路径 | 已在文件头标注 LEGACY，正路是 `build_j1.sh` | 可删，但保留能追溯当时跑的命令 |
| 5 | 没有任何 CI | 回归靠手工 | 可加一个只做 `verify-repro.sh` + `git apply --check` 的 workflow，成本低收益明确 |

### 4.0 u-boot 归属与复现（本轮查清）

| 项 | 结论 | 证据强度 |
|---|---|---|
| 我们的 u-boot 基于 `chenxin527/uboot-qsdk12.5-build` | **是** | ✅ 硬证：6 个文件带 `Copyright (C) 2026 chenxin527` |
| 构建包装 commit = `9ce31573` | **是** | ✅ **二进制自证**：`strings u-boot.bin` → `U-Boot 2016.01-9ce3157-dirty` |
| QSDK 发布标签 | `AU_LINUX_QSDK_NHSS.QSDK.12.5_TARGET_ALL.12.5.2783.2994` | ✅ 公开镜像 README 明写 |
| 公开镜像 | `1980490718/u-boot-2016`（GPL-2.0） | ✅ 不用登录 codelinaro |
| 本机树 == 该镜像 | **未对过** | ⬜ 未验证（不影响同代 overlay） |
| failsafe Web UI 是不是厂商的 | **不是** | ✅ 新写：中文、自有 CSS 变量，`tplink` 仅作型号名/API 路径 |
| `patches/uboot/files/` 有无二进制 blob | **无** | ✅ `file(1)` 全部 text |

**法务必读**：`THIRD-PARTY.md` §3.1 已写入归属声明，并明确禁止删除那 6 个
`chenxin527` 版权头（删了就是违反 GPL-2.0 §1）。

第 2 条已从「硬缺口」降为「细节残留」。

### 4.1 已解决的（这一轮）

| 问题 | 解法 | 验证 |
|---|---|---|
| `patches/bdf/` 的 IP 问题 | `tools/mk_board2_from_art.py`（新） | 用本机 ART dump 生成的两个文件与仓库自带**逐字节相同** |
| 出包依赖仓库外文件（`work/out-final/flash_release.py`、`work/op-build/mk_single_img.py`） | 新增 `tools/mk_web_img.py`，迁入 `mk_single_img.py` | 重构后重跑全链，四个 md5 与已发布包逐个相同 |
| 脚本硬编码本机绝对路径（30 处） | `deliver/lib-paths.sh` 统一参数化 | `verify-repro.sh` §2 逐脚本扫描 |
| `tools/parse_board2.py` 用大端解析（**工具是坏的**，跑仓库自带 BDF 就崩） | 改小端 + 完整回读校验 | 两个 BDF 都能解析，数值与 `M12` 文档记载一致 |
| `make-release.sh` 不解析 `--version/--stage` | 实现 getopt | `FINGERPRINT.json` 现在写真实版本号 |

---

## 5. 发布检查表（打印出来逐项打勾）

```
[ ] 板子已刷这一版并通过 verify-p26.sh（OK=24 FAIL=0）
[ ] 板子已通过 verify-p28.sh（B1~B7）
[ ] make-release.sh     REL_RC=0
[ ] make-deliverable.sh 全部 PASS
[ ] make-open-release.sh 自检全部 [OK]
[ ] 三个包尺寸：17170432 / ~13394197 / 20447232
[ ] u-boot 槽 262144，md5 与 README §3 一致
[ ] README.md 里的版本相关陈述已更新（尤其"已知限制"表）
[ ] THIRD-PARTY.md 的 bdf 章节与实际文件一致
[ ] git tag 打好，`git describe` 与发布版本号相同
[ ] Release notes 里写明：第一次必须走 u-boot 网页，之后才能 sysupgrade
[ ] Release notes 里写明：三个包不能混刷
```
