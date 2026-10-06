# DPU — Disk-Dependent Processing Unit

**A GPU that runs on disk.** A `pool.vram` file on `P:\`, presented to Vulkan
applications as a discrete GPU through a user-mode installable client driver
(no kernel driver, no signing, no WDK).

The pitch is a larger memory than the machine has, and the cost of that is
honesty about how slow it is. This repository keeps that cost visible: every
number below was measured on the machine that produced the code, and the ones
that could not be measured yet are marked as predictions rather than results.

## Status

| Gate | Result |
|---|---|
| `zig build check` | **17/17 steps, 140/140 tests, exit 0** |
| `zig build probe` | **61/61 checks, exit 0**, no Vulkan loader warnings |
| `zig fmt --check` | clean |

The gate builds both shipped binaries — `dpu.exe` and `dpubench` — so a green
run means the artifacts people actually run compile, not only that the tests
compiled. It used not to: a local `const` shadowed a top-level `fn`, so
`zig build bench` had not compiled for some time while the gate stayed green.
That is the class of failure this project is most careful about, and
`Context.md` records the red proof.

`zig build probe` is the honest one: it loads the *real* Vulkan loader, points
it at the built ICD, and asserts that the DPU enumerates as a device whose heap
carries real bytes on disk. It is a test against the driver as shipped, not
against the driver's own idea of itself.

## The layers

| Layer | Module | Job |
|---|---|---|
| Backend | [`dpu/src/backend/blockdev.zig`](dpu/src/backend/blockdev.zig), [`alloc.zig`](dpu/src/backend/alloc.zig) | Uncached write-through block I/O against `P:\DPU\pool.vram`, plus the bump + reclaim free-list allocator over it |
| Backend | [`dpu/src/backend/residency.zig`](dpu/src/backend/residency.zig) | The paging policy and feasibility planner: what fits, what faults, at what rate |
| Midend | [`dpu/src/backend/tiers.zig`](dpu/src/backend/tiers.zig), [`dpu/src/pool.zig`](dpu/src/pool.zig) | Capacity policy: the tier ladder, the pool ceiling, publishing `tier.cfg` |
| Frontend | [`dpu/src/server.zig`](dpu/src/server.zig), [`dpu/web/`](dpu/web/) | Dashboard and telemetry on `127.0.0.1:8787` |
| Driver | [`dpu/src/backend/icd/`](dpu/src/backend/icd/) | The user-mode Vulkan ICD that makes the pool visible to applications |

## Build and run

Requires **Zig 0.16** targeting `x86_64-windows-gnu`.

```sh
cd dpu
zig build            # engine       -> zig-out/bin/dpu.exe
zig build icd        # driver       -> zig-out/bin/{dpu_icd.dll, vk_icd.json, dpu-vulkan.cmd}
zig build run        # engine + dashboard at http://127.0.0.1:8787
zig build check      # the gate: fmt, tests, Vulkan ABI assertions, both binaries
zig build probe      # load the real loader and verify the DPU enumerates
zig build bench      # real flushed device throughput against P:\
```

| Step | What it does |
|---|---|
| `install` | Copy build artifacts to `zig-out` (default) |
| `uninstall` | Remove build artifacts |
| `run` | Run the DPU dashboard engine |
| `test` | Backend unit and integration tests |
| `test-vkabi` | Assert the vendored Vulkan headers match the 1.3 ABI |
| `bench` | Measure real flushed `P:\` device throughput |
| `compile-bench` | Build `dpubench` without running it (used by `check`) |
| `icd` | Build `dpu_icd.dll` + `vk_icd.json` + `dpu-vulkan.cmd` |
| `probe` | Load the real Vulkan loader and verify the DPU enumerates |
| `check` | Formatting, unit tests, ABI assertions, and the server executable |

The pool is optional. If `P:\` is missing the engine still boots and reports no
buffer rather than failing.

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
  band, so MAX on a 7 GiB volume granted nothing while 4 GiB sat free.
- **2 GiB is held back from the pool.** The one thing that can hurt the machine
  is filling the volume.

The ceiling is **monotonic** — `raiseCeiling` refuses to shrink — so dropping
from MAX back to LOW leaves the pool where it is rather than invalidating
offsets clients already hold.

## The Vulkan ICD

`zig build icd` produces a user-mode ICD: a DLL the Vulkan loader picks up per
process through `VK_ADD_DRIVER_FILES`. It advertises vendor `0xd5d0`, device
`0x0001`, type `DISCRETE_GPU`, API 1.3, one `DEVICE_LOCAL` memory type on one
heap sized to the granted tier, and one compute + transfer queue family with
no graphics bit.

**What it actually does, stated plainly:** it is not an enumerator that stops
at `vkGetDeviceQueue`. The entry table carries **74 entry points**, and the
execution layer underneath is real: `vkAllocateMemory`, `vkCreateBuffer`,
`vkBindBufferMemory`, command pools and buffers, fences,
`vkCmdCopyBuffer`, `vkCmdFillBuffer`, `vkCmdWriteBuffer`,
`vkCmdPipelineBarrier`, `vkQueueSubmit`, `vkQueueWaitIdle`, `vkQueueBindSparse`,
and `vkMapMemory`. The copy path moves real bytes between buffers backed by
real bytes in `pool.vram`; the probe asserts that end to end. Pipeline creation
is present and refuses with a definite status rather than pretending to work,
and there are no formats.

The tier reaches the driver through a file, `P:\DPU\tier.cfg`, written
atomically on every power-mode change and read once at ICD negotiation time. An
ICD that cannot find the engine's state still has to load, but it should not
advertise capacity nobody authorised, so it falls back to the bottom rung.

Verified end to end — the published tier and the heap a real Vulkan client sees:

| Mode | requested | granted | `tier.cfg` | ICD heap |
|---|---|---|---|---|
| MAX | 24 GiB | 16 GiB (clamped) | 16 GiB | 16.00 GiB |
| LOW | 4 GiB | 4 GiB | 4 GiB | 4.00 GiB |
| xHIGH | 8 GiB | 8 GiB | 8 GiB | 8.00 GiB |

## What a 9B model at 64k actually costs

This is the question the project is built around: can the DPU plus an iGPU plus
8 GB of RAM hold a 9B model at a 64k context? **It can hold it. It cannot run
it at a useful speed, and the reason is not the weights.**

Measured, 3B Q4_K_M at `-c 65536` under llama.cpp:

| Pool | Load | Generation | Exit |
|---|---|---|---|
| off | 2.06 s | **7.77 tok/s** | 0 |
| on (`GGML_DPU_POOL=1`) | 8.45 s | **6.29 tok/s** | 0 |

A 19% generation cost for a real 8 GiB pool, which is a far more useful number
than the single-digit-hours figure the design once assumed.

At 9B and 64k the **KV cache, not the weights, is the dominant term**:

| 9B at 64k | Weights | KV cache per token | Working set | Verdict |
|---|---|---|---|---|
| f16 | 18.5 GB | 22.5 GB | **41.0 GB** | `DOES NOT FIT` against an 8 GiB pool |
| 4-bit | 5.0 GB | 5.3 GB | 10.3 GB | `STREAMED` at **0.117 tok/s** |

So the original framing — *cannot run* to *can run* — is right, and the
`0.7-6 tok/s` target is not reachable. The lever is quantising the *cache*, and
that is a model-side change, not a driver one.

One correction the measurement forced: the planner originally priced the KV
cache at the full 64k context and predicted 0.167 tok/s for a run that did no
paging at all. A 64k window is a *reservation*; the history is a *length*. 31
tokens of history is about 3.6 MB, not 7.5 GB.

Device constants behind those numbers, all measured here:

| Quantity | Value |
|---|---|
| Pool random 4 KiB read | ~57.6 us |
| RAM random 4 KiB read | 0.100-0.185 us |
| Ratio | 312-576x slower |
| Sequential device throughput | 400-500 MB/s |
| Granule sweep, 4 KiB granule | 78-107 MB/s at 36-51 us |
| Granule sweep, 1 MiB granule | 443-580 MB/s |

**~5.4x from the read granule alone**, at identical device constants. That is
the largest single lever measured so far, and it is not implemented yet.

## Who can see the DPU

| Application | Sees the DPU | How |
|---|---|---|
| llama.cpp | **yes** | `VK_ADD_DRIVER_FILES`, via `dpu-vulkan.cmd` |
| vulkaninfo | **yes** | same |
| Lossless Scaling | **no** | DXGI / D3D11 Desktop Duplication only |
| Device Manager, Task Manager | **no** | needs a signed WDDM kernel driver |

`VK_ADD_DRIVER_FILES` rather than `VK_DRIVER_FILES` because it **appends** —
the real iGPU stays visible alongside the DPU, so `vulkaninfo --summary` lists
two devices. `VK_DRIVER_FILES` replaces the list and the iGPU disappears.

Lossless Scaling cannot be reached from user mode. A Vulkan ICD is invisible to
DXGI by construction: two graphics stacks, not two entries in one list. Putting
the DPU in Device Manager would need a signed WDDM display driver, which is not
buildable here — no WDK, no MSVC, HVCI on, no code-signing certificate.

## Current limitations, stated plainly

- **No compute pipelines.** `vkCreateComputePipelines` and
  `vkCreateGraphicsPipelines` exist and refuse with a definite status. Buffers,
  memory, submits, and the copy path work; shading does not.
- **Device and driver UUIDs are all zeros.** llama.cpp keys some caches off
  them. They should be stable and DPU-specific.
- **The 9B at 64k has never been run end to end.** Those rows are the planner
  predicting over measured device constants. They are not measurements.
- **Nothing drives the residency scheduler yet.** The plan table in
  `residency.zig` is a prediction until a client faults pages through it. Its
  policy finding is real and measured in isolation, though: **LRU earns zero
  hits on a decoder's cyclic scan**, where a pinned policy earns 8 on the same
  trace.
- **No iGPU tok/s baseline.** The Vulkan SDK is not installed on this machine,
  so the comparison half of every speedup claim is missing. Ten install attempts
  failed.
- **`AllocationSize` is not a usable committed-bytes measure on this volume.**
  After writing 256 MiB it reported 31 MiB, with every byte intact. Shown for
  information; never used as a correctness signal.
- **Latency numbers below ~2 GiB working set are the RAID controller's cache,
  not the disk.** `P:` is an NVMe behind a controller with a large cache: about
  4 GB/s under a 2 GiB set, falling to 400-500 MB/s once the set passes 4 GiB.
  Quote the device figures, not the small ones.
- **A cold-read minimum fix is unexercised.** Every run so far produced a single
  device-sized sweep row; the multi-row path that would exercise it needs 8 GiB
  of headroom, which this machine does not have.

## Layout

```
dpu/src/backend/blockdev.zig   uncached write-through block I/O, 4 KiB sectors
dpu/src/backend/alloc.zig      bump + reclaim free-list allocator with a VAT
dpu/src/backend/residency.zig  paging policy and the feasibility planner
dpu/src/backend/tiers.zig      the ladder, resolve(), and the tier.cfg format
dpu/src/backend/icd/           the ICD: icd.zig, exec.zig, probe.zig
dpu/src/pool.zig               facade: ceiling policy, publishTier
dpu/src/server.zig             dashboard HTTP + telemetry
dpu/web/                       the dashboard (compiled into the executable)
dpu/third_party/vulkan/        vendored headers, Vulkan-Headers v1.3.228
Context.md                     the working context: findings, dead ends, numbers
src/loadertest.zig             a scratch probe that loads vulkan-1.dll directly
tools/                         one-shot source-patch scripts from past debugging
```

`src/` and `tools/` at the repository root are not part of the build.
`loadertest.zig` asks the system Vulkan library directly for
`vkEnumerateInstanceVersion` and `vkCreateInstance`, which is how the loader's
own behaviour got separated from the driver's. The `tools/p*.py` scripts are
the exact-match source patches applied during those debugging sessions, kept
because they document what was tried and in what order. Neither is needed to
build or run the DPU.

## Further reading

- [`dpu/README.md`](dpu/README.md) — the deeper dive on the tier ladder, the
  `tier.cfg` handoff between engine and driver, and why the driver is attached
  per process instead of by a registry entry.
- [`Context.md`](Context.md) — the working context. Findings that survived
  verification, findings that did not, and the reasoning behind both.