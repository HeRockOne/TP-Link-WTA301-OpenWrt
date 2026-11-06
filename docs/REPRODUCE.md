# 复现指南 —— 从零到可刷固件

> 仓库里**不放源码树、不放工具链**，只放三样：
> ① 上游固定引用（tag + commit） ② 我们的代码（385 KB） ③ 构建与校验脚本。
>
> 两个产物分别复现：
> - **OpenWrt 固件** —— `op_single_0x4800000.bin`（20,447,232 B）
> - **u-boot kit** —— `uboot_slot_0x40000.bin`（262,144 B），见 `patches/uboot/README.md`

---

## 1. 上游固定引用（已核对）

| 组件 | 引用 | 验证方式 |
|---|---|---|
| OpenWrt | tag **`v25.12.6`** = commit **`64900e756efa667774214f9c6b17c113222e01f7`**，`https://github.com/openwrt/openwrt.git` | `git describe --tags` / `git rev-parse HEAD` |
| 内核 | 6.12.112 | `KERNEL_PATCHVER:=6.12` + `make kernelversion` |
| u-boot | `u-boot-2016` 分支 `NHSS.QSDK.12.5`，`https://git.codelinaro.org/clo/qsdk/oss/boot/u-boot-2016` | 见 `patches/uboot/README.md` §1 |
| u-boot 包装 | `chenxin527/uboot-qsdk12.5-build`，本机 HEAD `9ce31573` | 同上 |
| LuCI 主题 | Argon `v3.1.0`，`https://github.com/jerrykuku/luci-theme-argon`（tag，非 master） | 源码形式发布，不绑 ucode 版本 |
| fstools | 上游 commit `0b60224`（引入 `fstools_overlay_name`） | `docs/P11-OVERLAY-PERSISTENCE.md:245` |

**u-boot 的 codelinaro 基座没有固定 commit —— 这是唯一已知的弱环节。**
补救方式：`patches/uboot/files/` 是整份 overlay 而非 diff（同代基座即可，见 §4）。

---

## 2. 仓库自带的关键输入（不再依赖仓库外任何路径）

| 项 | 位置 | 说明 |
|---|---|---|
| 25.12.6 顶层 `.config` | `pin/ow2512-dot-config.txt`（7,472 行 / 284 KB） | **权威构建配置**，出 P21 那份固件用的就是它 |
| 两个 BDF 容器 | `patches/bdf/board2-wta301-{ipq5018-2g,qcn6122-5g}.bin` | 各 131,180 B，WiFi 必需，**上游任何 repo 都没有** |
| 内核补丁 ×7 | `patches/kernel-6.12/` | 0920–0926，含 UNIPHY PCS + DWMAC |
| 驱动/dts overlay | `files/` | RTL8367S DSA、pcs-qca-uniphy、板级 dts |
| fstools 补丁 | `patches/fstools/` | overlay 持久化（P11） |
| mac80211 补丁 | `patches/mac80211/0950-*` | ath11k ring 降到 256 MiB 档（P15） |
| 板级 base-files | `deliver/ipq50xx-base-files/` | MAC / caldata / LED / uci-defaults |
| Device 定义 | `deliver/ipq50xx-device.mk` | 追加进 `image/ipq50xx.mk` |
| u-boot 全部自研代码 | `patches/uboot/files/`（23 文件 / 385 KB） | 见 `patches/uboot/README.md` |
| 校验基线 | `deliver/images/FINGERPRINT.json` | md5/crc32 期望值 |

---

## 3. 复现 OpenWrt 固件

> **先跑静态自检**（30 秒，不编译）：
> ```bash
> bash wta301-2512/deliver/verify-repro.sh
> ```
> 它检查的东西全是「不编译也能查出来、但一旦错就白等 45 分钟」的：
> 仓库必需文件是否齐全、脚本里有没有本机绝对路径、补丁能否干净应用、
> DTS kernel 分区与 `mk_web_img.py` 的常量是否一致、BDF variant 是否与 DTS
> 对得上、文件末尾换行（heredoc 静默吞命令的根源）。
> **OK=24 WARN=0 FAIL=0 再往下走。**

