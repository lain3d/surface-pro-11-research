#!/bin/bash
# Build the bulk half of the handoff: full git history for every repo, plus the
# Ghidra project.
#
# Kept separate from sp11-handoff-*.tar.gz on purpose -- that one is ~840 KB of
# documents and tools you want to read immediately. This one is ~1 GB you only
# need if you are going to build a kernel or open the reverse-engineering
# database.
#
# Usage:  bash tools/make-repos-tar.sh [output.tar]
set -euo pipefail

STAGE=${STAGE:-/mnt/c/Users/Crazy/AppData/Local/Temp/claude/C--Users-Crazy-projs-arm64-egpu/b880cc65-8196-4cec-b3fe-5e6f6a4ce1cb/scratchpad/repos-stage}
KERNEL=${KERNEL:-/root/sp11/linux-sp11}
GHIDRA=${GHIDRA:-/mnt/c/Tools/ghidra-proj}
OUT=${1:-/mnt/c/Users/Crazy/Documents/sp11-repos-$(date +%Y%m%d).tar}

ROOT="$STAGE"
mkdir -p "$ROOT/bundles" "$ROOT/ghidra"

echo "=== kernel repo bundle ==="
# NOT --all. The kernel repo is SHALLOW -- .git/shallow pins the boundary at
# bd336e2e, the tip of crlftest/pristine and the root of
# jg/ubuntu-qcom-x1e-7.1.y. A bundle has no way to express "history stops here",
# so --all writes those refs happily and the resulting bundle cannot be cloned:
#
#     error: Could not read e024a7a9...
#     fatal: Failed to traverse parents of commit bd336e2e
#
# and `git bundle verify` will not tell you, because it needs a repository to
# verify against. Only an actual clone finds it.
#
# Every branch on the sp11 line shares root 31339fbd9 (the squashed import) and
# is complete, so bundle those by name. The dropped ref is only an upstream
# marker; its SHA (d81a425b872a, jglathe/linux_ms_dev_kit) is recorded in the
# README and in the repo's own docs.
KREFS="sp11 camera/imx681 camera/ov13858-dt camera/denali-pm8010
       usb4/platform-nhi debug/imx681-addr-scan
       integration/boot-test integration/iso2"
git -C "$KERNEL" bundle create "$ROOT/bundles/surface-pro-11-kernel.bundle" $KREFS 2>&1 | tail -2
echo "  size: $(du -h "$ROOT/bundles/surface-pro-11-kernel.bundle" | cut -f1)"
git -C "$KERNEL" show-ref | sed 's/^/    /' > "$ROOT/bundles/surface-pro-11-kernel.refs.txt"

echo "  verifying by cloning, which is the only check that catches a shallow bundle"
T=$(mktemp -d)
if git clone -q -b sp11 "$ROOT/bundles/surface-pro-11-kernel.bundle" "$T/k" 2>/dev/null; then
    echo "  clone OK: $(git -C "$T/k" branch -a | wc -l) refs, $(git -C "$T/k" rev-list --count origin/sp11) commits on sp11"
    rm -rf "$T"
else
    echo "  CLONE FAILED - the bundle is not usable"; rm -rf "$T"; exit 1
fi

echo
echo "=== ghidra project ==="
# Exclude lock files: a stale .lock makes Ghidra refuse to open the project with
# "project is in use", and the ones here were written by a server that is still
# running on the source machine. They are meaningless on the target.
if [ -d "$GHIDRA/SurfaceCam.rep" ]; then
    cp -a "$GHIDRA/SurfaceCam.gpr" "$ROOT/ghidra/" 2>/dev/null || true
    rsync -a --exclude '*.lock' --exclude '*.lock~' \
        "$GHIDRA/SurfaceCam.rep" "$ROOT/ghidra/" 2>/dev/null \
      || cp -a "$GHIDRA/SurfaceCam.rep" "$ROOT/ghidra/"
    find "$ROOT/ghidra" -name '*.lock' -o -name '*.lock~' | xargs -r rm -f
    echo "  SurfaceCam: $(du -sh "$ROOT/ghidra/SurfaceCam.rep" | cut -f1)"
else
    echo "  WARNING: $GHIDRA/SurfaceCam.rep not found"
fi

