# Session state — 2026-08-05, evening

> **SUPERSEDED by `session-state-20260806.md`.** Everything here is still
> accurate, but it is chronological and hard to read cold. Read the newer one
> first; come back here for the blow-by-blow of how each conclusion was reached.
> Two claims below were later overturned and are marked in place: the USB-C port
> rule, and "the port never comes back".

Supersedes the diagnosis in `session-state-20260805.md`. That document's
*facts* still hold (the port asymmetry, the config finding, the eliminations),
but its framing — overlay, device tree, initramfs — was wrong, and this one
explains why. Read this for where things stand.

## The headline

**The root disk failures were three separate drivers each reconfiguring
hardware that firmware had already configured and was actively using.** On a
normal machine that is an invisible glitch. Here the hardware in question is
carrying the root filesystem, so it is fatal.

Boot success went from **0 of several** to **5 of 6**. Three patches, all
independently upstreamable, are in `patches/`.

The machine now reaches a desktop with GPU, wifi and keyboard, and the T7
enumerates at **SuperSpeed Plus Gen 2x1 on `usb 4-1`** rather than the USB 2.0
high-speed it had been running at all along.

## The three bugs

| # | driver | what it did | evidence |
|---|---|---|---|
| 0001 | `ucsi_glink` | treated a protection-domain restart as a disconnect, reaching `typec_set_mode(TYPEC_STATE_SAFE)` | mux commanded to `NONE` after a `charger_pd` PDR |
| 0002 | `ps883x` | reset a retimer firmware left running; then, once that was fixed, rewrote its connection-status registers anyway | `usb 4-1: cmd cmplt err -71` 250–460 ms after probe |
| 0003 | `phy-qcom-qmp-combo` | power-cycled a PHY firmware left running, because its cached mode is seeded with the enum's zero value | `mux_set exit mode=1, new_mode=2` → `-71` |

### 0002 in detail — two distinct defects in one driver

**Probe.** The driver already detects a firmware-configured retimer and
carefully avoids resetting it — the reset GPIO is even requested `GPIOD_ASIS`
for that reason — and then calls `ps883x_reset()` unconditionally two lines
later, throwing the detection away. Moving that call inside the `else` branch
is the fix.

**Notification.** `ps883x_configure()` issues three *unconditional*
`regmap_write()`s to `REG_USB_PORT_CONN_STATUS_0/1/2` plus a 20–30 ms settle.
Writing identical values still pokes the chip's connection state machine. Read
first, skip the whole sequence when nothing would change.

Note the interaction: before the probe fix, `ps883x_sw_set()` returned early
because `in_reset` was true. Fixing probe *exposed* the notification defect.
The second fix is a consequence of the first, not an independent discovery.

### 0003 in detail

```c
enum qmpphy_mode { QMPPHY_MODE_USB3DP = 0, QMPPHY_MODE_DP_ONLY, QMPPHY_MODE_USB3_ONLY };
qmp->qmpphy_mode = QMPPHY_MODE_USB3DP;   /* the enum's zero, not an observation */
```

Firmware leaves the PHY in `USB3_ONLY` for a plain USB-C device. The driver
assumes `USB3DP`, so the first notification computes `USB3_ONLY`, misses the
"same mode, bail out" path, and runs
`usb_power_off → com_exit → com_init → usb_power_on` under a live link. Seeding
the cache with `USB3_ONLY` makes it a no-op. A genuine DP attach arrives with a
DP SVID and still switches modes, which is meant to be disruptive.

## What was eliminated, and in what order

Every one of these cost at least one boot, and the first four were my own wrong
turns:

1. **The initramfs overlay** — integ22 has no overlay at all and failed
   identically. The whole 08-05 daytime bisect was chasing the wrong variable.
2. **The device tree** — integ26 carried stock's `.dtb` and failed. My flat
   dwc3 binding is legitimate: `dwc3-qcom` matches `qcom,snps-dwc3` and computes
   qscratch as `reg.start + 0xf8800`, which lands exactly on `0xa6f8800`.
3. **The kernel command line** — integ27 used stock's exact cmdline and failed.
4. **A 7.0.0 → 7.1.3 regression** — never tested, because the config turned out
   to explain it.
5. **The USB-C port** — real and worth controlling (every success is on bus 3/4),
   but not sufficient: integ26 and integ27 failed on the verified good port.
