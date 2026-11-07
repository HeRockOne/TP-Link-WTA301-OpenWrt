# WTA301 → OpenWrt

把 **TP-Link WTA301**（Qualcomm IPQ5018 Wi-Fi 6 路由器）跑上 **OpenWrt 25.12.6** 的完整移植工程：
设备树、内核补丁、u-boot（含网页恢复界面）、固件打包、成品固件，以及每一步的实测证据。

板子是本仓库作者自己的一台机器，所有结论都在**真机**上验证过；没验证的地方在文档里
明确标为「未验证」，不写成「已完成」。

---

## 支持的硬件

| 项 | 规格 |
|---|---|
| SoC | Qualcomm **IPQ5018**（2× Cortex-A53 @ 1 GHz，2.4 GHz 射频内置） |
| 5 GHz | **QCN6122**（Wi-Fi 6，独立芯片） |
| 交换机 | **Realtek RTL8367S** → 4× RJ45，CPU 口 SGMII 1 Gbps |
| 内存 | 256 MiB DDR3（可用 174.5 MiB） |
| Flash | 128 MiB NAND |
| 按键 | reset（GPIO20）、WPS（GPIO17） |
| LED | 5 个（含一个 `green:wan`，但本机没有 WAN 口） |
| 串口 | 1 个（`blsp1_uart1`） |

**没有**：USB、PCIe 外设、SD/MMC。（DTS 里 `pcie0/pcie1` 注明 `disabled on purpose`。）

---

## 现在能做什么

| 能力 | 状态 | 文档 |
|---|---|---|
| 启动、有线 4 口（DHCP + 桥接） | ✅ 真机验证 | `docs/P7-WIRED-FIX-VERIFIED.md` |
| 双频 Wi-Fi（5 GHz HE80 / 2.4 GHz HT20） | ✅ 真机验证 | `docs/M12-FIRMWARE-BDF.md` |
| 中文 LuCI + Argon 主题 | ✅ | `docs/P16-CHINESE-LUCI.md` |
| 重置 / WPS 按键 | ✅ | `docs/P17-ARGON-KEYS.md` |
| overlay 断电持久化 | ✅ | `docs/P11-OVERLAY-PERSISTENCE.md` |
| **u-boot 网页刷机**（不死 u-boot + 自带 HTTP 恢复页） | ✅ | `docs/P20-UBOOT-UI.md` |
| **系统内 `sysupgrade`**（LuCI 直接刷，不用进 u-boot） | ✅ 真机验证 | `docs/P28-SYSUPGRADE-IN-OS.md` |
| LuCI 概览页 CPU / 温度面板 | ✅ | `docs/P30-THERMAL.md` |
| 性能调优（packet steering / IRQ 亲和 / NAPI budget） | ✅ 已烧进固件 | `docs/P26-PERF-TUNING.md` |
| 开箱即用（默认 SSID / 密码 / 信道） | ✅ | `docs/P25-OUT-OF-BOX.md` |
| **NSS 硬件加速** | ❌ 有意不做 | `docs/R21-CPU-LOAD-VS-STOCK-EXTERNAL-EVIDENCE.md` |
| 2.5G HSGMII | ❌ 交换芯片不支持 | `docs/R17-RTL8367S-SERDES.md` |

> **为什么 CPU 占用比原厂高**：原厂走 NSS（闭源硬件转发，947 Mbps @ 9% CPU）。
> 我们用主线的软件转发，有线 ~590 Mbps @ 80% CPU。要 NSS 就得弃 DSA、
> 换闭源 blob、内核全部脱离主线 —— 与「长期稳定家用」冲突，故不做。
> 完整对比数据见上面的 R21 文档。

---

## 固件下载

成品固件在 **Releases** 页（仓库里不存二进制，`*.bin` 已被 `.gitignore` 排除）。

每个版本给三个包，**用途完全不同，不能混刷**：

| 文件 | 大小 | 用途 |
|---|---|---|
| `wta301-op-25.12.6-<ver>.bin` | 17,170,432 B | **u-boot 网页刷机**（紧凑布局 `0x1060000`） |
| `wta301-op-25.12.6-<ver>-sysupgrade.bin` | ~13.4 MB | **系统内升级**（LuCI / `sysupgrade`） |
| `rescue/wta301-op-25.12.6-<ver>-ttl.bin` | 20,447,232 B | **串口救砖**（稀疏布局 `0x1380000`，含 head/tail 填充） |
| `wta301-uboot-p21c.bin` | 262,144 B | u-boot 槽镜像（一般不用刷，u-boot 本身已经是这个版本） |

