//! A loopback HTTP client for testing a server that serves one connection at a
//! time.
//!
//! This is test support, not production: nothing outside a test root imports
//! it. It exists so that `server_wire_test.zig` can contain no socket calls at
//! all -- the contract of what DPU promises over the wire lives in one file,
//! and the mechanics of asking a socket a question live in this one. The
//! boundary is worth the extra file because the two change for unrelated
//! reasons: this module changes when the harness needs a better way to read a
//! socket, and the other changes when a route, a status or a body changes.
//!
//! ## Why one server for the whole run
//!
//! `serveOnce` blocks in `accept` until a client arrives, so driving it needs a
//! client on the other end. Binding a server per test would mean a bind, a
//! listen, a WSAStartup and a teardown per case -- the slow way to learn
//! nothing. Instead the harness holds one bound server and one `Context` for
//! the life of the test binary, and each exchange is:
//!
//!   1. connect, so the socket is sitting in the accept backlog,
//!   2. write the request,
//!   3. call `serveOnce`, which accepts exactly that socket and answers it,
//!   4. read the response back off the client side.
//!
//! Step 3 runs on the caller's own thread, so there is no server thread, no
//! shutdown race and no timeout on the accept: the ordering is the caller's,
//! and the only thing that can block is a `recv` on a client that has already
//! been queued. The cost per case is one loopback round trip.
//!
//! ## Isolation
//!
//! `ctx.pool` is null and the sampler's pool path is a volume that cannot
//! exist, so nothing here reads or writes the live `P:\DPU\pool.vram`.

const std = @import("std");
const testing = std.testing;
const win = @import("win");
const telemetry = @import("telemetry.zig");
const pool_mod = @import("pool.zig");
const server = @import("server.zig");
const server_context = @import("server/context.zig");

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

/// How long a test will wait for a response before deciding the server is not
/// going to send one. Generous, because a loaded machine is the common case,
/// not the interesting one.
const READ_TIMEOUT_MS: u32 = 5000;

/// How long `bytesAvailable` waits before concluding that nothing is coming.
const PROBE_TIMEOUT_MS: u32 = 300;

