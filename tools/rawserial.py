#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rawserial.py —— 把 COM 口原样搬到 stdin/stdout（给 SSH 通道用）

设计意图：**不要自研 TCP 守护进程**。
本机通过 plink 的 stdin/stdout 直连这个脚本，SSH 连接本身就是生命线：

  - SSH 连接在 -> 本机读写就是串口字节，没有任何中间端口
  - SSH 断了   -> 本机立刻收到 EOF / 写失败，马上能发现
  - 串口挂了   -> 本脚本退出 -> SSH 通道 EOF -> 本机知道

对比之前的 serial_tcp.py：那个版本的读线程异常后永久退出，
端口仍在 LISTEN，TCP 还能连上，但永远读到 0 字节 —— 静默假死。
这条路结构上不可能出现那种状态。

用法（由 plink 远程调用，一般不用手动跑）：
    python rawserial.py COM5 [--baud 115200]
"""
import argparse
import sys
import threading

try:
    import serial
except ImportError:
    sys.stderr.write('missing pyserial\n')
    sys.exit(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('port')
    ap.add_argument('--baud', type=int, default=115200)
    a = ap.parse_args()

    # 先打开再设 DTR/RTS：pyserial 不接受 dtr=/rts= 构造参数
    sp = serial.Serial(a.port, a.baud, timeout=0.05)
    # 这块板的 CH340 需要 DTR/RTS 拉低，否则命令发不出去
    for attr in ('dtr', 'rts'):
        try:
            setattr(sp, attr, False)
        except Exception:
            pass
    sp.reset_input_buffer()
    sp.flush()

    out = sys.stdout.buffer
    inp = sys.stdin.buffer
    stop = threading.Event()

    def dev_to_stdout():
        """串口 -> 本机。任何异常都结束整个进程（让 SSH 通道关闭，不静默）。"""
        try:
            while not stop.is_set():
                n = sp.in_waiting
                data = sp.read(n or 1)
                if data:
                    out.write(data)
                    out.flush()
        except BaseException:
            pass
        finally:
            stop.set()
            try:
                out.flush()
            except Exception:
                pass
            # 主动退出，让上游看到 EOF
            import os
            os._exit(0)

    threading.Thread(target=dev_to_stdout, daemon=True).start()

    try:
        while True:
            data = inp.read(1)
            if not data:
                break                      # 本机断开 -> 退出
            sp.write(data)
            sp.flush()
    except BaseException:
        pass
    finally:
        stop.set()
        try:
            sp.close()
        except Exception:
            pass


if __name__ == '__main__':
    main()
