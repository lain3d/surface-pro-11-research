# Audio on the Surface Pro 11 — start here

You are running **on the Surface itself**, booted into Linux. That is new. Every
previous session drove this machine from Windows and could only read its disk
offline, which is why so much of the recorded work is indirect.

**The task was: work out why the ADSP has no audio, and fix it if you can.**

**Why is answered** (2026-08-04, on the machine — see the next-but-one section).
What remains is a choice between three routes to a fix, one of which has a
built experiment waiting for a reboot.

## State in six lines

```
kernel     7.1.3-sp11-stockcfg-gf2cc827b6b89   (integ20 UKI on the T7's ESP)
cmdline    modprobe.blacklist=thunderbolt      (qcom_q6v5_pas is NOT blacklisted)
GPU        working, 120Hz, zap shader installed
CDSP       booted, fastrpc up, 13 compute contexts
ADSP       attached, not booted - and silent
audio      absent: no sound card, PipeWire finds nothing
```

`/lib/firmware/qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn` is deliberately
renamed `.disabled`. **Do not restore it casually** — read the next section
first, it will kill the root filesystem.

## The one thing you must not do by accident

**The root filesystem is a USB-C disk, and restarting the ADSP disconnects it.**

`charger_pd`, the protection domain owning USB-C power delivery, runs on the
ADSP. Qualcomm's firmware boots the ADSP before Linux. If `qcom_q6v5_pas` finds
its firmware it *restarts* that running processor; `charger_pd` restarts with
it, and ~89 ms later the Type-C port drops the disk. The machine then wedges and
needs a power-button hold.

That is why the firmware is hidden. With it hidden the driver takes its
**attach** path instead, which is harmless:

```
Direct firmware load for .../qcadsp8380.mbn failed with error -2
attaching to adsp
remote processor adsp is now attached
```

Anything that stops/starts `remoteproc0` risks the same disconnect. Assume
`echo stop > /sys/class/remoteproc/remoteproc0/state` will take the disk with
it.

## The actual problem — SOLVED 2026-08-04, read this before anything else

This section used to pose two hypotheses and call the question open. It is
settled. **Do not re-run the investigation below; run the experiment instead.**

Every LPASS device waits on one supplier:

```
platform 6aa0000.codec: deferred probe pending: platform: wait for supplier
    /soc@0/remoteproc@6800000/glink-edge/gpr/service@2/clock-controller
```

The old claim that the ADSP's glink edge "never enumerates" was **wrong**. It
enumerates six channels — `APPS_ADSP_PWR_LMTS_GLINK_PORT`, `IPCRTR`,
`LOOPBACK_CTL_LPASS`, `PMIC_LOGS_ADSP_APPS`, `PMIC_RTR_ADSP_APPS`, `glink_ssr`.
Missing is exactly one, `adsp_apps`, which is what `gpr` wants. rpmsg devices
are created only on a remote-initiated OPEN (`qcom_glink_rx_open`), so six
advertisements did arrive. **The old hypothesis 2 — a stateful handshake that
never replays — is refuted.**

**Why:** Linux is attached to the ADSP image *firmware* booted, which lives in
`adsp-boot@86b00000` — a **12 MiB** carveout no DT node references.
`qcadsp8380.mbn` is **21.07 MiB** and targets `adspslpi@87e00000` (58 MiB).
Different, smaller image; it serves `charger_pd` and has no audio service.
`strings` on the full image finds `adsp_apps`, `audio_pd` and `avs/audio`; the
running one advertises a strict subset.

**Attaching therefore cannot ever give audio.** Audio needs Linux to boot
`qcadsp8380.mbn`, so the ADSP restart — and the Type-C drop — is unavoidable.
There is no userspace escape either: `glink_device_ops` has no
`.create_channel`, so `/dev/rpmsg_ctrl0` cannot open the channel.

Full evidence and what it does to the upstream patch:
`design/upstream-adsp-fix.md`.

## The one open question, now instrumented

**Does the Type-C port re-enumerate after a `charger_pd` restart?**

Still never observed — every failing boot ended in a power-button hold. If it
does come back, booting the ADSP from the initramfs **before** root is mounted
gives a fully Linux-booted ADSP, and therefore audio, with root still on the
T7.

