#!/usr/bin/env python3
"""生成 fstools 补丁（mount_root.c 的 done() + factoryreset.c 的 main()）。

两处都是同一类缺陷：把 overlay 卷名写死成字面量 "rootfs_data"，
而我们的卷名是 wta301data（因为 libfstools/rootdisk.c:166 硬编码该名，
会把 mtdsplit 的 rootfs_data 分区抢走）。

用法（在 WSL 里跑）：
    python3 mk_fstools_patch.py <fstools_src_dir> <out.patch>
"""
import difflib
import os
import sys

HDR = """From: WTA301 migration <noreply@example.invalid>
Subject: [PATCH] fstools: honor fstools_overlay_name instead of a hardcoded volume name

`mount_root start`() reads `fstools_overlay_name` from /proc/cmdline to pick the
overlay volume, but the rest of fstools still looks up the hardcoded name
"rootfs_data".  On a board whose overlay volume is named differently (we use
"wta301data", because libfstools/rootdisk.c:166 matches that exact name and
would otherwise grab the mtdsplit `rootfs_data` partition), that mismatch is
silent and destructive:

1. mount_root.c done()   -> volume_find("rootfs_data") returns NULL, so it
   returns before fs_state_set("/overlay", FS_STATE_READY).  /overlay/.fs_state
   therefore stays absent, every subsequent boot takes the
   FS_STATE_UNKNOWN -> FS_STATE_PENDING path in mount_overlay() and calls
   overlay_delete(), i.e. it WIPES the overlay and reformats it.  Nothing the
   user changes survives a reboot.  dmesg shows it every boot:
       mount_root: overlay filesystem has not been fully initialized yet
       mount_root: switching to ubifs overlay

2. factoryreset.c main() -> volume_find("rootfs_data") returns NULL, so
   `factoryreset -y` (and the reset button) abort with
   "MTD partition 'rootfs_data' not found", i.e. factory reset never works.

Both are fixed by using the same lookup as `mount_root start`().

"""


def patch_one(name, old_text, new_text, note):
    d = difflib.unified_diff(
        old_text.splitlines(True), new_text.splitlines(True),
        fromfile='a/' + name, tofile='b/' + name, n=3)
    body = ''.join(d)
    return note + body


def main():
    src, out = sys.argv[1], sys.argv[2]

    # ---- 1. mount_root.c done() ----
    mr = open(os.path.join(src, 'mount_root.c')).read()
    old = (
        'static int\n'
        'done(int argc, char *argv[1])\n'
        '{\n'
        '\tstruct volume *v = volume_find("rootfs_data");\n'
        '\n'
        '\tif (!v)\n'
        '\t\treturn -1;\n'
    )
    new = (
        'static int\n'
        'done(int argc, char *argv[1])\n'
        '{\n'
        '\tchar dataparam[BUFLEN];\n'
        '\tchar *dataname = "rootfs_data";\n'
        '\tstruct volume *v;\n'
        '\n'
        '\tif (get_var_from_file("/proc/cmdline", "fstools_overlay_name", dataparam, sizeof(dataparam)))\n'
        '\t\tdataname = dataparam;\n'
        '\n'
        '\tv = volume_find(dataname);\n'
        '\n'
        '\tif (!v)\n'
        '\t\treturn -1;\n'
    )
    if old not in mr:
        sys.exit('mount_root.c: 未找到 done() 目标片段')
    p1 = patch_one('mount_root.c', mr, mr.replace(old, new, 1),
                   '* mount_root: `done` must honor fstools_overlay_name\n\n')

    # ---- 2. factoryreset.c main() ----
    fr = open(os.path.join(src, 'factoryreset.c')).read()
    old2 = (
        '\tv = volume_find("rootfs_data");\n'
        '\tif (!v) {\n'
        "\t\tULOG_ERR(\"MTD partition 'rootfs_data' not found\\n\");\n"
        '\t\treturn -1;\n'
        '\t}\n'
    )
    new2 = (
        '\t{\n'
        '\t\tchar dataparam[64];\n'
        '\t\tchar *dataname = "rootfs_data";\n'
        '\n'
        '\t\tif (get_var_from_file("/proc/cmdline", "fstools_overlay_name",\n'
        '\t\t\t\t      dataparam, sizeof(dataparam)))\n'
        '\t\t\tdataname = dataparam;\n'
        '\n'
        '\t\tv = volume_find(dataname);\n'
        '\t}\n'
        '\tif (!v) {\n'
        '\t\tULOG_ERR("overlay volume not found\\n");\n'
        '\t\treturn -1;\n'
        '\t}\n'
    )
    if old2 not in fr:
        sys.exit('factoryreset.c: 未找到 volume_find 目标片段')
    fr2 = fr.replace(old2, new2, 1)
    # get_var_from_file() 声明在 libfstools/common.h，factoryreset.c 没包含
    inc_old = '#include "libfstools/libfstools.h"\n'
    inc_new = '#include "libfstools/libfstools.h"\n#include "libfstools/common.h"\n'
    if inc_old not in fr2:
        sys.exit('factoryreset.c: 未找到 include 锚点')
    fr2 = fr2.replace(inc_old, inc_new, 1)
    p2 = patch_one('factoryreset.c', fr, fr2,
                   '* factoryreset: same fix, otherwise `factoryreset -y` aborts\n\n')

    open(out, 'w', newline='\n').write(HDR + p1 + '\n' + p2)
    print('wrote %s (%d bytes)' % (out, os.path.getsize(out)))


if __name__ == '__main__':
    main()
