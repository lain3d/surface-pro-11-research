# ffmpeg patches — Surface Pro 11 hardware video encoder

## `0001-avcodec-v4l2_buffers-do-not-read-past-the-AVFrame-whe.patch`

Fixes a deterministic segfault in ffmpeg's V4L2 mem2mem **encoder** on this
machine:

```
ffmpeg -f lavfi -i testsrc=size=1920x1080:rate=30 -t 2 \
       -pix_fmt nv12 -c:v h264_v4l2m2m -b:v 8M -y out.mp4
```

8 runs out of 8, having written a 48-byte MP4 containing no frames.

Not specific to this hardware, and **still present in ffmpeg master** as of
2026-08-09 — it will bite any V4L2 encoder whose driver rounds the height up.

## What is actually wrong

`v4l2_buffer_swframe_to_buf()` in `libavcodec/v4l2_buffers.c` takes the plane
height from the **driver's** `v4l2_format` and the plane pointer from the
**AVFrame**, then copies `linesize * height` bytes out of the frame. Nothing
requires those two heights to agree. The iris encoder, asked for 1920x1080,
reports 1920x1088 — a perfectly ordinary alignment for a hardware codec that
works in 16-row macroblock rows — so ffmpeg reads past the end of a plane the
frame does not own:

```
luma    plane holds 2,073,600 bytes, ffmpeg copies 2,088,960  -> 15,360 over (8 rows)
chroma  plane holds 1,036,800 bytes, ffmpeg copies 1,044,480  ->  7,680 over (4 rows)
```

The **destination** is already clamped (`FFMIN(size, length-offset)`), so the
mmap'd V4L2 buffer is safe. Only the source read is unguarded.

## Why nobody has fixed it in seven years

