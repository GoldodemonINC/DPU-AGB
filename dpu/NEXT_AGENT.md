# Self-prompt for the next DPU agent

Paste the block below as the prompt for the next agent (or hand it to an
auto-prompter that re-issues it after each iteration). It is written to survive
a cold start with no conversation history.

---

```
You are continuing work on DPU, a disk-backed virtual VRAM engine plus a
user-mode Vulkan ICD. Repo: C:\Users\goldodemon\Desktop\Projects\APAGE, and the
project itself lives in the dpu\ subdirectory. Zig 0.16.0 is at
A:\toolchain\zig\zig.exe, target x86_64-windows-gnu. There is no Vulkan SDK and
no admin rights on this machine.

FIRST, ORIENT YOURSELF. Read dpu/README.md, dpu/build.zig and dpu/src/backend/tiers.zig
before changing anything. The build is the spec: build.zig explains, in
comments, why the pieces are shaped the way they are.

HOW TO BUILD. A cold build is about 6 minutes, and the project's own cache in
dpu/.zig-cache is known to corrupt, so always use a throwaway cache:

  cd dpu
  TMPD=$(mktemp -d)
  /a/toolchain/zig/zig.exe build check --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all
  /a/toolchain/zig/zig.exe build --release=safe icd --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all
  /a/toolchain/zig/zig.exe build probe --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all
  /a/toolchain/zig/zig.exe build run --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all

`zig build check` is the gate: it runs `zig fmt --check`, the backend suite, the
tiers suite, the ICD suite and the Vulkan ABI assertions. It must end at exit
status 0. `zig build test` needs drive P:\ to exist because the block-device
tests use the scratch directory P:\DPU-selftest. It exists. Do not delete
anything else on P:\.

HARD RULES.
- Never report a check you did not run, and never describe a failed or unrun
  check as passing. Paste the real exit status of every command.
- Do not commit, push, branch or deploy unless explicitly asked. Leave the
  working tree dirty for review.
- Do not run `zig fmt` across the whole tree, and do not edit files merely to
  satisfy the formatter -- fix the formatter complaint in the file that has it.
- Do not weaken, skip or delete a test to make a build go green. If a real
  behaviour is broken, fix the behaviour or report it as broken.
- No subagent is running right now. The two that owned probe.zig, blockdev.zig,
  backend_test.zig, web/index.html and web/app.js have both finished and their
  work is in the tree, so you own every file. Re-read this list rather than
  trusting it: ownership only existed to keep two lanes off each other's files
  while they were live.
- Keep the set of named shared modules (win, tiers, blockdev, alloc) intact.
  The engine and the driver must reach the same pool file through the same
  block semantics; duplicating a module so the two can drift is the one
  architectural mistake this project cannot absorb.
- tiers.RESERVE_BYTES (2 GiB) is the single reserve constant and the tier
  ladder LADDER_GIB = {2,4,6,8,12,16,24} is the policy. Do not fork either.

CURRENT STATE. HEAD is 1266077 on master with a clean commit history and a
dirty tree: 18 modified files plus this untracked prompt. Nothing is
committed -- the tree is the review artifact.

Two things an earlier version of this file got wrong, both now corrected:
the release ICD build is fixed, and the suite is 71 tests, not 68. The test
count is a static inventory of `test` declarations (31 backend + 13 tiers +
20 planner + 7 Vulkan ABI), NOT a passing run -- see below.

LANDED SINCE, all uncommitted and all unverified by a gate on the current
tree:

  Release ICD build: FIXED, no longer failing. Zig 0.16's translate-c emitted
  `extern_local_wcscat_s`/`extern_local_wcscpy_s` inside MinGW's fortified
  `wcscat`/`wcscpy` inlines without the `_ = &...;` marker it adds for the
  sibling locals, so they read as unused local constants. The workaround is
  `win_mod.addCMacro("_FORTIFY_SOURCE", "0")` at build.zig:105, applied to the
  cimporting module and documented in the comment block above it. It does not
  remove fortification from hand-written C -- there is none in this tree -- it
  stops MinGW's headers generating the broken inline. `zig-out/bin/dpu_icd.dll`
  exists, timestamped from a build that completed.

  Cross-process pool lock: DONE. `blockdev.zig` has `acquire`/`release` on
  `Local\DPU.pool.lock` with a single `WaitForSingleObject` call site, a
  30 s timeout reported as a failure rather than a silent proceed, and
  `defer release()` on every mutating path including the read-modify-write.
  Three tests back it, including one that proves a peer can take the lock
  after a transfer. This is queue item 5 and it is finished.

  Dashboard honesty pass: DONE. The SYSTEM panel was deleted because the
  server sends none of it, the tier buttons now carry the server's exact
  `MAX`/`xHIGH`/`LOW` casing, and every seeded default was replaced with `--`.

WHAT IS NOT GREEN, or not verified. Treat all four as open:

  1. No gate has been run against the current tree. The last recorded
     `zig build check` exit 0 was 71/71, but the dashboard edits landed after
     it. Run the gate before you trust any of the above, and treat its exit
     status as the first fact of your turn.

  2. The probe has still never been executed. `dpu_probe.exe` was built and
     `vk_icd.json` was written, but no run's output was ever captured. Every
     runtime claim about the driver is still unsubstantiated.

  3. `server.zig:364` -- `respond404` delegates to `respond200`, which
     hardcodes `HTTP/1.1 200 OK`. A missing route answers 200, so the client's
     `if (!res.ok)` guard can never fire. One line to fix, and nothing owns
     that file now.

  4. `bench.zig:112` prints a hardcoded `67.3 / 0.08` ratio directly beside
     the *measured* `device_random_us`, so a real number sits next to a
     fabricated one with nothing marking which is which. The 0.08 denominator
     is a RAM random-access latency nothing in this tree measures. README's
     "roughly 840x worse than RAM" is derived from that same literal, so
     fixing the bench means fixing that sentence too.

WORK QUEUE, in priority order. Do exactly one item per iteration, verify it,
report it, then take the next one.

0. Run `zig build check` and paste its real exit status. Everything below
   assumes a green gate, and no gate has covered the current tree.

1. Run `zig build probe` for real, unprefixed, and report what the actual
   Vulkan loader says. The binary has been built and never run, so every
   runtime claim about the driver is currently unsubstantiated. Acceptance: a
   report containing the probe's real output and exit status, including what
   it says about the heap the engine published.

2. Phase 3, the LARGER work. The pool can live on two volumes: P:\ and the
   nested volume mounted as P:\D drive (13.79 GB free). Combined free space is
   34.69 GB, so the MAX ladder rung of 24 GiB plus the 2 GiB reserve fits
   unclamped -- but only if the tier resolver sums both roots. Make the
   resolver see total free space across both roots and account the reserve
   per volume, with tests. Striping two partitions of the same physical NVMe
   buys capacity, not bandwidth; do not claim a speedup.

3. Phase 2 performance, each item measured before and after: I/O queue depth
   1 -> N with overlapped operations in the copy path; sequential readahead;
   an async submit worker instead of doing the copy inline in
   `vkQueueSubmit`; telemetry handle caching; one QPC clock helper instead of
   several. Do not claim any of these without a number from
   `zig build bench`.

4. Substantiate or delete the bench's hardcoded 67.3/0.08 ratio, and correct
   the README's "roughly 840x worse than RAM", which is derived from that same
   literal.

5. ~~Cross-process pool locking.~~ DONE in blockdev.zig, with tests. The
   remaining half is to prove two *processes* cannot corrupt the pool file --
   the tests cover threads, not processes.

LOOP PROTOCOL. If you are being re-issued this prompt: pick the highest-priority
item that is not yet done by reading the code and the tree, not by trusting this
list. Report in at most six lines: what you changed, the exact verification
command and its exit status, the measured result if there is one, and what you
could not verify. If an item is blocked, say what blocks it and move to the next
one instead of guessing. If everything in the queue is done, say so and stop --
do not invent new scope.
```

---

## Notes on using this

- Item 0 is new and comes first: nothing else is trustworthy until a gate has
  run against the tree you are actually editing. Then item 1, which is small
  and unblocks every runtime claim in the project.
- The probe now exits non-zero when any check fails and prints one
  `PROBE_SUMMARY: total=.. passed=.. failed=..` line as its last output, so a
  failing run reports everything rather than stopping at the first check.
- Items 2 and 3 need `zig build bench` to be runnable, which it currently is
  not verified to be. Treat item 3 as blocked until item 2's capacity work has
  proven the pool actually spans two volumes.
- The six files the prompt used to forbid were owned by two subagents that have
  both finished. The restriction is gone; do not reintroduce it.
- `dpu/NEXT_AGENT.md` itself is not part of the build. Delete it when the
  queue is empty.
