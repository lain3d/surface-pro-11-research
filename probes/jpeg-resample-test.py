#!/usr/bin/env python3
"""Second attempt: resampling leaves periodic correlations, not just a cliff.

Interpolating an image makes each output sample a fixed linear combination of
its neighbours, and the pattern of those combinations repeats with the
resampling ratio. A second-difference residual suppresses scene content and
exposes it as a peak in the residual's spectrum. Unlike the stop-band cliff,
this survives moderate JPEG.

3520 -> 4032 is a ratio of 1.14545, predicting a peak at |1 - 1/1.14545| =
0.1270 cycles/sample.

The catch, and the reason this is run with the same synthetic control as
before: JPEG's own 8-pixel block grid puts a peak at 0.1250, four FFT bins
away. If the control cannot be separated from the real capture, this test is
as blind as the last one and gets reported as such.
"""
import io
import numpy as np
from PIL import Image

BASE = "/mnt/c/Users/Crazy/OneDrive/Pictures/Camera Roll/"
SUSPECT = BASE + "WIN_20260807_19_48_04_Pro.jpg"
CONTROL = BASE + "WIN_20260807_19_29_42_Pro.jpg"
N = 4096


def residual_spectrum(im):
    a = np.asarray(im.convert("L"), dtype=np.float64)
    h, w = a.shape
    # second difference across rows: kills smooth content, keeps interpolation
    r = np.abs(2 * a[:, 1:-1] - a[:, :-2] - a[:, 2:])
    r = r - r.mean(axis=1, keepdims=True)
    seg = min(N, r.shape[1])
    r = r[:, :seg] * np.hanning(seg)[None, :]
    P = np.abs(np.fft.rfft(r, n=N, axis=1)) ** 2
    return np.fft.rfftfreq(N), P.mean(axis=0)


def peak_near(freq, P, f0, halfwidth=0.004):
    m = (freq > f0 - halfwidth) & (freq < f0 + halfwidth)
    local = P[m]
    # local floor from the surrounding shoulders
    ms = ((freq > f0 - 4 * halfwidth) & (freq < f0 - halfwidth)) | \
         ((freq > f0 + halfwidth) & (freq < f0 + 4 * halfwidth))
    floor = np.median(P[ms])
    return 10 * np.log10(max(local.max() / max(floor, 1e-30), 1e-30))


def measure(label, im, note=""):
    freq, P = residual_spectrum(im)
    resamp = peak_near(freq, P, 0.12698)
    jpeg = peak_near(freq, P, 0.1250)
    print("  %-40s  resample-peak %+6.1f dB   jpeg-grid %+6.1f dB  %s"
          % (label, resamp, jpeg, note))
    return resamp


if __name__ == "__main__":
    sus = Image.open(SUSPECT)
    q = sus.quantization
    print("peak prominence over the local floor; 3520->4032 predicts 0.1270 c/s,")
    print("JPEG's block grid sits at 0.1250\n")

    real = measure("REAL      4032x3024 as captured", sus)

    small = sus.convert("RGB").resize((3520, 2640), Image.LANCZOS)
    buf = io.BytesIO()
    small.resize((4032, 3024), Image.LANCZOS).save(buf, "JPEG", qtables=q, subsampling=2)
    buf.seek(0)
    synth = measure("SYNTHETIC 4032->3520->4032 Lanczos", Image.open(buf),
                    "<- known upscale")

    buf2 = io.BytesIO()
    sus.convert("RGB").resize((3520, 2640), Image.BICUBIC) \
       .resize((4032, 3024), Image.BICUBIC).save(buf2, "JPEG", qtables=q, subsampling=2)
    buf2.seek(0)
    synth2 = measure("SYNTHETIC 4032->3520->4032 bicubic", Image.open(buf2),
                     "<- known upscale")

    measure("CONTROL   3840x2160 capture", Image.open(CONTROL))

    print()
    best = max(synth, synth2)
    print("=== is the instrument switched on? ===")
    if best - real > 3:
        print("  YES. A known upscale reads %+.1f dB where the real capture" % best)
        print("  reads %+.1f dB, a %.1f dB separation. The real capture does not" % (real, best - real))
        print("  carry the signature: it is NATIVE 4032x3024, and the registry")
        print("  value was preview overwriting the still's.")
    elif real - best > 3:
        print("  YES, and it points the other way: the real capture reads")
        print("  %+.1f dB against %+.1f dB for a known upscale." % (real, best))
        print("  The capture IS resampled.")
    else:
        print("  NO. Known upscale %+.1f dB vs real %+.1f dB -- only %.1f dB apart."
              % (best, real, abs(best - real)))
        print("  The JPEG block grid at 0.1250 sits on top of the resampling")
        print("  peak at 0.1270. This test cannot separate them either, and")
        print("  must not be cited in either direction.")
