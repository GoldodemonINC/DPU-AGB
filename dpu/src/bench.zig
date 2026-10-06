//! Measure the real I/O ceiling of the P:\ pool.
//!
//! This exists to produce the number every later layer will be planned against.
//!
//! The first version of this benchmark reported 2560 MB/s, because it ran
//! through the page cache. Rewritten to use `NO_BUFFERING | WRITE_THROUGH` it
//! reported 4266 MB/s sequential and 3 microsecond random reads — still far too
//! good for an NVMe, and now for a different reason. The volume is exposed over
//! a RAID controller with its own cache, and a 256 MiB working set fits inside
//! it. Those figures were real measurements of a cached path, not of the
//! device.
//!
//! So the benchmark sweeps the working set. Small numbers describe behaviour
//! inside the storage cache; only the largest, once the set no longer fits,
//! describes the device the DPU will actually depend on. That largest figure is
//! the one to plan against.

const std = @import("std");
const blockdev = @import("blockdev");
const residency = @import("residency");
const tiers = @import("tiers");
const win = @import("win");
const c = win.c;

const MB: f64 = 1024.0 * 1024.0;

/// One mebibyte in bytes, for the integer arithmetic above.
const MB_BYTES: u64 = 1024 * 1024;

/// The smallest working set at which this volume's curve goes cold. Below it
/// the RAID controller's own cache answers, and a rate measured there is not a
/// rate the device can hold. Established by the sweep itself: on this machine
/// 2048 MiB still reads at 4 GB/s and 4096 MiB reads at 413.
const DEVICE_SIZED_MIB: u64 = 4096;

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    std.debug.print(
        \\
        \\  DPU pool — uncached device measurement
        \\  =========================================
        \\  transfer : 1 MiB blocks, NO_BUFFERING | WRITE_THROUGH
        \\
        \\  Working-set sweep. The volume sits behind a RAID controller with its
        \\  own cache, so small sets measure that cache rather than the device.
        \\  Only the largest rows are the device.
        \\
        \\     size    write MB/s   read MB/s   rnd rd us    rnd IOPS
        \\  ---------------------------------------------------
        \\
    , .{});

    // Deliberately spans well past any plausible controller cache so the tail
    // of the curve reflects the device.
    const sizes = [_]u64{ 64, 256, 1024, 2048, 4096, 8192 };

    // Measured before the sweep, not after: an 8 GiB write storm leaves the
    // system busy enough to halve a naive memcpy reading.
    const ram = measureRam(gpa);
    var device_random_us: f64 = 0;
    // The largest row's read rate, kept as the strictest streaming figure the
    // run produces. The granule sweep below reads a region it has just written,
    // so part of it is still in the controller cache and it reads optimistically;
    // this one does not, and the planner is not allowed to promise a rate only
    // the warmer measurement can reach.
    var cold_stream_mbps: f64 = 0;

    var dev = try blockdev.BlockDevice.init(gpa, "P:\\", "P:\\DPU", blockdev.DEFAULT_CEILING);
    // Unlink the pool afterwards. The sweep writes gigabytes; closing the handle
    // alone leaves all of it behind on P:\. The outcome is reported rather than
    // assumed: a peer process still holding the pool makes the delete fail, and
    // the volume used to drift downwards across runs with nothing saying why.
    defer {
        dev.destroy();
        if (dev.poolRemoved()) {
            std.debug.print("\n  pool unlinked; its space returns when the last handle closes\n", .{});
        } else {
            std.debug.print(
                \\
                \\  WARNING: the pool file could NOT be deleted -- another
                \\  process still has it open. Its bytes are still on P:\ and the
                \\  next run will reopen that same pool rather than a fresh one.
                \\  Close whatever is holding P:\DPU\pool.vram.
                \\
            , .{});
        }
    }
    std.debug.print("  sparse={s}  ceiling={d:.1} GB\n", .{
        if (dev.sparse) "yes" else "no",
        @as(f64, @floatFromInt(dev.ceiling)) / 1073741824.0,
    });

    // Skip any row the volume cannot hold beside the pool's own reserve. The
    // block layer refuses to grow past free-space-minus-reserve, so a fixed
    // ladder makes the whole benchmark fail on a volume that is merely busy:
    // on 2026-10-05 the 8192 row raised PoolOutOfSpace with 8.2 GB free, once
    // the 2 GiB reserve and the growth chunk had been taken off the top. The
    // row is dropped and named rather than the run being lost, because a
    // partial curve still answers the question the sweep is for.
    const free = if (win.VolumeSpace.query(dev.volume)) |s| s.free else 0;
    const headroom = free -| (tiers.RESERVE_BYTES + 64 * MB_BYTES);
    std.debug.print("  volume free {d:.1} GB, sweep headroom {d:.1} GB\n\n", .{
        @as(f64, @floatFromInt(free)) / 1073741824.0,
        @as(f64, @floatFromInt(headroom)) / 1073741824.0,
    });

    for (sizes) |mib| {
        if (mib * MB_BYTES > headroom) {
            std.debug.print("  {d:>5} MiB  skipped -- needs {d:.1} GB, headroom is {d:.1} GB\n", .{
                mib,
                @as(f64, @floatFromInt(mib * MB_BYTES)) / 1073741824.0,
                @as(f64, @floatFromInt(headroom)) / 1073741824.0,
            });
            continue;
        }
        const r = try sweep(&dev, mib);
        device_random_us = r.rand_read_us;
        // The strictest device-sized row of this run, not merely the last one.
        // Only rows at or above the size the curve goes cold at are eligible:
        // a 64 MiB row is measuring the controller's cache, and letting it into
        // this minimum would cap every later plan at a cache rate.
        if (mib >= DEVICE_SIZED_MIB) {
            // The *minimum* of the eligible rows, not the last one. Two
            // device-sized rows disagree by real amounts -- 412.7 MB/s at
            // 4096 MiB against 470.8 at 8192 on the same run -- and taking the
            // later one would let the plan promise a rate the stricter row does
            // not reach.
            cold_stream_mbps = if (cold_stream_mbps > 0)
                @min(cold_stream_mbps, r.read_mbps)
            else
                r.read_mbps;
        }
        std.debug.print("  {d:>5} MiB  {d:>12.1}  {d:>11.1}  {d:>11.1}  {d:>10.0}\n", .{
            mib, r.write_mbps, r.read_mbps, r.rand_read_us, r.rand_iops,
        });
    }

    // ---------------------------------------------------- single-block latency
    // One 4 KiB block, timed on its own. At small working sets this is the
    // cheapest possible operation and the most likely to be served from cache.
    std.debug.print("\n  single 4 KiB block latency (best of 200, repeats cached):\n", .{});
    var small = try blockdev.AlignedBuffer.alloc(blockdev.SECTOR);
    defer small.free();
    @memset(small.bytes, 0x33);
    _ = try dev.write(0, small.bytes);
    dev.flush();

    var best: f64 = 1e9;
    for (0..200) |_| {
        const t = tickUs();
        _ = try dev.read(0, small.bytes);
        const el = usSince(t);
        if (el < best) best = el;
    }
    std.debug.print("    uncached read : {d:.1} us best-case\n", .{best});

    var best_w: f64 = 1e9;
    for (0..200) |_| {
        const t = tickUs();
        _ = try dev.write(0, small.bytes);
        const el = usSince(t);
        if (el < best_w) best_w = el;
    }
    dev.flush();
    std.debug.print("    uncached write: {d:.1} us best-case\n", .{best_w});

    // ------------------------------------------------------------- reference
    //
    // Every figure below is measured in this run, on this machine, and the
    // ratio is computed from the two measured halves rather than from a quoted
    // constant. An earlier revision printed `67.3 / 0.08` here: `device_random_us`
    // beside it was real, `0.08` was a hardcoded literal that nothing measured,
    // and the printed multiplier was the invention divided by the invention's
    // partner. README quoted the same 840x for months.
    const ratio = if (ram.random_us > 0) device_random_us / ram.random_us else 0;
    std.debug.print(
        \\
        \\  reference -- every figure below was measured in this run:
        \\
        \\    system RAM memcpy         {d:>8.0} MB/s   (256 MiB, sequential)
        \\    system RAM random access  {d:>8.3} us     (dependent loads, 256 MiB set)
        \\    pool random access        {d:>8.1} us     (uncached 4 KiB reads, 8 GiB set)
        \\
        \\  => the pool runs about {d:.0}x slower than RAM on random access,
        \\     dividing the two measured numbers above. That gap, not the
        \\     bandwidth, is what every layer above has to design around.
        \\
    , .{
        ram.mbps,
        ram.random_us,
        device_random_us,
        ratio,
    });

    // --------------------------------------------------- fault economics
    //
    // Everything above sweeps one transfer size, 1 MiB. That is the right
    // granule for moving a file and the wrong question for a fault-driven
    // client: a scheduler decides what to keep resident, and the only thing it
    // can trade against residency is what one *fault* costs. A 4 KiB fault and
    // a 1 MiB fault are the same syscall and wildly different amounts of work,
    // so the granule is a policy decision, not an implementation detail.
    //
    // This is the table the residency planner is calibrated from. It is
    // measured here, uncached, on a set larger than the controller's cache, so
    // the tail is the device.
    // Optional because the sweep can fail: an unavailable grant or a short read
    // must not take the benchmark down, it must take the *plan* down, so the
    // numbers that did come back are still printed beside a named reason.
    const machine: ?residency.Machine = measureGranules(gpa, &dev, cold_stream_mbps, headroom) catch |e| blk: {
        std.debug.print("\n  granule sweep failed: {s}\n\n", .{@errorName(e)});
        break :blk null;
    };
    if (machine) |mm| reportPlans(mm);

    const info = dev.sparseInfo();
    std.debug.print(
        \\
        \\  pool after sweep: logical {d:.2} GB
        \\
        \\  NOTE: AllocationSize from FileStandardInfo reports {d:.2} GB here
        \\  while every byte written reads back intact. It is not a reliable
        \\  measure of committed bytes on this volume, so it is reported but
        \\  never used as a correctness signal.
        \\
    , .{
        @as(f64, @floatFromInt(info.logical)) / 1073741824.0,
        @as(f64, @floatFromInt(info.allocated)) / 1073741824.0,
    });
}

