# ============================================================================
# 反面证据 —— 这条路【已被本板实测否定】，保留仅供研究，不要指望它能成功。
# 结论与证据见 ../../README.md §3.4 与 ../../docs/GETROOT-AND-NORMAL-USER-FLASH.md
# 要拿 root 请用上级目录的 rawtcp_gw.py。
# ============================================================================

# -*- coding: utf-8 -*-
"""假设：板子只接受源 IP = 网关(192.168.1.1) 的 SSDP 应答。
用到 scapy 用源 IP 192.168.1.1 伪造 UDP 应答，LOCATION 各指不同端口当探针。"""
import socket, struct, threading, time
from scapy.all import IP, UDP, Ether, Raw, sendp, conf, sniff
conf.use_pcap=True
IFACE='WLAN'
MYMAC='64:6c:80:2b:81:41'
BMAC='98:97:cc:a8:1f:e7'
BIP='192.168.1.175'
MYIP='192.168.1.24'
GW='192.168.1.1'
GRP='239.255.255.250'; UPORT=32768; BASE=41100
VARIANTS=[
 'http://{ip}:{p}/elink.xml',
 'http://{ip}:{p}/',
 'http://{ip}:{p}',
 '{ip}:{p}',
 'http://{ip}:{p}/elink',
]
hit={}
def listener(p,i):
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    try: s.bind(('0.0.0.0',p)); s.listen(4)
    except Exception as e: print('bind %d %s'%(p,e),flush=True); return
    s.settimeout(3)
    while True:
        try: c,a=s.accept()
        except socket.timeout: continue
        except Exception: return
        hit.setdefault(i,[]).append(a)
        print('#### CONNECT port %d == VARIANT %d : %s'%(p,i,VARIANTS[i]),flush=True)
        try: c.close()
        except: pass
for i,v in enumerate(VARIANTS):
    threading.Thread(target=listener,args=(BASE+i,i),daemon=True).start()

seen=[]
def h(pkt):
    try:
        if Ether in pkt and pkt[Ether].src.lower()==BMAC and IP in pkt and UDP in pkt and pkt[UDP].dport==UPORT:
            seen.append((pkt[IP].src,int(pkt[UDP].sport)))
    except Exception: pass
print('等待板子 M-SEARCH…',flush=True)
sniff(iface=IFACE,timeout=20,prn=h,store=False,stop_filter=lambda p: len(seen)>=1)
if not seen:
    print('!! 20s 内没收到 M-SEARCH',flush=True); raise SystemExit(1)
bip,bport=seen[0]
print('先收到一个: %s:%d'%(bip,bport),flush=True)

sent=0
for k in range(18):   # 板子约 5s 一轮
    for i,v in enumerate(VARIANTS):
        p=BASE+i
        body=('HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\n'
              'LOCATION: %s\r\nSERVER: Linux/3.10 UPnP/1.0 E-Link/1.0\r\n'
              'ST: CTC_ELINK\r\nUSN: uuid:elink::%s\r\n\r\n')%(v.format(ip=MYIP,p=p),GW)
        pkt=Ether(src=MYMAC,dst=BMAC)/IP(src=GW,dst=bip)/UDP(sport=UPORT,dport=bport)/Raw(body.encode())
        sendp(pkt,iface=IFACE,verbose=False)
        sent+=1
    time.sleep(5)
print('=== done sent=%d hits=%s ==='%(sent,hit),flush=True)
