import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()
old = '    const h = [_]?*anyopaque{ device, phys };'
assert old in s
# The instance is always a legal first argument; a physical device is legal only
# from Vulkan 1.2, so it goes last rather than first. Order: device, physical
# device, instance.
new = '    const h = [_]?*anyopaque{ device, phys, vk };'
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
