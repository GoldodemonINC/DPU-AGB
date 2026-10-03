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
    /// True when no volume has room for even the mode's lowest tier.
    starved: bool,
    /// Free space the grant was computed against, summed over every root, for
    /// the dashboard. This is the number that was actually available, not a
    /// single volume's share of it.
    free_at_check: u64,
    /// How many volumes the grant was computed across. The reserve is taken
    /// once per volume, so this is the multiplier that explains why two roomy
    /// volumes are not quite as roomy as their sum.
    roots: u32,
};

/// Pick the largest tier that fits both the mode's ceiling and the space
/// actually free once the reserve is taken off the top.
///
/// `roots` is the free space of each volume the pool may live on, in bytes.
/// The budget is their sum less `RESERVE_BYTES` *per volume*, not per pool:
/// filling a disk is the one outcome that cannot be recovered from, and that
/// promise has to hold for every volume involved, not just the first one the
/// pool happens to land on. Two volumes that each sit 3 GiB above their own
/// reserve together offer 2 GiB, not 4 -- spending the second volume's
/// headroom would leave the OS no room on it.
///
/// The mode is an upper bound, not a floor. An earlier version searched only
/// the mode's own band, which meant MAX on a 7 GiB volume granted nothing at
/// all while 4 GiB sat available — the mode was supposed to be asking for
/// more room, not vetoing the pool's existence. Degrading below the band is
/// the difference between "asking for 24" and "having no device".
pub fn resolve(mode: Mode, roots: []const u64) Resolution {
    const requested = mode.maxTier();

    // Saturating: a bogus free-space figure must clamp to a smaller pool, not
    // wrap into a huge budget that the ladder would happily grant.
    var total: u64 = 0;
    for (roots) |r| total +|= r;
    const reserve = RESERVE_BYTES *| @as(u64, @intCast(roots.len));
    const budget = if (total > reserve) total - reserve else 0;

    const cap = @min(requested, budget);
    const granted = tierAtOrBelow(cap);

    return .{
        .requested = requested,
        .granted = granted,
        .clamped = granted != requested,
        .starved = granted == 0,
        .free_at_check = total,
        .roots = @intCast(roots.len),
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
    try testing.expectEqual(@as(u64, 4 * GiB), resolve(.low, &[_]u64{plenty}).granted);
    try testing.expectEqual(@as(u64, 8 * GiB), resolve(.x_high, &[_]u64{plenty}).granted);
    try testing.expectEqual(@as(u64, 24 * GiB), resolve(.max, &[_]u64{plenty}).granted);
    for ([_]Mode{ .low, .x_high, .max }) |m| {
        const r = resolve(m, &[_]u64{plenty});
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
        const r = resolve(m, &[_]u64{seven});
        try testing.expectEqual(expect_grant, r.granted);
        try testing.expect(r.granted > 0); // never a blackout
        try testing.expect(r.granted <= budget);
        // LOW lands exactly on its own 4 GiB ceiling here, so it is the one
        // mode that is *not* clamped; the flag has to track that distinction
        // rather than simply mean "free space was low".
        try testing.expectEqual(r.granted != r.requested, r.clamped);
    }
    try testing.expect(!resolve(.low, &[_]u64{seven}).clamped);
    try testing.expect(resolve(.x_high, &[_]u64{seven}).clamped);
    try testing.expect(resolve(.max, &[_]u64{seven}).clamped);
}

test "a mode never exceeds its own ceiling even on a huge volume" {
    const huge = 512 * GiB;
    try testing.expect(resolve(.low, &[_]u64{huge}).granted <= Mode.low.maxTier());
    try testing.expect(resolve(.x_high, &[_]u64{huge}).granted <= Mode.x_high.maxTier());
    try testing.expectEqual(Mode.max.maxTier(), resolve(.max, &[_]u64{huge}).granted);
}

test "24 GiB is refused on this volume because it does not fit" {
    // P:\ is 25.23 GiB total. Even ignoring the reserve, a 24 GiB pool would
    // leave the OS under 1.3 GiB on the same physical disk, so the ladder's
    // top rung is only ever granted somewhere with room to spare.
    const actual = 25.17 * @as(f64, GiB);
    const r = resolve(.max, &[_]u64{@intFromFloat(actual)});
    try testing.expect(r.clamped);
    try testing.expect(r.granted < 24 * GiB);
    try testing.expectEqual(@as(u64, 16 * GiB), r.granted);
}

test "a starved volume reports starvation rather than a silent zero" {
    for ([_]Mode{ .low, .x_high, .max }) |m| {
        const r = resolve(m, &[_]u64{RESERVE_BYTES / 2});
        try testing.expect(r.starved);
        try testing.expectEqual(@as(u64, 0), r.granted);
        // The request is still reported, so the UI can say why.
        try testing.expectEqual(m.maxTier(), r.requested);
    }
}

test "granted never exceeds requested even on an enormous volume" {
    for ([_]Mode{ .low, .x_high, .max }) |m| {
        const r = resolve(m, &[_]u64{1024 * GiB});
        try testing.expect(r.granted <= r.requested);
    }
}

// ------------------------------------------------------------- multiple roots

test "two volumes grant MAX where either alone would clamp it" {
    // The case this change exists for. P:\ alone is 25.17 GiB, which refuses
    // the 24 GiB rung and settles for 16. Adding the nested volume's 13.79
    // GiB clears 24 GiB plus both reserves, so the top of the ladder becomes
    // reachable for the first time on this machine.
    const p_root: u64 = @intFromFloat(25.17 * @as(f64, GiB));
    const d_root: u64 = @intFromFloat(13.79 * @as(f64, GiB));
    const both = [_]u64{ p_root, d_root };

    const one_root = resolve(.max, &[_]u64{p_root});
    const two_roots = resolve(.max, &both);

    try testing.expect(one_root.clamped);
    try testing.expectEqual(@as(u64, 16 * GiB), one_root.granted);

    try testing.expect(!two_roots.clamped);
    try testing.expectEqual(@as(u64, 24 * GiB), two_roots.granted);
    try testing.expectEqual(@as(u32, 2), two_roots.roots);
}

test "the reserve is taken once per volume, not once per pool" {
    // Each volume sits 3 GiB above its own 2 GiB reserve, so 5 GiB free apiece
    // and 10 GiB gross. The budget is 10 - (2 x 2) = 6 GiB, which lands
    // exactly on a rung. Taking a single reserve instead would offer 8 GiB and
    // leave each disk with 1 GiB for the OS, which is the outcome the reserve
    // exists to prevent.
    const each = RESERVE_BYTES + 3 * GiB;
    const roots = [_]u64{ each, each };
    const r = resolve(.max, &roots);

    try testing.expectEqual(@as(u64, 10 * GiB), r.free_at_check);
    try testing.expectEqual(@as(u64, 6 * GiB), r.granted);
    try testing.expect(r.clamped);
    try testing.expect(!r.starved);
}

test "per-volume reserve and single-reserve accounting give different grants" {
    // The test that would actually fail if the reserve were taken once for the
    // pool. Two volumes of 3 GiB: summing and subtracting one reserve gives
    // 6 - 2 = 4 GiB and a 4 GiB pool, which would consume both disks down to
    // 1 GiB each. Per volume it is 6 - 4 = 2 GiB and a 2 GiB pool.
    const roots = [_]u64{ 3 * GiB, 3 * GiB };
    const per_volume = resolve(.max, &roots);
    const single_reserve = tierAtOrBelow(6 * GiB - RESERVE_BYTES);

    try testing.expectEqual(@as(u64, 2 * GiB), per_volume.granted);
    try testing.expectEqual(@as(u64, 4 * GiB), single_reserve);
    try testing.expect(per_volume.granted != single_reserve);
}

test "two volumes that each have the reserve and nothing more are starved" {
    // The per-volume reserve is the whole point: a volume that is exactly at
    // its reserve contributes nothing, however many of them there are.
    const at_reserve = [_]u64{ RESERVE_BYTES, RESERVE_BYTES };
    try testing.expect(resolve(.low, &at_reserve).starved);
    try testing.expectEqual(@as(u64, 0), resolve(.low, &at_reserve).granted);
}

test "one volume resolving through the multi-root path is unchanged" {
    // The single-volume case is not a special case that could drift; it is
    // the same arithmetic with a one-element slice, and this pins that.
    const free = 25.17 * @as(f64, GiB);
    const bytes: u64 = @intFromFloat(free);
    const r = resolve(.max, &[_]u64{bytes});
    try testing.expectEqual(@as(u64, 16 * GiB), r.granted);
    try testing.expectEqual(@as(u32, 1), r.roots);
    try testing.expectEqual(bytes, r.free_at_check);
}

test "no volumes grants nothing rather than an unlimited pool" {
    const none = resolve(.max, &[_]u64{});
    try testing.expectEqual(@as(u64, 0), none.granted);
    try testing.expect(none.starved);
    try testing.expectEqual(@as(u32, 0), none.roots);
    try testing.expectEqual(@as(u64, 0), none.free_at_check);
}

test "an absurd free-space figure cannot overflow into a larger budget" {
    // Saturating add: two volumes each reporting u64 max must not wrap into a
    // budget smaller than one of them, which would silently clamp MAX.
    const huge = [_]u64{ std.math.maxInt(u64), std.math.maxInt(u64) };
    const r = resolve(.max, &huge);
    try testing.expectEqual(std.math.maxInt(u64), r.free_at_check);
    try testing.expectEqual(Mode.max.maxTier(), r.granted);
    try testing.expect(!r.clamped);
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