6. **`ucsi_glink`** — blacklisted alone in integ30 and the disk died at the same
   moment. Exonerated as the cause of *this* failure.
7. **The CDSP boot** — happens in the surviving boots too.

## Configuration that matters

The Type-C stack must be **modular**, as Ubuntu ships it — built in, it probes at
0.5–0.9 s against a disk attaching at ~1.3 s:

```
=m   TYPEC_UCSI  UCSI_PMIC_GLINK  TYPEC_MUX_PS883X  TYPEC_DP_ALTMODE
=y   PHY_QCOM_EDP  PHY_QCOM_QMP_COMBO  I2C_QCOM_GENI  RPMSG_QCOM_GLINK_SMEM
     CLK_X1E80100_DISPCC  DRM_MSM_DP  storage  xhci  dwc3  pmic_glink
```

**`PHY_QCOM_EDP` must stay built in.** Modularising it cost a boot: the internal
panel hangs off `displayport-controller@aea0000` with `dp_aux_backlight`, so
without the eDP PHY that controller never probes, `msm_dpu` never binds, and the
machine sits on `simpledrm` with a black screen. Nothing to do with USB-C.

**`msm` is a component driver.** It will not complete until *every*
displayport-controller registers, including the USB-C ones at `ae90000` and
`ae98000`. So `ps883x` cannot simply be blacklisted — doing that strands them at
`failed to acquire drm_bridge` and there is no display at all.

**`regulator_ignore_unused` is required.** The cmdline had carried
`clk_ignore_unused` and `pd_ignore_unused` all along and was missing the third
sibling. With `ps883x` blacklisted nothing claimed the retimer's rails, and at
~31 s the unused-regulator sweep switched `VREG_RTMR0/1_1P15/1P8/3P3` off; the
disk disconnected 2 ms later.

## Machine state

```
ESP    BOOTAA64.EFI = BOOTAA64-integ33-panen.efi
       102F24D15526BAC4D361ED14BE3A686540ED1838DB4D651BA2DF33410AA8E180
prev      C:\sp11-stage\BOOTAA64-integ31-qmpfix.efi     6103FF1D...  (no PAN_EN knob)
fallback  C:\sp11-stage\BOOTAA64-stock-KNOWN-GOOD.efi   68975CE3...  (stock 7.0.0-22)

cmdline  root=UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd ro loglevel=7 console=tty0
         clk_ignore_unused pd_ignore_unused arm64.nopauth
         modprobe.blacklist=thunderbolt regulator_ignore_unused
         pmic_glink_altmode.pan_enable=0

         NO_LPM was dropped after round two eliminated it. Flip pan_enable
         between 0 and 1 with tools/sp11-patch-cmdline.sh - no kernel rebuild.

modules  NOT reinstalled for integ33 and they do not need to be:
         CONFIG_MODVERSIONS is not set, so only vermagic has to match and
         CONFIG_LOCALVERSION is unchanged. Only a builtin was touched.

port     ACPI\QCOM0C8C\1 = URS1 = 0xa800000 = Linux buses 3 and 4
         check with tools\sp11-which-port.ps1 before EVERY test boot

T7       /lib/modules/7.1.3-sp11-stockcfg-gf2cc827b6b89  matches the running kernel
         /etc/modprobe.d/sp11-typec.conf  REMOVED - ucsi_glink loads again
         /etc/modprobe.d/sp11-adsp.conf   REMOVED - the ADSP and CDSP load again
                                          (sp11-set-typec-blacklist.sh ucsi-only / noadsp restore them)
         NOTHING of ours is blacklisted any more - verified against the disk

snapshot data/integ33/ holds the diff, .config, release and base commit;
         C:\sp11-stage\BOOTAA64-integ33-KNOWN-GOOD.efi = 102F24D1... is the
         labelled fallback for the reliable configuration
         qcadsp8380.mbn renamed .disabled  (so the ADSP attaches, never restarts)
         zap shader qcdxkmsuc8380.mbn installed
         dev-tpm0/dev-tpmrm0 masked; apt fixed
         filesystem CLEAN - e2fsck 1.47.2 run from the disk's own binary

kernel   /root/sp11/wt-cfg in WSL, CONFIG_LOCALVERSION="-sp11-stockcfg-gf2cc827b6b89"
         patches applied but UNCOMMITTED in that worktree; copies in patches/
```

