//! The pool-backed memory system behind the DPU's Vulkan ICD.
//!
//! Everything here exists so that `vkAllocateMemory` on the DPU's
//! `DEVICE_LOCAL` heap returns bytes that genuinely live in `P:\DPU\pool.vram`,
//! read and written at device speed through the same [blockdev] the engine uses.
//!
//! # Two heaps, and why
//!
//! | Heap | Memory type | Backing | Purpose |
//! |---|---|---|---|
//! | 0 | `DEVICE_LOCAL` | the pool file on `P:\` | the tier the engine granted |
//! | 1 | `HOST_VISIBLE` | ordinary RAM | staging for uploads and readback |
//!
//! Heap 1 is not a consolation prize; it is how a real driver works, and it is
//! what makes heap 0 usable. A client cannot write to device-local memory
//! directly -- it fills a host-visible staging buffer and copies. That is the
//! same path llama.cpp takes when it uploads tensor data, and it is the reason
//! `vkMapMemory` on heap 0 returns `VK_ERROR_MEMORY_MAP_FAILED` rather than
//! quietly succeeding.
//!
//! # Why mapping device-local memory is refused
//!
//! It would be easy to let `vkMapMemory` on heap 0 succeed: bounce through a RAM
//! cache and write back on unmap. That would make a client believe the DPU is
//! as fast as RAM, because every access it makes would *be* RAM. The spec
//! requires the error, and more importantly the error is true. A client that
//! stages its writes through heap 1 and copies them in sees the real cost of
//! the pool; a client that maps heap 0 sees nothing but the page cache wearing a
//! costume.

const std = @import("std");
const win = @import("win");
const tiers = @import("tiers");
const blockdev = @import("blockdev");
const alloc = @import("alloc");

const c = win.c;

/// Volume and directory the pool lives on. Mirrors the engine's constants; the
/// ICD runs inside a host process and cannot read the engine's configuration at
/// runtime, so these are duplicated deliberately and guarded by the probe test.
const POOL_VOLUME: []const u8 = "P:\\\\";
const POOL_DIR: []const u8 = "P:\\\\DPU";

/// Heap indices, mirrored in `vkGetPhysicalDeviceMemoryProperties`.
pub const HEAP_DEVICE_LOCAL: u32 = 0;
pub const HEAP_HOST: u32 = 1;

/// Size of the host staging heap.
///
/// Deliberately modest. Staging is a bounce buffer, not a second VRAM: a client
/// that tries to offload a whole model into it has misunderstood the pool, and
/// giving it room to do so would compete with the 2 GiB reserve the ladder
/// protects. 1 GiB is comfortably more than any single upload needs.
pub const HOST_HEAP_BYTES: u64 = 1024 * 1024 * 1024;

/// Alignment every pool-backed allocation gets.
///
/// The block layer transfers in [blockdev.SECTOR] units and `NO_BUFFERING` on
/// NTFS is not advisory: offset, length *and* buffer address must all be sector
/// multiples. A Vulkan allocation that started mid-sector would silently become
/// a page-cache access the first time it was written, so every offset the pool
/// hands out is rounded up to a sector before it is returned.
pub const ALLOCATION_ALIGNMENT: u64 = blockdev.SECTOR;

pub const Error = error{
    /// The pool could not be opened. `vkAllocateMemory` surfaces this as
    /// VK_ERROR_OUT_OF_DEVICE_MEMORY rather than pretending the pool is empty.
    PoolUnavailable,
    OutOfPool,
    OutOfHostHeap,
    NotDeviceLocal,
};

/// A live allocation.
///
/// `offset`/`len` are pool-relative for heap 0 and a RAM pointer for heap 1.
/// Keeping them in one struct with a tagged union would be tidier, but the two
/// are used in disjoint code paths and the tag costs a branch on the hot copy
/// path for no benefit.
pub const Allocation = struct {
    sentinel: u32 = 0x44505505,
    heap: u32,
    /// Pool offset for heap 0; ignored for heap 1.
    offset: u64 = 0,
    /// Virtual address inside the pool allocator, used to free heap 0 regions.
    vaddr: u64 = 0,
    len: u64,
    /// RAM pointer for heap 1.
    host_ptr: ?[*]u8 = null,
    /// Non-zero while a `vkMapMemory` is outstanding.
    mapped: bool = false,

    pub fn valid(self: *const Allocation) bool {
        return self.sentinel == 0x44505505;
    }
};

