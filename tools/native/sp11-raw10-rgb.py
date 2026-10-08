#!/usr/bin/env python3
"""MIPI RAW10-packed Bayer frame -> colour PNG.

    ./sp11-raw10-rgb.py /tmp/imx681-frame.raw 4032 3024 out.png

`sp11-raw10-preview.py` writes a single-channel 'L' image, which is why its
output is grey no matter how colourful the scene: the Bayer mosaic is still
there, it is just being displayed as luminance. This does the demosaic.

WHAT IT DOES, AND WHAT IT DELIBERATELY DOES NOT

Demosaic is **2x2 binning**, not interpolation. Each Bayer quad becomes one RGB
pixel, so a 4032x3024 sensor gives a 2016x1512 image. That is the real colour
resolution of a Bayer sensor; anything larger is invented detail. Binning also
averages four photosites, which is worth a lot at the gains this camera needs
indoors.

Layout is SRGGB (settled in mission 16 by an illuminant A/B, see
design/native/session-state-linux.md):

    R  Gr        R  = quad (0,0)      G = mean(Gr, Gb)
    Gb B         B  = quad (1,1)

Then three corrections, in this order, because raw sensor data is none of them:

1. **Black level.** ~15/255 of pedestal that carries no signal. Left in, it
   washes colour toward grey — the same effect that made mission 16's first
   colour attempt read as "no CFA".
2. **White balance.** Scale R and B so their means match G. Raw Bayer is
   green-heavy (twice the green photosites, and the CFA passes more green), so
   an unbalanced frame looks green even under neutral light.

   **Grey-world is not the default, and the reason is worth reading.** It
   assumes the whole scene averages to neutral. Point this camera at a room lit
   by one coloured lamp and that assumption is simply false: grey-world cancels
   the cast — that is what it is for — and the colour matrix then amplifies
   whatever residual is left, which lands on the opposite axis. A room under a
   magenta lamp came out green. The picture looked plausible, which is what
   made it dangerous.

   The tell is in the gains. Raw Bayer is green-heavy by construction: twice as
   many green photosites and a wider green passband. So **a correct white
   balance has both gains >= 1** — it is bringing weak red and weak blue up to
   green, never pushing them down. Grey-world returned `R 0.851` on that frame.
   A gain below 1 means the balance is compensating scene content rather than
   sensor response, and this script now says so out loud.

   In order of preference:
     --wb-gains R,B   explicit, if you know them
     --wb-rect        a patch you know is neutral AND not clipped
     --grey-world     only for a scene that really does average grey
   Default is a fixed preset (below), which preserves the scene's own cast.
   Coordinates for --wb-rect are in *output* pixels, i.e. half sensor size.
3. **Gamma.** Sensor data is linear, displays are not. Linear data shown
   directly looks far too dark in the midtones.

4. **Colour matrix.** Raw camera RGB is not sRGB — the CFA's passbands overlap
   far more than sRGB's primaries do, so uncorrected output is desaturated and
   greenish however well it is balanced. A proper CCM comes from characterising
   the sensor against known patches; we have no such measurement for this
   module, so the matrix here is a mild generic one that mostly undoes the
   channel overlap. **It is cosmetic, not colorimetric** — do not measure
   anything from its output. `sp11-bayer-phase.py` is the tool for measuring
   colour, and it works on the raw planes for exactly this reason.

   It is applied *after* the tone curve rather than in linear light, which is
   the wrong order in principle. At this sensor's noise levels the alternative —
   round-tripping through 8-bit linear — bands the shadows visibly, and that
   costs more than the hue error does. Use `--no-ccm` to see the difference.

Everything hot runs at C speed inside PIL: byte-slicing for the unpack, an
Image.blend for the green average, and a 256-entry LUT per channel via
Image.point. numpy is NOT installed on the SP11 image and this does not need it.
"""
import argparse
import sys
from PIL import Image

GAMMA = 2.2

# Fixed white-balance preset, applied relative to green. NOT a calibration --
# we have no measurement of this module against known patches. It encodes only
# the one thing that is certainly true (raw is green-heavy, so both gains
# exceed 1) at roughly daylight proportions. It renders a coloured lamp as that
# colour instead of neutralising it, which is the behaviour you want when the
# question is "what colour is the light".
WB_PRESET = (1.85, 1.30)   # (R, B)

# Mild raw-RGB -> sRGB-ish matrix. Rows sum to 1 so neutrals stay neutral and
# only saturation changes. See the module docstring: cosmetic, not colorimetric.
CCM = (
    1.35, -0.30, -0.05, 0,
    -0.15, 1.30, -0.15, 0,
    -0.05, -0.35, 1.40, 0,
)


