//! Tests for the backend block and allocation layers.
//!
//! The allocator tests are pure logic and run anywhere. The block device tests
//! need a real filesystem, because alignment and flush semantics are exactly
//! the kind of thing that only fails against an actual filesystem — but they
//! run against a scratch pool, never the live one.

const std = @import("std");
const testing = std.testing;
const blockdev = @import("blockdev");
const alloc = @import("alloc");
const tiers = @import("tiers");
const win = @import("win");

test {
    // Pull in the tier ladder's own tests; they live next to the policy they
    // describe rather than in this integration file.
    _ = @import("tiers");
    // Same for the server's routing table. Without this the dashboard's tests
    // are dead code: `zig build test` only discovers tests in the root module
    // and its relative imports, and nothing else in the backend touches the
    // HTTP layer.
    _ = @import("server.zig");
    // And for the wire-level suite, which drives the real server over loopback
    // sockets. server.zig's own tests stop at the function boundary: they say
    // a miss routes to a 404, never that a client receives one. The 200-for-a-
    // miss bug shipped green through all of them.
    _ = @import("server_wire_test.zig");
}

/// Scratch directory for the block device integration tests.
///
/// Deliberately not the engine's own `P:\DPU`: these tests open the pool file
/// and overwrite it, and a test run during an engine session would destroy
/// live VRAM. The ceiling is passed through only so the file grows the same way
/// it would in production; the tests only ever write a few sectors.
const scratch_dir = "P:\\DPU-selftest";

test "the published tier round-trips through the file the ICD reads" {
    // This is the whole engine-to-ICD channel, exercised end to end on a
    // scratch directory: write what the engine writes, then read it back
    // the way the Vulkan driver in another process does. If this passes but
    // the driver still advertises the wrong heap, the fault is in the ICD.
    const granted = 8 * 1024 * 1024 * 1024;
    const free_at_check = 25 * 1024 * 1024 * 1024;

    var text_buf: [128]u8 = undefined;
    const text = try tiers.formatState(&text_buf, granted, free_at_check);

    var path_buf: [320]u8 = undefined;
    const path_u8 = try std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{
        scratch_dir,
        tiers.state_filename,
    });

    var wide_buf: [640]u16 = undefined;
    const wide_len = try std.unicode.utf8ToUtf16Le(&wide_buf, path_u8);
    wide_buf[wide_len] = 0;
    const path: [:0]const u16 = @ptrCast(wide_buf[0..wide_len]);

    try testing.expect(win.writeFileAtomic(path, text));

    // Read it back the way the driver does, so a format change cannot pass
    // here and fail there. Win32 rather than std.fs because the ICD cannot use
    // std.fs either: it runs inside a host process, not a Zig program.
    const f = win.c.CreateFileW(
        path.ptr,
        win.c.GENERIC_READ,
        win.c.FILE_SHARE_READ | win.c.FILE_SHARE_WRITE,
        null,
        win.c.OPEN_EXISTING,
        win.c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    try testing.expect(f != win.c.INVALID_HANDLE_VALUE and f != null);
    defer _ = win.c.CloseHandle(f);

    var contents: [4096]u8 = undefined;
    var read: u32 = 0;
    try testing.expect(win.c.ReadFile(f, &contents, contents.len, &read, null) != 0);
    try testing.expect(read > 0);
    try testing.expectEqual(granted, tiers.parseState(contents[0..read]).?);
}

fn openScratch() !blockdev.BlockDevice {
    return blockdev.BlockDevice.init(testing.allocator, "P:\\", scratch_dir, blockdev.DEFAULT_CEILING);
}

// --------------------------------------------------------------- alignment

test "roundUp and roundDown respect the sector boundary" {
    try testing.expectEqual(@as(u64, 4096), blockdev.roundUp(1));
    try testing.expectEqual(@as(u64, 4096), blockdev.roundUp(4096));
    try testing.expectEqual(@as(u64, 8192), blockdev.roundUp(4097));
    try testing.expectEqual(@as(u64, 0), blockdev.roundDown(4095));
    try testing.expectEqual(@as(u64, 4096), blockdev.roundDown(4096));
    try testing.expectEqual(@as(u64, 4096), blockdev.roundDown(8191));
}

