//! The DPU's Vulkan installable client driver.
//!
//! This is a user-mode ICD. It needs no kernel driver, no admin rights and no
//! code signing, which is the only reason it can exist on this machine: HVCI
//! is on, there is no WDK, and an unsigned kernel driver would never load.
//!
//! **What it is for.** `vulkaninfo` and llama.cpp discover GPUs through
//! `vkEnumeratePhysicalDevices` and the ggml backend registry, not through the
//! PnP tree. An ICD is therefore the entire mechanism by which an application
//! can come to believe the disk pool is a graphics device. Device Manager and
//! Task Manager visibility would need the signed WDDM driver from the last
//! phase, and are explicitly out of scope.
//!
//! **What it does not do.** It advertises one `VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU`
//! with a single `DEVICE_LOCAL` heap sized to the pool's current tier. It does
//! not yet execute compute. Until the compute path lands, a client that
//! allocates from this device will write real bytes to the pool and read them
//! back at pool speed — see the honesty note in `advertiseHeapSize`.
//!
//! **Why it does not wrap the Intel GPU.** The iGPU stays visible through its
//! own driver. This ICD adds a second, independent device rather than
//! intercepting the first, which keeps the loader's dispatch unambiguous and
//! means a bug here cannot break the user's existing Vulkan install.

const std = @import("std");
const win = @import("win");
const tiers = @import("tiers");
const mem = @import("memory.zig");
const exec = @import("exec.zig");

const c = @cImport({
    @cInclude("vulkan/vulkan_core.h");
});

/// Device identity. Any value works as long as it is stable and not another
/// vendor's, because the loader does not interpret it.
const DPU_VENDOR_ID: u32 = 0xD5D0;
const DPU_DEVICE_ID: u32 = 0x0001;
const DPU_DRIVER_VERSION: u32 = 1;

/// Loader ICD interface version this driver negotiates.
///
/// Version 4 is the last version that needs no extra entry points. Version 5
/// introduced `vk_icdEnumerateAdapterPhysicalDevices`, which only exists to
/// map a DXGI adapter LUID onto a physical device; since the DPU is not a DXGI
/// adapter there is nothing for it to map, and capping at 4 keeps the loader on
/// the path that enumerates every ICD's devices unconditionally.
/// Loader ICD interface version.
///
/// 5, not 4, and the reason is observable rather than aspirational. With the
/// entry point `vkEnumerateInstanceVersion` added, the loader stopped logging
/// `treating as a 1.0 ICD` and started logging this instead:
///
///     Driver dpu_icd.dll supports Vulkan 1.3, but only supports loader
///     interface version 4. Interface version 5 or newer required to support
///     this version of Vulkan (Policy #LDP_DRIVER_7)
///
/// Reporting 1.3 while holding interface 4 is worse than reporting 1.0: the
/// manifest and `VkPhysicalDeviceProperties::apiVersion` both say 1.3, and the
/// loader now believes them. Interface 5 is what makes that belief correct.
const ICD_INTERFACE_VERSION: u32 = 5;

/// Instance and physical device handles are dispatchable, which on 64-bit
/// means they are opaque pointers. Pointing them at our own singletons is both
/// legal and cheaper than a lookup table, and it means a client cannot
/// fabricate one that we would then trust.
/// `VK_LOADER_DATA`. Every dispatchable handle a driver returns -- instance,
/// physical device, device, queue -- must begin with a pointer-sized field
/// holding this value, because the loader reads the first word of each handle
/// to find its own dispatch table.
///
/// A driver that puts a small integer first instead gets its handles rejected:
/// `vkGetDeviceQueue` returns null and the application reports "no queue",
/// which is nowhere near the real fault. This cost a debugging session and is
/// worth writing down.
const VK_LOADER_DATA: usize = 0x01C0DEEE;

const Instance = struct {
    loader_data: *anyopaque = @ptrFromInt(VK_LOADER_DATA),
    sentinel: u32 = 0x44505501, // "DPU"
};

const PhysicalDevice = struct {
    loader_data: *anyopaque = @ptrFromInt(VK_LOADER_DATA),
    sentinel: u32 = 0x44505502,
    /// Bytes this device advertises as DEVICE_LOCAL. Read from the engine's
    /// tier state at load time.
    heap_bytes: u64,
};

const Queue = struct {
    loader_data: *anyopaque = @ptrFromInt(VK_LOADER_DATA),
    sentinel: u32 = 0x44505504,
    family: u32,
    index: u32,
};

const MAX_QUEUES = 16;

/// Per-`vkCreateDevice` state. Allocated so that two devices never alias, and
/// the queues live inside it rather than in a side allocation — `vkGetDeviceQueue`
/// receives the device handle, so an inline array makes handing back a queue a
/// bounds check and a pointer arithmetic step, nothing more.
const Device = struct {
    loader_data: *anyopaque = @ptrFromInt(VK_LOADER_DATA),
    sentinel: u32 = 0x44505503,
    queues: [MAX_QUEUES]Queue,
    queue_count: u32,
};

var instance_singleton = Instance{};
var physical_device_singleton: PhysicalDevice = .{ .heap_bytes = tiers.LADDER_GIB[0] * 1024 * 1024 * 1024 };

/// Where the pool lives. Mirrors the engine's own constant; the ICD runs in
/// other processes, so it cannot import the engine's configuration at runtime.
const POOL_DIR: []const u8 = "P:\\DPU";

// --------------------------------------------------------------- allocator

/// Handle allocation lives in [memory] so the driver has exactly one arena.
/// `vulkaninfo` creates and destroys devices, buffers, fences and command
/// buffers many times per run, and a general allocator inside a graphics driver
/// is a well-known source of teardown crashes.
/// Device handed out most recently, so `vkGetDeviceQueue` can recover the
/// queues from a bare handle. Single-threaded by design; see above.
var last_device: ?*Device = null;