const SweepResult = struct {
    write_mbps: f64,
    read_mbps: f64,
    rand_read_us: f64,
    rand_iops: f64,
};

/// Measure one working-set size. Sequential phases are timed as a whole; the
/// random phase is timed per operation so it reflects latency rather than
/// throughput.
fn sweep(dev: *blockdev.BlockDevice, mib: u64) !SweepResult {
    const block: u64 = 1024 * 1024;
    const blocks: u64 = mib;
    const total = block * blocks;

    var stage = try blockdev.AlignedBuffer.alloc(@intCast(block));
    defer stage.free();
    @memset(stage.bytes, 0xAB);

    var off: u64 = 0;
    const w0 = tickUs();
    while (off < total) : (off += block) {
        const n = try dev.write(off, stage.bytes);
        // A short write here would silently shrink the working set and make
        // every later phase measure the wrong amount of data.
        if (n != block) return error.ShortWrite;
    }
    dev.flush();
    const write_mbps = rate(total, usSince(w0));

    // Flush again so the read phase cannot be answered from anything the write
    // phase left behind.
    dev.flush();

    var small = try blockdev.AlignedBuffer.alloc(blockdev.SECTOR);
    defer small.free();

    var rnd = Random{};
    var lat_sum: f64 = 0;
    const ops: u64 = 256;
    const r0 = tickUs();
    for (0..ops) |_| {
        const at = (rnd.next() % total) & ~@as(u64, blockdev.SECTOR - 1);
        const t = tickUs();
        _ = try dev.read(at, small.bytes);
        lat_sum += usSince(t);
    }
    const read_elapsed = usSince(r0);
    const rand_read_us = lat_sum / @as(f64, @floatFromInt(ops));

    off = 0;
    const s0 = tickUs();
    while (off < total) : (off += block) {
        const n = try dev.read(off, stage.bytes);
        if (n != block) return error.ShortRead;
    }
    const read_mbps = rate(total, usSince(s0));

    return .{
        .write_mbps = write_mbps,
        .read_mbps = read_mbps,
        .rand_read_us = rand_read_us,
        .rand_iops = @as(f64, @floatFromInt(ops)) / (read_elapsed / 1_000_000.0),
    };
}

