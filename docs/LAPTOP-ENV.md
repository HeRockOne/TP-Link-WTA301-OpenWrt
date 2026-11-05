# 三星笔记本（192.168.1.100）环境存档

**本机没有 192.168.1.x 口**，所有对板子的 HTTP/TFTP 都从这台笔记本发出。
`ssh -i ~/.ssh/wta301 null@192.168.112.222` · 有本机 plink，两边都能用 plink。

## 2026-11-06 清理后现状

清理前 `C:\Users\sophia` 下 380+ 个一次性探针脚本、`Downloads\wta` 15.1 GB；
清理后根目录 0 个文件，`wta` 只剩 op/ 与三件回退资产。释放 **14.65 GB**（C: 剩 29.7 GB）。

### `C:\Users\sophia\Downloads\wta\`
| 项 | 大小 | 说明 |
|---|---|---|
| `op\` | 98.8 MB | **TFTP 根目录**（`WTA301_TFTP` 任务指向这里，不能删目录） |
| `a_kernel.bin` | 4,194,304 | A 槽 kernel 回退 |
| `b_rootfs.bin` | 12,582,912 | B 槽 rootfs 回退 |
| `wta_key.pem` | 1,704 | 早期 SSH 私钥 |

### `wta\op\` 保留清单（12 个文件）
```
   17,170,432  op_wta301_firmware_web.bin   ← 网页刷机（紧凑包），md5 837a9a55…
   20,447,232  P17_single.bin               ← TTL nand write（稀疏包）
      262,144  kit_p19_slot.bin             ← 现役二级 u-boot 槽镜像
   17,302,016  fw_202.bin                   ← 官网 2.0.2，回原厂
    4,718,592  op_kernel_0x480000.bin       ┐
   12,320,768  op_rootfs_0xbc0000.bin       ├ 三件套，flash_release.py 要用
      131,072  op_tphdr_0x20000.bin         ┘
    1,966,080  ubi_rootfs_data3_wta301data.img
   23,068,672  op_mtd8_stock_ubi.bin        ← mtd8 dump
    4,194,304  mtd10_kernel_bak.bin         ← B 槽 kernel 回退
          959  FINGERPRINT.json
          924  flash_cmds.txt
```

### `C:\wta301\`（服务目录）
| 文件 | 用途 | 依赖它的任务 |
|---|---|---|
| `rawserial.py` | COM5 ↔ stdin/stdout，供 plink 串口桥 | 本机 `work/net/plink_serial.py` |
| `agent.py` | 笔记本 agent（`lap.py --backend agent` 用） | `WTA301_Agent` |
| `tftpd_v2.py` | TFTP 服务 | `WTA301_TFTP`（Running） |
| `watchdog.ps1` | 看护（**已删除其中 7001/serial_tcp 段**，串口改走 plink） | `WTA301_Watchdog` |
| `www\` | 静态文件 | `WTA301_HTTP`（8000 端口） |
| `OpenSSH-Win64-v9.5.0.0.msi` | sshd 安装包 —— plink 通道的保命备份，勿删 | — |

已删除的重复任务：`wta301tftp`（与 `WTA301_TFTP` 抢 69 端口）、`WTA301_Bridge`（已废弃）。

## sshd 配置（串口桥的前提）

```
HKLM\SOFTWARE\OpenSSH\DefaultShell = C:\Windows\System32\cmd.exe
```

**必须是 cmd.exe**：PowerShell 会转码并吞引号，二进制字节流透传会坏。
改了默认 shell 后，`lap.py --raw` 里的命令不能用 PowerShell 语法，要写
`powershell -c "..."`。`lap.py` 走 `run_ps()`（显式调 PowerShell），不受影响。

## 踩过的坑

1. **`subprocess.run(text=True)` 在中文 Windows 按 GBK 解码**。笔记本回传 UTF-8
   或串口字节时读线程抛 `UnicodeDecodeError`，`stdout` 静默变空字符串
   —— 看上去像「命令没输出」。必须 `encoding='utf-8', errors='replace'`。
2. **`powershell -EncodedCommand` 的输出混 CLIXML**，过滤时要同时滤掉
   `#< CLIXML` 行和 `<Objs ...>` 行。
3. **`lap.py` 位置**：仓库里的 `tools/*.py` 归档副本上级是 `wta301-2512/`，
   不是项目根，找 `work/net/lap.py` 必须向上逐级搜。
4. **plink 被杀后远程 python 不一定退出**，残留实例会一直占 COM5，
   新实例 `PermissionError`，谁也读不到数据。`rawserial.py` 启动时会先清理同名实例。
