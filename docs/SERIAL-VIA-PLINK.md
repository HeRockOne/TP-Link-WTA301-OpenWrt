# 串口桥：改用 plink 的 SSH 通道（废弃自研 TCP 守护进程）

**状态：已落地并实测（2026-11-06）**

**起由**：用户两次质问 ——「为什么那么复杂！！！！plink连接ssh不能够满足需求吗？
明明两边都有plink。」以及「你赶紧修好连接桥，脆弱」。

结论：用户是对的。此前 `serial_tcp.py`（笔记本）+ `lap.py --up` 端口转发（本机）
的组合有两处结构性缺陷，而且我在它上面又叠了一层守护（心跳、计划任务、
看护脚本），复杂度全花在补漏洞上。

---

## 一、旧方案为什么脆弱（根因，不是偶然）

`serial_tcp.py` 的读线程：

```python
def pump_serial_to_sock(sp, conn, stop):
    while not stop.is_set():
        try:
            data = sp.read(n or 1)
        except Exception:
            break                    # ← 永久退出
        if data:
            try:
                conn.sendall(data)
            except Exception:
                break                # ← 永久退出
```

读线程一死，主循环仍在 `recv` 等客户端说话。结果：

| 观察 | 实际 |
|---|---|
| 7001 在 LISTEN | 是 |
| TCP 能连上 | 是 |
| 能读到串口数据 | **永远 0 字节** |

这是**静默假死**：从外部看一切正常，只能靠人发现。2026-11-06 01:13 又复现一次。

补充一个更隐蔽的实例：`tftpd.py` 单线程，一次 RRQ 传输期间主循环卡在 ACK 重试里，
新请求收不到 —— 现象同样是「端口在听、请求无回应」。

**共性：自研守护进程没有「连接」这个概念，所以无法自我判定死活。**

## 二、新方案：SSH 通道即生命线

```
本机  work/net/plink_serial.py
        socket://127.0.0.1:7001
             │
             └─ plink -ssh -batch -i wta301.ppk null@192.168.112.222
                     "python.exe C:\wta301\rawserial.py COM5 --baud 115200"
                          │
                          ├─ stdin  ← 本机写的字节 → COM5
                          └─ stdout → COM5 读到的字节 → 本机
```

笔记本上**没有常驻进程、没有监听端口、没有计划任务、没有心跳文件**。
`rawserial.py` 由 plink 前台执行，随连接生灭。

### 三条自愈语义（结构保证，不靠巡检）

| 事件 | 结果 |
|---|---|
| plink 进程被杀 / SSH 断 | 本机 `stdout` 立刻 EOF → 断开客户端 → 重启 plink |
| 串口读异常 | `rawserial.py` 主动 `os._exit(0)` → SSH 通道 EOF → 同上 |
| 客户端断开 | 本机对 plink `stdin` 写失败 → 杀掉 plink → 下次连接重建 |

**没有「连着但没数据」这一态** —— 因为 SSH 通道断了就是断了，不会有僵尸端口。

## 三、必须改的一处：sshd 的 DefaultShell

`rawserial.py` 透传的是**二进制**。笔记本 sshd 默认 shell 是 PowerShell，
它会按编码解码 native 程序的 stdout，破坏二进制；而且 `"C:\...\python.exe"` 这种
引号命令会被 PowerShell 参数解析吃掉（实测报
`表达式或语句中包含意外的标记 "C:\wta301\rawserial.py"`）。

```
HKLM\SOFTWARE\OpenSSH\DefaultShell = C:\Windows\System32\cmd.exe
```

- **不需要重启 sshd**，只对新连接生效
- `lap.py` 的 `run_ps` 用 `powershell -NoProfile -EncodedCommand` 显式调用，不受影响；
  受影响的只有 `lap.py --raw`（那里传的若是纯 PowerShell 命令要改成 `powershell -c "..."`）

## 四、看门狗

`C:\wta301\watchdog.ps1` 原本会看护 7001 并在缺失时拉起 `serial_tcp.py`。
这段已删除 —— 否则它会把旧桥拉回来抢 COM5（实测 `PermissionError(13, '拒绝访问')`）。

保留 8199/agent 的看护（与本方案无关）。

## 五、用法

```bash
python work/net/plink_serial.py            # 前台（调试用）
python work/net/plink_serial.py --bg       # 后台常驻
python work/net/plink_serial.py --status   # 自检：端口 + 日志尾
python work/net/plink_serial.py --stop     # 停

# 现有工具零改动，仍用 socket://
WTA_PORT=socket://127.0.0.1:7001 python work/out-final/rescue.py probe
```

环境变量可覆盖：`WTA_COM`（默认 COM5）、`WTA_BAUD`、`WTA_PORT_NUM`（默认 7001）、
`WTA_RAWSERIAL`（笔记本上的脚本路径）、`WTA_REMOTE_PYTHON`。

## 六、实测证据

**01:36:26 首次连通**
```
[bridge] listening 127.0.0.1:7001 -> plink 192.168.112.222:COM5
[bridge] plink spawned pid=12080 (COM=COM5)
--> 读到 u-boot help 输出，结尾 IPQ5018#
```

**01:36:41 韧性测试（`taskkill /F /IM plink.exe`）**
```
[bridge] plink stdout EOF (SSH closed)
[bridge] device channel lost -> will respawn
[bridge] respawning plink
[bridge] plink spawned pid=4152 (COM=COM5)
--> 立即恢复，读到 IPQ5018#
```

自动重连耗时 **< 1 s**（日志同一秒）。

## 七、与旧方案的对照

| 项 | 旧（serial_tcp.py） | 新（plink_serial.py） |
|---|---|---|
| 跨机常驻进程 | 有 | **无** |
| 跨机监听端口 | 7001 | **无** |
| 假死可能 | 有（实测 2 次） | **结构上不存在** |
| 笔记本侧依赖 | pyserial + 计划任务 + 心跳 + 看门狗 | plink 执行一个脚本 |
| 断线检测 | 无 | EOF 立即 |
| 自愈 | 靠人 / 靠看门狗 | 自动 respawn |
| 本机端口 | 经 `lap.py --up` 隧道 | 本地直接监听 7001 |
