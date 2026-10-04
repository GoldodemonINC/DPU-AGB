//! Loopback HTTP server for the dashboard.
//!
//! Hand-rolled over Winsock rather than a framework. The only client is the
//! dashboard on 127.0.0.1, so there is no connection pooling, no TLS, and no
//! reason to spend startup time on an HTTP stack the process will never need
//! again once it is listening.
const std = @import("std");
const win = @import("win");
const telemetry = @import("telemetry.zig");
const pool_mod = @import("pool.zig");
const tiers = @import("tiers");
const c = win.c;

pub const DEFAULT_PORT: u16 = 8787;

/// Engine-level control state driven by the dashboard's right-hand matrix.
/// Lives here because the power mode and split flag are engine policy, not UI
/// state — a future headless control surface sets exactly the same fields.
pub const EngineState = struct {
    power: PowerMode = .x_high,
    split: bool = true,
    booted_at_ms: i64 = 0,

    pub fn nowMs() i64 {
        var ft: c.FILETIME = undefined;
        c.GetSystemTimeAsFileTime(&ft);
        const t = @as(u64, ft.dwHighDateTime) << 32 | @as(u64, ft.dwLowDateTime);
        return @intCast(t / 10_000); // 100ns ticks -> ms
    }

    pub fn uptimeMs(self: *const EngineState) i64 {
        return EngineState.nowMs() - self.booted_at_ms;
    }
};

pub const PowerMode = enum {
    max,
    x_high,
    low,

    pub fn label(self: PowerMode) []const u8 {
        return switch (self) {
            .max => "MAX",
            .x_high => "xHIGH",
            .low => "LOW",
        };
    }

    /// Prefetch depth multiplier. Real once the scheduler exists; for now the
    /// dashboard shows it as the selected aggressiveness.
    pub fn prefetchDepth(self: PowerMode) u32 {
        return switch (self) {
            .max => 8,
            .x_high => 4,
            .low => 1,
        };
    }

    pub fn parse(text: []const u8) ?PowerMode {
        if (std.ascii.eqlIgnoreCase(text, "max")) return .max;
        if (std.ascii.eqlIgnoreCase(text, "xhigh") or std.ascii.eqlIgnoreCase(text, "x_high")) return .x_high;
        if (std.ascii.eqlIgnoreCase(text, "low")) return .low;
        return null;
    }

    /// The tier ladder's name for this mode. The two enums mirror each other so
    /// the capacity policy stays out of the HTTP layer.
    pub fn tier(self: PowerMode) tiers.Mode {
        return switch (self) {
            .max => .max,
            .x_high => .x_high,
            .low => .low,
        };
    }
};

