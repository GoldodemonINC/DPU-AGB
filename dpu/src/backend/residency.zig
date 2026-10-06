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
/// `working_set` is bytes touched at one *position* in the sequence, not at the
/// sequence's capacity. This was measured the hard way on 2026-10-05: a 3B
/// model configured for a 64k context generated 31 tokens at 7.77 tok/s, while
/// the same run priced as if all 65536 KV slots were read on every token
/// predicted 0.167 tok/s. The cache is only read up to the position actually
/// reached -- 31 tokens of history is 3.6 MB, not 7.5 GB -- so a caller that
/// prices a run at its context capacity predicts a slowdown that does not exist
/// until the context is genuinely full. Price the position being measured.
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
    /// Pages fetched beyond each miss. Zero means fault exactly one. The
    /// effective value is clamped to what the resident set can hold -- see
    /// `effectiveReadAhead`.
    read_ahead: u32,
    /// Size of the client's working set in pages, or 0 when it is not known.
    ///
    /// Read-ahead past the end of a finite backing store asks the device for
    /// bytes that do not exist, so a client that knows its extent passes it
    /// here and the scheduler refuses to queue anything beyond it.
    pages: u64,

    /// Resident page -> slab slot.
    index: std.AutoHashMapUnmanaged(u64, usize),
    slab: []Slot,
    free_head: ?usize,
    /// Resident pages, including pinned ones.
    used: usize,
    /// Resident pinned pages. Tracked separately because they never enter the
    /// recency list and never become eviction candidates, so `capacity - used`
    /// is not the room a batch actually has.
    pinned_used: usize,
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
        pages: u64,
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
            .pages = pages,
            .index = .empty,
            .slab = try allocator.alloc(Slot, capacity),
            .free_head = null,
            .used = 0,
            .pinned_used = 0,
            .lru_head = null,
            .lru_tail = null,
            .stats = .{},
        };
        self.linkFree();
        return self;
    }

    /// How far read-ahead may actually go, after both limits are applied.
    ///
    /// `capacity - 1`, not `capacity`: a miss queues the demanded page *first*
    /// and its neighbours after, so `capacity` speculative pages would fill the
    /// set and evict the very page the caller is about to use. With
    /// `capacity - 1` the batch fits exactly and the demanded page survives to
    /// be read.
    pub fn effectiveReadAhead(self: *const Scheduler) u32 {
        // Only *evictable* slots can take part of a batch. A pinned slot never
        // leaves the set, so `capacity - 1` overstates the room when pinned
        // pages are already resident: with capacity 4, two pinned pages loaded
        // and read_ahead 3, a batch of four would evict the page the caller
        // just faulted to make room for the third neighbour. One slot has to
        // stay free for the demanded page, hence `- 1` on the evictable count.
        const evictable = self.capacity -| self.pinned_used;
        if (evictable == 0) return 0;
        return @intCast(@min(self.read_ahead, evictable - 1));
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
        const limit = self.effectiveReadAhead();
        while (ahead < limit) : (ahead += 1) {
            // Saturating, then bounds-checked: `page + 1 + ahead` wraps on a
            // large enough page index, and a wrapped index is a perfectly valid
            // looking address for the caller to fetch from.
            const step = 1 +% @as(u64, ahead);
            const next = page +% step;
            if (next < page) break; // wrapped
            if (self.pages != 0 and next >= self.pages) break; // past the end
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
    /// Make a fetched page resident. Returns the allocation error rather than
    /// swallowing it: a caller that cannot be told its fetch was dropped will
    /// go on to read a page that is not in the cache.
    /// A page could not be made resident. Returned rather than swallowed: a caller
    /// that is told its fetch landed will go on to read a page the scheduler
    /// never held.
    pub const LoadError = std.mem.Allocator.Error || error{NoEvictableSlot};

    pub fn load(self: *Scheduler, page: u64) LoadError!void {
        if (self.index.contains(page)) return;

        const pin = self.isPinned(page);

        if (self.used == self.capacity) {
            // Evict for either policy. A pinned page that arrives after the set
            // is full must still be able to take a slot, evicting any
            // non-pinned page to do so -- refusing it would mean the pinned
            // prefix was only honoured if it happened to arrive first, which is
            // not a policy. Pinned slots are deliberately absent from the
            // recency list, so `evictOne` can never reach one; a null return
            // means every resident page is pinned, and dropping the page
            // silently is exactly the bug this error exists for.
            if (self.evictOne() == null) return error.NoEvictableSlot;
        }

        const slot = self.free_head orelse return error.NoEvictableSlot;
        self.free_head = self.slab[slot].next;
        self.slab[slot] = .{ .page = page, .prev = null, .next = null, .pinned = pin };

        // On failure the slot has to go back on the free list. Dropping it
        // would take it out of circulation for the life of the scheduler, so
        // every later load would find one fewer usable slot and the cache
        // would quietly shrink by an amount nothing reported.
        self.index.put(self.allocator, page, slot) catch {
            self.slab[slot] = .{ .page = 0, .prev = null, .next = self.free_head, .pinned = false };
            self.free_head = slot;
            return error.OutOfMemory;
        };

        self.used += 1;
        if (pin) self.pinned_used += 1;

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
        // `evictOne` only ever reaches non-pinned slots, so this stays balanced.
        self.stats.evictions += 1;
        return v;
    }

    pub fn hitRate(self: *const Scheduler) f64 {
        return self.stats.hitRate();
    }

    /// Which slot holds `page`, or null when it is not resident.
    ///
    /// A fault path owns the *bytes* and needs the slot they live in.
    /// `access` and `load` deliberately answer only "is it resident", because
    /// that is the question the policy is about and the storage layout is not
    /// the scheduler's to know. This accessor is the seam: the scheduler stays
    /// a set of decisions, and whatever holds the pages reads the mapping here.
    ///
    /// The returned slot is only valid until the next `load` that evicts. It is
    /// an index into a slab that is reused constantly, so holding one across a
    /// fetch is how a fault path ends up copying from the wrong granule.
    pub fn slotOf(self: *const Scheduler, page: u64) ?usize {
        return self.index.get(page);
    }
};

/// The granule fault path: a scheduler-backed cache that reads a whole
/// granule on a miss and serves the rest of it from RAM.
///
/// The benchmark is the reason this exists. One uncached 4 KiB read costs
/// 36.5 us on this machine, so a client walking a working set in 4 KiB steps
/// moves 106.8 MB/s however fast the volume is; the same bytes in 1 MiB reads
/// move 580.5 MB/s. The fault *size* is the lever -- 5.4x, measured, with no
/// other variable changed. Until now that number existed only as a row in the
/// benchmark table and as `plan`'s third argument, so it was priced and never
/// spent: nothing in the read path took one.
///
/// `Backend` is a type offering
///
///     pub fn read(self: *Backend, offset: u64, buf: []u8) anyerror!usize
///
/// which is `blockdev.BlockDevice`'s own shape. Taking it as a comptime
/// parameter rather than a stored pointer keeps the error set inferred from the
/// backend instead of erased to `anyerror`, and keeps this file importing
/// nothing from the backend -- the property that lets `residency` still be
/// tested as arithmetic rather than against a device.
///
/// Every fault path obeys three rules, and each of them was a bug first:
///
/// 1. **A request at least as large as the granule is not cached.** The caller
///    is already asking for fault-sized I/O; buffering it would allocate and
///    fill a slab the caller immediately overwrites, and would report a miss
///    rate made of reads that were never inefficient.
/// 2. **A short fetch is remembered as a short granule, not padded.** The tail
///    past the end of the working set is zeroed so no caller can read
///    uninitialised memory, and a later read in that same granule is still a
///    *hit* -- the bytes really are resident, they just stop short.
/// 3. **The demanded granule is served before read-ahead is fetched.** Read
///    ahead is an optimisation and must never be the reason a call fails; if
///    the extra fetch errors, the demand still succeeds.
pub fn Faults(comptime Backend: type) type {
    return struct {
        const Self = @This();

        /// Alignment of the resident slab. `blockdev` refuses a transfer whose
        /// buffer is not `SECTOR`-aligned, so the slab is aligned to the same
        /// boundary and every granule inside it inherits that alignment.
        const SLAB_ALIGN: u64 = PAGE;

        /// Everything `read` can return: the backend's error set, this
        /// allocator's, the scheduler's `LoadError`, and two of this module's
        /// own -- `InvalidGranule` (from `init`: zero, unaligned, or below
        /// `PAGE`) and `PageNotResident` (the scheduler said a granule was
        /// resident and then had no slot for it, which `read` cannot provoke
        /// and names anyway so that it is visible if it ever happens).
        ///
        /// It is `anyerror` rather than the union spelled out, because the
        /// backend's set is whatever `Backend.read` returns and only a comptime
        /// instantiation knows it. The two errors above are still returned by
        /// name, so a caller matching on them does not care how the union
        /// types.
        pub const Error = anyerror;

        pub const Config = struct {
            /// Fault size in bytes: a power of two, at least `PAGE`. Defaults
            /// to the page, which is the *worst* choice the module allows and
            /// is left there deliberately -- a caller that has not measured a
            /// granule should get the honest floor, not a flattering default
            /// that quietly makes a slow path look fast.
            granule: u64 = PAGE,
            /// Bytes of working set kept resident. Rounded down to whole
            /// granules; defaults to 64 of them.
            capacity_bytes: u64 = 0,
            /// Granules fetched beyond each miss.
            read_ahead: u32 = 0,
            /// Granules in the working set, or 0 when it is not known. Read
            /// ahead past the end of a finite backing store asks the backend
            /// for bytes that do not exist, so a client that knows its extent
            /// passes it here.
            granules: u64 = 0,
            policy: Policy = .pinned,
            /// Leading granules held permanently under `Policy.pinned`.
            pinned_granules: u64 = 0,
        };

        allocator: std.mem.Allocator,
        backend: *Backend,
        granule: u64,
        /// Granule -> slot index. Parallel to `Scheduler`'s own map, and
        /// invalidated by the same evictions.
        sched: Scheduler,
        /// The backing allocation, held to free. The aligned view below is a
        /// window inside it, so freeing needs the original slice.
        raw: []u8,
        /// `capacity * granule` bytes, aligned to `SLAB_ALIGN`.
        slab: []u8,
        /// Bytes actually fetched into each slot. Less than `granule` for the
        /// final granule of a finite working set.
        valid: []usize,
        /// Read-ahead fetches that did not land. Counted, never fatal.
        skipped: u64 = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            backend: *Backend,
            config: Config,
        ) Error!Self {
            if (config.granule < PAGE or !std.math.isPowerOfTwo(config.granule)) {
                return error.InvalidGranule;
            }

            const granule = config.granule;
            const capacity_bytes = if (config.capacity_bytes == 0)
                granule * 64
            else
                config.capacity_bytes;
            // Rounded *down* to whole granules. Rounding up would silently
            // allocate more than the caller asked to keep resident, which is
            // the opposite error and the more expensive one.
            const slots = @max(@as(usize, 1), @as(usize, @intCast(capacity_bytes / granule)));

            // Over-allocate by one slab alignment and align by hand, because a
            // `[]u8` cannot carry an alignment and `blockdev` refuses a
            // transfer whose buffer is not sector-aligned. Every granule is a
            // multiple of `PAGE`, so aligning the base aligns all of them.
            const span = slots * @as(usize, @intCast(granule));
            const raw = try allocator.alloc(u8, span + SLAB_ALIGN);
            errdefer allocator.free(raw);
            const base = std.mem.alignForward(
                usize,
                @intFromPtr(raw.ptr),
                SLAB_ALIGN,
            );
            const slab = raw[base - @intFromPtr(raw.ptr) ..][0..span];

            const valid = try allocator.alloc(usize, slots);
            errdefer allocator.free(valid);
            @memset(valid, 0);

            const sched = Scheduler.init(
                allocator,
                slots,
                config.policy,
                config.pinned_granules,
                config.read_ahead,
                config.granules,
            ) catch |e| return e;
            errdefer sched.deinit();

            return .{
                .allocator = allocator,
                .backend = backend,
                .granule = granule,
                .sched = sched,
                .raw = raw,
                .slab = slab,
                .valid = valid,
            };
        }

        pub fn deinit(self: *Self) void {
            self.sched.deinit();
            self.allocator.free(self.valid);
            self.allocator.free(self.raw);
        }

        fn bytes(self: *Self, slot: usize) []u8 {
            const g: usize = @intCast(self.granule);
            return self.slab[slot * g ..][0..g];
        }

        /// Read `buf.len` bytes at `offset`, faulting whole granules.
        ///
        /// Returns the caller's byte count. A short return means the working
        /// set ends inside the request, and the bytes up to it are real.
        pub fn read(self: *Self, offset: u64, buf: []u8) Error!usize {
            if (buf.len == 0) return 0;
            if (buf.len >= self.granule) return self.backend.read(offset, buf);

            const page = offset / self.granule;
            const within: usize = @intCast(offset % self.granule);

            // `access` is called on every read, hit included: it is what counts
            // the hit. On a hit it returns before appending anything, so the
            // list below allocates nothing and the common path costs no
            // allocator traffic at all.
            var pending: std.ArrayList(u64) = .empty;
            defer pending.deinit(self.allocator);
            _ = try self.sched.access(page, &pending);

            if (pending.items.len > 0) {
                // The demanded granule first, and its read-ahead after. If the
                // speculative fetch fails the demand still succeeds -- the
                // extra reads are an optimisation, and an optimisation that can
                // fail a read is not one.
                try self.fetchInto(pending.items[0]);
                var i: usize = 1;
                while (i < pending.items.len) : (i += 1) {
                    // Counted, not dropped, and not printed. A prefetch that
                    // never lands is the difference between a hit and a miss on
                    // the next pass, so `stats().skipped` is where it shows up.
                    // Printing from a policy module would be the wrong place
                    // for it: this is a library that is called from the ICD,
                    // from the engine and from tests, and stderr from the
                    // middle of a client's read is noise nobody can act on.
                    self.fetchInto(pending.items[i]) catch {
                        self.skipped += 1;
                    };
                }
            }

            const slot = self.sched.slotOf(page) orelse return error.PageNotResident;
            const start = @min(within, self.valid[slot]);
            const n = @min(buf.len, self.valid[slot] - start);
            @memcpy(buf[0..n], self.bytes(slot)[start..][0..n]);
            return n;
        }

        /// Make one granule resident, fetching it if the set had to evict for
        /// it.
        fn fetchInto(self: *Self, page: u64) Error!void {
            if (self.sched.slotOf(page) != null) return;
            try self.sched.load(page);
            const slot = self.sched.slotOf(page) orelse return error.PageNotResident;

            // `page * granule` cannot overflow for any page the scheduler can
            // hold: the index came from `offset / granule`, and a backend that
            // reported a working set that large would have failed to allocate
            // the slab long before this.
            const base = page *% self.granule;
            const buf = self.bytes(slot);
            const got = try self.backend.read(base, buf);
            // A backend that reports more than it was given has a bug that
            // would otherwise turn into a silent overflow of the slab on the
            // next fetch.
            const valid = @min(got, buf.len);
            if (valid < buf.len) @memset(buf[valid..], 0);
            self.valid[slot] = valid;
        }

        pub fn setReadAhead(self: *Self, n: u32) void {
            self.sched.read_ahead = n;
        }

        /// Granule -> slot mapping for the current resident set. Exposed so a
        /// caller can assert on residency without reaching through the
        /// scheduler, and so the tests can check that a granule really was
        /// evicted rather than merely counted as evicted.
        pub fn isResident(self: *const Self, granule_index: u64) bool {
            return self.sched.slotOf(granule_index) != null;
        }

        pub fn stats(self: *const Self) FaultStats {
            return .{
                .hits = self.sched.stats.hits,
                .misses = self.sched.stats.misses,
                .evictions = self.sched.stats.evictions,
                .prefetched = self.sched.stats.prefetched,
                .skipped = self.skipped,
            };
        }

        /// Effective read-ahead after the scheduler's clamps, so a caller
        /// setting a depth sees what it will actually get rather than what it
        /// asked for.
        pub fn effectiveReadAhead(self: *const Self) u32 {
            return self.sched.effectiveReadAhead();
        }
    };
}

