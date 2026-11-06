# 只做 /upload（传内存+校验，不动 flash）。看官方包能不能过解析。
import urllib.request, uuid, json, sys, hashlib, time
HOST='http://192.168.1.1'
PATH=r'C:\Users\null\Desktop\flash-by-huamn\fw_202.bin'
data=open(PATH,'rb').read()
print('file %s  %d B  md5 %s' % (PATH, len(data), hashlib.md5(data).hexdigest()))
bd='----WTA301'+uuid.uuid4().hex
pre=('--%s\r\nContent-Disposition: form-data; name="firmware"; filename="fw_202.bin"\r\n'
     'Content-Type: application/octet-stream\r\n\r\n' % bd).encode()
post=('\r\n--%s--\r\n' % bd).encode()
body=pre+data+post
req=urllib.request.Request(HOST+'/upload', data=body, method='POST')
req.add_header('Content-Type','multipart/form-data; boundary='+bd)
t0=time.time()
try:
    r=urllib.request.urlopen(req, timeout=180)
    print('UPLOAD %d  %.1fs' % (r.status, time.time()-t0))
    print('  ', r.read().decode()[:600])
except Exception as e:
    print('UPLOAD FAIL', type(e).__name__, e)
    try: print('  ', e.read().decode()[:600])
    except Exception: pass
