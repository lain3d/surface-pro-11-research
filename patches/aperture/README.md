# GNOME Snapshot / libaperture — why its recordings are unwatchable

Two bugs in `aperture/src/viewfinder.rs` (gnome-snapshot 50.0), found while
answering "why is the video from the camera app so bad". Neither is ours and
neither is the camera's.

## Bug 1 — the VP8 bitrate is set 1024x too low

`DEFAULT_BITRATE = 2048`, meant as **kbit/s**, is applied to each encoder in an
`ElementProperties` map. The per-element units are not the same, and the code
handles that — for every element but one:

```rust
const DEFAULT_BITRATE: u32 = 2048;

ElementPropertiesMapItem::builder("x264enc")
    .field("bitrate", DEFAULT_BITRATE)            // property is kbit/s -> 2 Mbit/s  OK
ElementPropertiesMapItem::builder("openh264enc")
    .field("bitrate", DEFAULT_BITRATE * 1024)     // property is bit/s  -> 2 Mbit/s  OK
ElementPropertiesMapItem::builder("vah264enc")
    .field("bitrate", DEFAULT_BITRATE)            // VA-API, kbit/s     -> 2 Mbit/s  OK
ElementPropertiesMapItem::builder("vp8enc")
    .field("target-bitrate", DEFAULT_BITRATE)     // property is bit/s  -> 2 kbit/s  WRONG
```

`gst-inspect-1.0 vp8enc` is explicit: *"target-bitrate: Target bitrate (in
bits/sec)"*. So VP8 is asked for **2 kbit/s** where 2 Mbit/s was intended. The
`openh264enc` line right above it does the `* 1024` conversion correctly, which
is what makes this a slip rather than a misunderstanding.

Measured on this machine, 1080p30 off the camera:

```
vp8enc target-bitrate=2048       (as shipped)        80,989 bytes / 11.6 s =  0.06 Mbit/s
vp8enc target-bitrate=2097152    (what was meant) 2,247,994 bytes /  6.2 s =  2.89 Mbit/s
openh264enc bitrate=2097152      (as shipped)     3,563,499 bytes / 11.8 s =  2.42 Mbit/s
```

The fix is one character short of trivial:

```diff
     ElementPropertiesMapItem::builder("vp8enc")
-        .field("target-bitrate", DEFAULT_BITRATE)
+        .field("target-bitrate", DEFAULT_BITRATE * 1024)
```

**Which encoder you get decides whether you see this.** `camera.rs:276` picks
the container profile purely on whether `openh264enc` is registered:

```rust
let format = if aperture::is_h264_encoding_supported() {
    aperture::VideoFormat::H264Mp4      // openh264enc, correctly configured
} else {
    aperture::VideoFormat::Vp8Webm      // vp8enc, 1024x too low
};
```

`openh264enc` lives in `gstreamer1.0-plugins-bad`, which is not installed by
default on Ubuntu. So a stock desktop falls into the VP8 path and records at
kilobits. Installing that one package moves it to the H.264 path and the
problem disappears — which is a very confusing bug to report, because it comes
and goes with a package nobody associates with the camera.

## Bug 2 — `v4l2h264enc` is not in the properties map at all

Turning on `enable-hardware-encoding` raises the hardware encoder above the
software one in the GStreamer registry:

```rust
if let Some(encoder) = registry.lookup_feature("v4l2h264enc") {
    if self.enable_hw_encoding() {
        encoder.set_rank(gst::Rank::PRIMARY + 1);    // beats openh264enc at PRIMARY
```

But there is **no `ElementPropertiesMapItem` for `v4l2h264enc`**, so unlike
every other encoder in the list it gets no bitrate at all and runs at whatever
the driver defaults to. On this machine that is `video_bitrate = 20000000`,
which the iris driver then applies **per frame** (see `design/native/` — that
is a separate driver bug). Measured:

```
v4l2h264enc, no bitrate set, 1080p30    159,161,722 bytes / 4.8 s = 267 Mbit/s
                                                              (8.9 Mbit per frame)
```

About **2 GB per minute**. So on this platform `enable-hardware-encoding`
replaces a file that is 1000x too small with one that is 100x too large.

A fix is less trivial than bug 1: `v4l2h264enc` has no `bitrate` property, only
`extra-controls`, which takes a `GstStructure`. And the correct *value* is
platform-dependent for as long as the iris per-frame bug exists. Worth reporting
upstream; not worth guessing at.

## Status

Nothing here is patched or installed. Both are recorded so that the next person
measuring this camera does not spend the time we did concluding the sensor is
fine — it is, twice over.

The working path on this machine is `tools/native/sp11-record.sh`, which sets an
explicit bitrate and applies the iris per-frame correction.
