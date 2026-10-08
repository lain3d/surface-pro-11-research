# Root cause: the ADSP restart kills the USB-C root disk

Supersedes the diagnosis sections of `session-state-20260804.md`. That file's
history of eliminated hypotheses is still accurate; its conclusions about the
kernel config are not.

## The failure

Every INTEG boot lost the root filesystem — the T7 over USB-C — 11 to 19 seconds
in, then a wall of red `[FAILED]`. Stock `7.0.0-22-qcom-x1e` reaches a desktop on
the same disk, enclosure and port.

## The cause

From the kernel's own log, streamed to the internal NVMe so it survived the disk
going away:

```
[11.629486] remoteproc remoteproc0: remote processor adsp is now up
[11.650962] PDR: Indication received from msm/adsp/charger_pd, state: 0x1fffffff
[11.665685] PDR: Indication received from msm/adsp/audio_pd,   state: 0x1fffffff
[11.739850] usb 3-1: USB disconnect, device number 2
[11.740056] usb 3-1: stat urb: status -71
[11.741919] I/O error, dev sda, sector 1062221056 op 0x1:(WRITE)
[11.742506] device offline error, dev sda, sector 1761562784
```

**`charger_pd` — the protection domain that owns USB-C power delivery — runs on
the ADSP.** Qualcomm's boot firmware starts the ADSP before Linux does, and
`charger_pd` is already serving PD by the time the kernel loads.

`qcom_q6v5_pas` finds `qcadsp8380.mbn` on the root filesystem and **restarts the
already-running ADSP**:

```
[10.588106] remoteproc1: powering up cdsp
[10.593356] remoteproc1: Booting fw image .../qccdsp8380.mbn, size 3195304
[11.116503] remoteproc0: restarting adsp with new firmware
[11.196075] remoteproc0: stopped remote processor adsp
[11.196081] remoteproc0: Booting fw image .../qcadsp8380.mbn, size 22092168
```

`charger_pd` goes down and comes back with it. **89 ms later the Type-C port
drops the disk.**

## Why stock is immune

Stock does not have the DSP firmware installed:

```
remoteproc0: Direct firmware load for .../qcadsp8380.mbn failed with error -2
remoteproc0: request_firmware failed: -2
```

It gives up in under a millisecond and never touches the running ADSP. **This was
never a kernel config bug** — it is the presence of DSP firmware on the root
filesystem. Config comparisons kept half-pointing at it because the configs do
differ, but the config is not what kills the disk.

This also explains what nothing else did:

- **why the timing varied** (11.8 s, 18.7 s) — ADSP boot time tracks how fast
  22 MB reads off the disk
- **why every DTB change was irrelevant** — integ11 removed all our DT commits
  and failed identically
- **why `USB_UAS` made no difference** — a real defect, correctly found and
  fixed, but not this one

## Confirmed

integ21 booted to a desktop, 2026-08-04. The kernel log is the proof, and it is
a negative one — the entire failure chain is simply absent:

- no `powering up adsp`, no `Booting fw image ... qcadsp8380.mbn`, no
  `restarting adsp with new firmware`, no
  `PDR: Indication received from msm/adsp/charger_pd`
- **zero** matches for `USB disconnect`, `I/O error`, `device offline`,
  `stat urb`, `emergency_ro` or `EXT4-fs error`. The same search returned seven
  lines on the previous boot.
- `kmsg.txt` ends at 21.99 s having simply run out of things to say
- `live.log` ran its full 90 s with `root=rw,relatime,stripe=8191` and uptime
  advancing ~1.01 s per iteration — real seconds, not the free-running count
  that follows a dead disk. It is the only boot in the file that ever reached
  its own `=== sp11-winlog finished ===` marker.

The disk also came up on its native transport for the first time —
`scsi host0: uas`, where every prior boot fell back to `usb-storage`. That is
the `CONFIG_USB_UAS` fix landing, independent of the ADSP question.

## The workaround, and the real fix

`modprobe.blacklist=qcom_q6v5_pas` reproduces stock's state deliberately.
Installed as integ21.

Cost: no audio, no camera ISP, no NPU/fastrpc — exactly what stock already lives
without. **Charging and USB-C are unaffected**; they keep running on the
firmware-resident ADSP.

There is a second-order cost the first draft of this document missed. The boot
log carries:

```
qnoc-x1e80100 interconnect-1:              sync_state() pending due to 6800000.remoteproc
clk-rpmh 17500000.rsc:clock-controller:    sync_state() pending due to 6800000.remoteproc
qcom-rpmhpd 17500000.rsc:power-controller: sync_state() pending due to 32300000.remoteproc
camcc-x1e80100 ade0000.clock-controller:   sync_state() pending due to 1-0010
```

`sync_state()` is how a provider learns every consumer has probed and it may
drop the boot-time constraints that hold resources on. A blacklisted remoteproc
never probes, so that callback never fires and the interconnect, RPMh clock and
RPMh power-domain constraints are held for the life of the boot. Expect higher
idle power draw. **Measure battery life before treating the blacklist as a
daily driver** — and this is a further argument for fixing it upstream rather
than living on the workaround.

