#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""plink_serial.py —— 串口桥（本机侧），走 plink 的 SSH 通道

    socket://127.0.0.1:7001  <->  plink stdin/stdout  <->  笔记本 COM5

为什么这样取代 serial_tcp.py：

    旧方案在两台机器之间跑一个手写 TCP 守护进程，它有「静默假死」——
    端口还在 LISTEN、TCP 还能连上，但永远读到 0 字节，只能靠人发现。

    这条路把串口字节流放进 plink 的 stdin/stdout：SSH 连接本身就是生命线。
      SSH 在   -> 读到什么就是串口字节
      SSH 断   -> stdout 立刻 EOF，本脚本马上断开客户端并重启 plink
      plink 死 -> 同上
    结构上不存在「连着但没数据」的状态。

笔记本上只需要 plink 执行一个前台脚本 rawserial.py，没有常驻进程、
没有监听端口、没有计划任务、没有心跳文件。

用法：
    python work/net/plink_serial.py            # 前台
    python work/net/plink_serial.py --bg       # 后台常驻
    python work/net/plink_serial.py --status   # 自检
    python work/net/plink_serial.py --stop
"""
import argparse
import io
import os
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

HOST = os.environ.get('LAP_HOST', '192.168.112.222')
USER = os.environ.get('LAP_USER', 'null')
PPK = os.environ.get('LAP_PPK', os.path.join(ROOT, 'work', 'scratch', 'wta301.ppk'))
HOSTKEY = os.environ.get('LAP_HOSTKEY',
                         'SHA256:WBOjCwfzqKkzQdXepdVSFLYIBQPQ563Xb8t1eAQsNAM')
COM = os.environ.get('WTA_COM', 'COM5')
BAUD = os.environ.get('WTA_BAUD', '115200')
# 笔记本上用于串口中继的 Python。默认就用 PATH 里的 python.exe，
# 因为笔记本型号不同，写死某个安装路径对别人无意义。
PYTHON = os.environ.get('WTA_REMOTE_PYTHON', 'python.exe')
REMOTE = os.environ.get('WTA_RAWSERIAL', r'C:\wta301\rawserial.py')
PORT = int(os.environ.get('WTA_PORT_NUM', '7001'))
PIDFILE = os.path.join(ROOT, 'work', 'scratch', 'plink_serial.pid')
LOGFILE = os.path.join(ROOT, 'work', 'scratch', 'plink_serial.log')


def plink_bin():
    return os.environ.get('LAP_PLINK', os.path.join(ROOT, 'work', 'vendor', 'PuTTY', 'plink.exe'))


class Log(object):
    def __init__(self, path):
        self.path = path

    def __call__(self, msg):
        line = '%s %s' % (time.strftime('%H:%M:%S'), msg)
        try:
            print(line, flush=True)
        except Exception:
            pass
        try:
            with open(self.path, 'a', encoding='utf-8') as f:
                f.write(line + '\n')
        except Exception:
            pass


class Bridge(object):
    def __init__(self, log):
        self.log = log
        self.proc = None
        self.proc_lock = threading.Lock()
        self.client = None
        self.client_lock = threading.Lock()
        self.stop = threading.Event()
        self.generation = 0

    # ---- plink 子进程 ----
    def spawn(self):
        remote_cmd = '"%s" "%s" %s --baud %s' % (PYTHON, REMOTE, COM, BAUD)
        cmd = [plink_bin(), '-ssh', '-batch', '-no-antispoof',
               '-hostkey', HOSTKEY, '-i', PPK,
               '%s@%s' % (USER, HOST), remote_cmd]
        try:
            p = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE,
                                 bufsize=0)
        except Exception as e:
            self.log('[bridge] spawn failed: %s' % e)
            return None
        self.log('[bridge] plink spawned pid=%d (COM=%s)' % (p.pid, COM))
        return p

    def read_stderr(self, proc):
        try:
            for raw in iter(proc.stderr.readline, b''):
                line = raw.decode('utf-8', 'replace').rstrip()
                if line:
                    self.log('[plink] %s' % line)
        except Exception:
            pass

    def pump_dev_to_client(self, proc, gen):
        """plink stdout -> 客户端 socket。EOF 表示 SSH 通道断了。"""
        out = proc.stdout
        try:
            while not self.stop.is_set():
                data = out.read(4096)
                if not data:
                    self.log('[bridge] plink stdout EOF (SSH closed)')
                    break
                c = self.client
                if c is None:
                    continue
                try:
                    c.sendall(data)
                except Exception:
                    self.drop_client()
        except Exception as e:
            self.log('[bridge] dev->client error: %s' % e)
        finally:
            if gen == self.generation:
                self.log('[bridge] device channel lost -> will respawn')
                self.kill_proc()

    def kill_proc(self):
        with self.proc_lock:
            p, self.proc = self.proc, None
        if p is not None:
            try:
                p.kill()
            except Exception:
                pass
        self.drop_client()

    def drop_client(self):
        with self.client_lock:
            c, self.client = self.client, None
        if c is not None:
            try:
                c.close()
            except Exception:
                pass

    def ensure_proc(self):
        with self.proc_lock:
            if self.proc is not None and self.proc.poll() is None:
                return self.proc
        p = self.spawn()
        if p is None:
            return None
        with self.proc_lock:
            self.proc = p
            self.generation += 1
            gen = self.generation
        threading.Thread(target=self.read_stderr, args=(p,), daemon=True).start()
        threading.Thread(target=self.pump_dev_to_client, args=(p, gen),
                         daemon=True).start()
        return p

    # ---- 客户端 ----
    def serve_client(self, conn):
        self.drop_client()
        with self.client_lock:
            self.client = conn
        self.log('[bridge] client connected')
        gen = self.generation
        try:
            conn.settimeout(0.5)
            while not self.stop.is_set():
                try:
                    data = conn.recv(4096)
                except socket.timeout:
                    # 通道断了就主动关客户端，逼它重连
                    with self.proc_lock:
                        p = self.proc
                    if p is None or p.poll() is not None:
                        self.log('[bridge] device gone, closing client')
                        break
                    continue
                except Exception:
                    break
                if not data:
                    break
                with self.proc_lock:
                    p = self.proc
                if p is None or p.poll() is not None:
                    break
                try:
                    p.stdin.write(data)
                    p.stdin.flush()
                except Exception as e:
                    self.log('[bridge] write to device failed: %s' % e)
                    self.kill_proc()
                    break
        finally:
            with self.client_lock:
                if self.client is conn:
                    self.client = None
            try:
                conn.close()
            except Exception:
                pass
            self.log('[bridge] client gone')

    def run(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(('127.0.0.1', PORT))
        srv.listen(4)
        srv.settimeout(1.0)
        self.log('[bridge] listening 127.0.0.1:%d -> plink %s:%s'
                 % (PORT, HOST, COM))
        self.ensure_proc()

        try:
            while not self.stop.is_set():
                # 守护：plink 死了就重启（含 SSH 掉线）
                with self.proc_lock:
                    p = self.proc
                if p is None or p.poll() is not None:
                    self.log('[bridge] respawning plink')
                    self.ensure_proc()
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    continue
                except Exception:
                    continue
                threading.Thread(target=self.serve_client, args=(conn,),
                                 daemon=True).start()
        finally:
            self.stop.set()
            self.kill_proc()
            try:
                srv.close()
            except Exception:
                pass


def is_alive(port=PORT):
    try:
        s = socket.create_connection(('127.0.0.1', port), 2)
        s.close()
        return True
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bg', action='store_true', help='后台常驻')
    ap.add_argument('--status', action='store_true')
    ap.add_argument('--stop', action='store_true')
    a = ap.parse_args()

    if a.status:
        print('port 7001 : %s' % ('LISTENING' if is_alive() else 'DOWN'))
        if os.path.isfile(PIDFILE):
            print('pidfile   : %s' % open(PIDFILE).read().strip())
        if os.path.isfile(LOGFILE):
            print('--- log tail ---')
            for line in open(LOGFILE, encoding='utf-8', errors='replace').read().splitlines()[-6:]:
                print('  ' + line)
        return

    if a.stop:
        if os.path.isfile(PIDFILE):
            try:
                pid = int(open(PIDFILE).read().strip())
                os.kill(pid, 9)
                print('killed %d' % pid)
            except Exception as e:
                print('kill failed: %s' % e)
        return

    log = Log(LOGFILE)
    log('[bridge] start pid=%d' % os.getpid())
    with open(PIDFILE, 'w') as f:
        f.write(str(os.getpid()))
    b = Bridge(log)
    try:
        b.run()
    except KeyboardInterrupt:
        b.stop.set()


if __name__ == '__main__':
    main()
