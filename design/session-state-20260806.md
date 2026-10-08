# Session state — 2026-08-06

Supersedes `session-state-20260805-evening.md`, which is chronological and still
accurate but hard to read cold. This one is organised for a fresh start. Read it
first.

## Where the machine is

A Surface Pro 11 (X1E80100) boots Linux **reliably** from a Samsung T7 Shield
over USB-C, at SuperSpeed, from **either** port, with:

- GPU at 120 Hz, wifi, keyboard, touchpad, battery reporting
- ADSP **restarted with the full 21 MiB image** from a dracut pre-mount hook,
  CDSP booted, fastrpc with 13 compute contexts, `gprsvc` registered
- **Audio works** — speakers and mic, through the SP11 topology and UCM2
- **USB-C DisplayPort comes up with the desktop**, no replug, via a UCSI
  connector reset
- UCSI live; 34+ consecutive clean boots

Windows is untouched on the internal NVMe. Six patches, all in `patches/`, all
independently upstreamable in shape.

## The ADSP restart WORKS — 2026-08-06, integ38

The dracut pre-mount hook did the whole job, first time out:

```
3.86 s  hook unmounts root
3.91 s  qcom_q6v5_pas loaded via insmod
3.99 s  Booting fw image qcom/.../qcadsp8380.mbn, size 22092168
4.01 s  remote processor cdsp is now up
4.27 s  PDR: charger_pd up          4.28 s  audio_pd up, gprsvc:service:2:1 and 2:2
4.36 s  usb 3-1: USB disconnect     <- nothing was holding the disk
6.64 s  usb 3-1: new device number 3   (2.28 s)
9.71 s  remote processor adsp is now up
10.60 s dracut mounts root -> rw -> desktop
```

Clean boot: no `emergency_ro`, a full 90 s of `live.log`, wifi, and
`sp11-altmode.service` flipping `pan_enable` on at 71 s with no ill effect. This
is the first time the full 21 MiB ADSP image has been booted on this machine
without losing the root filesystem.

**`mkdir` finally said what was wrong with `/lib/modules`:**

```
sp11-adsp: mkdir /lib/modules/7.1.3-sp11-stockcfg-gf2cc827b6b89: mkdir: Read-only file system
```

Nothing exotic — `/usr` is read-only in this initramfs, and `/lib` is a symlink
into it. Every earlier theory was about `modprobe` failing to see files that had
arrived; the files could never have arrived. `/run` is the writable part, which
is where the modules go now.

### Audio: one fence left, and it is a missing file

`q6apm` bound to `gprsvc:service:2:1` and the card got all the way to probe:

```
24.04  qcom-apm gprsvc:service:2:1: CMD timeout for [1001021] opcode
24.22  Direct firmware load for qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin failed -2
24.22  tplg firmware loading ... failed -2
24.23  snd-x1e80100 sound: ASoC: failed to instantiate card -2
```

The fatal one is the `-2`. `audioreach_tplg_init()` builds the name as
`qcom/<card->driver_name>/<card->name>-tplg.bin`, and the sound node in
`x1-microsoft-denali.dtsi` sets `model = "X1E80100-Microsoft-Surface-Pro-11"`.
linux-firmware ships **fourteen** X1E80100 topologies and none is the Surface
Pro 11's, so on a stock system the file cannot exist. (Two of them — Dell XPS 13
9345 and Lenovo Yoga Slim7x — carry the same `WSA_CODEC_DMA_RX_0` +
`VA_CODEC_DMA_TX_0` pair the SP11 needs, and would have been the substitute.
They are not needed: see below.)

`0x01001021` is `APM_CMD_GET_SPF_STATE`. `q6apm_get_apm_state()` ignores the
send result, so the timeout is not itself fatal — but `q6prm`'s probe gates on
`q6apm_is_adsp_ready()` and defers when it fails.

### Installed 2026-08-06, from ../ubuntu-surface-pro-11