// ----------------------------------------------------------- device claims

/// Read the tier the engine granted, falling back to the bottom of the ladder.
///
/// The fallback is deliberately small. An ICD that cannot find the engine's
/// state file still loads — the loader will not tolerate a driver that refuses
/// to initialise — but it should not advertise capacity nobody authorised.
fn advertiseHeapSize() u64 {
    const fallback = tiers.LADDER_GIB[0] * 1024 * 1024 * 1024;

    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}\\{s}", .{ POOL_DIR, tiers.state_filename }) catch
        return fallback;

    const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path) catch
        return fallback;
    defer std.heap.page_allocator.free(wide);

    // CreateFileW signals failure with INVALID_HANDLE_VALUE rather than null,
    // and the engine not having run yet is an ordinary state, not an error.
    const f = win.c.CreateFileW(
        wide.ptr,
        win.c.GENERIC_READ,
        win.c.FILE_SHARE_READ | win.c.FILE_SHARE_WRITE,
        null,
        win.c.OPEN_EXISTING,
        win.c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (f == win.c.INVALID_HANDLE_VALUE) return fallback;
    if (f == null) return fallback;
    defer _ = win.c.CloseHandle(f);

    var contents: [4096]u8 = undefined;
    var read: u32 = 0;
    if (win.c.ReadFile(f, &contents, contents.len, &read, null) == 0 or read == 0)
        return fallback;

    return tiers.parseState(contents[0..read]) orelse
        (tiers.LADDER_GIB[0] * 1024 * 1024 * 1024);
}

/// One-time process init. The loader guarantees it calls the negotiation entry
/// point before anything else, so this is the right place to read the tier.
fn ensureInitialised() void {
    if (physical_device_singleton.heap_bytes != tiers.LADDER_GIB[0] * 1024 * 1024 * 1024) return;
    physical_device_singleton.heap_bytes = advertiseHeapSize();
    mem.setAdvertisedHeap(physical_device_singleton.heap_bytes);
}

// ------------------------------------------------------------ entry points

/// Loader calls this first and may lower the version. Reporting failure here
/// makes the loader skip the driver entirely, which is the correct response to
/// a version it cannot speak.
export fn vk_icdNegotiateLoaderICDInterfaceVersion(pVersion: ?*u32) callconv(.c) c_int {
    ensureInitialised();
    if (pVersion) |v| {
        if (v.* > ICD_INTERFACE_VERSION) v.* = ICD_INTERFACE_VERSION;
    }
    return 0; // VK_SUCCESS
}

/// Resolve a global or instance-level entry point.
///
/// The loader passes a null instance for the handful of functions that must
/// work before an instance exists. Anything it does not recognise must come
/// back as null: returning a stub that silently succeeds is how an ICD ends up
/// lying to applications about what it supports.
export fn vk_icdGetInstanceProcAddr(instance: ?*anyopaque, pName: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    _ = instance;
    if (pName == null) return null;
    const name = std.mem.span(pName.?);

    const entry = entryLookup(name) orelse return null;
    return @ptrCast(@constCast(entry));
}

const Pfn = *const fn () callconv(.c) void;

