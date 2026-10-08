# Current state, expected behaviour, and the plan to unblock

Written 2026-08-02, after the ACPI/blob work closed everything that was
answerable from Windows.

## The thing to know first

**The ISO that exists cannot answer the USB4 or camera questions.** It was built
at 00:47 on 2026-08-02, before any of the four feature branches were written. Its
kernel has `CONFIG_USB4` unset, no sensor drivers, and a DTB
without the new nodes.

```
/home/lain/sp11-out/surface-pro-11-ubuntu.iso      4.14 GB, never booted
kernel 7.1.3-sp11-gd81a425b872a-dirty
grub: devicetree /dtb/qcom/x1e80100-microsoft-denali-oled.dtb
```

| Symbol | In the ISO kernel |
|---|---|
| `CONFIG_USB4` | **not set** |
| `CONFIG_CLK_X1E80100_CAMCC` | `m` — **already present**, see correction below |
| `CONFIG_VIDEO_OV13858` | **not set** |
| `CONFIG_VIDEO_IMX681` | **absent** (driver not in that tree) |
| `CONFIG_VIDEO_QCOM_CAMSS` | `m` |
| `CONFIG_I2C_QCOM_CCI` | `m` |
| `CONFIG_I2C_CHARDEV`, `MEDIA_CONTROLLER`, `V4L2_SUBDEV_API` | `y` |
| `CONFIG_SPI_HID` | `y` |
| `CONFIG_UCSI_PMIC_GLINK` | `m` |

Booting it is still worth doing — see phase 0 — but it answers one of the three
pillars, not three.

### Correction: the camera clock controller was never missing

Earlier revisions of this document listed `CONFIG_QCOM_CAMCC_X1E80100` as unset.
**That symbol does not exist** — I invented the name, then read "absent from
config" as evidence and reported the camera clock controller as missing from the
ISO kernel.

The real symbol is `CONFIG_CLK_X1E80100_CAMCC`. It is annotated `y` and is
**already built as a module** in the shipped kernel. The camera gap is therefore
smaller than stated above: the two sensor drivers and the DT enables, nothing
else.

Same class of error as `vts_def` — a plausible-looking identifier that was never
checked against the tree. The lesson is the one in
`design/kernel-dev-strategy.md`: a symbol name is a constant like any other, and
`grep` is the check.

### The baseline is preserved

Before any rebuild touches that directory, the pre-change image and its kernel
packages are copied, verified and write-protected:

```
/home/lain/sp11-out/baseline/
    surface-pro-11-ubuntu-BASELINE-20260802-gd81a425b872a.iso
    linux-image-7.1.3-sp11-gd81a425b872a-dirty_...deb
    linux-headers-7.1.3-sp11-gd81a425b872a-dirty_...deb
    SHA256SUMS
    README
```

sha256 `0b1e0d23…a42788`, confirmed identical to the original after copying,
mode `444` with the immutable bit set. `sha256sum -c SHA256SUMS` re-verifies all
three.

This is not only insurance. It is the **control**: when an instrumented build
misbehaves, booting the baseline is what distinguishes "the new patches broke it"
from "it never worked here". Keep it, and give every new build a new filename
rather than rebuilding over `surface-pro-11-ubuntu.iso`.

One piece of good news underneath that: the four branches share base
`18b0b569c`, and **that tree is byte-identical to `d81a425b8`, the commit the ISO
kernel was built from.** They are different hashes because of a CRLF replay, not
different content (`git diff` between them is empty). So the branches compose
onto exactly what shipped — no rebase, no conflict archaeology.

## Where each pillar stands

### USB4 — built, unproven, and the risk is downstream of my work

`lain3d/surface-pro-11-kernel#3`, 6 commits, draft.

`tb_nhi` gained `struct device *dev` and `int irq`; the PCI-specific paths are
guarded; `nhi_probe_common()` is split out and a platform driver added; three
`usb4@` nodes are in `hamoa.dtsi` with a dt-binding that passes `dtbs_check`.
Module and DTB build clean at `W=1`, and all 34 `nhi->pdev` dereferences have
been audited against the NULL-pdev path.

What is already in this tree and does *not* need writing: `phy-qcom-qmp-combo`
has `x1e80100_usb43dp_*` init tables, and the DSDT exposes a UCSI controller
(`USBC000`) with three connectors.

**Gap found while writing this:** only `&usb4_0` is set `status = "okay"` in
`x1-microsoft-denali.dtsi`. Routers 1 and 2 are still disabled, so as it stands
one of three ports is testable, and it is not established which physical port
router 0 is.

