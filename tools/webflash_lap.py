# 在笔记本上把槽镜像推进板子（u-boot httpd）。
# ★ /result 必须空 body 且不设 Content-Type（net/httpd.c:549 会 400）。
import urllib.request, uuid, json, sys, time, hashlib, os

HOST = 'http://192.168.1.1'
PATH = sys.argv[1] if len(sys.argv) > 1 else r'C:\Users\null\Desktop\flash-by-huamn\uboot_p21b_slot.bin'
SLOT = sys.argv[2] if len(sys.argv) > 2 else '0'   # 0=两槽 1=image_1 2=image_2

data = open(PATH, 'rb').read()
print('file %s  %d B  md5 %s' % (PATH, len(data), hashlib.md5(data).hexdigest()))
print('target slot =', SLOT, '(0=两槽 1=image_1 2=image_2)')

b = uuid.uuid4().hex
body = []
def fld(name, val):
    body.append(('--' + b + '\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (name, val)).encode())
def fil(name, fn, content):
    body.append(('--' + b + '\r\nContent-Disposition: form-data; name="%s"; filename="%s"\r\n'
                 'Content-Type: application/octet-stream\r\n\r\n' % (name, fn)).encode())
    body.append(content)
    body.append(b'\r\n')

fld('slot', SLOT)
fil('uboot', os.path.basename(PATH), data)
body.append(('--' + b + '--\r\n').encode())
payload = b''.join(body)

req = urllib.request.Request(HOST + '/upload', data=payload,
    headers={'Content-Type': 'multipart/form-data; boundary=' + b})
t0 = time.time()
r = urllib.request.urlopen(req, timeout=180)
resp = r.read().decode('utf-8', 'replace')
print('UPLOAD  %s  %.1fs' % (r.status, time.time() - t0))
print('  ', resp)
try:
    j = json.loads(resp)
except Exception:
    print('!! 响应不是 JSON，停止'); sys.exit(1)
if j.get('status') != 'success':
    print('!! 校验没过，不写 flash'); sys.exit(1)

print('--- POST /result (空 body) ---')
req2 = urllib.request.Request(HOST + '/result', data=None, method='POST')
t0 = time.time()
r2 = urllib.request.urlopen(req2, timeout=300)
resp2 = r2.read().decode('utf-8', 'replace')
print('RESULT  %s  %.1fs' % (r2.status, time.time() - t0))
print('  ', resp2)
