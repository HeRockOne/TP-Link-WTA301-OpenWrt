# P21b 验收：并发下 decode_ok 必须全部 true，且 md5 一栏有值
import urllib.request, threading, json, time
N = 6
res = [None]*N
def one(i):
    try:
        r = urllib.request.urlopen('http://192.168.1.1/sysinfo/tplink', timeout=90)
        res[i] = json.loads(r.read().decode())
    except Exception as e:
        res[i] = {'err': type(e).__name__ + ' ' + str(e)}
ts = [threading.Thread(target=one, args=(i,)) for i in range(N)]
t0 = time.time()
for t in ts: t.start()
for t in ts: t.join()

ok = 0
for i, d in enumerate(res):
    if d and 'slots' in d:
        dec = [x.get('decode_ok') for x in d['slots']]
        oom = [x.get('oom') for x in d['slots']]
        md5 = [x.get('md5') for x in d['slots']]
        good = all(dec) and not any(oom) and all(m and len(m) == 32 for m in md5)
        if good: ok += 1
        print('%d dec=%s oom=%s md5=%s %s' % (i, dec, oom, [ (m or '-')[:8] for m in md5], 'PASS' if good else 'FAIL'))
    else:
        print(i, 'ERR', (d or {}).get('err'))

print('\n==> 通过 %d/%d   耗时 %.1fs' % (ok, N, time.time()-t0))
print('全站一致 md5:', set(tuple(x.get('md5') for x in d['slots']) for d in res if d and 'slots' in d))
