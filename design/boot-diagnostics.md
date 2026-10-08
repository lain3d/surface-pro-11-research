# Getting a boot log off a machine whose log disk dies

The Surface Pro 11 boots Linux from a USB-C disk. The failure under
investigation *is* that disk going offline mid-boot. So the ordinary answer —
read the journal — cannot work: **the journal lives on the disk that dies.**

Four mechanisms were tried. Three fail for structural reasons worth recording,
because each looks like it should work.

## 1. The persistent journal — fails, and lies convincingly

`journalctl` shows a boot that ends cleanly at:

```
systemd-journald[779]: Time spent on flushing to /var/log/journal/... is 32.369ms for 1324 entries
```

That is not a healthy boot. It is what a dead disk looks like from the inside:
journald flushes, the disk goes away, and nothing further can ever be written.
**A journal ending at `systemd-journal-flush` is a symptom, not a clean finish.**
This was misread once as "zero I/O errors, the config is the fix", and that
conclusion was wrong.

Two further traps in reading it:

- **`ro,noload` hides the newest writes.** `tools/sp11-journal.sh` mounts that
  way on purpose so it never writes to the machine's root filesystem, but the
  most recent entries are still unreplayed in the ext4 journal and are therefore
  invisible. A boot can appear absent when it is merely unreplayed. Mounting
  `rw` replays it — that is a write, and it is the only way to see those
  entries.
- **WSL cannot read these journals.** WSL is Ubuntu 22.04 (systemd 249), the
  Surface runs 26.04 (systemd 259), and 249 rejects the newer files with
  `unsupported feature, ignoring file` — which reads as corruption and is not.
  Run the target's own `journalctl` through its own loader instead.

## 2. The initramfs pre-pivot hook — fails by construction

`usr/lib/dracut/hooks/pre-pivot/50-sp11-log.sh` writes `dmesg`, a storage
summary and firmware presence to the **T7's** ESP. Useful for the initramfs
phase, and it is how the `uas`-vs-`usb-storage` question was settled.

But it cannot see this failure. It runs at ~4–8 s, is killed at switch-root, and
the disk dies at ~11 s. It also writes to a partition **on the disk that
disappears**, so in the UUID-hang case there is nowhere to write at all.

Note the hook's environment: the initramfs has no `head`, `tail`, `grep`, `awk`,
`wc`, `du` or `find`. Filtering is `sed -n`. And dracut *sources* hooks, so an
`exit` aborts the caller before its own `source_hook cleanup`.

## 3. ramoops / pstore — correct, and useless here

`CONFIG_PSTORE_CONSOLE=y` plus a 1 MiB `ramoops` carveout at `0xb0000000`
(verified against the built DTB as overlapping no reserved region). It
initialises perfectly:

```
printk: legacy console [ramoops-1] enabled
pstore: Registered ramoops as persistent store backend
ramoops: using 0x100000@0xb0000000, ecc: 0
```

And it never once recovered anything: `pstore=no` on every boot. **ramoops lives
in DRAM and only survives a warm reset.** The machine hangs, so the only way out
is holding the power button — a cold power cycle, and the contents are gone.

Two other pstore facts worth keeping: `/sys/fs/pstore` is a bare mount point
until something is mounted on it (systemd does that *after* switch-root, far too
late for an initramfs hook — mount it yourself), and `systemd-pstore.service`
skips on `ConditionDirectoryNotEmpty`, so an unmounted directory is
indistinguishable from "no crash captured".

Worth revisiting only if the machine can be made to warm-reset — Ctrl+Alt+Del at
the failure may work, since systemd is alive at that point.

## 4. sp11-winlog — works

`tools/sp11-winlog.sh`, installed to `/usr/local/sbin/sp11-winlog` and enabled
via `sysinit.target.wants`. It streams `/dev/kmsg` to the **internal NVMe's EFI
System Partition** — a different physical disk, which survives the T7 going
away.

This is what produced the root-cause evidence in
`design/root-cause-20260804.md`.

### The three constraints that make it work

Each was wrong in the first version, and each failure is visible in that
version's own output.

**One long-lived reader, not a polling loop.** The first version re-exec'd
`dmesg` every second. Once the root filesystem stopped serving reads, `exec`
failed and every subsequent sample was empty — the log filled with
`uptime= root_rw=`, and the last usable sample was 0.4 s *before* the failure,
which is exactly the part that mattered. A single `cat /dev/kmsg`, exec'd once at
startup, keeps writing straight through.

**Mount `-o sync`.** Page-cache writes are lost if power goes before the
unmount, and this machine gets power-cycled at the hang.

**Heartbeat with builtins only.** `read < /proc/uptime` is a redirect;
`$(cat ...)` is a process. `sleep` is a binary too — after the disk dies the loop
free-runs, so post-failure `t=+Ns` labels are iteration counts, not seconds:

```
t=+65s uptime=12.75 root=rw,relatime,stripe=8191,emergency_ro,shutdown kmsg_alive=yes
t=+89s uptime=12.80 root=rw,relatime,stripe=8191,emergency_ro,shutdown kmsg_alive=yes
```

24 iterations across 0.05 s of real time. **Trust `uptime=`, not `t=`.** Note
`emergency_ro` in the mount options — that is ext4 forcing itself read-only after
errors, and it is a precise marker of when the filesystem gave up.

### Reading the output

```
W:\sp11-diag\kmsg.txt    full kernel log, /dev/kmsg format, continues past the failure
W:\sp11-diag\live.log    per-second heartbeat: uptime, root mount options, reader alive
```

