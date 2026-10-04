//! What DPU's HTTP surface promises, asserted over a real socket.
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
//! tests, because `respond404` built the correct body and then handed it to
//! `respond200`, which hardcoded the status line. Everything above the socket
//! was correct and the client still received `200 OK`.
//!
//! ## What lives here and what does not
//!
//! This file is the contract: which routes exist, what status each one answers,
//! what each body says, and how HEAD is framed. The mechanics of asking a
//! socket a question -- binding, connecting, dispatching, reading -- are in
//! `wire_harness.zig`. Nothing below calls Winsock. That split is deliberate:
//! a reader asking "what does this server promise?" should not have to read a
//! `setsockopt` to find out, and a change to either half should not force a
//! reread of the other.
//!
//! ## Two rules the tables below obey
//!
//! Coverage is derived from `assets.ASSETS` rather than restated. A hand-copied
//! list of asset paths is a second place that has to agree with the router,
//! and it would quietly stop covering a newly added asset -- the same failure
//! mode #4 removed from the status code. Where a list is genuinely test data
//! (the matrix, which includes paths that must *not* route) it is written out.

const std = @import("std");
const testing = std.testing;
const wire = @import("wire_harness.zig");
const assets = @import("server/assets.zig");

const Harness = wire.Harness;
const Response = wire.Response;

/// Paths that are not routes. A miss must be a miss on every verb, including
/// HEAD, so this list is exercised by the HEAD and framing tests as well as by
/// the matrix.
const MISSES = [_][]const u8{
    "/nope",
    "/app.js.map",
    "/favicon.ico",
    "/API/telemetry",
    "/api/telemetry/",
};

/// Verbs that are not HEAD. Every one of them must keep its body; that is what
/// makes the HEAD results meaningful rather than everything being empty.
const NON_HEAD_METHODS = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "BREW" };

// ------------------------------------------------------------------ helpers

/// Assert a status, naming the case if it is wrong.
///
/// Repeated at every table row in this file with a per-case message, which is
/// both a lot of duplication and a lot of places to forget the message. One
/// helper with the label passed in keeps the diagnostics and the shape
/// together.
fn expectStatus(r: Response, want: []const u8, label: []const u8) !void {
    testing.expectEqualStrings(want, r.status) catch |e| {
        std.debug.print("\n  {s}\n  expected status {s}, got {s}\n", .{ label, want, r.status });
        return e;
    };
}

fn expectBody(r: Response, want: []const u8, label: []const u8) !void {
    testing.expectEqualStrings(want, r.body) catch |e| {
        std.debug.print("\n  {s}\n  expected body {s}\n  got      {s}\n", .{ label, want, r.body });
        return e;
    };
}

/// Assert a body is not empty, naming the case.
fn expectNonEmptyBody(r: Response, label: []const u8) !void {
    testing.expect(r.body.len > 0) catch |e| {
        std.debug.print("\n  {s} -> {s} with an empty body\n", .{ label, r.status });
        return e;
    };
}

/// The HEAD contract for one path: same status as GET, `Content-Length` equal
/// to the length GET actually returned, and no body bytes at all.
///
/// Shared by the asset test and the miss test, because "HEAD on a miss is
/// still a 404 with no body" and "HEAD on a hit is a 200 with no body" are the
/// same rule applied to two different statuses, and writing it twice is how one
/// of them stops being checked.
fn expectHeadMatchesGet(h: *Harness, path: []const u8) !void {
    const get = try h.get("GET", path);
    const head = try h.get("HEAD", path);

    // HEAD is not a different request; it is the same response without the
    // body.
    try expectStatus(head, get.status, "HEAD vs GET status");
    try expectNonEmptyBody(get, "GET");

    // The advertised length is the one a GET would have produced, taken from
    // both sides of the wire rather than from the header alone.
    testing.expectEqual(get.body.len, head.content_length.?) catch |e| {
        std.debug.print("\n  HEAD {s}\n  GET returned {d} bytes, HEAD advertised {d}\n", .{
            path, get.body.len, head.content_length.?,
        });
        return e;
    };

    // And nothing followed the headers.
    try testing.expectEqual(@as(usize, 0), head.body.len);
}

// ------------------------------------------------------------------- tables

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

/// A request line written out by hand, with the status it must produce.
///
/// One type for all three raw-line tables. They used to be three separate
/// anonymous structs, which meant three shapes to keep in step and two of them
/// printing a raw payload instead of a name when they failed.
const RawCase = struct {
    label: []const u8,
    payload: []const u8,
    status: []const u8,
};

