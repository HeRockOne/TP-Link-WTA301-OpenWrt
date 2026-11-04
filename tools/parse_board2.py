#!/usr/bin/env python3
"""解析 ath11k board-2.bin 容器，核对 variant 名 / BDF 大小 / 内容 md5。

用法: python tools/parse_board2.py <board-2.bin> [期望BDF文件]
"""
import sys, struct, hashlib

def parse(path):
    b = open(path, "rb").read()
    out = {"path": path, "size": len(b), "md5": hashlib.md5(b).hexdigest()}
    magic = b[:16]
    out["magic"] = magic
    if magic != b"QCA-ATH11K-BOARD":
        out["error"] = "magic mismatch: %r" % magic
        return out
    f10, f14 = struct.unpack(">II", b[0x10:0x18])
    length, f1c = struct.unpack(">II", b[0x18:0x20])
    out["hdr"] = {"0x10": f10, "0x14": f14, "0x18_len": length,
                  "0x1c": f1c, "len_check": length == len(b) - 0x1c}
    name_len = struct.unpack(">I", b[0x20:0x24])[0]
    out["name_len"] = name_len
    name = b[0x24:0x24 + name_len]
    out["name"] = name.decode("ascii", "replace")
    off = 0x24 + name_len
    off = (off + 3) & ~3
    out["pad_to"] = off
    count = struct.unpack(">I", b[off:off + 4])[0]
    off += 4
    out["count"] = count
    entries = []
    for i in range(count):
        size = struct.unpack(">I", b[off:off + 4])[0]
        off += 4
        data = b[off:off + size]
        off += size
        entries.append({"i": i, "size": size, "off": off - size,
                        "md5": hashlib.md5(data).hexdigest()})
    out["entries"] = entries
    out["tail_unused"] = len(b) - off
    return out

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    r = parse(sys.argv[1])
    print("== %s" % r["path"])
    print("   size   %d   md5 %s" % (r["size"], r["md5"]))
    if "error" in r:
        print("   ERROR %s" % r["error"])
        return 1
    print("   magic  %r" % r["magic"])
    print("   hdr    %s" % r["hdr"])
    print("   name   %r  (name_len=%d, pad->0x%x)" % (r["name"], r["name_len"], r["pad_to"]))
    print("   count  %d" % r["count"])
    for e in r["entries"]:
        print("     [%d] off=0x%x size=%d md5=%s" % (e["i"], e["off"], e["size"], e["md5"]))
    print("   tail   %d unused bytes" % r["tail_unused"])
    if len(sys.argv) > 2:
        import hashlib
        ref = open(sys.argv[2], "rb").read()
        print("   ref    %s size=%d md5=%s" % (sys.argv[2], len(ref),
                                               hashlib.md5(ref).hexdigest()))
        same = any(e["md5"] == hashlib.md5(ref).hexdigest() for e in r["entries"])
        print("   >>> BDF 内容与 ref 相同? %s" % same)
    return 0

if __name__ == "__main__":
    sys.exit(main())