## The three boots have been read — and the failure mode has changed

Two reached the desktop (`kmsg.2.txt`, `kmsg.1.txt`); the third died
(`kmsg.txt`). All three carry the fix signatures:

```
ps883x_retimer 3-0008: probe: CONNECTION_PRESENT=1 -> leaving retimer running
ps883x_retimer 5-0008: probe: CONNECTION_PRESENT=1 -> leaving retimer running
qcom-qmp-combo-phy fda000.phy: typec_mux_set: already in mode 2, not touching the PHY
usb 4-1: new SuperSpeed Plus Gen 2x1 USB device number 2
```

**`conn_status already ...` never printed — in any of the three.**
`ps883x_configure()` is not reached at all, so patch 0002's second hunk is not
being exercised and the retimer's connection-status registers are not the
remaining trigger. The only ps883x hardware access in the window is the
`regmap_assign_bits()` in `ps883x_sw_set()`, which is a read-modify-write and
should not write when the orientation bit already matches.

`qmp_combo_switch_set()` appears in all three boots with
`new_orientation=1, orientation=1` and returns at the equality check on line
4434 — a no-op, not a suspect.

### What the failing boot actually shows

```
1.293  usb 4-1: new SuperSpeed Plus Gen 2x1 USB device number 2
5.674  ps883x probe, both retimers left running
6.120  fda000.phy-switch: qmp_combo_switch_set() ... orientation=1   (no-op)
6.136  usb 4-1: cmd cmplt err -71     x3
6.161  sd 0:0:0:0: [sda] FAILED Result: hostbyte=DID_NO_CONNECT
6.204  EXT4-fs error ... 6.255 potential data loss ... emergency_ro
11.844 usb 4-1: disable of device-initiated U1 failed.
11.844 usb 4-1: enable of device-initiated U1 failed.
12.018 usb 4-1: reset SuperSpeed Plus Gen 2x1 USB device number 2   <-- came back
```

Two things make this a **different fault from the one we fixed**:

1. **The device recovers.** A plain `usb_reset_and_verify_device()` at 12.0 s
   re-establishes it at the same address. The port, the mux, the retimer and the
   PHY are all fine. Previously the port never re-enumerated at all. The
   filesystem was simply already dead by then.
2. **`cmd cmplt err -71` is `uas_cmd_cmplt()`** (`drivers/usb/storage/uas.c:444`)
   — the UAS *command* URB failing with `-EPROTO`. That is a symptom of the link
   dropping, not a cause.

And the U1 messages at 11.844 s prove **USB 3 link power management was enabled
on this device**: `usb_set_device_initiated_lpm()` only logs that if the kernel
had U1 turned on. U1/U2 do not exist on USB 2.0, so this failure mode became
*possible for the first time* when the earlier fixes got the disk onto
SuperSpeed.

**Leading hypothesis: a U1/U2 exit failure on an idle SuperSpeed link.** It fits
every observation — SuperSpeed-only, `-EPROTO` on the next transfer, recoverable
by reset, and intermittent because it depends on when the link happens to go
idle.

### The experiment now staged

`BOOTAA64-integ32-nolpm.efi` — integ31 with one cmdline token added, nothing else
touched (`.dtb`, `.linux`, `.initrd` verified byte-identical):

```
usbcore.quirks=04e8:61fb:k     # 04e8:61fb = Samsung PSSD T7 Shield, k = USB_QUIRK_NO_LPM
```

Installed to the **T7** ESP as `\EFI\BOOT\BOOTAA64.EFI`,
`2D3DA070C44B1B6D362247EB7C85C00025A59933B01CEBBC80C8179656DCFA49`.

Judge on **10+ boots**, not 3. If failures persist with no U1 message anywhere,
the next lever is dropping UAS to bulk-only: `usb-storage.quirks=04e8:61fb:u`.

### Round two: LPM eliminated, and the bug found a third time

Ten boots on integ32. **Nine clean, one death** (`live.log` boots 40–49). The
quirk demonstrably took effect — the `device-initiated U1` messages present in
the previous failure are **completely absent** — so LPM was genuinely off and it
failed anyway. **`USB_QUIRK_NO_LPM` is eliminated.** The rate moved 7/10 → 9/10,
which is not significant; treat it as noise, not a partial fix.

What the boot did give us is a hard number:

