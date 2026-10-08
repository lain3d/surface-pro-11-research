#!/usr/bin/env python3
"""
Parse the dumped ACPI tables for everything that decides eGPU viability on this platform:

  MCFG  -> PCIe segments, ECAM bases, bus ranges
  DSDT  -> PNP0A08/PNP0A03 host bridges and the MMIO windows their _CRS declares
  IORT  -> SMMU (IOMMU) topology, root-complex address-size limits, stream ID mappings

Deliberately not a full AML interpreter. For _CRS we scan for raw ACPI resource
descriptors (0x8A QWord / 0x87 DWord address-space descriptors), which is how
ResourceTemplate() bytes appear inline in AML, and correlate them to the nearest
preceding Device()/_HID by file offset. That is heuristic but sufficient for recon.

Usage: python parse_acpi.py [acpi_dir]
"""
import struct
import sys
import os

ACPI_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "data", "acpi")


def rd(name):
    p = os.path.join(ACPI_DIR, name)
    if not os.path.exists(p):
        return None
    with open(p, "rb") as f:
        return f.read()


def hdr(b):
    sig, length, rev, csum = struct.unpack_from("<4sIBB", b, 0)
    oemid = b[10:16].decode("ascii", "replace").strip("\0 ")
    oemtbl = b[16:24].decode("ascii", "replace").strip("\0 ")
    return sig.decode(), length, rev, oemid, oemtbl


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n/1.0:.2f}{unit}".replace(".00", "")
        n /= 1024.0


def hsize(n):
    """Human-readable byte size."""
    units = ["B", "KB", "MB", "GB", "TB"]
    v = float(n)
    i = 0
    while v >= 1024 and i < len(units) - 1:
        v /= 1024.0
        i += 1
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return f"{s}{units[i]}"


# ---------------------------------------------------------------- MCFG
def parse_mcfg():
    b = rd("MCFG.aml")
    print("=" * 78)
    print("MCFG  -- PCIe ECAM configuration space segments")
    print("=" * 78)
    if not b:
        print("  (missing)")
        return {}
    _, length, _, _, _ = hdr(b)
    off = 44  # 36 byte header + 8 reserved
    segs = {}
    while off + 16 <= length:
        base, seg, sbus, ebus = struct.unpack_from("<QHBB", b, off)
        nbus = ebus - sbus + 1
        segs[seg] = (base, sbus, ebus)
        print(f"  segment {seg}: ECAM base 0x{base:012X}  buses {sbus:3d}-{ebus:<3d} "
              f"({nbus} bus{'es' if nbus != 1 else ''}, {hsize(nbus * 1024 * 1024)} of config space)")
        off += 16
    print()
    return segs


# ---------------------------------------------------------------- resource descriptors
RES_TYPE = {0: "Memory", 1: "IO", 2: "BusNumber"}


def decode_addr_desc(b, off):
    """Decode a QWord(0x8A)/DWord(0x87)/Word(0x88) address space descriptor."""
    tag = b[off]
    dlen = struct.unpack_from("<H", b, off + 1)[0]
    if tag == 0x8A:
        w, fmt = 8, "<QQQQQ"
    elif tag == 0x87:
        w, fmt = 4, "<IIIII"
    elif tag == 0x88:
        w, fmt = 2, "<HHHHH"
    else:
        return None
    need = 3 + 3 + 5 * w
    if off + need > len(b) or dlen < 3 + 5 * w:
        return None
    rtype = b[off + 3]
    gflags = b[off + 4]
    tflags = b[off + 5]
    gran, mn, mx, xlat, alen = struct.unpack_from(fmt, b, off + 6)
    return {
        "off": off, "width": w * 8, "rtype": rtype, "gflags": gflags, "tflags": tflags,
        "gran": gran, "min": mn, "max": mx, "xlat": xlat, "len": alen,
        "size": (3 + dlen),
    }


