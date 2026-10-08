# Upstream work: what we build on, and what is already in our tree

> Historical August 2026 audit. The missing original distro/build tools are now
> exported in [the public tooling handoff](../handoff/distro-tools/README.md).
> The private distro fork below is provenance, not a required checkout; the
> remasterer uses a separately selected public denisix runtime baseline.

Audited 2026-08-09 against `/root/sp11/wt-cfg` (the tree whose `.config` carries
`CONFIG_LOCALVERSION="-sp11-stockcfg-gf2cc827b6b89"`, matching the running
kernel) and the live UKI `integ46`.

**Purpose.** Before touching NPU, pen, touchscreen or sensors, read the status
table in §5. Several of these are further along than they look, and at least one
is a single config symbol away from working. Everything here was checked, not
assumed; where something is inferred rather than measured it says so.

---

## 1. The stack, in layers

```
Layer 3   distro/userspace      lain3d/surface-pro-11-linux  (fork of denisix)
                                install.sh, udev, systemd, UCM, pen daemon
Layer 2   our kernel commits    lain3d/surface-pro-11-kernel   55 commits
                                = denisix's 16-patch series + our own work
Layer 1   base kernel tree      jglathe/linux_ms_dev_kit
```

---

## 2. Layer 1 — the base kernel tree

Our kernel repo's root commit `31339fbd9` is a squashed import, byte-identical
to:

| | |
|---|---|
| repo | https://github.com/jglathe/linux_ms_dev_kit |
| branch | `jg/ubuntu-qcom-x1e-7.1.y` |
| commit | `bd336e2e0937cb5b2dd258e784b3b6267c653167` |

Squashed because the full history is ~6 GB. The commit message carries the
`git rebase --onto` recipe to replant onto real history if a full fork ever
exists; the trees are identical, so it is pure re-parenting.

**Naming note.** `NPU.md` says its kernel came from "the `linux-qcom-x1e`
source" built by Jens Glathe. That is the Ubuntu *flavour* name and jglathe's
branch is literally `jg/ubuntu-qcom-x1e-7.1.y`, so it is very likely the same
lineage — **but this has not been verified**, and they ran
`7.1.3-jg-1sp11v2-qcom-x1e` while we run `7.1.3-sp11-stockcfg-gf2cc827b6b89`.
Do not assume a patch present in their build is present in ours.

---

## 3. Layer 2 — our kernel repo

55 commits on top of the import. Two groups.

### 3a. denisix's patch series — all sixteen are present

Verified individually, 2026-08-09:

| patch | what | in our tree |
|---|---|---|
| 0001 | `dma: qcom: gpi` QSPI protocol support | **yes** (`b875b8e49`) |
| 0002 | `spi-geni-qcom` QSPI 1-4-4 mode | **yes** (`76822e987`) |
| 0003–0013 | complete HID-over-SPI stack (11 patches) | **yes**, `drivers/hid/spi-hid/` with 5 `.c` |
| 0014 | Denali DTS touchscreen node + pinctrl | **yes** (`b4dd5fd47`) |
| 0015 | `debian.qcom-x1e` SPI_HID annotations | **yes** (`96a6c30b3`) |
| 0016 | Denali 2.4 MHz DMIC clock | **yes** (`18b0b569c`) |
| — | `ath12k` rfkill bypass + DT MAC (2 patches, separate dir) | **yes** |

`BUS_SPI` is in the uapi headers. The touchscreen DT node is in the **live
running DTB**, not merely in source — `spi@a88000` appears with
`compatible = "qcom,geni-spi-qspi"` and one `hid-over-spi` node.

**The gpi QSPI patch is the touchscreen one, not the NPU one.** Its commit
message says so outright: backported from the Android `spi-msm-geni` driver by
the x1e-nixos project, required by the SP11 touchscreen. It is unrelated to the
"gpi.ko DMA fix" `NPU.md` describes.

### 3b. Our own work, beyond anything upstream

- **Camera** — `media: i2c: add a driver for the Sony IMX681` plus the whole
  bring-up series; C-PHY work in `camss`/`csiphy`; `ov13858` DT probing; the
  PM8010 camera PMIC DT node. See `design/camera-state-20260807.md`.
