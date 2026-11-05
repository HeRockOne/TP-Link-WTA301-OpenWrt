# P12 软件包仓库现状：选 25.12 正式版的收益，达成了多少

判据来源全部为真机 + 官方 feed 实测，非推断。

## 0. 问题

用户选 25.12 正式版（而非 snapshot）的目标是：
> 不用安装那种快照版本的软件包丢失。

即：snapshot 的 `packages/` feed 每天滚动，昨天能装的包今天 404；
正式版的 `releases/<ver>/` 永久保留。

## 1. 已达成的部分（架构层）

| 项 | 实测 | 结论 |
|---|---|---|
| 固件版本 | `/etc/os-release` → `OpenWrt 25.12.6` / `r33311-981c978eff` | 正式版，非 snapshot |
| 构建 tag | `64900e75` == 25.12.6 release tag | 同源 |
| feed 路径 | `https://downloads.openwrt.org/releases/25.12.6/...` | **releases 永久路径，不随快照滚动** ✅ |
| 内核版本 | 官方 kmods 目录 `6.12.112-1-...`；`uname -r` = `6.12.112` | **与官方完全对齐** ✅ |

⇒ **"快照滚动的包丢失"这个问题，架构上已经解决。**

## 2. 未达成的部分（四个具体缺口）

### 缺口 A：板上只生成了 2 个 feed 行

真机 `cat /etc/apk/repositories.d/*`：
```
https://downloads.openwrt.org/releases/25.12.6/targets/qualcommax/ipq50xx/packages/packages.adb
https://downloads.openwrt.org/releases/25.12.6/packages/aarch64_cortex-a53/base/packages.adb
```

官方 `packages/aarch64_cortex-a53/` 实际有 **6 个** feed：
`base/ luci/ packages/ routing/ telephony/ video/`

代码依据 `include/feeds.mk:49-59` `FeedSourcesAppendAPK`：
```makefile
echo '%U/targets/%S/packages/packages.adb';                       # 总是写
$(if $(CONFIG_PER_FEED_REPO), echo '%U/packages/%A/base/packages.adb';
  $(if $(CONFIG_BUILDBOT), echo '%U/targets/%S/kmods/$(LINUX_VERSION)-$(LINUX_RELEASE)-$(LINUX_VERMAGIC)/packages.adb';)
  $(foreach feed,$(FEEDS_AVAILABLE), $(if $(CONFIG_FEED_$(feed)), ...)))   # =m 写成 # 注释
```

我们 `.config` 实况：
```
CONFIG_PER_FEED_REPO=y
# CONFIG_BUILDBOT is not set
# CONFIG_FEED_packages is not set
# CONFIG_FEED_luci is not set
# CONFIG_FEED_routing is not set
# CONFIG_FEED_telephony is not set
# CONFIG_FEED_video is not set
```
⇒ 所以只有 2 行。**`apk add luci-app-xxx` 现在搜不到包。**

### 缺口 B：官方 kmod 永远装不上（自编译的固有代价）

| | 值 |
|---|---|
| 官方 kmods 目录名 | `6.12.112-1-175dffd337a18721108278990fd69f67` |
| 板上 kernel 包 | `6.12.112~e98ab909e0808056fe8c2c0d03011f30-r1` |

kmods 目录名 = `<LINUX_VERSION>-<LINUX_RELEASE>-<LINUX_VERMAGIC>`，
而 `LINUX_VERMAGIC` 由内核 `.config` 的 hash 得出。

我们定制过内核（`CONFIG_PCS_QCA_UNIPHY=y`、DSA realtek 四文件、stmmac、DTS…），
hash 必然与官方不同 ⇒ 官方每个 kmod 包依赖的 `kernel (=<官方 vermagic>)` 不满足。

**这不是 25.12 的缺陷，是所有自编译 OpenWrt 的共性。**
⇒ 想要额外内核模块，只能自己编，或把我们自己的 kmod 做成 feed。

### 缺口 C：板子当前没有默认路由

真机：
```
$ ip route
192.168.1.0/24 dev br-lan scope link  src 192.168.1.1
$ ping -c 1 223.5.5.5
ping: sendto: Network unreachable
```
```
$ apk list
WARNING: opening from cache https://downloads.openwrt.org/.../packages.adb: No such file or directory
WARNING: opening from cache https://downloads.openwrt.org/.../base/packages.adb: No such file or directory
```
⇒ 两台 feed 的索引**从未成功下载过**。

注：这是当前"PC 直连测试"拓扑的必然结果。真实家用部署（板子接光猫/上级路由跑 DHCP 或 PPPoE）会有默认路由，缺口 C 自动消失。

### 缺口 D：官方 packages 里 kmod 与非 kmod 混在同一 target feed

`targets/qualcommax/ipq50xx/packages/` 里同时有 `arptables-nft`（纯用户态，可装）和
`kmod-*`（vermagic 绑死，装不上）。装用户态包时只要别让 apk 顺带解析 kmod 依赖即可，
实际用 `apk add <pkgname>` 单包精确指定即可避开。

## 3. 达成目标需要做什么

### 方案 1（推荐，最小改动）：补 distfeeds，让用户态包可用

在 `.config` 打开：
```
CONFIG_FEED_packages=y
CONFIG_FEED_luci=y
CONFIG_FEED_routing=y
CONFIG_FEED_telephony=y
```
然后 `make -j8 world`（只重编 base-files + 重打 rootfs，不会整核重编）。

得到：`luci-app-*`、`htop`、`curl`、`nano`、`routing`/`telephony` 类包可直接 `apk add`。
限制：所有 `kmod-*` 依旧不可用（缺口 B）。

### 方案 2（彻底，长期家用最稳）：自建本地 feed