/// The request lines #6 promised to reject. Each is a shape a client can
/// actually put on the wire, not a string that merely looks odd.
const MALFORMED: []const RawCase = &.{
    .{ .label = "a blank request line", .payload = "\r\n\r\n", .status = "400 Bad Request" },
    .{ .label = "a bare method with no target", .payload = "GET\r\n\r\n", .status = "400 Bad Request" },
    .{ .label = "a method and a space with no target", .payload = "GET \r\n\r\n", .status = "400 Bad Request" },
    .{ .label = "separators only", .payload = "   \r\n\r\n", .status = "400 Bad Request" },
    .{ .label = "a tab-separated request line", .payload = "GET\t/\tHTTP/1.1\r\n\r\n", .status = "400 Bad Request" },
    .{ .label = "a single LF", .payload = "\n", .status = "400 Bad Request" },
};

/// Malformed lines whose target names a path that does not exist.
///
/// The malformed check runs before any route lookup, and on the wire that is
/// an observable ordering rather than an internal one: a router that looked the
/// path up first would answer 404 and tell the client whether `/nope` is real.
/// A 400 answers the same way for a path that exists, one that does not, and
/// one that was never named at all.
///
/// Every shape here is broken in the *method* or the *separators*, never merely
/// unusual: `GE T /nope` is a well-formed request for the path `T` and is
/// correctly a 404, so it belongs in the unusual-but-valid table rather than
/// here.
const MALFORMED_NAMING_A_MISS: []const RawCase = &.{
    .{ .label = "tab-separated, targeting a miss", .payload = "GET\t/nope\tHTTP/1.1\r\n\r\n", .status = "400 Bad Request" },
    .{ .label = "leading space, targeting a miss", .payload = " /nope HTTP/1.1\r\n\r\n", .status = "400 Bad Request" },
    .{ .label = "slash in the method, targeting a miss", .payload = "GE/T /nope HTTP/1.1\r\n\r\n", .status = "400 Bad Request" },
    .{ .label = "paren in the method, targeting a miss", .payload = "GE(T /nope HTTP/1.1\r\n\r\n", .status = "400 Bad Request" },
};

/// The other side of #6: rejecting a bad request line must not reject a good
/// one. Each of these is unusual but legal, and each broke under an earlier
/// version of the parser.
const VALID_UNUSUAL: []const RawCase = &.{
    // No CRLF at all: the line ends where the read ends.
    .{ .label = "no trailing CRLF", .payload = "GET / HTTP/1.1", .status = "200 OK" },
    .{ .label = "leading space", .payload = " GET / HTTP/1.1\r\n\r\n", .status = "200 OK" },
};

// ------------------------------------------------------------------- tests

test "every route in the matrix answers the status it claims" {
    const h = try wire.harness();
    for (MATRIX) |row| {
        const r = try h.get(row.method, row.path);
        try expectStatus(r, row.status, row.path);

        if (row.allow) |want| {
            testing.expectEqualStrings(want, r.allow orelse "<absent>") catch |e| {
                std.debug.print("\n  {s} {s}\n  expected Allow: {s}\n", .{ row.method, row.path, want });
                return e;
            };
        } else {
            try testing.expect(r.allow == null);
        }

        // Every one of these statuses owes the client a body, and owes it a
        // length that matches. An empty body here would mean the emitter gave
        // up mid-write.
        try expectNonEmptyBody(r, row.path);
        try r.expectLengthMatchesBody();
        try testing.expectEqualStrings("close", r.connection orelse "<absent>");
    }
}

test "the dashboard body on the wire is the dashboard" {
    // Anchors the lengths asserted elsewhere to real content. Without this, a
    // response of the right size carrying the wrong bytes would satisfy every
    // count-based assertion in this file.
    const h = try wire.harness();
    const r = try h.get("GET", "/");
    try testing.expect(std.mem.startsWith(u8, r.body, "<!DOCTYPE html>"));
    try testing.expect(std.mem.indexOf(u8, r.body, "</html>") != null);

    // The two spellings of the same document must agree byte for byte.
    const alt = try h.get("GET", "/index.html");
    try testing.expectEqualStrings(r.body, alt.body);
    try testing.expectEqual(r.content_length.?, alt.content_length.?);
}

test "a request line that is not one is 400, and carries no dashboard" {
    const h = try wire.harness();
    for (MALFORMED) |cs| {
        const r = try h.raw(cs.payload, cs.label);
        try expectStatus(r, cs.status, cs.label);

        // The body is exactly this and nothing else. A request line that
        // failed to parse used to fall back to `GET /` and answer 200 with
        // 5744 bytes of HTML, so the length is part of the assertion.
        try expectBody(r, "bad request\n", cs.label);
        try r.expectLengthMatchesBody();

        // Named explicitly because it is the regression, not because the exact
        // body above does not already imply it.
        try testing.expect(std.mem.indexOf(u8, r.body, "<!DOCTYPE") == null);
        try testing.expect(std.mem.indexOf(u8, r.body, "<html") == null);
    }
}