- **USB4/Thunderbolt** — `thunderbolt: bind host routers that are not PCI
  devices`, plus two supporting commits and the three host-router DT nodes.
- **ADSP/USB-C boot fixes** — see `design/upstream-adsp-fix.md`.

---

## 4. Layer 3 — the distro fork

`lain3d/surface-pro-11-linux`, local `projs/ubuntu-surface-pro-11/`, remote
`upstream` = `denisix/ubuntu-surface-pro-11`. We are **14 ahead, 0 behind** —
we have all of denisix's work. Our 14 are ISO-build tooling, patch-series
hygiene (CRLF, malformed mboxes, hunk headers), the kernel/distro split, and
EFI-stub boot without GRUB.

Public export: original ISO build/inspection tools and EFI-stub sources are
included under `handoff/distro-tools/`, and the ADSP test UKI builder is now
`tools/sp11-build-adsp-test-uki.sh`. The broader installer/runtime remains an
external public denisix prerequisite rather than a copy of the private fork.
See [the tooling handoff](../handoff/distro-tools/README.md) for exact source
identifiers, licensing, deliberate exclusions, and experimental limits.

**`install.sh` never touches the kernel.** Read in full, 2026-08-09: it does
udev rules, `apt`, file copies, userspace builds, SDK downloads and firmware
*verification*. There is no patch step and no module build. Running it would
never have delivered the fastrpc or gpi changes `NPU.md` describes — those live
uncommitted in the author's `~/npu-re/`.

---

## 5. Status table — what is actually blocking each subsystem here

| subsystem | kernel side | userspace side | blocking us |
|---|---|---|---|
| **Touchscreen** | patches in, DT node **live** | none needed | **`CONFIG_SPI_HID_OF` is not set** — §6 |
| **Pen** | same digitizer as touch | daemon + udev + unit, not installed | touchscreen first |
| **NPU** | FastRPC built in, CDSP nodes created | nothing installed | firmware + `apt` + libs — §7 |
| **Wi-Fi** | rfkill bypass in | board file extraction | not assessed |
| **Audio** | DMIC clock in | topology + UCM2 + PipeWire | not assessed |
| **Sensors** | needs ADSP (running) | hexagonrpcd + libssc | not assessed |
| **Camera** | ours, working | libcamera helper (Linux side) | one mode, `3840x2160_1` |
| **Video codec** | driver present, node disabled | none | DT + firmware — §8 |

---

## 6. Touchscreen — one config symbol

Everything is in place except the transport driver's Device Tree half:

```
CONFIG_SPI_HID=m
# CONFIG_SPI_HID_ACPI is not set
# CONFIG_SPI_HID_OF is not set        <-- the SP11 is DT, not ACPI
```

