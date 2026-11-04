# M07 内存与 reserved-memory

**结论：/memory 必须写死 256 MiB；reserved-memory 沿用 S7 的 6 段；
wcss 区 52 MiB、5G bdf 0x4D300000、m3-dump 0x4E200000 —— 都是 TP-Link 定制值，
与上游任何同硬件板都不同。**

---

## 0. 先纠三个数字（dtc 的坑）

S7 实际 DTB 里，`qcom,bdf-addr` 和 `qcom,m3-dump-addr` 是 4 字节大端 u32，
但 **dtc 把它们渲染成了 ASCII 字符串**，因为字节恰好可打印：

| 属性 | dtc 输出 | 反转 = 真值 | 原始字节 |
|---|---|---|---|
| `wifi@c000000/qcom,bdf-addr` | `"L@\0"` | **0x4C400000** | `4c 40 00 00` |
| `wifi@b00a040/qcom,bdf-addr` | `"M0\0"` | **0x4D300000** | `4d 30 00 00` |
| `wifi@b00a040/qcom,m3-dump-addr` | `"N \0"` | **0x4E200000** | `4e 20 00 00` |

**踩过两次**：先把 `M0` 的 `0`（零）读成 `O`（字母）得出 0x4D100000，
又把 `N `（N+空格）读成 0x4E000000。两者都错。

⇒ **纪律：任何形如 `"\X\0"` 的 DTB 字符串属性，必须回原始 DTB 字节核对，
不许照抄 dtc 的 ASCII 渲染。** 工具：`wta301-2512/tools/scan_fake_strings.py` +
`pin/s7-actual-dtb.dtb` 裸解析（见 §2 脚本）。

原厂 DTB 已扫过，无此类属性（原厂是 4.4 内核 DTB，属性集不同）。

---

## 1. `/memory` 必须写死 256 MiB（**不能学 6.12 上游的 0**）

### 三方差值

| 来源 | `/memory` reg | 含义 |
|---|---|---|
| 原厂 `fdt_mp03.1.dtb` | `<0x0 0x40000000 0x0 0x20000000>` | 512 MiB（参考板配置） |
| **6.12 上游 `ipq5018.dtsi`** | `<0x0 0x40000000 0x0 0x0>` | **0**，注释 `/* We expect the bootloader to fill in the size */` |
| **S7 实际 DTB** | `<0x0 0x40000000 0x0 0x10000000>` | **256 MiB**，写死 |

### 为什么不能照抄上游的 0

6.12 mainline 的约定是「u-boot 会调 `fdt_fixup_memory()` 把大小填进去」。
这一条依赖 u-boot 的 `ft_system_setup` 路径。

**本板用的是 TP-Link QSDK u-boot 2016 的定制 boot 流程
（`tpl_boot_one()` → `bootm`），不是标准 `bootm` 的 `ft_system_setup` 链**，
`fdt_fixup_memory` 是否被调用**未验证**。若没被调用，`reg` 长度为 0 的 memory 节点
会被 `early_init_dt_scan_memory()` 跳过 ⇒ **内核拿不到任何内存 ⇒ 立即 panic**。

⇒ **裁决：写死 `reg = <0x0 0x40000000 0x0 0x10000000>`，不依赖 u-boot 修补。**
即使 u-boot 真的去 fixup，写死的 256 MiB 与硬件一致，结果相同。

（P4 上电时顺手确认：`dmesg | grep -i "Memory:"` 应报 `Memory: 177xxxK/262144K available`）

---

## 2. reserved-memory 三方对照

### 2.1 三方差值表

