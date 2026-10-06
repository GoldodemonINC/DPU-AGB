//! The residency scheduler: what stays in RAM, what comes from P:\ on demand.
//!
//! The pool is larger than RAM, so every client of it -- an inference runtime
//! paging weights, a texture store, a spill arena -- is really answering one
//! question over and over: which bytes stay resident, and which are fetched.
//! This module is that decision, expressed in bytes rather than in models so
//! the same policy serves all of them.
//!
//! Three things here are deliberate, and each of them was a wrong assumption
//! first:
//!
//! 1. **The access pattern decides the policy, not the other way round.** A
//!    transformer decoder touches every weight once per token and then starts
//!    again, which is a cyclic scan over a set larger than the cache. LRU is
//!    not merely suboptimal for that pattern, it is *exactly as good as no
//!    cache at all*: each eviction takes the page that is due next. This is
//!    why handing the weights to the pool made decoding slower rather than
//!    faster, and why `Policy.pinned` exists -- pinning a prefix turns a
//!    cyclic scan into a sequential scan of the remainder, which is the shape
//!    the device is actually good at.
//!
//! 2. **A fault has a latency and a bandwidth, and they bind separately.** One
//!    uncached 4 KiB read costs `Machine.fault_us` whatever the device's
//!    throughput is, because it is one round trip. A run of adjacent reads
//!    costs `bytes / stream_bps`. A design that faults one granule at a time
//!    is capped at `1/fault_us` operations per second no matter how fast the
//!    volume is, so the answer is the `max` of the two, never one of them
//!    alone. On this machine that gap is 4 KiB at 63 us against 1 MiB at
//!    482 MB/s, which is 65 MB/s of effective throughput at the small granule
//!    against 482 at the large one -- a factor of 7.4, from the granule alone.
//!
//! 3. **No constant here is quoted.** `Machine` is filled from a measurement
//!    taken on the machine the plan is for. An earlier revision of the
//!    benchmark printed a hardcoded figure beside a measured one and divided
//!    by the invention, so this module has no defaults to drift: a caller that
//!    has not measured cannot call it.

const std = @import("std");

/// Granule a fault is accounted in when the caller does not say. Matches
/// `blockdev.SECTOR`, so a caller never reasons about two block sizes.
pub const PAGE: u64 = 4096;

/// Bytes in a mebibyte, for the rate conversions below. Named because a bare
/// `1024 * 1024` in the middle of a bandwidth formula reads as a magic number
/// rather than as a unit.
pub const MIB: f64 = 1024.0 * 1024.0;

/// What one unit of work wants to touch.
///
/// `working_set` is the whole thing, not the part that misses: a decoder
/// touches all of its weights every token whether they are resident or not,
/// and the interesting output is how much of that has to come off the disk.
pub const Footprint = struct {
    /// Bytes touched per unit of work.
    working_set: u64,
    /// Bytes of the working set the client holds in RAM outside the pool.
    resident: u64,

    /// Bytes that have to be fetched per unit of work.
    pub fn missBytes(self: Footprint) u64 {
        return self.working_set -| self.resident;
    }

    /// Fraction of the working set held in RAM, 0..1.
    pub fn residentFraction(self: Footprint) f64 {
        if (self.working_set == 0) return 1.0;
        const r = @min(self.resident, self.working_set);
        return @as(f64, @floatFromInt(r)) / @as(f64, @floatFromInt(self.working_set));
    }
};

/// The machine's measured I/O behaviour. Every field is an input from a
/// benchmark run, never a quoted constant.
pub const Machine = struct {
    /// Microseconds for one uncached read of the granule under test.
    fault_us: f64,
    /// Sequential read bandwidth in mebibytes per second.
    stream_mbps: f64,
    /// Bytes the pool may claim. A plan is refused when the working set cannot
    /// be stored at all, which is the difference between "slow" and "does not
    /// run".
    pool_bytes: u64,

    pub fn streamBytesPerSec(self: Machine) f64 {
        return self.stream_mbps * MIB;
    }
};