cat > "$ROOT/README.md" <<'TXT'
# sp11 repos + Ghidra project

The bulk half of the handoff. The other tarball (`sp11-handoff-*.tar.gz`, ~840 KB)
has the documents, memories, tools and patch series — read that one first.

## Git bundles

A bundle is a whole repository in one file, with complete history. Clone from it:

```bash
git clone         bundles/surface-arm-platform-research.bundle research
git clone         bundles/surface-pro-11-linux.bundle           distro
git clone -b sp11 bundles/surface-pro-11-kernel.bundle          kernel
```

The kernel one needs `-b sp11` because its bundle carries no HEAD — see the note
at the bottom about why.

Every branch comes with it — `git branch -a` after cloning. To point a clone back
at GitHub afterwards:

```bash
git remote set-url origin git@github.com:lain3d/<repo>.git
```

| Bundle | What it is |
|---|---|
| `surface-arm-platform-research` | research, findings, probes, design docs. Branches include `research/camera-dt` and `handoff/new-system`. |
| `surface-pro-11-linux` | distro layer and ISO build tooling; fork of `denisix/ubuntu-surface-pro-11`. |
| `surface-pro-11-kernel` | the kernel, as commits. Branches: `sp11`, `camera/*`, `usb4/platform-nhi`, `debug/imx681-addr-scan`, `integration/*`. |

The kernel repo's root commit is a squashed import recording upstream SHA
`d81a425b872a` from `jglathe/linux_ms_dev_kit`, branch `jg/ubuntu-qcom-x1e-7.1.y`.
The trees are identical, so a real fork can be grafted later with
`git rebase --onto` — pure re-parenting, no content change.

`surface-pro-11-kernel.refs.txt` lists every ref and its SHA in the source repo
at bundle time, including the ones not carried here.

### Why the kernel bundle is not `--all`

The source repo is **shallow** — `.git/shallow` pins the boundary at `bd336e2e`,
which is the tip of `crlftest`/`pristine` and the root of
`jg/ubuntu-qcom-x1e-7.1.y`. A git bundle cannot express "history stops here", so
`git bundle create --all` writes those refs and produces a bundle that **cannot
be cloned**:

```
error: Could not read e024a7a9...
fatal: Failed to traverse parents of commit bd336e2e
fatal: remote did not send all necessary objects
```

Worse, `git bundle verify` does not catch it — it needs a repository to verify
against and reports nothing useful standalone. Only an actual clone finds it.

So this bundle carries the eight branches on the sp11 line, all of which share
root `31339fbd9` and are complete. `jg/ubuntu-qcom-x1e-7.1.y` is omitted; it was
only an upstream marker and its SHA is recorded above. Nothing of the actual work
is missing — `git clone -b sp11` then `git branch -a` shows all of it.

## Ghidra

`ghidra/SurfaceCam.gpr` + `SurfaceCam.rep/` — the reverse-engineering database
behind most of the Windows-side findings: `QcUsb4Bus8380.sys`,
`Usb4HostRouter.sys`, `TouchPenProcessor.dll`, the CamX DLLs, the camera sensor
drivers. Functions, types and comments from the analysis are saved in it.

Copy both into your Ghidra projects directory and open the `.gpr`.

**Lock files were deliberately removed.** A stale `.lock` makes Ghidra refuse the
project with "project is in use". The ones on the source machine were written by
a headless server that was still running; they mean nothing here. If you ever see
that error, delete `*.lock` and `*.lock~` next to the `.gpr`.

The snapshot was taken with that server running but **no programs open**, so
nothing was mid-write.

Working notes for headless/MCP use are in the research repo's `README.md` —
including that these are per-binary servers and that `analyzeHeadless` throttles
itself to a 2 GB heap by default, which looks like a hang on a large binary.
TXT

echo
echo "=== pack (bundles and Ghidra are already compressed; plain tar) ==="
mkdir -p "$(dirname "$OUT")"
tar -cf "$OUT" -C "$(dirname "$ROOT")" "$(basename "$ROOT")" \
    --transform "s|^$(basename "$ROOT")|sp11-repos|"
ls -la "$OUT"
echo
echo "contents:"
tar -tf "$OUT" | sed 's|^sp11-repos/||' | awk -F/ 'NF<=2 && $0!=""' | sort -u | head -20
