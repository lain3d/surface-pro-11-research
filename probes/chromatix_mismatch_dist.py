#!/usr/bin/env python3
"""Are the mismatches scattered (extraction bug) or clustered (real tuning
difference)? Clustering in the crop/window registers would be the signature of
a genuine per-board difference."""
import re
import sys
import collections
sys.path.insert(0, r"C:\Users\Crazy\projs\arm64-egpu\probes")
from chromatix_regs import extract

blob, src = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8", errors="replace").read()

m = re.search(r"static const struct ov13858_reg mode_4224x3136_regs\[\] = \{(.*?)\n\};",
              text, re.S)
ref = {int(a, 16): int(v, 16)
       for a, v in re.findall(r"\{0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+)\}", m.group(1))}

tables = sorted(extract(blob), key=lambda t: -len(t[2]))
got = {}
for a, v, _ in tables[0][2]:
    got.setdefault(a, v)

common = sorted(set(got) & set(ref))
diffs = [a for a in common if got[a] != ref[a]]

# OmniVision crop / timing window block
CROP = {
    0x3800: "h_crop_start_hi", 0x3801: "h_crop_start_lo",
    0x3802: "v_crop_start_hi", 0x3803: "v_crop_start_lo",
    0x3804: "h_crop_end_hi",   0x3805: "h_crop_end_lo",
    0x3806: "v_crop_end_hi",   0x3807: "v_crop_end_lo",
    0x3808: "h_output_hi",     0x3809: "h_output_lo",
    0x380a: "v_output_hi",     0x380b: "v_output_lo",
    0x380c: "hts_hi",          0x380d: "hts_lo",
    0x380e: "vts_hi",          0x380f: "vts_lo",
    0x3810: "h_win_off_hi",    0x3811: "h_win_off_lo",
    0x3812: "v_win_off_hi",    0x3813: "v_win_off_lo",
}

print(f"{len(common)} registers in both; {len(diffs)} differ\n")
inwin = [a for a in diffs if a in CROP]
outwin = [a for a in diffs if a not in CROP]

print(f"  in the crop/window/timing block (0x3800-0x3813): {len(inwin)}")
for a in inwin:
    print(f"      0x{a:04x} {CROP[a]:<18} blob 0x{got[a]:02x}  mainline 0x{ref[a]:02x}")
print(f"\n  outside it: {len(outwin)}")
for a in outwin:
    print(f"      0x{a:04x}                    blob 0x{got[a]:02x}  mainline 0x{ref[a]:02x}")

print("\nmismatches by high byte:")
for hi, n in sorted(collections.Counter(a >> 8 for a in diffs).items()):
    tot = sum(1 for a in common if a >> 8 == hi)
    print(f"    0x{hi:02x}xx : {n:>3} of {tot:>3} differ")