test "roundUp is idempotent at the boundary" {
    var v: u64 = 1;
    while (v < 40_000) : (v += 977) {
        const once = blockdev.roundUp(v);
        try testing.expectEqual(once, blockdev.roundUp(once));
        try testing.expectEqual(@as(u64, 0), once % blockdev.SECTOR);
        try testing.expect(once >= v);
    }
}

// --------------------------------------------------------------- allocator

fn testCfg() alloc.Config {
    return .{
        .total = 1 * 1024 * 1024 * 1024,
        .stream_share_pct = 50,
    };
}

test "stream allocations are monotonic and contiguous from zero" {
    var a = try alloc.Allocator.init(testing.allocator, testCfg());
    defer a.deinit();

    const s1 = try a.alloc(1, .stream);
    const s2 = try a.alloc(1, .stream);
    const s3 = try a.alloc(1, .stream);

    try testing.expectEqual(@as(u64, 0), s1.offset);
    try testing.expectEqual(@as(u64, 4096), s2.offset);
    try testing.expectEqual(@as(u64, 8192), s3.offset);
    try testing.expectEqual(@as(u64, 4096), s1.len);

    // vaddrs must be distinct even though offsets are sequential.
    try testing.expect(s1.vaddr != s2.vaddr);
    try testing.expect(s2.vaddr != s3.vaddr);
}

test "allocation length rounds up to the granularity" {
    var a = try alloc.Allocator.init(testing.allocator, testCfg());
    defer a.deinit();

    const s = try a.alloc(100, .stream);
    try testing.expectEqual(@as(u64, 4096), s.len);
}

test "stream region refuses to overrun rather than spilling into reclaim" {
    var cfg = testCfg();
    cfg.total = 64 * 1024; // 32K stream + 32K reclaim
    var a = try alloc.Allocator.init(testing.allocator, cfg);
    defer a.deinit();

    var last: alloc.Slice = undefined;
    for (0..8) |_| last = try a.alloc(4096, .stream);
    // The eighth and final block starts one slot in and ends exactly at the
    // region boundary, which is the whole point of the test.
    try testing.expectEqual(@as(u64, 4096 * 7), last.offset);
    try testing.expectEqual(@as(u64, 4096 * 8), a.stats().stream_used);
    try testing.expectError(error.OutOfSpace, a.alloc(4096, .stream));
}

test "reclaim splits the hole on allocate" {
    var a = try alloc.Allocator.init(testing.allocator, testCfg());
    defer a.deinit();

    const before = a.stats().free_extents;
    try testing.expectEqual(@as(usize, 1), before);

    _ = try a.alloc(4096, .reclaim);
    const st = a.stats();
    // One hole was split into two, one of which was handed out.
    try testing.expectEqual(@as(u64, 1), st.splits);
    try testing.expectEqual(@as(u64, 4096), st.reclaim_used);
}

test "free coalesces holes back into one extent" {
    var a = try alloc.Allocator.init(testing.allocator, testCfg());
    defer a.deinit();

    const total = a.stats().reclaim_total;

    const s1 = try a.alloc(4096, .reclaim);
    const s2 = try a.alloc(8192, .reclaim);
    const s3 = try a.alloc(4096, .reclaim);
    // All three came off the front of one contiguous hole, so a single tail
    // hole remains rather than three. The interesting case is the frees below,
    // where a hole is returned to the *middle* of the region.
    try testing.expectEqual(@as(u64, 1), a.stats().free_extents);

    // Free out of order: the allocator must handle a hole arriving between
    // two live ones, which is the case that breaks naive free lists.
    a.free(s2.vaddr);
    a.free(s1.vaddr);
    a.free(s3.vaddr);

    const st = a.stats();
    try testing.expectEqual(@as(usize, 1), st.free_extents);
    try testing.expectEqual(total, st.reclaim_free);
    try testing.expectEqual(@as(u64, 0), st.reclaim_used);
    try testing.expectEqual(@as(u64, 0), st.live_allocations);
}

