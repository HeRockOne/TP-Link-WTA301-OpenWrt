# M03 以太网 / MDIO / PHY / 交换机

**结论：这是全板差异最大的模块。原厂是 QSDK ESS 框架驱动交换机；S7 用上游 DSA。
两者拓扑完全不同，不能参照原厂 DTB。**

---

## 1. 三方对照

| 项 | 原厂 DTB | S7 实际 DTB | 25.12.6 上游同硬件板 |
|---|---|---|---|
| 交换机驱动框架 | **QSDK ESS/SSDK**（`qcom,ess-switch-ipq50xx` @ `0x39c00000`，`local bus`） | **mainline DSA**（`realtek,rtl8365mb` @ MDIO 0x1d） | QCA8337 DSA（`qca8k`） |
| 交换机芯片 | **RTL8367S**（原厂 dmesg：`C mapper` / `Chip version 0xee`） | 同（`rtl8365mb`） | **QCA8337** |
| 交换机访问总线 | 内存映射 `0x39c00000`（`local bus`） | **MDIO**（`mdio@90000`，地址 `0x1d`） | MDIO |
| gmac0 `0x39c00000` | 被 ESS 占用 | `qcom,ipq5018-gmac`，`phy-mode=sgmii`，`phy-handle=mdio@88000/phy@7`，**`status="disabled"`** | 视板而定 |
| gmac1 `0x39d00000` | — | `qcom,ipq5018-gmac`，`phy-mode=sgmii`，`pcs-handle=ethernet-pcs@98000`，**`status="okay"`**，`fixed-link{speed=1000,full-duplex}` | 视板而定 |
| PCS | `ess-uniphy@98000`（`qcom,ess-uniphy`，`local bus`） | `ethernet-pcs@98000`（`qcom,ipq5018-uniphy`），`#pcs-cells`，`assigned-clock-rates=0x17d7840`(=25 MHz) | 同代号 |
| mdio0 `0x88000` | `mdio@88000`，phy@0 | `mdio@88000`（`qcom,ipq5018-mdio`, `qcom,ipq...`），**含 `ethernet-phy@7`** | 视板 |
| mdio1 `0x90000` | `mdio@90000`，phy@0..3 | `mdio@90000`（`qcom,ipq5018-mdio`），pinctrl-0 | 视板 |
| 端口命名 | 无（SSDK 内部） | `lan1`…`lan5`（port@0..4）+ `cpu`（port@6） | 视板 |
| 上行 | SGMII（`mac mode = 0xc`） | port@6 `sgmii` + `fixed-link 1000/full`，`ethernet = <gmac1>` | SerDes→QCA8337 |

**原厂 dmesg 原文**（`work/docs/final2/17-真机实测-芯片与取root原理.md`）：

```
[    5.831484] ssdk_switch_device_num_init[1183]:INFO:ess-switch dts node number: 1
[    5.837989] ssdk_dt_parse_access_mode[880]:INFO:switch_access_mode: local bus
[    5.843929] ssdk_dt_parse_access_mode[893]:INFO:switchreg_base_addr: 0x39c00000
[    5.858271] ssdk_dt_parse_mac_mode[300]:INFO:mac mode = 0xc
[    9.451210] ssdk_switch_register[1710]:INFO:Chip version 0xee
[   10.085274] dal_rtl8367c_mapper[617]:C mapper
[   10.798209] RTL8367S: Enhance anti-jamming capability.
```

---

## 2. S7 的完整拓扑（从实际 DTB 反编译，已确证）

