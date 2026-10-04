# Serving llama.cpp's weights out of the DPU pool

Route 1 of the two-ideas diagram: `'DPU'` ⇄ `Llama.cpp` → 8B model → 10-40 TPS.
This directory is the measured attempt at it, and the measurement did not come
out the way the diagram assumes. Both the patch and the evidence are here so
the next person does not have to repeat the experiment to learn the same thing.

## What is here

| file | what it is |
| --- | --- |
| `0001-hooks.patch` | the two edits to upstream ggml: call the pool first in `ggml_aligned_malloc`, claim the pointer in `ggml_aligned_free`, and compile the new file |
| `0002-allocator.patch` | adds `ggml-dpu.c` / `ggml-dpu.h`, the allocator itself |
| `ggml-dpu.c`, `ggml-dpu.h` | the same two files, readable without applying a diff |
| `dputest.c` | a standalone correctness test for the allocator |
| `poolspeed.c` | isolates the pool mapping from llama.cpp to locate slowness |

Upstream revision tested: `ggml-org/llama.cpp` at `0504396`, ggml 0.25.3.
`llama-cli` was renamed upstream; the executable target is `llama-completion`
and `llama-bench` has no `--no-mmap` any more — `--load-mode none` replaced it.

## The idea

Every tensor the CPU backend does not memory-map comes from
`ggml_aligned_malloc`, which on Windows is `_aligned_malloc`: private, anonymous
memory, charged to the process commit and never reclaimable. This box has
**7.79 GiB of RAM**; an 8B Q4_K_M model is ~4.9 GiB of weights before a KV
cache exists. DPU already maintains a heap of exactly the right shape at
`P:\DPU\pool.vram` — a sparse file sized by the engine's granted tier, guarded by
the same `Local\DPU.pool.lock` the engine takes.

So: map the pool instead of calling the allocator, and the same bytes become
file-backed. Opt in with `GGML_DPU_POOL=1`. Off by default, and every failure
mode — absent, locked by another process, exhausted, too small — falls back to
`malloc` rather than failing the allocation.

## Building it

No Vulkan SDK is needed for any of this.

```sh
git clone --depth 1 https://github.com/ggml-org/llama.cpp
cd llama.cpp
patch -p1 < .../0001-hooks.patch
patch -p1 < .../0002-allocator.patch

cmake -B build -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=A:/toolchain/mingw64/bin/gcc.exe \
  -DCMAKE_CXX_COMPILER=A:/toolchain/mingw64/bin/g++.exe \
  -DCMAKE_MAKE_PROGRAM=A:/toolchain/bin/make.exe \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF
cmake --build build --target llama-completion -j 4

# MinGW builds need their runtime next to the exe or it exits 127 with no output.
cp /a/toolchain/mingw64/bin/lib{gcc_s_seh-1,gomp-1,stdc++-6,winpthread-1}.dll build/bin/
```

```sh
# correctness, both modes
GGML_DPU_POOL=1 ./dputest      # 14/14
./dputest                      # pool off: declines everything, by design
```

## What was measured

All on this machine: Intel Core i3-1115G4, 4 threads, 7.79 GiB RAM, Intel UHD
iGPU, `P:` an NVMe volume holding the pool. Both cases are the same command
with only `GGML_DPU_POOL` differing.

**`gemma-2-9b-it` Q4_K_M (5.76 GB) — the "8B model" from the diagram:**

| | peak commit | load | generation | exit |
| --- | --- | --- | --- | --- |
| DPU off | 8246 MB | 31 s | 2.51 tok/s | 0 |
| DPU on | 6562 MB | **32989 s** | 0.14 tok/s | 0 |

**`Llama-3.2-3B-Instruct` Q4_K_M (1.87 GB), same test:**

| | peak commit | peak working set | load | generation | exit |
| --- | --- | --- | --- | --- | --- |
| DPU off | 8353 MB | 5149 MB | 12 s | 7.54 tok/s | 0 |
| DPU on | 7734 MB | 5531 MB | 11.9 s | 2.63 tok/s | 0 |

The mechanism works, and it is not fast:

- the pool engaged (`ggml-dpu: pool P:\DPU\pool.vram, tier 8.00 GiB`), and
  `GGML_DPU_STATS=1` shows the **one** large allocation — the weight buffer —
  served from the pool, with all 1246 graph temporaries correctly below the
  4 MiB threshold and served by `malloc`;
- the allocator is not the slow part: `poolspeed` writes **884 MB/s** through a
  2 GiB pool mapping and reads it back at **50 GB/s** warm, against 949 MB/s for
  a plain `dd` write to `P:` — the device is not the bottleneck;
- the pool file stays sparse: 8 GiB logical, **0.00 GB allocated** after the
  allocator test.

And it does not buy the thing it was for. Peak commit fell by **619 MB on the
3B and 1684 MB on the 9B** — not the 1.87 GB / 5.76 GB of weights — while
generation went **2.87x slower**, and at 9B the load collapsed from 31 s to
**9.2 hours**.

## Why, which is the part worth keeping

"File-backed" does not mean "free". A mapping of the pool is charged to the
page cache, not to commit — that part is real and the counters show it — but
the pages are still resident RAM while the process is touching them, and
generating a token re-reads essentially the whole weight set. At 9B that is
~5.76 GB of reads per token on a machine with 7.79 GiB of RAM. The pool cannot
act as a cache for a working set that large, so the demand does not go away; it
just moves from a predictable cost into reclaim-then-re-read, which is the 9.2
hours.

So the honest conclusion for route 1: **holding a model's weights in the disk
pool is the wrong lever.** DPU's pool is a capacity tool, and the things worth
putting in it are things that are *not* re-read every token. The 10-40 TPS
target in the diagram is gated by memory bandwidth and by the four CPU cores
here, not by where the bytes are filed — a plain CPU-only llama.cpp with no DPU
at all already does 7.54 tok/s on the 3B and 2.51 tok/s on the 9B, which is
within a small factor of the target and needs nothing from this project.

The allocator is kept because the measurement is reusable and the test is
real, not because it is the way to an 8B model. A pool that a compute path can
address is the interesting version of this idea, and that is the compute path
the ICD does not have: of the fourteen entry points a Vulkan compute client
needs, `vkCreateShaderModule` and `vkCreateComputePipelines` are present and
refused, and the other twelve — including `vkCmdDispatch`, every descriptor-set
entry point and `vkCreatePipelineLayout` — are absent from
`src/backend/icd/icd.zig` entirely.