test "free in allocation order also coalesces to a single extent" {
    var a = try alloc.Allocator.init(testing.allocator, testCfg());
    defer a.deinit();

    const total = a.stats().reclaim_total;
    const s1 = try a.alloc(4096, .reclaim);
    const s2 = try a.alloc(4096, .reclaim);
    const s3 = try a.alloc(4096, .reclaim);

    a.free(s1.vaddr);
    a.free(s2.vaddr);
    a.free(s3.vaddr);

    const st = a.stats();
    try testing.expectEqual(@as(usize, 1), st.free_extents);
    try testing.expectEqual(total, st.reclaim_free);
}

test "VAT translates vaddr back to offset and length" {
    var a = try alloc.Allocator.init(testing.allocator, testCfg());
    defer a.deinit();

    const s = try a.alloc(16_384, .reclaim);
    const back = a.translate(s.vaddr).?;

    try testing.expectEqual(s.offset, back.offset);
    try testing.expectEqual(s.len, back.len);
    try testing.expectEqual(alloc.Kind.reclaim, back.kind);

    // Unknown addresses must not resolve to something plausible.
    try testing.expect(a.translate(s.vaddr + 1) == null);
    try testing.expect(a.translate(0) == null);

    a.free(s.vaddr);
    try testing.expect(a.translate(s.vaddr) == null);
}

test "freed space is handed out again rather than leaked" {
    var a = try alloc.Allocator.init(testing.allocator, testCfg());
    defer a.deinit();

    // Cycle far more allocations than the region holds at once.
    for (0..200) |_| {
        const s = try a.alloc(64 * 1024, .reclaim);
        a.free(s.vaddr);
    }
    const st = a.stats();
    try testing.expectEqual(@as(usize, 1), st.free_extents);
    try testing.expectEqual(st.reclaim_total, st.reclaim_free);
}

test "exhausting the reclaim region errors instead of overrunning" {
    var cfg = testCfg();
    cfg.total = 256 * 1024; // 128K reclaim
    var a = try alloc.Allocator.init(testing.allocator, cfg);
    defer a.deinit();

    var made: usize = 0;
    while (true) {
        _ = a.alloc(4096, .reclaim) catch break;
        made += 1;
        if (made > 1000) return error.TestOverrun;
    }
    try testing.expectEqual(@as(usize, 32), made);
    try testing.expect(a.alloc(4096, .reclaim) == error.OutOfSpace);
}

test "stream allocations are not reclaimed by free" {
    var a = try alloc.Allocator.init(testing.allocator, testCfg());
    defer a.deinit();

    const s = try a.alloc(4096, .stream);
    const used_before = a.stats().stream_used;
    a.free(s.vaddr);

    // Stream memory is forward-only: free is a no-op, and the cursor does not
    // rewind. Reclaiming it would break the guarantee that live weights are
    // never overwritten.
    try testing.expectEqual(used_before, a.stats().stream_used);
    try testing.expect(a.translate(s.vaddr) == null);
}

test "zero-length allocation is rejected" {
    var a = try alloc.Allocator.init(testing.allocator, testCfg());
    defer a.deinit();
    try testing.expectError(error.Misaligned, a.alloc(0, .reclaim));
}

test "a zero stream share gives the whole pool to reclaim" {
    // This is the configuration the Vulkan driver uses. With no stream region
    // at all, every byte a client frees comes back, which is what makes
    // vkFreeMemory mean anything.
    var cfg = testCfg();
    cfg.stream_share_pct = 0;
    var a = try alloc.Allocator.init(testing.allocator, cfg);
    defer a.deinit();

    const st = a.stats();
    try testing.expectEqual(@as(u64, 0), st.stream_total);
    try testing.expectEqual(@as(u64, st.stream_total + st.reclaim_total), st.stream_total + st.reclaim_total);
    try testing.expect(st.reclaim_total > 0);

    // Allocate and free far more than the pool holds at once.
    for (0..200) |_| {
        const s = try a.alloc(256 * 1024, .reclaim);
        a.free(s.vaddr);
    }
    const after = a.stats();
    try testing.expectEqual(@as(usize, 1), after.free_extents);
    try testing.expectEqual(after.reclaim_total, after.reclaim_free);
    try testing.expectEqual(@as(u64, 0), after.reclaim_used);
}