```bash
# 1) 取上游（稀疏克隆够用：qualcommax + mac80211 + generic）
git clone --filter=blob:none https://github.com/openwrt/openwrt.git /root/ow2512
cd /root/ow2512 && git checkout 64900e756efa667774214f9c6b17c113222e01f7
git rev-parse HEAD        # 必须就是上面这个 commit（v25.12.6）

# 2) 放权威 .config（省掉一长串 make menuconfig 猜测）
cp wta301-2512/pin/ow2512-dot-config.txt .config

# 3) 铺我们的改动（幂等，可重复跑）
#    树不在 /root/ow2512 时：OWTREE=/path/to/openwrt bash ...
bash wta301-2512/deliver/apply-to-2512.sh

# 4) Argon 主题（第三方，需自己下；位置可用 ARGON_SRC 覆盖）
mkdir -p /root/pkgsrc/luci-theme-argon-v3.1.0
curl -L https://codeload.github.com/jerrykuku/luci-theme-argon/tar.gz/refs/tags/v3.1.0 \
  | tar xz -C /root/pkgsrc/luci-theme-argon-v3.1.0 --strip-components=1

# 5) 编
make -j$(nproc) world      # 首次约 1.5–2 h
make -j$(nproc) target/install

# 6) 出包（三步，前一步的产物是后一步的输入）
bash wta301-2512/deliver/make-release.sh --version <VER>-2512 --stage <VER>
bash wta301-2512/deliver/make-deliverable.sh <ver>     # 小写
bash wta301-2512/deliver/make-open-release.sh <VER>    # 大写，出对外发布包
```

### 路径覆盖（全部可环境变量指定）

`deliver/lib-paths.sh` 统一解析，**没有一处写死本机路径**：

| 变量 | 默认 | 用途 |
|---|---|---|
| `OWTREE` | `/root/ow2512` | OpenWrt 源码树 |
| `WORK` | `<repo>/../work` | 仓库外资产（备份镜像、旧交付包） |
| `REL` | `/root/rel` | 出包输出根 |
| `ARGON_SRC` | `$WORK/pkgsrc/luci-theme-argon-v3.1.0` | 主题源码 |
| `HOSTBIN` | `$OWTREE/staging_dir/host/bin` | `mkfs.ubifs` / `ubinize` |
| `SRC` | 脚本所在仓库根 | 仓库自身 |

### 出包工具全在仓库内

早期 `make-deliverable.sh` 调的是 `work/out-final/flash_release.py` 和
`work/op-build/mk_single_img.py` —— **这两个文件不在仓库里**，别人 clone 下来
根本跑不了。现已改为：

| 产物 | 仓库内工具 | 状态 |
|---|---|---|
| 网页整包（紧凑 `0x1060000`） | `tools/mk_web_img.py` | ✅ 已逐字节验证：产出 md5 = 已交付的 `c5ac0911…` |
| TTL 整包（稀疏 `0x1380000`） | `tools/mk_single_img.py` | ✅ 已迁入仓库（原本只在 work/ 里） |
| 四区 + tphdr + UBI | `tools/mk_op_pack.py` | ✅ 仓库副本是规范版（含 `--rlen`） |
| 指纹 | `tools/mk_fingerprint.py` | ✅ |
| 包判据 | `tools/verify_single_bin.py` | ✅ 仓库副本更新（8 字节 magic 修正） |
| u-boot 槽镜像 | `patches/uboot/build/mk_uboot_slot.py` | ✅ 端到端验证：`u-boot.bin`(556032) → 槽 `d0ada9f7…` / crc32 `0xCB2D3108` |

**整链复现实测**：用重构后的纯仓库工具重跑 `make-deliverable.sh p29`，
四个包的 md5 与已交付发布的包**逐个相同**：

```
76df463df4d8b5acba5d52852870c127  sysupgrade
c5ac0911accd2ec48033329c383d5c4c  网页包
 d0ada9f76e4f1aba9b96a559a5220cee  u-boot 槽
 e1424fea2494bcb9b527f9540a5bc91d  TTL 包
```

### 交付前自检（必跑）

```bash
# 把要交付的那两个单 bin 按 u-boot 后端的判据验一遍
python3 wta301-2512/tools/verify_single_bin.py --dir <交付目录>
```

它模拟 `tpimg_parse_image()` 的全部判据（魔数 / klen 三条 / vlen 三条 /
avail+rlen / 防 `rootfs_too_big`），以及 `tpimg_uboot_write()` 的槽尺寸与
LZMA 解压上限。为什么不能用 `verify_pack.py`：那个验的是**四件套（TTL 口径）**，
网页刷是**单文件紧凑包**，判据不同 —— P18 §9 就踩过拿错包被判
`rootfs_too_big` 的坑。

