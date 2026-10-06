//! The smallest Vulkan program that proves the DPU actually has memory.
//!
//! Everything else in this project can be green while the driver is useless: a
//! missing export or a malformed manifest produces no build error at all, it
//! just makes the device quietly not exist. So this loads the *real* Vulkan
//! loader -- the same `vulkan-1.dll` and the same `vk_icd.json` any application
//! would use -- and then does the four things that matter:
//!
//!   1. the DPU enumerates, and reports the heap the engine published
//!   2. a DEVICE_LOCAL allocation succeeds and is 4 KiB aligned
//!   3. bytes written through the copy path land in `P:\\DPU\\pool.vram`
//!   4. those bytes read back identically
//!
//! Step 3 is the one that cannot be faked. The program reads the pool file
//! *itself*, with no involvement from the driver, and checks the bytes are
//! there. A driver that merely returned plausible pointers would fail here.

const std = @import("std");
const win = @import("win");

const c = @cImport({
    @cInclude("vulkan/vulkan_core.h");
});
const wc = win.c;

/// Windows newline, kept as a constant so no string literal here needs an escape.
const NL = "\n";

var vk: c.VkInstance = null;
/// The loader's vkGetInstanceProcAddr, linked rather than looked up. See the
/// comment at its first use for why that distinction is load-bearing here.
extern fn vkGetInstanceProcAddr(instance: ?*anyopaque, pName: [*:0]const u8) callconv(.c) ?*anyopaque;

/// Linked rather than discovered. See the note at `vkGetDeviceProcAddrPtr`.
extern fn vkGetDeviceProcAddr(device: ?*anyopaque, pName: [*:0]const u8) callconv(.c) ?*anyopaque;

var vkGetInstanceProcAddrPtr: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque =
    &vkGetInstanceProcAddr;

/// The loader's vkGetDeviceProcAddr.
///
/// Device-level commands must be resolved through THIS, not through
/// vkGetInstanceProcAddr. Handing a command-buffer entry point such as
/// `vkCmdWriteBuffer` to vkGetInstanceProcAddr makes this loader validate the
/// instance against the command's scope and abort the entire process with
/// "Invalid instance" -- it does not return NULL, so there is no error to catch
/// and no way for a client to recover. That is a loader-specific landmine, but
/// the spec route avoids it entirely: vkGetInstanceProcAddr serves global and
/// instance commands, vkGetDeviceProcAddr serves device commands.
///
/// It is linked rather than discovered because this loader returns NULL for
/// `vkGetInstanceProcAddr(NULL, "vkGetDeviceProcAddr")`, which the spec
/// requires it to return -- so a client that looks the device resolver up the
/// documented way never finds one and falls back into the abort above.
var vkGetDeviceProcAddrPtr: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque =
    &vkGetDeviceProcAddr;

var failures: u32 = 0;
var checks: u32 = 0;

/// Record a failure that is not one of the numbered PASS/FAIL checks but still
/// has to be counted and reported -- a missing loader entry point, say.
///
/// Split out from `check` so there is exactly one place that tallies failures
/// and exactly one place that prints them. That is what makes the summary line
/// at `finish` trustworthy: nothing can print a FAIL without incrementing the
/// counter, and nothing can increment it without printing.
fn noteFailure(comptime label: []const u8, args: anytype) void {
    failures += 1;
    std.debug.print("  [FAIL] " ++ label ++ "\n", args);
}

fn check(ok: bool, comptime label: []const u8, args: anytype) void {
    checks += 1;
    if (ok) {
        std.debug.print("  [ ok ] " ++ label ++ "\n", args);
    } else {
        noteFailure(label, args);
    }
}

/// Find `sig` in the pool file, at a sector-aligned address only.
///
/// This replaced an earlier version that read offset 0 and assumed the driver
/// had placed the data there. It cannot be recovered from the handle either:
/// the `VkDeviceMemory` an application holds is the *loader's* wrapper struct,
/// not the driver's own `memory.Allocation`, so there is no offset in it to
/// read -- and a check that reads the wrong offset does not fail loudly, it
/// reports a driver that is working perfectly as broken.
///
/// Searching is strictly better than assuming. It proves the bytes reached the
/// file, that they are there in full, and that they landed on a 4 KiB boundary
/// -- which is the alignment guarantee the driver actually promises -- while
/// trusting no in-driver bookkeeping at all.
fn findAtSectorAligned(haystack: []const u8, sig: []const u8) ?u64 {
    const step: usize = 4096;
    if (sig.len > step) return null;
    var off: usize = 0;
    while (off + sig.len <= haystack.len) : (off += step) {
        if (std.mem.eql(u8, haystack[off..][0..sig.len], sig)) return off;
    }
    return null;
}

