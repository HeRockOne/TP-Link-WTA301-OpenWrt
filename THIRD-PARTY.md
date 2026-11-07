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

2. **要不要因此删掉**：现在**不需要删**了。
   `tools/mk_board2_from_art.py` 可以从**你自己的** ART 分区生成等价文件：

   ```bash
   # 板子上直接跑
   scp tools/mk_board2_from_art.py root@192.168.1.1:/tmp/
   python3 /tmp/mk_board2_from_art.py --art /dev/mtdblock2 --outdir /tmp/bdf
   # 或先 dump 再本地跑
   dd if=/dev/mtdblock2 of=/tmp/art.bin
   python3 tools/mk_board2_from_art.py --art art.bin --outdir /tmp/bdf
   ```

   **已验证**：用本工程作者的 ART dump 跑出来的两个文件，与仓库自带的
   `patches/bdf/*.bin` **逐字节相同**（`78f5b21b…` / `e4904f13…`）。

   仓库现在保留 `patches/bdf/` 只为了一个目的：让**没有本机硬件**的环境
   （CI、想先构建后刷机的人）也能产出固件。如果你不接受这一点，
   就用上面的工具自己生成两份、覆盖 `patches/bdf/` 后构建。

**如果你是要基于本仓库做二次分发**：请自行决定是否保留 `patches/bdf/`，
或改用自己的 ART 数据。我们保留它们是因为这个工程的可复现性依赖它。

---

## 3. 构建时从上游获取（不随仓库分发）

| 组件 | 版本 | 许可 |
|---|---|---|
| OpenWrt | `v25.12.6` = `64900e756efa667774214f9c6b17c113222e01f7` | GPL-2.0 |
| Linux 内核 | 6.12.112（OpenWrt 树内） | GPL-2.0 |
| **`chenxin527/uboot-qsdk12.5-build`**（u-boot 构建包装 + failsafe 框架） | **`9ce31573`** "Merge pull request #4 from webbrain-one/webbrain/readme-improvement" | GPL-2.0 |
| u-boot 2016.01（QSDK 12.5 基座） | 分支 `NHSS.QSDK.12.5`，对应发布标签 `AU_LINUX_QSDK_NHSS.QSDK.12.5_TARGET_ALL.12.5.2783.2994`；**commit 未固定**，见 `patches/uboot/README.md` §1.1 | GPL-2.0+ |
| 工具链 | `arm_cortex-a7_gcc-5.2.0_musl-1.1.16_eabi` | GPL / LGPL 组合 |
| ath11k 固件（q6/m3） | `ath11k-firmware-ipq5018-qcn6122` `2024.10.14~15f05012-r2` | Qualcomm 专有，可再分发（见该包 `Notice.txt`） |
| Argon 主题 | `v3.1.0` | MIT（上游声明） |

### 3.1 u-boot 侧的上游归属（**必须保留**）

