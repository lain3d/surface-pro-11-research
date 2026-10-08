# The offline verification loop

Reboots are the scarce resource on this project. Each one needs someone
physically present, takes minutes, and answers one question. Meanwhile most of
the device-tree bugs that have cost us reboots were **fully determined before
the machine was ever powered on** — the value was wrong against a constraint
that was sitting in a driver source file the whole time.

This is the loop that catches those first.

```
edit -> build -> dt-audit + initrd-audit -> fix -> repeat until 0 BUG -> only then boot
```

There are two axes, because the bugs moved once the first was clean.

**`tools/dt-audit.py`** checks the device tree against the drivers that consume
it:

```sh
python3 tools/dt-audit.py \
    --tree /root/sp11/wt-ov13858 \
    --board x1e80100-microsoft-denali-oled \
    --quiet-hints
```

**`tools/initrd-audit.py`** checks the boot payload against the kernel that
will run it:

```sh
python3 tools/initrd-audit.py \
    --initrd /mnt/c/sp11-stage/initrd-sp11log.img \
    --config /root/sp11/wt-ov13858/.config
python3 tools/initrd-audit.py --self-test     # calibration, see below
```

Both exit non-zero when anything is classed BUG, so they drop into a build
script unchanged.

**The DT axis has converged.** It reports 0 BUG on `integration/iso2`, so
re-running it finds nothing; progress there now requires new checks, not new
runs. The initramfs axis has not converged and is where the open findings are.

---

## Severity means something

| | meaning |
|---|---|
| **BUG** | the tree contradicts a constraint read out of the driver. Do not boot this. |
| **SUSPECT** | mechanically wrong-looking, but legal in some designs. Read it. |
| **HINT** | a lead. Most boards do X and we do not. Often correct to ignore. |

The split matters because a checker that cries BUG at upstream code gets
switched off. On the first run this one reported 88 BUGs on a tree that boots;
all 88 were mine.

---

## The checks, and the bug each one generalises

Every check exists because something real cost us a boot cycle.

**REG-GRID** — a regulator whose `[min, max]` window contains no voltage the
PMIC can actually produce.

`vreg_l16b_2p9` was written as `2900000` because the Windows blob said 2.9 V.
`pmic5_pldo` is `REGULATOR_LINEAR_RANGE(1504000, 0, 255, 8000)`, so it can
produce 2896000 or 2904000 and nothing between. `min == max == 2900000` is an
empty interval, the rail never initialises its voltage, and the core returns
`-ENOTRECOVERABLE` — which fails **the entire `regulators-N` node**, not the
one rail. That stalled the boot at 0.196 s. Fixing it exposed
`vreg_l2m_1p15` at `1150000` doing exactly the same thing one PMIC over, which
cost a second boot.

The ranges and the per-PMIC LDO tables are parsed out of
`qcom-rpmh-regulator.c` and `of_match_table`, so the check tracks the driver
rather than a number someone typed into a checker once.

**GDSC** — an enabled node drawing clocks from a controller that also owns a
matching power domain the node never references.

This is the USB4 bug. The host router nodes had five GCC clocks and no
`power-domains`, so `devm_clk_bulk_get_all_enabled()` ran against an unpowered
GDSC, `clk_branch_wait()` warned "status stuck at 'off'" and returned
`-EBUSY`, and probe died on all three routers.

The check resolves each clock *index* back through
`include/dt-bindings/clock/qcom,x1e80100-gcc.h`, so it can say "takes
`GCC_USB4_0_SB_IF_CLK` and needs `gcc_usb4_0_gdsc`" instead of guessing from
the node name. Naming the exact fix is the difference between a lead and a
patch.

**NAME-COUNT** — `clocks`/`clock-names` and friends disagreeing in length.
Entry counts come from resolving each provider's `#*-cells` by phandle, and
`interrupts` from the interrupt parent's `#interrupt-cells`, because a flat
cell count means nothing on its own.

**DUP-IRQ / DUP-GPIO** — two enabled nodes claiming one GIC SPI or one TLMM
pin. Both are SUSPECT, not BUG: shared interrupts are legal and cluster PMUs
legitimately share one.

**REG-OVER** — overlapping MMIO windows, compared only between nodes that
share a parent, since `reg` lives in the parent bus's address space. Relevant
because the USB4 node rounded a `0xBFFFF` window from ACPI up to `0xC0000` on
a hunch.

**DEAD-REF** — a `*-supply` pointing at a node that is disabled or absent.

