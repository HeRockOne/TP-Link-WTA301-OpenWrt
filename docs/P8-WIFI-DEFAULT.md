# P8 第 1 轮：有线通过，Wi-Fi 默认启用未生效（已定位根因）

日期：2026-11-05　刷写日志：`work/evidence/p8-flash.log`、`p8-flash2.log`
冷启动日志：`work/evidence/p8-coldboot.log`

## 一、刷写结果：真校验全过

| 区 | 期望 crc32 | RAM | NAND 回读 | 结论 |
|---|---|---|---|---|
| kernel | `4131c6d0` | `4131c6d0` | `4131c6d0` | ✅ |
| rootfs | `0b6efbcb` | — | `0b6efbcb` | ✅ |
| ubi overlay | `56ac6282` | — | `56ac6282` | ✅ |
| tphdr | `c94a5c83` | — | `c94a5c83` | ✅ |

合计 5/5（kernel 组）+ 15/15（rootfs/ubi/tphdr 组）全部通过。
`uboot_flash.py` 的假校验 bug 已修（见 §四）。

## 二、冷启动判决

- `Linux version 6.12.112`，`tplboot: image_2 kernel 0x480000 @0x04880000 -> 0x44000000`（A 槽）
- `RTL8367S: chip 0x6367 ver 0x00a0`，`uniphy pll=0x00000ac1 locked=1`
- `lan1: Link is Up - 100Mbps/Full`，`br-lan: port 1(lan1) entered forwarding state`
- **`ping 192.168.1.100` → 2 packets transmitted, 2 received, 0% packet loss** ✅
- ❌ 无 `phy0-ap0` / `phy1-ap0`；`/etc/config/wireless` 里仍是 `option disabled '1'`

## 三、Wi-Fi 未启用：根因（已实证）

`/etc/init.d/boot` 的执行顺序：

```
 48:  [ -f /etc/board.json ] && /sbin/wifi config     ← 先
 52:  uci_apply_defaults                              ← 后
```

而 ath11k 是**模块**，dmesg 显示两个 phy 分别在 16~22 秒才 probe
（`ath11k c000000.wifi: ipq5018 hw1.0`、`ath11k b00a040.wifi: qcn6122 hw1.0`）。

⇒ 第 48 行执行时 phy 还不存在，`wifi config` 不生成任何文件，
`/etc/config/wireless` 在那一刻**根本不存在**
⇒ 我的脚本首行 `[ -f /etc/config/wireless ] || exit 0` 直接退出，
一个 `uci set` 都没执行。

等 phy 出现后，hotplug 才补生成那份带 `option disabled '1'` 的配置
（wifi-scripts 的安全默认）。

### 证据链

1. `/etc/uci-defaults/` 为空 ⇒ 脚本确实被执行过（`uci_apply_defaults` 成功后才 `rm -f`）
2. `sh -x /rom/etc/uci-defaults/99-wta301-wireless` 手工跑：
   逐条 `uci set 'wireless.radio0.disabled=0'` … 全部执行成功，脚本逻辑无误
3. 冷启动后 `/etc/config/wireless` 仍是 `option disabled '1'`、`ssid 'OpenWrt'`
   ⇒ 生效的是 hotplug 生成的默认值，不是我的脚本

## 四、顺带修掉的工具 bug（假校验）

`work/scratch/uboot_flash.py` 原来判 crc32 只看：

```python
ok = 'OK' in out or re.search(r'crc32 for .* is [0-9a-f]{8}', out)
```

两个问题：

1. u-boot 实际输出是 `crc32 for 43000000 ... 4347ffff ==> 4131c6d0`（用 `==>`），
   正则只认 ` is ` ⇒ **正确写入也被判 FAIL**（首轮就在这里中止，而值明明是 `4131c6d0`）。
2. 更严重：它只检查"输出里有 crc32 字样"，**从不与 FINGERPRINT.json 比对数值**
   ⇒ 即使写坏了也判 ok，属于假校验。

修法：从 `==>`（兼容 ` is `）解析出实得值，与 `FINGERPRINT.json` 里该文件的
`crc32` **逐区相等**才算通过；不相等时把期望/实得打进 tag。

## 五、修复方案

改用 S7 的做法：**把 `base-files/etc/config/wireless` 固化进 rootfs**。
依据是三方差异表 L6 行 —— S7 的 `wireless` / `network` / `system` 都是 rootfs 固化，
我们原来靠首启生成，属于结构差异（当时判"无害"，现在看对 Wi-Fi 是有害的）。

固化后由 fstools 首启 seed 到 overlay，第 48 行的 `wifi config` 会按
`option path` 匹配到已有段，不会重建。`uci-defaults` 脚本降级为兜底
（有人 `rm /etc/config/wireless` 时管用），并写明上述原因。

配置内容与 S7 基线逐项一致：

| | radio0 | radio1 |
|---|---|---|
| band | 2g | 5g |
| channel | 6 | 36 |
| htmode | HT40 | HE80 |
| country | CN | CN |
| ssid | `OpenWrt-WTA301` | `OpenWrt-WTA301-5G` |
| encryption | psk2 | psk2 |
| key | `123456789` | `123456789` |

> 默认 PSK 与 S7 相同，属"已知密码"。首次登录后应自行修改：
> `uci set wireless.default_radio0.key='新密码'` 等。
