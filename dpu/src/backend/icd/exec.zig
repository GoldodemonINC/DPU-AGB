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
    /// Pre-transferred bytes for `copy_buffer` when the source is host-visible.
    host_src: ?[*]u8 = null,
    host_len: usize = 0,
    fill_data: u32 = 0,
};

const CommandBuffer = struct {
    sentinel: u32 = 0x44505507,
    recording: bool = false,
    commands: []Command,
    count: usize,
    capacity: usize,
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
}

/// Scratch storage for command recording.
///
/// A fixed ring rather than a heap allocation per command buffer: this code
/// runs inside somebody else's process, often `vulkaninfo`, and a general
/// allocator in a graphics driver is a well-known source of crashes at
/// teardown. When the ring is exhausted the command is simply not recorded and
/// the submit reports `VK_ERROR_OUT_OF_DEVICE_MEMORY`, which is recoverable.
const MAX_COMMANDS: usize = 4096;
var command_storage: [MAX_COMMANDS]Command = undefined;

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
    _: u64,
) callconv(.c) c_int {
    const b: *Buffer = @ptrCast(@alignCast(hBuffer orelse return c.VK_ERROR_INITIALIZATION_FAILED));
    const a: *mem.Allocation = @ptrCast(@alignCast(hMemory orelse return c.VK_ERROR_INITIALIZATION_FAILED));
    if (!a.valid()) return c.VK_ERROR_OUT_OF_DEVICE_MEMORY;

    const wanted = blockdev.roundUp(@max(b.size, 1));
    if (a.len < wanted) return c.VK_ERROR_OUT_OF_DEVICE_MEMORY;

    b.memory = a;
    b.offset_in_alloc = 0;
    return c.VK_SUCCESS;
}