/// One read at each granule a client might fault in, over a fixed set.
///
/// The set is written once and then read back at every granule, rather than
/// re-written per granule. That matters: the sweep above establishes that this
/// volume sits behind a controller cache large enough to make anything under a
/// couple of gigabytes look four times faster than it is, and a granule sweep
/// that re-wrote a small region before each pass would measure the cache at
/// every row and report a shape that does not exist on the device.
///
/// The region is therefore sized to the smallest set the sweep above identified
/// as the device, and every row reads the same bytes. Per-read microseconds is
/// what a fault costs at that granule; the MB/s column is the ceiling for a run
/// of adjacent faults. A scheduler that faults 4 KiB at a time is bounded by
/// the first column and simply cannot reach the second, which is the whole
/// reason residency policy is about granules and not only about bytes.
fn measureGranules(
    gpa: std.mem.Allocator,
    dev: *blockdev.BlockDevice,
    cold_mbps: f64,
    headroom: u64,
) !residency.Machine {
    const MiB: u64 = 1024 * 1024;
    const one: u64 = MiB;

    // The region has to fit inside the same headroom the sweep rows were
    // checked against. Writing a fixed 4 GiB here is what turned a volume that
    // was merely busy into a dead benchmark: the row loop had already skipped
    // the sizes it could not hold, and then this measurement walked straight
    // into the growth the pool refuses and lost every granule row and the plan
    // along with them.
    const usable_mib = @min(DEVICE_SIZED_MIB, headroom / MiB);
    if (usable_mib < 64) {
        std.debug.print("\n  fault economics skipped -- only {d} MiB of headroom, need 64\n", .{usable_mib});
        return error.NotEnoughHeadroom;
    }
    const total: u64 = usable_mib * MiB;
    std.debug.print(
        \\
        \\  fault economics -- {d} MiB working set, uncached, one read in flight
        \\
        \\     granule   blocks      read MB/s      per-read us
        \\  ---------------------------------------------------
        \\
    , .{usable_mib});

    // Materialise the region once.
    var stage = try blockdev.AlignedBuffer.alloc(@intCast(one));
    defer stage.free();
    @memset(stage.bytes, 0x5A);

    var off: u64 = 0;
    while (off < total) : (off += one) {
        if (try dev.write(off, stage.bytes) != one) return error.ShortWrite;
    }
    dev.flush();

    var buf = try blockdev.AlignedBuffer.alloc(@intCast(one));
    defer buf.free();

    var fault_us: f64 = 0;
    var stream_mbps: f64 = 0;

    const granules = [_]u64{ 4096, 16 * 1024, 64 * 1024, 256 * 1024, one };
    for (granules) |g| {
        const blocks: u64 = total / g;
        dev.flush();

        var lat_sum: f64 = 0;
        const t0 = tickUs();
        var at: u64 = 0;
        while (at < total) : (at += g) {
            const t = tickUs();
            const n = try dev.read(at, buf.bytes[0..@intCast(g)]);
            if (n != g) return error.ShortRead;
            lat_sum += usSince(t);
        }
        const elapsed = usSince(t0);
        const mbps = rate(total, elapsed);
        const per_read = lat_sum / @as(f64, @floatFromInt(blocks));

        std.debug.print("  {d:>8}  {d:>7}  {d:>12.1}  {d:>12.1}\n", .{ g, blocks, mbps, per_read });

        if (g == 4096) fault_us = per_read;
        if (g == one) stream_mbps = mbps;
    }

    try measureFaultPath(dev, gpa, @min(total, 256 * MiB));

    // Planned against the *lower* of the two streaming figures. This pass reads
    // a region it just wrote, so it is partly controller-cached and reads fast;
    // the sweep above does not, and the difference is real rather than noise.
    // A plan that adopted the optimistic one would promise a rate the device
    // cannot hold once the set is genuinely cold.
    const planned_stream = if (cold_mbps > 0) @min(stream_mbps, cold_mbps) else stream_mbps;

    // The planner needs capacity the block device will actually agree to, not
    // the ceiling. `raiseCeiling` takes whatever the tier ladder says, and the
    // ladder is computed against free space at the time of the check -- so on a
    // busy volume the ceiling can be a number the pool will refuse to grow to.
    // Planning against it lets `plan` answer `streamed` for a working set whose
    // storage does not exist.
    //
    // `held` matters as much as the free space. By the time this runs the sweep
    // has already grown the pool to several GiB, and those bytes are already
    // spoken for *and already on the volume* -- they are capacity the planner
    // can use. Counting only the free space understates it by the whole pool
    // size, which is enough on its own to turn a working set that fits into
    // `does_not_fit`.
    const held = dev.sparseInfo().logical;
    const usable_capacity = @min(dev.ceiling, held +| freeSpace(dev));

    std.debug.print(
        \\
        \\  The two constants the residency planner is calibrated from, both
        \\  measured above rather than quoted:
        \\
        \\    one uncached 4 KiB fault   {d:>8.1} us
        \\    streaming, this pass        {d:>8.1} MB/s  (1 MiB, partly warm)
        \\    streaming, sweep above      {d:>8.1} MB/s  (largest device-sized row)
        \\    planned against             {d:>8.1} MB/s  (the lower of the two)
        \\
    , .{ fault_us, stream_mbps, cold_mbps, planned_stream });

    return .{
        .fault_us = fault_us,
        .stream_mbps = planned_stream,
        .pool_bytes = usable_capacity,
    };
}