That repo has a **genuine SP11 topology** — 36240 bytes with the `CoSA` ASoC
magic, three times the size of the generic ones — plus the rest of the audio
userspace, and it had already diagnosed the CMD timeout: `alsactl` restores WSA
mixer state before the DSP graph has loaded, so mask `alsa-restore.service` and
`alsa-state.service` and drive routing from a service that waits for the
SoundWire slaves to reach `Attached`.

`tools/sp11-install-audio.sh` puts all of it on the T7 offline:

- `X1E80100-Microsoft-Surface-Pro-11-tplg.bin` -> `/lib/firmware/qcom/x1e80100/`
- UCM2: `MICROSOFT-Surface-Pro-11.conf`, `Surface11-HiFi.conf`, and the
  `conf.d/x1e80100/x1e80100.conf` DMI matcher (old one kept as
  `.pre-sp11audio`)
- `sp11-enable-wsa-routing.sh` + `sp11-wsa-routing.service`, enabled
- `alsa-restore.service` and `alsa-state.service` masked to `/dev/null`
- `sp11-pipewire-speaker-sink.sh` staged; it is per-user, so it still has to be
  run from the desktop session with `--install --enable-route`

**Deliberately NOT done:** that recipe's step 1 installs `qcadsp8380.mbn` under
its real name. Ours stays `.disabled`. The pre-mount hook stages it into tmpfs;
un-hiding it puts the ADSP restart back in userspace, which is what killed
integ36.

### It works, and this is the whole chain

```
 1.9 s  dracut pre-mount hook runs
 3.9 s  qcom_q6v5_pas insmod'd from /run, ADSP restarts with the 21 MiB image
 4.4 s  charger_pd restarts -> the Type-C port drops the disk
 6.6 s  the disk is back (root was not mounted, so nothing to abort)
 9.9 s  ADSP running, adsp_apps present, gprsvc registered, staged fw deleted
10.6 s  dracut mounts root -> rw
14.1 s  sound.target
20.4 s  gdm.service - the GUI appears
~22.6 s sp11-altmode.service        pan_enable=1  -> PAN_EN
~25.6 s sp11-dp-reset.service       UCSI_CONNECTOR_RESET -> DP alt mode -> HPD
24.3 s  sound card0, Headset Jack
58.8 s  graphical-session.target
```

Four services carry it, and each exists for a reason the logs forced:

| unit | when | why |
|---|---|---|
| the dracut hook | 1.9 s | restart the ADSP while nothing holds the disk |
| `sp11-wsa-routing` | after `sound.target` | enable the WSA route once the DSP graph is loaded |
| `sp11-altmode` | gdm + 2 s | `pan_enable=1`, so Linux is subscribed to altmode notifications |
| `sp11-dp-reset` | gdm + altmode + 3 s | connector reset = a replug in software |

Plus one per-user piece that is **not** automatic and has to be run once from
the desktop session, without sudo:

```
~/sp11-fix-speakers.sh
```

It installs the PipeWire sink with the right channel map and — the part the
upstream script leaves out — *selects* it. Without that you get the UCM sink,
which is 4-channel with the wrong positions, and only the left speaker plays.

### integ37: the hook could not put anything in /lib/modules

Superseded by the `mkdir` answer above; kept because the elimination was sound.
`inventory: modules.dep=no remoteproc_kos=0 pas=no` while 25 MiB of firmware
copied off the same mount in the same instant. The defuse also proved itself:
the hook gave up at 3.96 s, deleted the staged tree, and the boot was ordinary.

### integ36: why a failed hook was worse than no hook

Neither reached a desktop. Both died the same way, and the way they died is
worth more than a success would have been.

**What the hook did.** It ran at 1.82 s and 1.85 s, found the root device,
staged the firmware and modules — and then `modprobe qcom_q6v5_pas` failed
**1.5 ms later**, with its stderr going to `/dev/null`. It waited 30 s for an
ADSP that was never going to appear, then continued. Every boot therefore cost
30 s and did nothing.

