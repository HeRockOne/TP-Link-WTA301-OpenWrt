# P24 — 5G 性能调优与瓶颈定位（实测定稿）

> 板子：WTA301（IPQ5018 + QCN6122）/ OpenWrt 25.12.6 / 2× Cortex-A53
> 客户端：Redmi Note 12T Pro，MAC `82:73:50:60:66:9f`，**只支持 80MHz**
> 日期：2026-11-06（出厂重置后完整重测）

---

## 1. 最终配置（已写入 flash，定稿）

```sh
# 5G —— 实测 590 avg / 675 峰值 Mbps
wireless.radio1.channel='161'        # 5805 MHz，CN 法规 33 dBm（ch36 只有 30）
wireless.radio1.htmode='HE80'        # WiFi 6，协商 1080.6 / 1200.9
wireless.radio1.country='CN'
wireless.radio1.txpower='33'         # 法规上限（BDF 实际限 24，见 §4）
wireless.radio1.noscan='1'
wireless.radio1.cell_density='2'

# 2.4G —— 从 ch6（busy 2,135,077 ms）换到 ch11（busy 22,130 ms）
wireless.radio0.channel='11'
wireless.radio0.htmode='HT40'        # 实际协商 20MHz（ch11 无法向上扩展）
wireless.radio0.country='CN'
wireless.radio0.txpower='20'         # CN 2.4G 法规上限
wireless.radio0.cell_density='2'
```

**最终链路状态（实测）**
```
5G : channel 161 (5805 MHz), width 80 MHz, txpower 24.00 dBm
     signal -20 dBm | tx 1080.6 / rx 1200.9 Mbps HE-MCS10/11 NSS2
     expected throughput 887.703 Mbps
2.4G: channel 11 (2462 MHz), width 20 MHz, txpower 20.00 dBm
```

---

## 2. 实测吞吐（重传 0）

| 测法 | 结果 |
|---|---|
| 手机 → 板（`iperf3 -c 192.168.1.1`） | **avg 590 / 峰值 675 Mbps** |
| 板 → 手机（板当 client） | 474 Mbps |
| 手机 → 板（板当 client `-R`） | 523–529 Mbps |
| 4 流上行 | 499 Mbps（+5%，说明多核已无余力） |
| UDP 800M | 282 Mbps，丢包 0.17%，jitter 0.103 ms |

**吞吐 ≈ expected throughput 的 66–74%** —— 这是 ath11k 无 NSS offload 时的正常比例。

---

## 3. 与外部同款 SoC 对比（同带宽 80MHz）

| 构建 | 80MHz 吞吐 | 来源 |
|---|---|---|
| **本板 OpenWrt 25.12.6** | **590 avg / 675 峰值** | 本轮实测 |
| 外部 NSS 构建（CMCC PZ-L8） | 462（四路 HTTP） | `mufeng05/openwrt-cmcc-pz-l8-nss` |
| 外部原生 OpenWrt | 308 | 同上 |
| 原厂 @**160MHz** | 711 | 同上 |
| NSS 构建 @**160MHz** | 697 | 同上 |

**本板比外部原生 OpenWrt 高 92%，比外部 NSS 构建高 28%。**

原厂 711 的两个前提本板都不满足：① 客户端支持 160MHz（本板手机只 80MHz）② NSS 硬件卸载（闭源，主线无）。

详见 `R19-THROUGHPUT-VS-STOCK-EXTERNAL-EVIDENCE.md`

---

## 4. 信道与功率表（`iw phy phy1 info`，country=CN 实测）

| 频段 | 信道 | 功率上限 | 备注 |
|---|---|---|---|
| U-NII-1 | 36 / 40 / 44 / 48 | **30 dBm** | 非 DFS ← 出厂默认 36 |
| U-NII-2A | 52 / 56 / 60 / 64 | 30 dBm | **DFS**（CAC 60s） |
| U-NII-2C | 100 – 144（15 个） | **disabled** | CN 不可用 |
| **U-NII-3** | **149 / 153 / 157 / 161 / 165** | **33 dBm** | 非 DFS ← **推荐 161** |
| ISM | 169 / 173 / 177 | disabled | 不可用 |

### `txpower` 写不动（BDF 硬限，非法规）

| 设置值 | 实际生效 |
|---|---|
| 2000 (20 dBm) | **20.00 dBm** ✅ |
| 2400 / 2450 / 2500 / 2600 / 2700 / 3000 / 3300 | **全部 24.00 dBm** |

