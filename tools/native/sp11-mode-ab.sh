#!/bin/bash
# Alternating A/B capture between two sensor modes.
#
#   sudo ./sp11-mode-ab.sh [-a 3520x2640] [-b 4032x3024] [-r ROUNDS] [-t SECS]
#
# Alternates so a difference cannot be blamed on drift, warm-up or ordering.
# This is what established that 3520x2640 captures a full frame every time and
# 4032x3024 never does -- A/B/A/B, four runs, unambiguous.
#
# Reports per run: output size, whether v4l2-ctl timed out, and the csid0 /
# csiphy / vfe0 interrupt deltas.
#
# On reading the interrupt columns:
#   csid0 +1  = the reset interrupt only; nothing streamed through
#   csid0 +4  = a frame completed
#   vfe0      = ALWAYS 0 on this hardware, working or not. buf_done is raised by
#               CSID_BUF_DONE_IRQ_STATUS in the CSID ISR, not the VFE IRQ line.
#               Do not use it as a success metric.

set -u
A=3520x2640
B=4032x3024
ROUNDS=2
SECS=15
TEST=${TEST:-/mnt/t7/surface/tools/sp11-camera-test.sh}
OUT=/tmp/imx681-frame.raw

while getopts 'a:b:r:t:h' o; do
    case $o in
        a) A=$OPTARG ;; b) B=$OPTARG ;; r) ROUNDS=$OPTARG ;; t) SECS=$OPTARG ;;
        h) sed -n '2,22p' "$0"; exit 0 ;; *) exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "# must run as root"; exit 1; }
[[ -x $TEST ]] || { echo "# capture script not found at $TEST (set TEST=)"; exit 1; }

snap() { grep -iE 'csid0|vfe0|ace8000\.csiphy' /proc/interrupts; }

delta() {  # delta <before-file> <after-file>
    python3 - "$1" "$2" <<'EOF'
import sys
def load(f):
    d={}
    for l in open(f):
        p=l.split()
        # trailing fields are "GICv3 <n> Edge <name>" -- exclude them or the
        # GIC number is silently added to every count
        if len(p)>2 and p[0].endswith(':'):
            d[p[-1]]=sum(int(x) for x in p[1:-4] if x.isdigit())
    return d
a,b=load(sys.argv[1]),load(sys.argv[2])
print(" ".join(f"{k.split('_')[-1]}+{b.get(k,0)-a.get(k,0)}" for k in sorted(a)))
EOF
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%-11s %-12s %-9s %s\n' mode bytes timeout interrupts

for (( r=0; r<ROUNDS; r++ )); do
    for M in "$A" "$B"; do
        rm -f "$OUT"
        snap > "$tmp/b"
        env TIMEOUT="$SECS" MODE="$M" "$TEST" --capture > "$tmp/log" 2>&1
        snap > "$tmp/a"
        sz=0; [[ -s $OUT ]] && sz=$(stat -c%s "$OUT")
        to=no; grep -q 'TIMED OUT' "$tmp/log" && to=yes
        printf '%-11s %-12s %-9s %s\n' "$M" "$sz" "$to" "$(delta "$tmp/b" "$tmp/a")"
    done
done