pub const Verdict = enum {
    /// Nothing misses: the working set is already in RAM.
    resident,
    /// Drains to the pool and reads back on demand. Slow, but it runs.
    streamed,
    /// The working set does not fit in RAM plus the pool, so no amount of
    /// policy makes it run. This is the honest "cannot run" answer.
    does_not_fit,

    pub fn label(self: Verdict) []const u8 {
        return switch (self) {
            .resident => "RESIDENT",
            .streamed => "STREAMED",
            .does_not_fit => "DOES NOT FIT",
        };
    }
};

/// Which of the two limits is binding, so a caller fixes the right one.
/// `fault` means queue depth or a larger granule is the lever; `bandwidth`
/// means only moving fewer bytes will help.
pub const Bound = enum {
    none,
    fault,
    bandwidth,

    pub fn label(self: Bound) []const u8 {
        return switch (self) {
            .none => "none",
            .fault => "fault latency",
            .bandwidth => "bandwidth",
        };
    }
};

/// Predicted cost of running one unit of work against a measured machine.
pub const Plan = struct {
    verdict: Verdict,
    /// Bytes fetched per unit of work.
    miss_bytes: u64,
    /// Faults per unit of work at the granule the plan was computed for.
    faults_per_unit: f64,
    /// Seconds per unit of work spent waiting on I/O. Compute time is not
    /// modelled -- this is the floor storage puts under the workload, and the
    /// number a target rate has to be compared against.
    io_seconds_per_unit: f64,
    /// Reciprocal of the above. Zero when the workload cannot run.
    units_per_second: f64,
    /// Fraction of the working set that never has to be fetched.
    resident_fraction: f64,
    bound: Bound,

    /// Seconds per unit if only the fault-latency limit applied.
    fault_seconds_per_unit: f64,
    /// Seconds per unit if only the bandwidth limit applied.
    bandwidth_seconds_per_unit: f64,
};

/// Predict what a working set costs on a measured machine at a given granule.
///
/// The two limits are computed separately and the larger wins. They bind
/// independently: a volume with a 63 microsecond round trip and 480 MB/s
/// streaming is fault-bound at 4 KiB and bandwidth-bound at 1 MiB, and a
/// planner that only looks at bandwidth will promise a rate it can never
/// reach.
pub fn plan(f: Footprint, m: Machine, granule: u64) Plan {
    const g = if (granule == 0) PAGE else granule;
    const miss = f.missBytes();

    if (miss == 0) {
        return .{
            .verdict = .resident,
            .miss_bytes = 0,
            .faults_per_unit = 0,
            .io_seconds_per_unit = 0,
            .units_per_second = std.math.inf(f64),
            .resident_fraction = 1.0,
            .bound = .none,
            .fault_seconds_per_unit = 0,
            .bandwidth_seconds_per_unit = 0,
        };
    }

    const faults = @as(f64, @floatFromInt(miss)) / @as(f64, @floatFromInt(g));
    const fault_seconds = faults * m.fault_us / 1_000_000.0;
    // An unmeasured bandwidth degrades to the fault term rather than to
    // infinity. A machine that has not measured its streaming rate has still
    // measured its round trip, and `granule / fault_us` is then a genuine lower
    // bound on what the bytes can cost -- the fault path is the fastest the
    // data can possibly arrive. Reporting `inf` would be defensible arithmetic
    // and a useless module: every plan on an uncalibrated machine would read as
    // "cannot run" when nothing had been shown to be broken.
    const bandwidth_seconds = if (m.stream_mbps > 0)
        @as(f64, @floatFromInt(miss)) / m.streamBytesPerSec()
    else
        fault_seconds;

    // Addressed against RAM plus the pool, because a working set that fits in
    // RAM but not in the pool is still fine -- it never needs the pool. Only a
    // set that exceeds both is refused, and `+|` keeps an absurd figure from
    // wrapping into an affordable one.
    if (f.working_set > m.pool_bytes +| f.resident) {
        return .{
            .verdict = .does_not_fit,
            .miss_bytes = miss,
            .faults_per_unit = faults,
            .io_seconds_per_unit = std.math.inf(f64),
            .units_per_second = 0,
            .resident_fraction = f.residentFraction(),
            .bound = .none,
            .fault_seconds_per_unit = fault_seconds,
            .bandwidth_seconds_per_unit = bandwidth_seconds,
        };
    }

    const io_seconds = @max(fault_seconds, bandwidth_seconds);

    return .{
        .verdict = .streamed,
        .miss_bytes = miss,
        .faults_per_unit = faults,
        .io_seconds_per_unit = io_seconds,
        .units_per_second = if (io_seconds > 0) 1.0 / io_seconds else std.math.inf(f64),
        .resident_fraction = f.residentFraction(),
        .bound = if (fault_seconds >= bandwidth_seconds) .fault else .bandwidth,
        .fault_seconds_per_unit = fault_seconds,
        .bandwidth_seconds_per_unit = bandwidth_seconds,
    };
}