/// What a fault path has done, for the dashboard and the tests.
pub const FaultStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    /// Granules fetched without being asked for.
    prefetched: u64 = 0,
    /// Read-ahead fetches that did not land. Non-fatal by construction.
    skipped: u64 = 0,

    pub fn hitRate(self: FaultStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
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
            .s = try Scheduler.init(allocator, cap, policy, pin, ahead, 0),
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
        for (self.pending.items) |p| try self.s.load(p);
    }
};

test "a resident set reports a hit on the second access" {
    var h = try Harness.init(testing.allocator, 4, .lru, 0, 0);
    defer h.deinit();

    // First touch faults, second hits.
    h.pending.clearRetainingCapacity();
    try testing.expect(!try h.s.access(7, &h.pending));
    for (h.pending.items) |p| try h.s.load(p);

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

    try h.s.load(11);
    _ = try h.s.access(10, &h.pending);
    try testing.expectEqual(@as(usize, 2), h.pending.items.len);
    try testing.expectEqual(@as(u64, 10), h.pending.items[0]);
    try testing.expectEqual(@as(u64, 12), h.pending.items[1]);
    try testing.expectEqual(@as(u64, 1), h.s.stats.prefetched);
}

test "an empty scheduler is refused rather than counting every access as a miss" {
    try testing.expectError(error.EmptyScheduler, Scheduler.init(testing.allocator, 0, .lru, 0, 0, 0));
}

