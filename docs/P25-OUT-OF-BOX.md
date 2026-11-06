# P25 —— 开箱即用：把调优烧进固件，而不是让用户 shell 调试

> 起因（用户原话）：
> 「我们这样做不到开箱即用啊，不应该是刷写后就是最优状态吗，
> 难道还得每个人 shell 调试？不现实」

P24 之前的所有无线/RPS 调优**只存在于板上 overlay 和我的 shell 历史里**。
刷一次机、或用户点一下「恢复出厂设置」，全部丢失，回到出厂默认。
这等于把调试成本转嫁给用户 —— P25 把它们全部搬进 rootfs。

---

## 1. 判据：什么叫「开箱即用」

刷完机、不做任何 shell 操作，以下**全部自动成立**：

| # | 判据 | 验证方法 |
|---|---|---|
| O1 | 5G 跑 161 / HE80 / cell_density 2 | `iw dev phy1-ap0 info` |
| O2 | 2.4G 跑 6 / HT40（40MHz 生效）/ cell_density 2 | `iw dev phy0-ap0 info` 显示 `width: 40 MHz` |
| O3 | 四个接口 `rps_cpus=3`，且 `wifi reload` 后仍是 3 | `cat /sys/class/net/*/queues/rx-0/rps_cpus` |
| O4 | `rps_sock_flow_entries=4096`、`netdev_max_backlog=1000` | `cat /proc/sys/net/core/...` |
| O5 | `/etc/init.d/rps` 已 enable（S99rps 链接存在） | `ls -l /etc/rc.d/S99rps` |
| O6 | SSID / 密码 / 双频都起得来 | 手机能连上两个 SSID |
| O7 | 「恢复出厂设置」后再重启，O1~O6 依然成立 | 板上操作后复查 |

**判据 O3 是重点**：这是唯一一项「写了不等于生效」的调优，踩过 4 次坑（见 §3）。

---

## 2. 落地位置（单一来源，不用 sed 打补丁）

| 内容 | 仓库路径 | 装到编译树 |
|---|---|---|
| RPS 守护 | `files-rootfs/usr/sbin/rps-watch` | `/root/ow2512/files/usr/sbin/` |
| RPS 服务 | `files-rootfs/etc/init.d/rps` | `/root/ow2512/files/etc/init.d/` |
| 开机链接 | （由 `apply-to-2512.sh` 建） | `/root/ow2512/files/etc/rc.d/S99rps` |
| RPS 内核参数 | `files-rootfs/etc/sysctl.d/99-wta301-rps.conf` | `/root/ow2512/files/etc/sysctl.d/` |
| **无线出厂配置** | `files-base-files/etc/config/wireless` | `target/linux/qualcommax/ipq50xx/base-files/etc/config/` |
| 无线兜底脚本 | `files-base-files/etc/uci-defaults/99-wta301-wireless` | 同上 `etc/uci-defaults/` |

**为什么分两个目录**

- `$T/files/`（`target/linux/qualcommax/files/`）是**内核源码 overlay** —— 放的是
  `drivers/net/dsa/realtek/*.c`、`arch/arm64/boot/dts/qcom/*.dts`，只在内核解包时铺。
- **rootfs** 文件必须进 `$(TOPDIR)/files/`，OpenWrt 在 base-files 和 package 之后
  把它覆盖进 `$(TARGET_DIR)`。
- `etc/config/wireless` 走 `base-files` 而不是 `files/`，是为了保持单一来源 ——
  否则同一份文件在两处存在，改一处不生效，排查会疯。

**为什么整份替换而不是 sed**：`apply-to-2512.sh` 里对 `base-files` 那两份文件
用 `cp -f` 整份覆盖。sed 打补丁依赖上游上下文，25.12.x 升一个小版本就可能失配，
而失配时 sed 静默不报错 —— 会得到一个「看起来构建成功但配置没进」的固件。

---

## 3. RPS 持久化的四个坑（全部实测，勿重犯）

RPS 是本次唯一「写了不等于生效」的项，前后失败 4 次：

| 方式 | 结果 | 原因 |
|---|---|---|
| `rc.local` | ✗ | 只在开机跑一次；`wifi reload` 重建 `phy*-ap*` 后 sysfs 被重置 |
| `/etc/hotplug.d/net/` | ✗ | hostapd 用 **netlink 直建** `phy*-ap*`，不发 net hotplug 事件（对 `br-lan`/`eth0` 有效） |
| `procd_add_reload_trigger network` | ✗ | 该宏监听 **`/etc/config/network` 文件变更**；而 `wifi reload` 走的是 `ubus call network reload`（`/sbin/wifi:44,48,55`），不产生 config.change 事件 |
| `ubus listen` | ✗ | 本 busybox 版本无输出，抓不到 hostapd 事件 |
| **常驻轮询守护** | ✓ | `/usr/sbin/rps-watch`，3 秒一轮 |

