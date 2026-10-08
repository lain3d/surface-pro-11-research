# Booting it: custom ISO, or VM?

Two questions with opposite answers. The VM one clarifies the ISO one, so it goes
first.

## VM: yes you can, but it proves nothing

**Can this machine run ARM64 Linux in a VM?** Yes, and it already does. WSL2 is
installed and working:

```
distro: Ubuntu 22.04.5 LTS
arch:   aarch64          <- native, no emulation, no cross-compiling
cores:  12
mem:    29 GiB
disk:   847 G free
gcc:    11.4.0
```

Constraints worth knowing: this is Windows 11 **Home**, so the full Hyper-V role and
Hyper-V Manager are unavailable — `VirtualMachinePlatform` is enabled (that is what
WSL2 uses) but `HypervisorPlatform` (WHP) is **disabled**, so third-party VMMs like
QEMU with hardware acceleration would need it turned on first. WSL2 is the path of
least resistance.

**But a VM cannot test any of the Surface enablement, and that matters.** Everything
in `denisix/ubuntu-surface-pro-11` is device-hardware-specific:

| Component | Bus / mechanism | Visible in a VM? |
|---|---|---|
| Digitizer (touch + pen) | HID-over-SPI on `spi10` | No |
| Speakers | WSA884x over SoundWire | No |
| Microphones | DMIC via VA macro | No |
| Audio/compute DSP | ADSP/CDSP remoteproc + firmware | No |
| Sensors, tablet mode | SSC / QMI, SSAM | No |
| NPU | Hexagon HTP0 | No |
| Lid switch, keyboard | SSAM over UART2 | No |

None of these are PCIe devices, so even full Hyper-V with DDA passthrough would not
help — there is nothing to pass through. In a VM you get generic ARM64 Ubuntu.

**So: WSL2 is a build environment, not a test environment.** That is genuinely useful,
just not for validation.

## ISO: possible, but not the right first move

The repo is **not an image builder**. It is `install.sh` (39 KB, phase-based) applied
on top of an already-installed Ubuntu Concept system, with `kernel-patches/`
(`sp11-touchscreen`, `dmic-clock`, `rfkill-wifi-mac`), userspace daemons, udev rules,
systemd units and PipeWire/UCM config.

Note `--kernel` is **not** part of the default `--all` run — the patched kernel is a
separate, explicit phase that builds from `$HOME/linux-sp11`.

Building a custom live ISO would mean: build the patched kernel + DTB, remaster the
Ubuntu Concept squashfs, inject modules and the DTB, pre-apply the install.sh file
phases, and bundle firmware. Each is doable; together it is a project.

Three complications specific to a *live USB*:

1. **The stock ISO may not have a DTB for this machine.** The Concept image is
   `resolute-desktop-arm64+x1e-20260326.iso` (2026-03-26), and the Denali device tree
   landed upstream around April 2026 via `soc-dt-7.1`. Booting likely needs a
   `devicetree` line added to GRUB pointing at a supplied DTB — which is exactly what
   dwhinham's `build.sh` does.
2. **Wi-Fi is dead in the live session** without the rfkill bypass and board-data
   fixup. Plan on USB-C Ethernet or phone tethering.
3. **DSP firmware comes from the Windows partition** (`.mbn` blobs). Device-specific
   and not redistributable, so it cannot cleanly live in a general ISO — fine for your
   own machine, awkward for anything shareable.

### Recommended order

1. **Build the patched kernel in WSL2 first.** Native aarch64, 12 cores, doesn't touch
   the machine's boot state, and is fully reversible — nothing is committed. This
   de-risks the slowest step before you disturb anything. `flex` and `bison` are the
   only missing build deps (`apt install flex bison libssl-dev libelf-dev`).
2. **Boot the stock Ubuntu Concept ISO from USB**, install to NVMe *alongside* Windows.
   **Do not erase Windows** — it is the firmware source.
3. **Run `install.sh`**, phase by phase rather than `--all`, so failures are
   attributable.
4. **Build a custom ISO only afterwards**, if you want reproducibility. By then you
   know which pieces actually work on your specific unit.

## You do not have to shrink anything

Installing to an **external USB SSD** leaves the internal NVMe completely untouched —
no shrinking, no repartitioning, no bootloader changes to the Windows disk. The USB
drive gets its own ESP and root; you pick it as the install target and boot it from the
Surface UEFI boot menu (**Volume-Down + Power**).

For reference, the internal layout is a single 954 GB NVMe: ESP (0.3 GB), MSR,
`C:` 951.6 GB with 421.6 GB free, and a 2 GB recovery partition. There *is* room to
shrink — but there is no reason to.

Notes on the external route:

- Use a **USB-C SSD, not a flash stick.** Flash sticks are painfully slow for a root
  filesystem and wear out fast.
- `grub-install` may add a UEFI **NVRAM boot entry**. That is a firmware variable, not
  a change to the Windows disk, and it is reversible. The removable fallback path
  (`\EFI\BOOT\BOOTAA64.EFI`) also works without one.
- "Enable boot from USB devices" must be on in Surface UEFI settings.
- A pure **live session** with no install also works and touches nothing, but is
  impractical here — you would be re-applying a patched kernel and the whole of
  `install.sh` on every boot.

## The real risk is BitLocker, not partitioning

This machine's `C:` is **`FullyEncrypted`** — XTS-AES-128, protectors
`RecoveryPassword, Tpm`. Two consequences, and the first can lock you out of Windows:

**1. Disabling Secure Boot will trigger a BitLocker recovery prompt.** The TPM
protector is sealed to platform state, and Secure Boot is part of that state. On the
next Windows boot you will be asked for the 48-digit recovery key.

Before changing any UEFI setting:

- Retrieve and verify the recovery key. On a Home device with automatic device
  encryption it is normally escrowed to your Microsoft account:
  **account.microsoft.com/devices/recoverykey**
- Or suspend protection first, which avoids the prompt entirely:
  ```
  manage-bde -protectors -disable C: -rebootcount 0     # suspend indefinitely
  manage-bde -protectors -enable  C:                    # re-enable when done
  ```

**2. Linux cannot read the Windows partition.** The repo's fallback advice — mount the
Windows install and extract Qualcomm DSP firmware with
`sp11-grab-fw.sh --windows-root` — **will not work** against an encrypted volume
without `dislocker` and the recovery key.

Work around it by extracting the firmware **from Windows, before rebooting**, onto the
USB drive. The repo also ships pre-packaged firmware, so this may not come up at all —
but do not plan on reaching into `C:` from Linux.

## Before starting

- Retrieve the **BitLocker recovery key** and confirm it works. This is the one step
  that can cost you the Windows install.
- **Secure Boot must be disabled** (Volume-Up + Power → UEFI settings).
- Everything here targets an OLED X1E80100 SKU (`Surface_Pro_11th_Edition_2076`) —
  the same as this machine, which is why it is worth attempting at all.
