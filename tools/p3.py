import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()
old = '    std.debug.print("  [FAIL] the loader does not expose " ++ name ++ NL, .{});'
assert old in s
new = '    std.debug.print("  [FAIL] the loader does not expose {s}" ++ NL, .{name});'
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
