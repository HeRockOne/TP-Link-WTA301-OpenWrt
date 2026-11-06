# P17 — Argon 主题 + 界面语言锁定 + 物理按键

> 用户指令（2026-11-05）：主题刷进固件用 `luci-theme-Argon`，默认的 Bootstrap
> 可以抛弃；界面语言锁成中文；验证 reset/WPS 按键；全部写进固件。
> 验收看 `uci get luci.main.lang` = `zh_cn`、`luci.main.mediaurlbase` = `/luci-static/argon`、
> `ls /sys/bus/platform/drivers/gpio-keys/keys` 存在（**不是** `/proc/bus/input/devices`，
> OpenWrt 的按键不走 input 子系统，见 §4）。
>
> 本轮三个改动都是**用户态可独立验证**的，不构成「混变量」：
> 按键看 `dmesg`/`/proc/bus/input/devices`，主题看页面，语言看 `uci get luci.main.lang`。

## 0. 为什么用 `luci-theme-argon` 而不用官方 feed 里的主题

### 外部检索结果（AGENTS §0 外部优先）

| 查什么 | 结论 | 出处 |
|---|---|---|
| 25.12.6 luci feed 有哪些主题 | **5 个**：bootstrap / footstrap / material / openwrt / openwrt-2020，**没有 Argon** | 本地 `feeds/luci/themes/` 与 `tmp/.config-package.in` 实测 |
| Argon 能否在 25.12 跑 | **v3.1.0 可以**。官方 CI「builds APK v3 with the **25.12.5 SDK**」；模板以源码发布（`LUCI_MINIFY_UT:=0`）避免绑死 ucode 字节码格式 | `github.com/jerrykuku/luci-theme-argon` `docs/DEVELOPMENT.md`、v3.1.0 release notes |
| 历史故障 | issue **#715**「v2.4.8 .apk won't install on stable OpenWrt 25.12 (requires ucode>=2026.02.27)」；issue **#660**「装完 Web 界面挂掉 `loop or previous error loading module 'luci.util'`」，报错版本 **v2.4.3** | github issues |
| 修法 | v2.4.8-r2 / v3.x 已修；v3 把配置功能并进主包，**不再需要 luci-app-argon-config** | v2.4.8 release notes |

**因此选 v3.1.0，且从源码编进树**（不是装第三方 .apk）——这样：
- 与树内 `luci-base` 同源编译，不存在跨版本 ABI 风险
- 不依赖第三方二进制供应链（长期家用安全）
- 离线可重建

### 取得方式（实测：WSL 直连 GitHub 失败）

```
WSL: git clone https://github.com/... -> GnuTLS recv error (-110): TLS connection non-properly terminated
Windows: Invoke-WebRequest https://codeload.github.com/jerrykuku/luci-theme-argon/tar.gz/refs/tags/v3.1.0
         成功，10,569,290 B
sha256: 5b504551ea6dcdc79a5103906240c26e4837e5d15902d8d52869d68bf24fb4f0
```

`apply-to-2512.sh` §5d 从 `/root/pkgsrc/luci-theme-argon-v3.1.0` 拷进
`package/luci-theme-argon`。该目录不存在时只告警、不中断（并打印下载地址与 sha256）。

## 1. Argon 依赖与体积（实测编译产物）

`luci-theme-argon/Makefile`：

```make
LUCI_DEPENDS:=+luci-base +USE_APK:wget-any +!USE_APK:wget +jsonfilter \
              +ucode-mod-math +flock +coreutils +coreutils-timeout
LUCI_BASENAME:=argon-config
PKG_VERSION:=3.1.0
PKG_RELEASE:=20261022
CONFIG_LUCI_UTMIN:=
LUCI_MINIFY_UT:=0        # 模板发布源码，不预编译字节码
```

| 包 | .apk 大小 |
|---|---|
| `luci-theme-argon-3.1.0-r20261022` | **296,081 B** |
| `luci-i18n-argon-config-zh-cn` | 4,015 B |
| `coreutils-timeout` | 19,678 B |
| `flock` | 12,673 B |
| `jsonfilter` | 11,025 B |
| `ucode-mod-math` | 3,268 B |
| `coreutils` | 765 B（纯依赖元包） |
| `wget-*` | 已在树上（P16 未新增） |
| **合计新增** | **≈ 348 KiB** |

