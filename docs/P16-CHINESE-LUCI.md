# P16 中文界面 + 可在线安装的包仓库

判据全部来自真机实测（`work/evidence/p15-pkg-probe*.txt`、`p15-netcheck.txt`）
与构建树源码（`/root/ow2512`）。每条标 [实证] / [上游代码] / [推断]。

## 0. 目标（用户原话）

> 先装中文。其他的能够线上安装吗？主题呢？我们选基线 25.12 正式版本就是为了
> 能够用户态包随意安装，不受快照影响。

拆成两件事：
1. **中文界面必须开箱可用** → 进固件（离线可用）
2. **主题/其他包必须能在线装** → 让 `distfeeds.list` 写全 feed

## 1. 25.12.6 官方 feed 现状 [实证]

```
releases/25.12.0 … 25.12.6                 全部存在（24.10 之后的 LTS 线）
packages/aarch64_cortex-a53/{base,luci,packages,routing,telephony,video}
targets/qualcommax/ipq50xx/packages/
```

**包格式已从 `.ipk` 换成 `.apk`**：

```
base/ 目录 742 个 .apk，0 个 .ipk
apk-tools 3.0.5, compiled for aarch64      ← 板上 /usr/bin/apk [实证]
```

⇒ 老的 opkg / `.ipk` 教程 **全部不适用**。查包、装包命令是 `apk add` / `apk search`。

主题 5 个 [实证，`releases/25.12.6/packages/aarch64_cortex-a53/luci/`]：

| 包 | 说明 |
|---|---|
| `luci-theme-bootstrap` | 默认（已进固件） |
| `luci-theme-footstrap` | |
| `luci-theme-material` | |
| `luci-theme-openwrt` | |
| `luci-theme-openwrt-2020` | |

中文包 100 个：`luci-i18n-*-zh-cn-26.304.26398~e969939.apk`。

## 2. 为什么板上装不了 luci 的包（根因）[实证+上游代码]

板上 `/etc/apk/repositories.d/distfeeds.list` **只有 2 行**：

```
https://downloads.openwrt.org/releases/25.12.6/targets/qualcommax/ipq50xx/packages/packages.adb
https://downloads.openwrt.org/releases/25.12.6/packages/aarch64_cortex-a53/base/packages.adb
```

`apk add luci-theme-material` → `no such package`。
`apk update` → `182 distinct packages available`（只有 base+targets 的量）。

根因在 `include/feeds.mk:48` `FeedSourcesAppendAPK`：

```make
echo '%U/targets/%S/packages/packages.adb';              # 无条件
if CONFIG_PER_FEED_REPO:
    echo '%U/packages/%A/base/packages.adb';             # 无条件
    if CONFIG_BUILDBOT:
        echo '%U/targets/%S/kmods/<ver>/packages.adb';   # 仅 buildbot
    foreach feed in FEEDS_AVAILABLE:
        if CONFIG_FEED_<feed>:
            echo '...%U/packages/%A/<feed>/packages.adb'
```

而我们的 `.config` 里 `# CONFIG_FEED_luci is not set`（5 个全是 n）
⇒ 只有前两行落盘。**前两行永远存在**，所以「base 能装、luci 不能装」。

**修法**：`CONFIG_FEED_{luci,packages,routing,telephony,video}=y`
⇒ `distfeeds.list` 变 7 行。

## 3. 中文包的 Kconfig 机制 [上游代码]

`tmp/.config-package.in:69907`：

```
config PACKAGE_luci-i18n-base-zh-cn
    tristate
    default y if DEFAULT_luci-i18n-base-zh-cn
    default LUCI_LANG_zh_Hans||(ALL&&m)
    select PACKAGE_libc
    depends on PACKAGE_luci-base
```

