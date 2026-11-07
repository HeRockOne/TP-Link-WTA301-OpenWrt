# 一键工具包（拿去就能用）

用户诉求原话：「把所有傻瓜式脚本需要的文件都放一起在一个目录，这样我就可以
直接打包走」。

对应产物：

```
work/wta301-kit/            目录，62 MB，14 个文件
work/wta301-kit.zip         zip，54 MB
```

生成脚本：`deliver/make-getroot-kit.sh`（可反复重建，每次都重算并校验 md5）

---

## 1. 为什么要打包，散着放会缺什么

`deliver/wta301-getroot.py` 看着是一个文件，实际运行时还依赖两样东西：

| 依赖 | 缺了会怎样 |
|---|---|
| `srv.py` | 启动 `Servers` 时 `find_script()` 返回 None → `die("找不到 srv.py / elink_gw4.py")` |
| `elink_gw4.py` | 同上 |
| `stock/*.bin` | `--flash-stock auto` / `--restore-bslot` 找不到镜像直接退出 |
| `images/*.bin` | 菜单里「刷 OpenWrt」「刷 u-boot kit」没有文件可选 |

只拷 `.py` 到别的机器，会在「已经拿到 root、正准备写 flash」那一步才失败。
所以打包时**任一文件缺失就报错退出**，不允许出现半套。

---

## 2. 包结构

```
wta301-kit/
├─ 启动.bat                    双击入口：自提权 + 环境自检 + 中文菜单
├─ 使用说明.txt                面向使用者的说明（UTF-8 BOM，记事本可直接看）
├─ MD5SUMS.txt                 14 个文件的 md5
├─ wta301-getroot.py           主程序
├─ srv.py                      HTTP 服务（依赖）
├─ elink_gw4.py                e-Link 模拟器（依赖）
├─ stock/
│   ├─ mtd5_kernel.bin         A 槽原厂 2.0.2 内核    4 MB  170b2188…
│   ├─ mtd6_rootfs.bin         A 槽原厂 2.0.2 rootfs 12 MB  30f48741…
│   ├─ mtd10_kernel_bak.bin    B 槽原厂 4.4.60 内核    4 MB  2868d8e9…
│   └─ mtd11_rootfs_bak.bin    B 槽原厂 4.4.60 rootfs 12 MB  bf2f92ce…
└─ images/
    ├─ wta301-op-25.12.6-p29.bin            17 MB  c5ac0911…
    ├─ wta301-op-25.12.6-p29-sysupgrade.bin 13 MB  76df463d…
    ├─ wta301-uboot-p21c.bin               256 KB  d0ada9f7…
    └─ README-刷机说明.txt                  原 TTL 刷机流程
```

`启动.bat` 的菜单：

```
1  只取 root
2  安全审计（只读）
3  整片备份（约 126 MB）
4  刷 OpenWrt 到 A 槽      [先空跑再看]
5  只刷 u-boot kit         [先空跑再看]
6  刷回原厂到 A 槽         [先空跑再看]
7  修 B 槽（写回原厂）
8  看分区说明
0  退出
```

每个写入类操作都先跑 `--dry-run` 打印计划，用户敲 `y` 才真正写。

---

## 3. 编码与行尾（这里全是坑）

| 文件 | 编码 | 行尾 | 原因 |
|---|---|---|---|
| `启动.bat` | UTF-8 **无 BOM** | CRLF | cmd 会把 BOM 当命令一部分报错；`chcp 65001` 后中文才正确 |
| `使用说明.txt` | UTF-8 **带 BOM** | CRLF | 记事本靠 BOM 识别 UTF-8 |
| `MD5SUMS.txt` | UTF-8 无 BOM | CRLF | 纯 ASCII 内容 |

`.gitattributes` 对这两个文件加了 `-text`，禁止 git 做行尾转换：

```
deliver/kit/启动.bat      -text
deliver/kit/使用说明.txt  -text
```

**易踩的坑**：`启动.bat` 里所有 `set /p` 读入的变量（`TGT` / `CHOICE` / `OK` /
`AGAIN`）必须用 `!var!` 引用，不能用 `%var%`。因为整段 `if` 块在解析时
`%var%` 就已经展开成旧值了。所以 `setlocal` 必须带 `EnableDelayedExpansion`。

静态自检（谁改 bat 都要跑一遍）：

```bash
python - <<'EOF'
import io, re
lines = io.open("启动.bat", encoding="utf-8").read().split("\n")
labels = {l.strip()[1:].lower() for l in lines
          if l.strip().startswith(":") and not l.strip().startswith("::")}
gotos = [(i, m.group(1).lower()) for i, l in enumerate(lines, 1)
         for m in re.finditer(r"\bgoto\s+:?(\w+)", l, re.I)]
bad = [(i, g) for i, g in gotos if g not in labels]
print("标签", len(labels), "goto", len(gotos), "未定义", bad or "无")
EOF
```