`SPI_HID_OF` is *"HID over SPI transport layer Open Firmware driver … supports
Open Firmware (Device Tree)-based systems"*, `depends on OF`, `select
SPI_HID_CORE`. Without it nothing claims the `hid-over-spi` node that is
already in the running DTB.

This is the trap recorded in memory as *annotations never reach the config*:
patch 0015 added the SPI_HID annotations to `debian.qcom-x1e`, and the built
`.config` still has the OF variant off.

**Cost to fix: `CONFIG_SPI_HID_OF=m`, rebuild modules, install.** No kernel
image rebuild (it is `=m`), no DTB change (the node is already live), no UKI
change. This is the cheapest unclaimed win in the project.

---

## 7. NPU

### What is already here

- `CONFIG_QCOM_FASTRPC=y` — **built in**, not a module. `NPU.md`'s verification
  step (`modinfo … fastrpc.ko.zst`) does not apply to us.
- CDSP gets unsigned-PD offload and **both** device nodes:
  ```c
  case CDSP_DOMAIN_ID:
  case GDSP_DOMAIN_ID:
      data->unsigned_support = true;
      /* Create both device nodes so that we can allow both Signed and Unsigned PD */
  ```
  which is what the `99-fastrpc.rules` 0666 rule expects.
- `fastrpc_soc_data` carries a CDSP-specific `dma_addr_bits_cdsp`, so the file
  is not bare-mainline-generic.
- **`qcom_q6v5_pas` is NOT blacklisted.** The live cmdline is
  `… modprobe.blacklist=thunderbolt … pmic_glink_altmode.pan_enable=0
  rd.sp11.adsp=1`. This mattered: the ADSP boot workaround could have killed
  CDSP too (one driver serves both), and it does not. The remoteprocs are up.

### What is not here

- **The gpi DMA fix — verified absent.** `gpi.c` contains no X1E, compute,
  fastrpc or cdsp handling of any kind, and its only local commit is the
  touchscreen QSPI backport.
- **The fastrpc "GLINK framing fix" — no trace.** No `rspv2`, no early-response
  handling, no `fastrpc_dbg`.

  *Hypothesis, not confirmed:* downstream Qualcomm has a longer
  `fastrpc_invoke_rspv2 { ctx, retval, rsp_flags, early_wake_time, version }`.
  Mainline knows one response shape and completes the context unconditionally,
  so an early-response flag would complete-and-tear-down early and the real
  reply would arrive against a freed idr entry. That fits "framing mismatch" and
  "garbled context IDs", but we have not reproduced it and have not seen their
  patch.

  **Signature to watch for**, from our `fastrpc_rpmsg_callback`:
  ```
  No context ID matches response
  ```

### Recommended order

Userspace first. The bug is described as hitting **signed**-PD calls and the
llama.cpp path is **unsigned** PD, so we may never see it — and patching a
built-in driver costs a kernel image *and* UKI rebuild, which is the wrong
price to pay for an unobserved bug.

`install_npu` is lighter than it looks. Most of it is packaged:

```
apt install hexagonrpcd hexagon-dsp-binaries-qualcomm-hamoa-iot-evk libhexagonrpc-dev
# fastrpc_shell_unsigned_3 from /usr/share/hexagon-dsp/x1e80100/Qualcomm/Hamoa-IoT-EVK/dsp/cdsp
```

What it does **not** install, and we must supply:

| item | source |
|---|---|
| `qccdsp8380.mbn` | Windows driver store → `/lib/firmware/qcom/x1e80100/microsoft/Denali/` |
| DSP `libc.so`, `libgcc.so` | Hexagon SDK `target/hexagon/lib/v73/G0/pic/` — only *verified* by 8h |
| `libcdsprpc.so` | built from `github.com/qualcomm/fastrpc` branch `development` |
| QAIRT SDK 2.48.0.260626 | ~1.5 GB from Qualcomm |

The summary line `libcdsprpc.so: ✓ patched` means only that the library exports
`remote_handle64_open`, i.e. that it was built from the `development` branch. It
is **not** a statement about the kernel.

**Watch out:** 8i sets `HEXAGON_TOOLS_ROOT="$QAIRT_ROOT/bin/x86_64-linux-clang"`
on an aarch64 machine. Either QAIRT ships host tools x86-only — in which case
the DSP skeleton cannot be built natively, which is exactly the failure 8i warns
about — or it is a bug. Establish this before spending the 1.5 GB.

---

## 8. Video codec (Venus/iris)

Not from either upstream — found by us, 2026-08-08, from a camera symptom.

`hamoa.dtsi` has `iris: video-codec@aa00000` with
`compatible = "qcom,x1e80100-iris", "qcom,sm8550-iris"` and `status =
"disabled"`, carrying an upstream comment that the firmware is vendor-signed and
the node should only be enabled where it is available. `CONFIG_VIDEO_QCOM_IRIS=m`
is already set and the driver binds via the sm8550 fallback, so **no driver
change is needed** — `iris_firmware.c` reads `firmware-name` from the DT.

`hamoa-lenovo-ideacentre-mini-01q8x10.dts` shows the pattern on another
X1E80100 board, naming the same file we have in the Windows image
(`qcvss8380.mbn`) under a Lenovo path. Full detail in
`design/camera-state-20260807.md` §11.

**Shipped 2026-08-09 as UKI `integ47`** — firmware installed and hash-verified,
node enabled, three-line DT delta, `dt-audit` clean, rollback staged as
`BOOTAA64-integ46-KNOWN-GOOD.efi`. Untested until the next boot; the open
question is whether TrustZone accepts our Microsoft-signed blob at `pas_id = 9`,
and the failure mode is a clean probe error.

### What it will and will not buy, before anyone gets hopeful

iris registers **both** devices — `iris_register_video_device()` is called for
`DECODER` and `ENCODER`, with `iris_vdec.c` / `iris_venc.c`, and `sm8550_data`
carries decode *and* encode firmware caps. Supported formats:

```
V4L2_PIX_FMT_H264   HEVC   VP9   AV1      (+ NV12, QC08C raw)
```

**No VP8.** Two consequences:

- **`tools/native/sp11-record.sh` cannot use it as written** — it encodes with
  `vp8enc`. It would need an H.264/HEVC branch (`v4l2h264enc ! h264parse !
  mp4mux`). The 256 kbit/s bitrate finding is still the real cause of the blocky
  Snapshot recordings; that is a software default, not a missing encoder. This
  capability sits *alongside* that fix, it does not replace it.
- That script's header (lines 30–33) claims *"no hardware encoder available …
  neither venus nor iris binds and there is no VPU firmware for x1e80100"*. Both
  halves are now disproved. Left for the Linux side to correct, since it is
  their file, but flagged in mission 19.

**Browsers probably do not benefit.** Firefox and Chromium accelerate through
VA-API; a V4L2 *stateful* m2m device is not a VA-API device and there is no
general bridge in stock distros (`libva-v4l2-request` targets *stateless*
decoders). `vainfo` settles it in one line and mission 19 asks for it. Recorded
as a reasoned expectation, not a measurement.

What should benefit: GStreamer's `v4l2` plugins and ffmpeg's `*_v4l2m2m`
codecs.

### Decode limits we inherit from the sm8550 fallback

Read from `iris_platform_gen2.c`, 2026-08-09. Levels and tiers are generous and
are **not** the constraint:

```
LEVEL_HEVC  max 6.2 (default 6.1)     Level 6.1 covers 8K
LEVEL_H264  max 6.2 (default 6.1)
TIER        max HIGH (default HIGH)
```

4K60 at 150 Mbit/s — a DJI Avata original, say — is Level 5.1/5.2 High tier and
sits well inside those.

**But HEVC 10-bit is not advertised:**

```c
.cap_id = PROFILE_HEVC,
.step_or_mask = BIT(V4L2_MPEG_VIDEO_HEVC_PROFILE_MAIN) |
                BIT(V4L2_MPEG_VIDEO_HEVC_PROFILE_MAIN_STILL_PICTURE),
