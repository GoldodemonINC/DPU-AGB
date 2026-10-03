//! DPU engine entry point.
//!
//! Samples real Windows counters on a fixed cadence and serves them to the
//! dashboard over loopback HTTP. The accept loop is driven by a socket receive
//! timeout rather than a dedicated sampler thread: there is one client, the
//! cadence is coarse, and avoiding the thread removes any question of the
//! sampler's state being read while it is mid-update.
const std = @import("std");
const win = @import("win");
const telemetry = @import("telemetry.zig");
const server = @import("server.zig");
const pool_mod = @import("pool.zig");

const c = win.c;

/// Sampling cadence. Fast enough to look live, slow enough that walking the
/// process table every tick stays in the sub-millisecond range.
const SAMPLE_MS: u32 = 250;

/// Static counters. Keys here are the names the dashboard plots.
const STATIC_COUNTERS = [_]struct { path: []const u8, key: []const u8 }{
    .{ .path = "\\Memory\\Page Faults/sec", .key = "page_faults_per_sec" },
    .{ .path = "\\Memory\\Available Bytes", .key = "mem_available" },
    .{ .path = "\\Memory\\Committed Bytes", .key = "mem_committed" },
    .{ .path = "\\Memory\\Commit Limit", .key = "mem_commit_limit" },
    .{ .path = "\\Memory\\Cache Bytes", .key = "file_cache_bytes" },
    .{ .path = "\\PhysicalDisk(_Total)\\Disk Read Bytes/sec", .key = "disk_read_bps" },
    .{ .path = "\\PhysicalDisk(_Total)\\Disk Write Bytes/sec", .key = "disk_write_bps" },
};

/// Wildcard counters, expanded to every matching instance at startup so the
/// dashboard adapts to whatever adapters the machine actually has.
const WILDCARD_COUNTERS = [_]struct { path: []const u8, prefix: []const u8 }{
    .{ .path = "\\GPU Adapter Memory(*)\\Shared Usage", .prefix = "gpu_shared" },
    .{ .path = "\\GPU Adapter Memory(*)\\Dedicated Usage", .prefix = "gpu_dedicated" },
};

/// Volume the DPU capacity pool lives on. Converted to UTF-16 at compile time
/// because every Win32 path-taking call here is the wide variant.
const POOL_PATH: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("P:\\");
const POOL_VOLUME: []const u8 = "P:\\";
const POOL_DIR: []const u8 = "P:\\DPU";

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    const gpa = gpa_state.allocator();

    var query = try win.Query.init(gpa);
    defer query.deinit();

    for (STATIC_COUNTERS) |entry| {
        try query.add(entry.path, entry.key);
    }
    var wildcard_buf: [8192]u8 = undefined;
    for (WILDCARD_COUNTERS) |entry| {
        const n = try query.addWildcard(entry.path, entry.prefix, &wildcard_buf);
        std.debug.print("  {s}: {d} instance(s)\n", .{ entry.prefix, n });
    }
    std.debug.print("counters registered: {d}\n", .{query.counters.items.len});

    // Two samples are needed before PDH will report a rate rather than zero.
    _ = c.PdhCollectQueryData(query.handle);
    win.sleepMs(500);
    _ = c.PdhCollectQueryData(query.handle);

    var sampler = telemetry.Sampler.init(gpa, POOL_PATH);
    defer sampler.deinit();
    sampler.refresh();
    sampler.computeCpuPercent(SAMPLE_MS);

    // The capacity pool is optional. If P:\ is unavailable or unwritable the
    // dashboard still runs and simply reports no buffer, rather than the whole
    // engine failing to start.
    var pool_holder: ?pool_mod.Pool = null;
    if (pool_mod.Pool.init(gpa, POOL_VOLUME, POOL_DIR, pool_mod.DEFAULT_CAPACITY)) |p| {
        pool_holder = p;
        // Start on the tier the initial power mode actually allows, rather than
        // the compile-time default, so the first advertised capacity is one the
        // volume can back. `p` is a const capture; the tier write goes through
        // the holder because raising a ceiling is not a read.
        const res = pool_holder.?.applyTier(server.PowerMode.x_high.tier());
        std.debug.print("  capacity pool: P:\\DPU\\pool.vram  ceiling {d} GB  sparse={}\n", .{
            p.ceiling() / (1024 * 1024 * 1024),
            p.sparse(),
        });
        if (res.clamped) {
            std.debug.print(
                "  tier: wanted {d} GB, volume allows {d} GB ({d} GB free)\n",
                .{ res.requested / (1024 * 1024 * 1024), res.granted / (1024 * 1024 * 1024), res.free_at_check / (1024 * 1024 * 1024) },
            );
        }
    } else |err| {
        std.debug.print("  capacity pool unavailable: {s}\n", .{@errorName(err)});
    }
    defer if (pool_holder) |*p| p.deinit();

    var srv = try server.Server.bind(server.DEFAULT_PORT);
    var engine = server.EngineState{};
    engine.booted_at_ms = server.EngineState.nowMs();

    var ctx = server.Context{
        .sampler = &sampler,
        .query = &query,
        .engine = &engine,
        .pool = if (pool_holder) |*p| p else null,
        .last_sample_ms = engine.booted_at_ms,
    };

    // Time out accept() so the loop can keep the sampling cadence even when the
    // dashboard is closed. Without this the sampler would only advance when
    // someone was actually looking at it.
    setAcceptTimeout(srv.listen_fd, SAMPLE_MS);

    std.debug.print(
        "\n  DPU control surface  ->  http://127.0.0.1:{d}\n  sampling @ {d}ms\n\n  Ctrl+C to stop.\n\n",
        .{ server.DEFAULT_PORT, SAMPLE_MS },
    );

    var last_ms = SAMPLEState.nowMs();
    while (true) {
        srv.serveOnce(&ctx);

        const now = server.EngineState.nowMs();
        if (now - last_ms >= SAMPLE_MS) {
            _ = c.PdhCollectQueryData(query.handle);
            sampler.refresh();
            sampler.computeCpuPercent(@intCast(now - last_ms));
            ctx.last_sample_ms = last_ms;
            last_ms = now;
        }
    }
}

/// `SAMPLEState` is a tiny alias so the loop can read the same monotonic-ish
/// clock the server uses for uptime, without threading a helper import around.
const SAMPLEState = struct {
    fn nowMs() i64 {
        return server.EngineState.nowMs();
    }
};

/// Bound how long accept() blocks so the sampler keeps its cadence.
fn setAcceptTimeout(fd: c.SOCKET, ms: u32) void {
    const timeout = c.timeval{
        .tv_sec = @intCast(ms / 1000),
        .tv_usec = @intCast((ms % 1000) * 1000),
    };
    // Failure here only means the loop falls back to sampling per-request,
    // which is slower but correct.
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, @ptrCast(&timeout), @intCast(@sizeOf(c.timeval)));
}
