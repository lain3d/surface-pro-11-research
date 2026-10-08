#!/bin/bash
# Does a FRESH enumeration after a charger_pd restart find the disk?
#
#   sudo /usr/local/sbin/sp11-portwatch-unbindfirst
#
# WHY THIS EXISTS
#
# Three runs established that a disk which has been dropped stays dropped: no
# rebind of xhci-hcd or dwc3-qcom recovers it. But every one of those runs
# restarted the ADSP while the disk was enumerated and in use. The remaining
# hope is sequencing - restart the ADSP when nothing is attached, so the port
# does a FIRST attach afterwards rather than a re-attach. First attach works on
# every cold boot.
#
# Doing that at boot needs the ADSP driver built in, the firmware embedded, and
# some way to order it ahead of USB - which the device tree cannot express, so
# it would need a custom binding plus a dwc3-qcom change that can brick the boot
# if it goes wrong. That is an hour of work resting on an untested assumption.
#
# This tests the assumption directly, from userspace, with no rebuild:
#
#   1. unbind dwc3/xhci      - the disk goes away, but WE did it, cleanly
#   2. restart the ADSP      - charger_pd bounces with nothing enumerated
#   3. rebind dwc3/xhci      - fresh probe, first enumeration
#
# If the disk comes back at step 3, sequencing works and the kernel work is
# worth doing. If it does not, no ordering scheme can help and we stop.
#
# Same survival rules as sp11-portwatch: everything after step 1 is builtins
# and sysfs writes, the log goes to the internal NVMe, and expect to
# power-cycle.
#
# WHY THIS RE-EXECS ITSELF FIRST
#
# The first attempt died immediately after the unbind, before it ever restarted
# the ADSP. Builtins-only is necessary but NOT sufficient: bash's own text pages
# are demand-paged from the root filesystem, so the moment one of them is
# evicted and faulted back in after the disk is gone, the shell dies mid-script.
# Nothing it does matters if it is not running.
#
# So stage the interpreter and its libraries into tmpfs and re-exec from there.
# After that bash is backed by RAM and can outlive the disk.
set -u

STAGE=/run/sp11rt
if [ "${SP11_RESIDENT:-}" != yes ]; then
    mkdir -p "$STAGE" || exit 1
    # the loader, bash, and everything bash links against
    cp -f /bin/bash "$STAGE/bash" || exit 1
    for lib in $(ldd /bin/bash | sed -n 's/.*=> \(\/[^ ]*\).*/\1/p'; ldd /bin/bash | sed -n 's/^\s*\(\/lib\/ld-[^ ]*\).*/\1/p'); do
        cp -f "$lib" "$STAGE/" 2>/dev/null
    done
    LD=$(ls "$STAGE"/ld-linux-*.so.* 2>/dev/null | head -1)
    [ -x "$LD" ] || { echo "could not stage the dynamic loader"; exit 1; }
    cp -f "$0" "$STAGE/run.sh" || exit 1
    echo "[unbindfirst] re-execing from tmpfs so the shell survives the disk"
    export SP11_RESIDENT=yes
    exec "$LD" --library-path "$STAGE" "$STAGE/bash" "$STAGE/run.sh" "$@"
fi

ESP_UUID=D297-77C3
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd
MNT=/run/sp11winesp
OUT=$MNT/sp11-diag
FWSTAGE=/run/sp11fw
BINSTAGE=/run/sp11bin
FWSUB=qcom/x1e80100/microsoft/Denali

say() { echo "[unbindfirst] $*"; echo "[unbindfirst] $*" > /dev/kmsg 2>/dev/null || true; }

[ "$(id -u)" = 0 ] || { echo "must be root"; exit 1; }

# ---- stage firmware into tmpfs, same as sp11-portwatch ---------------------
mkdir -p "$FWSTAGE/$FWSUB"
src=/lib/firmware/$FWSUB
got=no
for f in qcadsp8380.mbn qcadsp8380.mbn.disabled; do
    [ -f "$src/$f" ] && cp "$src/$f" "$FWSTAGE/$FWSUB/qcadsp8380.mbn" && got=yes && break
done
[ "$got" = yes ] || { say "no ADSP firmware; aborting"; exit 1; }
echo -n "$FWSTAGE" > /sys/module/firmware_class/parameters/path || exit 1
say "firmware staged in tmpfs"

# ---- fifo nap: no exec once the disk is gone -------------------------------
mkdir -p "$BINSTAGE"
FIFO=$BINSTAGE/nap
[ -p "$FIFO" ] || mkfifo "$FIFO" || exit 1
exec 9<> "$FIFO" || exit 1
nap() { read -t "$1" -u 9 _ 2>/dev/null || true; }

