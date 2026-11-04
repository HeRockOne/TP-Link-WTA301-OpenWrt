# M05 GPIO / LED / 按键

**结论：状态节点与 keys/leds 节点原样搬；节点名、label、aliases 一字不改。
不加 gpio26 交换机复位（主line 无消费方）；串口引脚已用原厂 DTB 双向确认。**

---

## 1. GPIO 全表（三源对照）

| GPIO | 用途 | 有效电平 | S7 实际 DTB | 原厂 mp02.1 DTB | 运行中实证 |
|---|---|---|---|---|---|
| 10 | LED `green:lan` | ACTIVE_LOW | `led-state` + `gpio-leds` | — | `/sys/kernel/debug/gpio` |
| 11 | LED `green:wan` | ACTIVE_LOW | 同上 | — | 同上 |
| 13 | LED `green:wlan2g` | ACTIVE_LOW | 同上 | — | 同上 |
| 15 | PCIe2 PERST | ACTIVE_LOW | 无（走 `boot-args` reset-gpio=15） | `pcie_x2_rp perst-gpio` | — |
| 17 | 键 `wps` | ACTIVE_LOW，`KEY_WPS_BUTTON`(529) | `button-state` + `gpio-keys` | — | 同上 |
| 19 | LED `green:system` | ACTIVE_LOW | `led-state` + `gpio-leds` | — | 同上 |
| 20 | 键 `reset` | ACTIVE_LOW，`KEY_RESTART`(408) | `button-state` + `gpio-keys` | — | 同上 |
| 26 | **RTL8367S 复位** | **ACTIVE_HIGH** | **无** ❗ | `rtl-instace switch-reset-gpio` | — |
| 27 | PCIe1 PERST | ACTIVE_LOW | 无（走 `boot-args` reset-gpio=27） | `pcie_x1_rp perst-gpio` | — |
| 28 | 串口 RX | 输入 | `serial0-state` → `blsp0_uart1` | `blsp0_uart_rx`（input-enable, bias-disable） | 双向可用 |
| 29 | 串口 TX | 输出 | 同上（合并节点） | `blsp0_uart_tx`（output-high, bias-disable） | 双向可用 |
| 31–34 | `blsp1_uart1`（未接线） | — | `uart1-state`（6.12 dtsi 自带 `uart1_pins`，**无引用**） | — | — |
| 36 | MDIO MDC → RTL8367S | — | `mdio-state` @ `mdio@90000` | — | 交换机 probe 成功 |
| 37 | MDIO MDIO → RTL8367S | — | 同上 | — | 同上 |

`gpio-ranges = <&tlmm 0 0 47>` ⇒ TLMM 共 **47** 个 pin（0–46），与 6.12 dtsi 一致。

---

## 2. ★ 串口引脚：TTL 命脉，两个源都对过了

这是本模块最要紧的一条 —— 引脚错了就没有 TTL，没有 TTL 就没有救砖路径。

| 源 | 引脚 | function | 附加 |
|---|---|---|---|
| **原厂 mp02.1** | `gpio28` (rx) / `gpio29` (tx) | `blsp0_uart1` | rx: `input-enable` + `bias-disable`；tx: `output-high` + `bias-disable`；均 `drive-strength 8` |
| **S7 实际 DTB** | `gpio28` `gpio29` | `blsp0_uart1` | 合并成一个节点：`drive-strength 8` + `bias-disable` |
| **6.12 上游 dtsi** | `gpio31–34` | `blsp1_uart1` | 那是 `uart1_pins`，指向 `serial@78af000` 的**另一种**接线，本板未用 |

- 两者都选 `gpio28/29 = blsp0_uart1`，**一致** ⇒ 引脚判定可靠。
- `serial@78af000` 在原厂与 S7 里都是 `status = "okay"`。
- S7 少了原厂的 `input-enable`(rx) / `output-high`(tx)，但**实测串口双向可用**
  （能收到 Linux shell 输出 → TX 通；能敲进命令 → RX 通）。
  ⇒ 按单一变量原则 **保持 S7 写法**，不为了"更像原厂"去改。
- ⚠ 注意：`uart1-state`(gpio31–34) 在 S7 DTB 里**没有任何节点引用**，是 dtsi 带来的死节点。
  6.12 dtsi 里叫 `uart1_pins`，新 DTS **不要**再重复定义。

---

## 3. GPIO 26（RTL8367S 复位）：原厂有，我们不加，理由如下

原厂 mp02.1 明确写了：
```dts
rtl-instace {
    compatible = "qualcomm,rtk-gsw";
    status = "ok";
    switch-reset-gpio = <&tlmm 26 GPIO_ACTIVE_HIGH>;   /* 高有效 */
};
```

但这是 **QSDK SSDK 私有驱动**（`qualcomm,rtk-gsw`）的绑定，主line 没有这个驱动。

