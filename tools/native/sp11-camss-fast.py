#!/usr/bin/env python3
"""High-rate gated sampler for a single CSID counter, via mmap'd /dev/mem.

    sudo ./sp11-camss-fast.py [--offset 0x240] [--limit 400000] [--analyse]

~110 kHz, versus ~55 Hz for the fork-per-read shell sampler. That is the
difference between seeing a burst as three points and seeing it as several
hundred, which is what resolved the 382-packet burst: 382 packets, 1,671 us,
4.37 us apart, uniform.

The gate is checked before EVERY read. It is an open()+read() of sysfs, not a
fork, so the cost is irrelevant -- there is no performance case for batching it.
A previous version checked every 200 samples to save the fork that $(cat ...)
costs in shell, kept reading for ~200 ms after STREAMOFF suspended the sensor,
and reset the SoC. See README.md.

--analyse clusters the samples into bursts by a 50 ms inter-event gap and prints
size, duration and spacing. Note bursts cannot be found by "contiguous rising
samples": at 110 kHz there are plateaus *between* packets inside a burst, which
splits every burst into fragments.
"""
import argparse, mmap, os, struct, sys, time

CSID_BASE = 0x0acb7000
PAGE = 0x1000


def find_status():
    base = '/sys/bus/i2c/drivers/imx681'
    for d in os.listdir(base):
        if d.endswith('-0010'):
            return os.path.realpath(os.path.join(base, d)) + '/power/runtime_status'
    return None


def sample(offset, limit, keep=False, deadline=120):
    st = find_status()
    if not st:
        sys.exit('# no imx681 bound')

    def active():
        try:
            with open(st) as f:
                return f.read().strip() == 'active'
        except OSError:
            return False

    # Busy-spin rather than sleep-poll. A successful capture's active window is
    # ~100 ms (the harness takes one frame and calls STREAMOFF); a 0.1 s poll
    # lands after most of it. Sysfs reads are outside the gate's remit.
    def spin_until_active(deadline_s):
        end = time.time() + deadline_s
        while time.time() < end:
            if active():
                return True
        return False

    if not spin_until_active(90):
        sys.exit('# never went active -- nothing mapped, nothing read')

    # The harness powers the sensor twice -- once for the state dump, then again
    # to stream -- so exiting at the first suspend samples the dump and misses
    # the capture entirely. Keep watching until the sample budget or the overall
    # deadline runs out. Every read is still gated.
    fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
    mm = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, mmap.PROT_READ, offset=CSID_BASE)
    out = []
    end = time.time() + deadline
    try:
        while len(out) < limit and time.time() < end:
            while len(out) < limit and active():
                out.append((time.time(), struct.unpack_from('<I', mm, offset)[0]))
            if not keep or time.time() >= end:
                break
            out.append((time.time(), None))       # window boundary
            if not spin_until_active(end - time.time()):
                break
    finally:
        mm.close()
        os.close(fd)
    return out


def analyse(rows, gap=0.05):
    if len(rows) < 2:
        print('# too few samples')
        return
    t0 = rows[0][0]
    span = rows[-1][0] - t0
    print(f'samples {len(rows):,}  span {span:.2f}s  rate {len(rows)/span:,.0f} Hz')
    ev = [(rows[k][0] - t0, rows[k][1] - rows[k-1][1])
          for k in range(1, len(rows)) if rows[k][1] != rows[k-1][1]]
    if not ev:
        print('counter never moved')
        return
    clusters, cur = [], [ev[0]]
    for e in ev[1:]:
        if e[0] - cur[-1][0] > gap:
            clusters.append(cur)
            cur = [e]
        else:
            cur.append(e)
    clusters.append(cur)
    sizes = {}
    for c in clusters:
        n = sum(x[1] for x in c)
        sizes[n] = sizes.get(n, 0) + 1
    print(f'bursts {len(clusters)}   sizes {dict(sorted(sizes.items(), key=lambda x: -x[1])[:5])}')
    durs = sorted((c[-1][0] - c[0][0]) * 1e6 for c in clusters if len(c) > 1)
    if durs:
        med = durs[len(durs)//2]
        big = max(sizes, key=sizes.get)
        print(f'duration us: min {durs[0]:.0f} median {med:.0f} max {durs[-1]:.0f}')
        print(f'inter-packet {med/max(1,big):.2f} us for the modal {big}-packet burst')
    if len(clusters) > 2:
        per = [clusters[k][0][0] - clusters[k-1][0][0] for k in range(1, len(clusters))]
        per = [p for p in per if p > gap]
        if per:
            m = sum(per)/len(per)
            print(f'burst period {m:.4f}s -> {1/m:.3f} Hz   duty {med/1e6/m*100:.2f}%')
    print(f'total counted: {rows[-1][1] - rows[0][1]:,}')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--offset', type=lambda x: int(x, 0), default=0x240,
                    help='CSID-relative register offset (default TOTAL_PKTS_RCVD)')
    ap.add_argument('--limit', type=int, default=400000)
    ap.add_argument('--analyse', action='store_true', help='summarise instead of dumping')
    ap.add_argument('--keep', action='store_true',
                    help='sample across suspend/resume; needed to catch a successful capture')
    ap.add_argument('--deadline', type=float, default=120)
    ap.add_argument('--values', action='store_true',
                    help='report every distinct value and its sample count, per window')
    a = ap.parse_args()
    rows = sample(a.offset, a.limit, keep=a.keep, deadline=a.deadline)
    if a.values:
        # For a register that may never change -- e.g. 0x210 on a working
        # capture -- "which values did it ever hold" is the whole question.
        win, counts, order = 1, {}, []
        for t, v in rows + [(0, None)]:
            if v is None:
                if counts:
                    n = sum(counts.values())
                    print(f'window {win}: {n:,} samples')
                    for k in order:
                        print(f'  0x{k:08X}  {counts[k]:,} ({counts[k]/n*100:.1f}%)')
                win, counts, order = win + 1, {}, []
                continue
            if v not in counts:
                order.append(v)
            counts[v] = counts.get(v, 0) + 1
    elif a.analyse:
        analyse([r for r in rows if r[1] is not None])
    else:
        for t, v in rows:
            print(f'{t:.6f} {"--window--" if v is None else v}')
