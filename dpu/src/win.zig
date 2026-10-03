//! Shared Win32 surface for the DPU engine.
//!
//! Everything the engine touches is declared here once so the rest of the code
//! never reaches into `@cImport` directly. Winsock headers are pulled in ahead
//! of windows.h because the latter drags in the legacy winsock.h and the two
//! collide on socket typedefs.
const std = @import("std");

pub const c = @cImport({
    @cInclude("winsock2.h");
    @cInclude("windows.h");
    @cInclude("tlhelp32.h");
    @cInclude("psapi.h");
    @cInclude("pdh.h");
});

/// PDH expands the anonymous union inside PDH_FMT_COUNTERVALUE to `unnamed_0`.
/// Confirmed against the generated cimport rather than assumed.
pub const CounterValue = struct {
    status: u32,
    value: f64,

    fn from(raw: c.PDH_FMT_COUNTERVALUE) CounterValue {
        // PDH_CSTATUS_VALID_DATA is 0. Any other status means the value field
        // is meaningless, so report zero rather than a garbage sample that the
        // dashboard would happily plot as a real spike.
        const status: u32 = @intCast(raw.CStatus);
        return .{
            .status = status,
            .value = if (status == 0) raw.unnamed_0.doubleValue else 0,
        };
    }
};

/// One PDH counter plus the stable JSON key the dashboard plots it under.
///
/// The key is stored rather than re-derived from the path at serialize time:
/// wildcard-expanded counters (one per GPU adapter) need a key derived from the
/// instance name, and a returned slice would dangle if built on a stack buffer.
pub const Counter = struct {
    key: []const u8,
    path: []const u8,
    handle: c.PDH_HCOUNTER,
};

pub const Query = struct {
    handle: c.PDH_HQUERY,
    counters: std.array_list.Managed(Counter),
    allocator: std.mem.Allocator,
    ok: bool,

    pub fn init(allocator: std.mem.Allocator) !Query {
        var q: Query = undefined;
        q.counters = std.array_list.Managed(Counter).init(allocator);
        q.allocator = allocator;
        q.ok = false;
        if (c.PdhOpenQueryA(null, 0, &q.handle) != 0) return error.PdhOpenFailed;
        q.ok = true;
        return q;
    }

    pub fn deinit(self: *Query) void {
        if (self.ok) _ = c.PdhCloseQuery(self.handle);
        self.counters.deinit();
    }

    /// Registers a counter, ignoring failures so a missing optional counter
    /// degrades one trace instead of failing the whole sampler.
    pub fn add(self: *Query, path: []const u8, key: []const u8) !void {
        var handle: c.PDH_HCOUNTER = undefined;
        if (c.PdhAddCounterA(self.handle, path.ptr, 0, &handle) != 0) return;
        try self.counters.append(.{
            .key = key,
            .path = path,
            .handle = handle,
        });
    }

    /// Expand a wildcard path into its instances and register each one.
    ///
    /// Needed for the GPU adapter counters: the LUID differs per machine and
    /// per boot, so a hardcoded instance name would silently produce zero
    /// telemetry on any box but this one.
    pub fn addWildcard(self: *Query, wildcard: []const u8, key_prefix: []const u8, scratch: []u8) !usize {
        // pcchPathListLength is an IN/OUT parameter: it must be seeded with the buffer
        // size in characters, or PDH sees a zero-length buffer and answers
        // PDH_MORE_DATA with the required length instead of filling it.
        var needed: c.DWORD = @intCast(scratch.len);
        const rc = c.PdhExpandWildCardPathA(null, wildcard.ptr, scratch.ptr, &needed, 0);
        if (rc != 0) return 0;
        const match_count = needed;
        if (match_count == 0) return 0;

        var added: usize = 0;
        var buf: []const u8 = scratch[0..];
        while (buf.len > 0) {
            const end = std.mem.indexOfScalar(u8, buf, 0) orelse break;
            const instance = buf[0..end];
            if (instance.len == 0) break;

            const key = try self.makeKey(key_prefix, instance);
            try self.add(instance, key);
            added += 1;

            // Instances are stored double-NUL-terminated; skip both terminators.
            const rest = buf[end + 1 ..];
            if (rest.len > 0 and rest[0] == 0) break;
            buf = rest;
        }
        return added;
    }

    /// Build `<prefix>_<discriminator>` where the discriminator is pulled out of
    /// the instance name. For GPU counters the useful token is the second half
    /// of the LUID, which is stable across reboots of the same hardware.
    fn makeKey(self: *Query, prefix: []const u8, instance: []const u8) ![]const u8 {
        const open = std.mem.indexOfScalar(u8, instance, '(') orelse return self.dupe(prefix);
        const close = std.mem.indexOfScalarPos(u8, instance, open, ')') orelse return self.dupe(prefix);

        var it = std.mem.splitScalar(u8, instance[open + 1 .. close], '_');
        _ = it.next(); // "luid"
        _ = it.next(); // adapter index
        const token = it.next() orelse return self.dupe(prefix);

        const gpa = self.allocator;
        return std.fmt.allocPrint(gpa, "{s}_{s}", .{ prefix, token });
    }

    fn dupe(self: *Query, text: []const u8) ![]const u8 {
        return self.allocator.dupe(u8, text);
    }

    /// Samples every registered counter into caller-owned storage.
    ///
    /// Takes a buffer instead of allocating: this runs four times a second for
    /// the life of the process, and the count of counters is fixed after
    /// startup, so there is no reason for the hot path to touch the allocator.
    pub fn sample(self: *const Query, out: []CounterValue) []CounterValue {
        const n = @min(out.len, self.counters.items.len);
        for (self.counters.items[0..n], out[0..n]) |ctr, *v| {
            var raw: c.PDH_FMT_COUNTERVALUE = undefined;
            const rc = c.PdhGetFormattedCounterValue(ctr.handle, c.PDH_FMT_DOUBLE, null, &raw);
            v.* = if (rc == 0) CounterValue.from(raw) else .{ .status = @intCast(rc), .value = 0 };
        }
        return out[0..n];
    }
};