**法规允许 33，BDF 功率表只放 24。** 设 20 能压到 20（说明可写），但往上撞 24 硬墙。

### 国家码不是瓶颈（决定性实验）

| 国家 | 161 法规上限 | 设 33 dBm 实际 |
|---|---|---|
| AU | 30 dBm | **24.00 dBm** |
| **CN** | **33 dBm** | **24.00 dBm** |

两种国家码下实际都是 24 ⇒ **24 比任何国家的法规值都低，国家码永远不构成功率瓶颈**。
国家码只影响**信道可用性**（JP/DE 直接禁用 161），不影响性能。

---

## 5. ★ 160MHz 在本板是负优化（实测推翻推断）

硬件支持 160MHz（`HE160/5GHz`），CAC 也通过了：

```
channel 36 (5180 MHz), width 160 MHz, center1 5250 MHz
DFS-CAC-COMPLETED success=1 freq=5180 cac_time=60s radar_detected=0
interface state DFS->ENABLED
```

但实测：

| 指标 | 160MHz @ch36 | **80MHz @ch161** | 结果 |
|---|---|---|---|
| 手机实际带宽 | **仍 80MHz** | 80MHz | 手机不支持 160 |
| 信道忙时 | **141,496 ms（63%）** | **1,277 ms（0.4%）** | 160 引入 111× 干扰 |
| 底噪 | -111 / **-97 dBm** | **-113 dBm** | — |
| 手机协商 | 648.5 / 1080.6 | **1080.6 / 1200.9** | — |
| **expected throughput** | **551.6 Mbps** | **887.7 Mbps** | **+61%** |

⇒ **手机只用 80MHz，却要承受整段 160MHz 的邻区干扰，纯亏 19%。已回退。**

外部实测「80MHz→160MHz 涨 51%」的前提是**客户端支持 160MHz**（Intel AX201）。

---

## 6. ★ RPS 配置缺陷与持久化（已修复）

### 6.1 问题

出厂状态：

| 接口 | `rps_cpus` |
|---|---|
| `phy1-ap0`（5G） | **`0`（禁用）** |
| `phy0-ap0`（2.4G） | `2` |
| `br-lan` | `0`（禁用） |
| `eth0` | `1` |

`/proc/net/softnet_stat` 累计：**CPU0 = 347,555 / CPU1 = 777**（450:1），CPU0 还有 2,330 次丢包。

### 6.2 修复后效果

| | 修复前 | 修复后 |
|---|---|---|
| softnet CPU0 | 347,555 | 903,837 |
| softnet CPU1 | **777** | **608,276** |
| 比例 | **450 : 1** | **1.5 : 1** |
| CPU1 测试时占用 | 1–9% | **99–100%** |

### 6.3 技术限制

```
phy1-ap0: rx=1 tx=1 队列
eth0:     rx=1 tx=1 队列
eth0 硬中断 IRQ 22：6781 次全在 CPU0
```

**ath11k 只给 1 个 RX 队列**，硬中断物理上只能落一个核。RPS 只能把「协议栈处理」搬到另一个核，是**半并行**。修复后吞吐 542 → 565/590（+4~9%），因为瓶颈是每包绝对开销，不是并行度。

### 6.4 持久化（三处，已部署）

**`/etc/hotplug.d/net/99-rps`** —— 接口创建时触发（`wifi down/up` 有效）
```sh
#!/bin/sh
[ -d "/sys/class/net/${DEVICENAME}/queues/rx-0" ] || exit 0
case "$DEVICENAME" in
    phy*-ap*|br-lan|eth0)
        echo 3 > "/sys/class/net/${DEVICENAME}/queues/rx-0/rps_cpus"
        echo 4096 > "/sys/class/net/${DEVICENAME}/queues/rx-0/rps_flow_cnt" 2>/dev/null
        ;;
esac
exit 0
```

**`/etc/init.d/rps`** —— 开机 + `procd_add_reload_trigger wireless`
```sh
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
apply_rps() {
	for _i in phy1-ap0 phy0-ap0 br-lan eth0; do
		[ -d "/sys/class/net/${_i}/queues/rx-0" ] || continue
		echo 3 > "/sys/class/net/${_i}/queues/rx-0/rps_cpus" 2>/dev/null
		echo 4096 > "/sys/class/net/${_i}/queues/rx-0/rps_flow_cnt" 2>/dev/null
	done
	echo 4096 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
	echo 1000 > /proc/sys/net/core/netdev_max_backlog 2>/dev/null
}
start_service()  { ( sleep 20; apply_rps ) & }
stop_service()   { :; }
reload_service() { ( sleep 8;  apply_rps ) & }
service_triggers() { procd_add_reload_trigger wireless; }
```

