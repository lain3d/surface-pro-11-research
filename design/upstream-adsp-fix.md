# The upstream shape: booting a DSP that firmware already booted

What breaks, why the obvious workaround is incomplete, and what a real fix has
to do. Background and evidence in `root-cause-20260804.md`.

> **Revised 2026-08-04, from the machine itself.** The "why attaching does not
> give audio" section of this document used to offer two candidate explanations
> and call the question open. It is now settled, and one of the two is refuted.
> See **Why attaching cannot give audio** below. The rest of the document —
> the defect, the attach path, the workaround — stands unchanged.

## The defect in one paragraph

On X1E80100 the ADSP is booted by Qualcomm's boot firmware before Linux starts,
and it is already serving protection domains — including `charger_pd`, which
owns **USB-C power delivery**. When `qcom_q6v5_pas` finds `qcadsp8380.mbn` it
*restarts* that running processor. `charger_pd` goes down and comes back with
it, and 89 ms later the Type-C port drops whatever is attached. On a machine
whose root filesystem is a USB-C disk, that is fatal to the boot. Nothing
warns; from userspace it looks like the disk failed.

```
[11.116503] remoteproc0: restarting adsp with new firmware
[11.196075] remoteproc0: stopped remote processor adsp
[11.629486] remoteproc0: remote processor adsp is now up
[11.650962] PDR: Indication received from msm/adsp/charger_pd, state: 0x1fffffff
[11.739850] usb 3-1: USB disconnect, device number 2
```

It is not specific to this laptop. Any X1E machine booting from a USB-C disk,
dock or enclosure with DSP firmware installed should hit it.

## The attach path already exists, and is reached by accident

`qcom_q6v5_pas` has an attach path. `qcom_pas_attach` → `qcom_q6v5_attach`, and
`__rproc_attach()` runs `rproc_prepare_subdevices` → `rproc_attach_device` →
`rproc_start_subdevices` before setting `RPROC_ATTACHED`. Verified in-tree.

But **it is selected by the firmware being absent, not by the processor being
already up.** Hide `qcadsp8380.mbn` and the driver does exactly the right thing:

```
remoteproc0: Direct firmware load for .../qcadsp8380.mbn failed with error -2
remoteproc0: attaching to adsp
remoteproc0: remote processor adsp is now attached
```

Disk survives, `charger_pd` is never disturbed, PD keeps working.

## Why attaching cannot give audio

**Settled 2026-08-04 on hardware. This replaces the two-hypotheses section.**

The old text said the ADSP's glink edge "never enumerates" on an attached
processor. That was wrong. It enumerates six channels:

```
/sys/bus/rpmsg/devices/6800000.remoteproc:glink-edge.*
    APPS_ADSP_PWR_LMTS_GLINK_PORT
    IPCRTR
    LOOPBACK_CTL_LPASS
    PMIC_LOGS_ADSP_APPS
    PMIC_RTR_ADSP_APPS
    glink_ssr
    rpmsg_ctrl
```

Missing is exactly one: **`adsp_apps`**, which is what `gpr` asks for
(`qcom,glink-channels = "adsp_apps"` in the live DTB, under
`remoteproc@6800000/glink-edge/gpr`, with `service@1` q6apm and `service@2`
q6prm both in `avs/audio` + `msm/adsp/audio_pd`).

In `qcom_glink_native.c`, an rpmsg device is created only in
`qcom_glink_rx_open()` with `create_device = true` — that is, **only when the
remote sends OPEN**. Six OPENs arrived. So:

- **The old hypothesis (2) — "glink over SMEM is a stateful handshake and the
  advertisement never replays" — is refuted.** The handshake replayed and the
  remote advertised six channels. The transport is fine.
- **Hypothesis (1) is correct, and now has a mechanism.**

**The mechanism: Linux is attached to the wrong ADSP image.** X1E boots a
separate, smaller ADSP image from firmware, in its own carveout:

| Region | Size | Referenced by |
|---|---|---|
| `adsp-boot@86b00000` + `adsp-boot-dtb` | **12 MiB** | **no DT node at all** |
| `adspslpi@87e00000` + `q6-adsp-dtb` | 58 MiB | `remoteproc@6800000` |

`qcadsp8380.mbn` is **21.07 MiB** — it does not fit in 12 MiB. So the attached
processor is not running it. `hamoa.dtsi` is the **only** SoC dtsi in the tree
with an `adsp-boot` region (checked against sm8550/8650/8750, glymur, milos,
kaanapali, eliza, qcs8550), so this early boot-ADSP is X1E-specific, and the
carveout exists purely to keep Linux out of it.

Positive control — `strings` on the full image finds every channel the running
one advertises, **plus** the missing one:

```
adsp_apps ✓   audio_pd ✓   avs/audio ✓   charger_pd ✓
LOOPBACK_CTL_LPASS ✓   PMIC_RTR_ADSP_APPS ✓   IPCRTR ✓   glink_ssr ✓
```

The PD maps agree: `avs/audio` lives in `msm/adsp/audio_pd` (`adspua.jsn`),
while `charger_pd` is its own subdomain (`battmgr.jsn`). The firmware boot image
serves charger/PMIC — exactly what is observed — and contains no audio service.

There is also no way to force the channel from the apps side:
`glink_device_ops` has **no `.create_channel`**, so `/dev/rpmsg_ctrl0` cannot
open `adsp_apps` locally. Nothing in userspace can fix this.

**Conclusion: attaching keeps the disk alive and costs nothing, and it can
never deliver audio.** Not "mechanism unknown" — structurally impossible. Audio
requires Linux to actually boot `qcadsp8380.mbn`, which means the ADSP restart,
and therefore the Type-C drop, is unavoidable.

## The disconnect is self-inflicted, and the line is known

**2026-08-04. This supersedes any framing of the drop as hardware behaviour.**
Nothing physical disconnects. **The kernel commands the mux to disconnect.**

The path, all in software:

```
charger_pd PDR down
  → pmic_glink_ucsi_pdr_notify()          sets pd_running = false, schedules work
  → pmic_glink_ucsi_register()            ucsi_registered && !pd_running → ucsi_unregister()
PDR up
  → ucsi_register(), which re-reads every connector
  → pmic_glink_ucsi_connector_status()    ucsi_glink.c
        if (!UCSI_CONSTAT(con, CONNECTED))
                typec_set_orientation(con->port, TYPEC_ORIENTATION_NONE);
  → typec_switch_set() → qmp_combo_switch_set(new_orientation=0)
  → the mux disconnects the lanes → "usb 3-1: USB disconnect"
```

The log matches line for line. `new_orientation=0` is `TYPEC_ORIENTATION_NONE`:

```
[131996878] ucsi_glink...: UCSI features: 0x0004        re-registered
[132006236] fd5000.phy-switch: new_orientation=0        NONE  <- disconnect
[132020094] fda000.phy-switch: new_orientation=0        NONE  <- disconnect
[132040953] fda000.phy-switch: new_orientation=2        REVERSE, moments later
[132071954] fda000.phy-mux:    mux_set mode=1           USB again
```

**It is a race.** On re-registration UCSI asks a PD controller that has just
rebooted and has not finished its own attach detection. It answers "not
connected". The kernel believes it and pulls the lanes. Milliseconds later the
connector reports connected with the right orientation and everything is put
back — but by then the USB device is gone, and re-attach needs a connect event
that will never come because the cable never moved.

Note `qcom_battmgr` handles the same notification correctly: `service_up = false`
and nothing else. Only the UCSI client tears its world down.

**So this is fixable in the kernel, in a few lines.** Options, narrowest first:

1. Do not act on a `not connected` reading taken immediately after a PDR
   recovery — treat the connector state as unknown until it settles.
2. Do not `typec_set_orientation(NONE)` from the *re-registration* path at all;
   only from a genuine connector-change event reporting disconnect.
3. Do not `ucsi_unregister()` on PDR down, matching `qcom_battmgr`. Mark the
   service down, stop issuing commands, reconcile on recovery.

**Test it without a patch:** blacklist `ucsi_glink`. No UCSI client, no
`connector_status` callback, no orientation NONE. `pmic_glink_altmode` still
drives the mux from ALTMODE notifications. If the disk survives an ADSP restart
with it blacklisted, the diagnosis is confirmed and the workaround costs only
UCSI-based PD status reporting.

## The patch works, and it is not sufficient

**integ22, tested 2026-08-04.** Verified the patched kernel booted — build stamp
`#12 SMP ... Tue Aug 4 16:44:22 CDT 2026`, where integ20 is 09:02. Note `uname -r`
cannot tell them apart: the release string was pinned identical on purpose, so
the module tree keeps matching. **Use the build date.**

The fixed bug is gone:

| | before (integ20) | after (integ22) |
|---|---|---|
| `debugfs: already exists in 'ucsi'` | present | **absent** |
| `UCSI features: 0x0004` | twice (boot + PDR) | **once, at boot** |
| `new_orientation=0` (NONE) after PDR | both ports | **never** |

UCSI no longer unregisters, and the mux is never commanded to safe state.

**But the disk still drops, and the signature reversed.** Before, the disconnect
came first and the transfer error followed it. Now the error comes first:

```
[305289806] PDR: Indication received from msm/adsp/charger_pd
[305371918] sd 0:0:0:0: [sda] tag#7 data cmplt err -71 uas-tag 4 inflight: CMD
[305371952] usb 3-1: stat urb: status -71
[305372348] usb 3-1: USB disconnect, device number 2
```

`-71` is `-EPROTO`: the USB link failed at protocol level, mid-write, 82 ms after
the `charger_pd` indication — and *then* the hub reported a disconnect. Nothing
in the kernel commanded it this time. The mux is only touched at 305.669, long
after, and only to re-apply the same orientation it already had.

**So there were two independent causes and this fixes one.** The remaining one is
below the kernel: when `charger_pd` restarts, the PD firmware re-initialises the
port and the link dies. Linux is not doing it and, as three rebind runs showed,
cannot undo it.

**Leading suspect: VBUS.** The T7 is bus-powered. If the restart drops VBUS and
does not re-assert it, the device is unpowered — which explains the mid-transfer
`-EPROTO`, the disconnect, and the permanent empty port afterwards. Cheapest
test in existence: **watch the T7's activity LED across the drop.** Dark and
staying dark means VBUS. Next cheapest: have `sp11-portwatch` log the UCSI
power-supply node's `voltage_now` through the window.

The patch remains worth keeping and worth upstreaming on its own merits — it
fixes a real self-inflicted disconnect that would bite any X1E machine with
anything attached during a DSP restart. It just is not the whole story here.

## What this means for the upstream patch

The earlier framing — "a complete fix needs both halves, attach instead of
restart *and* get glink channels on an attached edge" — is wrong. The second
half is not achievable and should not be attempted.

Worse, there is a trap in the shape this document originally proposed. "Decide
boot-vs-attach on the state of the remote processor" would make **every** X1E
machine attach to the firmware boot image and silently lose audio, camera ISP
and NPU/fastrpc. That turns a bug specific to USB-C-root machines into a
universal regression.

So:

| | |
|---|---|
| **attach instead of restart** | keeps USB-C alive. Correct behaviour *only* when the user does not want the DSP's services. Must be **opt-in** — cmdline or DT — never inferred from processor state. |
| **survive a `charger_pd` restart** | the real general fix. `pmic_glink` re-establishing after a PD restart without renegotiating a live Type-C port. |

The second is what actually deserves upstreaming. The first is worth sending
only if it is explicitly opt-in, and must be described as "do not break the
disk", never as "fix the ADSP".

## What this machine runs today

`integ20` (cmdline blacklists only `thunderbolt`) plus `qcadsp8380.mbn` renamed
`.disabled` via `tools/sp11-adsp-fw.sh`. Result:

- disk survives; no `USB disconnect`, no `emergency_ro`, root `rw` throughout
- ADSP attached, PD and charging working
- **CDSP fully booted** — `remote processor cdsp is now up`, fastrpc bound with
  13 compute contexts each in its own IOMMU group
- audio absent, for the reason above

Two corrections to notes elsewhere, both checked on the machine:

- **`pd-mapper` runs fine.** `root-cause-20260804.md` records it failing with
  `no pd maps available`; it reads the `.jsn` maps, not the `.mbn`, so hiding
  the firmware never affected it.
- **No userspace `qrtr-ns` is needed.** The name service is in-kernel
  (`net/qrtr/ns.c`). Its absence from systemd is not a bug — do not chase it.

One loose end visible in the same log:

```
qcom,fastrpc ...fastrpcglink-apps-dsp: no reserved DMA memory for FASTRPC
```

This is **not** upstreamable as first thought: mainline `hamoa.dtsi` has no
`memory-region` on *either* fastrpc node. Ours has one on the ADSP only, from
the jglathe import. A local tree inconsistency, and there is no CDSP
remote-heap carveout to point at anyway.

## Getting audio anyway

Three routes, cheapest first.

**1. Move root off the Type-C port.** `denisix/ubuntu-surface-pro-11` has audio
working on this exact SKU with **no ADSP workaround at all** — it installs the
firmware and lets remoteproc boot the ADSP. It never hits this bug because it
installs to the **internal NVMe**. Shrink Windows, put root there, restore the
firmware. No kernel work.

**2. Boot the ADSP from the initramfs, before root is mounted.** The Type-C port
drops at a moment when nothing holds the disk, and root is mounted afterwards.
Three facts make this workable:

- the cmdline is `root=UUID=…`, so the disk returning as `sdb` is harmless
- `qcom_q6v5_pas` is a **loadable module**, so nothing touches the ADSP until
  something calls `modprobe` — full control of the timing from a dracut hook
- the UKI is rebuildable on the machine itself with `objcopy` (no kernel build)

**ANSWERED 2026-08-04: no, and it cannot be forced back.** Three runs of
`sp11-portwatch` from a booted desktop. PD itself recovers in ~280 ms and the mux
is put back into USB mode:

```
[131740565] usb 3-1: USB disconnect, device number 2
[131996878] ucsi_glink...: UCSI features: 0x0004
[132071954] fda000.phy-mux: qmp_combo_mux_set() enter mode=1, altmode=0
```

Then unbinding and rebinding **both** `xhci-hcd` instances and both
`dwc3-qcom` controllers rebuilds the root hubs from scratch — and finds nothing:

```
[146760385] hub 3-0:1.0: USB hub found
[146760471] hub 3-0:1.0: 1 port detected
```

The host stack is healthy; **attach detection never re-runs**. So route 2 as
written does not work: a disk that has been dropped stays dropped, whether root
is mounted or not.

**But route 2 has a variant that does not need re-attach at all.** Restart the
ADSP *before USB has ever enumerated* — in a dracut `cmdline`-stage hook, ahead
of the first `usb 3-1: new high-speed USB device` at ~1.57 s. The port then does
a **first** attach after the disruption rather than a re-attach, and first
attach demonstrably works: it happens on every boot. This needs the firmware and
`qcom_q6v5_pas` inside the initramfs, since root is not available that early —
so it is a cpio append onto `.initrd` plus the UKI surgery already scripted.
**Untested. It is the cheapest remaining route that keeps root on the T7.**

Prevention is the other untried angle. The disconnect lands **249 µs** after
`debugfs: 'pmic_glink.ucsi.0' already exists in 'ucsi'`, i.e. exactly as
`pmic_glink` re-registers its aux devices following the PDR restart. If the
altmode/typec teardown is the proximate cause, `blacklist pmic_glink_altmode` in
`/etc/modprobe.d/` may stop the port ever being torn down — no UKI rebuild, one
reboot to test. Verify the machine still boots with it before restarting the
ADSP, since that driver also programs the mux for USB.

**3. Root in RAM.** 30 GB available. Boot the ISO with casper's `toram` and the
disk dropping is irrelevant. No persistence, but it is the fastest way to get a
working audio stack to develop the topology and UCM work against.

### The experiment, already built

```
tools/sp11-build-adsp-test-uki.sh
    rebuilds the UKI with rd.break=pre-mount and qcom_q6v5_pas blacklisted
    (--install / --rollback / --status). The blacklist matters: udev otherwise
    autoloads the driver during coldplug and binds the ADSP in attach mode
    before you get a prompt.

/usr/local/sbin/sp11-adsp   (source: tools/sp11-adsp-initramfs-boot.sh)
    run at the dracut prompt. Stages firmware from a read-only root, unmounts,
    loads the driver, times how long the root device is gone and whether it
    returns, then reports whether adsp_apps appeared.
```

Public-source handoff: both tools are included in this research checkout.
The `/usr/local/sbin/sp11-adsp` path above is a copy of the public helper on the
target root, not a private repository dependency. See
[the tooling handoff](../handoff/distro-tools/README.md) for source provenance,
deployment assumptions, and the historical nature of this experiment.

At the `dracut:/#` prompt:

```sh
mkdir -p /sp11root
mount -o ro /dev/sda5 /sp11root
/sp11root/usr/local/sbin/sp11-adsp
exit                      # resumes the boot; dracut mounts root by UUID
```

**Correction, 2026-08-04.** This section used to say the question could not be
answered from a running desktop because
`echo stop > /sys/class/remoteproc/remoteproc0/state` hangs the whole SoC
(denisix's README warns of it). **It does not.** Run three times from a booted
desktop via `sp11-portwatch`: `stop` then `start` took the ADSP from `attached`
to `running` on the full image every time, `adsp_apps` appeared, and the kernel
kept logging for ~50 s afterwards. What dies is the root filesystem, not the SoC
— which is survivable as long as the log goes to the internal NVMe and nothing
after the trigger needs an `exec`. The dracut route was never usable here
anyway: that prompt has no keyboard (see `START-HERE.md`).

## Still needed after the ADSP boots

Booting it is necessary, not sufficient. All four are solved in
`denisix/ubuntu-surface-pro-11`:

| Gap | Where |
|---|---|
| SP11 AudioReach topology (not in `linux-firmware`) | `audio/firmware/X1E80100-Microsoft-Surface-Pro-11-tplg.bin` |
| UCM2 profile — without it PipeWire sees the card but creates no sinks | `audio/ucm/` |
| `alsactl` restores WSA mixer state before the DSP graph loads → APM CMD timeout, SoundWire bus clash, silence | mask `alsa-restore`/`alsa-state`, use a WSA routing service |
| DMIC static at 4.8 MHz | needs 2.4 MHz — already commit `18b0b569c`, now PR #8 |
