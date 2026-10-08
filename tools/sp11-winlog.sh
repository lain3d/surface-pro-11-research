#!/bin/bash
# sp11-winlog: stream the kernel log to the Windows ESP while the root disk lives.
#
# Installs to /usr/local/sbin/sp11-winlog on the Surface. See
# design/boot-diagnostics.md for why the three simpler approaches do not work.
#
# The root filesystem is a USB-C disk that goes offline mid-boot. Everything that
# could record why is on that disk. The internal NVMe is a different disk and
# survives, so that is where this writes.
#
# Three constraints make this work, each learned by getting it wrong first:
#
#   1. ONE long-lived `cat /dev/kmsg`, not a loop that re-execs dmesg. Once the
#      root filesystem stops serving reads, exec fails - so any loop that spawns
#      a process goes silent exactly when it matters. The first version's log
#      filled with "uptime= root_rw=" for precisely this reason.
#   2. Mount -o sync. Page-cache writes are lost if power goes before unmount,
#      and this machine gets power-cycled at the hang.
#   3. Heartbeat with shell builtins only. `read < /proc/uptime` is a redirect;
#      `$(cat ...)` is a process. `sleep` is a binary too - after the disk dies
#      the loop free-runs, so the t=+Ns labels become iteration counts rather
#      than seconds. Trust the uptime= field.
#
# SAFETY: this writes to the Windows boot disk. It targets the ESP by serial,
# refuses unless EFI/Microsoft is present, only ever creates /sp11-diag, and
# never touches EFI/Microsoft, EFI/Boot, Capsules or System Volume Information.
UUID=D297-77C3          # internal NVMe ESP. The T7's is 5011-AB20 - not this one.
MNT=/run/sp11winesp
OUT=$MNT/sp11-diag
WINDOW=90

log() { echo "sp11-winlog: $*" > /dev/kmsg 2>/dev/null || true; }

dev=$(blkid -U "$UUID" 2>/dev/null)
if [ -z "$dev" ]; then log "ESP $UUID not found"; exit 0; fi

mkdir -p "$MNT" 2>/dev/null
mount -t vfat -o rw,sync,umask=0077 "$dev" "$MNT" 2>/dev/null || { log "mount failed"; exit 0; }

if [ ! -d "$MNT/EFI/Microsoft" ]; then
    log "no EFI/Microsoft - wrong volume, refusing"
    umount "$MNT" 2>/dev/null
    exit 0
fi
mkdir -p "$OUT" 2>/dev/null

# live.log appends across boots, so mark where this one begins. Spawning `date`
# here is fine - constraint 3 is about the loop, which runs after the disk may
# have died; at this point the root filesystem is still serving.
printf '=== sp11-winlog started %s ===\n' "$(date -Is 2>/dev/null || echo unknown)" \
    >> "$OUT/live.log" 2>/dev/null

# One long-lived reader for the whole kernel log, including everything after the
# root disk dies. /dev/kmsg replays the existing buffer and then follows.
cat /dev/kmsg > "$OUT/kmsg.txt" 2>/dev/null &
catpid=$!
log "streaming /dev/kmsg for ${WINDOW}s to $dev"

i=0
while [ "$i" -lt "$WINDOW" ]; do
    up=; rootline=
    read -r up _ < /proc/uptime 2>/dev/null || up=unreadable
    while read -r _ mp _ opts _; do
        if [ "$mp" = "/" ]; then rootline=$opts; break; fi
    done < /proc/mounts 2>/dev/null
    printf 't=+%ss uptime=%s root=%s kmsg_alive=%s\n' \
        "$i" "${up:-?}" "${rootline:-?}" \
        "$(if kill -0 "$catpid" 2>/dev/null; then echo yes; else echo NO; fi)" \
        >> "$OUT/live.log" 2>/dev/null
    sleep 1
    i=$((i + 1))
done

kill "$catpid" 2>/dev/null
printf '=== sp11-winlog finished ===\n' >> "$OUT/live.log" 2>/dev/null
umount "$MNT" 2>/dev/null
log "done"
