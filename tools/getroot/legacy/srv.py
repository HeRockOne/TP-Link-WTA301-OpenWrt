# ============================================================================
# 旧版组件 —— 已被 ../../rawtcp_gw.py 取代，保留只为对上既有文档的引用。
# 注意：getroot.py 走「给本机加 <网关IP>/32 别名」的老路，单网卡拓扑下会断网。
# ============================================================================

import argparse
import http.server
import os
import socketserver
import sys

ap = argparse.ArgumentParser()
ap.add_argument('--root', default=None,
                help='要服务的根目录（默认 = 本文件所在目录）')
ap.add_argument('--port', type=int, default=int(os.environ.get('SRV_PORT', '8099')))
a = ap.parse_args()

ROOT = os.path.abspath(a.root) if a.root else os.path.dirname(os.path.abspath(__file__))
os.chdir(ROOT)
sys.stderr.write('ROOT=%s PORT=%d\n' % (ROOT, a.port))
sys.stderr.flush()


class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        sys.stderr.write('REQ %s from %s\n' % (self.path, self.client_address))
        sys.stderr.flush()
        return super().do_GET()

    def log_message(self, *a):
        pass


socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('0.0.0.0', a.port), H).serve_forever()