/// Walk a region through the shipped fault path at two granules.
///
/// The granule table above measures the *device* at several transfer sizes.
/// That is a different claim from "the code gets the benefit", and only this
/// function measures the second: a fault path could read a granule on a miss
/// and immediately throw it away, leaving the table above entirely unchanged
/// while the thing the client actually calls did nothing. So this walks the
/// same materialised region, in the same 4 KiB steps a client would issue,
/// through `residency.Faults` itself, and reports what it gets.
///
/// The walk is bounded at 256 MiB rather than run over the whole region: at a
/// 4 KiB granule this is 65536 faults, and running it over 4 GiB would put
/// forty seconds of the benchmark into proving a point that 256 MiB already
/// proves. Both granules get the same bytes and the same resident budget, so
/// the only variable is the fault size -- which is the entire claim.
fn measureFaultPath(dev: *blockdev.BlockDevice, gpa: std.mem.Allocator, span: u64) !void {
    const step: u64 = 4096;
    if (span < step) return;

    std.debug.print(
        \\
        \\  fault path -- {d:.0} MiB walked in 4 KiB reads, whole walk resident
        \\
        \\    granule   faults      MB/s   hit rate   evictions   round trips
        \\    -----------------------------------------------------------
        \\
    , .{@as(f64, @floatFromInt(span)) / 1024.0});

    for ([_]u64{ 4096, 1024 * 1024 }) |g| {
        var faults = try residency.Faults(blockdev.BlockDevice).init(gpa, dev, .{
            .granule = g,
            // The whole walk fits, so the comparison isolates the fault size
            // and does not quietly measure eviction as well. A path that
            // thrashes would be a different -- and separately interesting --
            // experiment.
            .capacity_bytes = span,
        });
        defer faults.deinit();

        var buf = try blockdev.AlignedBuffer.alloc(@intCast(step));
        defer buf.free();

        // Flushed before the walk so each row starts from the same state, and
        // the row that runs second is not reading bytes the first row warmed.
        dev.flush();

        const t0 = tickUs();
        var off: u64 = 0;
        while (off < span) : (off += step) {
            const n = try faults.read(off, buf.bytes);
            if (n != step) return error.ShortRead;
        }
        const mbps = rate(span, usSince(t0));

        const s = faults.stats();
        std.debug.print(
            "  {d:>8}  {d:>7}  {d:>10.1}  {d:>9.3}  {d:>10}  {d:>12}\n",
            .{ g, s.misses + s.prefetched, mbps, s.hitRate(), s.evictions, s.misses + s.prefetched },
        );
    }

    std.debug.print(
        \\
        \\  The row above is not a device figure: it is what residency.Faults
        \\  actually returns. The granule is the whole difference.
        \\
        \\
    , .{});
}