**踩过的坑**：直接写 `CONFIG_PACKAGE_luci-i18n-base-zh-cn=y` 然后 `make defconfig`，
这几行会被 `default` 重新求值覆盖掉（`LUCI_LANG_zh_Hans` 当时是 `# not set`
⇒ default 求值为 n）⇒ 落盘 0 个中文包。

**正确做法**：只写语言开关，让 Kconfig 自己选：

```
CONFIG_LUCI_LANG_zh_Hans=y
```

`make defconfig` 后自动得到（[实证]）：

```
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y
CONFIG_PACKAGE_luci-i18n-package-manager-zh-cn=y
```

**正好 3 个，不多不少**——因为只翻译「已启用的模块」。我们启用的 luci 模块是
`luci-mod-admin-full/network/status/system` + `luci-app-firewall` +
`luci-app-package-manager` + `luci-theme-bootstrap`；其中四个 mod 的文案并在
`luci-base` 的 po 里（无独立 po 包），所以只需 base + 两个 app = 3 个。

`luci-mod-dashboard`、`luci-app-sqm` **未启用** ⇒ 不选译文，不占固件。
要用时 `apk add luci-app-sqm luci-i18n-sqm-zh-cn`（feed 已在）。

### 语言如何生效 [上游代码 + 实证]

- `feeds/luci/luci.mk:78` `LUCI_LC_ALIAS.zh_Hans=zh-cn` ⇒ 包名后缀 `-zh-cn`
- `luci.mk:344-349`：安装时写 `/etc/uci-defaults/luci-i18n-<basename>-<lang>`，
  内容为 `uci set luci.languages.<code>='<name>'`
- 板上 `/etc/config/luci` 已是 `option lang 'auto'` [实证]
- ⇒ 装完即生效，`/etc/config/luci` 的 `languages` 段由 uci-defaults 补入

## 4. 本轮构建配置（P16）

```
CONFIG_FEED_luci=y
CONFIG_FEED_packages=y
CONFIG_FEED_routing=y
CONFIG_FEED_telephony=y
CONFIG_FEED_video=y
CONFIG_LUCI_LANG_zh_Hans=y
```

**不含**：QoS / 主题 / adblock——按用户要求留给线上安装。

**内核不受影响**（自校验项）：这些 symbol 都不碰内核配置，
产物 kernel crc32 应仍为 `4131c6d0`。

## 5. 空间核算 [实证]

| 项 | 前 (P15) | 后 (P16) | 增量 |
|---|---|---|---|
| squashfs 实体 | 8,722,916 B | 待测 | 3 个中文包源 po 约 782 KB，压缩后约 +250 KiB |
| rootfs 分区（12 MiB = 0xC00000） | 余 3.68 MiB | 余 ≥3.4 MiB | 够 |
| `/overlay`（可写） | 27.9 MiB | 27.9 MiB | **与 rootfs 无关，不变** |
| RAM | | | 静态文件，不常驻 |

## 6. 验收判据

1. `uci get luci.languages.zh_cn` 有值（uci-defaults 跑过）
2. LuCI 页面切到中文，菜单/按钮为简体中文
3. `/etc/apk/repositories.d/distfeeds.list` **7 行**
4. 接 WAN 后 `apk update` → 数字远大于 **182**
5. `apk search luci-theme-material` 有结果
6. kernel crc32 = `4131c6d0`（证明内核没被带变）

## 7. 当前硬件网络状态 [实证]（影响「线上安装」）

板子现在**没有 WAN 口配置**：

```
ip addr  → 只有 br-lan 192.168.1.1/24
ip route → 只有 192.168.1.0/24 dev br-lan
ping 223.5.5.5 → Network unreachable
uci get network.wan.proto → Entry not found
```

⇒ **刷完 P16 后，中文立刻可用；主题/其他包要等接上 WAN。**
`/etc/config/network` 的 wan 由 `board.d/90_wta301` 生成，WAN 口是哪个物理口需
按 P7 有线那轮的结论接线（本包未改动网络配置）。
