#!/usr/bin/env python3
"""Add forced C-PHY lane programming to the Qualcomm CSIPHY driver.

Debug only. Gated behind phy_qcom_mipi_csi2.cphy_force so one module serves both
configurations and the A/B is a sysfs write plus a re-stream, not a reinstall.

TARGET: drivers/phy/qualcomm/phy-qcom-mipi-csi2-3ph-dphy.c

NOT camss. On x1e80100 the camss DT node carries `phys`/`phy-names`, so
`devm_phy_get()` succeeds, camss installs `csiphy_v4l2_ops` rather than the
legacy ops, and `csiphy_lanes_enable()` in camss-csiphy-3ph-1-0.c is never
called -- the CSIPHY is driven by this separate generic-PHY driver instead.
An earlier version of this patch targeted camss and landed entirely on dead
code. The tell was `csiphy_res_x1e80100[]` declaring no .clock, no .reg and no
.interrupt, which is also why there is no csiphy line in /proc/interrupts.

Everything programmed here was recovered from Windows' own CSIPHY driver,
qccammipicsi8380.sys; see data/csiphy-cphy-x1e80100.txt.
"""
import os
import re
import sys

P = "/root/sp11/wt-cfg/drivers/phy/qualcomm"
F = P + "/phy-qcom-mipi-csi2-3ph-dphy.c"
H = P + "/phy-qcom-mipi-csi2.h"
CORE = P + "/phy-qcom-mipi-csi2-core.c"
DATA = "/mnt/c/Users/Crazy/projs/arm64-egpu/data/csiphy-cphy-x1e80100.txt"

# Windows' C-PHY settle thresholds: {max symbol rate MSps, settle count}.
SETTLE_ROWS = [
    (500, 0x66), (600, 0x58), (700, 0x4e), (800, 0x46), (900, 0x40),
    (1000, 0x39), (1100, 0x38), (1200, 0x35), (1300, 0x2f), (1400, 0x2b),
    (1500, 0x2e), (1600, 0x2c), (1700, 0x2a), (1800, 0x29), (1900, 0x28),
    (2000, 0x27), (2100, 0x26), (2200, 0x25), (2300, 0x24), (2400, 0x23),
    (2500, 0x22), (2600, 0x22), (2700, 0x21), (2800, 0x21), (2900, 0x20),
    (3000, 0x20),
]
# per-lane settle-count registers, stride 0x400, odd lanes only
SETTLE_REGS = {0x20c, 0x60c, 0xa0c}

# The nine-entry block Windows writes immediately before the per-frequency
# C-PHY table, recovered from 0x1400119f0. FUN_140006f10 calls the same register
# writer on it -- FUN_140005d00(base, 0x1400119f0, 9) -- only in the C-PHY
# branch; the D-PHY branch goes straight to its table because the mainline
# D-PHY table carries the equivalent inline. lane_regs_x1e80100[] in this driver
# opens with exactly {0x1014, 0xD5}, {0x101C, 0x7A}, {0x1018, 0x01}, the same
# three registers in the same order, so this is the C-PHY analogue of that.
#
# Without it the C-PHY runs left CTRL7 (0x101c) at the 0x02 lanes_enable() writes
# by hand, rather than 0x7a -- the per-frequency table has no 0x101c entry to
# correct it, unlike the D-PHY table.
#
# 0x1014 is the lane mask. The binary stores 0x2a (three trios) and patches it at
# runtime in FUN_140006168; one trio is 0x02.
CPHY_PREAMBLE = [
    (0x1084, 0x00, 0),
    (0x108c, 0x00, 1000),
    (0x02f0, 0x00, 0),
    (0x06f0, 0x00, 0),
    (0x0af0, 0x00, 0),
    (0x1014, 0x02, 0),
    (0x101c, 0x7a, 0),
    (0x1018, 0x01, 0),
    (0x101c, 0x7a, 0),
]

# Windows' CSIPHY interrupt masks, CTRL11..CTRL21, read off the tail of both
# C-PHY per-frequency tables. Byte-identical to the mask block the other SoCs'
# D-PHY tables in this driver already carry; lane_regs_x1e80100[] is the one
# that omits it, which is why lanes_enable() zeroes these and this block has
# never reported anything on x1e80100.
#
# Note these are selective, not 0xff everywhere. The C-PHY table writes them
# itself, so cphy_force must not touch them afterwards.
IRQ_MASKS = [0xff, 0xfe, 0xe6, 0xdf, 0xdf, 0xfc, 0xfb, 0x9b, 0x7f, 0xbf, 0xff]

# Per-lane receiver status, polled by CSIPhyWaitforRx (FUN_140005dd8) until it
# reads zero -- up to 101 x 1 ms, then a further 20 ms settle. Lane block base
# + 0x158, stride 0x400. C-PHY uses the odd lanes, D-PHY the even ones plus clk.
CPHY_LANE_STATUS = [0x358, 0x758, 0xb58]
DPHY_LANE_STATUS = [0x0c4, 0x4c4, 0x8c4, 0xcc4, 0xec4]


def parse_table(marker, expect):
    """Pull one per-frequency table out of the data file as (off, val, ns) rows."""
    src = open(DATA).read().splitlines()
    i = next(n for n, l in enumerate(src) if marker in l and l.startswith("=="))
    rows = []
    for line in src[i + 1:]:
        m = re.match(r"\s+0x([0-9a-f]{4}) = 0x([0-9a-f]+)"
                     r"(?:\s+flag=0x([0-9a-f]+))?", line)
        if not m:
            if line.startswith("=="):
                break
            continue
        rows.append((int(m.group(1), 16), int(m.group(2), 16),
                     int(m.group(3), 16) if m.group(3) else 0))
    if len(rows) != expect:
        sys.exit(f"{marker}: expected {expect} entries, parsed {len(rows)}")
    # Every table ends with CTRL11..CTRL21 then CTRL0. The mask values differ
    # per rate -- table 3 is ff fe e2 df 5f fc fb 8b 7f bf ff, not table 1's --
    # so check the shape, not the bytes.
    want = [0x102c + 4 * k for k in range(11)] + [0x1000]
    if [r[0] for r in rows[-12:]] != want:
        sys.exit(f"{marker}: tail is not the irq mask block + CTRL0")
    return rows