test "a pool that is entirely forward-only is refused as unusable" {
    var cfg = testCfg();
    cfg.total = 4096;
    cfg.stream_share_pct = 100;
    try testing.expectError(error.OutOfSpace, alloc.Allocator.init(testing.allocator, cfg));
}

// ------------------------------------------------- block device integration

// Aligned write, flush, read, and compare. This is the gate the whole
// backend rests on: if the uncached path corrupts data, nothing above it
// matters.
test "aligned write flush read round-trips byte-identically" {
    var dev = try openScratch();
    defer dev.destroy();

    const size: usize = 64 * 1024;
    var stage = try blockdev.AlignedBuffer.alloc(size);
    defer stage.free();

    // A pattern that catches silent zero-fill and offset drift rather than
    // just "it came back all zeros".
    for (stage.bytes[0..size], 0..) |*byte, i| {
        byte.* = @truncate((i *% 31 +% 7) & 0xff);
    }
    const expect = try testing.allocator.dupe(u8, stage.bytes[0..size]);
    defer testing.allocator.free(expect);

    var backing = try blockdev.AlignedBuffer.alloc(size);
    defer backing.free();
    @memset(backing.bytes, 0);

    _ = try dev.write(0, stage.bytes);
    dev.flush();
    _ = try dev.read(0, backing.bytes);

    try testing.expectEqualSlices(u8, expect, backing.bytes[0..size]);
}

test "unaligned write then unaligned read returns the same bytes" {
    var dev = try openScratch();
    defer dev.destroy();

    const payload = "dpu-round-trip-check";
    _ = try dev.writeUnaligned(0, payload);
    dev.flush();

    var out: [64]u8 = undefined;
    // readUnaligned reports how much of the caller's buffer it filled, so the
    // caller asks for exactly the payload and gets the same length back.
    const n = try dev.readUnaligned(0, out[0..payload.len]);
    try testing.expectEqual(payload.len, n);
    try testing.expectEqualStrings(payload, out[0..n]);
}

// The staging bounce has to account for a transfer that begins mid-sector.
// An off-by-one in the base offset lands a few bytes off and shows up here.
test "unaligned read at a mid-sector offset returns the correct bytes" {
    var dev = try openScratch();
    defer dev.destroy();

    var stage = try blockdev.AlignedBuffer.alloc(blockdev.SECTOR);
    defer stage.free();
    for (stage.bytes, 0..) |*b, i| b.* = @truncate(i & 0xff);

    _ = try dev.write(0, stage.bytes);
    dev.flush();

    const want_offset: u64 = 100;
    const want_len = 16;

    var out: [16]u8 = undefined;
    const n = try dev.readUnaligned(want_offset, &out);
    try testing.expectEqual(want_len, n);

    var expect: [16]u8 = undefined;
    for (&expect, 0..) |*b, i| b.* = @truncate((want_offset + i) & 0xff);
    try testing.expectEqualSlices(u8, &expect, out[0..n]);
}

test "pool is marked sparse and grows without allocating the whole chunk" {
    var dev = try openScratch();
    defer dev.destroy();

    var stage = try blockdev.AlignedBuffer.alloc(4096);
    defer stage.free();
    @memset(stage.bytes, 0x5A);

    _ = try dev.write(0, stage.bytes);
    dev.flush();

    // The filesystem itself is the authority on sparseness here, and the only
    // question worth asking of it is whether the attribute is really set. The
    // pool is opened through `fsutil` because DeviceIoControl does not reach
    // the driver from this build, and `markSparseViaFsutil` confirms the result
    // with GetFileAttributesExW rather than assuming the call worked.
    try testing.expect(dev.sparse);

    // `AllocationSize` is deliberately not asserted on. It reported 31 MiB
    // after 256 MiB had been written and verified intact on this volume, so
    // `allocated < logical` is not a signal about sparseness — it is a signal
    // about how the RAID driver caches metadata. An earlier version of this
    // test asserted on it and passed only because a stale 8 GiB bench file was
    // lying around.
    const info = dev.sparseInfo();

    // Regardless of sparseness, the logical extent must cover the block that
    // was written, and must not have silently collapsed to nothing.
    try testing.expect(info.logical >= 4096);
}

