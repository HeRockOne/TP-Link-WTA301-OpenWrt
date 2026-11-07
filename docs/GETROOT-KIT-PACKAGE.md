# 一键工具包（纯 PowerShell，不需要装 Python）

用户诉求原话：

> 「为什么你不把 uboot 放到一个目录？？应该是所有操作单台电脑完成！
>  另外不要 py 脚本，别人电脑没有这种语言。用 bat 或者 ps1」

对应产物：

```
work/wta301-kit/            目录，62 MB，12 个文件
work/wta301-kit.zip         zip，54 MB
```

生成脚本：`deliver/make-getroot-kit.sh`（可反复重建，每次都重算并校验 md5）

---

## 0. 为什么把 Python 全部重写成 PowerShell

三条约束，来自实际使用场景：

| 约束 | 后果 |
|---|---|
| 目标机器是**别人的** Windows | 不能要求装 Python。`启动.bat` 里查 python 这一步本身就是门槛 |
| 要求**所有操作单台电脑完成** | getroot（网线）和刷 u-boot（TTL 串口）不能分两台机器、两套脚本 |
| u-boot 要**单独一个目录** | 固件包和 u-boot 混在一起，最容易发生「想把固件刷回去，结果顺手把 u-boot 也换了」 |

Windows 10 / 11 自带 PowerShell 5.1，密码学（DH / AES）、TCP、UDP、串口全都能做，
所以整个工具变成**单文件、零依赖**：`wta301.ps1`。

### 实测验证过的能力（不是推测）

| 能力 | 实现 | 实测结果 |
|---|---|---|
| DH 2048-bit 密钥交换 | `[System.Numerics.BigInteger]::ModPow` | ✅ 自检通过 |
| AES-128-CBC（零 IV、无填充） | `System.Security.Cryptography.Aes` | ✅ 自检通过 + 与设备真机握手成功 |
| telnet 客户端 | `TcpClient` + `NetworkStream` | ✅ 取到 `uid=0(root)` |
| HTTP 服务（设备 wget 取包） | `TcpListener` 手写 | ✅ 设备成功下载并按 md5 校验 |
| 并行 TCP 收数据 | 多 `TcpListener` + runspace | ✅ 15 分区 29 秒 |
| 串口 + TFTP（救砖） | `SerialPort` + `UdpClient` | 代码就位，未上机（本次没插 TTL） |

> `Get-FileHash` 在某些机器上会「无法识别」，所以 md5 直接用 .NET 算，不用 cmdlet。

---

## 1. 包结构

```
wta301-kit/
├─ 启动.bat                 入口：提权 → --SelfTest → 问 IP → 进菜单
├─ wta301.ps1               全部逻辑（单文件，零依赖）
├─ 使用说明.txt
├─ MD5SUMS.txt
├─ uboot/                   ★ u-boot 单独一个目录
│  ├─ wta301-uboot-p21c.bin     262144 B  d0ada9f76e4f1aba9b96a559a5220cee
│  └─ README.txt                为什么单独放、什么时候才需要刷
├─ images/
│  ├─ wta301-op-25.12.6-p29.bin            c5ac0911accd2ec48033329c383d5c4c
│  └─ wta301-op-25.12.6-p29-sysupgrade.bin 76df463df4d8b5acba5d52852870c127
└─ stock/                   原厂回退镜像
   ├─ mtd5_kernel.bin        170b2188...  ← 内容在 0x4880000（A 槽）
   ├─ mtd6_rootfs.bin        30f48741...  ← 内容在 0x4fc0000（A 槽）
   ├─ mtd10_kernel_bak.bin   2868d8e9...  ← 内容在 0x0880000（B 槽）
   └─ mtd11_rootfs_bak.bin   bf2f92ce...  ← 内容在 0x0fc0000（B 槽）
```

**注意 stock 里文件名和物理位置的对应是反的**，这是命名的历史原因（文件名来自
各自固件视角下的 mtd 编号，而两个固件对同一块区域编号不同）。所以工具只认
md5、不认文件名，`--SelfTest` 会把这张对应表打出来给你看。

---

## 2. `--SelfTest` 离线自检（不连设备、不写任何东西）

```
启动.bat 会自动先跑这个；也可以单独跑：
  powershell -NoProfile -ExecutionPolicy Bypass -File wta301.ps1 -SelfTest
```

检查项：

1. PowerShell 版本、串口列表、是否管理员
2. DH 2048-bit 模幂
3. AES-128-CBC 加解密回环
4. 四份原厂镜像的 md5 **与物理槽的对应关系**（防文件名误导）
5. OpenWrt 包 / sysupgrade / u-boot kit 的 md5
6. **写入门禁 11 条用例**（见下）

### 写入门禁（不是返回 false，是抛异常）

