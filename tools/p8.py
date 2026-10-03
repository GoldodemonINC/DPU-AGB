import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()
old = 'const pfn_commit: *const fn (c.VkDeviceMemory, ?*u64) callconv(.c) void ='
assert old in s
new = 'const pfn_commit: *const fn (c.VkDevice, c.VkDeviceMemory, ?*u64) callconv(.c) void ='
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