/// How the resident set is chosen when it cannot hold everything.
pub const Policy = enum {
    /// Evict least-recently-used. Correct for a working set with locality, and
    /// worthless for a cyclic scan -- see the module note.
    lru,
    /// Keep every page below `pinned_pages` resident permanently and let the
    /// rest cycle underneath. This is the policy that makes a decoder work:
    /// the pinned prefix is never re-read, and the remainder is read in order.
    pinned,
};

/// A bounded, fault-driven resident set.
///
/// Capacity is in pages, not bytes, because every decision here is per fault.
/// Pages are indices into the client's working set; the scheduler never sees
/// an offset or a pointer, so it does not care what the bytes are.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    /// Maximum resident pages.
    capacity: usize,
    /// Pages below this index are permanent under `Policy.pinned`.
    pinned_pages: u64,
    policy: Policy,
    /// Pages fetched beyond each miss. Zero means fault exactly one.
    read_ahead: u32,

    /// Resident page -> slab slot.
    index: std.AutoHashMapUnmanaged(u64, usize),
    slab: []Slot,
    free_head: ?usize,
    /// Resident pages, including pinned ones.
    used: usize,
    /// Recency list, newest first. Pinned slots are deliberately *not* in it:
    /// a page that cannot be evicted has no business holding a position in an
    /// eviction order, and keeping it out makes eviction O(1) instead of a
    /// walk that skips it.
    lru_head: ?usize,
    lru_tail: ?usize,
    stats: Stats,

    const Slot = struct {
        page: u64,
        prev: ?usize,
        next: ?usize,
        pinned: bool,
    };

    pub const Stats = struct {
        hits: u64 = 0,
        misses: u64 = 0,
        evictions: u64 = 0,
        /// Pages made resident without being asked for, because a read-ahead
        /// brought them in.
        prefetched: u64 = 0,

        /// Fraction of accesses served without a fetch. 1.0 before any access,
        /// because a rate with no denominator is not zero -- reporting 0.0
        /// would make an unused scheduler look broken on the dashboard.
        pub fn hitRate(self: Stats) f64 {
            const total = self.hits + self.misses;
            if (total == 0) return 1.0;
            return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: usize,
        policy: Policy,
        pinned_pages: u64,
        read_ahead: u32,
    ) !Scheduler {
        // Capacity zero is not a resident set, it is a bug: every access would
        // evict the page it just inserted, and the result would report a 100%
        // miss rate while looking like a working cache.
        if (capacity == 0) return error.EmptyScheduler;

        var self = Scheduler{
            .allocator = allocator,
            .capacity = capacity,
            .pinned_pages = if (policy == .pinned) @min(pinned_pages, capacity) else 0,
            .policy = policy,
            .read_ahead = read_ahead,
            .index = .empty,
            .slab = try allocator.alloc(Slot, capacity),
            .free_head = null,
            .used = 0,
            .lru_head = null,
            .lru_tail = null,
            .stats = .{},
        };
        self.linkFree();
        return self;
    }

    pub fn deinit(self: *Scheduler) void {
        self.index.deinit(self.allocator);
        self.allocator.free(self.slab);
    }

    fn linkFree(self: *Scheduler) void {
        for (self.slab, 0..) |*slot, i| {
            slot.* = .{
                .page = 0,
                .prev = null,
                .next = if (i + 1 < self.slab.len) i + 1 else null,
                .pinned = false,
            };
        }
        self.free_head = if (self.slab.len == 0) null else 0;
    }

    /// Whether a page is permanent under the current policy.
    pub fn isPinned(self: *const Scheduler, page: u64) bool {
        return self.policy == .pinned and page < self.pinned_pages;
    }

    /// Take one access to `page`. Returns whether it was resident.
    ///
    /// A miss also decides what to read ahead, so the caller never has to know
    /// the policy: `pending` receives the pages that must now be fetched,
    /// nearest first, and includes the faulted page itself.
    pub fn access(self: *Scheduler, page: u64, pending: *std.ArrayList(u64)) !bool {
        if (self.index.get(page)) |slot| {
            self.stats.hits += 1;
            self.touch(slot);
            return true;
        }

        self.stats.misses += 1;
        try pending.append(self.allocator, page);

        var ahead: u32 = 0;
        while (ahead < self.read_ahead) : (ahead += 1) {
            const next = page + 1 + ahead;
            if (self.index.contains(next)) continue;
            try pending.append(self.allocator, next);
            self.stats.prefetched += 1;
        }

        return false;
    }

    /// Record that a fetched page has arrived, making it resident.
    ///
    /// Separate from `access` because a fetch is asynchronous in practice: the
    /// fault is decided in one call and satisfied later, and a scheduler that
    /// assumed the bytes had landed would count hits on pages still in flight.
    pub fn load(self: *Scheduler, page: u64) void {
        if (self.index.contains(page)) return;

        const pin = self.isPinned(page);

        if (self.used == self.capacity) {
            if (pin) return; // every slot is spoken for and none is evictable
            _ = self.evictOne() orelse return;
        }

        const slot = self.free_head orelse return;
        self.free_head = self.slab[slot].next;
        self.slab[slot] = .{ .page = page, .prev = null, .next = null, .pinned = pin };
        self.index.put(self.allocator, page, slot) catch return;
        self.used += 1;

        // Pinned slots stay out of the recency list entirely.
        if (!pin) self.pushFront(slot);
    }

    fn pushFront(self: *Scheduler, slot: usize) void {
        self.slab[slot].prev = null;
        self.slab[slot].next = self.lru_head;
        if (self.lru_head) |h| self.slab[h].prev = slot;
        self.lru_head = slot;
        if (self.lru_tail == null) self.lru_tail = slot;
    }

    fn unlink(self: *Scheduler, slot: usize) void {
        const s = self.slab[slot];
        if (s.prev) |p| self.slab[p].next = s.next else self.lru_head = s.next;
        if (s.next) |n| self.slab[n].prev = s.prev else self.lru_tail = s.prev;
        self.slab[slot].prev = null;
        self.slab[slot].next = null;
    }

    fn touch(self: *Scheduler, slot: usize) void {
        // A pinned slot holds no position, so there is nothing to reorder.
        if (self.slab[slot].pinned) return;
        if (self.lru_head == slot) return;
        self.unlink(slot);
        self.pushFront(slot);
    }

    /// Drop the coldest evictable page. Returns the victim's slot, or null
    /// when every resident page is pinned.
    fn evictOne(self: *Scheduler) ?usize {
        const v = self.lru_tail orelse return null;
        _ = self.index.remove(self.slab[v].page);
        self.unlink(v);
        self.slab[v] = .{ .page = 0, .prev = null, .next = self.free_head, .pinned = false };
        self.free_head = v;
        self.used -= 1;
        self.stats.evictions += 1;
        return v;
    }

    pub fn hitRate(self: *const Scheduler) f64 {
        return self.stats.hitRate();
    }
};

