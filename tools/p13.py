import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()
old = '    const h = [_]?*anyopaque{ device, phys, null };'
assert old in s, 'devProc handles'
# No null: the loader aborts rather than returning null for a non-global command.
new = '    const h = [_]?*anyopaque{ device, phys };'
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