pub const Server = struct {
    listen_fd: c.SOCKET = c.INVALID_SOCKET,
    engine: EngineState = .{},

    pub fn bind(port: u16) !Server {
        var wsa: c.WSADATA = undefined;
        if (c.WSAStartup(0x0202, &wsa) != 0) return error.WsaStartup;

        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP);
        if (fd == c.INVALID_SOCKET) return error.SocketFailed;

        var opt: c_int = 1;
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, @ptrCast(&opt), @sizeOf(c_int));

        var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        addr.sin_family = c.AF_INET;
        addr.sin_port = std.mem.bigToNative(u16, port);
        // Loopback only. This binds the dashboard to the local machine and
        // nowhere else; there is no interface list, so nothing to get wrong.
        addr.sin_addr.S_un.S_addr = @bitCast(@as(u32, 0x0100_007F));

        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) != 0) return error.BindFailed;
        if (c.listen(fd, 8) != 0) return error.ListenFailed;

        return .{ .listen_fd = fd };
    }

    /// Serve one connection. Blocks until a client connects, handles the single
    /// request, and closes. Sequential is correct here: one dashboard, one tab.
    pub fn serveOnce(self: *Server, ctx: *Context) void {
        var client_addr: c.sockaddr_in = undefined;
        var addr_len: c_int = @intCast(@sizeOf(c.sockaddr_in));
        const client = c.accept(self.listen_fd, @ptrCast(&client_addr), &addr_len);
        if (client == c.INVALID_SOCKET) return;
        defer _ = c.closesocket(client);

        var buf: [8192]u8 = undefined;
        const n = c.recv(client, &buf, buf.len, 0);
        if (n <= 0) return;
        const req = buf[0..@intCast(n)];

        // `routeRequest` parses the request line once and returns both the
        // route and the framing. One parse decides all three things -- the
        // method, the status and whether bytes follow the headers -- so a HEAD
        // cannot be routed one way and framed another.
        const d = routeRequest(req);
        switch (d.route) {
            .telemetry => sendTelemetry(client, ctx, d.framing),
            .control => sendControl(client, req, ctx, d.framing),
            .asset => |p| serveAsset(client, p, d.framing),
            .reject => |r| respond(client, r.status, "text/plain", r.body, r.allow, d.framing),
        }
    }

    fn sendControl(client: c.SOCKET, req: []const u8, ctx: *Context, framing: Framing) void {
        if (parseParam(req, "power")) |p| {
            if (PowerMode.parse(p)) |mode| {
                ctx.engine.power = mode;
                // A power mode is also a capacity request, so adopt the tier
                // immediately rather than waiting for the next telemetry tick.
                // The ceiling only ever rises, so dropping from MAX back to LOW
                // leaves the pool where it is instead of invalidating offsets
                // that clients are already holding.
                if (ctx.pool) |pool_ref| _ = pool_ref.applyTier(mode.tier());
            }
        }
        if (parseParam(req, "split")) |s| {
            ctx.engine.split = std.ascii.eqlIgnoreCase(s, "1") or std.ascii.eqlIgnoreCase(s, "true");
        }
        respond(client, "200 OK", "application/json", "{\"ok\":true}", null, framing);
    }

    /// Build the telemetry payload by hand into a fixed buffer.
    ///
    /// A general JSON serializer would be more code and slower for a document
    /// whose shape never varies. Numbers go through `fmt` with explicit
    /// precision so the client never has to parse locale-formatted output.
    fn sendTelemetry(client: c.SOCKET, ctx: *const Context, framing: Framing) void {
        const now_ms = EngineState.nowMs();
        const last_sample_ms = ctx.last_sample_ms;
        var buf: [16384]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);

        const s = ctx.sampler;
        var counter_buf: [64]win.CounterValue = undefined;
        const counters = ctx.query.sample(&counter_buf);

        w.print("{{\"t\":{d}", .{now_ms}) catch return;
        w.print(",\"uptimeMs\":{d}", .{ctx.engine.uptimeMs()}) catch return;

        // Engine policy, mirrored so the UI renders the same state it set.
        w.print(",\"engine\":{{\"power\":\"{s}\",\"prefetch\":{d},\"split\":{s}}}", .{
            ctx.engine.power.label(),
            ctx.engine.power.prefetchDepth(),
            if (ctx.engine.split) "true" else "false",
        }) catch return;

        // Named scalar counters, keyed by the paths registered in main.
        w.writeAll(",\"counters\":{") catch return;
        var first = true;
        for (ctx.query.counters.items, counters) |ctr, val| {
            if (!first) w.writeAll(",") catch return;
            first = false;
            w.print("\"{s}\":{d:.2}", .{ ctr.key, val.value }) catch return;
        }
        w.writeAll("}") catch return;

        // Capacity pool on P:.
        const space = s.poolSpace();
        const used = if (space) |sp| sp.total - sp.free else 0;
        const saturation = if (space) |sp| blk: {
            if (sp.total == 0) break :blk 0;
            break :blk @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(sp.total)) * 100.0;
        } else 0;
        w.print(",\"pool\":{{\"path\":\"P:\\\\\",\"total\":{d},\"free\":{d},\"used\":{d},\"saturation\":{d:.2}}}", .{
            if (space) |sp| sp.total else 0,
            if (space) |sp| sp.free else 0,
            used,
            saturation,
        }) catch return;

        // Tracked processes for the node manager.
        w.writeAll(",\"procs\":[") catch return;
        var emitted: usize = 0;
        for (s.procs.items, 0..) |*p, i| {
            // Sorting by working set keeps the heaviest nodes at the top; the
            // dashboard shows a fixed number of slots and those are the ones
            // that matter.
            if (emitted >= 40) break;
            if (p.working_set < 512 * 1024) continue;
            if (emitted > 0) w.writeAll(",") catch return;
            emitted += 1;
            w.print("{{\"pid\":{d},\"name\":\"", .{p.pid}) catch return;
            for (p.name[0..p.name_len]) |ch| {
                if (ch == '"' or ch == '\\') w.writeAll("\\") catch return;
                w.writeByte(ch) catch return;
            }
            w.print("\",\"role\":\"{s}\",\"ws\":{d},\"priv\":{d},\"pf\":{d},\"cpu\":{d:.1}}}", .{
                p.role.label(), p.working_set, p.private_bytes, p.page_faults, s.cpuFor(i),
            }) catch return;
        }
        w.writeAll("]") catch return;

        // Capacity pool on P:\. Reported from the pool itself rather than from
        // volume free space, so the dashboard shows what the DPU buffer is
        // doing rather than merely how full the drive is.
        if (ctx.pool) |p| {
            const st = p.sample(@intCast(@max(now_ms - last_sample_ms, 1)));
            // Resolved per request rather than cached, so a power-mode change
            // shows up on the next tick even though the pool's own ceiling is
            // monotonic and will not move until the tier is applied.
            //
            // A one-element root list: the pool is still one file on one
            // volume. The resolver takes a list because it holds back the
            // reserve per volume, so widening this to the nested volume is a
            // change here rather than a change to every caller.
            const roots = [_]u64{p.freeSpace()};
            const res = tiers.resolve(ctx.engine.power.tier(), &roots);
            w.print(
                ",\"buffer\":{{\"ceiling\":{d},\"length\":{d},\"used\":{d},\"allocated\":{d},\"saturation\":{d:.3}," ++
                    "\"readBps\":{d:.0},\"writeBps\":{d:.0},\"latencyMs\":{d:.3}," ++
                    "\"reads\":{d},\"writes\":{d},\"sparse\":{s}," ++
                    "\"tierRequested\":{d},\"tierGranted\":{d},\"tierClamped\":{s},\"tierStarved\":{s}," ++
                    "\"volumeFree\":{d}}}",
                .{
                    p.ceiling(),
                    st.file_size,
                    st.used,
                    st.allocated,
                    p.saturation(),
                    st.read_bps,
                    st.write_bps,
                    st.latency_ms,
                    st.reads,
                    st.writes,
                    if (p.sparse()) "true" else "false",
                    res.requested,
                    res.granted,
                    if (res.clamped) "true" else "false",
                    if (res.starved) "true" else "false",
                    res.free_at_check,
                },
            ) catch return;
        } else {
            w.writeAll(",\"buffer\":null") catch return;
        }

        // System-wide totals the engine needs for residency decisions.
        w.print(",\"total\":{{\"workingSet\":{d},\"processes\":{d},\"agents\":{d},\"graphics\":{d}}}", .{
            s.totalWorkingSet(),
            s.procs.items.len,
            s.roleCount(.agent),
            s.roleCount(.graphics),
        }) catch return;

        w.writeAll("}") catch return;
        respond(client, "200 OK", "application/json", w.buffered(), null, framing);
    }
};

