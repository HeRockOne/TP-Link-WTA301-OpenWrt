# P27 —— 固件里「机器实际没有的东西」统计

> 用户指示：「我认为可以砍了。比如机器实际没有的，就不需要，统计出来」
>
> 本文档只做一件事：**把固件里包含、但本板硬件上不存在的东西全部统计出来**，
> 逐项给出体积与判据。不做取舍决定，取舍见 §6。

---

## 1. 硬件实际有什么（实证）

### 1.1 外部资料（拆解 + 参数站）`[外部实证]`

| 来源 | 关键信息 |
|---|---|
| https://www.efxn.net.cn/threads/...41/ （拆解） | 主控 IPQ0518、内存 256MB DDR3（Zentel 2Gbit）、Flash 128MB（ESMT）、**交换芯片 Realtek RTL8367S**、5G 芯片 QCN6102/QCN6122 |
| https://mao.fan/Router/telecom/WTA301 | AX3000、256MB/128MB、**网络接口：千兆网口 × 4**、12V/1A |
| https://post.smzdm.com/p/awwzeqp2/ | 「4 个全千兆网口，支持 WAN/LAN 盲插」 |

三处都只说 **4 个网口**，**没有任何一处提到 USB / SD 卡 / 硬盘接口**。

### 1.2 本板实证（`192.168.1.1`）

```
SoC        : TP-Link WTA301   compatible = tplink,wta301 / qcom,ipq5018
CPU        : 2 × Cortex-A53 (CPU part 0x801)
2.4G 射频   : ath11k c000000.wifi: ipq5018 hw1.0   （SoC 内置）
5G 射频     : ath11k b00a040.wifi: qcn6122 hw1.0
交换机      : rtl8365mb-mdio ... found an RTL8367S switch
内存        : MemTotal 178672 kB（物理 256MB，WCSS 等预留 52MB+）
Flash       : /proc/mtd 15 个分区，共 128MB

PCIe 设备数 : 0
USB  设备数 : 0     （/sys/bus/usb/devices 为空）
mmc_host 数 : 0
UART        : 仅 blsp1_uart1
```

### 1.3 DTS 明确写了什么（源码级判据）

`target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-wta301.dts` 第 62 行原文：

```
 *   A4  pcie0/pcie1 stated disabled on purpose: QCN6122 is NOT a PCIe device
```

- `pcie0` / `pcie1`：**明确 disabled**（不是漏掉，是有意）
- **全文没有 usb / dwc3 / xhci / sdhci / mmc 任何节点**
- 有 `keys`（gpio-keys）：reset=gpio20、wps=gpio17
- 有 `leds`（gpio-leds）：gpio 19 / 10 / 11 / 13 / 38，共 5 个

---

## 2. ★ 硬件不存在，但内核里编译了进去

### 2.1 内核符号体积（用 `System.map` 精确统计，58130 个符号）

方法：按符号地址差计算每个符号大小，再按子系统前缀聚合。

| 子系统 | 内核对映体积（未压缩） | 符号数 | 板上有吗 |
|---|---|---|---|
| **PCIe**（pci_/pcie_/dw_pcie/qcom_pcie） | **163,312 B** | 821 | **0 设备，DTS 明确 disabled** |
| **MMC/SD**（sdhci_/mmc_/cqhci_） | **149,112 B** | 545 | **0 host** |
| **SCSI/NVMe/SATA**（scsi_/nvme_/ata_/libata_/sd_/sg_） | **99,916 B** | 372 | **0 设备** |
| **USB**（usb_/xhci_/dwc3_/otg_/typec_） | **85,312 B** | 343 | **0 设备，DTS 无节点** |
| 声卡（snd_/soc_） | 5,840 B | 16 | 无 |
| HID/输入（hid_/input_/kbd_/mouse_） | 5,292 B | 18 | 只有 GPIO 按键 |
| 蓝牙（hci_/bt_/bluetooth） | 720 B | 3 | 无 |
| hamradio/can/nfc/wwan/gnss | 1,972 B | 14 | 无 |
| **合计** | **511,476 B ≈ 499 KB** | 2,132 | — |

参考：内核 `Image` 未压缩 22,751,240 B（21.7 MB）。
⇒ 这部分占 Image 的 **2.2%**；squashfs 压缩后估计能省 **100–150 KB**。`[推断]`

### 2.2 内核 config 里的条目数

| 子系统 | `=y`（进 Image） | `=m`（进 /lib/modules） |
|---|---|---|
| USB | 9 | 6 |
| PCIE | 10 | 0 |
| MMC | 7 | 0 |
| NVME | 6 | 0 |
| SCSI | 4 | 0 |

（`CONFIG_USB` 相关全部条目共 **108** 项）

---

## 3. ★ 硬件不存在，但模块**正在内存里躺着**

这部分比 §2 更重要——它不是占 Flash，是**真的占着 RAM**。

`/proc/modules` 第 2 列实测：