# ---- the Windows ESP ------------------------------------------------------
dev=$(blkid -U "$ESP_UUID") || { say "no ESP"; exit 1; }
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -t vfat -o rw,sync,umask=0077 "$dev" "$MNT" || exit 1
[ -d "$MNT/EFI/Microsoft" ] || { say "wrong volume"; umount "$MNT"; exit 1; }
mkdir -p "$OUT"
LOG=$OUT/unbindfirst.log
: > "$LOG"
printf '=== unbindfirst %s ===\n' "$(date -Is)" >> "$LOG"

cat /dev/kmsg > "$OUT/unbindfirst-kmsg.txt" 2>/dev/null &
catpid=$!
nap 1

ROOTDEV=/dev/disk/by-uuid/$ROOT_UUID

# ---- work out which devices to unbind, BEFORE the disk goes ---------------
XHCI=/sys/bus/platform/drivers/xhci-hcd
DWC3=/sys/bus/platform/drivers/dwc3-qcom
xdevs=""; ddevs=""
for d in "$XHCI"/*.auto; do [ -e "$d" ] && xdevs="$xdevs ${d##*/}"; done
for d in "$DWC3"/*.usb;  do [ -e "$d" ] && ddevs="$ddevs ${d##*/}"; done
say "xhci:$xdevs  dwc3:$ddevs"
printf 'xhci:%s dwc3:%s\n' "$xdevs" "$ddevs" >> "$LOG"

adsp=
for r in /sys/class/remoteproc/remoteproc*; do
    [ -e "$r/name" ] || continue
    read -r nm < "$r/name"
    [ "$nm" = adsp ] && { adsp=$r; break; }
done
[ -n "$adsp" ] || { say "no adsp"; kill $catpid; exit 1; }
read -r st0 < "$adsp/state"
printf 'adsp %s state before: %s\n' "$adsp" "$st0" >> "$LOG"

say "the desktop will wedge from here. Power-cycle afterwards and read"
say "W:\\sp11-diag\\unbindfirst.log"
nap 2

# ---- 1. take USB down ourselves -------------------------------------------
printf '\n-- 1. unbinding USB (disk goes away by our own hand) --\n' >> "$LOG"
for n in $xdevs; do echo "$n" > "$XHCI/unbind" 2>/dev/null; printf 'unbind xhci %s\n' "$n" >> "$LOG"; done
for n in $ddevs; do echo "$n" > "$DWC3/unbind" 2>/dev/null; printf 'unbind dwc3 %s\n' "$n" >> "$LOG"; done
nap 3
# no command substitution past this point - $( ) forks, and there is no reason
# to spend the risk on a yes/no string
if [ -e "$ROOTDEV" ]; then p=yes; else p=no; fi
printf 'rootdev after unbind: %s\n' "$p" >> "$LOG"

# ---- 2. restart the ADSP with nothing enumerated --------------------------
printf '\n-- 2. restarting the ADSP with the bus down --\n' >> "$LOG"
if [ "$st0" != offline ]; then echo stop > "$adsp/state" 2>/dev/null; nap 2; fi
echo start > "$adsp/state" 2>/dev/null
i=0
while [ "$i" -lt 25 ]; do
    read -r st < "$adsp/state" 2>/dev/null || st='?'
    printf '  adsp t+%ss state=%s\n' "$i" "$st" >> "$LOG"
    [ "$st" = running ] && break
    nap 1; i=$((i + 1))
done

# ---- 3. bring USB back: a FIRST enumeration -------------------------------
printf '\n-- 3. rebinding USB - this is the fresh probe --\n' >> "$LOG"
for n in $ddevs; do echo "$n" > "$DWC3/bind" 2>/dev/null; printf 'bind dwc3 %s\n' "$n" >> "$LOG"; done
nap 3
for n in $xdevs; do echo "$n" > "$XHCI/bind" 2>/dev/null; printf 'bind xhci %s\n' "$n" >> "$LOG"; done

back=
j=0
while [ "$j" -lt 40 ]; do
    if [ -e "$ROOTDEV" ]; then back=yes; p=yes; else p=no; fi
    printf '  after rebind t+%ss rootdev=%s\n' "$j" "$p" >> "$LOG"
    [ -n "$back" ] && break
    nap 1; j=$((j + 1))
done

{
    printf '\n'
    if [ -n "$back" ]; then
        printf 'RESULT: THE DISK CAME BACK on a fresh enumeration.\n'
        printf '  Sequencing works. Booting the ADSP before USB probes is worth\n'
        printf '  building: QCOM_Q6V5_PAS=y, firmware embedded, and an ordering\n'
        printf '  mechanism ahead of dwc3.\n'
    else
        printf 'RESULT: the disk did NOT come back even on a fresh probe.\n'
        printf '  The port will not present the device after a charger_pd restart\n'
        printf '  regardless of ordering. No initcall or device-tree scheme can\n'
        printf '  help. Audio needs root off the Type-C port.\n'
    fi
    printf '=== unbindfirst finished ===\n'
} >> "$LOG"

kill "$catpid" 2>/dev/null
umount "$MNT" 2>/dev/null
