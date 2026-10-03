import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()
fixes = [
 ('const pfn_bind: *const fn (c.VkBuffer, c.VkDeviceMemory, u64) callconv(.c) c_int =',
  'const pfn_bind: *const fn (c.VkDevice, c.VkBuffer, c.VkDeviceMemory, u64) callconv(.c) c_int ='),
]
for a, b in fixes:
    if a in s:
        s = s.replace(a, b, 1)
        print('fixed', b.split(':')[0])
    else:
        print('already ok:', b.split(':')[0])
io.open(p, 'w', encoding='utf-8', newline='').write(s)
