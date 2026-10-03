import io, re
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()

# Add the device argument at every call site whose typedef now takes it.
calls = [
    ('pfn_fence(', 'pfn_fence(device, '),
    ('pfn_alloc(', 'pfn_alloc(device, '),
    ('pfn_map(', 'pfn_map(device, '),
    ('pfn_commit(', 'pfn_commit(device, '),
    ('pfn_buf(', 'pfn_buf(device, '),
    ('pfn_bind(', 'pfn_bind(device, '),
    ('pfn_alloccmd(', 'pfn_alloccmd(device, '),
    ('pfn_begin(', 'pfn_begin(device, '),
    ('pfn_end(', 'pfn_end(device, '),
    ('pfn_cmdpool(', 'pfn_cmdpool(device, '),
    ('pfn_free(', 'pfn_free(device, '),
    ('pfn_destroybuf(', 'pfn_destroybuf(device, '),
]
for old, new in calls:
    if old + 'device,' in s:
        print('  already:', old); continue
    s = s.replace(old, new)

# vkCmdWriteBuffer / vkCmdCopyBuffer / vkQueueSubmit take NO device: their first
# argument is already the command buffer or the queue. These were correct.
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('call sites patched')
