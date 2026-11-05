# P13 迁移到 ImmortalWrt 25.12 的可行性（外部实证）

一句话结论：**不能整体迁移，但可以只借它的 feed（中文语言包 + 常用插件）。**

---

## 1. 外部实证（[外部实证]，含 URL）

### 1.1 ImmortalWrt 的 25.12 版本进度

`https://downloads.immortalwrt.org/releases/` 实列：

```
25.12.0/  25.12.1/  25.12.2/  25.12-SNAPSHOT/
```

`https://downloads.immortalwrt.org/releases/25.12.6/` → **HTTP 404**（不存在）

官方下载页 `https://downloads.immortalwrt.org/` 自述：
> The current ImmortalWrt release is … **ImmortalWrt 25.12.2 Released: Sun, 6 Sep 2026**

⇒ **ImmortalWrt 最新稳定版 = 25.12.2，比我们用的 OpenWrt 25.12.6 落后 4 个点版本。**

### 1.2 ImmortalWrt 25.12.2 不支持 WTA301

`https://downloads.immortalwrt.org/releases/25.12.2/targets/qualcommax/ipq50xx/` 机型全列：

```
cmcc_mr3000d-ci  cmcc_pz-l8  elecom_wrc-x3000gs2  glinet_gl-b3000
iodata_wn-dax3000gr  linksys_mr5500  linksys_mx2000  linksys_mx5500
linksys_mx6200  linksys_spnmx56  xiaomi_ax6000  yuncore_ax830
yuncore_ax850  zyxel_scr50axe
```

搜 `wta301|tplink` → **0 命中**。

### 1.3 内核版本更旧

`https://downloads.immortalwrt.org/releases/25.12.2/targets/qualcommax/ipq50xx/immortalwrt-25.12.2-qualcommax-ipq50xx.manifest`：

```
kernel - 6.12.103~6dc88cd23de5d9ac7327128d6f2ef611-r1
```

我们（OpenWrt 25.12.6）：`kernel-6.12.112~e98ab909e0808056fe8c2c0d03011f30-r1`

⇒ **ImmortalWrt 内核比我们旧 9 个点版本（6.12.103 vs 6.12.112）。**

### 1.4 以太网架构与我们完全不同（最关键）

ImmortalWrt 25.12.2 `target/linux/qualcommax/patches-6.12/`（共 102 个补丁）中与以太网相关的只有：

```
0056-v6.17-clk-qcom-gcc-ipq5018-fix-GE-PHY-reset.patch
0057-v6.17-net-phy-qcom-at803x-Add-Qualcomm-IPQ5018-Internal-PHY-support.patch
0059-v6.18-arm64-dts-qcom-ipq5018-Add-GE-PHY-to-internal-mdio-bus.patch
0722-clk-qcom-gcc-ipq5018-refer-to-uniphy-rx-and-tx-clk-providers-by-name.patch
0723-clk-qcom-gcc-ipq5018-fix-uniphy-soft-reset-issue.patch
0752-net-dsa-qca8k-support-PHY-to-PHY-CPU-link.patch
```

**没有** mainline 以太网三件套：
- 无 `net-pcs-add-uniphy-pcs`（我们的 0925）
- 无 `net-stmmac-introduce-qualcomm-ipq5018-dwmac`（我们的 0926）
- 无 `arm64-dts-qcom-ipq5018-add-uniphy-node`（我们的 0923）

ImmortalWrt 的 ipq50xx manifest 里有：
```
kmod-qca-nss-dp - 6.12.103.2025.11.24~19c51af0-r1
kmod-qca-ssdk  - 6.12.103.2025.05.30~446db12b-r1
```
⇒ **ImmortalWrt 的 ipq50xx 走 QCA SSDK + NSS offload 私有路径，不是 mainline DWMAC + DSA。**

我们的板子走的是后者（R14 定的路，R17 搬 S7 的 DSA SerDes，R18/P7 的 PCS 时钟）。

### 1.5 ImmortalWrt 的 fstools 同样没有 overlay 持久化修复

`https://api.github.com/repos/immortalwrt/immortalwrt/contents/package/system/fstools/patches?ref=v25.12.2`：

```
100-fstools-support-extroot-for-non-MTD-rootfs_data.patch
```

只有这一个，**不是** `fstools_overlay_name` 在 `done()` 里生效的修复。

上游 `openwrt/fstools` issue **#18「Overlay reformats on reboot with fstools_overlay_name bootparam」状态 = open**，
`https://github.com/openwrt/fstools/blob/master/mount_root.c` 的 `done()` 至今仍是
```c
struct volume *v = volume_find("rootfs_data");   // 字面量
```

⇒ **换到 ImmortalWrt，P11 那个补丁照样要打。**

