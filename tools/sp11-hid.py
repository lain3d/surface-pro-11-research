#!/usr/bin/env python3
"""Find the Surface Pro 11 heat-map digitizer and talk to its feature reports.

The touchscreen exposes several HID collections. The one that matters is usage
page 0x0D (Digitizers), usage 0x0F (heat map), which carries a 7488-byte input
report and a 120-byte feature report.

Two feature reports were read off the Windows side and are expected to match
here (see docs/multitouch-heatmap.md):

    0x05   120 bytes, payload is a single 0x01 -- the collection's only boolean,
           i.e. the heat-map mode switch. Set on Windows.
    0x06   120 bytes of frame parameters. payload[0] = 119 (its own length),
           then 46 and 68 as u32 LE at payload offsets 14 and 18.

Read 0x06 FIRST. Its expected bytes are already written down, so if it matches,
the whole feature-report analysis is confirmed on real hardware before anything
gets written. If it does not match, stop -- do not write 0x05.

Usage:
    sudo ./sp11-hid.py list
    sudo ./sp11-hid.py get  <hidraw> <report-id> [length]
    sudo ./sp11-hid.py set  <hidraw> <report-id> <hex-bytes>
    sudo ./sp11-hid.py check <hidraw>          # verify 0x06 against expectations
    sudo ./sp11-hid.py enable <hidraw>         # check 0x06, then set 0x05 = 01
    sudo ./sp11-hid.py read <hidraw> [n]       # read n input reports

Nothing here writes anything unless you use `set` or `enable`.
"""
import fcntl
import glob
import os
import struct
import sys

# _IOC(dir, type, nr, size); _IOC_READ = 2, _IOC_WRITE = 1
def _ioc(d, t, nr, size):
    return (d << 30) | (size << 16) | (ord(t) << 8) | nr

def HIDIOCGFEATURE(n): return _ioc(3, 'H', 0x07, n)
def HIDIOCSFEATURE(n): return _ioc(3, 'H', 0x06, n)
def HIDIOCGRDESCSIZE(): return _ioc(2, 'H', 0x01, 4)
def HIDIOCGRDESC():     return _ioc(2, 'H', 0x02, 4 + 4096)

HEATMAP_PAGE, HEATMAP_USAGE = 0x0D, 0x0F


def report_descriptor(path):
    """Prefer sysfs; fall back to the ioctl."""
    node = os.path.basename(path)
    sysfs = f"/sys/class/hidraw/{node}/device/report_descriptor"
    if os.path.exists(sysfs):
        with open(sysfs, "rb") as f:
            return f.read()
    with open(path, "rb") as f:
        buf = bytearray(4 + 4096)
        fcntl.ioctl(f, HIDIOCGRDESC(), buf, True)
        size = struct.unpack_from("<I", buf, 0)[0]
        return bytes(buf[4:4 + size])


def top_level_usages(desc):
    """Walk the short-item stream and collect (page, usage) at each Collection.

    Only enough of the HID item format to identify a collection -- this is not a
    general parser and does not try to be.
    """
    out, i, page, usages = [], 0, None, []
    while i < len(desc):
        b = desc[i]
        if b == 0xFE:                      # long item
            i += 2 + desc[i + 1]
            continue
        size = b & 0x03
        size = 4 if size == 3 else size
        typ, tag = (b >> 2) & 0x03, (b >> 4) & 0x0F
        data = int.from_bytes(desc[i + 1:i + 1 + size], "little") if size else 0
        if typ == 1 and tag == 0x0:         # Global / Usage Page
            page = data
        elif typ == 2 and tag == 0x0:       # Local / Usage
            usages.append(data)
        elif typ == 0 and tag == 0xA:       # Main / Collection
            u = usages[0] if usages else None
            if u is not None and u > 0xFFFF:
                page, u = u >> 16, u & 0xFFFF
            out.append((page, u))
            usages = []
        elif typ == 0:
            usages = []
        i += 1 + size
    return out


def devices():
    for path in sorted(glob.glob("/dev/hidraw*")):
        try:
            desc = report_descriptor(path)
        except Exception as e:
            yield path, None, f"<{e}>"
            continue
        yield path, desc, top_level_usages(desc)