def emit_table(name, comment, rows):
    """Render one table as a C array."""
    out = [comment,
           "static const struct",
           "mipi_csi2phy_lane_regs %s[] = {" % name]

    def emit(off, val, delay_ns):
        # Windows' own conversion, FUN_140005d00: us = ns / 1000, and anything
        # under a microsecond still waits one. Over 50 us it sleeps rather than
        # spinning, which fsleep() on the kernel side does for us.
        us = delay_ns // 1000
        if delay_ns and us == 0:
            us = 1
        p = ("CSIPHY_SETTLE_CNT_LOWER_BYTE" if off in SETTLE_REGS
             else "CSIPHY_DEFAULT_PARAMS")
        out.append("\t{0x%04x, 0x%02x, %d, %s}," % (off, val, us, p))

    for off, val, delay_ns in CPHY_PREAMBLE:
        emit(off, val, delay_ns)
    for off, val, delay_ns in rows:
        emit(off, val, delay_ns)
    out.append("};")
    return "\n".join(out) + "\n"


def lane_table():
    """Build the C array from the extracted Windows table."""
    src = open(DATA).read().splitlines()
    i = next(n for n, l in enumerate(src) if "dataRate < 2.000 Gbps" in l)
    out = [
        "/* 4nm C-PHY, x1e80100, dataRate < 2.0 Gbps. Recovered from",
        " * qccammipicsi8380.sys; see data/csiphy-cphy-x1e80100.txt in arm64-egpu.",
        " * Per-lane blocks repeat at stride 0x400; C-PHY drives the odd lanes only,",
        " * so the settle count lands at 0x20c / 0x60c / 0xa0c.",
        " *",
        " * The first nine entries are the block Windows writes separately, just",
        " * before this table, and are the C-PHY counterpart of the three entries",
        " * lane_regs_x1e80100[] opens with. The tail sets CTRL11..CTRL21 (the irq",
        " * masks) and CTRL0, so nothing afterwards should touch those.",
        " *",
        " * Delays are microseconds. Windows stores them in nanoseconds and this",
        " * is the conversion; an earlier version of this generator copied the raw",
        " * field into a us slot, which turned two 10 ms waits into two 10 s ones",
        " * and put every C-PHY run's stream-on 20 s past the capture timeout. */",
        "static const struct",
        "mipi_csi2phy_lane_regs lane_regs_x1e80100_cphy[] = {",
    ]

    def emit(off, val, delay_ns):
        # Windows' own conversion, FUN_140005d00: us = ns / 1000, and anything
        # under a microsecond still waits one. Over 50 us it sleeps rather than
        # spinning, which fsleep() on the kernel side does for us.
        us = delay_ns // 1000
        if delay_ns and us == 0:
            us = 1
        p = ("CSIPHY_SETTLE_CNT_LOWER_BYTE" if off in SETTLE_REGS
             else "CSIPHY_DEFAULT_PARAMS")
        out.append("\t{0x%04x, 0x%02x, %d, %s}," % (off, val, us, p))

    for off, val, delay_ns in CPHY_PREAMBLE:
        emit(off, val, delay_ns)

    n = 0
    for line in src[i + 1:]:
        m = re.match(r"\s+0x([0-9a-f]{4}) = 0x([0-9a-f]+)"
                     r"(?:\s+flag=0x([0-9a-f]+))?", line)
        if not m:
            if line.startswith("=="):
                break
            continue
        off, val = int(m.group(1), 16), int(m.group(2), 16)
        emit(off, val, int(m.group(3), 16) if m.group(3) else 0)
        n += 1
    out.append("};")
    if n != 123:
        sys.exit(f"expected 123 lane entries, generated {n} -- data file changed?")

    # The masks in the table tail must match what the driver is told they are.
    # last twelve entries are CTRL11..CTRL21 then CTRL0
    tail = out[-13:-1]
    got = [int(re.match(r"\t\{0x10[0-9a-f]{2}, 0x([0-9a-f]+)", t).group(1), 16)
           for t in tail[:11]]
    if got != IRQ_MASKS:
        sys.exit(f"table irq masks {got} != IRQ_MASKS {IRQ_MASKS}")

    return "\n".join(out) + "\n", n + len(CPHY_PREAMBLE)