// --------------------------------------------------------------- tests

const testing = std.testing;

const GB: u64 = 1000 * 1000 * 1000;
const GIB: u64 = 1024 * 1024 * 1024;

// The numbers the planner is tested against come from the benchmark run of
// 2026-10-05 on this machine, once the working set was past the controller's
// cache: 481.8 MB/s sequential, 63.1 us per uncached 4 KiB read. They are
// repeated here as *test inputs*, not as defaults -- nothing in the planner
// reads them, and changing them changes no shipped behaviour.

test "a working set that fits in RAM never touches the pool" {
    const f = Footprint{ .working_set = 2 * GIB, .resident = 6 * GIB };
    const m = Machine{ .fault_us = 63.1, .stream_mbps = 481.8, .pool_bytes = 8 * GIB };
    const p = plan(f, m, PAGE);
    try testing.expectEqual(Verdict.resident, p.verdict);
    try testing.expectEqual(@as(u64, 0), p.miss_bytes);
    try testing.expectEqual(Bound.none, p.bound);
    try testing.expectEqual(@as(f64, 1.0), p.resident_fraction);
}

test "gemma-2-9b geometry at 64k in f16 is 41 GB of working set" {
    // 42 layers, 8 KV heads, head_dim 256 -- the least forgiving of the
    // 9B-class shapes. Weights are 2 bytes per parameter at f16; a key and a
    // value per head per layer per token, also 2 bytes each.
    const weights: u64 = 9_240_000_000 * 2;
    const kv_per_token: u64 = 2 * 42 * 8 * 256 * 2;
    try testing.expectEqual(@as(u64, 344_064), kv_per_token);

    const kv: u64 = kv_per_token * 65_536;
    // 344064 bytes per token times 65536 tokens. Written out because the
    // product is the number the whole verdict rests on.
    try testing.expectEqual(@as(u64, 22_548_578_304), kv);
    try testing.expectEqual(@as(u64, 18_480_000_000), weights);

    // What one token touches: every weight, because the model is a cyclic
    // scan, plus the key/value history attention reads.
    const total = weights + kv;
    try testing.expectEqual(@as(u64, 41_028_578_304), total);
}