```
6.520372  fda000.phy-switch: qmp_combo_switch_set() ... orientation=1
6.536654  usb 4-1: cmd cmplt err -71            <- 16.3 ms
12.222    usb 4-1: reset SuperSpeed Plus Gen 2x1  <- recovers, as before
```

The previous failure was **16.1 ms** after the same event. Two independent
failures 0.2 ms apart is a deterministic reaction to the driver, not a link
event — and it matches the ~18 ms already recorded for the conn_status writes.

`ps883x_sw_set()` is the only code touching hardware in that window, and it
carries **the same bug for the third time**:

```c
retimer = devm_kzalloc(...);              /* orientation = 0 = ORIENTATION_NONE */
...
if (retimer->orientation != orientation)  /* NONE != NORMAL — always true */
        regmap_assign_bits(regmap, REG_USB_PORT_CONN_STATUS_0, ...);
```

Cached state seeded with a default while the chip is already configured and
passing traffic — exactly `qmpphy_mode` in 0003 and the unconditional reset in
0002. Patch **0004** seeds `retimer->orientation` from
`CONN_STATUS_0_ORIENTATION_REVERSED` at probe.

Note `regmap_assign_bits()` → `_regmap_update_bits()` with `force_write=false`,
and `ps883x_retimer_regmap` sets no `cache_type`, so it reads the chip and
writes only when the bit actually differs. **If the write is being skipped, the
i2c read alone is the trigger** — 0004 removes both, and the new
`sw_set: cached=N notified=N` line says which case we were in.

### Machine state for this round

ESP reverted to **integ31** (NO_LPM dropped, since it is eliminated), so the
only delta from the last run is the module. Modules rebuilt and installed;
`qcadsp8380.mbn.disabled` verified still hidden. What to look for:

```
ps883x_retimer 5-0008: probe: conn_status_0=xx -> seeding orientation=N
ps883x_retimer 5-0008: sw_set: cached=N notified=N -> no change, not touching the chip
```

and no `cmd cmplt err -71`. If `sw_set` says "not touching the chip" and the link
still dies at +16 ms, the remaining suspect is the i2c transaction itself or
something else on `i2c@b9c000`.

### Round three: the drivers are exonerated, and the ADSP is the last suspect

Eight boots, one death (`live.log` 50–57). The seeding worked and the
instrumentation answered the question outright:

```
6.1626  qmp_combo_switch_set() enter new_orientation=1, orientation=1   (no-op)
6.1626  ps883x 5-0008: sw_set: cached=1 notified=1 -> no change, not touching the chip
6.1775  usb 4-1: cmd cmplt err -71                                     <- +14.9 ms
6.1935  qmp_combo_mux_set() -> already in mode 2, not touching the PHY
```

`conn_status_0=21` (`CONNECTION_PRESENT | USB_3_1_CONNECTED`, orientation bit
clear) on both retimers, so the seed is right and the write was **never
happening in the first place** — `regmap_assign_bits()` had been skipping it.
**The retimer was not touched. The PHY was not touched. The link died anyway.**

So the whole local-driver family is eliminated: no reset, no conn_status write,
no orientation write, not even the i2c read, and LPM off didn't help either.
0004 is still correct (cached state should come from hardware) but it is not the
cure.

**What survives is the timing.** The `-71` lands **14.9 / 16.1 / 16.3 ms** after
the `pmic_glink` altmode notification, across three independent failures. That
notification comes **from the ADSP** — where `charger_pd`, the owner of USB-C
power delivery, runs. An ADSP *restart* is already known to kill this port in
89 ms; nothing has ever tested whether merely attaching and holding the first PD
conversation can perturb it.

Supporting detail: in both surviving boots the CDSP firmware request (a 3.2 MB
read off the T7) sits between the ADSP attach and the notification; in the
failing boot the notification raced in first and the link was idle. Suggestive,
not conclusive — `powering up cdsp` at 11.76 s in the failing boot is a
*consequence* of the disk dying, not a cause.

### The experiment now staged

`/etc/modprobe.d/sp11-adsp.conf` → `blacklist qcom_q6v5_pas`, via
`tools/sp11-set-typec-blacklist.sh noadsp` (`adsp-back` reverts). Linux then
never attaches to the ADSP, `pmic_glink` has no remote, no altmode notification
arrives, and `charger_pd` is left entirely to firmware.

