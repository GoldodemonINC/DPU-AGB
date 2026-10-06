# DPU — working context

A GPU that runs on disk. A `pool.vram` file on `P:\` presented to Vulkan
applications as a discrete GPU through a user-mode installable client driver.

## Status at this commit

`zig build check` — **138/138 tests**, exit 0, `zig fmt --check` clean. The gate
also builds `dpu.exe`, so a green run now means the shipping binary compiles.

`zig build probe` — **55/55, exit 0**, closing with
`PROBE_SUMMARY: total=55 passed=55 failed=0 result=PASS` and
`RESULT: PASS -- the DPU heap carries real bytes on disk`, and with **no loader
warnings at all** under `VK_LOADER_DEBUG=error,warn`.

Every number here was measured on this machine for this tree. An earlier copy of
this file claimed the probe was 45/45; that was stale, and a number nobody re-ran
is worse than no number.

## Repository state

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
| `caa8ab6` | — | Correct the merge-history table in Context.md |
| `08d78e5` | #8 | Union of #5 + #6 + #7, and `serveOnce` split into a pure router |
| `de4be68` | #9 | Split the wire suite into a harness and a contract |
| `d2ba409` | #10 | Split server.zig by what changes together, and move its tests out |

Every one of #5 to #10 is still open and none is merged. The stack is linear:

- **#5** `fix/check-must-build-the-exe` — the gate now builds the executable.
- **#6** `fix/malformed-request-400` — 400 for a request line that is not one.
- **#7** `fix/head-response-no-body` — no body on a HEAD response.
- **#8** `integrate/gate-400-and-head` — the union of those three, plus the
  router split that #9 and #10 both sit on.
- **#9** `test/wire-conformance` — the wire-level suite.
- **#10** `refactor/split-server` — the production server, split the same way.

This branch is stacked on all three of #8, #9 and #10 and cannot merge before
any of them. What it adds is small: a scratch pool for the wire suite, and the
one assertion that pool makes possible.

PR #1 merged at 2026-10-03T18:06:35Z by the `Goldodemon-Automation` credential
while a task was mid-run on another branch; PR #2 was merged immediately when
*auto*-merge was requested, because this repository does not have "Allow
auto-merge" enabled, so the API's `auto_merge` flag is ignored and the endpoint
merges on the spot. Both were unrequested and are treated as settled history.
Squash commits read as human commits; `merged_by` is the automation account.

## The HTTP surface

One request produces one `Decision`, and every response in this server comes from
it. That is the whole design, and it is what the three open PRs together restore.

```
raw bytes -> parseRequestLine -> Decision{ route, framing } -> handler -> respond
                  method         status              headers    headers only?
```

`parseRequestLine` is the only place that reads the method. `routeLine` is the
only place that picks a status. `framingFor` is the only place that decides
whether bytes follow the headers. All three read **one** parse, produced once in
`routeRequest`, so no two of them can disagree about the same request.

### Statuses the server can return

| Situation | Status | Body |
|---|---|---|
| Path matched, verb accepted | `200 OK` | the resource |
| Path matched, wrong verb | `405 Method Not Allowed` + `Allow` | `method not allowed` |
| No such path | `404 Not Found` | `not found` |
| Request line is not a request line | `400 Bad Request` | `bad request` |
| `HEAD`, any of the above | same status, **zero body bytes** | — |

Verified over raw sockets on the binary this gate builds:

```
GET    /                      200 OK                  CL=5744    body=5744
GET    /style.css             200 OK                  CL=12126   body=12126
GET    /app.js                200 OK                  CL=17926   body=17926
GET    /api/telemetry         200 OK                  CL=<live>  body=<live>
GET    /nope                  404 Not Found           CL=10      body=10
GET    /api/control           405 Allow: POST         CL=19      body=19
POST   /api/telemetry         405 Allow: GET, HEAD    CL=19      body=19
PUT    /api/telemetry         405 Allow: GET, HEAD    CL=19      body=19
DELETE /                      405 Allow: GET, HEAD    CL=19      body=19

blank request line            400 Bad Request         CL=12      body=12
bare GET, no target           400 Bad Request         CL=12      body=12
method + space, no target     400 Bad Request         CL=12      body=12
separators only               400 Bad Request         CL=12      body=12
tab-separated request line    400 Bad Request         CL=12      body=12
single LF                     400 Bad Request         CL=12      body=12

