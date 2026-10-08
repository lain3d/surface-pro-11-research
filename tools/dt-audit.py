#!/usr/bin/env python3
"""
dt-audit -- find device-tree bugs offline, before they cost a boot cycle.

Every check here exists because a real bug on this machine cost real reboots.
The pattern each one generalises is the same: a value in the device tree has
to satisfy a constraint that lives in the consuming driver, and nothing in
the build checks that the two agree.

  REG-GRID   a regulator voltage that is not on the PMIC's step grid.
             vreg_l16b_2p9 at 2900000 uV stalled the boot at 0.196s; the fix
             exposed vreg_l2m_1p15 at 1150000 doing the same thing one PMIC
             over. Constraints are read out of qcom-rpmh-regulator.c, not
             hardcoded, so they follow the driver.

  NAME-COUNT clocks/clock-names and friends disagreeing in length. Cell
             counts come from each provider's #*-cells, resolved by phandle.

  GDSC       an enabled node whose SoC clock driver defines a matching GDSC
             that the node never references. This is the USB4 bug: no
             power-domains meant the branch clock could not leave halt and
             probe died with -EBUSY.

  DUP-IRQ    two enabled nodes claiming the same GIC SPI.
  DUP-GPIO   two enabled nodes claiming the same TLMM pin.
  REG-OVER   two enabled nodes with overlapping MMIO windows. Our USB4 node
             rounded a 0xBFFFF window from ACPI up to 0xC0000 on a hunch.

  DEAD-REF   a *-supply or phandle pointing at a disabled or absent node.
  NO-DRIVER  an enabled node whose compatible no driver in the tree claims,
             or whose driver is not enabled in .config.

  ODD-ONE-OUT a property that most other boards with the same compatible
             declare and this one does not. This is how the missing
             reset-gpios on the WCN7850 PCIe port was found: 23 of 24 boards
             had it. Reported as a hint, never as a defect -- boards legitimately
             differ, and this check is a lead generator.

Usage:
  dt-audit.py --tree /root/sp11/wt-ov13858 \
              --board x1e80100-microsoft-denali-oled \
              [--check REG-GRID,GDSC] [--quiet-hints]
"""

import argparse
import os
import re
import subprocess
import sys
from collections import defaultdict

# ---------------------------------------------------------------- DTS parsing


class Node:
    __slots__ = ("path", "name", "props", "children", "parent")

    def __init__(self, path, name, parent=None):
        self.path = path
        self.name = name
        self.props = {}
        self.children = []
        self.parent = parent

    def __repr__(self):
        return f"<Node {self.path}>"

    @property
    def label(self):
        return self.name.split("@")[0]

    def cells(self, prop):
        """Flat list of ints from a <..> property."""
        raw = self.props.get(prop)
        if raw is None:
            return None
        out = []
        for m in re.finditer(r"<([^>]*)>", raw):
            for tok in m.group(1).split():
                tok = tok.strip()
                if not tok:
                    continue
                try:
                    out.append(int(tok, 0))
                except ValueError:
                    pass
        return out

    def strings(self, prop):
        """
        dtc renders a string *list* as one quoted string with \\0 separators:
            clock-names = "camnoc_axi\\0cpas_ahb\\0cci";
            compatible  = "qcom,x1e80100-cci\\0qcom,msm8996-cci";
        Reading these as single strings silently made every string list look
        one element long, which turned name-count checking into 80-odd false
        positives and made `compatible` matching miss entirely.
        """
        raw = self.props.get(prop)
        if raw is None:
            return None
        out = []
        for s in re.findall(r'"((?:[^"\\]|\\.)*)"', raw):
            out.extend(p for p in s.split("\\0") if p != "")
        return out

    def status(self):
        s = self.strings("status")
        return s[0] if s else "okay"

    def enabled(self):
        return self.status() in ("okay", "ok")


def decompile(dtb):
    try:
        out = subprocess.run(
            ["dtc", "-I", "dtb", "-O", "dts", dtb],
            capture_output=True, text=True, timeout=120,
        )
    except FileNotFoundError:
        sys.exit("dtc not found; install device-tree-compiler")
    return out.stdout