Costs both the ADSP and the CDSP — same driver — and battery reporting.
Precedent: integ21-noadsp reached a desktop with exactly this blacklist, so
display, GPU, wifi and keyboard are unaffected. ESP unchanged (integ31).

- **Failures stop completely** → the trigger is the ADSP conversation, and the
  remaining problem is `charger_pd`, not the USB/typec drivers. That merges
  straight into the experiment this project has been circling all along.
- **Failures continue** → the notification is a coincidence of scheduling and the
  last big candidate is gone; look at the xHCI/dwc3 side instead.

### Round four: ten clean boots with no ADSP

`live.log` boots 58–67, **10 for 10, no `emergency_ro`**. The test was valid:
no `adsp is available`, no `attaching to adsp`, no altmode notification, and
`6800000.remoteproc` / `32300000.remoteproc` both left unbound
(`sync_state() pending`). `ps883x` still probed and seeded `orientation=1`.
Zero `cmd cmplt err` anywhere.

**Do not over-read this.** The failure rate over the preceding 28 boots was
5/28 ≈ 18%, so ten consecutive clean boots happens by luck about **1 time in 7**:

```
0.82^10 = 14%    ten clean by chance
0.82^15 =  5%    fifteen clean -> ~95% confidence
0.82^23 =  1%    twenty-three  -> ~99%
```

Every additional normal boot is free evidence — `live.log` accumulates whether
or not anyone is watching.

### Round five: separating "ADSP up" from "Linux joined the PD conversation"

Blacklisting `qcom_q6v5_pas` removes the ADSP entirely, which also costs the
CDSP, battery reporting and any prospect of audio. It is a diagnosis, not an end
state. Patch **0005** splits the question with a command line parameter:

```
pmic_glink_altmode.pan_enable=0
```

`ALTMODE_PAN_EN` (0x10) is the one message where Linux announces itself to
`charger_pd` and asks to be told about port state. Everything downstream — the
per-port `USBC_NOTIFY_IND`, `pmic_glink_altmode_worker()`, the `PAN_ACK` —
follows from it. With `pan_enable=0` the ADSP attaches normally and everything
else it serves comes back; Linux simply never joins the conversation.

`QCOM_PMIC_GLINK=y`, so this is a builtin parameter and needs a kernel rebuild —
but once built, `0` and `1` are a cmdline edit apart, which makes the A/B cheap.
The worker also now logs `requesting altmode notifications (PAN_EN)`, giving a
timestamp for exactly when Linux joins.

Cost when disabled: no Type-C port notifications, so no USB-C DisplayPort alt
mode and no orientation/mux updates from firmware. The DP HPD bridges are still
allocated at probe, so `msm` still binds and the internal panel is unaffected.

Outcomes:

- **Clean** → it is the PD conversation, not the ADSP's existence. Audio becomes
  reachable, because `q6v5_pas` can stay loaded.
- **Fails** → merely attaching to the ADSP is enough to perturb the port, and the
  problem is deeper in `charger_pd` / the glink bring-up.

### Round five result: PAN_EN is the trigger, the ADSP is not

`live.log` boots 68–78, **11 clean, no `emergency_ro`**. All three kept kernel
logs confirm the configuration held:

```
remote processor adsp is now attached
pmic_glink.altmode.0: pan_enable=0, not requesting altmode notifications
remote processor cdsp is now up
```

and no `switch_set`, no `mux_set`, no `sw_set` — the notification chain never
runs. GPU bound, wifi associated, `qcom_battmgr` alive, fastrpc up with its
13 compute contexts.

**The combined evidence is now strong.** Two configurations, sharing exactly one
property — no altmode notification — and differing in everything else:

| config | ADSP | notifications | boots |
|---|---|---|---|
| `blacklist qcom_q6v5_pas` | absent | none | 10 clean |
| `pan_enable=0` | **attached** | none | 11 clean |

21 consecutive clean boots against a prior 5-in-28 (17.9%) failure rate:

```
0.821^21 = 1.6%     probability of this run under the null
```

So ~98% confidence that **joining the PD conversation is the trigger**. And the
second row isolates it further: the ADSP being attached is harmless. It is
`ALTMODE_PAN_EN` and what `charger_pd` does in response, not the ADSP's
existence.

### What this unblocks

