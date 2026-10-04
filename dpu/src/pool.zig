//! The DPU capacity pool: a sparse-backed virtual VRAM buffer on P:\
//!
//! This module is now a thin facade. It used to own the pool file, its I/O,
//! its growth policy and its statistics; all of that lives in
//! `backend/blockdev.zig`, which opens the file with `NO_BUFFERING |
//! WRITE_THROUGH` so the numbers are device numbers rather than page-cache
//! numbers. What is left here is the pool-level policy the engine cares about —
//! the ceiling, the status the dashboard reads, and the ownership boundary
//! between the block layer and the allocator.
//!
//! Two facts this layer records because they were learned the hard way:
//!
//! - **P:\ supports sparse files.** An earlier revision used a wrong
//!   `FSCTL_SET_SPARSE` constant (0x000900C6, which encodes METHOD_NEITHER and
//!   FILE_ANY_ACCESS) and concluded the volume could not do sparse. The correct
//!   value is 0x00094C44. Separately, DeviceIoControl does not reach the
//!   driver from this build at all, so `fsutil` is used as a setup fallback.
//!
//! - **`AllocationSize` is not a reliable committed-bytes measure here.** After
//!   writing 256 MiB it reported 31 MiB, yet every byte read back intact. It is
//!   surfaced for information only and is never used as a correctness signal.
//!
//! The pool never preallocates. An earlier version reserved the full ceiling
//! with SetFileValidData while sparse was silently not enabled and filled P:\
//! down to 1.6 GB free before anyone noticed.

const std = @import("std");
const win = @import("win");
const blockdev = @import("blockdev");
const tiers = @import("tiers");

/// Largest the pool is allowed to grow. A stop, not a reservation: the pool
/// grows on demand as blocks are actually written.
pub const DEFAULT_CAPACITY: u64 = blockdev.DEFAULT_CEILING;

/// Block size for the residency scheduler. 1 MiB matches what NVMe is
/// efficient at and keeps syscall counts sane.
pub const BLOCK_SIZE: u64 = 1024 * 1024;

pub const Stats = struct {
    /// Current addressable extent of the file.
    file_size: u64,
    /// Highest offset ever written.
    used: u64,
    /// Reported allocation size. Unreliable on this volume; informational only.
    allocated: u64,
    read_bps: f64,
    write_bps: f64,
    latency_ms: f64,
    reads: u64,
    writes: u64,
};

pub const Pool = struct {
    dev: blockdev.BlockDevice,

    pub fn init(allocator: std.mem.Allocator, volume: []const u8, dir: []const u8, capacity: u64) !Pool {
        return .{ .dev = try blockdev.BlockDevice.init(allocator, volume, dir, capacity) };
    }

    pub fn deinit(self: *Pool) void {
        self.dev.deinit();
    }

    /// Close and unlink the pool file. For scratch pools only — a real pool is
    /// destroyed by unlinking it, and nothing here can undo that.
    ///
    /// `BlockDevice.destroy` already exists for exactly this and documents the
    /// hazard; `Pool` simply did not surface it, so the only way to unlink a
    /// pool reached through this type was to reach past it into `dev`.
    pub fn destroy(self: *Pool) void {
        self.dev.destroy();
    }

    /// Read at an offset. Prefers the aligned path and falls back to the
    /// bouncing wrapper when the caller's buffer cannot satisfy it.
    pub fn read(self: *Pool, offset: u64, buf: []u8) !usize {
        return self.dev.readUnaligned(offset, buf);
    }

    /// Write at an offset, growing the pool as needed.
    pub fn write(self: *Pool, offset: u64, data: []const u8) !usize {
        return self.dev.writeUnaligned(offset, data);
    }

    pub fn flush(self: *Pool) void {
        self.dev.flush();
    }

    pub fn sample(self: *Pool, interval_ms: u64) Stats {
        const s = self.dev.sample(interval_ms);
        return .{
            .file_size = s.file_size,
            .used = s.used,
            .allocated = s.allocated,
            .read_bps = s.read_bps,
            .write_bps = s.write_bps,
            .latency_ms = s.latency_ms,
            .reads = s.reads,
            .writes = s.writes,
        };
    }

    /// How full the pool is against its ceiling, 0..100.
    ///
    /// Measured against the ceiling rather than current extent, because the
    /// file only grows on demand and measuring against current length would peg
    /// the gauge the moment anything was written.
    pub fn saturation(self: *const Pool) f64 {
        if (self.dev.ceiling == 0) return 0;
        return @as(f64, @floatFromInt(self.dev.used)) /
            @as(f64, @floatFromInt(self.dev.ceiling)) * 100.0;
    }

    pub fn sparse(self: *const Pool) bool {
        return self.dev.sparse;
    }

    pub fn ceiling(self: *const Pool) u64 {
        return self.dev.ceiling;
    }

    /// Free space on the volume the pool lives on, for tier resolution.
    pub fn freeSpace(self: *const Pool) u64 {
        return if (win.VolumeSpace.query(self.dev.volume)) |s| s.free else 0;
    }

    /// Resolve a power mode against the volume's real free space and adopt the
    /// resulting tier as the pool ceiling.
    ///
    /// Returns the tier decision so the caller can tell the difference between
    /// "you asked for 24 and got 24" and "you asked for 24 and the disk only
    /// had room for 16" — a distinction the dashboard needs, because the second
    /// one is a capacity problem the user can actually act on.
    ///
    /// The resolver takes a list of roots because it accounts the reserve per
    /// volume. The pool is still one file on one volume, so that list has one
    /// entry today and the arithmetic is unchanged — but the signature no
    /// longer forces every caller to pretend the second root does not exist.
    pub fn applyTier(self: *Pool, mode: tiers.Mode) tiers.Resolution {
        const roots = [_]u64{self.freeSpace()};
        const res = tiers.resolve(mode, &roots);
        if (res.granted > 0) _ = self.dev.raiseCeiling(res.granted);
        self.publishTier(res);
        return res;
    }

    /// Publish the capacity this pool can serve, for the Vulkan ICD to read.
    ///
    /// The ICD runs inside whichever application loaded Vulkan — llama.cpp,
    /// vulkaninfo — which are not this process. Without this file the DPU would
    /// advertise a capacity picked from a ladder rung at random, and a client
    /// would size its buffers against a number the pool never agreed to.
    ///
    /// On starvation the granted tier is zero, but the ceiling is monotonic and
    /// the pool does not shrink, so the capacity it can still serve is the
    /// ceiling it already has. That is what gets published: a full volume is a
    /// reason to stop growing, not a reason to start lying about what exists.
    pub fn publishTier(self: *const Pool, res: tiers.Resolution) void {
        const advertised = if (res.granted > 0) res.granted else self.dev.ceiling;
        if (advertised == 0) return;

        var text_buf: [128]u8 = undefined;
        const text = tiers.formatState(&text_buf, advertised, res.free_at_check) catch return;

        var path_buf: [320]u8 = undefined;
        const path_u8 = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{
            self.dev.dir_utf8,
            tiers.state_filename,
        }) catch return;

        var wide_buf: [640]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, path_u8) catch return;
        wide_buf[wide_len] = 0;
        // Slice to the written length before the cast. `@ptrCast(&wide_buf)`
        // would yield a 640-element slice, and the callee uses `.len` as the
        // path length -- so the whole thing reads as a path with no terminator
        // inside the buffer and the publish is refused.
        _ = win.writeFileAtomic(@ptrCast(wide_buf[0..wide_len]), text);
    }
};
