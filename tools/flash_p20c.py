# -*- coding: utf-8 -*-
"""flash_p20c.py — 用「修好后的前端行为」刷 u-boot 槽镜像。

与修复后的 index.html 完全一致的两步：
  /upload   multipart（含 uboot 文件 + slot 字段）   ← 这里决定 tpimg_uboot_target
  /result   **空 body、不设 Content-Type**           ← 修复点：不触发 httpd.c:549

不再使用 application/x-www-form-urlencoded，也不再发 "slot=0" 字符串 body。

用法: python flash_p20c.py <槽镜像路径>
"""
import http.client
import sys
import uuid


BOARD = '192.168.1.1'
SLOT = '0'          # 0 = 两槽都写


def post(path, body, ctype=None, timeout=600):
    hdrs = {'Content-Length': str(len(body)), 'Connection': 'close'}
    if ctype:
        hdrs['Content-Type'] = ctype
    c = http.client.HTTPConnection(BOARD, 80, timeout=timeout)
    c.request('POST', path, body=body, headers=hdrs)
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, dict(r.getheaders()), data


def show(tag, status, hdrs, data):
    print('==== %s ====' % tag)
    print('  status :', status)
    print('  ctype  :', hdrs.get('Content-Type'))
    print('  bytes  :', len(data))
    txt = data.decode('utf-8', 'replace')
    print('  raw    :', txt[:500])
    print()
    return txt


def main():
    path = sys.argv[1]
    with open(path, 'rb') as f:
        blob = f.read()
    print('file :', path, len(blob), 'bytes')

    bnd = '----wta301' + uuid.uuid4().hex
    name = path.replace('\\', '/').split('/')[-1]
    body = b''.join([
        ('--%s\r\n' % bnd).encode(),
        ('Content-Disposition: form-data; name="uboot"; filename="%s"\r\n'
         % name).encode(),
        b'Content-Type: application/octet-stream\r\n\r\n',
        blob, b'\r\n',
        ('--%s\r\n' % bnd).encode(),
        b'Content-Disposition: form-data; name="slot"\r\n\r\n',
        SLOT.encode(), b'\r\n',
        ('--%s--\r\n' % bnd).encode(),
    ])
    s, h, d = post('/upload', body, 'multipart/form-data; boundary=' + bnd)
    t = show('/upload', s, h, d)
    if '"success"' not in t:
        print('STOP: /upload 未通过校验，不写 flash。')
        return 2

    # 空 body + 无 Content-Type：这正是修复后的 index.html 发的请求
    s, h, d = post('/result', b'')
    t = show('/result (empty body)', s, h, d)
    if '"success"' in t:
        print('OK: 写入成功。')
        return 0
    print('FAIL: 写入未成功。')
    return 3


sys.exit(main())
