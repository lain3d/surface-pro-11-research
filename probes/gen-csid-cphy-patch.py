#!/usr/bin/env python3
"""Tell the CSID that the source is C-PHY.

Debug only, gated behind qcom_camss.csid_cphy.

TARGET: drivers/media/platform/qcom/camss/camss-csid-680.c

This one *is* camss. The CSIPHY patch had to go around camss because on
x1e80100 the DT gives the camss node `phys`/`phy-names`, so camss installs
csiphy_v4l2_ops and never touches the PHY. CSID is different: csid_res_x1e80100[]
declares `.reg = { "csid0" }` and `.interrupt = { "csid0" }`, csid0 takes an
interrupt on every STREAMON, and x1e80100 uses csid_ops_680. So this file is
live code on this SoC.

What it does:

    #define CSI2_RX_CFG0_PHY_TYPE_SEL   24

is declared in camss-csid-680.c, camss-csid-gen2.c and camss-csid-340.c, and is
written by none of them -- grep the whole of drivers/media. __csid_configure_rx()
builds CFG0 from lane count, lane assignment and PHY index and stops there, so
bit 24 is always 0 and the decoder has been told "D-PHY" on every run this
project has ever done, including with the PHY correctly programmed for C-PHY.

This is the fourth instance of one pattern on this hardware: a register field
that mainline defines and never writes. The others were the CSIPHY interrupt
(ISR present, line never requested), the CSIPHY interrupt masks (mask block in
every other SoC's table, absent from x1e80100's) and CSID_CSI2_RX_CAPTURE_CTRL
(three enable bits defined, register never written at all).

Not touched here, deliberately: CAPTURE_CTRL. Its CPHY_PKT_EN looks like a
debug packet-capture path rather than a decode enable, and adding it would be a
second variable in the same run. Worth a look if bit 24 alone does not do it.
"""
import os
import sys

F = ("/root/sp11/wt-cfg/drivers/media/platform/qcom/camss/"
     "camss-csid-680.c")


def main():
    if not os.path.exists(F):
        sys.exit(f"target not found: {F}")
    src = open(F).read()
    if "csid_cphy" in src:
        print("already patched, nothing to do")
        return 0

    # ---- the parameter ----
    anchor = "#define CSID_TOP_IO_PATH_CFG0(csid)"
    assert src.count(anchor) == 1, "top-of-file anchor not unique"
    src = src.replace(anchor, """/*
 * Debug: set CSI2_RX_CFG0_PHY_TYPE_SEL, telling the decoder its source is a
 * C-PHY link rather than a D-PHY one.
 *
 * The field is defined in this file, in camss-csid-gen2.c and in
 * camss-csid-340.c, and no CSID driver in drivers/media writes it. On this
 * machine the sensor is C-PHY -- confirmed on the part, CCS
 * CSI_SIGNALLING_MODE reads 0x03 while streaming -- and the CSIPHY is now
 * programmed for it, but CSID has been decoding as D-PHY throughout.
 *
 * Off by default; nothing changes unless it is set. Gated on the parameter
 * rather than on the SoC because it is an experiment, not a feature: the real
 * fix reads the bus type, which camss currently rejects outright at probe
 * (camss.c, vep.bus_type != V4L2_MBUS_CSI2_DPHY -> -EINVAL).
 */
static bool csid_cphy;
module_param(csid_cphy, bool, 0644);
MODULE_PARM_DESC(csid_cphy, "x1e80100 debug: tell CSID the source is C-PHY");

""" + anchor)

    # ---- set the bit, and report what the register actually holds ----
    old = """	val = (phy->lane_cnt - 1) << CSI2_RX_CFG0_NUM_ACTIVE_LANES;
	val |= phy->lane_assign << CSI2_RX_CFG0_DL0_INPUT_SEL;
	val |= (phy->csiphy_id + CSI2_RX_CFG0_PHY_SEL_BASE_IDX) << CSI2_RX_CFG0_PHY_NUM_SEL;

	writel(val, csid->base + CSID_CSI2_RX_CFG0);
"""
    new = """	val = (phy->lane_cnt - 1) << CSI2_RX_CFG0_NUM_ACTIVE_LANES;
	val |= phy->lane_assign << CSI2_RX_CFG0_DL0_INPUT_SEL;
	val |= (phy->csiphy_id + CSI2_RX_CFG0_PHY_SEL_BASE_IDX) << CSI2_RX_CFG0_PHY_NUM_SEL;

	if (csid_cphy)
		val |= 1 << CSI2_RX_CFG0_PHY_TYPE_SEL;

	writel(val, csid->base + CSID_CSI2_RX_CFG0);

	/*
	 * Read back rather than reporting the computed value. The CSIPHY driver
	 * spent four missions announcing a lane mask that a later table entry
	 * overwrote, so nothing here claims a register holds what we wrote.
	 */
	dev_info(csid->camss->dev,
		 "csid%u: rx cfg0 wrote %08x, reads %08x -- %s, %u lane(s), assign %x, phy %u\\n",
		 csid->id, val, readl(csid->base + CSID_CSI2_RX_CFG0),
		 csid_cphy ? "C-PHY (forced)" : "D-PHY",
		 phy->lane_cnt, phy->lane_assign, phy->csiphy_id);
"""
    assert src.count(old) == 1, "__csid_configure_rx anchor not unique"
    src = src.replace(old, new)

    open(F, "w").write(src)
    print("wrote", F, "- csid_cphy param, PHY_TYPE_SEL, cfg0 read-back")
    return 0


if __name__ == "__main__":
    sys.exit(main())