def scan_descriptors(b):
    out = []
    i = 0
    n = len(b)
    while i < n - 8:
        if b[i] in (0x8A, 0x87, 0x88):
            d = decode_addr_desc(b, i)
            if d and d["rtype"] in (0, 1, 2) and d["len"] > 0:
                # sanity: min<=max and the window is consistent
                if d["min"] <= d["max"] and d["len"] <= (d["max"] - d["min"] + 1):
                    out.append(d)
                    i += d["size"]
                    continue
        i += 1
    return out


# ---------------------------------------------------------------- DSDT
def eisaid(s):
    """Encode e.g. 'PNP0A08' to its 4 AML bytes."""
    v = ((ord(s[0]) - 0x40) << 10) | ((ord(s[1]) - 0x40) << 5) | (ord(s[2]) - 0x40)
    hexpart = int(s[3:], 16)
    return bytes([(v >> 8) & 0xFF, v & 0xFF,
                  (hexpart >> 8) & 0xFF, hexpart & 0xFF])


def nearest_device_name(b, pos, back=512):
    """Walk backward to the nearest Device() opcode (5B 82) and pull its NameSeg."""
    start = max(0, pos - back)
    best = None
    for i in range(pos, start, -1):
        if b[i - 1] == 0x5B and b[i] == 0x82:
            j = i + 1
            # skip PkgLength
            lead = b[j]
            nbytes = (lead >> 6) & 3
            j += 1 + nbytes
            # NameString: skip root '\' and '^' prefixes, and multi-name prefixes
            while j < len(b) and b[j] in (0x5C, 0x5E):
                j += 1
            if j < len(b) and b[j] == 0x2E:      # DualNamePrefix
                j += 1
                nm = b[j:j + 8].decode("ascii", "replace")
            elif j < len(b) and b[j] == 0x2F:    # MultiNamePrefix
                cnt = b[j + 1]
                j += 2
                nm = b[j:j + 4 * cnt].decode("ascii", "replace")
            else:
                nm = b[j:j + 4].decode("ascii", "replace")
            best = (i - 1, nm.strip())
            break
    return best


def parse_dsdt(segs):
    b = rd("DSDT.aml")
    print("=" * 78)
    print("DSDT  -- PCI host bridges and the MMIO windows firmware reserves for them")
    print("=" * 78)
    if not b:
        print("  (missing)")
        return
    print(f"  DSDT size: {len(b)} bytes\n")

    hits = []
    for hid in ("PNP0A08", "PNP0A03"):
        pat = eisaid(hid)
        i = 0
        while True:
            i = b.find(pat, i)
            if i < 0:
                break
            hits.append((i, hid))
            i += 4
    hits.sort()

    if not hits:
        print("  No PNP0A08/PNP0A03 _HID found (host bridges may be declared in an SSDT).")
        return

    descs = scan_descriptors(b)
    print(f"  Found {len(hits)} host-bridge _HID sites, {len(descs)} address-space descriptors in DSDT.\n")

    for idx, (pos, hid) in enumerate(hits):
        dev = nearest_device_name(b, pos)
        devname = dev[1] if dev else "?"
        devoff = dev[0] if dev else pos
        nxt = hits[idx + 1][0] if idx + 1 < len(hits) else len(b)
        # descriptors belonging to this device: between its Device() op and the next bridge
        mine = [d for d in descs if devoff <= d["off"] < nxt]
        print(f"  --- Device {devname}  (_HID {hid}, DSDT offset 0x{pos:X}) ---")
        if not mine:
            print("      no inline resource template found (likely a dynamic _CRS method)")
            print()
            continue
        for d in mine:
            t = RES_TYPE.get(d["rtype"], f"type{d['rtype']}")
            if d["rtype"] == 2:
                print(f"      {t:9s} bus {d['min']}..{d['max']}  (count {d['len']})")
            else:
                cache = {0: "non-cacheable", 1: "cacheable", 2: "write-combining",
                         3: "PREFETCHABLE"}.get((d["tflags"] >> 1) & 3, "?")
                rw = "RW" if (d["tflags"] & 1) else "RO"
                print(f"      {t:9s} 0x{d['min']:012X}-0x{d['max']:012X}  "
                      f"len {hsize(d['len']):>9s}  ({d['width']}-bit) "
                      f"{cache}/{rw}  [gflags=0x{d['gflags']:02X} tflags=0x{d['tflags']:02X}]")
        print()


