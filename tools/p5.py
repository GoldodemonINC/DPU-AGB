import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()

# No null fallback here: the loader treats a null instance for a non-global
# command as a hard validation abort, not a soft "not found".
old = 'fn resolveProcAt(name: [:0]const u8, h: ?*anyopaque) ?*anyopaque {' + chr(10) + '    return resolveProc(name, &[_]?*anyopaque{ h, null });' + chr(10) + '}'
assert old in s, 'resolveProcAt body'
new = ('/// Instance-scope lookup. Does NOT fall back to a null handle: the loader\n'
       '/// treats a null instance for a non-global command as a validation abort\n'
       '/// rather than "not found", so a fallback here would kill the probe\n'
       '/// instead of reporting a missing entry point.\n'
       'fn resolveProcAt(name: [:0]const u8, h: ?*anyopaque) ?*anyopaque {\n'
       '    return resolveProc(name, &[_]?*anyopaque{ h });\n'
       '}')
s = s.replace(old, new, 1)

# vkCreateDevice and vkCreateCommandPool are instance commands: they must be
# resolved against the instance, not the physical device.
for name in ('vkCreateDevice', 'vkCreateCommandPool'):
    a = 'resolveProcAt("' + name + '", dpu)'
    assert a in s, name
    s = s.replace(a, 'resolveProcAt("' + name + '", vk)', 1)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