**为什么轮询可接受**：steady state 下每 3 秒只有 3 次 sysfs **只读**，实测 CPU
占用 0.0%；且只在值不等于目标时才写，避免无谓重建 flow 表。

**实测验证（2026-10 于本板）**

```
手工清零 →   phy0=0 phy1=0 br-lan=0 eth0=0
wifi reload 后 → phy0=3 phy1=3 br-lan=3 eth0=3   ✓
```

守护进程本体：`{rps-watch} /bin/sh /usr/sbin/rps-watch`（procd respawn 5s）。

**附带发现的 busybox 坑**：`for f in a \` + 续行 + `b; do` 在这块板的 ash 上
解析异常（实测输出错乱并报 `syntax error: unexpected end of file`）。
所有 `for ... in` 列表写成**单行**。

---

## 4. 无线配置取值依据

每一项都有实测出处，详见 `P24-WIFI-5G-PERF.md`：

| 项 | 值 | 依据 |
|---|---|---|
| 5G channel | `161` | CN 非 DFS 段；DFS 52-64 需 CAC，实测设 64 后 hostapd 循环 `DFS-CAC-START → DFS->DISABLED`，**AP 完全起不来** |
| 5G htmode | `HE80` | 本机客户端只支持 80MHz；开 160MHz 后信道 busy 0.4%→**63%**、expected 887→**551（-19%）** |
| 5G cell_density | `2` | 更激进 CCA 阈值，实测吞吐更高 |
| 2.4G channel | `6` | 邻居实测 ch1=4 / ch3=1 / ch4=1 / **ch6=0** / ch11=4 |
| 2.4G htmode | `HT40` + `noscan 1` | 不加 noscan 时被 `20/40 MHz operation not permitted ... based on overlapping BSSes` 压回 20MHz + CTS，实测仅 ~20 Mbps |
| txpower | **不设置** | BDF 硬限 24 dBm；设 24~33 都回落 24.00，设 20 才生效。不写 = 驱动默认 = 上限 |
| country | `CN` | CN 的 5G 上限 33 dBm 全球最高档；改国家码**不能**提功率（实测都 24），只影响信道可用性（JP/DE 禁用 161） |

### 已知权衡（写在这里，不隐瞒）

**`noscan='1'` 是强行占用 40MHz**：无视邻居重叠，在密集住宅区会互相干扰。
本机实测 20MHz 时 66/49/26 Mbps，40MHz 的对比数据待补。
若实测无提升，应改回 `htmode HT40` 去掉 `noscan`（此时自动回落 20MHz）。

---

## 5. 未放进固件的东西（及理由）

| 项 | 为什么不烧 |
|---|---|
| `iperf3` | 测试工具，不是产品功能。用户需要时 `apk add iperf3` |
| adblock 及其 feed | 357k 域名会吃 40MB（可用内存 23%），属用户自选 |
| zram 参数调整 | 已由 `98-wta301-zram` 固化（P14） |
| 按键 / LED | 已由 `board.d/90_wta301` 固化（P17） |

---

## 6. 复现步骤

```bash
git clone <repo> && cd wta301-2512
cd /path/to/openwrt-25.12.6            # 见 docs/REPRODUCE.md
cp wta301-2512/pin/ow2512-dot-config.txt .config
bash wta301-2512/deliver/apply-to-2512.sh     # 含 §5e §5f 两段
make -j$(nproc) world && make -j$(nproc) target/install
```

`apply-to-2512.sh` 的输出里应能看到：

```
== 5e. rootfs overlay（RPS 守护 + sysctl + rc.d）==
  files//etc/rc.d/S99rps
  files//etc/sysctl.d/99-wta301-rps.conf
  files//etc/init.d/rps
  files//usr/sbin/rps-watch
== 5f. base-files 整份替换（无线出厂最优值）==
      option channel '161'
      option noscan '1'
```

---

## 7. 验收清单（刷机后按顺序跑）

```sh
# O1 5G
iw dev phy1-ap0 info | grep -E 'channel|txpower'      # 161 (5805 MHz), width 80 MHz
# O2 2.4G
iw dev phy0-ap0 info | grep -E 'channel|txpower'      # 6 (2437 MHz), width 40 MHz, center1 2447
# O3 RPS
for i in phy0-ap0 phy1-ap0 br-lan eth0; do
  echo "$i = $(cat /sys/class/net/$i/queues/rx-0/rps_cpus)"; done   # 全 3
# O3+ 持久性
echo 0 > /sys/class/net/phy1-ap0/queues/rx-0/rps_cpus; sleep 5
cat /sys/class/net/phy1-ap0/queues/rx-0/rps_cpus                    # 回到 3
# O4
cat /proc/sys/net/core/rps_sock_flow_entries                        # 4096
# O5
ls -l /etc/rc.d/S99rps                                              # -> ../init.d/rps
# O7 恢复出厂后复查（LuCI: 系统 → 备份/升级 → 恢复出厂）
```
