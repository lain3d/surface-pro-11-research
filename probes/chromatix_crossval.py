#!/usr/bin/env python3
"""Full cross-validation of the Chromatix register extractor.

The IMX681 driver's register tables rest entirely on this extraction being
right, and it was only spot-checked on 16 values. mainline ov13858.c holds the
real tables for this machine's rear sensor, so every overlapping register is a
test case.
"""
import re
import sys
import collections
sys.path.insert(0, r"C:\Users\Crazy\projs\arm64-egpu\probes")
from chromatix_regs import extract

blob, src = sys.argv[1], sys.argv[2]

# ---- mainline tables -------------------------------------------------
text = open(src, encoding="utf-8", errors="replace").read()
mainline = {}          # table name -> {addr: val}
for m in re.finditer(r"static const struct ov13858_reg (\w+)\[\] = \{(.*?)\n\};",
                     text, re.S):
    name, body = m.group(1), m.group(2)
    regs = {}
    for a, v in re.findall(r"\{0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+)\}", body):
        regs[int(a, 16)] = int(v, 16)
    mainline[name] = regs
    print(f"  mainline {name:<28} {len(regs)} registers")

# ---- extracted tables ------------------------------------------------
print()
tables = extract(blob)
for doff, dlen, entries in sorted(tables, key=lambda t: -len(t[2])):
    print(f"  blob table +0x{doff:<6x} {len(entries)} registers")

# ---- compare every blob table against every mainline table -----------
print("\nbest match for each blob table (overlap = registers present in both):\n")
overall_same = overall_diff = 0
for doff, dlen, entries in sorted(tables, key=lambda t: -len(t[2])):
    got = {}
    for a, v, _ in entries:
        got.setdefault(a, v)
    best = None
    for name, regs in mainline.items():
        common = set(got) & set(regs)
        if not common:
            continue
        same = sum(1 for a in common if got[a] == regs[a])
        score = (len(common), same)
        if best is None or score > best[0]:
            best = (score, name, common, same)
    if best is None:
        print(f"  +0x{doff:<6x}  no overlap with any mainline table")
        continue
    (_, name, common, same) = best
    pct = 100.0 * same / len(common)
    print(f"  +0x{doff:<6x} vs {name:<28} overlap {len(common):>3}  "
          f"match {same:>3}  ({pct:.1f}%)")
    overall_same += same
    overall_diff += len(common) - same
    diffs = [(a, got[a], mainline[name][a]) for a in sorted(common)
             if got[a] != mainline[name][a]]
    for a, g, e in diffs[:8]:
        print(f"        0x{a:04x}: extracted 0x{g:02x}, mainline 0x{e:02x}")
    if len(diffs) > 8:
        print(f"        ... {len(diffs) - 8} more")

tot = overall_same + overall_diff
print(f"\nTOTAL: {overall_same}/{tot} matching "
      f"({100.0 * overall_same / tot:.1f}%) across all overlapping registers")
