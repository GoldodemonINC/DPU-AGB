//! Aligned block I/O for the DPU capacity pool on P:\
//!
//! This module owns the pool file and every byte of I/O to it. `pool.zig` used
//! to own this and opened the file through the ordinary cached path, which is
//! why its benchmark reported a fictional 2560 MB/s: that number was the page
//! cache, not the device. The honest flushed figure on this box is roughly
//! 250 MB/s, and every later layer (the ICD's reported memory heaps, the
//! residency scheduler's prefetch model, the dashboard's latency trace) will be
//! built on whatever this module measures. If the numbers here are wrong, they
//! are wrong everywhere.
//!
//! Two invariants drive the design:
//!
//! 1. **Uncached.** The handle is opened with `FILE_FLAG_NO_BUFFERING |
//!    FILE_FLAG_WRITE_THROUGH`. Reads hit the device, not the page cache.
//!
//! 2. **Aligned.** `NO_BUFFERING` is not advisory on NTFS: the file offset,
//!    the transfer length *and* the buffer's address must all be multiples of
//!    the volume's sector size or the call fails outright. Every public entry
//!    point therefore enforces that, and the unaligned convenience wrappers
//!    bounce through an aligned bounce buffer rather than silently truncating.
//!
//! Sparse holes are verified with `GetFileInformationByHandleEx`, not
//! `FSCTL_QUERY_ALLOCATED_RANGES`. DeviceIoControl does not reach the driver
//! from this build (see pool.zig for the full diagnosis), so the one API that
//! would normally answer that question is unavailable.

const std = @import("std");
const win = @import("win");
const tiers = @import("tiers");
const c = win.c;

/// Alignment used for every transfer.
///
/// 4 KiB is used rather than the queried sector size because Windows requires
/// offset, length and address to be multiples of the *sector* size, and 4 KiB
/// is a multiple of every sector size in use (512, 1 KiB, 2 KiB, 4 KiB).
/// Choosing 4 KiB unconditionally therefore satisfies a 512-byte-sector
/// volume too, and it matches the allocator granularity in alloc.zig so a
/// caller never has to reason about two different block sizes.
pub const SECTOR: u64 = 4096;

/// Hard ceiling on pool growth. The pool never preallocates; this is a stop.
pub const DEFAULT_CEILING: u64 = 8 * 1024 * 1024 * 1024;

/// How far the file grows at a time when a write runs past its end.
const GROW_CHUNK: u64 = 64 * 1024 * 1024;

/// Free space kept in reserve on the volume. The pool must never be the thing
/// that fills the disk.
///
/// This is not defined independently of the tier ladder -- it *is*
/// `tiers.RESERVE_BYTES`. An earlier revision kept its own 512 MiB margin here
/// while the ladder reserved 2 GiB, so the tier a client was promised and the
/// space the block layer protected were two different numbers.
const FREE_SPACE_MARGIN: u64 = tiers.RESERVE_BYTES;

/// Cross-process advisory lock over the pool file.
///
/// The engine and the Vulkan ICD are separate processes that both open
/// `pool.vram`. Uncached 4 KiB I/O to the same region from two processes
/// interleaves into torn writes with no way to detect it afterwards, so every
/// transfer takes this first. It is a mutex rather than a file lock because
/// Windows byte-range locks are advisory too, and an advisory lock that the
/// other party does not take is worth nothing.
///
/// Local, not Global: a Global object needs SeCreateGlobalPrivilege, which is
/// one more reason this cannot work from an unelevated session, and per-session
/// is the correct scope anyway since both processes run in the same session.
const POOL_LOCK_NAME: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Local\\DPU.pool.lock");

/// How long a transfer waits for the other process before giving up. Long
/// enough to cover an 8 GiB flush, short enough that a wedged peer produces a
/// clean allocation failure instead of a hung application.
const POOL_LOCK_TIMEOUT_MS: u32 = 30_000;

pub const Error = error{
    PoolOpenFailed,
    PoolExtendFailed,
    OutOfBounds,
    NotAligned,
    WriteFailed,
    ReadFailed,
    SparseUnsupported,
    PoolCeilingReached,
    PoolOutOfSpace,
};