```
永远不许写：
  mtd0   0x0000000  一级 u-boot + SBL/QSEE/CDT   TTL 命脉
  mtd1   0x0400000  出厂信息（机型 / MAC）
  mtd2   0x0480000  射频校准（ART）
  mtd14  0x4000000  boot_flag（选槽标志）

需要显式授权（按动作区分，不用全局白名单）：
  0x0700000 / 0x4700000  两槽 u-boot     <- flash-uboot
  0x0880000 / 0x0fc0000  B 槽内核/rootfs <- restore-bslot
  0x4fc0000              A 槽 rootfs     <- flash-op
```

自检输出（实测，11/11 通过）：

```
mtd0  flash-op       -> 拒绝  (一级 u-boot，TTL 命脉)
mtd1  flash-stock    -> 拒绝  (出厂信息)
mtd2  flash-uboot    -> 拒绝  (射频校准)
mtd14 flash-op       -> 拒绝  (boot_flag)
mtd4  flash-op       -> 拒绝  (B 槽 u-boot 只能由 flash-uboot 写)
mtd9  restore-bslot  -> 拒绝  (A 槽 u-boot 只能由 flash-uboot 写)
mtd5  flash-stock    -> 拒绝  (B 槽内核只能由 restore-bslot 写)
mtd6  flash-uboot    -> 拒绝  (B 槽 rootfs 只能由 restore-bslot/flash-op 写)
mtd13 flash-op       -> 允许  (A 槽容器，flash-op 合法)
mtd11 flash-op       -> 允许  (A 槽 rootfs，flash-op 合法)
mtd4  flash-uboot    -> 允许  (B 槽 u-boot，flash-uboot 合法)
```

---

## 3. 落点解析：按绝对偏移反查，不按编号

`Resolve-WriteTarget` 做三件事：

1. 收集所有「覆盖目标绝对偏移且装得下」的分区
2. 优先挑起点正好对上的；否则挑**最小的能装下的**
3. 算出 dd 的 `seek`（落点相对分区起点的块数）

为什么必须这样（两个实测出来的坑）：

**坑 A：同一段区域被两个分区覆盖**

```
0x4880000 既是 mtd10 kernel（4 MiB）
          又是 mtd13 容器 firmware_bak 的 +0x80000（总 0x2620000）

OpenWrt FIT 实占 0x41526c（4.28 MiB）> 4 MiB
⇒ 直写 mtd10 会截断 => 变砖
⇒ 必须写 mtd13 + seek 8 块（0x80000/65536）
```

实测 dry-run 输出：

```
内核 -> mtd13 0x4800000 +seek 8 块 = 绝对 0x4880000
rootfs -> mtd11 0x4fc0000 +seek 0 块 = 绝对 0x4fc0000
```

**坑 B：分区编号跨固件错位**

```
原厂固件  mtd5 = 0x0880000（B 槽内核）
OpenWrt   mtd5 = 0x4880000（A 槽内核）
命名还互为主备（这边叫 kernel，那边叫 kernel_bak）
```

所以代码里没有任何一处按名字或按编号硬编码写入。

---

## 4. 速度：三处慢，全部修掉（实测数字）

| 问题 | 改前 | 改后 |
|---|---|---|
| 每条命令固定 `sleep 30` | 12 MiB 分区 md5 要 32.01 秒 | 哨兵轮询 **1.35 秒** |
| 备份每区读两遍（先 md5 再传） | 同一分区从 NAND 读两次 | 只传一遍，md5 本地现算 |
| nc 单流被往返延迟卡住 | ≈0.65 MB/s（NAND 本身 8.9 MB/s） | 4 路并行 |
| **整片备份总耗时** | **218 秒** | **29 秒** |

### 哨兵机制（这是提速的关键）

```
{ <cmd> ; } 2>&1; echo <tag>$?
```

踩过的两个坑：

1. **telnetd 会回显我们发的整行命令**，而那一行里就含 tag。
   用 `tag in buf` 判断会立刻命中、返回空串。
   ⇒ 判据必须是「行首独占 + 紧跟数字」：`(?:^|[\r\n])<tag>[0-9]`。
   （`echo <tag>$?` 的回显里 tag 后面是 `$`，不匹配，正好区分。）
   发送前还要把上一轮残留读干净。

2. **回显清理不能按「从 `{` 删到 `}`」**：长命令会一路删到缓冲区末尾，
   把真正的输出也删光。改成逐行精确比较（整行等于 payload）。

### 为什么备份必须并行

板上实测三个数字：

```
NAND 读出 12 MiB 并算 md5     1.35 秒   ≈ 8.9 MB/s
裸 100 Mbps 网线                        12.5 MB/s
dd | nc 单流                            ≈ 0.65 MB/s   ← 差距在这里
```

瓶颈不在 NAND、也不在带宽，而是单条 TCP 流上 busybox nc 的往返延迟。
加带宽没用，多开几条流才能把延迟重叠掉。

