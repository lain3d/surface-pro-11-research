# BRINGUP — read this first

You are on a **Microsoft Surface Pro 11** (Snapdragon X Elite, X1E80100, ARM64)
that has just booted Linux, probably from a live USB. This file is the handoff
from the session that did the preparation work. Nothing here has ever run on this
hardware before, so treat every prediction in these documents as a prediction.

---

## The situation in one paragraph

The machine works fine under Windows. Several parts do not work under Linux —
USB4, the cameras, the touchscreen's high-resolution mode — mostly because nobody
had written down, in the form Linux wants, what is wired to what. The previous
session recovered that description from Windows' firmware tables and driver data
files, wrote it as device tree and driver code, and produced this image. **The
work is now entirely blocked on measurements that need real hardware.** That is
you.

---

## Ground rules — these matter more than the task list

The previous session's single biggest failure mode, measured, was **asserting
conclusions whose evidence had not been gathered.** Nine of forty-three commits
exist purely to correct such claims. Inherit the correction, not the habit:

1. **Every constant traces to a source.** If you cannot say where a value came
   from, do not write it. A plausible-looking fabricated constant is
   indistinguishable from a real one by inspection — that is what makes it
   dangerous. This has already happened twice here: an invented `vts_def` and an
   invented Kconfig symbol name.
2. **A claim that states a magnitude or defers to someone else, with no
   procedure, is unverified.** "Months." "Too big." "Not supported." If you catch
   yourself writing one, run the check instead.
3. **Verify the artifact, not the source.** Do not read your own diff and
   conclude it is right. Decompile the DTB, read `.config` back, hash the file.
4. **Record proven negatives.** "X is not in the firmware, checked three ways" is
   a real result and saves the next person the search.
5. **A pipeline's exit code is not the command's.** `make … | grep …; echo $?`
   reports grep. This printed success for a failed build here, twice.

---

## What has already been established

Do not re-derive these. Sources are in `docs/`.

**Camera.** All three sensors identified from ACPI `_HID`: IMX681 (front,
`SONY0681`), OV13858 (rear, `OVTID858`), VD55G0 (IR, `SMO55F0`). Front sensor is
on **`cci1`, `i2c-bus@1`** — the always-on bus — with MCLK on **gpio100 under
pinmux function `cam_aon`, not `cam_mclk`**, reset gpio237, avdd LDO7_B 2.8 V,
dovdd LDO3_M 1.8 V. Register tables were recovered from the Windows Chromatix
blobs and cross-validate against mainline `ov13858.c` at 508/558, with every
divergence clustered in the crop block.

**USB4.** Three host routers in ACPI and now in DT, all enabled.
`drivers/thunderbolt` contains **no reference to typec or ucsi** — USB4 entry is
a PD `Enter_USB` negotiated by the PPM firmware, which already works under
Windows. So UCSI is *not* the thing to suspect. The routers-to-ports mapping is:
three routers, three ACPI connectors, but only **two physical USB-C ports**, and
DT labels are not in address order.

**Touchscreen.** The heat-map collection is usage page `0x0D`, usage `0x0F`, with
a 7488-byte input report and a 120-byte feature report. Feature `0x05` is a
single boolean — the mode switch, set on Windows. Feature `0x06` is the frame
parameters, byte-identical to a Windows registry blob.

---

## What is unknown, and exactly what settles it

Four things. Each needs one measurement.

| Unknown | Measurement | Notes |
|---|---|---|
| Does the USB4 router bind? | `dmesg \| grep -i thunderbolt`, `ls /sys/bus/thunderbolt/devices` | If this fails it is the previous session's code |
| Does PCIe tunnel? | plug a dock, then `lspci` / `boltctl list` | Suspect the router↔port mapping before UCSI |
| The sensor's I2C address | boot the INTEG image, `dmesg \| grep 'DEBUG:'` | Provably not in the firmware; checked three ways |
| The Bayer/CFA order | capture one frame, then `tools/sp11-bayer.py` | Provably not in any Windows file |

**The camera address needs the debug branch, not `i2cdetect`.** Nothing powers
the sensor until a driver binds — `imx681_power_on()` is what enables MCLK, the
regulators and releases reset. A bare `i2cdetect` scans an unpowered bus, returns
nothing, and reads as "wrong bus". Expect **two** responders: `0x50` (the module
EEPROM, which confirms the bus is right) and the sensor.