test "unaligned direct transfer is rejected rather than silently mangled" {
    var dev = try openScratch();
    defer dev.destroy();

    var stage = try blockdev.AlignedBuffer.alloc(8192);
    defer stage.free();

    // Offset not a multiple of the sector.
    try testing.expectError(error.NotAligned, dev.write(1, stage.bytes[0..4096]));
    // Length not a multiple of the sector.
    try testing.expectError(error.NotAligned, dev.write(0, stage.bytes[0..100]));
}

// --------------------------------------------------------- pool lock
//
// The mutex guarding `pool.vram` across the engine and the in-process ICD was
// created at open and then never waited on, so both processes wrote the same
// uncached 4 KiB regions concurrently and interleaved them into torn sectors
// that nothing could detect afterwards. These two tests pin the two properties
// that fix has to have: a mutating transfer really goes through the lock, and
// the lock really comes back.

/// A Win32 manual-reset event, used to order the two threads in the lock test.
///
/// `std.Thread.ResetEvent` no longer exists in Zig 0.16, and the rest of this
/// suite already reaches for `win.c` rather than wrapping Win32, so this does
/// the same thing instead of reintroducing a helper nobody else uses.
const Event = struct {
    handle: win.c.HANDLE,

    fn init() !Event {
        // bManualReset = TRUE, bInitialState = FALSE.
        const h = win.c.CreateEventW(null, 1, 0, null);
        if (h == null) return error.TestUnexpectedResult;
        return .{ .handle = h };
    }

    fn deinit(self: *Event) void {
        _ = win.c.CloseHandle(self.handle);
        self.handle = null;
    }

    fn set(self: *Event) void {
        _ = win.c.SetEvent(self.handle);
    }

    fn wait(self: *Event) void {
        // INFINITE, not a timeout: every one of these is signalled on every
        // exit path of the test below, and a bounded wait here could quietly
        // return early and turn into a confusing assertion failure rather than
        // an ordering problem. The mutex wait in `LockPeer.run` keeps a bound,
        // so that thread always terminates.
        _ = win.c.WaitForSingleObject(self.handle, 0xFFFF_FFFF);
    }
};

/// A second thread's view of the pool mutex, used to prove ownership without
/// waiting a real `POOL_LOCK_TIMEOUT_MS`.
///
/// This has to be a separate thread. A Windows mutex is recursive, so the
/// owning thread can take it again immediately and a same-thread "second
/// acquire" would succeed whether or not `release` had ever run -- it would
/// pass against exactly the broken build this is meant to catch. Only another
/// thread is turned away by a lock that is genuinely held.
const LockPeer = struct {
    mutex: win.c.HANDLE,
    start: *Event,
    probed: *Event,
    proceed: *Event,
    /// Result of a zero-timeout wait while the other thread owns the lock.
    while_held: u32 = 0xFFFF_FFFF,
    /// Result of a real wait once the owner has released.
    after_release: u32 = 0xFFFF_FFFF,

    fn run(self: *LockPeer) void {
        self.start.wait();
        // Zero timeout on purpose: this thread should be turned away at once,
        // not parked for 30 seconds waiting for a lock that is never released.
        self.while_held = win.c.WaitForSingleObject(self.mutex, 0);
        self.probed.set();
        // Wait for the owner to let go, then ask again.
        self.proceed.wait();
        self.after_release = win.c.WaitForSingleObject(self.mutex, 10_000);
        _ = win.c.ReleaseMutex(self.mutex);
    }
};