---

## 5. PowerShell 的一个大坑：scriptblock 不是词法闭包

第一版把清理逻辑写成 `return @{ Cleanup = { ... } }`，在函数外 `& $root.Cleanup` 调用。

**报错**：`管道元素中的"&"后面的表达式生成无效的对象`

**根因**：PowerShell 的 scriptblock 是动态作用域，不是词法闭包。在函数内定义、
函数返回后再调用时，它引用的局部变量（`$http` / `$elink`）已经随作用域销毁，
于是变成 `& $null.Stop`。

**连带后果**（更严重）：清理整个没执行 —— 网关别名和防火墙规则留在了本机。

**修法**：所有后台服务改成「state hashtable + 独立的 Stop 函数」：

```powershell
function Stop-BackgroundService { param($State, $Name) ... }
Stop-BackgroundService -State $root.Http -Name 'HTTP 服务'
```

实测收尾输出：

```
[收尾] 关闭连接、停服务、撤销本机改动
  - 已断开 root shell
  - 删除别名 192.168.1.1/32
  - 删除别名 192.168.0.1/32
  - 删除防火墙规则
会话结束（共 1 次操作）
```

清理只删「`/32` + `SkipAsSource`」的别名 —— 那是本工具加的假网关，
真网关是正常前缀地址，不会被误删。

---

## 6. 会话复用（用户提的第一个问题）

> 「每个选项都获取一次 root，明明第一次就已经够了，剩下的操作都是在第一的基础上进行」

两个根因：

1. `main()` 判断 `interactive = not argv or argv[0] in ("-i", ...)`，
   而 `启动.bat` 传了 `--target IP` ⇒ 掉进 CLI 单次模式，**压根没进菜单**
2. 每个菜单分支各自 `execute()`，每次都重建 telnet、重启服务、重等回连

修法：只有 argv 里出现**动作参数**才走 CLI；菜单是 `while` 循环，共享一个
`sess`（连接 + 服务 + 分区表），每次操作前用 `echo __PONG__` 探活，断了才重连。

实测（连按两次审计）：

```
设备: 192.168.1.175   第 1 次操作
[保持] 连接保留 —— 下一次操作直接复用，不会重新 getroot
[0] 复用已有 root 连接（不会重新 getroot）
设备: 192.168.1.175   第 2 次操作
```

`grep -c "2323 OPEN"` = **1**。

---

## 7. 验收记录（全部在真机上跑过）

| 项 | 结果 |
|---|---|
| `-SelfTest` 离线自检 | ✅ 全过（含 11 条门禁用例） |
| getroot | ✅ `*** 2323 OPEN t=0s ***` → `uid=0(root) gid=0(root)` |
| 会话复用 | ✅ 3 次操作只 getroot 1 次 |
| 安全审计 [5] | ✅ 两槽 md5、u-boot md5、五条逃生出口 |
| 整片备份 [6] | ✅ 15 分区 **29 秒**，md5 与 Python 版逐个一致 |
| 收尾清理 | ✅ 别名 + 防火墙全清，无残留 |
| 刷 OpenWrt dry-run | ✅ 内核 → mtd13 +seek 8 块（避开 4 MiB 截断） |
| 刷原厂 dry-run | ✅ 选定 A 槽 2.0.2，内核 → mtd10，rootfs → mtd11 |
| 刷 u-boot dry-run | ✅ `-> mtd9 0x4700000   mtd4 0x700000` |
| TTL 串口刷写 | ⬜ 代码就位，本次未插 TTL 线，**未上机** |

**未实测：真正写入 flash。** 所有写入路径只跑了 dry-run。

---

## 8. 板上当前状态（原厂固件下实测）

```
内核 4.4.60   固件 stock   IP 192.168.1.175
A 槽 kernel   mtd10 0x4880000  md5=2868d8e9...（原厂 4.4.60）
B 槽 kernel   mtd5  0x0880000  md5=2868d8e9...（原厂 4.4.60）
A 槽 u-boot   mtd9  0x4700000  md5=d0ada9f7...（我们的 kit）
B 槽 u-boot   mtd4  0x0700000  md5=d0ada9f7...（我们的 kit）
boot_flag     mtd14 0x4000000  55aa4246 00000001
```

两槽内核 md5 相同是**真实状态**：之前用 kit 把 B 槽原厂内核写过 0x4880000。

---

## 9. 重建

```bash
# WSL 里跑（要 powershell.exe 打 zip，中文文件名才不会乱）
cd wta301-2512
bash deliver/make-getroot-kit.sh              # 输出 ../work/wta301-kit + .zip
bash deliver/make-getroot-kit.sh /tmp/kit     # 指定输出目录
```

脚本会逐个校验 md5，缺一个文件就报错退出 —— 不允许出现半套。