**What killed the machine was the hook's leftovers, not its actions.**
`firmware_class.path` is kernel-global state and `/run` is carried across
switch-root, so the staged 22 MiB image at `/run/sp11fw` stayed reachable to
userspace. udev autoloaded `qcom_q6v5_pas` normally at 40.8 s / 43.9 s, found
`qcadsp8380.mbn` under the staged path — the whole point of hiding it on disk as
`.disabled` — and did a full ADSP restart with root mounted **rw** and the
desktop coming up:

```
40.815  remoteproc0: restarting adsp with new firmware
41.120  remote processor adsp is now up
41.140  PDR: Indication received from msm/adsp/charger_pd, state 0x1fffffff
41.152  qcom,apr ...adsp_apps: Adding APR/GPR dev: gprsvc:service:2:1  and 2:2
41.223  pmic_glink_altmode: pan_enable=0, not requesting altmode notifications
41.224  usb 3-1: USB disconnect
41.249  Aborting journal on device sda5-8
42.758  usb 2-1: new SuperSpeed USB device number 2
```

**A failed hook was worse than no hook at all.** That is now fixed: every armed
path deletes `/run/sp11fw` before returning, so the path resolves nothing.

### Three things these two boots established

**1. Attaching to the running ADSP does NOT give you audio; restarting does.**
The probe-only boot (`kmsg.2.txt`) shows `adsp is now attached` at 11.4 s and
then *no* `adsp_apps`, *no* `gprsvc`, and the whole LPASS tree parked in
deferred probe — `6e80000.pinctrl: Failed to get clk 'core'`, four codecs
waiting on `6d44000.codec`, `sound: snd-x1e80100: WSA Playback: error getting
cpu dai name`. The armed boots registered `gprsvc:service:2:1` and `2:2` within
33 ms of the ADSP coming up, both times. **The restart is not optional.** This
also corrects the 08-05 note that `adsp_apps` appeared "in both runs" — it
appears whenever the ADSP is *restarted*, never when it is attached.

**2. The port drop on an ADSP restart is not `ALTMODE_PAN_EN`.** `pan_enable=0`
was in force and the driver said so explicitly — and the disk dropped anyway,
1.6 ms later. The stable interval is against `charger_pd`'s PDR up-indication:
**84.5 ms and 85.8 ms**, versus 1.60 ms and 1.72 ms against the altmode probe,
which is itself downstream of the same event. PAN_EN was a *second*,
independent trigger. A `charger_pd` restart drops the port on its own.

**3. The port comes back, twice more.** 1.53 s and 1.54 s to `usb 2-1: new
SuperSpeed`, then the disk re-enumerated as `sdb`. What made these boots fatal
was only that ext4 had aborted its journal 25 ms into the outage. **Nothing
holding the disk means nothing to abort — which is the entire argument for
doing this at pre-mount.**

## The six patches

| # | driver | defect |
|---|---|---|
| 0001 | `ucsi_glink` | tears the port down on a protection-domain restart |
| 0002 | `ps883x` | resets a retimer firmware left running; then rewrites its conn_status registers anyway |
| 0003 | `phy-qcom-qmp-combo` | power-cycles a live PHY — cached mode seeded with the enum's zero |
| 0004 | `ps883x` | cached orientation seeded with `devm_kzalloc`'s zero instead of read from the chip |
| 0005 | `pmic_glink_altmode` | `pan_enable` parameter — makes `ALTMODE_PAN_EN` suppressible |
| 0006 | `pmic_glink_altmode` | makes it *writable*, so PAN_EN can be deferred instead of suppressed |

**One theme runs through 0001–0004:** cached driver state initialised from a
default instead of read back from hardware that firmware left running. Harmless
on a normal machine; fatal when that hardware carries the root filesystem.

0005/0006 are diagnostic in form, not upstream-ready. The real bug they expose is
that `charger_pd` does something disruptive to the port when Linux announces
itself — which is firmware behaviour, not a Linux defect we can patch.

## The two hard-won results

