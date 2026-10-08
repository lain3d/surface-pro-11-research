#!/usr/bin/env python3
"""Parse the QTI Chromatix sensor-module blobs shipped with the Surface camera
drivers (`com.surface.sensormodule.*.bin`).

These hold what the `CAM*_RES_MSHW*.bin` power blobs do not: the sensor's I2C
slave address, its CCI/I2C bus, the MIPI lane assignment and the CSI link
configuration. Found in the Windows driver store beside the resource blobs.

Layout, recovered by inspection rather than from the parser binary:

    0x00  "QTI Chromatix Header", padding, size, then
          "Parameter Parser V3.4.0 (...)" and the module name
    0xd0  a flat table of fixed 56-byte records:

          +0x00  char name[40]      NUL-padded
          +0x28  u32 0xffffffff     constant
          +0x2c  u32 offset         cumulative offset into the data section
          +0x30  u32 length         size of this field's data, in bytes
          +0x34  u32 id             mostly sequential

    then a data section, which every record's `offset` indexes.

`length` is a byte count, not a value. That was established by predicting it:
`sensorName` is 7 in the imx681 blob and 8 in the ov13858 and ov02c10 blobs,
i.e. exactly `len(name) + 1`. A field with `length == 0` is simply not stored,
which is the case for `sensorSlaveAddress` in all three blobs.

The data section's base is not in the header, so it is recovered by locating
the sensor-name string and subtracting that record's offset.

Usage: python chromatix_parse.py BLOB [name-substring ...]
"""
import struct
import sys

REC = 0x38
TABLE_START = 0xd0


def records(buf, end=None):
    """Walk the record table. `end` bounds it -- without one the walk runs off
    into the data section and decodes it as nonsense records (a length of
    1732277888 is the giveaway)."""
    limit = len(buf) if end is None else min(end, len(buf))
    off = TABLE_START
    while off + REC <= limit:
        raw = buf[off:off + REC]
        name = raw[:0x28].split(b"\x00")[0].decode("ascii", "replace")
        marker, rtype, value, rid = struct.unpack_from("<IIII", raw, 0x28)
        if name:
            yield off, name, marker, rtype, value, rid
        off += REC


def find_data_base(buf, recs):
    """Pin the data section using a string whose value is known in advance.

    The module name near the top of the file ("com.surface.sensormodule.
    ffc_imx681") ends in the part number, and that same part number is the
    `sensorName` field's data. So search for that exact string and subtract the
    record's offset. Matching on "some plausible string" instead picks the
    wrong base -- it lands on whatever unrelated token happens to sit at the
    right distance.
    """
    i = buf.find(b"com.surface.sensormodule.")
    if i < 0:
        i = buf.find(b"com.qti.sensormodule.")
    if i < 0:
        return None
    module = buf[i:buf.index(b"\x00", i)].decode()
    expect = module.rsplit("_", 1)[-1].encode() + b"\x00"

    for _, name, _, doff, dlen, _ in recs:
        if name != "sensorName" or dlen != len(expect):
            continue
        pos = 0
        while True:
            j = buf.find(expect, pos)
            if j < 0:
                break
            cand = j - doff
            if cand >= 0 and buf[cand + doff: cand + doff + dlen] == expect:
                return cand
            pos = j + 1
    return None


def decode(blob):
    if not blob:
        return "-"
    if blob.endswith(b"\x00") and all(32 <= c < 127 for c in blob[:-1]):
        return repr(blob[:-1].decode())
    if len(blob) in (1, 2, 4, 8):
        v = int.from_bytes(blob, "little")
        return f"0x{v:x} ({v})"
    return blob.hex(" ")


def main(argv):
    buf = open(argv[0], "rb").read()
    wanted = [w.lower() for w in argv[1:]]
    # First pass finds the data section, which is also where the table stops;
    # the second pass is bounded by it.
    base = find_data_base(buf, list(records(buf)))
    recs = list(records(buf, end=base))
    print(f"{len(recs)} records; data section base "
          f"{'0x%x' % base if base is not None else 'NOT FOUND'}\n")
    shown = 0
    for off, name, marker, doff, dlen, rid in recs:
        if wanted and not any(w in name.lower() for w in wanted):
            continue
        shown += 1
        data = ""
        if base is not None and dlen:
            data = decode(buf[base + doff: base + doff + dlen])
        flag = "" if marker == 0xffffffff else f"  marker=0x{marker:x}"
        print(f"0x{off:06x}  {name:<34} off=0x{doff:<6x} len={dlen:<4} "
              f"id=0x{rid:<5x} {data}{flag}")
    print(f"\n{len(recs)} records, {shown} shown")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
