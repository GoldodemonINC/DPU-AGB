# DPU — working context

A GPU that runs on disk. A `pool.vram` file on `P:\` presented to Vulkan
applications as a discrete GPU through a user-mode installable client driver.

## Status at this commit

`zig build check` — **78/78 tests**, exit 0, `zig fmt --check` clean.

`zig build probe` — **50/50, exit 0**, closing with
`PROBE_SUMMARY: total=50 passed=50 failed=0 result=PASS` and
`RESULT: PASS -- the DPU heap carries real bytes on disk`.

Both were re-measured on this machine for this merge. The previous copy of this
file claimed the probe was 45/45; that was stale, and a number nobody re-ran is
worse than no number.

## Repository state

- `main` is at `4b69d2a`, a **squash merge of PR #2** ("Make the loader stop
  corrupting command buffers, and run the probe for the first time"). It brought
  in `Context.md`, `dpu/src/backend/icd/exec.zig` and
  `dpu/src/backend/icd/probe.zig`.
- `bf3dfca` before it was a **squash merge of PR #1** ("Hold the tier reserve per
  volume, not per pool"), merged at 2026-10-03T18:06:35Z by the
  `Goldodemon-Automation` credential while the automation was mid-run on a
  different branch, and not requested by the task in flight. The squash commit
  is attributed to the PR author (`Goldodemon <dominickroman38@gmail.com`),
  which is what GitHub does for a squash merge; `merged_by` is the automation
  account. Treated as settled history, not reverted.
- **PR #3** (`fix/bench-fabricated-latency`) is being merged: the benchmark's
  fabricated ratio.
- **PR #4** (`fix/server-404-status`) is open: the dashboard answering 200 OK for
  a route that does not exist.

### A note on how PR #2 got merged

PR #2 was intended to be *auto*-merged, not merged immediately. The call was
`PUT /pulls/2/merge` with `{"auto_merge": true, "merge_method": "squash"}`.
GitHub only honours that flag when the repository has **"Allow auto-merge"**
enabled; it does not, so the parameter was ignored and the endpoint merged on
the spot. The token in the OS credential store also cannot read or patch
repository settings — `GET /repos/.../DPU-AGB` returns **404** — so the setting
could not be turned on programmatically first.

Worth recording because the failure mode is quiet and irreversible: the request
returns HTTP 200 and a merge SHA, and nothing in the response distinguishes
"scheduled" from "already merged". Anyone scripting this should confirm
`auto_merge` on the PR afterwards rather than trusting the 200.

Because `main` moved, PRs #3 and #4 conflicted — both had written their own
`Context.md` from scratch, so it was an add/add conflict on that one file. The
code in each branch was unaffected; the conflict is resolved by union.

## What changed in PR #2

### 1. Four command entry points had a phantom leading parameter

Every `vkCmd*` function in `src/backend/icd/exec.zig` declared one extra
leading `_: ?*anyopaque`, as if a `VkDevice` were passed first. Vulkan's
command buffers take no device:

| Entry point | Vulkan | Had | Now |
|---|---|---|---|
| `vkCmdCopyBufferImpl` | 5 | 6 | 5 |
| `vkCmdWriteBufferImpl` | 5 | 6 | 5 |
| `vkCmdFillBufferImpl` | 5 | 6 | 5 |
| `vkCmdPipelineBarrierImpl` | 10 | 11 | 10 |

They are registered directly in the dispatch table, so nothing stripped the
extra slot — it swallowed the real first argument. `vkCmdWriteBuffer` received
the *buffer* where the command buffer belonged, rejected it, recorded nothing,
and `vkQueueSubmit` cheerfully submitted an empty buffer. `vkQueueBindSparseImpl`
(4 params) and `vkCreateFenceImpl` (device-first, correct) were audited and
left alone.

### 2. The sentinel was read from a word the loader owns

`asCommandPool`, `asCommandBuffer` and `asFence` validated a magic `u32` at
offset 0. The loader writes its own dispatch pointer over the first 8 bytes of
a dispatchable object, so the check read a pointer and rejected handles the
driver had just created.

Validation now goes through `@offsetOf(T, "sentinel")`. This is not a
hardcoded 32 — see the layout note below; a literal would rot silently.

### 3. `CommandBuffer` is now an `extern struct` with a reserved first slot

Fixing the sentinel alone was not enough, because `commands.ptr` also lived at
offset 0 and was being destroyed by the same loader write. `CommandBuffer`
reserves that word (`loader_slot`) and carries no live state in it.

### 4. `zig fmt` normalisation of three files

`tiers.zig`, `pool.zig` and `server.zig` were rewritten with CRLF by a
`git checkout` under `core.autocrlf=true`, which `zig fmt --check` rejects.
`zig fmt` on exactly those three files restored them. `exec.zig` was not
touched for this.

## The loader/ICD handle contract, as measured

Not from the spec — measured on this machine, with the Windows loader at
`System32/vulkan-1.dll` (1.3.301) and ICD interface version 4:

- The loader allocates **no** separate wrapper. The address the ICD returns
  from `vkAllocateCommandBuffers` is the address the loader hands back.
- The loader **writes its dispatch pointer over the first 8 bytes** of that
  object. Anything live in that prefix is destroyed.
- `CommandPool` survived this because its sentinel is 4 bytes and the write
  landed elsewhere; `CommandBuffer` did not, because its `commands` slice
  started at offset 0.

### Zig 0.16 does not lay out structs in declaration order

This is the trap that cost the most time here. For
`{sentinel: u32, recording: bool, commands: []Command, count, capacity, err}`,
`@offsetOf` reports:

```
sentinel=32  recording=44  commands=0  count=16  capacity=24  size=48
```

`commands` is at offset **0** even though `sentinel` is written first. The
compiler packs by alignment. Any offset derived by reading the source, or by
assuming C-style ordering, is wrong. `@offsetOf` is the only safe source of
truth, which is why the validator uses it.

## Progression

| State | Probe result |
|---|---|
| First ever run | `total=44 passed=36 failed=8`, exit 1 — `BAD cmdbuf handle` on every command |
| After the `@offsetOf` sentinel fix | `passed=41 failed=3`, exit 1 — recording reached, loader rejected the handle at `vkEndCommandBuffer` |
| After the four signature fixes | unchanged — `vkCmdWriteBuffer` recorded, same VUID |
| After reserving the clobbered prefix | `total=45 passed=45 failed=0`, exit 0 |
| After adding `vkCmdFillBuffer` coverage | **`total=50 passed=50 failed=0`, exit 0** |

The third failure only appeared once recording genuinely started working, which
is why the object had to be made coherent rather than merely readable.

## What changed in PR #3: the benchmark's ratio is now measured on both sides

`bench.zig` printed `67.3 / 0.08`. The first half was a real uncached
random-read latency; the second was a literal that nothing in this project ever
measured, and the printed multiplier was that literal divided by its own
partner. README then repeated the result as "roughly 840× worse than RAM",
which made a fabricated number the project's headline performance claim.

`measureRam` now measures a counterpart instead of assuming one: a dependent
pointer chase through a 256 MiB buffer, so every step misses cache and the
prefetcher has nothing to work with. That is the same quantity the device half
measures — random access latency — rather than one borrowed from a spec sheet.

Measured on this machine:

```
system RAM memcpy             2108 MB/s   (256 MiB, sequential)
system RAM random access     0.587 us     (dependent loads, 256 MiB set)
pool random access          2370.1 us     (uncached 4 KiB reads, 8 GiB set)
=> about 4036x
```

**The honest ratio is 4036x, not 840x.** The old `0.08` understated RAM
random-access latency by roughly 7x, so the published gap was wrong in the
*optimistic* direction by about the same factor — the pool is slower than RAM
by nearly five times what the README claimed.

Two honest caveats the banner states rather than hides:

- The halves are not perfectly like for like. A dependent-load pointer chase
  and an uncached 4 KiB sector read are different operations; the ratio is a
  useful scale, not a precise constant.
- The pool figure is the 8 GiB row of a sweep. The smaller rows measure the
  RAID controller's cache, not the device, which is why the largest row is the
  one quoted.

## What comes next

1. **Multi-segment pool** — the tier resolver sums free space across roots and
   holds `RESERVE_BYTES` per volume (PR #1), but the pool is still a single file
   on a single volume, so nothing is gained on disk yet.
2. **Process-level pool locking test** — existing tests prove a *thread*
   releases `Local\DPU.pool.lock`; none proves two *processes* cannot corrupt
   `pool.vram`.
3. **Run the benchmark in CI.** Every number above is from one run on one
   machine. Nothing re-measures it, so the next edit can quietly make it stale
   the way the hardcoded `0.08` did — as the probe count already did once.

Resolved since this list was first written: the hardcoded `0.08` ratio (PR #3).

## Running things

No Vulkan SDK is required; Windows ships a loader. Always use a throwaway
cache — `dpu/.zig-cache` is known to corrupt:

```
cd dpu
TMPD=$(mktemp -d)
/a/toolchain/zig/zig.exe build check --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all
/a/toolchain/zig/zig.exe build probe --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all
/a/toolchain/zig/zig.exe build bench --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all
```

`zig build probe` sets `VK_ADD_DRIVER_FILES` itself and runs the probe. Nothing
is installed system-wide, so there is nothing to clean up. To run the binary
directly, point `VK_ADD_DRIVER_FILES` at `zig-out/bin/vk_icd.json`.

The probe exits non-zero if any check fails and prints one
`PROBE_SUMMARY: total=.. passed=.. failed=..` line last, so a failing run
reports everything rather than stopping at the first failure.

The engine binds `127.0.0.1:8787` and serves **one connection at a time**, so
issue requests sequentially or they will queue behind each other. `P:\` is
optional: `Pool.init` failure degrades telemetry to `"buffer":null` and the
server still starts.

`zig build bench` **destroys `P:\DPU\pool.vram`** — it sweeps an 8 GiB working
set through it and unlinks the file afterwards. The engine recreates it on next
start, but expect to recreate it before running the engine again.