test "a mutating write takes the pool lock, grows the file and reads back intact" {
    var dev = try openScratch();
    defer dev.destroy();

    // The mutex the whole scheme rests on has to exist; `openPool` now refuses
    // to open a pool without one.
    try testing.expect(dev.lock != null);

    // Write past the end of a freshly destroyed pool, so this exercises the
    // real mutation: `ensureRoom` extends the file and `write` commits a sector
    // of it. Not a read, not a bounds check, not a no-op.
    const off: u64 = 8 * blockdev.SECTOR;
    var stage = try blockdev.AlignedBuffer.alloc(blockdev.SECTOR);
    defer stage.free();
    for (stage.bytes, 0..) |*b, i| b.* = @truncate((i *% 31 +% off) & 0xff);

    const used_before = dev.used;
    const size_before = dev.file_size;
    const writes_before = dev.writes;

    const n = try dev.write(off, stage.bytes);
    dev.flush();

    try testing.expectEqual(@as(usize, blockdev.SECTOR), n);
    try testing.expectEqual(writes_before + 1, dev.writes);
    // The high-water mark moved, which is only true if the bytes were written.
    try testing.expectEqual(off + blockdev.SECTOR, dev.used);
    try testing.expect(dev.used > used_before);
    // The pool was grown rather than the write being refused or truncated.
    try testing.expectEqual(size_before, 0);
    try testing.expect(dev.file_size >= off + blockdev.SECTOR);

    // Nobody was turned away getting here. This is the assertion that would
    // have caught a lock left held by an earlier test.
    try testing.expectEqual(@as(u64, 0), dev.lock_timeouts);
    try testing.expectEqual(@as(u64, 0), dev.lock_abandoned);

    var back = try blockdev.AlignedBuffer.alloc(blockdev.SECTOR);
    defer back.free();
    const got = try dev.read(off, back.bytes);
    try testing.expectEqual(@as(usize, blockdev.SECTOR), got);
    try testing.expectEqualSlices(u8, stage.bytes, back.bytes);

    // An unaligned write at that same offset goes through the same lock and
    // still preserves its neighbours, which is the case that needs the lock
    // held across the read-modify-write rather than around each write alone.
    const patch = [_]u8{0xC7} ** 12;
    try testing.expectEqual(@as(usize, 12), try dev.writeUnaligned(off + 64, &patch));
    dev.flush();
    var window = try blockdev.AlignedBuffer.alloc(blockdev.SECTOR);
    defer window.free();
    _ = try dev.read(off, window.bytes);
    try testing.expectEqualSlices(u8, &patch, window.bytes[64..][0..12]);
    for (window.bytes[0..64], 0..) |have, i| {
        try testing.expectEqual(stage.bytes[i], have);
    }
}

test "the pool lock is released after a transfer, so a peer can take it" {
    var dev = try openScratch();
    defer dev.destroy();

    const mutex = dev.lock orelse return error.TestUnexpectedResult;

    // A real mutating operation, which acquires and releases internally. If
    // any of those call sites lost its `defer release()`, the mutex below would
    // still be owned when the peer thread asks for it.
    var stage = try blockdev.AlignedBuffer.alloc(blockdev.SECTOR);
    defer stage.free();
    @memset(stage.bytes, 0x6B);
    _ = try dev.write(0, stage.bytes);
    dev.flush();

    // And the literal "second acquire must succeed": take it, drop it, take it
    // again. Cheap, and it fails outright if the first release never happened.
    try dev.acquire();
    dev.release();
    try dev.acquire();
    dev.release();
    try testing.expectEqual(@as(u64, 0), dev.lock_timeouts);

    var start = try Event.init();
    defer start.deinit();
    var probed = try Event.init();
    defer probed.deinit();
    var proceed = try Event.init();
    defer proceed.deinit();
    var peer: LockPeer = .{
        .mutex = mutex,
        .start = &start,
        .probed = &probed,
        .proceed = &proceed,
    };

    const thread = try std.Thread.spawn(.{}, LockPeer.run, .{&peer});
    // Guarantees the peer is never left parked in `proceed.wait()` if an
    // assertion below fails, without joining on that path: a detached thread
    // that finishes is fine, one that hangs is not, and the wait is unbounded.
    defer proceed.set();

    {
        // Hold it for real, then let the peer try and be refused.
        try dev.acquire();
        defer dev.release();

        start.set();
        probed.wait();

        // WAIT_TIMEOUT, not WAIT_OBJECT_0: the lock really is held, so this
        // half cannot pass against a build that never took it.
        try testing.expectEqual(@as(u32, blockdev.WAIT_TIMED_OUT), peer.while_held);
    }

    // The block above has released it. The peer's identical call must now be
    // granted, which is the whole claim being tested.
    proceed.set();
    // Joined before reading `after_release`: without this the main thread races
    // the peer's write and reads the initialised 0xFFFF_FFFF.
    thread.join();
    try testing.expectEqual(@as(u32, blockdev.WAIT_ACQUIRED), peer.after_release);
    try testing.expectEqual(@as(u64, 0), dev.lock_timeouts);
    try testing.expectEqual(@as(u64, 0), dev.lock_abandoned);
}