`q6v5_pas` can stay loaded, which was the thing the earlier workaround gave up.
That puts audio back on the table, and reframes the oldest open question:

> **Does the +89 ms `charger_pd`-restart kill have the same cause?** That failure
> was measured before any of this was understood. If it was really the
> post-restart PD conversation rather than the restart itself, `pan_enable=0`
> may make booting the full 21.07 MiB `qcadsp8380.mbn` survivable — and that is
> the whole audio path.

Untested, and it is the experiment this project has been circling since 08-04.
Cost of failure: the disk dies mid-boot, hard power-off, dirty filesystem
(recoverable — `tools/sp11-fsck.sh`). Revert is renaming
`qcadsp8380.mbn.disabled` back.

### Round six: UCSI is live and the disk does not care

`live.log` boots 79–91, **13 clean**. And UCSI genuinely came up — this was not a
vacuous test:

```
6.6560  ucsi_glink.pmic_glink_ucsi pmic_glink.ucsi.0: UCSI features: 0x0004
6.7125  fd5000.phy-switch: switch_set() new_orientation=0, orientation=1
6.7125  ps883x 3-0008: sw_set: cached=1 notified=0 -> updating conn_status_0
6.7331  fda000.phy-switch: switch_set() new_orientation=1, orientation=1
6.7331  ps883x 5-0008: sw_set: cached=1 notified=1 -> no change, not touching the chip
6.7607  ps883x 5-0008: sw_set: cached=1 notified=1 -> no change, not touching the chip
```

`ucsi_glink` read the capability register over glink and then drove both
orientation switches. The **empty** port (connector@0 / 3-0008) was told
`orientation=0` and updated; **the disk's port (5-0008) was correctly left
untouched, twice.** That is patch 0004 visibly doing its job — without the seed
the cached value would have been `NONE` and both ports would have taken the
update path.

**This refutes my own prediction, in the good direction.** I expected
`ucsi_glink` to be able to reintroduce the fault, because it is a separate
pmic_glink client (owner `USBC`) opening its own conversation with `charger_pd`
that `pan_enable=0` does not touch. It did not. So the trigger is **not** "any
PD conversation" — UCSI talks to `charger_pd` happily. It is specifically the
**altmode `PAN_EN` path**.

Cumulative across the three configurations that suppress the altmode
notification: **34 consecutive clean boots**.

```
0.821^34 = 0.12%
```

**Patch 0001 is still untested.** There is no `PDR`, `servreg` or
`ucsi_unregister` line in any of these logs — a normal boot never restarts a
protection domain, so the code path it fixes has not run. Only the ADSP-restart
experiment will exercise it.

**Worth trying now:** since UCSI drives orientation and `TYPEC_DP_ALTMODE` is
loaded, USB-C DisplayPort may work through the UCSI path even with
`pan_enable=0`. Plug a USB-C display in and find out — if it does, `pan_enable=0`
costs almost nothing.

### Round seven: it is a boot-time race, and USB-C DisplayPort works

Two boots on integ34, `sp11-try-altmode` run at a settled desktop both times.
**Both survived, and the external display came up.**

```
66.7773  pan_enable turned on at runtime, requesting notifications
66.7784  requesting altmode notifications (PAN_EN)
66.7795  fd5000.phy-switch: orientation=2 -> no change, not touching the chip
66.8117  fd5000.phy-mux: mux_set() enter mode=5      <- TYPEC_DP_STATE_D
66.8117  typec_mux_set: already in mode 0, not touching the PHY
66.8437  fda000.phy-mux: mux_set() enter mode=1      <- the disk's port, USB
66.8437  typec_mux_set: already in mode 2, not touching the PHY
```

`mode=5` is `TYPEC_STATE_MODAL + 3` = **`TYPEC_DP_STATE_D`**, two DP lanes plus
USB. Zero `cmd cmplt err`, no `DID_NO_CONNECT`, no ext4 errors, disk alive.

**So the fault is a boot-time race, not the conversation.** The same request that
killed the disk at 6.1–6.5 s on ~18% of boots is harmless at 66–72 s. We can
have both.

Also visible: `probe: conn_status_0=23 -> seeding orientation=2`. `0x23` =
`CONNECTION_PRESENT | ORIENTATION_REVERSED | USB_3_1_CONNECTED` — the cable is in
flipped this time, and patch 0004 seeded `REVERSE` from the hardware. Every
subsequent `sw_set` then reported `cached=2 notified=2 -> no change`. Without the
seed the cache would have said `NONE` and the driver would have written to a live
retimer. **0004 is load-bearing on a flipped cable in a way it was not on a
normal one.**