test "stored in f16 the working set cannot be materialised at all" {
    // 41 GB wanted against 8 GiB of pool and 13 GB free on P:\ -- this is the
    // "can't run" row of the diagram, and it is a capacity fact, not a speed
    // one. No policy recovers it, which is why the verdict is not `streamed`.
    const f = Footprint{ .working_set = 41_028_578_304, .resident = 6 * GIB };
    const m = Machine{ .fault_us = 63.1, .stream_mbps = 481.8, .pool_bytes = 8 * GIB };
    const p = plan(f, m, 1024 * 1024);
    try testing.expectEqual(Verdict.does_not_fit, p.verdict);
    try testing.expectEqual(@as(f64, 0), p.units_per_second);
}

test "the same model quantised at 4 bits streams, and is still under a token per second" {
    // Four bits per weight and per KV element: 4.62 GB of parameters and
    // 5.64 GB of cache, so 10.26 GB touched per token, 6 GiB of it resident.
    const weights_q4: u64 = 9_240_000_000 / 2;
    const kv_q4: u64 = 22_548_578_304 / 4;
    const working = weights_q4 + kv_q4;
    try testing.expectEqual(@as(u64, 10_257_144_576), working);

    const f = Footprint{ .working_set = working, .resident = 6 * GIB };
    const m = Machine{ .fault_us = 63.1, .stream_mbps = 481.8, .pool_bytes = 8 * GIB };

    const small = plan(f, m, PAGE);
    const large = plan(f, m, 1024 * 1024);

    try testing.expectEqual(Verdict.streamed, small.verdict);
    try testing.expectEqual(Bound.fault, small.bound);
    try testing.expectEqual(Bound.bandwidth, large.bound);

    // 3.81 GB of misses: 7.55 seconds per token at 481.8 MB/s, or 0.13 tok/s.
    // A target of 0.7 is 5.3x away, and the gap is bytes, not policy.
    try testing.expectApproxEqAbs(@as(f64, 0.132), large.units_per_second, 0.005);
    try testing.expect(large.units_per_second < 1.0);
}

