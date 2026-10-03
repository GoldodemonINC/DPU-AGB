# DPU — working context

A GPU that runs on disk. A `pool.vram` file on `P:\` presented to Vulkan
applications as a discrete GPU through a user-mode installable client driver.

## Status at this commit

`zig build check` — **88/88 tests**, exit 0, `zig fmt --check` clean.

`zig build probe` — **50/50, exit 0**, closing with
`PROBE_SUMMARY: total=50 passed=50 failed=0 result=PASS` and
`RESULT: PASS -- the DPU heap carries real bytes on disk`.

Both numbers were measured on this machine, not carried forward. An earlier copy
of this file claimed the probe was 45/45; that was stale, and a number nobody
re-ran is worse than no number.

## Repository state

`main` history, oldest first. The first four rows are direct commits; every row
with a PR number is a squash merge of that pull request:

| Commit | PR | Subject |
|---|---|---|
| `03815a4` | — | Initial commit: DPU disk-backed VRAM engine and Vulkan ICD |
| `b0d61f3` | — | pool lock cross-process, probe exits honestly |
| `858e41f` | — | hand back freed pool bytes, fix validated handles |
| `4dfc254` | — | the copy path reports failure instead of wrong data |
| `bf3dfca` | #1 | Hold the tier reserve per volume, not per pool |
| `4b69d2a` | #2 | Make the loader stop corrupting command buffers, and run the probe |
| `5fce630` | #3 | Stop dividing a measurement by a hardcoded constant |
| `2225369` | #4 | Let the router pick the status, so a miss cannot answer 200 |

Two of those merges were not requested by the automation in flight:

- **PR #1** merged at 2026-10-03T18:06:35Z by the `Goldodemon-Automation`
  credential while a task was mid-run on another branch.
- **PR #2** was intended to be *auto*-merged, not merged immediately. The call
  was `PUT /pulls/2/merge` with `{"auto_merge": true, "merge_method": "squash"}`.
  GitHub only honours that flag when the repository has **"Allow auto-merge"**
  enabled; it does not, so the parameter was ignored and the endpoint merged on
  the spot. The token in the OS credential store also cannot read or patch
  repository settings — `GET /repos/.../DPU-AGB` returns **404** — so the setting
  could not be enabled programmatically first.

Worth recording because that failure mode is quiet and irreversible: the request
returns HTTP 200 and a merge SHA, and nothing in the response distinguishes
"scheduled" from "already merged". Anything scripting this should re-read the
PR afterwards and check `auto_merge`, rather than trusting the 200. Squash
commits are attributed to the PR author, which is why they read as human
commits; `merged_by` is the automation account.

Because `main` moved under PRs #3 and #4, both went dirty — each had written
its own `Context.md` from scratch, so it was an add/add conflict on that one
file. The code in each branch was unaffected and verified byte-identical across
the rebase; both conflicts were resolved by union.

## PR #2: four command entry points had a phantom leading parameter

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

**The sentinel was read from a word the loader owns.** `asCommandPool`,
`asCommandBuffer` and `asFence` validated a magic `u32` at offset 0, but the
loader writes its own dispatch pointer over the first 8 bytes of a dispatchable
object — so the check read a pointer and rejected handles the driver had just
created. Validation now goes through `@offsetOf(T, "sentinel")`.

**`CommandBuffer` is now an `extern struct` with a reserved first slot.** Fixing
the sentinel alone was not enough: `commands.ptr` also lived at offset 0 and was
being destroyed by the same loader write. The struct reserves that word
(`loader_slot`) and keeps no live state in it.

### The loader/ICD handle contract, as measured

Not from the spec — measured on this machine, with the Windows loader at
`System32/vulkan-1.dll` (1.3.301) and ICD interface version 4:

- The loader allocates **no** separate wrapper. The address the ICD returns from
  `vkAllocateCommandBuffers` is the address the loader hands back.
- The loader **writes its dispatch pointer over the first 8 bytes** of that
  object. Anything live in that prefix is destroyed.
- `CommandPool` survived because its sentinel is 4 bytes and the write landed
  elsewhere; `CommandBuffer` did not, because its `commands` slice started at 0.

### Zig 0.16 does not lay out structs in declaration order

This is the trap that cost the most time. For
`{sentinel: u32, recording: bool, commands: []Command, count, capacity, err}`,
`@offsetOf` reports:

```
sentinel=32  recording=44  commands=0  count=16  capacity=24  size=48
```

`commands` is at offset **0** even though `sentinel` is written first — the
compiler packs by alignment. Any offset derived by reading the source, or by
assuming C-style ordering, is wrong.

### Probe progression

| State | Probe result |
|---|---|
| First ever run | `total=44 passed=36 failed=8`, exit 1 — `BAD cmdbuf handle` on every command |
| After the `@offsetOf` sentinel fix | `passed=41 failed=3`, exit 1 — loader rejected the handle at `vkEndCommandBuffer` |
| After the four signature fixes | unchanged — `vkCmdWriteBuffer` recorded, same VUID |
| After reserving the clobbered prefix | `total=45 passed=45 failed=0`, exit 0 |
| After adding `vkCmdFillBuffer` coverage | **`total=50 passed=50 failed=0`, exit 0** |

The third failure only appeared once recording genuinely started working, which
is why the object had to be made coherent rather than merely readable.

## PR #3: the benchmark's ratio is now measured on both sides

`bench.zig` printed `67.3 / 0.08`. The first half was a real uncached
random-read latency; the second was a literal that nothing in this project ever
measured, and the printed multiplier was that literal divided by its own
partner. README repeated the result as "roughly 840x worse than RAM", making a
fabricated number the project's headline performance claim.

`measureRam` now measures a counterpart instead of assuming one: a dependent
pointer chase through a 256 MiB buffer, so every step misses cache and the
prefetcher has nothing to work with. That is the same quantity the device half
measures — random access latency — rather than one borrowed from a spec sheet.

```
system RAM memcpy             2108 MB/s   (256 MiB, sequential)
system RAM random access     0.587 us     (dependent loads, 256 MiB set)
pool random access          2370.1 us     (uncached 4 KiB reads, 8 GiB set)
=> about 4036x
```

**The honest ratio is 4036x, not 840x.** The old `0.08` understated RAM
random-access latency by roughly 7x, so the published gap was wrong in the
*optimistic* direction by about the same factor — the pool is slower than RAM by
nearly five times what the README claimed.

Two honest caveats the banner states rather than hides:

- The halves are not perfectly like for like. A dependent-load pointer chase and
  an uncached 4 KiB sector read are different operations; the ratio is a useful
  scale, not a precise constant.
- The pool figure is the 8 GiB row of a sweep. The smaller rows measure the RAID
  controller's cache, not the device, which is why the largest row is quoted.

## PR #4: the dashboard was answering 200 OK for a missing route

`serveOnce` dispatched on **path alone**, in an `if/else` chain whose last arm
was the catch-all. Nothing said what the catch-all should return, and the helper
it called was:

```zig
fn respond404(client: c.SOCKET) void {
    respond200(client, "text/plain", "not found\n");
}

