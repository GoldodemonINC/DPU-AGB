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
const win = @import("win");
const c = win.c;

const MB: f64 = 1024.0 * 1024.0;

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

    var dev = try blockdev.BlockDevice.init(gpa, "P:\\", "P:\\DPU", blockdev.DEFAULT_CEILING);
    // Unlink the pool afterwards. The sweep writes 8 GiB; closing the handle
    // alone leaves all of it behind on P:.
    defer dev.destroy();
    std.debug.print("  sparse={s}  ceiling={d:.1} GB\n\n", .{
        if (dev.sparse) "yes" else "no",
        @as(f64, @floatFromInt(dev.ceiling)) / 1073741824.0,
    });

    for (sizes) |mib| {
        const r = try sweep(&dev, mib);
        device_random_us = r.rand_read_us;
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
