# M05 修正 — 物理按键：三方比对（含原厂），推翻我此前的判断

日期：2026-11-05
触发：用户质疑「我记得 S7 没有配置按键？看看原厂」
结论：**用户正确**。我此前说「S7 是 INPUT=m ⇒ 我们缺配置」是**错的** ——
S7 的 `.config` 有 `=m` 但 **rootfs 里一个模块都没有**，按键在 S7 上从来就没工作过。

---

## ⚠️ 第二次修正（2026-11-05 晚，实测 P16）：本文下半部分的「我们**不能**」是错的

触发：用户质问「你没让我按键啊，为什么不顺手呢」。上板实测后推翻了本文结论。

**P16（已在板子上跑的固件）按键完全可用**，实测串口日志：

```
BTNTEST: RESET action=pressed  seen=0     ← gpio20 / KEY_RESTART
BTNTEST: RESET action=released seen=1
BTNTEST: WPS   action=released seen=1     ← gpio17 / KEY_WPS_BUTTON
```

**我漏掉的那一环：`kmod-gpio-button-hotplug`。**

本文下半部分只搜了 `input*.ko` / `evdev.ko` / `gpio_keys.ko`，命中 0 就断言「按键不可能工作」。
但 OpenWrt 根本不走 input 子系统。`package/kernel/gpio-button-hotplug/Makefile` 自述原文：

> This is a **replacement** for the following in-kernel drivers:
> 1) gpio_keys (KEYBOARD_GPIO) 2) gpio_keys_polled (KEYBOARD_GPIO_POLLED).
> Instead of generating input events (like in-kernel drivers do) it generates **uevent-s** and
> broadcasts them. This allows **disabling input subsystem** which is an overkill for OpenWrt
> simple needs.

它的 `of_device_id` 匹配表就是 `{ .compatible = "gpio-keys" }`（src 第 415-418 行），
与我们 DTS 的 `keys` 节点对应；而 `target/linux/qualcommax/Makefile:16` 的
`DEFAULT_PACKAGES` **早就带上了** `kmod-gpio-button-hotplug`。

### 实证链（P16，全部只读命令）

```
$ lsmod | grep -i button
gpio_button_hotplug    16384  0
$ ls /sys/bus/platform/drivers/gpio-keys/
bind  keys  module  uevent  unbind      ← 驱动已 bind 到 keys 设备
$ ls /sys/bus/platform/devices/ | grep keys
keys
$ cat /sys/firmware/devicetree/base/keys/compatible
gpio-keys
$ ls /sys/firmware/devicetree/base/keys/
compatible  key-reset  key-wps  name  pinctrl-0  pinctrl-names
```

用户态分发器也不在 `/etc/hotplug.d/button/`（该目录在 25.12.6 整个源码树里**不存在**，
所以「没这个目录 ⇒ 按键不工作」是个我犯过的误判），而在 procd 本体：
`plug/hotplug.c` 有 `HANDLER_BUTTON`（`.name = "button"`，
`handle_button_start` / `handle_button_complete` / `handle_button_timeout`），
规则写在 `package/system/procd/files/hotplug.json:70-73`：

```json
[ "has", "BUTTON" ],
[ "eq", "SUBSYSTEM", "button" ]
[ "button", "/etc/rc.button/%BUTTON%" ]
```

### 因此：`CONFIG_INPUT=y` 方案不但多余，还会**破坏**按键

P17 第一轮我按「选项 B」开了 `CONFIG_INPUT/INPUT_EVDEV/INPUT_KEYBOARD/KEYBOARD_GPIO/INPUT_MISC = y`，
内核 Image 因此 +65536 B。这不只是白胖：内建的 `gpio_keys` 驱动**同样**匹配 `"gpio-keys"` compatible，
开机时它先注册就抢走 `keys` 设备，`gpio_button_hotplug` 再也绑不上，
而 input 事件在 OpenWrt 用户态**没有任何消费者**（全树 `grep -r '/dev/input' package/` 只命中 busybox 的 Kconfig 文字）。
⇒ **开着 INPUT 反而是按键失效的那种配置。**

P17 最终配置：`WITH_KEYS=0`（内核回到 P11 的 `4131c6d0`），零改动即获得可用按键。

### `/etc/rc.button/reset` 的真实行为（25.12.6 base-files）

| 事件 | 条件 | 动作 |
|---|---|---|
| `pressed` | 有 `/overlay` | `return 5` ⇒ procd 起 5 秒超时定时器 |
| `timeout` | 按住满 5 秒 | `. /etc/diag.sh; set_state failsafe`（只改灯） |
| `released` | `SEEN -lt 1` | **重启**（`echo REBOOT > /dev/console; sync; reboot`） |
| `released` | `SEEN -ge 5` 且有 overlay | **`factoryreset -y && reboot`**（清空数据） |
| `released` | `1 ≤ SEEN < 5` | 什么都不做 |

`SEEN` = 按住秒数。**短按（<1s）会重启，长按（≥5s）会恢复出厂**，中间 1~4 秒是安全区。
这条 5 秒阈值是 OpenWrt 默认；若要更保守（原厂 TP-Link 一般 10 秒），
应改 `/etc/rc.button/reset` 的 `-ge 5`，属于后续决策项，本轮未改。

---

## 三方逐层表（AGENTS §-1）

