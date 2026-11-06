# 抓并发失败时的控制台输出：区分「malloc 失败」还是「LZMA 坏流」
import socket, urllib.request, threading, time, json

def drain(s, t):
    out = b''; end = time.time() + t; s.settimeout(0.3)
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d: break
            out += d
        except socket.timeout: pass
        except OSError: break
    return out

tel = socket.create_connection(('192.168.1.1', 23), 8)
drain(tel, 1.0)
tel.sendall(b'\r')
drain(tel, 1.0)

N = 6
res = [None]*N
def one(i):
    try:
        r = urllib.request.urlopen('http://192.168.1.1/sysinfo/tplink', timeout=60)
        res[i] = json.loads(r.read().decode())
    except Exception as e:
        res[i] = {'err': str(e)}

ts = [threading.Thread(target=one, args=(i,)) for i in range(N)]
for t in ts: t.start()
for t in ts: t.join()

ok = 0
for i, d in enumerate(res):
    if d and 'slots' in d:
        dec = [x['decode_ok'] for x in d['slots']]
        if all(dec): ok += 1
        print(i, dec)
    else:
        print(i, 'ERR', (d or {}).get('err'))

print('\n成功 %d/%d' % (ok, N))
print('--- 控制台输出（关键：失败原因）---')
print(drain(tel, 5).decode('utf-8', 'replace'))
tel.close()
