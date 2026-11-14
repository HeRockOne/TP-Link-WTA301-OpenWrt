# P37 监听版 —— 把 WTA301 变成可抓包的网卡

date: 2026-11-15
基线：**p36**（25.12.6 / kernel 6.12.112 / ath11k 0950+951+守护三件套）
新增：**952 补丁**（2.4G 的 monitor 开关）· **aircrack-ng 1.7 + libpcap + tcpdump**

---

## 0. 先说清楚能做和不能做

| | 2.4 GHz（IPQ5018 / phy0） | 5 GHz（QCN6122 / phy1） |
|---|---|---|
| managed / AP / mesh | ✅ | ✅ |
| **monitor（原版驱动）** | ❌ **驱动硬编码关闭** | ✅ |
| **monitor（打了 952 并打开参数）** | ⚠️ 能建出来，但**未验证**能否真收到包 | ✅ |

这是查出来的事实，不是猜的。两块射频的唯一差别就在这里：

```
phy0（IPQ5018）  Supported interface modes:
                   * managed   * AP   * mesh point
phy1（QCN6122）  Supported interface modes:
                   * managed   * AP   * monitor   * mesh point
```

原因链（三处代码，逐行核过）：

1. `net/mac80211/main.c:1353` —— **mac80211 无条件给所有驱动加 monitor**
   ```c
   /* mac80211 always supports monitor */
   hw->wiphy->interface_modes |= BIT(NL80211_IFTYPE_MONITOR);
   ```
2. `ath11k/core.c` —— 但 hw_params 表里：
   ```c
   .hw_rev = ATH11K_HW_IPQ5018_HW10,  .supports_monitor = false,   ← 2.4G
   .hw_rev = ATH11K_HW_QCN9074_HW10,  .supports_monitor = true,    ← 5G 用它
   ```
3. `ath11k/mac.c:10480` —— 注册完成后又被摘掉：
   ```c
   if (!ab->hw_params.supports_monitor)
           ar->hw->wiphy->interface_modes &= ~BIT(NL80211_IFTYPE_MONITOR);
   ```

952 补丁只把第 3 步变成可关闭，**默认仍然关闭**（`monitor_all=0`），
所以不主动开参数时，行为与 p36 完全一致。

**为什么默认不开**：`supports_monitor = false` 是 Qualcomm 写的，说明 Q6 固件
可能不接受这个 pdev 上的 `WMI_VDEV_TYPE_MONITOR`。主机侧无法预知。
真不支持的话表现为 `iw ... add type monitor` 报错（可恢复，重启即回到默认），
而不是变砖 —— 但这属于**没验证过的路径**，所以做成开关而不是默认。

---

## 1. 物理限制（这两条绕不过去）

1. **没有 USB、没有 PCIe**。`pcie0/pcie1` 在 DTS 里是 `disabled on purpose`，
   也没有 USB 控制器。**外置监听网卡这条路物理上不存在。**
2. **5G 是唯一的 monitor 通路，而你就是靠 5G 连这台机器的。**
   `phy1` 同时跑 `phy1-sta0`（中继）和 `phy1-ap0`（AP），切 monitor 必须先把
   这两个拆掉 —— **SSH 当场断**。

> 所以：**刷完先插网线到 LAN 口**，从有线侧操作。否则改完 monitor 就把自己
> 锁在门外，而这块板子的射频一旦卡死，`wifi reload` / `wifi down;up` /
> `ath11k unbind-bind` 三级自救**实测全灭**，只能跑去断电。

---

## 2. 装了什么

| 组件 | 版本 | 说明 |
|---|---|---|
| `aircrack-ng` | 1.7 | 含 `airodump-ng` `aireplay-ng` `aircrack-ng` `airdecap-ng` 等全套 |
| `libpcap` | 1.10.x | aircrack / tcpdump 的依赖 |
| `tcpdump` | — | 抓包与快速自检 |

**没装 `airmon-ng`**：它是 `iw` 的旧包装，在 nl80211/ath11k 上经常判断错误，
而且会拖进 `wireless-tools`（WEXT，ath11k 根本不走这条路）。直接 `iw` 更可靠。

实际执行的 `.config` 改动就三行（其余依赖自动带入）：