/// Free space on the volume the pool lives on, or 0 when it cannot be read.
fn freeSpace(dev: *blockdev.BlockDevice) u64 {
    const s = win.VolumeSpace.query(dev.volume) orelse return 0;
    return s.free -| tiers.RESERVE_BYTES;
}

/// The working sets worth asking about, in bytes, with the geometry they come
/// from. Named because a bare 18-digit literal in a verdict table is not a
/// claim anyone can check.
const Scenario = struct {
    name: []const u8,
    working_set: u64,
    resident: u64,
};

/// What the residency plan says about the workloads the DPU was proposed for.
///
/// Every figure fed in is either measured in this run (`m`) or derived from a
/// model's own geometry here, so the table cannot drift from the machine it is
/// printed on.
fn reportPlans(m: residency.Machine) void {
    const GiB: u64 = 1024 * 1024 * 1024;

    // Gemma-2-9B: 42 layers, 8 KV heads, head_dim 256. A decoder touches all
    // of its weights per token (a cyclic scan) plus the whole KV history that
    // attention reads, so both terms are per token, not one-off.
    const weights_f16: u64 = 9_240_000_000 * 2;
    const kv_f16: u64 = 22_548_545_536;
    const weights_q4: u64 = 9_240_000_000 / 2;
    const kv_q4: u64 = 22_548_545_536 / 4;

    // Llama-3.2-3B: 28 layers, 8 KV heads, head_dim 128. Its cache is a third
    // of the 9B's, and the row is here to show that the *cache* is what makes
    // 64k expensive -- not the weights, which are the small term at every size.
    const small_w_q4: u64 = 3_210_000_000 / 2;
    const small_kv_f16: u64 = 2 * 28 * 8 * 128 * 2 * 65_536;

    const scenarios = [_]Scenario{
        // The control: both terms quantised, the whole working set resident, so
        // the verdict is RESIDENT and no paging happens at all.
        .{ .name = "3B q4/q4, 64k", .working_set = small_w_q4 + small_kv_f16 / 4, .resident = 6 * GiB },
        // Same weights, f16 cache: the weights are 18% of the working set and
        // the cache is the other 82%, which is the point of the row.
        .{ .name = "3B q4/f16kv, 64k", .working_set = small_w_q4 + small_kv_f16, .resident = 6 * GiB },
        .{ .name = "9B q4/q4, 64k", .working_set = weights_q4 + kv_q4, .resident = 6 * GiB },
        .{ .name = "9B f16, 64k ctx", .working_set = weights_f16 + kv_f16, .resident = 6 * GiB },
    };

    // Every row above prices a *full* context: a token at position 65536 reads
    // the whole history. A run that configures a 64k window but only generates
    // a few dozen tokens reads almost none of it, and prices far lower --
    // measured 2026-10-05 at 7.77 tok/s with the pool off, where this table's
    // second row would have predicted 0.167. The window is a reservation; the
    // history is a length.

    // 6 GiB rather than the machine's 7.79 GiB: the OS, the dashboard and the
    // engine are on the same box, and a plan that assumes every last byte is
    // available is a plan that pages itself to death.
    std.debug.print(
        \\
        \\  residency plan -- a decoder touches every weight plus the whole KV
        \\  history per token, so the working set below is per token, not once.
        \\  Resident is 6 GiB of the machine's 7.79 GiB.
        \\
        \\    {s:<18} {s:>10} {s:>11} {s:>9} {s:>13}
        \\  ---------------------------------------------------------------------
        \\
    , .{ "working set", "at 4 KiB", "at 1 MiB", "tok/s", "bound" });

    for (scenarios) |sc| {
        const f = residency.Footprint{ .working_set = sc.working_set, .resident = sc.resident };
        const small = residency.plan(f, m, 4096);
        const large = residency.plan(f, m, 1024 * 1024);

        // A resident working set has no I/O rate at all, so `units_per_second`
        // is infinite by construction. Printing `inf` in a rate column reads as
        // a very fast device rather than as "this never touches the pool", so
        // the column says `--` and the verdict column says why.
        var rate_buf: [16]u8 = undefined;
        // Named `rate_text`, not `rate`: `rate` is a top-level function in this
        // file and shadowing it compiles fine in isolation -- it only broke when
        // the whole file was built, which `zig build check` does not do.
        const rate_text = if (large.verdict == .resident)
            "--"
        else
            std.fmt.bufPrint(&rate_buf, "{d:.3}", .{large.units_per_second}) catch "?";

        std.debug.print("  {s:<18} {s:>10} {s:>11} {s:>9} {s:>13}\n", .{
            sc.name,
            small.verdict.label(),
            large.verdict.label(),
            rate_text,
            large.bound.label(),
        });
        // Only the 1 MiB column is a rate anyone could reach; printing the
        // 4 KiB one beside it would suggest it is an alternative, when the
        // whole finding is that it is not.
    }

    std.debug.print(
        \\
        \\  The 1 MiB column is not a tuning suggestion. Every row above is
        \\  bounded by bandwidth at that granule, so the only way to raise it
        \\  is to move fewer bytes per token -- which is a quantisation
        \\  decision, not a paging one.
        \\
    , .{});
}

