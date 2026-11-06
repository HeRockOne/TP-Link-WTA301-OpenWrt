# iStore 适用性评估 —— WTA301 / OpenWrt 25.12.6

评估时间：2026-11-06
问题来源：用户问「iStore 应用商店适合我们机器安装吗」

**结论：不适合。四个硬障碍，其中第一个是死结。**

证据等级标注：`[本板实证]` 我们自己机器上跑命令得到的 · `[外部实证]` 外部可复核的原始
输出/原文 · `[推断]` 有推理链但未实测。

---

## 1. 决定性障碍：包格式完全不匹配

iStore 的公开仓库**至今 100% 是 `.ipk`（opkg 格式）**，没有一个 `.apk`。

`[外部实证]` 实地 curl 统计（2026-11-06）：

| 仓库路径 | `.ipk` | `.apk` |
|---|---|---|
| `/repo/aarch64_generic/nas/` | 1 | **0** |
| `/repo/aarch64_cortex-a53/nas/` | 67 | **0** |
| `/repo/all/store/` | 4 | **0** |
| `/repo/all/meta/` | 140 | **0** |

`[外部实证]` apk 索引文件 `packages.adb` 探测：

```
https://istore.istoreos.com/repo/aarch64_generic/packages.adb     -> 404
https://istore.istoreos.com/repo/aarch64_cortex-a53/packages.adb  -> 404
https://istore.istoreos.com/repo/all/packages.adb                 -> 404
```

`[外部实证]` 仓库源声明仍是 opkg 语法（`/repo/all/isfeeds.conf`）：

```
src/gz is_nas_luci https://istore.istoreos.com/repo/all/nas_luci
src/gz is_store https://istore.istoreos.com/repo/all/store
```

`[外部实证]` `/repo/aarch64_cortex-a53/isfeeds.conf` 仍是 `src/gz`，且声明
`arch aarch64_cortex-a53 10` / `arch aarch64_generic 5`。

`[本板实证]` 我们的包管理器是 apk：

```
$ apk --version
apk-tools 3.0.5, compiled for aarch64.
```

**⇒ `src/gz` 语法 apk 不认，`.ipk` apk 装不了。连商店本体
（`luci-app-store_0.2.1-r1_all.ipk`）都是 ipk。**

### 1.1 关于「iStore 0.2.0 支持 apk」

`[外部实证]` 作者 jjm2473 在 issue #22 公告：「0.2.0 支持APK包管理器（OpenWrt 25.12）」

但同一作者在 2025-04-15 说（issue 讨论原文）：
> 现在istore还没提供apk仓库呢，就算集成了也大部分插件无法安装的

`[本板实证]` 2026-11-06 实地复查：**仍然没有 apk 仓库**（见 §1 表格与 404）。

`[推断]` 合理理解：0.2.x 让**商店界面本身**能在 apk 系统上运行，
但仓库商品仍是 ipk，因此「能装商店 ≠ 能从商店装东西」。
这不是我们机器的问题，是 iStore 迁移尚未完成。

### 1.2 架构对照，作者原话

`[外部实证]` jjm2473（2026-08-16，istoreos discussion #3008）：
> 25.12上实际是让 aarch64_cortex-a53 的机器兼容 aarch64_generic，
> 24.10之前是反过来的。也就是说 istore 上 arm64 只提供了
> aarch64_cortex-a53 的 ipk，也只提供了 aarch64_generic 的 apk。

`[本板实证]` 我们是 **aarch64_cortex-a53** + apk → 按此说法正好落在
「a53 只有 ipk」这一侧。

---

## 2. 内存：只剩 37MB，余量太小

`[本板实证]`：

```
$ grep -E "MemTotal|MemFree|MemAvailable" /proc/meminfo
MemTotal:         178672 kB      (174.5 MB)
MemFree:           26924 kB
MemAvailable:      37224 kB      (36.4 MB)
```

对照已知构成（`docs/P23` 内存审计）：ath11k 无线驱动独占约 73.4MB（42%），
用户态全部加起来仅约 4.5MB。

`[外部实证]` iStore 常驻组件需要新增进程：`taskd`（任务守护）、
`luci-lib-xterm`（网页终端）、商店前端。
另有论坛实测反馈（恩山，x86 分配 2GB 内存）：
> istoreos内存占用一直飙高 … 两三天就涨到70%以上 … 只能重启

`[推断]` 我们 37MB 可用内存，装 iStore 加依赖后预计只剩 20MB 上下。
WiFi 高负载时本就吃紧（P26 实测单流 414Mbps 时 CPU 平均 70%），
再加常驻进程有触发 OOM 的风险。**未实测，不写进结论表。**

---

## 3. 空间够装商店，不够装插件

`[本板实证]`：

```
$ df -h /overlay
/dev/ubi0_0  27.9M  268.0K  27.6M  1%  /overlay
```

