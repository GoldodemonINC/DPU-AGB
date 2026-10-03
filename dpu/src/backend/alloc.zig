//! Address and memory management for the DPU's virtual VRAM.
//!
//! Two allocation policies over one pool, because the two workloads have
//! genuinely opposite shapes:
//!
//! - **stream** — forward-only weight loading. A model is read in once, front
//!   to back, and never freed while it runs. This is a bump cursor. Trying to
//!   free-list it would just build a fragmentation problem the workload never
//!   asks you to solve.
//!
//! - **reclaim** — KV-cache churn. Context blocks are allocated and freed
//!   constantly during a generation. This needs a real free list with split on
//!   allocate and coalesce on free, at 4 KiB granularity, or long sessions leak
//!   themselves to death a few kilobytes at a time.
//!
//! Both hand out a *virtual address*, not a pool offset. That indirection is
//! the point: it is what lets the ICD hand an application a plausible VRAM
//! address while the bytes actually live at an unrelated offset in the file,
//! which is how a real GPU behaves and what makes the VAT worth having.

const std = @import("std");
const blockdev = @import("blockdev");

/// Allocation granularity, aligned to the block device's sector size so every
/// allocation is automatically safe to hand to a `NO_BUFFERING` transfer.
pub const GRANULARITY: u64 = blockdev.SECTOR;

/// Default base for DPU VRAM addresses.
///
/// Chosen to look like a plausible 64-bit device address and to sit well clear
/// of the null page, so a bug that returns address 0 is obvious rather than
/// silently plausible.
pub const DEFAULT_VADDR_BASE: u64 = 0x0000_1000_0000_0000;

pub const Error = error{
    OutOfMemory,
    OutOfSpace,
    InvalidHandle,
    Misaligned,
};

pub const Kind = enum {
    /// Forward-only, bump allocated, never reclaimed.
    stream,
    /// Split/merge free list, reclaimed on `free`.
    reclaim,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .stream => "STREAM",
            .reclaim => "RECLAIM",
        };
    }
};

/// A live allocation, as seen by a caller.
pub const Slice = struct {
    /// Address handed to the application. Opaque outside the allocator.
    vaddr: u64,
    /// Where the bytes actually live in the pool file.
    offset: u64,
    len: u64,
    kind: Kind,
};

/// A hole in the reclaim region.
pub const Extent = struct {
    offset: u64,
    len: u64,
};

const VatEntry = struct {
    vaddr: u64,
    offset: u64,
    len: u64,
    kind: Kind,
};

pub const Config = struct {
    /// Pool bytes under management.
    total: u64,
    /// Percentage of the pool given to the forward-only stream region.
    stream_share_pct: u8 = 60,
    vaddr_base: u64 = DEFAULT_VADDR_BASE,
};

pub const Stats = struct {
    /// Stream cursor, i.e. bytes committed to forward-only weights.
    stream_used: u64,
    stream_total: u64,
    /// Bytes currently handed out from the reclaim region.
    reclaim_used: u64,
    reclaim_total: u64,
    /// Largest single reclaim allocation that succeeded, for fragmentation
    /// trend tracking.
    largest_reclaim: u64,
    live_allocations: u64,
    free_extents: u64,
    /// How much of the reclaim region is still contiguous and unallocated.
    reclaim_free: u64,
    splits: u64,
    coalesces: u64,
};

