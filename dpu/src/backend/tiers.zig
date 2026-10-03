//! Capacity tiers for the DPU pool.
//!
//! The pool has one knob — the ceiling — and that knob decides how much the
//! DPU advertises to clients, so it wants to move with the engine's power mode
//! rather than sit fixed. It is deliberately a ladder of discrete stops rather
//! than a continuous value: a client that sizes buffers from the advertised
//! capacity should not see it drift underneath it, and the dashboard needs
//! somewhere unambiguous to display.
//!
//! Nothing here reserves space. A tier is a promise about the maximum, and the
//! pool only consumes what is actually written, so sitting on the 24 GiB tier
//! costs nothing until a client fills it.
//!
//! The one thing that can hurt the machine is filling the volume, because the
//! pool lives on P:\ alongside the pagefile's physical disk. A tier is
//! therefore never granted just because it is the highest one the mode
//! allows; it has to fit inside the space actually free, minus a reserve.

const std = @import("std");

const GiB: u64 = 1024 * 1024 * 1024;

/// The ladder, ascending. `max` and `x_high` reach further than `low`, and
/// the top of the ladder is deliberately above what a single tier can be
/// granted on a small volume — see `Resolution`.
pub const LADDER_GIB: [7]u64 = .{ 2, 4, 6, 8, 12, 16, 24 };

/// Space kept back on the volume for everything that is not the pool.
///
/// This is not decoration. The pool shares a physical disk with the pagefile
/// and the OS, and an earlier revision reserved the full ceiling up front and
/// filled P:\ to 1.6 GB free before anyone noticed. A 2 GiB reserve is the
/// floor below which the pool refuses to grow even when a tier would fit.
pub const RESERVE_BYTES: u64 = 2 * GiB;

/// Engine power mode. Mirrors the dashboard's control matrix; kept separate
/// from server.EngineState so the ladder does not depend on the HTTP layer.
pub const Mode = enum {
    low,
    x_high,
    max,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .low => "LOW",
            .x_high => "xHIGH",
            .max => "MAX",
        };
    }

    /// Tier indices this mode prefers, ascending.
    ///
    /// Grouping is what makes a mode change meaningful: LOW reaches for a
    /// small pool, MAX a large one, and xHIGH sits between. This is a
    /// *preference*, not a floor — see `resolve`, which will fall below the
    /// band rather than leave the pool with nowhere to live.
    pub fn band(self: Mode) []const usize {
        return switch (self) {
            .low => &[_]usize{ 0, 1 }, // 2, 4
            .x_high => &[_]usize{ 2, 3 }, // 6, 8
            .max => &[_]usize{ 4, 5, 6 }, // 12, 16, 24
        };
    }

    /// Highest tier this mode will ever ask for.
    pub fn maxTier(self: Mode) u64 {
        const b = self.band();
        return LADDER_GIB[b[b.len - 1]] * GiB;
    }
};

/// Outcome of resolving a mode against the space actually available.
pub const Resolution = struct {
    /// The mode's top tier, before free space was considered.
    requested: u64,
    /// What the pool may actually use. Zero when nothing in the band fits.
    granted: u64,
    /// True when free space cut the request below the mode's preference.
    clamped: bool,
    /// True when the volume is too full for even the mode's lowest tier.
    starved: bool,
    /// Free space the grant was computed against, for the dashboard.
    free_at_check: u64,
};

/// Pick the largest tier that fits both the mode's ceiling and the space
/// actually free once the reserve is taken off the top.
///
/// The mode is an upper bound, not a floor. An earlier version searched only
/// the mode's own band, which meant MAX on a 7 GiB volume granted nothing at
/// all while 4 GiB sat available — the mode was supposed to be asking for
/// more room, not vetoing the pool's existence. Degrading below the band is
/// the difference between "asking for 24" and "having no device".
pub fn resolve(mode: Mode, free_bytes: u64) Resolution {
    const requested = mode.maxTier();
    const budget = if (free_bytes > RESERVE_BYTES) free_bytes - RESERVE_BYTES else 0;
    const cap = @min(requested, budget);
    const granted = tierAtOrBelow(cap);

    return .{
        .requested = requested,
        .granted = granted,
        .clamped = granted != requested,
        .starved = granted == 0,
        .free_at_check = free_bytes,
    };
}

