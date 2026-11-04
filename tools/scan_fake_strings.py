import re, sys

BS = chr(92)          # backslash
PATH = sys.argv[1] if len(sys.argv) > 1 else "wta301-2512/patches/s7-actual-dtb.dts"

STR_RE = re.compile(r'\s*([\w,.\-]+)\s*=\s*"((?:[^"' + BS + BS + r']|' + BS + BS + r'.)*)"\s*;')

def unescape(val):
    b = bytearray()
    j = 0
    n = len(val)
    while j < n:
        c = val[j]
        if c == BS and j + 1 < n:
            e = val[j + 1]
            if e == '0':
                b.append(0); j += 2
            elif e == 'x':
                b.append(int(val[j + 2:j + 4], 16)); j += 4
            elif e == 'n':
                b.append(10); j += 2
            elif e == 't':
                b.append(9); j += 2
            elif e == 'a':
                b.append(7); j += 2
            else:
                b.append(ord(e) & 0xff); j += 2
        else:
            b.append(ord(c) & 0xff); j += 1
    return bytes(b)

lines = open(PATH, encoding="utf-8", errors="replace").read().split("\n")
hits = []
for i, l in enumerate(lines, 1):
    m = STR_RE.match(l)
    if not m:
        continue
    name, val = m.group(1), m.group(2)
    b = unescape(val)
    if len(b) == 4 and b[2:] == b"\x00\x00" and 0x20 <= b[0] < 0x7f and 0x20 <= b[1] < 0x7f:
        v = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]
        hits.append((i, name, val, v))

print("=== %d 个被 dtc 渲染成字符串、实为大端 u32 的属性 ===" % len(hits))
for i, name, val, v in hits:
    print("  L%-5d %-40s \"%-6s\" -> 0x%08X" % (i, name, val, v))
