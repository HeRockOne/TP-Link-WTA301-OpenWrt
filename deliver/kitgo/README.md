# wta301 一键工具（Go 版）

单文件 exe，零依赖。原厂 ⇄ OpenWrt 互刷 / 备份 / 审计 / u-boot。

## 编译

```bash
export PATH="/c/Program Files/Go/bin:$PATH"
cd wta301-2512/deliver/kitgo
go build -ldflags="-s -w" -o wta301.exe .
```

产物约 4.3 MB，不需要 Go 运行环境，也不需要 PowerShell 脚本权限。

## 为什么用 Go 而不是 PowerShell

旧版 `deliver/kit/wta301.ps1`（约 2100 行）能跑，但踩了一串语言层的坑，
每个都要花半小时以上，而且错误是**静默**的：

| PowerShell 的坑 | Go 里 |
|---|---|
| `@{0x4880000=...}` 键是 Int32，查找传 Int64 ⇒ 写入门禁**全部静默放行** | int64 就是 int64 |
| `@{Stop={...}}` scriptblock 不是词法闭包 ⇒ 清理整段不执行，网关别名/防火墙残留 | 闭包就是闭包 |
| 给 `ssh.exe` 喂密码要 SSH_ASKPASS + .bat + cmd /c + `< 文件` + LF + 禁管道 | `ssh.Dial` 一行 |
| `LiteralPath 为空字符串` 的报错点离根因一万行 | 入口直接拦 |
| 某些机器 `Get-FileHash` "无法识别" | .NET `MD5.Create()` |
| `/sys/class/mtd/mtd*` glob 会匹配到 `mtdNro` 字符设备 ⇒ 挂 30 s | 显式 0..19 + `[ -d ]` |

## ★ 写入必须走内核 MTD

**唯一合法写法**：

```
mtd erase <label>
mtd -q write <file> <label>
```

原因与两次事故的完整记录见 `docs/FLASH-INCIDENT-ECC-AND-SAME-SLOT.md`。摘要：

- 这颗 NAND（GigaDevice GD5F1GQ5REYIG）每页带 **ECC 8-bit**，校验码由**内核 MTD 层**算进 OOB
- `dd of=/dev/mtdN` 绕过内核 ⇒ 写进去没有校验码 ⇒ 之后读全部 `I/O error`，分区报废
- `dd of=/dev/mtdblockN` 在原厂 4.4.60 可用，在 OpenWrt 6.12.112 下报 `I/O error`
- busybox 的 `mtd` 不认 mtd-utils 的 `-e` 开关，所以必须两条命令

**裸 `/dev/mtdN` 只读不写** —— 读不需要解 ECC，快，且能暴露写坏的情况。

## ★ 必须交叉刷

```
跑 A 槽 → 写 B 槽  ✓
跑 B 槽 → 写 A 槽  ✓
跑 A 槽 → 写 A 槽  ✗ 概率性把系统卡死
```

`mtd erase` 持有 MTD 全局锁，而 rootfs（squashfs）的读也走 MTD。
擦自己正在运行的分区 ⇒ dropbear/uhttpd 全部阻塞 ⇒ ping 通但 SSH/HTTP 全断，只能断电重启。

`guard.go` 的 `ActiveSlot()` / `CheckSameSlot()` 会挡住，需要 `-allow-same-slot` 才放行。

## 写入门禁（真抛异常，`-yes` 绕不过）

```
永不写：mtd0 一级u-boot  mtd1 出厂信息  mtd2 ART射频校准  mtd14 boot_flag
按动作授权：
  0x0700000 / 0x4700000  两槽 u-boot   ← -flash-uboot
  0x0880000 / 0x0fc0000  B 槽内核/rootfs ← -restore-bslot
  0x4fc0000              A 槽 rootfs   ← -flash-op
```

判据一律是**绝对偏移**，不是 mtd 编号 —— 编号跨固件会错位，而且
OpenWrt 下 `mtd13` 是 `boot_flag`，原厂下 `mtd13` 是 `firmware_bak`。

## 用法

```
wta301.exe                                     # 菜单
wta301.exe -target 192.168.1.1 -password root -verify
wta301.exe -target 192.168.1.1 -password root -flash-op -yes -keep
wta301.exe -target 192.168.1.1 -password root -flash-stock -dry-run
wta301.exe -selftest -app <目录>               # 自检：镜像 md5 + 17 条门禁 + 落点解析
wta301.exe -target IP -password X -exec "命令"  # 调试：在设备上跑一条命令
```

`-self` 系列参数：`-target -password -user -kind -stock -backup -app -dry-run -yes -keep -allow-same-slot`

## 自检

```
$ wta301.exe -selftest -app ../work/wta301-kit
  镜像 md5      5/5
  写入门禁      17/17
  落点解析      3/3
  自检通过
```

落点解析的关键用例（两种固件分区表不同，同一绝对偏移可能落到不同 mtd）：

```
0x4880000 need 0x41526c -> mtd13 (0x4800000 +seek 4 块)   # 原厂表：装不下 mtd10
0x4880000 need 0x400000 -> mtd10 (0x4880000)              # 原厂表：正好
0x4fc0000 need 0xc00000 -> mtd6  (0x4fc0000)              # OpenWrt 表
```
