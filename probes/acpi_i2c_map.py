#!/usr/bin/env python3
"""Map I2C/SPI/UART slave devices out of the Windows ACPI DSDT.

Linux's upstream Surface Pro 11 device tree has enabled I2C buses with unidentified
devices on them:

    &i2c0 { /* Something @39, @3e, @44 */ };
    &i2c4 { /* Something @12, @14, @16, @18, @1a */ };

Windows enumerates the same hardware via ACPI, and the DSDT contains SerialBus
connection descriptors (0x8E) that carry the slave address plus the controller path,
inside a Device() scope that also carries a _HID. So the mapping is recoverable
statically - no bus probing required.

Usage: python acpi_i2c_map.py [path/to/DSDT.aml]
"""
import os
import re
import struct
import sys

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "data", "acpi", "DSDT.aml")
d = open(path, "rb").read()

BUS = {1: "I2C", 2: "SPI", 3: "UART"}


def decode_eisaid(v):
    """Inverse of the EISAID packing, for _HID values stored as integers."""
    vendor = ((v >> 10) & 0x1F, (v >> 5) & 0x1F, v & 0x1F)
    letters = "".join(chr(0x40 + c) for c in vendor)
    return f"{letters}{(v >> 16) & 0xFFFF:04X}"


def nearest_device(pos, back=4096):
    """Walk back to the enclosing Device() op and return (name, hid_string)."""
    start = max(0, pos - back)
    for i in range(pos, start, -1):
        if d[i - 1] == 0x5B and d[i] == 0x82:
            j = i + 1
            lead = d[j]
            j += 1 + ((lead >> 6) & 3)
            while j < len(d) and d[j] in (0x5C, 0x5E):
                j += 1
            if j < len(d) and d[j] == 0x2E:
                j += 1
                name = d[j:j + 8].decode("ascii", "replace")
            elif j < len(d) and d[j] == 0x2F:
                cnt = d[j + 1]
                j += 2
                name = d[j:j + 4 * cnt].decode("ascii", "replace")
            else:
                name = d[j:j + 4].decode("ascii", "replace")

            # look for a _HID inside this device's first ~1.5 KB
            scope = d[i:i + 1536]
            hid = ""
            k = scope.find(b"_HID")
            if k >= 0:
                tail = scope[k + 4:k + 16]
                if tail[:1] == b"\x0d":                      # string
                    end = tail.find(b"\x00", 1)
                    hid = tail[1:end].decode("ascii", "replace")
                elif tail[:1] == b"\x0c" and len(tail) >= 5:  # DWordConst
                    hid = decode_eisaid(struct.unpack_from("<I", tail, 1)[0])
                elif tail[:1] == b"\x0b" and len(tail) >= 3:  # WordConst
                    hid = decode_eisaid(struct.unpack_from("<H", tail, 1)[0])
            return name.strip(), hid
    return "?", ""


rows = []
i = 0
while i < len(d) - 16:
    if d[i] != 0x8E:
        i += 1
        continue
    dlen = struct.unpack_from("<H", d, i + 1)[0]
    if dlen < 9 or i + 3 + dlen > len(d):
        i += 1
        continue
    bus_type = d[i + 5]
    if bus_type not in BUS:
        i += 1
        continue
    tdl = struct.unpack_from("<H", d, i + 10)[0]      # type data length
    tdata = i + 12
    addr = None
    if bus_type == 1 and tdl >= 6:                     # I2C: speed(4) + address(2)
        addr = struct.unpack_from("<H", d, tdata + 4)[0]
    elif bus_type == 2 and tdl >= 8:                   # SPI
        addr = struct.unpack_from("<H", d, tdata + 4)[0]
    src = d[tdata + tdl: i + 3 + dlen].split(b"\x00")[0].decode("ascii", "replace")
    name, hid = nearest_device(i)
    rows.append((BUS[bus_type], addr, src.strip(), name, hid))
    i += 3 + dlen

print(f"{os.path.basename(path)}: {len(rows)} serial-bus connections\n")
print(f"{'BUS':5} {'ADDR':>6}  {'CONTROLLER':38} {'DEVICE':10} HID")
print("-" * 100)
seen = set()
for bus, addr, src, name, hid in rows:
    key = (bus, addr, src, name)
    if key in seen:
        continue
    seen.add(key)
    a = f"0x{addr:02X}" if addr is not None else "-"
    print(f"{bus:5} {a:>6}  {src[-38:]:38} {name:10} {hid}")