/// One response, as read off a socket.
///
/// Parsing is deliberately strict: a response with no header terminator is an
/// error rather than an empty body, because a silent truncation here would
/// turn every `Content-Length` assertion into a comparison against whatever
/// happened to arrive.
pub const Response = struct {
    /// The complete bytes received, headers and body.
    raw: []const u8,
    /// The status line with the `HTTP/1.1 ` prefix removed, e.g. `200 OK`.
    status: []const u8,
    body: []const u8,
    content_length: ?usize = null,
    allow: ?[]const u8 = null,
    connection: ?[]const u8 = null,

    pub fn parse(buf: []const u8) !Response {
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

    /// Assert the invariant every HTTP response owes its client: the declared
    /// length is the number of bytes that followed the headers.
    ///
    /// This is not a restatement of what the DPU server's `respond` does.
    /// `respond` computes the header from `body.len` and then sends the body
    /// under an independent `if`, so the two can disagree -- and for HEAD they
    /// are *supposed* to disagree, which is exactly why the rule is worth
    /// asserting on the wire rather than trusting the emitter.
    pub fn expectLengthMatchesBody(self: Response) !void {
        const declared = self.content_length orelse return error.NoContentLength;
        try testing.expectEqual(declared, self.body.len);
    }
};

/// The server under test, plus the one client socket factory.
pub const Harness = struct {
    srv: server.Server,
    engine: server_context.EngineState,
    sampler: telemetry.Sampler,
    query: win.Query,
    ctx: server_context.Context,
    port: u16,
    buf: []u8,
    /// Scratch for request building. Separate from `buf`, which holds the
    /// response being read; a request built while a response is still
    /// arriving must not land on top of it.
    req: [1024]u8 = undefined,
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
        h.engine.booted_at_ms = server_context.EngineState.nowMs();

        // Port 0: the OS picks a free port, so these tests cannot collide with
        // a running engine on 8787 or with a second test binary.
        h.srv = try server.Server.bind(0);
        h.port = try boundPort(h.srv.listen_fd);

        // One allocation owns the fixture, so `ctx` points into `self`. That is
        // deliberate: the alternative is a struct of pointers that must be
        // threaded through every call for no gain, given the harness outlives
        // the process anyway.
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

    /// Send a request line request for `method path` and read the answer.
    ///
    /// The label is derived rather than passed, so a failure names the request
    /// that caused it and no call site can forget to.
    pub fn get(self: *Harness, method: []const u8, path: []const u8) !Response {
        var lbl: [256]u8 = undefined;
        const label = std.fmt.bufPrint(&lbl, "{s} {s}", .{ method, path }) catch "request";
        return self.exchange(try self.request(method, path), label);
    }

    /// POST a control body, computing `Content-Length` from the body rather
    /// than from a hand-counted literal beside it.
    pub fn post(self: *Harness, path: []const u8, body: []const u8) !Response {
        var w = std.Io.Writer.fixed(&self.req);
        w.print("POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n{s}", .{
            path, body.len, body,
        }) catch return error.RequestTooLong;
        return self.exchange(w.buffered(), path);
    }

    /// Send arbitrary bytes and read the answer. For request lines that are
    /// not well-formed, and for well-formed ones this module should not be
    /// asked to build -- which is most of what the malformed tests are for.
    pub fn raw(self: *Harness, payload: []const u8, label: []const u8) !Response {
        return self.exchange(payload, label);
    }

    /// Connect, write, and let the server answer, returning the socket it
    /// answered on. The caller owns it and must `close` it.
    ///
    /// This is the one place the three steps live, because splitting them is
    /// how a test ends up with two connections queued at once -- see `serve`.
    pub fn dispatch(self: *Harness, payload: []const u8) !c.SOCKET {
        const s = try self.open();
        errdefer close(s);
        if (c.send(s, payload.ptr, @intCast(payload.len), 0) != @as(c_int, @intCast(payload.len))) {
            return error.ShortSend;
        }
        self.serve();
        return s;
    }

    /// Open a scratch capacity pool into `scratch` and attach it to this harness.
    ///
    /// The caller supplies the storage deliberately. `h.ctx.pool` has to keep
    /// pointing at the same live object for the whole test, so the pool cannot
    /// be built in one frame and returned by value into another — that leaves
    /// the context holding the address of a frame that has already returned.
    ///
    /// Fails loudly if the pool cannot be opened — no fallback to a pool-less
    /// document. A telemetry document without a pool says `"buffer":null`,
    /// which would make every assertion about the buffer object's fields pass
    /// vacuously, and a test that passes for the wrong reason is worse than no
    /// test.
    pub fn openScratchPool(self: *Harness, scratch: *Scratch) !void {
        const dir = try makeScratchDir();
        errdefer removeDir(dir);

        // `DEFAULT_CAPACITY` so `ceiling` reads the way it does in production.
        // Nothing is preallocated and this path never writes, so the file stays
        // at zero length: the 8 GiB is a limit, not a reservation.
        scratch.* = .{
            .pool = try pool_mod.Pool.init(std.heap.page_allocator, SCRATCH_VOLUME, dir, pool_mod.DEFAULT_CAPACITY),
            .dir = dir,
        };
        self.ctx.pool = &scratch.pool;
    }

    fn exchange(self: *Harness, payload: []const u8, label: []const u8) !Response {
        const s = try self.dispatch(payload);
        defer close(s);
        const bytes = readToEof(s, self.buf) catch |e| {
            std.debug.print("\n  {s}: {s}\n", .{ label, @errorName(e) });
            return e;
        };
        return Response.parse(bytes) catch |e| {
            std.debug.print("\n  {s}: {s}\n  {s}\n", .{ label, @errorName(e), bytes });
            return e;
        };
    }

    fn request(self: *Harness, method: []const u8, path: []const u8) ![]const u8 {
        var w = std.Io.Writer.fixed(&self.req);
        w.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", .{ method, path }) catch
            return error.RequestTooLong;
        return w.buffered();
    }

    /// Connect without sending anything, leaving the socket in the backlog for
    /// the next `serve`.
    fn open(self: *Harness) !c.SOCKET {
        const s = c.socket(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP);
        if (s == c.INVALID_SOCKET) return error.SocketFailed;
        errdefer close(s);

        // A large receive buffer, set before connect so it applies to this
        // socket. The server writes headers and body with two `send` calls and
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
            @panic("serve() called with no connection queued: a connection must be dispatched before it is served, and nothing may queue a second one in between");
        }
        self.queued = false;
        self.srv.serveOnce(&self.ctx);
    }
};

/// The one bound server, created on first use and shared by every test that
/// asks for it.
pub fn harness() !*Harness {
    if (shared == null) shared = try Harness.create();
    return shared.?;
}

var shared: ?*Harness = null;

/// Where a scratch capacity pool is opened.
///
/// Same volume as the backend suite's scratch pool, deliberately: the gate
/// already requires `P:\` to exist, so putting it here adds no environmental
/// requirement the gate did not already have. A different directory from
/// `DPU-selftest` because that pool is written to by the block device tests and
/// this one must not share a file with them.
const SCRATCH_DIR = "P:\\DPU-wirepool";
const SCRATCH_VOLUME = "P:\\";

/// A scratch capacity pool attached to the harness for the length of one test.
///
/// Owns the directory and the pool file inside it. `detach` unlinks the file,
/// removes the directory and stops the harness reporting a pool, so a test
/// cannot leave either behind — the failure mode `BlockDevice.destroy` was
/// written to prevent.
pub const Scratch = struct {
    pool: pool_mod.Pool,
    dir: []const u8,

    pub fn detach(self: *Scratch, h: *Harness) void {
        // Stop the context pointing at it before the pool is torn down, so
        // nothing can read a destroyed device.
        h.ctx.pool = null;
        self.pool.destroy();
        removeDir(self.dir);
        std.heap.page_allocator.free(self.dir);
    }
};

