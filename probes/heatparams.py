#!/usr/bin/env python3
"""Decode the HEAT CurrentParams blob from the registry."""
import struct
import sys

raw = bytes(int(x) for x in open(sys.argv[1]).read().split())
print(f"{len(raw)} bytes\n")
print("hex:")
for off in range(0, len(raw), 16):
    print(f"  {off:03x}  {raw[off:off+16].hex(' ')}")
print()

print("as u32 / float pairs:")
for off in range(0, len(raw) - 3, 4):
    (u,) = struct.unpack_from("<I", raw, off)
    (f,) = struct.unpack_from("<f", raw, off)
    fs = f"{f:.4g}" if 1e-6 < abs(f) < 1e9 else ""
    note = ""
    if u in (46, 68):
        note = "   <-- projection length"
    if u == 46 * 68:
        note = "   <-- 46*68 cells"
    print(f"  +{off:03x}  u32={u:<12} f32={fs:<12}{note}")
