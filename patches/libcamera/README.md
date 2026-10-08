# libcamera patches for the Surface Pro 11 IMX681

## What is here

`0001-ipa-libipa-add-CameraSensorHelper-for-IMX681.patch` — adds the
`CameraSensorHelper` that libcamera's software ISP needs to run auto-exposure
on this sensor.

## Why it is needed

libcamera brings this camera up through the `simple` pipeline handler (which
carries an explicit `qcom-camss` entry) and debayers `SRGGB10` in the software
ISP. That part works out of the box. But libcamera ships helpers for 27 sensors
and `imx681` is not one of them, so `IPASoft` cannot convert an analogue gain
*code* into a gain:

```
IPASoft: Failed to create camera sensor helper for imx681
```

Its AE loop then reasons with the wrong model. Measured on this machine:

| | exposure | gain code | actual gain | result |
|---|---|---|---|---|
| stock libcamera 0.7.0 | 3546 (max) | 18 | 1.02x | black preview |
| with this patch | 2210 | 1014 | 102x | correctly exposed |

Frames flowed in both cases. The camera was not broken; the exposure was.

## The constants, and how they were established

`gain = 1024/(1024 - code)` — Sony's usual reciprocal law, the same constants
IMX477 and IMX708 already use in this file. Not taken from a datasheet, which we
do not have. A gain sweep was captured through the qcom-camss RDI path and
`gain = C/(D - code)` solved pairwise over all ten combinations of codes 900,
960, 1000, 1014 and 1020, using per-frame medians so a few per cent of clipped
highlights could not skew the fit:

```
D = 1026 .. 1035 (median 1028)   at black level 15.5
D = 1020 .. 1027 (median 1026)   at black level 16.0   <- brackets 1024
```

Black level `0x40` at 10 bits, also measured: dark frames sit at 15–16 of 255 on
the high byte of each RAW10 pixel, i.e. 62–64 at 10 bits.

## The second patch: sensor properties

`0002-libcamera-add-camera_sensor_properties-entry-for-IMX6.patch` adds the
`camera_sensor_properties` entry that mission 18 deliberately left out for want
of a unit cell size. The Windows side then recovered one from the driver store's
`IMX681DeLoB35P3A5.json` — `pixel_width_mm` and `pixel_height_mm` both `0.001`,
so 1000 nm square, measured rather than inferred from the array aspect ratio.

```
Property: UnitCellSize = 1000x1000
Property: PixelArraySize = 4032x3024
Property: PixelArrayActiveAreas = [ (8, 64)/4032x3024 ]
```

`sensorDelays` is still left zeroed, which was checked rather than assumed:
`camera_sensor_legacy.cpp:498` treats an all-zero delay block exactly like a
missing entry, so the unverified defaults still apply *and* the "No sensor
delays found" warning still prints. We have the cell size and we do not have the
delays, and the log now says exactly that. Silencing that warning by inventing
plausible delays would buy nothing and cost the reminder.

Apply `0001` first; `0002`'s context sits between the `imx519` and `imx708`
entries.

## Building

The distro package is rebuilt rather than an upstream tree installed over it —
same soname, same paths, and `apt install --reinstall` is a clean rollback.
libcamera signs IPA modules per build, so **the core library and the IPA package
must be installed together**; mixing a locally built module with the distro
library fails signature verification and falls back to running the IPA isolated.

```bash
# source packages need enabling first (see /etc/apt/sources.list.d/ubuntu-src.sources)
sudo apt-get build-dep -y libcamera
apt-get source libcamera
cd libcamera-0.7.0
patch -p1 < .../0001-ipa-libipa-add-CameraSensorHelper-for-IMX681.patch
DEB_BUILD_OPTIONS="parallel=$(nproc) nocheck" dpkg-buildpackage -b -uc -us
cd .. && sudo dpkg -i libcamera0.7_*.deb libcamera-ipa_*.deb \
                     gstreamer1.0-libcamera_*.deb libcamera-v4l2_*.deb
systemctl --user restart wireplumber pipewire pipewire-pulse
```

Verify it took:

```bash
strings /usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so | grep -cx imx681   # 1, not 0
```

## Still outstanding

**Colour is uncalibrated.** There is no `imx681.yaml` IPA tuning file, so
libcamera falls back to `uncalibrated.yaml`. Expect approximate white balance —
the same class of problem documented in `tools/native/README.md`. This one needs
a colour target rather than more code.

Closed since these patches were first written, all on the kernel side:

- Mode 0 delivers full resolution — `0x2000 = 0x01` is in the driver's mode
  table as of mission 17, `mode0_class` no longer exists, and
  `/etc/modprobe.d/imx681-sp11.conf` has been deleted.
- The sensor subdev implements `get_selection`, so `PixelArrayActiveAreas` is
  real and *"The sensor kernel driver needs to be fixed"* is gone.
- The broken duplicate `3840x2160` entry is no longer the one libcamera picks.

Note that **`/dev/video0` is no longer the camera** — the hardware video codec
came up in mission 19 and iris registers first, so camss now starts at
`/dev/video2`. libcamera is unaffected because it follows the media graph.