当前结果：11 个标签 / 28 处 goto / 0 处未定义。

---

## 4. zip 里中文文件名

用 PowerShell 的 `Compress-Archive` 打包，中文名会带 UTF-8 标志位（`flag_bits & 0x800`）。
Windows 资源管理器和资源管理器右键「全部解压缩」都正常。

`make-getroot-kit.sh` 里按顺序找打包工具：

1. `powershell.exe`（PATH 里）
2. `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`（WSL interop
   默认没把 Windows 路径塞进 PATH，所以要写绝对路径）
3. `zip -qr -UN=UTF8`
4. 都没有 → 只留目录，跳过 zip（目录本身已经完整可用）

**实测**：WSL 里 `which powershell.exe` 找不到，但绝对路径存在。所以第 2 条是
必需的，不能只写第 1 条。

---

## 5. 验收记录（全部实测）

### 5.1 打包与 md5

```
14 个文件，解压后 61.5 MB，zip 53.9 MB
stock 四个 + images 三个 md5 全部等于实证值
MD5SUMS.txt 与 zip 内实际内容逐项一致
```

### 5.2 传到另一台 Windows 解压（PowerShell Expand-Archive）

```
14 个文件全部还原，字节数与源目录逐项相同
中文名带 utf8=Y 标志
```

### 5.3 在解压目录里跑主程序

| 命令 | 结果 |
|---|---|
| `--help` | 参数齐全，19 个 |
| `--explain` | 正常，中文不乱码 |
| `--flash-stock auto --dry-run` | 找到 stock 镜像、FIT/squashfs 校验通过、计划 kernel→mtd10 / rootfs→mtd11、退出码 0 |
| `--verify` | 逃生出口 5 条，A 槽 rootfs 判为「非已知原厂」、B 槽判为「原厂 4.4.60」，判定正确 |
| `--restore-bslot --dry-run` | md5 门禁通过，kernel→mtd5 / rootfs→mtd6 |

`--flash-stock auto --dry-run` 能跑通这条最关键：它同时证明了

- `find_script()` 找到了同目录的 `srv.py` / `elink_gw4.py`
- 自动 getroot 成功（Servers 起得来）
- `find_stock_set()` 找到了同目录的 `stock/`
- 计划落点与安全门禁都没问题

---

## 6. 板上当前状态（`--verify` 实测，2026-11-07）

```
boot_flag (mtd14) 头 = 55aa4246          → 能选槽
mtd4 / mtd9 = d0ada9f7… = 我们的 kit

A 槽 mtd10/11   kernel FIT  2868d8e9…（原厂 4.4.60）
                rootfs squashfs 3df05b56…（不是任何已知原厂版本）
                → 可启动，但这个槽的原厂回退能力不完整

B 槽 mtd5/6     kernel FIT  2868d8e9…  rootfs bf2f92ce…
                → 可启动，完整原厂 4.4.60

离线原厂镜像：找到 2.0.2 那组
结论：逃生出口 5 条，mtd0/mtd1/mtd2/mtd14 都未动
```

A 槽那个 `2868d8e9` 是上一轮从 u-boot 里 `nand read 0x880000` → `nand write 0x4880000`
写进去的（B 槽原厂内核），所以 A 槽现在是「原厂内核 + OpenWrt rootfs」的半残状态。
跑一次菜单 `6 刷回原厂到 A 槽` 就变成完整 2.0.2（`170b2188` + `30f48741`）。

---

## 7. 重建

```bash
# WSL 里跑（要 powershell 打 zip）
cd wta301-2512
bash deliver/make-getroot-kit.sh              # 输出 ../work/wta301-kit
bash deliver/make-getroot-kit.sh /tmp/kit     # 指定输出目录
```

脚本会先 `rm -rf` 目标目录再从零重建，然后逐个校验 md5。任一不符即退出。

源文件取自四处：

```
wta301-2512/deliver/wta301-getroot.py
wta301-2512/deliver/kit/{启动.bat,使用说明.txt}
wta301-2512/deliver/stock/*.bin
work/net/{srv.py,elink_gw4.py}
work/deliver-final-p29/*.bin
```

`deliver/stock/*.bin` 被 `.gitignore` 排除，克隆仓库后需要先按
`deliver/stock/README.md` 从原厂全盘镜像 `flash_full_128M.bin` 里按偏移切出来
（四个 md5 都写在那份 README 里）。
