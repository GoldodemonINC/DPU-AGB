# DPU — Disk-Dependent Processing Unit

A disk-backed virtual VRAM engine for Windows, in three layers. For the
repository landing page, see the [root README](../README.md).

| Layer | Module | Job |
|---|---|---|
| Backend | [blockdev.zig](src/backend/blockdev.zig), [alloc.zig](src/backend/alloc.zig) | Block I/O against `P:\DPU\pool.vram`, plus the allocator |
| Midend | [tiers.zig](src/backend/tiers.zig), [pool.zig](src/pool.zig) | Capacity policy: the tier ladder and the pool ceiling |
| Frontend | [server.zig](src/server.zig), [web/](web/) | Dashboard and control surface on `127.0.0.1:8787` |
| Driver | [icd.zig](src/backend/icd/icd.zig) | The Vulkan ICD that makes the pool visible to applications |

## Build and run

```sh
zig build            # engine  -> zig-out/bin/dpu.exe
zig build test       # 133 tests: block device, allocator, tiers, residency, ICD
zig build test-vkabi # 7 assertions about the vendored Vulkan headers
zig build icd        # -> zig-out/bin/{dpu_icd.dll, vk_icd.json, dpu-vulkan.cmd}
zig build bench      # real flushed device throughput against P:\
zig build run        # engine + dashboard
zig build probe      # load the real Vulkan loader and verify the DPU enumerates
zig build check      # the gate: fmt, 140 tests, ABI assertions, both binaries
```

