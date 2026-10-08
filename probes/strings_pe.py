#!/usr/bin/env python3
"""Extract ASCII + UTF-16LE strings and the PE import table from a driver.

Usage: python strings_pe.py <file.sys> [regex_filter]
"""
import re
import struct
import sys

path = sys.argv[1]
filt = re.compile(sys.argv[2], re.I) if len(sys.argv) > 2 else None
data = open(path, "rb").read()

def ascii_strings(b, n=4):
    for m in re.finditer(rb"[\x20-\x7e]{%d,}" % n, b):
        yield m.start(), m.group().decode("ascii")

def utf16_strings(b, n=4):
    for m in re.finditer(rb"(?:[\x20-\x7e]\x00){%d,}" % n, b):
        yield m.start(), m.group().decode("utf-16-le")

seen = set()
out = []
for off, s in list(ascii_strings(data)) + list(utf16_strings(data)):
    if s in seen:
        continue
    seen.add(s)
    if filt and not filt.search(s):
        continue
    out.append((off, s))

# ---- PE imports
def imports(b):
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    if b[pe:pe+4] != b"PE\0\0":
        return []
    nsec = struct.unpack_from("<H", b, pe + 6)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", b, opt)[0]
    dd = opt + (112 if magic == 0x20B else 96)
    imp_rva, imp_sz = struct.unpack_from("<II", b, dd + 8)
    if not imp_rva:
        return []
    sects = []
    so = opt + struct.unpack_from("<H", b, pe + 20)[0]
    for i in range(nsec):
        s = so + i * 40
        name = b[s:s+8].rstrip(b"\0").decode("ascii", "replace")
        vsz, va, rsz, ra = struct.unpack_from("<IIII", b, s + 8)
        sects.append((va, vsz, ra, rsz, name))
    def r2o(rva):
        for va, vsz, ra, rsz, _ in sects:
            if va <= rva < va + max(vsz, rsz):
                return ra + (rva - va)
        return None
    res = []
    off = r2o(imp_rva)
    while off:
        oft, tds, fwd, nrva, fthunk = struct.unpack_from("<IIIII", b, off)
        if not nrva:
            break
        no = r2o(nrva)
        dll = b[no:b.index(b"\0", no)].decode("ascii", "replace")
        funcs = []
        t = r2o(oft or fthunk)
        while t:
            ent = struct.unpack_from("<Q", b, t)[0]
            if not ent:
                break
            if not (ent >> 63):
                fo = r2o(ent & 0x7FFFFFFF)
                if fo:
                    funcs.append(b[fo+2:b.index(b"\0", fo+2)].decode("ascii", "replace"))
            t += 8
        res.append((dll, funcs))
        off += 20
    return res

print(f"=== {path} ===\n")
print(f"--- strings ({len(out)}) ---")
for off, s in out:
    print(f"  0x{off:06X}  {s}")

print("\n--- imports ---")
for dll, funcs in imports(data):
    print(f"  {dll}  ({len(funcs)})")
    for f in funcs:
        if not filt or filt.search(f):
            print(f"      {f}")