test "a pinned prefix larger than the cache is clamped, not accepted" {
    var s = try Scheduler.init(testing.allocator, 4, .pinned, 99, 0, 0);
    defer s.deinit();
    try testing.expectEqual(@as(u64, 4), s.pinned_pages);
}

test "lru evicts the coldest page and keeps capacity bounded" {
    var h = try Harness.init(testing.allocator, 4, .lru, 0, 0);
    defer h.deinit();

    for (0..4) |i| try h.s.load(i);
    // Re-touch 0 so that 1 becomes the coldest.
    try h.step(0);

    try h.s.load(4);
    try testing.expectEqual(@as(usize, 4), h.s.used);
    try testing.expectEqual(@as(u64, 1), h.s.stats.evictions);
    try testing.expect(!h.s.index.contains(1));
    for ([_]u64{ 0, 2, 3, 4 }) |p| try testing.expect(h.s.index.contains(p));
}

test "eviction under a pinned policy never takes a pinned page" {
    var h = try Harness.init(testing.allocator, 4, .pinned, 2, 0);
    defer h.deinit();

    for (0..2) |i| try h.s.load(i); // the pinned pair
    for (0..20) |i| try h.s.load(100 + i); // churn

    try testing.expect(h.s.index.contains(0));
    try testing.expect(h.s.index.contains(1));
    try testing.expectEqual(@as(usize, 4), h.s.used);
}

