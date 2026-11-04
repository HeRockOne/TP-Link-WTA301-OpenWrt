# 00 迁移分析

**结论先行**：迁移可行，资产复用率约 70%，但有一个必须先解决的硬问题（256 MiB RAM 上的
ath11k 双射频内存）和两个必须先搞清的事实（实际 DTB 与源 dts 不一致、25.12.6 无 low-mem 补丁）。

---

## 1. 基线选择复盘（为什么会走到这一步）

| 时点 | 事件 |
|---|---|
| 2026-03-03 | `v25.12.0` 发布，**首次**含 `qualcommax/ipq50xx` 子目标 |
| 2026-10-18 02:11 | `v25.12.6` 发布 |
| 2026-10-25 20:35:35 | 本板 rootfs 构建于 `r37669-6c9452a35b`（snapshot） |
| 2026-10-25 之后 | 8 条源开始漂移：现为 `r38103-39e77cc05d` / 内核 `6.18.60` |

⇒ 做决定时正式版已存在 **7 天**，且 `24.10.x` 系列确实没有 `ipq50xx`（只有 `ipq807x`）。
所以「要么 snapshot、要么等」的判断在 `24.10` 语境下成立，在 `25.12` 语境下不成立。

**代价（已实证）**：

```
官方 kmods 目录名 = 6.18.55-1-ad1e5aee9f1dffd79ef5c56569836d4e
板上 kernel 包版本 = 6.18.55~ad1e5aee9f1dffd79ef5c56569836d4e-r1
```

内核配置哈希 `ad1e5aee…` 与官方一致纯属运气（本板内核躯干是 IB 自带原厂 Image）。但
`base/packages/luci` 已漂移，`apk add` 任何东西都可能连带升级到 6.18.60 生态。

**全量快照不可行（实测数字）**：

| repo | 包数 | 体积 | 版本与本板一致 |
|---|---:|---:|---:|
| packages | 4,620 | 2,378 MB | 1 |
| video | 78 | 345 MB | 0 |
| base | 754 | 332 MB | 69 |
| kmods | 1,241 | 43 MB | 69 |
| telephony | 607 | 34 MB | 0 |
| luci | 7,454 | 23 MB | 5 |
| target/ipq50xx | 203 | 4 MB | 10 |
| routing | 13 | 1 MB | 0 |
| **合计** | **14,970** | **3,160 MB** | **154（1.0%）** |

⇒ 冻结 snapshot 只能救回 154 个包；想要"应用商店体验"必须换正式版。

---

## 2. 两版差异全表

| 维度 | S7（现行） | 25.12.6 目标 | 影响 |
|---|---|---|---|
| OpenWrt | `r37669-6c9452a35b` snapshot | `v25.12.6` 正式版 | 源永久冻结 |
| 内核 | **6.18.55** | **6.12.112** | 内核大版本回退，DTS 语法/驱动行为都要重核 |
| 内核 ABI 哈希 | `ad1e5aee…` | `175dffd337a18721108278990fd69f67`（kmods 目录名） | kmod 全部作废，需重新取 |
| 无线驱动 | nss-edma fork 的 `ath11k.ko`（6.18.55，含 nss/ecm 字样 26 处） | 上游 `ath11k` + 6 个 QCN6122 补丁 | **可卸掉 9.3 G 的 fork** |
| 分区写法 | `compatible = "fixed-partitions"` | 上游同硬件板用 `compatible = "qcom,smem-part"` | 我们继续用 fixed-partitions（见 §4 坑 3） |
| rootfs 承载 | raw squashfs @ mtd6 + UBIFS overlay @ rootfs_data3 | 上游同硬件板用 `append-ubi`（内核+rootfs 都在 UBI） | 我们保持现有直写布局，减少变量 |
| sysupgrade | 无 `platform.sh` case ⇒ 必失败 | 若能落 `nand_do_upgrade` + `CI_KERNPART` | 可分阶段实现 |
| 软件源 | 8 条，漂移中 | 冻结 + 可改国内镜像 | 核心收益 |

---

## 3. 资产复用矩阵