/// Nearest tier at or below `bytes`, for clamping a ceiling that was set
/// some other way. Returns 0 when `bytes` is below the first rung.
pub fn tierAtOrBelow(bytes: u64) u64 {
    var best: u64 = 0;
    for (LADDER_GIB) |g| {
        const b = g * GiB;
        if (b <= bytes and b > best) best = b;
    }
    return best;
}

// ------------------------------------------------------- shared tier state

/// File the engine writes and the ICD reads, so both processes agree on how
/// much capacity the DPU is advertising.
///
/// Without this the ICD would have to guess. It loads into whichever process
/// touches Vulkan first — vulkaninfo, llama.cpp, whatever — and those are
/// different processes from the engine, so the ceiling the user set on the
/// dashboard would not otherwise reach the thing that actually has to honour
/// it. A file is a deliberate, boring channel: no shared memory handle to leak
/// and no ordering to get wrong.
pub const state_filename = "tier.cfg";


/// Serialise the granted tier. Written best-effort; a failure here must not
/// take the engine down, because the fallback is a conservative default.
pub fn formatState(buf: []u8, granted: u64, free_at_check: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "tier_bytes={d}\nfree_bytes={d}\n", .{ granted, free_at_check });
}

/// Parse `tier_bytes` out of the state file. Returns null when the file is
/// absent, truncated, or does not contain a plausible tier.
///
/// "Implausible" matters: a half-written file could otherwise advertise a
/// capacity of zero or a garbage number, and a Vulkan application sizing
/// buffers from that is entitled to believe it.
pub fn parseState(text: []const u8) ?u64 {
    var granted: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "tier_bytes=")) {
            const digits = trimmed["tier_bytes=".len..];
            granted = std.fmt.parseInt(u64, digits, 10) catch null;
        }
    }
    const g = granted orelse return null;
    if (g == 0) return null;
    // Snap to the ladder: a value between rungs means a stale or hand-edited
    // file, and the pool cannot honour a capacity it was never sized for.
    const snapped = tierAtOrBelow(g);
    return if (snapped == 0) null else snapped;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "ladder is ascending and ends at 24 GiB" {
    for (LADDER_GIB, 0..) |g, i| {
        if (i > 0) try testing.expect(g > LADDER_GIB[i - 1]);
    }
    try testing.expectEqual(@as(u64, 24), LADDER_GIB[LADDER_GIB.len - 1]);
}

test "mode bands partition the ladder" {
    // Every rung is claimed by exactly one mode, so no tier is unreachable
    // and no two modes fight over the same one.
    var claimed = [_]bool{false} ** LADDER_GIB.len;
    for ([_]Mode{ .low, .x_high, .max }) |m| {
        for (m.band()) |i| {
            try testing.expect(!claimed[i]);
            claimed[i] = true;
        }
    }
    for (claimed) |was| try testing.expect(was);
}

test "modes map to the tiers the dashboard advertises" {
    try testing.expectEqual(@as(u64, 4 * GiB), Mode.low.maxTier());
    try testing.expectEqual(@as(u64, 8 * GiB), Mode.x_high.maxTier());
    try testing.expectEqual(@as(u64, 24 * GiB), Mode.max.maxTier());
}

test "a roomy volume grants each mode its top tier unclamped" {
    const plenty = 64 * GiB;
    try testing.expectEqual(@as(u64, 4 * GiB), resolve(.low, plenty).granted);
    try testing.expectEqual(@as(u64, 8 * GiB), resolve(.x_high, plenty).granted);
    try testing.expectEqual(@as(u64, 24 * GiB), resolve(.max, plenty).granted);
    for ([_]Mode{ .low, .x_high, .max }) |m| {
        const r = resolve(m, plenty);
        try testing.expect(!r.clamped);
        try testing.expect(!r.starved);
    }
}

test "a full volume degrades to a lower tier instead of failing" {
    // 7 GiB free, 2 GiB reserved, leaves 5 GiB of budget. No mode in the band
    // reaches 6 GiB, so all three fall back to the same 4 GiB rung rather
    // than the pool being switched off entirely.
    const seven = 7 * GiB;
    const budget = seven - RESERVE_BYTES;
    const expect_grant = tierAtOrBelow(budget);

    for ([_]Mode{ .low, .x_high, .max }) |m| {
        const r = resolve(m, seven);
        try testing.expectEqual(expect_grant, r.granted);
        try testing.expect(r.granted > 0); // never a blackout
        try testing.expect(r.granted <= budget);
        // LOW lands exactly on its own 4 GiB ceiling here, so it is the one
        // mode that is *not* clamped; the flag has to track that distinction
        // rather than simply mean "free space was low".
        try testing.expectEqual(r.granted != r.requested, r.clamped);
    }
    try testing.expect(!resolve(.low, seven).clamped);
    try testing.expect(resolve(.x_high, seven).clamped);
    try testing.expect(resolve(.max, seven).clamped);
}