主line 侧是否有任何层会消费子节点上的 `reset-gpios`？在 6.18.55 全树逐一 grep：

| 位置 | 结果 |
|---|---|
| `drivers/net/dsa/realtek/*.c` | 无 `reset-gpios` / `reset_gpio` |
| `net/dsa/*.c` | 无 |
| `drivers/net/mdio/of_mdio.c` | 只有总线级 `reset-delay-us` / `reset-post-delay-us`，**不解析 `reset-gpios`** |
| `drivers/net/phy/mdio_device.c` | `mdio_device_reset()` 存在，但 `mdiodev->reset_gpio` **不由 DT 填充** |
| `drivers/net/dsa/realtek/realtek-mdio.c` | probe 里完全不碰 reset |

⇒ **`reset-gpios` 写在交换机节点上是死属性，无人读取。**
⇒ 加上去只是装饰，改成"更像原厂"反而增加变量。

**S7 的实证**：不声明 gpio26，5 个口全部 probe 成功（dmesg `found an RTL8367S switch`），
v19 起长期可用。

**已知差异（诚实边界）**：Linux 侧不做主动交换机复位，状态依赖 u-boot / 上电复位。
若 P4 出现「5 口全不通且 MDIO 读不到 0x1d」，第一嫌疑是这里 —— 那时才考虑
用 `gpio-hog` 或 `gpio-line-names` + userspace 拉低再拉高来复位。

---

## 4. GPIO 冲突排查：无

对 `pinctrl-ipq5018.c` 的 `PINGROUP` 表逐个核对我们用到的 13 个 pin：

```
PINGROUP(10, blsp0_spi, blsp1_uart0, led0, gcc_plltest, qdss_tracedata_a, ...)   ← LED
PINGROUP(11, blsp0_spi, blsp1_uart0, gcc_tlmm, qdss_tracedata_a, ...)            ← LED
PINGROUP(13, blsp0_spi, blsp0_i2c, blsp1_uart0, qdss_tracedata_a, ...)           ← LED
PINGROUP(15, cri_trng1, qdss_tracedata_a, ...)                                   ← PCIe2 PERST
PINGROUP(17, pcie1_clk, btss, prng_rosc, qdss_tracedata_a, ...)                  ← WPS 键
PINGROUP(19, pcie1_wake, blsp1_spi0, blsp1_i2c0, btss, qdss_tracedata_a, ...)    ← LED
PINGROUP(20, blsp0_uart0, blsp1_spi0, blsp1_i2c0, qdss_tracedata_a, ...)         ← RESET 键
PINGROUP(26, audio_rxd, audio_pdm1, blsp2_i2c1, blsp2_spi1, blsp1_uart2, btss, ...) ← 交换机复位（未用）
PINGROUP(27, audio_txmclk, wsa_swrm, blsp2_spi, btss, qdss_tracedata_b, ...)     ← PCIe1 PERST
PINGROUP(28, audio_txbclk, wsa_swrm, blsp0_uart1, btss, qdss_tracedata_b, ...)   ← 串口 RX
PINGROUP(29, audio_txfsync, blsp0_uart1, qdss_tracedata_b, ...)                  ← 串口 TX
PINGROUP(36, mdc, qdss_tracedata_b, wsi_clk3, ...)                               ← MDC
PINGROUP(37, mdio, atest_char, qdss_tracedata_b, wsi_data3, ...)                 ← MDIO
PINGROUP(38, qdss_tracedata_b, ...)                                              ← LED 5G
```

- **`mdc` 只在 gpio36、`mdio` 只在 gpio37** ⇒ MDIO 引脚唯一可能，不存在选错的余地。
- 13 个 pin 之间无功能重叠，无「同一 pin 被两个节点抢」的情况。
- gpio 38 只支持 `qdss_tracedata_b`，做普通 GPIO 不受影响。

---

## 5. 25.12.6 侧需要什么

| 项 | 25.12.6 状态 | 动作 |
|---|---|---|
| `CONFIG_PINCTRL_IPQ5018` | 通用 `qualcommax/config-6.12` 里是 `# ... is not set`，但 **`ipq50xx/config-default:17` 是 `=y`** | **不用改** |
| `pinctrl@1000000` 节点本身 | 6.12 dtsi 与 S7 反编译值**完全一致**（`qcom,ipq5018-tlmm` / `reg 0x01000000 0x300000` / `GIC_SPI 208` level-high / `gpio-ranges 47`） | 由 dtsi 提供，不重复写 |
| `CONFIG_LEDS_GPIO` / `CONFIG_KEYBOARD_GPIO` | `=y`（gpio-keys / gpio-leds 板级通用） | 不用改 |
| LED/键 的 state 节点 | 板级，dtsi 没有 | **必须自己写**（原样搬） |

---

## 6. ★ LED 名字是用户态契约，不能改成新约定