```
CONFIG_PACKAGE_libpcap=y
CONFIG_PACKAGE_aircrack-ng=y
CONFIG_PACKAGE_tcpdump=y
```

自动拽进来的依赖：`libopenssl3` `libnl-core200` `libnl-genl200` `libpcre2`
`libstdcpp6`（共 +8 个包，−0）。

---

## 3. 用法

### 3.1 有线接好之后，先确认能恢复

```sh
ip -4 addr show br-lan          # 有线口有 IP
ping -c2 192.168.1.1
```

### 3.2 5 GHz monitor（推荐，驱动原生支持）

```sh
wifi down                                    # 拆掉 phy1-sta0 / phy1-ap0
iw phy phy1 interface add mon0 type monitor
ip link set mon0 up
iw dev mon0 set channel 149 80MHz
iw dev mon0 info

airodump-ng mon0
```

抓包**不要往 `/tmp` 写**（见 §5）：

```sh
# 直接流到电脑
tcpdump -i mon0 -w - | ssh 你的电脑 "cat > cap.pcap"

# 或者写到 U 盘/overlay 的持久位置，再 scp 走
airodump-ng -w /overlay/cap --output-format pcap mon0
```

### 3.3 2.4 GHz monitor（需要打开参数，未验证）

```sh
# 1) 打开开关（写在 /etc/modules.d 或 modprobe 命令行）
echo "options ath11k monitor_all=1" > /etc/modules.d/ath11k-monitor

# 2) 重新加载模块（注意：这会把 Wi-Fi 全部拆掉再重建）
wifi down
rmmod ath11k_ahb ath11k 2>/dev/null
modprobe ath11k_ahb
wifi up

# 3) 确认 pyh0 现在 advertise 了 monitor
iw phy phy0 info | sed -n '/Supported interface modes/,/Band/p'
#   期望看到 * monitor

# 4) 建接口
iw phy phy0 interface add mon1 type monitor
ip link set mon1 up
iw dev mon1 set channel 6 HT20
airodump-ng mon1
```

**如果第 3 步没看到 `* monitor`** ⇒ 参数没生效（检查 `dmesg | grep monitor_all`，
或 `cat /sys/module/ath11k/parameters/monitor_all`）。
**如果第 4 步报错** ⇒ Q6 固件不接受，这条路对 2.4G 走不通，回到默认即可。

### 3.4 用完恢复中继

```sh
iw dev mon0 del        # 或 mon1
wifi up
# 确认 phy1-sta0 重新关联上去
iw dev phy1-sta0 link
```

---

## 4. 关于"监听别人的网"

技术上有两个坎，先讲明白：

- **注入**：`ath11k_mac_op_tx` 里没有 radiotap 注入通路，管理帧只走
  `ath11k_mac_mgmt_tx`。所以 `aireplay-ng -0`（deauth）、ARP replay 这些
  **在 ath11k 上没有可靠实现**，别指望。被动抓包和 `aircrack-ng` 离线破解
  握手包不受影响。
- **WPA3 / SAE**：抓到的 SAE 握手不是 WPA2 那套 4 次握手，
  `aircrack-ng` 的 PMKID/握手破解对其无效。

**法律**：抓自己家的、自己设备的流量没问题。抓别人的、或者发 deauth 干扰
别人的连接，在绝大多数司法辖区都是违法的，不是免责声明套话。
本固件不区分用途，怎么用是你的事。

---

## 5. 内存：这块板子最脆的地方

```
MemTotal:      178224 kB
MemAvailable:   41216 kB      ← 平时就只剩 40 MB
```

这块板子的老毛病是 ath11k 的 page_frag 钉页（见 `docs/P36-CE-RING-NEGATIVE-RESULT.md`），
而 **`/tmp` 是 tmpfs，就是 RAM**。之前每次 `cat` 一个 17 MB 的 page_owner dump
到 `/tmp` 都直接把内存推到 OOM。

所以抓包：

- ❌ 不要 `airodump-ng -w /tmp/xxx`
- ✅ 流到电脑（`-w -`），或写 `/overlay`（ubifs，占 NAND 不占 RAM）
- ⚠️ 写 `/overlay` 也要看余量（约 28 MB），抓久了会满