本工程的 u-boot 不是从 codelinaro 裸树改起，而是基于
[`chenxin527/uboot-qsdk12.5-build`](https://github.com/chenxin527/uboot-qsdk12.5-build)
（GPL-2.0，自称 "uBootKit"）—— 它提供了 failsafe（网页恢复）框架、`fw_dec.c` 等
基础设施。我们在此基础上加了 TP-Link WTA301 的板级支持。

**这份归属没有商量的余地。** `patches/uboot/files/` 里实际有 **4 个不同上游**：

| 版权持有人 | 文件 | 来历 |
|---|---|---|
| **chenxin527**（2026） | `board/qca/arm/common/failsafe.c`<br>`board/qca/arm/common/fw_dec.c`<br>`failsafe/failsafe.c`<br>`failsafe/modules/modules.h`<br>`include/failsafe/fw_dec.h` | uBootKit 框架 |
| **MediaTek Inc. / Weijie Gao**（2022） | `failsafe/modules/upgrade.c` | **OpenWrt 原版 failsafe**（不是 chenxin527 的） |
| **The Linux Foundation / Qualcomm**（2013–2021） | `board/qca/arm/ipq5018/ipq5018.c`<br>`drivers/net/ipq5018/ipq5018_gmac.c`<br>`board/qca/arm/common/cmd_bootqca.c` 等 | QSDK 原始代码 |
| **Google Inc.**（2009） | `arch/arm/cpu/armv7/qca/common/smem.c` 中的片段 | U-Boot / Linux ARM 渊源 |

**四个文件的版权头缺失（诚实告知）**：

```
board/qca/arm/common/tplink_tpimg.c
include/failsafe/tplink_tpimg.h
drivers/net/ipq5018/rtl8367s.c
failsafe/modules/tplinkinfo.c
```

这四个文件**没有任何 copyright 头**。它们是在 chenxin527 的通用 TP-Link 代码
基础上改的，但我们**没有保留基座 commit 的副本**，所以无法逐行判断哪些是
原作者写的、哪些是我们加的 —— 因此**不往上面加我们的署名**（那可能是错的）。
它们在仓库里以 **GPL-2.0** 分发，与全仓一致。

⚠️ **如果你要重用这四个文件，请自行追溯来源**，不要把它们当成我们的原创。

### 3.2 硬性约束

1. **任何版权头都不得删除。** 包括 `chenxin527` 的 5 个、MediaTek 的 1 个、
   Linux Foundation 的、以及散在文件里的 Google 片段。删任何一个即违反
   GPL-2.0 §1（保留版权声明）。
   `deliver/verify-repro.sh` §7 会逐文件校验，删了立刻报 FAIL。

2. **修改声明在 `patches/uboot/CHANGES.md`**（GPL-2.0 §2(a) 要求）。
   包含：23 个文件的逐文件改动说明 + 对应源码声明（§3）。
   改 `patches/uboot/files/` 里任何东西时，**同一提交里更新 CHANGES.md**。

3. 构建包装钉在 `9ce31573`，并且**由产物自证** —— 已交付的 `u-boot.bin` 里
   版本横幅就是 `U-Boot 2016.01-9ce3157-dirty`。这是本工程唯一一个精确固定
   到 commit 的 u-boot 侧引用。

4. 如果日后把 `patches/uboot/` 拆成独立仓库（类似上游 uBootKit 那样按机型
   收录），开头必须写明「基于 `chenxin527/uboot-qsdk12.5-build` 派生」。

5. **不要把它叫「uBootKit」而不提来源**。上游同名项目的作者是 chenxin527；
   已有一个叫 `chenxin527/uboot-qsdk12.5-build` 的仓库用这个名。
   建议对外用「WTA301 u-boot kit」或「WTA301 U-Boot 复现包」避免混淆。

### 3.3 能不能开源（一句话回答）

**能。** 基座是 GPL-2.0/GPL-2.0+，我们也用 GPL-2.0，许可兼容无冲突。
GPL 只要求「标明 + 给源码」，不禁止分发。

本项目已做到：版权头保留（逐文件自检）· 修改声明（`CHANGES.md`）·
对应源码（overlay + 构建脚本 + 上游引用）。

**唯一的真缺口是工程问题，不是法务**：内层 codelinaro commit 未固定，
所以「逐字节可复现」做不到。GPL **不**要求 bit-identical 构建，
所以不构成违规，但对外应如实说明。

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

## 5. `tools/getroot/`：安全研究代码

这一目录分发的是**针对原厂固件缺陷的可运行利用脚本**，性质与其余目录不同，
单独说明。

### 5.1 它利用的是什么

原厂固件里 `ctcapd.appd install` 的 `url` 参数**未过滤 shell 元字符**，
`appd` 把该 URL 拼进 `wget` 命令行后 `popen()`，因此 `;` 之后的内容会被执行。
`tools/getroot/rawtcp_gw.py` 利用这个缺陷注入
`telnetd -l /bin/sh -p 2323`，得到一个**无密码的 root shell**。

这是**厂商与运营商一侧的安全问题**，不是本工程引入的。它在已出厂、
在网运行的设备上存在。

### 5.2 为什么仍然发布

1. **这是我们自己的设备**，取证与刷机流程的必要前置步骤（不拆机、不接 TTL）。
2. 本仓库 `docs/GETROOT-AND-NORMAL-USER-FLASH.md` **早已完整记录**了这条链
   （六环原理、字符串表偏移、实测日志），只藏脚本没有意义。
3. 对**本机型**的持有者，这决定了「第一次刷 u-boot 是否需要 TTL」，
   是可复现性的一部分。

### 5.3 使用限制（`tools/getroot/README.md` 里同样写明）

- **只在你自己拥有的设备上使用。** 对他人设备执行属未授权访问，多数司法辖区
  构成刑事犯罪。
- 拿到的 shell **无密码**，同网段任何人都能连。用完立即重启板子（`telnetd`
  只活在 RAM，重启即消失）。
- 脚本会**临时改动本机网络**（ARP 单条记录 / IP 别名），退出时还原；
  运行期间本机可能断网。`rawtcp_gw.py` 内置 `NetWatch`，断网即回滚。

### 5.4 代码与依赖归属

| 文件 | 来历 | 许可 |
|---|---|---|
| `rawtcp_gw.py` | **本项目原创**，基于本板逆向（2026-11） | GPL-2.0 |
| `getroot_alias.py` | 本项目原创（早期版本，原名 `getroot3.py`） | GPL-2.0 |
| `legacy/*.py` | 本项目原创（更早的四件套） | GPL-2.0 |
| `negative/*.py` | 本项目原创（**已实测否定**的路线，故意保留） | GPL-2.0 |

运行期第三方依赖（**不随仓库分发**）：

| 依赖 | 用途 | 许可 |
|---|---|---|
| `scapy` | 构造 / 嗅探原始以太网帧 | GPL-2.0 |
| Npcap（仅 Windows） | 给 scapy 提供 libpcap 接口 | Npcap Free / Pro 双许可 |
| `cryptography`（仅 `legacy/elink_gw4.py`） | AES-128-CBC | Apache-2.0 / BSD |

本工程对原厂固件的**逆向分析结论**（协议格式、字符串表偏移、缺陷成因）
属于事实性发现，与代码一并按 GPL-2.0 发布。

---

## 6. 商标

「TP-Link」「WTA301」是其各自权利人的商标，本工程仅用于**标识所适配的硬件**。
本项目与 TP-Link 无任何隶属或背书关系。

刷入非原厂固件通常会使保修失效，并可能违反当地无线电法规（发射功率、信道、国家码）。
本工程默认沿用设备出厂的国家码与功率设置，未做任何放宽。
