#!/bin/bash
# Shared runtime-PM gate and MMIO helpers for the SP11 camss probes.
#
# Source this; do not execute it:
#     . "$(dirname "$0")/sp11-camss-gate.sh"
#
# WHY THIS FILE EXISTS
# CSID and CSIPHY are clock-gated. Any access while the sensor is suspended
# raises a NoC error that resets the SoC below the kernel -- no panic, no
# pstore record, all mounted FAT/exFAT volumes dirty on the way back up.
# Three resets during bring-up were all the same mistake: skipping the gate
# because the access "did not count" (a timing test, a throwaway read, a
# batched check). It always counts.
#
# The gate is a sysfs read via the bash `read` builtin -- no fork, so there is
# no performance argument for skipping it. That was the excuse the third time.

CSID_BASE=${CSID_BASE:-0x0acb7000}
PHY_BASE=${PHY_BASE:-0x0ace8000}

# Locate the sensor's runtime-PM status file. i2c adapter numbers are not
# stable across boots, so glob rather than hardcode i2c-1.
camss_find_sensor() {
    local d
    for d in /sys/bus/i2c/drivers/imx681/*-0010; do
        [[ -e $d ]] || continue
        CAMSS_ST="$(realpath "$d")/power/runtime_status"
        return 0
    done
    return 1
}

# True while the sensor is powered and the CSID/CSIPHY clocks are up.
camss_active() {
    local s
    read -r s < "$CAMSS_ST" 2>/dev/null || return 1
    [[ $s == active ]]
}

# Block until streaming starts. Returns 1 if it never does -- callers MUST
# check, and must not fall through to a read.
#
# This busy-spins rather than sleeping between polls. A SUCCESSFUL capture is
# short: the harness runs v4l2-ctl --stream-count=1, so it takes one frame and
# calls STREAMOFF, and the whole active window is well under a second. A 0.1s
# poll interval lost all but the last ~60 ms of it and produced four samples of
# a mode-1 run. The failing mode blocks for the full TIMEOUT, which is why the
# sleeping version looked adequate for fifteen missions -- it was only ever
# timed against a mode that never stops streaming.
#
# The spin is a sysfs read, not an MMIO access, so it is outside the gate's
# remit and cannot trip the NoC. It costs one core for as long as the caller
# waits; bound it with the deadline argument rather than by sleeping.
camss_wait_active() {
    local deadline=$(( SECONDS + ${1:-90} ))
    while (( SECONDS < deadline )); do camss_active && return 0; done
    return 1
}

# Gated 32-bit read.  camss_rd <absolute-addr>
camss_rd() {
    camss_active || return 1
    busybox devmem "$(printf '0x%08x' "$1")" 32 2>/dev/null
}

# Gated 32-bit write. camss_wr <absolute-addr> <value>
camss_wr() {
    camss_active || return 1
    busybox devmem "$(printf '0x%08x' "$1")" 32 "$2" 2>/dev/null
}

# Convenience wrappers taking an offset from each block's base.
csid_rd() { camss_rd $(( CSID_BASE + $1 )); }
csid_wr() { camss_wr $(( CSID_BASE + $1 )) "$2"; }
phy_rd()  { camss_rd $(( PHY_BASE  + $1 )); }

camss_require_root() {
    [[ $EUID -eq 0 ]] || { echo "# must run as root (/dev/mem)" >&2; exit 1; }
}
