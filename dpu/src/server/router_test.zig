//! The router's unit tests, kept out of the module they describe.
//!
//! These live here rather than inline in `router.zig` for the same reason
//! `server_wire_test.zig` exists: a test that sits next to the code it checks
//! drifts toward restating it. `router.zig` is short enough to read in one go
//! *because* the twenty-one assertions are not interleaved with it.
//!
//! What they cover is the pure decision -- the method, the status and the
//! framing, and the claim that they cannot disagree. What they deliberately do
//! not cover is whether a client sees any of it: no socket, no status line, no
//! `Content-Length`. That is the gap the 200-for-a-miss bug shipped through,
//! and `server_wire_test.zig` is what closed it.
//!
//! The 200-for-a-missing-route bug shipped because the dispatch was an
//! `if/else` chain with no statement anywhere saying what a miss returns.
//! These tests say it out loud; the wire suite is what says the socket agrees.

const std = @import("std");
const router = @import("router.zig");
const assets = @import("assets.zig");

const testing = std.testing;

fn statusOf(r: router.Route) ?[]const u8 {
    return switch (r) {
        .reject => |why| why.status,
        else => null,
    };
}

test "a path that serves nothing is 404, not 200" {
    const r = router.route("/nope", "GET");
    try testing.expectEqualStrings("404 Not Found", statusOf(r).?);
    try testing.expectEqualStrings("not found\n", r.reject.body);
    // A miss must not advertise a verb list: there is nothing there to allow.
    try testing.expect(r.reject.allow == null);
}

test "browser and crawler paths that do not exist are 404" {
    for ([_][]const u8{ "/favicon.ico", "/app.js.map", "/index.htm", "/API/telemetry", "/api/telemetry/", "api/telemetry", "" }) |p| {
        try testing.expectEqualStrings("404 Not Found", statusOf(router.route(p, "GET")).?);
    }
}

test "every dashboard path still routes" {
    try testing.expectEqual(std.meta.activeTag(router.route("/api/telemetry", "GET")), .telemetry);
    try testing.expectEqual(std.meta.activeTag(router.route("/api/control", "POST")), .control);
    try testing.expectEqual(std.meta.activeTag(router.route("/", "GET")), .asset);
    try testing.expectEqual(std.meta.activeTag(router.route("/index.html", "GET")), .asset);
    try testing.expectEqual(std.meta.activeTag(router.route("/app.js", "GET")), .asset);
    try testing.expectEqual(std.meta.activeTag(router.route("/style.css", "GET")), .asset);
}

test "the wrong verb on a real route is 405 with Allow" {
    // The bug this PR fixes: the verb was not part of the route at all, so
    // `DELETE /` answered with the whole dashboard and `GET /api/control`
    // claimed a write it never performed.
    const d = router.route("/", "DELETE");
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(d).?);
    try testing.expectEqualStrings("GET, HEAD", d.reject.allow.?);

    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(router.route("/app.js", "PUT")).?);
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(router.route("/api/control", "GET")).?);
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(router.route("/api/telemetry", "POST")).?);
}

test "POST on a GET-only route never reaches a handler" {
    // Belt and braces: a 405 on the telemetry path must not carry a payload.
    const r = router.route("/api/telemetry", "PUT");
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(r).?);
    try testing.expectEqualStrings("GET, HEAD", r.reject.allow.?);
    try testing.expectEqualStrings("method not allowed\n", r.reject.body);
}

test "the control route does not answer GET" {
    // Only the verb guard can stop this; there is no body check behind it.
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(router.route("/api/control", "GET")).?);
    try testing.expectEqualStrings("POST", router.route("/api/control", "GET").reject.allow.?);
}

test "HEAD is accepted wherever GET is" {
    for ([_][]const u8{ "/", "/index.html", "/app.js", "/style.css", "/api/telemetry" }) |p| {
        try testing.expect(statusOf(router.route(p, "HEAD")) == null);
    }
}

test "the method comes off the request line" {
    try testing.expectEqualStrings("GET", router.parseRequestLine("GET / HTTP/1.1\r\nHost: x\r\n\r\n").?.method);
    try testing.expectEqualStrings("POST", router.parseRequestLine("POST /api/control HTTP/1.1\r\n\r\n").?.method);
    try testing.expectEqualStrings("DELETE", router.parseRequestLine("DELETE / HTTP/1.1\r\n\r\n").?.method);
}

test "the path drops the query string" {
    try testing.expectEqualStrings("/api/telemetry", router.parseRequestLine("GET /api/telemetry?x=1 HTTP/1.1\r\n\r\n").?.path);
    try testing.expectEqualStrings("/", router.parseRequestLine("GET /?x=1 HTTP/1.1\r\n\r\n").?.path);
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
        const r = router.routeRequest(req).route;
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
    const r = router.routeRequest("\r\n\r\n").route;
    try testing.expectEqualStrings("bad request\n", r.reject.body);
    try testing.expect(r.reject.body.len < assets.findAsset("/").?.body.len);
}