/// Bytes on disk vs bytes addressable, which is what proves sparseness.
pub const SparseInfo = struct {
    /// Logical end of file: the addressable extent.
    logical: u64,
    /// Bytes the filesystem has actually allocated.
    allocated: u64,
    /// True when allocated is meaningfully below logical, i.e. holes exist.
    has_holes: bool,
};

pub const Stats = struct {
    ceiling: u64,
    file_size: u64,
    used: u64,
    allocated: u64,
    read_bps: f64,
    write_bps: f64,
    latency_ms: f64,
    reads: u64,
    writes: u64,
    flushes: u64,
};

pub const Bench = struct {
    bytes: u64,
    write_mbps: f64,
    read_mbps: f64,
    /// Mean single-block read latency in milliseconds.
    read_latency_ms: f64,
    write_latency_ms: f64,
};

pub const BlockDevice = struct {
    allocator: std.mem.Allocator,
    volume: [:0]const u16,
    /// The pool directory in both spellings. The UTF-8 copy exists because
    /// sibling files are addressed by formatted path rather than by handle,
    /// and `std.fmt` only formats bytes; the wide copy is what Win32 wants.
    dir: [:0]const u16,
    dir_utf8: [:0]const u8,
    path: [:0]const u16,
    handle: c.HANDLE = undefined,
    open: bool = false,
    sparse: bool = false,
    /// True when the handle really is `NO_BUFFERING | WRITE_THROUGH`. False
    /// means this pool is a cached file and its timings are cache timings.
    uncached: bool = false,
    /// Handle for the cross-process pool lock, or null when it could not be
    /// created (in which case transfers proceed unlocked rather than failing).
    lock: ?c.HANDLE = null,
    ceiling: u64,
    file_size: u64 = 0,
    /// High-water mark of the highest offset ever written.
    used: u64 = 0,

    // Rate accounting. Byte counters are deltas consumed by `sample`.
    last_read_bytes: u64 = 0,
    last_write_bytes: u64 = 0,
    read_bps: f64 = 0,
    write_bps: f64 = 0,
    latency_ms: f64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
    flushes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, volume: []const u8, dir: []const u8, ceiling: u64) !BlockDevice {
        const volume_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, volume);
        errdefer allocator.free(volume_w);
        const dir_u8 = try allocator.dupeZ(u8, dir);
        errdefer allocator.free(dir_u8);
        const dir_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, dir_u8);
        errdefer allocator.free(dir_w);

        // The formatted path is a temporary in its own right; inlining it into
        // the utf16 conversion call leaked it on every open.
        const path_str = try std.fmt.allocPrint(allocator, "{s}\\pool.vram", .{dir});
        defer allocator.free(path_str);
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path_str);
        errdefer allocator.free(path_w);

        var self: BlockDevice = .{
            .allocator = allocator,
            .volume = volume_w,
            .dir = dir_w,
            .dir_utf8 = dir_u8,
            .path = path_w,
            .ceiling = ceiling,
        };
        try self.openPool();
        return self;
    }

    pub fn deinit(self: *BlockDevice) void {
        if (self.open) _ = c.CloseHandle(self.handle);
        self.open = false;
        if (self.lock) |m| _ = c.CloseHandle(m);
        self.lock = null;
        self.allocator.free(@constCast(self.dir));
        self.allocator.free(@constCast(self.dir_utf8));
        self.allocator.free(@constCast(self.path));
        self.allocator.free(@constCast(self.volume));
    }

    /// Raise the growth ceiling. Monotonic by design.
    ///
    /// The tier ladder moves the ceiling with the engine's power mode, and a
    /// mode change has to be able to escalate. Shrinking is refused rather
    /// than applied: the file may already be past the new value, and a ceiling
    /// that silently sits below the file's extent would turn later writes
    /// into `OutOfBounds` long after the data landed. Lowering a tier is a
    /// policy decision for the next process, not a live operation.
    ///
    /// Returns the ceiling actually in effect afterwards, which is `new_ceiling`
    /// unless it was lower than what is already in force.
    pub fn raiseCeiling(self: *BlockDevice, new_ceiling: u64) u64 {
        if (new_ceiling > self.ceiling) self.ceiling = new_ceiling;
        return self.ceiling;
    }

    /// Close and delete the pool file, then release the same state `deinit`
    /// does. For scratch pools only — a real pool is destroyed by unlinking
    /// it, and nothing here can undo that.
    ///
    /// This exists because a benchmark that writes 8 GiB and then merely
    /// closes its handle leaves 8 GiB of residue on the volume, and a test
    /// suite pointed at the live pool path can clobber a running engine.
    pub fn destroy(self: *BlockDevice) void {
        if (self.open) {
            _ = c.CloseHandle(self.handle);
            self.open = false;
            _ = c.DeleteFileW(self.path.ptr);
        }
        if (self.lock) |m| _ = c.CloseHandle(m);
        self.lock = null;
        self.allocator.free(@constCast(self.dir));
        self.allocator.free(@constCast(self.dir_utf8));
        self.allocator.free(@constCast(self.path));
        self.allocator.free(@constCast(self.volume));
    }

    /// Open the pool uncached and write-through.
    ///
    /// Nothing is preallocated. An earlier revision reserved the full ceiling
    /// with SetFileValidData while sparse was silently not enabled and filled
    /// P:\ down to 1.6 GB free before it was noticed. Growth is therefore
    /// driven by real writes, and bounded by both the ceiling and the volume's
    /// actual free space.
    fn openPool(self: *BlockDevice) !void {
        _ = c.CreateDirectoryW(self.dir.ptr, null);

        // These flags are the entire point of the block layer, and they were
        // documented here while not actually being passed. Without them the
        // handle is a normal cached handle and every "device" number this
        // project has reported was really a page-cache number.
        //
        // Uncached is tried first and cached is a declared fallback rather than
        // a silent one: `uncached` is surfaced in telemetry, because a caller
        // that believes it is measuring disk while reading the cache is the
        // exact failure this project exists to avoid.
        // FILE_FLAG_WRITE_THROUGH is 0x80000000, which translate-c imports as
        // a negative c_int, so the bitwise-or has to be done in u32.
        const UNCACHED: u32 = @as(u32, c.FILE_FLAG_NO_BUFFERING) | @as(u32, @bitCast(c.FILE_FLAG_WRITE_THROUGH));
        self.handle = c.CreateFileW(
            self.path.ptr,
            c.GENERIC_READ | c.GENERIC_WRITE,
            c.FILE_SHARE_READ | c.FILE_SHARE_WRITE,
            null,
            c.OPEN_ALWAYS,
            @as(u32, c.FILE_ATTRIBUTE_NORMAL) | UNCACHED,
            null,
        );
        if (self.handle != c.INVALID_HANDLE_VALUE) {
            self.uncached = true;
        } else {
            self.handle = c.CreateFileW(
                self.path.ptr,
                c.GENERIC_READ | c.GENERIC_WRITE,
                c.FILE_SHARE_READ | c.FILE_SHARE_WRITE,
                null,
                c.OPEN_ALWAYS,
                c.FILE_ATTRIBUTE_NORMAL,
                null,
            );
            self.uncached = false;
        }
        if (self.handle == c.INVALID_HANDLE_VALUE) return Error.PoolOpenFailed;
        self.open = true;

        // bInitialOwner = 0: take it per transfer rather than holding it for
        // the lifetime of the pool, so the two processes interleave at
        // transfer granularity instead of one of them winning outright.
        self.lock = c.CreateMutexW(null, 0, POOL_LOCK_NAME);

        self.sparse = markSparseViaFsutil(self.allocator, self.path);
        self.file_size = self.queryFileSize();
        if (self.file_size > self.ceiling) return Error.OutOfBounds;
    }

    /// Write at an offset. `data` must be sector-aligned in both length and
    /// address; use `writeUnaligned` when the caller's buffer is not.
    pub fn write(self: *BlockDevice, offset: u64, data: []const u8) !usize {
        try self.checkTransfer(offset, data.len);
        if (!isAlignedPtr(data.ptr)) return Error.NotAligned;
        try self.ensureRoom(offset + data.len);

        const start = tickMs();
        var ov: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
        ov.unnamed_0.unnamed_0.Offset = @truncate(offset);
        ov.unnamed_0.unnamed_0.OffsetHigh = @truncate(offset >> 32);

        var wrote: c.DWORD = 0;
        if (c.WriteFile(self.handle, @ptrCast(data.ptr), @intCast(data.len), &wrote, &ov) == 0) {
            return Error.WriteFailed;
        }
        self.latency_ms = ewma(self.latency_ms, msBetween(start), 0.2);
        self.writes += 1;
        self.last_write_bytes += wrote;
        if (offset + wrote > self.used) self.used = offset + wrote;
        return wrote;
    }

    /// Read into `offset`. `buf` must be sector-aligned in both length and
    /// address; use `readUnaligned` otherwise.
    pub fn read(self: *BlockDevice, offset: u64, buf: []u8) !usize {
        try self.checkTransfer(offset, buf.len);
        if (!isAlignedPtr(buf.ptr)) return Error.NotAligned;

        const start = tickMs();
        var ov: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
        ov.unnamed_0.unnamed_0.Offset = @truncate(offset);
        ov.unnamed_0.unnamed_0.OffsetHigh = @truncate(offset >> 32);

        var got: c.DWORD = 0;
        if (c.ReadFile(self.handle, @ptrCast(buf.ptr), @intCast(buf.len), &got, &ov) == 0) {
            return Error.ReadFailed;
        }
        self.latency_ms = ewma(self.latency_ms, msBetween(start), 0.2);
        self.reads += 1;
        self.last_read_bytes += got;
        return got;
    }

    /// Write from an arbitrary buffer, bouncing through an aligned staging
    /// buffer when necessary.
    ///
    /// Returns the caller's own byte count, never the sector-rounded one. The
    /// old version returned whatever `write` reported for the padded transfer,
    /// so a 20 byte write came back as 4096 and every caller that trusted the
    /// number over-counted by three orders of magnitude.
    ///
    /// The partial sectors at each end are read back, spliced and rewritten
    /// rather than written wholesale. Writing the staging buffer as-is is the
    /// obvious implementation and it is wrong twice over: it stamps the bytes
    /// on either side of the caller's range with whatever an uninitialised
    /// `VirtualAlloc` happened to contain, and it silently discards the
    /// neighbour that lived there.
    pub fn writeUnaligned(self: *BlockDevice, offset: u64, data: []const u8) !usize {
        if (data.len == 0) return 0;

        if (offset % SECTOR == 0 and data.len % SECTOR == 0 and isAlignedPtr(data.ptr)) {
            _ = try self.write(offset, data);
            return data.len;
        }

        var stage = try AlignedBuffer.alloc(@intCast(SECTOR));
        defer stage.free();
        const sect = stage.bytes[0..@intCast(SECTOR)];
        var done: usize = 0;

        // Head: a partial first sector, merged into whatever is already there.
        const head: usize = @intCast(offset % SECTOR);
        if (head != 0) {
            const chunk = @min(@as(usize, SECTOR), data.len);
            // A sector that has never been written is holes on NTFS and reads
            // back as zeroes, but a read past the current end of the file
            // simply fails. Both mean the same thing here -- there is nothing
            // to preserve -- so both leave the scratch zeroed.
            _ = self.read(roundDown(offset), sect) catch @memset(sect, 0);
            @memcpy(sect[head..][0..chunk], data[0..chunk]);
            _ = try self.write(roundDown(offset), sect);
            done = chunk;
        }

        // Middle: whole sectors straight from the caller's buffer.
        while (done + SECTOR <= data.len and (offset + done) % SECTOR == 0) {
            const chunk: usize = @intCast(SECTOR);
            const src = data[done..][0..chunk];
            if (isAlignedPtr(src.ptr)) {
                _ = try self.write(offset + done, src);
            } else {
                @memcpy(sect, src);
                _ = try self.write(offset + done, sect);
            }
            done += chunk;
        }

        // Tail: a partial final sector, same treatment as the head.
        if (done < data.len) {
            const at = offset + done;
            const base = roundDown(at);
            const inside: usize = @intCast(at - base);
            const chunk = data.len - done;
            _ = self.read(base, sect) catch @memset(sect, 0);
            @memcpy(sect[inside..][0..chunk], data[done..][0..chunk]);
            _ = try self.write(base, sect);
            done += chunk;
        }

        return done;
    }

    /// Read into an arbitrary buffer, bouncing through an aligned staging
    /// buffer when necessary.
    ///
    /// A short read at end of file stops the loop and reports the short count.
    /// It does not copy whatever the staging buffer held past that point: the
    /// old version discarded the byte count from `read` and copied the full
    /// requested length out of uninitialised scratch, so a read that ran off
    /// the end of the pool handed the caller uninitialised memory.
    pub fn readUnaligned(self: *BlockDevice, offset: u64, buf: []u8) !usize {
        if (buf.len == 0) return 0;

        if (offset % SECTOR == 0 and buf.len % SECTOR == 0 and isAlignedPtr(buf.ptr)) {
            _ = try self.read(offset, buf);
            return buf.len;
        }

        var stage = try AlignedBuffer.alloc(@intCast(SECTOR));
        defer stage.free();
        const sect = stage.bytes[0..@intCast(SECTOR)];
        var done: usize = 0;

        while (done < buf.len) {
            const at = offset + done;
            const base = roundDown(at);
            const inside: usize = @intCast(at - base);
            const want = @min(@as(usize, SECTOR) - inside, buf.len - done);
            // A read that fails is a read that ran off the end of the file.
            // Stop and report the short count rather than copying whatever the
            // scratch allocation held.
            const got = self.read(base, sect) catch break;
            if (got < inside + want) break;
            @memcpy(buf[done..][0..want], sect[inside..][0..want]);
            done += want;
        }

        return done;
    }

    /// Push buffered writes to the device.
    ///
    /// With `WRITE_THROUGH` the data is already on its way to the platter, but
    /// `FlushFileBuffers` is what makes the write *complete*, and a round-trip
    /// through it is the only honest way to measure device latency.
    pub fn flush(self: *BlockDevice) void {
        const start = tickMs();
        _ = c.FlushFileBuffers(self.handle);
        self.latency_ms = ewma(self.latency_ms, msBetween(start), 0.2);
        self.flushes += 1;
    }

    fn checkTransfer(self: *const BlockDevice, offset: u64, len: usize) Error!void {
        if (offset % SECTOR != 0) return Error.NotAligned;
        if (len % SECTOR != 0) return Error.NotAligned;
        if (len == 0) return Error.NotAligned;
        if (offset + len > self.ceiling) return Error.OutOfBounds;
    }

    /// Grow the file so `needed` bytes are addressable, bounded by the ceiling
    /// and by free space on the volume.
    fn ensureRoom(self: *BlockDevice, needed: u64) Error!void {
        if (needed <= self.file_size) return;
        if (needed > self.ceiling) return Error.PoolCeilingReached;

        const target = @min(@max(needed, self.file_size + GROW_CHUNK), self.ceiling);

        // The reserve is checked whether or not the file is sparse.
        //
        // It used to be skipped for sparse pools, on the theory that a sparse
        // file does not really consume the volume until its holes are filled.
        // That is true in the steady state and useless as a guard: the moment a
        // client writes the holes, the volume is full, and the check that would
        // have stopped it did not run. AllocationSize -- the query that would
        // settle it -- is unreliable on this volume.
        //
        // So growth is charged as if it were fully allocated. That is strictly
        // conservative: some allocations that would have fitted are refused.
        // Refusing is recoverable and loud; filling P: is neither.
        const growth = target - self.file_size;
        if (win.VolumeSpace.query(self.volume)) |space| {
            if (space.free < growth + FREE_SPACE_MARGIN) return Error.PoolOutOfSpace;
        }

        const length: c.LARGE_INTEGER = .{ .QuadPart = @intCast(target) };
        var moved: c.LARGE_INTEGER = undefined;
        if (c.SetFilePointerEx(self.handle, length, &moved, c.FILE_END) == 0) return Error.PoolExtendFailed;
        if (c.SetFilePointerEx(self.handle, length, &moved, c.FILE_BEGIN) == 0) return Error.PoolExtendFailed;
        self.file_size = target;
    }

    fn queryFileSize(self: *BlockDevice) u64 {
        var size: c.LARGE_INTEGER = undefined;
        if (c.GetFileSizeEx(self.handle, &size) == 0) return 0;
        return @intCast(size.QuadPart);
    }

    /// Logical extent versus bytes actually allocated.
    ///
    /// `FSCTL_QUERY_ALLOCATED_RANGES` would be the precise answer, but
    /// DeviceIoControl does not reach the driver from this build. The standard
    /// information class reports allocation size directly and needs no ioctl.
    pub fn sparseInfo(self: *BlockDevice) SparseInfo {
        var info: c.FILE_STANDARD_INFO = std.mem.zeroes(c.FILE_STANDARD_INFO);
        const got = c.GetFileInformationByHandleEx(
            self.handle,
            c.FileStandardInfo,
            @ptrCast(&info),
            @sizeOf(c.FILE_STANDARD_INFO),
        );
        if (got == 0) return .{ .logical = 0, .allocated = 0, .has_holes = false };

        const logical: u64 = @intCast(@max(info.EndOfFile.QuadPart, 0));
        const allocated: u64 = @intCast(@max(info.AllocationSize.QuadPart, 0));
        return .{
            .logical = logical,
            .allocated = allocated,
            // A cluster of slack is normal for a sparsely-extended file.
            .has_holes = allocated + SECTOR < logical,
        };
    }

    pub fn sample(self: *BlockDevice, interval_ms: u64) Stats {
        const seconds = @as(f64, @floatFromInt(@max(interval_ms, 1))) / 1000.0;
        const rd = self.last_read_bytes;
        const wr = self.last_write_bytes;
        self.read_bps = ewma(self.read_bps, @as(f64, @floatFromInt(rd)) / seconds, 0.3);
        self.write_bps = ewma(self.write_bps, @as(f64, @floatFromInt(wr)) / seconds, 0.3);
        self.last_read_bytes = 0;
        self.last_write_bytes = 0;

        return .{
            .ceiling = self.ceiling,
            .file_size = self.file_size,
            .used = self.used,
            .allocated = self.sparseInfo().allocated,
            .read_bps = self.read_bps,
            .write_bps = self.write_bps,
            .latency_ms = self.latency_ms,
            .reads = self.reads,
            .writes = self.writes,
            .flushes = self.flushes,
        };
    }

    /// Measure real, flushed, device throughput.
    ///
    /// Each phase is separated by an explicit `FlushFileBuffers`, and the
    /// buffer is aligned and uncached, so these are device numbers. The read
    /// phase additionally flushes the file system cache first, otherwise a
    /// just-written block could be served from cache and the figure would be
    /// fiction all over again.
    pub fn benchmark(self: *BlockDevice, block: u64, blocks: usize) !Bench {
        if (block % SECTOR != 0 or block == 0) return Error.NotAligned;
        var stage = try AlignedBuffer.alloc(@intCast(block));
        defer stage.free();
        @memset(stage.bytes, 0xAB);

        const w0 = tickMs();
        for (0..blocks) |i| _ = try self.write(i * block, stage.bytes);
        self.flush();
        const w_elapsed = msBetween(w0);

        // Force any cached copy out before timing reads.
        self.flush();

        var r_latency: f64 = 0;
        const r0 = tickMs();
        for (0..blocks) |i| {
            const t = tickMs();
            _ = try self.read(i * block, stage.bytes);
            r_latency = ewma(r_latency, msBetween(t), 0.15);
        }
        const r_elapsed = msBetween(r0);

        const bytes: f64 = @floatFromInt(block * blocks);
        return .{
            .bytes = block * blocks,
            .write_mbps = mbPerSec(bytes, w_elapsed),
            .read_mbps = mbPerSec(bytes, r_elapsed),
            .read_latency_ms = r_latency,
            .write_latency_ms = w_elapsed / @as(f64, @floatFromInt(blocks)),
        };
    }
};

