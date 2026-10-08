#!/usr/bin/env python3
"""Distinguish ARM64EC / ARM64X hybrid images from genuine x64 images.

PE machine type alone cannot tell them apart: an ARM64EC image deliberately
reports machine type AMD64 so the x64 loader accepts it. The difference is the
CHPEMetadataPointer field in the Load Config Directory, which is non-zero only
for hybrid images.

This matters because it is the difference between an emulated x64 application
calling into *emulated* driver code, and calling into *native ARM64* code
wearing an x64 ABI.

Usage: python pe_hybrid.py <file.dll> [more.dll ...]
"""
import os
import struct
import sys

MACHINE = {0x014C: "x86", 0x8664: "x64", 0xAA64: "ARM64"}
# offsetof(IMAGE_LOAD_CONFIG_DIRECTORY64, CHPEMetadataPointer)
CHPE_OFF = 0xC8


def classify(path):
    with open(path, "rb") as f:
        b = f.read()
    if b[:2] != b"MZ":
        return None
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    if b[pe:pe + 4] != b"PE\0\0":
        return None
    machine = struct.unpack_from("<H", b, pe + 4)[0]
    nsec = struct.unpack_from("<H", b, pe + 6)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", b, opt)[0]
    if magic != 0x20B:
        return {"machine": MACHINE.get(machine, hex(machine)), "hybrid": False,
                "note": "PE32 (32-bit)"}

    # section table -> RVA to file offset
    sects = []
    so = opt + struct.unpack_from("<H", b, pe + 20)[0]
    for i in range(nsec):
        s = so + i * 40
        vsz, va, rsz, ra = struct.unpack_from("<IIII", b, s + 8)
        sects.append((va, max(vsz, rsz), ra))

    def r2o(rva):
        for va, sz, ra in sects:
            if va <= rva < va + sz:
                return ra + (rva - va)
        return None

    # data directory 10 = Load Config
    dd = opt + 112
    lc_rva, lc_size = struct.unpack_from("<II", b, dd + 10 * 8)
    hybrid = False
    chpe = 0
    if lc_rva:
        off = r2o(lc_rva)
        if off:
            cfg_size = struct.unpack_from("<I", b, off)[0]
            if cfg_size > CHPE_OFF + 8 and off + CHPE_OFF + 8 <= len(b):
                chpe = struct.unpack_from("<Q", b, off + CHPE_OFF)[0]
                hybrid = chpe != 0

    m = MACHINE.get(machine, hex(machine))
    if hybrid and machine == 0x8664:
        kind = "ARM64EC (native ARM64, x64 ABI)"
    elif hybrid and machine == 0xAA64:
        kind = "ARM64X (hybrid ARM64 + ARM64EC)"
    elif machine == 0x8664:
        kind = "x64 (emulated on ARM)"
    elif machine == 0xAA64:
        kind = "ARM64 native"
    else:
        kind = m
    return {"machine": m, "hybrid": hybrid, "chpe": chpe, "kind": kind}


if __name__ == "__main__":
    files = sys.argv[1:]
    w = max(len(os.path.basename(f)) for f in files)
    for f in files:
        r = classify(f)
        if not r:
            print(f"{os.path.basename(f):<{w}}  not a PE")
            continue
        print(f"{os.path.basename(f):<{w}}  {r['machine']:<6} {r['kind']}")