---

## Do this, in order

**0. Collect state before touching anything.**

```bash
sudo ./tools/sp11-collect.sh
```

Writes a self-contained directory. **Copy it off the machine before rebooting** —
a live session keeps nothing.

**1. Which image are you on?**

```bash
uname -r
```

- `7.1.3-sp11-gd81a425b872a-dirty` → **baseline**. Answers multi-touch only. It
  is the control: if the other image misbehaves, this one tells you whether the
  machine or the new patches are at fault.
- `7.1.3-sp11-integ-gf2cc827b6b89` → **INTEG**. Answers everything.

**2. Multi-touch — works on either image.**

```bash
sudo ./tools/sp11-hid.py list            # find the HEAT MAP DIGITIZER node
sudo ./tools/sp11-hid.py check /dev/hidrawN
```

`check` is read-only and verifies feature `0x06` against values recovered from
Windows. **If it matches, the whole analysis is confirmed on hardware.** If it
does not, stop — do not write `0x05`; the layout is wrong.

```bash
sudo ./tools/sp11-hid.py enable /dev/hidrawN    # refuses unless check passes
sudo ./tools/sp11-hid.py read /dev/hidrawN 3    # expect 7488-byte reports
```

**3. USB4 — INTEG only.**

```bash
dmesg | grep -iE 'thunderbolt|usb4|nhi'
ls /sys/bus/thunderbolt/devices/
```

Then plug something in — a dock or an NVMe enclosure is a cheaper first test than
a GPU. If the router bound but nothing enumerates, work out **which router is
which physical port** before concluding USB4 is broken.

**4. Camera — INTEG only.**

```bash
dmesg | grep 'DEBUG:'
```

Expect the scan output listing `0x50` and one other address. **Probe is expected
to fail afterwards** — there is no port/endpoint and camss is not wired up. That
is designed behaviour, not a bug. The other address is the answer.

---

## What is in this bundle

```
BRINGUP.md            this file
docs/                 per-pillar findings, with evidence
  orientation.md      >> read this if the acronyms are unfamiliar
  camera-sensors.md   sensor identification, blob decoding, CCI bus derivation
  usb4-host-router.md router analysis, the UCSI reassessment
  multitouch-heatmap.md  heat map, feature reports, first-boot procedure
design/
  first-boot-runbook.md   BitLocker step 0, live vs installed, the measurements
  state-and-unblock-plan.md  where everything stands
  kernel-dev-strategy.md     how the kernel work is done and verified
  iso-build.md               how the images were built
tools/
  sp11-hid.py         heat-map discovery and feature reports
  sp11-collect.sh     one-pass state collection
probes/               the analysis tools that produced docs/ (mostly host-side)
data/                 decoded ACPI, register tables, HID descriptors
kernel-patches/       the five branches as patch series, on a shared base
```

If the acronyms are unfamiliar — CCI, CSIPHY, NHI, UCSI, HUTRR87, GSIV — read
`docs/orientation.md` first. It exists for exactly that.

---

## Traps that have already cost time here

- **Shell scripts may arrive with CRLF** if unpacked from a Windows-made archive
  and fail with `$'\r': command not found`. This bundle is built with LF, but
  check if something refuses to run.
- **`pgrep -f <pattern>` matches its own command line** and will appear to find a
  process that is not running, or kill the shell that invoked it.
- **`.config` goes stale across branch switches**, and `syncconfig` can fail and
  still exit 0. After any checkout, set the symbol, `make olddefconfig </dev/null`,
  then **grep `.config`** to confirm.
- **Do not trust a file of plausible size.** A truncated capture and a truncated
  squashfs both looked fine here. Validate with the tool that parses the format.

---

## The upstream position

Five draft PRs on `lain3d/surface-pro-11-kernel`, one branch each:

| # | Branch | |
|---|---|---|
| 1 | `camera/ov13858-dt` | rear sensor DT probing |
| 2 | `camera/denali-pm8010` | camera power rails |
| 3 | `usb4/platform-nhi` | bind the USB4 host routers |
| 4 | `camera/imx681` | new front-camera driver |
| 5 | `debug/imx681-addr-scan` | **throwaway** — delete once it yields the address |

Nothing has been sent to a mailing list, deliberately: several patches encode
assumptions only hardware can confirm, and submitting them first would mean
asking maintainers to review guesses. **Your measurements are what change that.**