def main():
    if not os.path.exists(F):
        sys.exit(f"target not found: {F}")
    src = open(F).read()
    if "cphy_force" in src:
        # The lane table is already in. The later steps each guard themselves on
        # the symbol they introduce, so run them anyway -- this is how a mission
        # that only adds one of them gets applied to a tree that already carries
        # the others.
        print("lane table already present, running the later steps only")
        return late_patches()

    tbl, n = lane_table()
    rows = "".join("\t{ %4d, 0x%02x },\n" % (m, s) for m, s in SETTLE_ROWS)

    block = tbl + """
/*
 * Debug: force C-PHY lane programming. The IMX681 on the Surface Pro 11 is put
 * into CSI-2 C-PHY mode by its vendor init table -- CCS CSI_SIGNALLING_MODE
 * (0x0111) reads 0x02 freshly powered and 0x03 once the driver has programmed
 * it, measured on the part. This driver implements D-PHY only, which is why the
 * sensor reports itself streaming and vfe0 has never taken an interrupt.
 *
 * Off by default; nothing changes unless it is set. Gated on the parameter
 * alone rather than on the SoC, because it is an experiment, not a feature.
 *
 * Not static: phy_qcom_mipi_csi2_set_clock_rates() in the core file reads it
 * to pick the 400 MHz timer rate the recovered settle counts assume.
 */
bool cphy_force;
module_param(cphy_force, bool, 0644);
MODULE_PARM_DESC(cphy_force, "x1e80100 debug: force C-PHY lane programming");

/*
 * C-PHY settle count. Windows does not compute this -- on the C-PHY side it is
 * a threshold table keyed on the symbol rate. "First threshold greater than the
 * symbol rate wins."
 */
struct mipi_csi2phy_cphy_settle {
	u32 max_msps;
	u8 settle;
};

static const struct mipi_csi2phy_cphy_settle cphy_settle_x1e80100[] = {
%s};

/*
 * link_freq is the D-PHY DDR convention the DT and camss use, so the bit rate
 * is 2 * link_freq. Windows converts to symbols at 2.28 bits per C-PHY symbol.
 */
static u8 phy_qcom_mipi_csi2_cphy_settle_cnt(s64 link_freq)
{
	u64 msps;
	int i;

	if (link_freq <= 0)
		return 0;

	msps = div_u64((u64)link_freq * 2 * 100, 228);
	msps = div_u64(msps, 1000000);

	for (i = 0; i < ARRAY_SIZE(cphy_settle_x1e80100); i++)
		if (msps < cphy_settle_x1e80100[i].max_msps)
			return cphy_settle_x1e80100[i].settle;

	return cphy_settle_x1e80100[ARRAY_SIZE(cphy_settle_x1e80100) - 1].settle;
}

""" % rows

    anchor = "mipi_csi2phy_lane_regs lane_regs_x1e80100[] = {"
    i = src.index(anchor)
    j = src.rindex("static const struct", 0, i)
    src = src[:j] + block + src[j:]
    print(f"inserted C-PHY lane table ({n} entries) and settle table")

    # gen2_config_lanes: pick the C-PHY table
    old = """	const struct mipi_csi2phy_lane_regs *r = regs->init_seq;
	int i, array_size = regs->lane_array_size;
	u32 val;
"""
    new = """	const struct mipi_csi2phy_lane_regs *r = regs->init_seq;
	int i, array_size = regs->lane_array_size;
	u32 val;

	if (cphy_force) {
		r = lane_regs_x1e80100_cphy;
		array_size = ARRAY_SIZE(lane_regs_x1e80100_cphy);
	}
"""
    # CTRL5 comes from the parameter, not the table's baked-in value, so the
    # one-trio / three-trio question is a sysfs write rather than a rebuild.
    old_c5 = """		default:
			val = r->reg_data;
			break;
		}
"""
    new_c5 = """		default:
			val = r->reg_data;
			break;
		}

		if (cphy_force && r->reg_addr == 0x1014)
			val = cphy_ctrl5;
"""
    assert src.count(old) == 1, "gen2_config_lanes anchor not unique"
    src = src.replace(old, new)
    assert src.count(old_c5) == 1, "gen2_config_lanes default-case anchor not unique"
    src = src.replace(old_c5, new_c5)
    print("gen2_config_lanes selects the C-PHY table, CTRL5 from cphy_ctrl5")

    # The C-PHY table has two 10 ms waits in it, which udelay() would busy-spin
    # inside a driver callback. Windows sleeps anything over 50 us and spins
    # below it; fsleep() makes the same split, and for the D-PHY table -- whose
    # longest wait is 1 us -- it compiles down to the udelay this replaces.
    old = """		if (r->delay_us)
			udelay(r->delay_us);
"""
    new = """		if (r->delay_us)
			fsleep(r->delay_us);
"""
    assert src.count(old) == 1, "udelay anchor not unique"
    src = src.replace(old, new)
    print("gen2_config_lanes sleeps rather than spins for long waits")

    # lanes_enable: settle count
    old = ("	settle_cnt = phy_qcom_mipi_csi2_settle_cnt_calc(cfg->link_freq, "
           "csi2phy->timer_clk_rate);\n")
    new = """	if (cphy_force)
		settle_cnt = phy_qcom_mipi_csi2_cphy_settle_cnt(cfg->link_freq);
	else
		settle_cnt = phy_qcom_mipi_csi2_settle_cnt_calc(cfg->link_freq,
								csi2phy->timer_clk_rate);
"""
    assert src.count(old) == 1, "settle_cnt anchor not unique"
    src = src.replace(old, new)

    # lanes_enable: lane mask. `val` is reused for the CTRL6/7/0 writes further
    # down, so keep a copy for the announcement or it reports the last write
    # rather than the lane mask.
    old = """	u8 settle_cnt;
	u8 val;
	int i;
"""
    new = """	u8 settle_cnt;
	u8 val;
	u8 ctrl5_val;
	int i;
"""
    assert src.count(old) == 1, "lanes_enable declarations anchor not unique"
    src = src.replace(old, new)

    old = """	val = CSIPHY_3PH_CMN_CSI_COMMON_CTRL5_CLK_ENABLE;
	for (i = 0; i < cfg->num_data_lanes; i++)
		val |= BIT(lane_cfg->data[i].pos * 2);
"""
    new = """	if (cphy_force) {
		/*
		 * One C-PHY trio by default. Unlike D-PHY's 0x81 there is no
		 * clock-lane bit -- C-PHY embeds the clock. The table writes
		 * CTRL5 again a few lines below, with the same value; both go
		 * through cphy_ctrl5 so a sysfs write moves them together.
		 */
		val = cphy_ctrl5;
	} else {
		val = CSIPHY_3PH_CMN_CSI_COMMON_CTRL5_CLK_ENABLE;
		for (i = 0; i < cfg->num_data_lanes; i++)
			val |= BIT(lane_cfg->data[i].pos * 2);
	}
	ctrl5_val = val;
"""
    assert src.count(old) == 1, "CTRL5 anchor not unique"
    src = src.replace(old, new)
    print("lanes_enable uses the C-PHY settle count and lane mask")

    # unconditional announcement -- its ABSENCE is what diagnosed the last round,
    # so it prints on both paths and carries timer_clk_rate, which decides
    # whether Windows' settle counts are even in the same units as ours.
    old = "	if (phy_qcom_mipi_csi2_is_gen2(csi2phy))\n"
    new = """	dev_info(csi2phy->dev,
		 "csiphy: %s lanes, settle_cnt 0x%02x, ctrl5 0x%02x, link_freq %lld, timer_clk %u\\n",
		 cphy_force ? "C-PHY (forced)" : "D-PHY",
		 settle_cnt, ctrl5_val, cfg->link_freq, csi2phy->timer_clk_rate);

	if (phy_qcom_mipi_csi2_is_gen2(csi2phy))
"""
    assert src.count(old) == 1, "gen2 dispatch anchor not unique"
    src = src.replace(old, new)
    print("added the unconditional path announcement")

    open(F, "w").write(src)
    print("wrote", F)

    # ---- header: export cphy_force to the core file (same module) ----
    hdr = open(H).read()
    if "cphy_force" not in hdr:
        anchor = "struct mipi_csi2phy_clk_freq {"
        assert hdr.count(anchor) == 1, "header anchor not unique"
        hdr = hdr.replace(anchor,
                          "/* debug: force C-PHY lane programming, "
                          "defined in phy-qcom-mipi-csi2-3ph-dphy.c */\n"
                          "extern bool cphy_force;\n\n" + anchor)
        open(H, "w").write(hdr)
        print("wrote", H)

    # ---- core: take the top timer rate when forcing C-PHY ----
    #
    # Windows' CSIPHY driver computes settle counts against a 2.5 ns tick --
    # a 400 MHz timer -- so the recovered C-PHY table is in those units. The
    # default pick lands on 266666667 here because link_freq/4 plus the 5%
    # margin is 262080000, 1.7% short of it, and 0x40 then means 240 ns of
    # settle instead of the intended 160 ns.
    #
    # Taking the top entry is already an established move in this very
    # function -- see the min_rate == 0 case immediately below.
    core = open(CORE).read()
    if "cphy_force" not in core:
        old = """		if (min_rate == 0)
			j = clk_freq->num_freq - 1;
"""
        new = """		/*
		 * cphy_force: the recovered C-PHY settle counts are in 2.5 ns
		 * ticks, i.e. a 400 MHz timer. The default pick lands one
		 * entry low here, which stretches every settle by 1.5x.
		 */
		if (min_rate == 0 || cphy_force)
			j = clk_freq->num_freq - 1;
"""
        assert core.count(old) == 1, "core clock-pick anchor not unique"
        core = core.replace(old, new)

        # ---- timer_400: the same clock change, independent of cphy_force ----
        #
        # Asked for by the Linux side as run C. At 400 MHz this driver's own
        # D-PHY formula should yield 0x1d, which is what Windows' D-PHY formula
        # yields for this link -- so it checks that the two stacks agree about
        # settle arithmetic, independently of anything C-PHY.
        old = "	if (min_rate == 0 || cphy_force)\n"
        new = "	if (min_rate == 0 || cphy_force || timer_400)\n"
        assert core.count(old.replace("\t", "\t\t")) == 1
        core = core.replace(old.replace("\t", "\t\t"), new.replace("\t", "\t\t"))

        anchor = "#define CAMSS_CLOCK_MARGIN_NUMERATOR 105"
        assert core.count(anchor) == 1, "core margin anchor not unique"
        core = core.replace(anchor, """/*
 * Debug: take the top CSIPHY timer rate regardless of C-PHY. Independent of
 * cphy_force so D-PHY at 400 MHz can be measured on its own -- this driver
 * should then produce settle_cnt 0x1d, matching Windows' D-PHY formula for the
 * same link, which checks that both stacks agree about settle arithmetic.
 */
static bool timer_400;
module_param(timer_400, bool, 0644);
MODULE_PARM_DESC(timer_400, "x1e80100 debug: force the 400 MHz CSIPHY timer");

""" + anchor)

        # ---- request the CSIPHY interrupt ----
        #
        # The DT routes it, the driver has an ISR and wires it into the ops
        # struct -- and nothing ever asked for the line, so the hardware's own
        # error reporting has never been connected to anything.
        if "#include <linux/interrupt.h>" not in core:
            core = core.replace("#include <linux/platform_device.h>",
                                "#include <linux/interrupt.h>\n"
                                "#include <linux/platform_device.h>")

        old = """	csi2phy->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(csi2phy->base))
		return PTR_ERR(csi2phy->base);
"""
        new = """	csi2phy->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(csi2phy->base))
		return PTR_ERR(csi2phy->base);

	/*
	 * The CSIPHY interrupt: the DT routes it and ops->isr decodes it, but
	 * nothing ever requested the line, so the block's own error reporting
	 * has never reached anyone. lanes_enable() masks every source unless
	 * cphy_force is set, so on the default path this changes nothing.
	 */
	ret = platform_get_irq(pdev, 0);
	if (ret < 0) {
		dev_warn(dev, "no CSIPHY irq, error reporting stays off: %d\\n",
			 ret);
	} else {
		csi2phy->irq = ret;
		ret = devm_request_irq(dev, csi2phy->irq,
				       csi2phy->soc_cfg->ops->isr, 0,
				       dev_name(dev), csi2phy);
		if (ret) {
			dev_warn(dev, "CSIPHY irq %d request failed: %d\\n",
				 csi2phy->irq, ret);
			csi2phy->irq = 0;
		} else {
			dev_info(dev, "CSIPHY irq %d requested\\n",
				 csi2phy->irq);
		}
	}
"""
        assert core.count(old) == 1, "core ioremap anchor not unique"
        core = core.replace(old, new)

        open(CORE, "w").write(core)
        print("wrote", CORE, "- top timer rate, timer_400 param, irq requested")

    # ---- header: irq field ----
    hdr = open(H).read()
    if "int irq;" not in hdr:
        anchor = "	u32 timer_clk_rate;\n"
        assert hdr.count(anchor) == 1, "header timer_clk_rate anchor not unique"
        hdr = hdr.replace(anchor, anchor + "	int irq;\n")
        open(H, "w").write(hdr)
        print("wrote", H, "- irq field")

    return late_patches()