HEAD /                        200 OK                  CL=5744    body=0
HEAD /style.css               200 OK                  CL=12126   body=0
HEAD /app.js                  200 OK                  CL=17926   body=0
HEAD /nope                    404 Not Found           CL=10      body=0
```

Three things worth stating, because each was a real defect:

- **A miss is 404, not 200.** `respond404` used to build its body and delegate to
  `respond200`, which hardcoded `200 OK`. Verified on a binary from `main`:
  `GET /nope` answered `200 OK` with the body `not found`.
- **The verb is part of the route.** Dispatch was on path alone, so `DELETE /`
  returned the entire dashboard and `GET /api/control` answered `{"ok":true}`
  having written nothing — an ack for a write never performed.
- **A malformed request line is 400, not the dashboard.** `extractMethod` and
  `extractPath` each supplied a default (`"GET"` and `"/"`); a blank line
  resolved to `GET /` and returned 5744 bytes of HTML with a `200`. A
  tab-separated line was worse in a different way: it tokenises to one token, that
  token became the *method*, and the result was a `405` advertising
  `Allow: GET, HEAD` for a request that was never valid. The method is now
  validated against RFC 9110 `tchar`, because a token count cannot tell "the
  client forgot the method" from "the method is an odd word" — `/ HTTP/1.1` has
  two tokens.

`Content-Length` on a HEAD response is the length GET would have returned, not
zero. RFC 9110 says the headers SHOULD match; zeroing it would make the framing
consistent by making the header a lie. The proof that framing is right is not
the status line but the connection: a second request sent down the same socket
after `HEAD /` is refused (`ConnectionAbortedError`) because the server sent
`Connection: close` and closed. No phantom 5744 bytes arrive to be misread as a
second response.

## The HTTP surface is asserted on the wire, not just in the router

Two files, split by what changes together:

| File | Owns | Knows about |
|---|---|---|
| `src/wire_harness.zig` | binding, connecting, dispatching, reading; the server fixture and its single listener | sockets, HTTP framing. Nothing about DPU's routes. |
| `src/server_wire_test.zig` | the contract: which routes exist, what status each answers, what HEAD advertises | DPU. **No socket calls at all.** |

The second row is the one worth enforcing. `server_wire_test.zig` imports only
`std`, `wire_harness.zig` and `server/assets.zig`; a grep for `socket`, `recv`,
`send`, `connect`, `setsockopt` or `SOCKET` in it returns nothing. A reader
asking "what does this server promise?" should not have to read a `setsockopt`
to find out, and the split is only worth anything if it stays a fact rather
than a habit.

### The production server is split the same way

`server.zig` was 773 lines holding five things, and the audit graded it the
weakest dimension for it. It is now six modules, split by what changes
together rather than by size:

| Module | Lines | Owns | Changes when |
|---|---|---|---|
| `src/server.zig` | 191 | bind, accept, recv, dispatch, `respond` | the wire format or socket handling changes |
| `src/server/router.zig` | 183 | the pure decision: parse, route, framing | a route, status, verb rule or framing rule changes |
| `src/server/telemetry_doc.zig` | 159 | the telemetry document | the JSON shape changes |
| `src/server/context.zig` | 95 | `EngineState`, `PowerMode`, `Context` | the engine's modes change |
| `src/server/assets.zig` | 44 | the one asset table | the dashboard's files change |
| `src/server/router_test.zig` | 213 | the 21 unit tests | the router's contract changes |

Three decisions inside that layout are worth stating, because each was a real
choice rather than a default:

**`router.zig` is pure.** It reads request bytes and returns a value. No socket,
no clock, no engine state — and it imports no `win`. That is what makes the
three facts a request line implies provably consistent: they come from one parse
and travel together in a `Decision`, so there is no second read of the method
to drift.

**`Context` has its own module** rather than living in `server.zig`. The
telemetry document needs to read it, and leaving it in the transport module
would mean `server.zig` and `telemetry_doc.zig` import each other. A cycle is
legal in Zig and would have worked; it would also have left "who owns engine
state" ambiguous, which is the thing being fixed. One module, one owner, no
cycle.

**`respond` stayed in `server.zig`.** It is the only function that writes a
status line, so "what code does this return" keeps one answer. Splitting the
transport from the response format would have been tidier on paper and would
have put the status line's owner somewhere nobody looks.

The 21 unit tests moved to `router_test.zig` for the reason
`server_wire_test.zig` exists: a test that sits next to the code it checks
drifts toward restating it. `router.zig` is short enough to read in one go
*because* twenty-one assertions are not interleaved with it.

Callers get three verbs and never assemble a request by hand: `h.get(method,
path)`, `h.post(path, body)` — which computes `Content-Length` rather than
carrying a hand-counted literal beside it — and `h.raw(payload, label)` for the
request lines that are not well-formed. `h.dispatch` returns the socket when a
test needs to ask a question `readToEof` cannot answer.

The tests exist because of a specific, measured gap. The twenty-one tests in
`server.zig` call `route`, `routeRequest` and `framingFor` directly. None of them
opens a socket, formats a status line, or compares a `Content-Length` against
the bytes that actually followed it. So the assertion "a miss is 404" was, in
practice, the assertion "the router returns a Route whose status string says
404" — and the 200-for-a-miss bug shipped through all of them green, because
`respond404` built the correct body and then handed it to `respond200`, which
hardcoded the status line. Everything above the socket was correct and the
client still got `200 OK`.

What the suite asserts, and why each one is not a restatement of the code:

| Test | Claim |
|---|---|
| every route in the matrix answers the status it claims | all 16 rows of the external matrix, on the wire, each with `Content-Length` equal to the bytes that followed and no `Allow` on a 404 |
| the dashboard body on the wire is the dashboard | `/` really is the HTML document, and `/` and `/index.html` are byte-identical — so the lengths above belong to the right content |
| a request line that is not one is 400, and carries no dashboard | the six malformed shapes answer 400 with exactly `bad request\n` and no `<!DOCTYPE` anywhere in the body |
| a malformed line is 400 even when its target names no route | the malformed check runs before any route lookup: four shapes naming `/nope` answer the same 400 as the shapes that named nothing, so a client cannot use a malformed request to discover whether a path exists |
| valid request lines that look unusual still route | #6 did not over-reach: a line with no trailing CRLF, and one with a leading space, still serve |
| a control write is visible in the telemetry that follows it | POST `power=low`, then GET telemetry and find `"power":"LOW"` and `"prefetch":1` — the dashboard's own exchange, as a gate check rather than a demo |
| every asset answers HEAD with its GET length and no bytes | derived from `assets.ASSETS`, not restated — see below |
| HEAD on a miss is the miss, with no bytes | the same rule over paths that do not route: "no body" has to be a property of the response path, not of the asset table |
| only HEAD suppresses the body | the negative case: every other verb still gets its body, so the HEAD results are not an artefact of everything being empty |
| the telemetry document keeps every key the dashboard parses | the eight top-level keys and the three `engine` keys, read at their own JSON depth — every other assertion in the suite counts bytes, and a dropped field changes the length and nothing else |
| a HEAD connection carries no phantom body and is closed after it | reads the header block only, then requires **zero** further bytes, then requires a second request on that socket to get no response |

The last one is the one no other test can be. A framing regression is invisible
in the response: `respond` can advertise the right `Content-Length` and still
write the body, and the bytes only become visible to whoever reads the socket
next. The unit tests call `framingFor` and see a correct enum; only a socket can
see that 5744 bytes arrived anyway.

### Coverage is derived, not restated

The asset tests iterate `assets.ASSETS`, which is why `Asset` and `ASSETS` are
`pub`. The first version carried a written-out list of asset paths, and that is
a second thing that has to agree with the router — it would have stopped
agreeing the day somebody added an asset, and nothing would have said so. This
is the same failure mode #4 removed from the status code: two copies of one
fact, one of which is only exercised when someone remembers.

Derived coverage has the opposite hazard — an empty table makes the loop
vacuously true — so the asset test asserts `ASSETS.len >= 3` first.

The tables that *are* written out are genuinely test data: the matrix includes
paths that must **not** route, so it cannot be derived from the router.

### The `buffer` object is covered now, with a pool of the test's own

The `buffer` object is the largest part of the telemetry document and it is
`null` unless the capacity pool is open. The gate deliberately runs without one
so it never touches `P:\DPU\pool.vram`, so all sixteen of its fields — half the
document — were invisible to `zig build check` and were checked against a
running engine instead. That is a weaker guarantee wearing the same clothes as
a strong one, which is the exact defect #5 was opened for narrowed to one
object.

The harness now opens a scratch pool: `P:\DPU-wirepool`, created with
`CreateDirectoryW` after a `RemoveDirectoryW` so a crashed run cannot make every
later run fail, opened at `DEFAULT_CAPACITY` so `ceiling` reads the way it does
in production. Nothing is preallocated and the test never writes, so the file
stays at zero length — the 8 GiB is a limit, not a reservation — and `P:\` is
already a requirement the backend suite imposes, so this adds no environmental
demand the gate did not already carry.

Four things about it are deliberate:

**It fails loudly.** A telemetry document without a pool says `"buffer":null`.
Every field assertion would then be skipped and the test would report success
for having checked nothing. `error.BufferIsNull` is the opposite outcome, and it
prints the whole document so the cause is visible.

**It cannot share a file with the block device tests.** `P:\DPU-selftest` is
written to by `blockdev`'s own tests; a pool that shares one would race them.
`P:\DPU-wirepool` is separate, and `P:\DPU\pool.vram` is never opened.

**`Scratch.detach` unlinks the file and removes the directory.** `Pool` did not
surface `BlockDevice.destroy`, which already existed for exactly this and
documents why it is dangerous; reaching past `Pool` into `dev` was the only
alternative. Both are now behind one `detach` that a test cannot half-do.

**The caller supplies the storage.** The first version of `openScratchPool`
built the pool in a local, handed `h.ctx.pool` that local's address, and
returned the pool *by value*. The context was left pointing into a stack frame
that had already returned. Every one of the sixteen keys was still present —
a `Pool` read through a dead pointer serialises into a perfectly well-formed
object — and every value was garbage: `"ceiling":48`,
`"length":140699779393448`. The key assertions could not see it at all.

So the test also asserts five zero counters and the ceiling. With the storage
fixed the object reads:

```json
{"ceiling":8589934592,"length":0,"used":0,"allocated":0,"saturation":0.000,
 "readBps":0,"writeBps":0,"latencyMs":0.000,"reads":0,"writes":0,"sparse":true,
 "tierRequested":8589934592,"tierGranted":8589934592,"tierClamped":false,
 "tierStarved":false,"volumeFree":13284679680}
