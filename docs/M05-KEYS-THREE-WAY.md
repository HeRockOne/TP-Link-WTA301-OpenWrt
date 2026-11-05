# M05 修正 — 物理按键：三方比对（含原厂），推翻我此前的判断

日期：2026-11-05
触发：用户质疑「我记得 S7 没有配置按键？看看原厂」
结论：**用户正确**。我此前说「S7 是 INPUT=m ⇒ 我们缺配置」是**错的** ——
S7 的 `.config` 有 `=m` 但 **rootfs 里一个模块都没有**，按键在 S7 上从来就没工作过。

---

## 三方逐层表（AGENTS §-1）

| 层 | 原厂（QSDK 4.4.60） | S7（OpenWrt 6.18.55） | 我们（25.12.6 / 6.12.112） |
|---|---|---|---|
| **DTB `keys` 节点** | 参考板 DTB 里有 `gpio_keys`，按键是 **gpio38 wps**（`0x07 0x26 0x01`），非本板 | **有**：`key-reset { gpios = <&tlmm 20 GPIO_ACTIVE_LOW>; linux,code = <KEY_RESTART> }`、`key-wps { gpios = <&tlmm 17 ...>; linux,code = <KEY_WPS_BUTTON> }` | **有**，与 S7 逐字相同 |
| **内核 config** | 私有 QSDK，未见 `CONFIG_INPUT*` 痕迹 | `CONFIG_INPUT=m`、`CONFIG_INPUT_EVDEV=m`、`CONFIG_KEYBOARD_GPIO=m` | **`# CONFIG_INPUT is not set`** |
| **vmlinux 内建** | — | `nm vmlinux \| grep -iE 'gpio_keys_probe\|evdev_init'` → **空**（未内建） | **0 命中**（未内建） |
| **rootfs 模块** | 42 个，无 `input*.ko` / `evdev.ko` / `gpio_keys.ko`；有 **`slp_gpio.ko`** | 76 个，**零 input 相关**（`ls \| grep -icE 'input\|evdev\|keyboard\|gpio_key'` = 0） | 74 个，零 input 相关 |
| **用户态** | `kmod-gpio-slp` 自述 **"Kernel modules for GPIO button and leds"**；`/bin/dms` 打开 **`/dev/slp_gpio_chrdev`** 并 `insmod slp_gpio.ko` | `/etc/rc.button/{reset,wps,…}` 存在（`procd` 的按钮分发器） | 同 S7，`/etc/rc.button/` 六项齐全 |
| **按键是否真能用** | **能**（TP-Link 私有字符设备 + `dms` 守护进程） | **不能**（设备从未注册：无模块、vmlinux 未内建） | **不能**（同 S7） |

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

## 结论

- **S7 的物理按键从未工作**（用户记忆正确）。
- 我们当前状态**与 S7 等价**：按钮设备不存在，`/etc/rc.button/*` 是死代码。
- 「长按 reset 恢复出厂」这条免串口救援路径，在 S7 和我们现在都**不存在**。
  但 `factoryreset -y`（SSH 里敲）在 P11 已验证可用 ⇒ 救援并非完全无路。

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
