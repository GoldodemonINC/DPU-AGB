import io, re
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()

dev_fns = [
    'vkCreateFence', 'vkAllocateMemory', 'vkMapMemory',
    'vkGetDeviceMemoryCommitment', 'vkCreateBuffer', 'vkBindBufferMemory',
    'vkAllocateCommandBuffers', 'vkBeginCommandBuffer', 'vkEndCommandBuffer',
    'vkCreateCommandPool', 'vkFreeMemory', 'vkDestroyBuffer',
]

count = 0
for name in dev_fns:
    pat = re.compile(r'\*const fn \(([^)]*)\)[^=]*=\s*\n\s*@ptrCast\(@alignCast\((?:devProc|resolveProcAt)\("' + name + r'"')
    m = pat.search(s)
    if not m:
        print('  no typedef for', name); continue
    args = m.group(1)
    if 'c.VkDevice' in args:
        print('  already has device:', name); continue
    s = s[:m.start(1)] + 'c.VkDevice, ' + args + s[m.end(1):]
    count += 1

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('typedefs patched:', count)