```
                    ┌──────────────────────────────┐
   IPQ5018 SoC      │  gmac1  ethernet@39d00000    │  status = okay
                    │  phy-mode = "sgmii"          │
                    │  pcs-handle → ethernet-pcs@98000 (uniphy)
                    │  fixed-link { 1000, full }   │
                    └───────────┬──────────────────┘
                                │ SGMII
                    ┌───────────┴──────────────────┐
                    │  RTL8367S (rtl8365mb)        │  MDIO addr 0x1d
                    │  on mdio@90000               │
                    │                              │
      internal MDIO │  port@0 lan1 ─ phy@0         │
        (switch     │  port@1 lan2 ─ phy@1         │
         internal)  │  port@2 lan3 ─ phy@2         │
                    │  port@3 lan4 ─ phy@3         │
                    │  port@4 lan5 ─ phy@4         │
                    │  port@6 cpu  ─ sgmii ────────┼──→ gmac1
                    └──────────────────────────────┘

                    ┌──────────────────────────────┐
                    │  gmac0  ethernet@39c00000    │  status = disabled
                    │  phy-handle → mdio@88000/phy@7│
                    └──────────────────────────────┘
                       phy@7 = qcom,ipq5018 内置 GEPHY
                       compatible = "ethernet-phy-id004d.d0c0"
```

### 2.1 `004d.d0c0` 是什么 —— 已查实

`drivers/net/phy/qcom/at803x.c:97`：

```c
#define IPQ5018_PHY_ID				0x004dd0c0
```

⇒ 是 **IPQ5018 SoC 内置的 1G GEPHY**，**不是**外部 2.5G PHY。
（旧笔记里的「2.5G HSGMII → gmac1」需要按此修正：gmac1 走的是 port@6 的 SGMII，
`fixed-link` 明写 `speed = 1000`，即 **1 Gbps**，不是 2.5 G。）

> **待核（M03 遗留）**：u-boot 字符串里有 `Set RTL8367 SGMII 2.5Gbps`。
> 那说明 u-boot 把 RTL8367 的 SGMII 配置在 2.5G 档，但 Linux 侧 `fixed-link` 写的是 1000。
> 两者是否冲突、实际协商速率是多少，**P4 上电后必须实测**（`ethtool`/`ip -s link`）。

---

## 3. 关键教训（外部证据，已入档 `docs/03-EXTERNAL-EVIDENCE.md` E-6）

### 3.1 mainline 的 `rtl8365mb` 只按 `(chip_id, chip_ver)` 精确匹配

`drivers/net/dsa/realtek/rtl8365mb_main.c` 表里 `0x6367` 四个版本：

| 名字 | chip_id | chip_ver |
|---|---|---|
| RTL8365MB-VC | 0x6367 | 0x0040 |
| **RTL8367S** | 0x6367 | **0x00A0** |
| （还有两个） | 0x6367 | … |

**原厂实测 `Chip version 0xee`** —— 但这是 QSDK SSDK 的版本寄存器读法，与 mainline 的
`chip_ver` 不一定是同一个东西。**S7 能起来说明匹配上了**，所以以 S7 的实测为准。

### 3.2 `mdio0` 必须 okay —— 不，本板不适用

RE700X 的教训是「`mdio0` 关掉会导致 MDIO1 上 PHY 不应答」，因为 `mdio0` probe 时设
`TCSR ETH_LDO_RDY`（告诉 CMN PLL 以太网 LDO 已上电）。

**本板 S7 的实际写法是**：`mdio@88000` **`status = "okay"`** ✅（与 RE700X 教训一致），
但挂在它下面的 `ethernet-phy@7` 所在的 gmac0 是 `disabled`。
⇒ 也就是说我们把「mdio0 开、gmac0 关」这个组合保留了下来 —— **这正好是 RE700X 教训推荐的写法**。

### 3.3 vendor DTB 的 GPIO 分配不可信

RE700X 的例子里，vendor DTB 声称 gpio33 是 PHY reset，实际是 2.4G LED。
本板也必须 GPIO 扫描实测（M5 一起做）。

---

## 4. 对 25.12.6 迁移的裁决

**决定：沿用 S7 的 DSA 写法，不改拓扑。**

要动的地方：