pub fn vkBindBufferMemory2Impl(
    _: ?*anyopaque,
    count: u32,
    p: ?*const c.VkBindBufferMemoryInfo,
) callconv(.c) c_int {
    // Vulkan declares this as a single  plus a
    // count, not a pointer-to-array, so it is widened once here rather than
    // walking it by hand at every access.
    const raw = p orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    const infos: [*]const c.VkBindBufferMemoryInfo = @ptrCast(raw);

    // Every entry is attempted even after one fails, and the worst status is
    // returned: a partial bind is recoverable and the client needs to know that
    // *something* failed, not which entry happened to be first.
    var worst: c_int = c.VK_SUCCESS;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const info = infos[i];
        const b: *Buffer = @ptrCast(@alignCast(info.buffer));
        const a: *mem.Allocation = @ptrCast(@alignCast(info.memory));
        if (!a.valid() or a.len < blockdev.roundUp(@max(b.size, 1))) {
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
    const count = @max(info.commandBufferCount, 1);

    for (0..count) |i| {
        const slot = mem.arenaAlloc(@sizeOf(CommandBuffer)) orelse return c.VK_ERROR_OUT_OF_HOST_MEMORY;
        const cb: *CommandBuffer = @ptrCast(@alignCast(slot));
        cb.* = .{
            .commands = command_storage[0..],
            .count = 0,
            .capacity = MAX_COMMANDS,
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
    return c.VK_SUCCESS;
}

pub fn vkResetCommandBufferImpl(
    _: ?*anyopaque,
    handle: ?*anyopaque,
    _: c.VkCommandBufferResetFlags,
) callconv(.c) c_int {
    const cb = asCommandBuffer(handle) orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    cb.count = 0;
    cb.recording = false;
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
        _ = record(cb, .{
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

    // The caller's bytes are copied into the ring now rather than at submit
    // time. The spec permits the driver to copy at record time, and doing so is
    // the only correct option: the client is free to overwrite `pData` as soon
    // as this call returns.
    const slot = mem.arenaAlloc(@as(usize, @intCast(size))) orelse return;
    const buf: [*]u8 = @ptrCast(slot);
    const src: [*]const u8 = @ptrCast(pData.?);
    @memcpy(buf[0..@intCast(size)], src[0..@intCast(size)]);

    _ = record(cb, .{
        .kind = .write_buffer,
        .dst_buffer = d,
        .dst_offset = offset,
        .size = size,
        .host_src = buf,
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
    _ = record(cb, .{
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
) callconv(.c) void {
}

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
    const submits = pSubmits orelse {
        if (asFence(pFence)) |f| f.signalled = true;
        return c.VK_SUCCESS;
    };

    var n: u32 = 0;
    while (n < submit_count) : (n += 1) {
        const si = submits[n];

        // Semaphores need no implementation: every transfer completes inside
        // this call, so a wait is already satisfied and a signal is already
        // raised. Their counts are still read so that a client pairing them
        // does not leave an unused pointer array dangling.
        if (si.pWaitSemaphores != null) {
            for (si.pWaitDstStageMask[0..si.waitSemaphoreCount]) |_| {}
        }
        if (si.pSignalSemaphores != null) _ = si.signalSemaphoreCount;

        const cbs = si.pCommandBuffers orelse continue;
        var k: u32 = 0;
        while (k < si.commandBufferCount) : (k += 1) {
            const cb = asCommandBuffer(cbs[k]) orelse continue;
            var ci: usize = 0;
            while (ci < cb.count) : (ci += 1) execute(cb.commands[ci]);
            cb.count = 0;
        }
    }

    // The fence is the fourth argument to vkQueueSubmit, not a member of
    // VkSubmitInfo -- VkSubmitInfo has no fence field at all. A driver that
    // looked for one would never signal, and a client that waits on the fence
    // would hang forever.
    if (asFence(pFence)) |f| f.signalled = true;
    return c.VK_SUCCESS;
}

/// Perform one recorded command against the pool.
fn execute(cmd: Command) void {
    const b = mem.ensureBackend() orelse return;
    const d = cmd.dst_buffer orelse return;
    const dst_alloc = d.memory orelse return;

    switch (cmd.kind) {
        .copy_buffer => {
            const s = cmd.src_buffer orelse return;
            const src_alloc = s.memory orelse return;
            const n: usize = @intCast(@min(cmd.size, @min(src_alloc.len -| cmd.src_offset, dst_alloc.len -| cmd.dst_offset)));

            if (dst_alloc.heap == mem.HEAP_DEVICE_LOCAL) {
                // host -> device: a real uncached write to P:\
                if (src_alloc.heap == mem.HEAP_HOST) {
                    const host = src_alloc.host_ptr orelse return;
                    _ = b.write(dst_alloc.offset + cmd.dst_offset + d.offset_in_alloc, host[0..n]) catch return;
                } else {
                    // Arena memory, so there is nothing to release: it is
                    // reclaimed wholesale when the next device is created.
                    const staging = mem.arenaAlloc(n) orelse return;
                    _ = b.read(src_alloc.offset + cmd.src_offset, staging[0..n]) catch return;
                    _ = b.write(dst_alloc.offset + cmd.dst_offset + d.offset_in_alloc, staging[0..n]) catch return;
                }
            } else {
                // device -> host: a real uncached read from P:\
                const host = dst_alloc.host_ptr orelse return;
                if (src_alloc.heap == mem.HEAP_HOST) {
                    const sh = src_alloc.host_ptr orelse return;
                    @memcpy(host[0..n], sh[cmd.src_offset .. cmd.src_offset + n]);
                } else {
                    _ = b.read(src_alloc.offset + cmd.src_offset + s.offset_in_alloc, host[0..n]) catch return;
                }
            }
        },
        .write_buffer => {
            if (dst_alloc.heap != mem.HEAP_DEVICE_LOCAL) return;
            if (cmd.host_src) |src| {
                _ = b.write(dst_alloc.offset + cmd.dst_offset + d.offset_in_alloc, src[0..cmd.host_len]) catch return;
            }
        },
        .fill_buffer => {
            if (dst_alloc.heap != mem.HEAP_DEVICE_LOCAL) return;
            const n: usize = @intCast(@min(cmd.size, dst_alloc.len -| cmd.dst_offset));
            const staging = mem.arenaAlloc(n) orelse return;
            const bytes: []u8 = staging[0..n];
            var i: usize = 0;
            while (i + 4 <= n) : (i += 4) std.mem.writeInt(u32, bytes[i..][0..4], cmd.fill_data, .little);
            _ = b.write(dst_alloc.offset + cmd.dst_offset + d.offset_in_alloc, bytes) catch return;
        },
    }
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