/// Everything the server needs to answer a request. Passing an explicit context
/// keeps the server free of globals and makes the sampling cadence testable.
pub const Context = struct {
    sampler: *telemetry.Sampler,
    query: *const win.Query,
    engine: *EngineState,
    /// The P:\ capacity pool. Optional so a failure to open it degrades the
    /// dashboard to capacity-less reporting rather than preventing startup.
    pool: ?*pool_mod.Pool = null,
    /// Timestamp of the previous sampling tick, so the pool can turn its byte
    /// counters into a rate without owning a clock.
    last_sample_ms: i64 = 0,
};

/// Extract the method from an HTTP request line: `GET /path HTTP/1.1`.
///
/// The router used to dispatch on path alone, so `POST /api/telemetry` was
/// served as a GET and `GET /api/control` reported `{"ok":true}` having done
/// nothing. The verb is part of the route, not an optional detail on it.
/// A request line that carried both a method and a target.
const RequestLine = struct {
    method: []const u8,
    path: []const u8,
};

/// Parse `GET /path HTTP/1.1`, or return null when the line is not one.
///
/// These were two functions that each supplied their own default: the method
/// defaulted to `"GET"` and the path to `"/"`. A default is a guess, and a
/// guess about a request line is a guess about what the client asked for -- a
/// blank line or a bare `GET` resolved to the dashboard and answered 200, so a
/// client trusting the status code read a valid response to a request it never
/// made. It also produced a wrong answer rather than none: a tab-separated line
/// tokenised to a single token, that token became the *method*, and the result
/// was a 405 advertising `Allow: GET, HEAD` for a request that was never valid.
///
/// RFC 9112 defines the request line as method SP request-target SP
/// HTTP-version. Anything short of a method and a target is malformed, and the
/// honest answer is to say so rather than invent one.
fn parseRequestLine(req: []const u8) ?RequestLine {
    const line_end = std.mem.indexOfScalar(u8, req, '\n') orelse req.len;
    const line = std.mem.trimEnd(u8, req[0..line_end], "\r ");
    var it = std.mem.tokenizeAny(u8, line, " ");
    const method = it.next() orelse return null;
    // A count of tokens cannot tell "the client forgot the method" from "the
    // method is an odd word", because `/ HTTP/1.1` has two tokens. RFC 9110
    // defines `method = token` and a token cannot contain a separator, so this
    // is what stops a missing method being routed as a request for the literal
    // path "HTTP/1.1" and answered 404.
    if (!isMethodToken(method)) return null;
    const target = it.next() orelse return null;
    // Ignore any query string; control arrives over POST bodies instead.
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    return .{ .method = method, .path = path };
}