test "a malformed line is 400 even when its target names no route" {
    const h = try wire.harness();

    // The control: a well-formed line for the same path is a 404, so the 400s
    // below are caused by the malformed line and not by the path.
    try expectStatus(try h.get("GET", "/nope"), "404 Not Found", "control");

    for (MALFORMED_NAMING_A_MISS) |cs| {
        const r = try h.raw(cs.payload, cs.label);
        try expectStatus(r, cs.status, cs.label);
        try expectBody(r, "bad request\n", cs.label);
        try r.expectLengthMatchesBody();
    }
}

test "valid request lines that look unusual still route" {
    const h = try wire.harness();
    for (VALID_UNUSUAL) |cs| {
        const r = try h.raw(cs.payload, cs.label);
        try expectStatus(r, cs.status, cs.label);
        try r.expectLengthMatchesBody();
    }
}

test "a control write is visible in the telemetry that follows it" {
    // The dashboard's right-hand matrix is a POST followed by a GET, and until
    // now that pairing was only ever checked by clicking in a browser. This is
    // the same exchange over the wire, which is what makes it a gate check
    // rather than a demo.
    const h = try wire.harness();

    const before = try h.get("GET", "/api/telemetry");
    try testing.expect(std.mem.indexOf(u8, before.body, "\"power\":\"xHIGH\"") != null);

    const write = try h.post("/api/control", "power=low");
    try expectStatus(write, "200 OK", "control write");
    try expectBody(write, "{\"ok\":true}", "control write");
    try write.expectLengthMatchesBody();

    const after = try h.get("GET", "/api/telemetry");
    try testing.expect(std.mem.indexOf(u8, after.body, "\"power\":\"LOW\"") != null);
    // Prefetch is derived from the mode, so it moves with it.
    try testing.expect(std.mem.indexOf(u8, after.body, "\"prefetch\":1") != null);

    // Restore the default so this test does not leak state into the ones after
    // it. Tests run in declaration order, so relying on that is fine -- but
    // leaving the engine pinned to LOW for the rest of the run is not.
    try expectStatus(try h.post("/api/control", "power=xhigh"), "200 OK", "restore");
    const final = try h.get("GET", "/api/telemetry");
    try testing.expect(std.mem.indexOf(u8, final.body, "\"power\":\"xHIGH\"") != null);
}

test "every asset answers HEAD with its GET length and no bytes" {
    // Derived from the server's own table so a newly added asset is covered
    // the day it is added. The floor stops an empty table from making this
    // vacuously true, which is the failure mode a derived list has and a
    // written-out one does not.
    try testing.expect(assets.ASSETS.len >= 3);

    const h = try wire.harness();
    for (assets.ASSETS) |asset| {
        try expectHeadMatchesGet(h, asset.path);
    }
}

test "HEAD on a miss is the miss, with no bytes" {
    // HEAD on a miss matters as much as HEAD on a hit: "no body" has to be a
    // property of the response path, not of the asset table.
    const h = try wire.harness();
    for (MISSES) |path| {
        try expectHeadMatchesGet(h, path);
    }
}

test "only HEAD suppresses the body" {
    // The negative case for the two above. If framing were decided by the path
    // or by the status rather than by the method, one of these would come back
    // empty -- and a HEAD assertion alone would not notice, because it only
    // ever looks at responses that are already empty.
    const h = try wire.harness();
    for (assets.ASSETS) |asset| {
        for (NON_HEAD_METHODS) |method| {
            const r = try h.get(method, asset.path);
            // Every one of these owes a body: the asset itself, or the
            // `method not allowed` text the 405 promises.
            try expectNonEmptyBody(r, asset.path);
            try r.expectLengthMatchesBody();
        }
    }
    for (MISSES) |path| {
        for (NON_HEAD_METHODS) |method| {
            const r = try h.get(method, path);
            try expectNonEmptyBody(r, path);
            try r.expectLengthMatchesBody();
        }
    }

    // `HEAD` in another case is a different method and must keep its body.
    const lower = try h.raw("head / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "lowercase head");
    try expectStatus(lower, "405 Method Not Allowed", "lowercase head");
    try expectNonEmptyBody(lower, "lowercase head");
}

/// The keys of a flat JSON object, in the order they appear.
///
/// Not a substring search, and that is the whole point. `"total":` also occurs
/// *inside* the `pool` object, so searching the document for `"total":` passes
/// even when the top-level `total` object has been deleted -- which is exactly
/// the mistake this exists to catch, and which it initially failed to.
///
/// This walks the bytes, tracking brace depth and skipping string literals, and
/// reports only the names that sit at the object's own level.
fn topLevelKeys(doc: []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < doc.len and n < out.len) {
        switch (doc[i]) {
            '{' => depth += 1,
            '}' => {
                if (depth > 0) depth -= 1;
            },
            '"' => {
                const start = i + 1;
                var j = start;
                while (j < doc.len and doc[j] != '"') {
                    if (doc[j] == '\\') j += 1; // an escaped quote is not the end
                    j += 1;
                }
                const name = doc[start..j];
                i = j + 1;
                // A key is a string at this object's own depth, followed by ':'.
                if (depth == 1 and i < doc.len and doc[i] == ':') {
                    out[n] = name;
                    n += 1;
                }
                continue;
            },
            else => {},
        }
        i += 1;
    }
    return out[0..n];
}

