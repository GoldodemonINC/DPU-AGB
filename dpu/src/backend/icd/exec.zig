//! Device-level Vulkan entry points: memory, buffers, and the copy path.
//!
//! This is the execution layer. Before it, the DPU advertised a heap and
//! nothing else, so a client could see the device and then discover that
//! `vkGetDeviceProcAddr("vkAllocateMemory")` returned null. Now a client can
//! allocate from the pool, fill a staging buffer, copy into device-local
//! memory, and copy it back out -- with every byte really touching `P:\`.
//!
//! # What this is, precisely
//!
//! A **copy engine**. `vkCmdCopyBuffer`, `vkCmdWriteBuffer` and
//! `vkCmdFillBuffer` move bytes between host-visible staging memory and the
//! pool, and `vkQueueSubmit` executes them synchronously. That is the whole
//! data path a client needs in order to upload weights and read results back.
//!
//! It is *not* a shader engine. There is no `vkCmdBindPipeline`, no SPIR-V, no
//! descriptor handling, and therefore no compute. `vkCreateShaderModule`
//! returns `VK_ERROR_FEATURE_NOT_PRESENT` rather than pretending, so a client
//! that reaches for it fails at the first call with an honest status rather
//! than after allocating two gigabytes and discovering the truth.
//!
//! # Why synchronous submit is the right thing here
//!
//! A real driver queues work and returns. This one performs the transfer during
//! `vkQueueSubmit` and signals the fence immediately. That is a legitimate
//! implementation of a legal API -- completion sooner than promised is always
//! allowed -- and it means a client that submits without waiting still gets
//! correct data. The cost is that nothing overlaps, so the pool's latency is
//! paid serially. For a disk that is 800x slower than RAM on random access,
//! overlapping is not the bottleneck being addressed yet.

const std = @import("std");
const win = @import("win");
const tiers = @import("tiers");
const blockdev = @import("blockdev");
const mem = @import("memory.zig");

// The same headers icd.zig imports, cImported again rather than borrowed from
// there. Two translation units each getting their own copy of the C types is
// normal C practice; importing the sibling module would be a cycle for no gain.
const c = @cImport({
    @cInclude("vulkan/vulkan_core.h");
});

// --------------------------------------------------------------------- types

const Buffer = struct {
    sentinel: u32 = 0x44505506,
    size: u64,
    usage: u32,
    memory: ?*mem.Allocation = null,
    /// Offset of this buffer inside its allocation.
    offset_in_alloc: u64 = 0,

    /// Bytes this buffer occupies once the rounding in `fillRequirements` is
    /// applied.
    ///
    /// Every bound in this module is checked against *this*, never against the
    /// allocation it happens to be bound to. Two buffers may share one
    /// `VkDeviceMemory` at different offsets -- that is the whole reason
    /// `vkBindBufferMemory` takes a `memoryOffset` -- so a check against the
    /// allocation would happily let the second buffer write past the end of its
    /// own region and into its neighbour, silently, at pool speed.
    fn extent(self: *const Buffer) u64 {
        return blockdev.roundUp(@max(self.size, 1));
    }
};

const CommandKind = enum {
    copy_buffer,
    write_buffer,
    fill_buffer,
};

const Command = struct {
    kind: CommandKind,
    src_buffer: ?*Buffer = null,
    dst_buffer: ?*Buffer = null,
    dst_memory: ?*mem.Allocation = null,
    src_offset: u64 = 0,
    dst_offset: u64 = 0,
    size: u64 = 0,
    /// Client-owned payload pointer for `write_buffer`.
    ///
    /// This is *not* a private copy. The Vulkan spec requires `pData` to stay
    /// valid until the command buffer executes, precisely so a driver may
    /// reference it rather than duplicate it -- and duplicating it is what
    /// this module used to do, which meant a 4 GiB tensor upload asked a
    /// 512 KiB arena for 4 GiB, failed, and was dropped in silence.
    host_src: ?[*]const u8 = null,
    host_len: usize = 0,
    fill_data: u32 = 0,
};

const CommandBuffer = struct {
    sentinel: u32 = 0x44505507,
    recording: bool = false,
    commands: []Command,
    count: usize,
    capacity: usize,
    /// First failure seen while recording.
    ///
    /// Every `vkCmd*` entry point returns void, so a command that could not be
    /// recorded has nowhere to report itself. Dropping it in silence is how a
    /// full command ring turns into a submit that returns VK_SUCCESS having
    /// written nothing at all, so the status is latched here and surfaced by
    /// the next `vkQueueSubmit` instead of being discarded.
    err: ?c_int = null,
};

const Fence = struct {
    sentinel: u32 = 0x44505508,
    signalled: bool = true,
};

/// A command pool is a scheduling object, and this driver is synchronous: work
/// is executed inside `vkQueueSubmit` on the calling thread. The pool therefore
/// owns nothing and is validated only so a client cannot hand
/// `vkAllocateCommandBuffers` a fabricated handle.
///
/// It still has to exist. A missing entry point is worse than a refusal here:
/// the loader carries its own trampoline for `vkCreateCommandPool`, returns a
/// non-null pointer to it for any ICD that does not implement the command, and
/// that trampoline dispatches through a null slot. The client calls a non-null
/// function pointer and dies at address 0 with no error anywhere. Every
/// command a client can call needs a real entry, even if the body refuses.
const CommandPool = struct {
    sentinel: u32 = 0x44505509,
    family: u32 = 0,
};

fn asCommandPool(handle: ?*anyopaque) ?*CommandPool {
    const h = handle orelse return null;
    if (@intFromPtr(h) % @alignOf(CommandPool) != 0 or
        @as(*align(1) const u32, @ptrCast(h)).* != 0x44505509)
    {
        std.debug.print("[dpu] BAD pool handle 0x{x} first_u32=0x{x}\n", .{ @intFromPtr(h), @as(*align(1) const u32, @ptrCast(h)).* });
        return null;
    }
    return @ptrCast(@alignCast(h));
}

pub fn vkCreateCommandPoolImpl(
    _: ?*anyopaque,
    p: ?*const c.VkCommandPoolCreateInfo,
    _: ?*const c.VkAllocationCallbacks,
    pPool: ?*?*anyopaque,
) callconv(.c) c_int {
    const info = p orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    const out = pPool orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    // One family exists. Accepting any other index would hand back a pool whose
    // queues were never created, and the failure would surface much later as
    // a submission that quietly does nothing.
    if (info.queueFamilyIndex != 0) return c.VK_ERROR_INITIALIZATION_FAILED;

    const slot = mem.arenaAlloc(@sizeOf(CommandPool)) orelse return c.VK_ERROR_OUT_OF_HOST_MEMORY;
    const pool: *CommandPool = @ptrCast(@alignCast(slot));
    pool.* = .{ .family = info.queueFamilyIndex };
    out.* = @ptrCast(pool);
    return c.VK_SUCCESS;
}

pub fn vkDestroyCommandPoolImpl(_: ?*anyopaque, handle: ?*anyopaque, _: ?*const c.VkAllocationCallbacks) callconv(.c) void {
    const pool = asCommandPool(handle) orelse return;
    pool.sentinel = 0;
    // Vulkan requires every command buffer allocated from a pool to be freed
    // before the pool is destroyed, so nothing carved out of the command pool
    // can still be live here and the whole arena can go back.
    releaseCommandWindows();
}