pub const Allocator = struct {
    allocator: std.mem.Allocator,
    cfg: Config,

    stream_start: u64,
    stream_end: u64,
    stream_cursor: u64,

    reclaim_start: u64,
    reclaim_end: u64,

    /// Holes in the reclaim region, sorted ascending by offset. Sorted order is
    /// what makes coalescing with both neighbours a local operation rather than
    /// a scan.
    free_list: std.array_list.Managed(Extent),

    /// Live allocations keyed by vaddr, sorted ascending. vaddr comes from a
    /// monotonic counter so appends stay ordered without extra work.
    vat: std.array_list.Managed(VatEntry),

    next_vaddr: u64,
    reclaim_used: u64 = 0,
    largest_reclaim: u64 = 0,
    splits: u64 = 0,
    coalesces: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Allocator {
        const share = @min(cfg.stream_share_pct, 100);
        // Clamped to `total` before the reclaim split, because roundUp can
        // push a share of 100% past the pool and the subtraction below would
        // underflow.
        const stream_bytes = @min(roundUp(cfg.total * share / 100), cfg.total);
        const reclaim_bytes = cfg.total - stream_bytes;

        // A zero stream share is legal and is what the driver configures: a
        // forward-only pool can never return a byte, so a client that frees
        // and reallocates would leak the whole pool within a single session.
        // Only a pool with no reclaim region is unusable.
        if (reclaim_bytes == 0) return Error.OutOfSpace;

        var self: Allocator = .{
            .allocator = allocator,
            .cfg = cfg,
            .stream_start = 0,
            .stream_end = stream_bytes,
            .stream_cursor = 0,
            .reclaim_start = stream_bytes,
            .reclaim_end = stream_bytes + reclaim_bytes,
            .free_list = std.array_list.Managed(Extent).init(allocator),
            .vat = std.array_list.Managed(VatEntry).init(allocator),
            .next_vaddr = cfg.vaddr_base,
        };
        errdefer self.free_list.deinit();
        errdefer self.vat.deinit();

        // The whole reclaim region starts as one hole.
        try self.free_list.append(.{ .offset = self.reclaim_start, .len = reclaim_bytes });
        return self;
    }

    pub fn deinit(self: *Allocator) void {
        self.free_list.deinit();
        self.vat.deinit();
    }

    /// Allocate `len` bytes under `kind`. Length is rounded up to the
    /// granularity, so every result is safe to transfer without further
    /// alignment work.
    pub fn alloc(self: *Allocator, len: u64, kind: Kind) !Slice {
        if (len == 0) return Error.Misaligned;
        const need = roundUp(len);

        const offset = switch (kind) {
            .stream => try self.allocStream(need),
            .reclaim => try self.allocReclaim(need),
        };

        // From here the region is carved out of the pool. Every fallible step
        // below has to hand it back, because the failure mode of getting this
        // wrong is that the same bytes are later handed out twice -- two live
        // allocations overlapping, with nothing to detect it.
        errdefer switch (kind) {
            .stream => self.stream_cursor -= need,
            .reclaim => {
                self.reclaim_used -= need;
                self.releaseExtent(offset, need);
            },
        };

        const vaddr = self.next_vaddr;
        // Wrapping would silently alias two live allocations onto one address.
        if (self.next_vaddr + 1 == 0) return Error.OutOfSpace;
        self.next_vaddr += GRANULARITY;

        try self.vat.append(.{
            .vaddr = vaddr,
            .offset = offset,
            .len = need,
            .kind = kind,
        });

        return .{ .vaddr = vaddr, .offset = offset, .len = need, .kind = kind };
    }

    /// Release an allocation.
    ///
    /// Stream allocations are never reclaimed; freeing one is a no-op rather
    /// than an error, because a caller unwinding on an error path should not
    /// have to know which region it drew from.
    pub fn free(self: *Allocator, vaddr: u64) void {
        const idx = self.findVat(vaddr) orelse return;
        const entry = self.vat.items[idx];

        if (entry.kind == .reclaim) {
            self.releaseExtent(entry.offset, entry.len);
            self.reclaim_used -= entry.len;
        }
        _ = self.vat.orderedRemove(idx);
    }

    /// Resolve a vaddr back to its pool offset and length.
    pub fn translate(self: *const Allocator, vaddr: u64) ?Slice {
        const idx = self.findVat(vaddr) orelse return null;
        const e = self.vat.items[idx];
        return .{ .vaddr = e.vaddr, .offset = e.offset, .len = e.len, .kind = e.kind };
    }

    pub fn liveCount(self: *const Allocator) usize {
        return self.vat.items.len;
    }

    // -------------------------------------------------------------- internals

    fn allocStream(self: *Allocator, need: u64) !u64 {
        if (self.stream_cursor + need > self.stream_end) return Error.OutOfSpace;
        const at = self.stream_cursor;
        self.stream_cursor += need;
        return at;
    }

    /// First-fit over the sorted hole list.
    ///
    /// First-fit rather than best-fit on purpose: holes are kept sorted by
    /// offset, so the lowest usable hole is also the most likely to be adjacent
    /// to live data, which keeps the region behaving like a linear address
    /// space rather than fragmenting across the whole pool.
    fn allocReclaim(self: *Allocator, need: u64) !u64 {
        for (self.free_list.items, 0..) |hole, i| {
            if (hole.len < need) continue;

            if (hole.len == need) {
                _ = self.free_list.orderedRemove(i);
            } else {
                // Split: hand out the head, keep the tail.
                self.free_list.items[i].offset += need;
                self.free_list.items[i].len -= need;
                self.splits += 1;
            }
            self.reclaim_used += need;
            if (need > self.largest_reclaim) self.largest_reclaim = need;
            return hole.offset;
        }
        return Error.OutOfSpace;
    }

    /// Return a hole, merging with neighbours on either side so the free list
    /// does not fragment into unusable slivers.
    fn releaseExtent(self: *Allocator, offset: u64, len: u64) void {
        var i: usize = 0;
        while (i < self.free_list.items.len and self.free_list.items[i].offset < offset) i += 1;

        // Merge backwards if the previous hole ends exactly here.
        var merged_back = false;
        if (i > 0) {
            const prev = self.free_list.items[i - 1];
            if (prev.offset + prev.len == offset) {
                self.free_list.items[i - 1].len += len;
                merged_back = true;
                self.coalesces += 1;
                i -= 1;
            }
        }
        if (!merged_back) {
            self.free_list.insert(i, .{ .offset = offset, .len = len }) catch {
                // Losing a hole would hand the same bytes out twice, so the
                // unwind path in `alloc` is the only thing that may run here.
                // Reaching this means a caller released an extent that never
                // came from the free list, which is a bug rather than a
                // condition to survive.
                @panic("dpu alloc: free list insert failed");
            };
            self.coalesces += 1;
        }

        // Merge forwards if the hole now ends exactly at the next one.
        if (i + 1 < self.free_list.items.len) {
            const cur = self.free_list.items[i];
            const nxt = self.free_list.items[i + 1];
            if (cur.offset + cur.len == nxt.offset) {
                self.free_list.items[i].len += nxt.len;
                _ = self.free_list.orderedRemove(i + 1);
            }
        }
    }

    fn findVat(self: *const Allocator, vaddr: u64) ?usize {
        var lo: usize = 0;
        var hi: usize = self.vat.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const v = self.vat.items[mid].vaddr;
            if (v == vaddr) return mid;
            if (v < vaddr) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    pub fn stats(self: *const Allocator) Stats {
        var reclaim_free: u64 = 0;
        for (self.free_list.items) |h| reclaim_free += h.len;
        return .{
            .stream_used = self.stream_cursor,
            .stream_total = self.stream_end,
            .reclaim_used = self.reclaim_used,
            .reclaim_total = self.reclaim_end - self.reclaim_start,
            .largest_reclaim = self.largest_reclaim,
            .live_allocations = self.vat.items.len,
            .free_extents = self.free_list.items.len,
            .reclaim_free = reclaim_free,
            .splits = self.splits,
            .coalesces = self.coalesces,
        };
    }
};

pub fn roundUp(v: u64) u64 {
    return (v + GRANULARITY - 1) & ~(GRANULARITY - 1);
}

pub fn roundDown(v: u64) u64 {
    return v & ~(GRANULARITY - 1);
}