def planes(data, w, h):
    """Split a RAW10-packed SRGGB frame into four half-res 'L' planes.

    Five bytes carry four pixels; the first four bytes are those pixels' high
    8 bits. row[n::5] for n in 0..3 pulls each of the four out at C speed, so
    x = 0,4,8.. is row[0::5], x = 2,6,10.. is row[2::5], and interleaving the
    two recovers every even-x pixel. Same for odd-x from slices 1 and 3.
    """
    stride = w * 10 // 8
    w2, h2 = w // 2, h // 2
    R, Gr, Gb, B = bytearray(), bytearray(), bytearray(), bytearray()

    def split(row):
        """-> (even-x bytes, odd-x bytes), each w2 long."""
        ev = bytearray(w2)
        ev[0::2] = row[0::5]
        ev[1::2] = row[2::5]
        od = bytearray(w2)
        od[0::2] = row[1::5]
        od[1::2] = row[3::5]
        return ev, od

    for y in range(h2):
        top = data[(2 * y) * stride:(2 * y + 1) * stride]
        bot = data[(2 * y + 1) * stride:(2 * y + 2) * stride]
        if len(bot) < stride:
            break
        e, o = split(top)
        R += e
        Gr += o
        e, o = split(bot)
        Gb += e
        B += o

    mk = lambda buf: Image.frombytes('L', (w2, len(buf) // w2), bytes(buf))
    return mk(R), mk(Gr), mk(Gb), mk(B)


def percentile(img, pct):
    hist = img.histogram()
    target = sum(hist) * pct / 100.0
    acc = 0
    for v, n in enumerate(hist):
        acc += n
        if acc >= target:
            return v
    return 255


def mean_above(img, floor):
    hist = img.histogram()
    tot = sum(hist[floor:]) or 1
    return sum(v * n for v, n in enumerate(hist) if v >= floor) / tot


def lut(black, white, gain, gamma):
    span = max(1, white - black)
    out = []
    for v in range(256):
        n = (v - black) / span * gain
        n = 0.0 if n < 0 else (1.0 if n > 1 else n)
        out.append(int(255 * n ** (1.0 / gamma) + 0.5))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('raw')
    ap.add_argument('width', type=int)
    ap.add_argument('height', type=int)
    ap.add_argument('out', nargs='?', default='colour.png')
    ap.add_argument('--gamma', type=float, default=GAMMA)
    ap.add_argument('--no-wb', action='store_true', help='no balance at all')
    ap.add_argument('--wb-gains', default=None, metavar='R,B',
                    help='explicit gains relative to green')
    ap.add_argument('--wb-rect', default=None, metavar='X,Y,W,H',
                    help='balance off a known-neutral patch, in output pixels')
    ap.add_argument('--grey-world', action='store_true',
                    help='balance so the whole frame averages neutral. Cancels '
                         'a coloured lamp -- see the module docstring')
    ap.add_argument('--black', type=int, default=None, help='override black level')
    ap.add_argument('--white', type=int, default=None, help='override white point')
    ap.add_argument('--white-pct', type=float, default=99.5,
                    help='percentile taken as white (default 99.5); lower '
                         'brightens, useful when a blown lamp pins the top end')
    ap.add_argument('--no-ccm', action='store_true',
                    help='skip the raw->sRGB colour matrix')
    ap.add_argument('--ccm-strength', type=float, default=1.0,
                    help='blend the matrix toward identity, 0..1')
    ap.add_argument('--full', action='store_true',
                    help='upscale back to sensor size (invents no detail)')
    a = ap.parse_args()

    data = open(a.raw, 'rb').read()
    expect = a.width * a.height * 10 // 8
    print(f'{len(data):,} bytes; expected {expect:,} for {a.width}x{a.height} '
          f'RAW10 packed -- {"complete" if len(data) == expect else "TRUNCATED"}')
    if len(data) < expect:
        sys.exit('refusing to demosaic a truncated frame')

    R, Gr, Gb, B = planes(data, a.width, a.height)
    G = Image.blend(Gr, Gb, 0.5)

    black = a.black if a.black is not None else percentile(G, 0.5)
    white = a.white if a.white is not None else percentile(G, a.white_pct)
    if white <= black:
        white = min(255, black + 1)

    measured = False
    if a.no_wb:
        gR = gB = 1.0
    elif a.wb_gains:
        gR, gB = (float(v) for v in a.wb_gains.split(','))
    elif a.wb_rect or a.grey_world:
        measured = True
        src = (R, G, B)
        if a.wb_rect:
            x, y, bw, bh = (int(v) for v in a.wb_rect.split(','))
            src = tuple(p.crop((x, y, x + bw, y + bh)) for p in src)
            print(f'white balance off {bw}x{bh} patch at ({x},{y})')
        else:
            print('white balance: grey-world over the whole frame')
        mR, mG, mB = (mean_above(p, black) for p in src)
        gR = (mG - black) / max(1e-6, mR - black)
        gB = (mG - black) / max(1e-6, mB - black)
        gR = max(0.2, min(4.0, gR))
        gB = max(0.2, min(4.0, gB))
    else:
        gR, gB = WB_PRESET
    print(f'black {black}  white {white}  wb gains  R {gR:.3f}  B {gB:.3f}'
          f'  gamma {a.gamma}')

    # Raw is green-heavy, so a real white balance never pulls a channel below
    # green. If a measured balance does, it is neutralising the scene's own
    # colour -- the reference patch was coloured, clipped, or the scene simply
    # is not grey. Say so; a silently wrong cast is the failure mode here.
    if measured and (gR < 1.0 or gB < 1.0):
        low = ' and '.join(n for n, g in (('R', gR), ('B', gB)) if g < 1.0)
        print(f'WARNING: measured gain {low} < 1.0. Raw Bayer is green-heavy, so'
              ' a correct balance raises R and B toward green, never below it.'
              '\n         This balance is cancelling the scene\'s own colour --'
              ' a coloured lamp will come out as its complement.'
              '\n         Use a neutral, unclipped --wb-rect, or drop the flag'
              ' for the fixed preset.')

    rgb = Image.merge('RGB', (
        R.point(lut(black, white, gR, a.gamma)),
        G.point(lut(black, white, 1.0, a.gamma)),
        B.point(lut(black, white, gB, a.gamma)),
    ))
    if not a.no_ccm:
        s = a.ccm_strength
        ident = (1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0)
        m = tuple(i + (c - i) * s for c, i in zip(CCM, ident))
        rgb = rgb.convert('RGB', m)
        print(f'colour matrix applied, strength {s:.2f}')
    if a.full:
        rgb = rgb.resize((a.width, a.height), Image.BICUBIC)
    rgb.save(a.out)
    print(f'wrote {a.out}  {rgb.size[0]}x{rgb.size[1]}')


if __name__ == '__main__':
    main()
