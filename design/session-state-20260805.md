# Session state — 2026-08-05

Supersedes nothing; extends `root-cause-20260804.md` and `upstream-adsp-fix.md`,
both of which remain accurate. Read this one for *where things stand*.

## The headline

**A control test proved the recent boot failures are ours, not the hardware.**
Stock `7.0.0-22-qcom-x1e` — untouched since 2026-08-03, no patch, no overlay —
boots to a desktop with the T7 as root. Every `integ23` boot since the overlay
started actually unpacking has failed with the disk not enumerating at all.

That retires the theory that the T7 or its Type-C port had degraded. It had not.
The user suspected the tooling before I did, and was right.

## What was actually achieved today

| | |
|---|---|
| **GPU** | Fixed. Missing zap shader `qcdxkmsuc8380.mbn` pulled from the Windows driver store. 120 Hz, accelerated. |
| **A real kernel bug found and patched** | `ucsi_glink` treated a protection-domain restart as a device removal, reaching `typec_set_mode(TYPEC_STATE_SAFE)` and electrically disconnecting the root disk. Patch in `patches/0001-ucsi_glink-*.patch`, built as integ22, verified working — the mux is never commanded to `NONE` any more. |
| **The ADSP question settled in principle** | Attaching can never give audio (the firmware-booted image is 12 MiB and contains no audio service). Booting the full image *does* give audio — `adsp_apps` appears 35 ms after the processor comes up. |
| **TPM stalls removed** | Two 90 s waits on `dev-tpm0`/`dev-tpmrm0`, which can never appear under a device-tree boot. |
| **apt fixed** | curtin had left the real archive config as `ubuntu.sources.curtin.orig`; only `cdrom.sources` was active. |

## Addendum 2026-08-05, from the logs alone — no reboot needed

Four things were settled offline, from captures already on disk. They correct
parts of what is written below; the corrections are marked inline.

### 1. integ22 and integ23 differ in exactly ONE section

```
             .cmdline   .dtb       .linux            .initrd
integ20      6735283…   3a61ead…   08a9dab…          2a7fcdc…  57,369,577
integ22      6735283…   3a61ead…   73156051d71c1cf2  2a7fcdc…  57,369,577
integ23      6735283…   3a61ead…   73156051d71c1cf2  d6944a3…  79,710,700
```

Same kernel image, same DTB, same cmdline, same uname. **The ucsi_glink patch is
exonerated** — it is byte-identical in the build that works and the one that
fails. The overlay is the entire difference.

### 2. No device-tree change was ever built

`.dtb` is byte-identical across integ20, integ22 and integ23 (`3a61eadc1ce49ad4`).
The DT changes requested for reliable ordering exist in no staged image. Stating
it plainly because the record implied otherwise.

### 3. Initrd growth is not the mechanism

Stock boots with a **larger** initrd than the one that fails:

```
stock 7.0.0-22   Freeing initrd memory: 86104K   boots
integ23          Freeing initrd memory: 77840K   fails
```

So "the initrd grew and landed on ADSP memory" is dead as stated. Whatever the
overlay does, it is not by being big.

### 4. The root disk is a USB 2.0 device, and always was

This corrects the reasoning in "What is broken" below.

| boot | T7 attaches | Type-C mux / UCSI configured |
|---|---|---|
| stock 7.0.0-22 | 1.567 s, **high-speed** | not within capture |
| integ22 (portwatch) | 1.574 s, **high-speed** | 13.5 s |
| integ22 (unbindfirst) | 1.565 s, **high-speed** | 9.8 s |

`usb 3-1: new high-speed USB device number 2` — the T7 enumerates on the USB 2.0
pins at 1.57 s, **eight to twelve seconds before** any `qmp_combo_mux_set`,
`qmp_combo_switch_set` or `UCSI features` line exists. Those are hardwired pins;
they do not care about orientation, mux state, or the ADSP.

Two consequences:

- The absence of `qmp_combo_*` and `UCSI features` in a failing boot is listed
  below as evidence of what went wrong. **It is not.** Those events simply had
  not happened yet at the point the boot died. Their absence is a symptom of
  dying at ~10 s, not a cause.
- The failure to explain is narrower than thought: something stops a plain
  **USB 2.0 high-speed attach**. That is D+/D- signalling and VBUS, nothing else.

It also means the root filesystem has been running at 480 Mb/s — roughly
40 MB/s — for this entire project, on a drive capable of 20× that. The
SuperSpeed lanes are never switched in because the mux is configured long after
the disk has already attached and nothing re-enumerates it.

### 5. Nothing built in can consume the overlay's firmware

Candidate mechanism 3 below — "something early reaches for the now-present ADSP
image" — is dead. From `config-stockcfg-fixedreg`:

```
CONFIG_QCOM_Q6V5_PAS=m      CONFIG_QCOM_MDT_LOADER=m
CONFIG_QCOM_Q6V5_COMMON=m   CONFIG_QCOM_SYSMON=m
CONFIG_QCOM_PIL_INFO=m      CONFIG_EXTRA_FIRMWARE=""
```

Every driver that could request `qcadsp8380.mbn` is a module, none is in the
base initrd's loadable set, and no firmware is linked into the image. The 22 MB
is inert data until the hook `insmod`s it by hand at 1.81 s — by which time the
disk should already have attached at 1.57 s.

### 6. Why the mux is late — and why an initramfs cannot help

The obvious reading of finding 4 is "the Type-C drivers are modules on the root
disk, so they load too late." **That is wrong**, and it was my first answer.
Every driver in the chain is built in:

```
CONFIG_PHY_QCOM_QMP_COMBO=y   CONFIG_TYPEC_MUX_PS883X=y    CONFIG_TYPEC=y
CONFIG_I2C_QCOM_GENI=y        CONFIG_UCSI_PMIC_GLINK=y     CONFIG_QCOM_PMIC_GLINK=y
CONFIG_PINCTRL_X1E80100=y     CONFIG_QCOM_GENI_SE=y        CONFIG_USB_DWC3_QCOM=y
```

There is nothing to add to an initramfs. And nothing *could* be added usefully:
the disk attaches at **1.565 s** while initramfs userspace only starts at
**1.652 s**. No hook, at any dracut stage, runs before the disk enumerates.

The real cause is a `fw_devlink` dependency cycle, visible at 35 ms:

```
0.035  typec-mux@8: Fixed dependency cycle(s) with phy@fd5000
0.035  phy@fd5000: Fixed dependency cycle(s) with typec-mux@8
0.697  pmic-glink: Failed to create device link (0x180) with supplier 3-0008
0.898  pmic-glink: Failed to create device link (0x180) with supplier a600000.usb
       ... 8.8 seconds of silence ...
9.804  qmp_combo_switch_set()   9.858  UCSI features   9.912  qmp_combo_mux_set()
```

The ps8830 retimer (`typec-mux@8`, on i2c) and the QMP combo PHY each declare the
other as a supplier. `fw_devlink` cannot order them, downgrades the links, and
`pmic_glink`'s connectors never acquire their suppliers — so the whole Type-C
chain sits deferred. Nothing resolves gradually; it all lands at once, which is
the signature of a deferred-probe flush rather than dependency resolution.

**Two candidates for what fires at 9.8 s, and the log cannot distinguish them:**

1. `deferred_probe_timeout` expiring (default 10 s when `CONFIG_MODULES=y`)
2. the deferred queue being re-run by an unrelated success — PCIe comes up at
   9.708 s, 96 ms earlier, which is uncomfortably close

`BOOTAA64-integ25-earlyprobe.efi`
`F9B535B48F25EA342F98DC132C40896AFF65B6F8CB049EA592369A3FA187EC6D`

integ22 with `deferred_probe_timeout=1` appended to `.cmdline` and **nothing
else** — `.dtb`, `.linux` and `.initrd` verified byte-identical to integ22, and
the UKI is the same 73,667,584 bytes. It discriminates:

