# ============================================================================
# 旧版组件 —— 已被 ../../rawtcp_gw.py 取代，保留只为对上既有文档的引用。
# 注意：getroot.py 走「给本机加 <网关IP>/32 别名」的老路，单网卡拓扑下会断网。
# ============================================================================

#!/usr/bin/env python3
"""e-Link 网关模拟器 v4 —— 完成握手后主动下发 ubus_call。"""
import socket, struct, json, base64, threading, time, sys, os, random
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

MAGIC=0x3F721FB5
LOG=open('elink_gw4.log','a',encoding='utf-8',buffering=1)
def log(*a):
    s=' '.join(str(x) for x in a); print(s,flush=True); LOG.write(time.strftime('[%H:%M:%S] ')+s+'\n')
def rx(s,n):
    b=b''
    while len(b)<n:
        c=s.recv(n-len(b))
        if not c: return None
        b+=c
    return b
def read_frame(s):
    h=rx(s,8)
    if not h: return None
    m,l=struct.unpack('>II',h)
    if m!=MAGIC: return None
    return rx(s,l)
def send_frame(s,p): s.sendall(struct.pack('>II',MAGIC,len(p))+p)
def enc(k,d):
    c=Cipher(algorithms.AES(k),modes.CBC(b'\x00'*16)).encryptor(); return c.update(d)+c.finalize()
def dec(k,d):
    c=Cipher(algorithms.AES(k),modes.CBC(b'\x00'*16)).decryptor(); return c.update(d)+c.finalize()

CMD=None
def handle(conn,addr):
    global CMD
    log('=== accept from',addr); conn.settimeout(120)
    st={'aes':None,'seq':0}
    try:
        while True:
            body=read_frame(conn)
            if body is None: log('--- closed'); break
            raw=body
            plain=dec(st['aes'],body) if st['aes'] else body
            try: txt=plain.rstrip(b'\x00').decode('utf-8')
            except Exception:
                log('!! undecodable',plain[:80].hex()); break
            log('<<<',txt[:800])
            try: j=json.loads(txt)
            except Exception:
                log('   (padding tail, ignore)'); continue
            t=j.get('type'); seq=j.get('sequence',0); mac=j.get('mac','')
            st['seq']=seq
            if t=='keyngreq':
                send_frame(conn,json.dumps({'type':'keyngack','sequence':seq,'mac':mac,'keymode':'dh','data':{'keymode':'dh'}},separators=(',',':')).encode())
            elif t=='dh':
                d=j['data']; pc=int.from_bytes(base64.b64decode(d['dh_key']),'big')
                p=int.from_bytes(base64.b64decode(d['dh_p']),'big'); g=int.from_bytes(base64.b64decode(d['dh_g']),'big')
                for _ in range(500):
                    priv=random.randrange(2,p-2); pub=pow(g,priv,p); sh=pow(pc,priv,p)
                    sb=sh.to_bytes((p.bit_length()+7)//8,'big').lstrip(b'\x00')
                    if len(sb)==16: break
                st['aes']=sb; log('    AES',sb.hex())
                send_frame(conn,json.dumps({'type':'dh','sequence':seq,'mac':mac,'data':{'dh_key':base64.b64encode(pub.to_bytes((p.bit_length()+7)//8,'big').lstrip(b'\x00')).decode(),'dh_p':d['dh_p'],'dh_g':d['dh_g']}},separators=(',',':')).encode())
            elif t=='dev_reg':
                if CMD:
                    time.sleep(0.3)
                    obj,meth,msg=CMD
                    p={'type':'ubus_call','sequence':seq+1,'mac':mac,
                       'data':[{'object':obj,'method':meth,'message':CMDMSG}]}
                    pl=json.dumps(p,separators=(',',':')).encode()
                    pl=pl+b'\x00'*((16-len(pl)%16)%16)
                    send_frame(conn,enc(st['aes'],pl))
                    log('>>> ubus_call %s.%s %s'%(obj,meth,msg))
            elif t=='ubus_call':
                log('*** ubus 结果:',json.dumps(j.get('data'),ensure_ascii=False)[:1500])
            elif t=='keepalive':
                pass
            else:
                log('*** 业务帧',t)
                send_frame(conn,json.dumps({'type':'ack','sequence':seq,'mac':mac,'data':{}},separators=(',',':')).encode())
    except Exception as e:
        log('!! exc',type(e).__name__,e)
    finally:
        try: conn.close()
        except Exception: pass

def main():
    global CMD,CMDMSG
    CMDMSG={}
    port=int(os.environ.get('ELINK_PORT','32768'))
    dur=int(sys.argv[1]) if len(sys.argv)>1 else 90
    # 约定: argv[2]=obj  argv[3]=meth  argv[4..]=msg 片段(自动拼接)
    if len(sys.argv)>4:
        obj=sys.argv[2]; meth=sys.argv[3]
        m=' '.join(sys.argv[4:])
        if m.startswith('RAW:'):
            CMDMSG=json.loads(m[4:])
        else:
            try: CMDMSG=json.loads(m)
            except Exception: CMDMSG={}
        CMD=(obj,meth,m)
    else:
        CMD=('','','')
    srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    srv.bind(('0.0.0.0',port)); srv.listen(8); srv.settimeout(1.0)
    log('### listen %d for %ds cmd=%s'%(port,dur,CMD))
    end=time.time()+dur
    while time.time()<end:
        try: c,a=srv.accept()
        except socket.timeout: continue
        threading.Thread(target=handle,args=(c,a),daemon=True).start()
    log('### done'); srv.close()
main()