The real fix is upstream-shaped: either do not tear down a DSP that firmware
already booted, or make `pmic_glink` re-establish after a PD restart without
renegotiating a live Type-C port. It would hit anyone booting an X1E machine from
a USB-C disk with DSP firmware present.

## What else was fixed on the way

| | |
|---|---|
| `CONFIG_USB_UAS` | absent from every config we built; the root disk is a UAS device and was running the usb-storage BOT fallback. Real defect, not the cause. |
| `CONFIG_REGULATOR_FIXED_VOLTAGE` | `=m`. Every RPMh regulator bank takes its parent supply from `regulator-vph-pwr`, a `regulator-fixed` node, so with no loadable modules all eight banks deferred, the eUSB2 repeaters looped on `unable to get supplies`, and USB never came up. Also explains the dead NVMe and unbound `ps8830` retimer. |
| `CONFIG_TYPEC_MUX_PS883X` | the retimer on this board is `parade,ps8830`. Missing it, `fw_devlink` deferred `usb@a600000` forever. |
| 4 device-tree fixes | voltage grid, PERST#/WAKE#, USB4 GDSCs, SMMU stream IDs — all cleared as innocent by integ11, PRs stand |

## Instrumentation that finally worked

`sp11-winlog` (installed on the root filesystem, `sysinit.target.wants`) streams
`/dev/kmsg` to the **Windows ESP** — a different physical disk, so it survives
the T7 disappearing.

Three constraints made it work, each learned by getting it wrong first:

1. **One long-lived `cat /dev/kmsg`, not a `dmesg` loop.** Once the root
   filesystem stops serving reads, `exec` fails; a loop that re-execs anything
   goes silent exactly when it matters. The first version's log filled with
   `uptime= root_rw=` for this reason.
2. **Mount `-o sync`.** Page-cache writes are lost if power goes before unmount.
3. **Heartbeat with shell builtins only.** `read < /proc/uptime` is a redirect;
   `$(cat ...)` is a process. `sleep` is also a binary — after the disk dies the
   loop free-runs, so post-failure `t=+Ns` labels are iteration counts, not
   seconds. Trust the `uptime=` field.

Why nothing else worked: the journal lives on the disk that dies and always
stops at its last flush; ramoops needs a warm reset and this machine gets
power-cycled at the hang; the initramfs capture is killed at switch-root, two
seconds before the failure.

## Corrections worth keeping

- **A journal ending cleanly at `systemd-journal-flush` is not a healthy boot.**
  It is what a dead disk looks like from inside. This was called "zero I/O
  errors, the config is the fix" and was wrong.
- **`ro,noload` hides the newest writes.** They sit unreplayed in the ext4
  journal. A boot can look absent when it is merely unreplayed.
- **`dev_err` vs `dev_err_probe`.** `qcom-eusb2-repeater` prints `unable to get
  supplies` on every `-EPROBE_DEFER`, so it reads as a hard failure and is not.
- **Grepping a file for a code construct matches your own comments.** Two builds
  were blocked by guards that hit the comment explaining them. Strip comments
  first.
- **`grep -c` prints `0` and exits 1**, so `$(grep -c x f || echo 0)` yields
  `0\n0` and breaks `&&` chains.

## State

## Result: the CDSP is back, and the driver attaches instead of restarting

Confirmed 2026-08-04. Hiding only `qcadsp8380.mbn` under `integ20` produced more
than expected — the driver took a path nobody asked for:

```
remoteproc0: Direct firmware load for .../qcadsp8380.mbn failed with error -2
remoteproc0: attaching to adsp
remoteproc0: remote processor adsp is now attached
remoteproc1: powering up cdsp
remoteproc1: remote processor cdsp is now up
```

**`qcom_q6v5_pas` already has an attach path**, and a missing firmware file is
what selects it. So the correct behaviour — attach to a processor firmware
already booted, rather than tear it down — is one condition away from the
current behaviour. That is the upstream fix, and it is now evidence, not theory:
`design/upstream-adsp-fix.md`.

State: disk survives with no `USB disconnect` or `emergency_ro`, root `rw`
throughout; charging fine; **fastrpc bound with 13 compute contexts**, each in
its own IOMMU group.