**1. `ALTMODE_PAN_EN` is a boot-time race.** Linux announcing itself to
`charger_pd` at ~6 s killed the disk on ~18% of boots (`cmd cmplt err -71`
14.9–16.3 ms later, three independent failures). The *same* request at 66–72 s is
harmless, twice out of two, and brings up USB-C DisplayPort. `pan_enable=0` on
the cmdline plus `sp11-altmode.service` gets both. That service now fires at
**~22.6 s**, off `display-manager.service`, not at 55–72 s — see the TODO below,
because moving it there rests on an argument rather than a measurement.

`pan_enable=0` alone costs DisplayPort **outright** —
`drm_aux_hpd_bridge_notify()` has exactly one caller on this platform and it is
inside `pmic_glink_altmode_worker()`. UCSI discovers the display and drives
orientation but never signals HPD.

**2. The Type-C port DOES come back after a `charger_pd` restart** — 2.3 s, on
its own, and 1.53 s and 1.54 s on the two armed boots since. This **overturns**
the 08-04 finding that it never does. That finding was real for its kernel (its
log shows the disconnect and no re-attach at all); the credit goes to the
patches, almost certainly **0001**.

Two corrections to what was written here on 08-05, both from the armed boots:

- PAN_EN is not the only trigger, and not the one that matters for audio. With
  `pan_enable=0` in force and the driver logging that it declined to send it,
  the port still dropped — **84.5 ms and 85.8 ms after `charger_pd`'s PDR
  up-indication.** A `charger_pd` restart drops the port by itself.
- `adsp_apps` does **not** appear when the ADSP merely attaches. It appears only
  after a restart. The audio channel *was* a blocker, and still is.

## Machine state