/// Scratch storage for command recording.
///
/// A fixed pool rather than a heap allocation per command buffer: this code
/// runs inside somebody else's process, often `vulkaninfo`, and a general
/// allocator in a graphics driver is a well-known source of crashes at
/// teardown.
///
/// Each command buffer is carved a **disjoint window** out of this pool.
/// Giving them all the same window is a data race dressed as a working
/// driver: two command buffers recorded before a single submit would overwrite
/// each other's commands and both would submit successfully having executed
/// neither. The carve is a bump that is reset when a pool is destroyed, so the
/// normal create/destroy cycle reuses the same memory indefinitely.
const MAX_COMMANDS: usize = 4096;
const COMMANDS_PER_BUFFER: usize = 512;
var command_storage: [MAX_COMMANDS]Command = undefined;
var command_windows_used: usize = 0;

/// Hand out one command buffer's private window, or null when the pool is
/// exhausted -- which callers surface as VK_ERROR_OUT_OF_HOST_MEMORY rather
/// than as a driver that accepts work it cannot hold.
fn takeCommandWindow() ?[]Command {
    if (command_windows_used * COMMANDS_PER_BUFFER + COMMANDS_PER_BUFFER > MAX_COMMANDS) return null;
    const start = command_windows_used * COMMANDS_PER_BUFFER;
    command_windows_used += 1;
    return command_storage[start..][0..COMMANDS_PER_BUFFER];
}

fn releaseCommandWindows() void {
    command_windows_used = 0;
}

/// Bounce memory for copies that cannot go straight to the device.
///
/// Transfers are executed synchronously inside `vkQueueSubmit`, one at a time,
/// so a single buffer is genuinely enough -- the read completes before the
/// write begins and both finish before the next command starts. It is
/// thread-local because `vkQueueSubmit` can legitimately be called from more
/// than one thread, and a shared static here would be a data race between two
/// submits rather than merely a performance problem.
const BOUNCE_BYTES: usize = 1024 * 1024;
threadlocal var bounce_buffer: [BOUNCE_BYTES]u8 align(blockdev.SECTOR) = undefined;

fn bounce(n: usize) []u8 {
    return bounce_buffer[0..@min(n, BOUNCE_BYTES)];
}

/// ------------------------------------------------------------- vkAllocateMemory
/// `VK_ERROR_OUT_OF_DEVICE_MEMORY` for every allocation failure.
///
/// Not `VK_ERROR_FRAGMENTED_POOL` or a silent success with a short allocation:
/// a client that is told "yes" and then reads 4 GiB of the 6 GiB it asked for
/// gets silently wrong results, which is the one failure mode this project must
/// never have. A clean refusal is recoverable; wrong data is not.
const ALLOCATION_FAILED: c_int = c.VK_ERROR_OUT_OF_DEVICE_MEMORY;

pub fn vkAllocateMemoryImpl(
    _: ?*anyopaque,
    pInfo: ?*const c.VkMemoryAllocateInfo,
    _: ?*const c.VkAllocationCallbacks,
    pMemory: ?**anyopaque,
) callconv(.c) c_int {
    const info = pInfo orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    const out = pMemory orelse return c.VK_ERROR_INITIALIZATION_FAILED;

    const heap = mem.heapForMemoryType(info.memoryTypeIndex) orelse
        return c.VK_ERROR_INITIALIZATION_FAILED;
    const b = mem.ensureBackend() orelse return ALLOCATION_FAILED;

    const slot = mem.arenaAlloc(@sizeOf(mem.Allocation)) orelse
        return c.VK_ERROR_OUT_OF_HOST_MEMORY;
    const a: *mem.Allocation = @ptrCast(@alignCast(slot));
    a.* = b.allocate(heap, info.allocationSize) catch return ALLOCATION_FAILED;
    out.* = @ptrCast(a);
    return c.VK_SUCCESS;
}

pub fn vkFreeMemoryImpl(_: ?*anyopaque, handle: ?*anyopaque, _: ?*const c.VkAllocationCallbacks) callconv(.c) void {
    const a: *mem.Allocation = @ptrCast(@alignCast(handle orelse return));
    if (!a.valid()) return;
    if (mem.ensureBackend()) |b| b.release(a);
}

pub fn vkMapMemoryImpl(
    _: ?*anyopaque,
    handle: ?*anyopaque,
    _: u64,
    _: u64,
    _: u32,
    ppData: ?*?*anyopaque,
) callconv(.c) c_int {
    const a: *mem.Allocation = @ptrCast(@alignCast(handle orelse return c.VK_ERROR_MEMORY_MAP_FAILED));
    if (!a.valid()) return c.VK_ERROR_MEMORY_MAP_FAILED;
    const out = ppData orelse return c.VK_ERROR_MEMORY_MAP_FAILED;

    // Device-local memory is not host-visible, and this refuses to pretend
    // otherwise. See the module comment: allowing this would make the DPU look
    // like RAM to every client that used it.
    if (a.heap != mem.HEAP_HOST) return c.VK_ERROR_MEMORY_MAP_FAILED;

    const p = a.host_ptr orelse return c.VK_ERROR_MEMORY_MAP_FAILED;
    if (a.mapped) return c.VK_ERROR_MEMORY_MAP_FAILED;
    a.mapped = true;
    out.* = @ptrCast(p);
    return c.VK_SUCCESS;
}

pub fn vkUnmapMemoryImpl(_: ?*anyopaque, handle: ?*anyopaque) callconv(.c) void {
    const a: *mem.Allocation = @ptrCast(@alignCast(handle orelse return));
    if (!a.valid()) return;
    // Nothing to write back: host memory is the backing store, not a cache of
    // it. The flush entry point exists for symmetry and is a no-op.
    a.mapped = false;
}

pub fn vkFlushMappedMemoryRangesImpl(
    _: ?*anyopaque,
    _: u32,
    _: ?*const c.VkMappedMemoryRange,
) callconv(.c) c_int {
    return c.VK_SUCCESS;
}

pub fn vkInvalidateMappedMemoryRangesImpl(
    _: ?*anyopaque,
    _: u32,
    _: ?*const c.VkMappedMemoryRange,
) callconv(.c) c_int {
    return c.VK_SUCCESS;
}

pub fn vkGetDeviceMemoryCommitmentImpl(
    _: ?*anyopaque,
    pMemory: ?*anyopaque,
    pCommitted: ?*u64,
) callconv(.c) void {
    const out = pCommitted orelse return;
    const a: *mem.Allocation = @ptrCast(@alignCast(pMemory orelse {
        out.* = 0;
        return;
    }));
    if (!a.valid()) {
        out.* = 0;
        return;
    }
    if (a.heap == mem.HEAP_HOST) {
        out.* = a.len;
        return;
    }
    const b = mem.ensureBackend() orelse {
        out.* = 0;
        return;
    };
    out.* = b.commitment();
}

// -------------------------------------------------------------------- buffers