fn entryLookup(name: []const u8) ?Pfn {
    const table = .{
        .{ "vkGetInstanceProcAddr", &vkGetInstanceProcAddrImpl },
        .{ "vkCreateInstance", &vkCreateInstanceImpl },
        .{ "vkEnumerateInstanceExtensionProperties", &vkEnumerateInstanceExtensionPropertiesImpl },
        .{ "vkEnumerateInstanceLayerProperties", &vkEnumerateInstanceLayerPropertiesImpl },
        .{ "vkEnumerateInstanceVersion", &vkEnumerateInstanceVersionImpl },
        .{ "vkEnumeratePhysicalDevices", &vkEnumeratePhysicalDevicesImpl },
        .{ "vkEnumeratePhysicalDeviceGroups", &vkEnumeratePhysicalDeviceGroupsImpl },
        .{ "vkEnumeratePhysicalDeviceGroupsKHR", &vkEnumeratePhysicalDeviceGroupsImpl },
        .{ "vkGetPhysicalDeviceProcAddr", &vk_icdGetPhysicalDeviceProcAddr },
        .{ "vkGetPhysicalDeviceProperties", &vkGetPhysicalDevicePropertiesImpl },
        .{ "vkGetPhysicalDeviceProperties2", &vkGetPhysicalDeviceProperties2Impl },
        .{ "vkGetPhysicalDeviceProperties2KHR", &vkGetPhysicalDeviceProperties2Impl },
        .{ "vkGetPhysicalDeviceFeatures", &vkGetPhysicalDeviceFeaturesImpl },
        .{ "vkGetPhysicalDeviceFeatures2", &vkGetPhysicalDeviceFeatures2Impl },
        .{ "vkGetPhysicalDeviceFeatures2KHR", &vkGetPhysicalDeviceFeatures2Impl },
        .{ "vkGetPhysicalDeviceMemoryProperties", &vkGetPhysicalDeviceMemoryPropertiesImpl },
        .{ "vkGetPhysicalDeviceMemoryProperties2", &vkGetPhysicalDeviceMemoryProperties2Impl },
        .{ "vkGetPhysicalDeviceMemoryProperties2KHR", &vkGetPhysicalDeviceMemoryProperties2Impl },
        .{ "vkEnumerateDeviceExtensionProperties", &vkEnumerateDeviceExtensionPropertiesImpl },
        .{ "vkEnumerateDeviceLayerProperties", &vkEnumerateDeviceLayerPropertiesImpl },
        .{ "vkEnumerateDeviceQueueFamilies", &vkEnumerateDeviceQueueFamiliesImpl },
        .{ "vkGetPhysicalDeviceQueueFamilyProperties", &vkEnumerateDeviceQueueFamiliesImpl },
        .{ "vkGetPhysicalDeviceFormatProperties", &vkGetPhysicalDeviceFormatPropertiesImpl },
        .{ "vkGetPhysicalDeviceImageFormatProperties", &vkGetPhysicalDeviceImageFormatPropertiesImpl },
        .{ "vkGetPhysicalDeviceImageFormatProperties2", &vkGetPhysicalDeviceImageFormatProperties2Impl },
        .{ "vkGetPhysicalDeviceSparseImageFormatProperties", &vkGetPhysicalDeviceSparseImageFormatPropertiesImpl },
        .{ "vkGetPhysicalDeviceSparseImageFormatProperties2", &vkGetPhysicalDeviceSparseImageFormatProperties2Impl },
        .{ "vkGetPhysicalDeviceExternalBufferProperties", &vkGetPhysicalDeviceExternalBufferPropertiesImpl },
        .{ "vkGetPhysicalDeviceExternalFenceProperties", &vkGetPhysicalDeviceExternalFencePropertiesImpl },
        .{ "vkGetPhysicalDeviceExternalSemaphoreProperties", &vkGetPhysicalDeviceExternalSemaphorePropertiesImpl },
        .{ "vkGetPhysicalDeviceToolProperties", &vkGetPhysicalDeviceToolPropertiesImpl },
        .{ "vkCreateDevice", &vkCreateDeviceImpl },
        .{ "vkDestroyDevice", &vkDestroyDeviceImpl },
        .{ "vkGetDeviceProcAddr", &vkGetDeviceProcAddrImpl },
        .{ "vkGetDeviceQueue", &vkGetDeviceQueueImpl },
        .{ "vkGetDeviceQueue2", &vkGetDeviceQueue2Impl },
        .{ "vkDestroyInstance", &vkDestroyInstanceImpl },
        // --- execution layer: memory ---
        .{ "vkAllocateMemory", &exec.vkAllocateMemoryImpl },
        .{ "vkFreeMemory", &exec.vkFreeMemoryImpl },
        .{ "vkMapMemory", &exec.vkMapMemoryImpl },
        .{ "vkUnmapMemory", &exec.vkUnmapMemoryImpl },
        .{ "vkFlushMappedMemoryRanges", &exec.vkFlushMappedMemoryRangesImpl },
        .{ "vkInvalidateMappedMemoryRanges", &exec.vkInvalidateMappedMemoryRangesImpl },
        .{ "vkGetDeviceMemoryCommitment", &exec.vkGetDeviceMemoryCommitmentImpl },
        // --- execution layer: buffers ---
        .{ "vkCreateBuffer", &exec.vkCreateBufferImpl },
        .{ "vkDestroyBuffer", &exec.vkDestroyBufferImpl },
        .{ "vkGetBufferMemoryRequirements", &exec.vkGetBufferMemoryRequirementsImpl },
        .{ "vkGetBufferMemoryRequirements2", &exec.vkGetBufferMemoryRequirements2Impl },
        .{ "vkGetDeviceBufferMemoryRequirements", &exec.vkGetDeviceBufferMemoryRequirementsImpl },
        .{ "vkBindBufferMemory", &exec.vkBindBufferMemoryImpl },
        .{ "vkBindBufferMemory2", &exec.vkBindBufferMemory2Impl },
        // --- execution layer: command buffers and sync ---
        .{ "vkCreateCommandPool", &exec.vkCreateCommandPoolImpl },
        .{ "vkDestroyCommandPool", &exec.vkDestroyCommandPoolImpl },
        .{ "vkAllocateCommandBuffers", &exec.vkAllocateCommandBuffersImpl },
        .{ "vkFreeCommandBuffers", &exec.vkFreeCommandBuffersImpl },
        .{ "vkBeginCommandBuffer", &exec.vkBeginCommandBufferImpl },
        .{ "vkEndCommandBuffer", &exec.vkEndCommandBufferImpl },
        .{ "vkResetCommandBuffer", &exec.vkResetCommandBufferImpl },
        .{ "vkCreateFence", &exec.vkCreateFenceImpl },
        .{ "vkDestroyFence", &exec.vkDestroyFenceImpl },
        .{ "vkGetFenceStatus", &exec.vkGetFenceStatusImpl },
        .{ "vkResetFences", &exec.vkResetFencesImpl },
        .{ "vkWaitForFences", &exec.vkWaitForFencesImpl },
        // --- execution layer: the copy path ---
        .{ "vkCmdCopyBuffer", &exec.vkCmdCopyBufferImpl },
        .{ "vkCmdWriteBuffer", &exec.vkCmdWriteBufferImpl },
        .{ "vkCmdFillBuffer", &exec.vkCmdFillBufferImpl },
        .{ "vkCmdPipelineBarrier", &exec.vkCmdPipelineBarrierImpl },
        .{ "vkQueueSubmit", &exec.vkQueueSubmitImpl },
        .{ "vkQueueWaitIdle", &exec.vkQueueWaitIdleImpl },
        .{ "vkQueueBindSparse", &exec.vkQueueBindSparseImpl },
        .{ "vkDeviceWaitIdle", &exec.vkDeviceWaitIdleImpl },
        // --- present, and refused with a definite status ---
        .{ "vkCreateShaderModule", &exec.vkCreateShaderModuleImpl },
        .{ "vkCreateComputePipelines", &exec.vkCreateComputePipelinesImpl },
        .{ "vkCreateGraphicsPipelines", &exec.vkCreateGraphicsPipelinesImpl },
    };

    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            return @ptrCast(entry[1]);
        }
    }
    return null;
}

