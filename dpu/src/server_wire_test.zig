//! Wire-level conformance tests for the dashboard's HTTP server.
//!
//! The tests in server.zig call the router, the framing rule and the parser
//! directly. That is the right level for "does a miss return 404" and the wrong
//! level for "does the client see 404", because every one of those assertions
//! stops at the function boundary. Nothing in the unit suite opens a socket,
//! formats a status line, or compares a `Content-Length` header against the
//! bytes that actually followed it -- so a regression in `respond` itself, the
//! one function every response in this server goes through, would sail through
//! a green gate.
//!
//! That is not hypothetical: the 200-for-a-miss bug shipped with 21 passing
//! tests, because `respond404` built the right body and then delegated to
//! `respond200`, which hardcoded the status line. Nothing that stopped at the
//! router could see it.
//!
//! These tests therefore drive the real thing. A `Server` is bound once to an
//! ephemeral port, and every request is a real loopback connection whose
//! response is read off a socket and parsed. There is no mock and no shim.
//!
//! ## Why one server for the whole file
//!
//! `serveOnce` blocks in `accept` until a client arrives, so driving it needs a
//! client on the other end. Starting a server per test would mean a bind, a
//! listen, a WSAStartup and a teardown per case, which is the slow way to
//! learn nothing. Instead the harness holds one bound server and one `Context`
//! for the life of the test binary, and each exchange is:
//!
//!   1. connect, so the socket is sitting in the accept backlog,
//!   2. write the request,
//!   3. call `serveOnce`, which accepts exactly that socket and answers it,
//!   4. read the response to EOF from the client side.
//!
//! Step 3 runs on the test's own thread, so there is no server thread, no
//! shutdown race and no timeout on the accept: the ordering is the caller's,
//! and the only thing that can block is a `recv` on a client that has already
//! been queued. The cost per case is one loopback round trip.
//!
//! ## Isolation
//!
//! `ctx.pool` is null and the sampler's pool path is a volume that cannot
//! exist, so nothing here reads or writes the live `P:\DPU\pool.vram`. The one
//! test that mutates engine state restores it before it returns.

const std = @import("std");
const testing = std.testing;
const win = @import("win");
const telemetry = @import("telemetry.zig");
const server = @import("server.zig");

const c = win.c;

/// A volume that cannot exist, so the telemetry route reports no capacity.
/// Pointing the sampler at `P:\` would make these tests depend on a machine
/// detail, and would mean a gate run touching the live pool.
const NO_POOL: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\dpu-wire-test-no-such-volume\\");

/// One real counter, so the telemetry document has a `counters` object to
/// serialize. `Query.sample` over an empty set is legal but would leave that
/// branch of the document untested.
const TEST_COUNTER_PATH = "\\Memory\\Available Bytes";
const TEST_COUNTER_KEY = "mem_available";

const Response = struct {
    /// The complete bytes received, headers and body.
    raw: []const u8,
    /// The status line with the `HTTP/1.1 ` prefix removed, e.g. `200 OK`.
    status: []const u8,
    body: []const u8,
    content_length: ?usize = null,
    allow: ?[]const u8 = null,
    connection: ?[]const u8 = null,

    /// Parse one response off the wire.
    ///
    /// Deliberately strict: a response with no header terminator is an error
    /// rather than an empty body, because a silent truncation here would turn
    /// the `Content-Length` assertions into comparisons against whatever
    /// happened to arrive.
    fn parse(buf: []const u8) !Response {
        const sep = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.NoHeaderTerminator;
        var lines = std.mem.splitScalar(u8, buf[0..sep], '\n');
        const status_line = std.mem.trimEnd(u8, lines.next() orelse return error.Empty, "\r");
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ")) return error.NotHttp11;

        var r = Response{
            .raw = buf,
            .status = status_line["HTTP/1.1 ".len..],
            .body = buf[sep + 4 ..],
        };
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) {
                r.content_length = std.fmt.parseInt(usize, value, 10) catch
                    return error.BadContentLength;
            } else if (std.ascii.eqlIgnoreCase(line[0..colon], "allow")) {
                r.allow = value;
            } else if (std.ascii.eqlIgnoreCase(line[0..colon], "connection")) {
                r.connection = value;
            }
        }
        return r;
    }

    /// Assert the invariant every response in this server owes its client:
    /// the declared length is the number of bytes that followed the headers.
    ///
    /// This is not a restatement of what `respond` does. `respond` computes the
    /// header from `body.len` and then sends the body under an independent
    /// `if`, so the two can disagree -- and for HEAD they are *supposed* to
    /// disagree, which is exactly why the rule is worth asserting on the wire
    /// rather than trusting the emitter.
    fn expectLengthMatchesBody(self: Response) !void {
        const declared = self.content_length orelse return error.NoContentLength;
        try testing.expectEqual(declared, self.body.len);
    }
};

