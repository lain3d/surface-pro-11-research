# How I work in the kernel tree

The working method behind the commits in `lain3d/surface-pro-11-kernel`. Written
down so the choices are reviewable and so the traps do not have to be rediscovered.

MVP posture: correctness over conformance. Nothing here is yet shaped for
upstream submission, and that is deliberate — see the last section.

---

## The setup

```
/root/sp11/linux-sp11     kernel repo, main checkout
/root/sp11/wt-ov13858     git worktree, where feature branches are built
```

A **worktree** is a second directory with a different branch checked out from the
same repository. It matters here because a kernel build is slow and switching
branches invalidates object files; having a dedicated build directory keeps the
main checkout stable.

`publish` is the remote pointing at `lain3d/surface-pro-11-kernel`. Everything is
pushed there. Nothing is ever pushed to anyone else's repository.

All feature branches share one base commit. That base is byte-identical in
content to the commit the existing ISO's kernel was built from, which is what
makes the branches composable with what already exists.

---

## One logical change per branch

Each branch does one thing and gets its own draft PR:

| Branch | One thing |
|---|---|
| `camera/ov13858-dt` | make an existing driver DT-probeable |
| `camera/denali-pm8010` | describe the camera power rails |
| `usb4/platform-nhi` | let the USB4 host router bind without PCI |
| `camera/imx681` | a new sensor driver |
| `debug/imx681-addr-scan` | throwaway, recovers one unknown value |

Why bother when nothing is upstream yet: a branch that does one thing can be
*reviewed*, and more importantly can be *reverted or rebased independently* when
one of its assumptions turns out wrong. Several assumptions have turned out
wrong. The cost of the discipline has already been repaid.

Draft PRs are used as the write-up surface. Each PR accumulates comments
recording what was verified, what was found later, and what is still unknown, so
the reasoning sits next to the code rather than in a chat log.

---

## The evidence rule

**Every constant must trace to a source, and if it cannot, it does not get
written.**

This is the central rule, and it exists because of a specific failure. An early
version of the IMX681 driver contained:

```c
.vts_def = height + 100,
```

which looks like a considered value and was invented. No register table anywhere
writes that register. It survived review-by-reading because it *looked*
researched. It was caught only by going back and asking, for each constant,
"where did this come from?" — and finding no answer.

So the rule has a corollary: **a plausible-looking fabricated constant is the
most dangerous output of this kind of work**, because it is indistinguishable
from a real one by inspection. Two live consequences:

- The front camera's DT node is not written, because its I2C address is unknown.
  A "reasonable" address would look exactly like a researched one.
- The IMX681 driver's Bayer order is marked as a guess in the code, not quietly
  assumed, because no Windows file contains it.

The inverse also matters: a *proven negative* is a real result worth recording.
"The I2C address is not in the firmware" is now backed by three independent
checks against a sensor whose address is publicly known, and that saves the next
person the search.

---

## The verification ladder

Applied in this order, cheapest first. Each rung catches a different class of
error, and the higher rungs have each caught something real.

1. **It compiles.** Necessary, proves very little.
2. **`W=1`.** Extra warnings. Catches unused variables, suspicious casts.
3. **sparse (`make C=2`).** Catches address-space confusion — mixing `__iomem`
   pointers with normal ones. Run specifically because the USB4 work moves
   `void __iomem *` between structures. Came back clean.
4. **`dt_binding_check` / `dtbs_check`.** Validates bindings and the built DTBs
   against them. **Found two real defects**: a `compatible` with no binding at
   all, and a binding that failed to match all three of its own nodes.
5. **Build the consumers, not just the directory you touched.** The USB4 work
   changes `include/linux/thunderbolt.h`, a public header. Building only
   `drivers/thunderbolt/` was insufficient; the two other files in the tree that
   include it were built too.
6. **Reason about reachability by hand where the compiler cannot help.** Making
   `tb_nhi::pdev` NULL for the first time meant every dereference of it was a
   potential NULL crash that still compiles. All 34 were enumerated and checked.
   One pair (`switch.c`) was reachable from hotplug rather than probe — a smoke
   test would not have caught it.

### Verify the artifact, not the source

Reading your own diff and concluding it is correct is not verification; you are
checking the thing you just wrote against the intention you just had.