def parse_dts(text):
    """Parse dtc output into a node tree. Good enough for flat dtc output."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)

    root = Node("/", "")
    stack = [root]
    i = 0
    n = len(text)
    buf = ""
    while i < n:
        c = text[i]
        if c == "{":
            name = buf.strip().split(":")[-1].strip()
            parent = stack[-1]
            if name == "/":                      # dtc's root node
                name = ""
            path = ("/" + name) if parent.path == "/" else (parent.path + "/" + name)
            path = re.sub(r"/+", "/", path)
            node = Node(path, name, parent)
            parent.children.append(node)
            stack.append(node)
            buf = ""
            i += 1
        elif c == "}":
            if len(stack) > 1:
                stack.pop()
            buf = ""
            i += 1
            while i < n and text[i] in " ;\n\t":
                i += 1
        elif c == ";":
            stmt = buf.strip()
            if stmt:
                if "=" in stmt:
                    k, v = stmt.split("=", 1)
                    stack[-1].props[k.strip()] = v.strip()
                else:
                    stack[-1].props[stmt] = True
            buf = ""
            i += 1
        else:
            buf += c
            i += 1
    return root


def walk(node):
    yield node
    for c in node.children:
        yield from walk(c)


def phandle_map(root):
    m = {}
    for nd in walk(root):
        for key in ("phandle", "linux,phandle"):
            cs = nd.cells(key)
            if cs:
                m[cs[0]] = nd
    return m


# --------------------------------------------------- driver-derived constraints


def rpmh_constraints(tree):
    """Read voltage ranges and per-PMIC LDO tables out of the rpmh driver."""
    p = os.path.join(tree, "drivers/regulator/qcom-rpmh-regulator.c")
    if not os.path.exists(p):
        return None
    src = open(p, encoding="utf-8", errors="replace").read()

    hw = {}
    for m in re.finditer(r"rpmh_vreg_hw_data\s+(\w+)\s*=\s*\{(.*?)\n\};", src, re.S):
        ranges = []
        for r in re.finditer(r"REGULATOR_LINEAR_RANGE\(([^)]*)\)", m.group(2)):
            parts = [x.strip() for x in r.group(1).split(",")]
            try:
                ranges.append(tuple(int(x, 0) for x in parts[:4]))
            except ValueError:
                pass
        if ranges:
            hw[m.group(1)] = ranges

    tables = {}
    for m in re.finditer(
        r"rpmh_vreg_init_data\s+(\w+)\[\]\s*=\s*\{(.*?)\n\};", src, re.S
    ):
        entries = {}
        for e in re.finditer(r'RPMH_VREG\(\s*"([^"]+)"\s*,.*?&(\w+)', m.group(2)):
            entries[e.group(1)] = e.group(2)
        if entries:
            tables[m.group(1)] = entries

    compat = {}
    for m in re.finditer(
        r'\.compatible\s*=\s*"([^"]+)"\s*,\s*\.data\s*=\s*&?(\w+)', src
    ):
        compat[m.group(1)] = m.group(2)

    return {"hw": hw, "tables": tables, "compat": compat}


def gdsc_names(tree, socname="x1e80100"):
    """GDSCs the SoC clock drivers define, e.g. gcc_usb4_0_gdsc."""
    found = set()
    for sub in ("clk/qcom",):
        d = os.path.join(tree, "drivers", sub)
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            if socname not in fn or not fn.endswith(".c"):
                continue
            src = open(os.path.join(d, fn), encoding="utf-8", errors="replace").read()
            for m in re.finditer(r"struct gdsc (\w+_gdsc)\s*=", src):
                found.add(m.group(1))
    return found


def compatible_index(tree):
    """
    Every quoted token appearing anywhere under drivers/ and sound/.

    Matching only `.compatible = "..."` misses drivers that build their
    of_device_id tables with macros, generic bindings handled without a
    match entry ("syscon", "cache", "shared-dma-pool"), and anything
    registered through OF_DECLARE. A whole-string index is coarser but its
    false-positive rate is low enough to be worth reading.
    """
    idx = set()
    try:
        out = subprocess.run(
            ["git", "grep", "-h", "-o", r'"[a-zA-Z0-9][a-zA-Z0-9,._+-]\{3,\}"',
             "--", "drivers/", "sound/"],
            cwd=tree, capture_output=True, text=True, timeout=600,
        ).stdout
    except Exception:
        return idx
    for line in out.splitlines():
        idx.add(line.strip().strip('"'))
    return idx


# ------------------------------------------------------------------- checks

FINDINGS = []


def finding(kind, sev, path, msg, detail=""):
    FINDINGS.append((kind, sev, path, msg, detail))


def check_reg_grid(root, con):
    if not con:
        return
    for nd in walk(root):
        comp = nd.strings("compatible") or []
        table = None
        for c in comp:
            if c in con["compat"]:
                table = con["tables"].get(con["compat"][c])
                break
        if not table:
            continue
        for child in nd.children:
            hwname = table.get(child.name)
            if not hwname:
                continue
            ranges = con["hw"].get(hwname)
            if not ranges:
                continue
            label = (child.strings("regulator-name") or [child.name])[0]
            lo = child.cells("regulator-min-microvolt")
            hi = child.cells("regulator-max-microvolt")
            if not lo:
                continue
            vmin = lo[0]
            vmax = hi[0] if hi else vmin
            if vmax < vmin:
                finding("REG-GRID", "BUG", child.path,
                        f"{label} min {vmin} exceeds max {vmax}")
                continue

            # The core does not require min to land on the grid -- it picks the
            # lowest selector inside [min, max]. The failure mode is an EMPTY
            # interval: no selector at all between min and max. That is what
            # vreg_l16b_2p9 (2900000..2900000, selectors at 2896000/2904000)
            # and vreg_l2m_1p15 (1150000..1150000) hit, and it fails the whole
            # regulators-N node with -ENOTRECOVERABLE, not just the one rail.
            # Checking "min is on the grid" instead flags correct upstream
            # rails like vreg_bob1 (3008000..3960000) and is simply wrong.
            # REGULATOR_LINEAR_RANGE(min_uV, min_sel, max_sel, step) yields
            #     V(sel) = min_uV + (sel - min_sel) * step,  sel in [min_sel, max_sel]
            # so the selector offset matters. Ignoring it makes the second
            # ftsmps525 range (base 1376000 starting at selector 268) look
            # unreachable for 1856000, which lands on it exactly.
            def values(rng):
                base, sel_lo, sel_hi, step = rng
                if step == 0:
                    return base, base, 0
                return base, base + (sel_hi - sel_lo) * step, step

            reachable = []
            near = []
            for rng in ranges:
                first, last, step = values(rng)
                if step == 0:
                    if vmin <= first <= vmax:
                        reachable.append(first)
                    else:
                        near.append(first)
                    continue
                if vmin <= first:
                    cand = first
                else:
                    cand = first + -(-(vmin - first) // step) * step
                if cand <= last:
                    if cand <= vmax:
                        reachable.append(cand)
                    else:
                        near.append(cand)
                        prev = cand - step
                        if prev >= first:
                            near.append(prev)
                else:
                    near.append(last)
            if reachable:
                continue
            hint = ""
            if near:
                best = min(near, key=lambda v: abs(v - vmin))
                hint = (f" -- widen the range or use {best}"
                        f" (nearest reachable to {vmin})")
            finding("REG-GRID", "BUG", child.path,
                    f"{label} [{vmin}, {vmax}] contains no selector "
                    f"reachable on {hwname}",
                    f"ranges={ranges}{hint}")


NAME_PAIRS = [
    ("clocks", "clock-names", "#clock-cells"),
    ("interrupts-extended", "interrupt-names", "#interrupt-cells"),
    ("resets", "reset-names", "#reset-cells"),
    ("dmas", "dma-names", "#dma-cells"),
    ("power-domains", "power-domain-names", "#power-domain-cells"),
]


def check_name_counts(root, ph):
    for nd in walk(root):
        if not nd.enabled():
            continue

        # reg / reg-names uses the parent's #address-cells + #size-cells
        names = nd.strings("reg-names")
        cs = nd.cells("reg")
        if names and cs and nd.parent:
            ac = (nd.parent.cells("#address-cells") or [2])[0]
            sc = (nd.parent.cells("#size-cells") or [1])[0]
            stride = ac + sc
            if stride and len(cs) % stride == 0:
                cnt = len(cs) // stride
                if cnt != len(names):
                    finding("NAME-COUNT", "BUG", nd.path,
                            f"reg has {cnt} entries but reg-names has {len(names)}")

        # interrupts against the interrupt parent's #interrupt-cells
        names = nd.strings("interrupt-names")
        cs = nd.cells("interrupts")
        if names and cs:
            ic = 3
            p = nd
            while p is not None:
                pc = p.cells("interrupt-parent")
                if pc and pc[0] in ph:
                    v = ph[pc[0]].cells("#interrupt-cells")
                    if v:
                        ic = v[0]
                    break
                p = p.parent
            if ic and len(cs) % ic == 0:
                cnt = len(cs) // ic
                if cnt != len(names):
                    finding("NAME-COUNT", "BUG", nd.path,
                            f"interrupts has {cnt} entries but "
                            f"interrupt-names has {len(names)}")

        for prop, nameprop, cellprop in NAME_PAIRS:
            names = nd.strings(nameprop)
            cs = nd.cells(prop)
            if not names or not cs:
                continue
            i = 0
            cnt = 0
            bad = False
            while i < len(cs):
                target = ph.get(cs[i])
                if target is None:
                    bad = True
                    break
                nc = (target.cells(cellprop) or [0])[0]
                i += 1 + nc
                cnt += 1
            if not bad and cnt != len(names):
                finding("NAME-COUNT", "BUG", nd.path,
                        f"{prop} has {cnt} entries but {nameprop} has {len(names)}")


def clock_id_names(tree, soc):
    """clock-provider index -> macro name, from the dt-bindings headers."""
    out = defaultdict(dict)
    d = os.path.join(tree, "include/dt-bindings/clock")
    if not os.path.isdir(d):
        return out
    for fn in os.listdir(d):
        if soc not in fn:
            continue
        kind = fn.rsplit("-", 1)[-1].replace(".h", "")
        src = open(os.path.join(d, fn), encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"^#define\s+(\w+)\s+(\d+)\s*$", src, re.M):
            out[kind][int(m.group(2))] = m.group(1)
    return out


def check_gdsc(root, ph, gdscs, clkids):
    """
    An enabled node that pulls clocks from a controller which also owns a
    matching GDSC, but never references that GDSC in power-domains.

    This is the USB4 bug: with the GDSC unpowered the branch clock cannot
    leave halt, clk_branch_wait() WARNs and returns -EBUSY, and probe dies.
    Resolving the clock *index* through the dt-bindings header is what lets
    this name the exact GDSC to add rather than guessing from the node name.
    """
    cores = {g[:-5]: g for g in gdscs}           # gcc_usb4_0 -> gcc_usb4_0_gdsc
    for nd in walk(root):
        if not nd.enabled() or "power-domains" in nd.props:
            continue
        cs = nd.cells("clocks")
        if not cs:
            continue
        wanted = {}
        i = 0
        while i < len(cs):
            prov = ph.get(cs[i])
            if prov is None:
                break
            ncells = (prov.cells("#clock-cells") or [0])[0]
            if ncells == 1 and i + 1 < len(cs):
                kind = None
                for c in prov.strings("compatible") or []:
                    for k in clkids:
                        if c.endswith(k):
                            kind = k
                            break
                name = clkids.get(kind, {}).get(cs[i + 1]) if kind else None
                if name:
                    low = name.lower()
                    for core, g in cores.items():
                        if low.startswith(core + "_"):
                            wanted[g] = name
            i += 1 + ncells
        for g, via in sorted(wanted.items()):
            finding("GDSC", "SUSPECT", nd.path,
                    f"no power-domains, but takes {via} from a controller "
                    f"that also defines {g}",
                    "a branch clock cannot leave halt with its GDSC off; "
                    "probe fails -EBUSY")


def check_duplicates(root, ph):
    irq = defaultdict(list)
    gpio = defaultdict(list)
    for nd in walk(root):
        if not nd.enabled():
            continue
        cs = nd.cells("interrupts")
        if cs and len(cs) % 3 == 0:
            for i in range(0, len(cs), 3):
                if cs[i] == 0:                   # GIC_SPI
                    irq[cs[i + 1]].append(nd.path)
        for prop, raw in nd.props.items():
            if not prop.endswith("gpios") and prop != "gpio":
                continue
            cells = nd.cells(prop)
            if cells and len(cells) >= 3 and len(cells) % 3 == 0:
                for i in range(0, len(cells), 3):
                    tgt = ph.get(cells[i])
                    if tgt is not None and "tlmm" in tgt.name:
                        gpio[cells[i + 1]].append(f"{nd.path}:{prop}")

    for num, users in sorted(irq.items()):
        # Sharing a SPI is legal (IRQF_SHARED) and cluster PMUs legitimately
        # do it, so this is a lead rather than a defect.
        if len(set(users)) > 1:
            finding("DUP-IRQ", "SUSPECT", users[0],
                    f"GIC SPI {num} claimed by {len(set(users))} enabled nodes",
                    ", ".join(sorted(set(users))))
    for num, users in sorted(gpio.items()):
        if len(set(users)) > 1:
            finding("DUP-GPIO", "SUSPECT", users[0].split(":")[0],
                    f"TLMM gpio {num} claimed by {len(set(users))} places",
                    ", ".join(sorted(set(users))))


def check_reg_overlap(root):
    """
    Only nodes sharing a parent are comparable: `reg` is in the parent bus's
    address space, so a register at 0x48 inside an SPMI nvram node and one at
    0x48 on the main soc bus are unrelated numbers.
    """
    by_parent = defaultdict(list)
    for nd in walk(root):
        if not nd.enabled() or nd.parent is None:
            continue
        by_parent[nd.parent.path].append(nd)
    for siblings in by_parent.values():
        _overlap_group(siblings)


def _overlap_group(nodes):
    spans = []
    for nd in nodes:
        if nd.parent is None:
            continue
        ac = (nd.parent.cells("#address-cells") or [2])[0]
        sc = (nd.parent.cells("#size-cells") or [1])[0]
        cs = nd.cells("reg")
        if not cs or ac + sc == 0 or len(cs) % (ac + sc):
            continue
        stride = ac + sc
        for i in range(0, len(cs), stride):
            addr = 0
            for j in range(ac):
                addr = (addr << 32) | cs[i + j]
            size = 0
            for j in range(sc):
                size = (size << 32) | cs[i + ac + j]
            if size:
                spans.append((addr, addr + size, nd.path))
    spans.sort()
    for a, b in zip(spans, spans[1:]):
        if a[1] > b[0] and a[2] != b[2]:
            finding("REG-OVER", "SUSPECT", b[2],
                    f"MMIO {b[0]:#x} overlaps {a[2]} ending {a[1]:#x}")


def check_dead_refs(root, ph):
    for nd in walk(root):
        if not nd.enabled():
            continue
        for prop, raw in nd.props.items():
            if not prop.endswith("-supply"):
                continue
            cs = nd.cells(prop)
            if not cs:
                continue
            tgt = ph.get(cs[0])
            if tgt is None:
                finding("DEAD-REF", "BUG", nd.path,
                        f"{prop} points at phandle {cs[0]:#x} which resolves to nothing")
            elif not tgt.enabled():
                finding("DEAD-REF", "BUG", nd.path,
                        f"{prop} points at {tgt.path}, which is {tgt.status()}")


GENERIC_COMPATS = {
    "cache", "syscon", "simple-bus", "simple-mfd", "shared-dma-pool",
    "usb-c-connector", "gpio-keys", "pwm-backlight", "operating-points-v2",
    "arm,armv8-pmuv3", "fixed-clock", "fixed-factor-clock",
}


def check_no_driver(root, compat_idx):
    """
    A node is only reported when NONE of its compatible strings appear
    anywhere in drivers/ or sound/. DT compatibles are a fallback list, so a
    node whose first string is unknown but whose second is claimed is fine --
    that is exactly how "qcom,x1e80100-cci", "qcom,msm8996-cci" works.
    """
    if not compat_idx:
        return
    seen = set()
    for nd in walk(root):
        if not nd.enabled():
            continue
        compats = nd.strings("compatible") or []
        if not compats:
            continue
        # CPU and SoundWire nodes are matched by other means (CPU compatibles
        # are informational; SoundWire devices bind on their SDW device ID).
        if nd.path.startswith("/cpus") or "soundwire@" in nd.path:
            continue
        key = tuple(compats)
        if key in seen:
            continue
        seen.add(key)
        if any(c in compat_idx or c in GENERIC_COMPATS for c in compats):
            continue
        if any(c.startswith(("simple-", "fixed-")) for c in compats):
            continue
        finding("NO-DRIVER", "HINT", nd.path,
                "no compatible is claimed anywhere in drivers/ or sound/: "
                + ", ".join(f'"{c}"' for c in compats))


IGNORE_PROPS = {
    "phandle", "linux,phandle", "status", "name",
    # instance-specific by nature; their presence says nothing
    "reg", "compatible", "interrupts", "interrupts-extended",
    "pinctrl-0", "pinctrl-1", "pinctrl-2", "pinctrl-names",
}


DMA_APIS = re.compile(
    r"\b(dma_alloc_coherent|dma_alloc_noncoherent|dma_map_single|dma_map_sg|"
    r"dma_set_mask|dma_set_mask_and_coherent|dma_pool_create|dmam_alloc_coherent)\b"
)


def check_dma_masters(root, tree, compat_files):
    """
    An enabled node whose driver does DMA, with no `iommus`, while an SMMU is
    enabled on the board.

    This is the second USB4 bug, found by hand after the GDSC one was fixed.
    nhi_probe_common() calls dma_set_mask_and_coherent(DMA_BIT_MASK(64)) and
    allocates every ring with dma_alloc_coherent(); apps_smmu is enabled and 39
    other nodes on this board declare stream IDs; the router nodes declared
    none. Fixing the GDSC would have moved the failure from clock setup to the
    first ring allocation rather than removing it.

    Stream IDs are not in the driver -- on this machine they came out of the
    firmware's IORT (see tools/iort-parse.py). This check finds the *gap*; it
    cannot supply the number.
    """
    smmu_on = False
    for nd in walk(root):
        if not nd.enabled():
            continue
        for c in nd.strings("compatible") or []:
            if "smmu" in c:
                smmu_on = True
                break
    if not smmu_on:
        return

    cache = {}

    def driver_does_dma(path):
        if path not in cache:
            full = os.path.join(tree, path)
            try:
                src = open(full, encoding="utf-8", errors="replace").read()
            except OSError:
                cache[path] = False
            else:
                cache[path] = bool(DMA_APIS.search(src))
        return cache[path]

    seen = set()
    for nd in walk(root):
        if not nd.enabled() or "iommus" in nd.props:
            continue
        compats = nd.strings("compatible") or []
        if not compats or tuple(compats) in seen:
            continue
        for c in compats:
            for path in compat_files.get(c, ()):
                if driver_does_dma(path):
                    seen.add(tuple(compats))
                    finding("DMA-MASTER", "SUSPECT", nd.path,
                            f'"{c}" is handled by {path}, which calls the DMA '
                            f"API, but this node declares no iommus",
                            "behind an enabled SMMU an unmapped stream faults "
                            "on the first allocation")
                    break
            if tuple(compats) in seen:
                break


def compat_file_index(tree, wanted):
    """compatible -> source files mentioning it, in one grep pass."""
    idx = defaultdict(set)
    wanted = [w for w in wanted if len(w) >= 4]
    if not wanted:
        return idx
    args = ["git", "grep", "-o", "-F"]
    for w in wanted:
        args += ["-e", f'"{w}"']
    args += ["--", "drivers/", "sound/"]
    try:
        out = subprocess.run(args, cwd=tree, capture_output=True,
                             text=True, timeout=600).stdout
    except Exception:
        return idx
    for line in out.splitlines():
        if ":" not in line:
            continue
        path, _, match = line.partition(":")
        idx[match.strip().strip('"')].add(path)
    return idx


def check_odd_one_out(ours, others, min_frac=0.75, min_boards=6):
    """
    Compare each enabled node against the node at the SAME PATH on other
    boards, and report properties most of them declare that we do not.

    Path is the right key, not compatible. Comparing by compatible pits one
    fixed-regulator against every fixed-regulator on every board, which is
    noise; comparing /soc@0/pcie@1c08000/pcie@0 against the same node
    elsewhere is exactly the reasoning that found the missing reset-gpios,
    where 23 of 24 boards declared it and denali did not.

    This is a lead generator, never a defect: boards legitimately differ, and
    the fix is only obvious once you check whether the peers share our
    hardware.
    """
    by_path = defaultdict(dict)
    for board, root in others:
        for nd in walk(root):
            if nd.enabled():
                by_path[nd.path][board] = nd

    for nd in walk(ours):
        if not nd.enabled() or nd.path == "/":
            continue
        # dtc bookkeeping, not hardware
        if nd.path.startswith(("/__symbols__", "/__fixups__", "/__overrides__")):
            continue
        peers = by_path.get(nd.path, {})
        if len(peers) < min_boards:
            continue
        tally = defaultdict(set)
        for b, peer in peers.items():
            for p in peer.props:
                tally[p].add(b)
        for prop, who in sorted(tally.items()):
            if prop in nd.props or prop in IGNORE_PROPS:
                continue
            if len(who) / len(peers) < min_frac:
                continue
            finding("ODD-ONE-OUT", "HINT", nd.path,
                    f"{len(who)}/{len(peers)} boards declare {prop} here; "
                    f"this one does not",
                    ", ".join(sorted(who)[:5]))


# ---------------------------------------------------------------------- main

SEV_ORDER = {"BUG": 0, "SUSPECT": 1, "HINT": 2}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True)
    ap.add_argument("--board", required=True)
    ap.add_argument("--check", default="")
    ap.add_argument("--quiet-hints", action="store_true")
    ap.add_argument("--soc", default="x1e80100")
    args = ap.parse_args()

    dtsdir = os.path.join(args.tree, "arch/arm64/boot/dts/qcom")
    ourdtb = os.path.join(dtsdir, args.board + ".dtb")
    if not os.path.exists(ourdtb):
        sys.exit(f"no such dtb: {ourdtb} (run `make dtbs` first)")

    only = {c.strip() for c in args.check.split(",") if c.strip()}

    def want(k):
        return not only or k in only

    ours = parse_dts(decompile(ourdtb))
    ph = phandle_map(ours)

    if want("REG-GRID"):
        check_reg_grid(ours, rpmh_constraints(args.tree))
    if want("NAME-COUNT"):
        check_name_counts(ours, ph)
    if want("GDSC"):
        check_gdsc(ours, ph, gdsc_names(args.tree, args.soc),
                   clock_id_names(args.tree, args.soc))
    if want("DUP-IRQ") or want("DUP-GPIO"):
        check_duplicates(ours, ph)
    if want("REG-OVER"):
        check_reg_overlap(ours)
    if want("DEAD-REF"):
        check_dead_refs(ours, ph)
    if want("NO-DRIVER"):
        check_no_driver(ours, compatible_index(args.tree))
    if want("DMA-MASTER"):
        cands = set()
        for nd in walk(ours):
            if nd.enabled() and "iommus" not in nd.props:
                cands.update(nd.strings("compatible") or [])
        check_dma_masters(ours, args.tree, compat_file_index(args.tree, sorted(cands)))
    if want("ODD-ONE-OUT"):
        others = []
        for fn in sorted(os.listdir(dtsdir)):
            if not fn.endswith(".dtb") or fn == args.board + ".dtb":
                continue
            if not (fn.startswith("x1e") or fn.startswith("x1p")):
                continue
            # -el2 files are generated overlay variants of a board that is
            # already in the list; counting both double-weights that machine.
            if fn.endswith("-el2.dtb"):
                continue
            try:
                others.append((fn[:-4], parse_dts(decompile(os.path.join(dtsdir, fn)))))
            except Exception:
                pass
        check_odd_one_out(ours, others)

    rows = sorted(FINDINGS, key=lambda f: (SEV_ORDER.get(f[1], 9), f[0], f[2]))
    if args.quiet_hints:
        rows = [r for r in rows if r[1] != "HINT"]

    counts = defaultdict(int)
    for kind, sev, *_ in rows:
        counts[sev] += 1

    print(f"dt-audit: {args.board}")
    print(f"  {counts['BUG']} BUG, {counts['SUSPECT']} SUSPECT, {counts['HINT']} HINT\n")
    last = None
    for kind, sev, path, msg, detail in rows:
        if kind != last:
            print(f"--- {kind} ---")
            last = kind
        print(f"  [{sev}] {path}")
        print(f"         {msg}")
        if detail:
            print(f"         {detail}")
    return 1 if counts["BUG"] else 0


if __name__ == "__main__":
    sys.exit(main())