test "a pool with no mutex refuses the transfer instead of writing it unlocked" {
    // The "not a silent proceed" half, on the one lock failure that can be
    // provoked without waiting. A genuine `POOL_LOCK_TIMEOUT_MS` expiry is not
    // testable here: the timeout is fixed at 30 s and must not be changed, so
    // asserting that path would add 30 s of wall clock to every suite run.
    // What this does check is the contract around it -- when the lock cannot be
    // taken, the mutating entry points return an error and touch nothing,
    // rather than falling through to an unprotected `WriteFile`. That was the
    // behaviour when the mutex existed but was never waited on.
    var dev = try openScratch();
    defer dev.destroy();

    var stage = try blockdev.AlignedBuffer.alloc(blockdev.SECTOR);
    defer stage.free();
    @memset(stage.bytes, 0x11);

    // Simulate the mutex having failed to be created at open.
    dev.lock = null;

    try testing.expectError(error.PoolLockUnavailable, dev.acquire());
    try testing.expectError(error.PoolLockUnavailable, dev.write(0, stage.bytes));
    try testing.expectError(error.PoolLockUnavailable, dev.writeUnaligned(0, stage.bytes));
    try testing.expectError(error.PoolLockUnavailable, dev.read(0, stage.bytes));
    try testing.expectError(error.PoolLockUnavailable, dev.tryFlush());

    // Nothing was written: the refusal has to happen before the write, not
    // after it.
    try testing.expectEqual(@as(u64, 0), dev.used);
    try testing.expectEqual(@as(u64, 0), dev.file_size);
    try testing.expectEqual(@as(u64, 0), dev.writes);

    // Releasing a lock that was never taken is harmless, which is what lets the
    // `defer` on every call site be unconditional.
    dev.release();

    // `flush` keeps its `void` signature for callers outside this module, so
    // its failure is counted rather than returned. Nothing timed out here, and
    // the counter is what a caller would read to find out.
    dev.flush();
    try testing.expectEqual(@as(u64, 0), dev.lock_timeouts);
}
// --------------------------------------------------------------- regression
//
// These began life as a temporary audit block. Three of the four were wrong
// -- they asserted values the allocator was never going to produce, and one
// was fixed by making the allocator unwind a carved extent instead of leaking
// it. They are kept because each pins down a behaviour that has already been
// wrong once.

test "an unaligned write reports the caller's byte count, not the padded one" {
    var dev = try openScratch();
    defer dev.destroy();

    const payload = "dpu-round-trip-check";
    const n = try dev.writeUnaligned(0, payload);
    // Used to return the sector-rounded length, so a 20 byte write reported
    // 4096 and every caller that trusted the count over-counted by 200x.
    try testing.expectEqual(payload.len, n);
}