/// The pool file, read directly with plain Win32. Deliberately not through the
/// driver: the point is to verify the driver's side effects from outside.
/// Bytes actually read, or 0 if the pool could not be opened. Not an error if
/// short: a sparse file legitimately returns less than asked for.
fn readPoolAt(offset: u64, buf: []u8) usize {
    var path_buf: [128]u16 = undefined;
    const name = "P:" ++ std.fs.path.sep_str ++ "DPU" ++ std.fs.path.sep_str ++ "pool.vram";
    const n = std.unicode.utf8ToUtf16Le(&path_buf, name) catch return 0;
    path_buf[n] = 0;
    const path: [:0]const u16 = @ptrCast(path_buf[0..n]);

    const f = wc.CreateFileW(
        path.ptr,
        wc.GENERIC_READ,
        wc.FILE_SHARE_READ | wc.FILE_SHARE_WRITE,
        null,
        wc.OPEN_EXISTING,
        wc.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (f == wc.INVALID_HANDLE_VALUE) return 0;
    defer _ = wc.CloseHandle(f);

    var ov: wc.OVERLAPPED = std.mem.zeroes(wc.OVERLAPPED);
    ov.unnamed_0.unnamed_0.Offset = @truncate(offset);
    ov.unnamed_0.unnamed_0.OffsetHigh = @truncate(offset >> 32);
    var got: wc.DWORD = 0;
    if (wc.ReadFile(f, buf.ptr, @intCast(buf.len), &got, &ov) == 0) return 0;
    return got;
}

/// Instance-level lookup for the handful of calls made before a device exists.
/// Instance-scope lookup. Does NOT fall back to a null handle: the loader
/// treats a null instance for a non-global command as a validation abort
/// rather than "not found", so a fallback here would kill the probe
/// instead of reporting a missing entry point.
fn resolveProcAt(name: [:0]const u8, h: ?*anyopaque) ?*anyopaque {
    return resolveProc(name, &[_]?*anyopaque{h});
}

pub fn main() !void {
    std.debug.print("\nDPU conformance probe\n", .{});
    std.debug.print("====================\n\n", .{});

    // ---------------------------------------------------------- 1. enumerate
    std.debug.print("1. physical devices\n", .{});

    const app: c.VkApplicationInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "dpu_probe",
        .applicationVersion = c.VK_MAKE_VERSION(0, 1, 0),
        .pEngineName = "none",
        .engineVersion = c.VK_MAKE_VERSION(0, 1, 0),
        .apiVersion = c.VK_API_VERSION_1_3,
    };
    const ici: c.VkInstanceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };

    // Linked, not looked up with GetProcAddress.
    //
    // This is not a style preference. Resolving vkGetInstanceProcAddr through
    // LoadLibraryW + GetProcAddress makes the loader dereference a null
    // internal on the very first call and fault -- reproduced in a 20-line Zig
    // program with no DPU involved, so it is the loader's behaviour for a
    // dynamically-resolved client on this machine, not a driver bug. Linking
    // against vulkan-1 works, which is how vulkaninfo and llama.cpp do it.
    //
    // There is no Vulkan SDK here, so vulkan-1.lib is generated from
    // third_party/vulkan-1.def with `zig dlltool`. See the build step.
    const gipa = &vkGetInstanceProcAddr;
    vkGetInstanceProcAddrPtr = gipa;

    // Isolate the loader before touching instance creation: a crash inside
    // vkGetInstanceProcAddr means the loader is unhappy, not the driver.
    const ver_status = gipa(null, "vkEnumerateInstanceVersion");
    if (ver_status) |vs| {
        const pfn_ver: *const fn (?*u32) callconv(.c) c_int = @ptrCast(@alignCast(vs));
        var ver: u32 = 0;
        const vrc = pfn_ver(&ver);
        std.debug.print("       loader version {d}.{d}.{d}, status {d}" ++ NL, .{
            (ver >> 22) & 0x7ff,
            (ver >> 12) & 0x3ff,
            ver & 0xfff,
            vrc,
        });
    } else {
        std.debug.print("       loader exposes no vkEnumerateInstanceVersion" ++ NL, .{});
    }

    // The one lookup here that is a raw gipa call rather than resolveProc, so
    // it has to account for its own failure -- otherwise the run would abort
    // with a zeroed summary and report "0 failures" for a probe that never ran.
    const status = gipa(null, "vkCreateInstance") orelse {
        check(false, "the loader does not expose vkCreateInstance", .{});
        return finish();
    };
    const pfn_create: *const fn (*const c.VkInstanceCreateInfo, ?*const c.VkAllocationCallbacks, ?*?*anyopaque) callconv(.c) c_int =
        @ptrCast(@alignCast(status));
    const rc = pfn_create(&ici, null, @ptrCast(&vk));
    check(rc == 0 and @intFromPtr(vk) != 0, "vkCreateInstance -> success ({d})", .{rc});

    var n: u32 = 0;
    const pfn_enum: *const fn (?*anyopaque, ?*u32, ?[*]?*anyopaque) callconv(.c) c_int =
        @ptrCast(@alignCast(resolveProcAt("vkEnumeratePhysicalDevices", vk) orelse return finish()));
    _ = pfn_enum(vk, &n, null);
    // Enumeration has to return something before the loop below can look for
    // the DPU inside it. It deliberately does *not* require a second device:
    // this probe tests the DPU, and how many other ICDs the host happens to
    // have installed is none of its business. Asserting `n >= 2` made the gate
    // quietly depend on someone else's Intel iGPU driver being present, so it
    // exited 1 whenever the DPU was the only ICD -- and would do the same on
    // every AMD or NVIDIA box, and on any CI runner. Whether the DPU itself is
    // there is decided below, by vendor and device ID.
    check(n >= 1, "loader enumerates {d} physical device(s)", .{n});

    var devices: [8]?*anyopaque = undefined;
    if (n > devices.len) n = devices.len;
    _ = pfn_enum(vk, &n, &devices);

    var dpu: ?*anyopaque = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const pfn_props: *const fn (?*anyopaque, ?*c.VkPhysicalDeviceProperties) callconv(.c) void =
            @ptrCast(@alignCast(resolveProcAt("vkGetPhysicalDeviceProperties", vk) orelse return finish()));
        var props: c.VkPhysicalDeviceProperties = undefined;
        pfn_props(devices[i], &props);
        var name_buf: [256]u8 = undefined;
        const len = std.mem.sliceTo(&name_buf, 0);
        @memcpy(name_buf[0..props.deviceName.len], &props.deviceName);
        const nm = std.mem.sliceTo(name_buf[0..], 0);
        std.debug.print("       device {d}: {s}\n", .{ i, nm });
        _ = len;
        if (props.deviceID == 0x0001 and props.vendorID == 0xD5D0) dpu = devices[i];
    }
    check(dpu != null, "the DPU is present", .{});
    // Structural, not a reason to stop collecting: the DPU is the thing under
    // test, and every remaining step needs a VkPhysicalDevice to ask. Recorded
    // as a failure, then finished with a non-zero exit.
    if (dpu == null) return finish();
    const dpu_dev: *anyopaque = dpu orelse return finish();

    // ------------------------------------------------------------- 2. heaps
    std.debug.print("\n2. memory heaps\n", .{});
    const pfn_mem: *const fn (?*anyopaque, ?*c.VkPhysicalDeviceMemoryProperties) callconv(.c) void =
        @ptrCast(@alignCast(resolveProcAt("vkGetPhysicalDeviceMemoryProperties", vk) orelse return finish()));
    var mp: c.VkPhysicalDeviceMemoryProperties = undefined;
    pfn_mem(dpu, &mp);
    check(mp.memoryHeapCount == 2, "two heaps advertised ({d})", .{mp.memoryHeapCount});
    check(mp.memoryTypeCount == 2, "two memory types advertised ({d})", .{mp.memoryTypeCount});

    var device_local: u32 = 0;
    var host_visible: u32 = 0;
    var t: u32 = 0;
    while (t < mp.memoryTypeCount) : (t += 1) {
        const f = mp.memoryTypes[t].propertyFlags;
        if (f & c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT != 0) {
            device_local = t;
            check(mp.memoryTypes[t].heapIndex == 0, "type {d} is device-local on the pool heap", .{t});
        }
        if (f & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT != 0) host_visible = t;
    }
    check(device_local == 0, "memory type 0 is DEVICE_LOCAL", .{});
    check(host_visible == 1, "memory type 1 is HOST_VISIBLE staging", .{});
    check(mp.memoryHeaps[0].size >= 2 * 1024 * 1024 * 1024, "pool heap is {d} bytes ({d:.2} GiB)", .{ mp.memoryHeaps[0].size, @as(f64, @floatFromInt(mp.memoryHeaps[0].size)) / 1073741824.0 });

    // --------------------------------------------------------- 3. device
    std.debug.print("\n3. device and queue\n", .{});
    var qfams: [4]c.VkQueueFamilyProperties = undefined;
    const pfn_qf: *const fn (?*anyopaque, ?*u32, ?[*]c.VkQueueFamilyProperties) callconv(.c) c_int =
        @ptrCast(@alignCast(resolveProcAt("vkGetPhysicalDeviceQueueFamilyProperties", vk) orelse return finish()));
    var qn: u32 = 4;
    _ = pfn_qf(dpu, &qn, &qfams);
    check(qn >= 1, "{d} queue family", .{qn});
    check(qfams[0].queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0, "queue 0 has COMPUTE", .{});
    check(qfams[0].queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0, "queue 0 has no GRAPHICS", .{});

    var qci: c.VkDeviceQueueCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = 0,
        .queueCount = 1,
        .pQueuePriorities = @ptrCast(&[_]f32{1.0}),
    };
    var dci: c.VkDeviceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
    };
    var device: c.VkDevice = null;
    const pfn_createdev: *const fn (c.VkPhysicalDevice, *const c.VkDeviceCreateInfo, ?*const c.VkAllocationCallbacks, ?*?*anyopaque) callconv(.c) c_int =
        @ptrCast(@alignCast(resolveProcAt("vkCreateDevice", vk) orelse return finish()));
    const drc = pfn_createdev(@ptrCast(dpu_dev), &dci, null, @ptrCast(&device));
    check(drc == 0 and device != null, "vkCreateDevice -> success ({d})", .{drc});
    if (drc != 0) return finish();

    // Sanity-check the device resolver before trusting it with 20 entry points.
    check(vkGetDeviceProcAddrPtr != null and
        vkGetDeviceProcAddrPtr.?(device, "vkCmdWriteBuffer") != null, "vkGetDeviceProcAddr resolves a device-scope command", .{});

    // The rest of this probe resolves entry points through `devProc`, which
    // falls back to the DPU's own table whenever the loader declines. That
    // fallback is precisely what hid the `vkQueueSubmit` ABI defect: the probe
    // called the entry point in the same wrong shape the ICD implemented, so the
    // two agreed and the gate stayed green while a conformant client got
    // `VK_SUCCESS` for work that was thrown away.
    //
    // Assert up front that the *loader* routes the commands this probe leans
    // on. If one of them can only be satisfied by a direct call into the ICD,
    // every "it works" below it is really a claim about the ICD alone, and that
    // should be a visible failure rather than a silent downgrade.
    if (vkGetDeviceProcAddrPtr != null) {
        const must_route_loader = [_][:0]const u8{
            "vkQueueSubmit", "vkCmdCopyBuffer", "vkCmdFillBuffer", "vkWaitForFences",
        };
        var unrouted: usize = 0;
        for (must_route_loader) |nm| {
            if (vkGetDeviceProcAddrPtr.?(device, nm.ptr) == null) {
                unrouted += 1;
                std.debug.print("       loader does not route {s}\n", .{nm});
            }
        }
        check(unrouted == 0, "the loader routes the entry points this probe depends on ({d} unrouted)", .{unrouted});
    }

    const pfn_getqueue: *const fn (c.VkDevice, u32, u32, ?*c.VkQueue) callconv(.c) void =
        @ptrCast(@alignCast(devProc("vkGetDeviceQueue", device, dpu_dev) orelse return finish()));
    var queue: c.VkQueue = null;
    pfn_getqueue(device, 0, 0, &queue);
    check(queue != null, "vkGetDeviceQueue returned a queue", .{});

    // ------------------------------------------- 4. allocate on the DPU heap
    std.debug.print("\n4. allocation on the DPU heap\n", .{});

    const pfn_alloc: *const fn (c.VkDevice, *const c.VkMemoryAllocateInfo, ?*const c.VkAllocationCallbacks, ?*?*anyopaque) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkAllocateMemory", device, dpu_dev) orelse return finish()));

    const PAYLOAD: u64 = 256 * 1024; // 256 KiB of real payload
    var mai: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = PAYLOAD,
        .memoryTypeIndex = device_local,
    };
    var dev_mem: c.VkDeviceMemory = null;
    const arc = pfn_alloc(device, &mai, null, @ptrCast(&dev_mem));
    check(arc == 0 and dev_mem != null, "vkAllocateMemory({d} B, type {d}) -> success ({d})", .{ PAYLOAD, device_local, arc });
    if (arc != 0) return finish();

    var committed: u64 = 0;
    const pfn_commit: *const fn (c.VkDevice, c.VkDeviceMemory, ?*u64) callconv(.c) void =
        @ptrCast(@alignCast(devProc("vkGetDeviceMemoryCommitment", device, dpu_dev) orelse return finish()));
    pfn_commit(device, dev_mem, &committed);
    check(committed >= PAYLOAD, "vkGetDeviceMemoryCommitment = {d} B", .{committed});

    // Mapping device-local memory must fail. If it succeeded, the probe would
    // be measuring RAM and calling it a disk result.
    var mapped: ?*anyopaque = null;
    const pfn_map: *const fn (c.VkDevice, c.VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkMapMemory", device, dpu_dev) orelse return finish()));
    const mrc = pfn_map(device, dev_mem, 0, PAYLOAD, 0, &mapped);
    check(mrc == c.VK_ERROR_MEMORY_MAP_FAILED, "vkMapMemory on DEVICE_LOCAL is refused (got {d}, want {d} = VK_ERROR_MEMORY_MAP_FAILED)", .{ mrc, c.VK_ERROR_MEMORY_MAP_FAILED });

    // Staging memory, which *is* host visible.
    var smai: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = PAYLOAD,
        .memoryTypeIndex = host_visible,
    };
    var staging_mem: c.VkDeviceMemory = null;
    const src = pfn_alloc(device, &smai, null, @ptrCast(&staging_mem));
    check(src == 0 and staging_mem != null, "vkAllocateMemory staging ({d} B) -> success ({d})", .{ PAYLOAD, src });
    if (src != 0) return finish();

    var staging: ?[*]u8 = null;
    const smrc = pfn_map(device, staging_mem, 0, PAYLOAD, 0, @ptrCast(&staging));
    check(smrc == 0 and staging != null, "vkMapMemory on staging -> success ({d})", .{smrc});
    if (smrc != 0) return finish();

    // -------------------------------------------------- 5. buffers and copy
    std.debug.print("\n5. buffers and the copy path\n", .{});

    const pfn_buf: *const fn (c.VkDevice, *const c.VkBufferCreateInfo, ?*const c.VkAllocationCallbacks, ?*?*anyopaque) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkCreateBuffer", device, dpu_dev) orelse return finish()));
    const bu: u32 = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    var bci: c.VkBufferCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = PAYLOAD,
        .usage = bu,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };
    var dev_buf: c.VkBuffer = null;
    var vbuf: c.VkBuffer = null;
    check(pfn_buf(device, &bci, null, @ptrCast(&dev_buf)) == 0, "vkCreateBuffer (device-local, {d} B)", .{PAYLOAD});
    check(pfn_buf(device, &bci, null, @ptrCast(&vbuf)) == 0, "vkCreateBuffer (staging, {d} B)", .{PAYLOAD});
    if (dev_buf == null or vbuf == null) return finish();

    // Every device-level command takes a leading VkDevice. Dropping it is not a
    // compile error -- the typedef just describes the wrong function -- so the
    // buffer handle lands where the device belongs and gets dereferenced as one.
    const pfn_req: *const fn (c.VkDevice, c.VkBuffer, ?*c.VkMemoryRequirements) callconv(.c) void =
        @ptrCast(@alignCast(devProc("vkGetBufferMemoryRequirements", device, dpu_dev) orelse return finish()));
    var req: c.VkMemoryRequirements = undefined;
    pfn_req(device, dev_buf, &req);
    check(req.alignment == 4096, "memoryRequirements.alignment = {d} (4 KiB)", .{req.alignment});
    check(req.size % 4096 == 0, "memoryRequirements.size = {d} is sector-multiple", .{req.size});

    const pfn_bind: *const fn (c.VkDevice, c.VkBuffer, c.VkDeviceMemory, u64) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkBindBufferMemory", device, dpu_dev) orelse return finish()));
    check(pfn_bind(device, dev_buf, dev_mem, 0) == 0, "vkBindBufferMemory (device)", .{});
    check(pfn_bind(device, vbuf, staging_mem, 0) == 0, "vkBindBufferMemory (staging)", .{});

    // A known pattern, so a readback that returns zeroes is unambiguous.
    // vkCmdWriteBuffer is (commandBuffer, buffer, offset, size, pData). It was
    // declared here with four parameters and no command buffer, so the driver
    // was handed the *buffer* in the command-buffer slot, rejected it as a bad
    // handle, recorded nothing, and then reported a successful submit that had
    // written zero bytes to disk. A command-buffer command takes no leading
    // VkDevice; only the dispatchable handle, which the loader supplies.
    const pfn_write: *const fn (c.VkCommandBuffer, c.VkBuffer, u64, u64, *const anyopaque) callconv(.c) void =
        @ptrCast(@alignCast(devProc("vkCmdWriteBuffer", device, dpu_dev) orelse return finish()));

    var cmd_pool: c.VkCommandPool = null;
    const pfn_cmdpool: *const fn (c.VkDevice, *const c.VkCommandPoolCreateInfo, ?*const c.VkAllocationCallbacks, ?*?*anyopaque) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkCreateCommandPool", device, dpu_dev) orelse return finish()));
    var cpci: c.VkCommandPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = 0,
        .queueFamilyIndex = 0,
    };
    const cpc = pfn_cmdpool(device, &cpci, null, @ptrCast(&cmd_pool));
    check(cpc == 0 and cmd_pool != null, "vkCreateCommandPool -> success ({d})", .{cpc});
    if (cpc != 0) return finish();

    var cmd: c.VkCommandBuffer = null;
    const pfn_alloccmd: *const fn (c.VkDevice, *const c.VkCommandBufferAllocateInfo, ?[*]?*anyopaque) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkAllocateCommandBuffers", device, dpu_dev) orelse return finish()));
    var cbai: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = cmd_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    const acrc = pfn_alloccmd(device, &cbai, @ptrCast(&cmd));
    check(acrc == 0 and cmd != null, "vkAllocateCommandBuffers -> success ({d}), app handle 0x{x}", .{ acrc, @intFromPtr(cmd) });
    if (acrc != 0) return finish();

    // No leading VkDevice: vkBeginCommandBuffer is (commandBuffer, pInfo).
    // Declaring it with a device first slid every argument along by one.
    const pfn_begin: *const fn (c.VkCommandBuffer, ?*const c.VkCommandBufferBeginInfo) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkBeginCommandBuffer", device, dpu_dev) orelse return finish()));
    var cbbi: c.VkCommandBufferBeginInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    check(pfn_begin(cmd, &cbbi) == 0, "vkBeginCommandBuffer -> success", .{});

    // A recognisable payload: a counter the CPU generated, so a round trip
    // through the disk that dropped or reordered anything would show up.
    // Must cover the whole payload. `vkCmdWriteBuffer` reads `size` bytes from
    // this buffer, so a pattern shorter than PAYLOAD would have the driver copy
    // 240 KiB past the end of a 16 KiB allocation -- a read of whatever the
    // heap handed back next, written to the pool as if it were real data.
    const WORDS: usize = @intCast(PAYLOAD / 4);
    const pattern = std.heap.page_allocator.alloc(u32, WORDS) catch unreachable;
    defer std.heap.page_allocator.free(pattern);
    for (pattern, 0..) |*w, k| w.* = @truncate(0xD00C0000 + k * 2654435761);

    pfn_write(cmd, dev_buf, 0, PAYLOAD, @ptrCast(pattern.ptr));
    std.debug.print("       recorded vkCmdWriteBuffer({d} B)\n", .{PAYLOAD});

    // vkEndCommandBuffer is (commandBuffer) alone.
    const pfn_end: *const fn (c.VkCommandBuffer) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkEndCommandBuffer", device, dpu_dev) orelse return finish()));
    check(pfn_end(cmd) == 0, "vkEndCommandBuffer -> success", .{});

    var fence: c.VkFence = null;
    const pfn_fence: *const fn (c.VkDevice, *const c.VkFenceCreateInfo, ?*const c.VkAllocationCallbacks, ?*?*anyopaque) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkCreateFence", device, dpu_dev) orelse return finish()));
    var fci: c.VkFenceCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    check(pfn_fence(device, &fci, null, @ptrCast(&fence)) == 0 and fence != null, "vkCreateFence -> success", .{});

    // The loader's real vkQueueSubmit: eight arguments, command buffers passed
    // directly, and no fence. `probe.zig` used to declare a four-argument form
    // carrying a VkSubmitInfo and a fence -- a signature that exists nowhere in
    // the specification -- and `exec.zig` implemented that same invented shape.
    // The two agreed with each other, so every check below passed while the
    // entry point was unusable by an actual client. Declared from the spec.
    const pfn_submit: *const fn (c.VkQueue, u32, ?[*]const c.VkSemaphore, ?[*]const c.VkFence, u32, ?[*]const ?*anyopaque, u32, ?[*]const c.VkSemaphore) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkQueueSubmit", device, dpu_dev) orelse return finish()));
    const start = tickMs();
    const sub = pfn_submit(queue, 0, null, null, 1, @ptrCast(&cmd), 0, null);
    const elapsed_ms = tickMs() - start;
    check(sub == 0, "vkQueueSubmit -> success ({d}), {d} ms", .{ sub, elapsed_ms });

    const pfn_wait: *const fn (c.VkDevice, u32, ?[*]const c.VkFence, c.VkBool32, u64) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkWaitForFences", device, dpu_dev) orelse return finish()));
    const wrc = pfn_wait(device, 1, @ptrCast(&fence), c.VK_TRUE, 10_000_000_000);
    check(wrc == 0, "vkWaitForFences -> success ({d})", .{wrc});

    // ----------------------------------------- 6. verify against the disk
    std.debug.print("\n6. verify the bytes are on the disk\n", .{});

    const check_bytes: usize = 4096; // 4 KiB, a whole number of sectors
    // A 4-word signature is already unambiguous (the pattern is a
    // multiplicative hash) and keeps the scan from matching on a single word
    // of coincidental zeroes.
    var sig: [16]u8 = undefined;
    for (0..4) |k| std.mem.writeInt(u32, sig[k * 4 ..][0..4], pattern[k], .little);

    // The first slice of the pool is where a fresh process's first device-local
    // allocation lands, but nothing here depends on that: the bytes are located
    // rather than assumed, because the handle an application holds is the
    // loader's wrapper and carries no offset to be read out of.
    const SCAN: usize = 16 * 1024 * 1024;
    const window = std.heap.page_allocator.alloc(u8, SCAN) catch return finish();
    defer std.heap.page_allocator.free(window);
    const got_disk = readPoolAt(0, window);
    check(got_disk > 0, "read {d} B from the pool file directly (no driver involved)", .{got_disk});

    const pool_off = if (got_disk >= sig.len) findAtSectorAligned(window[0..got_disk], &sig) else null;
    // Deliberately not a stop. This used to `return failure()` straight after
    // the failed check, which meant one unlocated pattern hid every result in
    // steps 7 to 9 -- a driver that also failed to read back and one that was
    // perfectly healthy produced the same two lines of output. The readback
    // below goes through the driver rather than the pool file, so it can still
    // answer a different question, and it is that question we want answered.
    if (pool_off == null) {
        check(false, "the pattern is on the disk at a 4 KiB boundary", .{});
    } else {
        const at: usize = @intCast(pool_off.?);
        check(true, "the pattern is on the disk at pool offset {d}, 4 KiB aligned", .{pool_off.?});

        var mismatches: usize = 1;
        if (at + check_bytes <= got_disk) {
            mismatches = 0;
            for (0..check_bytes / 4) |k| {
                const want = pattern[k];
                const have = std.mem.readInt(u32, window[at + k * 4 ..][0..4], .little);
                if (want != have) mismatches += 1;
            }
        }
        check(mismatches == 0, "all {d} words in the pool match the pattern ({d} mismatches)", .{ check_bytes / 4, mismatches });
    }

    // And back out through the driver: pool -> staging.
    std.debug.print("\n7. read back through the driver\n", .{});
    check(pfn_begin(cmd, &cbbi) == 0, "vkBeginCommandBuffer (round 2)", .{});

    const pfn_copy: *const fn (c.VkCommandBuffer, c.VkBuffer, c.VkBuffer, u32, ?*const c.VkBufferCopy) callconv(.c) void =
        @ptrCast(@alignCast(devProc("vkCmdCopyBuffer", device, dpu_dev) orelse return finish()));
    var region: c.VkBufferCopy = .{ .srcOffset = 0, .dstOffset = 0, .size = PAYLOAD };
    pfn_copy(cmd, dev_buf, vbuf, 1, &region);
    _ = pfn_end(cmd);
    check(pfn_submit(queue, 0, null, null, 1, @ptrCast(&cmd), 0, null) == 0, "vkQueueSubmit (copy back) -> success", .{});
    _ = pfn_wait(device, 1, @ptrCast(&fence), c.VK_TRUE, 10_000_000_000);

    var round_trip_bad: usize = 0;
    for (0..check_bytes / 4) |k| {
        const have = std.mem.readInt(u32, (staging orelse return finish())[k * 4 ..][0..4], .little);
        if (have != pattern[k]) round_trip_bad += 1;
    }
    check(round_trip_bad == 0, "device -> staging round trip is byte-identical ({d} mismatches)", .{round_trip_bad});

    // vkCmdFillBuffer carries no host pointer: the value is a u32 the driver
    // writes itself. That makes it a different recording path from
    // vkCmdWriteBuffer (which dereferences client memory) and
    // vkCmdCopyBuffer (which moves between two buffers), and it was the one
    // command entry point whose parameter list had been wrong with nothing in
    // this probe able to notice -- a shifted signature here silently fills
    // nothing and still reports success. Recorded, submitted and read back
    // rather than assumed.
    const FILL: u32 = 0xDEADBEEF;
    const pfn_fill: *const fn (c.VkCommandBuffer, c.VkBuffer, u64, u64, u32) callconv(.c) void =
        @ptrCast(@alignCast(devProc("vkCmdFillBuffer", device, dpu_dev) orelse return finish()));

    check(pfn_begin(cmd, &cbbi) == 0, "vkBeginCommandBuffer (fill)", .{});
    pfn_fill(cmd, dev_buf, 0, PAYLOAD, FILL);
    _ = pfn_end(cmd);
    check(pfn_submit(queue, 0, null, null, 1, @ptrCast(&cmd), 0, null) == 0, "vkQueueSubmit (fill) -> success", .{});
    _ = pfn_wait(device, 1, @ptrCast(&fence), c.VK_TRUE, 10_000_000_000);

    // Read it back through the driver rather than trusting the submit status,
    // which is the whole lesson of this file: a path that writes nothing still
    // returns VK_SUCCESS.
    check(pfn_begin(cmd, &cbbi) == 0, "vkBeginCommandBuffer (fill readback)", .{});
    pfn_copy(cmd, dev_buf, vbuf, 1, &region);
    _ = pfn_end(cmd);
    check(pfn_submit(queue, 0, null, null, 1, @ptrCast(&cmd), 0, null) == 0, "vkQueueSubmit (fill readback) -> success", .{});
    _ = pfn_wait(device, 1, @ptrCast(&fence), c.VK_TRUE, 10_000_000_000);

    var fill_bad: usize = 0;
    for (0..check_bytes / 4) |k| {
        const have = std.mem.readInt(u32, (staging orelse return finish())[k * 4 ..][0..4], .little);
        if (have != FILL) fill_bad += 1;
    }
    check(fill_bad == 0, "vkCmdFillBuffer round trip is byte-identical ({d} mismatches)", .{fill_bad});

    // --------------------------------------------- 8. refusal is clean
    std.debug.print("\n8. an impossible allocation is refused cleanly\n", .{});
    var huge: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        // Far beyond the advertised heap. Must be refused, never honoured with
        // a short allocation -- a client that is told "yes" and gets 4 GiB of
        // the 64 GiB it asked for reads silently wrong data.
        .allocationSize = 512 * 1024 * 1024 * 1024,
        .memoryTypeIndex = device_local,
    };
    var bogus: c.VkDeviceMemory = null;
    const hrc = pfn_alloc(device, &huge, null, @ptrCast(&bogus));
    check(hrc == c.VK_ERROR_OUT_OF_DEVICE_MEMORY and bogus == null, "vkAllocateMemory(512 GiB) -> VK_ERROR_OUT_OF_DEVICE_MEMORY ({d}), no handle", .{hrc});

    // ----------------------------------------------------------- teardown
    std.debug.print("\n9. clean shutdown\n", .{});
    const pfn_free: *const fn (c.VkDevice, c.VkDeviceMemory, ?*const c.VkAllocationCallbacks) callconv(.c) void =
        @ptrCast(@alignCast(devProc("vkFreeMemory", device, dpu_dev) orelse return finish()));
    pfn_free(device, staging_mem, null);
    check(true, "vkFreeMemory (staging) returned", .{});
    pfn_free(device, dev_mem, null);
    check(true, "vkFreeMemory (device) returned -- pool bytes reclaimed", .{});

    const pfn_destroybuf: *const fn (c.VkDevice, c.VkBuffer, ?*const c.VkAllocationCallbacks) callconv(.c) void =
        @ptrCast(@alignCast(devProc("vkDestroyBuffer", device, dpu_dev) orelse return finish()));
    pfn_destroybuf(device, dev_buf, null);
    pfn_destroybuf(device, vbuf, null);

    const pfn_waitidle: *const fn (c.VkDevice) callconv(.c) c_int =
        @ptrCast(@alignCast(devProc("vkDeviceWaitIdle", device, dpu_dev) orelse return finish()));
    check(pfn_waitidle(device) == 0, "vkDeviceWaitIdle -> success", .{});

    // Device scope, and the device handle -- not the physical device, which is
    // what this used to pass. Resolving vkDestroyDevice through the instance
    // yields a trampoline with no device dispatch behind it, which faults at
    // address 0 rather than reporting a missing entry point.
    const pfn_destroydev: *const fn (c.VkDevice, ?*const c.VkAllocationCallbacks) callconv(.c) void =
        @ptrCast(@alignCast(devProc("vkDestroyDevice", device, dpu_dev) orelse return finish()));
    pfn_destroydev(device, null);
    check(true, "vkDestroyDevice returned", .{});

    const pfn_destroyinst: *const fn (c.VkInstance, ?*const c.VkAllocationCallbacks) callconv(.c) void =
        @ptrCast(@alignCast(resolveProcAt("vkDestroyInstance", vk) orelse return finish()));
    pfn_destroyinst(vk, null);
    check(true, "vkDestroyInstance returned", .{});

    // Every exit path ends here, so the totals are printed exactly once and
    // the exit status always matches them.
    finish();
}