/// Sector-aligned scratch memory.
///
/// `NO_BUFFERING` requires the *address* to be aligned, which a general
/// allocator will not promise, so this goes to `VirtualAlloc` directly. Windows
/// reserves 64 KiB-aligned regions, which satisfies any sector size.
pub const AlignedBuffer = struct {
    bytes: []align(SECTOR) u8,
    reserved: usize,
    ptr: ?[*]u8 = null,

    pub fn alloc(len: usize) !AlignedBuffer {
        const rounded = roundUp(@max(len, @as(usize, SECTOR)));
        const ptr = c.VirtualAlloc(
            null,
            rounded,
            c.MEM_COMMIT | c.MEM_RESERVE,
            c.PAGE_READWRITE,
        );
        if (ptr == null) return Error.OutOfBounds;
        return .{
            .bytes = @as([*]align(SECTOR) u8, @ptrCast(@alignCast(ptr)))[0..rounded],
            .reserved = rounded,
            .ptr = @ptrCast(ptr),
        };
    }

    pub fn free(self: *AlignedBuffer) void {
        if (self.ptr) |p| {
            _ = c.VirtualFree(p, 0, c.MEM_RELEASE);
            self.ptr = null;
        }
    }
};

pub fn roundUp(v: u64) u64 {
    return (v + SECTOR - 1) & ~(SECTOR - 1);
}