| 资产 | 位置 | 复用到 25.12.6 | 依据 |
|---|---|---|---|
| TP 头打包链 | `wta301-s7/scripts/mk_op_pack.py`、`verify_op_pack.py` | ✅ **100%** | 纯数据格式，与内核无关 |
| TP 头样本 | `pin/op_tphdr_0x20000.bin` | ✅ | 同上 |
| 固件产物结构（4 区） | `op_kernel/op_rootfs/op_tphdr/整包` | ✅ | 同上 |
| 刷写工具 | `work/out-final/flash_release.py` | ✅ 不改 | 只读 FINGERPRINT.json |
| argon 主题 | `wta301-s7/rootfs/argon/`（88 文件） | ✅ **100%** | 纯 LuCI 前端 |
| overlay 用户态 | `etc/config`、`sysctl.d`、`preinit` | ✅ 基本全用 | 与内核无关 |
| rootfs 重拼脚本 | `scripts/assemble-rootfs.sh` | ⚠ 需改 | IB tarball 换成 25.12.6 版，manifest 换 |
| DTS 分区表 | 14 项，`fixed-partitions` | ✅ 可搬 | 偏移/大小不变 |
| DTS GPIO/LED/按键段 | `ipq5018-wta301.dts` 468 行 | ✅ 可搬 | 需按 6.12 语法校对 |
| DTS Wi-Fi 段 | 见 §4 坑 1 | ⚠ **不能照抄** | 源与实际不符 |
| 内核/rootfs 产物本体 | — | ❌ 作废 | 指纹全变 |
| nss-edma 定制驱动 | `/root/nss-edma` | ⚪ **不需要** | 上游已有 QCN6122 支持 |

---

## 4. 四个必须先解决的坑

### 坑 1（实测，最重要）：实际启动的 DTB 与源 dts 不一致

**源文件** `wta301-s7/rootfs/ib-patches/ipq5018-wta301.dts`：

```dts
&wifi  { status = "okay";    qcom,ath11k-fw-memory-mode = <1>; };
&wifi1 { status = "disabled"; qcom,ath11k-fw-memory-mode = <1>;
         /* 注释：ath11k 6.18 无低内存 ring 档，双射频耗尽 256 MiB */ };
```

**实际烧进 S7 的 DTB**（从 `op_kernel_0x480000.bin` 偏移 `0x46eb48` 反编译，25,978 B，
md5 `dff6e3c9168e168a0b12c1c2c685cbfc`）：

```dts
wifi@c000000 { status = "okay";  qcom,ath11k-fw-memory-mode = <0x02>; };  ← 2.4G
wifi@b00a040 { status = "okay";  qcom,ath11k-fw-memory-mode = <0x02>; };  ← QCN6122 5G
wifi@b00b040 { status = "disabled"; };                                    ← 第二个 QCN6122，正确禁用
```

**含义**：
1. 板子上**双射频都在跑**，模式是 **2**（最省内存档），不是源文件写的 1。
2. 源 dts 不能用来重建实际 DTB ⇒「DTB 可由 .dts 源字节级重建」这句话**对那份源不成立**。
   实际 DTB 是另一次改动的产物，改动未回写源。**这是资产缺口**。
3. 迁移时必须以**实际 DTB**为基线，不是 md。

**迁移动作**：先把实际 DTB 反编译成 `.dts` 入仓（`patches/`），与源 dts 做 diff，补齐差异，
再以实际 DTB 的语义去改 25.12.6 的 DTS。

### 坑 2：ath11k 在 256 MiB + 双射频上的内存

**已知问题**（外部证据，见 `docs/03-EXTERNAL-EVIDENCE.md` E-4）：上游 ath11k 的 DP ring 按
充裕内存设计，IPQ5018 + QCN6122 双射频会把 256 MiB 吃光，开机后 OOM。

上游现状：
- `v25.12.6` 的 `package/kernel/mac80211/patches/ath11k/` **没有**任何 low-memory / ring 缩减补丁
  （补丁号 900–948，逐一核对过）。
- 官方同硬件板 `elecom_wrc-x3000gs2`（256 MiB）在 25.12.6 里 `&wifi` / `&wifi1` 都是
  `status = "disabled"` —— 官方选择「有线可用、无线不启用」。

**但本板 S7 实测反例**（`evidence/s7-mem.txt` 待落）：

```
Mem: 177652 total, 98212 used, 37832 free, 63940 available
ath11k 两个实例：c000000.wifi (ipq5018 hw1.0) + b00a040.wifi (qcn6122 hw1.0)
FW memory mode: 2       ← 两个都是
fw_version WLAN.HK.2.7.0.1-01744-QCAHKSWPL_SILICONZ-1
可用内存 63 MB，无 OOM
```

⇒ **mode 2 + 默认 DP ring 在本板能跑**。推论：25.12.6 可能不需要 low-mem 补丁，只要
`fw-memory-mode` 设为 2。**但这是 6.18.55 的观测，6.12.112 需重验。**

**降级方案（按优先级）**：
1. `fw-memory-mode = <2>` + 上游默认 ring（本板已验证可行于 6.18）
2. 若 OOM：加 hzyitc 的 ring 缩减补丁（PR #21495 / `911-ath11k-reduce-dma-buffer`）
3. 若仍 OOM：只启用 2.4G，5G 留待后续（`&wifi1 status="disabled"`）
4. 保底：纯有线可用

**注意**：论坛实测指出 `EXTRA_CFLAGS` 在 6.18 起不再被 kbuild 采纳，需改用 `KCPPFLAGS`。
25.12.6 是 6.12，`EXTRA_CFLAGS` 仍有效，但若将来升 6.18 会静默失效。

