#!/usr/bin/env python3
"""Decode the per-mode `resolutionData` array in a QTI Chromatix sensor-module
blob, and compare the same column across several sensors.

`probes/chromatix_parse.py` recovers the record table; the mode geometry and the
CSI link description live *inside* one record's data rather than as named
records, which is why searching the blob for `laneCount` or `is3Phase` finds
nothing. `resolutionData` is a flat array of **252-byte** per-mode structs.

The layout is not documented anywhere, so it is pinned empirically:

  * the stride is fixed by an ascending record-id column that advances by a
    constant per mode;
  * **column [20] is `laneCount`** -- it reads 1 / 2 / 4 for the IMX681,
    OV02C10 and OV13858 respectively, and the latter two are independently
    known (mainline `ov13858.c`; `laneAssign` 0x10 and 0x3210 in the same
    blobs; `x1-dell-thena.dtsi` wires the OV02C10 as `data-lanes = <1 2>`).
    Three parts agreeing is what makes the rest of the decode trustworthy;
  * **column [24] is `is3Phase`** -- CamX's D-PHY/C-PHY selector. See below.

`CamX::ImageSensorData::CreateCSIPHYConfig` in `QcDeviceMFT8380.dll` reads
`laneCount`, `settleTimeNS` and `is3Phase` out of the in-memory mode struct and
packs them into the 24-byte `CSIPHY info` payload the kernel driver logs as
`pCSIPhyInfo->laneCount / settleTimeNS / CSIPHY3Phase`. The in-memory struct is
584 bytes and laid out differently from this serialised one, so the column had
to be identified by signature rather than by offset:

    sensor                    laneCount  col[24]   PHY
    front IMX681 (this SKU)       1         1      <- the odd one out
    IR VD55G0                     1         0
    front OV02C10 (other SKU)     2         0      known D-PHY
    rear OV13858                  4         0      known D-PHY

The IR sensor is what makes this an identification rather than a guess: it is
*also* one lane and *also* the always-on/Windows-Hello part, so "1 lane" and
"always on" both fail to explain the column, while "C-PHY" still does.

Usage:  python chromatix_resdata.py BLOB [BLOB ...]
        python chromatix_resdata.py --columns BLOB [BLOB ...]   # full dump
"""
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STRIDE = 252
COL_LANE_COUNT = 20
COL_IS_3PHASE = 24


def _parse(path):
    """Run chromatix_parse.py and pull out the data base and resolutionData."""
    out = subprocess.run([sys.executable, os.path.join(HERE, "chromatix_parse.py"), path],
                         capture_output=True, text=True).stdout
    m = re.search(r"data section base 0x([0-9a-f]+)", out)
    base = int(m.group(1), 16) if m else None
    rec = re.search(r"resolutionData\s+off=0x([0-9a-f]+)\s+len=(\d+)", out)
    lane = re.search(r"laneAssign\s+off=0x[0-9a-f]+\s+len=\d+\s+id=0x[0-9a-f]+\s+(\S+)", out)
    return base, rec, (lane.group(1) if lane else "?")


def _base_by_sensor_name(buf):
    """Fallback for blobs whose module name does not end in the part number.

    The aux blobs are named `...aux_vd55g0_MSHW0492`, so chromatix_parse's
    "module name ends in the part number" trick picks `MSHW0492` and fails.
    Pin the base off the `sensorName` record's data instead, and accept only a
    base that makes resolutionData a whole number of 252-byte modes.
    """
    sys.path.insert(0, HERE)
    from chromatix_parse import records

    recs = list(records(buf, end=len(buf)))
    res = [r for r in recs if r[1] == "resolutionData" and r[4] >= STRIDE]
    for _, name, _, doff, dlen, _ in recs:
        if name != "sensorName" or not dlen:
            continue
        for j in range(len(buf)):
            j = buf.find(b"\x00", j)
            if j < 0:
                break
            break
        # try every occurrence of a NUL-terminated token of the right length
        for m in re.finditer(rb"[ -~]{%d}\x00" % (dlen - 1), buf):
            base = m.start() - doff
            if base <= 0 or not res:
                continue
            _, _, _, ro, rl, _ = res[0]
            if base + ro + rl <= len(buf) and rl % STRIDE == 0:
                return base, res[0]
    return None, None


def modes(path):
    """Return (list-of-mode-rows, laneAssign-string). Each row is 63 u32."""
    buf = open(path, "rb").read()
    base, rec, lane = _parse(path)
    if base is None or rec is None:
        # chromatix_parse could not pin the base, so its laneAssign line was
        # matched against an unpinned dump -- do not report it as a value.
        lane = "?"
        base, res = _base_by_sensor_name(buf)
        if base is None:
            return [], lane
        off, ln = res[3], res[4]
    else:
        off, ln = int(rec.group(1), 16), int(rec.group(2))
    d = buf[base + off:base + off + ln]
    if len(d) < ln or ln % STRIDE:
        return [], lane
    n = ln // STRIDE
    return [[struct.unpack_from("<I", d, m * STRIDE + i * 4)[0]
             for i in range(STRIDE // 4)] for m in range(n)], lane


def main(argv):
    full = "--columns" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        print(__doc__)
        return 1

    print(f"{'blob':34} {'modes':>5} {'laneAssign':>11} "
          f"{'laneCount':>10} {'is3Phase':>9}")
    rows = {}
    for p in paths:
        ms, lane = modes(p)
        rows[p] = ms
        if not ms:
            print(f"{os.path.basename(p)[:34]:34} -- resolutionData not decodable")
            continue

        def col(i):
            vals = {m[i] for m in ms}
            return str(sorted(vals)[0]) if len(vals) == 1 else str(sorted(vals))

        print(f"{os.path.basename(p)[:34]:34} {len(ms):>5} {lane:>11} "
              f"{col(COL_LANE_COUNT):>10} {col(COL_IS_3PHASE):>9}")

    if full:
        for p, ms in rows.items():
            if not ms:
                continue
            print(f"\n=== {os.path.basename(p)} ===")
            for i in range(STRIDE // 4):
                vals = [m[i] for m in ms]
                if all(v == 0 for v in vals):
                    continue
                print(f"  [{i:2d}] byte {i * 4:4d} |" + "".join(f"{v:>12}" for v in vals))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