**`/etc/rc.local`** —— 全局 sysctl
```sh
echo 4096 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
echo 1000 > /proc/sys/net/core/netdev_max_backlog 2>/dev/null
```

**验证**：`wifi down` → 接口消失 → `wifi up` → `phy1-ap0 = 3` ✓（日志 `rps: set phy1-ap0 rps_cpus=3`）

### 6.5 坑：为什么不能用 rc.local 单干

`wifi reload` / `wifi down/up` 会重建 `phy*-ap*` 接口，sysfs 被重置为 0。
- `rc.local` 只在开机跑一次 → 接不住
- `hotplug.d/net` 对 `phy*-ap*` **只在真正创建时**触发（hostapd 走 netlink，`wifi reload` 不重建接口时不触发）
- 必须 **hotplug + init.d 双保险**

---

## 7. 2.4G 信道（ch6 → ch11）

| 信道 | 频率 | busy time | 说明 |
|---|---|---|---|
| **ch6**（出厂默认） | 2437 MHz | **2,135,077 ms** | 严重拥塞，被挤到 20MHz + CTS protection，实测 ~20 Mbps |
| **ch11** | 2462 MHz | **22,130 ms** | **97× 更干净** |

2.4G 邻居（`scan` 实测）：邻频有 CMCC / HUAWEI 多个 AP。
`ch11 + HT40` 实际协商 **20 MHz**（ch11 向上无合法 HT40 扩展位），这是法规限制，正常。

---

## 8. 已知无效优化清单（实测排除）

| 做法 | 为什么无效 |
|---|---|
| 改 `txpower` 到 27/30/33 | BDF 硬限 24 dBm |
| 改国家码到 US/TW/HK/KR | 161 上限从 33 降到 30 dBm |
| 改国家码到 JP/DE | **161 直接禁用** |
| 切 `HE160`（本板 + 本手机） | 手机只 80MHz；信道 busy 63%，expected 反而 -19% |
| 切 DFS 52–64 | 开机 CAC 60s；实测循环 `DFS-CAC-START` → `DFS->DISABLED` 的风险 |
| `flow_offloading` | 只加速 **forward** 链，对路由器自身收发的 AP 流量无效 |
| 改 CPU governor | **无 `cpufreq`**，CPU 固定频率 |
| 加 RX 队列分流硬中断 | ath11k 只给 1 个 RX 队列，硬件不支持 |

---

## 9. 测量方法陷阱（重要）

**不要用 `/sys/class/net/*/statistics` 或 `iw station dump` 的 `tx bytes` 差分算吞吐** —— 含重传字节，会算出**超过协商上限**的值（实测算出 1549 Mbps，而协商只有 1200.9，物理不可能）。

可靠方法（按优先级）：
1. `iperf3` 自己打印的数字
2. `/proc/net/dev` 收包方向（下行时比较干净）
3. UDP 测试看丢包率

---

## 10. BDF 改动评估（能做但不建议）

| 项 | 值 |
|---|---|
| 工具 | `ath11k_bdf_tool.py`（`-e` 提取 / `-u` 更新 / `-p` 打补丁）+ `ath11k-bdencoder` |
| 功率偏移（外部证据） | **`0x1eb` / `0x1ec` / `0x1ed`**（IPQ5018，= 491/492/493） |
| 本板 5G BDF | `0x1eb=03` / `0x1ec=01` / `0x1ed=02` |
| 本板 2.4G BDF | `0x1eb=03` / `0x1ec=01` / `0x1ed=00` |
| `0x45c` | **`0x00`**（已是修好的状态，无需 3→0） |
| 容器内名字 | `bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=TP-Link-WTA301` |
| 内嵌 regdb | **无** |

**不建议改**，因为：手机信号 -20 dBm 已极强；瓶颈是 CPU；BDF 版本必须严格匹配固件 `WLAN.HK.2.7.0.1-01744`，改错射频不工作。

---

## 11. 待办

- [ ] 2.4G 用老设备实测（预期从 20 提升到 60–90 Mbps）
- [ ] 决定是否上 NSS offload（需自建固件，闭源 `qca-nss-drv`）
- [ ] 客户端若换支持 160MHz 的网卡，可回到 ch36/HE160 复测