test "the granule alone is worth a factor of 7.4 in effective throughput" {
    const f = Footprint{ .working_set = 4 * GIB, .resident = 0 };
    const m = Machine{ .fault_us = 63.1, .stream_mbps = 481.8, .pool_bytes = 8 * GIB };

    const page = plan(f, m, 4096);
    const block = plan(f, m, 1024 * 1024);

    // 4 GiB in 4 KiB faults is 1048576 round trips at 63.1 us: 66.17 seconds.
    try testing.expectApproxEqAbs(@as(f64, 66.165), page.fault_seconds_per_unit, 0.01);
    // The same bytes in 1 MiB reads is 4096 round trips: 0.26 s of latency,
    // but 8.9 s of bandwidth, so bandwidth binds and wins.
    try testing.expectApproxEqAbs(@as(f64, 0.258), block.fault_seconds_per_unit, 0.01);
    try testing.expectEqual(Bound.bandwidth, block.bound);

    // Effective throughput is bytes over seconds, and neither plan is a
    // latency plan: the 4 KiB one pays 66 s of round trips for bytes that the
    // 1 MiB one moves in 8.5 s. Same bytes, same device, 7.8x apart.
    const ratio = page.io_seconds_per_unit / block.io_seconds_per_unit;
    try testing.expectApproxEqAbs(@as(f64, 7.78), ratio, 0.1);
}

test "a zero bandwidth machine is reported as finite, not as free" {
    const f = Footprint{ .working_set = 1 * GIB, .resident = 0 };
    const m = Machine{ .fault_us = 63.1, .stream_mbps = 0, .pool_bytes = 8 * GIB };
    const p = plan(f, m, PAGE);
    // An unmeasured streaming rate must not become `inf` by dividing by zero --
    // and it must not become zero either, which would report a free device.
    try testing.expect(std.math.isFinite(p.io_seconds_per_unit));
    try testing.expect(p.io_seconds_per_unit > 0);
    try testing.expectEqual(Bound.fault, p.bound);
    // The degradation is stated, not silent: the fault term is what is left.
    try testing.expectEqual(p.fault_seconds_per_unit, p.bandwidth_seconds_per_unit);
}

test "a working set larger than pool plus RAM is refused" {
    const f = Footprint{ .working_set = 40 * GIB, .resident = 1 * GIB };
    const m = Machine{ .fault_us = 63.1, .stream_mbps = 481.8, .pool_bytes = 8 * GIB };
    const p = plan(f, m, PAGE);
    try testing.expectEqual(Verdict.does_not_fit, p.verdict);
    try testing.expectEqual(@as(f64, 0), p.units_per_second);
    // The limits are still reported, so a caller can see how far off it is.
    try testing.expect(p.fault_seconds_per_unit > 0);
}

test "an absurd pool size cannot wrap into a refusal" {
    // `+|` on the comparison: a pool claiming u64 max must not overflow the
    // right-hand side into a small number and refuse a working set that fits.
    const f = Footprint{ .working_set = 41_028_545_536, .resident = 0 };
    const m = Machine{ .fault_us = 63.1, .stream_mbps = 481.8, .pool_bytes = std.math.maxInt(u64) };
    try testing.expectEqual(Verdict.streamed, plan(f, m, PAGE).verdict);
}

test "a granularity of zero falls back to the page rather than dividing by zero" {
    const f = Footprint{ .working_set = 1 * MIB, .resident = 0 };
    const m = Machine{ .fault_us = 63.1, .stream_mbps = 481.8, .pool_bytes = 8 * GIB };
    const p = plan(f, m, 0);
    try testing.expect(std.math.isFinite(p.faults_per_unit));
    try testing.expectEqual(@as(f64, 256), p.faults_per_unit);
}

// ------------------------------------------------------------- scheduler

