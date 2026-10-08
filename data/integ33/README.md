# integ33 — the reliable-boot snapshot

Snapshot of the kernel source changes, `.config` and base commit behind the
configuration that made this machine boot dependably. Before it, the root
filesystem dropped on roughly 18% of boots.

**Regenerated 2026-08-06.** The first cut of this directory was taken after 21
clean boots and carried patches 0001–0005. It has since been refreshed from the
same worktree, so the diff now also carries **0004** (`ps883x` orientation
seeding) and **0006** (`pan_enable` made writable, so `ALTMODE_PAN_EN` can be
deferred rather than suppressed). Patch 0006 replaced 0005 in the build; the
earlier form of every file here is in git history at `aa7b9d8`, which is the
one to check out if the exact `integ33` UKI ever has to be reproduced bit for
bit.

This directory exists because all six patches live **uncommitted** in the WSL
worktree `/root/sp11/wt-cfg`, which is a single point of failure. Everything
needed to rebuild is here.

## What it is

```
kernel      7.1.3-sp11-stockcfg-gf2cc827b6b89
base        f2cc827b6b896127c9f1397a3c9d85dc00a57963
            ("Merge branch 'usb4/platform-nhi' into integration/iso2")
UKI         C:\sp11-stage\BOOTAA64-integ33-KNOWN-GOOD.efi
            102F24D15526BAC4D361ED14BE3A686540ED1838DB4D651BA2DF33410AA8E180
fallback    C:\sp11-stage\BOOTAA64-stock-KNOWN-GOOD.efi
            68975CE36899AD67B3081C397FFFF6ABB7774D6125F7315F12BAC3314E7835E2
```

The `integ34`, `integ35` and `integ36` UKIs are this same source. They differ
only in the initrd (the ADSP pre-mount hook) and the cmdline, not in the kernel.

| file | what |
|---|---|
| `all-patches.diff` | the complete worktree diff, exactly as built |
| `config` | the `.config` that produced it |
| `kernel.release` | the release string the modules are stamped with |
| `base-commit` | the upstream commit the diff applies to |

The same changes are also split by concern in `../../patches/0001..0006`.

## Rebuilding

```sh
git checkout f2cc827b6b89
cp data/integ33/config .config
git apply data/integ33/all-patches.diff
make LOCALVERSION= -j$(nproc) Image vmlinuz.efi
```

`LOCALVERSION=` empty is required — `CONFIG_LOCALVERSION` already carries the
whole suffix and `LOCALVERSION_AUTO` is off. Never change
`CONFIG_LOCALVERSION` to label a build: `DRM_MSM`, `ATH12K`,
`SURFACE_AGGREGATOR` and `HID_GENERIC` are all `=m` and load from the T7's
module tree, so a new suffix orphans every one of them.

## Machine state this snapshot assumes

```
cmdline   root=UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd ro loglevel=7 console=tty0
          clk_ignore_unused pd_ignore_unused arm64.nopauth
          modprobe.blacklist=thunderbolt regulator_ignore_unused
          pmic_glink_altmode.pan_enable=0

T7        /lib/modules/7.1.3-sp11-stockcfg-gf2cc827b6b89   matches
          NOTHING of ours blacklisted in /etc/modprobe.d   (ucsi_glink is live)
          /etc/systemd/system/sp11-altmode.service         enabled, fires ~55s
          /lib/firmware/.../Denali/qcadsp8380.mbn.disabled  hidden, so the ADSP
                                                            attaches and is never restarted
          qcdxkmsuc8380.mbn (zap shader) installed

port      either USB-C port boots. tools\sp11-which-port.ps1 reports which.
```

`CONFIG_MODVERSIONS` is not set, so a rebuild that touches only builtins does
**not** require reinstalling modules — vermagic is all that has to match.

## What works, and what does not

**USB-C DisplayPort works**, which it did not when this snapshot was first
taken. `pan_enable=0` buys the boot stability and also suppresses the
notification DP alt mode is signalled through — so patch 0006 makes the
parameter writable and `sp11-altmode.service` turns it back on at ~55 s, once
the race window has passed. Both the disk and the external display survive.

**Audio still does not work, and the reason is now measured.** With
`qcadsp8380.mbn` hidden the ADSP *attaches* to the image firmware already left
running, and an attached ADSP never brings up the `adsp_apps` glink channel —
so `gprsvc` never registers and every LPASS device stays in deferred probe
(`snd-x1e80100: WSA Playback: error getting cpu dai name`). Booting the full
21.07 MiB image *does* register `gprsvc:service:2:1` and `2:2`, confirmed twice
on 2026-08-06 — but restarting the ADSP restarts `charger_pd`, which drops the
Type-C port about 85 ms later, and that is fatal once root is mounted rw. The
open work is doing it from the dracut pre-mount hook, before root is mounted.
