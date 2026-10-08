#!/usr/bin/env python3
"""Reduce the `CAM*_RES_MSHW*.bin` power blobs to the facts a DT node needs.

Each blob is the Windows power-up/power-down sequence for one camera device,
in execution order: clocks, footswitches, TLMM GPIOs, PMIC regulator votes and
delays. Everything a Linux sensor driver needs for `power_on()` is here except
the I2C slave address, which is genuinely absent (see chromatix_slaveaddr.py).

The MCLK clock name is the useful one -- `cam_cc_mclkN_clk` pins which of the
SoC's MCLK outputs feeds this module, and by extension which CCI bus it sits
on. The regulator votes give the rails and their exact microvolts, and the
TLMM entry gives the reset GPIO and its polarity, read off the 0->1 transition
rather than assumed.

Usage: python camres_summary.py CAM*_RES*.bin
"""
import re
import subprocess
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def summarise(path):
    out = subprocess.run([sys.executable, os.path.join(HERE, "camres_parse.py"), path],
                         capture_output=True, text=True).stdout
    dev = re.search(r"'(\\\\_SB\.[A-Z0-9]+)'", out)
    print(f"=== {os.path.basename(path)}  {dev.group(1) if dev else '?'} ===")

    clocks = []
    for m in re.finditer(r"'CLOCK'\n\s+(\S+)\s+(.*)", out):
        name, rest = m.group(1), m.group(2).strip()
        rate = re.findall(r"\((\d+)\)", rest)
        hz = int(rate[1]) if len(rate) > 1 else None
        entry = (name, hz)
        if entry not in clocks:
            clocks.append(entry)
    print("  clocks:")
    for name, hz in clocks:
        r = f"{hz/1e6:g} MHz" if hz else ""
        star = "   <-- MCLK" if "mclk" in name else ""
        print(f"      {name:<26} {r}{star}")

    fsw = sorted(set(re.findall(r"'FOOTSWITCH'\n\s+(\S+)", out)))
    if fsw:
        print("  footswitch: " + ", ".join(fsw))

    rails = []
    for m in re.finditer(r"'PMICVREGVOTE'\n\s+(\S+)\s+(.*)", out):
        nums = re.findall(r"\((\d+)\)", m.group(2))
        uv = int(nums[1]) if len(nums) > 1 else 0
        e = (m.group(1), uv)
        if e not in rails:
            rails.append(e)
    print("  regulators:")
    for name, uv in rails:
        print(f"      {name:<26} {uv/1e6:g} V")

    gpios = re.findall(r"'TLMMGPIO'\n\s+0x[0-9a-f]+ \((\d+)\)\s+0x[0-9a-f]+ \((\d+)\)", out)
    if gpios:
        pins = sorted({g[0] for g in gpios})
        seq = " -> ".join(f"{p}={v}" for p, v in gpios)
        print(f"  reset GPIO: {', '.join(pins)}   sequence: {seq}")

    rows = re.findall(r"'NPARESOURCE'\n\s+.*?'(\S+)'", out)
    if rows:
        print("  NPA: " + ", ".join(sorted(set(rows))))
    print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for p in sys.argv[1:]:
        summarise(p)
