#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""web_flash.py —— 完整走一遍 Web failsafe 刷机：/upload -> /result -> /reboot

为什么要它：现有的 web_upload_test.py 只打 /upload（校验），不写盘；
仓库里没有把三步串起来、且**在同一个进程里持串口**的完整刷写工具。
本文件沿用 web_upload_test.py 的既有模式，只补上 /result 与 /reboot。

为什么必须在同一进程里持串口：
u-boot 的 httpd 主循环每轮都 poll 控制台 ctrlc()。串口句柄一关闭，
CH340 的线状态变化会被 u-boot 读成 Ctrl+C，服务器立刻退出 —— 所以
任何 HTTP 操作都必须由「保持串口打开的那个进程」发起。

用法：
    python web_flash.py <本地web包> [笔记本上的路径] [--dry]

    --dry   只做 /upload 校验，不写 flash
"""
import os
import subprocess
import sys
import time

import serial

HERE = os.path.dirname(os.path.abspath(__file__))
LAPTOP = os.path.join(os.path.dirname(HERE), 'net', 'laptop.py')
PORT = os.environ.get('WTA_PORT', 'COM7')
BOARD = 'http://192.168.1.1'

KEYS = ('tpimg', 'fw_type', 'upload_data', 'nand', 'erase', 'write',
        'Error', 'error', 'status', 'response message', '###', 'gunzip',
        'httpd', 'Web failsafe', 'reboot', 'reset')


def drain(sp, secs):
    t0 = time.time()
    buf = bytearray()
    while time.time() - t0 < secs:
        n = sp.in_waiting
        if n:
            d = sp.read(n)
            if d:
                buf.extend(d)
        else:
            time.sleep(0.02)
    return buf.decode('utf-8', 'replace')


def show(title, text, full=False):
    print('\n--- %s ---' % title)
    if full:
        print(text[-2000:])
        return
    seen = False
    for line in text.splitlines():
        s = line.strip()
        if s and any(k in s for k in KEYS):
            print('  ' + s[:180])
            seen = True
    if not seen:
        print('  (没有匹配的关键输出)')


def ps_run(ps, timeout='600'):
    """在笔记本上跑一条命令（笔记本才在 192.168.1.0/24）。"""
    r = subprocess.run([sys.executable, LAPTOP, ps, timeout],
                       capture_output=True, text=True)
    return (r.stdout or '').strip()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    dry = '--dry' in sys.argv
    if not args:
        print('用法: python web_flash.py <本地web包> [笔记本路径] [--dry]')
        return 1
    src = args[0]
    remote = args[1] if len(args) > 1 else \
        r'C:\Users\sophia\Downloads\wta\op\v21web.bin'
    if not os.path.isfile(src):
        print('找不到 %s' % src)
        return 1
    print('[本地] %s  %d B' % (src, os.path.getsize(src)))
    print('[远端] %s' % remote)

    sp = serial.serial_for_url(PORT, 115200, timeout=0.05)
    try:
        sp.dtr = False
        sp.rts = False
    except Exception:
        pass
    time.sleep(0.4)
    sp.reset_input_buffer()
    sp.flush()
    drain(sp, 1.5)

    # 确保在 u-boot 提示符，然后起 httpd
    sp.write(b'\r')
    sp.flush()
    time.sleep(0.6)
    before = drain(sp, 1.2)
    if 'IPQ5018' not in before and '#' not in before:
        print('[warn] 没看到 u-boot 提示符，当前输出：')
        print(before[-400:])
    sp.write(b'printenv ;httpd\r')
    sp.flush()
    boot = drain(sp, 8)
    if 'Web failsafe UI' in boot or 'httpd' in boot.lower():
        print('[ok] httpd 已启动')
    else:
        print('[warn] 未确认 httpd 启动，输出：')
        print(boot[-500:])

    # ---- 第 1 步：/upload（校验，只写 RAM）----
    url = remote.replace('\\', '/')
    ps = ('curl.exe -sS -m 600 -w "\\nHTTP=%%{http_code} SIZE=%%{size_download}"'
          ' -F "firmware=@%s" %s/upload' % (url, BOARD))
    print('\n[1/3] POST /upload')
    t0 = time.time()
    out = ps_run(ps)
    print('  用时 %0.1fs' % (time.time() - t0))
    print('  ' + (out[-800:] if out else '(空)'))
    show('板子串口', drain(sp, 6))

    if 'success' not in out.lower():
        print('\n[停] /upload 未返回 success，不写 flash。')
        sp.close()
        return 2
    if dry:
        print('\n[--dry] 校验通过，按要求不写 flash。')
        sp.close()
        return 0

    # ---- 第 2 步：/result（真正写 flash）----
    print('\n[2/3] POST /result （开始写 flash）')
    ps = ('curl.exe -sS -m 600 -w "\\nHTTP=%%{http_code}"'
          ' -X POST %s/result' % BOARD)
    t0 = time.time()
    out = ps_run(ps)
    print('  用时 %0.1fs' % (time.time() - t0))
    print('  ' + (out[-800:] if out else '(空)'))
    show('板子串口', drain(sp, 10))

    if 'success' not in out.lower():
        print('\n[停] /result 未返回 success，不重启。板子仍在 u-boot，可查串口。')
        sp.close()
        return 3

    # ---- 第 3 步：/reboot ----
    print('\n[3/3] POST /reboot')
    ps = ('curl.exe -sS -m 60 -w "HTTP=%%{http_code}"'
          ' -X POST %s/reboot' % BOARD)
    out = ps_run(ps, '60')
    print('  ' + (out[-300:] if out else '(空，通常正常 —— 板子已复位)'))
    show('板子串口', drain(sp, 12))

    sp.close()
    print('\n[完成] 三项请求均已发出。请检查串口重启日志。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
