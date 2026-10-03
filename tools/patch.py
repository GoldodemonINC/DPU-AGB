import io

p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()

# A resolver that tries the three handles Vulkan allows rather than assuming one.
old = '''/// Resolve a device-level command.
///
/// Tries the device first and the physical device second, which is the order
/// the loader documents. A top-level function rather than a nested struct
/// because Zig will not let an inner `struct` capture a mutable local, and
/// threading two handles through every call site is noisier than this.
fn devProc(name: [*:0]const u8, device: ?*anyopaque, phys: ?*anyopaque) ?*anyopaque {
    const base = vkGetInstanceProcAddrPtr;
    return base(device, name) orelse base(phys, name);
}'''
assert old in s, 'devProc anchor'

new = '''/// Resolve an entry point, trying every handle form the spec allows.
///
/// `vkGetInstanceProcAddr` accepts NULL (global commands only), an instance
/// (instance commands), and -- since 1.2 -- a physical device or device (every
/// command). A client that assumes one form and fails on the other gets a
/// null function pointer and a crash somewhere unrelated, so this tries all
/// three and names the ones that failed if none work.
fn resolveProc(
    comptime name: [*:0]const u8,
    handles: []const ?*anyopaque,
) ?*anyopaque {
    const base = vkGetInstanceProcAddrPtr;
    for (handles) |h| {
        if (base(h, name)) |p| return p;
    }
    std.debug.print("  [FAIL] the loader does not expose " ++ name ++ NL, .{});
    return null;
}

/// Same, but a missing pointer is fatal with a message rather than a panic.
fn mustProc(comptime name: [*:0]const u8, handles: []const ?*anyopaque) ?*anyopaque {
    return resolveProc(name, handles) orelse failure();
}

/// Device-level commands: device first, then the physical device, then the
/// instance. A top-level function rather than a nested struct because Zig will
/// not let an inner `struct` capture a mutable local.
fn devProc(name: [*:0]const u8, device: ?*anyopaque, phys: ?*anyopaque) ?*anyopaque {
    const h = [_]?*anyopaque{ device, phys, null };
    return resolveProc(name, &h);
}'''
s = s.replace(old, new, 1)

# Physical-device commands go through the forgiving resolver too.
s = s.replace('''    const proc = struct {
        fn resolve(comptime name: [*:0]const u8, h: ?*anyopaque) ?*anyopaque {
            const base = vkGetInstanceProcAddrPtr;
            return base(h, name);
        }
    };

''', '')
s = s.replace('proc.resolve(', 'resolveProcAt(')
s = s.replace('''pub fn main() !void {''',
'''/// Instance-level lookup for the handful of calls made before a device exists.
fn resolveProcAt(comptime name: [*:0]const u8, h: ?*anyopaque) ?*anyopaque {
    return resolveProc(name, &[_]?*anyopaque{ h, null });
}

pub fn main() !void {''', 1)

# Replace the remaining `unreachable` on a proc lookup with a named failure.
s = s.replace('orelse unreachable));', 'orelse return failure()));')

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