把我们自己编出来的 182 个包（`bin/targets/.../packages/` 84 + `bin/packages/aarch64_cortex-a53/*/` 98）
做成静态 apk feed，托管在内网（PC 上 `http.server` 或板子本地 U 盘），
板上 `repositories.d/customfeeds.list` 指向它。

优点：
- kmod 与内核**严格同源**，永远不会有 vermagic 问题
- 不依赖公网，家用断网也能装
- 新增内核模块 = 改 config 重编 → 自动进 feed

代价：首次要把 182 个 apk 加索引，约 10 分钟一次性的活。

### 方案 3：两者都做（最接近"完美迁移"）
方案 1 + 方案 2。官方 feed 拿用户态包，本地 feed 拿 kmod 与自有包。

## 4. 与 S7 的对比（判据：为什么会觉得 snapshot 会"丢包"）

S7 的 `/etc/opkg/distfeeds.conf` 指向 snapshot，每天滚动：
- 重装/升级时旧 feed 已删 ⇒ `opkg install` 404
- 内核版本一变，旧 kmod 全失效

我们在 25.12.6 上：
- feed 永久 ⇒ 用户态包永不 404（**这是真正的收益**）
- kmod 本来就不可能从官方拿（自编译即如此），与版本无关

⇒ **收益真实存在，但只覆盖"用户态包"这一类。**

## 5. 复现命令

```sh
# 板上
cat /etc/os-release ; cat /etc/apk/repositories.d/*
apk --version ; apk policy kernel ; apk list -I | grep '^kernel'
ip route ; ping -c 1 223.5.5.5

# 官方侧
curl -s https://downloads.openwrt.org/releases/25.12.6/targets/qualcommax/ipq50xx/kmods/
curl -s https://downloads.openwrt.org/releases/25.12.6/packages/aarch64_cortex-a53/

# 构建树
grep -E '^CONFIG_(PER_FEED_REPO|BUILDBOT|FEED_[a-z]+)=' .config
sed -n '49,60p' include/feeds.mk
```

## 6. 结论

**目标部分达成。**

- ✅ 不再受快照滚动影响（feed 在 `releases/25.12.6/` 永久路径，内核 6.12.112 与官方对齐）
- ❌ 但当前固件**实际上装不了任何包**：distfeeds 缺 4 个 feed（缺口 A）+ 无默认路由（缺口 C）
- ⚠️ `kmod-*` 这一类从官方**永远**装不上（缺口 B），与版本选择无关，是自编译的固有代价

要让"能装包"变成现实，最小的一步是方案 1（改 4 个 config symbol，重编 base-files）。

---

## 7. 验证补充（2026-11-05，`CONFIG_PACKAGE_*` 有效性）

早前"`grep CONFIG_PACKAGE_luci tmp/.config-package.in` = 0 条 ⇒ `CONFIG_PACKAGE_*` 可能无效"的结论是**grep 锚定错误**，现更正：

| 检查 | 命令 | 结果 |
|---|---|---|
| 首字符是 `config ` | `grep -c '^config PACKAGE_'` | 0（**假阴性**） |
| 实际格式 | `grep -n PACKAGE_luci-i18n-base` | `66721:\tconfig PACKAGE_luci-i18n-acl-zh-cn` —— 选项行**是 TAB 缩进** |
| 正确计数 | `grep -c 'zh-cn' tmp/.config-package.in` | 200（=100 包 ×2 行） |
| `.config` 里就有的形式 | `grep -c '^CONFIG_PACKAGE_' .config` | 191 |

⇒ `CONFIG_PACKAGE_<name>=y` 是**正确且有效**的写法，`apply-to-2512.sh` 该块可用。

### 顺带修正两处包名

1. `tc` 不是包名。真名：`tc-tiny` / `tc-full` / `tc-bpf`。
   `tmp/.config-package.in` 里 `sqm-scripts` 已自动
   `select PACKAGE_tc-tiny if PACKAGE_tc-bpf<PACKAGE_sqm-scripts&&PACKAGE_tc-full<PACKAGE_sqm-scripts`，
   并 select `kmod-ifb` / `kmod-sched-cake` / `iptables-mod-ipopt` / `iptables-nft` / `ip-tiny`。
   ⇒ 只需 `CONFIG_PACKAGE_sqm-scripts=y`；其余显式行只为自文档，取 `tc-tiny` 与 select 条件同向。
2. `luci-base-zh-cn` 口语写法对应真实包名 `luci-i18n-base-zh-cn`（`feeds/luci/luci.mk:78`
   `LUCI_LC_ALIAS.zh_Hans=zh-cn`，`luci.mk:344` 拼 `luci-i18n-<basename>-<lang>`）。
   脚本原本已是正确形式，5 个包名逐个在 `tmp/.config-package.in` 中 `EXISTS` 命中。

### 为什么不用 `CONFIG_LUCI_LANG_zh_Hans=y` 一行搞定

```
config PACKAGE_luci-i18n-base-zh-cn
        tristate
        default y if DEFAULT_luci-i18n-base-zh-cn
        default LUCI_LANG_zh_Hans||(ALL&&m)
        depends on PACKAGE_luci-base
```

语言总开关会把 **100 个** zh-cn 包全部打开（源 po 与 lmo 全量约 4.6 MiB），而 mtd6 rootfs
分区硬预算只有 **3.58 MiB**（`0xC00000 - 8_722_096`，squashfs 本体实测 8,722,096 B）。
⇒ 只点 5 个最必要包：`base`(608 KiB po) / `firewall`(72 KiB) / `package-manager`(18 KiB) /
`dashboard`(20 KiB) / `sqm`(13 KiB)，编译后约 250 KiB，留足余量。

`safe` 校验：`luci-base` 已 `=y`；五个包 `depends on PACKAGE_luci-base` 满足。