| 模块 | 占用 RAM | 驱动绑定了几个设备 |
|---|---|---|
| `xhci_hcd` | **132 KB** | 0（`/sys/bus/platform/drivers/xhci-hcd/` 只有 bind/module/uevent/unbind） |
| `dwc3` | **48 KB** | 0 |
| `xhci_pci` | 16 KB | 0 |
| `dwc3_qcom` | 16 KB | 0 |
| `xhci_plat_hcd` | 12 KB | 0 |
| **合计** | **224 KB** | **全部为 0** |

判据三重印证：
1. `/sys/bus/usb/devices/` 空，`ls | wc -l` = **0**
2. `/sys/bus/platform/devices/` 里 grep `usb|xhci|dwc3` = **空**
3. DTS 里 grep `usb|dwc3|xhci` = **空**

对应 7 个软件包：`kmod-usb-common` `kmod-usb-core` `kmod-usb-dwc3`
`kmod-usb-dwc3-qcom` `kmod-usb-roles` `kmod-usb-xhci-hcd` `kmod-usb3`

磁盘上：`xhci-hcd.ko` 214,272 B、`dwc3.ko` 79,368 B、`dwc3-qcom.ko` 18,440 B、
`xhci-pci.ko` 18,704 B、`xhci-plat-hcd.ko` 16,344 B、`roles.ko` 14,960 B
⇒ **合计 362 KB 的 .ko 文件**

---

## 4. ★ 新发现：板上多出了硬件上不存在的端口与 LED

### 4.1 `lan5` —— RTL8367S 第 5 个内置 PHY，但板子只有 4 个 RJ45

```
dmesg:
  rtl8365mb-mdio ... lan1: PHY [...:user_mii:00] RTL8365MB-VC
  rtl8365mb-mdio ... lan2: PHY [...:user_mii:01]
  rtl8365mb-mdio ... lan3: PHY [...:user_mii:02]
  rtl8365mb-mdio ... lan4: PHY [...:user_mii:03]
  rtl8365mb-mdio ... lan5: PHY [...:user_mii:04]   ← 第 5 个
```

- RTL8367S 芯片集成 **5 个 GbE PHY**
- 本板只引出 **4 个 RJ45**（外部拆解三处一致）
- ⇒ `lan5` 对应的 PHY **没有接网口**，物理上永远 link down
- 实测 `lan5: carrier=0 oper=lowerlayerdown`
- 而它**被桥接进了 br-lan**

DTS 自己的注释也承认这点：
```
 * wifi1 disabled, 4 front ports instead of 5, ...
```

代价 `[推断]`：一个 netdev + 一个 PHY 实例 + DSA 端口 + 桥接成员，
且 rtl8365mb 用 `irq=POLL` 轮询所有端口 ⇒ lan5 让轮询多做一份无用功。
量级小（几十 KB RAM），但属于「硬件没有却存在」的典型。

### 4.2 `green:wan` LED —— 本板没有 WAN 口

```
/sys/class/leds/:
  green:lan  green:system  green:wan  green:wlan2g  green:wlan5g
```

本板 **5 个口全在 br-lan，没有独立 WAN 口**（P26 已记）。
`green:wan` 这个名字是照搬上游模板留下的，语义上不存在对应硬件事物。
（GPIO 本身可能确实驱动一颗物理 LED，所以**不能盲目删 LED 节点**，
只能改语义标签。）`[未验证]` 物理丝印是 LAN 还是 WAN。

---

## 5. 汇总：可砍清单与预期收益

| # | 项目 | 性质 | Flash | RAM | 判据强度 | 风险 |
|---|---|---|---|---|---|---|
| A | `kmod-usb-*` 7 个包 + 内核 USB 108 项 | 硬件不存在 | ~362 KB (.ko) + ~85 KB (Image) | **224 KB**（已加载） | 三重印证（sysfs/DTS/驱动绑定） | **无** |
| B | 内核 PCIe（163 KB 符号 + 10 项 =y） | 硬件不存在 | ~163 KB (Image) | 0（未加载） | DTS 明确 disabled + 0 设备 | **无** |
| C | 内核 MMC/SD（149 KB 符号 + 7 项 =y） | 硬件不存在 | ~149 KB (Image) | 0 | 0 个 mmc_host | **无** |
| D | 内核 SCSI/NVMe/SATA（100 KB 符号） | 硬件不存在 | ~100 KB (Image) | 0 | 0 设备 | 低（可能被 fstools 用到，需验） |
| E | `lan5` DSA 端口 + PHY | 硬件不存在 | 0 | ~几十 KB | 拆解 3 处 + dmesg 5 个 PHY | 低 |
| F | `green:wan` 标签 | 语义错误 | 0 | 0 | 无 WAN 口 | 无 |
| G | 声卡/HID/蓝牙/hamradio（小项） | 硬件不存在 | ~15 KB | ~0 | 0 设备 | 无 |
| **合计** | | | **~800 KB–1 MB** | **~250 KB** | | |