/// True for the characters RFC 9110 permits in a method token: `tchar`.
fn isMethodToken(m: []const u8) bool {
    if (m.len == 0) return false;
    for (m) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9' => {},
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

/// The request body is everything after the header/body separator.
fn requestBody(req: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "";
    return req[sep + 4 ..];
}

/// Read `key=value` out of the request body.
///
/// Scoping the search to the body is not optional: scanning the whole request
/// makes the first `&`-delimited chunk start at `POST /api/control ...`, so the
/// key comparison fails and every control write silently does nothing.
fn parseParam(req: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, requestBody(req), '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        var v = pair[eq + 1 ..];
        if (v.len > 0 and v[0] == '"') v = v[1..];
        if (v.len > 0 and v[v.len - 1] == '"') v = v[0 .. v.len - 1];
        return v;
    }
    return null;
}

// Static assets are embedded at compile time. The dashboard then ships inside
// the binary: no asset directory to lose and no runtime file I/O. It does not
// mean every request succeeds -- anything outside this set is a 404.
const assets = @import("web_assets");
const index_html = assets.index_html;
const app_js = assets.app_js;
const style_css = assets.style_css;

/// The dashboard's own files.
///
/// One table, read by both the router and the handler. Keeping the list of paths
/// in the router and a second copy in the handler is how a path ends up routable
/// but unservable, or served but unroutable -- two places that have to agree is
/// the same failure this PR just removed from the status code.
pub const Asset = struct { path: []const u8, mime: []const u8, body: []const u8 };

/// Public so the wire suite can derive its coverage from this table rather than
/// keep a second copy of it. A written-out list of asset paths in a test is a
/// second thing that has to agree with the router, and it stops agreeing the
/// day somebody adds an asset here.
pub const ASSETS = [_]Asset{
    .{ .path = "/", .mime = "text/html; charset=utf-8", .body = index_html },
    .{ .path = "/index.html", .mime = "text/html; charset=utf-8", .body = index_html },
    .{ .path = "/app.js", .mime = "application/javascript; charset=utf-8", .body = app_js },
    .{ .path = "/style.css", .mime = "text/css; charset=utf-8", .body = style_css },
};

fn findAsset(path: []const u8) ?Asset {
    for (ASSETS) |a| {
        if (std.mem.eql(u8, path, a.path)) return a;
    }
    return null;
}