网页包和 TTL 包的**布局不同**（紧凑 vs 稀疏），互相刷会写错偏移。看标题对号入座。

### 刷机流程

**第一次从原厂 / 别的 OpenWrt 过来 —— 必须走 u-boot 网页**：

1. 断电，按住 reset 不放，上电，等约 **40 秒**到红灯常亮（进入 u-boot failsafe）
2. 网线接到 LAN 口，电脑设 `192.168.1.2/24`，浏览器开 `http://192.168.1.1`
3. 上传网页包 → 页面会先校验再写入
4. 刷完**手动 `bootipq`**，不要放手

细节与故障处理见 `docs/USER-MANUAL.md` §3。

**之后的版本 —— 直接在 LuCI 里刷**：
「系统 → 备份/刷写固件」上传 `-sysupgrade.bin`。
配置和已装软件包**会自动保留**（overlay 在独立的 UBI 卷上，升级不碰它）。

### 回原厂

原厂固件在 B 槽（`mtd10` + `mtd11`）里原封不动保留着。
`boot_flag`（`mtd13`）= `55 aa 42 46 | 00 00 00 02`，大端 `2` = 从 A 槽启动。
把原厂 A 槽镜像 dd 回 `mtd5` + `mtd6` 即可，`boot_flag` 不用改。

---

## 仓库结构

| 目录 | 内容 |
|---|---|
| `patches/uboot/` | **u-boot kit** —— 全部自研 u-boot 代码（23 个文件，整份 overlay 不打 diff）+ 构建脚本 + 槽镜像打包器。见 `patches/uboot/README.md` |
| `patches/kernel-6.12/` | 内核补丁：UNIPHY PCS、stmmac DWMAC、gephy 时钟、dt-binding |
| `patches/mac80211/` | ath11k 低内存 DP ring 尺寸 |
| `patches/fstools/` | `fstools_overlay_name` 支持（overlay 用自定义 UBI 卷名） |
| `patches/bdf/` | Wi-Fi 板型容器 `board-2.bin` 的**生成位置**（仓库不分发，见下）。用 `tools/mk_board2_from_art.py` 从你自己的 ART 分区生成 |
| `files/` | DTS + 设备树覆盖 |
| `files-rootfs/` | rootfs overlay：`net-tune` 守护、sysctl、LuCI 温度面板、rpcd 数据源 |
| `files-base-files/` | base-files overlay：出厂无线配置、uci-defaults |
| `files-ipq50xx-upgrade/` | `platform.sh`（系统内升级的板级实现） |
| `deliver/` | 应用脚本、出包脚本、验收脚本 |
| `tools/` | 校验 / 刷写 / 串口 / 三方差异表工具 |
| `tools/getroot/` | **免拆机拿原厂 root** 的脚本（`rawtcp_gw.py`）+ 反面证据 + 失败模式。见 `tools/getroot/README.md` |
| `pin/` | 事实快照（上游 `.config`、S7 基线、板级实测数据） |
| `docs/` | 分析、风险登记、阶段记录、外部证据、复现指南。**读之前先看 `docs/README.md`**（里的路径与 IP 是取证记录，不是配置） |
| `evidence/` | 实测日志 |

**不包含**（按固定引用取）：OpenWrt 源码树（14 GB）、u-boot 源码树（133 MB）、工具链。
具体 tag / commit 见 `docs/REPRODUCE.md`。

---

## 从源码构建

### 先做一步：生成 board-2.bin

`board-2.bin` 里装的是**逐台**射频校准数据（从 ART 分区提取），属于厂商烧进
flash 的数据，**本仓库不分发**。构建前用你自己的板子生成一次：

```bash
# 需要本机 root（不拆机、不接 TTL）：见 tools/getroot/README.md
# 板子有 python3：
scp tools/mk_board2_from_art.py root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "python3 /tmp/mk_board2_from_art.py --art /dev/mtdblock2 --outdir /tmp/bdf"
scp root@192.168.1.1:/tmp/bdf/board2-wta301-*.bin patches/bdf/

# 板子没有 python3：先 dump 再本地跑
ssh root@192.168.1.1 "dd if=/dev/mtdblock2 of=/tmp/art.bin"
scp root@192.168.1.1:/tmp/art.bin .
python3 tools/mk_board2_from_art.py --art art.bin --outdir patches/bdf
```