fn respond200(client: c.SOCKET, mime: []const u8, body: []const u8) void {
    // ... "HTTP/1.1 200 OK\r\n" ...
}
```

`respond404` composed its body and then delegated to a function that hardcoded
`200 OK`. The body was honest; the status line was not.

**The verb was never read off the request line either**, so a route's verb was
advisory. `GET /api/control` answered `{"ok":true}` having written nothing — an
ack for a write it never performed, since `parseParam` reads the body and a GET
has none.

`route(path, method)` is now a pure function returning a tagged `Route`:

- No handler holds a status, so there is nothing for one to forget.
- `respond` is the only function that writes a status line, and takes the status
  as an argument.
- There is no path through `route` that matches nothing and returns 200, because
  the final arm *is* the 404 and nothing follows it to fall into.

The same argument applies to *which paths exist*. `route` consulted
`isAssetPath` while `serveAsset` re-listed the same paths in an `if/else` chain
that ended in a catch-all `else` serving `style.css` for anything it did not
match — so adding a path to the router would have shipped a stylesheet under a
200. Both now read one `ASSETS` table of `{path, mime, body}`:

```
/            text/html; charset=utf-8             5744 bytes  sha256 01ba6e1e
/index.html  text/html; charset=utf-8             5744 bytes  sha256 01ba6e1e
/app.js      application/javascript; charset=utf-8 17926 bytes sha256 c55403c1
/style.css   text/css; charset=utf-8              12126 bytes sha256 0f7f8a3e
```

405 carries a correct `Allow` header, as RFC 9110 requires. HEAD is accepted
wherever GET is.

This is **observable to anything already consuming the server.** A dashboard, a
health check or a proxy that branches on `200` vs `4xx` will start seeing 404
and 405 from paths and verbs that previously succeeded — including paths it
believed existed.

### Verified over real sockets, before and after

Built a binary from `main` and one from the branch, ran both the way the project
starts them, and drove them with raw sockets.

```
BEFORE (main @ bf3dfca)
GET /nope                    -> 200 OK  Content-Length: 9     not found
GET /favicon.ico             -> 200 OK  Content-Length: 9     not found
DELETE /                     -> 200 OK  Content-Length: 5744  <the entire dashboard>
PUT /api/telemetry           -> 200 OK  Content-Length: 4939  <live telemetry>
GET /api/control             -> 200 OK  {"ok":true}          <wrote nothing>

