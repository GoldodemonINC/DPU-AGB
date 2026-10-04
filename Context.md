# DPU — working context

A GPU that runs on disk. A `pool.vram` file on `P:\` presented to Vulkan
applications as a discrete GPU through a user-mode installable client driver.

## Status at this commit

`zig build check` — **99/99 tests**, exit 0, `zig fmt --check` clean. The gate
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

This branch is the union of three still-open PRs, none of which is merged:

- **#5** `fix/check-must-build-the-exe` — the gate now builds the executable.
- **#6** `fix/malformed-request-400` — 400 for a request line that is not one.
- **#7** `fix/head-response-no-body` — no body on a HEAD response.

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

1. **Retire #5, #6 and #7.** They are fully contained in this branch. Closing
   them is the user's call, not the agent's.
2. **Multi-segment pool** — the tier resolver sums free space across roots and
   holds `RESERVE_BYTES` per volume (PR #1), but the pool is still a single file
   on a single volume, so nothing is gained on disk yet.
3. **Split `server.zig`.** It is 769 lines holding Winsock transport, routing,
   the telemetry document builder and asset serving. The telemetry serializer
   belongs in its own file; a change to the document shape should not require
   reading the router.
4. **Process-level pool locking test** — existing tests prove a *thread* releases
   `Local\DPU.pool.lock`; none proves two *processes* cannot corrupt `pool.vram`.
5. **Run the benchmark in CI.** Every number above is from one run on one machine.
   Nothing re-measures it, so the next edit can quietly make it stale the way the
   hardcoded `0.08` did — as the probe count already did once.

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