### Camera — everything but one number

Three PRs: `#1` ov13858 DT probing, `#2` PM8010 PMIC, `#4` the IMX681 driver.

The board wiring is fully derived (see `docs/camera-sensors.md`): front IMX681 on
`cci1 i2c-bus@1`, MCLK on gpio100 under pinmux function `cam_aon` (not
`cam_mclk`), reset gpio237, avdd LDO7_B 2.8 V, dovdd LDO3_M 1.8 V. The register
tables cross-validate against mainline `ov13858.c` at 508/558 with all divergence
clustered in the crop block.

The platform side is already supported in-tree and only needs enabling:
`camcc-x1e80100.c` exists, `cci0`/`cci1` carry `qcom,x1e80100-cci`, `camss.c`
matches `qcom,x1e80100-camss`, and `csiphy0/1/2/4` are present — all
`status = "disabled"` at SoC level.

Missing: the sensor's I2C address, which is provably not in the firmware, and
the Bayer order, which is provably not in any blob.

### Multi-touch — baseline should already work; the heat map is a userspace project

`CONFIG_SPI_HID=y` and the touchscreen node are already in the shipped ISO
kernel, so pen and touch are expected to work on first boot with no new code.

The 7488-byte full-frame heat-map report exists (46 × 68, one byte per cell,
confirmed twice). What does not exist is any kernel consumer for a HUTRR87
capacitive heat-map digitizer — `iptsd` solves the same problem but is bound to
Intel IPTS, not this HID usage. So this pillar is not blocked on reverse
engineering; it is blocked on writing userspace, and that decision was already
made deliberately.

## What to expect on use

Honest confidence levels, because the difference matters for how much time to
spend before concluding something is broken.

| | Expect | Confidence |
|---|---|---|
| ISO boots, pen/touch/wifi/audio work | yes | high — prior art covers this |
| `thunderbolt` binds the platform router, a domain appears | yes | **moderate-high** — this is the audited part |
| A plugged dock/eGPU enumerates over USB4 | **unknown** | **moderate** — see the UCSI note below |
| PCIe tunnels | unknown | moderate, gated on the row above |
| `camcc` + `cci1` probe, an i2c bus appears | yes | high — all mainline code |
| `i2cdetect` shows `0x50` and the sensor | yes | high — EEPROM presence is established from the blobs |
| `imx681` probes | only after the DT gets the real address | — |
| A frame captures | needs a media-ctl pipeline built by hand | moderate; several steps past probe |
| Heat-map frames arrive on hidraw | needs a feature-report write first | moderate |

**Correction to what I said earlier: UCSI is not the risk, and it is not where to
look first.** `drivers/thunderbolt` has no reference to typec or ucsi at all; the
only coupling runs the other way (`usb4_usb3_port_match()`, consumed by
`port-mapper.c`, for sysfs links and USB3 tunnel bandwidth). USB4 entry is a PD
`Enter_USB` negotiated by the PPM firmware — Linux only reads
`PARTNER_FLAG_USB4_GEN3/4` status bits and has no code path to request it. The
same firmware does this under Windows, where USB4 works. Full reasoning in
`docs/usb4-host-router.md`.

What that leaves as the first thing to check is much more concrete: **the routers
and the ports do not line up.** Three `usb4@` nodes and three ACPI UCSI
connectors, but only two `usb-c-connector` nodes in the board DT, two physical
USB-C ports, and only `&usb4_0` enabled. The currently-enabled router may not be
a user-facing port at all. Enable all three and establish which is which *before*
reading anything into a dock that fails to enumerate.

## Plan

### Phase 0 — boot the ISO exactly as it is

Cheap, and it de-risks everything after. Do not skip it to save a step: if the
image does not boot, every later phase is debugging two things at once.

Install to an **external USB disk**, not the internal one — no partition
shrinking, and BitLocker is the real hazard here (see `[[surface-pro-11-arm64-device]]`).

Collect and keep:

```
dmesg
cat /sys/class/hidraw/*/device/report_descriptor | xxd
ls /sys/bus/i2c/devices /sys/bus/thunderbolt/devices
lsmod, lspci -nn, /proc/interrupts
```

Answers: does it boot; is the boot path sound; does pen/touch work; what does the
digitizer actually advertise on real hardware. Does **not** answer USB4 or camera.

### Phase 1 — build a kernel that can answer the rest