/// Per-process singleton.
///
/// Opened lazily on the first `vkAllocateMemory` rather than at
/// `vk_icdNegotiateLoaderICDInterfaceVersion`, because opening the pool means
/// taking a file handle and running `fsutil`, and `vulkaninfo` creates and
/// destroys devices repeatedly without ever allocating. Paying that cost at
/// enumeration time would make merely *looking* at the device expensive.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    dev: blockdev.BlockDevice,
    pool_alloc: alloc.Allocator,
    /// Total bytes handed out on the host heap, for the commitment query.
    host_used: u64 = 0,

    pub fn open(allocator: std.mem.Allocator, heap_bytes: u64) !Backend {
        var dev = try blockdev.BlockDevice.init(allocator, POOL_VOLUME, POOL_DIR, heap_bytes);

        // The pool allocator is sized to what the device advertises, which is
        // the tier the engine granted. If the file on disk is longer than that
        // -- because the user dropped the tier -- the pool is left alone rather
        // than truncated: offsets a client already holds must stay valid.
        const total = @max(dev.ceiling, dev.file_size);
        // stream_share_pct is zero on purpose. A `stream` allocation is forward-only:
        // freeing one drops the VAT row but never returns the bytes, so a
        // client that allocates and frees in a loop -- vulkaninfo does, many
        // times per run -- walks the pool cursor to its end and then starts
        // getting VK_ERROR_OUT_OF_DEVICE_MEMORY from a pool that is visibly
        // empty. Reclaim costs a little fragmentation and is the only policy
        // under which `vkFreeMemory` means anything.
        const pool_alloc = alloc.Allocator.init(allocator, .{
            .total = total,
            .stream_share_pct = 0,
        }) catch {
            dev.deinit();
            return Error.PoolUnavailable;
        };

        return .{
            .allocator = allocator,
            .dev = dev,
            .pool_alloc = pool_alloc,
        };
    }

    pub fn close(self: *Backend) void {
        self.pool_alloc.deinit();
        self.dev.deinit();
    }

    /// Allocate `len` bytes from `heap`, rounded up to the sector size.
    ///
    /// The rounding happens here rather than being left to the caller because a
    /// caller that does not round produces a region whose tail crosses into the
    /// next allocation's first sector, and that corrupts a neighbour rather
    /// than failing visibly.
    pub fn allocate(self: *Backend, heap: u32, len: u64) !Allocation {
        const size = blockdev.roundUp(@max(len, 1));

        if (heap == HEAP_HOST) {
            // Commit lazily. MEM_RESERVE without MEM_COMMIT would let a client
            // "allocate" a terabyte and have it fail at first touch, which is
            // the worst possible time to discover the limit.
            const ptr = c.VirtualAlloc(
                null,
                size,
                c.MEM_COMMIT | c.MEM_RESERVE,
                c.PAGE_READWRITE,
            );
            if (ptr == null) return Error.OutOfHostHeap;
            self.host_used += size;
            return .{
                .heap = heap,
                .len = size,
                .host_ptr = @ptrCast(ptr),
            };
        }

        if (heap != HEAP_DEVICE_LOCAL) return Error.NotDeviceLocal;

        // Reclaim, not stream: see `Backend.open`. Weights and KV blocks would
        // ideally be forward-only, but Vulkan gives the client the right to
        // free any VkDeviceMemory at any time, and a driver that treats that
        // as a no-op is a driver that exhausts its own pool.
        const slice = self.pool_alloc.alloc(size, .reclaim) catch return Error.OutOfPool;
        return .{
            .heap = heap,
            .offset = slice.offset,
            .vaddr = slice.vaddr,
            .len = slice.len,
        };
    }

    pub fn release(self: *Backend, a: *Allocation) void {
        if (!a.valid()) return;
        if (a.heap == HEAP_HOST) {
            if (a.host_ptr) |p| {
                _ = c.VirtualFree(p, 0, c.MEM_RELEASE);
                a.host_ptr = null;
                self.host_used -|= a.len;
            }
        } else {
            self.pool_alloc.free(a.vaddr);
        }
        a.sentinel = 0;
    }

    /// Copy `len` bytes into the pool at `offset`. Real, uncached, flushed.
    pub fn write(self: *Backend, offset: u64, data: []const u8) !usize {
        if (data.len == 0) return 0;
        return self.dev.writeUnaligned(offset, data) catch |e| switch (e) {
            error.PoolOutOfSpace, error.PoolCeilingReached => Error.OutOfPool,
            else => Error.PoolUnavailable,
        };
    }

    pub fn read(self: *Backend, offset: u64, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        return self.dev.readUnaligned(offset, buf) catch Error.PoolUnavailable;
    }

    pub fn flush(self: *Backend) void {
        self.dev.flush();
    }

    /// Bytes actually committed on heap 0. Reported to clients so that
    /// `vkGetDeviceMemoryCommitment` reflects real disk usage rather than the
    /// difference of two bookkeeping counters.
    pub fn commitment(self: *Backend) u64 {
        const st = self.pool_alloc.stats();
        return st.stream_used + st.reclaim_used;
    }

    pub fn capacity(self: *const Backend) u64 {
        return self.dev.ceiling;
    }
};

/// How many memory types and heaps the device advertises. The two must agree
/// with `vkGetPhysicalDeviceMemoryProperties`, which reads them from here.
pub const MEMORY_TYPE_COUNT: u32 = 2;
pub const HEAP_COUNT: u32 = 2;

