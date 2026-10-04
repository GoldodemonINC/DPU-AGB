//! The telemetry document, and the only thing that builds it.
//!
//! This is pure: a `Context` in, bytes out. It opens no socket and writes no
//! response, which is the whole reason it can be reasoned about on its own --
//! before this was a method on the transport, the JSON shape and the HTTP
//! framing were the same 120 lines, and a field could only be checked by
//! starting a server.
//!
//! A general JSON serializer would be more code and slower for a document
//! whose shape never varies. Numbers go through `fmt` with explicit precision
//! so the client never has to parse locale-formatted output.

const std = @import("std");
const win = @import("win");
const telemetry = @import("../telemetry.zig");
const pool_mod = @import("../pool.zig");
const tiers = @import("tiers");
const context = @import("context.zig");

/// Room for the document. The payload is about 5 KiB on this machine; this is
/// the same buffer the serializer has always used, and `render` reports
/// `NoSpace` rather than truncating a JSON object into something that parses
/// but lies.
pub const BUFFER_BYTES = 16384;

/// The `Content-Type` of the document, stated here because the transport
/// decides the MIME type and the document owns its own shape.
pub const MIME = "application/json";

/// Build the telemetry document into `buf`.
///
/// A fixed buffer rather than an allocation because this runs on every
/// dashboard poll and the size never varies with the request.
///
/// Every field below is part of the contract the dashboard parses. The wire
/// suite asserts the top-level keys and the `engine` keys are present, which is
/// what catches a field being dropped during a refactor of this file; the
/// `buffer` object's fields are only emitted when the capacity pool is open, so
/// they are checked against a running engine rather than by the gate.
pub fn render(ctx: *const context.Context, buf: []u8) error{NoSpace}![]const u8 {
    const now_ms = context.EngineState.nowMs();
    const last_sample_ms = ctx.last_sample_ms;
    var w = std.Io.Writer.fixed(buf);

    const s = ctx.sampler;
    var counter_buf: [64]win.CounterValue = undefined;
    const counters = ctx.query.sample(&counter_buf);

    w.print("{{\"t\":{d}", .{now_ms}) catch return error.NoSpace;
    w.print(",\"uptimeMs\":{d}", .{ctx.engine.uptimeMs()}) catch return error.NoSpace;

    // Engine policy, mirrored so the UI renders the same state it set.
    w.print(",\"engine\":{{\"power\":\"{s}\",\"prefetch\":{d},\"split\":{s}}}", .{
        ctx.engine.power.label(),
        ctx.engine.power.prefetchDepth(),
        if (ctx.engine.split) "true" else "false",
    }) catch return error.NoSpace;

    // Named scalar counters, keyed by the paths registered in main.
    w.writeAll(",\"counters\":{") catch return error.NoSpace;
    var first = true;
    for (ctx.query.counters.items, counters) |ctr, val| {
        if (!first) w.writeAll(",") catch return error.NoSpace;
        first = false;
        w.print("\"{s}\":{d:.2}", .{ ctr.key, val.value }) catch return error.NoSpace;
    }
    w.writeAll("}") catch return error.NoSpace;

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
    }) catch return error.NoSpace;

    // Tracked processes for the node manager.
    w.writeAll(",\"procs\":[") catch return error.NoSpace;
    var emitted: usize = 0;
    for (s.procs.items, 0..) |*p, i| {
        // Sorting by working set keeps the heaviest nodes at the top; the
        // dashboard shows a fixed number of slots and those are the ones
        // that matter.
        if (emitted >= 40) break;
        if (p.working_set < 512 * 1024) continue;
        if (emitted > 0) w.writeAll(",") catch return error.NoSpace;
        emitted += 1;
        w.print("{{\"pid\":{d},\"name\":\"", .{p.pid}) catch return error.NoSpace;
        for (p.name[0..p.name_len]) |ch| {
            if (ch == '"' or ch == '\\') w.writeAll("\\") catch return error.NoSpace;
            w.writeByte(ch) catch return error.NoSpace;
        }
        w.print("\",\"role\":\"{s}\",\"ws\":{d},\"priv\":{d},\"pf\":{d},\"cpu\":{d:.1}}}", .{
            p.role.label(), p.working_set, p.private_bytes, p.page_faults, s.cpuFor(i),
        }) catch return error.NoSpace;
    }
    w.writeAll("]") catch return error.NoSpace;

    // Capacity pool on P:\. Reported from the pool itself rather than from
    // volume free space, so the dashboard shows what the DPU buffer is
    // doing rather than merely how full the drive is.
    if (ctx.pool) |p| {
        const st = p.sample(@intCast(@max(now_ms - last_sample_ms, 1)));
        // Resolved per request rather than cached, so a power-mode change
        // shows up on the next tick even though the pool's own ceiling is
        // monotonic and will not move until the tier is applied.
        //
        // A one-element root list: the pool is still one file on a single
        // volume. The resolver takes a list because it holds back the
        // reserve per volume, so widening this to the nested volume is a
        // change here rather than a change to every caller.
        const roots = [_]u64{p.freeSpace()};
        const res = tiers.resolve(ctx.engine.power.tier(), &roots);
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
        ) catch return error.NoSpace;
    } else {
        w.writeAll(",\"buffer\":null") catch return error.NoSpace;
    }

    // System-wide totals the engine needs for residency decisions.
    w.print(",\"total\":{{\"workingSet\":{d},\"processes\":{d},\"agents\":{d},\"graphics\":{d}}}", .{
        s.totalWorkingSet(),
        s.procs.items.len,
        s.roleCount(.agent),
        s.roleCount(.graphics),
    }) catch return error.NoSpace;

    w.writeAll("}") catch return error.NoSpace;
    return w.buffered();
}