```

The enum is `MAIN = 0, MAIN_STILL_PICTURE = 1, MAIN_10 = 2`, so **`MAIN_10` is
absent**. 10-bit HEVC — D-Log, HLG, most HDR camera output — will not hardware
decode and will fall back to software.

**This is very likely a platform-data limit, not a silicon one.** VP9 directly
below advertises `PROFILE_0 | PROFILE_2`, and Profile 2 *is* 10-bit. A block
that decodes 10-bit VP9 almost certainly decodes 10-bit HEVC.

**Root cause: we bind through `qcom,sm8550-iris`** because iris has no
`x1e80100` platform entry (§8), so we inherit sm8550's capability table. X
Elite's Venus is a later revision and probably exceeds it. The concrete cost of
the fallback is therefore not failure to bind — it is understating the hardware.

Candidate future work, and plausibly upstreamable: add an `x1e80100_data`
platform entry with the real caps. **Measure first** — the Windows driver
supporting Main10 is evidence about the silicon, not about what this driver
should claim.

---

## 9. USB4, the retimer, and jglathe's `jg/usb4-dock-hack`

Branch: https://github.com/jglathe/linux_ms_dev_kit/tree/jg/usb4-dock-hack

**It is a different layer from our USB4 work, not a duplicate.** Ours is the
host-router/NHI side — making the SoC's USB4 controllers exist and bind when
they are platform devices rather than PCI (`thunderbolt: bind host routers that
are not PCI devices`, the `tb_nhi` `struct device` work, and the three DT host
router nodes). His is the **retimer/mux** side: the Parade PS8830 between the
SoC and the USB-C connector, plus DP Alt Mode power sequencing. A working dock
needs both.

**It applies to this board.** The SP11 has two `parade,ps8830` retimers — one
per USB-C port — present in the live DTB, with `CONFIG_TYPEC_MUX_PS883X=m`.

### Why he calls it a hack

Read from the source on that branch, not inferred from commit subjects. The
driver adds a DT property and refuses USB4 outright when it is set:

```c
retimer->disable_usb4 = device_property_read_bool(dev, "qcom,disable-usb4");
...
if (retimer->disable_usb4) {
	dev_info(&retimer->client->dev,
		 "USB4 disabled via DT property, rejecting USB4 mode\n");
	return -EOPNOTSUPP;
}
```

He then sets it on his own T14s (`disable ps883x USB4 capapility`). So the way
the branch makes USB4 docks work is by **not doing USB4** — the link falls back
to DP Alt Mode / USB 3.x. That is a workaround rather than a fix, which is
exactly what the branch name says.

The rest of the branch is more substantive: stale DP Alt Mode handling in
`phy-qcom-qmp-combo` (force-clear `dp_powered_on` on hotplug, actually power the
PHY off when clearing stale state), a 20–30 ms delay after writing the retimer
config registers, and registering all three switch roles.

### We already have this, inherited and active

Checked 2026-08-09, and this was a surprise:

```
x1-microsoft-denali.dtsi:860    parade,disable-usb4;      (left-side port)
x1-microsoft-denali.dtsi:925    parade,disable-usb4;      (right-side port)
live DTB                        2 occurrences
ps883x.c:418   retimer->disable_usb4 = device_property_read_bool(dev, "parade,disable-usb4");
ps883x.c:277   case TYPEC_MODE_USB4: if (retimer->disable_usb4) ... return -EOPNOTSUPP;
```

Both the property and the driver support came in with the **base import**
(`31339fbd9`), under the `parade,` vendor prefix; the `usb4-dock-hack` branch
uses `qcom,`, so that branch is a later or parallel iteration of the same idea.

**So USB4 is currently disabled on both USB-C ports of this machine, in the
running kernel, by a device-tree property we inherited.** Recorded as fact, not
as a proposal: the eGPU-on-Linux question is a closed decision and this note is
not reopening it. But the knob exists and is one property away.

**Do not flip it casually.** This root filesystem boots over USB-C, and our own
commit `50c70f2d0 WIP: the six Type-C fixes that let this machine boot off
USB-C` touches this exact driver. The retimer path is load-bearing for booting
at all.

### Planned: trace a Dell Thunderbolt dock hotplug under Windows

Not done, recorded so the groundwork is not repeated. **This is a much better
tracing target than the camera was**, for three reasons: the providers are
Microsoft-authored and manifest-based (self-describing, no TMF and no Ghidra
needed, unlike `qccamisp8380.sys`'s WPP); a hotplug is a discrete event with a
clean before/after; and Windows *works* with docks while Linux does no USB4 at
all, so there is a real behavioural gap to diff against.

Providers present on this machine, checked 2026-08-09:

```
Microsoft-Windows-USB-USB4DeviceRouter-EventLogs  {D07E8C3F-78FB-4C22-B77C-2203D00BFDF3}
Microsoft-Windows-USB-UCMUCSICX                   {569D11AA-5068-5EE5-DA22-CE541C0B1481}
Microsoft-Windows-USB-USBHUB3                     {AC52AD17-CC01-4F85-8DF5-4DCE4333C99B}
Microsoft-Windows-USB-USBXHCI                     {30E1D284-5D88-459C-83FD-6345B39B19EC}
Microsoft-Windows-Kernel-PnP                      {9C205A39-1250-487D-ABD7-E831C6290539}
```

`wpr.exe` and `xperf.exe` are both installed. The vendor binaries are already
extracted to `data/bin/`: `QcUsb4Bus8380.sys`, `Usb4HostRouter.sys`.

**The profile is written and validated: `tools/sp11-boottrace.wprp`.**

```
wpr -addboot tools\sp11-boottrace.wprp!SP11Platform -filemode
shutdown /r /t 0
wpr -stopboot %USERPROFILE%\Documents\sp11-boot.etl "dock cold boot"
wpr -cancelboot        <- escape hatch; know it before rebooting
```

**`-addboot` is the Autologger registry mechanism, not BCD**, so it does not
touch boot configuration and does not trip BitLocker recovery. Kernel debugging
would, and is not worth it here.

Boot tracing also makes the two sides comparable, which a hotplug trace alone
does not: docks behave differently present-at-boot versus plugged in later, and
the boot window is where `ALTMODE_PAN_EN` is fatal at 6 s and harmless at 66 s.
The Linux counterpart is `initcall_debug` plus `trace_event=` on the command
line, with `ramoops` to survive a bad boot — this board already has the node.

There is no pre-OS option. No exposed serial or debug port on a Surface, so the
earliest instrumentation point is the Windows kernel's first moments, which is
where Autologger starts.

What it would answer that we cannot get statically: what Windows actually
negotiates on the connector and in what order — alt-mode entry, USB4 router
discovery, tunnel setup, retimer configuration. That maps directly onto the
questions this section leaves open, above all whether `parade,disable-usb4` is
covering for something specific or is a blanket workaround.

### Leads worth keeping

- His stale-DP-Alt-Mode power-sequencing commits sit in the same territory as
  our `ALTMODE_PAN_EN` boot race — fatal at 6 s, harmless at 66 s — which we
  currently work around with `pmic_glink_altmode.pan_enable=0` plus
  `sp11-altmode.service`. Worth diffing against `design/upstream-adsp-fix.md`
  before spending more effort there.
- `Register as mode-switch to satisfy pmic_glink hotplug`: our nodes declare
  `retimer-switch` and `orientation-switch` but **not** `mode-switch`. If DP
  hotplug ever misbehaves, that is a named suspect.
- The 20–30 ms post-config delay may bear on the retimer latching across warm
  reboot that we already know costs us root-disk link speed.

---

## 10. The Surface Pro 10 camera work

`linux-surface/linux-surface#2153`, by djmulder — a complete IMX681 bring-up:
1920x1080, SBGGR10, ~15.85 fps, working in Teams via PipeWire.