```
ESP    BOOTAA64.EFI = BOOTAA64-integ40-nvmesafe.efi
       C30EBF9BBE9B989CD3589DB5BE0186B41FAF10C0AFB6C8544A033657509EC12C

       The T7's ESP is 488 MB and a UKI is 70 MB, so only one lives there at a
       time; the fallbacks are staged on C:\sp11-stage and swapped in from
       Windows. Mount the ESP with tools\sp11-disk.ps1 esp.

fallbacks, in order of how far back they take you:
  BOOTAA64-integ38-disarmed.efi     0F92A435...  same UKI, no rd.sp11.adsp=1
  BOOTAA64-integ37-adsphook2.efi    C03D700B...  boots fine, hook bails at 4s
  BOOTAA64-integ34-defer.efi        BCAF75CB...  no hook at all
  BOOTAA64-integ33-KNOWN-GOOD.efi   102F24D1...  the reliable snapshot
  BOOTAA64-stock-KNOWN-GOOD.efi     68975CE3...  stock 7.0.0-22

  integ36 (2826F7DE) and integ35 (3D0CB575) carry the BROKEN hook - the one
  that leaks firmware_class.path into userspace. Do not boot them.

ESP  BOOTAA64.EFI = BOOTAA64-integ44-camera.efi, as of 2026-08-06
     FA317B1E4B5459EA27800523AC4B1944707669AE1A8A68592A68E01B96B5E46B

     integ43 (9684656D) IS BAD -- DO NOT BOOT IT. Built in the wrong worktree;
     it deleted ramoops, pcie4_port0 PERST#/WAKE#, and the USB4 routers' iommus
     and power-domains. Two failed boots, root disk never enumerated.
     integ44 is the same camera change rebuilt on debug/ramoops in wt-ov13858,
     which is where integ40's DTB actually came from (proven byte-identical).
     THUNDERBOLT IS STILL BLACKLISTED -- integ43 kept integ40's cmdline byte
     for byte; only .dtb differs.

     integ40 (C30EBF9B) = the known-good baseline. Rolling back is one copy:
         copy C:\sp11-stage\BOOTAA64-integ40-nvmesafe.efi S:\EFI\BOOT\BOOTAA64.EFI
     integ41 (5F94910B) = integ40 with modprobe.blacklist=thunderbolt removed.
     integ42 (813783C1) = integ41 plus thunderbolt.dyndbg=+p.
     Both were built by cmdline edit alone, with .dtb, .linux and .initrd
     verified byte-identical to integ40, so swapping between the three is one
     file copy from C:\sp11-stage and changes nothing but the cmdline.
     integ43 (9684656D) = integ40 with the camera device tree. .cmdline,
     .linux and .initrd verified identical to integ40; .dtb is the only change.

     Why reverted: with the routers bound, boots began failing intermittently
     with U1 link-power-management errors on the root disk -
     "disable of device-initiated U1 failed" -> "reset SuperSpeed Plus Gen 2x1"
     -> a new scsi host under a mounted filesystem -> ext4 errors -> emergency_ro.
     Three of the last six boots died that way. The same 10 Gbps link had zero
     U1 failures across every Aug 5 boot, when thunderbolt was blacklisted.

     NOT proven, and worth stating as a hypothesis rather than a finding: the
     thunderbolt driver calls nhi_reset() and programs rings on host routers
     that share Type-C hardware with the root disk, then fails probe. That is
     the only new thing touching that silicon. A cable flip also cleared one
     failure, so a marginal connection is not excluded.

     Next time this is picked up: usbcore.quirks=04e8:61fb:k disables link
     power management for the T7 specifically and would separate the two.

     The patched thunderbolt.ko stays installed on the T7 (harmless while
     blacklisted); the stock one is beside it as thunderbolt.ko.zst.orig.

cmdline  root=UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd ro loglevel=7 console=tty0
         clk_ignore_unused pd_ignore_unused arm64.nopauth
         regulator_ignore_unused
         pmic_glink_altmode.pan_enable=0 rd.sp11.adsp=1
         (integ40 and earlier also carried modprobe.blacklist=thunderbolt)

T7 has  thunderbolt.ko.zst and thunderbolt_net.ko.zst installed, no thunderbolt
        blacklist in /etc/modprobe.d, and modules.alias carries
        "of:N*T*Cqcom,x1e80100-usb4 thunderbolt" - so udev will autoload it off
        the DT compatible with no manual modprobe. boltd is installed, so a
        never-seen dock may enumerate and deliberately NOT tunnel until it is
        authorized: check /sys/bus/thunderbolt/devices/domain0/security and
        `boltctl list` before calling that a failure.

kernel   7.1.3-sp11-stockcfg-gf2cc827b6b89, base f2cc827b6b89
         /root/sp11/wt-cfg in WSL - patches UNCOMMITTED there
         full snapshot in data/integ33/ (diff, .config, release, base commit)

T7       /lib/modules/7.1.3-sp11-stockcfg-gf2cc827b6b89   matches
         NOTHING of ours blacklisted in /etc/modprobe.d
         units, all enabled into graphical.target.wants (NOT multi-user):
           sp11-altmode.service     display-manager + 2s   pan_enable=1
           sp11-dp-reset.service    + altmode + 3s         UCSI connector reset
           sp11-wsa-routing.service after sound.target     WSA route
           sp11-winlog / sp11-bootlog                      diagnostics
         alsa-restore.service and alsa-state.service masked to /dev/null
         audio: SP11 tplg in /lib/firmware/qcom/x1e80100/, UCM2 in
           /usr/share/alsa/ucm2/Qualcomm/x1e80100/ (old conf kept .pre-sp11audio)
         /etc/sp11-dp-connector.learned-was-1 is the retired --learn value;
           the connector is derived from the root disk's USB controller now
         qcadsp8380.mbn.disabled  (hidden, so the ADSP attaches not restarts;
                                   the pre-mount hook stages it under its real
                                   name into tmpfs and never touches the disk)
         zap shader qcdxkmsuc8380.mbn installed
         /usr/local/sbin/sp11-{portwatch,adsp,try-altmode,collect}
         fsck'd clean 2026-08-06 after the two aborted-journal boots
         (e2fsck -p, exit 1, errors corrected; module tree and Denali intact)

         Denali holds: qcadsp8380.mbn.disabled 22092168, qccdsp8380.mbn 3195304,
         adsp_dtb.mbn, cdsp_dtb.mbn, *_dtbs.elf, adspr/adsps/adspua/battmgr/
         cdspr .jsn, qcdxkmsuc8380.mbn. Modules on the T7 are .ko.zst.

port     either works. tools\sp11-which-port.ps1 reports which, no longer warns.
```