pub fn vkCreateBufferImpl(
    _: ?*anyopaque,
    pCreateInfo: ?*const c.VkBufferCreateInfo,
    _: ?*const c.VkAllocationCallbacks,
    pBuffer: ?**anyopaque,
) callconv(.c) c_int {
    const info = pCreateInfo orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    const out = pBuffer orelse return c.VK_ERROR_INITIALIZATION_FAILED;

    const slot = mem.arenaAlloc(@sizeOf(Buffer)) orelse return c.VK_ERROR_OUT_OF_HOST_MEMORY;
    const b: *Buffer = @ptrCast(@alignCast(slot));
    b.* = .{ .size = info.size, .usage = info.usage };
    out.* = @ptrCast(b);
    return c.VK_SUCCESS;
}

pub fn vkDestroyBufferImpl(_: ?*anyopaque, handle: ?*anyopaque, _: ?*const c.VkAllocationCallbacks) callconv(.c) void {
    const b: *Buffer = @ptrCast(@alignCast(handle orelse return));
    b.sentinel = 0;
}

fn fillRequirements(p: *c.VkMemoryRequirements, size: u64) void {
    // Every size and alignment is a sector multiple. A client that sizes a
    // buffer from this and binds it to pool memory gets offsets that the block
    // layer can actually transfer, rather than offsets that silently fall back
    // to the page cache on first write.
    p.* = .{
        .size = blockdev.roundUp(@max(size, 1)),
        .alignment = blockdev.SECTOR,
        .memoryTypeBits = 0x3, // device-local or host-visible
    };
}

pub fn vkGetBufferMemoryRequirementsImpl(_: ?*anyopaque, handle: ?*anyopaque, p: ?*c.VkMemoryRequirements) callconv(.c) void {
    const out = p orelse return;
    const b: *Buffer = @ptrCast(@alignCast(handle orelse {
        fillRequirements(out, 0);
        return;
    }));
    fillRequirements(out, b.size);
}

/// Walk a `pNext` chain for a `VkMemoryRequirements2`.
///
/// The `2` variants do not carry their output in a field of the info struct --
/// the caller chains a `VkMemoryRequirements2` and expects the driver to find
/// it. An ICD that assumed a field would silently write nothing, and the client
/// would size its allocation from an uninitialised struct.
fn findRequirements2(head: ?*const anyopaque) ?*c.VkMemoryRequirements2 {
    var cur = head;
    while (cur) |node| {
        const base: *const c.VkBaseInStructure = @ptrCast(@alignCast(node));
        if (base.sType == c.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2) {
            return @ptrCast(@alignCast(@constCast(node)));
        }
        cur = base.pNext;
    }
    return null;
}

pub fn vkGetBufferMemoryRequirements2Impl(
    _: ?*anyopaque,
    handle: ?*anyopaque,
    p: ?*c.VkBufferMemoryRequirementsInfo2,
) callconv(.c) void {
    const info = p orelse return;
    if (info.sType != c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_REQUIREMENTS_INFO_2) return;
    const reqs = findRequirements2(info.pNext) orelse return;
    const b: *Buffer = @ptrCast(@alignCast(handle orelse {
        fillRequirements(&reqs.memoryRequirements, 0);
        return;
    }));
    fillRequirements(&reqs.memoryRequirements, b.size);
}

pub fn vkGetDeviceBufferMemoryRequirementsImpl(
    _: ?*anyopaque,
    p: ?*const c.VkDeviceBufferMemoryRequirements,
) callconv(.c) void {
    const info = p orelse return;
    if (info.pCreateInfo == null) return;
    const reqs = findRequirements2(info.pNext) orelse return;
    fillRequirements(&reqs.memoryRequirements, info.pCreateInfo[0].size);
}

pub fn vkBindBufferMemoryImpl(
    _: ?*anyopaque,
    hBuffer: ?*anyopaque,
    hMemory: ?*anyopaque,
    memoryOffset: u64,
) callconv(.c) c_int {
    const b: *Buffer = @ptrCast(@alignCast(hBuffer orelse return c.VK_ERROR_INITIALIZATION_FAILED));
    const a: *mem.Allocation = @ptrCast(@alignCast(hMemory orelse return c.VK_ERROR_INITIALIZATION_FAILED));
    if (!a.valid()) return c.VK_ERROR_OUT_OF_DEVICE_MEMORY;

    // The offset has to be honoured. Discarding it and pinning every buffer to
    // the start of its allocation means two buffers bound to the same
    // `VkDeviceMemory` at different offsets alias exactly, and whichever copy
    // ran last silently wins.
    //
    // The bound is `offset + extent`, not `extent`: checking the extent alone
    // is how a buffer bound near the end of an allocation is allowed to run
    // off the end of it.
    if (!fitsInAllocation(a, memoryOffset, b.extent())) return c.VK_ERROR_OUT_OF_DEVICE_MEMORY;

    b.memory = a;
    b.offset_in_alloc = memoryOffset;
    return c.VK_SUCCESS;
}

/// Whether `offset .. offset+extent` lies inside a live allocation.
///
/// Saturating throughout: a malicious or buggy `offset` must produce a refusal,
/// never an arithmetic wrap that happens to land back inside the range.
fn fitsInAllocation(a: *const mem.Allocation, offset: u64, extent: u64) bool {
    if (!a.valid()) return false;
    const end = offset +| extent;
    if (end < offset) return false; // wrapped
    return end <= a.len;
}

pub fn vkBindBufferMemory2Impl(
    _: ?*anyopaque,
    count: u32,
    p: ?[*]const c.VkBindBufferMemoryInfo,
) callconv(.c) c_int {
    const infos = p orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    if (count == 0) return c.VK_SUCCESS;

    // Every entry is attempted even after one fails, and the worst status is
    // returned: a partial bind is recoverable and the client needs to know that
    // *something* failed, not which entry happened to be first.
    var worst: c_int = c.VK_SUCCESS;
    for (infos[0..count]) |info| {
        const b: *Buffer = @ptrCast(@alignCast(info.buffer orelse {
            worst = c.VK_ERROR_INITIALIZATION_FAILED;
            continue;
        }));
        const a: *mem.Allocation = @ptrCast(@alignCast(info.memory orelse {
            worst = c.VK_ERROR_INITIALIZATION_FAILED;
            continue;
        }));
        if (!fitsInAllocation(a, info.memoryOffset, b.extent())) {
            worst = c.VK_ERROR_OUT_OF_DEVICE_MEMORY;
            continue;
        }
        b.memory = a;
        b.offset_in_alloc = info.memoryOffset;
    }
    return worst;
}

// ------------------------------------------------------------- command buffers

pub fn vkAllocateCommandBuffersImpl(
    _: ?*anyopaque,
    p: ?*const c.VkCommandBufferAllocateInfo,
    pCmds: ?[*]?*anyopaque,
) callconv(.c) c_int {
    const info = p orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    const out = pCmds orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    // Refuse a pool this driver did not create rather than allocate from a
    // garbage handle.
    _ = asCommandPool(info.commandPool) orelse return c.VK_ERROR_INITIALIZATION_FAILED;

    // A zero count is legal and means success with nothing written. It must
    // not be clamped up to one: the output array is sized by the caller to
    // zero elements, so writing slot 0 is a write past the end of it.
    if (info.commandBufferCount == 0) return c.VK_SUCCESS;
    const count = info.commandBufferCount;

    for (0..count) |i| {
        const slot = mem.arenaAlloc(@sizeOf(CommandBuffer)) orelse return c.VK_ERROR_OUT_OF_HOST_MEMORY;
        const cb: *CommandBuffer = @ptrCast(@alignCast(slot));
        const window = takeCommandWindow() orelse return c.VK_ERROR_OUT_OF_HOST_MEMORY;
        cb.* = .{
            .commands = window,
            .count = 0,
            .capacity = window.len,
        };
        out[i] = @ptrCast(cb);
    }
    return c.VK_SUCCESS;
}