test "a mode never exceeds its own ceiling even on a huge volume" {
    const huge = 512 * GiB;
    try testing.expect(resolve(.low, huge).granted <= Mode.low.maxTier());
    try testing.expect(resolve(.x_high, huge).granted <= Mode.x_high.maxTier());
    try testing.expectEqual(Mode.max.maxTier(), resolve(.max, huge).granted);
}

test "24 GiB is refused on this volume because it does not fit" {
    // P:\ is 25.23 GiB total. Even ignoring the reserve, a 24 GiB pool would
    // leave the OS under 1.3 GiB on the same physical disk, so the ladder's
    // top rung is only ever granted somewhere with room to spare.
    const actual = 25.17 * @as(f64, GiB);
    const r = resolve(.max, @intFromFloat(actual));
    try testing.expect(r.clamped);
    try testing.expect(r.granted < 24 * GiB);
    try testing.expectEqual(@as(u64, 16 * GiB), r.granted);
}

test "a starved volume reports starvation rather than a silent zero" {
    for ([_]Mode{ .low, .x_high, .max }) |m| {
        const r = resolve(m, RESERVE_BYTES / 2);
        try testing.expect(r.starved);
        try testing.expectEqual(@as(u64, 0), r.granted);
        // The request is still reported, so the UI can say why.
        try testing.expectEqual(m.maxTier(), r.requested);
    }
}

test "granted never exceeds requested even on an enormous volume" {
    for ([_]Mode{ .low, .x_high, .max }) |m| {
        const r = resolve(m, 1024 * GiB);
        try testing.expect(r.granted <= r.requested);
    }
}

test "tier state round-trips through the file format" {
    var buf: [128]u8 = undefined;
    const text = try formatState(&buf, 16 * GiB, 25 * GiB);
    try testing.expectEqual(@as(u64, 16 * GiB), parseState(text).?);
}

test "tier state is snapped to the ladder on the way in" {
    // A hand-edited or half-written file must not make the DPU advertise a
    // capacity the pool was never sized for.
    try testing.expectEqual(@as(u64, 16 * GiB), parseState("tier_bytes=20000000000").?);
    try testing.expectEqual(@as(u64, 2 * GiB), parseState("tier_bytes=2147483648").?);
}

test "a missing or nonsensical tier file yields null, not a bad capacity" {
    try testing.expectEqual(@as(?u64, null), parseState(""));
    try testing.expectEqual(@as(?u64, null), parseState("tier_bytes="));
    try testing.expectEqual(@as(?u64, null), parseState("tier_bytes=abc"));
    try testing.expectEqual(@as(?u64, null), parseState("tier_bytes=0"));
    try testing.expectEqual(@as(?u64, null), parseState("free_bytes=1234\n"));
    // Below the first rung, and trailing garbage from a partial write.
    try testing.expectEqual(@as(?u64, null), parseState("tier_bytes=1024"));
    try testing.expectEqual(@as(?u64, null), parseState("tier_bytes=214748"));
}

test "tierAtOrBelow floors to the nearest rung" {
    try testing.expectEqual(@as(u64, 0), tierAtOrBelow(0));
    try testing.expectEqual(@as(u64, 0), tierAtOrBelow(GiB));
    try testing.expectEqual(@as(u64, 2 * GiB), tierAtOrBelow(2 * GiB));
    try testing.expectEqual(@as(u64, 2 * GiB), tierAtOrBelow(3 * GiB));
    // One byte under a rung floors to the rung below it, not to itself.
    try testing.expectEqual(@as(u64, 4 * GiB), tierAtOrBelow(6 * GiB - 1));
    try testing.expectEqual(@as(u64, 6 * GiB), tierAtOrBelow(6 * GiB));
    try testing.expectEqual(@as(u64, 24 * GiB), tierAtOrBelow(24 * GiB));
    try testing.expectEqual(@as(u64, 24 * GiB), tierAtOrBelow(999 * GiB));
}