/// What the router decided for one `(path, method)` pair.
///
/// A route is the pair, not the path alone: the verb is part of what the server
/// offers for that path, so routing on the path alone let `DELETE /` answer with
/// the dashboard and `GET /api/control` report `{"ok":true}` having written
/// nothing.
///
/// The three payload-free tags are the ones that have a handler; only `.reject`
/// carries a status, so a handler has no status to remember and a miss cannot be
/// reported as a success.
const Route = union(enum) {
    /// Serve the telemetry document.
    telemetry,
    /// Apply a control write.
    control,
    /// Serve the embedded dashboard asset at this path.
    asset: []const u8,
    /// Refuse.
    reject: Rejection,
};

/// Verbs a path accepts, as an `Allow` header value.
///
/// HEAD rides along with GET because a client asking for headers only is asking
/// for the same resource. This server still writes the body for a HEAD, which
/// RFC 9110 does not permit; splitting the two is a larger change than fixing
/// the status code and is left deliberately undone rather than half-done.
fn allowFor(want: []const u8) []const u8 {
    return if (std.mem.eql(u8, want, "GET")) "GET, HEAD" else want;
}

/// Why a request is being refused, including everything the response needs.
const Rejection = struct {
    status: []const u8,
    body: []const u8,
    allow: ?[]const u8 = null,
};

/// Accept `method` for a route that serves `want`, or explain why not.
fn accept(method: []const u8, want: []const u8) ?Rejection {
    if (std.mem.eql(u8, method, want)) return null;
    if (std.mem.eql(u8, want, "GET") and std.mem.eql(u8, method, "HEAD")) return null;
    return .{
        .status = "405 Method Not Allowed",
        .body = "method not allowed\n",
        .allow = allowFor(want),
    };
}

/// The dashboard's own paths. Anything not in this list is a miss.
fn isAssetPath(path: []const u8) bool {
    return findAsset(path) != null;
}

/// The whole routing table, as one pure decision.
///
/// Every status this server can produce is named here, which is what makes the
/// "200 for a missing route" bug unrepresentable rather than merely fixed: there
/// is no path through this function that matches nothing and returns 200.
fn route(path: []const u8, method: []const u8) Route {
    if (std.mem.eql(u8, path, "/api/telemetry")) {
        if (accept(method, "GET")) |why| return .{ .reject = why };
        return .telemetry;
    }
    if (std.mem.eql(u8, path, "/api/control")) {
        if (accept(method, "POST")) |why| return .{ .reject = why };
        return .control;
    }
    if (isAssetPath(path)) {
        if (accept(method, "GET")) |why| return .{ .reject = why };
        return .{ .asset = path };
    }
    return .{ .reject = .{ .status = "404 Not Found", .body = "not found\n" } };
}

/// The status for a parsed request line, including one that is not a request
/// line at all.
///
/// The malformed case is answered here, by the router, for the same reason 404
/// and 405 are: a handler must not have to remember to reject it. It is checked
/// before any lookup because there is nothing to look up -- no method and no
/// target means no route, not a route whose name happens to be missing.
fn routeLine(line: ?RequestLine) Route {
    const parsed = line orelse return .{ .reject = .{
        .status = "400 Bad Request",
        .body = "bad request\n",
    } };
    return route(parsed.path, parsed.method);
}

/// Everything a request line implies: which route, and whether the response
/// carries a body.
///
/// The two travel together because they are facts about the *same* parse.
/// `routeLine` picks the status and `framingFor` picks whether bytes follow the
/// headers, and both read the one `line` produced here. Returning them as a
/// pair is what stops a future edit from routing on one read of the request and
/// framing on another -- the same split the 404 fix removed from the status
/// code, only relocated.
const Decision = struct {
    route: Route,
    framing: Framing,
};

fn routeRequest(req: []const u8) Decision {
    const line = parseRequestLine(req);
    return .{
        .route = routeLine(line),
        // A request line that did not parse is not a HEAD, so its 400 keeps the
        // body it describes. `framingFor("")` is `.body`.
        .framing = framingFor(if (line) |l| l.method else ""),
    };
}