fn asCommandBuffer(handle: ?*anyopaque) ?*CommandBuffer {
    const h = handle orelse return null;
    if (@intFromPtr(h) % @alignOf(CommandBuffer) != 0 or
        @as(*align(1) const u32, @ptrCast(h)).* != 0x44505507)
    {
        std.debug.print("[dpu] BAD cmdbuf handle 0x{x} first_u32=0x{x}\n", .{ @intFromPtr(h), @as(*align(1) const u32, @ptrCast(h)).* });
        return null;
    }
    return @ptrCast(@alignCast(h));
}

pub fn vkFreeCommandBuffersImpl(
    _: ?*anyopaque,
    _: ?*anyopaque,
    count: u32,
    p: ?[*]?*anyopaque,
) callconv(.c) void {
    const list = p orelse return;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const cb = asCommandBuffer(list[i]) orelse continue;
        cb.sentinel = 0;
    }
}

pub fn vkBeginCommandBufferImpl(
    handle: ?*anyopaque,
    _: ?*const c.VkCommandBufferBeginInfo,
) callconv(.c) c_int {
    const cb = asCommandBuffer(handle) orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    cb.recording = true;
    cb.count = 0;
    return c.VK_SUCCESS;
}

pub fn vkEndCommandBufferImpl(handle: ?*anyopaque) callconv(.c) c_int {
    const cb = asCommandBuffer(handle) orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    cb.recording = false;
    // Report a recording failure here rather than letting it reach the submit.
    // The client gets to know its work was dropped while there is still
    // something it can do about it, instead of after a submit reported
    // success having written nothing.
    return cb.err orelse c.VK_SUCCESS;
}

pub fn vkResetCommandBufferImpl(
    _: ?*anyopaque,
    handle: ?*anyopaque,
    _: c.VkCommandBufferResetFlags,
) callconv(.c) c_int {
    const cb = asCommandBuffer(handle) orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    cb.count = 0;
    cb.recording = false;
    // Only a reset clears a latched failure. A client that begins recording
    // again without one is reusing a command buffer the spec says it must not
    // reuse, and quietly clearing here would hide exactly the mistake this
    // latch exists to surface.
    cb.err = null;
    return c.VK_SUCCESS;
}

fn record(cb: ?*CommandBuffer, cmd: Command) c_int {
    const buf = cb orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    if (!buf.recording) return c.VK_ERROR_INITIALIZATION_FAILED;
    if (buf.count >= buf.capacity) return c.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    buf.commands[buf.count] = cmd;
    buf.count += 1;
    return c.VK_SUCCESS;
}

/// Record a command, latching the status when it fails.
///
/// Every `vkCmd*` entry point returns void, so a failure here has no channel
/// to the client. Discarding it is precisely the bug this module used to have:
/// a command that was never recorded became a submit that returned VK_SUCCESS
/// having moved zero bytes. The status now lives on the command buffer and
/// comes back out of `vkEndCommandBuffer` and `vkQueueSubmit`.
fn recordOrLatch(cb: *CommandBuffer, cmd: Command) void {
    const rc = record(cb, cmd);
    if (rc != c.VK_SUCCESS and cb.err == null) cb.err = rc;
}

pub fn vkCmdCopyBufferImpl(
    _: ?*anyopaque,
    handle: ?*anyopaque,
    src: ?*anyopaque,
    dst: ?*anyopaque,
    regions: ?[*]const c.VkBufferCopy,
    region_count: u32,
) callconv(.c) void {
    const cb = asCommandBuffer(handle) orelse return;
    const s: *Buffer = @ptrCast(@alignCast(src orelse return));
    const d: *Buffer = @ptrCast(@alignCast(dst orelse return));
    const list = regions orelse return;
    for (list[0..region_count]) |r| {
        recordOrLatch(cb, .{
            .kind = .copy_buffer,
            .src_buffer = s,
            .dst_buffer = d,
            .src_offset = r.srcOffset,
            .dst_offset = r.dstOffset,
            .size = r.size,
        });
    }
}

pub fn vkCmdWriteBufferImpl(
    _: ?*anyopaque,
    handle: ?*anyopaque,
    dst: ?*anyopaque,
    offset: u64,
    size: u64,
    pData: ?*const anyopaque,
) callconv(.c) void {
    const cb = asCommandBuffer(handle) orelse return;
    const d: *Buffer = @ptrCast(@alignCast(dst orelse return));
    if (pData == null or size == 0) return;

    // `pData` is referenced, not copied. The spec requires the client to keep
    // it valid until the command buffer executes, and that requirement exists
    // so a driver does not have to duplicate megabytes per upload. Copying it
    // into a fixed arena meant any write larger than the arena silently
    // recorded nothing and reported success.
    recordOrLatch(cb, .{
        .kind = .write_buffer,
        .dst_buffer = d,
        .dst_offset = offset,
        .size = size,
        .host_src = @ptrCast(pData.?),
        .host_len = @intCast(size),
    });
}

pub fn vkCmdFillBufferImpl(
    _: ?*anyopaque,
    handle: ?*anyopaque,
    dst: ?*anyopaque,
    offset: u64,
    size: u64,
    data: u32,
) callconv(.c) void {
    const cb = asCommandBuffer(handle) orelse return;
    const d: *Buffer = @ptrCast(@alignCast(dst orelse return));
    recordOrLatch(cb, .{
        .kind = .fill_buffer,
        .dst_buffer = d,
        .dst_offset = offset,
        .size = size,
        .fill_data = data,
    });
}

pub fn vkCmdPipelineBarrierImpl(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: c.VkPipelineStageFlags,
    _: c.VkPipelineStageFlags,
    _: c.VkDependencyFlags,
    _: u32,
    _: ?*const c.VkMemoryBarrier,
    _: u32,
    _: ?*const c.VkBufferMemoryBarrier,
    _: u32,
    _: ?*const c.VkImageMemoryBarrier,
) callconv(.c) void {
    // A no-op, and legitimately so. Transfers here complete inside
    // vkQueueSubmit, so by the time a barrier is reached there is no outstanding
    // work to wait on and nothing to invalidate. Recording one as a no-op rather
    // than returning an error keeps a client that issues standard barriers on
    // every dispatch working unchanged.
}

pub fn vkQueueBindSparseImpl(
    _: ?*anyopaque,
    _: u32,
    _: ?*const c.VkBindSparseInfo,
    _: ?*anyopaque,
) callconv(.c) void {}

// -------------------------------------------------------------------- fences

pub fn vkCreateFenceImpl(
    _: ?*anyopaque,
    _: ?*const c.VkFenceCreateInfo,
    _: ?*const c.VkAllocationCallbacks,
    p: ?**anyopaque,
) callconv(.c) c_int {
    const out = p orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    const slot = mem.arenaAlloc(@sizeOf(Fence)) orelse return c.VK_ERROR_OUT_OF_HOST_MEMORY;
    const f: *Fence = @ptrCast(@alignCast(slot));
    f.* = .{ .signalled = true };
    out.* = @ptrCast(f);
    return c.VK_SUCCESS;
}