AFTER — 17 cases, every Content-Length matching the actual body byte count
GET    /                      200 OK                   5744/5744
GET    /index.html            200 OK                   5744/5744
GET    /style.css             200 OK                   12126/12126
GET    /app.js                200 OK                   17926/17926
GET    /api/telemetry         200 OK                   (live)
GET    /nope                  404 Not Found            10/10
GET    /favicon.ico           404 Not Found            10/10
GET    /app.js.map            404 Not Found            10/10
GET    /API/telemetry         404 Not Found            10/10
GET    /api/telemetry/        404 Not Found            10/10
GET    /api/control           405  Allow: POST
POST   /api/control           200 OK                   {"ok":true}
POST   /api/telemetry         405  Allow: GET, HEAD
PUT    /api/telemetry         405  Allow: GET, HEAD
DELETE /                      405  Allow: GET, HEAD
HEAD   /                      200 OK                   5744/5744
BREW   /api/telemetry         405  Allow: GET, HEAD
```

The write path was re-checked **for its effect, not just its status**:
`POST power=LOW` moved telemetry to `LOW`, `POST power=MAX&split=0` moved it to
`MAX` with `split:false`.

### Two known gaps, deliberately not fixed here

1. **`HEAD` sends a body.** `HEAD /` returns 200 with `Content-Length: 5744`
   *and* all 5744 bytes; RFC 9110 forbids a body on a HEAD response. HEAD is
   reachable — it is a real request, not a theoretical one. Splitting GET and
   HEAD in `respond` is a larger change than fixing the status code, so it is
   left undone rather than half-done.
2. **A malformed request line answers 200** — fixed since this was written; see
   below. Kept here as the record of what it was.

## A malformed request line was answered 200 with the whole dashboard

`extractMethod` and `extractPath` were two functions that each supplied a default:
the method defaulted to `"GET"` and the path to `"/"`. A default is a guess, and a
guess about a request line is a guess about what the client asked for.

Measured over a socket against a binary built from `main`:

```
A blank request line          -> 200 OK   body[5744] <!DOCTYPE html>...
B bare GET, no path           -> 200 OK   body[5744] <!DOCTYPE html>...
C method + space, no path     -> 200 OK   body[5744] <!DOCTYPE html>...
D spaces only                 -> 200 OK   body[5744] <!DOCTYPE html>...
F single LF                   -> 200 OK   body[5744] <!DOCTYPE html>...
E tab-separated request line  -> 405 Method Not Allowed, Allow: GET, HEAD
```

The hole was wider than the blank line that was reported. Five shapes resolved to
`GET /` and served the index page with a 200, and a sixth produced something
different and equally wrong: a tab-separated line tokenises to a single token, so
that whole line became the *method*, and the server answered a verb negotiation
for a request that was never valid.

`parseRequestLine` now returns `?RequestLine` — no method, no target, or a method
that is not an RFC 9110 token is `null` — and `routeRequest` turns that into a
400 before any route is consulted. The status is chosen by the router, like 404
and 405, because the alternative was a handler having to remember to reject it.

The token check is what makes the last case work: counting tokens cannot tell
"the client forgot the method" from "the method is an odd word", because
`/ HTTP/1.1` has two tokens. That line is malformed, but it parses as a request
for the literal path `HTTP/1.1` and would answer 404. RFC 9110 defines
`method = token`, and a token cannot contain a separator, so the method is
validated against `tchar`.

After:

```
A blank request line          -> 400 Bad Request  body[12] b'bad request\n'
B bare GET, no path           -> 400 Bad Request  body[12] b'bad request\n'
C method + space, no path     -> 400 Bad Request  body[12] b'bad request\n'
D spaces only                 -> 400 Bad Request  body[12] b'bad request\n'
E tab-separated request line  -> 400 Bad Request  body[12] b'bad request\n'
F single LF                   -> 400 Bad Request  body[12] b'bad request\n'

