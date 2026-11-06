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

```bash
# 1) 取上游（稀疏克隆够用：qualcommax + mac80211 + generic）
git clone --filter=blob:none https://github.com/openwrt/openwrt.git /root/ow2512
cd /root/ow2512 && git checkout v25.12.6
git rev-parse HEAD        # 必须是 64900e756efa667774214f9c6b17c113222e01f7

# 2) 放权威 .config（省掉一长串 make menuconfig 猜测）
cp wta301-2512/pin/ow2512-dot-config.txt .config

# 3) 铺我们的改动（幂等，可重复跑）
bash wta301-2512/deliver/apply-to-2512.sh

# 4) Argon 主题（第三方，需自己下）
mkdir -p /root/pkgsrc/luci-theme-argon-v3.1.0
curl -L https://codeload.github.com/jerrykuku/luci-theme-argon/tar.gz/refs/tags/v3.1.0 \
  | tar xz -C /root/pkgsrc/luci-theme-argon-v3.1.0 --strip-components=1

# 5) 编
make -j$(nproc) world      # 首次约 1.5–2 h

# 6) 出四件套
bash wta301-2512/deliver/make-release.sh
```

### 交付前自检（必跑）

```bash
# 把要交付的那两个单 bin 按 u-boot 后端的判据验一遍
python wta301-2512/tools/verify_single_bin.py --dir <交付目录>
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
| **u-boot 槽镜像**（262,144 B） | ✅ **闭环** | 仓库版 `mk_uboot_slot.py` 重跑 → `d0ada9f7…` / `0xCB2D3108`，与已刷入板子的 `work/images/kit-p21c/uboot_slot_0x40000.bin` **逐字节一致** |
| **u-boot `u-boot.bin`** | ⚠️ 理论上可以，**未实跑** | 脚本已可移植，本轮未执行；且基座 commit 未固定（§4） |
| **OpenWrt 固件四件套** | ✅ 可重建 | P10：同源重跑三项逐字节相同；输入已全在仓库（§2） |
| **UBI overlay** | 结构可重建、字节不能 | 时间戳写进 superblock（§4） |

> 一句话：**出槽镜像那一步已闭环；编译那一步靠固定引用 + overlay，换机器第一次跑不能指望 md5 一致。**
> 想真正卡死 u-boot 复现，唯一办法是把 codelinaro 基座 commit 钉下来写进 §1。

---

## 4. 已知不可复现 / 弱环节

| 项 | 状况 | 影响 |
|---|---|---|
| u-boot 基座 commit | **未固定**（只记了分支） | 同代基座可过；跨大版本要人工对 |
| UBI overlay 镜像字节 | `mkfs.ubifs` 写入当前时间戳，`SOURCE_DATE_EPOCH` 在 host 工具上不生效 | 只影响字节，不影响功能（首启会重格式化） |
| 绝对路径 | `apply-to-2512.sh` 硬编码 `/root/ow2512`、`/root/pkgsrc/...` | 换机器要改，脚本有 `die()` 保护会早失败，不会静默走错 |
| 工具链 | 不进仓库（`staging_dir` 有数百 MB，随基座走） | 属正常实践 |

---

## 5. 不要做的事

1. **不要 `make distclean`**（u-boot 侧会删手写 dts）。
2. **不要把 sparse 包当网页刷**：网页=紧凑 `0x1060000`；TTL=稀疏 `0x1380000`。
3. **不要用 `patch -p1` 铺 u-boot**：`patches/uboot/p18` 是扁平命名且有旧版，
   直接 `cp -a patches/uboot/files/. <u-boot 树>/`。
4. **不要写 B 槽**（`0x700000`）以外的回退资产；B 槽不能擦。
5. **链接基址不得改成 `0x4a920000`** —— 那是 TTL 死亡区。