#!/usr/bin/env python3
"""Parse the Surface camera resource blobs (`CAM*_RES_MSHW*.bin`, `SCFG_*.bin`).

These ship in the Windows driver store alongside the Qualcomm camera drivers:

    C:\\Windows\\System32\\DriverStore\\FileRepository\\
        surfacecam{front,rear,aux}sensor_extension8380.inf_arm64_*\\

The DSDT declares the camera sensors as bare `_HID`/`_UID`/`_SUB`/`_STA` stubs with
no `_CRS` at all, so none of the wiring a device tree needs — clocks, regulators,
GPIOs, I2C address, CSIPHY lanes — is in ACPI. It is in these blobs, and each
sensor's ACPI `_SUB` names the file that applies to this machine.

The format turns out to be a self-describing TLV tree, no reverse engineering
required:

    magic   "AeoB"   4 bytes
    size    u32              total file size
    version u32              1
    then a tree of records:
    type    u16
    length  u16
    payload `length` bytes

    type 0 -> unsigned integer (payload is 1/2/4/8 bytes, little-endian)
    type 1 -> NUL-terminated ASCII string
    type 3 -> container; payload is a nested sequence of records

Usage: python camres_parse.py CAMF_RES_MSHW0490.bin [...]
"""
import struct
import sys

T_INT, T_STR, T_LIST = 0, 1, 3


def parse(buf, pos, end):
    """Walk a record sequence, returning a list of (type, value) pairs."""
    out = []
    while pos + 4 <= end:
        rtype, rlen = struct.unpack_from("<HH", buf, pos)
        pos += 4
        if pos + rlen > end:
            break
        payload = buf[pos:pos + rlen]
        if rtype == T_LIST:
            out.append((T_LIST, parse(buf, pos, pos + rlen)))
        elif rtype == T_STR:
            out.append((T_STR, payload.rstrip(b"\x00").decode("ascii", "replace")))
        elif rtype == T_INT:
            out.append((T_INT, int.from_bytes(payload, "little")))
        else:
            out.append((rtype, payload.hex()))
        pos += rlen
    return out


def render(nodes, depth=0):
    """Print the tree. A container whose members are all scalars goes on one line."""
    pad = "  " * depth
    for rtype, value in nodes:
        if rtype == T_LIST:
            flat = [v for t, v in value if t != T_LIST]
            if len(flat) == len(value):
                # Only a leading *string* is a label; a leading int is data
                # (the GPIO pin number, for one) and must not be swallowed.
                if flat and isinstance(flat[0], str):
                    head, rest = flat[0], flat[1:]
                else:
                    head, rest = "", flat
                print(f"{pad}{head:<18} " + "  ".join(
                    (f"0x{v:x} ({v})" if isinstance(v, int) else repr(v)) for v in rest))
            else:
                print(f"{pad}[")
                render(value, depth + 1)
                print(f"{pad}]")
        elif rtype == T_STR:
            print(f"{pad}{value!r}")
        elif rtype == T_INT:
            print(f"{pad}0x{value:x} ({value})")
        else:
            print(f"{pad}<type {rtype}> {value}")


def main(paths):
    for path in paths:
        buf = open(path, "rb").read()
        magic, size, version = struct.unpack_from("<4sII", buf, 0)
        print(f"===== {path} =====")
        print(f"magic={magic!r} size={size} (file {len(buf)}) version={version}")
        if magic != b"AeoB":
            print("  unexpected magic, skipping")
            continue
        render(parse(buf, 12, len(buf)))
        print()


if __name__ == "__main__":
    main(sys.argv[1:] or ["CAMF_RES_MSHW0490.bin"])
