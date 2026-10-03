//! Smoke test: can Zig cImport the vendored Vulkan headers, and do the
//! structure sizes match the Vulkan 1.3 ABI for x86-64?
//!
//! The DPU defines no Vulkan types by hand. It cImports Khronos' own
//! `vulkan_core.h` so that `VkPhysicalDeviceLimits` and friends get the exact
//! layout the loader and every application expect. Getting one of those
//! structs wrong does not fail loudly — it silently feeds garbage to
//! `vulkaninfo` and to llama.cpp — which is why the sizes are asserted rather
//! than assumed.
//!
//! The numbers below are the spec's x86-64 sizes, not this compiler's opinion.
//! A mismatch means either the vendored header changed shape or the DPU is
//! being built for the wrong ABI.

const std = @import("std");

const c = @cImport({
    @cInclude("vulkan/vulkan_core.h");
});

test "vendored headers match the Vulkan 1.3 ABI" {
    try std.testing.expectEqual(@as(usize, 824), @sizeOf(c.VkPhysicalDeviceProperties));
    try std.testing.expectEqual(@as(usize, 504), @sizeOf(c.VkPhysicalDeviceLimits));
    try std.testing.expectEqual(@as(usize, 520), @sizeOf(c.VkPhysicalDeviceMemoryProperties));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(c.VkMemoryType));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(c.VkMemoryHeap));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(c.VkQueueFamilyProperties));
    try std.testing.expectEqual(@as(usize, 260), @sizeOf(c.VkExtensionProperties));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(c.VkApplicationInfo));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(c.VkInstanceCreateInfo));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(c.VkDeviceCreateInfo));
    try std.testing.expectEqual(@as(usize, 220), @sizeOf(c.VkPhysicalDeviceFeatures));
}

test "handles are pointers and device size is 64 bit" {
    // Dispatchable handles are opaque pointers on 64-bit, which is why the ICD
    // can hand back a pointer to its own state instead of a lookup table.
    try std.testing.expectEqual(@as(usize, @sizeOf(usize)), @sizeOf(c.VkInstance));
    try std.testing.expectEqual(@as(usize, @sizeOf(usize)), @sizeOf(c.VkPhysicalDevice));
    try std.testing.expectEqual(@as(usize, @sizeOf(usize)), @sizeOf(c.VkDevice));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(c.VkDeviceSize));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(c.VkBool32));
}

test "spec capacity constants are what the ICD advertises against" {
    try std.testing.expectEqual(@as(u32, 32), c.VK_MAX_MEMORY_TYPES);
    try std.testing.expectEqual(@as(u32, 16), c.VK_MAX_MEMORY_HEAPS);
    try std.testing.expectEqual(@as(u32, 256), c.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE);
    try std.testing.expectEqual(@as(u32, 256), c.VK_MAX_EXTENSION_NAME_SIZE);
    try std.testing.expectEqual(@as(u32, 16), c.VK_UUID_SIZE);
}

test "API version macros are the 1.3 ones the plan targets" {
    // Use the header's own accessors. Re-deriving the bit-packing by hand is
    // how the minor version gets read as 1027 instead of 3: MAJOR occupies
    // bits 22..28 and MINOR only 12..21, so masking MINOR with MAJOR's 0x7ff
    // mask spills the major number into it.
    try std.testing.expectEqual(@as(u32, 1), c.VK_API_VERSION_MAJOR(c.VK_API_VERSION_1_3));
    try std.testing.expectEqual(@as(u32, 3), c.VK_API_VERSION_MINOR(c.VK_API_VERSION_1_3));
}

test "memory property flags used by the ICD are the spec values" {
    // C enums cross into Zig as their underlying integer type, so these are
    // plain constants rather than something `@intFromEnum` accepts.
    try std.testing.expectEqual(@as(c_uint, 0x1), c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    try std.testing.expectEqual(@as(c_uint, 0x2), c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    try std.testing.expectEqual(@as(c_uint, 0x4), c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    try std.testing.expectEqual(@as(c_uint, 0x8), c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT);
}

test "queue family capability flags the ICD reports are the spec values" {
    // GRAPHICS is bit 0, not COMPUTE. The DPU exposes a compute-only queue,
    // and getting this backwards would make clients believe it can render.
    try std.testing.expectEqual(@as(c_uint, 0x1), c.VK_QUEUE_GRAPHICS_BIT);
    try std.testing.expectEqual(@as(c_uint, 0x2), c.VK_QUEUE_COMPUTE_BIT);
    try std.testing.expectEqual(@as(c_uint, 0x4), c.VK_QUEUE_TRANSFER_BIT);
    try std.testing.expectEqual(@as(c_uint, 0x8), c.VK_QUEUE_SPARSE_BINDING_BIT);
    try std.testing.expectEqual(@as(u32, 0x6), c.VK_QUEUE_COMPUTE_BIT | c.VK_QUEUE_TRANSFER_BIT);
}

test "device type the DPU reports as discrete" {
    // VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU is 2. Claiming INTEGRATED or
    // CPU would make clients pick different code paths than we want.
    try std.testing.expectEqual(@as(c_uint, 2), @as(c_uint, c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU));
}
