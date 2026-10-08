#!/usr/bin/env python3
"""Resolve the per-entry `slaveAddr` record in a Chromatix register table.

`sensorSlaveAddress` is stored with length 0 in every blob -- the field exists
in the schema and holds nothing. That was taken to mean the I2C address is
absent from the blobs entirely, and the driver work proceeded on the assumption
that it needs an `i2cdetect` on a booted kernel to recover.

But the 40-byte register entries carry a *second* reference to a slave address:
slot 2 is a record id, and that record has its own data offset. Nobody followed
that indirection. This does.

The OV13858 blob is the control: that sensor's address is public (0x36 7-bit,
0x6c write / 0x6d read 8-bit). If slot 2 resolves to one of those, the decode is
confirmed and the same lookup on the IMX681 blob yields the front sensor's
address -- one of the values otherwise gated behind booting.

Usage: python chromatix_slaveaddr.py BLOB [BLOB ...]
"""
import collections
import struct
import sys

sys.path.insert(0, __file__.rsplit("\\", 1)[0] if "\\" in __file__ else ".")
from chromatix_parse import records, find_data_base

ENTRY = 0x28
SLOT_SLAVE_ID = 2


def report(path):
    buf = open(path, "rb").read()
    base = find_data_base(buf, list(records(buf)))
    if base is None:
        print(f"{path}: could not locate the data section")
        return
    recs = list(records(buf, end=base))
    by_id = {r[5]: r for r in recs}

    print(f"=== {path} ===")

    # Every record whose name mentions a slave address, whatever its length.
    print("  records matching /slave|addr/:")
    for off, name, marker, doff, dlen, rid in recs:
        if "slave" in name.lower() or "addr" in name.lower():
            raw = buf[base + doff: base + doff + dlen] if dlen else b""
            val = int.from_bytes(raw, "little") if 0 < dlen <= 8 else None
            shown = f"0x{val:x} ({val})" if val is not None else (
                raw.hex(" ") if raw else "<empty>")
            print(f"    {name:<26} id=0x{rid:<5x} off=0x{doff:<6x} "
                  f"len={dlen:<3} {shown}")

    # Now the per-entry slot 2, resolved.
    seen = collections.Counter()
    for off, name, marker, doff, dlen, rid in recs:
        if name != "regSetting" or dlen < ENTRY:
            continue
        region = base + doff
        end = min(region + dlen, len(buf))
        for skew in range(0, ENTRY, 4):
            start = region + skew
            ok = 0
            for k in range((end - start) // ENTRY):
                s = struct.unpack_from("<10I", buf, start + k * ENTRY)
                if s[1] == 1 and s[3] == 2 and s[4] == 1 and s[6] == 1:
                    ok += 1
                else:
                    break
            if ok:
                for k in range(ok):
                    s = struct.unpack_from("<10I", buf, start + k * ENTRY)
                    seen[s[SLOT_SLAVE_ID]] += 1
                break

    print("  slot-2 record ids referenced by register entries:")
    for rid, n in seen.most_common():
        rec = by_id.get(rid)
        if not rec:
            print(f"    id=0x{rid:<5x} x{n:<5} <no such record>")
            continue
        _, name, _, doff, dlen, _ = rec
        raw = buf[base + doff: base + doff + dlen] if dlen else b""
        val = int.from_bytes(raw, "little") if 0 < dlen <= 8 else None
        shown = f"0x{val:x} ({val})" if val is not None else (
            raw.hex(" ") if raw else "<empty>")
        print(f"    id=0x{rid:<5x} x{n:<5} {name:<24} len={dlen:<3} {shown}")
    print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for p in sys.argv[1:]:
        report(p)