fn hasKey(keys: []const []const u8, name: []const u8) bool {
    for (keys) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

test "the telemetry document keeps every key the dashboard parses" {
    // Every other assertion in this file counts bytes. A serializer field
    // dropped in a refactor changes the length and nothing else, so a
    // count-based check sails straight past it.
    //
    // The `buffer` object's sixteen fields are deliberately absent from this
    // list: they are only emitted when the capacity pool is open, and the gate
    // deliberately runs without one so it never touches `P:\DPU\pool.vram`.
    // They are checked against a running engine instead -- a weaker guarantee,
    // recorded as such rather than papered over with a conditional assertion
    // that passes either way.
    const h = try wire.harness();
    const r = try h.get("GET", "/api/telemetry");

    const TOP_LEVEL = [_][]const u8{
        "t",    "uptimeMs", "engine", "counters",
        "pool", "procs",    "buffer", "total",
    };

    var found: [16][]const u8 = undefined;
    const keys = topLevelKeys(r.body, &found);
    for (TOP_LEVEL) |key| {
        testing.expect(hasKey(keys, key)) catch |e| {
            std.debug.print("\n  telemetry has no top-level key {s}\n  top-level keys are:", .{key});
            for (keys) |k| std.debug.print(" {s}", .{k});
            std.debug.print("\n  {s}\n", .{r.body});
            return e;
        };
    }

    // The engine object is nested, so its keys are checked at its own level.
    const at = std.mem.indexOf(u8, r.body, "\"engine\":{") orelse return error.NoEngine;
    const end = std.mem.indexOfScalarPos(u8, r.body, at, '}') orelse return error.NoEngine;
    var found_engine: [8][]const u8 = undefined;
    const engine_keys = topLevelKeys(r.body[at + "\"engine\":".len .. end + 1], &found_engine);
    for ([_][]const u8{ "power", "prefetch", "split" }) |key| {
        testing.expect(hasKey(engine_keys, key)) catch |e| {
            std.debug.print("\n  telemetry engine object has no key {s}\n  {s}\n", .{
                key, r.body[at .. end + 1],
            });
            return e;
        };
    }

    // Still the shape the dashboard parses, and still the right size for its
    // declared length.
    try testing.expectEqual(@as(u8, '{'), r.body[0]);
    try testing.expectEqual(@as(u8, '}'), r.body[r.body.len - 1]);
    try r.expectLengthMatchesBody();
    try expectStatus(r, "200 OK", "GET /api/telemetry");
}

test "a HEAD connection carries no phantom body and is closed after it" {
    // The framing bug cannot be caught from the response alone: `respond`
    // advertised the right Content-Length and could still have written the
    // body anyway, leaving bytes in the socket that a client reading by
    // Content-Length would swallow as the start of the next response. So this
    // reads the header block only and then requires that not one further byte
    // is available.
    const h = try wire.harness();

    // First an ordinary exchange, to pin the status and the framing.
    const head_only = try h.get("HEAD", "/");
    try expectStatus(head_only, "200 OK", "HEAD /");
    try testing.expectEqual(@as(usize, 0), head_only.body.len);

    // Then the same request again on its own connection, reading only the
    // header block and probing the socket for anything after it. `dispatch`
    // does the connect/send/serve sequence in one place, so this cannot end up
    // with a second connection queued behind the first.
    const s = try h.dispatch("HEAD / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    defer wire.close(s);

    var head_buf: [4096]u8 = undefined;
    const head = try Response.parse(try wire.readHeaderBlock(s, &head_buf));
    try expectStatus(head, "200 OK", "HEAD / header block");
    try testing.expect(head.content_length.? > 0);

    // The phantom check. Zero bytes may be here only if the server withheld
    // the body; the Content-Length above says the length a GET owed, so
    // anything at all on this socket is a body that should not exist.
    var probe: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), wire.bytesAvailable(s, &probe, 300));

    // `Connection: close` was declared, so a second request down this same
    // socket gets no second response rather than the tail of a first one.
    // Deliberately `sendOn`, not `dispatch`: this is the pipelining question,
    // and dispatching would open a fresh connection and ask nothing.
    wire.sendOn(s, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    try testing.expectEqual(@as(usize, 0), wire.bytesAvailable(s, &probe, 300));
}