### 1.6 顺带：OpenWrt 官方 25.12.6 也没有 mainline 以太网栈

`git status` 相对 tag `64900e75` 显示，我们 `target/linux/qualcommax/patches-6.12/0920~0926` **全部是 `??`（我们新增）**：

```
?? 0920-dt-bindings-net-ethernet-phy-increase-max-clock-count.patch
?? 0921-arm64-qcom-ipq5018-add-gephy-rx-and-tx-clocks.patch
?? 0922-net-phy-at803x-add-rx-tx-clock-management-for-ipq5018.patch
?? 0923-arm64-dts-qcom-ipq5018-add-uniphy-node.patch
?? 0924-net-stmmac-add-get_interfaces-platform-method.patch
?? 0925-net-pcs-add-uniphy-pcs.patch
?? 0926-net-stmmac-introduce-qualcomm-ipq5018-dwmac.patch
```

⇒ **OpenWrt 官方与 ImmortalWrt 都不提供 ipq50xx 的 mainline 以太网支持**，这段是我们自己补的。

---

## 2. 我们的全部改动清单（git status，共 23 项）

| 类别 | 项数 | 内容 |
|---|---|---|
| 修改 | 3 | `qualcommax/Makefile`（去 kmod-qca-nss-dp）· `image/ipq50xx.mk`（加 WTA301 device）· `ipq50xx/config-default` |
| 内核补丁 | 7 | 0920~0926（GE-PHY 时钟 + UNIPHY 节点 + PCST + DWMAC 驱动） |
| 内核源文件 | 19 | DTS×2 · DSA realtek 11（R17 搬 S7）· stmmac 1 · pcs-qca-uniphy 1 · dt-bindings 3 |
| fstools 补丁 | 1 | `0001-fstools-honor-fstools_overlay_name.patch`（P11） |
| base-files | 5 | `90_wta301` · `etc/config/wireless` · `12-wta301-caldata` · `uci-defaults/` · `lib/firmware/ath11k/` |

**这 23 项 ImmortalWrt 一项都没有。** 换发行版 = 23 项全部重搬 + 9/9 判据重验 + 以太网架构重选。

---

## 3. 但 ImmortalWrt 有三样我们值得直接拿的东西

### 3.1 ABI 完全相同，feed 可以直接混用（决定性）

| 组件 | OpenWrt 25.12.6（我们） | ImmortalWrt 25.12.2 |
|---|---|---|
| libc | **1.2.5-r5** | **1.2.5-r5** |
| libgcc1 | **14.3.0-r5** | **14.3.0-r5** |
| 架构 | `aarch64_cortex-a53` | `aarch64_cortex-a53` |
| 包管理器 | apk (apk-tools 3.0.5) | apk |

⇒ **纯用户态包（非 kmod）ABI 兼容，可直接装。**

### 3.2 158 个中文语言包

`https://downloads.immortalwrt.org/releases/25.12.2/packages/aarch64_cortex-a53/luci/`
`i18n.*zh-cn` 计数 = **158**

样例：
```
luci-i18n-base-zh-cn-26.298.29275~c84adb9.apk
luci-i18n-adblock-zh-cn-…
luci-i18n-adblock-fast-zh-cn-…
luci-i18n-firewall-zh-cn-…
```

### 3.3 常用插件确实在（非 kmod 的能用）

`.../packages/aarch64_cortex-a53/packages/`：
```
adblock-4.5.9-r4.apk          ← 纯用户态（依赖 jshn/jsonfilter/firewall4/coreutils…）
adblock-fast-1.2.4-r4.apk    ← 纯用户态
sqm-scripts-1.7.2-r1.apk     ← 需 kmod-sched-cake + kmod-ifb（装不上，见 §4）
```

### 3.4 按键：ImmortalWrt 用更轻的方案

ImmortalWrt ipq50xx manifest 含 `kmod-gpio-button-hotplug - 6.12.103-r5`。
它走 procd hotplug 路径，**不需要** `CONFIG_INPUT` + `INPUT_EVDEV` + `KEYBOARD_GPIO` + `INPUT_MISC` 四件套。
但它是 kmod ⇒ 仍然只能自己编进固件（见 §4）。

---

## 4. 铁律：kmod 永远不能跨构建拿

```
官方/ImmortalWrt kmods 目录名 = <LINUX_VERSION>-<LINUX_RELEASE>-<LINUX_VERMAGIC>
  OpenWrt   25.12.6 :  6.12.112-1-175dffd337a18721108278990fd69f67
  Immortal  25.12.2 :  6.12.103-…（另一串）
  我们              :  6.12.112~e98ab909e0808056fe8c2c0d03011f30-r1
```
`LINUX_VERMAGIC` 由内核 `.config` 的 hash 得出（`include/feeds.mk:55`）。
我们改了 `CONFIG_PCS_QCA_UNIPHY=y`、DSA SerDes、stmmac、DTS ⇒ hash 必然不同。

