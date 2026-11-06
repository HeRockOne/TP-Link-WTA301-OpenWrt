# 第三方材料与许可

本仓库的原创部分以 GPL-2.0 发布（见 [`LICENSE`](LICENSE)）。
下面列出仓库里**不是我们写的东西**，以及它们的来源和许可状态。
有疑问的部分我们写明「未确认」，不含糊过去。

---

## 1. 直接随仓库分发的文件

| 路径 | 内容 | 来源 | 许可状态 |
|---|---|---|---|
| `patches/bdf/board2-wta301-ipq5018-2g.bin` | ath11k `board-2.bin` 容器（131,180 B） | 本机 ART 分区提取后封装 | ⚠️ **见 §2，务必读** |
| `patches/bdf/board2-wta301-qcn6122-5g.bin` | 同上，5 GHz | 同上 | ⚠️ **见 §2** |
| `patches/factory/fdt_mp02.1.*` … `fdt_mp03.3.*` | 原厂固件里的设备树（dtb + 反编译 dts） | 本机原厂固件提取 | ⚠️ 厂商固件内容，仅供分析对照，非运行时依赖 |
| `patches/s7-actual-dtb.dts` | 板子跑 S7 时的实际 DTB 反编译结果 | 本机提取 | 同上，分析用途 |
| `pin/s7-actual-dtb.dtb` | 同上，二进制 | 本机提取 | 同上 |
| `evidence/*.txt` `*.log` | 串口 / 刷机实测日志 | 本机采集 | 我们自己的记录 |

**注意**：`patches/factory/`、`patches/s7-actual-dtb.dts`、`pin/s7-actual-dtb.dtb`
是**分析用的对照材料**，不参与固件构建。真正参与构建的只有 `patches/bdf/` 两个文件。

---

## 2. ⚠️ `patches/bdf/`：校准数据的来历与影响

这是本仓库**唯一一处需要认真对待的**第三方数据问题。

### 2.1 这些文件里装的是什么

`board-2.bin` 是 ath11k 的「板型容器」，里面装一块 131,072 字节的 BDF。
本板的 ART 分区（`mtd2`，gzip+tar 包着一个 512 KiB 的 `virtual_art.bin`）
在 `+0x1000` 和 `+0x26800` 各存一份 128 KiB 数据 —— 那是**这台机器出厂时逐台校准的
射频参数**（功率、频偏等）。

随仓库分发的两个 `board2-wta301-*.bin` 装的就是**本机这两份校准数据**。

### 2.2 为什么用本机 cal 而不是原厂通用模板

原厂 rootfs 里另有 `bdwlan.b10` / `bdwlan.b50`（各 131,072 B）—— 那是**通用模板**。
实测两者差异极小（2.4G 差 25 字节、5G 差 79 字节），集中在 `0xa` 头字段和
`0x1a00+` / `0x2700+` 的功率校准区。

⇒ `bdwlan` = 通用模板；ART 里的 = 通用模板 + 逐台校准微调。
用通用模板会丢掉本机的功率校准。推导过程见 `docs/M12-FIRMWARE-BDF.md` §1.2。

### 2.3 别人刷了这个固件，用的是谁的校准？—— **他自己的**

这一点很重要，且已实证：

固件里带了 `etc/hotplug.d/firmware/12-wta301-caldata`，开机时从**本机 ART** 提取
`cal-ahb-*.wifi.bin`：

```
IPQ5018 : virtual_art.bin + 0x1000  len 0x20000
qcn6122 : virtual_art.bin + 0x26800 len 0x20000
```

ath11k 分别加载 board data（`board-2.bin`）与 caldata（`cal-*.wifi.bin`），
**校准以 caldata 为准**。也就是说：`board-2.bin` 提供板型/variant 匹配（必须有，
否则 `-12` 加载失败），而**射频校准始终来自刷机者自己的 ART**。

⇒ 把这份 `board-2.bin` 分发给别的 WTA301，不会让别人用我们的发射功率。

### 2.4 仍然存在的两个问题（诚实列出）

1. **IP 层面**：ART 校准数据是厂商烧进 flash 的，理论上不是可自由分发的内容。
   Qualcomm 的 ath11k-firmware 仓库（`Notice.txt`）只覆盖 q6/m3 固件，
   **不覆盖 `board-2.bin` / `caldata.bin`** —— 上游明确「这两个不提供」。
   我们在本仓库分发，等于把一台机器自己的校准数据公开。

2. **要不要因此删掉**：删了仓库就不能直接构建出可用固件（缺 variant 匹配 → Wi-Fi 起不来）。
   折中方案是提供生成脚本、让使用者从**自己的 ART** 生成。目前**没有实现**这个脚本，
   已列入 `docs/OPEN-SOURCE-RELEASE.md` 的待办。

**如果你是要基于本仓库做二次分发**：请自行决定是否保留 `patches/bdf/`，
或改用自己的 ART 数据。我们保留它们是因为这个工程的可复现性依赖它。

---

## 3. 构建时从上游获取（不随仓库分发）

| 组件 | 版本 | 许可 |
|---|---|---|
| OpenWrt | `v25.12.6` = `64900e756efa667774214f9c6b17c113222e01f7` | GPL-2.0 |
| Linux 内核 | 6.12.112（OpenWrt 树内） | GPL-2.0 |
| u-boot 2016.01 | 分支 `NHSS.QSDK.12.5`（commit 未固定，见 `patches/uboot/README.md` §1.1） | GPL-2.0+ |
| 工具链 | `arm_cortex-a7_gcc-5.2.0_musl-1.1.16_eabi` | GPL / LGPL 组合 |
| ath11k 固件（q6/m3） | `ath11k-firmware-ipq5018-qcn6122` `2024.10.14~15f05012-r2` | Qualcomm 专有，可再分发（见该包 `Notice.txt`） |
| Argon 主题 | `v3.1.0` | MIT（上游声明） |

---

## 4. 我们没有改过、但被本工程依赖的上游代码

内核补丁目录 `patches/kernel-6.12/` 里的补丁，**主体来自上游**（Qualcomm / linux-arm-msm /
netdev 邮件列表），我们只做了适配：

| 补丁 | 上游来源 |
|---|---|
| `0740-01` dt-binding phy 时钟数 | 上游 dt-binding 演进 |
| `0740-03` `ipq5018` gephy rx/tx 时钟 | Qualcomm 上游化系列 |
| `0740-04` `at803x` ipq5018 phy 时钟管理 | 同上 |
| `0842` ipq5018 uniphy 节点 | 同上 |
| `0843` stmmac `get_interfaces` | netdev |
| `0951` uniphy PCS | netdev / linux-arm-msm |
| `0954` IPQ5018 DWMAC | 同上 |
| `0950` ath11k DP ring 尺寸 | ath11k 低内存提案（`[PATCH ath-next] wifi: ath11k: use smaller DP rings on low-memory systems`） |

每条的 URL 与原文记录在 `docs/03-EXTERNAL-EVIDENCE.md` 和
`docs/R20-PERF-EXTERNAL-EVIDENCE.md`。

---

## 5. 商标

「TP-Link」「WTA301」是其各自权利人的商标，本工程仅用于**标识所适配的硬件**。
本项目与 TP-Link 无任何隶属或背书关系。

刷入非原厂固件通常会使保修失效，并可能违反当地无线电法规（发射功率、信道、国家码）。
本工程默认沿用设备出厂的国家码与功率设置，未做任何放宽。