fn serveAsset(client: c.SOCKET, path: []const u8, framing: Framing) void {
    // The router only dispatches here for a path present in ASSETS, so the
    // unwrap cannot fail and this cannot silently serve the wrong file.
    const a = findAsset(path).?;
    respond(client, "200 OK", a.mime, a.body, null, framing);
}

/// Whether the exchange carries a response body.
///
/// `respond` used to send the body unconditionally and knew nothing about the
/// request, so the status was decided by the router while the framing was
/// decided by a writer that had never seen the method -- two places deciding
/// one thing, which is the arrangement PR #4 removed from the status code. The
/// value is computed once in `serveOnce` from the same `method` that routed the
/// request, so the two facts have a single source.
///
/// HEAD is admitted by `accept` exactly where GET is, and suppressed here for
/// exactly the same requests, because both read the same variable.
const Framing = enum { body, headers_only };

fn framingFor(method: []const u8) Framing {
    return if (std.mem.eql(u8, method, "HEAD")) .headers_only else .body;
}

/// The single response emitter. Every status line in this server is written
/// here, so "which code does this return" has one answer rather than one per
/// helper that happens to remember.
fn respond(client: c.SOCKET, status: []const u8, mime: []const u8, body: []const u8, allow: ?[]const u8, framing: Framing) void {
    var head: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&head);
    w.print(
        "HTTP/1.1 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Connection: close\r\n",
        .{ status, mime, body.len },
    ) catch return;
    // RFC 9110 requires Allow on a 405; harmless anywhere else, so it is only
    // written when the router supplied one.
    if (allow) |a| w.print("Allow: {s}\r\n", .{a}) catch return;
    w.writeAll("\r\n") catch return;

    const out = w.buffered();
    _ = c.send(client, out.ptr, @intCast(out.len), 0);
    // Content-Length above is the length a GET would have returned, which is
    // what a HEAD response must advertise -- RFC 9110 says the headers SHOULD
    // match what GET would have sent. Zeroing it would "fix" the framing by
    // lying about the resource instead.
    //
    // The bytes themselves are not sent. Sending them was not cosmetic: a
    // client that reads by Content-Length would consume 5744 bytes of dashboard
    // it never asked for, and on a connection that stayed open those bytes
    // would be the start of the next response.
    if (framing == .body) {
        _ = c.send(client, body.ptr, @intCast(body.len), 0);
    }
}

// ---------------------------------------------------------------------- tests
//
// The routing table is pure, so it is worth asserting directly: the 200-for-a-
// missing-route bug shipped because the dispatch was an `if/else` chain with no
// statement anywhere saying what a miss returns. These tests say it out loud,
// and the wire check in the PR description is what says the socket agrees.

const testing = std.testing;

fn statusOf(r: Route) ?[]const u8 {
    return switch (r) {
        .reject => |why| why.status,
        else => null,
    };
}

test "a path that serves nothing is 404, not 200" {
    const r = route("/nope", "GET");
    try testing.expectEqualStrings("404 Not Found", statusOf(r).?);
    try testing.expectEqualStrings("not found\n", r.reject.body);
    // A miss must not advertise a verb list: there is nothing there to allow.
    try testing.expect(r.reject.allow == null);
}

test "browser and crawler paths that do not exist are 404" {
    for ([_][]const u8{ "/favicon.ico", "/app.js.map", "/index.htm", "/API/telemetry", "/api/telemetry/", "api/telemetry", "" }) |p| {
        try testing.expectEqualStrings("404 Not Found", statusOf(route(p, "GET")).?);
    }
}

test "every dashboard path still routes" {
    try testing.expectEqual(std.meta.activeTag(route("/api/telemetry", "GET")), .telemetry);
    try testing.expectEqual(std.meta.activeTag(route("/api/control", "POST")), .control);
    try testing.expectEqual(std.meta.activeTag(route("/", "GET")), .asset);
    try testing.expectEqual(std.meta.activeTag(route("/index.html", "GET")), .asset);
    try testing.expectEqual(std.meta.activeTag(route("/app.js", "GET")), .asset);
    try testing.expectEqual(std.meta.activeTag(route("/style.css", "GET")), .asset);
}