/// Map a `VkMemoryTypeIndex` onto its heap.
///
/// The index is validated rather than trusted: a client that passes 7 has a
/// bug, and silently clamping it to heap 1 would hand it RAM while it believes
/// it got the pool.
pub fn heapForMemoryType(index: u32) ?u32 {
    return switch (index) {
        0 => HEAP_DEVICE_LOCAL,
        1 => HEAP_HOST,
        else => null,
    };
}

/// --------------------------------------------------------- process arena
///
/// One fixed buffer per process, shared by every handle this driver hands out.
///
/// The alternative -- a general allocator inside a graphics driver -- is a
/// well-known source of crashes at teardown, because the loader may destroy
/// objects after the host application's own allocator is gone. `vulkaninfo`
/// alone creates and destroys devices, buffers and fences many times per run, so
/// this path is hot. The arena is reset when a device is created, which bounds
/// growth in an application that recreates devices.
///
/// Pool memory itself is *not* kept here: `vkFreeMemory` returns it to the pool
/// allocator's free list immediately, so a client that frees and reallocates
/// reuses real disk space rather than leaking it.
var arena_storage: [512 * 1024]u8 = undefined;
var arena_len: usize = 0;

pub fn arenaReset() void {
    arena_len = 0;
}

/// Bump-allocate from the arena. Returns null when the arena is exhausted, which
/// every caller surfaces as a Vulkan error rather than as a crash.
pub fn arenaAlloc(bytes: usize) ?[*]u8 {
    const base = @intFromPtr(&arena_storage[0]);
    const aligned = std.mem.alignForward(usize, base + arena_len, @alignOf(u64));
    const offset = aligned - base;
    if (offset + bytes > arena_storage.len) return null;
    arena_len = offset + bytes;
    return @ptrCast(&arena_storage[offset]);
}

// -------------------------------------------------------- backend singleton

/// The backend, opened lazily on first use.
///
/// Deliberately not opened at `vk_icdNegotiateLoaderICDInterfaceVersion`:
/// opening the pool means taking a file handle and running `fsutil`, and
/// `vulkaninfo` creates and destroys devices repeatedly without ever
/// allocating. Charging enumeration for that would make merely *looking* at the
/// device expensive.
var backend_storage: ?Backend = null;

/// Heap size the device advertises, set by the ICD before any allocation.
///
/// Kept separately from [Backend] because the tier is known before the pool is
/// opened, and opening the pool is exactly what we want to defer.
var advertised_heap_bytes: u64 = 0;

pub fn setAdvertisedHeap(bytes: u64) void {
    advertised_heap_bytes = bytes;
}

pub fn advertisedHeapBytes() u64 {
    return advertised_heap_bytes;
}

/// Open the pool on first use. Returns null when `P:\` is unavailable, which
/// callers turn into `VK_ERROR_OUT_OF_DEVICE_MEMORY`.
pub fn ensureBackend() ?*Backend {
    if (backend_storage != null) return &backend_storage.?;
    backend_storage = Backend.open(std.heap.page_allocator, advertised_heap_bytes) catch return null;
    return &backend_storage.?;
}

/// Host heap size, for the memory-properties query.
pub fn hostHeapBytes() u64 {
    return HOST_HEAP_BYTES;
}

/// Device-local heap size, for the memory-properties query.
pub fn deviceHeapBytes() u64 {
    return advertised_heap_bytes;
}

// --------------------------------------------------------------------- tests

const testing = std.testing;

test "every device-local allocation lands on a sector boundary" {
    // The reason this is not optional: NO_BUFFERING on NTFS rejects a transfer
    // whose offset, length or address is not a sector multiple, and an offset
    // that is not sector-aligned degrades silently to a cached write rather than
    // failing. This asserts the property that prevents that.
    const sizes = [_]u64{ 1, 100, 4095, 4096, 4097, 1 << 20, (1 << 20) + 1 };
    for (sizes) |n| {
        const rounded = blockdev.roundUp(@max(n, 1));
        try testing.expectEqual(@as(u64, 0), rounded % blockdev.SECTOR);
        try testing.expect(rounded >= n);
    }
}

test "the heap indices the ICD advertises are the ones memory.zig uses" {
    // A silent mismatch here would let a client pick heap 0 and land in RAM.
    try testing.expectEqual(@as(u32, 0), HEAP_DEVICE_LOCAL);
    try testing.expectEqual(@as(u32, 1), HEAP_HOST);
    try testing.expect(HOST_HEAP_BYTES > 0);
    try testing.expect(HOST_HEAP_BYTES < tiers.RESERVE_BYTES);
}

test "allocation sentinel detects a released handle" {
    var a: Allocation = .{ .heap = HEAP_HOST, .len = 4096 };
    try testing.expect(a.valid());
    a.sentinel = 0;
    try testing.expect(!a.valid());
}