```

A stale frame cannot produce that. The value search is safe here in a way the
`total` search was not: every value inside `buffer` is a number or a bool, so
there is no nested object for a same-named key to hide behind.

### It costs one server, not ten

`serveOnce` blocks in `accept` until a client arrives, so driving it needs a
client on the other end. Binding a server per test would mean a `WSAStartup`, a
bind, a listen and a teardown per case — the slow way to learn nothing. Instead
the harness holds one server bound to port 0 (so it can never collide with a
running engine on 8787) and one `Context` for the life of the test binary, and
each exchange is: connect, write, call `serveOnce`, read to EOF. `serveOnce`
runs on the caller's own thread, so there is no server thread, no shutdown race
and no accept timeout — the ordering is the caller's.

Measured as the minimum of fourteen alternating runs against the same 52-test
binary with no wire suite:

| Build | Total | Suite cost |
|---|---|---|
| quiet machine, 52 tests | 819 ms | — |
| 61 tests, written-out asset list | 804 ms | below the noise floor |
| 62 tests, derived asset list | 793 ms | below the noise floor |

On an idle machine the suite is **not measurable** — all three builds land
inside each other's spread. Under load the same measurement gave 83–93 ms for
the 62-test build. Either way it is well under a tenth of a second, andthe suite runs ~100 exchanges against a ~800 ms binary whose time is dominated by
the block-device integration tests.

Opening a scratch pool is not free — it creates a file, marks it sparse through
an `fsutil` spawn, and hands back a handle — so the 64-test build was timed
against the 63-test build it sits on, twenty-five alternating runs each, on the
committed content:

| Build | min | p25 | median | p75 | mean |
|---|---|---|---|---|---|
| 63 tests, no scratch pool | 1776 ms | 1939 ms | 2150 ms | 2278 ms | 2163 ms |
| 64 tests, scratch pool | 1754 ms | 2045 ms | 2229 ms | 2376 ms | 2278 ms |
| delta | −22 ms | +106 ms | +79 ms | +98 ms | +115 ms |

About **+0.1 s**, roughly 5% of the binary, inside a run-to-run spread several
times that size — the minima are indistinguishable. Fifty runs, fifty exits of
zero, so the pool open is not flaky either. That is the whole price of closing
the gap, and it is cheap enough not to be a reason to leave the gap open.

One trap worth naming, because it hung the first version of this file:
`serveOnce` takes no socket — it serves whichever connection is next in the
accept backlog. A test that opens a connection and then lets something else
serve blocks forever in the server's `recv`. `dispatch` now does the
connect/send/serve sequence in one place so it cannot be split, and the harness
tracks whether a connection is queued and aborts loudly if `serve` is reached
without one, so the mistake is a failed test rather than a hung gate.

### It has been shown to fail

A regression is only worth a test if the test can go red. Two were injected and
reverted:

| Regression injected | Result |
|---|---|
| `respond` always writes the body, ignoring `framing` | `CHECK_EXIT=1` — the two HEAD tests and the phantom-body test all failed; the first with `expected 0, found 5744`. **All 21 unit tests still passed.** |
| a miss answers `200 OK` instead of `404 Not Found` | `CHECK_EXIT=1` — the wire matrix failed, alongside five unit tests that already covered the same claim |
| the top-level `total` object deleted from the serializer | `CHECK_EXIT=1` — `telemetry has no top-level key total; top-level keys are: t uptimeMs engine counters pool procs buffer` |
| the `latencyMs` field deleted from the `buffer` object | `CHECK_EXIT=1` — `buffer has no field latencyMs`, with the fifteen surviving names listed. `110/111` |
| the scratch pool opened but never attached to the harness | `CHECK_EXIT=1` — `buffer is null: the scratch pool did not attach`. `110/111` |
| `serveAsset` re-decides framing instead of trusting the `Decision` | `CHECK_EXIT=1` — the asset-HEAD test and the phantom-body test failed. A handler reaching back across the module boundary to re-derive a fact the router already decided |

The first is the point of the file. That regression is invisible to every test
above the socket, and it is exactly the defect #7 exists to remove.

The fifth is the one that keeps the fourth honest. Every field assertion in the
`buffer` test sits behind the pool being open, so a harness that opened a pool
and then forgot to attach it would skip the lot and report success for having
checked nothing — the tautology this suite has already produced once. The test
returns `error.BufferIsNull` instead, and that path was proven by deleting the
attach line and watching the gate go red, rather than being trusted because it
reads that way.

The third one is worth keeping for a different reason: **the first version of
that test did not catch it.** It searched the document for the substring
`"total":`, and the `pool` object contains a `total` field of its own, so the
assertion passed with the top-level `total` deleted. The test was a tautology
and the only reason anyone knows is that the injected mistake was run against
it and the gate stayed green. It now walks the bytes tracking brace depth and
reports only names at the object's own level — which is what makes "the key is
present" mean present *there* rather than present somewhere. The `buffer` test
uses the same walker on the `buffer` object rather than a hand-copied key list,
and asserts `BUFFER_FIELDS.len == keys.len` so an object that grew a field would
also fail rather than pass unnoticed.

## The loader/ICD handle contract, as measured

Measured on this machine with the Windows loader at `System32/vulkan-1.dll`
(1.3.301) and ICD interface version 4 — not from the spec:

- The loader allocates **no** separate wrapper. The address the ICD returns from
  `vkAllocateCommandBuffers` is the address the loader hands back.
- The loader **writes its dispatch pointer over the first 8 bytes** of that
  object. Anything live in that prefix is destroyed.
- `CommandPool` survived because its sentinel is 4 bytes; `CommandBuffer` did not,
  because its `commands` slice started at offset 0.

Four `vkCmd*` entry points had a phantom leading `_: ?*anyopaque`, as if a
`VkDevice` were passed first. They are registered directly in the dispatch table,
so the extra slot swallowed the real first argument.

**Zig 0.16 packs struct fields by alignment, not declaration order.** For
`{sentinel: u32, recording: bool, commands: []Command, count, capacity, err}`:

```
sentinel=32  recording=44  commands=0  count=16  capacity=24  size=48
```

`commands` is at offset **0** even though `sentinel` is written first. Handle
validation therefore goes through `@offsetOf(T, "sentinel")`; any literal would
rot silently.

## The benchmark's ratio is measured on both sides

`bench.zig` used to print `67.3 / 0.08`, where the second half was a literal
nothing had ever measured, and the printed multiplier divided it by its own
partner. README repeated the result as "roughly 840x worse than RAM".

`measureRam` now measures a counterpart: a dependent pointer chase through a
256 MiB buffer, so every step misses cache. Same quantity the device half
measures.

```
system RAM memcpy             2108 MB/s   (256 MiB, sequential)
system RAM random access     0.587 us     (dependent loads, 256 MiB set)
pool random access          2370.1 us     (uncached 4 KiB reads, 8 GiB set)
=> about 4036x
```

Two caveats the banner states rather than hides: a dependent-load chase and an
uncached 4 KiB sector read are different operations, so the ratio is a scale and
not a constant; and the pool figure is the 8 GiB row of a sweep, because the
smaller rows measure the RAID controller's cache rather than the device.

## The gate builds what it vouches for

`zig build check` compiled four test roots and nothing else. `main.zig` is the
root of no test module, so a compile error there left the gate reporting
`10/10 steps succeeded; 88/88 tests passed` and exiting **0** while `zig build`
failed outright. Measured with one well-formatted line added to `src/main.zig` —
a call to a function that does not exist, so the formatting check still passes
and only a real compile can reject it:

```
BEFORE   zig build check -> 10/10 steps succeeded, 88/88 tests passed   exit 0
         zig build       -> use of undeclared identifier                 exit 1