| 区域 | 原厂 mp03.1 | **6.12 上游 `ipq5018.dtsi`** | S7 实际 DTB | 裁决 |
|---|---|---|---|---|
| `nss@40000000` | 8 MiB | — | — | 不要（NSS 已弃用，nss-edma 不用） |
| `bt@7000000` | 0x58000 | — | — | 不要（蓝牙，本板无） |
| `tz_apps@4a400000` | — | — | **4 MiB** | **保留**（QSDK TZ 应用区） |
| `bootloader@4a800000` | 2 MiB | **2 MiB** | 2 MiB | 一致 |
| `sbl@4aa00000` | 1 MiB | **1 MiB** | 1 MiB | 一致 |
| `smem@4ab00000` | 1 MiB | **1 MiB**（`hwlocks = <&tcsr_mutex 3>`） | 1 MiB（`hwlocks = <0x8 0x3>` = `tcsr_mutex 3`） | 一致 |
| `tz@4ac00000` | **4 MiB** | **2 MiB** ❗ | **4 MiB** | **保留 4 MiB** |
| `wcnss` / `wcss@4b000000` | 0x1700000（23 MiB） | 见 §2.2 | **0x3400000（52 MiB）** | **保留 52 MiB** |
| `m3_dump@4c700000` | 1 MiB | — | — | 不要（已由 `qcom,m3-dump-addr` 属性替代） |
| `q6_etr_dump@4c800000` | 1 MiB | — | — | 不要 |
| `qcn9000_pcie0@4c900000` | 17 MiB | — | — | 不要（本板无外挂 QCN9000） |
| `dma_pool1@4da00000` | 16 MiB `shared-dma-pool` | — | — | 不要（nss-edma 专用） |

**`tz@4ac00000` 是危险项**：6.12 上游写 2 MiB，实际硬件（QSDK）是 4 MiB。
若照抄 2 MiB，`0x4ae00000–0x4b000000` 会落入 Linux 可分配内存，
TZ 在该区有数据 ⇒ **随机踩踏 / 安全世界崩溃**。
⇒ **保留 S7 的 4 MiB。**

### 2.2 upstream 的 `q6_region` 是在补丁里定义的，且被 qcn6122 覆盖

`6.12 ipq5018.dtsi` 本身**没有** `q6_region` / `q6v5_wcss`（grep 无匹配）。
它们由 OpenWrt 补丁加：

```
target/linux/qualcommax/patches-6.12/0189-arm64-dts-qcom-ipq5018-add-nodes-to-bringup-q6.patch
+		q6_region: wcss@4b000000 {
+			reg = <0x0 0x4b000000 0x0 0x1b00000>;     ← 27 MiB（基础值）
+			no-map;
+		};
```

然后 `target/linux/qualcommax/files/.../ipq5018-qcn6122.dtsi` 覆盖：

```dts
&q6_region {
	reg = <0x0 0x4b000000 0x0 0x3000000>;                 ← 48 MiB（带 QCN6122 时）
};
```

⇒ **48 MiB 是「IPQ5018 + 1个 QCN6122」的上游值**；我们是 **52 MiB**。

### 2.3 `remoteproc@cd00000`（`q6v5_wcss`）对照

| 属性 | 6.12 upstream（0189 补丁） | S7 实际 DTB |
|---|---|---|
| `compatible` | `qcom,ipq5018-wcss-sec-pil`（基础）→ `ipq5018-q6-mpd`（qcn6122.dtsi 覆盖） | `qcom,ipq5018-q6-mpd` ✅ |
| `reg` | `0xcd00000 0x10000` | `0xcd00000 0x10000` ✅ |
| `firmware-name` | `IPQ5018/hw1.0/q6_fw.mdt`, `IPQ5018/hw1.0/m3_fw.mdt`, `QCN6122/hw1.0/m3_fw.mdt` | **完全相同** ✅ |
| `memory-region` | `<&q6_region>` | `phandle 0x31` = `wcss@4b000000` ✅ |
| `clocks` / `clock-names` | sleep / interconnect | 相同 ✅ |
| `boot-args` | 补丁里无 | **`<1 4 3 15 0 0 2 4 2 27 0 0>`**（48 字节） |
| `pd-1/2/3` smem-states | 8/9/10 · 16/17/18 · 24/25/26 | **完全相同** ✅ |
| `pd-1/2/3` firmware-name | 全部 `IPQ5018/hw1.0/q6_fw.mdt` | 相同 ✅ |

