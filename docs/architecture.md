# Architecture

> This describes the **write-your-own-driver** project. Since it was written, NVIDIA
> shipped an ARM64 Windows driver that reportedly works with GeForce cards over USB4
> on Snapdragon X Elite — see `prior-art.md`. If the goal is simply to use a GPU here,
> that is the shorter path and this document is not the answer. What follows assumes
> the driver itself is the point.

Design constraints are set by `feasibility.md` and `device-profile.md`. The governing
decisions: **no WDDM**, **Vulkan-first via Mesa RADV**, **user-mode fence polling**.

Stated project priorities: not distributed, safety irrelevant, performance preferred
over safety, stability desired.

## Why not WDDM

WDDM would give desktop integration and D3D for free — if a UMD existed. It doesn't,
and writing one is the wall. Adopting WDDM also drags in VidMm's paging/residency
model and the dxgkrnl monitored-fence contract, which is precisely the machinery that
made the previous VirtualBox passthrough effort painful, for benefits we cannot
collect without a UMD anyway.

So: `dxgkrnl` is not involved. The GPU is a PCIe compute/render appliance.

## Stack

```
 application
     |  Vulkan
 Mesa RADV, built for Windows ARM64          <- user mode
     |  thin ioctl-shaped interface (DeviceIoControl + shared memory)
 egpu.sys — KMDF PCI function driver         <- kernel mode, ARM64, test-signed
     |  MMIO / MSI / DMA (SMMUv3 IOVAs)
 AMD RDNA2 GPU, behind a USB4 PCIe tunnel
```

`egpu.sys` responsibilities, and nothing more:

- Claim the PCI function, map BARs, program rBAR to a size that fits the 3.75 GB window
- MSI/MSI-X interrupt plumbing
- Device bring-up: AtomBIOS interpretation, clock/power init, ring buffer setup
- Memory: allocate VRAM (its own suballocator over the BAR) and GTT (host memory
  mapped through the SMMU), hand IOVAs to user mode
- Map buffers into user-mode address space
- Submit: ring/doorbell writes on behalf of user mode
- Nothing else. No state tracking, no validation, no scheduling policy beyond FIFO.

Everything else — command buffer construction, shader compilation, synchronization
bookkeeping, residency — lives in user mode where it can be iterated without
bugchecking the machine.

## Memory model

Three pools, all visible to user mode:

| Pool | Backing | CPU access | GPU access | Use |
|---|---|---|---|---|
| VRAM | GPU local, via BAR aperture | WC, slow over tunnel | native, fast | textures, render targets |
| GTT | host RAM, SMMU-mapped | cached, fast | DMA over tunnel | command buffers, staging, fences |
| Fence page | host RAM, SMMU-mapped | cached | DMA write | see below |

The SMMUv3 means device-visible addresses are **IOVAs**, not physicals. Allocate host
buffers through the OS DMA abstraction (`WdfDmaEnabler` / `AllocateCommonBuffer` or a
scatter-gather list) and hand the returned logical addresses to the GPU. Raw
`MmGetPhysicalAddress` output is wrong here and will produce silent corruption or
SMMU faults, not an obvious error.

IORT reports **`coherent = True`**, so no cache maintenance is needed around DMA
buffers. On most ARM SoCs this would be a constant source of subtle bugs; here it is
simply free. Do not add speculative cache flushes "for safety" — they cost real time
and buy nothing on this platform.

Command buffers go in **GTT, not VRAM**. The GPU pulls them by DMA at full tunnel
bandwidth; writing them into VRAM through the BAR means CPU stores crossing the
tunnel one WC burst at a time, which is far slower.

## Synchronization — the part that went wrong last time

The previous VirtualBox effort routed fences through the kernel: GPU raises an
interrupt, the KMD signals an event, user mode wakes. That design has two fatal
properties. Every fence costs a kernel transition plus a scheduler wakeup
(microseconds, and jittery), and the ordering between "GPU wrote the fence value" and
"kernel signalled the event" becomes a correctness problem you have to reason about
under interrupt latency. Over a **USB4 tunnel**, where MMIO round-trips are already
microseconds, that is the wrong shape entirely.

**Design instead around user-mode fence polling.**

AMD hardware fences are not special objects — they are memory writes. An end-of-pipe
packet writes a 64-bit value to an arbitrary GPU-visible address, optionally raising
an interrupt. Put that address in the **coherent host-memory fence page**. Then:

- User mode allocates a monotonically increasing sequence number per queue.
- Submission appends an EOP write of `seq` to the fence page, then rings the doorbell.
- Waiting is `while (atomic_load(fence) < seq) pause();` — **zero kernel transitions,
  zero interrupts, ~100 ns to observe completion.**