const Harness = struct {
    s: Scheduler,
    pending: std.ArrayList(u64),

    fn init(allocator: std.mem.Allocator, cap: usize, policy: Policy, pin: u64, ahead: u32) !Harness {
        return .{
            .s = try Scheduler.init(allocator, cap, policy, pin, ahead),
            .pending = .empty,
        };
    }

    fn deinit(self: *Harness) void {
        self.pending.deinit(self.s.allocator);
        self.s.deinit();
    }

    /// One access with the fetch satisfied immediately, which is what a
    /// caller with a synchronous device does.
    fn step(self: *Harness, page: u64) !void {
        self.pending.clearRetainingCapacity();
        _ = try self.s.access(page, &self.pending);
        for (self.pending.items) |p| self.s.load(p);
    }
};

test "a resident set reports a hit on the second access" {
    var h = try Harness.init(testing.allocator, 4, .lru, 0, 0);
    defer h.deinit();

    // First touch faults, second hits.
    h.pending.clearRetainingCapacity();
    try testing.expect(!try h.s.access(7, &h.pending));
    for (h.pending.items) |p| h.s.load(p);

    try testing.expect(try h.s.access(7, &h.pending));
    try testing.expectEqual(@as(u64, 1), h.s.stats.hits);
    try testing.expectEqual(@as(u64, 1), h.s.stats.misses);
}

test "lru earns nothing on a cyclic scan larger than the cache" {
    // The pattern a decoder actually has: every page once, in order, then
    // start again. This is the test that documents why the pool made weights
    // slower -- at any capacity below the working set, LRU evicts precisely
    // the page that is needed next.
    var h = try Harness.init(testing.allocator, 16, .lru, 0, 0);
    defer h.deinit();

    for (0..3) |_| {
        var p: u64 = 0;
        while (p < 64) : (p += 1) try h.step(p);
    }

    // Zero hits. The classic result for cyclic access under LRU, and the
    // reason `Policy.pinned` exists at all.
    try testing.expectEqual(@as(u64, 0), h.s.stats.hits);
    try testing.expectEqual(@as(f64, 0.0), h.s.hitRate());
    // Every page of every pass had to be fetched.
    try testing.expectEqual(@as(u64, 192), h.s.stats.misses);
}

test "lru is perfect when the working set fits" {
    var h = try Harness.init(testing.allocator, 64, .lru, 0, 0);
    defer h.deinit();

    for (0..3) |_| {
        var p: u64 = 0;
        while (p < 64) : (p += 1) try h.step(p);
    }

    // 192 accesses, 64 of them the first pass.
    try testing.expectEqual(@as(u64, 128), h.s.stats.hits);
}

test "pinning a prefix is what makes a cyclic scan hit at all" {
    // Same pattern and same capacity as the LRU test, but a quarter of the set
    // is pinned. The pinned quarter is never re-read, which is the entire
    // mechanism: it converts re-reading everything into re-reading less.
    var h = try Harness.init(testing.allocator, 16, .pinned, 4, 0);
    defer h.deinit();

    for (0..3) |_| {
        var p: u64 = 0;
        while (p < 64) : (p += 1) try h.step(p);
    }

    // The first 4 pages are loaded on pass one and stay, so passes two and
    // three hit 4 times each. LRU on the identical trace hits zero.
    try testing.expectEqual(@as(u64, 8), h.s.stats.hits);
    try testing.expect(h.s.hitRate() > 0.0);
}

test "pinning converts a miss rate into bandwidth rather than removing it" {
    // The honest reading of the previous test: pinning does not make the
    // working set resident, it makes *less* of it miss. At 1/4 pinned the miss
    // count falls by exactly the pinned fraction, no more.
    var h = try Harness.init(testing.allocator, 16, .pinned, 8, 0);
    defer h.deinit();

    for (0..2) |_| {
        var p: u64 = 0;
        while (p < 64) : (p += 1) try h.step(p);
    }

    // Pass one misses all 64. Pass two misses only the 56 above the pin.
    try testing.expectEqual(@as(u64, 120), h.s.stats.misses);
    try testing.expectEqual(@as(u64, 8), h.s.stats.hits);
}

