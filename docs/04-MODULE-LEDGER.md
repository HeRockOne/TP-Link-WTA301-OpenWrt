# 04 模块台账

**用法**：一次只推进一个模块。每个模块都要跑完 **原厂 → S7 → 25.12.6 上游** 三方核对，
落一份 `docs/Mxx-*.md`，并把结论行写回本表。

**三方数据源**（一次性备齐）：

| 代号 | 来源 | 提取方式 |
|---|---|---|
| **原厂** | `work/backup/mtd10_kernel_bak.bin` 内 FIT 的 3 个 DTB | `fdt_mp03.3` / `fdt_mp03.1` / `fdt_mp02.1`，反编译在 `patches/factory/` |
| **原厂-u-boot** | `work/backup/mtd4_normal_boot.uboot.bin` 内 10 个板级 DTS + 1 控制 DTB | `ub_01`…`ub_10` 全为 QCA 参考板 |
| **S7** | `op_kernel_0x480000.bin` 偏移 `0x46eb48` 的实际 DTB | `patches/s7-actual-dtb.dts`（1,289 行） |
| **25.12.6** | `/tmp/ow` sparse clone | `target/linux/qualcommax/...` |

**一个重要前提**：原厂固件是 **QSDK 4.4.60 / arch=arm（32 位）**，DTB 里 **没有分区节点**
（分区由 u-boot 用 `cmdlinepart.mtdparts` 传入）。所以「原厂的分区定义」要到 u-boot 里找，
不在 DTB 里 —— 这一点会直接影响 M2。

---

## 模块清单与状态

| # | 模块 | 三方一致? | 状态 | 记录 |
|---|---|---|---|---|
| **M1** | NAND 控制器 / ECC 参数 | ❌ **不一致（ECC 4 vs 8）** | ✅ 已核对 | `docs/M01-NAND-ECC.md` |
| **M2** | 分区表 | ⚠ 原厂无节点，S7 硬编码 14 项 | ✅ 已核对 | `docs/M02-PARTITIONS.md` |
| **M3** | 以太网 / MDIO / PHY / 交换机 | ❌ 完全不同（QSDK ESS vs 上游 DSA） | ✅ 已核对 + **R14 缺口已解** | `docs/M03-ETHERNET.md` · `docs/M06-CLOCK-UNIPHY.md` §4–§6 |
| **M4** | Wi-Fi（IPQ5018 2.4G + QCN6122 5G） | ⚠ 源 dts ≠ 实际 DTB | ✅ 已核对 | `docs/M04-WIFI-DRIVER.md` |
| **M5** | GPIO / LED / 按键 / pinctrl | ⚠ 原厂只给 15/26/27，其余来自运行时 | ✅ 已核对 | `docs/M05-GPIO-LED-KEYS.md` |
| **M6** | 时钟 / PLL / uniphy | ⚠ 25.12.6 缺 uniphy0 + 整个主线以太网栈 | ✅ 已核对（含 R14 解决方案 + 补丁集验证） | `docs/M06-CLOCK-UNIPHY.md` |
| **M7** | 内存 / reserved-memory | ❌ 上游 tz 2 MiB 会踩踏 TZ；memory size=0 | ✅ 已核对 | `docs/M07-MEMORY.md` |
| **M8** | 引导链 / chosen / bootargs | ⚠ vendor 有 `init=/init`，我们必须去掉 | ✅ 已核对 | `docs/M08-BOOT-CHAIN.md` |
| **M9** | USB / PCIe / SDCC / 其它外设 | ⚪ 本板全关；★ QCN6122 不是 PCIe 设备 | ✅ 已核对 | `docs/M09-PERIPHERALS.md` |
| **M10** | MAC 地址 / ART / caldata 来源 | ⚠ 原厂 ART 无 MAC；真 MAC 在 factory_info@0x1c；S7 实际没设 MAC | ✅ 已核对 | `docs/M10-MAC-ART.md` |
| **M11** | 温度 / 电源 / 稳压器 | ⚪ 零动作：thermal 三源一致、无 PMIC | ✅ 已核对 | `docs/M11-THERMAL-POWER.md` |
| **M12** | 无线固件 / BDF 加载路径 | ❌ bdwlan ≠ cal；包不含 board-2.bin | ✅ 已核对 | `docs/M12-FIRMWARE-BDF.md` |

**优先级顺序**（按「会挡住启动」排序）：M1 → M2 → M3 → M8 → M7 → M4 → M12 → M5 → M6 → M10 → M9 → M11

---

## 已确认的全局差异（不属于任何单一模块，但必须记住）

| 项 | 原厂 | S7 | 25.12.6 |
|---|---|---|---|
| 内核 | **4.4.60** | 6.18.55 | 6.12.112 |
| 架构 | **arm（32 位）** | aarch64 | aarch64 |
| DTB 来源 | 高通公版参考板（`AP-MP02.1`/`MP03.1`/`MP03.3`）**三选一** | 自建 | 需自建 |
| 分区定义 | **不在 DTB 里**，由 u-boot `mtdparts` 传 | DTB `fixed-partitions` 14 项 | 需自建 |
| 节点命名 | `soc` / `qpic-nand@` / `ess-switch@0x` | `soc@0` / `spi@` / `ethernet@` | 同 S7 |

**⇒ 原厂 DTB 不是"WTA301 的硬件描述"，而是"QCA 参考板的硬件描述"。**
TP-Link 的板级差异（RTL8367S、分区、MAC）全部藏在 u-boot 与 `config` 分区里。
这一条改变了迁移策略：**不能用"和原厂 DTB 对齐"作为正确性判据**，
必须以 **S7 实际运行的 DTB + 板上实测** 为判据。

---

## 工具

| 工具 | 用途 |
|---|---|
| `work/scratch/fdtdiff.py <A.dtb> <B.dtb> <A名> <B名>` | 两个 DTB 的结构化差异（节点集 + 属性值） |
| `work/scratch/fdt/` | 已提取的全部 DTB |
| `work/scratch/fdt/factory/*.dts` | 原厂 3 个 DTB 反编译 |
| `work/scratch/fdt/uboot/*.dts` | u-boot 内 10 个板级 DTS 反编译 |
| `work/scratch/fdt/v19.dts` | S7 实际 DTB 反编译（= `patches/s7-actual-dtb.dts`） |

**性能注意**：解析 `/mnt/c` 上的大文件必须一次性 `read()` 后内存里处理。
`dd bs=1` 等于百万次 9p 调用，会 300 s 超时。