### 坑 3：分区写法与 UBI 布局分歧

上游同硬件 7 个设备全部是 `append-ubi`（内核在 UBI 卷里，`root=/dev/ubiblock0_1`），
而我们是 raw squashfs 直写 mtd6 + 独立 UBIFS overlay。

**决策：保持我们的现有布局不动**（单变量原则）。理由：
- 现有布局已在真机验证（V3 自举 10/10、冷启动 ×2 12/12、长稳）
- UBI 布局迁移会同时改变分区语义、overlay 机制、刷写顺序，多变量叠加
- 我们要的是"源冻结"和"上游驱动"，不是"和上游长得一样"

**代价**：不能直接套用上游的 `Device/` 定义，需自己写 `ipq50xx.mk` 的 Device 段，
`IMAGE/*` 用 `append-kernel` 风格而非 `append-ubi`。

### 坑 4：内核 6.18 → 6.12 的 DTS/驱动回退

- 6.12 的 `ipq5018-qcn6122.dtsi` 是否存在、节点名是否为 `wifi@b00a040`，需核对
  （25.12.6 里该 dtsi 存在，已在 §3 确认）
- 6.12 与 6.18 的 `q6v5_wcss` / `remoteproc` 绑定属性名可能不同
- 需逐个核对：`qcom,ath11k-fw-memory-mode`（patch 903，6.12 有）、
  `qcom,bdf-addr`（patch 201）、`qcom,m3-dump-addr`（patch 931）

---

## 5. 外部同硬件参照对象

25.12.6 里 7 个 IPQ5018+QCA8337+QCN6122 设备，按与我们的接近程度排序：

| 设备 | 交换机 | 5G | 256 MiB | 无线状态 | 可借鉴 |
|---|---|---|---|---|---|
| `glinet_gl-b3000` | qca8337 | qcn6122 | 是 | okay/okay | **最接近**：`noload` 无、`boot-args` 被注释 |
| `cmcc_mr3000d-ci` | qca8337 | qcn6122 | 是 | okay/okay | DTS 分区（smem-part） |
| `elecom_wrc-x3000gs2` | qca8337 | qcn6122 | 是 | **disabled** | 官方承认 256M+双射频难搞 |
| `iodata_wn-dax3000gr` | qca8337 | qcn6122 | 是 | okay/okay | — |
| `linksys_mx2000` | qca8337 | qcn6122 | 是 | okay/okay | — |
| `zyxel_scr50axe` | qca8337 | qcn6122 | 是 | okay/okay | **两个** QCN6122 |
| `cmcc_pz-l8` | qca8337 | qcn6122 | 是 | 未显式设置 | — |

**注意**：`gl-b3000` 用 `KERNEL_IN_UBI := 1`，`IMAGE_SIZE := 83968k`（linksys base）等，
这些都是 UBI 布局参数，我们不采用。

---

## 6. 本板与上游的关键硬件差异（必须逐条确认）

| 项 | 上游 gl-b3000 | 本板 WTA301 | 状态 |
|---|---|---|---|
| SoC | IPQ5018 | IPQ5018 | 同 |
| 2.4G | IPQ5018 内置 | IPQ5018 内置 | 同 |
| 5G | QCN6122 | QCN6122 | 同 |
| 交换机 | QCA8337 | **RTL8367S** | ❗ **不同** |
| 交换机上行 | SGMII → QCA8337 SerDes | **HSGMII 2.5G → gmac1** | ❗ 不同 |
| NAND | 128 MiB | 128 MiB | 同 |
| RAM | 256 MiB | 256 MiB | 同 |
| 分区 | `qcom,smem-part`（U-Boot 提供） | `fixed-partitions`（DTS 硬编码 14 项） | ❗ 不同 |
| 引导 | 标准 U-Boot + FIT | **TP-Link 自定义 TP 头 + 双槽** | ❗ 不同 |
| rootfs 承载 | UBI 卷 | raw squashfs @ mtd6 | ❗ 不同 |

⇒ 「同 SoC + 同无线芯片」只解决了 Wi-Fi 与 SoC 层；**网络/分区/引导三块完全不同**，
上游 DTS 只能借用 Wi-Fi、pinctrl、时钟、qfprom 段。

---

## 7. 结论

**可行，但不是"换个 tag 重编"。**

- 真正能白拿的：上游 ath11k（含 QCN6122 全套补丁）、6.12 的 IPQ5018 基础设施、冻结源
- 必须自己写的：TP-Link 引导链打包、fixed-partitions 分区、RTL8367S 交换、raw squashfs 布局
- 最大未知：6.12.112 上的 ath11k 双射频内存行为
- 必须先补的缺口：实际 DTB 的 dts 源（坑 1）
