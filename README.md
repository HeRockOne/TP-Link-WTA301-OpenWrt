# wta301-2512 —— 迁移到 OpenWrt 正式版 25.12.6

**目标**：把 TP-Link WTA301（IPQ5018 + RTL8367S + QCN6122，256 MiB DDR3 / 128 MiB NAND）从当前的
**snapshot `r37669-6c9452a35b`** 迁到 **正式版 `v25.12.6`**，从而获得永久冻结的软件源、上游维护的
无线驱动，以及正常的 `sysupgrade` 能力。

**当前状态（2026-11-06）**：**P1–P11、P16、P17 已在真机验证；P18–P21 网页刷机链路打通**。
板子现跑 OpenWrt 25.12.6 r33311 / 6.12.112，u-boot 为 P21c。

| 阶段 | 状态 | 落点 |
|---|---|---|
| P1 逐模块核对（12 个） | ✅ | `docs/M01..M12` |
| P2/P3 造 DTS、编内核、四件套打包 | ✅ 逐项复核 | `docs/P2-BUILD-DELIVERY.md` · `docs/P3-PACK-CONTRACT.md` |
| P4–P5 真机首启 + 包集对齐 | ✅ 已实证 | `docs/P5-PACKAGE-PARITY.md` |
| P7 有线（UNIPHY PCS） | ✅ 9/9 判据 | `docs/P7-WIRED-FIX-VERIFIED.md` |
| P9–P11 overlay 持久化 | ✅ | `docs/P11-OVERLAY-PERSISTENCE.md` |
| P16/P17 中文 LuCI + Argon + 按键 | ✅ | `docs/P16-VERIFIED.md` · `docs/P17-ARGON-KEYS.md` |
| P18–P21 u-boot 网页刷机 | ✅ 链路闭环，余 `factory_no_fit` 真刷未验 | `docs/P20-UBOOT-UI.md` · `docs/P21-DECODE-OOM.md` |
| P22 存储布局实测 | ✅ 已实测并决策（mtd8 保留不动） | `docs/P22-STORAGE-LAYOUT.md` |

**复现**：见 `docs/REPRODUCE.md`（OpenWrt）与 `patches/uboot/README.md`（u-boot kit）。

**待服务决策**（不影响当前可用性）：WiFi 默认密码、reset 长按阈值、是否开 WAN。

**已决策**：mtd8 的 22 MB 保留不动 —— `/overlay` 还剩 27.7 MB，190 个包只占 508 KB，
改分区表风险大于收益。实测数据与理由见 `docs/P22-STORAGE-LAYOUT.md`。

---

## 这个仓库是什么

| 目录 | 内容 |
|---|---|
| `docs/` | 迁移分析、风险登记、阶段记录、外部证据、复现指南 |
| `pin/` | 事实快照（S7 基线、**25.12.6 顶层 .config**、板级实测数据） |
| `patches/` | 本板补丁 + **`uboot/files/`（u-boot 自研代码全量）** + **`bdf/`（两个 board-2.bin）** |
| `files/` | 内核驱动 / dt-binding / 板级 dts 的 overlay |
| `deliver/` | 应用脚本 + 出包脚本 + base-files + 成品固件 |
| `evidence/` | 实测日志 |
| `tools/` | 校验 / 刷写 / 串口 / 差异表工具 |

**不包含**：OpenWrt 源码树（14 GB）、u-boot 源码树（133 MB）、工具链。
这些不属仓库内容 —— 只记固定引用（tag + commit），具体见 `docs/REPRODUCE.md` §1。

**回退基线**在仓库外：`../work/backup/FROZEN-S7-20261105/`。

---

## 为什么迁移（决策依据，全部有出处）

| 事实 | 证据 |
|---|---|
| `v25.12.6` 标签日期 **2026-10-18 02:11**，而本板 snapshot 构建于 **2026-10-25 20:35** | 上游 git tag |
| 正式版 `ipq50xx` 子目标自 `25.12.0` 起存在；`24.10.x` 无此子目标 | `downloads.openwrt.org/releases/` |
| 正式版**永久冻结**；snapshot 每次构建覆盖，8 条源已在漂移（现 `r38103` / 内核 6.18.60） | `docs/03-EXTERNAL-EVIDENCE.md` |
| 25.12.6 有 **7 个同硬件组合**设备（IPQ5018+QCA8337+QCN6122）的 DTS 可参照 | `pin/x2512-facts.json` |
| 25.12.6 含 QCN6122 专用 ath11k 补丁 5 个（920/921/922/923/924/925） | 同上 |

⇒ 当初选 snapshot 是在正式版已发布 7 天的情况下选的，属于**基线选择失误**。见 `docs/00-MIGRATION-ANALYSIS.md` §1。

---

## 关键约束（不可协商）

1. **S7 是回退基线，迁移全程不碰板子**。所有产物先离线造好、离线校验。
2. 首版目标 = **只验证能不能启动 + 有线通**，Wi-Fi 留到第二阶段。
3. 迁移产物**不覆盖** S7 的 `work/images/out-op-v19-fix10.1-S7/`。
4. 刷机前必须过 `flash_release.py` 预检 + 三重校验（`AGENTS.md` §5.5）。
5. 未在真机验证的产物不得写成"已完成"。

---

## 状态

| 阶段 | 状态 |
|---|---|
| P0 规划（本文档 + 分析 + 风险 + 计划） | ✅ |
| P1 取得上游参数、克隆源码树 | ✅ v25.12.6 = 64900e75 |
| P2 造 DTS、编内核 | ✅ 6.12.112 |
| P3 离线造包 + 打包（TP 头） | ✅ 四件套逐项复核 |
| P4 真机验证（启动 + 有线） | ✅ |
| P5 包集对齐（182 包） | ✅ |
| P6 sysupgrade | ⛔ **不做**（stock sysupgrade 会破坏启动） |
| P7 有线 UNIPHY PCS | ✅ 9/9 |
| P9–P11 overlay 持久化 | ✅ |
| P16/P17 中文 LuCI + Argon + 按键 | ✅ |
| P18–P21 u-boot 网页刷机 | ✅ 闭环（`factory_no_fit` 真刷未验） |

各阶段细节见 `docs/02-PHASE-PLAN.md`；从零复现见 `docs/REPRODUCE.md`。
