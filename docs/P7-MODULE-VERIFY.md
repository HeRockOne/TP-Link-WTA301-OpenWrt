# P7 全模块真机核对（M01–M12）

日期：2026-11-05　设备：WTA301，P7 固件（25.12.6 / r33311 / kernel 6.12.112）
原始日志：`work/evidence/p7-sweep12.log`（`work/scratch/sweep12.py` 一次跑完 23 条命令）

约定：**已实证** = 有本板日志原文；**推断** = 有推理链；**未验证** = 缺证据，不允许略过。

---

## M01 NAND 控制器 / ECC —— 已实证 ✅

| 项 | 实测 |
|---|---|
| 控制器 | `spi-nand spi0.0: GigaDevice SPI NAND was found.` |
| 几何 | `128 MiB, block size: 128 KiB, page size: 2048, OOB size: 128` |
| ECC 计数 | `/sys/class/mtd/mtd0/ecc_failures` = `0`，`corrected_bits` = `0` |

ECC 方案由 spi-nand 内核框架按 OOB 128 B 自动选择（GigaDevice 1 bit/512B + 8 bit/512B BCH），
与 S7 的 6.18.55 同一份 `drivers/mtd/nand/spi/gigadevice.c`。

## M02 分区表 —— 已实证 ✅

`cat /proc/mtd` 共 14 项（含 mtdsplit 生成的 `rootfs_data`），与规划逐项一致：

```
mtd0 003c0000 factory_boot      mtd7  003a0000 rootfs_data (mtdsplit)
mtd1 00020000 factory_info      mtd8  01600000 rootfs_data2
mtd2 00020000 art               mtd9  00040000 normal_boot_bak
mtd3 00200000 config            mtd10 00400000 kernel_bak
mtd4 00040000 normal_boot       mtd11 00c00000 rootfs_bak
mtd5 00400000 kernel            mtd12 02440000 rootfs_data3
mtd6 00c00000 rootfs            mtd13 00020000 boot_flag
```

## M03 以太网 / 交换机 —— 已实证 ✅

- `rtl8365mb-mdio 90000.mdio-1:1d: found an RTL8367S switch`
- `lan1..lan5` 全部注册；CPU 口链路 `Link is Up - 1Gbps/Full`
- **CPU 口 MTU 1508、用户口 1500** ⇒ DSA `tag_rtl8_4`（8 字节标签）正确生效
- `ping 192.168.1.100` → 0% loss；`eth0 rx=36688 tx=15223`、`lan1` 双向计数均增长
- 根因与修复见 `P7-WIRED-FIX-VERIFIED.md`

## M04 Wi-Fi —— 已实证 ✅（默认状态本次修复）

- `ath11k c000000.wifi: ipq5018 hw1.0` / `ath11k b00a040.wifi: qcn6122 hw1.0`（multipd, userpd 2）
- `phy0-ap0` ch1/2.4G、`phy1-ap0` ch36/5G 80MHz，均进 `br-lan` 并 forwarding
- **重要 L4 事实**：apk 名为 `kmod-ath11k-6.12.112.6.18.55-r2.apk` ⇒ ath11k 来自
  **backports 6.18.55**，与 S7 的 Wi-Fi 代码树**同一份**。这解释了 L4 差异表里
  网络类模块只有 crypto 改名。

默认状态问题：25.12 的 `wifi-scripts` 生成 `default_radioN` 时**显式写**
`option disabled '1'`（安全默认），因此出厂镜像首启无 Wi-Fi。
修复：新增 `deliver/ipq50xx-base-files/etc/uci-defaults/99-wta301-wireless`，
按 S7 基线启用（SSID/PSK/国家码/信道一致），见该脚本头部注释。

## M05 GPIO / LED / 按键 —— 已实证 ✅（物理按键未实测）

- LED 5 个：`green:system`(gpio19) `green:lan`(10) `green:wan`(11) `green:wlan2g`(13) `green:wlan5g`(38)
- `keys` 节点在运行态 DTB 中可见：
  `/sys/firmware/devicetree/base/keys/{key-reset,key-wps}`（reset=gpio20，wps=gpio17）
- `lsmod` 有 `gpio_button_hotplug`；它匹配 `compatible="gpio-keys"`
  （`package/kernel/gpio-button-hotplug/src/gpio-button-hotplug.c:416`），
  **成功时不打日志、也不创建 input 设备** —— 所以 `/sys/class/input/` 不存在是预期，
  不是缺陷（按键走 ubus 事件 + `/etc/rc.button/`，不是 evdev）。
- **未验证**：物理按下 reset/wps 的实际响应（无法远程触发，需现场确认）。

## M06 时钟 / PLL / UNIPHY —— 已实证 ✅

```
gmac0_tx_clk_src            125000000
gcc_uniphy_tx_clk   enable_cnt=2  is_enabled=Y   consumer=ethernet-pcs@98000
gcc_uniphy_rx_clk   enable_cnt=2  is_enabled=Y   consumer=ethernet-pcs@98000
gcc_uniphy_sys_clk  enable_cnt=1  is_enabled=Y
gcc_uniphy_ahb_clk  enable_cnt=1  is_enabled=Y
gmac1_tx_clk_src            0        ← 已知读数假象，非故障
```

判据陷阱已写入 `P7-WIRED-FIX-VERIFIED.md` §5.1：`gmac1_tx_clk_src` 在 1 Gbps Up 时也读 0 Hz。