**`boot-args` 是 S7 独有、上游没有的项**，值与外部证据完全一致：

```
外部证据 ipq5018-re700x.dts：boot-args = <1 4 3 15 0 0 2 4 2 27 0 0>
S7 实际 DTB：            0x01 0x04 0x03 0x0f 0x00 0x00 0x02 0x04 0x02 0x1b 0x00 0x00
                         =  <1    4    3    15   0    0    2    4    2    27   0    0>   ✅ 一致
```

格式（RE700X 源里已确认）：**每射频 6 个 u32 = `<PCIE-idx, length, userPD-id, reset-gpio, resv, resv>`**
- 第 1 组 `<1 4 3 15 0 0>`：QCN6122（PCIe 实例 1），userPD **3**，reset-gpio **15**
- 第 2 组 `<2 4 2 27 0 0>`：IPQ5018 内置 2.4G，userPD **2**，reset-gpio **27**

⇒ **必须原样保留。**

---

## 3. 三个 Wi-Fi 节点的实测值（S7 实际 DTB）

### 3.1 `wifi@c000000`（2.4G，IPQ5018 内置）

```dts
compatible = "qcom,ipq5018-wifi";
reg = <0xc000000 0x1000000>;
status = "okay";
qcom,rproc = <&q6_wcss_pd1>;                 /* phandle 0x2e */
qcom,ath11k-fw-memory-mode = <2>;
qcom,ath11k-calibration-variant = "TP-Link-WTA301";
qcom,bdf-addr = <0x4C400000>;
```

### 3.2 `wifi@b00a040`（5G，QCN6122 #1）—— 唯一起作用的 5G

```dts
compatible = "qcom,qcn6122-wifi";
reg = <0xb00a040 0x0>;
status = "okay";
qcom,rproc = <&q6_wcss_pd2>;                 /* phandle 0x34 */
qcom,userpd-subsys-name = "q6v5_wcss_userpd2";
qcom,ath11k-fw-memory-mode = <2>;
qcom,ath11k-calibration-variant = "TP-Link-WTA301";
qcom,bdf-addr = <0x4D300000>;
qcom,m3-dump-addr = <0x4E200000>;
```

**注意 `qcom,userpd-subsys-name = "q6v5_wcss_userpd2"`** —— 上游 7 个同硬件板的
`ipq5018-qcn6122.dtsi` 里**没有这个属性**。这是 S7 独有。

### 3.3 `wifi@b00b040`（QCN6122 #2）

```dts
status = "disabled";    /* 本板只有一颗 QCN6122 */
```

⇒ 与上游 dtsi 的默认（`disabled`）一致，无需改动。

---

## 4. 与 7 个同硬件板的对比（为什么我们的值都不一样）

| 板 | fw-mode (2.4G/5G) | 2.4G bdf | 5G bdf | m3-dump | wcss 区 | wifi 状态 |
|---|---|---|---|---|---|---|
| gl-b3000 | -/<1> | 0x4C400000 | 0x4D100000 | 0x4DF00000 | 48 MiB | okay/okay |
| mx2000 | -/<1> | 0x4C400000 | 0x4D100000 | 0x4DF00000 | 48 MiB | okay/okay |
| scr50axe | -/<1> | 0x4C400000 | 0x4D100000 | 0x4DF00000 | 48 MiB | okay/okay |
| wn-dax3000gr | -/<2> | 0x4C400000 | 0x4D100000 | 0x4DF00000 | 48 MiB | okay/okay |
| wrc-x3000gs2 | -/<2> | 0x4C400000 | 0x4D100000 | 0x4DF00000 | 48 MiB | **disabled** |
| pz-l8 / mr3000d-ci / mx6200 | 未显式 | — | 0x4D100000 | — /0x4DF00000 | 48 MiB | 部分未显式 |
| **WTA301（我们）** | **2/2** | **0x4C400000** | **0x4D300000** | **0x4E200000** | **52 MiB** | **okay/okay** |

