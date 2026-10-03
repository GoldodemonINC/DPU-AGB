import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()

old = 'const pfn_createdev: *const fn (*const c.VkDeviceCreateInfo, ?*const c.VkAllocationCallbacks, ?*?*anyopaque) callconv(.c) c_int ='
assert old in s, 'createdev typedef'
new = 'const pfn_createdev: *const fn (c.VkPhysicalDevice, *const c.VkDeviceCreateInfo, ?*const c.VkAllocationCallbacks, ?*?*anyopaque) callconv(.c) c_int ='
s = s.replace(old, new, 1)

old2 = 'const drc = pfn_createdev(&dci, null, @ptrCast(&device));'
assert old2 in s, 'createdev call'
new2 = 'const drc = pfn_createdev(@ptrCast(dpu_dev), &dci, null, @ptrCast(&device));'
s = s.replace(old2, new2, 1)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