### The durable fix

`tools/sp11-altmode.service` + `tools/sp11-install-altmode-unit.sh on`
(`off` reverts). Ordered `After=multi-user.target` with a further `sleep 30`, so
it fires around 50–60 s:

```ini
ExecStartPre=/bin/sleep 30
ExecStart=/bin/sh -c 'echo 1 > /sys/module/pmic_glink_altmode/parameters/pan_enable'
```

The cmdline still carries `pan_enable=0`; the unit turns it on later rather than
replacing it. **The exact safe boundary is unknown** — 6 s kills, 66 s does not,
and nothing in between has been measured — so the delay is deliberately well past
anything observed. The only cost is that an already-attached external display
lights up around a minute in; plug one in after that and it is immediate.

### Round eight: the port comes back, and the pre-mount hook is armed

**`sp11-portwatch` overturned the 08-04 finding.** With patches 0001–0006 and
`ucsi_glink` loaded, the full 21 MiB image booted and the T7 re-attached **on its
own, 2.3 s after the disconnect**:

```
86.7900  remoteproc0: remote processor adsp is now up
86.8256  qcom,apr ...glink-edge.adsp_apps: Adding APR/GPR dev: gprsvc:service:2:1
86.9024  usb 3-1: USB disconnect, device number 2
89.2002  usb 3-1: new high-speed USB device number 3
89.3249  usb 3-1: Product: PSSD T7 Shield
89.3474  sd 1:0:0:0: [sdb] Write cache: enabled
```

The 08-04 result was not a measurement artefact — that log shows the disconnect
at 305.37 s and **no re-attach at all** before the forced rebinds at 313.3 s. The
difference is the patches, almost certainly **0001**, the protection-domain
teardown path, exercised for the first time in that run.

`adsp_apps` appeared in **both** runs: the audio channel was never the blocker.

**`sp11-portwatch` itself was lying**, and had been since 08-04. It watched
`/dev/disk/by-uuid/…`, a *udev*-created symlink, and udev's binaries were on the
disk that had just died — so it reported `rootdev=no` for eight seconds while the
drive was already back, then "forced" a rebind that tore down a recovered port.
Now watches `/proc/partitions`, which the kernel maintains with no userspace.

### The pre-mount hook

`tools/50-sp11-adsp.sh` → `/var/lib/dracut/hooks/pre-mount/50-sp11-adsp.sh`,
appended to `.initrd` by `tools/sp11-add-initrd-hook.sh`.

Facts read out of the initrd, each of which would otherwise have cost a boot:

- **`hookdir=/var/lib/dracut/hooks`**, not `/usr/lib`. `list_hooks` searches all
  three with `/var` winning ties, so the four hooks a previous session left in
  `/usr/lib/dracut/hooks` *are* still sourced — but `dracut-pre-mount.service`
  has `ConditionDirectoryNotEmpty` on all three pre-mount dirs and **all three
  are empty**, so the service was being skipped entirely.
- Ordered `After=dracut-initqueue.service`, `Before=sysroot.mount`.
- `/bin/sh` is **dash**. No bash, no `printf`, no `dd`, and **no vfat module**, so
  the ESP cannot be mounted from the hook — log to `/dev/kmsg`, which
  `sp11-winlog` replays in full once root is up.
- Hooks are **sourced**, so a bare `exit` aborts `dracut-pre-mount`. Everything
  is inside a function using `return`.

**Probe boot (integ35), clean:**

```
1.965  sp11-adsp: pre-mount hook running at uptime 1.95s
2.968  sp11-adsp: root device present after 1s
3.853  sp11-adsp: staged firmware=yes modules=yes for 7.1.3-sp11-stockcfg-...
3.853  sp11-adsp: PROBE ONLY - add rd.sp11.adsp=1 to arm.
```

Note it fires at **1.95 s** and the root device was *not* there yet — one second
of polling was needed. The defensive poll earned its place.

**integ36 is integ35 + `rd.sp11.adsp=1`**,
`2826F7DED7FA890F132464EE52C4AEA8EF6CE320991416778F3D78B0D9A59F04`.

