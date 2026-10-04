# DPU — working context

A GPU that runs on disk. A `pool.vram` file on `P:\` presented to Vulkan
applications as a discrete GPU through a user-mode installable client driver.

## Status at this commit

`zig build check` — **110/110 tests**, exit 0, `zig fmt --check` clean. The gate
also builds `dpu.exe`, so a green run now means the shipping binary compiles.

`zig build probe` — **50/50, exit 0**, closing with
`PROBE_SUMMARY: total=50 passed=50 failed=0 result=PASS` and
`RESULT: PASS -- the DPU heap carries real bytes on disk`.

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

This branch is stacked on **#8**, which is itself the union of three still-open
PRs, none of which is merged:

- **#5** `fix/check-must-build-the-exe` — the gate now builds the executable.
- **#6** `fix/malformed-request-400` — 400 for a request line that is not one.
- **#7** `fix/head-response-no-body` — no body on a HEAD response.

On top of that, this branch adds the wire-level suite described below. It cannot
be merged before #8, and it exists only because #5, #6 and #7 are all claims
about HTTP behaviour that nothing in the repository was checking.

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
| every asset answers HEAD with its GET length and no bytes | derived from `server.ASSETS`, not restated — see below |
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

The asset tests iterate `server.ASSETS`, which is why `Asset` and `ASSETS` are
`pub`. The first version carried a written-out list of asset paths, and that is
a second thing that has to agree with the router — it would have stopped
agreeing the day somebody added an asset, and nothing would have said so. This
is the same failure mode #4 removed from the status code: two copies of one
fact, one of which is only exercised when someone remembers.

Derived coverage has the opposite hazard — an empty table makes the loop
vacuously true — so the asset test asserts `ASSETS.len >= 3` first.

The tables that *are* written out are genuinely test data: the matrix includes
paths that must **not** route, so it cannot be derived from the router.

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
the 62-test build. Either way it is well under a tenth of a second, and the
suite runs ~100 exchanges against a ~800 ms binary whose time is dominated by
the block-device integration tests.

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
| `serveAsset` re-decides framing instead of trusting the `Decision` | `CHECK_EXIT=1` — the asset-HEAD test and the phantom-body test failed. A handler reaching back across the module boundary to re-derive a fact the router already decided |

The first is the point of the file. That regression is invisible to every test
above the socket, and it is exactly the defect #7 exists to remove.

The third one is worth keeping for a different reason: **the first version of
that test did not catch it.** It searched the document for the substring
`"total":`, and the `pool` object contains a `total` field of its own, so the
assertion passed with the top-level `total` deleted. The test was a tautology
and the only reason anyone knows is that the injected mistake was run against
it and the gate stayed green. It now walks the bytes tracking brace depth and
reports only names at the object's own level — which is what makes "the key is
present" mean present *there* rather than present somewhere.

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

## What comes next

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
6. **Cover the `buffer` object in the gate.** The telemetry shape test asserts
   the eight top-level keys and the three `engine` keys, but the sixteen
   `buffer` fields are only emitted when the capacity pool is open, and the gate
   deliberately runs without one. They are checked against a running engine, which
   is weaker than a gate check. A scratch pool on a test volume would close it.

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

`zig build bench` **destroys `P:\DPU\pool.vram`** — it sweeps an 8 GiB working set
through it and unlinks the file afterwards. The engine recreates it on next start.