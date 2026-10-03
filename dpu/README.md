# DPU — Disk-Dependent Processing Unit

A disk-backed virtual VRAM engine for Windows, in three layers:

| Layer | Module | Job |
|---|---|---|
| Backend | [blockdev.zig](src/backend/blockdev.zig), [alloc.zig](src/backend/alloc.zig) | Block I/O against `P:\DPU\pool.vram`, plus the allocator |
| Midend | [tiers.zig](src/backend/tiers.zig), [pool.zig](src/pool.zig) | Capacity policy: the tier ladder and the pool ceiling |
| Frontend | [server.zig](src/server.zig), [web/](web/) | Dashboard and control surface on `127.0.0.1:8787` |
| Driver | [icd.zig](src/backend/icd/icd.zig) | The Vulkan ICD that makes the pool visible to applications |

## Build and run

```sh
zig build            # engine  -> zig-out/bin/dpu.exe
zig build test       # 33 backend tests (block device + allocator + tiers)
zig build test-vkabi # 7 assertions about the vendored Vulkan headers
zig build icd        # -> zig-out/bin/{dpu_icd.dll, vk_icd.json, dpu-vulkan.cmd}
zig build bench      # real flushed device throughput against P:\
zig build run        # engine + dashboard
```

The dashboard is at `http://127.0.0.1:8787`. The capacity pool is optional: if
`P:\` is missing the engine still boots and simply reports no buffer.

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

- **The ICD is an identity, not an executor.** It enumerates and reports; it
  stops at `vkGetDeviceQueue`. There are no buffers, no `vkAllocateMemory`, no
  submits — `vkGetDeviceProcAddr` returns null for those. An application that
  picks the DPU and then asks for a buffer will get a clean failure, not a
  crash, but it will not get work done. This is the honest current state: the
  device is discoverable, the plumbing underneath it is not built yet.
- **Device and driver UUIDs are all zeros.** llama.cpp keys some caches off
  them; worth filling in with something stable and DPU-specific.
- **`AllocationSize` is not a usable committed-bytes measure on this volume.**
  After writing 256 MiB it reported 31 MiB, with every byte intact. It is shown
  for information only and is never used as a correctness signal.
- **Latency numbers below ~2 GiB are cache, not disk.** The volume sits behind a
  RAID controller. Under ~2 GiB working set you are measuring the controller
  cache (3–6 µs random, ~4 GB/s read). At 8 GiB the device numbers are
  ~295–385 MB/s write, ~377–487 MB/s read, ~62–66 µs random 4 KiB read — roughly
  840× worse than RAM. Quote the 8 GiB figures; the small ones are noise.

## Layout

```
src/backend/blockdev.zig   uncached write-through block I/O, 4 KiB sectors
src/backend/alloc.zig      bump + reclaim free-list allocator with a VAT
src/backend/tiers.zig      the ladder, resolve(), and the tier.cfg format
src/backend/icd/icd.zig    the Vulkan ICD
src/pool.zig               facade: ceiling policy, publishTier
src/server.zig             dashboard HTTP + telemetry
web/                       the dashboard (compiled into the executable)
third_party/vulkan/        vendored headers, Vulkan-Headers v1.3.228
```
