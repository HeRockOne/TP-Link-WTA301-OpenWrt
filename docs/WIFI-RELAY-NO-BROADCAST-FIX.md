# 5G 无线中继「不广播」根因与修法

真机实证：2026-11-07，WTA301 / OpenWrt 25.12.6（r33311-981c978eff，内核 6.12.112），
SSID 来自邻居 `TP-LINK_5G_9ED9`（BSSID `DC:FE:18:B6:9E:DB`，5745 MHz = ch149）。

## 1. 症状

- LuCI 里配了 5G 中继（`mode=sta`），能扫描到邻居 SSID，但**自家 5G 不广播**
- `iw dev` 里**没有** `phy1-sta0`
- `iwinfo phy1-ap0 info` → **`Channel: 0 (unknown GHz)`**
- 2.4G 正常

## 2. 根因（三条，缺一不可）

### 根因 A：STA 接口被拖进网桥 → `BRIDGE_NOT_ALLOWED`

```
daemon.notice netifd: radio1 (2462): wifi-scripts: Preparing interface: phy1-sta0 with MAC: 9a:97:cc:a8:1f:ea
daemon.notice netifd: radio1 (2462): wifi-scripts: Device setup failed: BRIDGE_NOT_ALLOWED
daemon.notice netifd: radio1 (2462): BRIDGE_NOT_ALLOWED
```

配置是 `wireless.wifinet2.network='wwan lan'`。
`lan` 是 `br-lan` 网桥，而 **STA 模式的接口不允许加入网桥**（mac80211/ath11k 限制）
⇒ wifi-scripts 直接放弃创建 `phy1-sta0`。

**修法**：`option network 'wwan'`（只挂 wwan，靠路由 + NAT 转发）。

### 根因 B：信道写死 → AP 拿不到信道

`wireless.radio1.channel='149'` 写死。
同射频 AP+STA 时，STA 必须与上游 AP 同信道，AP 只能跟随 STA 决定的信道。
写死就冲突，AP 停在 `Channel: 0`。

**外部依据** [forum.openwrt.org/t/mixing-multiple-ap-and-sta-interfaces-on-the-same-hardware-radio/140217](https://forum.openwrt.org/t/mixing-multiple-ap-and-sta-interfaces-on-the-same-hardware-radio/140217)：
> "If you have a single radio that will operate in STA + AP modes, you will need to set the channel to auto."
> "the STA must come up first or else the AP mode cannot operate (because of the channel dependency)."

**修法**：`option channel 'auto'`。

### 根因 C：wwan 留在 LAN firewall zone → 能连不能上网

`firewall.@zone[0].network='lan' 'wwan'` ⇒ wwan 在 LAN zone，**没有 masquerade**。
LAN 客户端拿 `192.168.1.x` 直接从 wwan 出去，上游路由器不知道回程路由。

**修法**：wwan 移进 `wan` zone（`masq=1`、`mtu_fix=1`），`lan → wan` forwarding。

## 3. 附带坑：`wifi reload` 在 ath11k 上不可靠

改了 AP 密码后执行 `wifi reload`：

```
daemon.notice netifd: radio1 (3852): wifi-scripts: Starting
daemon.notice netifd: radio1 (3852): command failed: Not supported (-95)
daemon.notice netifd: radio1 (3852): command failed: Not supported (-95)
（之后 phy1-ap0 再没有 AP-ENABLED）
```

`phy1-ap0` 又变回 `Channel: 0 (unknown)`。

**修法**：`wifi down; sleep 3; wifi up`（整组重启）。外部依据 [openwrt#24294](https://github.com/openwrt/openwrt/issues/24294)。

## 4. 修好后实测

```
iw dev
  phy1-sta0  managed  channel 149 (5745 MHz), width: 80 MHz   ← 已关联
  phy1-ap0   AP       channel 149 (5745 MHz), width: 40 MHz   ← 有信道了
  phy0-ap0   AP       channel 11  (2462 MHz), width: 20 MHz

iw dev phy1-sta0 link
  Connected to dc:fe:18:b6:9e:db
  SSID: TP-LINK_5G_9ED9  freq 5745.0  signal -80 dBm
  rx 26.0 MBit/s VHT-MCS 1 NSS 2 / tx 6.0 MBit/s

iwinfo phy1-ap0 info
  Channel: 149 (5.745 GHz)  Encryption: WPA-PSK (CCMP)

ubus call network.interface.wwan status
  "up": true   "address": "192.168.0.122"   nexthop 192.168.0.1

ping 192.168.0.1 → 0% loss
ping 223.5.5.5  → 0% loss    ← 真能上网

hostapd: phy1-ap0: interface state COUNTRY_UPDATE->ENABLED
hostapd: phy1-ap0: AP-ENABLED
hostapd: phy1-ap0: AP-STA-CONNECTED 82:7e:05:ea:e7:aa
  assoclist: 82:7E:05:EA:E7:AA  -43 dBm  RX 130.0 MBit/s / TX 180.0 MBit/s（本机近距离）
```

**重启后依然正常**（这才是「之前可以、后来不行」的关键验证）：
reboot → 36 秒后 `phy1-sta0` 关联、`phy1-ap0` AP-ENABLED on ch149、wwan 拿到 IP。

## 5. 落地工具

`files-rootfs/usr/sbin/wta301-relay`（构建后进 rootfs 的 `/usr/sbin/wta301-relay`，权限归一化会设 0755）

```
wta301-relay scan                     # 列附近 5G AP（SSID/信道/信号/加密）
wta301-relay set <SSID> <密码> [AP密码]  # 一键配置，4 个坑全规避
wta301-relay status                   # 状态（AP Channel=0 会主动告警）
wta301-relay off                      # 关闭中继，回普通 AP
```

`status` 里对 `Channel: 0` 有显式告警，因为那是「不广播」的标志性故障。

## 6. 判据（给验收脚本用）

| 检查 | 通过条件 |
|---|---|
| STA 接口存在 | `iw dev` 输出含 `phy1-sta0` |
| STA 已关联 | `iw dev phy1-sta0 link` 含 `Connected to` |
| AP 有信道 | `iwinfo phy1-ap0 info` 的 Channel **不是** `0` |
| AP 在广播 | `logread` 含 `phy1-ap0: AP-ENABLED` 且之后无 `AP-DISABLED` |
| wwan 通 | `ubus call network.interface.wwan status` → `"up": true` 且有 address |
| NAT 生效 | `nft list ruleset \| grep -c masquerade` ≥ 1 |
| 真能上网 | `ping -c2 223.5.5.5` 通 |

## 7. 已知限制

- 同射频 AP+STA ⇒ 实际吞吐减半（半双工，STA 与 AP 抢同一信道时间片）
- 上游 −80 dBm 时 rx 只有 26 Mbit/s，是链路预算限制，不是软件问题
- 上游掉线时 AP 也起不来（信道依赖），需要 `travelmate` 之类做切换；本板未装
