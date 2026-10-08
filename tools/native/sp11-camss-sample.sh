#!/bin/bash
# Gated CSID/CSIPHY register sampler.
#
#   sudo ./sp11-camss-sample.sh [-n SAMPLES] [-r REGS] [-s SWEEP] [-w ADDR=VAL]
#
#   -n  samples in the main loop            (default 1200)
#   -r  comma-separated name:offset pairs sampled every iteration, CSID-relative
#       unless prefixed phy:                (default: the standard set below)
#   -s  comma-separated lo-hi ranges to sweep once, mid-stream, CSID-relative
#       e.g. -s 0x20c-0x23c,0x500-0x574
#   -w  gated write applied after streaming starts, repeatable
#       e.g. -w 0x0f0=0xFFFFFFFF   (open the RDIN mask)
#   -k  keep watching across suspend/resume instead of exiting on the first
#       suspend, until -n samples are taken or -T seconds elapse
#   -T  overall deadline in seconds for -k (default 120)
#
# USE -k FOR ANY RUN THAT MUST CATCH A SUCCESSFUL CAPTURE. The harness powers
# the sensor twice: once for the state dump, then again to stream. Without -k
# the sampler locks onto the dump, takes ~90 ms of pre-streaming zeros, and
# exits at the gap -- so a successful mode-1 capture reads as "pkts never moved"
# when in fact streaming had not started yet. The failing mode hid this because
# its dump and its stream are one continuous active window.
#
# Start this in the background, then start a capture. It waits for the sensor to
# go active, samples while it stays active, and stops the instant it does not.
#
# Roughly 55 Hz with the default 8 registers -- one busybox fork per read. If
# you need the fine structure of a sub-10 ms event, use sp11-camss-fast.py
# instead; do not "optimise" this by loosening the gate. See README.md.

set -u
. "$(dirname "$(realpath "$0")")/sp11-camss-gate.sh"
camss_require_root

N=1200
REGS='pkts:0x240,rdin:0x0ec,top:0x07c,rx:0x09c,bufd:0x08c,crc:0x248,ecc:0x244,t0:phy:0x358'
SWEEPS=''
WRITES=()
KEEP=0
DEADLINE=120

while getopts 'n:r:s:w:kT:h' o; do
    case $o in
        n) N=$OPTARG ;;
        r) REGS=$OPTARG ;;
        s) SWEEPS=$OPTARG ;;
        w) WRITES+=("$OPTARG") ;;
        k) KEEP=1 ;;
        T) DEADLINE=$OPTARG ;;
        h) sed -n '2,33p' "$0"; exit 0 ;;
        *) exit 2 ;;
    esac
done

camss_find_sensor || { echo "# no imx681 bound"; exit 1; }
camss_wait_active || { echo "# never went active -- no access issued"; exit 1; }

# ---- gated writes, after the clocks are up ----
for w in ${WRITES+"${WRITES[@]}"}; do
    a=${w%%=*}; v=${w##*=}
    camss_active || { echo "# gate lost before write"; exit 1; }
    csid_wr $((a)) "$v"
    echo "## wrote CSID+$a = $v, reads back $(csid_rd $((a)))"
done

# ---- one-shot sweeps, mid-stream so the values mean something ----
# Note the $(( )) on the bounds: POSIX [ compares decimal only, and a bare
# hex bound makes the loop skip silently. That bug cost a whole run.
if [[ -n $SWEEPS ]]; then
    echo "## sweep"
    IFS=, read -ra ranges <<< "$SWEEPS"
    for r in "${ranges[@]}"; do
        lo=$(( ${r%%-*} )); hi=$(( ${r##*-} ))
        for (( o=lo; o<=hi; o+=4 )); do
            camss_active || { echo "# gate lost in sweep"; exit 1; }
            printf 'sweep 0x%03x %s\n' "$o" "$(csid_rd "$o")"
        done
    done
fi

# ---- main loop ----
# Each pass over the outer loop is one active window. With -k a suspend ends
# the window but not the run, so the dump and the stream both get sampled and
# the "## window" markers keep them from being read as one series.
IFS=, read -ra fields <<< "$REGS"
end=$(( SECONDS + DEADLINE ))
n=0 w=0
while (( n < N )); do
    (( w++ )); echo "## window $w"
    while (( n < N )); do
        camss_active || break
        line="$EPOCHREALTIME"
        for f in "${fields[@]}"; do
            name=${f%%:*}; rest=${f#*:}
            if [[ $rest == phy:* ]]; then v=$(phy_rd $(( ${rest#phy:} )))
            else                          v=$(csid_rd $(( rest ))); fi
            line+=" $name=$v"
        done
        echo "$line"
        ((n++))
    done
    (( KEEP )) || { echo "# rpm left active -> stopping"; break; }
    (( SECONDS < end )) || { echo "# deadline reached"; break; }
    camss_wait_active $(( end - SECONDS )) || { echo "# no further window"; break; }
done
echo "## done"
