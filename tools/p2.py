import io

p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()

a = 'fn resolveProc(' + chr(10) + '    comptime name: [*:0]const u8,' + chr(10) + '    handles: []const ?*anyopaque,' + chr(10) + ') ?*anyopaque {'
b = 'fn resolveProc(name: [:0]const u8, handles: []const ?*anyopaque) ?*anyopaque {'
assert a in s, 'resolveProc'
s = s.replace(a, b, 1)

s = s.replace('fn mustProc(comptime name: [*:0]const u8, handles: []const ?*anyopaque) ?*anyopaque {',
              'fn mustProc(name: [:0]const u8, handles: []const ?*anyopaque) ?*anyopaque {', 1)
s = s.replace('fn devProc(name: [*:0]const u8, device: ?*anyopaque, phys: ?*anyopaque) ?*anyopaque {',
              'fn devProc(name: [:0]const u8, device: ?*anyopaque, phys: ?*anyopaque) ?*anyopaque {', 1)
s = s.replace('fn resolveProcAt(comptime name: [*:0]const u8, h: ?*anyopaque) ?*anyopaque {',
              'fn resolveProcAt(name: [:0]const u8, h: ?*anyopaque) ?*anyopaque {', 1)
s = s.replace('        if (base(h, name)) |p| return p;',
              '        if (base(h, name.ptr)) |p| return p;', 1)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