def late_patches():
    """Everything after the lane table. Each step guards on the symbol it adds,
    so this is idempotent and a tree carrying only some of them catches up.

    There used to be a second copy of this list on main()'s already-patched
    path, and adding a step to one and not the other made the step silently
    never run on the tree that actually needed it."""
    patch_isr()
    patch_reset()
    patch_datarate()
    return 0


def patch_datarate():
    """Feed the settle lookup and the table choice the real C-PHY data rate.

    Measured 2026-08-07 out of Windows' own CsiTestMode dump, from a working
    front-camera session: Csi2DataRateKbps = 5,485,700, i.e. 5.4857 Gbps.

    That reconciles exactly with the sensor's recovered PLL registers. EXTCLK is
    19.2 MHz; modes 1-5 set op_pre_pll_clk_div 3 and op_pll_multiplier 375, so
    op_sys_clk = 2400.0 MHz, and 5,485,700,000 / 2,400,000,000 = 16/7 to five
    figures. So op_sys_clk *is* the C-PHY symbol rate and the data rate is
    symbols x 16/7, C-PHY carrying 16 bits per 7 symbols. Two independent
    sources -- the vendor blob and the live link -- agreeing, which also settles
    imx681.c's UNVERIFIED assumption that op_sys_clk_div is 1.

    imx681.c's link_freq_menu_items are therefore HALF the symbol rate: the
    D-PHY DDR convention applied to a C-PHY sensor. cphy_settle_cnt() doubled
    that back to 1996.8 and then divided by 2.28 as if it were a bit rate,
    landing on 875.8 MSps -- 36 % of the truth -- which picked settle 0x40 (64)
    where mode 0 wants 0x26 (38), out of the < 2.0 Gbps table where mode 0 wants
    the >= 2.5 Gbps one.

    So every C-PHY run so far ran the wrong register table with a settle window
    68 % too long. That is a complete account of a receiver that never locks and
    syncs by accident a couple of dozen times a minute.

    Fixing it in imx681.c would change what camss and the clock code see as
    well; here the derivation is local to the PHY and cphy_datarate_kbps
    overrides it outright, so the corrected value is one sysfs write.
    """
    src = open(F).read()
    if "cphy_datarate_kbps" in src:
        return

    t2 = parse_table("dataRate < 2.500 Gbps", 123)
    t3 = parse_table("dataRate >= 2.500 Gbps", 121)

    tables = emit_table(
        "lane_regs_x1e80100_cphy_2g5",
        "/* 4nm C-PHY, x1e80100, 2.0 Gbps <= dataRate < 2.5 Gbps. */",
        t2) + "\n" + emit_table(
        "lane_regs_x1e80100_cphy_hi",
        "/* 4nm C-PHY, x1e80100, dataRate >= 2.5 Gbps -- the one IMX681 needs on\n"
        " * every mode. Its irq mask block differs from the other two tables\n"
        " * (ff fe e2 df 5f fc fb 8b 7f bf ff), which is why the masks are\n"
        " * validated by shape rather than by value. */",
        t3) + "\n"

    anchor = "/* 4nm C-PHY, x1e80100, dataRate < 2.0 Gbps. Recovered from"
    assert src.count(anchor) == 1, "cphy table comment anchor not unique"
    src = src.replace(anchor, tables + anchor)

    helper = """/*
 * Windows' dataRate, in bits per second. See the settle table's own comment:
 * the lookup is keyed on the bit rate, not the symbol rate.
 *
 * link_freq here is imx681.c's link_freq_menu_items entry, which is half the
 * C-PHY symbol rate -- the driver applied the D-PHY DDR convention to a C-PHY
 * sensor. Doubling recovers op_sys_clk, which is the symbol rate, and C-PHY
 * carries 16 bits per 7 symbols.
 *
 * mode 0 (4032x3024): op_sys_clk 1996.8 MHz -> 4.564 Gbps.
 * modes 1-5:          op_sys_clk 2400.0 MHz -> 5.4857 Gbps, which is exactly
 *                     what Windows recorded for a working link.
 */
static u32 cphy_datarate_kbps;
module_param(cphy_datarate_kbps, uint, 0644);
MODULE_PARM_DESC(cphy_datarate_kbps,
		 "x1e80100 debug: C-PHY data rate in kbps (0 = derive from link_freq)");

static u64 phy_qcom_mipi_csi2_cphy_datarate(s64 link_freq)
{
	if (cphy_datarate_kbps)
		return (u64)cphy_datarate_kbps * 1000;
	if (link_freq <= 0)
		return 0;

	return div_u64((u64)link_freq * 2 * 16, 7);
}

/*
 * Windows picks one of three tables by data rate, splitting at 2.0 and 2.5
 * Gbps. Every C-PHY run before this used the first unconditionally.
 */
static const struct mipi_csi2phy_lane_regs *
phy_qcom_mipi_csi2_cphy_table(s64 link_freq, int *n)
{
	u64 bps = phy_qcom_mipi_csi2_cphy_datarate(link_freq);

	if (bps < 2000000001ULL) {
		*n = ARRAY_SIZE(lane_regs_x1e80100_cphy);
		return lane_regs_x1e80100_cphy;
	}
	if (bps < 2500000001ULL) {
		*n = ARRAY_SIZE(lane_regs_x1e80100_cphy_2g5);
		return lane_regs_x1e80100_cphy_2g5;
	}
	*n = ARRAY_SIZE(lane_regs_x1e80100_cphy_hi);
	return lane_regs_x1e80100_cphy_hi;
}

"""
    anchor = "static u8 phy_qcom_mipi_csi2_cphy_settle_cnt(s64 link_freq)\n{"
    assert src.count(anchor) == 1, "settle_cnt anchor not unique"
    src = src.replace(anchor, helper + anchor)

    # The lookup itself: Windows' formula, on the real bit rate. Keep its 2.28
    # rather than the exact 16/7 -- the goal is to reproduce a configuration
    # that works, and the two differ by enough to cross a row of the table.
    old = """	u64 msps;
	int i;

	if (link_freq <= 0)
		return 0;

	msps = div_u64((u64)link_freq * 2 * 100, 228);
	msps = div_u64(msps, 1000000);
"""
    new = """	u64 bps = phy_qcom_mipi_csi2_cphy_datarate(link_freq);
	u64 msps;
	int i;

	if (!bps)
		return 0;

	msps = div_u64(bps * 100, 228);
	msps = div_u64(msps, 1000000);
"""
    assert src.count(old) == 1, "settle_cnt body anchor not unique"
    src = src.replace(old, new)

    old = """	if (cphy_force) {
		r = lane_regs_x1e80100_cphy;
		array_size = ARRAY_SIZE(lane_regs_x1e80100_cphy);
	}
"""
    new = """	if (cphy_force) {
		r = phy_qcom_mipi_csi2_cphy_table(csi2phy->stream_cfg.link_freq,
						  &array_size);
		dev_info(csi2phy->dev, "csiphy: C-PHY table %s, %d entries\\n",
			 r == lane_regs_x1e80100_cphy     ? "< 2.0 Gbps" :
			 r == lane_regs_x1e80100_cphy_2g5 ? "< 2.5 Gbps" :
							   ">= 2.5 Gbps",
			 array_size);
	}
"""
    assert src.count(old) == 1, "gen2 table-select anchor not unique"
    src = src.replace(old, new)

    old = """		 "csiphy: %s lanes, settle_cnt 0x%02x, ctrl5 0x%02x, link_freq %lld, timer_clk %u\\n",
		 cphy_force ? "C-PHY (forced)" : "D-PHY",
		 settle_cnt, ctrl5_val, cfg->link_freq, csi2phy->timer_clk_rate);
"""
    new = """		 "csiphy: %s lanes, settle_cnt 0x%02x, ctrl5 0x%02x, link_freq %lld, datarate %llu kbps, timer_clk %u\\n",
		 cphy_force ? "C-PHY (forced)" : "D-PHY",
		 settle_cnt, ctrl5_val, cfg->link_freq,
		 div_u64(phy_qcom_mipi_csi2_cphy_datarate(cfg->link_freq), 1000),
		 csi2phy->timer_clk_rate);
"""
    assert src.count(old) == 1, "lanes_enable dev_info anchor not unique"
    src = src.replace(old, new)

    open(F, "w").write(src)
    print("wrote", F, "- three C-PHY tables, real data rate, corrected settle lookup")