/// Create the scratch pool directory, clearing any residue from a crashed run.
fn makeScratchDir() ![]const u8 {
    const dir = try std.fmt.allocPrint(std.heap.page_allocator, SCRATCH_DIR, .{});
    errdefer std.heap.page_allocator.free(dir);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, dir);
    defer std.heap.page_allocator.free(wide);
    // Remove any residue from a previous run before creating, so a crash
    // cannot make every later run fail.
    _ = c.RemoveDirectoryW(wide.ptr);
    if (c.CreateDirectoryW(wide.ptr, null) == 0) {
        if (c.GetLastError() != c.ERROR_ALREADY_EXISTS) return error.ScratchDirFailed;
    }
    return dir;
}

fn removeDir(dir: []const u8) void {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, dir) catch return;
    defer std.heap.page_allocator.free(wide);
    // Only the empty directory: the pool file inside it was unlinked by
    // `Pool.destroy`, and anything else here would be a bug worth leaving
    // visible rather than deleting.
    _ = c.RemoveDirectoryW(wide.ptr);
}

/// Ask the OS which port the listener actually got.
fn boundPort(fd: c.SOCKET) !u16 {
    var addr: c.sockaddr_in = undefined;
    var len: c_int = @intCast(@sizeOf(c.sockaddr_in));
    if (c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.GetsocknameFailed;
    return std.mem.bigToNative(u16, addr.sin_port);
}

pub fn close(s: c.SOCKET) void {
    _ = c.closesocket(s);
}

/// Write bytes on a connection that is already open.
///
/// Only useful for asking what happens when a client keeps talking after the
/// server has answered -- pipelining a second request down a socket the server
/// has already closed. A write here may succeed and be lost, which is the
/// point: the assertion is on what comes back, never on whether the write did.
pub fn sendOn(s: c.SOCKET, payload: []const u8) void {
    _ = c.send(s, payload.ptr, @intCast(payload.len), 0);
}

/// Bound how long a read on this socket waits before reporting that nothing
/// arrived.
pub fn setReadTimeout(s: c.SOCKET, ms: u32) void {
    const tv = c.timeval{
        .tv_sec = @intCast(ms / 1000),
        .tv_usec = @intCast((ms % 1000) * 1000),
    };
    _ = c.setsockopt(s, c.SOL_SOCKET, c.SO_RCVTIMEO, @ptrCast(&tv), @intCast(@sizeOf(c.timeval)));
}

/// Read until the peer closes.
///
/// This server always declares `Connection: close` and always closes, so a read
/// timeout means the same thing as EOF and is not distinguished.
pub fn readToEof(s: c.SOCKET, buf: []u8) ![]const u8 {
    setReadTimeout(s, READ_TIMEOUT_MS);
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.recv(s, buf.ptr + total, @intCast(buf.len - total), 0);
        if (n > 0) {
            total += @intCast(n);
            continue;
        }
        if (n == 0) break;
        if (c.WSAGetLastError() == c.WSAETIMEDOUT) break;
        return error.RecvFailed;
    }
    if (total == 0) return error.NoResponse;
    return buf[0..total];
}

/// Read up to and including the header terminator, leaving any body in the
/// socket for the caller to look for.
///
/// This is the only way to see the framing question. A server can advertise
/// the right `Content-Length` and still write the body; those bytes only
/// become visible to whoever reads the socket next.
pub fn readHeaderBlock(s: c.SOCKET, buf: []u8) ![]const u8 {
    setReadTimeout(s, READ_TIMEOUT_MS);
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.recv(s, buf.ptr + total, @intCast(buf.len - total), 0);
        if (n > 0) {
            total += @intCast(n);
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |i| return buf[0 .. i + 4];
            continue;
        }
        if (n == 0) break;
        if (c.WSAGetLastError() == c.WSAETIMEDOUT) break;
        return error.RecvFailed;
    }
    return error.NoHeaderTerminator;
}

/// How many bytes are readable on this socket within `ms`, capped at
/// `buf.len`. Zero means the peer sent nothing more and said nothing more.
///
/// The name is the point: on a connection where the body should have been
/// suppressed, the answer is zero, and "zero" is not something
/// `readToEof` could tell you -- it would have consumed the phantom bytes and
/// reported success.
pub fn bytesAvailable(s: c.SOCKET, buf: []u8, ms: u32) usize {
    setReadTimeout(s, ms);
    const n = c.recv(s, buf.ptr, @intCast(buf.len), 0);
    if (n <= 0) return 0;
    return @intCast(n);
}