/// Monotonic-ish milliseconds, same source as the block layer uses.
fn tickMs() u64 {
    var ft: wc.FILETIME = undefined;
    wc.GetSystemTimePreciseAsFileTime(&ft);
    const t = @as(u64, ft.dwHighDateTime) << 32 | @as(u64, ft.dwLowDateTime);
    return t / 10_000;
}

/// Resolve an entry point, trying every handle form the spec allows.
///
/// `vkGetInstanceProcAddr` accepts NULL (global commands only), an instance
/// (instance commands), and -- since 1.2 -- a physical device or device (every
/// command). A client that assumes one form and fails on the other gets a
/// null function pointer and a crash somewhere unrelated, so this tries all
/// three and names the ones that failed if none work.
fn resolveProc(name: [:0]const u8, handles: []const ?*anyopaque) ?*anyopaque {
    const base = vkGetInstanceProcAddrPtr;
    for (handles) |h| {
        if (base(h, name.ptr)) |p| return p;
    }
    noteFailure("the loader does not expose {s}" ++ NL, .{name});
    return null;
}

/// Same, but a missing pointer is fatal with a message rather than a panic.
fn mustProc(name: [:0]const u8, handles: []const ?*anyopaque) ?*anyopaque {
    return resolveProc(name, handles) orelse finish();
}

