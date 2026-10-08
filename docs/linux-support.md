# Linux on this Surface Pro 11 — peripheral status

Surface Pro 11 is **"Denali"** upstream. This machine (X1E80100, OLED) maps to
`x1e80100-microsoft-denali-oled.dts`; the X1P/LCD SKU is `x1p64100-microsoft-denali.dts`,
with `x1-microsoft-denali.dtsi` shared between them.

> **Superseded in large part by `linux-prior-art.md`.** Most gaps below have since
> been solved by `denisix/ubuntu-surface-pro-11` (pushed 2026-07-29) — including the
> pen, audio and suspend. USB4 and cameras remain broken. Read that first.

**Support is upstream in mainline, and current.** The community port
(`dwhinham/linux-surface-pro-11`, last pushed 2025-10-29) reads as abandoned but is
not — the work moved into the kernel. The shared DTSI is 1319 lines and its most
recent commits are March–April 2026, merged via the `soc-dt-7.1` tag.

Status below is drawn from the upstream device tree (authoritative and current) plus
the community port's test results (older, but the only source for "does it actually
work in practice").

## Verdict against the two hard requirements

| Requirement | Status |
|---|---|
| Detachable keyboard (older, non-Bluetooth) | ✅ **Working** — Type Cover confirmed |
| Pen | ✅ **Working** — solved by others, see `linux-prior-art.md` |

### Keyboard — supported

The upstream DTSI enables the Surface Aggregator Module on UART2:

```dts
&uart2 {
	status = "okay";
	embedded-controller {
		compatible = "microsoft,surface-sam";
		interrupts-extended = <&tlmm 91 IRQ_TYPE_EDGE_RISING>;
		current-speed = <4000000>;
	};
};
```

SAM is what exposes the detachable keyboard and touchpad. The community port confirms
the Flex Keyboard works when attached. The older non-Bluetooth Surface Pro Keyboard
uses the *same* pogo connector and the same SAM/HID path — and is simpler, since it has
no Bluetooth mode to negotiate. Untested specifically, but there is no mechanism by
which it would work less well than the Flex.

### Pen — not supported, and not close

The pen is not a separate device from Linux's perspective: inking (position, pressure,
tilt) arrives through the **digitizer**, the same controller as the touchscreen. The
Slim Pen's Bluetooth link carries only the button and haptics.

So "pen works" requires the touchscreen stack to work. It doesn't. The upstream device
tree is unambiguous about why:

```dts
&i2c0 {
	status = "okay";
	/* Something @39, @3e, @44 */
};

&i2c4 {
	status = "okay";
	/* Something @12, @14, @16, @18, @1a */
};
```

The buses are enabled; the devices on them are literally unidentified. On the Windows
side these correspond to the `Surface Touch G6` stack — `Surface Touch Communications`,
`Surface Touch Screen Device`, `Surface Touch Pen Processor` — a Microsoft-proprietary
touch/pen subsystem.

> **This section was wrong, and is corrected in `linux-gap-analysis.md`.**
>
> It originally claimed the pen needed an IPTS-scale multi-year reverse-engineering
> effort. It does not. The digitizer is `ACPI\MSHW0485` with compatible ID
> **`PNP0C51`** — the standard ACPI ID for a **HID-over-SPI** device, a published
> Microsoft specification bound to Microsoft's inbox `hidspi.sys`. Open
> implementations already exist (`linux-surface/spi-hid`, plus an upstream `spi-hid`
> v3 series posted April 2026).
>
> The unidentified I2C devices below are real, but they are *not* the digitizer —
> that lives on SPI, most likely QUP1 SE2. Getting the pen working is device-tree and
> driver-integration work, not reverse engineering. See `linux-gap-analysis.md`.

The pen is therefore **not currently working, but is tractable** — the most likely
path to a usable Linux install on this machine. Until the digitizer is wired up,
Bluetooth gives you a pen that pairs, reports battery, and does nothing when it
touches the screen.

## Full peripheral status

Legend: ✅ works · ⚠️ partial · ❌ not working

| Peripheral | Status | Notes |
|---|---|---|
| NVMe (WD SN740) | ✅ | `pcie6a` enabled upstream |
| GPU / 3D (Adreno X1-85) | ✅ | freedreno; 3D accel on X1E. X1P was behind |
| Display / backlight | ✅ | needs a DP hack — the OLED panel reports max link rate 0, hardcoded workaround |
| USB-C DisplayPort alt mode | ✅ | since 6.15-rc6 |
| Wi-Fi (FastConnect 7800) | ✅ | ath12k/WCN7850; needed an rfkill workaround |
| Bluetooth | ✅ | `qcom,wcn7850-bt` on uart14; needs udev rule for a valid MAC |
| Detachable keyboard + touchpad | ✅ | via `microsoft,surface-sam` |
| USB3 (USB-C ports) | ⚠️ | ports work; Surface Dock connector does not |
| Audio | ⚠️ | speakers work but distort; microphone unusably distorted. Needs `alsa-ucm-conf` + audioreach topology |
| Suspend / resume | ⚠️ | resume can hang or come back to a black screen; freezes reported even without suspending. Suspending *with* the Surface keyboard attached reportedly freezes almost always |
| **Touchscreen** | ❌ | unidentified I2C devices |
| **Pen** | ❌ | same digitizer as touchscreen |
| Cameras (front, rear, IR) | ❌ | Spectra 695 ISP; Windows Hello therefore also dead |
| Status LEDs | ❌ | |
| **USB4 / Thunderbolt** | ❌ | no external display via the official USB4 dock |

Firmware blobs must be extracted from the Windows install (Qualcomm QRD reference
drivers) or many components stay broken.

## This kills the Linux eGPU path

Early in this project, ARM64 Linux looked like a possible shortcut for eGPU work — the
reasoning being that `amdgpu` already runs on ARM64, so the driver problem largely
disappears. The reasoning was sound; the premise is not. **USB4/Thunderbolt does not
work on this device under Linux**, so there is no PCIe tunnel for an eGPU to arrive
through.

So on this hardware today:

- **Windows**: USB4 tunneling works, NVIDIA ships an ARM64 driver, everything except
  hotplug/sleep polish is in place.
- **Linux**: better GPU driver *situation* in the abstract, no transport to use it.

That inverts the usual expectation and is worth remembering before reaching for the
"just use Linux" answer.

## If you want to track it

- Upstream DTS: `arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi` and
  `x1e80100-microsoft-denali-oled.dts`
- Community port and issue tracker: `dwhinham/linux-surface-pro-11` (stale repo,
  still-active issues)
- The upstream series: `lore.kernel.org` — "Microsoft Surface Pro 11 support",
  Dale Whinham

The thing to watch is the upstream `spi-hid` series, and anyone adding a digitizer
node to the Denali device tree. The unidentified I2C devices at `i2c0@39/3e/44` and
`i2c4@12/14/16/18/1a` are still unknown, but they are not the digitizer.