## Corrections made this session — do not reinstate the old versions

- **"URS0 is the wrong port, no boot has ever succeeded on it"** — false since
  the driver fixes. Both ports boot at SuperSpeed. It was where the drive
  happened to sit, never a property of the port.
- **"The port never comes back after a `charger_pd` restart"** — overturned, see
  above.
- **`sp11-portwatch` watched `/dev/disk/by-uuid/…`**, a *udev*-created symlink,
  while udev's binaries were on the disk that had just died. It reported
  `rootdev=no` for eight seconds with the drive already back, then forcibly tore
  down a recovered port. Now watches `/proc/partitions`.
- **`/home/lain/sp11-collect.sh` was a 134-byte wrapper** exec'ing a script that
  does not exist, so every run produced nothing. Replaced.
- **Judge boots from `live.log` on `emergency_ro`**, never on how long the 90 s
  loop ran — a healthy boot rebooted early ends short too, because `sleep` stops
  being executable once root goes away at shutdown. `failures.txt` is stale, and
  so is `state.txt`: both are written by the `sp11-winesp` *timed* capture at
  25/55/100 s, unconditionally, so every one of their "failed boot" lines is
  just a timer firing.
- **A hook that gives up must undo itself.** `firmware_class.path` is kernel
  state, `/run` survives switch-root, and between them a hook that bailed out
  early handed userspace a loaded gun. See the two armed boots above.

## Initramfs facts, established by reading the image

- **`hookdir=/var/lib/dracut/hooks`**, not `/usr/lib`. All three locations are
  searched, `/var` wins ties — but `dracut-pre-mount.service` has
  `ConditionDirectoryNotEmpty` on all three pre-mount dirs, and all three were
  empty, so the service was skipped entirely until we dropped a file in.
- Hooks are **sourced**; a bare `exit` aborts `dracut-pre-mount`. Use a function
  and `return`.
- `/bin/sh` is **dash**. No bash, no `printf`, no `dd`, **no vfat module** — the
  ESP cannot be mounted from a hook, so log to `/dev/kmsg`;`sp11-winlog` replays
  the whole ring buffer once root is up.
- The initrd's module tree is stamped `7.1.3-sp11-integ-*` while the kernel is
  `-stockcfg-*`, so `modprobe` finds nothing there. Stage modules out of the
  mounted root — into **`/run`**, never `/lib/modules`: `/usr` is **read-only**
  in this initramfs and `/lib` is a symlink into it, so every write there fails.
  `insmod` by absolute path does not care. This cost three boots to find because
  the failing `mkdir`'s stderr was going to `/dev/null`.
- The hook fires at **1.95 s** and the root device is **not yet present** — poll
  for it, do not assume, despite `After=dracut-initqueue.service`.
- Appending to `.initrd` works: uncompressed cpio, padded to 4-byte alignment,
  shipping only files whose parent directories already exist in the base.

## Still open

- **`pan_enable` at ~22.6 s rests on an argument, not a measurement.** PAN_EN at
  ~6 s dropped the root disk on roughly one boot in six; 66–72 s was safe; the
  boundary was never measured, and 22.6 s is inside the untested gap. The
  argument for it: the pre-mount hook restarts the ADSP at 3.9 s, which destroys
  the firmware-negotiated port state PAN_EN used to disturb, so from 6.6 s the
  port is plain USB and nothing about it differs between 22 s and 72 s — and at
  71.5 s PAN_EN was observably inert (`mux_set mode=1`, "not touching the PHY").
  **Watch for `emergency_ro` in `live.log` over the next several boots.** The
  revert is one number: `ExecStartPre=/bin/sleep` in `sp11-altmode.service`.
