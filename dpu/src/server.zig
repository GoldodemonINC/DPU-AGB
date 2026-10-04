//! Loopback HTTP server for the dashboard.
//!
//! Hand-rolled over Winsock rather than a framework. The only client is the
//! dashboard on 127.0.0.1, so there is no connection pooling, no TLS, and no
//! reason to spend startup time on an HTTP stack the process will never need
//! again once it is listening.
//!
//! ## What lives here
//!
//! This file is the composition root: it owns the listening socket, hands a
//! request to the router, and writes the response. The concerns that used to
//! sit beside it are now beside it as modules, split by what changes together
//! rather than by size:
//!
//! | Module | Owns | Changes when |
//! |---|---|---|
//! | `server/router.zig` | the pure decision: parse, route, framing | a route, status, verb rule or framing rule changes |
//! | `server/assets.zig` | the one asset table | the dashboard's files change |
//! | `server/telemetry_doc.zig` | the telemetry document | the JSON shape changes |
//! | `server/context.zig` | `EngineState`, `PowerMode`, `Context` | the engine's modes change |
//! | this file | bind, accept, recv, dispatch, `respond` | the wire format or socket handling changes |
//!
//! `respond` stays here because it is the only function that writes a status
//! line: one place decides how bytes reach a client, so "what code does this
//! return" has one answer rather than one per handler that remembers.

const std = @import("std");
const win = @import("win");
const pool_mod = @import("pool.zig");
const router = @import("server/router.zig");
const assets = @import("server/assets.zig");
const telemetry_doc = @import("server/telemetry_doc.zig");
const context = @import("server/context.zig");

const c = win.c;

pub const DEFAULT_PORT: u16 = 8787;

pub const Server = struct {
    listen_fd: c.SOCKET = c.INVALID_SOCKET,
    engine: context.EngineState = .{},

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
    pub fn serveOnce(self: *Server, ctx: *context.Context) void {
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
        // cannot be routed one way and framed another. Nothing below this line
        // re-reads the method.
        const d = router.routeRequest(req);
        switch (d.route) {
            .telemetry => sendTelemetry(client, ctx, d.framing),
            .control => sendControl(client, req, ctx, d.framing),
            .asset => |p| serveAsset(client, p, d.framing),
            .reject => |r| respond(client, r.status, "text/plain", r.body, r.allow, d.framing),
        }
    }

    fn sendTelemetry(client: c.SOCKET, ctx: *const context.Context, framing: router.Framing) void {
        // The buffer belongs here because it is transport-sized scratch; the
        // document itself is `telemetry_doc`'s, and it reports NoSpace rather
        // than handing back a truncated object.
        var buf: [telemetry_doc.BUFFER_BYTES]u8 = undefined;
        const doc = telemetry_doc.render(ctx, &buf) catch return;
        respond(client, "200 OK", telemetry_doc.MIME, doc, null, framing);
    }

    fn serveAsset(client: c.SOCKET, path: []const u8, framing: router.Framing) void {
        // The router only dispatches here for a path present in ASSETS, so the
        // unwrap cannot fail and this cannot silently serve the wrong file.
        const a = assets.findAsset(path).?;
        respond(client, "200 OK", a.mime, a.body, null, framing);
    }
};

/// Apply a control write from a request body.
///
/// The only writer of `EngineState` outside construction, which is why it lives
/// next to the transport rather than in `context.zig`: `context` owns what the
/// state *is*, this owns the one place it *changes*.
fn sendControl(client: c.SOCKET, req: []const u8, ctx: *context.Context, framing: router.Framing) void {
    if (parseParam(req, "power")) |p| {
        if (context.PowerMode.parse(p)) |mode| {
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
    respond(client, "200 OK", telemetry_doc.MIME, "{\"ok\":true}", null, framing);
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

/// The single response emitter. Every status line in this server is written
/// here, so "which code does this return" has one answer rather than one per
/// helper that happens to remember.
fn respond(client: c.SOCKET, status: []const u8, mime: []const u8, body: []const u8, allow: ?[]const u8, framing: router.Framing) void {
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