pub fn roundDown(v: u64) u64 {
    return v & ~(SECTOR - 1);
}

fn isAlignedPtr(ptr: anytype) bool {
    return @intFromPtr(ptr) % SECTOR == 0;
}

fn mbPerSec(bytes: f64, ms: f64) f64 {
    if (ms <= 0) return 0;
    return bytes / ms * 1000.0 / (1024.0 * 1024.0);
}

fn tickMs() u64 {
    var ft: c.FILETIME = undefined;
    c.GetSystemTimePreciseAsFileTime(&ft);
    const t = @as(u64, ft.dwHighDateTime) << 32 | @as(u64, ft.dwLowDateTime);
    return t / 10_000;
}

fn msBetween(start: u64) f64 {
    return @floatFromInt(tickMs() - start);
}

fn ewma(prev: f64, next: f64, alpha: f64) f64 {
    if (prev == 0) return next;
    return prev * (1.0 - alpha) + next * alpha;
}

/// Ask `fsutil` to mark the pool sparse.
///
/// DeviceIoControl(FSCTL_SET_SPARSE) does not reach the driver from this build
/// for reasons documented in pool.zig, but `fsutil sparse setflag` succeeds on
/// the same volume immediately afterwards. This runs once at open, never on the
/// I/O path. If it fails the pool still works, just densely.
fn markSparseViaFsutil(allocator: std.mem.Allocator, path: [:0]const u16) bool {
    const path_len = std.mem.indexOfScalar(u16, path, 0) orelse path.len;
    const path_u8 = std.unicode.utf16LeToUtf8Alloc(allocator, path[0..path_len]) catch return false;
    defer allocator.free(path_u8);

    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "fsutil sparse setflag \"{s}\"", .{path_u8}) catch return false;
    if (!runAndWait(cmd)) return false;

    // The output of GetFileAttributesExW is a WIN32_FILE_ATTRIBUTE_DATA --
    // five fields, 88 bytes on x86-64 -- not the DWORD the old code passed. A
    // four byte stack buffer meant every pool open in both processes wrote
    // roughly eighty bytes past the end of it.
    var attr: c.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (c.GetFileAttributesExW(path, c.GetFileExInfoStandard, @ptrCast(&attr)) == 0) return false;
    return @as(u32, attr.dwFileAttributes) & @as(c_uint, c.FILE_ATTRIBUTE_SPARSE_FILE) != 0;
}

fn runAndWait(cmd: []const u8) bool {
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, cmd) catch return false;
    defer std.heap.page_allocator.free(cmd_w);

    var si: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
    si.cb = @sizeOf(c.STARTUPINFOW);
    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);

    // CreateProcessW may rewrite the command line, hence a writable buffer.
    if (c.CreateProcessW(null, cmd_w.ptr, null, null, 0, c.CREATE_NO_WINDOW, null, null, &si, &pi) == 0) return false;
    defer {
        _ = c.CloseHandle(pi.hThread);
        _ = c.CloseHandle(pi.hProcess);
    }

    // Bounded so a wedged fsutil cannot stall engine startup.
    if (c.WaitForSingleObject(pi.hProcess, 5000) != 0) return false;
    var code: c.DWORD = 0;
    if (c.GetExitCodeProcess(pi.hProcess, &code) == 0) return false;
    return code == 0;
}