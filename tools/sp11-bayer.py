#!/usr/bin/env python3
"""Determine the Bayer/CFA order from one captured raw frame.

The IMX681 driver declares SRGGB10 and that is a guess -- the order is not in
any Windows file, and register 0x3820 (binning/flip) differs between the Surface
blob and mainline, so the phase really is board-specific. One frame decides it.

Renders the same raw data under all four orders. The correct one is the image
whose colours are right; the other three will show swapped red/blue or maze-like
artefacts.

Capture first (INTEG image, sensor bound, pipeline linked):

    v4l2-ctl -d /dev/video0 --set-fmt-video=width=4032,height=3024,pixelformat=RG10 \\
             --stream-mmap --stream-count=1 --stream-to=frame.raw

Then:

    ./sp11-bayer.py frame.raw 4032 3024            # writes bayer-RGGB.png etc
    ./sp11-bayer.py frame.raw 4032 3024 --stats    # no files, just numbers

Point the camera at something strongly and unambiguously coloured before
capturing -- a red object on a neutral background is ideal. Grey or white scenes
cannot distinguish red-blue swaps and will waste the trip.

Needs numpy. Pillow is optional; without it you still get --stats.
"""
import sys

try:
    import numpy as np
except ImportError:
    sys.exit("needs numpy:  sudo apt install python3-numpy  (or pip install numpy)")

ORDERS = ("RGGB", "BGGR", "GRBG", "GBRG")


def load(path, w, h, bits):
    raw = np.fromfile(path, dtype="<u2" if bits > 8 else np.uint8)
    want = w * h
    if raw.size < want:
        sys.exit(f"file holds {raw.size} samples, need {want} for {w}x{h}. "
                 "Wrong dimensions, or the frame is packed rather than "
                 "unpacked 16-bit -- try the sensor's *10 (unpacked) format.")
    if raw.size > want:
        print(f"note: {raw.size - want} extra samples ignored (padding/metadata)")
    a = raw[:want].reshape(h, w).astype(np.float32)
    return a / float((1 << bits) - 1)


def demosaic(a, order):
    """Deliberately crude 2x2 block averaging -- half resolution, no
    interpolation. Enough to judge colour, and it cannot mask a wrong order
    behind a clever interpolator."""
    h, w = a.shape
    h, w = h & ~1, w & ~1
    tl, tr = a[0:h:2, 0:w:2], a[0:h:2, 1:w:2]
    bl, br = a[1:h:2, 0:w:2], a[1:h:2, 1:w:2]
    if order == "RGGB":   r, g, b = tl, (tr + bl) / 2, br
    elif order == "BGGR": r, g, b = br, (tr + bl) / 2, tl
    elif order == "GRBG": r, g, b = tr, (tl + br) / 2, bl
    elif order == "GBRG": r, g, b = bl, (tl + br) / 2, tr
    else: raise ValueError(order)
    return np.dstack([r, g, b])


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    path, w, h = argv[0], int(argv[1]), int(argv[2])
    bits = 10
    if "--bits" in argv:
        bits = int(argv[argv.index("--bits") + 1])
    stats_only = "--stats" in argv

    a = load(path, w, h, bits)
    print(f"{path}: {w}x{h}, {bits}-bit, mean level {a.mean():.3f}")
    if a.mean() < 0.02:
        print("WARNING: frame is nearly black. Nothing can be concluded from it.")
    if a.mean() > 0.98:
        print("WARNING: frame is nearly saturated. Nothing can be concluded.")

    print(f"\n{'order':<6} {'R mean':>8} {'G mean':>8} {'B mean':>8}   channel balance")
    for o in ORDERS:
        rgb = demosaic(a, o)
        m = rgb.reshape(-1, 3).mean(axis=0)
        print(f"{o:<6} {m[0]:>8.4f} {m[1]:>8.4f} {m[2]:>8.4f}   "
              f"R/G {m[0]/max(m[1],1e-6):.2f}  B/G {m[2]/max(m[1],1e-6):.2f}")

    print("""
Reading the numbers:
  RGGB and BGGR differ only by swapping R and B, so their means are mirrored.
  So are GRBG and GBRG. The means alone therefore narrow it to a PAIR, not a
  single answer -- you have to look at an image, or shoot a known colour and see
  which pairing puts red where the red object is.""")

    if stats_only:
        return 0
    try:
        from PIL import Image
    except ImportError:
        print("\n(Pillow not installed; skipping PNGs. Re-run with --stats, or "
              "pip install pillow)")
        return 0
    for o in ORDERS:
        rgb = demosaic(a, o)
        p = np.percentile(rgb, 99.5)
        img = np.clip(rgb / max(p, 1e-6), 0, 1) ** (1 / 2.2)     # rough gamma
        out = f"bayer-{o}.png"
        Image.fromarray((img * 255).astype(np.uint8)).save(out)
        print(f"  wrote {out}")
    print("\nOpen all four. The one with correct colours is the sensor's order.\n"
          "Then set MEDIA_BUS_FMT_S<order>10_1X10 in imx681.c and delete the\n"
          "comment marking it a guess.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