**共同点**：2.4G `bdf-addr` 全是 `0x4C400000`，`fw-memory-mode` 只用 1 或 2。
**我们独有的**：5G bdf 偏移 +0x200000、m3-dump 偏移 +0x300000、wcss 区 +4 MiB、
`fw-memory-mode=2`（两个射频都用 2）。

⇒ **这些偏移是 TP-Link 在 QSDK 里的自定义保留布局**，与上游厂商无关。
⇒ **不能照抄上游任何一块板的值**，必须用 S7 实测值。

### 4.1 `fw-memory-mode` 的语义与我们的选择

| 值 | 含义（ath11k `hal.c` / `qmi.c`） | 谁用 |
|---|---|---|
| 1 | 固件在 host 内存里分配 ring/缓冲（**吃 host RAM 少，固件吃得多**） | gl-b3000 / mx2000 / scr50axe |
| 2 | 固件自己管内存（`HAL_FW_MEM_MODE_LEGACY`/`HYBRID` 分支），host 只留最小 ring | wn-dax3000gr / wrc-x3000gs2 / **我们** |
| 3 | 更低内存（部分板用） | 无 |

`mode 2` 是**最省 host 内存**的档，`wn-dax3000gr` 同为 256 MiB 也用 2。
⇒ **R1（ath11k OOM）在 mode 2 下已被 S7 实证无 OOM**（`available 63940 KB`，见
`evidence/s7-boot-mem.txt`）。25.12.6 迁移**沿用 mode 2，不加任何低内存 ring 补丁**。

---

## 5. 迁移动作清单（M07）

| # | 动作 | 依据 |
|---|---|---|
| 1 | `/memory@40000000` 写死 `<0x0 0x40000000 0x0 0x10000000>` | §1，不依赖 u-boot fixup |
| 2 | `tz@4ac00000` 用 **4 MiB**，不用上游的 2 MiB | §2.1，危险项 |
| 3 | 保留 `tz_apps@4a400000` 4 MiB | S7 实测 |
| 4 | `wcss@4b000000` 用 **0x3400000**，不用上游的 0x3000000 | §2.2 |
| 5 | `remoteproc@cd00000` 的 `boot-args = <1 4 3 15 0 0 2 4 2 27 0 0>` **必须写** | §2.3 |
| 6 | `wifi@c000000`：`bdf-addr = <0x4C400000>`，`fw-memory-mode = <2>`，`calibration-variant = "TP-Link-WTA301"` | §3.1 |
| 7 | `wifi@b00a040`：`bdf-addr = <0x4D300000>`，`m3-dump-addr = <0x4E200000>`，`fw-memory-mode = <2>`，`userpd-subsys-name = "q6v5_wcss_userpd2"` | §3.2 |
| 8 | `wifi@b00b040` 保持 `disabled` | §3.3 |
| 9 | 不加 `nss@40000000` / `dma_pool1` / `qcn9000_pcie0` / `bt` / `m3_dump@4c700000` / `q6_etr_dump` | §2.1 表 |
| 10 | 不加任何 low-memory ring 补丁（6.12 上游也没有） | §4.1 |

---

## 6. P4 上电必测（M07 部分）

| # | 命令 | 通过判据 |
|---|---|---|
| 1 | `dmesg \| grep -i "Memory:"` | `Memory: 17xxxxK/262144K available`（≈173 MiB） |
| 2 | `free -k` | total ≈ 177,000 KB |
| 3 | `cat /proc/iomem \| grep -iE "reserved\|wcss"` | 能看到 0x4b000000 起被保留 |
| 4 | `dmesg \| grep -i "remoteproc"` | `q6v5_wcss` 起来了，无 `memory-region` 错误 |
| 5 | `dmesg \| grep -i "ath11k.*fw_mem_mode\|fw-memory"` | 报 mode 2 |
| 6 | `cat /sys/class/ieee80211/*/device/uevent` 或 `iw phy \| grep -c Wiphy` | ≥2（2.4G + 5G） |
| 7 | 30 分钟 `free` 采样 | available 不低于 30,000 KB，无 OOM killer 记录 |
