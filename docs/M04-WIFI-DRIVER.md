# M04 Wi-Fi 驱动栈（ath11k / mac80211 backports）

**结论：25.12.6 的 ath11k 补丁集开箱即用，涵盖我们需要的全部 5 个 DT 属性。
不加不减，不改任何补丁。**

---

## 1. 最关键的差异：backports 版本不同

| | S7（snapshot r37669） | 25.12.6（发布版） |
|---|---|---|
| 内核 | 6.18.55 | **6.12.112** |
| mac80211 来源 | **backports-7.2** | **backports-6.18.55** |
| `PKG_SOURCE_VERSION`（S7 树） | `7.2` | — |
| `dl/` 里的 tarball | `backports-7.2.tar.zst`（8,346,980 B） | `backports-6.18.55.tar.zst`（sha256 `ca3666d1…`） |
| ath11k 补丁数 | **25** | **19** |

**两个维度同时回退**：内核 6.18.55 → 6.12.112，无线栈 backports 7.2 → 6.18.55。
两者方向一致（都是更旧的稳定版），但 **backports 与内核版本号无关** ——
25.12.6 用 6.18.55 的 backports 跑在 6.12.112 内核上，这是 OpenWrt 的常规做法。

⇒ 迁移后 ath11k 的行为由 **backports-6.18.55** 决定，不是由内核版本决定。

---

## 2. 补丁集对照

### 2.1 名称层面的关系

25.12.6 的 19 个补丁，**全部**在 S7 树里有同名文件（19 ⊂ 25）。
S7 独有 6 个：

| S7 独有补丁 | 内容 | 25.12.6 有？ |
|---|---|---|
| `949-wifi-ath11k-fix-monitor-rx-pktlen` | 修 monitor 模式 rx pktlen | ❌ |
| `950-wifi-ath11k-implement-CE-interrupt-enable-disable-for-AHB` | AHB 的 CE 中断开关 | ❌ |
| `951-wifi-ath11k-disable-interrupts-during-firmware-crash-recovery` | 固件崩溃恢复期关中断 | ❌ |
| `952-wifi-ath11k-support-calibration-data-from-NVMEM` | 从 NVMEM 取 cal | ❌ |
| `953-wifi-ath11k-support-ipq9574` | 加 IPQ9574 支持（**与本板无关**） | ❌ |
| `960-ath11k-lowmem-rings` | DP ring 缩小 | ❌ |

### 2.2 ★ 决定性证据：960 lowmem 补丁从未生效

这是本轮推翻旧结论的关键。**三条独立证据**：

1. **补丁文件 mtime**：`960-ath11k-lowmem-rings.patch` = `2026-11-04 16:34:10`
2. **内核构建产物 mtime**：`vmlinux` / `arch/arm64/boot/Image` = `2026-11-04 15:50`
   ⇒ 补丁写于构建**之后** 44 分钟
3. **构建树里已打补丁的源码**（`build_dir/.../linux-6.18.55/drivers/net/wireless/ath/ath11k/dp.h`）实测：

```
#define DP_TX_COMP_RING_SIZE		32768      ← 默认值，未缩到 8192
#define DP_RXDMA_BUF_RING_SIZE		4096       ← 默认值，未缩到 1024
#define DP_RXDMA_MON_STATUS_RING_SIZE	1024   ← 默认值，未缩到 512
#define DP_RXDMA_MONITOR_BUF_RING_SIZE	4096   ← 默认值，未缩到 128
#define DP_RXDMA_MONITOR_DST_RING_SIZE	2048   ← 默认值，未缩到 128
```

⇒ **S7 是在「上游默认 ring 尺寸」下跑通双射频、无 OOM 的。**
⇒ **25.12.6 不需要任何 low-memory ring 补丁。R1 关闭。**

（同时被这组证据推翻的还有一条：`952-nvmemnvmem-caldata` 也未生效 —— S7 根本不是靠 NVMEM 取 cal，
而是靠 `board-2.bin` 文件路径，见 `M12-FIRMWARE-BDF.md`。）

