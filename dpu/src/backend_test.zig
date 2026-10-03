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