fn rate(bytes: u64, us: f64) f64 {
    if (us <= 0) return 0;
    return @as(f64, @floatFromInt(bytes)) / (us / 1_000_000.0) / MB;
}

const Random = struct {
    state: u64 = 0x9E3779B97F4A7C15,
    fn next(self: *@This()) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545F4914F6CDD1D;
    }
};

/// Both RAM-side figures the reference banner needs, measured here rather than
/// quoted.
///
/// `random_us` is the honest counterpart to the pool's uncached 4 KiB random
/// read: a dependent pointer chase through a 256 MiB buffer, so every step
/// misses cache and the prefetcher has nothing to work with. The previous
/// version of this banner divided the *measured* device latency by a hardcoded
/// `0.08` that nothing in this project ever measured, which put a real number
/// next to an invented one and divided by the invention.
const RamSample = struct {
    mbps: f64,
    random_us: f64,
};

fn measureRam(gpa: std.mem.Allocator) RamSample {
    const none = RamSample{ .mbps = 0, .random_us = 0 };
    const size: usize = 256 * 1024 * 1024;
    const a = gpa.alignedAlloc(u64, .@"16", size / @sizeOf(u64)) catch return none;
    defer gpa.free(a);
    const b = gpa.alignedAlloc(u8, .@"16", size) catch return none;
    defer gpa.free(b);
    @memset(a, @as(u64, 1));
    const t = tickUs();
    @memcpy(b, std.mem.sliceAsBytes(a));
    const us = usSince(t);
    const mbps = if (us <= 0) 0 else @as(f64, @floatFromInt(size)) / (us / 1_000_000.0) / MB;

    // A stride that is coprime with the element count and long enough that the
    // hardware prefetcher cannot learn it. Each step depends on the previous
    // one, so the loads cannot be issued in parallel either.
    const n = a.len;
    for (a, 0..) |*slot, i| slot.* = @intCast((i + 1) *% 2_654_435_761 % n);

    var idx: usize = 0;
    for (0..200_000) |_| idx = @intCast(a[idx]); // warm the path
    const reps: usize = 20_000_000;
    const t2 = tickUs();
    for (0..reps) |_| idx = @intCast(a[idx]);
    const per_us = usSince(t2) / @as(f64, @floatFromInt(reps));
    std.mem.doNotOptimizeAway(idx);

    return .{ .mbps = mbps, .random_us = per_us };
}

fn tickUs() u64 {
    var ft: c.FILETIME = undefined;
    c.GetSystemTimePreciseAsFileTime(&ft);
    const t = @as(u64, ft.dwHighDateTime) << 32 | @as(u64, ft.dwLowDateTime);
    return t / 10;
}

/// Elapsed microseconds.
///
/// This must not rescale. `tickUs` already yields microseconds (100ns ticks
/// divided by 10), and an earlier revision divided the delta by 1000 "to get
/// milliseconds" while every caller still treated it as microseconds, which
/// inflated throughput by 1000x and reported sub-microsecond random latency.
fn usSince(start: u64) f64 {
    return @as(f64, @floatFromInt(tickUs() - start));
}