test "a fully pinned set refuses to evict and says so" {
    // Capacity and pin size equal: nothing is evictable. The load must fail
    // loudly. Returning success while the page never becomes resident is the
    // bug this error exists for -- a caller that believes its fetch landed
    // goes on to read a page the scheduler never held.
    var h = try Harness.init(testing.allocator, 2, .pinned, 2, 0);
    defer h.deinit();

    try h.s.load(0);
    try h.s.load(1);
    try testing.expectError(error.NoEvictableSlot, h.s.load(2));

    // The pinned pair is untouched, and the refused page is simply absent.
    try testing.expect(h.s.index.contains(0));
    try testing.expect(h.s.index.contains(1));
    try testing.expect(!h.s.index.contains(2));
    try testing.expectEqual(@as(u64, 0), h.s.stats.evictions);
}

test "read-ahead leaves room for the demanded page when pins are resident" {
    // The clamp has to count *evictable* slots. Capacity 4 with two pinned
    // pages resident leaves room for two, so a batch can be the demanded page
    // plus one neighbour. Clamping on capacity instead would queue four and
    // evict the page the caller just faulted.
    var h = try Harness.init(testing.allocator, 4, .pinned, 2, 8);
    defer h.deinit();

    try h.step(0);
    try h.step(1);
    try testing.expectEqual(@as(usize, 2), h.s.pinned_used);

    try testing.expectEqual(@as(u32, 1), h.s.effectiveReadAhead());

    h.pending.clearRetainingCapacity();
    try testing.expect(!try h.s.access(20, &h.pending));
    try testing.expectEqual(@as(usize, 2), h.pending.items.len);
    for (h.pending.items) |p| try h.s.load(p);

    // The demanded page survived its own read-ahead.
    try testing.expect(h.s.index.contains(20));
    try testing.expectEqual(@as(usize, 4), h.s.used);
}