| 层 | 原厂（QSDK 4.4.60） | S7（OpenWrt 6.18.55） | 我们（25.12.6 / 6.12.112） |
|---|---|---|---|
| **DTB `keys` 节点** | 参考板 DTB 里有 `gpio_keys`，按键是 **gpio38 wps**（`0x07 0x26 0x01`），非本板 | **有**：`key-reset { gpios = <&tlmm 20 GPIO_ACTIVE_LOW>; linux,code = <KEY_RESTART> }`、`key-wps { gpios = <&tlmm 17 ...>; linux,code = <KEY_WPS_BUTTON> }` | **有**，与 S7 逐字相同 |
| **内核 config** | 私有 QSDK，未见 `CONFIG_INPUT*` 痕迹 | `CONFIG_INPUT=m`、`CONFIG_INPUT_EVDEV=m`、`CONFIG_KEYBOARD_GPIO=m` | **`# CONFIG_INPUT is not set`** |
| **vmlinux 内建** | — | `nm vmlinux \| grep -iE 'gpio_keys_probe\|evdev_init'` → **空**（未内建） | **0 命中**（未内建） |
| **rootfs 模块** | 42 个，无 `input*.ko` / `evdev.ko` / `gpio_keys.ko`；有 **`slp_gpio.ko`** | 76 个，**零 input 相关**（`ls \| grep -icE 'input\|evdev\|keyboard\|gpio_key'` = 0） | 74 个，零 input 相关 |
| **用户态** | `kmod-gpio-slp` 自述 **"Kernel modules for GPIO button and leds"**；`/bin/dms` 打开 **`/dev/slp_gpio_chrdev`** 并 `insmod slp_gpio.ko` | `/etc/rc.button/{reset,wps,…}` 存在（`procd` 的按钮分发器） | 同 S7，`/etc/rc.button/` 六项齐全 |
| **按键是否真能用** | **能**（TP-Link 私有字符设备 `slp_gpio` + `dms` 守护进程） | **不能**（设备从未注册：无 input 模块、vmlinux 未内建） | **能**（`gpio_button_hotplug` 树外模块；本行原写「不能」已被文首第二次修正推翻） |

### 实证

1. S7 rootfs 模块实测：

```
$ ls /root/lp/tree/lib/modules/6.18.55/ | wc -l
76
$ ls /root/lp/tree/lib/modules/6.18.55/ | grep -icE 'input|evdev|keyboard|gpio_key'
0
```

2. S7 vmlinux 未内建（否则 `=m` 之外还有兜底）：

```
$ aarch64-linux-gnu-nm /root/kf/linux-6.18.55/vmlinux | grep -iE 'gpio_keys_probe|evdev_init|gpio_keys_driver'
（空）
```

3. 我们 P11 板上：

```
$ cat /proc/bus/input/devices
cat: can't open '/proc/bus/input/devices': No such file or directory
$ dmesg | grep -iE 'gpio-keys|input:'
（空）
$ ls /etc/rc.button/
failsafe  power  reboot  reset  rfkill  wps      ← 脚本在，但永远收不到事件
```

4. 原厂的按键路径是**完全不同的机制**（不是 input 子系统）：

```
$ cat fr/usr/lib/opkg/info/kmod-gpio-slp.control
Package: kmod-gpio-slp
Description:  Kernel modules for GPIO button and leds

$ strings fr/bin/dms | grep slp
/dev/slp_gpio_chrdev
insmod slp_gpio.ko
```

`slp_gpio.ko` 的字符串显示它注册的是自己的字符设备
（`slp_gpio_chrdev` / `slp_device2` / `class_create`），与 `gpio-keys`、`evdev` 无关。

5. 原厂 DTB 里的按键不是本板的：原厂 kernel（B 槽 `0x880000`，与
   `flash_full_128M.bin` 一致）内含 3 个 DTB，model 分别为
   `IPQ5018/AP-MP03.3`、`AP-MP03.1`、`AP-MP02.1`，都是 QSDK 参考板；
   带 `gpio_keys` 的那个是 `AP-MP03.3`，其按键为 **gpio38 / KEY_WPS_BUTTON**。

---

## 结论（已被文首「第二次修正」推翻，保留原文以存档判断过程）

- **S7 的物理按键从未工作**（用户记忆正确）。
- ~~我们当前状态与 S7 等价：按钮设备不存在，`/etc/rc.button/*` 是死代码。~~
  **错**：`gpio_button_hotplug` 在 P16 上已 bind，`/etc/rc.button/*` 是活代码，双键实测有事件。
- ~~「长按 reset 恢复出厂」这条免串口救援路径，在 S7 和我们现在都不存在。~~
  **错**：P16 上存在且可用（`SEEN>=5` ⇒ `factoryreset -y`）。
- 仍然成立的部分：S7 自己没有这条路径；原厂走私有 `slp_gpio`，与我们的机制不同。

## 因此

启用 `CONFIG_INPUT` / `CONFIG_KEYBOARD_GPIO` **不是「恢复基线」，而是「超越基线的改进」**。
按 AGENTS §2.2（未在真机验证过的组件不得叠加进实验）与 §-1 规则 6（S7 缺少实证必须写明），
是否采纳需要显式决定，不能默默加进交付。

两种选项：

| 选项 | 内容 | 优点 | 代价 |
|---|---|---|---|
| **A：保持与 S7 严格一致** | 不启用，撤回 `apply-to-2512.sh` 里的 4 行 | 零风险；`files/` 与 S7 逐字节对齐 | 恢复出厂只能走 SSH；物理按键无用 |
| **B：启用为改进项** | `CONFIG_INPUT=y` / `INPUT_EVDEV=y` / `KEYBOARD_GPIO=y` / `INPUT_MISC=y` | reset/wps 真正可用；多一条免串口救援路径 | 偏离基线；仍需现场按一次才能最终确认 GPIO 映射 |

若选 B，可远程验证到「设备已注册」这一步（不需按键）：

```
ls /proc/bus/input/devices          # 应出现 gpio-keys
dmesg | grep gpio-keys              # 应有 probe 成功
cat /proc/bus/input/devices | grep -A2 -i keys
```

最终仍需现场按一次以确认 label 与物理键对应。