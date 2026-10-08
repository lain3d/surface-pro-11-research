#!/usr/bin/env python3
"""
Does wrapping the mode programming in a grouped parameter hold make the
sensor emit?  The driver cannot be changed from this side, so replay the
vendor sequence over i2c onto a pipeline camss already has running.

Phase A is the control: same stop / rewrite / start with NO hold.  If A and B
behave the same, the hold is not the mechanism.
"""
import fcntl, os, sys, time, subprocess

I2C_SLAVE_FORCE = 0x0706
BUS, ADDR = 1, 0x10
fd = os.open(f"/dev/i2c-{BUS}", os.O_RDWR)
fcntl.ioctl(fd, I2C_SLAVE_FORCE, ADDR)

def wr(reg, val):
    os.write(fd, bytes([(reg >> 8) & 0xff, reg & 0xff, val & 0xff]))

def rd(reg):
    os.write(fd, bytes([(reg >> 8) & 0xff, reg & 0xff]))
    return os.read(fd, 1)[0]

REGS = []
for line in open(sys.argv[1]):
    if line.startswith('0x'):
        r, v = line.split()
        REGS.append((int(r, 16), int(v, 16)))

def vfe():
    for l in open('/proc/interrupts'):
        if 'msm_vfe0' in l:
            return sum(int(x) for x in l.split()[1:13])
    return -1

def csid():
    for l in open('/proc/interrupts'):
        if 'msm_csid0' in l:
            return sum(int(x) for x in l.split()[1:13])
    return -1

def replay(hold):
    wr(0x0100, 0x00)                      # stream off
    time.sleep(0.05)
    if hold:
        wr(0x0104, 0x01)
        print(f"    0x0104 after set = {rd(0x0104)}")
    t = time.time()
    for r, v in REGS:
        wr(r, v)
    print(f"    replayed {len(REGS)} writes in {time.time()-t:.2f}s")
    if hold:
        wr(0x0104, 0x00)
        print(f"    0x0104 after release = {rd(0x0104)}")
    wr(0x0100, 0x01)                      # stream on
    print(f"    0x0100 reads back = {rd(0x0100)}")

print("=== sanity: sensor answers and is streaming ===")
print(f"  0x0016 = 0x{rd(0x0016):02x}{rd(0x0017):02x}   (expect 0x0681)")
print(f"  0x0100 = {rd(0x0100)}   (1 = driver has it streaming)")
print(f"  vfe0={vfe()} csid0={csid()}")

for name, hold in (("A  CONTROL: stop, rewrite, start -- NO hold", False),
                   ("B  TEST:    stop, HOLD, rewrite, release, start", True)):
    print(f"\n=== {name} ===")
    v0, c0 = vfe(), csid()
    replay(hold)
    time.sleep(5)
    print(f"    vfe0  {v0} -> {vfe()}   (delta {vfe()-v0})")
    print(f"    csid0 {c0} -> {csid()}   (delta {csid()-c0})")

print(f"\nfinal: 0x0100={rd(0x0100)} 0x0104={rd(0x0104)} vfe0={vfe()} csid0={csid()}")
os.close(fd)