iStore 本体 + 依赖约 1MB 量级（store 117KB + xterm 78KB + taskd +
curl/tar/mount-utils/libuci-lua），**空间足够**。

但 iStore 的插件生态（§4）里几乎所有东西都远超 27.6MB。
本板**无 USB、无 SATA、无 MMC**（P27 硬件审计：`PCIe/USB 设备 0`、
`mmc_host 0`），无法扩存储。

---

## 4. 生态不匹配：iStore 面向 NAS/软路由，不是 256MB 无存储路由器

`[外部实证]` iStore 商品清单（`all/meta/` 140 个包）与常见教程覆盖的主打插件：
Docker / Dockerman、alist、aliyundrive-webdav、baidupcs-web、
qBittorrent、Jellyfin、Samba、KMS 服务器、udpxy、openfog…

`[本板实证]` 我们的条件：

| 项 | 实况 |
|---|---|
| 内存 | 174.5MB 总 / 37MB 可用 |
| overlay | 27.6MB 可用 |
| USB / SATA / MMC | **无**（P27 已实证） |
| 定位 | 纯路由器，软转发 502Mbps@100% CPU（无 NSS） |

⇒ Docker 不可能（无 cgroup 空间 + 无存储）；下载/媒体类无盘可存；
剩余能装的多是代理类插件，那属于另一条路（且我们是官方固件体系）。

`[外部实证]` iStore README 自己列的两条「无法弥补的缺陷」：
> 1. 因为 OpenWRT 版本特别多，导致不同平台的插件依赖不一样。
>    所以即使你的系统能安装 iStore，iStore 里面的插件不一定能安装
> 2. 我们需要固件开发者自主集成 iStore，并解决 iStore 里面的各种插件的依赖。
>    原版 OpenWRT 通常不会有依赖问题

我们用的正是**原版 OpenWrt**（v25.12.6 官方），恰好在作者说的
「需要固件开发者自己解决依赖」这一侧。

`[外部实证]` 做 ImmortalWrt ImageBuilder 的 wukongdaily（issue #810）：
> 目前由于首页向导无 aarch64_cortex-a53 架构的 APK 包，因此硬路由暂时不能集成

---

## 5. 依赖缺口：装 iStore 要先补 7 个包

`[本板实证]`：

```
$ for p in curl tar mount-utils lua libuci-lua luci-lib-taskd luci-compat; do
    apk info -e "$p"; done
  curl               缺失
  tar                缺失
  mount-utils        缺失
  lua                缺失
  libuci-lua         缺失
  luci-lib-taskd     缺失
  luci-compat        缺失
```

`[外部实证]` `luci-app-store` 的 Makefile 依赖声明：
```
LUCI_DEPENDS:=+curl +tar +libuci-lua +mount-utils +luci-lib-taskd
```

`[推断]` 其中 `libuci-lua` 是 **Lua 版 LuCI** 的 uci 绑定。我们是 25.12，
LuCI 主体是 JS 版（见 P29 `luci-mod-status-wta301.json`），
需要额外拉 `luci-compat` + `luci-lua-runtime` 才能满足。
会进一步吃内存和 overlay。**未实测。**

---

## 6. 结论与替代方案

### 不推荐的三个理由（按严重度）

1. **包格式死结** —— 仓库全 ipk，我们 apk。装了商店也装不了商品
2. **生态方向错** —— 它是给 x86 软路由/NAS 做的；我们无存储、175MB 内存
3. **内存余量** —— 37MB 可用，加常驻进程风险不明（未实测）

### 如果只是想要某个功能

**更好的是直接编进固件。** 我们的出包链路已经成熟（`deliver/` =
`apply-*` → `make-release.sh` → `make-deliverable.sh`），加一个包就是在
`.config` 里开一个 `CONFIG_PACKAGE_xxx=y`，走既有流程出四区包。
这样：

- 走 apk 官方源，架构/依赖自动匹配
- 不额外常驻进程（不需要 taskd/xterm）
- sysupgrade 升级时一并更新，不留残余

### 如果一定要试，最低风险做法

**不装商店，只在 SSH 里用 apk 装单个具体需求。** 且先备份
（`deliver/` 有现成流程），确认内存占用（`free -m` / `cat /proc/meminfo`）
再决定是否保留。

---

## 7. 未验证项（不许当成结论用）

| 项 | 状态 |
|---|---|
| 真的从 ipk2apk 转出商店本体并在本板跑通 | ⬜ 未做 |
| 装上后实测内存增量 | ⬜ 未做 |
| 我们用 apk 能否装 `aarch64_generic` 的包（arch override） | ⬜ 未做 |
| iStore 0.2.x 是否有未公开的 apk 仓库路径 | ⬜ 未穷举，仅查了 3 个常见路径 |