AFTER    zig build check -> install transitive failure, 1 errors        exit 1
```

`check_step` now depends on `b.getInstallStep()`, the same dependency `run` uses,
so the gate and the shipping build cannot drift. A gate that cannot go red on
the artifact it certifies is decoration.

## How the three branches combined

They were three independent fixes to the same file, all branched from `main`, and
they did not merge cleanly. Resolving mechanically would have produced a server
where the route came from one read of the request and the framing from another —
the precise defect #7 exists to remove. So the conflicts were resolved by making
the decision a single value:

| Conflict | Sides | Resolution |
|---|---|---|
| `Context.md`, 3 blocks | all three rewrote the same sections | discarded all three; rewrote as one document describing the combined system |
| `server.zig` `serveOnce` | #6 replaced the `path`/`method` locals with `routeRequest(req)`; #7 read `method` to compute framing | `routeRequest` now returns a `Decision{route, framing}` from a single parse, so framing is no longer threaded from a local #6 deleted |
| `server.zig` `serveAsset` | #6 kept the 2-arg signature; #7 added a `Framing` parameter | kept #7's signature; it is required, so a call site that forgets cannot compile |

The `Decision` pair is the point. `routeLine` picks the status and `framingFor`
picks the framing from the same `line`, so the two cannot come from different
reads. `respond` takes `Framing` as a required parameter, so the compiler rejects
a handler that forgets to thread it.

## Route 1 measured: llama.cpp on the DPU pool

The first idea in the two-ideas diagram is DPU to llama.cpp to an 8B model at
10-40 TPS. It was measured rather than argued, and the answer is not the one the
diagram assumes. Patch, test and full numbers are in
`dpu/third_party/llama-dpu/README.md`.

The premise is sound, and this machine is the reason. There is **7.79 GiB of
RAM**; an 8B Q4_K_M model is ~4.9 GiB of weights before a KV cache exists.
Every tensor the CPU backend does not memory-map comes from
`ggml_aligned_malloc`, which on Windows is `_aligned_malloc`: private,
anonymous, charged to commit and never reclaimable. So a small change makes
`ggml_aligned_malloc` offer the allocation to DPU's pool first, mapping
`P:\DPU\pool.vram` instead of allocating, and the same bytes become
file-backed. Opt in with `GGML_DPU_POOL=1`. Every failure mode -- absent,
locked by another process, exhausted, under 4 MiB -- falls back to `malloc`.

It works, and it is not worth having. Same command, only `GGML_DPU_POOL`
differing:

| model | peak commit | load | generation | exit |
| --- | --- | --- | --- | --- |
| `gemma-2-9b-it` Q4_K_M, pool off | 8246 MB | 31 s | 2.51 tok/s | 0 |
| `gemma-2-9b-it` Q4_K_M, pool on | 6562 MB | **32989 s** | 0.14 tok/s | 0 |
| `Llama-3.2-3B` Q4_K_M, pool off | 8353 MB | 12 s | 7.54 tok/s | 0 |
| `Llama-3.2-3B` Q4_K_M, pool on | 7734 MB | 11.9 s | 2.63 tok/s | 0 |

Peak commit fell by 619 MB on the 3B and 1684 MB on the 9B -- not the 1.87 GB /
5.76 GB of weights -- while generation went 2.87x slower, and at 9B the load
went from 31 s to **9.2 hours**. The allocator is not the reason.
`GGML_DPU_STATS=1` shows the one large allocation (the weight buffer) served
from the pool, with all 1246 graph temporaries correctly below the 4 MiB
threshold and left to `malloc`; and `poolspeed` writes **1428 MB/s** through a
2 GiB pool mapping and reads every byte of it back at **3942 MB/s** warm,
against 949 MB/s for a plain `dd` write to `P:`, so neither the code nor the
device is the bottleneck. Task Manager shows the run pegged at 100% disk,
which is the same fact from the other side.

The reason is that **file-backed does not mean free**. Mapping the pool is
charged to the page cache rather than to commit, and the counters show it -- but
the pages are still resident RAM while the process touches them, and generating
a token re-reads essentially the whole weight set. At 9B that is ~5.76 GB of
reads per token on a machine with 7.79 GiB of RAM. The pool cannot cache a
working set that large, so the demand does not disappear; it turns into
reclaim and re-read, which is the 9.2 hours.

So **holding model weights in the pool is the wrong lever**. The pool is a
capacity tool, and what belongs in it is what is *not* re-read every token. The
10-40 TPS target is gated by memory bandwidth and by these four cores, not by
where the bytes are filed: a stock CPU-only llama.cpp with no DPU at all already
does 7.54 tok/s on the 3B and 2.51 tok/s on the 9B.

The code is kept because the measurement is reusable and `dputest` is a real
test -- 21/21 with the pool on, 3/3 with it off -- not because it is the route
to an 8B model. The route to one is a compute path the ICD does not have, and
that used to be an inference from reading `src/backend/icd/icd.zig`. It is now
measured, through the real loader, with the iGPU as a control on the same run:

| asked of the loader | Intel UHD (control) | DPU |
| --- | --- | --- |
| device extensions advertised | 130 | **0** |
| `VK_KHR_buffer_device_address` | YES | **NO** |
| compute entry points that resolve | 10 of 16 | **2 of 16** |
| `vkCreateShaderModule` (valid SPIR-V) | `VK_SUCCESS` | **`VK_ERROR_FEATURE_NOT_PRESENT` (-8)** |
| `vkCreatePipelineLayout` (empty) | `VK_SUCCESS` | **NULL, never called** |
| `vkCreateComputePipelines` (1) | `VK_SUCCESS` | NULL, never reached |

The two entry points DPU resolves are exactly the two it refuses with a
definite status; the other fourteen are NULL, so a client dereferences a crash
rather than a diagnosable error. `vkCmdDispatch`, every descriptor-set entry
point and `vkCreatePipelineLayout` are among them. Advertising **zero**
extensions is separately fatal on its own: without buffer device address there
is no way to hand a buffer address to a shader at all, so `ggml-vulkan` stops
before it reaches a pipeline. The control matters -- the same probe, the same
loader and the same battery produce three `VK_SUCCESS` on a real compute-capable
ICD, so the refusals belong to the DPU rather than to the harness.

Two related defects fall out of the same run. `vk_icd.json` declares
`"api_version":"1.3"` and the ICD did not implement `vkEnumerateInstanceVersion`,
so the loader could not confirm the claim and logged `treating as a 1.0 ICD`.
**Both halves are now fixed:** the entry point reports 1.3, and the honest
consequence -- Vulkan 1.3 needs loader interface version 5 -- moved
`ICD_INTERFACE_VERSION` from 4 to 5, with
`vk_icdGetPhysicalDeviceProcAddr` restricted to the commands whose first
dispatchable argument is a `VkPhysicalDevice`. With both in place the loader
logs no ICD warnings at all. And the
loader finds the iGPU's ICD in the DriverStore
(`...\iigd_dch.inf_amd64_...\igvk64.json`) by enumerating display devices, not
through `HKLM\SOFTWARE\Khronos\Vulkan\Drivers`, which is empty -- so the
absence of registered drivers on this machine does not mean the absence of
Vulkan hardware.

### `vkCmdCopyBuffer` had its pointer and count the wrong way round (fixed)

**The previous revision of this file told the opposite story, and it was
wrong.** It claimed `vkQueueSubmit` took eight arguments with no fence and that
the vendored header had been hand-edited into a non-conformant API. Reviewer
Greptile flagged that as P1 on the PR built from that claim, and checking the
Khronos registry settled it:

```
VkResult vkQueueSubmit(VkQueue queue, uint32_t submitCount,
                       const VkSubmitInfo* pSubmits, VkFence fence);

