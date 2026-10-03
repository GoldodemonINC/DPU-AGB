import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()
fixes = [
 ('const pfn_free: *const fn (c.VkDeviceMemory, ?*const c.VkAllocationCallbacks) callconv(.c) void =',
  'const pfn_free: *const fn (c.VkDevice, c.VkDeviceMemory, ?*const c.VkAllocationCallbacks) callconv(.c) void ='),
 ('const pfn_destroybuf: *const fn (c.VkBuffer, ?*const c.VkAllocationCallbacks) callconv(.c) void =',
  'const pfn_destroybuf: *const fn (c.VkDevice, c.VkBuffer, ?*const c.VkAllocationCallbacks) callconv(.c) void ='),
]
for a, b in fixes:
    if a in s:
        s = s.replace(a, b, 1); print('fixed', b.split(':')[0].split()[-1])
    else:
        print('already ok')
io.open(p, 'w', encoding='utf-8', newline='').write(s)
