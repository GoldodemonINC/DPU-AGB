# DPU — working context

A GPU that runs on disk. A `pool.vram` file on `P:\` presented to Vulkan
applications as a discrete GPU through a user-mode installable client driver.

## Status at this commit

`zig build check` — 71/71 tests, exit 0, `zig fmt --check` clean.

`zig build probe` — **45/45, exit 0**, `PROBE_SUMMARY: total=45 passed=45
failed=0 result=PASS`, closing with `RESULT: PASS -- the DPU heap carries real
bytes on disk`.

Until now the probe had never been executed. Every runtime claim about the
driver was unsubstantiated; this is the first run, and it is green.

## What changed in this commit

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
| After reserving the clobbered prefix | **`total=45 passed=45 failed=0`, exit 0** |

The third failure only appeared once recording genuinely started working, which
is why the object had to be made coherent rather than merely readable.

## What comes next

1. **Multi-segment pool** — the tier resolver already sums free space across
   roots and holds `RESERVE_BYTES` per volume (PR #1), but the pool is still a
   single file on a single volume, so nothing is gained on disk yet.
2. **Process-level pool locking test** — the existing tests prove a *thread*
   releases `Local\DPU.pool.lock`; no test yet proves two *processes* cannot
   corrupt `pool.vram`.
3. **The bench's hardcoded `67.3 / 0.08` ratio** — a fabricated denominator
   sits next to a measured number in `bench.zig`, and README's "840× worse than
   RAM" derives from it.

## Running the probe

No Vulkan SDK is required; Windows ships a loader.

```
cd dpu
TMPD=$(mktemp -d)
/a/toolchain/zig/zig.exe build probe --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all
```

`zig build probe` sets `VK_ADD_DRIVER_FILES` itself and runs the probe.
Nothing is installed system-wide, so there is nothing to clean up. To run the
binary directly, point `VK_ADD_DRIVER_FILES` at `zig-out/bin/vk_icd.json`.

The probe exits non-zero if any check fails and prints one
`PROBE_SUMMARY: total=.. passed=.. failed=..` line last, so a failing run
reports everything rather than stopping at the first failure.
