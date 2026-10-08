#!/usr/bin/env python3
"""Dump a PE's export table.

`strings_pe.py` covers strings and imports; this covers the other direction.
For a plug-in DLL the exports are usually the fastest way in, because they are
the contract with the host and are often left with C++ mangled names even when
everything else is stripped. That was exactly the case for
`TouchPenProcessor0C83.dll`, where the export table named the entire HEAT
processor interface after telemetry strings had led nowhere.

Two offsets are easy to get wrong and both produce confident nonsense rather
than an error, so they are called out here:

  - data directories start at optional-header offset 0x60 for PE32 and
    **0x70** for PE32+, not 0x80
  - IMAGE_EXPORT_DIRECTORY has **eleven** fields; unpacking ten silently
    shifts everything after MinorVersion

Usage: python pe_exports.py FILE.dll
"""
import struct
import sys


def exports(path):
    buf = open(path, "rb").read()
    pe = struct.unpack_from("<I", buf, 0x3c)[0]
    if buf[pe:pe + 4] != b"PE\0\0":
        raise SystemExit("not a PE file")

    magic = struct.unpack_from("<H", buf, pe + 0x18)[0]
    dd = pe + 0x18 + (0x60 if magic == 0x10b else 0x70)
    exp_rva, _exp_sz = struct.unpack_from("<II", buf, dd)
    if not exp_rva:
        return path, None, []

    nsec = struct.unpack_from("<H", buf, pe + 6)[0]
    opthdr = struct.unpack_from("<H", buf, pe + 0x14)[0]
    secbase = pe + 0x18 + opthdr
    secs = []
    for i in range(nsec):
        o = secbase + i * 40
        vsz, va, rsz, raw = struct.unpack_from("<IIII", buf, o + 8)
        secs.append((va, max(vsz, rsz), raw))

    def off(rva):
        for va, size, raw in secs:
            if va <= rva < va + size:
                return raw + (rva - va)
        return None

    (_c, _t, _maj, _min, name_rva, base, _naddr, nnames,
     addr_rva, names_rva, ords_rva) = struct.unpack_from("<IIHHIIIIIII", buf,
                                                         off(exp_rva))
    dll = buf[off(name_rva):].split(b"\0")[0].decode("ascii", "replace")

    out = []
    for i in range(nnames):
        nr = struct.unpack_from("<I", buf, off(names_rva) + i * 4)[0]
        nm = buf[off(nr):].split(b"\0")[0].decode("ascii", "replace")
        ordi = struct.unpack_from("<H", buf, off(ords_rva) + i * 2)[0]
        fn = struct.unpack_from("<I", buf, off(addr_rva) + ordi * 4)[0]
        out.append((base + ordi, fn, nm))
    return path, dll, sorted(out)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for p in sys.argv[1:]:
        path, dll, exp = exports(p)
        print(f"=== {path} ===")
        if dll is None:
            print("  no export table\n")
            continue
        print(f"  {dll}: {len(exp)} named exports\n")
        for ordinal, rva, name in exp:
            print(f"  {ordinal:>4}  rva=0x{rva:08x}  {name}")
        print()