test "a fully pinned scheduler asks for no read-ahead at all" {
    var h = try Harness.init(testing.allocator, 2, .pinned, 2, 8);
    defer h.deinit();

    try h.step(0);
    try h.step(1);
    try testing.expectEqual(@as(usize, 2), h.s.pinned_used);
    try testing.expectEqual(@as(u32, 0), h.s.effectiveReadAhead());

    h.pending.clearRetainingCapacity();
    try testing.expect(!try h.s.access(50, &h.pending));
    try testing.expectEqual(@as(usize, 1), h.pending.items.len);
}

test "a pinned page that arrives last still takes a slot" {
    // The prefix is a *policy*, not a hint. If a pinned page were refused
    // whenever the set happened to be full, the pinned prefix would only be
    // honoured if it arrived first -- and the fill order is the client's, not
    // the scheduler's.
    var h = try Harness.init(testing.allocator, 4, .pinned, 1, 0);
    defer h.deinit();

    // Four non-pinned pages arrive first and fill the set.
    try h.step(10);
    try h.step(11);
    try h.step(12);
    try h.step(13);
    try testing.expectEqual(@as(usize, 4), h.s.used);

    // Now the pinned prefix page, which is resident nowhere.
    try h.step(0);
    try testing.expect(h.s.index.contains(0));
    try testing.expectEqual(@as(usize, 4), h.s.used);
}

test "read-ahead cannot evict the page the caller asked for" {
    // capacity 4 with a read-ahead of 8. Without a clamp the batch is the
    // demanded page plus eight neighbours; loading them fills the set and
    // evicts the page that was demanded, so the caller faults, does the read
    // it already paid for, and faults again.
    var h = try Harness.init(testing.allocator, 4, .lru, 0, 8);
    defer h.deinit();

    try testing.expectEqual(@as(u32, 3), h.s.effectiveReadAhead());

    h.pending.clearRetainingCapacity();
    try testing.expect(!try h.s.access(20, &h.pending));
    // 20 plus three neighbours: exactly the set's capacity.
    try testing.expectEqual(@as(usize, 4), h.pending.items.len);
    for (h.pending.items) |p| try h.s.load(p);

    // The demanded page is still there to be read.
    try testing.expect(h.s.index.contains(20));
    try testing.expectEqual(@as(usize, 4), h.s.used);
}

test "read-ahead stops at the end of the working set" {
    // A finite backing store has an end, and the scheduler has no business
    // asking the device for pages past it.
    var h = try Harness.init(testing.allocator, 8, .lru, 0, 4);
    defer h.deinit();
    h.s.pages = 10;

    h.pending.clearRetainingCapacity();
    _ = try h.s.access(9, &h.pending);
    // Only page 9: 10 and beyond are outside the set.
    try testing.expectEqual(@as(usize, 1), h.pending.items.len);
    try testing.expectEqual(@as(u64, 9), h.pending.items[0]);

    // And from the middle it stops exactly at the boundary.
    h.pending.clearRetainingCapacity();
    _ = try h.s.access(7, &h.pending);
    try testing.expectEqual(@as(usize, 3), h.pending.items.len);
    try testing.expectEqual(@as(u64, 9), h.pending.items[2]);
}

test "read-ahead does not wrap around past the largest page index" {
    // `page + 1 + ahead` wraps on a large enough index, and a wrapped index is
    // a perfectly valid-looking address for the caller to go and fetch.
    var h = try Harness.init(testing.allocator, 8, .lru, 0, 4);
    defer h.deinit();
    h.s.pages = 0; // unbounded: the wrap guard is what has to hold here

    h.pending.clearRetainingCapacity();
    _ = try h.s.access(std.math.maxInt(u64), &h.pending);
    try testing.expectEqual(@as(usize, 1), h.pending.items.len);

    h.pending.clearRetainingCapacity();
    _ = try h.s.access(std.math.maxInt(u64) - 1, &h.pending);
    // max-1 and max are both real; the step past max wraps and is dropped.
    try testing.expectEqual(@as(usize, 2), h.pending.items.len);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), h.pending.items[1]);
}

