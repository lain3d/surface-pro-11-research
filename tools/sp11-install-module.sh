#!/bin/bash
#
# Install a built kernel module onto the Surface Pro 11's Linux root on the T7.
#
# Run from WSL, with the T7 handed over first:
#     powershell tools/sp11-disk.ps1 to-wsl
#     wsl -d Ubuntu-22.04 -u root bash tools/sp11-install-module.sh <built.ko> [...]
#     powershell tools/sp11-disk.ps1 to-win
#
# Why this exists rather than a one-liner per module: an ad-hoc installer got
# the target wrong in exactly the way this script now refuses to. It globbed
# `qcom-camss.ko*`, matched a pre-existing `qcom-camss.ko.zst.orig` backup
# before the real module, derived the compression from that filename's `.orig`
# extension, took the plain-copy branch instead of the zstd one, and wrote an
# uncompressed 13.9 MB module over the backup -- without ever installing
# anything. Nothing was lost only because the backup step had already run.
#
# So: the search excludes backups, the compression comes from the live file's
# real name, the vermagic is checked before any write, the backup is created
# once and never overwritten, and what landed is decompressed and compared
# against the source.
set -u

KV="${KV:-7.1.3-sp11-stockcfg-gf2cc827b6b89}"
MNT="${MNT:-/mnt/sp11root}"
ROOT_MIN_BYTES=500000000000

die() { echo "error: $*" >&2; cleanup; exit 1; }

MOUNTED=0
cleanup() {
    cd /
    if [ "$MOUNTED" = 1 ]; then
        sync
        umount "$MNT" 2>/dev/null && echo "unmounted cleanly" \
            || echo "WARNING: $MNT still mounted"
    fi
}
trap cleanup EXIT

[ "$#" -ge 1 ] || die "usage: $0 <built-module.ko> [more.ko ...]"
for m in "$@"; do [ -f "$m" ] || die "no such file: $m"; done

# ---- find the root ----
#
# "large ext4" alone is not enough: WSL's own system distro is a 1 TB sparse
# ext4 volume on /dev/sdd, mounted at /mnt/wslg/distro, and it matched. Anything
# already mounted is by definition not the disk we just attached, so skip it --
# and then confirm the survivor actually carries the module tree rather than
# trusting the size test.
ROOT=""
for d in /dev/sd*; do
    [ -b "$d" ] || continue
    t=$(blkid -o value -s TYPE "$d" 2>/dev/null) || true
    s=$(lsblk -bdno SIZE "$d" 2>/dev/null) || true
    [ "$t" = ext4 ] && [ "${s:-0}" -gt "$ROOT_MIN_BYTES" ] || continue
    if findmnt -rn -S "$d" >/dev/null 2>&1; then
        echo "skipping $d: already mounted at $(findmnt -rn -o TARGET -S "$d" | tr '\n' ' ')"
        continue
    fi
    [ -n "$ROOT" ] && die "more than one candidate root ($ROOT and $d)"
    ROOT="$d"
done
[ -n "$ROOT" ] || { lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT; die "no unmounted large ext4 root found"; }
echo "root: $ROOT"

mkdir -p "$MNT"
if mountpoint -q "$MNT"; then
    echo "note: $MNT already mounted, leaving it to whoever mounted it"
else
    mount "$ROOT" "$MNT" || die "mount failed"
    MOUNTED=1
fi

MODDIR="$MNT/lib/modules/$KV"
[ -d "$MODDIR" ] || die "no module tree at $MODDIR -- wrong volume?"
echo "module tree: $MODDIR"

rc=0
for SRC in "$@"; do
    base=$(basename "$SRC" .ko)
    echo
    echo "=== $base ==="

    # Live module only: never a .orig, never a stray backup. Match the module
    # name exactly, with an optional single compression suffix.
    mapfile -t found < <(find "$MODDIR" -type f \
        \( -name "$base.ko" -o -name "$base.ko.zst" -o -name "$base.ko.xz" \
           -o -name "$base.ko.gz" \) | sort)
    if [ "${#found[@]}" -eq 0 ]; then
        echo "  not installed on the target, skipping"; rc=1; continue
    elif [ "${#found[@]}" -gt 1 ]; then
        printf '  %s\n' "${found[@]}"; echo "  ambiguous, skipping"; rc=1; continue
    fi
    TGT="${found[0]}"
    echo "  target: $TGT"

    case "$TGT" in
        *.ko.zst) COMP=zst ;;
        *.ko.xz)  COMP=xz  ;;
        *.ko.gz)  COMP=gz  ;;
        *.ko)     COMP=none ;;
        *) echo "  unrecognised target name, skipping"; rc=1; continue ;;
    esac
    echo "  compression: $COMP"

    # ---- vermagic, before touching anything ----
    want=$(modinfo "$SRC" 2>/dev/null | awk '/^vermagic/{print $2}')
    if [ "$want" != "$KV" ]; then
        echo "  vermagic '$want' != '$KV' -- refusing"; rc=1; continue
    fi
    echo "  vermagic: $want"

    # ---- backup, created once ----
    if [ -f "$TGT.orig" ]; then
        echo "  .orig present, $(stat -c%s "$TGT.orig") bytes -- left alone"
    else
        cp -f "$TGT" "$TGT.orig" || { echo "  backup failed"; rc=1; continue; }
        echo "  .orig created, $(stat -c%s "$TGT.orig") bytes"
    fi

    # ---- install ----
    case "$COMP" in
        zst)  zstd -q -f -19 "$SRC" -o "$TGT" ;;
        xz)   xz  -T0 -c "$SRC" > "$TGT" ;;
        gz)   gzip -9 -c "$SRC" > "$TGT" ;;
        none) cp -f "$SRC" "$TGT" ;;
    esac || { echo "  install failed"; rc=1; continue; }

    # ---- verify what landed, by reading it back ----
    tmp=$(mktemp /tmp/sp11-verify-XXXXXX.ko)
    case "$COMP" in
        zst)  zstd -dc "$TGT" > "$tmp" ;;
        xz)   xz -dc   "$TGT" > "$tmp" ;;
        gz)   gzip -dc "$TGT" > "$tmp" ;;
        none) cp "$TGT" "$tmp" ;;
    esac
    if cmp -s "$tmp" "$SRC"; then
        echo "  installed, byte-identical to the build"
    else
        echo "  INSTALLED CONTENT DIFFERS FROM THE BUILD"; rc=1
    fi
    modinfo "$tmp" | grep -E '^(vermagic|srcversion)' | sed 's/^/    /'
    modinfo "$tmp" | grep '^parm' | sed 's/^/    /' || true
    rm -f "$tmp"
done

echo
echo "=== depmod ==="
depmod -b "$MNT" "$KV" && echo "  ok" || { echo "  depmod failed"; rc=1; }

exit "$rc"
