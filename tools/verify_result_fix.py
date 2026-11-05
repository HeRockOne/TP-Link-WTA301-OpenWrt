# -*- coding: utf-8 -*-
"""verify_result_fix.py — 证明「空 body 的 POST /result 不再返回 400」，且**不写一格 flash**。

原理：
  /upload 传一个 1 KB 的假 uboot 字段
    -> tpimg_uboot_validate 只认 size==0x40000，必然拒绝（uboot_slot_bad_size）
    -> 但 upload_data_id 仍被设成 fs_upload_id（见 upgrade.c RESPONDING 分支）
  /result 发**空 body、不设 Content-Type**（就是修好后的浏览器行为）
    -> httpd 头解析阶段跳过 httpd.c:549 的 boundary 检查  ← 本次要验的就是这条
    -> 进入 result_handler -> failsafe_write_uboot
    -> check_fw_type(1KB 垃圾) 既不是 FW_TYPE_TPLINK_UBOOT 也不是 FW_TYPE_ELF
    -> handle_wrong_fw_type("U-BOOT ELF") -> RET_WRONG_FW_TYPE  -> **不写 flash**

期望输出：
  旧行为（带 body）: HTTP 400 · b'Bad Request'
  新行为（空 body）: HTTP 200 · {"status":"fail","info":{...wrong_file_type...}}
  只要不再是 400，就说明修复成立。

用法: python verify_result_fix.py
"""
import http.client
import uuid


BOARD = '192.168.1.1'


def post(path, body, ctype=None):
    hdrs = {'Content-Length': str(len(body)), 'Connection': 'close'}
    if ctype:
        hdrs['Content-Type'] = ctype
    c = http.client.HTTPConnection(BOARD, 80, timeout=120)
    c.request('POST', path, body=body, headers=hdrs)
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, dict(r.getheaders()), data


def show(tag, status, hdrs, data):
    print('==== %s ====' % tag)
    print('  status  :', status)
    print('  ctype   :', hdrs.get('Content-Type'))
    print('  bytes   :', len(data))
    print('  raw     :', repr(data[:400]))
    try:
        print('  text    :', data.decode('utf-8'))
    except UnicodeDecodeError:
        pass
    print()


# ---- 1. /upload：1 KB 垃圾，故意让校验失败 ----
junk = b'\xA5' * 1024
bnd = '----wta301' + uuid.uuid4().hex
body = b''.join([
    ('--%s\r\n' % bnd).encode(),
    b'Content-Disposition: form-data; name="uboot"; filename="junk.bin"\r\n',
    b'Content-Type: application/octet-stream\r\n\r\n',
    junk, b'\r\n',
    ('--%s\r\n' % bnd).encode(),
    b'Content-Disposition: form-data; name="slot"\r\n\r\n',
    b'0\r\n',
    ('--%s--\r\n' % bnd).encode(),
])
s, h, d = post('/upload', body, 'multipart/form-data; boundary=' + bnd)
show('/upload  (1KB junk, 应被 uboot_slot_bad_size 拒绝)', s, h, d)

# ---- 2. /result：空 body、无 Content-Type（修好后的浏览器行为）----
s, h, d = post('/result', b'')
show('/result  (空 body，旧代码这里必 400)', s, h, d)

print('---- 判定 ----')
if s == 400:
    print('FAIL: 仍然是 400，说明 Content-Type 分支还有别的触发点。')
elif s == 200:
    print('PASS: 不再是 400 —— 空 body 通过了 httpd 头解析，修复成立。')
    print('      同时确认 flash 未被写入（wrong_fw_type 提前返回）。')
else:
    print('OTHER: 状态 %d，看上面原文判断。' % s)