# ---------------------------------------------------------------- IORT
IORT_NODE = {0: "ITS group", 1: "Named component", 2: "Root complex",
             3: "SMMUv1/v2", 4: "SMMUv3", 5: "PMCG", 6: "RMR"}


def parse_iort():
    b = rd("IORT.aml")
    print("=" * 78)
    print("IORT  -- IOMMU (SMMU) topology and DMA address limits")
    print("=" * 78)
    if not b:
        print("  (missing)")
        return
    _, length, rev, _, _ = hdr(b)
    ncount, noff = struct.unpack_from("<II", b, 36)
    print(f"  revision {rev}, {ncount} nodes\n")

    # First pass: index node offset -> type, so output references resolve to something meaningful
    index = {}
    o = noff
    for _ in range(ncount):
        if o + 16 > length:
            break
        index[o] = IORT_NODE.get(b[o], f"type{b[o]}")
        o += struct.unpack_from("<H", b, o + 1)[0]

    off = noff
    for _ in range(ncount):
        if off + 16 > length:
            break
        ntype = b[off]
        nlen = struct.unpack_from("<H", b, off + 1)[0]
        nrev = b[off + 3]
        ident = struct.unpack_from("<I", b, off + 4)[0]
        nmap = struct.unpack_from("<I", b, off + 8)[0]
        moff = struct.unpack_from("<I", b, off + 12)[0]
        name = IORT_NODE.get(ntype, f"type{ntype}")
        extra = ""
        if ntype == 2:  # Root complex
            cache, = struct.unpack_from("<I", b, off + 16)
            memflags = b[off + 21]
            ats, = struct.unpack_from("<I", b, off + 24)
            seg, = struct.unpack_from("<I", b, off + 28)
            addrlimit = b[off + 32]
            extra = (f"\n        PCI segment {seg}, "
                     f"memory address size limit {addrlimit} bits "
                     f"({hsize(1 << addrlimit) if 0 < addrlimit < 64 else 'n/a'}), "
                     f"coherent={bool(cache)}, ATS={'yes' if ats & 1 else 'no'}")
        elif ntype == 4:  # SMMUv3
            base, = struct.unpack_from("<Q", b, off + 16)
            flags, = struct.unpack_from("<I", b, off + 24)
            extra = f"\n        base 0x{base:012X}, flags 0x{flags:X}"
        elif ntype == 3:  # SMMUv1/2
            base, span = struct.unpack_from("<QQ", b, off + 16)
            model, = struct.unpack_from("<I", b, off + 32)
            extra = f"\n        base 0x{base:012X} span {hsize(span)}, model {model}"
        elif ntype == 0:  # ITS group
            cnt, = struct.unpack_from("<I", b, off + 16)
            ids = [struct.unpack_from("<I", b, off + 20 + 4 * i)[0] for i in range(min(cnt, 8))]
            extra = f"\n        {cnt} ITS block(s): {ids}"
        elif ntype == 1:  # Named component
            nm = b[off + 16 + 12:nlen + off].split(b"\0")[0].decode("ascii", "replace")
            extra = f"\n        name: {nm}"

        print(f"  [{name}] id=0x{ident:X} len={nlen} maps={nmap}{extra}")
        for m in range(nmap):
            mo = off + moff + m * 20
            if mo + 20 > length:
                break
            icount, ibase, obase, oref, mflags = struct.unpack_from("<IIIII", b, mo)
            single = " (single mapping)" if mflags & 1 else ""
            tgt = index.get(oref, "UNRESOLVED")
            print(f"        map: input 0x{ibase:X}..0x{ibase + icount:X} -> "
                  f"output 0x{obase:X} @0x{oref:X} [{tgt}]{single}")
        off += nlen
    print()


if __name__ == "__main__":
    print(f"\nACPI dir: {os.path.abspath(ACPI_DIR)}\n")
    segs = parse_mcfg()
    parse_dsdt(segs)
    parse_iort()