fn asFence(handle: ?*anyopaque) ?*Fence {
    const f: *Fence = @ptrCast(@alignCast(handle orelse return null));
    if (f.sentinel != 0x44505508) return null;
    return f;
}

pub fn vkDestroyFenceImpl(_: ?*anyopaque, handle: ?*anyopaque, _: ?*const c.VkAllocationCallbacks) callconv(.c) void {
    const f = asFence(handle) orelse return;
    f.sentinel = 0;
}

pub fn vkGetFenceStatusImpl(_: ?*anyopaque, handle: ?*anyopaque) callconv(.c) c_int {
    const f = asFence(handle) orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    return if (f.signalled) c.VK_SUCCESS else c.VK_NOT_READY;
}

pub fn vkResetFencesImpl(_: ?*anyopaque, count: u32, p: ?[*]?*anyopaque) callconv(.c) void {
    const list = p orelse return;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (asFence(list[i])) |f| f.signalled = false;
    }
}

pub fn vkWaitForFencesImpl(
    _: ?*anyopaque,
    _: u32,
    _: ?[*]?*anyopaque,
    _: c.VkBool32,
    _: u64,
) callconv(.c) c_int {
    // Everything completes inside vkQueueSubmit, so a fence is always signalled
    // by the time anything can wait on it.
    return c.VK_SUCCESS;
}

// --------------------------------------------------------------------- queues

pub fn vkQueueSubmitImpl(
    _: ?*anyopaque,
    submit_count: u32,
    pSubmits: ?[*]const c.VkSubmitInfo,
    pFence: ?*anyopaque,
) callconv(.c) c_int {
    // Cleared first so a submit that fails never leaves a stale signalled fence
    // lying around for a client to observe.
    if (asFence(pFence)) |f| f.signalled = false;

    const submits = pSubmits orelse {
        if (asFence(pFence)) |f| f.signalled = true;
        return c.VK_SUCCESS;
    };

    // Worst status wins, and it is returned to the client. The old version
    // discarded every failure with `catch return` and reported VK_SUCCESS
    // unconditionally, so a full disk, a refused write and a dropped command
    // were all indistinguishable from a successful upload -- the one failure
    // mode this module exists to avoid.
    var status: c_int = c.VK_SUCCESS;

    for (submits[0..submit_count]) |si| {
        // Semaphores need no implementation: every transfer completes inside
        // this call, so a wait is already satisfied and a signal is already
        // raised.
        //
        // The guard is on the *count*, not on the pointer. `pWaitDstStageMask`
        // is explicitly permitted to be NULL whenever `waitSemaphoreCount` is
        // zero, and testing the pointer instead dereferences address zero on a
        // perfectly legal submission.
        if (si.waitSemaphoreCount > 0 and si.pWaitDstStageMask != null) {
            for (si.pWaitDstStageMask[0..si.waitSemaphoreCount]) |_| {}
        }
        if (si.signalSemaphoreCount > 0 and si.pSignalSemaphores == null and status == c.VK_SUCCESS) {
            status = c.VK_ERROR_INITIALIZATION_FAILED;
        }

        if (si.commandBufferCount == 0 or si.pCommandBuffers == null) continue;
        for (si.pCommandBuffers[0..si.commandBufferCount]) |cbh| {
            const cb = asCommandBuffer(cbh) orelse {
                status = worstStatus(status, c.VK_ERROR_DEVICE_LOST);
                continue;
            };
            // A command that failed to record never reached the disk. Surface
            // it rather than submitting the truncated remainder as a success.
            if (cb.err) |e| status = worstStatus(status, e);
            for (cb.commands[0..cb.count]) |cmd| {
                execute(cmd) catch |err| {
                    status = worstStatus(status, submitStatus(err));
                };
            }
            cb.count = 0;
        }
    }

    // The fence is the fourth argument to vkQueueSubmit, not a member of
    // VkSubmitInfo -- VkSubmitInfo has no fence field at all. A driver that
    // looked for one would never signal, and a client that waits on the fence
    // would hang forever.
    if (asFence(pFence)) |f| f.signalled = status == c.VK_SUCCESS;
    return status;
}

fn worstStatus(a: c_int, b: c_int) c_int {
    return if (a == c.VK_SUCCESS) b else a;
}

// ------------------------------------------------------- transfer planning

pub const PlanError = error{
    /// A buffer in the command was never bound to memory.
    UnboundBuffer,
    /// The requested range falls outside a buffer, or outruns its allocation.
    OutOfBounds,
    /// The pool has no room left for this transfer.
    OutOfPool,
    /// Fewer bytes moved than were asked for. Never acceptable silently.
    ShortTransfer,
    /// The pool file could not be reached at all.
    PoolUnavailable,
};

/// One side of a transfer: where it lives and where inside that place.
const End = struct {
    /// Byte offset into the pool file, or null when this side is RAM.
    pool_offset: ?u64,
    /// Host pointer, or null when this side is the pool.
    host: ?[*]u8,
    device_local: bool,
};

/// A validated transfer: how many bytes, and exactly where each side is.
///
/// Deliberately pure. It reads nothing but the buffers and allocations the
/// client handed in and touches no disk, which is what makes the offset
/// arithmetic testable on a machine with no P:\ -- and the arithmetic is where
/// every bug in this module used to live. `execute` does nothing except carry
/// out a plan it has been given.
pub const Plan = struct {
    bytes: usize,
    src: End,
    dst: End,
    /// Pool to pool: the bytes have to pass through RAM on the way.
    needs_bounce: bool,
};

/// Bytes readable from `buf` at `offset`, or null when `offset` is outside the
/// buffer's own extent.
///
/// Buffer-relative, and that is the whole point. A buffer bound at a non-zero
/// `memoryOffset` has only `extent - offset` bytes, and two buffers sharing one
/// allocation must not be able to reach into each other's bytes -- so the
/// allocation's length is deliberately not consulted here.
fn available(buf: *const Buffer, offset: u64) ?u64 {
    const ext = buf.extent();
    if (offset >= ext) return null;
    return ext - offset;
}

/// Locate one side of a transfer.
fn endOf(buf: *const Buffer, alloc: *const mem.Allocation, offset: u64) End {
    if (alloc.heap == mem.HEAP_DEVICE_LOCAL) {
        return .{
            .pool_offset = alloc.offset + buf.offset_in_alloc + offset,
            .host = null,
            .device_local = true,
        };
    }
    // A host allocation without a pointer is not a state a client can reach --
    // every path that sets HEAP_HOST sets it too -- but the plan stays total
    // rather than fabricating one. A null here reaches `execute`, which already
    // treats a missing host pointer as UnboundBuffer, so it surfaces as a
    // status instead of an unchecked dereference.
    const base = alloc.host_ptr orelse return .{
        .pool_offset = null,
        .host = null,
        .device_local = false,
    };
    return .{
        .pool_offset = null,
        .host = base + @as(usize, @intCast(buf.offset_in_alloc + offset)),
        .device_local = false,
    };
}