Three facts make that workable: the cmdline is `root=UUID=…` so the disk
returning as `sdb` is harmless; `qcom_q6v5_pas` is a **loadable module**, so
nothing touches the ADSP until `modprobe`; and the UKI is rebuildable on this
machine with `objcopy`, no kernel build needed.

**Do not try to answer it from a running desktop.**
`echo stop > /sys/class/remoteproc/remoteproc0/state` hangs the entire SoC
(denisix's README warns of this) — no log, nothing observed. It has to happen
where remoteproc does a clean boot.

### The experiment is already built

```
~/surface/surface-pro-11-linux/scripts/sp11-build-adsp-test-uki.sh
    Rebuilds the UKI with rd.break=pre-mount and qcom_q6v5_pas blacklisted.
    --install / --rollback / --status. The blacklist matters: udev otherwise
    autoloads the driver during coldplug and binds the ADSP in attach mode
    before you ever get a prompt.

/usr/local/sbin/sp11-adsp   (source: .../scripts/sp11-adsp-initramfs-boot.sh)
    Run at the dracut prompt. Stages firmware from a read-only root, unmounts
    so nothing holds the disk, loads the driver, times how long the root device
    is gone and whether it returns, then reports whether adsp_apps appeared.
```

At the `dracut:/#` prompt:

```sh
mkdir -p /sp11root
mount -o ro /dev/sda5 /sp11root
/sp11root/usr/local/sbin/sp11-adsp
exit                      # resumes the boot; dracut mounts root by UUID
```

Look for, in order: `state after Ns: running` (the full image booted, not
`attached`), `RESULT: THE PORT RE-ENUMERATES` with timings, and
`*** adsp_apps IS PRESENT ***`.

If the disk does not come back, `exit` drops you into dracut's emergency shell
— that is the "no" answer, not a new fault. Power-cycle; the ESP still holds
`EFI/sp11/pre-adsp-test-backup.efi` and `stock-fallback.efi`.

## The cheaper routes to audio

1. **Move root to the internal NVMe.** `denisix/ubuntu-surface-pro-11` has audio
   working on this exact SKU with **no ADSP workaround at all** — it installs
   the firmware and lets remoteproc boot the ADSP, and never hits this bug
   because it installs to NVMe. Shrink Windows, put root there, restore the
   firmware. No kernel work at all.
2. **Root in RAM.** 30 GB available; boot the ISO with casper's `toram` and the
   disk dropping stops mattering. No persistence, but the fastest way to get a
   working audio stack to develop topology/UCM against.

Either way, four downstream pieces are still required after the ADSP boots —
topology blob, UCM2 configs, `alsa-restore` masking plus a WSA routing service,
and the 2.4 MHz DMIC clock (already commit `18b0b569c`). All solved in that
repo; see the table at the end of `design/upstream-adsp-fix.md`.

## Two corrections to notes elsewhere

- **`pd-mapper` runs fine** — `root-cause-20260804.md` records it failing with
  `no pd maps available`. It reads the `.jsn` maps, not the `.mbn`, so hiding
  the firmware never affected it.
- **No userspace `qrtr-ns` is needed.** The name service is in-kernel
  (`net/qrtr/ns.c`). Its absence from systemd is not a bug — do not chase it.

## Ground rules carried from previous sessions

- **The bootloader goes on the T7, never the internal NVMe.**
- `/lib/firmware/.../Denali/` blobs come from the **Windows driver store**;
  `linux-firmware` does not carry them. See `design/upstream-adsp-fix.md`.
- Don't conclude "it never worked" from grepping for errors —
  `adreno_request_fw` logs a failure for the legacy path *and then succeeds*.
  Read the following line. That mistake was made twice.

## What is in here

```
design/     root-cause + the upstream analysis + how to get logs off this machine
tools/      the Windows-side scripts; mostly not runnable here, but documented
logs/       the boot logs this analysis came from
```

`design/upstream-adsp-fix.md` is the densest and most current. Read it second.

The kernel source is **not on this machine** — it lives in WSL on the Windows
side at `/root/sp11/wt-cfg` (and sibling worktrees). Runtime debugging above
needs no source. If you reach the point of needing a build, say so; that has to
happen on the Windows side and the result comes back as a new UKI.