monitor 本身的内存开销 **不是** 从零开始算的：p35 的 page_owner 账本里本来就有
`ath11k_dp_tx_htt_monitor_mode_ring_config` 6.5 MB，那是开机就分配的
（相关环在 DP 初始化时按常量建好，与是否开 monitor 无关）。

守护脚本仍在跑：`MemAvailable < 12 MB 连续两分钟 → snapshot → sync → reboot`。
**抓包时它可能因为你要的内存把你重启掉**，介意就先关：

```sh
uci set wta301-guard.settings.autoreboot=0 && uci commit
```

---

## 6. 产物与校验

| 文件 | 大小 | md5 |
|---|---|---|
| `wta301-op-25.12.6-P37-监听版-sysupgrade.bin`（**推荐**）| 16,425,237 | `97264088f95926cc692c5f0e2b3ed147` |
| `wta301-op-25.12.6-P37-监听版.bin`（网页恢复页）| 17,170,432 | `e8da8038d0be107cb46f4c8ffc63fa17` |
| `rescue/wta301-op-25.12.6-P37-监听版-ttl.bin` | 20,447,232 | `58794379f8d5de76ce2d85b27816e0da` |
| `wta301-uboot-p21c.bin`（未改）| 262,144 | `d0ada9f76e4f1aba9b96a559a5220cee` |

### 工具的实际路径（别找错地方）

```
/usr/sbin/airodump-ng   /usr/sbin/aireplay-ng   /usr/sbin/airbase-ng
/usr/sbin/airserv-ng    /usr/sbin/airtun-ng     /usr/sbin/airventriloquist-ng
/usr/bin/aircrack-ng    /usr/bin/airdecap-ng    /usr/bin/airdecloak-ng
/usr/bin/tcpdump
```

上游的 `install` 目标把工具分到 `bin/` 和 `sbin/` 两处，`airodump-ng` /
`aireplay-ng` 在 **`/usr/sbin`**，不在 `/usr/bin`。

### 镜像尺寸（重要）

```
rootfs squashfs = 12,072,306 B (0xB83572)
分区上限 0xBC0000 = 12,320,768 B
余量 248,462 B = 2.0%
```

p36 是 9,116,872 B，本次 **+2,955,434 B** —— 主要是 `libopenssl3`
（aircrack-ng 默认链 openssl）、`tcpdump`（906 KB）、aircrack 自身与 libpcap。
**只剩 2% 余量，够刷但不宽裕**；想再往里加东西得先瘦身（比如关掉
`CONFIG_AIRCRACK_NG_OPENSSL` 或去掉 tcpdump，能腾出约 2 MB）。

### 刷完后的自检

```sh
# 1. 工具在不在（注意 sbin）
which airodump-ng aireplay-ng tcpdump aircrack-ng
airodump-ng --help 2>&1 | head -3

# 2. 952 补丁在不在（参数文件存在 = 补丁编进去了）
ls /sys/module/ath11k/parameters/monitor_all
cat /sys/module/ath11k/parameters/monitor_all     # 默认 N
dmesg | grep -i monitor_all

# 3. 两块射频各自支持什么
iw phy phy0 info | sed -n '/Supported interface modes/,/Band/p'
iw phy phy1 info | sed -n '/Supported interface modes/,/Band/p'
```

判据：**`monitor_all` 默认是 `N`**。如果默认就是 `Y`，说明补丁的默认值写错了，
不要继续用。

### 包清单

198 个包，相对 p31 基线 **+8、−0**：

```
+ aircrack-ng  + libpcap1  + tcpdump  + libopenssl3
+ libnl-core200  + libnl-genl200  + libpcre2  + libstdcpp6
```

---

## 7. 与 p36 的完整差异

| 项 | p36 | p37 |
|---|---|---|
| 内核 | 6.12.112 | 同 |
| ath11k 补丁 | 0950 + 951 | 0950 + 951 + **952** |
| 包 | 190 | 190 + aircrack-ng / libpcap / tcpdump |
| Wi-Fi 守护 | 有 | 同 |
| 默认行为 | — | **与 p36 一致**（monitor_all=0） |

除了「多了三个工具」和「多了一个默认关闭的开关」，p37 与 p36 没有区别。
不想用监听功能的话，p36 和 p37 对日常中继是等价的。