test "a failed index insert hands the slot back instead of shrinking the cache" {
    // The slab slot is taken off the free list before the map is told about
    // it. If the map insert fails and the slot is not returned, the cache is
    // one smaller for the rest of its life and nothing reports it.
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    fa.fail_index = 1; // the slab alloc succeeds, the map's first alloc fails

    var s = try Scheduler.init(fa.allocator(), 4, .lru, 0, 0, 0);
    defer s.deinit();
    s.linkFree();

    try testing.expectError(error.OutOfMemory, s.load(1));

    try testing.expectEqual(@as(usize, 0), s.used);

    // The real assertion: all four slots are still in circulation.
    var free: usize = 0;
    var cur = s.free_head;
    while (cur) |c| : (cur = s.slab[c].next) {
        free += 1;
        try testing.expect(free <= 4); // a cycle would hang the count
    }
    try testing.expectEqual(@as(usize, 4), free);
}

test "hitRate is one before any access rather than zero" {
    // A rate with no denominator is not a miss rate of zero, and reporting it
    // as one would make an unused scheduler look broken on the dashboard.
    const s = Scheduler.Stats{};
    try testing.expectEqual(@as(f64, 1.0), s.hitRate());
}

// ------------------------------------------------------- the fault path

/// An in-memory backend for the fault-path tests, counting the reads it is
/// asked for. The point of the granule is visible in exactly one number, and
/// this is where it shows up: `reads` is the round-trip count.
const FakeBackend = struct {
    bytes: []u8,
    /// Reads issued.
    reads: usize = 0,
    /// Bytes the backend was asked to produce.
    requested: usize = 0,
    /// Length of the last read, so a test can prove the fault size.
    last_len: usize = 0,
    /// Fail from this read onwards, so a test can prove read-ahead cannot fail
    /// a demand.
    fail_from: usize = std.math.maxInt(usize),

    pub fn read(self: *FakeBackend, offset: u64, buf: []u8) anyerror!usize {
        if (self.reads >= self.fail_from) return error.ReadFailed;
        self.reads += 1;
        self.requested += buf.len;
        self.last_len = buf.len;
        if (offset >= self.bytes.len) return 0;
        const n = @min(buf.len, self.bytes.len - offset);
        @memcpy(buf[0..n], self.bytes[@intCast(offset)..][0..n]);
        return n;
    }
};

/// A backend whose every byte is its own index, so a mis-sliced copy shows up
/// as wrong data rather than as a plausible number.
fn ramp(n: usize) std.mem.Allocator.Error![]u8 {
    const out = try testing.allocator.alloc(u8, n);
    for (out, 0..) |*b, i| b.* = @truncate(i);
    return out;
}

test "a 4 KiB read faults a whole granule, and the bytes are right" {
    const backing = try ramp(4 * 1024 * 1024);
    defer testing.allocator.free(backing);
    var be = FakeBackend{ .bytes = backing };

    const F = Faults(FakeBackend);
    var f = try F.init(testing.allocator, &be, .{
        .granule = 64 * 1024,
        .capacity_bytes = 256 * 1024,
    });
    defer f.deinit();

    var buf: [4096]u8 = undefined;
    const n = try f.read(0, &buf);

    try testing.expectEqual(@as(usize, 4096), n);
    // The whole point: 4 KiB asked for, 64 KiB fetched. One round trip rather
    // than one per 4 KiB the caller wanted.
    try testing.expectEqual(@as(usize, 1), be.reads);
    try testing.expectEqual(@as(usize, 64 * 1024), be.last_len);
    for (buf, 0..) |b, i| try testing.expectEqual(@as(u8, @truncate(i)), b);
}

test "a second read inside the same granule costs nothing" {
    const backing = try ramp(4 * 1024 * 1024);
    defer testing.allocator.free(backing);
    var be = FakeBackend{ .bytes = backing };

    const F = Faults(FakeBackend);
    var f = try F.init(testing.allocator, &be, .{
        .granule = 64 * 1024,
        .capacity_bytes = 256 * 1024,
    });
    defer f.deinit();

    var buf: [4096]u8 = undefined;
    _ = try f.read(0, &buf);
    _ = try f.read(8192, &buf);
    _ = try f.read(60 * 1024, &buf);

    try testing.expectEqual(@as(usize, 1), be.reads);
    const s = f.stats();
    try testing.expectEqual(@as(u64, 1), s.misses);
    try testing.expectEqual(@as(u64, 2), s.hits);
    try testing.expectEqual(@as(f64, 2.0 / 3.0), s.hitRate());
}