- **mux configured at ~1.1 s** → it was the timeout, and the disk should
  enumerate SuperSpeed
- **still 9.8 s** → it is the PCIe-triggered re-run, and the fix has to be the
  DT cycle itself

Risk, stated plainly: when the timeout expires, `driver_deferred_probe_check_state()`
starts returning `-ENODEV` instead of `-EPROBE_DEFER`, so a driver still waiting
at 1 s gives up permanently. A boot failure is a plausible outcome. It is
recoverable by restoring `stock-fallback.efi`, and it costs one boot to learn.

### 7. The two USB-C ports are not identical — and every success used the same one

Asked whether the ports differ. Diffed the full chain of both, normalising the
addresses and phandles that must differ. Result:

| compared | difference |
|---|---|
| `usb@a600000` vs `usb@a800000` (mine) | `interconnects` + `interconnect-names` **only** |
| `usb@a6f8800` vs `usb@a8f8800` (stock) | the same, identically |
| combo phy `fd5000` vs `fda000` | none |
| `pmic-glink/connector@0` vs `connector@1` | none |

So there is exactly one asymmetry, it is upstream's rather than mine, and it is
present in the kernel that boots reliably.

**What `interconnects` does.** It names two NoC paths — `usb-ddr` (controller to
memory) and `apps-usb` (CPU to the controller's registers) — and lets
`dwc3_qcom_interconnect_init()` vote for bandwidth with `icc_set_bw()`, scaled to
whether the attached device is high-speed or SuperSpeed. Without the property the
driver makes no vote and the path runs at whatever it was left at. That is a
throughput and QoS concern, **not** a reason a device would fail to enumerate —
so it does not explain this failure.

**But the port question is still the best lead so far**, for a different reason.
Every successful T7 attach on record, across four independent captures and both
kernels, is on **bus 3**:

```
dmesg-live.txt        usb 3-1: Product: PSSD T7 Shield
kmsg.txt   (stock)    usb 3-1: Product: PSSD T7 Shield
portwatch-kmsg.txt    usb 3-1: Product: PSSD T7 Shield
unbindfirst-kmsg.txt  usb 3-1: Product: PSSD T7 Shield
```

Bus 3 is `xhci-hcd.2.auto`, which is `a800000.usb` — the port that *does* have
the interconnect vote. **There is not one record of a successful boot on
`a600000`.** If the drive has been moved between ports across this project, that
is an uncontrolled variable running through the entire dataset, and it would
produce exactly the intermittency that made the overlay look guilty.

**The port is now identifiable from Windows, with no reboot.** Dumping the DSDT
via `GetSystemFirmwareTable` and parsing the `Memory32Fixed` descriptors — each
sits exactly 110 bytes after its device name — gives the mapping:

```
URS0 -> 0xa600000    ACPI\QCOM0C8B\0    xhci-hcd.1.auto    Linux buses 1 and 2
URS1 -> 0xa800000    ACPI\QCOM0C8C\1    xhci-hcd.2.auto    Linux buses 3 and 4
```

which the kernel logs confirm independently: `xhci-hcd.1.auto: io mem 0x0a600000`
and `xhci-hcd.2.auto: io mem 0x0a800000`. `tools/sp11-which-port.ps1` walks the
T7's PnP parent chain to the dual-role controller and reports which port it is
in, exiting non-zero on the bad one.

**And the drive is in the wrong port right now** — `ACPI\QCOM0C8B\0`, URS0,
buses 1 and 2. That is very likely why integ22 stalled tonight, and it means the
integ22 result must not be counted as a data point about integ22.

**Action: run `sp11-which-port.ps1` before every test boot.** Until the port is
controlled, no per-build verdict from a single boot means anything. Note this is
correlation — four successes on bus 3 and no observed success on bus 1 — not
proof that bus 1 can never work.

### 8. The config, not the version — and the counterexample that keeps it a hypothesis

After the overlay, the port, the DTB and the cmdline were each eliminated by a
boot, the remaining difference from stock was the kernel. It is **not** a
7.0.0 → 7.1.3 regression. It is the config:

```
                           stock   mine
TYPEC_UCSI                   m       y
UCSI_PMIC_GLINK              m       y
TYPEC_MUX_PS883X             m       y     the ps8830 retimer
TYPEC_DP_ALTMODE             m       y
I2C_QCOM_GENI                m       y     the bus the retimer sits on
PHY_QCOM_EDP                 m       y
RPMSG_QCOM_GLINK_SMEM        m       y
```

In stock none of that code runs until after root is mounted, so Linux never
touches the Type-C port while the T7 enumerates. Built in, `i2c-qcom-geni`
brings up the bus, `ps883x` probes and resets the retimer over its reset GPIO,
and `ucsi_glink` starts driving the connector — all at 0.5–0.9 s, against an
attach at ~1.5 s.

**This is a hypothesis, not a proven cause, and two things argue for caution:**

1. **integ21, integ20 and integ22 all reached a desktop with this exact config.**
   Commit `70b5ef1` is "integ21 boots to a desktop". So built-in is not
   deterministically fatal. A race fits the evidence — 23 failures alongside
   four successes — but "built-in is broken" does not.
2. **`failures.txt` only records this kernel**, because only this initrd carries
   the capture script. A stock failure would leave no trace anywhere. So "23
   failures, all on mine" is partly selection bias, and the claim that stock
   never fails is unsupported.

### Why it was built in — the reason was real

`integ16-stockcfg-builtin` flipped 16 symbols in one step: `QRTR`, `QRTR_SMD`,
`QCOM_PD_MAPPER`, `RPMSG_QCOM_GLINK_SMEM`, `MFD_SPMI_PMIC`, `I2C_QCOM_GENI`,
`SPI_QCOM_GENI`, `TYPEC_UCSI`, `UCSI_PMIC_GLINK`, `TYPEC_DP_ALTMODE`,
`TYPEC_MUX_FSA4480`, `TYPEC_MUX_NB7VPQ904M`, `CLK_X1E80100_DISPCC`/`TCSRCC`,
`PHY_QCOM_M31_USB`, `USB_ONBOARD_DEV`.

That is the protection-domain and pmic_glink stack, made built-in **so it would
be alive during early boot** — the whole `charger_pd` question is about what
happens before root is mounted, and modules only arrive afterwards.
Modularising it trades that instrument away. Worth doing to get a machine that
starts, but it is a trade, not a free win.

**If integ28 proves the hypothesis, do not leave everything modular.** Split the
set: `QRTR`, `QCOM_PD_MAPPER` and `MFD_SPMI_PMIC` never touch the connector and
can go back to `=y`; only `I2C_QCOM_GENI`, `TYPEC_MUX_PS883X`, `UCSI_PMIC_GLINK`
and `TYPEC_UCSI` need to stay out of early boot.

### NEVER change CONFIG_LOCALVERSION to label a build

`DRM_MSM`, `ATH12K`, `SURFACE_AGGREGATOR` and `HID_GENERIC` are all `=m` and
load from `/lib/modules/7.1.3-sp11-stockcfg-gf2cc827b6b89` on the T7 — that is
how integ20/21 had a working GPU and wifi. Changing the suffix to tag a build
orphans every one of them: no GPU, no wifi, no keyboard. Caught before booting
it; `sp11-build-typec-modular.sh` now refuses to build unless the string matches
the installed tree.

`BOOTAA64-integ28-tcmod.efi`
`022A8DD65D889741482B3E31BAFBD91A9332CCE66F54F5E5D1CBD3F7CD029D9E`
— integ22 with only `.linux` replaced; `.uname` verified as
`7.1.3-sp11-stockcfg-gf2cc827b6b89`. Expect GPU, wifi and keyboard to work and
Type-C to be absent, because the new `.ko` files are not installed on the T7
yet. And expect one good boot to prove little: the failure is intermittent.

### What the logs could NOT settle

There is **no software divergence** between the working and failing boots before
the disk fails to appear. Same kernel, same DTB, same probe order, xHCI up at
0.75 s in both, both controllers, same IRQs. The T7 is simply absent. Nothing in
the overlay executes before 1.81 s, and the disk should have attached at 1.57 s —
so the hook cannot be the cause either.

That is genuinely odd, and it is worth holding open that the failing sample is
confounded: every failure followed a hard power-off, and both T7 filesystems are
dirty. A boot of integ22 on the machine's *current* physical state is the honest
control.

### The discriminator is now staged

`BOOTAA64-integ24-hookonly.efi`
`C4FB6E26CBF006714D2A4731611264108D4CE0103BD65DF36FA9AC837B189DDE`

integ22 plus the pre-mount hook and **nothing else** — a 9,216-byte overlay, so
the UKI is 73,676,800 bytes against integ22's 73,667,584. It controls for size
and isolates the payload:

- **boots** → appending and unpacking a second archive is harmless; the fault is
  in the 22 MB of firmware and modules
- **fails** → the payload is irrelevant and the act of extending the initramfs is
  itself the problem, which would point at the EFI stub or firmware handoff

The hook now reports the disk-appeared/never-appeared result before it needs any
module, so the hookonly build still writes a real log.

Recommended order: **integ22 first** (re-establish the baseline on today's
physical state), then **integ24**.

## What is broken, and what we know about it

**`integ23` prevents the T7 from enumerating.** Not the port, not the drive:

- fails identically on **both** USB-C ports (`a600000.usb` and `a800000.usb`)
- survives a full power-off with the drive unplugged for 30 s
- the drive is `Healthy` in Windows and mounts both volumes
- **UEFI reads a 96 MB UKI off that same disk seconds earlier, every time**
- the USB controllers probe identically to a working boot — same buses, same
  root hubs, within 3 ms — there is simply no device on the port
- no Type-C configuration happens at all: no `qmp_combo_switch_set`, no
  `qmp_combo_mux_set`, no `UCSI features`

### The bisect that has not been run yet

```
integ20   stock-derived kernel, no patch, no overlay      known good, many boots
integ22   integ20 + ucsi_glink patch, no overlay          known good (portwatch ran on it)
integ23   integ22 + initramfs overlay                     FAILS
  └─ except the FIRST integ23, whose overlay was misaligned and never unpacked:
     that one booted to a desktop
```

That last line is the strongest clue in the whole picture. The overlay only
became *live* in the current build. Everything that worked either lacked the
overlay or failed to parse it.

**So the prime suspect is the overlay, not the kernel patch.** The next step is
to boot `integ22` and confirm — if it works, the overlay is responsible and the
patch is exonerated.

### Overlay contents, for whoever bisects it

```
usr/lib/dracut/hooks/pre-mount/50-sp11-ramtest.sh
usr/lib/firmware/qcom/x1e80100/microsoft/Denali/{qcadsp8380.mbn, adsp_dtb.mbn, *.jsn}
sp11/mods/{mdt_loader, qcom_common, qcom_sysmon, qcom_q6v5, qcom_pil_info, qcom_q6v5_pas}.ko + ORDER
```

22 MB, appended as an uncompressed cpio, padded to 4-byte alignment. Candidate
mechanisms, none confirmed:

1. **Memory placement.** The initrd grows 57 MB → 80 MB. The EFI stub allocates
   for it; if that lands on memory the firmware-booted ADSP is using, and the
   region is not marked reserved in the EFI memory map, it would corrupt
   `charger_pd` and take the port down. Argues against: the misaligned build was
   the same size and booted fine — though its overlay was never unpacked, so
   only ~57 MB was ever touched.
2. **Something the unpacked overlay does to the rootfs.** `clean_path()` already
   bit us once by deleting the `/lib` symlink. The type-collision guard added
   since covers that class, but the overlay still `chmod`s and `chown`s
   `.`, `usr`, `usr/lib` and `usr/lib/firmware` — real directories in the base.
3. **The firmware being present in the initramfs.** `CONFIG_QCOM_PMIC_GLINK=y`
   and `CONFIG_UCSI_PMIC_GLINK=y` are built in and probe during kernel init.
   Whether anything early reaches for the now-present ADSP image has not been
   checked.

The cheapest discriminator is to strip the overlay to *only* the hook — no
firmware, no modules — and see whether the disk comes back.

## Machine state as of writing

```
ESP    BOOTAA64.EFI = stock-fallback.efi  68975CE3...  7.0.0-22, BOOTS
       pre-adsp-test-backup.efi           D75D3989...  integ20
C:\sp11-stage\
       BOOTAA64-integ20-fixedreg.efi      D75D3989...  no patch, no overlay
       BOOTAA64-integ22-ucsipatch.efi     7DCB259C...  patch only  <- boot this next
       BOOTAA64-integ23-ramtest.efi       C1F1487D...  patch + overlay, FAILS

T7     qcadsp8380.mbn renamed .disabled (so the ADSP attaches, disk survives)
       zap shader installed; GPU works
       dev-tpm0/dev-tpmrm0 masked; apt fixed
       filesystems dirty from ~10 hard power-offs - worth an fsck

kernel /root/sp11/wt-cfg in WSL, release pinned 7.1.3-sp11-stockcfg-gf2cc827b6b89
       ucsi_glink patch applied but UNCOMMITTED in that worktree
```

## The experiment that still has not run

**Does the Type-C port survive a `charger_pd` restart when nothing is holding
the disk?** Eight boots, zero measurements. Every failure was the harness:

| Attempt | Why it produced nothing |
|---|---|
| interactive dracut shell | no keyboard in the initramfs — every input driver is a module, none packed in |
| from the desktop | bash died when its own text pages faulted off the dead disk |
| unbind USB first | a `dwc3`/`xhci` rebind loses the Type-C mux config, so the device can never return regardless |
| dracut pre-mount hook ×4 | misaligned cpio; then the `lib` symlink deletion; then the disk stopped enumerating |

The harness is now correct — the hook runs, waits for the disk, and writes a real
log. It is the boot underneath it that is broken.

## The decision, now made: NOT the internal NVMe

**Closed 2026-08-05 by the user: no.** They do not want the NVMe shrunk to make
room for it, so it is not on the table — regardless of what it would buy for
audio, boot robustness or throughput. Root stays on the T7, on the Type-C port.

This is a permanent constraint, not a preference to keep re-arguing. Every fix
from here has to work with the root filesystem on that port, which means the
`charger_pd` restart has to be *survived*, not sidestepped. Do not re-raise it.

## Mistakes worth not repeating

- **`objcopy --update-section` silently truncates** to the old section size and
  exits 0. Strip to the stub and re-add at explicit VMAs.
- **`objcopy --dump-section` exits non-zero on success.** Never use it under
  `set -e`; test the artefact.
- **Concatenated initramfs archives must start 4-byte aligned** —
  `init/initramfs.c` takes the cpio path only when `!(this_header & 3)`. Zero
  padding is skipped by the same loop, so pad.
- **Never ship a directory entry whose type differs from the base.**
  `clean_path()` unlinks the existing one. A `lib` directory deleted the
  `/lib → usr/lib` symlink and made the machine unbootable.
- **Avoiding `exec` is not enough after the root disk dies** — bash's own text is
  demand-paged from it. Re-exec from tmpfs first.
- **Pin `CONFIG_LOCALVERSION` when rebuilding.** An unpinned build produced
  `7.1.3-gf2cc827b6b89-dirty`, which boots with no modules at all: no keyboard,
  no wifi.
- **A control test is cheap.** Booting untouched stock settled in one reboot a
  question I had spent four reboots theorising about.
