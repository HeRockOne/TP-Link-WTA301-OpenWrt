# M11 温度 / 电源 / 稳压器

**一句话结论：零动作。** thermal-zones 三源逐字一致；本板**没有 PMIC、没有任何软件可控稳压器**；
tsens 驱动支持在 25.12.6 里齐全（补丁 0053/0054/0180）；cpufreq 走 `cpufreq-dt` + 共享 OPP（1.008 GHz @ 1.1 V），三方一致。

---

## 1. thermal-zones 三源逐字对照

| 来源 | 文件 |
|---|---|
| 25.12.6（6.12.112 + 全部 102 补丁） | `/tmp/dtsi_after.dtsi` 的 `thermal-zones {}` 块 |
| S7 实测（跑在板上的 DT） | `patches/s7-actual-dtb.dts:1123-1189` |

| zone | 传感器 index | trips | 25.12.6 | S7 |
|---|---|---|---|---|
| `cpu-thermal` | `&tsens 2` | critical 120000 m°C / hyst 1000 · **passive 100000 m°C**（`cooling-maps/map0` → `<&cpu0 NO_LIMIT NO_LIMIT>, <&cpu1 …>`） | 有 | `0x1d4c0`/`0x186a0`/`0x3e8` = 同值 ✅ |
| `gephy-thermal` | `&tsens 4` | critical 120000 | 有 | 同 ✅ |
| `top-glue-thermal` | `&tsens 3` | critical 120000 | 有 | 同 ✅ |
| `ubi32-thermal` | `&tsens 1` | critical 120000 | 有 | 同 ✅ |

⇒ **不需要板级覆盖任何 thermal 参数**。（`0x1d4c0`=120000，`0x186a0`=100000，`0x3e8`=1000，dtc 十六进制显示而以。）

### tsens 驱动支持链（25.12.6 已具备）

| 补丁 | 作用 |
|---|---|
| `patches-6.12/0053-v6.16-thermal-drivers-qcom-tsens-Add-support-for-IPQ5018-t.patch` | 驱动内加 `qcom,ipq5018-tsens` |
| `patches-6.12/0054-v6.18-arm64-dts-qcom-ipq5018-Add-tsens-node.patch` | dtsi 里加 `tsens: thermal-sensor@4a9000` |
| `patches-6.12/0050-v6.15-thermal-drivers-tsens-Add-TSENS-enable-and-calibrati.patch` | 使能/校准序列 |
| `patches-6.12/0180-arm64-dts-qcom-ipq5018-Remove-tsens-v1-fallback-compatible.patch` | 去掉 `"qcom,tsens-v1"` 兜底 ⇒ dtsi 只剩 `compatible = "qcom,ipq5018-tsens"` |

**这是 6.18→6.12 的唯一天差**：6.18.55 的 dtsi 还写着 `"qcom,ipq5018-tsens", "qcom,tsens-v1"`；
25.12.6 写的是单 compatible。我们照 25.12.6 写（驱动有精确匹配项，不需要兜底）。
`CONFIG_QCOM_TSENS=y`（`target/linux/qualcommax/config-6.12`）。

---

## 2. CPU 频率 / OPP（冷却设备来源）

两个 `cpu@` 节点都有 `operating-points-v2 = <&cpu_opp_table>` 与 `#cooling-cells = <2>`；
`cpu_opp_table` 在**两版里只有一条**：

```dts
cpu_opp_table: opp-table-cpu {
    compatible = "operating-points-v2";
    opp-shared;
    opp-1008000000 { opp-hz = /bits/ 64 <1008000000>; opp-microvolt = <1100000>; };
};
```
S7 实测解码：`opp-hz = <0x00 0x3c14dc00>` = 1008000000，`opp-microvolt = 0x10c8e0` = 1100000 ✅ 一致。

config：`CONFIG_CPUFREQ_DT=y` · `CONFIG_CPUFREQ_DT_PLATDEV=y` · `CONFIG_ARM_QCOM_CPUFREQ_NVMEM=y` ·
`# CONFIG_ARM_QCOM_CPUFREQ_HW is not set`。⇒ `cpufreq-dt` 生效，policy 由 OPP 表决定，无需板级动作。

> 注意：只有 1.008 GHz 一档 ⇒ **`cpu-passive` 的 cooling-map 实际上无法降频**（只有一档）。
> S7 也是同一张表，行为一致。这是上游 dtsi 的既定状态，不是我们的问题。

---

## 3. 电源 / 稳压器：本板完全没有

- **无 PMIC**：IPQ5018 的这些板子（含 WTA301）用固定 DC-DC，全部常开，**没有任何 `regulator*` / `*-supply` 节点**。
  验证：`grep -inE "regulator|ldo|vreg|voltage|supply"` 扫三份原厂 DTB + S7 实际 DTB，
  只命中两类无关项：
  1. `patches/factory/fdt_mp0*.dts:618-621`（SDCC 节点内）
     `qcom,vdd-voltage-level = <0x2c4020 0x2c4020>` = 2,900,000 µV = 2.9 V
     `qcom,vdd-io-voltage-level = <0x1b7740 0x1b7740>` = 1,800,000 µV = 1.8 V
     —— 这是 SD/eMMC 的电压等级属性，且 **SDCC 节点在本板是 disabled**（M09）⇒ 无关。
  2. `reset-names` 里那一长串 `gcc_*_bcr`，其中含 `gcc_cmn_ldo_bcr`，只是复位名字符串，不是稳压器。
- **`TCSR ETH_LDO_RDY`**（M03 提到的 `mdio@88000` 存在的理由）：那是 GEPHY 的 LDO 就绪位，
  由 TCSR syscon 在 mdio 驱动 probe 时置位，不经 regulator 框架。M03 已处理。

⇒ **动作：什么都不写。**

---

## 4. 与 E 系列外部证据的对应

- 上游 `ipq5018-*.dts` 全部板子都没有 regulator 节点（`grep -rn regulator files/arch/arm64/boot/dts/qcom/ipq5018-*.dts` 为空），
  与本次结论一致：这是 SoC/参考设计层面的固定供电。
- thermal 参数在上游所有板子里也都不覆盖（除 `ax850.dts:372 &tsens { status="okay"; }` 一句，
  因为 6.12 dtsi 的 tsens 默认就是 okay，写不写等价）。

---

## 5. 未验证项

| 项 | 级别 | 说明 |
|---|---|---|
| `cpu-passive` 冷却地图只有一档频率 | 🟡 已知 | 上游 dtsi 只有 1.008 GHz 单 OPP，`cooling-device` 实际无法降频。S7 同表，行为不变；真要降频需加 OPP 档位（超出迁移范围） |
| 板载实际温度读数 | ⬜ 未验证 | 迁移后可在 P4 用 `cat /sys/class/thermal/thermal_zone*/temp` 核对 4 个 zone 是否有值 |
| `sleep_clk` 无频率 ⇒ `qcom-wdt` 的 rate=0 | 🟡 见 M09 | 温度/电源无关，但同属「上游遗留空白」，已在 M09 记录 |