def cmd_list():
    print(f"{'device':<16} {'len':>5}  collections (page/usage)")
    for path, desc, cols in devices():
        if desc is None:
            print(f"{path:<16} {'-':>5}  {cols}")
            continue
        tag = ""
        if any(p == HEATMAP_PAGE and u == HEATMAP_USAGE for p, u in cols):
            tag = "   <== HEAT MAP DIGITIZER"
        pretty = " ".join(f"{p:#06x}/{u:#04x}" for p, u in cols if p is not None)
        print(f"{path:<16} {len(desc):>5}  {pretty}{tag}")
    print("\nPick the device tagged HEAT MAP DIGITIZER for everything below.")


def get_feature(path, rid, length=120):
    buf = bytearray(length)
    buf[0] = rid
    with open(path, "rb+", buffering=0) as f:
        n = fcntl.ioctl(f, HIDIOCGFEATURE(length), buf, True)
    return bytes(buf[:n if n > 0 else length])


def set_feature(path, rid, payload, length=120):
    buf = bytearray(length)
    buf[0] = rid
    buf[1:1 + len(payload)] = payload
    with open(path, "rb+", buffering=0) as f:
        return fcntl.ioctl(f, HIDIOCSFEATURE(length), buf, True)


def hexdump(b, indent="    "):
    for o in range(0, len(b), 16):
        print(indent + f"{o:03x}  " + " ".join(f"{x:02x}" for x in b[o:o + 16]))


def cmd_check(path):
    """Verify report 0x06 against what Windows reported. Read-only."""
    data = get_feature(path, 0x06, 120)
    payload = data[1:]
    print(f"feature 0x06, {len(data)} bytes (report id + {len(payload)} payload)")
    hexdump(data)
    ok = True

    def chk(label, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print(f"  {'OK ' if good else 'BAD'}  {label}: got {got}, expected {want}")

    chk("payload[0] self-length", payload[0] if payload else None, 119)
    chk("rows  (u32 @ payload+14)", struct.unpack_from("<I", payload, 14)[0] if len(payload) > 18 else None, 46)
    chk("cols  (u32 @ payload+18)", struct.unpack_from("<I", payload, 18)[0] if len(payload) > 22 else None, 68)

    print()
    if ok:
        print("MATCH - the feature-report analysis holds on real hardware.")
    else:
        print("MISMATCH - stop here. Do NOT write 0x05; re-derive the layout first.")
    return 0 if ok else 1


def cmd_enable(path):
    if cmd_check(path) != 0:
        return 1
    cur = get_feature(path, 0x05, 120)
    print(f"\nfeature 0x05 currently: {cur[1]:#04x}")
    if cur[1] == 1:
        print("already enabled; nothing to do")
        return 0
    print("writing 0x05 = 01 to enable heat-map mode")
    set_feature(path, 0x05, b"\x01", 120)
    back = get_feature(path, 0x05, 120)
    print(f"read back: {back[1]:#04x}  {'OK' if back[1] == 1 else 'DID NOT STICK'}")
    return 0 if back[1] == 1 else 1


def cmd_read(path, count=3):
    print(f"reading {count} input reports from {path} (touch the screen)")
    with open(path, "rb", buffering=0) as f:
        for i in range(count):
            data = f.read(8192)
            print(f"\n--- report {i}: {len(data)} bytes "
                  f"{'(7488 = full heat-map frame)' if len(data) == 7488 else ''}")
            hexdump(data[:64])
            if len(data) > 64:
                nz = sum(1 for b in data if b)
                print(f"    ... {len(data) - 64} more; {nz} non-zero bytes total")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd = argv[0]
    if cmd == "list":
        cmd_list(); return 0
    if len(argv) < 2:
        print(__doc__); return 2
    dev = argv[1]
    if cmd == "get":
        rid = int(argv[2], 0)
        ln = int(argv[3], 0) if len(argv) > 3 else 120
        hexdump(get_feature(dev, rid, ln), indent="  ")
        return 0
    if cmd == "set":
        rid = int(argv[2], 0)
        payload = bytes.fromhex(argv[3].replace(" ", ""))
        set_feature(dev, rid, payload, 120)
        print("written; reading back:")
        hexdump(get_feature(dev, rid, 120), indent="  ")
        return 0
    if cmd == "check":
        return cmd_check(dev)
    if cmd == "enable":
        return cmd_enable(dev)
    if cmd == "read":
        cmd_read(dev, int(argv[2]) if len(argv) > 2 else 3)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except PermissionError:
        sys.exit("permission denied - run with sudo")