- **TODO, deferred deliberately: send PAN_EN *before* the restart.** If Linux
  were already subscribed when `charger_pd` renegotiates the port at ~6.6 s, DP
  alt mode might be entered there and then — no connector reset, no debugfs, no
  connector arithmetic, and the display up at 7 s instead of 25 s.
  `pmic_glink_altmode` cannot probe that early today because it needs the
  `ps883x` retimer, a module from the root filesystem, so this means staging
  `ps883x` and the typec-switch/PHY plumbing into the initramfs — the same class
  of work as the UCSI attempt, which cost 15 s of boot, 78 UCSI re-inits and the
  audio. Worth revisiting; not worth destabilising a working machine for now.
  Note the timing that makes it plausible: `charger_pd`'s PDR "up" lands at
  4.30 s, *between* the port dropping at 4.4 s and re-attaching at 6.6 s.
- **`~/sp11-fix-speakers.sh` is a manual step.** It has to be run once per user
  from the desktop session, without sudo. Everything else is automatic.
- **The `CMD timeout for [1001021]` (`APM_CMD_GET_SPF_STATE`) still fires**, at
  ~24 s, despite masking `alsa-restore`/`alsa-state`. Audio works anyway. Worth
  watching whether it correlates with which slot the right speaker lands on.
- **The winlog's kmsg capture ends at ~71.5 s.** Anything later exists only in
  the journal — which is how the ordering cycle and the CRLF both hid. Extend it.
- **Pushed 2026-08-06.** `handoff/new-system` →
  `lain3d/surface-arm-platform-research`, and the six patches are off the
  working tree and onto `lain3d/surface-pro-11-kernel`, branch
  **`wip/sp11-typec-adsp-fixes`** (`50c70f2d0`, based on `f2cc827b6b89`).
  Squashed deliberately; the commit message enumerates the six and which file
  each lives in, so splitting them is mechanical. **That split is the next job
  on the kernel side**, and it is what the eventual PRs are made of — 0001–0004
  are upstreamable in shape, 0005/0006 are diagnostic and are not.
  PRs only in the user's own `lain3d/*` repos.
- `data/integ33/` has the full diff, regenerated 2026-08-06 and covering
  0001–0006.
- **`sp11-adsp-initramfs-boot.sh` is redundant** with the hook. Retire it.

## A warm reboot never resets the retimer — and that cost 10 Gbps for 17 boots

**Found 2026-08-06.** The T7 had been enumerating at **`high-speed`, USB 2.0, on
`usb 3-1`** — the USB 2.0 root hub — since **18:48 on Aug 5**, through every
boot of the audio and DisplayPort work. Same cable throughout, and kernel and
cmdline byte-identical across the transition (`boot-19` through `boot-14` all
`7.1.3-sp11-stockcfg-gf2cc827b6b89`, same arguments), so nothing in software
caused it.

A **cold power-off** cleared it instantly:

```
1.317s  usb 4-1: new SuperSpeed Plus Gen 2x1 USB device number 2   <- 10 Gbps
```

The mechanism is ours. `ps883x_configure()` returns early rather than rewrite
matching registers —

```
conn_status already 23/00/00, not reprogramming
```

— and patch 0002 stops us resetting a retimer firmware left running. Both are
right: rewriting cost a USB `-EPROTO` on the root disk 18 ms later. But together
they mean **a degraded lane configuration, once latched, survives every warm
reboot indefinitely.** Only dropping the retimer's rails clears it. The likely
origin is the 4-lane DP alt mode entered during display testing, which leaves no
SuperSpeed pairs at all.

**Practical rule: if the root disk is slow, cold boot before investigating
anything else.** And when judging link speed from a log, follow
`Product: PSSD T7 Shield` to *its own* enumeration line — `usb1`/`usb3` are the
USB 2.0 root hubs and `usb2`/`usb4` the SuperSpeed ones, and there are other
devices (a Realtek `0bda:0409` hub) whose lines are easy to mistake for the
disk's. Match `SuperSpeed Plus Gen 2x1` too, not just `SuperSpeed`.

## Watch: the port did NOT drop on the cold boot

Same boot, and against what was treated as settled. The ADSP fully restarted —
`restarting adsp with new firmware`, `qcadsp8380.mbn` booted, `charger_pd` PDR
indication received, `adsp is now up`, `adsp_apps` present, `gprsvc` registered
— and the **`USB disconnect` count for the entire boot was 0**. The two boots
before it were 4 and 1.