This works because the fence page is host RAM, coherent, and the GPU's write lands via
DMA. It is exactly how amdgpu user-space fences work on Linux, and it sidesteps the
entire class of bugs from last time.

Three rules that make it actually hold:

1. **Never poll a GPU register to detect completion.** An MMIO read over the tunnel is
   a synchronous round trip — microseconds, and it stalls the pipe. Only ever poll
   host memory the GPU writes into. Doorbell *writes* are posted and cheap; reads are
   not. This single asymmetry drives most eGPU performance behaviour.
2. **Hybrid wait.** Spin for a bounded window (a few microseconds), then fall back to
   an interrupt-backed event for long waits so a core isn't burned on a 16 ms frame.
   The fast path stays in user mode; the slow path pays the kernel cost only when the
   wait was going to be long anyway.
3. **Fence page ordering.** The EOP write must be ordered after the work it signals —
   that's the packet's job, and the hardware guarantees it. What is *not* guaranteed
   is ordering between the fence write and any other DMA the GPU has in flight, so do
   not infer anything beyond "the work before this EOP is done."

Interrupts remain wired up, but only for the slow path and for error/fault reporting.
They are not on the critical path of a normal submit/wait.

## Submission

Single hardware ring per queue type to start (one gfx, one compute, one SDMA). No
scheduler, no preemption, no priorities. User mode builds an IB (indirect buffer) in
GTT, submits via ioctl for the first implementation, and once that is correct, moves
to a user-mode doorbell write so the common path skips the kernel entirely.

Deliberately absent for v1: preemption, per-process address spaces, GPU reset
recovery, VRAM eviction. Each is a real feature; each can be added once something
renders. Attempting them up front is how this kind of project dies.

## Stability strategy

"Unsafe is fine" and "stable" are compatible here, but only if the split is
deliberate. Unsafety is spent on *skipping validation and kernel transitions* — a
malicious or buggy user-mode process can trivially hang or corrupt the GPU, and that
is accepted. It is not spent on *guessing about hardware contracts*. So:

- No validation of user-mode-supplied command buffers. Trust everything.
- No security boundary between the user-mode driver and the kernel driver.
- But: strict adherence to SMMU/DMA API contracts, ring buffer invariants, and
  register access ordering, because violations there produce non-deterministic
  corruption rather than clean failures, and non-determinism is what actually
  destroys a project like this.
- GPU hang detection via fence timeout from user mode, and a device reset path in the
  KMD, added early. Hangs will be constant during bring-up; recovering without a
  reboot is the difference between iterating in minutes versus hours.

## Phases

| Phase | Deliverable | Proves |
|---|---|---|
| 0 | NVMe enclosure enumerates over USB4 | transport, host bridge, resource assignment |
| 1 | Hello-world KMDF driver loads test-signed on ARM64 | signing/HVCI path |
| 2 | `egpu.sys` claims the GPU, maps BARs, dumps PCI config + VBIOS | device is reachable |
| 3 | AtomBIOS init runs; GPU reaches a known-good state | bring-up |
| 4 | Ring buffer live; a NOP packet completes and the fence lands in host memory | **the whole sync design** |
| 5 | SDMA copy host↔VRAM at expected bandwidth | DMA/SMMU correctness |
| 6 | Hand-assembled compute shader executes | compute path end to end |
| 7 | RADV ported onto the ioctl surface | Vulkan |
| 8 | Copy-back presentation into a normal window | something visible |

Phase 4 is the real milestone. It is where the previous project's hardest problem gets
retired, and everything after it is incremental.

## Known open questions

- Does Windows actually populate `PCI0`/`PCI1` and assign the 3.75 GB window on
  hotplug? (Phase 0 answers this.)
- Do the non-prefetchable window flags cause the PCI arbiter to refuse a 64-bit
  prefetchable BAR placement?
- Does the USB4 bandwidth manager reserve enough PCIe bandwidth when a DisplayPort
  tunnel is also active, or does attaching a monitor starve the GPU?
  (Partially answered: `Usb4HostRouter.sys` exposes `ForceEnableDpBwAllocationMode`
  and `EnableDpBwMinimalPreallocationMode` as registry knobs that shift this
  allocation — see `usb4-driver-notes.md`. Needs hardware to tune.)
- Can RADV's build system be made to target Windows ARM64 at all? Mesa's Windows
  support is real but x64-centric; this may need meaningful build-system work before
  any of it compiles.
- Does the SMMUv3 impose an IOVA size limit that constrains total mapped GTT?
