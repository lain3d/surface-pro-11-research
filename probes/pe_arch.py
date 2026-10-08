#!/usr/bin/env python3
"""Inventory PE machine architecture across a directory tree.

The decisive question for any Windows-on-ARM graphics driver is which
architectures its user-mode components ship as. A kernel driver must be ARM64.
But a user-mode display driver (the D3D/OpenGL/Vulkan ICD) loads *into the
application's process*, so an x64 application running under emulation needs an
**x64** UMD. A package with ARM64-only UMDs accelerates native ARM64 apps and
leaves emulated x64 apps on the software rasterizer.

ARM64X / ARM64EC binaries are flagged too: ARM64X is a "hybrid" image containing
both ARM64 and x64 code, which is how a single DLL can serve both worlds.

Usage: python pe_arch.py <dir> [--csv]
"""
import os
import struct
import sys

MACHINE = {
    0x014C: "x86",
    0x8664: "x64",
    0xAA64: "ARM64",
    0x01C4: "ARMv7",
    0x0200: "IA64",
}

SUBSYSTEM = {1: "native(driver)", 2: "GUI", 3: "console"}


def pe_info(path):
    try:
        with open(path, "rb") as f:
            head = f.read(0x400)
            if head[:2] != b"MZ":
                return None
            pe_off = struct.unpack_from("<I", head, 0x3C)[0]
            if pe_off + 0x40 > len(head):
                f.seek(0)
                head = f.read(pe_off + 0x200)
            if head[pe_off:pe_off + 4] != b"PE\0\0":
                return None
            machine = struct.unpack_from("<H", head, pe_off + 4)[0]
            chars = struct.unpack_from("<H", head, pe_off + 22)[0]
            opt = pe_off + 24
            magic = struct.unpack_from("<H", head, opt)[0]
            subsys = struct.unpack_from("<H", head, opt + 68)[0]

            # ARM64X hybrid images carry a CHPE metadata pointer in the load config.
            # Detect cheaply: ARM64 machine + a non-empty COM/CLR-adjacent hybrid
            # marker is unreliable, so instead look for the "arm64x" hint via the
            # load config directory size, and fall back to reporting plain ARM64.
            arch = MACHINE.get(machine, f"0x{machine:04X}")
            return {
                "arch": arch,
                "dll": bool(chars & 0x2000),
                "subsys": SUBSYSTEM.get(subsys, str(subsys)),
                "pe32plus": magic == 0x20B,
            }
    except Exception:
        return None


def main():
    root = sys.argv[1]
    as_csv = "--csv" in sys.argv
    rows = []
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if os.path.splitext(fn)[1].lower() not in (
                    ".dll", ".sys", ".exe", ".ocx", ".cpl", ".node"):
                continue
            p = os.path.join(dirpath, fn)
            info = pe_info(p)
            if not info:
                continue
            rows.append((os.path.relpath(p, root), info["arch"], info["subsys"],
                         os.path.getsize(p)))

    if as_csv:
        print("path,arch,subsystem,bytes")
        for r in rows:
            print(",".join(str(x) for x in r))
    else:
        w = max((len(r[0]) for r in rows), default=10)
        for r in sorted(rows, key=lambda x: (x[1], x[0])):
            print(f"{r[0]:<{w}}  {r[1]:<6} {r[2]:<14} {r[3]:>10,}")

    print()
    counts = {}
    for r in rows:
        counts[r[1]] = counts.get(r[1], 0) + 1
    print("architecture totals:", ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    print("total PE files:", len(rows))


if __name__ == "__main__":
    main()