/// Milliseconds of wall clock. Used for sampler cadence and I/O latency, where
/// QPC is overkill and QueryPerformanceCounter adds a call the cost model does
/// not need to see.
pub fn sleepMs(ms: u32) void {
    c.Sleep(ms);
}

/// Write `data` to `path`, replacing whatever was there.
///
/// Goes via a sibling `.tmp` and a rename because the reader is a *different
/// process* — the Vulkan ICD reads this file from whatever application
/// happened to load Vulkan first. A truncating write leaves a window in which
/// the file is empty, and the reader would see "no tier" instead of the old
/// one. The rename is atomic on NTFS, so a reader sees either the old bytes or
/// the new ones and never a half-written mix.
///
/// Returns false rather than an error: every caller treats a failure here as
/// "publish what you can, fall back conservatively", and none of them should
/// fail because a cache file could not be written.
pub fn writeFileAtomic(path: [:0]const u16, data: []const u8) bool {
    // std.fmt only formats bytes, so the suffix is appended by hand rather than
    // round-tripped through UTF-8 just to add four characters.
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral(".tmp");
    var tmp_buf: [320]u16 = undefined;
    if (path.len + suffix.len >= tmp_buf.len) return false;
    @memcpy(tmp_buf[0..path.len], path);
    @memcpy(tmp_buf[path.len..][0..suffix.len], suffix);
    const end = path.len + suffix.len;
    // The NUL has to be written by hand. Casting a plain slice to a sentinel
    // one does not check that the byte past the end is zero, and Win32 reads
    // until it finds one -- so without this the call silently reads uninitialised
    // stack and every CreateFileW fails with a path that looks almost right.
    tmp_buf[end] = 0;
    const tmp: [:0]const u16 = @ptrCast(tmp_buf[0..end]);

    const f = c.CreateFileW(
        tmp.ptr,
        c.GENERIC_WRITE,
        c.FILE_SHARE_READ,
        null,
        c.CREATE_ALWAYS,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (f == c.INVALID_HANDLE_VALUE) return false;

    // Deliberately not `defer`: the handle is closed here rather than at
    // function exit because the rename below cannot move a file that is still
    // open. The handle was requested with FILE_SHARE_READ only, so an open one
    // makes MoveFileExW fail with ERROR_SHARING_VIOLATION and the publish
    // silently never lands.
    var written: u32 = 0;
    const wrote = c.WriteFile(f, data.ptr, @intCast(data.len), &written, null);
    _ = c.CloseHandle(f);
    if (wrote == 0 or written != data.len) {
        _ = c.DeleteFileW(tmp.ptr);
        return false;
    }
    // REPLACE_EXISTING is required or the very first publish fails against a
    // stale file. The rename still fails if a reader holds the target open
    // without FILE_SHARE_DELETE, and that failure is reported rather than
    // swallowed: it means the published tier is stale, which the caller
    // decides what to do about.
    return c.MoveFileExW(tmp.ptr, path.ptr, c.MOVEFILE_REPLACE_EXISTING) != 0;
}

/// Bytes free/total on a volume. The path is wide because the underlying call
/// is the W variant; callers pass a `[:0]const u16` literal.
pub const VolumeSpace = struct {
    free: u64,
    total: u64,

    pub fn query(path: [:0]const u16) ?VolumeSpace {
        // These are ULARGE_INTEGER unions, not plain u64s.
        var avail: c.ULARGE_INTEGER = undefined;
        var total: c.ULARGE_INTEGER = undefined;
        var total_free: c.ULARGE_INTEGER = undefined;
        const ok = c.GetDiskFreeSpaceExW(path.ptr, &avail, &total, &total_free);
        if (ok == 0) return null;
        return .{
            .free = @intCast(avail.QuadPart),
            .total = @intCast(total.QuadPart),
        };
    }
};