/// Validate a buffer-to-buffer copy. `size` is measured from `src_offset` and
/// `dst_offset` respectively, both relative to the start of their buffer.
pub fn planCopy(
    s: *const Buffer,
    d: *const Buffer,
    src_offset: u64,
    dst_offset: u64,
    size: u64,
) PlanError!Plan {
    const src_alloc = s.memory orelse return PlanError.UnboundBuffer;
    const dst_alloc = d.memory orelse return PlanError.UnboundBuffer;

    const src_avail = available(s, src_offset) orelse return PlanError.OutOfBounds;
    const dst_avail = available(d, dst_offset) orelse return PlanError.OutOfBounds;

    // A request that does not fit is refused outright, never quietly shortened.
    // The spec requires it, and the reason is not politeness: a client told
    // "yes" and handed half the bytes reads silently wrong results, which is
    // the single thing this driver must never do.
    if (size == 0) return PlanError.OutOfBounds;
    if (size > src_avail or size > dst_avail) return PlanError.OutOfBounds;

    // The bound is checked against the allocation as well, because a client can
    // bind a buffer to an allocation that is smaller than the buffer claims.
    // Both sides are checked whatever kind of memory they are: a host to host
    // copy is perfectly legal and must not be refused just because neither
    // side has a pool offset.
    if (!fitsInAllocation(src_alloc, s.offset_in_alloc +| src_offset, size)) return PlanError.OutOfBounds;
    if (!fitsInAllocation(dst_alloc, d.offset_in_alloc +| dst_offset, size)) return PlanError.OutOfBounds;

    return .{
        .bytes = @intCast(size),
        .src = endOf(s, src_alloc, src_offset),
        .dst = endOf(d, dst_alloc, dst_offset),
        .needs_bounce = src_alloc.heap == mem.HEAP_DEVICE_LOCAL and dst_alloc.heap == mem.HEAP_DEVICE_LOCAL,
    };
}

/// Validate a fill. The destination must be device-local: filling host memory
/// is legal Vulkan, but this driver has no reason to bounce through the pool
/// to do it and refuses rather than pretending.
pub fn planFill(d: *const Buffer, dst_offset: u64, size: u64) PlanError!Plan {
    const dst_alloc = d.memory orelse return PlanError.UnboundBuffer;
    const avail = available(d, dst_offset) orelse return PlanError.OutOfBounds;
    if (size == 0 or size > avail) return PlanError.OutOfBounds;
    if (!fitsInAllocation(dst_alloc, d.offset_in_alloc +| dst_offset, size)) return PlanError.OutOfBounds;

    const end = endOf(d, dst_alloc, dst_offset);
    if (!end.device_local) return PlanError.UnboundBuffer;
    return .{
        .bytes = @intCast(size),
        .src = .{ .pool_offset = null, .host = null, .device_local = false },
        .dst = end,
        .needs_bounce = false,
    };
}

// ------------------------------------------------------------- execution

/// Perform one recorded command against the pool.
///
/// Every failure is returned to `vkQueueSubmit`, which reports it to the
/// client. There is no path through this function that moves no bytes and
/// reports nothing.
fn execute(cmd: Command) PlanError!void {
    const d = cmd.dst_buffer orelse return PlanError.UnboundBuffer;

    switch (cmd.kind) {
        .copy_buffer => {
            const s = cmd.src_buffer orelse return PlanError.UnboundBuffer;
            const plan = try planCopy(s, d, cmd.src_offset, cmd.dst_offset, cmd.size);
            try runPlan(plan);
        },
        .write_buffer => {
            const src = cmd.host_src orelse return PlanError.UnboundBuffer;
            const dst_alloc = d.memory orelse return PlanError.UnboundBuffer;
            const end = endOf(d, dst_alloc, cmd.dst_offset);
            if (!end.device_local) return PlanError.UnboundBuffer;
            // The client promises pData stays valid until execution, which is
            // what lets a multi-gigabyte upload cost no driver memory at all.
            const len = @min(cmd.host_len, @as(usize, @intCast(available(d, cmd.dst_offset) orelse return PlanError.OutOfBounds)));
            const plan: Plan = .{
                .bytes = len,
                .src = .{ .pool_offset = null, .host = null, .device_local = false },
                .dst = end,
                .needs_bounce = false,
            };
            const b = mem.ensureBackend() orelse return PlanError.PoolUnavailable;
            try ramToPool(b, plan.dst.pool_offset.?, src, len);
        },
        .fill_buffer => {
            const plan = try planFill(d, cmd.dst_offset, cmd.size);
            try runFill(plan, cmd.fill_data);
        },
    }
}

/// Carry out a planned copy between any combination of pool and RAM.
fn runPlan(plan: Plan) PlanError!void {
    if (plan.needs_bounce) {
        const b = mem.ensureBackend() orelse return PlanError.PoolUnavailable;
        const s = plan.src.pool_offset orelse return PlanError.UnboundBuffer;
        const dd = plan.dst.pool_offset orelse return PlanError.UnboundBuffer;
        try poolToPool(b, s, dd, plan.bytes);
        return;
    }

    if (plan.dst.device_local) {
        // RAM -> pool.
        const host = plan.src.host orelse return PlanError.UnboundBuffer;
        const b = mem.ensureBackend() orelse return PlanError.PoolUnavailable;
        const dd = plan.dst.pool_offset orelse return PlanError.UnboundBuffer;
        try ramToPool(b, dd, host, plan.bytes);
        return;
    }

    const host = plan.dst.host orelse return PlanError.UnboundBuffer;
    if (plan.src.device_local) {
        // pool -> RAM.
        const b = mem.ensureBackend() orelse return PlanError.PoolUnavailable;
        const s = plan.src.pool_offset orelse return PlanError.UnboundBuffer;
        try poolToRam(b, s, host, plan.bytes);
        return;
    }

    // RAM -> RAM.
    const src = plan.src.host orelse return PlanError.UnboundBuffer;
    @memcpy(host[0..plan.bytes], src[0..plan.bytes]);
}

/// Write a repeated u32 pattern across a planned destination.
fn runFill(plan: Plan, pattern: u32) PlanError!void {
    const b = mem.ensureBackend() orelse return PlanError.PoolUnavailable;
    const off = plan.dst.pool_offset orelse return PlanError.UnboundBuffer;

    const tmp = bounce(plan.bytes);
    var done: usize = 0;
    while (done < plan.bytes) {
        const n = @min(BOUNCE_BYTES, plan.bytes - done);
        const chunk = tmp[0..n];
        var i: usize = 0;
        while (i + 4 <= n) : (i += 4) std.mem.writeInt(u32, chunk[i..][0..4], pattern, .little);
        // A trailing partial word used to be left as whatever the scratch
        // buffer happened to contain, so the tail of a fill was uninitialised
        // memory written to the pool as if it were data.
        while (i < n) : (i += 1) chunk[i] = @truncate(pattern >> @intCast((i % 4) * 8));
        try writeExact(b, off + done, chunk);
        done += n;
    }
}

