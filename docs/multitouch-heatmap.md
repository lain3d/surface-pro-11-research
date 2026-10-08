# Multi-touch: the digitizer does emit a full 2-D frame

**Status: the open question is settled, and the previous answer was wrong.**

`design/three-pillars-loop.md` framed Pillar 1 around one question — *can the
digitizer emit a true 2-D frame at all?* — and treated it as blocked on booting
Linux, because the plan was to answer it by dumping
`/sys/class/hidraw/*/device/report_descriptor`.

It was never blocked. Windows parses the same report descriptor the device hands
to any host, and exposes the parsed result through `HidP_GetCaps`. The answer was
available on the machine as it sits.

**A 7488-byte input report exists, on a collection whose usage is literally
`Capacitive Heat Map Digitizer`.** That is 16× the 464-byte report the pen daemon
reads, and it is squarely inside the 3–12 KB range a real frame was predicted to
occupy.

## How this was measured

`probes/hid-collections.ps1` enumerates every HID top-level collection
(`SetupDiEnumDeviceInterfaces` over `GUID_DEVINTERFACE_HID`), opens each one, and
reads `HIDP_CAPS` — which carries `InputReportByteLength`, the largest input
report declared in that collection. Full output in `data/hid-collections.txt`.

The per-collection numbers differ (3, 6, 10, 16, 61, 7488), so this is a genuine
per-collection maximum, not one device-wide figure repeated.

## The ten collections of `ACPI\MSHW0485`

VID `045E`, PID `0C83`, `prod="HIDSPI Device"`. Report lengths in bytes, report ID
included.

| Col | Usage page / usage | Meaning | Input | Output | Feature |
|---|---|---|---|---|---|
| 01 | `FF0B` / `0B` | vendor | **7488** | 2 | 511 |
| 02 | `000D` / `0F` | **Capacitive Heat Map Digitizer** | **7488** | 64 | 120 |
| 03 | `FF0F` / `50` | vendor | 61 | 61 | 17 |
| 04 | `000D` / `04` | Touch Screen | **6** | 0 | 0 |
| 05 | `FFF4` / `01` | vendor | 12 | 28 | 8 |
| 06 | `FF0B` / `101` | vendor | 61 | 61 | 61 |
| 07 | `000D` / `02` | Pen | 16 | 0 | 0 |
| 08 | `FFA1` / `60` | vendor | 3 | 0 | 0 |
| 09 | `FF0F` / `51` | vendor | 0 | 0 | 59 |
| 0A | `FF0D` / `01` | vendor | 10 | 6 | 11 |