25.12.6 的上游板子（如 gl-b3000）用的是新写法：
```dts
led_system_blue: system-blue {
    color = <LED_COLOR_ID_BLUE>;
    function = LED_FUNCTION_STATUS;
    gpios = <&tlmm 24 GPIO_ACTIVE_HIGH>;
};
```

**我们不能跟。** 因为我们的 `90_wta301`（板级 uci-defaults 脚本）里写死了名字：
```sh
ucidef_set_led_netdev "lan"   "LAN"    "green:lan"    "br-lan"     "link tx rx"
ucidef_set_led_netdev "wlan2g" "WLAN2G" "green:wlan2g" "phy0-ap0"  "link tx rx"
ucidef_set_led_netdev "wlan5g" "WLAN5G" "green:wlan5g" "phy1-ap0"  "link tx rx"
```
⇒ DTS 必须保持 `label = "green:lan"` 等**五个 label 一字不改**，否则 netdev 触发器找不到 LED，
`/sys/class/leds/` 下的名字全变，网络灯永远不亮。

**aliases 同理**：
```dts
aliases {
    serial0 = "/soc@0/serial@78af000";
    led-boot     = "/leds/led-19";
    led-failsafe = "/leds/led-19";
    led-running  = "/leds/led-19";
    led-upgrade  = "/leds/led-19";
};
```
⇒ 新 DTS 的 green:system 节点名必须仍是 **`led-19`**，否则 preinit 阶段找不到 boot LED
（不致命，只是丢失"开机灯"）。

> 注：`90_wta301` 里说明 LED 语义是 best-effort —— 原厂从用户态守护进程驱动五个灯，
> `/sys/class/leds` 从未暴露映射，所以 DTS 里的 label 是按 GPIO 顺序推断的。
> 只接入了不依赖「哪个口是 WAN」的三个（lan / wlan2g / wlan5g），`green:system` 交默认 heartbeat。

---

## 7. 迁移动作清单（M05）

| # | 动作 | 依据 |
|---|---|---|
| 1 | `button-state`（gpio17/20）+ `led-state`（gpio19/10/11/13/38）原样搬 | §1 |
| 2 | `serial0-state`（gpio28/29 blsp0_uart1）原样搬，**不加** `input-enable`/`output-high` | §2 |
| 3 | `mdio-state`（gpio36/37 mdc/mdio）原样搬，挂 `&mdio1`（`mdio@90000`） | §1 §4 |
| 4 | `keys` / `leds` 节点原样搬，**节点名 + label 一字不改** | §6 |
| 5 | `aliases` 的 `led-boot/failsafe/running/upgrade` 保留 | §6 |
| 6 | **不加** `uart1-state`（dtsi 已有 `uart1_pins`，且本板不用） | §2 |
| 7 | **不加** gpio26 `reset-gpios` | §3 |
| 8 | `90_wta301` 脚本原样搬进 25.12.6 的 `ipq50xx/base-files/etc/board.d/` | 已有资产 |

---

## 8. P4 验证判据（M05 部分）

| # | 命令 | 通过判据 |
|---|---|---|
| 1 | `ls /sys/class/leds/` | 出现 `green:system green:lan green:wan green:wlan2g green:wlan5g`（5 个，名字完全一致） |
| 2 | `cat /proc/device-tree/aliases/led-boot` | `/leds/led-19` |
| 3 | `cat /sys/kernel/debug/gpio` | gpio 10/11/13/19/38 为 out，17/20 为 in |
| 4 | 插网线 | `green:lan` 亮（netdev 触发器生效） |
| 5 | 按 WPS 键 | `evtest` 见 `KEY_WPS_BUTTON`；`logread` 见 `wps` 事件 |
| 6 | 长按 RESET | 见 `KEY_RESTART`（**先确认能 TTL 干预再测**，会触发 failsafe/重启） |
| 7 | 串口双向 | 能收启动日志 + 能敲进命令 |
| 8 | `dmesg \| grep -i "pinctrl\|pinconf"` | 无 `fail`/`error` |

---

## 9. 与原厂 DTB 的可信度说明

之前（外部证据）有一条教训：**vendor DTB 的 GPIO 分配不可信** —— RE700X 的 vendor DTB
声称 gpio33 是 PHY reset，实为 2.4G LED。

本板的结论不受影响，因为本板的 GPIO 判定**三方交叉**：
1. 原厂 mp02.1 DTB 只提供了 gpio 15 / 26 / 27 三个，且都与 boot-args / 交换机语义自洽
2. LED 与按键的 6 个 GPIO **来自原厂固件运行时的 `/sys/kernel/debug/gpio`**，不是从 DTB 猜的
3. S7 已在自己板上跑通这些 GPIO（灯会亮、键有事件）

⇒ 只有「哪个灯对应哪个丝印」是推断（原厂从用户态驱动，无 DTB 映射），
「哪个 GPIO 被占用」是实证。