为什么不分发、以及为什么这不影响射频性能：`THIRD-PARTY.md` §2。
细节：`patches/bdf/README.md`。`patches/bdf/*.bin` 已 gitignore，不会误入库。

### OpenWrt

```bash
git clone https://github.com/openwrt/openwrt.git
cd openwrt && git checkout 64900e756efa667774214f9c6b17c113222e01f7   # v25.12.6
# 铺本仓库的 overlay + 补丁（脚本会逐项校验 md5）
bash wta301-2512/deliver/apply-to-2512.sh /path/to/openwrt
make -j$(nproc) world
make -j$(nproc) target/install
```

`apply-to-2512.sh` 会碰 `target/linux/qualcommax/files/`，**触发内核全量重编（约 45 分钟）**。
只改用户态时用 `deliver/apply-rootfs-only.sh`，不触发重编。

出包：

```bash
bash deliver/make-release.sh --version P29-2512 --stage P29   # 四区 + sysupgrade
bash deliver/make-deliverable.sh p29                          # 三种成品包 + 自检
```

### u-boot

见 `patches/uboot/README.md`。要点：

```bash
UBOOT_TREE=/path/to/u-boot-2016 \
TOOLCHAIN_BIN=/path/to/toolchain/bin \
bash patches/uboot/build/build_j1.sh
```

验收：`u-boot.bin` 应为 **556,032 B**，槽镜像 262,144 B / md5 `d0ada9f7…`。

---

## ⚠️ 刷机前必须知道的三件事

1. **二级 u-boot 链接基址是 `0x49900000`，不是 `0x4a920000`。**
   链错 → 一级跳过去找不到东西 → **串口直接死**。

2. **一级 u-boot（`factory_boot`，`0x0–0x3c0000`）永不写入。**
   它是唯一的救命通道。本仓库的所有工具都不会碰它。

3. **u-boot 基座 commit 未固定。**
   `patches/uboot/README.md` §1.1 写明了这个残余风险：codelinaro 上游当时没记 commit。
   补救是本目录的 `files/` 是**整份 overlay**（改过的文件全量收录，不打 diff），
   只要基座同代（2016.01 / QSDK 12.5）就能重建出等价产物。
   跨基座版本重编不保证 md5 一致 —— 这是已知局限，不是疏漏。

---

## 已知限制

| 限制 | 说明 |
|---|---|
| 无 WAN 口 | 5 个交换口全在 `br-lan` 桥里，有意设计（原厂也只有一个桥） |
| 内存紧 | `MemTotal 174.5 MiB`，ath11k 独占 73.4 MiB = 42%。装软件包要看容量 |
| 无 `cpufreq` | IPQ5018 频率锁定，无法调频/降频省电 |
| 无 RTC | 重启后时钟倒退，判断事件先后要用 `/proc/uptime` |
| 5 GHz 峰值温度较高 | 满载打到 90 °C（芯片阈值 120 °C，`ath11k_thermal cur_state=0/100`）。给 5G 芯片加散热片有用，给 CPU 加没用（两者不在同一硅片） |
| mtd8 的 22 MiB 未启用 | 改分区表风险大于收益，保留不动。理由见 `docs/P22-STORAGE-LAYOUT.md` |

---

## 许可

本仓库的**原创部分**（脚本、文档、DTS、u-boot 自研代码、内核补丁）以 **GPL-2.0** 发布，
见 [`LICENSE`](LICENSE)。这是与 OpenWrt、u-boot、Linux 内核保持一致的选择。

仓库内含的第三方材料及其许可见 [`THIRD-PARTY.md`](THIRD-PARTY.md)。
其中 `patches/bdf/` 与 ART 校准数据的关系，务必读那一节。

---

## 致谢

- **OpenWrt** —— 整个用户态、LuCI、`ipq50xx` 子目标
- **Linux 内核** + Qualcomm 上游化工作（UNIPHY PCS、IPQ5018 DWMAC、gephy 时钟）
- **ath11k** —— 无线驱动，以及上游那套低内存 DP ring 尺寸提案
- **u-boot** 与 CodeLinaro QSDK（`NHSS.QSDK.12.5` 分支）
- **kenzok8 / jerrykuku** —— Argon 主题
- 所有在 OpenWrt 论坛、linux-arm-msm、lore.kernel.org 上留下实证记录的人 ——
  本工程大部分的「可行 / 不可行」结论，先是他们的，然后才是我们验证的