def patch_reset():
    """Run Windows' CSIDPhyReset before the lane configuration.

    Two gaps, found 2026-08-07 in FUN_140006028 and confirmed against the
    restored source:

      1. This driver's own phy_qcom_mipi_csi2_reset() is in the ops struct and
         *nothing ever calls it*. phy_qcom_mipi_csi2_power_on() goes
         hw_version_read -> lanes_enable. So on x1e80100 the CSIPHY has never
         been reset at all, on either path.

      2. Even that function only does the common CTRL0 pulse. Windows follows it
         with a per-lane pulse that appears nowhere in this driver:
             C-PHY  0x025c / 0x065c / 0x0a5c   0x10 -> 0x00
             D-PHY  0x0e18 / 0x0018 / 0x0418 / 0x0818 / 0x0c18   0x01 -> 0x00
         Note the C-PHY registers are on the odd (trio) blocks at offset 0x5c,
         a different register from the D-PHY one, and carry a different value.
         Mainline touches 0x?05c only as CSIPHY_SKEW_CAL on the even blocks,
         which gen2_config_lanes() skips.

    That makes an unreset trio receiver a live candidate for a link that never
    locks but occasionally syncs by accident -- which is what mission 11
    measured: 23 packets in 113 s, half of them failing CRC, against the ~2
    million a 6 fps stream should have delivered.

    Off by default so run G is repeatable and the reset is a clean A/B.
    """
    src = open(F).read()
    if "win_reset" in src:
        return

    fn = """/*
 * Windows' CSIDPhyReset, FUN_140006028 in qccammipicsi8380.sys. Runs between
 * the RefGen check and the per-frequency table, i.e. before anything this
 * driver's lanes_enable() writes.
 *
 * The existing phy_qcom_mipi_csi2_reset() below covers only the first of these
 * two pulses, and is dead code -- power_on() never calls ->reset.
 */
static const u16 csiphy_reset_lanes_cphy[] = { 0x025c, 0x065c, 0x0a5c };
static const u16 csiphy_reset_lanes_dphy[] = {
	0x0e18, 0x0018, 0x0418, 0x0818, 0x0c18,
};

static bool win_reset;
module_param(win_reset, bool, 0644);
MODULE_PARM_DESC(win_reset, "x1e80100 debug: run Windows' CSIPHY reset before lane config");

static void phy_qcom_mipi_csi2_windows_reset(struct mipi_csi2phy_device *csi2phy)
{
	const struct mipi_csi2phy_device_regs *regs = csi2phy_dev_to_regs(csi2phy);
	const u16 *lane = cphy_force ? csiphy_reset_lanes_cphy
				     : csiphy_reset_lanes_dphy;
	int n = cphy_force ? ARRAY_SIZE(csiphy_reset_lanes_cphy)
			   : ARRAY_SIZE(csiphy_reset_lanes_dphy);
	u32 val = cphy_force ? 0x10 : 0x01;
	int i;

	/* common. Windows waits 20 ns here, not the 5-8 ms below. */
	writel_relaxed(0x1, csi2phy->base +
		       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, 0));
	ndelay(20);
	writel_relaxed(0x0, csi2phy->base +
		       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, 0));

	for (i = 0; i < n; i++) {
		writel_relaxed(val, csi2phy->base + lane[i]);
		ndelay(100);
		writel_relaxed(0x0, csi2phy->base + lane[i]);
	}

	dev_info(csi2phy->dev,
		 "csiphy: reset -- common CTRL0, then %d %s blocks pulsed 0x%02x\\n",
		 n, cphy_force ? "C-PHY trio" : "D-PHY lane", val);
}

"""
    anchor = "static int phy_qcom_mipi_csi2_lanes_enable(struct mipi_csi2phy_device *csi2phy,"
    assert src.count(anchor) == 1, "lanes_enable anchor not unique"
    src = src.replace(anchor, fn + anchor)

    # Call it, and read the RefGen bit -- unconditionally, because it costs one
    # readl and it is the one reading nobody has ever taken.
    old = """	if (cphy_force)
		settle_cnt = phy_qcom_mipi_csi2_cphy_settle_cnt(cfg->link_freq);
"""
    new = """	/*
	 * STATUS19 bit 7 is "RefGen Ready". Windows checks it by that name
	 * immediately before starting the PHY and logs "RefGen is Not Ready"
	 * when it is clear. It starts anyway, so it is diagnostic rather than a
	 * gate -- but nothing in Linux has ever read it, and a reference
	 * generator that is not up is a complete explanation for a receiver
	 * that never locks. Unconditional: it costs one readl and it is valid
	 * on every path.
	 */
	status19 = readl_relaxed(csi2phy->base +
				 CSIPHY_3PH_CMN_CSI_COMMON_STATUSn(regs->offset, 19));
	dev_info(csi2phy->dev, "csiphy: status19 %08x -- RefGen %s\\n",
		 status19, (status19 & BIT(7)) ? "Ready" : "NOT READY");

	if (win_reset)
		phy_qcom_mipi_csi2_windows_reset(csi2phy);

	if (cphy_force)
		settle_cnt = phy_qcom_mipi_csi2_cphy_settle_cnt(cfg->link_freq);
"""
    assert src.count(old) == 1, "settle_cnt anchor not unique"
    src = src.replace(old, new)

    old = """	u8 settle_cnt;
	u8 val;
	u8 ctrl5_val;
	int i;
"""
    new = """	u8 settle_cnt;
	u8 val;
	u8 ctrl5_val;
	u32 status19;
	int i;
"""
    assert src.count(old) == 1, "lanes_enable decl anchor not unique"
    src = src.replace(old, new)

    open(F, "w").write(src)
    print("wrote", F, "- win_reset param, Windows reset sequence, RefGen read")


