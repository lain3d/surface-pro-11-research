#!/usr/bin/env python3
"""Which Bayer phase is which -- from a shot of a known-coloured subject.

    ./sp11-bayer-phase.py frame.raw 3520 2640 --expect blue [--crop 0.4]

imx681.c declares SRGGB10 and says so is a one-in-four guess; the SP10 thread
measured SBGGR10 on their module, with a different IMAGE_ORIENTATION, so it does
not transfer. One frame of a strongly coloured subject settles it here.

The method: split the frame into the four 2x2 CFA phases, take each phase's mean
over a centre crop, and see which phase the subject's colour lands on. For a
blue subject the brightest phase is B and the darkest is R; the two greens sit
between and near each other. The green pair is the control -- if Gr and Gb are
far apart, the frame is not a clean single-colour field and the call is unsafe.

TWO THINGS THAT WASTED SIX FRAMES BEFORE THIS WORKED

1. RAISE analogue_gain FIRST. At default gain a dim indoor scene lands at a mean
   of ~16/255, and almost all of that is black-level pedestal, which carries no
   colour. Ratios between phases then come out within 1 % of each other no
   matter what you photograph -- a 100x change in illuminant colour moved
   R/B by 1.3 %. With gain at 1023 the same scene means ~130 and the same
   comparison moves R/B by 30 %. If the spread is small, suspect exposure
   before you suspect the sensor.

       sudo v4l2-ctl -d /dev/v4l-subdev22 --set-ctrl=analogue_gain=1023

2. USE AN EMISSIVE SOURCE, OR CHANGE THE ROOM LIGHT. A blue *object* under a
   warm lamp reflects almost no blue -- blue shorts filling the whole frame came
   back darker than the empty room and perfectly neutral. Recolouring the room
   light works far better than holding something up, and it needs no aim and no
   timing.

The strongest form is an A/B between two illuminants at the same gain: shoot the
scene under blue light and again under warm, and check that R and B swap. That
is what settled it here -- B/R went 1.241 under blue to 0.916 under warm, with
|Gr-Gb| = 0.08. A single frame can be argued with; a flip cannot.

Reads the high byte of each RAW10 pixel, like sp11-raw10-preview.py. PIL only;
numpy is not installed on the SP11 image.
"""
import argparse
import sys

# Phase (x,y) parity -> colour, for each candidate CFA order. Index is
# (y & 1) * 2 + (x & 1), i.e. the raster order of the 2x2 tile.
LAYOUTS = {
    'SRGGB': ('R', 'Gr', 'Gb', 'B'),
    'SBGGR': ('B', 'Gb', 'Gr', 'R'),
    'SGRBG': ('Gr', 'R', 'B', 'Gb'),
    'SGBRG': ('Gb', 'B', 'R', 'Gr'),
}


def phase_means(data, w, h, crop):
    """Mean of each 2x2 phase over a centred crop. Returns 4 floats."""
    stride = w * 10 // 8
    x0, x1 = int(w * (1 - crop) / 2), int(w * (1 + crop) / 2)
    y0, y1 = int(h * (1 - crop) / 2), int(h * (1 + crop) / 2)
    tot = [0] * 4
    cnt = [0] * 4
    for y in range(y0, y1):
        row = data[y * stride:(y + 1) * stride]
        if len(row) < stride:
            break
        base = (y & 1) * 2
        for x in range(x0, x1):
            # 4 pixels per 5-byte group; the high bytes are the first 4
            i = (x >> 2) * 5 + (x & 3)
            p = base + (x & 1)
            tot[p] += row[i]
            cnt[p] += 1
    return [t / c if c else 0.0 for t, c in zip(tot, cnt)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path')
    ap.add_argument('width', type=int)
    ap.add_argument('height', type=int)
    ap.add_argument('--expect', choices=['blue', 'red', 'green'], required=True,
                    help='the subject colour that was actually in front of the lens')
    ap.add_argument('--crop', type=float, default=0.4,
                    help='centre fraction to measure (default 0.4), so the subject '
                         'need not fill the frame edge to edge')
    a = ap.parse_args()

    data = open(a.path, 'rb').read()
    expect = a.width * a.height * 10 // 8
    if len(data) != expect:
        sys.exit(f'{len(data):,} bytes, expected {expect:,} -- truncated frame, '
                 f'phase means would be meaningless')

    m = phase_means(data, a.width, a.height, a.crop)
    print(f'centre {a.crop:.0%} crop, phase means (raster order of the 2x2 tile):')
    for i, v in enumerate(m):
        print(f'  phase {i} (x{i & 1}, y{i >> 1}): {v:7.2f}')

    order = sorted(range(4), key=lambda i: -m[i])
    spread = m[order[0]] - m[order[3]]
    print(f'\nbrightest phase {order[0]}, darkest phase {order[3]}, spread {spread:.2f}')

    if spread < 4.0:
        print('\nSpread is tiny -- the subject is not strongly coloured, or the frame '
              'is too dark. This does NOT settle the Bayer order; reshoot.')
        return

    # Under a blue subject the B phase is brightest and R darkest; red inverts it.
    # Green is the awkward case: two phases tie for brightest.
    want_bright = {'blue': 'B', 'red': 'R', 'green': 'G'}[a.expect]
    print()
    for name, layout in LAYOUTS.items():
        bright, dark = layout[order[0]], layout[order[3]]
        greens = [m[i] for i in range(4) if layout[i].startswith('G')]
        gdiff = abs(greens[0] - greens[1])
        ok = bright.startswith(want_bright)
        # A correct layout also puts the two greens together in the middle.
        ok = ok and gdiff < spread / 2
        print(f'  {name}10: brightest={bright:2s} darkest={dark:2s} '
              f'|Gr-Gb|={gdiff:6.2f}   {"CONSISTENT" if ok else "no"}')

    print('\nThe green pair is the control: a layout that puts the subject colour on '
          'the right phase\nbut splits the greens is not actually consistent.')


if __name__ == '__main__':
    main()