test "a request at least as large as the granule is not cached" {
    // It is already fault-sized. Caching it would allocate a slab the caller
    // immediately overwrites, and would report misses for reads that were
    // never inefficient.
    const backing = try ramp(4 * 1024 * 1024);
    defer testing.allocator.free(backing);
    var be = FakeBackend{ .bytes = backing };

    const F = Faults(FakeBackend);
    var f = try F.init(testing.allocator, &be, .{
        .granule = 64 * 1024,
        .capacity_bytes = 256 * 1024,
    });
    defer f.deinit();

    var buf: [64 * 1024]u8 = undefined;
    const n = try f.read(0, &buf);

    try testing.expectEqual(@as(usize, 64 * 1024), n);
    try testing.expectEqual(@as(usize, 1), be.reads);
    try testing.expectEqual(@as(usize, 64 * 1024), be.last_len);
    try testing.expect(!f.isResident(0));
    try testing.expectEqual(@as(u64, 0), f.stats().misses);
}

test "a read past the end of the working set stops short and is still a hit" {
    // 100 KiB of working set in 64 KiB granules: the second granule is short.
    const backing = try ramp(100 * 1024);
    defer testing.allocator.free(backing);
    var be = FakeBackend{ .bytes = backing };

    const F = Faults(FakeBackend);
    var f = try F.init(testing.allocator, &be, .{
        .granule = 64 * 1024,
        .capacity_bytes = 256 * 1024,
    });
    defer f.deinit();

    var buf: [4096]u8 = undefined;

    // 90 KiB is inside the working set and inside the short granule.
    const inside = try f.read(90 * 1024, &buf);
    try testing.expectEqual(@as(usize, 4096), inside);
    for (buf, 0..) |b, i| try testing.expectEqual(@as(u8, @truncate(90 * 1024 + i)), b);

    // Exactly at the end: zero bytes, and no second fetch. The granule really
    // is resident -- it is short, not absent.
    const at_end = try f.read(100 * 1024, &buf);
    try testing.expectEqual(@as(usize, 0), at_end);
    try testing.expectEqual(@as(usize, 1), be.reads);
    try testing.expectEqual(@as(u64, 1), f.stats().hits);
}

test "the short tail of a granule is never handed back" {
    // The final granule of a finite working set is short. `valid` is what gates
    // the copy, so the bytes past the end are unreachable -- and the fetch
    // zeroes them anyway, so a future change that widens `valid` cannot start
    // returning whatever the allocator had in the slab.
    const backing = try ramp(64 * 1024 + 10);
    defer testing.allocator.free(backing);
    var be = FakeBackend{ .bytes = backing };

    const F = Faults(FakeBackend);
    var f = try F.init(testing.allocator, &be, .{
        .granule = 64 * 1024,
        .capacity_bytes = 4 * 64 * 1024,
    });
    defer f.deinit();

    var buf: [4096]u8 = undefined;
    @memset(&buf, 0xFF);

    // The last 10 bytes of the working set. The request starts 6 bytes into
    // the granule and the granule is 10 bytes long, so 4 come back -- not 10.
    try testing.expectEqual(@as(usize, 4), try f.read(64 * 1024 + 6, &buf));
    for (buf[0..4], 0..) |b, i| try testing.expectEqual(@as(u8, @truncate(64 * 1024 + 6 + i)), b);

    // One byte past the end: nothing, and still no fetch.
    const past = try f.read(64 * 1024 + 10, &buf);
    try testing.expectEqual(@as(usize, 0), past);
    try testing.expectEqual(@as(usize, 1), be.reads);
}

test "a granule below a sector, or not a power of two, is refused" {
    const backing = try ramp(4096);
    defer testing.allocator.free(backing);
    var be = FakeBackend{ .bytes = backing };

    const F = Faults(FakeBackend);
    // 0 would divide by zero in the page arithmetic; 5000 is not a power of
    // two, so `offset / granule` is not a shift and `offset % granule` is not a
    // mask; 2048 is a power of two but under `PAGE`, which would break the
    // slab's alignment for every granule after the first.
    try testing.expectError(error.InvalidGranule, F.init(testing.allocator, &be, .{ .granule = 0 }));
    try testing.expectError(error.InvalidGranule, F.init(testing.allocator, &be, .{ .granule = 5000 }));
    try testing.expectError(error.InvalidGranule, F.init(testing.allocator, &be, .{ .granule = 2048 }));
}

test "read-ahead fetches the neighbours, and they are then hits" {
    const backing = try ramp(4 * 1024 * 1024);
    defer testing.allocator.free(backing);
    var be = FakeBackend{ .bytes = backing };

    const F = Faults(FakeBackend);
    var f = try F.init(testing.allocator, &be, .{
        .granule = 64 * 1024,
        .capacity_bytes = 4 * 64 * 1024,
        .read_ahead = 2,
    });
    defer f.deinit();

    var buf: [4096]u8 = undefined;
    _ = try f.read(0, &buf);

    // One demand, two neighbours, three fetches.
    try testing.expectEqual(@as(usize, 3), be.reads);
    try testing.expect(f.isResident(0));
    try testing.expect(f.isResident(1));
    try testing.expect(f.isResident(2));
    try testing.expectEqual(@as(u64, 2), f.stats().prefetched);

    // The prefetched granules hold the right bytes, not just the right count.
    var check: [4096]u8 = undefined;
    _ = try f.read(64 * 1024, &check);
    for (check, 0..) |b, i| try testing.expectEqual(@as(u8, @truncate(64 * 1024 + i)), b);
}