**Different machine.** SP10 is Intel Meteor Lake with IPU6; the "SP11" in their
comparison table is Intel Lunar Lake with IPU7. Ours is Snapdragon X1E80100 with
camss. None of their INT3472 / ipu-bridge work applies, and nothing they built
touches CSIPHY, CSID or VFE.

**What transferred:** `0x0340` frame length reads back 0 and must be written
after `MODE_SELECT`; horizontal binning does not work on this part (`0x0901 =
0x22` reads back `0x02`) and horizontal reduction needs the scaler; the binning
register numbers.

**What did not, and cost us time until measured:** their `SBGGR10` Bayer order
(ours is `SRGGB10` — they run `IMAGE_ORIENTATION = 0x03`, and RGGB rotated 180°
is BGGR), and their inverted analogue gain (ours increases with the code). Their
C-PHY retraction also does not transfer; our `0x03` came from the SP11 vendor
blob, and one lane at 5.49 Gbps is not physically D-PHY.

Full treatment in `design/camera-state-20260807.md` §4 — including why "same
sensor" is not "same module".

---

## 11. Ordering when we make a pass

1. **Touchscreen** — one config symbol, module-only rebuild. Cheapest.
2. **Pen** — userspace only once touch works; same digitizer, mutually
   exclusive modes, needs the daemon.
3. **NPU** — userspace-first, watch for `No context ID matches response`.
4. **Video codec** — DT + firmware, needs a DTB/UKI rebuild.

Items 1 and 3 need no DTB or UKI change. Item 4 does, and pairs with the
deferred camera `bus-type` commit — one rebuild, both changes.

**Before any DTB rebuild, read the provenance rule:** the live UKI's DTB is
built from **`wt-pr` on `integration/camera`**, not `wt-cfg`. The six worktrees
carry different device trees. Prove byte equality against the extracted running
DTB before applying any change.
