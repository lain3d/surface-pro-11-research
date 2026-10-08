#!/usr/bin/env python3
"""Same measurement, but with a positive control built from the image itself.

The first pass found no spectral cliff in the 4032x3024 capture and concluded
it was native. That conclusion is only worth anything if the measurement could
have detected a cliff at all -- and there are three reasons it might not:
JPEG quantisation noise is broadband and could fill the stop band, the ISP
sharpens, and the "control" capture was only assumed to be a native mode.

So: manufacture a known upscale from the suspect image itself. Downscale it to
3520x2640, put it back to 4032x3024, re-encode as JPEG. Same content, same
encoder settings, same everything except that this one is definitely resampled.

If the synthetic upscale shows a cliff and the real capture does not, the test
is sensitive and the capture is native. If the synthetic shows no cliff either,
the test proves nothing and must not be used either way.
"""
import io
import numpy as np
from PIL import Image

CROP = 2048
BASE = "/mnt/c/Users/Crazy/OneDrive/Pictures/Camera Roll/"
SUSPECT = BASE + "WIN_20260807_19_48_04_Pro.jpg"
CONTROL = BASE + "WIN_20260807_19_29_42_Pro.jpg"


def spectrum(im):
    im = im.convert("L")
    w, h = im.size
    a = np.asarray(im, dtype=np.float64)
    y0, x0 = (h - CROP) // 2, (w - CROP) // 2
    a = a[y0:y0 + CROP, x0:x0 + CROP]
    a = a - a.mean()
    win = np.hanning(CROP)
    a = a * win[:, None] * win[None, :]
    P = np.abs(np.fft.fftshift(np.fft.fft2(a))) ** 2
    c = CROP // 2
    yy, xx = np.mgrid[0:CROP, 0:CROP]
    r = np.sqrt((yy - c) ** 2 + (xx - c) ** 2) / c
    nb = 100
    idx = np.clip((r * nb).astype(int), 0, nb - 1)
    prof = np.bincount(idx.ravel(), P.ravel(), minlength=nb) / \
           np.maximum(np.bincount(idx.ravel(), minlength=nb), 1)
    return (np.arange(nb) + 0.5) / nb, prof


def band(freq, prof, lo, hi):
    return prof[(freq >= lo) & (freq < hi)].mean()


def measure(label, im, note=""):
    freq, prof = spectrum(im)
    ref = band(freq, prof, 0.30, 0.40)
    n = prof / ref
    below = band(freq, prof, 0.78, 0.86)
    above = band(freq, prof, 0.90, 0.98)
    d = 10 * np.log10(max(above / below, 1e-30))
    pts = "  ".join("%.2f:%6.1f" % (f, 10 * np.log10(max(n[int(f * 100)], 1e-30)))
                    for f in (0.70, 0.80, 0.87, 0.92, 0.98))
    print("  %-42s %s   step %+.1f dB  %s" % (label, pts, d, note))
    return d


if __name__ == "__main__":
    sus = Image.open(SUSPECT)
    q = sus.quantization

    print("normalised to the 0.30-0.40 band; 'step' = mean(0.90-0.98) - mean(0.78-0.86)")
    print("a 3520->4032 upscale puts its ceiling at %.3f of Nyquist\n" % (3520 / 4032))

    real = measure("REAL      4032x3024 as captured", sus)

    # the positive control: same pixels, definitely resampled
    small = sus.convert("RGB").resize((3520, 2640), Image.LANCZOS)
    back = small.resize((4032, 3024), Image.LANCZOS)
    buf = io.BytesIO()
    back.save(buf, "JPEG", qtables=q, subsampling=2)
    buf.seek(0)
    synth = measure("SYNTHETIC 4032->3520->4032, re-encoded", Image.open(buf),
                    "<- must show a cliff for the test to mean anything")

    # a second synthetic, bicubic, in case the interpolator matters
    back2 = sus.convert("RGB").resize((3520, 2640), Image.BICUBIC) \
                              .resize((4032, 3024), Image.BICUBIC)
    buf2 = io.BytesIO()
    back2.save(buf2, "JPEG", qtables=q, subsampling=2)
    buf2.seek(0)
    measure("SYNTHETIC bicubic instead of Lanczos", Image.open(buf2))

    ctrl = measure("CONTROL   3840x2160 capture", Image.open(CONTROL))

    print()
    print("=== is the instrument switched on? ===")
    sep = real - synth
    if sep > 3:
        print("  YES. The known upscale sits %.1f dB below the real capture," % sep)
        print("  so a cliff of that size would have been visible. It is not")
        print("  there in the real capture: the 4032x3024 read is NATIVE, and")
        print("  the registry value was preview overwriting the still's.")
    else:
        print("  NO. The known upscale is only %.1f dB from the real capture," % sep)
        print("  so this measurement cannot tell them apart -- JPEG noise or")
        print("  ISP sharpening is filling the stop band. It says nothing")
        print("  either way and must not be cited.")