### 2.3 共享 19 个补丁的正文有 diff，但只是行号

19 个共享补丁中 17 个 `cmp` 不一致。抽查 `903`（fw-memory-mode via DT）：

```
25c25  < @@ -38,7 +38,7 @@      > @@ -39,7 +39,7 @@
34c34  < @@ -2605,7 +2605,8 @@   > @@ -2576,7 +2576,8 @@
44c44  < @@ -2621,7 +2622,31 @@ > @@ -2592,7 +2593,31 @@
```

差异**全部在 hunk 头的行号**，正文一字不差。原因：backports-7.2 与 backports-6.18.55 的
`core.c` 基线行数不同（上游在两版之间加了代码）。
⇒ 迁移时**直接使用 25.12.6 自带的补丁文件**，不搬 S7 的。

---

## 3. 25.12.6 的补丁集覆盖了我们需要的全部 DT 属性

对 `package/kernel/mac80211/patches/ath11k/*.patch` 全量 grep `^+` 行里的 `"qcom,…"` 字面量：

| DT 属性 | 出现在几个补丁 | 由谁读 | 我们需要它吗 |
|---|---|---|---|
| `qcom,bdf-addr` | 2（`qmi.c` 两处） | `201` | ✅ 必须（0x4C400000 / 0x4D300000） |
| `qcom,caldb-addr` | 1 | `201` | ⚪ 不用（走 board-2.bin 路径，见 M12） |
| `qcom,m3-dump-addr` | 1 | `931` | ✅ 必须（0x4E200000） |
| `qcom,ath11k-fw-memory-mode` | 1 | `903` | ✅ 必须（=2） |
| `qcom,userpd-subsys-name` | 1 | `924`（`ahb.c`） | ✅ 必须（`q6v5_wcss_userpd2`） |
| `qcom,qcn6122-wifi`（compatible） | 1 | `925` | ✅ 必须（5G 节点） |

**六项全有。** ⇒ M07 里列的那张 Wi-Fi DTS 属性表，可以**原样搬到 25.12.6**，一个属性都不用改。

### 3.1 `qcom,bdf-addr` 的读取位置（`201` 补丁原文）

```c
 case BDF_MEM_REGION_TYPE:
-    ab->qmi.target_mem[idx].paddr = ab->hw_params.bdf_addr;
+    if (of_property_read_u32(dev->of_node, "qcom,bdf-addr", &addr))
+        addr = ab->hw_params.bdf_addr;
+    ab->qmi.target_mem[idx].paddr = addr;
```

以及固定 BDF 地址路径：
```c
 if (ab->hw_params.fixed_bdf_addr) {
-    bdf_addr = ioremap(ab->hw_params.bdf_addr, ab->hw_params.fw.board_size);
+    if (of_property_read_u32(ab->dev->of_node, "qcom,bdf-addr", &addr))
+        addr = ab->hw_params.bdf_addr;
+    bdf_addr = ioremap(addr, ab->hw_params.fw.board_size);
```

⇒ 两个入口都认 `qcom,bdf-addr`，DTS 一旦写上就优先于 hw_params 默认值。

### 3.2 `qcom,userpd-subsys-name` 的作用（`924` 补丁原文）

```c
static int ath11k_get_userpd_id(struct device *dev)
{
    ret = of_property_read_string(dev->of_node, "qcom,userpd-subsys-name", &subsys_name);
    if (ret) return 0;
    if (strcmp(subsys_name, "q6v5_wcss_userpd2") == 0)  userpd_id = ATH11K_QCN6122_USERPD_2;
    else if (strcmp(subsys_name, "q6v5_wcss_userpd3") == 0) userpd_id = ATH11K_QCN6122_USERPD_3;
    dev_info(dev, "Multipd architecture - userpd: %d\n", userpd_id + 1);
    return userpd_id;
}
...
    ab->qmi.service_ins_id = ab->hw_params.qmi_service_ins_id;
    ab->qmi.service_ins_id += ab->userpd_id;      /* ← 关键：QMI 服务实例号偏移 */
```