rootfs 预算：分区 `0xC00000`（12 MiB）− squashfs 本体 ≈ 3.5 MiB 余量 ⇒ **安全**。

### 中文语言包自动跟着来

`LUCI_BASENAME:=argon-config` ⇒ 语言包名 `luci-i18n-argon-config-zh-cn`。
`.config` 里只写了总开关 `CONFIG_LUCI_LANG_zh_Hans=y`，Kconfig 自动选中它
（实测 `make defconfig` 后 `.config` 里出现 `CONFIG_PACKAGE_luci-i18n-argon-config-zh-cn=y`）。

⚠️ **但 `luci-app-argon-config` 这个包在 v3.1.0 里不存在**（实测
`ls package/luci-app-argon-config` → 无此目录）。设置界面已折进主题自己的
`30_luci-theme-argon`（写 `argon.@global[0]` 的 `login_style` / `primary` /
`dark_primary` / `blur` / `transparency` / `mode` / `online_wallpaper`）。
所以这个 `=y` 只会落下一个**孤立 ~2 KiB 的 `.lmo`**（
`/usr/lib/lua/luci/i18n/argon-config.zh-cn.lmo`），没有任何消费者。
无害，但属于冗余；后续清理时显式关掉即可：

```sh
del_pkg_sym CONFIG_PACKAGE_luci-i18n-argon-config-zh-cn
```

不为了这 2 KiB 重开一轮构建 —— AGENTS §2「一次只改一个变量」。

## 2. 默认主题怎么生效（读 Argon 源码）

`root/etc/uci-defaults/30_luci-theme-argon`（节选）：

```sh
if [ "$PKG_UPGRADE" != 1 ]; then
	uci get luci.themes.Argon >/dev/null 2>&1 || \
	uci batch <<-EOF
		set luci.themes.Argon=/luci-static/argon
		set luci.main.mediaurlbase=/luci-static/argon
		commit luci
	EOF
fi
```

⇒ 装上即成为默认主题，不需要额外 uci-defaults。

### Bootstrap 为什么保留安装

用户说「默认的 Bootstrap 可以抛弃」。**当默认确实抛弃了**（`mediaurlbase` 指向
argon），但**包本身保留**（约 40 KiB）：

- 它是逃生门：Argon 若在某个后装插件页面上渲染失败，
  `uci set luci.main.mediaurlbase=/luci-static/bootstrap && uci commit luci` 立刻回到
  一个已知能用的界面 —— 不用重刷、不用接网线。
- 代价 40 KiB，占 rootfs 余量 1%。
- 真要彻底删：`apply-to-2512.sh` §5d 里去掉 `CONFIG_PACKAGE_luci-theme-bootstrap=y`。

## 3. 界面语言锁定（读 LuCI 源码定值）

`feeds/luci/modules/luci-base/ucode/dispatcher.uc:83-110`：

```uc
let lang = uci.get('luci', 'main', 'lang') || 'auto';
if (lang == 'auto') { ...按浏览器 Accept-Language 匹配 luci.languages 里注册的项... }
if (lang == 'auto') lang = 'en';
else lang = replace(lang, '_', '-');
...
load_catalog(lang, '/usr/lib/lua/luci/i18n');   // -> base.zh-cn.lmo
```

两个关键点：

1. **值必须带下划线** `zh_cn`，代码会把 `_` 换成 `-` 去找 `base.zh-cn.lmo`。
2. `luci-i18n-base-zh-cn` 自带的 uci-defaults **只注册、不锁定**：

```sh
uci set luci.languages.zh_cn='简体中文 (Simplified Chinese)'; uci commit luci
```

它往语言下拉框里加一项，`luci.main.lang` 仍是 `auto`。**浏览器是英文时界面还是英文**
——这就是「装了中文包但还是英文」的成因。

所以要真正锁定，新增
`deliver/ipq50xx-base-files/etc/uci-defaults/97-wta301-luci-lang`：

```sh
uci set luci.main.lang='zh_cn'
uci commit luci
```

命名 `97-` 是为了排在 Argon 的 `30_luci-theme-argon` 和 luci 的 i18n 注册之后。