### 5.1 诚实结论：这些砍完，对「跑不了软件」几乎没有帮助

用户原话是「当前才几十 mb，根本运行不了什么软件」。按实测：

```
MemTotal      178,672 kB  (174.5 MB)
MemAvailable   57,276 kB  ( 55.9 MB)   ← 现在其实有 56MB 可用
```

真实占用分布（P23/P26 已算清）：

| 项 | 大小 | 占 MemTotal |
|---|---|---|
| **ath11k（双射频 DP ring + page-frag）** | **73.4 MB** | **42%** |
| SUnreclaim slab | 15.6 MB | 9% |
| VmallocUsed | 8.2 MB | 5% |
| 用户态 anon | **4.5 MB** | 2.6% |
| KernelStack + PageTables | 2.0 MB | 1% |
| Cached（可回收） | 29.4 MB | — |

**用户态总共只用了 4.5 MB**，84 个进程 RSS 合计 29 MB（含共享）。
所以「删掉没用的包」最多省下几百 KB，
**真正的 73 MB 压在 ath11k 上**（不是「硬件不存在」，是驱动固有取用）。

---

## 6. 如果要真的腾出内存，唯一有效的手段

### 6.1 ath11k 的 DP ring（唯一大头）

外部已有上游正式提案 `[外部实证]`：
`[PATCH ath-next] wifi: ath11k: use smaller DP rings on low-memory systems`
（Eduard Hart, 2026-09-30, lore-kernel.gnuweeb.org/ath11k/20260930165052...）

原文：
> On IPQ5018 boards with 256 MiB of RAM and a second radio (e.g. QCN6122),
> the RX buffers and TX completion rings of both radios take so much memory
> that the system runs out of memory shortly after bringing up both interfaces.

上游 low-memory profile（测试机型正是 **TP-Link RE700X = IPQ5018 + QCN6122 + 256 MiB**）：

| 常量 | 默认 | 上游 low-mem | 本板当前(0950) |
|---|---|---|---|
| `DP_TX_COMP_RING_SIZE` | 32768 | **2048** | 8192 |
| `DP_RXDMA_BUF_RING_SIZE` | 4096 | **1024** | 2048 |
| `DP_RXDMA_MON_STATUS_RING_SIZE` | 1024 | 512 | 512 |
| `DP_RXDMA_MONITOR_BUF_RING_SIZE` | 4096 | 128 | 128 |
| `DP_RXDMA_MONITOR_DST_RING_SIZE` | 2048 | 128 | 128 |

上游实测结果：
> both radios of a TP-Link RE700X (IPQ5018 + QCN6122, 256 MiB) stay up under
> load (4-6 clients) with **14-37 MiB of RAM available** and no OOM

⚠️ 但社区对 `DP_TX_COMP_RING_SIZE` 有反向证据 `[外部实证]`：
（forum.openwrt.org/t/mercusys-mr80x-v2.../252380）
> I ended up **raising its ring sizes again**, because `DP_TX_COMP_RING_SIZE`
> also caps in-flight TX descriptors and **cutting it hurts throughput** for no
> benefit here.

⇒ **这是一个必须实测的取舍**，不能照抄。

### 6.2 其它方向（代价更大）

- **eisbaw 的 per-RXDMA-ring page_frag_cache 补丁**：修的是「碎片跨源共享导致
  32KB 整页被钉住」的机制，不改 ring 尺寸 ⇒ 吞吐无代价。但它是在 6.18 内核上
  验的，本板 6.12.112 要重做。`[未验证]`
- **砍 swap/zram**：实测 `SwapTotal 49148 kB / SwapFree 49148 kB` —— **一次都没用过**。
  zram 模块占 20 KB + zsmalloc 20 KB RAM，看起来是白占；
  但它是 OOM 安全网，砍掉风险 > 收益。**建议保留**。
- **ext4/jbd2**（444 KB + 76 KB RAM）：overlay 用 ubifs，ext4 只在
  loop 挂载镜像/sysupgrade 时用。`[未验证]` 能否砍要看 fstools 依赖。

---

## 7. 建议的执行顺序

1. **先砍 A（USB）** —— 零风险、三重印证、省 224 KB RAM + 362 KB Flash
2. **再砍 B/C/G（PCIe / MMC / 声卡等）** —— 零风险，省 ~330 KB Image
3. **D（SCSI/NVMe）** 需先确认 fstools 不依赖，再动
4. **E（lan5）** 改 DTS 去掉第 5 个 PHY，需重编内核并回归网口
5. **ath11k low-mem profile** 单独做一轮：改 → 测吞吐 → 测内存，用数据决定

前 3 步合计约省 **0.6–1 MB Flash / 0.25 MB RAM**，对「跑软件」帮助有限，
但能让固件更干净、攻击面更小、启动更快。**真正的大头在第 5 步。**