**NO-DRIVER** — no compatible on the node appears anywhere under `drivers/` or
`sound/`. HINT only, and a node passes if *any* of its compatibles is claimed,
because the list is a fallback chain.

**ODD-ONE-OUT** — a property most other boards declare at the same node path
that we do not.

This is the reasoning that found the missing `reset-gpios` on the WCN7850
PCIe port, where 23 of 24 boards had it. Keyed on **node path**, not
compatible: comparing one `regulator-fixed` against every fixed regulator on
69 boards produces 127 findings and no information. `-el2` variants are
excluded because they are generated overlays of a board already in the list
and double-weight that machine.

---

## The second axis: the boot payload

Once the device tree was clean, three unexplained `-ENOENT`s were still costing
boots. They had one cause, and it was provable without booting.

**FW-COMPRESS** — firmware shipped compressed that the kernel cannot
decompress. The INTEG initramfs carries **29 zstd-compressed firmware files
and 6 plain**, including `qcom/x1e80100/gen70500_zap.mbn.zst`, while
`CONFIG_FW_LOADER_COMPRESS is not set`. So `request_firmware()` returns
`-ENOENT` for 29 of 35 files that are sitting inside the kernel's own
initramfs. That single fact accounts for the GPU, WiFi and Bluetooth firmware
failures at once, and it is a file listing plus a config grep.

**MOD-COMPRESS** — the same trap for modules.

**HOOK-TOOLS** — a dracut hook calling a command the initramfs does not
contain. The pre-pivot hook used `du`, `head`, `cut` and `basename`, none of
which exist there. The size guard was `du -k | cut -f1`, which produced an
empty string, so every file took the "skipped oversize" branch. It reported
success and copied nothing, and the failure presented as "there was no journal"
rather than "the check is broken."

**HOOK-EXIT** — dracut *sources* hook files, so a live `exit` aborts
`dracut-pre-pivot` before its own `source_hook cleanup` on the next line.

**CONFIG-REQ** — symbols this machine has been observed to need, each stored
with the consequence of it being off. Not derived from source, so it is a
regression guard rather than a discovery: once a boot teaches us something, a
later rebuild should not be able to lose it silently.

## Every branch has to be audited on its own

Topic branches fork from `sp11` independently, so **a fix made on one does not
reach the others, and nothing warns you.** The voltage-grid fix lives on
`camera/denali-pm8010`; `debug/imx681-addr-scan` merges that branch and so
carried both bad rails, and `debug/cci-bus-scan` inherited them from there.

Built as they were, PR #5 and PR #7 would each have stalled at 0.196 s — and
PR #5's entire purpose is to run an I²C scan that needs userspace.

So the loop runs per branch, not once on the integration branch:

```sh
# one worktree, seeded once, switching branches -- objects persist, so each
# `make dtbs` is seconds rather than a cold build of ~11000 files
for b in $BRANCHES; do
    git reset -q --hard && git checkout -q -f "$b"
    cp "$MAIN/.config" .config
    make -j"$(nproc)" olddefconfig </dev/null   # this branch's Kconfig
    make -j"$(nproc)" dtbs </dev/null
    dt-audit.py --tree "$W" --board "$BOARD" --quiet-hints
done
```

**Auditing the content is not the same as checking what the PR shows.** A
killed run had already cherry-picked the fix onto `debug/imx681-addr-scan`
locally but died before pushing, so the branch was correct on disk and stale on
GitHub. Every audit passed and PR #5 still displayed the broken version.
Compare `git rev-parse <branch>` against `git rev-parse publish/<branch>` as a
separate step.

## Harness traps that look like results

These cost more time today than any real bug, and none of them are about the
kernel.

**`make` with no stdin hangs forever.** Switching branches changes `Kconfig`,
so `make` fires `conf --syncconfig`, which blocks reading stdin when stdin is a
pipe that never delivers:

```
conf --syncconfig Kconfig   state=S  wchan=pipe_read  syscall=63(read)
```

At 0% CPU this is indistinguishable from a slow build. **Give every `make` a
`</dev/null`.** `build-iso2.sh:58` already does this on its own make line — that
redirect was not decoration, and reading past it cost two wedged runs.

**WSL2 reclaims its VM out from under long jobs, and that is why `/tmp` keeps
emptying.** Not a quirk — a fresh VM each time.

The Hyper-V VmSwitch log shows the mechanism plainly. Three VM lifecycles in
seven minutes:

```
18:50:16  port 1F1E00CC  Delete complete      VM #1 destroyed
18:50:33  port 6325280E  Create succeeded     VM #2
18:53:54  port 6325280E  Delete complete      VM #2 destroyed
          ...3m19s with no VM at all...
18:57:13  port F48BB3E4  Create succeeded     VM #3
```