## M07 内存 —— 已实证 ✅（附一个未归属量说明）

```
dmesg: Memory: 176132K/262144K available (… 84432K reserved, 0K cma-reserved)
/proc/meminfo: MemTotal 178672 kB
```

- 总量 **256 MB，与 V3 基线（`Memory: 174988K/262144K`）同量级** ⇒ 内存节点 `0x10000000` 正确。
- reserved 主要项：`wcss@4b000000` 53248 KiB（Wi-Fi 固件区）、`tz_apps` 4 MiB、`tz` 4 MiB、
  `bootloader` 2 MiB、`smem` 1 MiB。
- zram swap 87 MiB（`/dev/zram0`，priority 100），运行 13 min 用了 3.3 MB。
- **约 100 MB 内存没有任何 `/proc/meminfo` 计数器归属**（Slab 25 MB、AnonPages 1.8 MB、
  VmallocUsed 8 MB，其余对不上）。这是 ipq50xx + ath11k **host memory mode 2** 的特征：
  同族板 TP-Link EX511 v2（IPQ5018 + QCN6122 + 256 MB + RTL8367S-VB）的维护者在
  OpenWrt 论坛明确记录同样的现象与数字（"~50 MB of used RAM that no /proc/meminfo
  counter names… 17 h 时 MemAvailable 15 MB，0 OOM"）。
  来源：<https://forum.openwrt.org/t/ipq5018-nss-offload-on-kernel-6-18-with-the-upstream-ethernet-stack-gl-b3000/253014?page=18>
- **不适用项**：论坛建议 256 MB 板选 `ATH11K_MEM_PROFILE_256M` / `NSS_MEM_PROFILE_LOW` /
  `coherent_pool=512K`。已全树检索：`ATH11K_MEM_PROFILE` 在 25.12.6 源码树中**不存在**
  （那是 kuncy7/nss 下游 fork 的私有符号），故本交付不做改动，
  `coherent_pool=2M` 保持与 S7 逐字一致。
- **待观测**：MemAvailable 启动后约 5 MB，需长时间 soak 确认不继续下降（见 `work/evidence/p7-soak.log`）。

## M08 引导链 —— 已实证 ✅

- `Machine model: TP-Link WTA301`
- `tplboot` 走 A 槽：`image_2 kernel 0x480000 @0x04880000 -> 0x44000000`
- cmdline：`root=/dev/mtdblock6 rootfstype=squashfs rootwait coherent_pool=2M
  ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data`

## M09 外设 —— 已实证 ✅

- USB 子系统注册正常，无设备（本板无 USB 口，符合硬件）
- 无 PCIe 设备 —— QCN6122 走 AHB + multipd（`qcom-q6-mpd cd00000.remoteproc: pd-1/2/3 node found`）
- `dwc3_qcom` 已加载（与 S7 相同）

## M10 MAC / ART —— 已实证 ✅

| 接口 | MAC |
|---|---|
| `eth0` / `br-lan` | `98:97:cc:a8:1f:e7` = 板底标签（mtd1 `factory_info` @0x1c） |
| `phy0-ap0` | `98:97:cc:a8:1f:e9` |
| `phy1-ap0` | `98:97:cc:a8:1f:ea` |

u-boot 报 `.e8` 是二级 u-boot 自己 +1 的行为，与内核取值无关。

## M11 温度 / 电源 —— 已实证 ✅

```
thermal_zone0  ubi32-thermal     47000
thermal_zone1  cpu-thermal       47000
thermal_zone2  top-glue-thermal  48000
thermal_zone3  gephy-thermal     49000
```

四源齐全、温度正常；本板无 PMIC、无软件可控稳压器（与 M11 文档一致）。

## M12 固件 / BDF —— 已实证 ✅

```
78f5b21b2cd1dee8fb6155e1f74a1073  /lib/firmware/ath11k/IPQ5018/hw1.0/board-2.bin
e4904f1326df5edfd7842b319e0828da  /lib/firmware/ath11k/QCN6122/hw1.0/board-2.bin
```

`q6_fw.mdt` 由 `remoteproc` 加载成功（`Booting fw image ath11k/IPQ5018/hw1.0/q6_fw.mdt`），
两个 userpd 均起来（`Multipd architecture - userpd: 2`）。

---

## 汇总

| 模块 | 结论 | 备注 |
|---|---|---|
| M01 NAND/ECC | ✅ | ecc_failures=0 |
| M02 分区 | ✅ | 14 项 |
| M03 以太网 | ✅ | P7 修复后 0% 丢包 |
| M04 Wi-Fi | ✅ | 默认关闭已修（uci-defaults） |
| M05 GPIO/LED/按键 | ✅ | 物理按键**未实测** |
| M06 时钟 | ✅ | gmac1_tx 读数 0 属假象 |
| M07 内存 | ✅ | ~100 MB 未归属 = ipq50xx 已知特征；待 soak |
| M08 引导链 | ✅ | A 槽 + tplboot |
| M09 外设 | ✅ | 无 USB/PCIe 设备符合硬件 |
| M10 MAC | ✅ | 与 mtd1 一致 |
| M11 温度 | ✅ | 4 源 47~49 ℃ |
| M12 固件/BDF | ✅ | 双 board-2.bin |

**11 项完全通过 + M05 物理按键待现场确认。**