### What is different about doing it at pre-mount

At ~4 s the Type-C **modules are not loaded** — `ps883x` and `ucsi_glink` are
`=m` and live on the root disk. Only the builtins are up: `pmic_glink`,
`phy-qcom-qmp-combo`, dwc3, xhci. That cuts both ways:

- **In favour:** the 08-04 failure was `ucsi_glink` tearing the port down on the
  PDR. It cannot do that if it is not loaded. `ps883x` cannot touch the retimer
  either. `pmic_glink_altmode` gets the PDR notification and does nothing,
  because `pan_enable=0`.
- **Against:** the 2.3 s recovery was measured with the full stack live. This is
  a different configuration and the result may not transfer.
- **Mitigating:** the disk is on USB 2.0 here (`usb 3-1: new high-speed`), and
  D+/D- are hardwired through the connector independent of mux and orientation.
  A re-attach should not need anything reprogrammed.

If root does not come back, dracut drops to emergency with no keyboard — a
power-button hold, and the ESP gets re-flashed from Windows with
`BOOTAA64-integ35-adsphook.efi` (same UKI, unarmed).

### Reading live.log

`live.log` appends across every boot, but its `=== sp11-winlog started ===`
header only ever wrote once — use the `t=+0s` lines as boot boundaries instead.
**Do not classify a boot by how long the 90 s loop ran**: a healthy boot that the
user rebooted at 30 s also stops early, because `sleep` stops being executable
once root goes away at shutdown. The reliable discriminator is
**`emergency_ro`** in the `root=` field — that only appears when ext4 hits I/O
errors and remounts itself read-only.

## Still open

- **`ucsi_glink` was re-enabled 2026-08-05 late** and is now under test. Expect
  it to be able to reintroduce the dropout: `ucsi_glink` is a *separate*
  pmic_glink client (owner `USBC`) from the altmode one, so it opens its own
  conversation with `charger_pd` that `pan_enable=0` does not touch. That is
  exactly the class of thing round five convicted. A failure here is a result,
  not a regression — and it would say the trigger is any PD conversation rather
  than `PAN_EN` specifically. Look for `UCSI` lines near a `cmd cmplt err -71`.
- **The `charger_pd` experiment has still never run.** Does the Type-C port
  survive an ADSP restart with nothing holding the disk? That decides whether
  audio is reachable. Everything else has been prologue to this.
- **Nothing is pushed.** 30+ commits on `handoff/new-system`. PRs only in the
  user's own `lain3d/*` repos.

## Closed decisions

- **Root will NOT move to the internal NVMe.** The user has ruled out shrinking
  it. Every fix has to work with root on the Type-C port. Do not re-raise.
- **The filesystem fsck debt is paid.** Clean as of this session.

## Mistakes worth not repeating

- **A single boot never convicts a build.** This cost two full wrong diagnoses.
  0-of-several, then 2-of-3, then 0-of-several again, then 5-of-6 — all of the
  same underlying race. Judge on 10+.
- **The winlog overwrote `kmsg.txt`**, so successful boots destroyed the failing
  boot's log. Fixed to rotate. `live.log` appends and saved one investigation.
- **Never change `CONFIG_LOCALVERSION` to label a build.** `DRM_MSM`, `ATH12K`,
  `SURFACE_AGGREGATOR` and `HID_GENERIC` are all `=m` and load from the T7's
  module tree; a new suffix orphans all of them. The build script now refuses.
- **Install modules whenever the config changes.** The tree was stale from
  08-04 for several boots, which is how `msm` loaded far enough to probe DP but
  never bound the GPU.
- **WSL's tools are older than the disk.** e2fsprogs 1.46.5 rejects the T7's
  `orphan_file` as `FEATURE_C12/R16`; run the disk's own binary through its
  loader, as `sp11-journal.sh` already did for journalctl. Generalise this
  before concluding anything needs a booted system.
- **usbipd drops the attachment under long jobs.** `blkid` then answers from
  cache with a stale `/dev/sdX`. Cycle `to-win`/`to-wsl`.
- **Anchor text needs its leading newline.** `"\tqmp->x"` is a substring of
  `"\t\t\tqmp->x"`, so a patch anchor matched twice and refused. That refusal
  was correct behaviour; the guard earned its place.
- **Inline `wsl bash -c` still eats scripts.** Three more times this session.
  Write a file.