The dashboard is at `http://127.0.0.1:8787`. The capacity pool is optional: if
`P:\` is missing the engine still boots and simply reports no buffer.

`zig build check` is the gate, and it currently reports **17/17 steps,
140/140 tests, exit 0**. It builds both shipped binaries -- `dpu.exe` and
`dpubench` -- so a green run means the artifacts people actually run compile,
not merely that the tests compiled. It used not to: a local `const` shadowed a
top-level `fn`, so `zig build bench` had stopped compiling while the gate stayed
green. `probe` is the honest test: **61/61, exit 0**, against the real loader,
with no loader warnings at all.

## The capacity tier ladder

Capacity is not a continuous knob. It is a fixed ladder, so that what the
dashboard advertises and what the disk can back can never drift apart:

```
2 · 4 · 6 · 8 · 12 · 16 · 24   GiB
```

| Mode | Rungs it may grant | Top rung |
|---|---|---|
| LOW | 2, 4 | 4 GiB |
| xHIGH | 6, 8 | 8 GiB |
| MAX | 12, 16, 24 | 24 GiB |

Two rules matter more than the table:

- **A mode is an upper bound, not a floor.** `resolve()` grants the highest rung
  that fits in `free - 2 GiB`. An earlier revision searched only the mode's own
  band, so MAX on a 7 GiB volume granted nothing while 4 GiB sat free. A mode
  is a request for *at most*, and the volume has the final word.
- **2 GiB is held back from the pool.** The one thing that can hurt the machine
  is filling the volume.

`Resolution` distinguishes four outcomes, because "you asked for 24 and got 24"
and "you asked for 24 and the disk only had room for 16" call for different
responses: `granted`, `clamped` (a lower rung fitted), `starved` (nothing
fits), and `free_at_check`.

The ceiling is **monotonic** — `raiseCeiling` refuses to shrink. Dropping from
MAX back to LOW therefore leaves the pool where it is rather than invalidating
offsets that clients are already holding.

### On this machine, 24 GiB is refused

`P:\` is a 25.23 GiB volume. With the 2 GiB reserve, 24 GiB does not fit, so MAX
resolves to 16 GiB with `clamped: true`. That is the ladder working, not a bug.
On a larger volume MAX grants the full 24 GiB with nothing to clamp.

## The Vulkan ICD

`zig build icd` produces a **user-mode** installable client driver. No kernel
driver, no signing, no WDK — which is the only reason it builds and loads here
(HVCI is on and there is no EV certificate on this machine).

It advertises:

- vendor `0xd5d0`, device `0x0001`, name `DPU Disk-Dependent Processing Unit`,
  type `DISCRETE_GPU`, API 1.3
- one `DEVICE_LOCAL` memory type on one heap, sized to the **granted tier**
- one queue family: compute + transfer, **no graphics bit**
- no device extensions, no formats (`vkGetPhysicalDeviceImageFormatProperties`
  returns `VK_ERROR_FORMAT_NOT_SUPPORTED`)

### The engine and the driver are different processes

The ICD loads inside whichever application opened Vulkan first. So the tier the
user picked on the dashboard has to reach it somehow. It does so through a
file, [tiers.state_filename](src/backend/tiers.zig):

```
P:\DPU\tier.cfg
tier_bytes=8589934592
free_bytes=27026370560
```

`Pool.applyTier` rewrites it on every power-mode change, atomically (temp file
plus `MoveFileExW`, with the handle closed before the rename — an open handle
makes the rename fail with `ERROR_SHARING_VIOLATION` and the publish silently
never lands). The ICD reads it once at `vk_icdNegotiateLoaderICDInterfaceVersion`
time and sizes its heap from it. If the file is missing or implausible it falls
back to the bottom rung: an ICD that cannot find the engine's state still has to
load, but it should not advertise capacity nobody authorised.

Verified end to end — the published tier and the heap a Vulkan client sees:

| Mode | requested | granted | tier.cfg | ICD heap |
|---|---|---|---|---|
| MAX | 24 GiB | 16 GiB (clamped) | 16 GiB | 16.00 GiB |
| LOW | 4 GiB | 4 GiB | 4 GiB | 4.00 GiB |
| xHIGH | 8 GiB | 8 GiB | 8 GiB | 8.00 GiB |

## Running llama.cpp against it

```sh
zig-out\bin\dpu-vulkan.cmd llama-server.exe --model ggml-org-model.gguf
```

The launcher sets `VK_ADD_DRIVER_FILES` for one command and exits. `vulkaninfo
--summary` then lists two devices:

```
GPU0:  Intel(R) UHD Graphics
GPU1:  DPU Disk-Dependent Processing Unit
```

`VK_ADD_DRIVER_FILES` rather than `VK_DRIVER_FILES` because it **appends** — the
real GPU stays visible alongside the DPU. `VK_DRIVER_FILES` replaces the list,
and the iGPU disappears.

### Why a launcher and not a registry entry

Two facts, both established by reading the loader's own trace with
`VK_LOADER_DEBUG=all`:

1. The Windows loader reads driver manifests from
   `HKLM\SOFTWARE\Khronos\Vulkan\Drivers` and from `VK_ADD_DRIVER_FILES`. It does
   **not** read `HKCU` for drivers — only for layers. A per-user registry key for
   a driver is silently ignored.
2. `HKLM` needs administrator rights, and it would advertise the DPU to *every*
   Vulkan application on the machine.

Point 2 is the reason for point 1 being acceptable. The DPU is for llama.cpp, so
it is attached per process. `zig build icd` builds; it never registers anything,
because a compile should not be able to install a driver behind your back.

## What Lossless Scaling will and will not see

**Lossless Scaling cannot see the DPU, and no amount of work here will change
that.** It enumerates through DXGI / D3D11 Desktop Duplication. A Vulkan ICD is
invisible to DXGI by construction — the two are different graphics stacks, not
two entries in one list. Putting the DPU in Device Manager would need a signed
WDDM display driver, which is not buildable here: no WDK, no MSVC, HVCI on, and
no code-signing certificate.

So the honest summary:

| Application | Sees the DPU | How |
|---|---|---|
| llama.cpp | **yes** | `VK_ADD_DRIVER_FILES`, via `dpu-vulkan.cmd` |
| vulkaninfo | **yes** | same |
| Lossless Scaling | **no** | DXGI/D3D11 only; unreachable from user mode |
| Device Manager / Task Manager | **no** | needs a signed WDDM kernel driver |

## Current limits, stated plainly

- **The ICD executes; it does not shade.** The entry table carries **74 entry
  points**, and the execution layer underneath is real: `vkAllocateMemory`,
  `vkCreateBuffer`, `vkBindBufferMemory`, command pools and command buffers,
  fences, `vkCmdCopyBuffer`, `vkCmdFillBuffer`, `vkCmdWriteBuffer`,
  `vkCmdPipelineBarrier`, `vkQueueSubmit`, `vkQueueWaitIdle`,
  `vkQueueBindSparse`, and `vkMapMemory`. The copy path moves real bytes between
  buffers backed by real bytes in `pool.vram`, and `probe` asserts that end to
  end. What is missing is shading: `vkCreateComputePipelines` and
  `vkCreateGraphicsPipelines` exist and refuse with a definite status rather
  than pretending to work. There are no formats either. An earlier version of
  this file claimed the ICD stopped at `vkGetDeviceQueue` with "no buffers, no
  `vkAllocateMemory`, no submits"; that was stale, and it was stale in the
  direction of understating what the driver does.
- **Device and driver UUIDs are all zeros.** llama.cpp keys some caches off
  them; worth filling in with something stable and DPU-specific.
- **`AllocationSize` is not a usable committed-bytes measure on this volume.**
  After writing 256 MiB it reported 31 MiB, with every byte intact. It is shown
  for information only and is never used as a correctness signal.
- **Latency numbers below ~2 GiB working set are the RAID controller's cache,
  not the disk.** `P:` is an NVMe behind a controller with a large cache: about
  4 GB/s under a 2 GiB set, falling to 400–500 MB/s once the set passes 4 GiB.
  The device figures are **~57.6 µs** for a random 4 KiB read against
  **0.100–0.185 µs** for RAM — 312× to 576× — and both sides are now measured
  rather than quoted. An earlier version of this file contradicted itself
  exactly here, claiming ~62–66 µs in one sentence and 2370 µs in the next,
  because it divided a measured device figure by a hardcoded 0.08 µs that
  nothing in this project ever measured and then repeated the quotient as
  fact. Quote the device figures; the small ones are noise.
- **The read granule is the largest untaken lever.** A granule sweep at a 4 GiB
  working set with one read in flight measured 78–107 MB/s at 36–51 µs for a
  4 KiB granule against 443–580 MB/s for 1 MiB — **~5.4× from the granule
  alone**, at identical device constants. Run-to-run variance is real here: the
  controller's cache moves the cold boundary between 2 and 4 GiB.

## Layout

```
src/backend/blockdev.zig   uncached write-through block I/O, 4 KiB sectors
src/backend/alloc.zig      bump + reclaim free-list allocator with a VAT
src/backend/residency.zig  paging policy and the feasibility planner
src/backend/tiers.zig      the ladder, resolve(), and the tier.cfg format
src/backend/icd/           the ICD: icd.zig, exec.zig, probe.zig
src/pool.zig               facade: ceiling policy, publishTier
src/server.zig             dashboard HTTP + telemetry
web/                       the dashboard (compiled into the executable)
third_party/vulkan/        vendored headers, Vulkan-Headers v1.3.228
```