The branch this bug lives in was added in
[`b3b958c1`](https://github.com/FFmpeg/FFmpeg/commit/b3b958c19e30af20af69a218ad122d6eed7235a6)
(Aman Gupta, September 2019) — *"teach `ff_v4l2_buffer_avframe_to_buf` about
contiguous planar formats. This fixes h264_v4l2m2m encoding on the Raspberry
Pi."* So the code path exists **because** of the Pi, and the Pi's codec pads
1080 to 1088 exactly as iris does. It has been over-reading there for seven
years.

**Two ffmpeg allocators disagree about padding, and only one of them is safe.**
`libavutil/frame.c:get_video_buffer()` — what `av_frame_get_buffer()` calls —
allocates `FFALIGN(frame->height, 32)` rows, which is 1088 for 1080 and happens
to be exactly what this driver wants. A frame from there absorbs the over-read
completely and nothing is ever wrong. `libavfilter/framepool.c` passes
`pool->height` through unmodified and allocates `sizes[i] + align`, so a frame
arriving at the encoder through a filter graph has exactly `linesize × height`
bytes and no slack. That is the 2,073,616-byte block valgrind names: 1920×1080
plus `av_cpu_max_align()`.

Which allocator produced the frame therefore decides whether this over-reads at
all, and nothing in the encoder can see the difference.

It then survives because **the over-read has no observable effect.** The stray
bytes are written into the destination's own padding rows — in bounds, the
destination is clamped and the two planes fill `sizeimage` exactly — and the
encoder edge-extends over them. Same input through patched and unpatched
binaries gives byte-identical output.

Measured here, on the same unpatched system ffmpeg:

```
software decode -> swscale to nv12 -> hardware encode
   completes normally, 30/30 frames, 140,448 bytes, plays fine
   valgrind: 4 x "Invalid read ... 0 bytes after a block of size 2,073,616"
```

Same over-read, same address, no crash. So this is not a niche crash in an
unusual pipeline — it is a universal out-of-bounds read that only occasionally
finds an unmapped page. What people get in the field is an *occasional* crash
in a subsystem with a reputation for flakiness, which reads as "V4L2 codecs are
unreliable" rather than as one specific line. There are scattered reports that
look like this one — [PyAV #798](https://github.com/PyAV-Org/PyAV/issues/798),
[mpv #10701](https://github.com/mpv-player/mpv/issues/10701),
[rpi-ffmpeg #28](https://github.com/jc-kynesim/rpi-ffmpeg/issues/28) — none with
a deterministic reproducer pointing at the line.

## It does not leak the heap into the bitstream — measured, not assumed

The obvious worry with an out-of-bounds *read* that feeds an encoder is that
adjacent heap ends up in the output file. On this hardware it does not.

Test: 12 frames of 1920x1080 where every frame is a single uniform luma value,
encoded through an unpatched ffmpeg on a path that survives, then decoded with
`-flags2 +ignorecrop` so the coded 1088 rows are visible rather than the
cropped 1080.

```
frame  0: picture 0x20 (100%) | rows 1080-1087: 15,360 bytes, all 0x20
frame  1: picture 0x28 (100%) | rows 1080-1087: 15,360 bytes, all 0x28
...      every frame identical, no foreign values at all
```

Every byte of the over-read region in the coded picture is the picture's own
value. iris knows the visible height is 1080, and **edge-extends from the last
real row** to fill the macroblock padding rather than encoding whatever is in
the buffer there. The heap bytes are copied into the V4L2 buffer and then
discarded by the encoder.

There is a structural reason to expect this generally: the over-read only
happens when the driver's height exceeds the frame's, which is exactly the case
where the encoder has to signal a crop — and an encoder that crops has a
visible rectangle to extend from. It is still implementation-defined, so this
is a statement about iris and not a guarantee for every V4L2 encoder.

So the impact is a crash and a memory-safety defect, **not** an information
disclosure. Worth stating plainly, because "OOB read in a media encoder"
invites the opposite assumption.

## Why it looks intermittent, and why that is a trap

Whether an over-read faults depends entirely on what the allocator happened to
leave after the plane, so the symptom tracks the *resolution*, not the code
path — which makes it look like a codec or driver quirk rather than a memory
bug. Measured here, asking ffmpeg for a size and reading back what the driver
returned:

```
asked        driver returns   over-read   result
1920x1080    1920x1088        8 rows      SIGSEGV
1280x720     1280x736        16 rows      SIGSEGV
1920x1000    1920x1024       24 rows      SIGSEGV
640x488      640x512         24 rows      survives      <- same byte count as 1920x1080
640x480      640x480          none        ok
1920x1088    1920x1088        none        ok
1024x768     1024x768         none        ok
```

`640x488` over-reads exactly as many bytes as `1920x1080` (15,360 luma,
7,680 chroma) and does not fault, because a half-megabyte allocation comes out
of the heap with slack after it while a three-megabyte one ends at a page
boundary. **Do not use "it works at 640" as evidence that a resolution is
safe.**

The first plausible hypothesis here — "it crashes when the height is not a
multiple of 16" — is wrong, and the table above is what killed it: 1280x720 is
a multiple of 16 and crashes, 640x488 is not and does not. The variable is what
the driver *returns*, not what you asked for.

## The fix

Pass the copy length separately from the plane extent. Copy only the rows the
AVFrame owns; keep advancing the destination offset by the driver's plane size,
so the following plane still lands where the driver expects it and `bytesused`
is unchanged.

## Verification

Same source tree, same `configure`, same compiler, patch the only difference:

```
1920x1080   unpatched   SIGSEGV, 0 bytes
1920x1080   patched     30/30 frames, 136,294 bytes, High@5.0
```

- **PSNR against the source: y 52.91 dB, average 52.59 dB** — so the picture is
  correct, not shifted by the alignment fudge or filled with the junk rows.
- **valgrind: exit clean, 0 invalid reads** (unpatched: `Invalid read of size 8
  ... 0 bytes after a block of size 2,073,616`, which is `1920*1080 +
  AV_INPUT_BUFFER_PADDING_SIZE`).
- Regression, all 10/10 frames with correct output dimensions: 1920x1080,
  1920x1088, 1280x720, 640x480, 640x488, 1920x1000, 1024x768, 320x240.

## Reproducing the build

The full Ubuntu ffmpeg package takes a long time to build and none of it is
needed. A minimal configure is enough to test the encoder:

```bash
apt-get source ffmpeg
cd ffmpeg-8.0.1
patch -p1 < .../0001-avcodec-v4l2_buffers-do-not-read-past-the-AVFrame-whe.patch
./configure --disable-everything --disable-doc --disable-network --disable-autodetect \
            --disable-debug --enable-v4l2-m2m --enable-encoder=h264_v4l2m2m \
            --enable-decoder=rawvideo --enable-demuxer=rawvideo --enable-muxer=h264 \
            --enable-protocol=file --enable-filter=null,format,copy,scale \
            --enable-swscale --enable-ffmpeg
make -j$(nproc) ffmpeg
```

Feed it raw NV12 rather than lavfi, since the minimal build has no lavfi
demuxer:

```bash
ffmpeg -f lavfi -i testsrc=size=1920x1080:rate=30 -frames:v 30 \
       -pix_fmt nv12 -f rawvideo -y in1080.nv12
./ffmpeg -f rawvideo -pix_fmt nv12 -s 1920x1080 -r 30 -i in1080.nv12 \
         -c:v h264_v4l2m2m -b:v 8M -f h264 -y out.h264
```

**Nothing here is installed.** The system ffmpeg is the stock Ubuntu package;
the patched binary lives in the build tree only. Recording on this machine goes
through GStreamer (`tools/native/sp11-record.sh`), which does not hit this path.

## Why this is ffmpeg's bug and not the driver's

Worth stating explicitly, because "the driver returned a size I did not ask
for" sounds like a driver fault and is not.

1. **`VIDIOC_S_FMT` is defined to adjust and return.** The driver is required to
   modify the requested format to something the hardware can do and hand the
   adjusted values back; the application must use what it got. A driver that
   refused would be the non-conforming one.
2. **ffmpeg uses the returned height correctly for the destination.** The
   layout it builds matches the driver's own `sizeimage` — 1920×1088×1.5 =
   3,133,440 — to the byte. That half is right.
3. **The source extent is ffmpeg's own knowledge, not the driver's.**
   `frame->height` is 1080 and ffmpeg allocated the frame. Nothing justifies
   using the driver's number to decide how much of ffmpeg's own buffer to read.
4. **The same function already clamps the destination**
   (`FFMIN(size, length-offset)`), so the author knew the two extents could
   diverge — one direction was guarded and the other was not.
5. **The driver's end-to-end behaviour is correct.** With the patch the output
   is 1920×1080 High@5.0 at 52.9 dB PSNR: iris signalled the crop in the SPS and
   encoded the right picture. It only ever needed the right bytes put in front
   of it.
6. **The obvious "driver fix" is worse.** If iris reported 1080 it would still
   need a padded `sizeimage`, and ffmpeg would then place the chroma plane at
   1920×1080 where the hardware expects 1920×1088 — silently wrong colour
   instead of a crash.

## A second bug in the same function, which this patch does NOT fix

`v4l2_buffer_swframe_to_buf()` also ignores the driver's `bytesperline`. It does
one flat `memcpy` per plane, which silently assumes the source and destination
strides are equal. When the driver pads the *width*, they are not, and the
encoded video comes out sheared. No crash, no warning, just wrong output.

iris aligns width up to a multiple of 128. Every common HD width already is one
— 1920, 1280, 1024, 640 — which is why this hides at the resolutions people
actually use. It appears immediately at, say, 320 or 352 or 480 or 854.

Measured with the *patched* binary, so the over-read is out of the picture and
this is the stride bug alone:

```
asked 320x180   frame linesize 320   driver bytesperline 384   ->  PSNR 12.1 dB
asked 640x360   frame linesize 640   driver bytesperline 640   ->  PSNR 51.2 dB
```

Confirmed as a shear rather than a guess. Source is a monotonic ramp, identical
on every row; destination row *r* is read by the driver from byte `r*384` while
ffmpeg wrote it at `r*320`, so row *r* should start at source column
`(384r) mod 320`:

```
decoded row   1: starts at source column ~53    predicted 64
decoded row   2: starts at source column ~126   predicted 128
decoded row   3: starts at source column ~200   predicted 192
decoded row  10: starts at source column ~0     predicted 0
decoded row  40: starts at source column ~0     predicted 0
decoded row 100: starts at source column ~0     predicted 0
```

Every fifth row is correct, because `384r ≡ 0 (mod 320)` when `r` is a multiple
of 5. That is a 64-pixel-per-row shear and nothing else.

**This one is not a security bug, and the two should not be lumped together.**
`bytesperline` comes from the driver, i.e. from local hardware, not from
anything an attacker supplies — the most an attacker picks is a width, and the
driver then chooses the alignment. And the damage stays inside the destination
buffer, which is clamped. So it is a correctness defect that produces wrong
video, full stop. The split is worth keeping straight:

| | memory-safe? | output correct? |
|---|---|---|
| height over-read (patch 0001) | **no** — reads out of bounds | yes, output is byte-identical |
| stride shear (not fixed here) | yes — writes stay clamped | **no** — silently sheared |

One code-reading caveat, unverified and *not* reachable on this driver: in
`v4l2_bufref_to_buf()`, `length` is `unsigned int` and `offset` is `int`, so
`length - offset` wraps if `offset` ever exceeds `length`, and the clamp stops
clamping. That needs the summed plane extents to exceed `sizeimage`, which needs
`frame->linesize > bytesperline`. It cannot happen here — iris rounds
`bytesperline` up to a multiple of 128 while ffmpeg's linesize is the width
rounded up to at most 64, so `bytesperline >= linesize` for every width. A
driver that returned an unpadded `bytesperline` smaller than ffmpeg's aligned
linesize would be a different story. Noted as an observation, not a finding: no
such driver was tested.

**Note the contrast with every other ffmpeg encoder wrapper.** `mediacodecenc.c`
and `omx.c` face exactly the same problem — copy an AVFrame into a buffer whose
geometry the hardware dictates — and both do:

```c
av_image_copy2(dst_data, dst_linesize, frame->data, frame->linesize,
               avctx->pix_fmt, avctx->width, avctx->height);
```

One call, row by row, separate source and destination strides, and the height
taken from the frame. That is immune to **both** bugs. The V4L2 path hand-rolls
a flat `memcpy` and gets both wrong.

So the properly correct fix for this function is to do what the others do —
build the destination pointers and linesizes from the driver's returned
geometry and hand the copy to `av_image_copy2`, which subsumes patch 0001. That
is a larger change than the crash fix and is not attempted here: it is untested
against any driver but this one, and a minimal validated fix for a segfault is
worth more upstream than a broad one that has been exercised on a single
device.

## Not the same as the other two encoder findings

Three separate things turned up around this encoder in mission 19, with three
different owners:

| symptom | owner |
|---|---|
| bitrate control is per frame, not per second | the iris kernel driver |
| encoder emits `profile=Baseline level=1.0` at 1080p | GStreamer's caps fixation |
| encoding segfaults | ffmpeg, this patch |

Worth keeping apart. Note that ffmpeg's own output is `High@5.0` — the driver's
defaults — which is independent corroboration that the level-1 stream is
GStreamer's doing and not the driver's.