The settled finding says a `charger_pd` restart drops the port by itself, 84.5
and 85.8 ms after the PDR up-indication. It did not here. **Two variables moved
at once** — cold start *and* a 10 Gbps link instead of USB 2.0 — so this
overturns nothing on n=1. Watch the disconnect count over the next several
boots: if the drop turns out to be conditional rather than inherent, the dracut
hook's whole timing rationale gets simpler.

## Next: USB4 / Thunderbolt with the Dell dock

The starting position is better than expected — this is a *test*, not a build.

```
CONFIG_USB4=m, CONFIG_USB4_NET=m          already in the running kernel
base f2cc827b6b89 = "Merge branch 'usb4/platform-nhi' into integration/iso2"
1553f000.usb4  1563f000.usb4  1573f000.usb4    all three DT nodes enumerate
```

They appear in `state.txt`'s unbound list every boot, and `gcc-x1e80100` reports
`sync_state() pending` on all three. The driver is built, the nodes are there,
the devices exist — and nothing binds, because the cmdline carries

```
modprobe.blacklist=thunderbolt
```

which was added early to remove a variable and has been inherited ever since.

**First move is therefore a cmdline edit, not a rebuild:**
`tools/sp11-patch-cmdline.sh` with the blacklist removed, and see whether the
platform driver binds all three routers. `tools/sp11-which-port.ps1` still says
which physical port is which.

**Four gates were enumerated on 2026-08-06 without booting** — full working in
`docs/usb4-host-router.md`, "The four gates". In short:

1. the `thunderbolt` blacklist — a cmdline edit, and `nhi_of_match` does match
   `qcom,x1e80100-usb4`, so the routers should bind;
2. **`parade,disable-usb4` on both SP11 retimers**, which is *live*, not
   cosmetic: `pmic_glink_altmode_enable_usb4()` really does call
   `typec_retimer_set()` with `TYPEC_MODE_USB4`, and `ps883x.c:276` answers
   `-EOPNOTSUPP`. A DTB change, and the second move rather than the first;
3. USB4 entry rides the same PAN notification channel as DP, so nothing arrives
   before `pan_enable=1` at ~22.6 s — **plug the dock in after the desktop is
   up** for the first test;
4. **no DT host bridge for the tunnel.** Windows lands tunneled PCIe in
   `\_SB.PCI0`/`PCI1` at ECAM `0x400000000`/`0x500000000`; the DT's four PCIe
   controllers are the small on-die ones (NVMe, WiFi, and two unenabled). Expect
   the routers to bind and a tunneled device still not to appear. Look for the
   tunnel before looking for a PCI device — Linux builds the tunnel purely from
   router adapters and never consults a `pci_dev`, so a tunnel coming up is not
   evidence that anything will enumerate.

Also resolved: **`CONFIG_HOTPLUG_PCI_PCIE` is `=y`** in the running stockcfg
kernel. `first-boot-runbook.md` said it was unset — true of the integ config,
not of what we run. Only `CONFIG_USB4_DEBUGFS_WRITE` is absent, and it is
debugging-only, so USB4 needs no rebuild at all.

What to watch for, given everything this project has learned: the dock is a
Type-C device on the same `charger_pd`-owned ports as the root filesystem, and
the first attempt at a Dell dock (2026-08-05, HDMI into the dock) produced no
display at all. Treat any dock experiment as capable of dropping root, and
prefer testing with the T7 on the *other* port from the dock.

The open question from `linux-enablement-state` remains: **whether PCIe tunnels
over it**. Five commits in `lain3d/surface-pro-11-kernel#3` got the module and
DTB building; nothing has ever bound to real hardware.

## Standing constraints

- PRs only in the user's own `lain3d/*` repos.
- The bootloader goes on the T7, **never** the internal NVMe.
- The baseline ISO is never overwritten.
- BitLocker recovery password never printed to a transcript.
- **Root will not move to the internal NVMe.** Closed decision; do not re-raise.