Not sleep: zero `Kernel-Power` events. Not memory: 27 GB free of a 30 GB limit,
no OOM, no swap touched. The WSL journal's last entries before each gap are an
*orderly* shutdown — `snapd.service: Deactivated successfully` — so something
asked politely.

It is `vmIdleTimeout`, which `.wslconfig` never sets and so defaults to 60 s.
WSL2 tears the VM down once no `wsl.exe` **client session** remains, and every
tool invocation is such a session. A harness timeout that kills the foreground
`wsl.exe` removes one; if it was the last, the VM and every "background" job
inside it go about a minute later.

Two mitigations, in order of preference:

```sh
# immediate, no restart needed: a session-detached process the VM cannot
# consider idle. setsid is the point -- nohup alone still dies with the session.
setsid nohup sleep 86400 </dev/null >/dev/null 2>&1 &

# durable, but needs `wsl --shutdown` to take effect, so do it when nothing
# is building:  %USERPROFILE%\.wslconfig
#   [wsl2]
#   vmIdleTimeout=-1
```

Diagnose with `ps -o etime= -p 1` before assuming a job is merely slow, and
check the VmSwitch provider in the Windows System log for Create/Delete pairs.
Scripts belong on `/mnt/c`; anything long should be resumable.

**A cold worktree is a cold build.** Seed a new worktree from the main tree's
objects (`tar --exclude=.git`) or a five-second job becomes an hour.

**Never redirect an error you have not read once.** `git checkout 2>/dev/null`
reported "checkout failed" on five of seven branches; the real cause was the
loop leaving the worktree dirty, and checkout was correctly refusing to
clobber. The message said so and I had thrown it away.

## Adding a check

The pattern that makes these worth writing:

1. **Find the constraint in the consuming driver, and parse it from there.**
   Not from a datasheet, not from memory. A hardcoded 8000 would have been
   wrong for `pmic5_nldo502` (base 528000), `pmic5_bob` (step 32000) and
   `pmic5_ftsmps525` (step 4000 below 1376000, 8000 above).
2. **Regression-test against a bug you already fixed.** Revert the fix in a
   scratch copy, rebuild, confirm the check fires, restore. A check that has
   never caught its own motivating bug is decoration:

   ```
   REG-GRID with the fix reverted:
     [BUG] ldo16  vreg_l16b_2p9 [2900000, 2900000] contains no selector
     [BUG] ldo2   vreg_l2m_1p15 [1150000, 1150000] contains no selector
   clean tree: 0 BUG
   ```
3. **Classify honestly.** If boards legitimately differ, it is a HINT.

---

## Five ways my own checks were wrong

Recorded because they are the failure modes to expect, not because they were
interesting.

**`dtc` renders string lists as one string with `\0` separators.**

```
clock-names = "camnoc_axi\0cpas_ahb\0cci";
compatible  = "qcom,x1e80100-cci\0qcom,msm8996-cci";
```

Reading them as single strings made every list look one element long — 80-odd
false NAME-COUNT positives, and silently broke `compatible` matching in three
other checks, which is the more dangerous half because it fails quiet.

**`REGULATOR_LINEAR_RANGE(min_uV, min_sel, max_sel, step)` is offset by
`min_sel`.** The value at a selector is `min_uV + (sel - min_sel) * step`.
Ignoring the offset made `ftsmps525`'s second range (base 1376000 starting at
selector 268) look unreachable for `1856000`, which lands on it exactly.

**The core does not require `min` to be on the grid.** It picks the lowest
selector inside `[min, max]`. Checking "is `min` a valid selector" flags
correct upstream rails like `vreg_bob1` at `3008000..3960000`. The real defect
is an *empty interval*, which is a different question and the one that
actually fires.

**Splitting shell on `;` without respecting quotes.** The hook contains
`echo "name can ever load; a .zst present alone means -ENOENT."`, and the
command extractor split on that semicolon and reported `a` as a missing
command. Quoted spans are now masked before any splitting, and the case is in
the self-test.

**A verification step that could not succeed.** While distributing commits to
topic branches I "verified" each with `make dtbs` in a fresh worktree — which
has no `.config`, so the build cannot run and always reports failure. Three
FAILED lines went by and the branches were pushed anyway. Re-run with the
config copied in, all three build and audit clean, but the check as written
carried no information.

The common thread for the first four: they made the checker disagree with a
tree that boots. When that happens, the checker is wrong until proven
otherwise.

