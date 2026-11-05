# P17 真机验证通过 — Argon 主题 + 界面锁中文 + 按键归因修正

日期：2026-11-05
固件：25.12.6 r33311-981c978eff / Linux 6.12.112
证据：`work/evidence/p17-flash.log`（21/21）· `p17-verify.txt` · 本文 §3 按键实测

---

## 1. 指纹（四区三列 crc32 全等）

| 区 | 偏移 | 长度 | crc32 | md5 |
|---|---|---|---|---|
| kernel | `0x480000` | `0x480000` | **`4131c6d0`** | `842d204e915a4660541e964229e21f09` |
| rootfs | `0x4fc0000` | `0xbc0000` | `0112e226` | `a1881bccea236586f0da775659db0426` |
| ubi overlay | `0x1bc0000` | `0x1e0000` | `c8ca6022` | `73b079fbbcddafd43620ecb1fdb4977a` |
| tphdr | `0x4800000` | `0x20000` | `d343b30c` | `7cf8185682493b95115f1c81b5388f85` |

**kernel crc32 与 P11 完全相同（`4131c6d0`）= 自校验成功。**
本轮只动用户态（主题 + uci-defaults），内核一个字节没变。这与 P16 的
`4131c6d0` 一致，说明「P17 相对 P16」的差异全部落在 rootfs：

| | P16 | P17 |
|---|---|---|
| kernel | `4131c6d0` | `4131c6d0`（同） |
| rootfs | `51a8d52d` | `0112e226` |
| ubi | `c212ff9a` | `c8ca6022` |
| tphdr | `fed69cb4` | `d343b30c` |

产物：`work/images/v25.12.6-P17/` · `/root/rel/P17/` · `FINGERPRINT.json`

## 2. 验收 11 项（全部通过）

```
DISTRIB_RELEASE='25.12.6'  DISTRIB_REVISION='r33311-981c978eff'  uname -r=6.12.112

uci get luci.main.lang          -> zh_cn                    ← 锁定成功
uci get luci.main.mediaurlbase  -> /luci-static/argon         ← Argon 为默认主题
/www/luci-static/argon/css/cascade.css  267675 B
/www/luci-static/bootstrap             存在（逃生门）
/usr/lib/lua/luci/i18n/         -> argon-config / base / firewall / package-manager (.zh-cn.lmo)

lsmod                           -> gpio_button_hotplug 16384 0
/sys/bus/platform/drivers/gpio-keys/ -> bind keys module uevent unbind
/sys/firmware/devicetree/base/keys/compatible -> gpio-keys
/proc/bus/input/devices         -> No such file or directory   ← 正确（开了会抢设备）
/etc/rc.button/                 -> failsafe power reboot reset rfkill wps
grep -c 'FACTORY RESET' /etc/rc.button/reset -> 1

MemAvailable 69712 kB · MemFree 48740 kB · Cached 29872 kB · min_free_kbytes 4096
br-lan: port 7(phy1-ap0) entered forwarding state
br-lan: port 6(phy0-ap0) entered forwarding state

distfeeds.list -> 7 行
/dev/ubi0_0  27.9M  72.0K  used  27.8M avail
```

## 3. 按键现场实测（P17）

把 `/etc/rc.button/reset` 临时换成只记日志的探针（原脚本备份 `/root/reset.orig`），
`logread -f > /tmp/btn.log`，人手按 RESET 1 秒：

```
Sat Oct 17 21:55:59 2026 user.notice BTNTEST: RESET action=pressed  seen=0
Sat Oct 17 21:56:00 2026 user.notice BTNTEST: RESET action=released seen=1
```

测完已还原：`md5 /etc/rc.button/reset` = `bc5c03efd93164372219c79c5bada8c6`，
`grep -c 'FACTORY RESET'` = 1。

## 4. 本轮改了什么（相对 P16）

1. **Argon 主题 v3.1.0** 进固件（`luci-theme-argon=y`），Bootstrap 保留作兜底。
   Argon 自己的 `30_luci-theme-argon` 会写 `luci.themes.Argon` 与
   `luci.main.mediaurlbase=/luci-static/argon`，无需额外脚本。
2. **界面语言锁中文**：新增 `deliver/ipq50xx-base-files/etc/uci-defaults/97-wta301-luci-lang`
   → `uci set luci.main.lang='zh_cn'`。值必须是**下划线**形式，依据
   `feeds/luci/modules/luci-base/ucode/dispatcher.uc:83-110`（非 auto 时
   `replace(lang,'_','-')` 再找 `base.zh-cn.lmo`）。
3. **`WITH_KEYS` 归零 + 原理重写**：见 `docs/M05-KEYS-THREE-WAY.md` 文首「第二次修正」。

## 5. 已知小冗余（不改）

`CONFIG_PACKAGE_luci-i18n-argon-config-zh-cn=y` 被 `LUCI_LANG_zh_Hans` 自动选中，
但 `luci-app-argon-config` 包在 v3.1.0 里**不存在**（设置已折进主题的 uci-defaults）。
⇒ 多一个约 2 KiB 的孤立 `argon-config.zh-cn.lmo`，无消费者，无害。
后续清理时 `del_pkg_sym CONFIG_PACKAGE_luci-i18n-argon-config-zh-cn` 即可，
不值得为 2 KiB 单开一轮构建（AGENTS §2）。

## 6. 未做（用户已决策）

- **无独立 WAN 是有意设计**：本板 4×1GbE WAN/LAN 盲插，
  `deliver/ipq50xx-base-files/etc/board.d/90_wta301:31` 把 5 个 DSA 口全桥进 `br-lan`，
  任何口插上都是 192.168.1.1。要让 `apk add` 通外网，需要再加一个 WAN 口或改桥接方式，
  这是**新变量**，需单开一轮。
- `/etc/rc.button/reset` 的 `SEEN>=5` 会 `factoryreset`（OpenWrt 默认）。原厂 TP-Link 一般 10 秒。
  是否改宽属产品决策，本轮未动。
- 默认 WiFi 密码仍是 S7 的 `123456789`，待改。