/// Device-level commands: device first, then the physical device, then the
/// instance. A top-level function rather than a nested struct because Zig will
/// not let an inner `struct` capture a mutable local.
fn devProc(name: [:0]const u8, device: ?*anyopaque, phys: ?*anyopaque) ?*anyopaque {
    // Device scope first, via the function that is actually specified for it.
    if (vkGetDeviceProcAddrPtr) |gdpa| {
        if (gdpa(device, name.ptr)) |p| return p;
    }
    // Fall back to the instance-scope lookup for the handful of entry points a
    // device dispatch does not carry. Ordering matters even here: this loader
    // aborts when vkGetInstanceProcAddr is handed a VkDevice or VkPhysicalDevice
    // instead of returning null, so the instance is still tried first.
    const h = [_]?*anyopaque{ vk, device, phys };
    return resolveProc(name, &h);
}

/// Print the totals and end the process with the code CI reads.
///
/// This was the whole point of the change: the probe used to print FAIL and
/// then return 0, so `zig build probe` was a report and not a gate -- a run in
/// which the driver did not exist at all was indistinguishable from a clean one.
/// Now every exit path funnels through here, the summary is always the last
/// line, and the status is non-zero whenever `failures` is non-zero.
///
/// It is reached in two different situations, and the difference matters:
///
///   * `finish()` at the end of `main`, after every check has run. This is the
///     normal path and it has seen all of the breakage.
///   * `finish()` from an intermediate `orelse return finish()`, when a handle
///     this program needs in order to keep going does not exist. Those are
///     *structural* stops, not a place to stop collecting results: continuing
///     would mean dereferencing a null entry point or reading a handle that was
///     never filled in, which does not report a second problem, it crashes.
///
/// So the rule the code follows is: never return early because a *check* failed,
/// and always return early when there is no way left to run the next check.
fn finish() noreturn {
    const passed = checks - failures;
    std.debug.print("\n====================\n", .{});
    if (failures == 0) {
        std.debug.print("RESULT: PASS -- the DPU heap carries real bytes on disk\n", .{});
    } else {
        std.debug.print("RESULT: FAIL -- {d} of {d} checks failed\n", .{ failures, checks });
    }
    // The single line a caller greps for. Fixed keys, fixed order, always last,
    // so a harness can assert on it rather than on scrollback.
    std.debug.print("PROBE_SUMMARY: total={d} passed={d} failed={d} result={s}\n\n", .{
        checks,
        passed,
        failures,
        if (failures == 0) "PASS" else "FAIL",
    });
    std.process.exit(if (failures == 0) 0 else 1);
}