`live.log` **appends** across boots; `kmsg.txt` is rewritten each boot, so it
only ever holds the most recent one.

Boots are delimited by `t=+0s`, which is the reliable marker. A
`=== sp11-winlog started ===` line is written too, but only by versions that
have it — the version that caught the root cause did not, so a log can contain
several boots under a single header. A `=== sp11-winlog finished ===` line means
the loop ran its full window and unmounted; **a boot with no `finished` line was
power-cycled at the hang**, which is itself a useful signal.

`/dev/kmsg` lines are `priority,sequence,timestamp_us,flags;message`, with
continuation lines indented. The timestamp is microseconds since boot, so
`11739850` is 11.739850 s.

### Safety, since it writes to the Windows boot disk

- targets the ESP by serial `D297-77C3`, never "first vfat found" (the T7's is
  `5011-AB20`)
- refuses unless `EFI/Microsoft` is present on the mounted volume
- only ever creates `/sp11-diag`; never touches `EFI/Microsoft`, `EFI/Boot`,
  `Capsules` or `System Volume Information`
- unmounts when its window closes, so the volume is not left mounted

The ESP is plain FAT32 and is not inside BitLocker's encrypted volume. Adding an
unlaunched file cannot extend any PCR, so it cannot trigger a recovery prompt.
The real risk is a power cut mid-write, which `-o sync` plus small writes early
in boot keeps to milliseconds. `chkdsk` has reported the volume clean after every
run so far.

## Choosing a mechanism

| what you need | use |
|---|---|
| initramfs phase, which storage driver bound | pre-pivot hook → T7 ESP |
| a boot that completed | `tools/sp11-journal.sh` |
| a boot where the root disk died | **sp11-winlog → Windows ESP** |
| a kernel panic, if a warm reset is possible | ramoops |

The general rule: **write the log to a device that is not the one under
investigation, from a process that needs no `exec` after it starts.**

## The intermittent no-boot, 2026-08-06: it is not a timing race

One boot in roughly ten does not come up. The capture that survives it is
`sp11-diag/state.txt` on the **Windows** ESP, written by the initqueue timeout
hook, and it opens with the whole answer:

```
sp11 failure capture - the root filesystem never appeared
uptime:  27.19 320.94

== block devices ==   loop0..loop7, nvme0n1, nvme0n1p1..p4     <- no sda
== usb devices ==                                              <- EMPTY
```

**Not a slow disk — no USB bus at all.** That distinction matters, because the
obvious fix is to wait longer, and it would do nothing. Measured across three
consecutive good boots:

| | |
|---|---|
| T7 enumerates | `usb 4-1: new SuperSpeed Plus Gen 2x1` at **1.33–1.37 s** |
| `sda` attached | **1.38–1.47 s** |
| root mounted | **~3.1 s** |
| initramfs gives up | **27 s** |

A twenty-fold margin. The failure is binary: the disk is there in 1.4 seconds or
it is never there. `rootdelay` and `rd.timeout` are the wrong lever.

### What did not come up

`state.txt` lists devices with no driver bound. Most of that list is normal for
an initramfs — the modules live on the root filesystem that never mounted. Two
groups are not normal, because USB *must* work at this point:

```
unbound: a600000.usb          <- both dwc3 controllers
unbound: a800000.usb          <- the T7 lives on this one (xhci-hcd.2.auto, bus 4)
unbound: fd3000.phy           <- eUSB2 HS PHYs
unbound: fd9000.phy
unbound: c432000.spmi:pmic@7:phy@fd00     <- eUSB2 repeaters on the PMICs
unbound: c432000.spmi:pmic@a:phy@fd00
unbound: c432000.spmi:pmic@b:phy@fd00
```

The QMP SuperSpeed PHYs `fd5000.phy` and `fda000.phy` are **absent from the list**
— they bound. So the SS side came up and the **high-speed side did not**, which is
consistent with the repeater → eUSB2 PHY → dwc3 chain never resolving. Both
controllers, not one, which is why there is no USB at all rather than a missing
port.

### The structural reason it can vary boot to boot

`fw_devlink` reports dependency **cycles** around exactly these nodes and
resolves them by dropping the ordering guarantee:

```
/soc@0/usb@a800000: Fixed dependency cycle(s) with /soc@0/phy@fda000
/soc@0/usb@a600000: Fixed dependency cycle(s) with /soc@0/phy@fd5000
/soc@0/phy@fda000:  Fixed dependency cycle(s) with .../typec-mux@8
```

and even on a **good** boot the Type-C side cannot link to the controllers:

```
qcom_pmic_glink pmic-glink: Failed to create device link (0x180) with supplier a600000.usb for /pmic-glink/connector@0
qcom_pmic_glink pmic-glink: Failed to create device link (0x180) with supplier a800000.usb for /pmic-glink/connector@1
```

Ordering that is not enforced is ordering that usually works. That is the shape
of a one-in-ten failure.

### Honest limit, and the one thing that would close it

**There is no kernel log for the failed boot.** `sp11-winlog` starts from
`sysinit.target`, i.e. after the root filesystem is mounted, so a boot that dies
in the initramfs produces no `kmsg.txt` at all. `state.txt` is a snapshot of
device state with no `dmesg` behind it, so *which* link in the chain failed
first is inference, not measurement.

The fix is to have the initqueue timeout hook dump `dmesg` beside `state.txt`.
It is an initramfs change, so it costs a full UKI rebuild — and note the hook
that writes `state.txt` **is not in this repo**; it exists only on the machine.
Recovering it into `tools/` should come first, or the next edit to it is
untracked too.
