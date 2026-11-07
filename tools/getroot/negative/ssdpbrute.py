# ============================================================================
# 反面证据 —— 这条路【已被本板实测否定】，保留仅供研究，不要指望它能成功。
# 结论与证据见 ../../README.md §3.4 与 ../../docs/GETROOT-AND-NORMAL-USER-FLASH.md
# 要拿 root 请用上级目录的 rawtcp_gw.py。
# ============================================================================

# -*- coding: utf-8 -*-
"""给每种 LOCATION 格式分配不同 TCP 端口 —— 板子连哪个端口就说明哪种格式被接受。"""
import socket, struct, threading, time, sys

MYIP='192.168.1.24'; GRP='239.255.255.250'; UPORT=32768; BASE=41000
VARIANTS = [
 'http://{ip}:{p}/elink.xml',
 'http://{ip}:{p}/',
 'http://{ip}:{p}',
 '{ip}:{p}',
 '{ip}',
 'http://{ip}:{p}/elink',
 'HTTP://{ip}:{p}/',
 'http://{ip}:{p}/dd.xml',
 '{ip} {p}',
 'udp://{ip}:{p}/',
]
hit={}
def listener(p, idx):
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    try: s.bind(('0.0.0.0',p)); s.listen(4)
    except Exception as e:
        print('bind %d fail %s'%(p,e),flush=True); return
    s.settimeout(3)
    while True:
        try: c,a=s.accept()
        except socket.timeout: continue
        except Exception: return
        hit.setdefault(idx,[]).append(a)
        print('#### TCP CONNECT on port %d  == VARIANT %d : %s'%(p,idx,VARIANTS[idx]),flush=True)
        try: c.close()
        except: pass

for i,v in enumerate(VARIANTS):
    threading.Thread(target=listener,args=(BASE+i,i),daemon=True).start()
time.sleep(1)

sk=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
sk.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
sk.bind(('0.0.0.0',UPORT))
mreq=struct.pack('4s4s',socket.inet_aton(GRP),socket.inet_aton('0.0.0.0'))
sk.setsockopt(socket.IPPROTO_IP,socket.IP_ADD_MEMBERSHIP,mreq)
sk.settimeout(1.0)
print('listening UDP 32768, %d variants on ports %d..%d'%(len(VARIANTS),BASE,BASE+len(VARIANTS)-1),flush=True)

end=time.time()+100; n=0
while time.time()<end:
    try: data,addr=sk.recvfrom(4096)
    except socket.timeout: continue
    txt=data.decode('utf-8','replace')
    if 'M-SEARCH' not in txt: continue
    n+=1
    for i,v in enumerate(VARIANTS):
        p=BASE+i
        loc=v.format(ip=MYIP,p=p)
        body=('HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\n'
              'LOCATION: %s\r\nSERVER: Linux/3.10 UPnP/1.0 E-Link/1.0\r\n'
              'ST: CTC_ELINK\r\nUSN: uuid:elink::%s\r\n\r\n')%(loc,MYIP)
        try: sk.sendto(body.encode(),addr)
        except Exception as e: print('send fail',e,flush=True)
    if n<=2: print('M-SEARCH #%d from %s -> sent %d variants'%(n,addr,len(VARIANTS)),flush=True)
print('=== done, M-SEARCH=%d, hits=%s ==='%(n,hit),flush=True)