## 4. 物理按键（结论推翻：P16 上已经能用，本轮**零改动**）

### 4.1 我错了两次，第二次是被用户逼着上板才发现的

第一次：`docs/M05-KEYS-THREE-WAY.md` 里我只搜 `input*.ko` / `evdev.ko` / `gpio_keys.ko`，
命中 0 就断言「按键是死代码」。
第二次：发现 `/etc/hotplug.d/button/` 不存在，又断言「没有分发器所以按键不响」——也错，
分发器在 procd 本体（`plug/hotplug.c` 的 `HANDLER_BUTTON`）。

**真相：OpenWrt 根本不用 input 子系统。**
`package/kernel/gpio-button-hotplug/Makefile` 自述：

> This is a **replacement** for the following in-kernel drivers: 1) gpio_keys (KEYBOARD_GPIO)
> 2) gpio_keys_polled (KEYBOARD_GPIO_POLLED). Instead of generating input events it generates
> **uevent-s** and broadcasts them. This allows **disabling input subsystem**.

它匹配的 `of_device_id` 就是 `{ .compatible = "gpio-keys" }`（src:415-418），
与 S7 给我们的 DTS `keys` 节点天然对应；而 `target/linux/qualcommax/Makefile:16` 的
`DEFAULT_PACKAGES` **一直就带着** `kmod-gpio-button-hotplug`。

### 4.2 P16 实测证据（只读命令 + 人手按一次）

```
$ lsmod | grep -i button
gpio_button_hotplug    16384  0
$ ls /sys/bus/platform/drivers/gpio-keys/
bind  keys  module  uevent  unbind     ← 已 bind
$ cat /sys/firmware/devicetree/base/keys/compatible
gpio-keys

# 人手按完（reset 先换成只记日志的探针）
BTNTEST: RESET action=pressed  seen=0
BTNTEST: RESET action=released seen=1
BTNTEST: WPS   action=released seen=1
```

完整链路：DTS `keys` → `gpio_button_hotplug` → uevent →
procd `HANDLER_BUTTON`（`hotplug.json:70-73` `[ "button", "/etc/rc.button/%BUTTON%" ]`）
→ `/etc/rc.button/{reset,wps}`。

### 4.3 所以 `WITH_KEYS=1` 必须取消（它会**弄坏**按键）

内建 `gpio_keys` 同样匹配 `"gpio-keys"` compatible，开机先注册就抢走 `keys` 设备，
`gpio_button_hotplug` 再也绑不上；而 input 事件在 OpenWrt 用户态没有消费者
（全树 `grep -r '/dev/input' package/` 只命中 busybox 的 Kconfig 文字）。
结果是：多 65536 B 内核 + 按键失效。

P17 最终：**`WITH_KEYS=0`**，内核回到 P11 的 `4131c6d0`（自校验），按键本来就是好的。

### 4.4 `WITH_KEYS` 开关保留但语义已变

`apply-to-2512.sh` 保留开关，但两边注释都已改写：
默认 0 时仍写 `# CONFIG_INPUT is not set` 等 5 行（merge_config 不会因删行而回退，lesson `g8tl61k`）；
`WITH_KEYS=1` 仅作为「将来真要 input 子系统（比如接 USB 键盘）」时的入口，**不是按键的开关**。

### 4.5 验收（P17 刷完后）

```sh
ls /sys/bus/platform/drivers/gpio-keys/keys   # 存在 = 绑定成功
lsmod | grep gpio_button_hotplug              # 模块已载
uci get luci.main.lang                        # zh_cn
uci get luci.main.mediaurlbase                # /luci-static/argon
ls /www/luci-static/argon/css/cascade.css     # Argon 资源在位
```


## 5. 本轮同时修正的一个方法论问题

`apply-to-2512.sh` §3 原先把 **FEED + 中文 + SQM(QoS)** 三组混在一个循环里，
任何一次跑本脚本都会把 SQM 一起带进固件 —— 违反 AGENTS §2「一次只改一个变量」，
而 SQM 是**数据面**改动，必须单独跑吞吐验证。

已拆成 `WITH_SQM` 开关（默认 0，显式写 `# CONFIG_PACKAGE_... is not set`，
因为删行不会让旧 `.config` 的 `=y` 回退，见 lesson `g8tl61k`）。