typedef struct VkSubmitInfo {
    VkStructureType sType; const void* pNext;
    uint32_t waitSemaphoreCount; const VkSemaphore* pWaitSemaphores;
    const VkPipelineStageFlags* pWaitDstStageMask;
    uint32_t commandBufferCount; const VkCommandBuffer* pCommandBuffers;
    uint32_t signalSemaphoreCount; const VkSemaphore* pSignalSemaphores;
} VkSubmitInfo;   // no fence member, anywhere
```

Four arguments, fence last, and `VkSubmitInfo` carries no fence field at all.
`main` already declared exactly that. So the header was conformant, the "fix"
was a regression that would have handed a real loader seven arguments where it
passed four, and the whole eight-argument story has been reverted.

**What the real defect was**, and it was smaller and sharper: `icd.zig` maps the
entry name `vkCmdCopyBuffer` straight onto `exec.vkCmdCopyBufferImpl`, and that
function had the last two parameters the wrong way round:

```zig
regions: ?[*]const c.VkBufferCopy,   // was here
region_count: u32,                   // was here
```

The loader calls per the specification -- `(cb, src, dst, regionCount,
pRegions)` -- so the driver read `regions` as the count `1` and `region_count` as
the low 32 bits of a pointer. One region became "read from address 1, for
however many bytes were in the low half of a pointer". The header was right
throughout, which is why the fix belongs in the impl.

The probe hid it the way these things always hide: it declared its **own**
function pointer for `vkCmdCopyBuffer` in the same wrong order, so the probe and
the ICD agreed by construction and 111 green tests proved nothing about the ABI.

Three probe defects were real and are fixed:

- `pfn_wait` was declared with four arguments and called without a fence count,
  so the fence pointer arrived where `fenceCount` belongs. `vkWaitForFences` has
  five.
- The loader-routing guard is back, so this class of drift cannot return
  unnoticed: it asserts the **loader** routes `vkQueueSubmit`, `vkCmdCopyBuffer`,
  `vkCmdFillBuffer` and `vkWaitForFences`.
- The fence check could not fail. `vkWaitForFences` in this driver always returns
  success, so `check(wrc == 0, ...)` was unfalsifiable. It now resets the fence
  before each submission (the spec requires an unsignalled fence on re-submit,
  and without it the status read would be answering itself) and asserts
  `vkGetFenceStatus` returns `VK_SUCCESS`, which does fail when nothing ran.

Probe count 51 -> 55. All four new checks are assertions that can go red.

The lesson is worth keeping: **"the header disagreed with my memory of the spec"
is not evidence that the header is wrong.** The registry is the arbiter, and it
was one fetch away.

## What 9B at 64k actually costs, measured

The second diagram asks for something specific: 128 MB of VRAM plus 8 GB of RAM
**cannot** run a 9B model at 64k context today, and with the DPU added it should
**run**, at 0.7-6 tok/s. That is a claim about capacity and a claim about speed,
and they turn out to have different answers.

### The working set is per token, and the cache is the big half

A decoder touches every weight once per token and then starts again, and
attention reads the whole key/value history. So the bytes that matter are per
token, not once:

| | 3B (Llama-3.2) | 9B (gemma-2) |
| --- | --- | --- |
| layers / KV heads / head_dim | 28 / 8 / 128 | 42 / 8 / 256 |
| KV bytes per token, f16 | 114,688 | 344,064 |
| KV at 64k, f16 | **7.5 GB** | **22.5 GB** |
| weights, f16 | 6.4 GB | 18.5 GB |
| weights, q4 | 1.6 GB | 4.6 GB |

At 64k the cache is the dominant term at both sizes, and it is the thing that
makes the top row of the diagram true. The weights are the small half.

### What the device actually does

`zig build bench`, 2026-10-05. The volume sits behind a RAID controller with a
large cache, so the small rows are measuring that cache and not the disk. The
sweep now drops any row the volume cannot hold beside the pool's own reserve,
and says so, rather than failing the whole run:

| working set | write MB/s | read MB/s | rnd 4 KiB us |
| --- | --- | --- | --- |
| 64 MiB | 247 | 4860 | 4.5 |
| 1024 MiB | 268 | 4515 | 4.4 |
| 2048 MiB | 209 | 347 | 39.3 |
| **4096 MiB** | 182 | **427** | 57.6 |
| 8192 MiB | *skipped* -- needs 8.0 GB, headroom was 6.0 GB | | |

**Run-to-run variance is real and is not noise to average away.** An earlier run
the same day read 412.7 MB/s at 4096 MiB and 470.8 at 8192, and 4104 MB/s at
2048 MiB where this one reads 347 -- the controller's cache state moves the cold
boundary between 2 and 4 GiB. The device is therefore **roughly 400-500 MB/s
sequential**, and every plan below is computed against the lowest device-sized
row of *its own* run rather than a remembered number.

Against RAM at 4004 MB/s memcpy and 0.100 us random, the pool's uncached random
access is **57.6 us, or 576x slower**. That ratio, not the bandwidth, is the
design constraint.

### The granule is worth 5.4x on its own

A scheduler does not read a file, it *faults*. One read in flight, same 4 GiB
set, only the transfer size varying:

| granule | read MB/s | per-read us |
| --- | --- | --- |
| 4 KiB | **106.8** | 36.5 |
| 16 KiB | 289.2 | 54.0 |
| 64 KiB | 530.0 | 117.9 |
| 256 KiB | 575.0 | 434.7 |
| **1 MiB** | **580.5** | 1722.5 |

Effective throughput rises **5.4x** from the granule alone at identical byte
counts (6.7x in the earlier run). That is the entire reason `residency.zig` takes
a granule as policy rather than reading whatever the caller asked for.

### The plan, from those measured constants

`residency.plan` is arithmetic over a working set, a RAM budget and a measured
machine -- no model, no geometry, no victory condition. Fed the table above
(36.5 us faults, streaming planned against the lower of the two device-sized read
rates, 6 GiB resident of 7.79 GiB):

| working set | at 4 KiB | at 1 MiB | tok/s | bound |
| --- | --- | --- | --- | --- |
| 3B q4/q4, 64k | RESIDENT | RESIDENT | -- | none |
| 3B q4 / f16 KV, 64k | STREAMED | STREAMED | 0.167 | bandwidth |
| 9B q4/q4, 64k | STREAMED | STREAMED | 0.117 | bandwidth |
| **9B f16, 64k** | **DOES NOT FIT** | **DOES NOT FIT** | **0.000** | none |

The row the diagram is about is the last one, and it fails on **capacity, not
speed**: 41.0 GB of working set against an 8 GiB pool ceiling and 13 GB free on
`P:\`. No eviction policy recovers that, which is why the verdict is not
`streamed` with a small number but `does_not_fit` with none.

### What that means for the 0.7-6 tok/s claim

- **"Can't run" -> "can run" is real, and it is the capacity half.** At 4 bits
the 9B working set is 10.3 GB and streams. That is the diagram's headline and it
holds.
- **0.7 tok/s is not reachable at 9B/64k on this machine, and 6 is not close.**
The 9B q4 row lands at **0.117 tok/s**, on a run whose device read rate was the
optimistic end of the observed range. Raising it means moving fewer bytes per
token, and at 64k the cache is 55% of the working set before quantisation is
even considered. Quantising the *cache* is the lever, not the weights, and it is
a model-side decision that no amount of DPU policy can make.
- **6 tok/s requires the working set resident, not paged.** At a 427 MB/s device
the budget is ~330 MB of misses per token, against a **7.5 GB** f16 cache for the
3B alone. Only the `RESIDENT` row reaches that regime, and it does so without the
pool: the **first** row of the table is what "fits" looks like.

### The mechanism that does ship

`src/backend/residency.zig` -- the layer `pool.zig` and `blockdev.zig` have
referred to as "the residency scheduler" since before it existed. It is policy
and arithmetic only: it imports nothing from the backend, holds no handles, and
is tested as arithmetic rather than against a device.

Three findings are encoded as behaviour rather than as comments:

1. **LRU earns literally nothing on a cyclic scan.** A decoder's access pattern
is every page once, then again, over a set larger than the cache -- the case
where LRU evicts precisely the page it needs next. Two tests pin this: the same
trace gives **0 hits** under `Policy.lru` and **8 hits** under `Policy.pinned`
at the same capacity. This is why handing the weights to the pool made decoding
slower, and `Policy.pinned` is the fix.
2. **Fault latency and bandwidth bind separately.** The planner computes both and
takes the maximum, so a device with a fast round trip and a slow stream is not
modelled as fast. At 4 KiB the plan is fault-bound and at 1 MiB it is
bandwidth-bound -- from the same machine, on the same bytes.
3. **An unmeasured rate degrades to the measured limit, not to infinity.** A
machine with no streaming figure plans against `granule / fault_us`, which is a
genuine lower bound on cost. Reporting `inf` would be defensible arithmetic and
a module nobody could use.

### The correction that the measurement forced

The pool is the **wrong place to store the weights**, and this is a design
conclusion rather than a tuning one. A GGUF on disk is already a random-access
backing store; copying it into `pool.vram` doubles the storage for the same
bytes, adds a copy, and changes nothing about the access pattern. Route 1 did
exactly that and measured the result. What the DPU can contribute is the *fault
path* -- granule, read-ahead, eviction policy and the honest numbers above --
applied to the file the model already lives in.

## Unlinking the pool did not give the space back, and it was not NTFS

`P:\` had lost ~4.7 GB across a session of benchmarks, with nothing on the volume
holding it: `du` found no large file, and the pool was gone. Three hypotheses,
each tested rather than argued:

| experiment | free before | free after write | free after delete |
| --- | --- | --- | --- |
| 2 GiB plain file | 8300 MB | 6151 MB | **8300 MB** — returned |
| 2 GiB sparse file (`fsutil sparse setflag`) | 8300 MB | 6244 MB | **8300 MB** — returned |
| 512 MB sparse, deleted **while a second handle was open** | 8300 MB | 7754 MB | **7754 MB** — *not* returned |

The first two clear the volume. The third is the mechanism: deleting a file
another process has open fails with `ERROR_SHARING_VIOLATION` (`os.remove`
surfaces it as `PermissionError 13`), and **the block layer discarded
`DeleteFileW`'s return value**. So `destroy()` reported a clean exit while the
pool's bytes stayed on disk -- and the next run reopened *that* pool instead of
a fresh one, which is how several GB quietly accumulated.

Two changes, both needed:

- `FILE_SHARE_DELETE` on every open of the pool. With it, NTFS marks the file
  delete-pending and reclaims when the last handle closes, so a peer reading the
  pool no longer blocks its removal. This matters because the engine and the
  ICD are separate processes holding the same file.
- `destroy` records the outcome, exposed as `poolRemoved()`. `destroy` cannot
  return an error -- its callers live in files this module does not own -- so
  `zig build bench` now prints a warning naming the file when the pool could not
  be removed, instead of quietly leaving it there.

## Route 1 re-measured at 64k, and it corrected the planner

Same experiment as before, but at `-c 65536` on the 3B, which is the context the
"can't run" claim is about. `llama-completion`, 31 generated tokens, pool off and
`GGML_DPU_POOL=1`:

| 3B Q4_K_M at `-c 65536` | load | eval | exit |
| --- | --- | --- | --- |
| pool off | 2.06 s | **7.77 tok/s** | 0 |
| pool on (`GGML_DPU_POOL=1`) | 8.45 s | **6.29 tok/s** | 0 |

The pool hook engaged (`serving allocations >= 4 MiB from disk`), the load went
4.1x slower because the weights now come off `P:\` once, and generation cost
**19%**. That is a far milder penalty than route 1's 9B figure of 0.14 tok/s,
which was never re-measured and is now suspect.

**It also corrected the planner, which is the more useful result.** The 3B was
predicted to stream at 0.167 tok/s from a working set priced at the full 64k
context. It ran at 7.77 tok/s with no paging at all, because **the KV cache is
only read up to the position actually reached**: 31 tokens of history is 3.6 MB,
not the 7.5 GB a full window would hold. A 64k window is a *reservation*; the
history is a *length*, and pricing a short run at its capacity predicts a
slowdown that does not exist.

`Footprint.working_set` is bytes touched at one position, and the module now
says so with this measurement attached. The hard numbers earlier in this file --
the 9B rows, which assume a filled context -- remain valid for a filled context
and are explicitly scoped that way in the benchmark table.

Not re-measured: the 9B at 64k, which would take hours at these rates. The 9B
figures in the table above are a planner prediction over measured device
constants, not an end-to-end run, and are labelled as such.

### The gate did not compile the benchmark, and a shadowed local got through

`zig build check` covered `src/backend` and `src/*.zig`; `bench.zig` sits in the
same tree behind a step nobody runs by default. So a local constant named
`rate` shadowed the file's top-level `fn rate`, `zig build check` stayed
**138/138 and exit 0**, and `zig build bench` did not compile at all. That is the
same failure this file already records for the executable, in a different file: a
gate that cannot fail on an artifact in the repository is not covering it.

Fixed by compiling `dpubench` in `check` without running it — running it writes
gigabytes to `P:\`, which a gate must not do. Gate is now **17/17 steps**.

The red proof matters more than the count. Reintroducing the shadow makes
`zig build check` report

```
+- compile exe dpubench Debug native 1 errors
src\bench.zig:488:15: error: local constant shadows declaration of 'rate'
Build Summary: 14/17 steps succeeded (1 failed); 138/138 tests passed
exit 1
```

Note the **138/138 tests passed** on the failing line. That is the trap this
project has already been caught by once: the exit code is the signal, and a
filter or a summary line is not a passing test.

### The release fix, verified end to end

With `FILE_SHARE_DELETE` and the recorded outcome, one full `zig build bench`
now returns the volume to where it started:

| | free on `P:\` | `P:\DPU\pool.vram` |
| --- | --- | --- |
| before the run | 8300 MB | absent |
| mid-sweep (4 GiB written) | 3933 MB | 4294967296 bytes |
| after the run | **8301 MB** | **absent** |

and the benchmark prints `pool removed; the volume has its space back`. That is
the exact operation that used to lose gigabytes silently, and the warning path
is there for the case where a peer still holds the pool open.

**On capacity, and a mistake I made in it.** The planner is handed the capacity
the block device will actually agree to grow into rather than the configured
ceiling: `min(ceiling, pool_bytes_already_held + free - reserve)`. The first
version of that expression left out `pool_bytes_already_held`, and the
consequence was immediate and wrong: by the time the benchmark plans, its own
sweep has grown the pool to several GiB, and counting only the *free* space
understated the capacity by that whole amount. On the run recorded above,
**9B q4/q4 printed `DOES NOT FIT`** for a working set of 10.3 GB that the pool
was in fact carrying. I wrote that paragraph up as the fix working. It was the
miscount.

The `held` term is what makes it honest: those bytes are already spent *and*
already on the volume, which is precisely what capacity means. A verdict here is
now sensitive to real free space rather than to an artefact of when the plan ran,
which is the property that was wanted from the start.

## What comes next

**The guard is now in place, and the probe count went from 50 to 51.** The probe
resolves entry points through `devProc`, which falls back to the DPU's own table
whenever the loader declines -- so the probe and the ICD agreed by construction,
which is how the defect stayed green. A new check asserts that the **loader
itself** routes `vkQueueSubmit`, `vkCmdCopyBuffer`, `vkCmdFillBuffer` and
`vkWaitForFences`. It passes with 0 unrouted, which means the byte-identical
round trips above really are loader-mediated rather than direct calls into the
ICD, and an entry point that could only be satisfied by a fallback is now a
visible failure instead of a silent downgrade.

The check has teeth, which matters more than that it passes: adding an entry
point neither the loader nor the ICD serves reports `1 unrouted`, names it, and
takes the probe to `50/51` with **exit 1**.

**The probe no longer requires another vendor's driver.** It used to assert the
loader reported two physical devices, which quietly made the gate depend on an
Intel iGPU ICD being installed: with `VK_DRIVER_FILES=./vk_icd.json` -- the DPU
as the only driver -- it reported one device and exited 1, and it would have
done the same on every AMD or NVIDIA box and on any CI runner. Enumeration is
now asserted to return at least one device, and whether the DPU is present is
decided where it always should have been, by vendor and device ID. All four
cases behave:

| environment | result |
| --- | --- |
| DPU only, `VK_DRIVER_FILES=./vk_icd.json` | 61/61, exit 0 |
| ambient iGPU + DPU, `zig build probe` | 61/61, exit 0 |
| DPU absent (no `VK_*` set) | exit 1, `the DPU is present` |
| no ICDs at all | exit 3, `vkCreateInstance -> VK_ERROR_INCOMPATIBLE_DRIVER` |

The third row is the one that keeps this honest. Before the change the same
run failed on the device *count*, which named the wrong problem; it now fails
on the check that states the real one -- the DPU was not found -- so relaxing
the count could not quietly turn the probe into a no-op.

That list is now closed: `vkEnumerateInstanceVersion` is implemented, the loader
confirms the manifest's 1.3, and the interface version moved to 5 to match. See
the section on the loader/ICD handle contract above.

0. **Wire the residency scheduler to a real fault path.** It exists, it is
   tested, and nothing calls it yet -- `prefetchDepth` is now a page count for
   `residency.Scheduler.read_ahead` rather than a display value, but no client
   faults through it. Until one does, the plan table is a prediction and not a
   measurement, and the difference matters.
1. **Retire #5, #6 and #7.** They are fully contained in #8. Closing them is the
   user's call, not the agent's.
2. **Multi-segment pool** — the tier resolver sums free space across roots and
   holds `RESERVE_BYTES` per volume (PR #1), but the pool is still a single file
   on a single volume, so nothing is gained on disk yet.
3. **Process-level pool locking test** — existing tests prove a *thread* releases
   `Local\DPU.pool.lock`; none proves two *processes* cannot corrupt `pool.vram`.
4. **Run the benchmark in CI.** Every number above is from one run on one machine.
   Nothing re-measures it, so the next edit can quietly make it stale the way the
   hardcoded `0.08` did — as the probe count already did once.
5. **Extend the wire suite where the claims are still unchecked.** It covers
   every route the dashboard can reach, and nothing else: there is no route yet
   that takes a body, no keep-alive, and no concurrent client. Each of those is
   a claim someone will eventually make, and the suite should already be red when
   they start.
6. **Assert the `buffer` values, not just its keys — on the write path.** The
   sixteen fields are now covered with a pool open, but that pool is fresh and
   never written to, so every counter it reports is a zero. The same test with a
   pool that has actually absorbed and read back blocks would cover the sampler
   arithmetic, which nothing in the gate touches today.
7. **Measure the iGPU baseline -- the one number that decides Route 1.** The
   iGPU does have a working Vulkan driver (`igvk64.dll`, apiVersion 1.3.280,
   130 extensions, and it returns `VK_SUCCESS` from `vkCreateComputePipelines`),
   so the 10-40 TPS target can be measured on hardware rather than argued about
   from a CPU-only 2.51 tok/s. Building `ggml-vulkan` needs `glslc` and the
   Vulkan headers, and the SDK install has failed twice (eight unattended
   attempts, then a manual run that logged `Installation aborted!` and rolled
   `C:\VulkanSDK` back out). Nothing else is missing.

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

`zig build check` writes `zig-out/bin/dpu.exe`; that is deliberate, and it means
the gate is no longer a pure verification step. To run the binary directly,
point `VK_ADD_DRIVER_FILES` at `zig-out/bin/vk_icd.json`. The probe exits
non-zero if any check fails and prints one
`PROBE_SUMMARY: total=.. passed=.. failed=..` line last.

The engine binds `127.0.0.1:8787` and serves **one connection at a time**, so
issue requests sequentially or they will queue behind each other. `P:\` is
optional: `Pool.init` failure degrades telemetry to `"buffer":null` and the server
still starts.

The gate's wire suite needs `P:\` for the one test that opens a scratch pool,
and it creates and removes `P:\DPU-wirepool` itself. Verified after 50 runs and
a probe: the directory is gone, `P:\DPU\pool.vram` is byte-for-byte unchanged
(same mtime, same size) across a test binary, and no `test.exe`, `dpu.exe` or
`fsutil.exe` outlives the run. `zig build probe` *does* write to the live pool —
that is what it is for, and `src/backend/icd/probe.zig` hardcodes the path.

`zig build bench` **destroys `P:\DPU\pool.vram`** — it sweeps an 8 GiB working set
through it and unlinks the file afterwards. The engine recreates it on next start.

### A fresh clone must be able to pass the gate

The blobs in this repository are stored with **mixed line endings** —
`dpu/src/pool.zig` carries 292 CR bytes and 181 bare LFs — and until
`.gitattributes` was added there was nothing telling git not to touch them. On
Windows the default is `core.autocrlf=true`, which re-smudges every LF into CRLF
on checkout: `pool.zig` came out at 473 CR bytes and `build.zig` at 1281, and
`zig fmt --check` then failed on all eleven Zig files. **111/111 tests still
passed** — only the formatting step went red — and `git status` reported the tree
as clean throughout, so nothing surfaced the corruption until the gate ran.

The fix is `* -text` in `.gitattributes`: no EOL conversion in either direction,
so the checkout is byte-exact whatever `core.autocrlf` says, and git still
renders text diffs rather than calling the files binary. Verified the only way
that counts — a clone with the default settings and the attribute present at
first checkout lands on 292/863 CR bytes, a clean `git status`, and
`13/13 steps, 111/111 tests`.

One trap in testing it: cloning and *then* switching to a branch that adds
`.gitattributes` proves nothing, because git does not rewrite files whose blob
is unchanged between the two branches — the already-corrupted bytes survive the
switch. The attribute has to be present at the initial checkout, or the test is
measuring the old checkout. Re-checking out with `rm -rf` and `git checkout --`
reproduces the good state, which is what makes the failing case look fixed.