test "read-ahead past a known extent is not fetched" {
    // Asking the backend for granules that do not exist wastes a round trip at
    // the end of every sequential walk. A client that knows its extent says so,
    // and the walk stops at it.
    const backing = try ramp(4 * 1024 * 1024);
    defer testing.allocator.free(backing);
    var be = FakeBackend{ .bytes = backing };

    const F = Faults(FakeBackend);
    var f = try F.init(testing.allocator, &be, .{
        .granule = 64 * 1024,
        .capacity_bytes = 4 * 64 * 1024,
        .read_ahead = 8,
        .granules = 4,
    });
    defer f.deinit();

    var buf: [4096]u8 = undefined;
    _ = try f.read(0, &buf);

    // Granules 0..4 exist, so the demand plus three read-ahead, nothing more.
    try testing.expectEqual(@as(usize, 4), be.reads);
    try testing.expect(!f.isResident(4));
    try testing.expectEqual(@as(u64, 3), f.stats().prefetched);
}

test "the fault path evicts by the scheduler's policy" {
    const backing = try ramp(4 * 1024 * 1024);
    defer testing.allocator.free(backing);
    var be = FakeBackend{ .bytes = backing };

    const F = Faults(FakeBackend);
    var f = try F.init(testing.allocator, &be, .{
        .granule = 64 * 1024,
        .capacity_bytes = 2 * 64 * 1024,
    });
    defer f.deinit();

    var buf: [4096]u8 = undefined;
    _ = try f.read(0, &buf);
    _ = try f.read(64 * 1024, &buf);
    _ = try f.read(128 * 1024, &buf);

    // Three granules through a two-granule set: the first is gone, and it is
    // gone rather than merely counted -- `isResident` is the map, not the
    // counter.
    try testing.expect(!f.isResident(0));
    try testing.expect(f.isResident(1));
    try testing.expect(f.isResident(2));
    try testing.expectEqual(@as(u64, 1), f.stats().evictions);

    // And a re-read of the evicted granule faults again.
    const before = be.reads;
    _ = try f.read(0, &buf);
    try testing.expectEqual(before + 1, be.reads);
}

test "a failed read-ahead does not fail the demanded read" {
    const backing = try ramp(4 * 1024 * 1024);
    defer testing.allocator.free(backing);
    // The demand is read 0; every read-ahead after it fails.
    var be = FakeBackend{ .bytes = backing, .fail_from = 1 };

    const F = Faults(FakeBackend);
    var f = try F.init(testing.allocator, &be, .{
        .granule = 64 * 1024,
        .capacity_bytes = 4 * 64 * 1024,
        .read_ahead = 4,
    });
    defer f.deinit();

    var buf: [4096]u8 = undefined;
    const n = try f.read(0, &buf);

    try testing.expectEqual(@as(usize, 4096), n);
    try testing.expect(f.isResident(0));

    // A four-slot set asked for four granules of read-ahead grants three, not
    // four: the demanded granule takes a slot of its own, and a batch that
    // filled the set would evict the very page the caller is about to read.
    // This is the scheduler's clamp, reached through the fault path's config.
    try testing.expectEqual(@as(u32, 3), f.effectiveReadAhead());
    // All three failed, and none of them took the demand down with it.
    try testing.expectEqual(@as(u64, 3), f.stats().skipped);
    try testing.expectEqual(@as(usize, 1), be.reads);
}

test "the granule is the lever: same bytes, one sixteenth the round trips" {
    // This is the measured claim reduced to arithmetic. The benchmark measured
    // 106.8 MB/s at a 4 KiB fault against 580.5 MB/s at 1 MiB on this machine,
    // 5.4x, with nothing else changed. Here the whole lever is two counters:
    // the same 256 KiB walk, the same bytes off the backend, and the round-trip
    // count falls by exactly the ratio of the granules.
    const walk: usize = 256 * 1024;
    const step: usize = 4096;

    const backing = try ramp(walk);
    defer testing.allocator.free(backing);

    var small_be = FakeBackend{ .bytes = backing };
    const Small = Faults(FakeBackend);
    var small = try Small.init(testing.allocator, &small_be, .{
        .granule = 4096,
        .capacity_bytes = walk,
    });
    defer small.deinit();

    var big_be = FakeBackend{ .bytes = backing };
    const Big = Faults(FakeBackend);
    var big = try Big.init(testing.allocator, &big_be, .{
        .granule = 64 * 1024,
        .capacity_bytes = walk,
    });
    defer big.deinit();

    var buf: [step]u8 = undefined;
    var off: usize = 0;
    while (off < walk) : (off += step) {
        _ = try small.read(off, &buf);
        _ = try big.read(off, &buf);
    }

    // 64 faults at 4 KiB, 4 at 64 KiB, and the same 256 KiB either way.
    try testing.expectEqual(@as(usize, 64), small_be.reads);
    try testing.expectEqual(@as(usize, 4), big_be.reads);
    try testing.expectEqual(small_be.requested, big_be.requested);
    try testing.expectEqual(walk, big_be.requested);
}