test "a well-formed request line still routes" {
    // The regression this must not cause: stricter parsing rejecting real
    // traffic. These are the exact shapes the PR verified over a socket.
    try testing.expectEqual(std.meta.activeTag(router.routeRequest("GET / HTTP/1.1\r\n\r\n").route), .asset);
    try testing.expectEqual(std.meta.activeTag(router.routeRequest("GET /api/telemetry HTTP/1.1\r\n\r\n").route), .telemetry);
    try testing.expectEqual(std.meta.activeTag(router.routeRequest("POST /api/control HTTP/1.1\r\n\r\npower=MAX").route), .control);
    try testing.expectEqual(std.meta.activeTag(router.routeRequest("HEAD / HTTP/1.1\r\n\r\n").route), .asset);
    try testing.expectEqual(std.meta.activeTag(router.routeRequest("GET /app.js HTTP/1.1\r\n\r\n").route), .asset);
}

test "a request line without a trailing newline is still valid" {
    // A client that sends the line and stops is normal enough on loopback;
    // rejecting it would be stricter than the bug being fixed.
    const line = router.parseRequestLine("GET /api/telemetry HTTP/1.1").?;
    try testing.expectEqualStrings("GET", line.method);
    try testing.expectEqualStrings("/api/telemetry", line.path);
}

test "leading separators do not make a valid line malformed" {
    const line = router.parseRequestLine("  GET / HTTP/1.1\r\n\r\n").?;
    try testing.expectEqualStrings("GET", line.method);
    try testing.expectEqualStrings("/", line.path);
}

test "malformed is decided before any route lookup" {
    // A miss is 404 and a malformed line is 400; they must not be confused.
    try testing.expectEqualStrings("404 Not Found", statusOf(router.routeRequest("GET /nope HTTP/1.1\r\n\r\n").route).?);
    try testing.expectEqualStrings("400 Bad Request", statusOf(router.routeRequest("GET\r\n\r\n").route).?);
}

test "no verb reaches a handler for a path that does not exist" {
    for ([_][]const u8{ "GET", "POST", "HEAD", "PUT", "DELETE" }) |m| {
        try testing.expectEqualStrings("404 Not Found", statusOf(router.route("/nope", m)).?);
    }
}

// ------------------------------------------------------------------- framing

test "HEAD is admitted wherever GET is" {
    // The router already admitted HEAD beside GET. router.Framing now agrees with it
    // because both read the same `method`; this pins the pairing.
    for ([_][]const u8{ "/", "/index.html", "/app.js", "/style.css" }) |p| {
        try testing.expectEqual(std.meta.activeTag(router.route(p, "HEAD")), std.meta.activeTag(router.route(p, "GET")));
        try testing.expectEqual(router.Framing.headers_only, router.framingFor("HEAD"));
    }
}

test "only HEAD suppresses the body" {
    try testing.expectEqual(router.Framing.headers_only, router.framingFor("HEAD"));
    for ([_][]const u8{ "GET", "POST", "PUT", "DELETE", "BREW", "get" }) |m| {
        try testing.expectEqual(router.Framing.body, router.framingFor(m));
    }
}

test "framing is case-sensitive, matching HTTP method semantics" {
    // RFC 9110 methods are case-sensitive, so a lowercase "head" is not HEAD and
    // is not a verb this server serves -- it must not silently get HEAD framing.
    try testing.expectEqual(router.Framing.body, router.framingFor("head"));
    try testing.expectEqualStrings("405 Method Not Allowed", statusOf(router.route("/", "head")).?);
}

test "HEAD on a miss is still a 404, and still framed as headers-only" {
    try testing.expectEqualStrings("404 Not Found", statusOf(router.route("/nope", "HEAD")).?);
    try testing.expectEqual(router.Framing.headers_only, router.framingFor("HEAD"));
}

test "every asset has a body for Content-Length to describe" {
    // `respond` formats Content-Length from `body.len` before it consults
    // `framing`, so a HEAD advertises exactly the length GET would have
    // returned. Asserting that the length is non-zero and is the embedded
    // asset's own length is the part provable here; that the number reaches
    // the wire while the bytes do not is observable only over a socket, and is
    // verified there rather than pretended at here.
    for ([_][]const u8{ "/", "/index.html", "/app.js", "/style.css" }) |p| {
        const a = assets.findAsset(p).?;
        try testing.expect(a.body.len > 0);
    }
    // The 404 body a HEAD advertises is the same 10 bytes GET would have sent.
    const body = router.route("/nope", "HEAD").reject.body;
    try testing.expectEqualStrings("not found\n", body);
    try testing.expectEqual(@as(usize, 10), body.len);
}