const Harness = struct {
    srv: server.Server,
    engine: server.EngineState,
    sampler: telemetry.Sampler,
    query: win.Query,
    ctx: server.Context,
    port: u16,
    buf: []u8,
    /// Scratch for `get`. Separate from `buf`, which holds the response being
    /// read; a request built while a response is still arriving must not land
    /// on top of it.
    req: [512]u8 = undefined,
    /// Whether a connection is sitting in the backlog waiting for `serve`.
    queued: bool = false,

    fn create() !*Harness {
        // page_allocator: this lives for the whole test binary and is never
        // freed, and std.testing.allocator would fail the run on a leak that is
        // deliberate here -- one server, one PDH query, one sampler.
        const gpa = std.heap.page_allocator;
        const h = try gpa.create(Harness);
        h.* = undefined;

        h.sampler = telemetry.Sampler.init(gpa, NO_POOL);
        h.query = try win.Query.init(gpa);
        // Missing counters degrade one field rather than failing startup, so
        // this cannot fail the run on a machine without that counter.
        h.query.add(TEST_COUNTER_PATH, TEST_COUNTER_KEY) catch {};

        h.engine = .{};
        h.engine.booted_at_ms = server.EngineState.nowMs();

        // Port 0: the OS picks a free port, so these tests cannot collide with
        // a running engine on 8787 or with a second test binary.
        h.srv = try server.Server.bind(0);
        h.port = try boundPort(h.srv.listen_fd);

        h.ctx = .{
            .sampler = &h.sampler,
            .query = &h.query,
            .engine = &h.engine,
            .pool = null,
            .last_sample_ms = h.engine.booted_at_ms,
        };
        h.buf = try gpa.alloc(u8, 1 << 20);
        return h;
    }

    /// Ask the OS which port the listener actually got.
    fn boundPort(fd: c.SOCKET) !u16 {
        var addr: c.sockaddr_in = undefined;
        var len: c_int = @intCast(@sizeOf(c.sockaddr_in));
        if (c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.GetsocknameFailed;
        return std.mem.bigToNative(u16, addr.sin_port);
    }

    /// Connect without sending anything, leaving the socket in the backlog for
    /// the next `serve`.
    fn open(self: *Harness) !c.SOCKET {
        const s = c.socket(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP);
        if (s == c.INVALID_SOCKET) return error.SocketFailed;
        errdefer _ = c.closesocket(s);

        // A large receive buffer, set before connect so it applies to this
        // socket. `respond` writes headers and body with two `send` calls and
        // ignores a short write, so a client that cannot take 18 KiB in one go
        // would silently truncate the body and turn a correct server into a
        // flaky test.
        var rcv: c_int = 256 * 1024;
        _ = c.setsockopt(s, c.SOL_SOCKET, c.SO_RCVBUF, @ptrCast(&rcv), @sizeOf(c_int));

        var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        addr.sin_family = c.AF_INET;
        addr.sin_port = std.mem.bigToNative(u16, self.port);
        addr.sin_addr.S_un.S_addr = @bitCast(@as(u32, 0x0100_007F)); // 127.0.0.1
        if (c.connect(s, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) != 0) return error.ConnectFailed;
        self.queued = true;
        return s;
    }

    /// Answer the queued connection. Blocking here is bounded: the caller has
    /// already connected, so `accept` returns as soon as it is called.
    ///
    /// `serveOnce` serves whichever connection is next in the accept backlog,
    /// not a socket it is handed -- it takes no socket. So a test that opens a
    /// connection and then lets something else serve will block forever in the
    /// server's `recv` on a client that never sent anything. `queued` turns
    /// that mistake into an immediate, loud abort instead of a hung gate.
    fn serve(self: *Harness) void {
        if (!self.queued) {
            @panic("serve() called with no connection queued: open() and serve() must alternate, and nothing may open a second connection in between");
        }
        self.queued = false;
        self.srv.serveOnce(&self.ctx);
    }

    fn readToEof(self: *Harness, s: c.SOCKET) ![]const u8 {
        var total: usize = 0;
        while (total < self.buf.len) {
            const n = c.recv(s, self.buf.ptr + total, @intCast(self.buf.len - total), 0);
            if (n > 0) {
                total += @intCast(n);
                continue;
            }
            if (n == 0) break; // server closed, as `Connection: close` promised
            // A read timeout means "nothing more arrived", which for this
            // server is the same fact as EOF: it always closes.
            if (c.WSAGetLastError() == c.WSAETIMEDOUT) break;
            return error.RecvFailed;
        }
        if (total == 0) return error.NoResponse;
        return self.buf[0..total];
    }

    /// One request/response exchange over a fresh connection.
    fn exchange(self: *Harness, raw: []const u8) !Response {
        const s = try self.open();
        defer _ = c.closesocket(s);
        setTimeoutMs(s, 5000);
        if (c.send(s, raw.ptr, @intCast(raw.len), 0) != @as(c_int, @intCast(raw.len))) {
            return error.ShortSend;
        }
        self.serve();
        return Response.parse(try self.readToEof(s));
    }

    /// Build a plain request line request into the harness's own buffer.
    ///
    /// A comptime-concatenated builder looks tidier but cannot be called from a
    /// table row, and every table here is the interesting part.
    fn get(self: *Harness, method: []const u8, path: []const u8) ![]const u8 {
        var w = std.Io.Writer.fixed(&self.req);
        w.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", .{ method, path }) catch
            return error.RequestTooLong;
        return w.buffered();
    }
};

fn setTimeoutMs(s: c.SOCKET, ms: u32) void {
    const tv = c.timeval{
        .tv_sec = @intCast(ms / 1000),
        .tv_usec = @intCast((ms % 1000) * 1000),
    };
    _ = c.setsockopt(s, c.SOL_SOCKET, c.SO_RCVTIMEO, @ptrCast(&tv), @intCast(@sizeOf(c.timeval)));
}

var shared: ?*Harness = null;

/// The one bound server, created on first use and shared by every test here.
fn harness() !*Harness {
    if (shared == null) shared = try Harness.create();
    return shared.?;
}

// ---------------------------------------------------------------- the matrix

const MatrixRow = struct {
    method: []const u8,
    path: []const u8,
    status: []const u8,
    /// The `Allow` header, or null when the response must not carry one.
    allow: ?[]const u8,
};

/// Every case the external route matrix exercises, with the status it claims.
/// A miss must not advertise `Allow`: there is nothing there to allow, and a
/// verb list on a 404 is the same class of mistake as a 200 on a miss.
const MATRIX = [_]MatrixRow{
    .{ .method = "GET", .path = "/", .status = "200 OK", .allow = null },
    .{ .method = "GET", .path = "/style.css", .status = "200 OK", .allow = null },
    .{ .method = "GET", .path = "/app.js", .status = "200 OK", .allow = null },
    .{ .method = "GET", .path = "/index.html", .status = "200 OK", .allow = null },
    .{ .method = "GET", .path = "/api/telemetry", .status = "200 OK", .allow = null },
    .{ .method = "GET", .path = "/nope", .status = "404 Not Found", .allow = null },
    .{ .method = "GET", .path = "/favicon.ico", .status = "404 Not Found", .allow = null },
    .{ .method = "GET", .path = "/app.js.map", .status = "404 Not Found", .allow = null },
    .{ .method = "GET", .path = "/API/telemetry", .status = "404 Not Found", .allow = null },
    .{ .method = "GET", .path = "/api/telemetry/", .status = "404 Not Found", .allow = null },
    .{ .method = "GET", .path = "/api/control", .status = "405 Method Not Allowed", .allow = "POST" },
    .{ .method = "POST", .path = "/api/control", .status = "200 OK", .allow = null },
    .{ .method = "POST", .path = "/api/telemetry", .status = "405 Method Not Allowed", .allow = "GET, HEAD" },
    .{ .method = "PUT", .path = "/api/telemetry", .status = "405 Method Not Allowed", .allow = "GET, HEAD" },
    .{ .method = "DELETE", .path = "/", .status = "405 Method Not Allowed", .allow = "GET, HEAD" },
    // An unknown verb is a method problem, not a route problem: the path
    // exists and accepts GET, so this is 405 and must say which verbs it takes.
    .{ .method = "BREW", .path = "/api/telemetry", .status = "405 Method Not Allowed", .allow = "GET, HEAD" },
};

test "every route in the matrix answers the status it claims" {
    const h = try harness();
    for (MATRIX) |row| {
        const r = try h.exchange(try h.get(row.method, row.path));
        std.testing.expectEqualStrings(row.status, r.status) catch |e| {
            std.debug.print("\n  {s} {s}\n", .{ row.method, row.path });
            return e;
        };
        if (row.allow) |want| {
            std.testing.expectEqualStrings(want, r.allow orelse "<absent>") catch |e| {
                std.debug.print("\n  {s} {s}: Allow\n", .{ row.method, row.path });
                return e;
            };
        } else {
            try testing.expect(r.allow == null);
        }
        // Every one of these statuses owes the client a body, and owes it a
        // length that matches. An empty body here would mean the emitter gave
        // up mid-write.
        try testing.expect(r.body.len > 0);
        try r.expectLengthMatchesBody();
        try testing.expectEqualStrings("close", r.connection orelse "<absent>");
    }
}

test "the dashboard body on the wire is the dashboard" {
    // Anchors the lengths above to real content. Without this, a response of
    // the right size carrying the wrong bytes would satisfy every count-based
    // assertion in this file.
    const h = try harness();
    const r = try h.exchange(try h.get("GET", "/"));
    try testing.expect(std.mem.startsWith(u8, r.body, "<!DOCTYPE html>"));
    try testing.expect(std.mem.indexOf(u8, r.body, "</html>") != null);
    // The two spellings of the same document must agree byte for byte.
    const alt = try h.exchange(try h.get("GET", "/index.html"));
    try testing.expectEqualStrings(r.body, alt.body);
    try testing.expectEqual(r.content_length.?, alt.content_length.?);
}

// ------------------------------------------------------------ the malformed six

/// The request lines #6 promised to reject. Each is a shape a client can
/// actually put on the wire, not a string that merely looks odd.
const MALFORMED = [_]struct { label: []const u8, payload: []const u8 }{
    .{ .label = "a blank request line", .payload = "\r\n\r\n" },
    .{ .label = "a bare method with no target", .payload = "GET\r\n\r\n" },
    .{ .label = "a method and a space with no target", .payload = "GET \r\n\r\n" },
    .{ .label = "separators only", .payload = "   \r\n\r\n" },
    .{ .label = "a tab-separated request line", .payload = "GET\t/\tHTTP/1.1\r\n\r\n" },
    .{ .label = "a single LF", .payload = "\n" },
};

test "a request line that is not one is 400, and carries no dashboard" {
    const h = try harness();
    for (MALFORMED) |cs| {
        const r = h.exchange(cs.payload) catch |e| {
            std.debug.print("\n  {s}: {s}\n", .{ cs.label, @errorName(e) });
            return e;
        };
        std.testing.expectEqualStrings("400 Bad Request", r.status) catch |e| {
            std.debug.print("\n  {s}\n", .{cs.label});
            return e;
        };
        // The body is exactly this and nothing else. A request line that
        // failed to parse used to fall back to `GET /` and answer 200 with
        // 5744 bytes of HTML, so the length is part of the assertion.
        try testing.expectEqualStrings("bad request\n", r.body);
        try r.expectLengthMatchesBody();
        // Named explicitly because it is the regression, not because the exact
        // body above does not already imply it.
        try testing.expect(std.mem.indexOf(u8, r.body, "<!DOCTYPE") == null);
        try testing.expect(std.mem.indexOf(u8, r.body, "<html") == null);
    }
}

test "a malformed line is 400 even when its target names no route" {
    // The malformed check runs before any route lookup, and on the wire that
    // is an observable ordering rather than an internal one: each of these
    // names a path that does not exist, so a router that looked the path up
    // first would answer 404 and tell the client whether /nope is real. A 400
    // answers the same way for a path that exists, one that does not, and one
    // that was never named at all.
    //
    // Distinct from the six-shape test above, which only ever asserts the body
    // of a malformed line that carries no usable target.
    //
    // Every shape here is broken in the *method* or the *separators*, never
    // merely unusual: `GE T /nope` is a well-formed request for the path `T`
    // and is correctly a 404, so it belongs in the unusual-but-valid test
    // rather than here.
    const malformed_missing_route = [_][]const u8{
        "GET\t/nope\tHTTP/1.1\r\n\r\n",
        " /nope HTTP/1.1\r\n\r\n",
        "GE/T /nope HTTP/1.1\r\n\r\n",
        "GE(T /nope HTTP/1.1\r\n\r\n",
    };
    const h = try harness();

    // The control: a well-formed line for the same path is a 404, so the 400s
    // below are caused by the malformed line and not by the path.
    const control = try h.exchange(try h.get("GET", "/nope"));
    try testing.expectEqualStrings("404 Not Found", control.status);

    for (malformed_missing_route) |payload| {
        const r = h.exchange(payload) catch |e| {
            std.debug.print("\n  {s}: {s}\n", .{ payload, @errorName(e) });
            return e;
        };
        std.testing.expectEqualStrings("400 Bad Request", r.status) catch |e| {
            std.debug.print("\n  {s}\n", .{payload});
            return e;
        };
        try testing.expectEqualStrings("bad request\n", r.body);
        try r.expectLengthMatchesBody();
    }
}

// ------------------------------------------------------- valid shapes survive

/// The other side of #6: rejecting a bad request line must not reject a good
/// one. Each of these is unusual but legal, and each broke under an earlier
/// version of the parser.
const VALID_UNUSUAL = [_]struct { label: []const u8, payload: []const u8, status: []const u8 }{
    // No CRLF at all: the line ends where the read ends.
    .{ .label = "no trailing CRLF", .payload = "GET / HTTP/1.1", .status = "200 OK" },
    .{ .label = "leading space", .payload = " GET / HTTP/1.1\r\n\r\n", .status = "200 OK" },
};

test "valid request lines that look unusual still route" {
    const h = try harness();
    for (VALID_UNUSUAL) |cs| {
        const r = h.exchange(cs.payload) catch |e| {
            std.debug.print("\n  {s}: {s}\n", .{ cs.label, @errorName(e) });
            return e;
        };
        std.testing.expectEqualStrings(cs.status, r.status) catch |e| {
            std.debug.print("\n  {s}\n", .{cs.label});
            return e;
        };
        try r.expectLengthMatchesBody();
    }
}

test "a control write is visible in the telemetry that follows it" {
    // The dashboard's right-hand matrix is a POST followed by a GET, and until
    // now that pairing was only ever checked by clicking in a browser. This is
    // the same exchange over the wire, which is what makes it a gate check
    // rather than a demo.
    const h = try harness();

    const before = try h.exchange(try h.get("GET", "/api/telemetry"));
    try testing.expect(std.mem.indexOf(u8, before.body, "\"power\":\"xHIGH\"") != null);

    const write = try h.exchange(
        "POST /api/control HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 10\r\n\r\npower=low",
    );
    try testing.expectEqualStrings("200 OK", write.status);
    try testing.expectEqualStrings("{\"ok\":true}", write.body);
    try write.expectLengthMatchesBody();

    const after = try h.exchange(try h.get("GET", "/api/telemetry"));
    try testing.expect(std.mem.indexOf(u8, after.body, "\"power\":\"LOW\"") != null);
    // Prefetch is derived from the mode, so it moves with it.
    try testing.expect(std.mem.indexOf(u8, after.body, "\"prefetch\":1") != null);

    // Restore the default so this test does not leak state into the ones after
    // it. Tests run in declaration order, so relying on that is fine -- but
    // leaving the engine pinned to LOW for the rest of the run is not.
    const restore = try h.exchange(
        "POST /api/control HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 11\r\n\r\npower=xhigh",
    );
    try testing.expectEqualStrings("200 OK", restore.status);
    const final = try h.exchange(try h.get("GET", "/api/telemetry"));
    try testing.expect(std.mem.indexOf(u8, final.body, "\"power\":\"xHIGH\"") != null);
}

// ------------------------------------------------------------------- HEAD

/// Paths checked for the HEAD contract: the three distinct assets, the second
/// spelling of the dashboard, and two misses. HEAD on a miss matters as much as
/// HEAD on a hit -- "no body" has to be a property of the response path, not of
/// the asset table.
const HEAD_PATHS = [_][]const u8{ "/", "/index.html", "/style.css", "/app.js", "/nope", "/app.js.map" };

test "HEAD advertises the length GET returns, and sends no bytes" {
    const h = try harness();
    for (HEAD_PATHS) |path| {
        const get = try h.exchange(try h.get("GET", path));
        const head = try h.exchange(try h.get("HEAD", path));

        // Same status: HEAD is not a different request, it is the same
        // response without the body.
        std.testing.expectEqualStrings(get.status, head.status) catch |e| {
            std.debug.print("\n  HEAD {s}: status\n", .{path});
            return e;
        };
        // The advertised length is the one a GET would have produced, taken
        // from both sides of the wire rather than from the header alone.
        try testing.expect(get.body.len > 0);
        std.testing.expectEqual(get.body.len, head.content_length.?) catch |e| {
            std.debug.print("\n  HEAD {s}: GET returned {d} bytes, HEAD advertised {d}\n", .{
                path, get.body.len, head.content_length.?,
            });
            return e;
        };
        // And nothing followed the headers.
        try testing.expectEqual(@as(usize, 0), head.body.len);
    }
}

test "only HEAD suppresses the body" {
    // The negative case for the one above. If framing were decided by the path
    // or by the status rather than by the method, one of these would come back
    // empty -- and a HEAD assertion alone would not notice, because it only
    // ever looks at responses that are already empty.
    const h = try harness();
    for ([_][]const u8{ "/", "/style.css", "/nope" }) |path| {
        for ([_][]const u8{ "GET", "POST", "PUT", "DELETE", "BREW" }) |method| {
            const r = try h.exchange(try h.get(method, path));
            // Every one of these owes a body: the asset, or the `not found`
            // / `method not allowed` text the status promises.
            std.testing.expect(r.body.len > 0) catch |e| {
                std.debug.print("\n  {s} {s} -> {s} with an empty body\n", .{ method, path, r.status });
                return e;
            };
            try r.expectLengthMatchesBody();
        }
    }
    // `HEAD` in another case is a different method and must keep its body.
    const lower = try h.exchange("head / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    try testing.expectEqualStrings("405 Method Not Allowed", lower.status);
    try testing.expect(lower.body.len > 0);
}

test "a HEAD connection carries no phantom body and is closed after it" {
    // The framing bug cannot be caught from the response alone: `respond`
    // advertised the right Content-Length and could still have written the
    // body anyway, leaving 5744 bytes in the socket that a client reading by
    // Content-Length would swallow as the start of the next response. So this
    // reads the header block only and then checks that not one further byte is
    // available.
    const h = try harness();

    // First an ordinary exchange, to pin the status and the framing.
    const head_only = try h.exchange("HEAD / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    try testing.expectEqualStrings("200 OK", head_only.status);
    try testing.expectEqual(@as(usize, 0), head_only.body.len);

    // Then the same request again on its own connection, reading only the
    // header block and probing the socket for anything after it. Opened after
    // the exchange above, never alongside it: `serveOnce` takes whichever
    // connection is next in the backlog.
    const s = try h.open();
    defer _ = c.closesocket(s);
    setTimeoutMs(s, 5000);

    var probe: [1]u8 = undefined;
    const timeout = c.timeval{ .tv_sec = 0, .tv_usec = 300 * 1000 };
    _ = c.setsockopt(s, c.SOL_SOCKET, c.SO_RCVTIMEO, @ptrCast(&timeout), @intCast(@sizeOf(c.timeval)));

    const request = try h.get("HEAD", "/");
    if (c.send(s, request.ptr, @intCast(request.len), 0) != @as(c_int, @intCast(request.len))) {
        return error.ShortSend;
    }
    h.serve();

    var head: [4096]u8 = undefined;
    const head_len = try readHeadOnly(s, &head);
    const parsed = try Response.parse(head[0..head_len]);
    try testing.expectEqualStrings("200 OK", parsed.status);
    try testing.expect(parsed.content_length.? > 0);

    // The phantom check. Zero bytes may be here only if the server withheld
    // the body; the Content-Length above says the length a GET owed, so
    // anything at all on this socket is a body that should not exist.
    const extra = c.recv(s, probe[0..].ptr, 1, 0);
    try testing.expect(extra <= 0);

    // `Connection: close` was declared, so a second request down this socket
    // gets no second response rather than the tail of a first one.
    const second = try h.get("GET", "/");
    _ = c.send(s, second.ptr, @intCast(second.len), 0);
    const tail = c.recv(s, probe[0..].ptr, 1, 0);
    try testing.expect(tail <= 0);
}

/// Read up to and including the header terminator, leaving any body in the
/// socket for the caller to look for.
fn readHeadOnly(s: c.SOCKET, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.recv(s, buf.ptr + total, @intCast(buf.len - total), 0);
        if (n > 0) {
            total += @intCast(n);
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |i| return i + 4;
            continue;
        }
        if (n == 0) break;
        if (c.WSAGetLastError() == c.WSAETIMEDOUT) break;
        return error.RecvFailed;
    }
    return error.NoHeaderTerminator;
}