/// Resolves device-level entry points. The loader prefers this over
/// `vkGetDeviceProcAddr` for dispatchable physical-device queries.
export fn vk_icdGetPhysicalDeviceProcAddr(_: ?*anyopaque, pName: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (pName == null) return null;
    const name = std.mem.span(pName.?);

    // Interface version 5 requires this to return a pointer only for commands
    // whose first dispatchable argument is a `VkPhysicalDevice`, and null for
    // everything else -- including commands it does not recognise.
    //
    // An allowlist, not a denylist. The earlier version excluded six
    // instance-scope names and let the rest of the table through, which meant
    // a non-null answer for `vkEnumeratePhysicalDevices` (whose dispatchable
    // argument is an instance) and for every device command such as
    // `vkCmdWriteBuffer`. A non-null answer tells the loader it may build a
    // physical-device trampoline, and calling a device command through that
    // trampoline dereferences the wrong handle: it is a crash, not an error.
    if (!isPhysicalDeviceScope(name)) return null;

    const entry = entryLookup(name) orelse return null;
    return @ptrCast(@constCast(entry));
}

/// The commands this driver routes whose first dispatchable argument is a
/// `VkPhysicalDevice`.
///
/// Everything else -- instance commands, device commands, queue commands --
/// must come back null from `vk_icdGetPhysicalDeviceProcAddr`.
fn isPhysicalDeviceScope(name: []const u8) bool {
    const physical_device_scope = [_][]const u8{
        "vkGetPhysicalDeviceProcAddr",
        "vkGetPhysicalDeviceProperties",
        "vkGetPhysicalDeviceProperties2",
        "vkGetPhysicalDeviceProperties2KHR",
        "vkGetPhysicalDeviceFeatures",
        "vkGetPhysicalDeviceFeatures2",
        "vkGetPhysicalDeviceFeatures2KHR",
        "vkGetPhysicalDeviceMemoryProperties",
        "vkGetPhysicalDeviceMemoryProperties2",
        "vkGetPhysicalDeviceMemoryProperties2KHR",
        "vkEnumerateDeviceExtensionProperties",
        "vkEnumerateDeviceLayerProperties",
        "vkEnumerateDeviceQueueFamilies",
        "vkGetPhysicalDeviceQueueFamilyProperties",
        "vkGetPhysicalDeviceFormatProperties",
        "vkGetPhysicalDeviceImageFormatProperties",
        "vkGetPhysicalDeviceImageFormatProperties2",
        "vkGetPhysicalDeviceSparseImageFormatProperties",
        "vkGetPhysicalDeviceSparseImageFormatProperties2",
        "vkGetPhysicalDeviceExternalBufferProperties",
        "vkGetPhysicalDeviceExternalFenceProperties",
        "vkGetPhysicalDeviceExternalSemaphoreProperties",
        "vkGetPhysicalDeviceToolProperties",
        "vkGetPhysicalDeviceSurfaceSupportKHR",
        "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
        "vkGetPhysicalDeviceSurfaceFormatsKHR",
        "vkGetPhysicalDeviceSurfacePresentModesKHR",
        "vkEnumeratePhysicalDeviceGroups",
        "vkEnumeratePhysicalDeviceGroupsKHR",
    };
    for (physical_device_scope) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

// --------------------------------------------------------------- instance

fn vkGetInstanceProcAddrImpl(_: ?*anyopaque, pName: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (pName == null) return null;
    return vk_icdGetInstanceProcAddr(null, pName);
}

fn vkCreateInstanceImpl(
    _: ?*const c.VkInstanceCreateInfo,
    _: ?*const c.VkAllocationCallbacks,
    pInstance: ?*?*anyopaque,
) callconv(.c) c_int {
    // Validation of layers and extensions is the loader's job by the time we
    // are called; an ICD that duplicates it usually gets it wrong.
    if (pInstance) |out| out.* = @ptrCast(&instance_singleton);
    return 0; // VK_SUCCESS
}

fn vkDestroyInstanceImpl(_: ?*anyopaque) callconv(.c) void {
    // The singleton carries no per-instance resources. Intentionally a no-op
    // rather than tearing down state a second instance would still share.
}

fn vkEnumerateInstanceExtensionPropertiesImpl(
    _: ?[*:0]const u8,
    pCount: ?*u32,
    pProps: ?[*]c.VkExtensionProperties,
) callconv(.c) c_int {
    // The DPU adds no instance extensions of its own. Reporting an accurate
    // zero beats inventing something to look capable.
    if (pCount) |n| n.* = 0;
    _ = pProps;
    return 0;
}

/// The instance API version this driver implements.
///
/// `vk_icd.json` declares `"api_version":"1.3"`, and that claim is only
/// confirmed if the ICD answers this call. Without the entry point the loader
/// falls back to assuming 1.0 and logs `treating as a 1.0 ICD`, which is the
/// difference between a driver that says what it is and one that is taken at
/// its word.
///
/// The version returned has to agree with the two other places the driver
/// states it: `vk_icd.json`'s `"api_version":"1.3"` and
/// `VkPhysicalDeviceProperties::apiVersion`, which `fillProperties` already
/// sets to `VK_API_VERSION_1_3`. Answering 1.0 here would not be caution, it
/// would be a third number that disagrees with the other two -- and the loader
/// uses the *lower* of the manifest and this answer, so under-reporting here
/// silently caps a driver that advertises 1.3 everywhere else.
fn vkEnumerateInstanceVersionImpl(pApiVersion: ?*u32) callconv(.c) c_int {
    const p = pApiVersion orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    p.* = c.VK_API_VERSION_1_3;
    return c.VK_SUCCESS;
}

fn vkEnumerateInstanceLayerPropertiesImpl(pCount: ?*u32, _: ?[*]c.VkLayerProperties) callconv(.c) c_int {
    if (pCount) |n| n.* = 0;
    return 0;
}

fn vkEnumeratePhysicalDevicesImpl(
    _: ?*anyopaque,
    pCount: ?*u32,
    pDevices: ?[*]?*anyopaque,
) callconv(.c) c_int {
    // The count is written whether or not an array was supplied, and the array
    // is only touched when the caller has already asked for room. Writing
    // slot 0 regardless is a write past a zero-sized array.
    if (pCount) |n| n.* = 1;
    if (pDevices) |list| {
        if (pCount == null or pCount.?.* >= 1) list[0] = @ptrCast(&physical_device_singleton);
    }
    return 0;
}

fn vkEnumeratePhysicalDeviceGroupsImpl(
    _: ?*anyopaque,
    pCount: ?*u32,
    pGroups: ?[*]c.VkPhysicalDeviceGroupProperties,
) callconv(.c) c_int {
    if (pCount) |n| n.* = 1;
    if (pGroups) |g| {
        g[0] = std.mem.zeroes(c.VkPhysicalDeviceGroupProperties);
        g[0].sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GROUP_PROPERTIES;
        g[0].physicalDeviceCount = 1;
        g[0].physicalDevices[0] = @ptrCast(&physical_device_singleton);
    }
    return 0;
}

// --------------------------------------------------------- physical device

fn fillProperties(p: *c.VkPhysicalDeviceProperties) void {
    p.* = std.mem.zeroes(c.VkPhysicalDeviceProperties);
    p.apiVersion = c.VK_API_VERSION_1_3;
    p.driverVersion = DPU_DRIVER_VERSION;
    p.vendorID = DPU_VENDOR_ID;
    p.deviceID = DPU_DEVICE_ID;
    p.deviceType = c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;

    const name = "DPU Disk-Dependent Processing Unit";
    const n = @min(name.len, c.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE);
    @memcpy(p.deviceName[0..n], name[0..n]);
    @memset(p.deviceName[n..c.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE], 0);

    // A stable, obviously-synthetic UUID. The spec requires it to be
    // persistent across runs; deriving it from anything machine-specific would
    // make the device look like a different GPU after a reboot.
    @memset(&p.pipelineCacheUUID, 0);
    const tag = "DPU-pool";
    @memcpy(p.pipelineCacheUUID[0..tag.len], tag[0..]);

    // Limits. The honest floor: this is a compute-only device with one queue
    // family, and understating rather than overstating keeps clients from
    // building pipelines for capabilities that are not there.
    const L = &p.limits;
    L.maxImageDimension1D = 16384;
    L.maxImageDimension2D = 16384;
    L.maxImageDimension3D = 2048;
    L.maxImageDimensionCube = 16384;
    L.maxImageArrayLayers = 2048;
    L.maxTexelBufferElements = 1 << 27;
    L.maxUniformBufferRange = 64 * 1024;
    L.maxStorageBufferRange = 1 << 30;
    L.maxPushConstantsSize = 256;
    L.maxMemoryAllocationCount = 4096;
    L.maxSamplerAllocationCount = 4000;
    L.bufferImageGranularity = 1;
    L.sparseAddressSpaceSize = 0;
    L.maxBoundDescriptorSets = 8;
    L.maxPerStageDescriptorSamplers = 16;
    L.maxPerStageDescriptorUniformBuffers = 16;
    L.maxPerStageDescriptorStorageBuffers = 8;
    L.maxPerStageDescriptorSampledImages = 16;
    L.maxPerStageDescriptorSamplers = 16;
    L.maxPerStageDescriptorStorageImages = 8;
    L.maxPerStageDescriptorInputAttachments = 8;
    L.maxPerStageResources = 128;
    L.maxDescriptorSetSamplers = 16;
    L.maxDescriptorSetUniformBuffers = 128;
    L.maxDescriptorSetUniformBuffersDynamic = 8;
    L.maxDescriptorSetStorageBuffers = 8;
    L.maxDescriptorSetStorageBuffersDynamic = 4;
    L.maxDescriptorSetSampledImages = 16;
    L.maxDescriptorSetStorageImages = 8;
    L.maxDescriptorSetInputAttachments = 8;
    L.maxVertexInputAttributes = 32;
    L.maxVertexInputBindings = 32;
    L.maxVertexInputAttributeOffset = 2047;
    L.maxVertexInputBindingStride = 2048;
    L.maxVertexOutputComponents = 128;
    L.maxTessellationGenerationLevel = 0;
    L.maxTessellationPatchSize = 0;
    L.maxTessellationControlPerVertexInputComponents = 0;
    L.maxTessellationControlPerVertexOutputComponents = 0;
    L.maxTessellationControlPerPatchOutputComponents = 0;
    L.maxTessellationControlTotalOutputComponents = 0;
    L.maxTessellationEvaluationInputComponents = 0;
    L.maxTessellationEvaluationOutputComponents = 0;
    L.maxGeometryShaderInvocations = 0;
    L.maxGeometryInputComponents = 0;
    L.maxGeometryOutputComponents = 0;
    L.maxGeometryOutputVertices = 0;
    L.maxGeometryTotalOutputComponents = 0;
    L.maxFragmentInputComponents = 128;
    L.maxFragmentOutputAttachments = 8;
    L.maxFragmentDualSrcAttachments = 0;
    L.maxFragmentCombinedOutputResources = 16;
    L.maxComputeSharedMemorySize = 32 * 1024;
    L.maxComputeWorkGroupCount = [_]u32{ 65535, 65535, 65535 };
    L.maxComputeWorkGroupInvocations = 256;
    L.maxComputeWorkGroupSize = [_]u32{ 256, 256, 64 };
    L.subPixelPrecisionBits = 0;
    L.subTexelPrecisionBits = 0;
    L.mipmapPrecisionBits = 0;
    L.maxDrawIndexedIndexValue = 0;
    L.maxDrawIndirectCount = 0;
    L.maxSamplerLodBias = 0;
    L.maxSamplerAnisotropy = 1;
    L.maxViewports = 1;
    L.maxViewportDimensions = [_]u32{ 16384, 16384 };
    L.viewportBoundsRange = [_]f32{ 0, 0 };
    L.viewportSubPixelBits = 0;
    L.minMemoryMapAlignment = 4096;
    L.minTexelBufferOffsetAlignment = 256;
    L.minUniformBufferOffsetAlignment = 256;
    L.minStorageBufferOffsetAlignment = 256;
    L.minTexelOffset = -8;
    L.maxTexelOffset = 7;
    L.minTexelGatherOffset = -8;
    L.maxTexelGatherOffset = 7;
    L.minInterpolationOffset = -0.5;
    L.maxInterpolationOffset = 0.5;
    L.subPixelInterpolationOffsetBits = 4;
    L.maxFramebufferWidth = 16384;
    L.maxFramebufferHeight = 16384;
    L.maxFramebufferLayers = 2048;
    L.framebufferColorSampleCounts = c.VK_SAMPLE_COUNT_1_BIT;
    L.framebufferDepthSampleCounts = c.VK_SAMPLE_COUNT_1_BIT;
    L.framebufferStencilSampleCounts = c.VK_SAMPLE_COUNT_1_BIT;
    L.framebufferNoAttachmentsSampleCounts = c.VK_SAMPLE_COUNT_1_BIT;
    L.maxColorAttachments = 8;
    L.sampledImageColorSampleCounts = c.VK_SAMPLE_COUNT_1_BIT;
    L.sampledImageIntegerSampleCounts = c.VK_SAMPLE_COUNT_1_BIT;
    L.sampledImageDepthSampleCounts = c.VK_SAMPLE_COUNT_1_BIT;
    L.sampledImageStencilSampleCounts = c.VK_SAMPLE_COUNT_1_BIT;
    L.storageImageSampleCounts = c.VK_SAMPLE_COUNT_1_BIT;
    L.maxSampleMaskWords = 1;
    L.timestampComputeAndGraphics = c.VK_TRUE;
    L.timestampPeriod = 1.0;
    L.maxClipDistances = 8;
    L.maxCullDistances = 8;
    L.maxCombinedClipAndCullDistances = 8;
    L.discreteQueuePriorities = 2;
    L.pointSizeRange = [_]f32{ 0, 0 };
    L.lineWidthRange = [_]f32{ 0, 0 };
    L.pointSizeGranularity = 0;
    L.lineWidthGranularity = 0;
    L.strictLines = c.VK_FALSE;
    L.standardSampleLocations = c.VK_TRUE;
    L.optimalBufferCopyOffsetAlignment = 4096;
    L.optimalBufferCopyRowPitchAlignment = 4096;
    L.nonCoherentAtomSize = 64;

    p.sparseProperties.residencyStandard2DBlockShape = c.VK_FALSE;
    p.sparseProperties.residencyStandard2DMultisampleBlockShape = c.VK_FALSE;
    p.sparseProperties.residencyStandard3DBlockShape = c.VK_FALSE;
    p.sparseProperties.residencyAlignedMipSize = c.VK_FALSE;
    p.sparseProperties.residencyNonResidentStrict = c.VK_FALSE;
}

fn vkGetPhysicalDevicePropertiesImpl(_: ?*anyopaque, p: ?*c.VkPhysicalDeviceProperties) callconv(.c) void {
    if (p) |out| fillProperties(out);
}

fn vkGetPhysicalDeviceProperties2Impl(
    _: ?*anyopaque,
    p: ?*c.VkPhysicalDeviceProperties2,
) callconv(.c) void {
    const out = p orelse return;
    if (out.sType != c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2) return;
    fillProperties(&out.properties);
    // pNext is deliberately left as the caller sent it. Zeroed extension
    // structs read as "not supported", which is the truth for all of them.
}

fn vkGetPhysicalDeviceFeaturesImpl(_: ?*anyopaque, p: ?*c.VkPhysicalDeviceFeatures) callconv(.c) void {
    const out = p orelse return;
    out.* = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
    // Nothing is claimed. A compute device that reports no features will be
    // driven down the most conservative path, which is where it belongs until
    // the compute path actually exists.
}

fn vkGetPhysicalDeviceFeatures2Impl(_: ?*anyopaque, p: ?*c.VkPhysicalDeviceFeatures2) callconv(.c) void {
    const out = p orelse return;
    if (out.sType != c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) return;
    vkGetPhysicalDeviceFeaturesImpl(null, &out.features);
}

fn vkGetPhysicalDeviceMemoryPropertiesImpl(
    _: ?*anyopaque,
    p: ?*c.VkPhysicalDeviceMemoryProperties,
) callconv(.c) void {
    const out = p orelse return;
    out.* = std.mem.zeroes(c.VkPhysicalDeviceMemoryProperties);
    // Clamped against the ABI maximum rather than against itself. The old second
    // line was `@min(x, x)` immediately after assigning x -- a bounds check
    // that cannot fail, which is the worst kind: it reads as protection and
    // protects nothing.
    out.memoryTypeCount = @min(mem.MEMORY_TYPE_COUNT, c.VK_MAX_MEMORY_TYPES);
    out.memoryTypes[0] = .{
        // The pool. Not host-visible, and deliberately so: a client that could
        // map this directly would never pay the disk latency, and the whole
        // premise of the device would be false.
        .propertyFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .heapIndex = mem.HEAP_DEVICE_LOCAL,
    };
    out.memoryTypes[1] = .{
        // Staging. Every real driver has one, and it is how a client gets bytes
        // into and out of the pool: fill this, then vkCmdCopyBuffer.
        .propertyFlags = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
            c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
        .heapIndex = mem.HEAP_HOST,
    };

    out.memoryHeapCount = @min(mem.HEAP_COUNT, c.VK_MAX_MEMORY_HEAPS);
    out.memoryHeaps[mem.HEAP_DEVICE_LOCAL] = .{
        // The pool's granted tier. This is the number that decides how large a
        // model llama.cpp will try to offload, so it has to be the tier the
        // engine actually granted — not the compile-time default.
        .size = mem.deviceHeapBytes(),
        .flags = c.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT,
    };
    out.memoryHeaps[mem.HEAP_HOST] = .{
        .size = mem.hostHeapBytes(),
        .flags = 0,
    };
}

fn vkGetPhysicalDeviceMemoryProperties2Impl(
    _: ?*anyopaque,
    p: ?*c.VkPhysicalDeviceMemoryProperties2,
) callconv(.c) void {
    const out = p orelse return;
    if (out.sType != c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2) return;
    vkGetPhysicalDeviceMemoryPropertiesImpl(null, &out.memoryProperties);
}

fn vkEnumerateDeviceExtensionPropertiesImpl(
    _: ?*anyopaque,
    _: ?[*:0]const u8,
    pCount: ?*u32,
    pProps: ?[*]c.VkExtensionProperties,
) callconv(.c) c_int {
    if (pCount) |n| n.* = 0;
    _ = pProps;
    return 0;
}

fn vkEnumerateDeviceLayerPropertiesImpl(pCount: ?*u32, _: ?[*]c.VkLayerProperties) callconv(.c) c_int {
    if (pCount) |n| n.* = 0;
    return 0;
}

fn vkEnumerateDeviceQueueFamiliesImpl(
    _: ?*anyopaque,
    pCount: ?*u32,
    pProps: ?[*]c.VkQueueFamilyProperties,
) callconv(.c) c_int {
    if (pCount) |n| n.* = 1;
    if (pProps) |p| {
        if (pCount != null and pCount.?.* < 1) return 0;
        p[0] = .{
            // Compute and transfer, deliberately not graphics. A graphics bit
            // would invite clients to build render pipelines against a device
            // that cannot present anything.
            .queueFlags = c.VK_QUEUE_COMPUTE_BIT | c.VK_QUEUE_TRANSFER_BIT,
            .queueCount = 1,
            .timestampValidBits = 64,
            .minImageTransferGranularity = .{ .width = 1, .height = 1, .depth = 1 },
        };
    }
    return 0;
}

fn vkGetPhysicalDeviceFormatPropertiesImpl(
    _: ?*anyopaque,
    format: c.VkFormat,
    p: ?*c.VkFormatProperties,
) callconv(.c) void {
    _ = format;
    const out = p orelse return;
    // No formats are advertised. The compute path is buffer-only, and claiming
    // image support would be a claim this device cannot honour.
    out.* = std.mem.zeroes(c.VkFormatProperties);
}

fn vkGetPhysicalDeviceImageFormatPropertiesImpl(
    _: ?*anyopaque,
    _: c.VkFormat,
    _: c.VkImageType,
    _: c.VkImageTiling,
    _: c.VkImageUsageFlags,
    _: c.VkImageCreateFlags,
    p: ?*c.VkImageFormatProperties,
) callconv(.c) c_int {
    if (p) |out| out.* = std.mem.zeroes(c.VkImageFormatProperties);
    return -9; // VK_ERROR_FORMAT_NOT_SUPPORTED
}

fn vkGetPhysicalDeviceImageFormatProperties2Impl(
    _: ?*anyopaque,
    _: ?*const c.VkPhysicalDeviceImageFormatInfo2,
    p: ?*c.VkImageFormatProperties2,
) callconv(.c) c_int {
    if (p) |out| {
        out.imageFormatProperties = std.mem.zeroes(c.VkImageFormatProperties);
        if (out.pNext != null) return c.VK_ERROR_EXTENSION_NOT_PRESENT;
    }
    return -9; // VK_ERROR_FORMAT_NOT_SUPPORTED
}

fn vkGetPhysicalDeviceSparseImageFormatPropertiesImpl(
    _: ?*anyopaque,
    _: c.VkFormat,
    _: c.VkImageType,
    _: c.VkSampleCountFlagBits,
    _: c.VkImageUsageFlags,
    _: c.VkImageTiling,
    pCount: ?*u32,
    pProps: ?[*]c.VkSparseImageFormatProperties,
) callconv(.c) void {
    if (pCount) |n| n.* = 0;
    _ = pProps;
}

fn vkGetPhysicalDeviceSparseImageFormatProperties2Impl(
    _: ?*anyopaque,
    pCount: ?*u32,
    pProps: ?[*]c.VkSparseImageFormatProperties2,
) callconv(.c) void {
    if (pCount) |n| n.* = 0;
    _ = pProps;
}

fn vkGetPhysicalDeviceExternalBufferPropertiesImpl(
    _: ?*anyopaque,
    _: ?*c.VkPhysicalDeviceExternalBufferInfo,
    p: ?*c.VkExternalBufferProperties,
) callconv(.c) void {
    const out = p orelse return;
    out.* = std.mem.zeroes(c.VkExternalBufferProperties);
}

fn vkGetPhysicalDeviceExternalFencePropertiesImpl(
    _: ?*anyopaque,
    _: ?*c.VkPhysicalDeviceExternalFenceInfo,
    p: ?*c.VkExternalFenceProperties,
) callconv(.c) void {
    const out = p orelse return;
    out.* = std.mem.zeroes(c.VkExternalFenceProperties);
}

fn vkGetPhysicalDeviceExternalSemaphorePropertiesImpl(
    _: ?*anyopaque,
    _: ?*c.VkPhysicalDeviceExternalSemaphoreInfo,
    p: ?*c.VkExternalSemaphoreProperties,
) callconv(.c) void {
    const out = p orelse return;
    out.* = std.mem.zeroes(c.VkExternalSemaphoreProperties);
}

fn vkGetPhysicalDeviceToolPropertiesImpl(
    _: ?*anyopaque,
    pCount: ?*u32,
    pProps: ?[*]c.VkPhysicalDeviceToolProperties,
) callconv(.c) c_int {
    if (pCount) |n| n.* = 0;
    _ = pProps;
    return 0;
}

// ----------------------------------------------------------------- device

fn vkCreateDeviceImpl(
    device: ?*anyopaque,
    pCreateInfo: ?*const c.VkDeviceCreateInfo,
    _: ?*const c.VkAllocationCallbacks,
    pDevice: ?*?*anyopaque,
) callconv(.c) c_int {
    const out = pDevice orelse return -1; // VK_ERROR_INITIALIZATION_FAILED
    const info = pCreateInfo orelse return -1;

    // The process arena is recycled here, which is the only point at which it
    // is safe: Vulkan requires every object created from a device to be
    // destroyed before the device itself. Without this the 512 KiB arena was
    // allocated once per device and never given back, so an application that
    // creates and destroys devices in a loop -- vulkaninfo does, repeatedly --
    // ran the driver out of handle space partway through its own run.
    mem.arenaReset();

    var wanted: u32 = 1;
    if (info.queueCreateInfoCount > 0 and info.pQueueCreateInfos != null) {
        const qci = info.pQueueCreateInfos[0];
        // One family exists and it is index 0. A client asking for anything
        // else would be about to dispatch to a queue that does not exist.
        if (qci.queueFamilyIndex != 0) return -9; // VK_ERROR_INITIALIZATION_FAILED
        wanted = @min(qci.queueCount, MAX_QUEUES);
    }

    const raw = mem.arenaAlloc(@sizeOf(Device)) orelse return -2; // VK_ERROR_OUT_OF_HOST_MEMORY
    const dev: *Device = @ptrCast(@alignCast(raw));
    // Explicit initialisation, NOT `std.mem.zeroes`. A zeroed `loader_data` is
    // not a shape problem to work around; it is exactly the handle the loader
    // rejects. `zeroes` would also clear `sentinel`, which is the guard
    // `vkGetDeviceQueue` uses to refuse a fabricated handle -- so the device
    // would pass creation and then report "no queue", with no error anywhere.
    dev.* = .{
        .loader_data = @ptrFromInt(VK_LOADER_DATA),
        .sentinel = 0x44505503,
        .queues = undefined,
        .queue_count = wanted,
    };
    // Fill every slot, not just the first `wanted`. The surplus is never handed
    // out, but a queue carrying a null `loader_data` is a trap for anything
    // that later walks the array looking for a free one.
    for (0..MAX_QUEUES) |i| {
        dev.queues[i] = .{ .family = 0, .index = @intCast(i) };
    }

    // Stash the device so vkGetDeviceQueue, which only gets the handle the
    // client kept, can find the queues again.
    last_device = dev;
    out.* = @ptrCast(dev);
    _ = device;
    return 0;
}

fn vkDestroyDeviceImpl(handle: ?*anyopaque, _: ?*const c.VkAllocationCallbacks) callconv(.c) void {
    if (handle != null and @intFromPtr(handle) == @intFromPtr(last_device)) last_device = null;
    // Backing store is a thread-local arena reused by the next vkCreateDevice.
    // Device objects are tiny and short-lived; tracking allocation order to free
    // them exactly would buy nothing over reusing one slot per thread.
}

fn vkGetDeviceProcAddrImpl(_: ?*anyopaque, pName: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (pName == null) return null;
    const entry = entryLookup(std.mem.span(pName.?)) orelse return null;
    return @ptrCast(@constCast(entry));
}

fn vkGetDeviceQueueImpl(
    handle: ?*anyopaque,
    family: u32,
    index: u32,
    pQueue: ?*?*anyopaque,
) callconv(.c) void {
    const out = pQueue orelse return;
    const dev: *Device = @ptrCast(@alignCast(handle orelse {
        out.* = null;
        return;
    }));
    // Out-of-range requests yield a null queue, which is what the spec asks for
    // rather than an error return: vkGetDeviceQueue has no VkResult.
    if (dev.sentinel != 0x44505503 or family != 0 or index >= dev.queue_count) {
        out.* = null;
        return;
    }
    out.* = @ptrCast(&dev.queues[index]);
    last_device = dev;
}

fn vkGetDeviceQueue2Impl(
    device: ?*anyopaque,
    pQueueInfo: ?*const c.VkDeviceQueueInfo2,
    pQueue: ?*?*anyopaque,
) callconv(.c) void {
    const out = pQueue orelse return;
    const info = pQueueInfo orelse return;
    // The device handle is this command's first argument, exactly as in
    // vkGetDeviceQueue. It used to be dropped on the floor here, and the
    // callee treats a null device as "no queue" rather than as an error --
    // vkGetDeviceQueue has no VkResult to fail with. The net effect was that
    // every client using vkGetDeviceQueue2 got VK_NULL_HANDLE, which is to say
    // every client of a device advertising API 1.3.
    vkGetDeviceQueueImpl(device, info.queueFamilyIndex, info.queueIndex, out);
}

// --------------------------------------------------------------- lifetime

export fn DPU_ICD_ABI_MARKER() callconv(.c) void {
    // Present so that `zig build` or a PE export dump can prove the three
    // vk_icd entry points above are the ones the loader will find. The body is
    // empty on purpose; this exists to be seen in a symbol table.
    mem.arenaReset();
}