```dts
/* 1. uniphy / PCS —— 从 ipq5018.dtsi 继承，只确认 status */
&uniphy0 { /* pcs for gmac1 */ status = "okay"; };

/* 2. gmac1：SGMII + fixed-link 1000 */
&gmac1 {
	status = "okay";
	phy-mode = "sgmii";
	pcs-handle = <&uniphy0>;
	fixed-link { speed = <1000>; full-duplex; };
};

/* 3. gmac0 + 内置 GEPHY：gmac0 关、mdio0 开（为 TCSR ETH_LDO_RDY） */
&gmac0 { status = "disabled"; phy-handle = <&gephy>; };
&mdio0 { status = "okay"; };

/* 4. mdio1 上挂 RTL8367S */
&mdio1 {
	status = "okay";
	pinctrl-0 = <&mdio1_pins>;
	pinctrl-names = "default";

	switch@1d {
		compatible = "realtek,rtl8365mb";
		reg = <0x1d>;
		mdio {
			#address-cells = <1>; #size-cells = <0>;
			phy0: ethernet-phy@0 { reg = <0>; };   /* … 到 @4 */
		};
		ports {
			#address-cells = <1>; #size-cells = <0>;
			port@0 { reg=<0>; label="lan1"; phy-handle=<&phy0>; };
			/* … port@1..4 */
			port@6 {
				reg = <6>; label = "cpu";
				phy-mode = "sgmii";
				ethernet = <&gmac1>;
				fixed-link { speed=<1000>; full-duplex; };
			};
		};
	};
};
```

**必须核对的 6.12 差异**：

| # | 核对项 | 怎么核 |
|---|---|---|
| a | 6.12 的 `rtl8365mb` 是否仍支持 `mdio` 子节点写内建 PHY | 读 `drivers/net/dsa/realtek/rtl8365mb_main.c` |
| b | `qcom,ipq5018-mdio` 在 6.12 的 `ipq5018.dtsi` label 名（`mdio0`/`mdio1`?） | 读 dtsi |
| c | `pcs-handle` / `#pcs-cells` 属性名在 6.12 是否已换成 phylink PCS 框架新写法 | 读 `ethernet-pcs@98000` 驱动 |
| d | `fixed-link` 写法（`speed`/`full-duplex` 位置） | 对照 6.12 其它板 |
| e | `ethernet-pcs@98000` 的 `assigned-clock-rates = 0x17d7840`（25 MHz）是否仍需 | 对照 uniphy 驱动 |
| f | RTL8367S 的 `chip_ver` 匹配是否符合本板 | P4 上电看 `dmesg` |

---

## 5. P4 上电必测清单（M03 部分）

| # | 测什么 | 通过判据 |
|---|---|---|
| 1 | `dmesg \| grep -i rtl8365` | 出现 switch 探测成功，无 `unsupported chip` |
| 2 | `ip link` | 出现 `lan1`…`lan5` 与 `cpu`（或 `eth0`/`eth1`，视 DSA 命名） |
| 3 | `ip -d link show` 看 DSA 端口 | 每个 lanN 都 `master` 到交换机 |
| 4 | 插网线到每个口 | `ethtool lanN` 显示 `Link detected: yes` + 速率 |
| 5 | 实际速率 | **确认是 1000 还是 2500**（与 u-boot 的 2.5G 声明对账） |
| 6 | `ping` 通 | — |
| 7 | `ethtool -S lan1` | 无 `rx_errors` 暴涨 |
| 8 | gmac0 状态 | `disabled`，但 `mdio@88000` okay |

---

## 6. 一句话

**原厂用 QSDK SSDK 从内存映射直接管 RTL8367S；我们用上游 DSA 从 MDIO 管。
拓扑上我们是「gmac1 → SGMII → RTL8367S port6(CPU) → 5 个内建 PHY 口」，
gmac0 与 SoC 内置 GEPHY 关掉但保留 mdio0 上电。这个写法与 RE700X 的教训一致，
迁移时原样搬过去，只按 6.12 语法校对。**