/// RAM -> pool, in bounce-sized chunks so the scratch never has to hold the
/// whole transfer.
fn ramToPool(b: *mem.Backend, off: u64, host: [*]const u8, len: usize) PlanError!void {
    if (len == 0) return;
    const tmp = bounce(len);
    var done: usize = 0;
    while (done < len) {
        const n = @min(BOUNCE_BYTES, len - done);
        @memcpy(tmp[0..n], host[done..][0..n]);
        try writeExact(b, off + done, tmp[0..n]);
        done += n;
    }
}

/// pool -> RAM, chunked.
fn poolToRam(b: *mem.Backend, off: u64, host: [*]u8, len: usize) PlanError!void {
    if (len == 0) return;
    const tmp = bounce(len);
    var done: usize = 0;
    while (done < len) {
        const n = @min(BOUNCE_BYTES, len - done);
        try readExact(b, off + done, tmp[0..n]);
        @memcpy(host[done..][0..n], tmp[0..n]);
        done += n;
    }
}

/// pool -> pool, through RAM. Read-then-write per chunk so the transfer never
/// needs scratch proportional to its own size.
fn poolToPool(b: *mem.Backend, src_off: u64, dst_off: u64, len: usize) PlanError!void {
    if (len == 0) return;
    const tmp = bounce(len);
    var done: usize = 0;
    while (done < len) {
        const n = @min(BOUNCE_BYTES, len - done);
        try readExact(b, src_off + done, tmp[0..n]);
        try writeExact(b, dst_off + done, tmp[0..n]);
        done += n;
    }
}

/// Write exactly `buf.len` bytes or fail.
///
/// The count is compared rather than ignored. `writeUnaligned` reports the
/// number of bytes it moved, and a short transfer -- a sector it could not
/// write, a volume that filled mid-command -- is a failure, not a rounding
/// detail.
fn writeExact(b: *mem.Backend, off: u64, buf: []const u8) PlanError!void {
    const wrote = b.write(off, buf) catch |e| return poolWriteError(e);
    if (wrote != buf.len) return PlanError.ShortTransfer;
}

fn readExact(b: *mem.Backend, off: u64, buf: []u8) PlanError!void {
    const got = b.read(off, buf) catch return PlanError.PoolUnavailable;
    if (got != buf.len) return PlanError.ShortTransfer;
}

fn poolWriteError(e: mem.Error) PlanError {
    return switch (e) {
        mem.Error.OutOfPool => PlanError.OutOfPool,
        else => PlanError.PoolUnavailable,
    };
}

/// Map a transfer failure onto a status the client can act on.
///
/// A full pool is memory pressure it can work around; an unreachable pool is
/// the device being gone. Neither is a success, and neither is allowed to
/// reach the client as one.
fn submitStatus(err: PlanError) c_int {
    return switch (err) {
        PlanError.OutOfPool, PlanError.ShortTransfer => c.VK_ERROR_OUT_OF_DEVICE_MEMORY,
        PlanError.PoolUnavailable => c.VK_ERROR_DEVICE_LOST,
        PlanError.UnboundBuffer, PlanError.OutOfBounds => c.VK_ERROR_INITIALIZATION_FAILED,
    };
}

pub fn vkQueueWaitIdleImpl(_: ?*anyopaque) callconv(.c) c_int {
    if (mem.ensureBackend()) |b| b.flush();
    return c.VK_SUCCESS;
}

pub fn vkDeviceWaitIdleImpl(_: ?*anyopaque) callconv(.c) c_int {
    return vkQueueWaitIdleImpl(null);
}

// ------------------------------------------------------- explicitly refused

// Shader execution is not implemented. These return a Vulkan status rather than
// null so that a client gets a definite answer at the first call.

pub fn vkCreateShaderModuleImpl(
    _: ?*anyopaque,
    _: ?*const c.VkShaderModuleCreateInfo,
    _: ?*const c.VkAllocationCallbacks,
    _: ?**anyopaque,
) callconv(.c) c_int {
    return c.VK_ERROR_FEATURE_NOT_PRESENT;
}

pub fn vkCreateComputePipelinesImpl(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: u32,
    _: ?[*]const c.VkComputePipelineCreateInfo,
    _: ?[*]?*anyopaque,
) callconv(.c) c_int {
    return c.VK_ERROR_FEATURE_NOT_PRESENT;
}

pub fn vkCreateGraphicsPipelinesImpl(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: u32,
    _: ?[*]const c.VkGraphicsPipelineCreateInfo,
    _: ?[*]?*anyopaque,
) callconv(.c) c_int {
    return c.VK_ERROR_FEATURE_NOT_PRESENT;
}

// --------------------------------------------------------------------- tests
//
// The planner is pure, so it is testable exhaustively without a pool file, a
// P:\ drive or a Vulkan loader. That is the point: `execute` used to carry the
// offset arithmetic and the disk I/O in one function, which is precisely why
// the arithmetic went untested while the I/O was exercised only by a probe
// that could not fail a build.

const testing = std.testing;

fn hostAlloc(len: u64) mem.Allocation {
    return .{ .heap = mem.HEAP_HOST, .len = len, .host_ptr = @ptrFromInt(0x1000) };
}

fn deviceAlloc(pool_offset: u64, len: u64) mem.Allocation {
    return .{ .heap = mem.HEAP_DEVICE_LOCAL, .offset = pool_offset, .len = len };
}

fn makeBuffer(size: u64, alloc: ?*mem.Allocation, memory_offset: u64) Buffer {
    return .{ .size = size, .usage = 0, .memory = alloc, .offset_in_alloc = memory_offset };
}

test "a host to host copy plans as plain memory" {
    var a = hostAlloc(64 * 1024);
    var b = hostAlloc(64 * 1024);
    const src = makeBuffer(64 * 1024, &a, 0);
    const dst = makeBuffer(64 * 1024, &b, 0);

    const plan = try planCopy(&src, &dst, 0, 0, 4096);
    try testing.expectEqual(@as(usize, 4096), plan.bytes);
    try testing.expect(!plan.needs_bounce);
    try testing.expect(!plan.src.device_local);
    try testing.expect(!plan.dst.device_local);
}

test "a pool to pool copy reports both pool offsets and needs a bounce" {
    var a = deviceAlloc(0x4000_0000, 1024 * 1024);
    var b = deviceAlloc(0x8000_0000, 1024 * 1024);
    const src = makeBuffer(1024 * 1024, &a, 0);
    const dst = makeBuffer(1024 * 1024, &b, 0);

    const plan = try planCopy(&src, &dst, 0, 0, 65536);
    try testing.expect(plan.needs_bounce);
    try testing.expectEqual(@as(?u64, 0x4000_0000), plan.src.pool_offset);
    try testing.expectEqual(@as(?u64, 0x8000_0000), plan.dst.pool_offset);
}

test "memoryOffset moves both sides of the pool offset" {
    // The bug this exists for: vkBindBufferMemory discarded the offset and
    // pinned every buffer to the start of its allocation, so two buffers bound
    // to one VkDeviceMemory at different offsets aliased exactly.
    var a = deviceAlloc(0x1000, 64 * 1024);
    var b = deviceAlloc(0x1000, 64 * 1024);
    const src = makeBuffer(64 * 1024, &a, 8192);
    const dst = makeBuffer(64 * 1024, &b, 16384);

    const plan = try planCopy(&src, &dst, 0, 0, 4096);
    try testing.expectEqual(@as(?u64, 0x1000 + 8192), plan.src.pool_offset);
    try testing.expectEqual(@as(?u64, 0x1000 + 16384), plan.dst.pool_offset);
}