So: **decompile the DTB and look at what actually landed.**

```
dtc -I dtb -O dts x1e80100-microsoft-denali-oled.dtb | less
```

This is how "all three USB4 routers are enabled" and "the sensor node has
`CAM_CC_MCLK4_CLK`, 19.2 MHz, gpio237 active-low" were confirmed — as numbers in
the output blob (`0x4f`, `0x124f800`, `0xed`/`0x01`), not as text in the source.
It also surfaced that DT labels are not in address order, which the source did
not make obvious.

The same principle applies elsewhere: check the built object exists and its
timestamp moved, rather than trusting an exit code.

---

## Traps worth knowing

Each of these produced a wrong conclusion at least once.

**A pipeline's exit code is not the command's.**
```bash
make ... | grep -i warning
echo "exit $?"          # this is grep's status, not make's
```
This printed `exit 0` for a build that had failed. Capture `${PIPESTATUS[0]}`, or
better, delete the output file first and check it reappears.

**`.config` goes stale across branch switches.** A branch that introduces a new
`CONFIG_` symbol leaves the other branch's `.config` missing it. `syncconfig`
then prompts, fails on closed stdin — *and still exits 0*. The first `W=1` build
run this way was meaningless. Fix: after every checkout, `./scripts/config -m
<SYMBOL>`, `make olddefconfig </dev/null`, then **grep `.config` to confirm the
symbol is actually set** before believing any build.

**Structure offsets are a rich source of confident nonsense.** A PE parser read
data directories at the wrong optional-header offset and reported a coherent,
entirely fictional export table. When parsing a binary format, prefer a decode
you can test against known plaintext, and reuse a parse that has already been
validated rather than re-deriving offsets.

**A parser needs a limit it can fail against, not just a start.** A record walker
with no end bound ran into the data section and reported a field length of
1732277888. Bounds turn silent garbage into a visible error.

**WSL from Git Bash rewrites paths.** `/mnt/c/...` becomes
`C:/Program Files/Git/mnt/c/...`. Prefix with `MSYS_NO_PATHCONV=1`. Separately,
inline `bash -c '... $VAR ...'` silently eats variables — write script files.
This one previously caused a false claim in a public issue on someone else's
repo, which then needed retracting.

**Truncating a pipeline truncates the artifact.** `... | Tee-Object | Select
-First 70` wrote a partial capture file that looked complete and analysed as
"nothing found." Write full output to disk first, summarise second.

---

## Debug branches are quarantined

`debug/imx681-addr-scan` exists to recover the sensor's I2C address. It contains
a placeholder `reg` value and a bus scan inside `probe()`. It is:

- based on the feature branch it supports, not on the main line
- titled **"DEBUG (do not merge)"**
- explicit in its commit message and PR body that probe is *expected to fail*
  afterwards, so a failed probe does not get filed as a bug
- to be deleted once it has produced its number

The reason for the ceremony is the evidence rule. A placeholder constant in a
throwaway branch is a tool. The same constant in the PR series is a fabrication.
Keeping them physically separate is what stops the second thing happening by
accident.

---

## Commit messages

Written to answer *why*, since *what* is visible in the diff. In practice each
one records: the fact and where it came from, what was checked and how, and what
remains unknown. Where a previous conclusion is being overturned, the message
says so plainly — several commits here exist specifically to correct earlier
claims, and burying that would make the history misleading.

They are long by normal standards. That is a deliberate trade for work whose main
risk is unverifiable assertions.

---

## What "MVP" means here, and what changes later

Currently **not** being done, on purpose:

- `checkpatch.pl --strict` conformance, subject-line conventions, patch ordering
- splitting `nhi.c` into `pci.c` / `platform.c`, which review would want and which
  is a large mechanical change best done once the design is settled
- dropping `CONFIG_USB4`'s `depends on PCI`, which is upstream hygiene but cannot
  be *tested* here since this tree cannot produce a working `PCI=n` arm64 config
- mailing list submission of anything

What is not being deferred, because deferring it would poison the result:
correctness of every value, honest marking of what is unproven, and the
verification ladder above.

The transition to upstream-shaped work should happen after the first boot, for a
concrete reason: several patches encode assumptions that only hardware can
confirm, and submitting them before that would mean asking maintainers to review
guesses.