The fifth is the more dangerous shape and it recurs — the same family as
`du` failing open, and as `modprobe -r` on a driver name silently doing
nothing while three BDF candidates "tested" clean. **A check that cannot fail
and a check that cannot succeed both read as information.** Before trusting
a green or a red, confirm the check is capable of the other answer.

---

## Open findings

Fixed, committed, and distributed to the topic branch that owns each, with a
draft PR on `lain3d/surface-pro-11-kernel`:

| commit | branch | PR |
|---|---|---|
| camera rails snapped to the voltage grid | `camera/denali-pm8010` | #2 |
| GDSCs on the three USB4 host routers — **not yet booted** | `usb4/platform-nhi` | #3 |
| SMMU stream IDs on those routers, from the IORT — **not yet booted** | `usb4/platform-nhi` | #3 |
| PERST#/WAKE# on the WCN7850 PCIe port | `wifi/wcn7850-perst` | #6 |
| voltage fix propagated to the debug branches | `debug/imx681-addr-scan`, `debug/cci-bus-scan` | #5, #7 |

All seven branches build `x1e80100-microsoft-denali-oled.dtb` and audit clean
**on their own**, and each local ref matches its `publish/` counterpart:

```
camera/ov13858-dt        camera/denali-pm8010     usb4/platform-nhi
camera/imx681            debug/imx681-addr-scan   wifi/wcn7850-perst
debug/cci-bus-scan                       all: 0 BUG, 0 SUSPECT, 0 HINT
```

The `iommus` gap was found by hand, not by the tool. A `DMA-MASTER` check
exists for it but is **not in the default set**: calibration showed it fires
correctly on the USB4 routers before the fix and is clean after, but it also
flags `arm,mmu-500` on the SMMU itself and matches `syscon` to
`ixp4xx_hss.c`. "The driver calls the DMA API" is much weaker than "this device
is a DMA master behind this SMMU", and a check that noisy would not get read.

Open on the initramfs axis, all needing one kernel rebuild:

| symbol | consequence |
|---|---|
| `FW_LOADER_COMPRESS` (+`_ZSTD`) | 29 of 35 firmware files in the initramfs are unloadable |
| `EXFAT_FS` | `/mnt/t7` cannot mount; the original diag pipeline is dead |
| `SQUASHFS_LZO/XZ/ZSTD` | every snap fails to mount |
| `PSTORE_RAM` is `m`, wants `y` | ramoops misses early boot |

Left alone deliberately, because they are upstream code we have no evidence
about and adding them means adding variables:

| finding | peers | note |
|---|---|---|
| `rtmr0_default` lacks `bias-disable`, `input-disable`, `output-enable` | 21/25 | Type-C retimer reset pin. Interesting given the retimers sit on the port the root disk uses |
| `spkr_01_sd_n_active` lacks `output-low` | 31/33 | speaker shutdown pin |
| `vreg_l12b_1p2`, `vreg_l15b_1p8` lack `regulator-always-on` | 16/21 | they *do* have consumers here (the WSA speakers), but those are deferred on the offline ADSP, so nothing enables them and the core may drop them as unused |

Accepted as upstream behaviour:

- three cluster PMUs sharing GIC SPI 581
- `gmu@3d6a000`'s window overlapping `clock-controller@3d90000`

---

## What this cannot tell you

Static checking ends where the hardware begins. It cannot know an I²C address
until something ACKs, whether firmware exists on the target root, whether a
QMI handshake is accepted, or whether a link trains. Those need a boot, and
the point of the loop is to make sure that boot is spent on one of them rather
than on a voltage that was never producible.

---

## Save point

Recorded so a bad iteration can be undone without re-deriving anything.
Full manifest with hashes in `C:\sp11-stage\BASELINE.txt`.

```
kernel tree      integration/iso2 @ 029174f90
kernel release   7.1.3-sp11-integ-gf2cc827b6b89
booting image    BOOTAA64-integ7.efi   (ESP \EFI\BOOT\BOOTAA64.EFI)
fallback         \EFI\sp11\stock-fallback.efi   -- one copy restores a working machine
cmdline          root=UUID=803b0fd3-... ro loglevel=7 console=tty0
                 clk_ignore_unused pd_ignore_unused arm64.nopauth
                 modprobe.blacklist=thunderbolt
```

The DTB that `029174f90^` produces is byte-identical to the one in the booting
image, which is the property that makes the save point real rather than
nominal. `029174f90` itself adds the USB4 GDSCs and has not been booted.