test "the wrong verb on a real route is 405 with Allow" {
    // The bug this PR fixes: the verb was not part of the route at all, so
    // `DELETE /` answered with the whole dashboard and `GET /api/control`
    // claimed a write it never performed.
    const d = route("/", "DELETE");
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(d).?);
    try testing.expectEqualStrings("GET, HEAD", d.reject.allow.?);

    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(route("/app.js", "PUT")).?);
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(route("/api/control", "GET")).?);
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(route("/api/telemetry", "POST")).?);
}

test "POST on a GET-only route never reaches a handler" {
    // Belt and braces: a 405 on the telemetry path must not carry a payload.
    const r = route("/api/telemetry", "PUT");
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(r).?);
    try testing.expectEqualStrings("GET, HEAD", r.reject.allow.?);
    try testing.expectEqualStrings("method not allowed\n", r.reject.body);
}

test "the control route does not answer GET" {
    // Only the verb guard can stop this; there is no body check behind it.
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(route("/api/control", "GET")).?);
    try testing.expectEqualStrings("POST", route("/api/control", "GET").reject.allow.?);
}

test "HEAD is accepted wherever GET is" {
    for ([_][]const u8{ "/", "/index.html", "/app.js", "/style.css", "/api/telemetry" }) |p| {
        try testing.expect(statusOf(route(p, "HEAD")) == null);
    }
}

test "the method comes off the request line" {
    try testing.expectEqualStrings("GET", parseRequestLine("GET / HTTP/1.1\r\nHost: x\r\n\r\n").?.method);
    try testing.expectEqualStrings("POST", parseRequestLine("POST /api/control HTTP/1.1\r\n\r\n").?.method);
    try testing.expectEqualStrings("DELETE", parseRequestLine("DELETE / HTTP/1.1\r\n\r\n").?.method);
}

test "the path drops the query string" {
    try testing.expectEqualStrings("/api/telemetry", parseRequestLine("GET /api/telemetry?x=1 HTTP/1.1\r\n\r\n").?.path);
    try testing.expectEqualStrings("/", parseRequestLine("GET /?x=1 HTTP/1.1\r\n\r\n").?.path);
}

// ------------------------------------------------------------ malformed lines

test "a request line that is not one is 400, not the dashboard" {
    // Every one of these used to resolve to "GET /" and answer 200 with 5744
    // bytes of dashboard, because the method defaulted to "GET" and the path
    // to "/". Measured over a socket, not assumed.
    const malformed = [_][]const u8{
        "\r\n\r\n", // blank request line
        "\n", // a bare newline
        "GET\r\n\r\n", // method with no target
        "GET \r\n\r\n", // method, separator, no target
        "   \r\n", // separators only
        "GET\t/\tHTTP/1.1\r\n\r\n", // tabs are not the SP separator
        "/ HTTP/1.1\r\n\r\n", // target with no method
        "\r\n",
    };
    for (malformed) |req| {
        const r = routeRequest(req).route;
        try testing.expectEqualStrings("400 Bad Request", statusOf(r).?);
        try testing.expectEqualStrings("bad request\n", r.reject.body);
        // A malformed request has no target, so it must not advertise a verb
        // list -- that was how a tab-separated line produced a 405 promising
        // "GET, HEAD" for a request that was never valid.
        try testing.expect(r.reject.allow == null);
    }
}

test "a 400 does not leak the dashboard" {
    // The failure being fixed was a 200 carrying the whole index page.
    const r = routeRequest("\r\n\r\n").route;
    try testing.expectEqualStrings("bad request\n", r.reject.body);
    try testing.expect(r.reject.body.len < index_html.len);
}

