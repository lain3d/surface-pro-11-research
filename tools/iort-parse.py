#!/usr/bin/env python3
"""
iort-parse -- read SMMU stream IDs for named devices out of an ACPI IORT.

Device tree needs `iommus = <&apps_smmu SID MASK>` for every DMA master behind
an enabled SMMU. On this machine those numbers are not in any driver or
datasheet we have; they are in the firmware's IORT, mapping ACPI device object
names to stream IDs. This pulls them out so a DT node can be written from
firmware rather than guessed.

Same reasoning that produced the USB4 interrupt numbers: take the value the
firmware already states, and say where it came from.

Usage:
  iort-parse.py data/acpi/IORT.aml [--match UBF0]
"""

import argparse
import struct
import sys

NODE_TYPES = {
    0: "ITS group", 1: "Named component", 2: "Root complex",
    3: "SMMUv1/v2", 4: "SMMUv3", 5: "PMCG", 6: "RMR",
}


def cstr(buf, off):
    end = buf.find(b"\x00", off)
    return buf[off:end if end >= 0 else len(buf)].decode("ascii", "replace")


def parse(path):
    buf = open(path, "rb").read()
    if buf[:4] != b"IORT":
        sys.exit(f"{path}: not an IORT table (signature {buf[:4]!r})")
    length = struct.unpack_from("<I", buf, 4)[0]
    num_nodes, node_off = struct.unpack_from("<II", buf, 36)
    print(f"IORT  length={length}  nodes={num_nodes}  first_node=0x{node_off:x}\n")

    nodes = {}
    off = node_off
    for _ in range(num_nodes):
        if off + 16 > len(buf):
            break
        ntype = buf[off]
        nlen, rev = struct.unpack_from("<HB", buf, off + 1)
        ident, map_count, map_off = struct.unpack_from("<III", buf, off + 4)
        nodes[off] = (ntype, nlen, rev, ident, map_count, map_off)
        off += nlen
        if nlen == 0:
            break
    return buf, nodes


def name_of(buf, off, ntype, nlen):
    if ntype == 1:                       # named component
        # node_flags(4) + memory_access(8) + memory_address_limit(1)
        return cstr(buf, off + 16 + 13)
    if ntype in (3, 4):
        base = struct.unpack_from("<Q", buf, off + 16)[0]
        return f"SMMU @ 0x{base:x}"
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("table")
    ap.add_argument("--match", default="")
    args = ap.parse_args()

    buf, nodes = parse(args.table)

    labels = {}
    for off, (ntype, nlen, *_rest) in nodes.items():
        labels[off] = name_of(buf, off, ntype, nlen) or NODE_TYPES.get(ntype, f"type {ntype}")

    for off, (ntype, nlen, rev, ident, map_count, map_off) in sorted(nodes.items()):
        label = labels[off]
        if args.match and args.match.lower() not in label.lower():
            continue
        kind = NODE_TYPES.get(ntype, f"type {ntype}")
        print(f"0x{off:04x}  {kind:16s}  {label}")
        if ntype == 1:
            flags = struct.unpack_from("<I", buf, off + 16)[0]
            cca, hints, _res, mflags = struct.unpack_from("<IBHB", buf, off + 20)
            print(f"          node_flags=0x{flags:x}  cache_coherent=0x{cca:x} "
                  f"memory_flags=0x{mflags:x}")
        for i in range(map_count):
            m = off + map_off + i * 20
            if m + 20 > len(buf):
                break
            in_base, id_count, out_base, out_ref, mflags = struct.unpack_from("<IIIII", buf, m)
            tgt = labels.get(out_ref, f"node@0x{out_ref:x}")
            single = mflags & 1
            if single:
                print(f"          -> stream id 0x{out_base:x} (single mapping)  to {tgt}")
            else:
                print(f"          -> input 0x{in_base:x}..0x{in_base + id_count:x} "
                      f"=> stream 0x{out_base:x}..0x{out_base + id_count:x}  to {tgt}")
                print(f"             device tree: iommus = <&apps_smmu 0x{out_base:x} "
                      f"0x{id_count:x}>;")
        print()


if __name__ == "__main__":
    main()