**Audio is still absent, and attaching can never fix it.** *(Revised
2026-08-04. The original text here — "attaching does not bring up the ADSP's
glink edge … why is not yet known" — was wrong on both counts.)*

The edge **does** come up, with six channels. The only one missing is
`adsp_apps`, which `gpr` needs. rpmsg devices are created only on a
remote-initiated OPEN, so the handshake replayed and the remote did advertise —
which refutes the stateful-handshake hypothesis. The cause is that Linux
attaches to the ADSP image *firmware* booted: a **12 MiB** image in
`adsp-boot@86b00000`, not the **21.07 MiB** `qcadsp8380.mbn` that targets
`adspslpi@87e00000`. It serves `charger_pd` and has no audio service. Audio
therefore requires actually booting the full image. Full evidence in
`upstream-adsp-fix.md`.

Two claims in the sections above are also superseded: `pd-mapper` runs fine (it
reads the `.jsn` maps, not the `.mbn`), and `CONFIG_USB_UAS` /
`CONFIG_REGULATOR_FIXED_VOLTAGE` were not defects — stock `7.0.0-22` ships both
as `=m` and boots this machine from the same disk. See the end of this file.

## The experiment that produced it: keep the CDSP, drop only the ADSP

Blacklisting `qcom_q6v5_pas` is heavier than the fault requires. The **ADSP** is
already running from boot firmware, so loading its blob makes remoteproc
*restart* it — that is the destructive act. The **CDSP** is cold (`powering up
cdsp`, not `restarting`) and in every failing boot it finished at ~10.6 s with
the disk healthy through 11.7 s.

So: install `integ20` (identical to integ21 except its cmdline omits
`,qcom_q6v5_pas`) and hide only `qcadsp8380.mbn`. remoteproc0 then fails `-2`
exactly as stock does, while remoteproc1 boots.

```
tools/sp11-adsp-fw.sh off      # rename qcadsp8380.mbn -> .disabled
BOOTAA64-integ20-fixedreg.efi  # cmdline: modprobe.blacklist=thunderbolt
```

Expected: fastrpc/NPU back, `sync_state()` resolves for `32300000.remoteproc`
(half the idle-power cost), disk survives, audio still absent. The one untested
element is a CDSP that boots while the ADSP never does — no prior boot has been
in that state.

**Rollback if the disk dies:** power-cycle, reinstall
`BOOTAA64-integ21-noadsp.efi`, and `sp11-adsp-fw.sh on`. `sp11-winlog` is still
enabled, so the console will be on the Windows ESP either way.

```
INSTALLED   BOOTAA64-integ20-fixedreg.efi   DSPs enabled, ADSP firmware hidden
rollback    BOOTAA64-integ21-noadsp.efi     qcom_q6v5_pas blacklisted - reaches a desktop
rollback    BOOTAA64-stock-KNOWN-GOOD.efi   7.0.0-22, reaches a desktop
kernel      7.1.3-sp11-stockcfg-gf2cc827b6b89, 11,918 symbols, stock-derived
modules     7837 installed on the root fs; old trees untouched
```

This machine now has a custom kernel that boots, renders on the GPU at 120 Hz,
and has working WiFi and charging.

## Fixed after first successful boot

**GPU.** `adreno_zap_shader_load` wanted
`qcom/x1e80100/microsoft/Denali/qcdxkmsuc8380.mbn`, got `-ENOENT`, and
`a6xx_hw_init` returned `-2`. Stock never hit this: its DTB has no `zap-shader`
child node, and `zap_shader_load_mdt` returns `-ENODEV` for that case, which
`a6xx_gpu.c` handles by warning once and writing `SECVID_TRUST_CNTL=0`. **A
missing file returns `-ENOENT` and is fatal; an absent node is not.** The blob
was in the Windows driver store all along — installed, and the GPU now inits
clean. Fallback if a blob ever fails to authenticate: delete the `zap-shader`
node from our DTB and take stock's `-ENODEV` path.

**TPM.** `dev-tpm0.device` / `dev-tpmrm0.device` each burn 90 s of
`DefaultDeviceTimeoutSec`. Only `tpm2.target` pulls them in, and with `Wants=`
rather than `Requires=`, which is why boot survives. There is no TPM to find:
Pluton is exposed through ACPI's TPM2 table and `tpm_crb` is ACPI-only, while we
boot device tree. Both units masked. Nothing is lost that was working — every
systemd TPM service already exited with `No complete TPM2 support detected`.

**apt.** `cdrom.sources` (`file:///cdrom`, `main` only, one-time ISO key) was the
only active source. curtin had saved the real archive config as
`ubuntu.sources.curtin.orig`, and apt reads only `*.sources` / `*.list`, so it
was invisible. Activated it, retired the cdrom source.

Diagnosed and deliberately left alone:

- **`pd-mapper` fails** with `no pd maps available`, five times in one second,
  then hits systemd's rate limit and stops. Bounded, not a loop. Direct
  consequence of the DSP blacklist. Leave it failing — it is a useful signal for
  when the DSPs come back.
- **`sssd-*.socket` dependency failures.** `/etc/sssd` has no `sssd.conf`, so
  the service cannot start. Nothing here uses domain auth.
- **Charging is unaffected**, as predicted: `qcom-battmgr-bat` and
  `qcom-battmgr-usb` both present under `pmic-glink`.

## Open items, in order of what they buy:

1. **Measure idle power** against stock, given the `sync_state()` finding above.
2. **Decide the upstream shape** — do not tear down a DSP that firmware already
   booted, or make `pmic_glink` survive a `charger_pd` restart without
   renegotiating a live Type-C port. The second is the more general fix.
3. **Retire `sp11-winlog`.** It still runs 90 s and mounts the Windows ESP `rw`
   on every boot, for no remaining diagnostic value. Unlink it from
   `sysinit.target.wants`; leave the script installed so it can be re-enabled.
4. Confirm the four device-tree PRs still apply cleanly on top of the
   stock-derived config.