Usage `0x0D`/`0x0F` is not a guess. It was added to the Digitizers page by
[HUTRR87 — Heat Map Digitizers](https://usb.org/sites/default/files/hutrr87_-_heat_map_digitizers_1.pdf),
submitted by Nathan Sherman of Microsoft and approved 2018-11-02, alongside
`0x6A` Capacitive Heat Map Protocol Vendor ID, `0x6B` Protocol Version, and `0x6C`
Capacitive Heat Map Frame Data. The spec defines the class as

> A digitizer that collects raw capacitive data in a heat map format and reports
> to the host device for additional processing.

and says of the encodings:

> encodings allow for heat map data to be sent into multiple reports for reporting
> of large sensor areas, reporting a subset of the heat map for power savings, and
> packaging additional data relevant for input processing.

## What this overturns

`iso-build/research/MULTITOUCH.md` in the distro repo concluded that HEAT mode
"delivers two one-dimensional projections, not a 2-D image", and that multi-touch
was therefore blocked at the protocol level by the ghost-point problem.

The byte accounting in that document is still correct — the 464-byte type-`0x5b`
report really is `8 + 46·4 + 68·4`, and two projections really cannot resolve N
contacts. What was wrong is the inference from one report to the whole device.
The 464-byte report is *"reporting a subset of the heat map for power savings"*, in
the spec's own words. It is the cheap mode, and the daemon picked it.

Multi-touch is **not** protocol-blocked. It is a mode-selection problem followed
by ordinary heat-map processing.

## Two more things the table says

**Windows is not getting multi-touch from the standard touchscreen collection
either.** Col04 (`000D`/`04`, Touch Screen) declares a **6-byte** input report.
Windows mandates Contact ID and Contact Count in that collection for a
multi-contact device; six bytes — report ID, a bit field, and two 16-bit
coordinates — cannot carry them. So on Windows too, contacts are being recovered
from the heat map in software above `hidspi.sys`. That is what `heat.inf` /
`oem178.inf` are for, and it means the Linux side is not chasing something the
hardware does natively for Windows and refuses to do for us. Both hosts have to do
the same work.

**It also explains the single-touch status quo on Linux.** Six bytes is exactly
one contact, and one contact is exactly what the upstream repo reports working
through the standard HID path.

## Frame geometry — arithmetic, not yet a measurement

The 46- and 68-bin projections imply a 46 × 68 = 3128-node sensor grid. At
`uint16` per node that is 6256 bytes, leaving 1232 bytes of the 7488 for headers
and metadata. 7488 is also exactly 117 × 64, and 64 is the size of Col02's output
report, so a transport chunk size of 64 is plausible.

Both are consistent with the observed number. Neither is confirmed. Confirming the
layout means capturing frames, which is step 3.

## Revised Pillar 1

| Step | Status |
|---|---|
| 1 — dump the descriptor | **done**, from Windows, no boot needed |
| 2 — find a report ≫ 464 bytes | **done** — 7488 bytes, Col02 |
| 3 — capture frames in that mode | next |
| 4 — RE the Windows side | now optional; needed only if step 3 can't find the mode switch |
| 5 — blob detection → uinput MT slots | unchanged, and now unblocked in principle |

The next question is narrow and concrete: **which feature report puts the device
into full-frame mode?** Col02 has a 120-byte feature report and a 64-byte output
report; Col01 has a 511-byte feature report. `set_heat()` in the pen daemon
already writes one feature report to select the 464-byte mode, so the mechanism is
known — only the value is not.

On Linux this is all one `hidraw` node (hidraw does not split top-level
collections), so the existing daemon already has a file descriptor that can carry
a 7488-byte report. No kernel change is implied.

## How Windows consumes the heat map — confirmed, not inferred

The section above inferred from report sizes that Windows must be recovering
contacts in software. The Windows side now confirms it directly.

**`heat.inf`** (in the driver store as `heat.inf_arm64_7dacd0522a92e4b8`) binds:

```inf
[Msft.NTarm64]
%HeatHid% = HeatHid.Inst, HID_DEVICE_UP:000D_U:000F

[HeatHid.Inst.NT.Services]
AddService = , 2
```

Three things fall out of those five lines:

1. It matches on **`UP:000D_U:000F`** — usage page `0x0D`, usage `0x0F`. That is
   exactly the Capacitive Heat Map Digitizer collection (Col02) with the
   7488-byte report. The `%HeatHid%` string is *"HID-compliant HEAT touch
   screen"*, and the provider is `%Msft%` — this is an **inbox Microsoft
   driver**, not a Surface one.
2. **`AddService = , 2` means there is no service binary at all.** There is no
   `heat.sys`. The INF only creates registry keys and an ACL.
3. That ACL grants access to `S-1-5-90-0` — the **Window Manager\DWM** group —
   alongside administrators and SYSTEM. A kernel driver would not need that; a
   user-mode consumer would.

### The consumer, named

Under the Col02 device instance — `3&3b13a23&0&0001`, the same instance path as
`hid#mshw0485&col02` in `data/hid-collections.txt` — the `Device Parameters` key
holds:

| Value | Contents |
|---|---|
| `Heat\SoftwareProcessor` | `…\surfacetouchpenprocessor0c83update.inf_arm64_*\TouchPenProcessor0C83.dll` |
| `Heat\CurrentParams` | ~104-byte blob, visibly IEEE-754 floats (`00 00 32 43` = 178.0f, …) |
| `Heat\VendorSpecific\FastHostId` | `116 2` |
| `Heat\VendorSpecific\LatestFwVersion` | `63 20 0 137` |
| `Heat\VendorSpecific\RecentPens` | per-pen pairing table |

So Windows' architecture is: **inbox HID driver exposes the heat-map collection,
and a user-mode `SoftwareProcessor` DLL turns frames into contacts.** No kernel
driver does contact detection on this machine.

### `CurrentParams` confirms the 46 × 68 grid

The 119-byte `Heat\CurrentParams` blob decodes as a 55-byte header followed by
**16 IEEE-754 floats** (0x37 + 4k, ending exactly at 119):

```
178.0  182.0  180.0  1.0
178.0  182.0  180.0  1.0
 90.0  171.0  100.0  20.0
172.0  177.0  175.0  2.0
```

Two identical quadruples then two different ones — thresholds or per-axis
baselines rather than geometry.

The geometry is in the header. At offsets `0x0e` and `0x12` sit two `u32`s:

```
0e  2e 00 00 00     = 46
12  44 00 00 00     = 68
```

**46 and 68, stated explicitly in Microsoft's own configuration for this
device.** Until now those two numbers came only from byte accounting on the
464-byte report in the Linux daemon. This is an independent second source, and it
confirms the sensor grid is 46 × 68 = 3128 nodes.

What it does *not* settle is how a 3128-node frame is packed into 7488 bytes.
See the next section — the cell width is now known, and it is **not** what the
earlier arithmetic in this document assumed.

## Inside `TouchPenProcessor0C83.dll`

Full Ghidra analysis of the 9.3 MB DLL proved impractical — `analyzeHeadless`
ran **36 minutes of CPU and 2 GB of RSS without producing a program**, and was
killed. This project's own `probes/strings_pe.py` ("fast triage without involving
Ghidra at all") answered more than the decompiler would have, because the DLL
ships with its telemetry event names intact.

### Cells are 1 byte, not 2 — correcting this document

```
SurfaceHeatProcessorParseFullFrameOnly1BytesSupported
SurfaceHeatProcessorParseFullFrame2BytesNotSupported
SurfaceHeatProcessor_ProcessHeatmap_ParseFullFrameFailed
```

The parser explicitly supports **one byte per cell** and explicitly rejects two.
Every `× 2` in the geometry arithmetic earlier in this file was an assumption,
and it was wrong. At 1 byte per cell a 46 × 68 grid is **3128 bytes**, not 6256.

That leaves 4360 of the 7488 bytes unaccounted for, so the full-frame report is
*not* simply a bare 46 × 68 image — it carries something else as well, or its
dimensions differ from the projection bin counts. Still a question for a capture;
but now it is a question with one fewer wrong assumption in it.

### The mode switch is a feedback report, and its ID is discovered, not fixed

```
SendSwitchModeFeedback
FeedbackSendSwitchModeFeedbackEntry
FeedbacksDisabledSendSwitchModeFeedback
IsSendSwitchMode
GetFeedbackReportIdAndIoControlCode_HidDescriptorFailed
HeatHidModeBitmapRecordReceived
```

Two things matter here for the Linux side:

1. Mode selection is a **HID feedback (output) report**, not a magic vendor
   command — and `GetFeedbackReportIdAndIoControlCode` says the **report ID and
   the IOCTL are derived from the HID report descriptor at runtime**, not
   hardcoded. So the daemon does not need a captured magic constant; it needs to
   parse the descriptor and find the right report, which `hidraw` supports.
2. The device announces which modes it supports as a **bitmap**
   (`HeatHidModeBitmapRecordReceived`), so full-frame availability is
   discoverable rather than guessed.

### The processor does no I/O at all

With the DLL properly analysed (2590 functions — see the README note about
`analyzeHeadless` being throttled by default, which made this look impossible
earlier), its **import table** settles something the strings only implied.

It imports exactly two HID functions — `HidP_GetCaps` and `HidP_GetValueCaps` —
and **no `HidD_SetFeature`, no `DeviceIoControl`, no `CreateFile`, no
`WriteFile`.**

So `TouchPenProcessor0C83.dll` never talks to the device. It *parses* the HID
descriptor and computes feedback; the Windows touch stack performs the actual
writes. That is what `GetFeedbackReportIdAndIoControlCode` means — the processor
works out *which* report to send from the descriptor, and hands both the report
ID and the IOCTL back to its host.

This strengthens the earlier conclusion rather than complicating it: **there is
no captured magic constant to steal, because Windows does not use one either.**
Both sides derive the report from the descriptor at runtime, which is exactly
what a Linux daemon can do through `hidraw`.

What is still not pinned down is the *payload* — the bytes that select
full-frame mode once the report is identified. The telemetry strings naming that
path are metadata, not code-referenced, and the `HidP_*` call sites are not
resolved in the current analysis, so following it needs another pass.

### The plug-in interface, in full

The telemetry strings were a dead end — not code-referenced, and the `HidP_*`
call sites unresolved. The **export table** was the way in, and it is intact
with C++ mangled names (`probes/pe_exports.py`). `TouchPenProcessor.dll`
exports 28 symbols: one C entry point and 27 virtual methods of a single class,
`SurfaceHeatProcessor`.

```
InitializeHeatProcessor                     the entry point

SurfaceHeatProcessor::ProcessHeatmap(IHeatFrameNew *)
SurfaceHeatProcessor::PostProcessHeatmap(IHeatFrameNew *)
SurfaceHeatProcessor::SanitizeHeatmap(IHeatFrameNew *)

SurfaceHeatProcessor::OnDeviceAttached(IHeatDeviceNew *)
SurfaceHeatProcessor::OnDeviceDetached(IHeatDeviceNew *)
SurfaceHeatProcessor::OnDeviceReset(IHeatDeviceNew *)
SurfaceHeatProcessor::OnDisplayEnabled / OnDisplayDisabled
SurfaceHeatProcessor::OnStitchingEnabled(HeatDeviceRegionNew *, unsigned,
                                         IHeatPointerInputReporter *)
SurfaceHeatProcessor::OnAngleChanged(float, IHeatHingeAngleSensor *)
SurfaceHeatProcessor::OnConfigAdded / OnConfigRemoved / OnConfigUpdated

SurfaceHeatProcessor::GetTouchInputCapabilities(HeatTouchInputCapabilities *)
SurfaceHeatProcessor::GetTouchMaxCount(unsigned int *)
SurfaceHeatProcessor::GetPenInputCapabilities / GetPenMaxPressure
   ... plus eight touchpad accessors
```

Three things follow.

**The frames are pushed to it.** `ProcessHeatmap` *receives* an `IHeatFrameNew *`.
The processor never asks for a frame, which is why it imports no I/O — the host
owns the device and delivers frames.

**Mode selection lives behind `IHeatDeviceNew`, on the host side.** That
interface is implemented by the Windows HEAT stack, not here, so the switch-mode
report is constructed and written by Microsoft's component. There is nothing
further to extract from *this* DLL about it — which closes that line of enquiry
rather than leaving it open.

**But `ProcessHeatmap` is the contact-detection algorithm**, at a known address,
in an analysable binary. That is Pillar 1 step 6 — turning a frame into
contacts — and it is now directly readable rather than guessed at. Likewise
`GetTouchMaxCount` states the supported contact count outright.

This DLL also handles the Type Cover touchpad (`GetTouchpadMaxCount`,
`GetTouchpadRightClickZone`, `GetTouchpadCurtainZone`), which explains its size
and is worth knowing if palm rejection ever needs attention.

### The processing pipeline, located

`ProcessHeatmap` itself is 379 decompiled lines of which almost all is ETW
telemetry. Its actual body is short:

```
null-check the frame
two virtual calls on IHeatFrameNew  (the second takes &DAT_1807fed90 as
                                     what looks like an IID -- QueryInterface)
call the dispatcher with the frame buffer and dimensions
map the HRESULT and release
```

The dispatcher then runs three stages:

| Stage | Address | Size | Callees |
|---|---|---|---|
| 1 | `0x180070460` | 243 B | none notable |
| 2 | `0x18008f058` | 767 B | 2 |
| **3** | **`0x18008f828`** | **4947 B** | **13+** |

Stage 3 looked like the contact-extraction work on size and fan-out alone.
**Reading it shows that was wrong** — which is exactly why the earlier note said
the ranking was inferred rather than read.

Stage 3 is an **orchestration layer**:

```
index = HeatFrame_GetSlotIndex(ctx)          (the function previously "Stage1")
pSlot = ctx + index * 0xee52                 61010-byte slot array
store the frame parameters into pSlot
run state and configuration checks against slot fields
dispatch to ~13 helpers, each with its own fan-out
```

No grid loops, no 46/68 bounds, no thresholds, no float comparisons appear in
it. The arithmetic is one to two levels further down, spread across mid-size
helpers — `FUN_180068008` (1627 B), `FUN_180068cb8` (795 B), `FUN_180067b20`
(599 B) and others, each calling more.

The Ghidra names are corrected accordingly: `HeatFrame_Stage3_Orchestrate`,
`HeatFrame_GetSlotIndex`.

### Why this is where the RE stops

Recovering the algorithm means descending several more levels through a wide,
heavily abstracted C++ call tree. That is a multi-session project — and it is
**not on the critical path**, because *Linux does not need Microsoft's
algorithm, only an algorithm*.

**linux-surface's `iptsd` already turns heat maps into contacts, is open
source, and was identified as the precedent at the start of this pillar.**
Starting from a working implementation beats reverse-engineering a proprietary
one, and the frame format — 46 × 68, one byte per cell — is now known
independently of it.

So the useful output of this exercise is the architecture, not the arithmetic:
frames are pushed to a user-mode processor, contacts come back through a virtual
HID device, mode selection is host-side, and none of it needs a kernel driver.
The Linux daemon can be built on that shape using `iptsd`'s maths.

### Max contact count is not a constant

`GetTouchMaxCount` reduces to one line:

```c
*param_1 = *(byte *)(*(longlong *)(this + 0x2cc60) + 0xe);
```

A byte read from device configuration at runtime, so there is no fixed number to
lift — the count comes from the device, as it should.

### Contacts are injected through a virtual HID device

```
VirtualHidManager_Init
VirtualHidManager_SendPtpData_SendInput      (PTP = Precision Touchpad)
VirtualHidManager_SendCnmData_SendInput
CreateVirtualHidFailed
```

Windows' processor creates a *virtual HID device* and injects the contacts it
computed. That is precisely what `uinput` does on Linux — so the architecture the
Linux daemon already uses is the same one Microsoft chose, not a workaround.

### The rest of the pipeline, for orientation

`SurfaceHeatProcessor_ProcessHeatmap` is the entry point, with
`OnDeviceAttached` / `OnDeviceDetached` / `OnDeviceReset` lifecycle hooks and
context handlers — `HandleStitchingModeChange`, `HandleNewHingeAngle`,
`HandleDisplayChange`. The DLL also imports `HidP_GetCaps` and
`HidP_GetValueCaps`, the same API used to produce `data/hid-collections.txt`.

### Why that matters for Linux

It means the Linux design does not need to differ in shape. `sp11-pen-daemon` is
already the structural equivalent of `TouchPenProcessor0C83.dll` — a userspace
consumer of the same HID collection. What it lacks is the mode selection and the
blob detection, not an architecture.

It also makes step 5 concrete. The feature report that selects full-frame mode is
written by a **9.3 MB user-mode DLL whose name we now have**, rather than being
buried somewhere in the kernel stack.

## Ground rule this validates

Rule 3 of the loop recipe — *verify against the source, not against memory*. The
464-byte report was read correctly and the arithmetic on it was right. The error
was concluding something about the device from the one report someone had already
chosen to enable.

## The feature reports, read from the live device

Earlier I concluded there was "no magic constant to steal" because mode selection
is host-side. That is true as a principle and unhelpful as a procedure. Reading
the collection's feature reports off the running machine gives the actual
numbers (`probes/HeatFeature.cs`, output in `data/heat-feature-reports.txt`).

The heat-map collection is `mshw0485 col02` — usage page `0x000D`, usage `0x0F`,
7488-byte input report, **120-byte feature report, exactly one button cap**.
Three feature reports respond:

### `0x05` — a single boolean, currently set

```
05 01 00 00 00 00 ... (117 more zero bytes)
```

120 bytes whose entire payload is one `0x01`. The collection advertises
`featBtnCaps=1` and `featValCaps=0` — one boolean and nothing else — and this is
the report carrying it. **It is currently 1**, which fits everything else known:
Windows runs the digitizer in heat-map mode continuously and does contact
detection in user mode.

This is the mode switch. Stated at the confidence the evidence supports: a
120-byte feature report whose only content is the collection's only boolean, set
to 1 on a machine that is demonstrably consuming heat-map frames. I did not
toggle it to prove it — writing 0 to the live device risks taking out touch
input on the machine being used to do the work.

### `0x06` — the frame parameters

```
06 | 77 00 00 00 00 00 00 70 00 00 00 00 02 01 2e 00
     00 00 44 00 00 00 fd 6a 00 00 53 47 00 00 01 41 ...
```

**This is byte-for-byte the registry's `HEAT CurrentParams` blob** — verified by
comparison, not by eye: the 119-byte registry value equals the 120-byte report
with its report-ID byte removed, exactly.

That settles what that registry blob was. Layout so far:

| payload offset | value | |
|---|---|---|
| 0 | `0x77` = 119 | self length, = the payload's own size |
| 14 (u32 LE) | 46 | frame rows |
| 18 (u32 LE) | 68 | frame columns |
| 55 onward | floats | 178.0, 182.0, 180.0, 1.0, … per-axis calibration, repeated twice |

46 × 68 = 3128 cells, and the input report is 7488 bytes — so the frame is not
one byte per cell end to end; there is a header and/or padding, which the
capture on hardware will resolve.

### `0x11` — additional parameters

14 non-zero bytes including floats `0.9124` and `50.475`. Thresholds of some
kind; not needed to get frames flowing.

## Procedure for the first boot

This is the one pillar the **baseline** ISO can answer — `CONFIG_SPI_HID=y` and
the touchscreen node already ship in it, so no rebuilt kernel is required.

1. Find the hidraw node whose descriptor has usage page `0x000D`, usage `0x0F`.
2. `HIDIOCGFEATURE` on report `0x05` — expect `01` if Linux inherits the enabled
   state, `00` if the reset put it back to multi-touch reporting.
3. If it reads `00`, `HIDIOCSFEATURE` with `{0x05, 0x01, 0x00 × 118}`.
4. `HIDIOCGFEATURE` on `0x06` and check it matches the block above. If it does,
   the parse here is confirmed on hardware and the geometry is trustworthy.
5. Read input reports and confirm 7488 bytes arriving.

Step 4 is the cheap one that makes the rest trustworthy, because the expected
bytes are already written down here.
