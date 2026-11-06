# P30 —— 温度：为什么 LuCI 没有显示、本板实际多热、满载安全边界

> 用户问：「为什么界面上没有 cpu 占用温度展示的控件？」
> 又说：「话说为什么不放在顶部？」「温度挺高啊」

---

## 1. 为什么 LuCI 默认没有这个控件

**不是缺驱动，不是缺传感器。是上游故意不做。**

本板温度全部可读，有 **6 个传感器**：

```
thermal_zone0  ubi32-thermal      51°C   critical 120°C
thermal_zone1  cpu-thermal        51°C   passive  100°C / critical 120°C
thermal_zone2  top-glue-thermal   51°C   critical 120°C
thermal_zone3  gephy-thermal      53°C   critical 120°C
hwmon4 (phy0)  ath11k 2.4G        61°C
hwmon5 (phy1)  ath11k 5G          53°C
```

上游核心开发者 slh 在 [forum 253648](https://forum.openwrt.org/t/add-cpu-freq-fan-rpm-and-cpu-temp-slot-in-luci-overview/253648)
驳回 feature request 的原话：

> "On modern ARMv8/wifi6+ routers you may easily find >10 temperature sensors...
> It's hard to come up with a sensible way to display these in a meaningful way
> (with proper labels, etc.). ... **luci is the same for all devices**, making
> that sensible for all devices is not trivial."

`[外部实证]` 结论：**这是机型定制问题，不是固件缺陷。**
既然我们只管这一块板，标准化的顾虑就不存在了 —— 直接做。

---

## 2. 实现：三个文件，零侵入

| 文件 | 作用 |
|---|---|
| `files-rootfs/usr/share/rpcd/ucode/wta301` | ubus 对象 `wta301.status` |
| `files-rootfs/usr/share/rpcd/acl.d/luci-mod-status-wta301.json` | 只授权这一个方法 |
| `files-rootfs/www/luci-static/resources/view/status/include/15_sensors.js` | 前端 section |

### 2.1 为什么必须走 rpcd，不能前端直接读 sysfs

LuCI 前端读文件要过 rpcd 的 ACL。`luci-mod-status-index.json` 原文只放通了：

```json
"/etc/board.json": [ "read" ],
"/proc/sys/net/netfilter/nf_conntrack_count": [ "read" ],
"/proc/sys/net/netfilter/nf_conntrack_max": [ "read" ],
"/www/luci-static/resources/view/status/include": [ "list" ]
```

没有 `/sys/class/thermal`。前端写 `fs.read('/sys/class/thermal/...')` 会被拒。
两条路：给 file ACL 加一堆 sysfs 路径，或者**在 rpcd 里读、只授权一个 ubus 方法**。
选后者 —— 不放开任何文件路径。

### 2.2 为什么文件名是 `15_`

`view/status/index.js` 的加载逻辑（上游原文）：

```js
load: function() {
  return L.resolveDefault(fs.list('/www'+L.resource('view/status/include')), [])
    .then(entries => Promise.all(entries
      .filter(e => e.type=='file' && e.name.match(/\.js$/))
      .map(e => 'view.status.include.'+e.name.replace(/\.js$/,''))
      .sort()                                    // ← 纯字符串排序
      .map(n => L.require(n))));
}
```

⇒ **文件名数字前缀 = 页面顺序，且不需要改任何上游文件。**

实际顺序（用户拍定：系统 → CPU温度 → 内存）：

```
1. 10_system.js     系统
2. 15_sensors.js    CPU 使用率与温度   ← 本项
3. 20_memory.js     内存
4. 25_storage.js    存储
5. 29_ports.js      端口
6. 30_network.js    网络
7. 40_dhcp.js       DHCP
8. 50_dsl.js        DSL（本板无此硬件，自动隐藏）
9. 60_wifi.js       无线
```

想换位置改前缀数字即可，一行代码都不用动。

### 2.3 CPU 使用率怎么算

`/proc/stat` 首行两次差分（LuCI 默认 5 秒轮询一次）：

```
使用率 = (Δtotal - Δidle) / Δtotal      idle = 第 4 列 idle + 第 5 列 iowait
```

首帧没有前值，显示「采样中…」。

### 2.4 部署（不重编固件）

```bash
cd wta301-2512
SSHKEY=C:/Users/Sophia/.ssh/wta301 bash deliver/deploy-sensors.sh
```

脚本自带四道防护：源文件末尾换行检查 → heredoc 写入 → `ucode -c` 编译 →
重启 rpcd 后 `ubus call wta301 status` 验证 → 打印页面顺序。

---

## 3. 满载实测（60 秒单流 TCP 上行）

### 3.1 方法

板上每 2 秒采样一次，全程覆盖 64 秒窗口：

```sh
cpu%   = /proc/stat 差分
cpuT   = /sys/class/thermal/thermal_zone1/temp
phy0T  = /sys/class/ieee80211/phy0/hwmon4/temp1_input    # 2.4G
phy1T  = /sys/class/ieee80211/phy1/hwmon5/temp1_input    # 5G
gephyT = /sys/class/thermal/thermal_zone3/temp
```

`[本板实证]` 采样脚本 `/tmp/monrun.sh`，原始数据 `/overlay/load60.log`。

### 3.2 吞吐

```
[  6]   0.00-68.00  sec  3.28 GBytes   414 Mbits/sec    0    sender
```

**重传 0 次**。客户端协商 `tx/rx 1080.6 MBit/s HE-MCS10 NSS2 80MHz`，
实测 414 Mbps ≈ 协商值的 38%。

`[推断]` 单流 TCP 上行达不到 expected 887 Mbps 的原因：
手机是发送方受其自身 TCP 栈与 WiFi 驱动限制 + 本板 ath11k 只有 1 个 RX 队列、
32 个 DP 中断全在 CPU0。这是 64 流时能到 563 而单流只有 414 的原因。

### 3.3 CPU 曲线

```
秒   CPU%          秒   CPU%
 2   32            34   67
 4   81            36   68
 6   19            38   79
 8   50            40   78
10   58            42   70
12   69            44   92   ← 峰值
14   77            46   60
16   85            48   86
18   77            50   81
20   85            52   83
22   81            54   68
24   79            56   71
26   72            58   90
28   73            60   79
30   90            62   80
32   63            64   69
```

平均 **~70%**，峰值 **92%**，未触顶。

### 3.4 温度曲线

| 传感器 | 打流前 | 峰值 | 打流后 1 分钟 |
|---|---|---|---|
| **CPU** | 53°C | **55°C** | 53°C |
| 2.4G 射频 | 62°C | **64°C** | 62°C |
| **5G 射频** | 56°C | **90°C** | 55°C |
| gephy | 54°C | 56°C | 54°C |

**5G 射频满载 +34°C，过后 1 分钟完全回落。CPU 只涨 2°C。**

---

## 4. 安全性判据（三条，各自独立）

### 4.1 温控器一级都没触发（最硬）

```
thermal/cooling_device0: ath11k_thermal  cur=0/100
thermal/cooling_device1: ath11k_thermal  cur=0/100
```

`max_state = 100`（100 级降额），`cur_state = 0`。
**打流 60 秒、5G 结温 90°C，一级降额都没用。**
如果进入危险区，`cur_state` 会 > 0，同时速率会掉。

### 4.2 距离降频点还有一半

| 阈值 | 值 | 当前最高 |
|---|---|---|
| cpu-thermal passive（降频） | 100°C | 55°C |
| cpu-thermal critical（关机） | 120°C | 55°C |
| ubi32 / top-glue / gephy critical | 120°C | 56°C |

CPU 满载只用到降频点温度的一半。

### 4.3 为什么热的是 5G 芯片而不是 CPU

- **2.4G 射频集成在 IPQ5018 内部**，与 CPU 同硅片 → 温度总是跟着 CPU
  （实测 CPU 53→55°C，2.4G 62→64°C，同步 +2°C）
- **5G 是独立 QCN6122**，自己的功放在 80MHz 满功率发射 → 结温 90°C

⇒ 单给 5G 加散热片有用，给 CPU 加没用（CPU 根本不热）。

---

## 5. 明确不做

| 想法 | 为什么不做 |
|---|---|
| 调 `trip_point` 温度 | 芯片厂定的值，改它只是自欺欺人，不改变物理 |
| 加风扇 | 板子无风扇接口，破壳改造违背「长期稳定家用」 |
| 降频保温度 | 无 cpufreq（频率锁定），根本做不到 |
| 限制发射功率降温 | 已在 BDF 硬限 24 dBm（见 P24），且 90°C 远未到危险区 |
| collectd + luci-app-statistics | 依赖链太重（rrdtool），本板 55MB 可用内存，为一个温度不值 |

---

## 6. 踩到的三个坑（都已在脚本里防住）

### 6.1 源文件末尾无换行 ⇒ heredoc 结束标记失效

```
return { wta301: methods };UCODE_EOF_WTA301     ← 粘在一起
/etc/init.d/rpcd restart; sleep 2                ← 后续 shell 行被吞进目标文件
```

表现是 ucode 报 `Syntax error: return must be inside function body`。
`deploy-sensors.sh` 现在先检查每个源文件末字节，不是 `\n` 就拒绝执行。

### 6.2 板子没有 base64 / nl

busybox 未编译这两个。传文件只能走 heredoc，编号只能 shell 循环。

### 6.3 `setsid` 是 busybox 版，不支持 `-f`

```
setsid: unrecognized option: f
Usage: setsid [-c] PROG ARGS
```

想在板上跑后台采集，只能让 SSH 连接阻塞到采集结束（`sh /tmp/monrun.sh`），
不能靠 `setsid ... &` 脱离 —— 脱离后脚本会因为 stdin 是 `sh -s` 的管道而失败。

⇒ **跨重启保留的日志一律写 `/overlay`**（`/tmp` 是 tmpfs）。
