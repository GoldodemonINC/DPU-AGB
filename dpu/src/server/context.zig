//! The state the control surface owns.
//!
//! `EngineState` is engine policy, not HTTP: the power mode and the split flag
//! are decisions the engine makes, and the dashboard happens to be able to set
//! them. It lives here rather than in `server.zig` so the telemetry document
//! can read it without importing the transport module that writes it -- which
//! is what keeps this a dependency rather than a cycle, and keeps one owner for
//! every field a response can report.

const std = @import("std");
const win = @import("win");
const telemetry = @import("../telemetry.zig");
const pool_mod = @import("../pool.zig");
const tiers = @import("tiers");

const c = win.c;

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

/// Everything a request needs in order to be answered. Passing an explicit
/// context keeps the handlers free of globals and makes the sampling cadence
/// testable.
///
/// `pool` is optional so a failure to open the capacity pool degrades the
/// dashboard to capacity-less reporting rather than preventing startup.
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