def patch_isr():
    """Make the ISR report what it read, and stop it running away.

    The handler already acks correctly, so a storm is unlikely -- but an
    unmasked PHY interrupt on hardware nobody has run this way before is
    exactly where a hard hang would come from, and a hang here costs a
    power-cycle on a machine whose boot is already intermittent.
    """
    src = open(F).read()
    if "csiphy_irq_count" in src:
        return

    old = """	const struct mipi_csi2phy_device *csi2phy = dev;
	const struct mipi_csi2phy_device_regs *regs = csi2phy_dev_to_regs(csi2phy);
	int i;

	for (i = 0; i < 11; i++) {
		int c = i + 22;
		u8 val = readl_relaxed(csi2phy->base +
				       CSIPHY_3PH_CMN_CSI_COMMON_STATUSn(regs->offset, i));

		writel_relaxed(val, csi2phy->base +
			       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, c));
	}
"""
    new = """	const struct mipi_csi2phy_device *csi2phy = dev;
	const struct mipi_csi2phy_device_regs *regs = csi2phy_dev_to_regs(csi2phy);
	u8 status[11];
	bool any = false;
	int i;

	for (i = 0; i < 11; i++) {
		int c = i + 22;
		u8 val = readl_relaxed(csi2phy->base +
				       CSIPHY_3PH_CMN_CSI_COMMON_STATUSn(regs->offset, i));

		status[i] = val;
		if (val)
			any = true;

		writel_relaxed(val, csi2phy->base +
			       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, c));
	}

	/*
	 * Report rather than silently ack. This is the whole point of wiring
	 * the line up: a flat vfe0 says nothing about where the link fails,
	 * and these eleven words are the block's own account of it.
	 *
	 * Printed in register order, STATUS0..STATUS10. Windows' own handler
	 * (MipiCsiCallback) reads the same eleven and keeps four of them by
	 * name: STATUS1, 3, 6 and 8 are its Csi2CommonStatus1/3/6/8, so those
	 * are the four positions worth reading first.
	 */
	if (any) {
		dev_warn_ratelimited(csi2phy->dev,
				     "csiphy irq: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\\n",
				     status[0], status[1], status[2], status[3],
				     status[4], status[5], status[6], status[7],
				     status[8], status[9], status[10]);

		/*
		 * The other half of the lane-status reading, which the previous
		 * build defined and never called. Here is where it means
		 * something: the sensor is transmitting, so this is the state
		 * Windows' CSIPhyWaitforRx would be polling.
		 */
		phy_qcom_mipi_csi2_report_lane_status(csi2phy, "irq", true);
	}

	/*
	 * Runaway guard. The ack sequence below looks correct, but this line
	 * has never been enabled on this hardware and a screaming irq would
	 * cost a power cycle. Mask everything and say so, once.
	 */
	if (atomic_inc_return(&csiphy_irq_count) > CSIPHY_IRQ_STORM_LIMIT) {
		for (i = 11; i < 22; i++)
			writel_relaxed(0, csi2phy->base +
				       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, i));
		dev_err_ratelimited(csi2phy->dev,
				    "csiphy irq storm past %d, masking all sources\\n",
				    CSIPHY_IRQ_STORM_LIMIT);
	}
"""
    assert src.count(old) == 1, "ISR anchor not unique"
    src = src.replace(old, new)

    # counter, limit, masks, lane-status reporter -- all above the ISR
    anchor = "static irqreturn_t phy_qcom_mipi_csi2_isr(int irq, void *dev)"
    assert src.count(anchor) == 1
    masks = ", ".join("0x%02x" % m for m in IRQ_MASKS)
    cphy_ls = ", ".join("0x%03x" % r for r in CPHY_LANE_STATUS)
    dphy_ls = ", ".join("0x%03x" % r for r in DPHY_LANE_STATUS)
    src = src.replace(anchor, """#define CSIPHY_IRQ_STORM_LIMIT 5000
static atomic_t csiphy_irq_count = ATOMIC_INIT(0);

/*
 * Debug: apply Windows' interrupt masks on the D-PHY path too. Independent of
 * cphy_force, because without a D-PHY run that reports, there is no baseline
 * for what a C-PHY run reports and the result is one-sided.
 */
static bool irq_unmask;
module_param(irq_unmask, bool, 0644);
MODULE_PARM_DESC(irq_unmask, "x1e80100 debug: unmask CSIPHY irq sources on D-PHY");

/*
 * CTRL11..CTRL21, read off the tail of Windows' C-PHY per-frequency tables and
 * byte-identical to the mask block the other SoCs' tables in this file carry.
 * Selective, not 0xff everywhere.
 */
static const u8 csiphy_irq_masks_x1e80100[] = {
	%s,
};

/*
 * Per-lane receiver status, lane block + 0x158 at stride 0x400. Windows polls
 * these until zero in CSIPhyWaitforRx before it calls the link up; C-PHY drives
 * the odd lanes, D-PHY the even ones plus the clock lane.
 */
static const u16 csiphy_lane_status_cphy[] = { %s };
static const u16 csiphy_lane_status_dphy[] = { %s };

/*
 * Debug: the C-PHY lane mask written to CTRL5 (0x1014).
 *
 * 0x02 is one trio, and it is what Windows programs: CSIPhyRxLane derives the
 * mask from nNumOfDataLane, and the IMX681's chromatix resolutionData gives
 * laneCount 1 -- cross-checked against 2 for the OV02C10 and 4 for the OV13858,
 * both independently known. The binary's static table entry is 0x2a because
 * that is the three-trio default it patches over at runtime.
 *
 * Exposed anyway. Two of three trios being disabled is a sufficient explanation
 * for a link that never assembles, and 0x2a costs one sysfs write to rule out.
 * 0x02 = trio 0, 0x0a = trios 0-1, 0x2a = trios 0-2.
 */
static u8 cphy_ctrl5 = 0x02;
module_param(cphy_ctrl5, byte, 0644);
MODULE_PARM_DESC(cphy_ctrl5, "x1e80100 debug: C-PHY lane mask for CTRL5 (default 0x02, one trio)");

static void
phy_qcom_mipi_csi2_report_lane_status(const struct mipi_csi2phy_device *csi2phy,
				      const char *when, bool rl)
{
	const u16 *r = cphy_force ? csiphy_lane_status_cphy
				  : csiphy_lane_status_dphy;
	int n = cphy_force ? ARRAY_SIZE(csiphy_lane_status_cphy)
			   : ARRAY_SIZE(csiphy_lane_status_dphy);
	u32 v[ARRAY_SIZE(csiphy_lane_status_dphy)] = {};
	u32 ctrl5;
	int i;

	for (i = 0; i < n; i++)
		v[i] = readl_relaxed(csi2phy->base + r[i]);

	/*
	 * Read CTRL5 back rather than reporting what we meant to write. The
	 * D-PHY path announces 0x81 from the DT and the table then writes 0xD5
	 * over it, so the computed value and the live register disagree.
	 */
	ctrl5 = readl_relaxed(csi2phy->base + 0x1014);

	/* zero on every lane is what Windows waits for */
	if (rl)
		dev_info_ratelimited(csi2phy->dev,
			 "csiphy lane status (%%s): %%08x %%08x %%08x %%08x %%08x [%%d lanes, ctrl5 %%02x]\\n",
			 when, v[0], v[1], v[2], v[3], v[4], n, ctrl5);
	else
		dev_info(csi2phy->dev,
			 "csiphy lane status (%%s): %%08x %%08x %%08x %%08x %%08x [%%d lanes, ctrl5 %%02x]\\n",
			 when, v[0], v[1], v[2], v[3], v[4], n, ctrl5);
}

""" % (masks, cphy_ls, dphy_ls) + anchor)

    # ---- irq masks ----
    #
    # Mission 8 ran with 0xff written to all eleven, which was wrong twice over:
    # it is not what Windows programs, and under cphy_force it overwrote the
    # correct values the C-PHY table had just written. Windows' set is selective
    # and lives in the table tail; irq_unmask applies the same set on the D-PHY
    # path so the two are directly comparable.
    old = """	/* IRQ_MASK registers - disable all interrupts */
	for (i = 11; i < 22; i++) {
		writel_relaxed(0, csi2phy->base +
			       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, i));
	}
"""
    new = """	/*
	 * IRQ_MASK registers, CTRL11..CTRL21. Stock behaviour is to disable
	 * every source, which is why this block has never reported anything on
	 * x1e80100 -- the other SoCs' tables here carry a mask block and
	 * lane_regs_x1e80100[] is the one that does not.
	 *
	 * Under cphy_force the C-PHY table has already written Windows' masks
	 * (and CTRL0) a few lines above, so leave them alone; writing anything
	 * here would clobber them. irq_unmask applies the same set on the D-PHY
	 * path, which is the control for what the C-PHY run reports.
	 */
	if (cphy_force) {
		atomic_set(&csiphy_irq_count, 0);
		dev_info(csi2phy->dev,
			 "csiphy: irq masks left as the C-PHY table set them\\n");
	} else if (irq_unmask) {
		atomic_set(&csiphy_irq_count, 0);
		for (i = 0; i < ARRAY_SIZE(csiphy_irq_masks_x1e80100); i++) {
			writel_relaxed(csiphy_irq_masks_x1e80100[i],
				       csi2phy->base +
				       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset,
								       11 + i));
		}
		dev_info(csi2phy->dev, "csiphy: irq sources unmasked (D-PHY)\\n");
	} else {
		for (i = 11; i < 22; i++) {
			writel_relaxed(0, csi2phy->base +
				       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, i));
		}
	}

	/*
	 * Per-lane receiver status. Windows polls these until they read zero
	 * before it calls the link up (CSIPhyWaitforRx), and nothing in this
	 * driver has ever looked at them. Reported once here, with the sensor
	 * not yet streaming, as the baseline for what the ISR reports later.
	 */
	if (cphy_force || irq_unmask)
		phy_qcom_mipi_csi2_report_lane_status(csi2phy, "programmed", false);
"""
    assert src.count(old) == 1, "IRQ_MASK anchor not unique"
    src = src.replace(old, new)

    open(F, "w").write(src)
    print("wrote", F, "- ISR reports, storm guard, unmask under cphy_force")


if __name__ == "__main__":
    sys.exit(main())