G valid GET /                 -> 200 OK  5744 bytes
I valid GET /api/telemetry    -> 200 OK  live JSON
J valid POST /api/control     -> 200 OK  {"ok":true}
K valid HEAD /                -> 200 OK  unchanged
L leading space, still valid  -> 200 OK
```

The 400 body is 12 bytes and does not leak the dashboard; that is asserted in a
test, not just observed here. `BREW` still answers 405 because it is a valid token
and simply is not a method this server serves.

### A gate hole this work hit

`zig build check` does **not** build the server binary — the step never compiles
`main.zig`. A `switch` in `server.zig` that the test root does not reach passed
`check` at 88/88 and then failed `zig build` with `expected optional type, found
'[]const u8'`. Making `check_step` depend on the install step would close it.
The same reasoning applies to test discovery: `zig build test` only finds tests
in the root module and its relative imports, so `server.zig`'s tests needed
`backend_test.zig` to pull the file in and `build.zig` to give the test root the
same `web_assets` import the exe has. Without both, ten tests would have been
dead code behind a green gate.

## What comes next

1. **Make `check` build the executable** — the gate currently passes on code
   that cannot link into a server. Found the hard way on PR #4.
2. **Send no body for HEAD.** `HEAD /` returns 200 with a 5744-byte body, which
   RFC 9110 forbids. Known and confirmed reachable; deliberately kept separate
   from the malformed-request fix rather than bundled with it.
3. **Multi-segment pool** — the tier resolver sums free space across roots and
   holds `RESERVE_BYTES` per volume (PR #1), but the pool is still a single file
   on a single volume, so nothing is gained on disk yet.
4. **Process-level pool locking test** — existing tests prove a *thread* releases
   `Local\DPU.pool.lock`; none proves two *processes* cannot corrupt `pool.vram`.
5. **Run the benchmark in CI.** Every number above is from one run on one
   machine. Nothing re-measures it, so the next edit can quietly make it stale
   the way the hardcoded `0.08` did — as the probe count already did once.

Resolved since this list was first written: the hardcoded `0.08` ratio (PR #3),
and 400 for a malformed request line (this branch).

## Running things

No Vulkan SDK is required; Windows ships a loader. Always use a throwaway cache —
`dpu/.zig-cache` is known to corrupt:

```
cd dpu
TMPD=$(mktemp -d)
/a/toolchain/zig/zig.exe build check --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all
/a/toolchain/zig/zig.exe build probe --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all
/a/toolchain/zig/zig.exe build bench --cache-dir "$TMPD/l" --global-cache-dir "$TMPD/g" --summary all
```

`zig build probe` sets `VK_ADD_DRIVER_FILES` itself and runs the probe. Nothing
is installed system-wide, so there is nothing to clean up. To run the binary
directly, point `VK_ADD_DRIVER_FILES` at `zig-out/bin/vk_icd.json`. The probe
exits non-zero if any check fails and prints one
`PROBE_SUMMARY: total=.. passed=.. failed=..` line last, so a failing run reports
everything rather than stopping at the first failure.

The engine binds `127.0.0.1:8787` and serves **one connection at a time**, so
issue requests sequentially or they will queue behind each other. `P:\` is
optional: `Pool.init` failure degrades telemetry to `"buffer":null` and the
server still starts.

`zig build bench` **destroys `P:\DPU\pool.vram`** — it sweeps an 8 GiB working
set through it and unlinks the file afterwards. The engine recreates it on next
start, but expect to recreate it before running the engine again.