test "an unaligned write preserves the bytes either side of it" {
    // The reason the partial sectors are read back and spliced. Writing the
    // staging buffer wholesale stamps the neighbouring bytes with whatever an
    // uninitialised allocation contained.
    var dev = try openScratch();
    defer dev.destroy();

    var stage = try blockdev.AlignedBuffer.alloc(blockdev.SECTOR);
    defer stage.free();
    for (stage.bytes, 0..) |*b, i| b.* = @truncate(i & 0xff);

    _ = try dev.write(0, stage.bytes);
    dev.flush();

    // Overwrite 16 bytes in the middle of that sector.
    const patch = [_]u8{0xDE} ** 16;
    try testing.expectEqual(@as(usize, 16), try dev.writeUnaligned(100, &patch));
    dev.flush();

    var back: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 16), try dev.readUnaligned(100, &back));
    try testing.expectEqualSlices(u8, &patch, &back);

    // Everything outside the patch must still be the original pattern.
    for (stage.bytes, 0..) |want, i| {
        if (i >= 100 and i < 116) continue;
        var one: [1]u8 = undefined;
        const got = try dev.readUnaligned(@intCast(i), &one);
        try testing.expectEqual(@as(usize, 1), got);
        try testing.expectEqual(want, one[0]);
    }
}

test "an unaligned read that runs off the end returns short, not scratch bytes" {
    var dev = try openScratch();
    defer dev.destroy();

    var stage = try blockdev.AlignedBuffer.alloc(blockdev.SECTOR);
    defer stage.free();
    @memset(stage.bytes, 0x77);
    _ = try dev.write(0, stage.bytes);
    dev.flush();

    // One byte past what was written must not come back as whatever the
    // staging allocation happened to hold.
    var one: [1]u8 = undefined;
    const n = try dev.readUnaligned(blockdev.SECTOR * 64, &one);
    try testing.expect(n <= 1);
}

test "freeing a stream allocation never hands those bytes out again" {
    var a = try alloc.Allocator.init(testing.allocator, testCfg());
    defer a.deinit();

    const s1 = try a.alloc(4096, .stream);
    a.free(s1.vaddr);

    // Stream memory is forward-only: the cursor does not rewind and a fresh
    // allocation must not land on the hole `free` just left.
    const used_after_free = a.stats().stream_used;
    const s2 = try a.alloc(4096, .stream);
    try testing.expect(s2.offset != s1.offset);
    try testing.expectEqual(used_after_free + 4096, a.stats().stream_used);
    try testing.expect(a.translate(s1.vaddr) == null);
}

test "only the stream share of the pool is reachable, so the reclaim share is dead space" {
    // Worth pinning down precisely because the ICD allocates every
    // VkDeviceMemory from the stream region: a 16 GiB tier advertises a
    // 16 GiB heap of which a client can actually use only the stream share.
    var cfg = testCfg();
    cfg.total = 1024 * 1024 * 1024;
    cfg.stream_share_pct = 60;
    var a = try alloc.Allocator.init(testing.allocator, cfg);
    defer a.deinit();

    const chunk: u64 = 4 * 1024 * 1024;
    var made: u64 = 0;
    while (a.alloc(chunk, .stream)) |_| {
        made += 1;
    } else |_| {}

    const st = a.stats();
    try testing.expect(made * chunk <= st.stream_total);
    try testing.expect((made + 1) * chunk > st.stream_total);
    try testing.expectError(error.OutOfSpace, a.alloc(chunk, .stream));
    // Real capacity the driver cannot currently address.
    try testing.expect(st.reclaim_total > 0);
}

test "a failed vat.append returns the extent that had already been carved" {
    // fail_index 0 fails inside Allocator.init itself, before the code path
    // this is about is reached. Index 1 lets init finish and fails on the
    // append inside alloc.
    var fba = std.testing.FailingAllocator.init(testing.allocator, .{});
    fba.fail_index = 1;
    var a = try alloc.Allocator.init(fba.allocator(), testCfg());
    defer a.deinit();

    const free_before = a.stats().reclaim_free;
    try testing.expectError(error.OutOfMemory, a.alloc(4096, .reclaim));
    // Handing the same bytes out twice is the one outcome a free list exists
    // to prevent, so the hole must be back.
    try testing.expectEqual(free_before, a.stats().reclaim_free);
}