Compose the four branches — **verified, not assumed**: merged in order onto the
shared base, all four apply, and the single overlapping file
(`x1-microsoft-denali.dtsi`, touched by both the USB4 and PM8010 branches)
auto-merges. Then:

**Config**
```
CONFIG_USB4=m
CONFIG_USB4_DEBUGFS_WRITE=y
CONFIG_VIDEO_OV13858=m
CONFIG_VIDEO_IMX681=m
```

**Device tree**
- enable `camcc`, `cci1`, `csiphy*`, `camss` at board level
- enable `&usb4_1` and `&usb4_2` alongside `&usb4_0`
- do **not** yet add the imx681 sensor node — it has no valid `reg`

**Prefer a persistent install over a live ISO from here on.** Phases 2 and 3
involve repeated reboots and DT edits, and a live image makes every iteration
cost a rebuild.

One practical lever: grub loads the DTB by path
(`devicetree /dtb/qcom/x1e80100-microsoft-denali-oled.dtb`), so **DT iteration is
a dtb rebuild and a reboot — no kernel rebuild.** That matters a lot in phase 3.

### Phase 2 — the four measurements

In the stated priority order, each with what it settles:

1. **USB4 bind.** `dmesg | grep -i thunderbolt`, `ls /sys/bus/thunderbolt/devices`.
   Settles whether the platform NHI patches work at all. If this fails, it is my
   code and the audit missed something.
2. **USB4 tunnel.** Plug a dock, then an eGPU. `boltctl list`, `lspci`. If bind
   succeeded and this does not, look at UCSI/altmode before touching the NHI.
3. **Camera address.** ~~`i2cdetect -y -r <cci1 i2c-bus@1>`.~~ **This does not
   work as written** — see the correction below.
4. **Camera frame.** Add the sensor node with the real `reg`, rebuild the DTB,
   reboot, build the pipeline with `media-ctl`, capture with `v4l2-ctl
   --stream-mmap`. The first frame settles the Bayer order, which is the last
   fabricated-risk value in `imx681.c`.

Multi-touch's heat-map switch can be attempted at any point from phase 0 onward,
since it needs no new kernel code — only a `HIDIOCSFEATURE` write.

#### Correction: a bare `i2cdetect` will find nothing

Testing the integration merge exposed a flaw in step 3 as originally written.
`imx681_power_on()` is what enables MCLK, both regulators and releases reset. **A
sensor with no driver bound to it is unpowered and unclocked, so it cannot ACK.**
An `i2cdetect` on `cci1 i2c-bus@1` would come back empty and read as "wrong bus",
when the bus was right and the sensor was simply off.

Two things have to be true before that scan means anything:

- **The rails must exist in DT.** They did not. denali defines ldo1, 2, 4, 6,
  8… on PMIC b and skips 7 and 16, so `vreg_l7b_2p8` (front avdd, 2.8 V) and
  `vreg_l16b_2p9` (rear, 2.9 V) had no phandle to point at — the binding example
  shipped alongside the driver resolved only on `x1-crd.dtsi`. Fixed in
  `camera/denali-pm8010` (`6df377fd7`), verified in the decompiled DTB.
- **Something must hold the sensor powered during the scan.** The workable
  approach is a throwaway debug branch: a DT node with the correct clock,
  regulators, reset GPIO and `cam_aon` pinmux at any placeholder `reg`, plus a
  patch that — after `imx681_power_on()` — walks 0x08–0x77 with a one-byte read
  and logs every address that ACKs. The i2c client is created from DT whether or
  not the device answers, so probe runs regardless of the placeholder being
  wrong.

This must stay on a debug branch and never reach the PR series. A placeholder
`reg` in an upstream patch is the fabricated-constant failure mode again.

Related: `imx681_probe()` has **no chip-ID check**, so at a wrong address it
binds and reports success while talking to nothing. That is worth fixing on its
own merits, but the ID register and value for this part are not in any blob, so
the check cannot be written before the sensor answers.

### Phase 3 — feed results back

Each measurement retires a stated unknown in a draft PR. The two camera values
are the ones that turn `#4` from a well-researched driver into a testable one.
`docs/camera-sensors.md` should record the measured address next to the evidence
that it could not be derived, so the next person does not repeat the search.

## What I will not do without hardware

Guess the I2C address, or guess the Bayer order. Both are single values that look
harmless and would read as researched. That failure mode has already happened
once in this driver (`vts_def`, invented as `height + 100`, later removed), and
the whole point of the cross-validation work is that fabricated constants are the
thing this project is worst at detecting after the fact.