### 验收判据

| 项 | 期望 | 来源 |
|---|---|---|
| kernel md5 | `842d204e…`（P9/P10 口径，见 `docs/P10-REPRODUCIBILITY.md`） | 逐字节可复现 |
| rootfs md5 | `f0525a4f…` | 同上 |
| tphdr md5 | `376053b7…` | 同上 |
| ubi overlay | 字节会变、结构相同 | 时间戳写进 superblock，`docs/P10-REPRODUCIBILITY.md` §2 |
| `verify_pack.py` | PASS | 结构判据，不看字节 |

> **P10 已实证**：同源重跑 `apply-to-2512.sh` + `make world`，kernel / rootfs /
> tphdr **三项逐字节相同** ⇒ 出包链路没有隐藏随机输入。
>
> 注意：这只证明「**同一棵树**上可重复」，不等于「从仓库能重建同一棵树」。
> 后者靠 §2 那批输入 + §1 的固定引用。

---

## 3.1 复现能力现状（哪部分真闭环了）

| 产物 | 能否从仓库重建 | 实测证据 |
|---|---|---|
| **u-boot 槽镜像**（262,144 B） | ✅ **闭环** | 仓库版 `mk_uboot_slot.py` 重跑 → `d0ada9f7…` / crc32 `0xCB2D3108`，与已刷入板子的实物 **逐字节一致**（本轮再次复验） |
| **u-boot `u-boot.bin`**（556,032 B） | ⚠️ 理论上可以，**未实跑** | 已有实物 `u-boot.bin` md5 `3a4cb00e…` 与 README §3 记载一致；从其重生槽镜像也一致。但「从基座源码编译出这个 `u-boot.bin`」本轮未执行，且基座 commit 未固定（§4） |
| **OpenWrt 固件出包** | ✅ **闭环，已逐字节验证** | 重构为纯仓库工具后重跑 `make-deliverable.sh p29`，四个包 md5 与已发布的 **逐个相同**（§3） |
| **OpenWrt 编译** | ✅ 同一棵树内可重复 | P10：同源重跑 kernel / rootfs / tphdr 三项逐字节相同 |
| **UBI overlay** | 结构可重建、字节不能 | 时间戳写进 superblock（§4） |

> 一句话：**出包链路完全闭环（含 u-boot 槽镜像）；编译链路靠固定引用 + overlay，u-boot 基座 commit 是唯一剩下的硬缺口。**
> OpenWrt 侧已固定到 commit（`64900e75…`），u-boot 侧只固定到分支，这是本工程最大的复现残留风险。

---

## 4. 已知不可复现 / 弱环节

| 项 | 状况 | 影响 |
|---|---|---|
| u-boot 基座 commit | **未固定**（只记了分支 `NHSS.QSDK.12.5`） | 同代基座可过；跨大版本要人工对 |
| UBI overlay 镜像字节 | `mkfs.ubifs` 写入当前时间戳，`SOURCE_DATE_EPOCH` 在 host 工具上不生效 | 只影响字节，不影响功能（首启会重格式化） |
| ~~绝对路径~~ | ✅ **已修**：所有脚本走 `deliver/lib-paths.sh`，`OWTREE`/`WORK`/`REL`/`ARGON_SRC`/`HOSTBIN` 全部可环境变量覆盖 | 已无此项 |
| 工具链 | 不进仓库（`staging_dir` 有数百 MB，随基座走） | 属正常实践 |
| 整包尺寸常量 | `0x1060000`/`0x1380000`/`0x740000` 写在多处（出包脚本、`mk_web_img.py`、DTS），改一处必须改一片 | `verify-repro.sh` §6/§9 会交叉比对并报错 |

---

## 5. 不要做的事

1. **不要 `make distclean`**（u-boot 侧会删手写 dts）。
2. **不要把 sparse 包当网页刷**：网页=紧凑 `0x1060000`；TTL=稀疏 `0x1380000`。
3. **不要用 `patch -p1` 铺 u-boot**：`patches/uboot/p18` 是扁平命名且有旧版，
   直接 `cp -a patches/uboot/files/. <u-boot 树>/`。
4. **不要写 B 槽**（`0x700000`）以外的回退资产；B 槽不能擦。
5. **链接基址不得改成 `0x4a920000`** —— 那是 TTL 死亡区。
