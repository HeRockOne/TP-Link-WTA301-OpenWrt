"""utel.py -- u-boot telnet 控制台驱动（在笔记本上跑）

板子的 u-boot 同时开着 telnetd(23) 和 httpd(80)。TTL 串口拔掉后，
telnet 就是唯一可靠的 console —— 它走网线，不依赖 CH340。

用法：
    python utel.py "<命令>|<等待秒>" ["<命令>|<等待秒>" ...]

    tplcheck 要给足时间，例如 "tplcheck|25"。
注意：httpd 是单连接单线程的，做 HTTP 上传期间不要同时 telnet（会抢）。
"""
import io
import socket
import sys
import time

HOST = '192.168.1.1'
PORT = 23
OUT = r'C:\wta301\utel.out'


def run(specs, quiet=1.0):
    s = socket.create_connection((HOST, PORT), 5)
    s.settimeout(0.25)
    buf = bytearray()

    def drain(t):
        end = time.time() + t
        while time.time() < end:
            try:
                d = s.recv(8192)
                if not d:
                    return False
                buf.extend(d)
            except socket.timeout:
                pass
            except OSError:
                return False
        return True

    drain(quiet)
    for c, w in specs:
        try:
            s.sendall(c.encode('utf-8', 'replace') + b'\r')
        except OSError:
            break
        if not drain(w):
            break
    try:
        s.close()
    except OSError:
        pass
    return bytes(buf).decode('utf-8', 'replace')


def parse(argv):
    out = []
    for a in argv:
        if '|' in a:
            c, w = a.rsplit('|', 1)
            out.append((c, float(w)))
        else:
            out.append((a, 1.5))
    return out


if __name__ == '__main__':
    res = run(parse(sys.argv[1:]))
    io.open(OUT, 'w', encoding='utf-8', newline='\n').write(res)
    sys.stdout.buffer.write(res.encode('ascii', 'replace'))