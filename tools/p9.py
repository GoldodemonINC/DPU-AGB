import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()
old = 'const pfn_map: *const fn (c.VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) c_int ='
assert old in s, 'pfn_map typedef'
new = 'const pfn_map: *const fn (c.VkDevice, c.VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) c_int ='
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
