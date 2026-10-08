#!/usr/bin/env python3
"""Extract sensor register-write tables from a QTI Chromatix sensor-module blob.

Companion to `chromatix_parse.py`, which decodes the record table. This decodes
the *register programming* those records describe, which is what a Linux sensor
driver needs as its `reg_sequence` arrays.

## Where the addresses live

An earlier pass concluded the blob held register data but no addresses. That was
wrong, and the mistake is worth recording: the per-field records
(`slaveAddr` / `registerData` / `delayUs`) are the *schema*, and their data
offsets hold values only. The register **addresses** are in the data section, in
a flat array of 40-byte entries that the `regSetting` record points at.

Each entry is ten little-endian u32:

    slot 0   register address
    slot 1   1                (constant)
    slot 2   record id of this entry's `slaveAddr`
    slot 3   2                (constant)
    slot 4   1
    slot 5   0
    slot 6   1
    slot 7   record id of this entry's `registerData`  <- the value lives there
    slot 8   0
    slot 9   record id of this entry's `delayUs`

So the address is inline and the value is one indirection away, through the
record table. Values are deduplicated, which is why far fewer distinct data
offsets exist than there are writes.

## How that was established

Known-plaintext. Mainline `drivers/media/i2c/ov13858.c` carries the real
register tables for the OV13858, which is this machine's rear sensor, so the
address sequence had to appear in `com.surface.sensormodule.rfc_ov13858.bin` if
it was stored at all. It does, at a 40-byte stride, and decoding through the
above layout reproduces mainline's values 15/16 -- the exception being a
register where the Surface tuning legitimately differs.

Usage: python chromatix_regs.py BLOB [--limit N]
"""
import struct
import sys

sys.path.insert(0, __file__.rsplit("\\", 1)[0] if "\\" in __file__ else ".")
from chromatix_parse import records, find_data_base

ENTRY = 0x28
SLOT_ADDR, SLOT_DATA_ID, SLOT_DELAY_ID = 0, 7, 9


def extract(path):
    buf = open(path, "rb").read()
    base = find_data_base(buf, list(records(buf)))
    if base is None:
        raise SystemExit("could not locate the data section")
    recs = list(records(buf, end=base))
    by_id = {r[5]: r for r in recs}

    def value_of(rid):
        rec = by_id.get(rid)
        if not rec or not rec[4]:
            return None
        return int.from_bytes(buf[base + rec[3]: base + rec[3] + rec[4]], "little")

    def aligned_at(start, limit):
        """Entries carry constants in slots 1/3/4/6; use them to find the
        array's alignment instead of assuming it begins at the record offset.
        Different blobs prefix the array differently."""
        n = 0
        for k in range((limit - start) // ENTRY):
            s = struct.unpack_from("<10I", buf, start + k * ENTRY)
            if s[1] == 1 and s[3] == 2 and s[4] == 1 and s[6] == 1:
                n += 1
            else:
                break
        return n

    tables = []
    for off, name, marker, doff, dlen, rid in recs:
        if name != "regSetting" or dlen < ENTRY:
            continue
        region = base + doff
        end = min(region + dlen, len(buf))
        best = max(range(0, ENTRY, 4),
                   key=lambda skew: aligned_at(region + skew, end))
        count = aligned_at(region + best, end)

        # A single-entry array cannot be found this way, and seven of them were
        # silently dropped for months: the search needs ENTRY bytes *after* the
        # skew to test the constants, so in a 40-byte region every skew above 0
        # has nothing to look at, and skew 0 fails whenever the entry does not
        # start at the very beginning. In this blob those seven carry the
        # signature two words in, so the entry runs 8 bytes past the declared
        # length -- dlen understates it.
        #
        # They are not filler. They are 0x0100 = 1 / 0 (stream on and off) and
        # 0x0104 = 1 / 0 (grouped parameter hold), i.e. exactly the sequences
        # whose absence had been written up as "the blob never writes 0x0100,
        # the Windows stack does that itself".
        #
        # So when the bounded search finds nothing, retry against the buffer
        # rather than against dlen. Still requires the full constant signature,
        # so this loosens where we look and not what counts as a match.
        relaxed = False
        if not count:
            loose = min(region + dlen + ENTRY, len(buf))
            best = max(range(0, ENTRY, 4),
                       key=lambda skew: aligned_at(region + skew, loose))
            count = aligned_at(region + best, loose)
            end = loose
            relaxed = True
        if not count:
            continue
        entries = []
        for k in range(count):
            slots = struct.unpack_from("<10I", buf, region + best + k * ENTRY)
            data = value_of(slots[SLOT_DATA_ID])
            if data is None:
                continue
            if relaxed:
                # The entry overruns the declared length, so the delay id sits
                # outside the record and reading it yields whatever follows --
                # which printed as a 90-digit "delay" the first time round. A
                # wrong number is worse than no number: report 0.
                #
                # Two sanity checks, because loosening the search also admits
                # false positives: a real write here is one byte, and address 0
                # is not a register any table uses. Without these, a spurious
                # {0x0000, 0x1762} appeared.
                if data > 0xff or slots[SLOT_ADDR] == 0:
                    continue
                entries.append((slots[SLOT_ADDR], data, 0))
            else:
                entries.append((slots[SLOT_ADDR], data,
                                value_of(slots[SLOT_DELAY_ID]) or 0))
        if entries:
            tables.append((doff + best, dlen, entries))
    return tables


def main(argv):
    path = argv[0]
    limit = 12
    if "--limit" in argv:
        limit = int(argv[argv.index("--limit") + 1])

    tables = extract(path)
    total = sum(len(t[2]) for t in tables)
    print(f"{path}\n{len(tables)} register tables, {total} writes\n")
    for doff, dlen, entries in sorted(tables, key=lambda t: -len(t[2])):
        print(f"--- table at data+0x{doff:x}: {len(entries)} writes ({dlen} bytes) ---")
        for addr, data, delay in entries[:limit]:
            extra = f"   delay {delay}us" if delay else ""
            print(f"    {{0x{addr:04x}, 0x{data:02x}}},{extra}")
        if len(entries) > limit:
            print(f"    ... {len(entries) - limit} more")
        print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
