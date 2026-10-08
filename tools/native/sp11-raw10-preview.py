#!/usr/bin/env python3
"""MIPI RAW10-packed frame -> PNG preview.

    ./sp11-raw10-preview.py /tmp/imx681-frame.raw 3520 2640 out.png

The capture path (`tools/sp11-camera-test.sh --capture`) writes `pRAA`, which is
MIPI RAW10 packed: five bytes carry four pixels, the first four bytes holding
each pixel's high 8 bits and the fifth packing the four low-2-bit remainders.
For a preview the high byte alone is plenty, so this ignores the fifth byte.

Expected file size is W*H*10/8 exactly. 3520x2640 -> 11,616,000 bytes. If the
file is that size, the frame is complete; a short file means the capture was
truncated.

Only needs PIL. numpy is NOT installed on the SP11 image.
"""
import sys
from PIL import Image


def unpack_hi(data, w, h):
    """Return a PIL 'L' image of the high byte of every pixel."""
    stride = w * 10 // 8
    img = Image.new('L', (w, h))
    px = img.load()
    for y in range(h):
        row = data[y * stride:(y + 1) * stride]
        if len(row) < stride:
            break
        for x in range(w):
            # 4 pixels per 5-byte group; high bytes are the first 4 of the group
            i = (x >> 2) * 5 + (x & 3)
            px[x, y] = row[i]
    return img


def stretch(img, lo_pct=1.0, hi_pct=99.0):
    hist = img.histogram()
    tot = sum(hist)
    acc = 0
    lo = 0
    for i, v in enumerate(hist):
        acc += v
        if acc > tot * lo_pct / 100:
            lo = i
            break
    acc = 0
    hi = 255
    for i in range(255, -1, -1):
        acc += hist[i]
        if acc > tot * (100 - hi_pct) / 100:
            hi = i
            break
    span = max(1, hi - lo)
    return img.point(lambda v: max(0, min(255, (v - lo) * 255 // span)))


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    out = sys.argv[4] if len(sys.argv) > 4 else 'preview.png'
    data = open(path, 'rb').read()
    expect = w * h * 10 // 8
    print(f'{len(data):,} bytes; expected {expect:,} for {w}x{h} RAW10 packed'
          f' -- {"complete" if len(data) == expect else "TRUNCATED"}')
    zeros = data.count(0)
    print(f'zero bytes {zeros:,} ({zeros/len(data)*100:.2f}%),'
          f' mean {sum(data)/len(data):.2f}')
    img = stretch(unpack_hi(data, w, h))
    # halve for a manageable preview; Bayer pairs collapse to one pixel
    img.resize((w // 4, h // 4)).save(out)
    print('wrote', out)


if __name__ == '__main__':
    main()
