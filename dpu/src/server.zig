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

        const path = extractPath(req);
        if (std.mem.eql(u8, path, "/api/telemetry")) {
            sendTelemetry(client, ctx);
        } else if (std.mem.eql(u8, path, "/api/control")) {
            sendControl(client, req, ctx);
        } else {
            serveStatic(client, path);
        }
    }

    fn sendResponse(client: c.SOCKET, status: []const u8, mime: []const u8, body: []const u8) void {
        var head: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&head,
            "HTTP/1.1 {s}\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Cache-Control: no-store\r\n" ++
                "Connection: close\r\n\r\n",
            .{ status, mime, body.len },
        ) catch return;
        _ = c.send(client, header.ptr, @intCast(header.len), 0);
        _ = c.send(client, body.ptr, @intCast(body.len), 0);
    }

    fn sendControl(client: c.SOCKET, req: []const u8, ctx: *Context) void {
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
        sendResponse(client, "200 OK", "application/json", "{\"ok\":true}");
    }

    /// Build the telemetry payload by hand into a fixed buffer.
    ///
    /// A general JSON serializer would be more code and slower for a document
    /// whose shape never varies. Numbers go through `fmt` with explicit
    /// precision so the client never has to parse locale-formatted output.
    fn sendTelemetry(client: c.SOCKET, ctx: *const Context) void {
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
            const res = tiers.resolve(ctx.engine.power.tier(), p.freeSpace());
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
        sendResponse(client, "200 OK", "application/json", w.buffered());
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

/// Extract the path from an HTTP request line: `GET /path HTTP/1.1`.
fn extractPath(req: []const u8) []const u8 {
    const line_end = std.mem.indexOfScalar(u8, req, '\n') orelse req.len;
    const line = std.mem.trimEnd(u8, req[0..line_end], "\r ");
    var it = std.mem.tokenizeAny(u8, line, " ");
    _ = it.next() orelse return "/"; // method
    const path = it.next() orelse return "/";
    // Ignore any query string; control arrives over POST bodies instead.
    if (std.mem.indexOfScalar(u8, path, '?')) |q| return path[0..q];
    return path;
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
        if (v.len > 0 and v[0] == '"') v = v[1 ..];
        if (v.len > 0 and v[v.len - 1] == '"') v = v[0 .. v.len - 1];
        return v;
    }
    return null;
}



// Static assets are embedded at compile time. The dashboard then ships inside
// the binary: no asset directory to lose, no runtime file I/O, no 404s.
const assets = @import("web_assets");
const index_html = assets.index_html;
const app_js = assets.app_js;
const style_css = assets.style_css;

fn serveStatic(client: c.SOCKET, path: []const u8) void {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        respond200(client, index_html, "text/html; charset=utf-8");
    } else if (std.mem.eql(u8, path, "/app.js")) {
        respond200(client, app_js, "application/javascript; charset=utf-8");
    } else if (std.mem.eql(u8, path, "/style.css")) {
        respond200(client, style_css, "text/css; charset=utf-8");
    } else {
        respond404(client);
    }
}

fn respond200(client: c.SOCKET, body: []const u8, mime: []const u8) void {
    var head: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&head,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        .{ mime, body.len },
    ) catch return;
    _ = c.send(client, header.ptr, @intCast(header.len), 0);
    _ = c.send(client, body.ptr, @intCast(body.len), 0);
}

fn respond404(client: c.SOCKET) void {
    respond200(client, "not found", "text/plain");
}