test "a well-formed request line still routes" {
    // The regression this must not cause: stricter parsing rejecting real
    // traffic. These are the exact shapes the PR verified over a socket.
    try testing.expectEqual(std.meta.activeTag(routeRequest("GET / HTTP/1.1\r\n\r\n").route), .asset);
    try testing.expectEqual(std.meta.activeTag(routeRequest("GET /api/telemetry HTTP/1.1\r\n\r\n").route), .telemetry);
    try testing.expectEqual(std.meta.activeTag(routeRequest("POST /api/control HTTP/1.1\r\n\r\npower=MAX").route), .control);
    try testing.expectEqual(std.meta.activeTag(routeRequest("HEAD / HTTP/1.1\r\n\r\n").route), .asset);
    try testing.expectEqual(std.meta.activeTag(routeRequest("GET /app.js HTTP/1.1\r\n\r\n").route), .asset);
}

test "a request line without a trailing newline is still valid" {
    // A client that sends the line and stops is normal enough on loopback;
    // rejecting it would be stricter than the bug being fixed.
    const line = parseRequestLine("GET /api/telemetry HTTP/1.1").?;
    try testing.expectEqualStrings("GET", line.method);
    try testing.expectEqualStrings("/api/telemetry", line.path);
}

test "leading separators do not make a valid line malformed" {
    const line = parseRequestLine("  GET / HTTP/1.1\r\n\r\n").?;
    try testing.expectEqualStrings("GET", line.method);
    try testing.expectEqualStrings("/", line.path);
}

test "malformed is decided before any route lookup" {
    // A miss is 404 and a malformed line is 400; they must not be confused.
    try testing.expectEqualStrings("404 Not Found", statusOf(routeRequest("GET /nope HTTP/1.1\r\n\r\n").route).?);
    try testing.expectEqualStrings("400 Bad Request", statusOf(routeRequest("GET\r\n\r\n").route).?);
}

test "no verb reaches a handler for a path that does not exist" {
    for ([_][]const u8{ "GET", "POST", "HEAD", "PUT", "DELETE" }) |m| {
        try testing.expectEqualStrings("404 Not Found", statusOf(route("/nope", m)).?);
    }
}

// ------------------------------------------------------------------- framing

test "HEAD is admitted wherever GET is" {
    // The router already admitted HEAD beside GET. Framing now agrees with it
    // because both read the same `method`; this pins the pairing.
    for ([_][]const u8{ "/", "/index.html", "/app.js", "/style.css" }) |p| {
        try testing.expectEqual(std.meta.activeTag(route(p, "HEAD")), std.meta.activeTag(route(p, "GET")));
        try testing.expectEqual(Framing.headers_only, framingFor("HEAD"));
    }
}

test "only HEAD suppresses the body" {
    try testing.expectEqual(Framing.headers_only, framingFor("HEAD"));
    for ([_][]const u8{ "GET", "POST", "PUT", "DELETE", "BREW", "get" }) |m| {
        try testing.expectEqual(Framing.body, framingFor(m));
    }
}

test "framing is case-sensitive, matching HTTP method semantics" {
    // RFC 9110 methods are case-sensitive, so a lowercase "head" is not HEAD and
    // is not a verb this server serves -- it must not silently get HEAD framing.
    try testing.expectEqual(Framing.body, framingFor("head"));
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(route("/", "head")).?);
}

test "HEAD on a miss is still a 404, and still framed as headers-only" {
    try testing.expectEqualStrings("404 Not Found", statusOf(route("/nope", "HEAD")).?);
    try testing.expectEqual(Framing.headers_only, framingFor("HEAD"));
}

test "every asset has a body for Content-Length to describe" {
    // `respond` formats Content-Length from `body.len` before it consults
    // `framing`, so a HEAD advertises exactly the length GET would have
    // returned. Asserting that the length is non-zero and is the embedded
    // asset's own length is the part provable here; that the number reaches
    // the wire while the bytes do not is observable only over a socket, and is
    // verified there rather than pretended at here.
    for ([_][]const u8{ "/", "/index.html", "/app.js", "/style.css" }) |p| {
        const a = findAsset(p).?;
        try testing.expect(a.body.len > 0);
    }
    // The 404 body a HEAD advertises is the same 10 bytes GET would have sent.
    const body = route("/nope", "HEAD").reject.body;
    try testing.expectEqualStrings("not found\n", body);
    try testing.expectEqual(@as(usize, 10), body.len);
}