⇒ **所有 `kmod-*`（含 `kmod-sched-cake`/`kmod-ifb`/`kmod-gpio-button-hotplug`）只能自己编进固件。**

---

## 5. 板级差异表（外部结论 ≠ 本板结论）

| 维度 | ImmortalWrt 25.12.2 | 本板（OpenWrt 25.12.6） | 判定 |
|---|---|---|---|
| 机型支持 | 无 WTA301 | 我们自己加了 `Device/tplink_wta301` | **必须自带** |
| 内核 | 6.12.103 | 6.12.112 | 不同（同 6.12 系列，API 一致） |
| 以太网路径 | QCA SSDK + NSS offload | mainline DWMAC + DSA realtek | **完全不同，不可替换** |
| uniphy PCS | 无 | 有（我们 0925 + P7 的 `CONFIG_PCS_QCA_UNIPHY=y`） | **必须自带** |
| DSA SerDes | 无 6.18 四文件 backport | 有（R17 从 S7 搬） | **必须自带** |
| fstools overlay 修复 | 无 | 有（P11 补丁） | **必须自带** |
| libc | 1.2.5-r5 | 1.2.5-r5 | **相同 ⇒ feed 可混用** |
| 中文语言包 | 158 个，随 manifest 预装 | 0（只有 luci-base 英文） | **可直接借** |
| 包管理器 | apk | apk | 相同 |
| 按键 | `kmod-gpio-button-hotplug` | 我们编 `CONFIG_INPUT` 四件套 | 可借鉴，但要自己编 |

---

## 6. 结论与推荐做法

### ❌ 不迁移整个发行版
1. ImmortalWrt 不支持 WTA301，23 项改动全要重搬
2. 内核更旧（6.12.103 < 6.12.112）
3. 以太网架构完全不同（NSS/SSDK vs mainline DWMAC+DSA）⇒ R14/R17/R18/P7 全部作废重做
4. fstools 补丁照样要打（上游至今未修）

### ✅ 只借它的 feed（推荐，改动极小）
在我们固件里额外加一行：
```
https://downloads.immortalwrt.org/releases/25.12.2/packages/aarch64_cortex-a53/luci/packages.adb
```
收益：**158 个中文语言包** + `luci-app-*` 中文插件，`apk add luci-i18n-base-zh-cn` 即界面变中文。
风险：ImmortalWrt 的 luci 版本（26.298.x）比我们的（26.249.x）新，个别 `luci-*` 本体包可能冲突；
**只装 `luci-i18n-*`（纯 .lmo 翻译文件）最安全**。
kmod 类包（`kmod-sched-cake` 等）即使出现在该 feed 里也装不上（§4）。

### ✅ 顺手做（本次已加进 apply-to-2512.sh）
- 4 个 `CONFIG_FEED_*` 补齐，让板上 distfeeds 从 2 行变 6 行
- 家用 QoS 直接编进固件（`kmod-ifb` `kmod-sched-cake` `sqm-scripts` `luci-app-sqm` `tc`，约 200KB，
  rootfs squashfs 实测 8.32MiB / 余量到 11.75MiB）

---

## 7. 复现命令

```sh
# ImmortalWrt 版本进度
curl -s https://downloads.immortalwrt.org/releases/ | grep -oE 'href="25\.12[^"]*/"'
for v in 25.12.0 25.12.1 25.12.2 25.12.6; do
  curl -s -o /dev/null -w "$v -> %{http_code}\n" \
    "https://downloads.immortalwrt.org/releases/$v/"
done

# 机型清单
curl -s https://downloads.immortalwrt.org/releases/25.12.2/targets/qualcommax/ipq50xx/ \
  | grep -oE 'ipq50xx-[a-z0-9_-]+-squashfs' | sed 's/ipq50xx-//;s/-squashfs//' | sort -u

# 内核版本
curl -s https://downloads.immortalwrt.org/releases/25.12.2/targets/qualcommax/ipq50xx/immortalwrt-25.12.2-qualcommax-ipq50xx.manifest | grep '^kernel '

# 补丁清单
curl -s "https://api.github.com/repos/immortalwrt/immortalwrt/contents/target/linux/qualcommax/patches-6.12?ref=v25.12.2" | grep -oE '"name": "[^"]*"'

# ABI 对齐
curl -s https://downloads.openwrt.org/releases/25.12.6/targets/qualcommax/ipq50xx/openwrt-25.12.6-qualcommax-ipq50xx.manifest | grep -E '^libc |^libgcc1 '

# 我们的改动清单
cd /root/ow2512 && git status --short
```