**作用**：QCN6122 与 IPQ5018 共用同一套 QMI 服务号，靠 `service_ins_id += userpd_id`
区分「第几个 PD」。本板 5G 是 **userPD 2**（DTS 里写 `q6v5_wcss_userpd2`）⇒ +2。

这解释了 M07 里 `boot-args` 第 1 组 `<1 4 3 15 …>` 的 `userPD-id = 3`
（QCN6122 在 MPD 里的 PD 编号 3）与 DTS 字符串名 `userpd2`（数学上是"第 2 个 QCN6122 位"）
为何数值不同 —— **两个编号体系，不是矛盾**。

---

## 4. 诚实边界：S7 的 ko 与当前树不一致

| 产物 | md5 | 说明 |
|---|---|---|
| `work/images/…-S7` 里 `/lib/modules/6.18.55/ath11k.ko` | `6ad6c24e0cd3c4d4c365d57664e04bf2` | 804,736 B（真机在跑的那个） |
| `nss-edma/staging_dir/…/6.18.55/ath11k.ko` | `84a8d56b01cbf69d2c58dfe9f24ea172` | 828,392 B（当前树编出） |

**二进制差异印证**：
```
strings S7-ko | grep -c userpd                        → 0
strings S7-ko | grep -c Multipd                       → 0
strings S7-ko | grep -c "q6v5_wcss_userpd2"           → 0
```

⇒ **S7 真机在跑的 ath11k.ko 里根本没有 924 multipd 补丁。**
⇒ 那个 `qcom,userpd-subsys-name = "q6v5_wcss_userpd2"` 属性在 S7 上**是死属性**（无人读取，
被内核静默忽略），5G 靠 `qmi_service_ins_id` 的 hw_params 默认值走通了。

**这为什么重要**：
- 25.12.6 **有** 924 ⇒ 属性会真正生效 ⇒ `service_ins_id` 会 +2
- 这是从 S7 到 25.12.6 的**行为变化**，不是「保持原样」
- 若 25.12.6 上 5G 起不来，第一嫌疑就是这里

⇒ 记入风险 **R13**（新增）：迁移引入 924 multipd 生效，5G QMI 实例号从「默认」变为「+2」。

---

## 5. 迁移动作清单（M04）

| # | 动作 | 依据 |
|---|---|---|
| 1 | **使用 25.12.6 自带的 19 个 ath11k 补丁**，不搬 S7 的 | §2.3 正文相同，行号随基线 |
| 2 | **不加** `960-ath11k-lowmem-rings` | §2.2 证据链，S7 在默认 ring 下无 OOM |
| 3 | **不加** `952-NVMEM-caldata` | 25.12.6 无此补丁；我们走 board-2.bin |
| 4 | **不加** `949/950/951` | S7 未生效，无双射频必要性证据 |
| 5 | DTS 的 6 个 Wi-Fi 属性原样搬（见 M07 §5） | §3 六项全有支持 |
| 6 | `kmod-ath11k` / `kmod-ath11k-ahb` 编进 25.12.6 | 与 S7 同 |
| 7 | vermagic 会从 `6.18.55` 变 `6.12.112`，所有 kmod 重编 | 必然 |

---

## 6. P5 分步验证判据（M04 部分）

| 步骤 | 命令 | 通过判据 |
|---|---|---|
| 1 | `dmesg \| grep -c "failed to fetch board data"` | **0** |
| 2 | `dmesg \| grep -i "Multipd"` | 出现 `Multipd architecture - userpd: 2`（**S7 没有这条**，R13 判据） |
| 3 | `dmesg \| grep -i "q6v5_wcss\|remoteproc"` | 无 `failed to boot the remote processor Q6` |
| 4 | `dmesg \| grep "fw_build_id"` | `WLAN.HK.2.7.0.1-01744-QCAHKSWPL_SILICONZ-1`（与 S7 相同） |
| 5 | `ls /sys/class/ieee80211/` | `phy0 phy1` |
| 6 | `iwinfo \| grep ESSID` | 至少 2 个 radio |
| 7 | `free -k` 30min 采样 | available 稳定，无 OOM killer |