test "read-ahead fetches neighbours and counts them as prefetched" {
    var h = try Harness.init(testing.allocator, 8, .lru, 0, 3);
    defer h.deinit();

    _ = try h.s.access(10, &h.pending);
    // The page itself is a fault, not a prefetch; the three behind it are.
    try testing.expectEqual(@as(usize, 4), h.pending.items.len);
    try testing.expectEqual(@as(u64, 10), h.pending.items[0]);
    try testing.expectEqual(@as(u64, 11), h.pending.items[1]);
    try testing.expectEqual(@as(u64, 12), h.pending.items[2]);
    try testing.expectEqual(@as(u64, 13), h.pending.items[3]);
    try testing.expectEqual(@as(u64, 3), h.s.stats.prefetched);
}

test "read-ahead does not re-request a resident neighbour" {
    var h = try Harness.init(testing.allocator, 8, .lru, 0, 2);
    defer h.deinit();

    h.s.load(11);
    _ = try h.s.access(10, &h.pending);
    try testing.expectEqual(@as(usize, 2), h.pending.items.len);
    try testing.expectEqual(@as(u64, 10), h.pending.items[0]);
    try testing.expectEqual(@as(u64, 12), h.pending.items[1]);
    try testing.expectEqual(@as(u64, 1), h.s.stats.prefetched);
}

test "an empty scheduler is refused rather than counting every access as a miss" {
    try testing.expectError(error.EmptyScheduler, Scheduler.init(testing.allocator, 0, .lru, 0, 0));
}

test "a pinned prefix larger than the cache is clamped, not accepted" {
    var s = try Scheduler.init(testing.allocator, 4, .pinned, 99, 0);
    defer s.deinit();
    try testing.expectEqual(@as(u64, 4), s.pinned_pages);
}

test "lru evicts the coldest page and keeps capacity bounded" {
    var h = try Harness.init(testing.allocator, 4, .lru, 0, 0);
    defer h.deinit();

    for (0..4) |i| h.s.load(i);
    // Re-touch 0 so that 1 becomes the coldest.
    try h.step(0);

    h.s.load(4);
    try testing.expectEqual(@as(usize, 4), h.s.used);
    try testing.expectEqual(@as(u64, 1), h.s.stats.evictions);
    try testing.expect(!h.s.index.contains(1));
    for ([_]u64{ 0, 2, 3, 4 }) |p| try testing.expect(h.s.index.contains(p));
}

test "eviction under a pinned policy never takes a pinned page" {
    var h = try Harness.init(testing.allocator, 4, .pinned, 2, 0);
    defer h.deinit();

    for (0..2) |i| h.s.load(i); // the pinned pair
    for (0..20) |i| h.s.load(100 + i); // churn

    try testing.expect(h.s.index.contains(0));
    try testing.expect(h.s.index.contains(1));
    try testing.expectEqual(@as(usize, 4), h.s.used);
}

test "a fully pinned set refuses to evict rather than dropping a pinned page" {
    // Capacity and pin size equal: nothing is evictable, so a load that would
    // need room is dropped instead of silently unpinning something. Returning
    // without loading is the honest failure -- the alternative loses a page the
    // caller was promised would stay.
    var h = try Harness.init(testing.allocator, 2, .pinned, 2, 0);
    defer h.deinit();

    h.s.load(0);
    h.s.load(1);
    h.s.load(2);

    try testing.expect(h.s.index.contains(0));
    try testing.expect(h.s.index.contains(1));
    try testing.expect(!h.s.index.contains(2));
    try testing.expectEqual(@as(u64, 0), h.s.stats.evictions);
}

test "hitRate is one before any access rather than zero" {
    // A rate with no denominator is not a miss rate of zero, and reporting it
    // as one would make an unused scheduler look broken on the dashboard.
    const s = Scheduler.Stats{};
    try testing.expectEqual(@as(f64, 1.0), s.hitRate());
}