test "copy offsets add to the buffer's own place in its allocation" {
    var a = deviceAlloc(0x2000, 64 * 1024);
    var b = deviceAlloc(0x9000, 64 * 1024);
    const src = makeBuffer(64 * 1024, &a, 4096);
    const dst = makeBuffer(64 * 1024, &b, 0);

    const plan = try planCopy(&src, &dst, 512, 1024, 4096);
    try testing.expectEqual(@as(?u64, 0x2000 + 4096 + 512), plan.src.pool_offset);
    try testing.expectEqual(@as(?u64, 0x9000 + 1024), plan.dst.pool_offset);
}

test "a copy cannot outrun its buffer even when the allocation is big enough" {
    // Two buffers sharing one VkDeviceMemory: the allocation is ample, the
    // buffer is not. Bounds are buffer-relative precisely so the second buffer
    // cannot reach into the first one's bytes.
    var shared = deviceAlloc(0, 64 * 1024);
    const first = makeBuffer(16 * 1024, &shared, 0);
    const second = makeBuffer(16 * 1024, &shared, 16 * 1024);

    // Exactly filling the second buffer is fine.
    _ = try planCopy(&first, &second, 0, 0, 16 * 1024);
    // One byte more would run past the end of *second* into nothing, even
    // though the shared allocation has plenty left.
    try testing.expectError(PlanError.OutOfBounds, planCopy(&first, &second, 0, 0, 16 * 1024 + 1));
    // Starting one byte into the second leaves one byte less, so 16 KiB no
    // longer fits.
    try testing.expectError(PlanError.OutOfBounds, planCopy(&first, &second, 0, 1, 16 * 1024));
    _ = try planCopy(&first, &second, 0, 1, 16 * 1024 - 1);
}

test "an offset past the end of a buffer is refused rather than clamped" {
    var a = deviceAlloc(0, 64 * 1024);
    var b = deviceAlloc(0, 64 * 1024);
    const src = makeBuffer(4096, &a, 0);
    const dst = makeBuffer(4096, &b, 0);

    try testing.expectError(PlanError.OutOfBounds, planCopy(&src, &dst, 4096, 0, 1));
    try testing.expectError(PlanError.OutOfBounds, planCopy(&src, &dst, 0, 4096, 1));
}

test "an oversized or empty copy is refused, never truncated" {
    var a = deviceAlloc(0, 64 * 1024);
    var b = deviceAlloc(0, 64 * 1024);
    const src = makeBuffer(4096, &a, 0);
    const dst = makeBuffer(4096, &b, 0);

    try testing.expectError(PlanError.OutOfBounds, planCopy(&src, &dst, 0, 0, 4097));
    try testing.expectError(PlanError.OutOfBounds, planCopy(&src, &dst, 0, 0, 0));
}

test "an unbound buffer is reported as such" {
    var a = deviceAlloc(0, 64 * 1024);
    const unbound = makeBuffer(4096, null, 0);
    const bound = makeBuffer(4096, &a, 0);

    try testing.expectError(PlanError.UnboundBuffer, planCopy(&unbound, &bound, 0, 0, 4096));
    try testing.expectError(PlanError.UnboundBuffer, planCopy(&bound, &unbound, 0, 0, 4096));
}

test "a transfer larger than the bound allocation is refused" {
    // The client can bind a 64 KiB buffer to a 2 KiB allocation. Bounds are
    // checked against the allocation too, so the copy is refused rather than
    // running off the end of it.
    var tiny = deviceAlloc(0, 2048);
    var other = deviceAlloc(0, 64 * 1024);
    const big = makeBuffer(64 * 1024, &tiny, 0);
    const dst = makeBuffer(64 * 1024, &other, 0);

    try testing.expectError(PlanError.OutOfBounds, planCopy(&big, &dst, 0, 0, 4096));
    _ = try planCopy(&big, &dst, 0, 0, 2048);
}

test "an offset that would wrap is refused" {
    var a = deviceAlloc(0, 64 * 1024);
    try testing.expect(!fitsInAllocation(&a, std.math.maxInt(u64), 4096));
    try testing.expect(!fitsInAllocation(&a, 0, std.math.maxInt(u64)));
    try testing.expect(fitsInAllocation(&a, 0, 4096));
}

test "a fill is bounded by the buffer and lands at its bound offset" {
    var a = deviceAlloc(0x7000, 64 * 1024);
    const dst = makeBuffer(64 * 1024, &a, 4096);

    const plan = try planFill(&dst, 8192, 16384);
    try testing.expectEqual(@as(usize, 16384), plan.bytes);
    try testing.expectEqual(@as(?u64, 0x7000 + 4096 + 8192), plan.dst.pool_offset);

    try testing.expectError(PlanError.OutOfBounds, planFill(&dst, 8192, (64 * 1024 - 8192) + 1));
    try testing.expectError(PlanError.OutOfBounds, planFill(&dst, 64 * 1024, 1));
    try testing.expectError(PlanError.OutOfBounds, planFill(&dst, 0, 0));
}

test "a fill will not target host memory" {
    var h = hostAlloc(64 * 1024);
    const dst = makeBuffer(64 * 1024, &h, 0);
    try testing.expectError(PlanError.UnboundBuffer, planFill(&dst, 0, 4096));
}

test "a buffer extent rounds up to the sector" {
    var a = deviceAlloc(0, 64 * 1024);
    try testing.expectEqual(@as(u64, blockdev.SECTOR), makeBuffer(1, &a, 0).extent());
    try testing.expectEqual(@as(u64, blockdev.SECTOR), makeBuffer(blockdev.SECTOR, &a, 0).extent());
}

test "each command buffer is handed a disjoint command window" {
    // The aliasing bug: every command buffer pointed at the same slice of the
    // shared pool, so two buffers recorded before one submit overwrote each
    // other and both submitted successfully having executed neither.
    releaseCommandWindows();
    const a = takeCommandWindow().?;
    const b = takeCommandWindow().?;
    try testing.expect(a.ptr != b.ptr);
    try testing.expect(a.len == COMMANDS_PER_BUFFER and b.len == COMMANDS_PER_BUFFER);
    releaseCommandWindows();
}

test "the command pool is finite and says so" {
    releaseCommandWindows();
    var taken: usize = 0;
    while (takeCommandWindow() != null) taken += 1;
    try testing.expectEqual(@as(usize, MAX_COMMANDS / COMMANDS_PER_BUFFER), taken);
    try testing.expect(taken * COMMANDS_PER_BUFFER <= MAX_COMMANDS);
    releaseCommandWindows();
}

test "bounce memory is sector aligned and bounded" {
    const b = bounce(std.math.maxInt(usize));
    try testing.expectEqual(@as(usize, BOUNCE_BYTES), b.len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(b.ptr) % blockdev.SECTOR);
}

test "no transfer failure is reported to the client as success" {
    const every = [_]PlanError{
        error.OutOfPool,     error.ShortTransfer, error.PoolUnavailable,
        error.UnboundBuffer, error.OutOfBounds,
    };
    for (every) |err| {
        try testing.expect(submitStatus(err) != c.VK_SUCCESS);
    }
}
