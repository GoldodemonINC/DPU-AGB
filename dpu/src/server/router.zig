//! The routing decision: one parse, one status, one framing, no I/O.
//!
//! Everything in this file is pure. It reads request bytes and returns a value;
//! it never touches a socket, never reads a clock, and never looks at engine
//! state. That is what makes the three facts a request line implies -- the
//! method, the status, and whether bytes follow the headers -- provably
//! consistent: they are computed from one parse and travel together in a
//! `Decision`, so there is no second read of the method to drift.
//!
//! The history is worth keeping in mind. Dispatch used to be an `if/else` chain
//! on the path alone, with no statement anywhere saying what a miss returns,
//! and a miss answered 200 with the dashboard. Then the parser supplied its own
//! defaults for a missing method and target, so a blank line resolved to
//! `GET /` and answered 200 as well. Each of those was a routing fact computed
//! somewhere other than the router, and each is now unrepresentable rather than
//! merely fixed: there is no path through `route` that matches nothing and
//! returns 200, and no path through `parseRequestLine` that invents a method.

const std = @import("std");
const assets = @import("assets.zig");

/// A request line that carried both a method and a target.
pub const RequestLine = struct {
    method: []const u8,
    path: []const u8,
};

/// Parse `GET /path HTTP/1.1`, or return null when the line is not one.
///
/// RFC 9112 defines the request line as method SP request-target SP
/// HTTP-version. Anything short of a method and a target is malformed, and the
/// honest answer is to say so rather than invent one.
pub fn parseRequestLine(req: []const u8) ?RequestLine {
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

/// What the router decided for one `(path, method)` pair.
///
/// A route is the pair, not the path alone: the verb is part of what the server
/// offers for that path, so routing on the path alone let `DELETE /` answer
/// with the dashboard and `GET /api/control` report `{"ok":true}` having written
/// nothing.
///
/// The three payload-free tags are the ones that have a handler; only `.reject`
/// carries a status, so a handler has no status to remember and a miss cannot be
/// reported as a success.
pub const Route = union(enum) {
    /// Serve the telemetry document.
    telemetry,
    /// Apply a control write.
    control,
    /// Serve the embedded dashboard asset at this path.
    asset: []const u8,
    /// Refuse.
    reject: Rejection,
};

/// Why a request is being refused, including everything the response needs.
pub const Rejection = struct {
    status: []const u8,
    body: []const u8,
    allow: ?[]const u8 = null,
};

/// Verbs a path accepts, as an `Allow` header value.
///
/// HEAD rides along with GET because a client asking for headers only is asking
/// for the same resource.
fn allowFor(want: []const u8) []const u8 {
    return if (std.mem.eql(u8, want, "GET")) "GET, HEAD" else want;
}

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

/// The whole routing table, as one pure decision.
///
/// Every status this server can produce is named here, which is what makes the
/// "200 for a missing route" bug unrepresentable rather than merely fixed: there
/// is no path through this function that matches nothing and returns 200.
pub fn route(path: []const u8, method: []const u8) Route {
    if (std.mem.eql(u8, path, "/api/telemetry")) {
        if (accept(method, "GET")) |why| return .{ .reject = why };
        return .telemetry;
    }
    if (std.mem.eql(u8, path, "/api/control")) {
        if (accept(method, "POST")) |why| return .{ .reject = why };
        return .control;
    }
    if (assets.isAssetPath(path)) {
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
pub fn routeLine(line: ?RequestLine) Route {
    const parsed = line orelse return .{ .reject = .{
        .status = "400 Bad Request",
        .body = "bad request\n",
    } };
    return route(parsed.path, parsed.method);
}

/// Whether the exchange carries a response body.
///
/// `respond` used to send the body unconditionally and knew nothing about the
/// request, so the status was decided by the router while the framing was
/// decided by a writer that had never seen the method -- two places deciding
/// one thing, which is the arrangement #4 removed from the status code. The
/// value is computed in `routeRequest` from the same `method` that routed the
/// request, so the two facts have a single source.
///
/// HEAD is admitted by `accept` exactly where GET is, and suppressed for
/// exactly the same requests, because both read the same variable.
pub const Framing = enum { body, headers_only };

pub fn framingFor(method: []const u8) Framing {
    return if (std.mem.eql(u8, method, "HEAD")) .headers_only else .body;
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
pub const Decision = struct {
    route: Route,
    framing: Framing,
};

pub fn routeRequest(req: []const u8) Decision {
    const line = parseRequestLine(req);
    return .{
        .route = routeLine(line),
        // A request line that did not parse is not a HEAD, so its 400 keeps the
        // body it describes. `framingFor("")` is `.body`.
        .framing = framingFor(if (line) |l| l.method else ""),
    };
}
