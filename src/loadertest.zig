const std = @import("std");

const c = @cImport({
    @cInclude("windows.h");
});

pub fn main() !void {
    var wide: [64]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&wide, "vulkan-1.dll");
    wide[n] = 0;

    const lib = c.LoadLibraryW(@ptrCast(&wide)) orelse {
        std.debug.print("LoadLibraryW failed, err {d}\n", .{c.GetLastError()});
        return;
    };
    std.debug.print("vulkan-1.dll at {x}\n", .{@intFromPtr(lib)});

    const name: [*:0]const u8 = "vkGetInstanceProcAddr";
    const p = c.GetProcAddress(lib, name) orelse {
        std.debug.print("GetProcAddress failed, err {d}\n", .{c.GetLastError()});
        return;
    };
    std.debug.print("vkGetInstanceProcAddr at {x}\n", .{@intFromPtr(p)});

    const gipa: *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(@alignCast(p));

    std.debug.print("asking for vkEnumerateInstanceVersion...\n", .{});
    const v = gipa("vkEnumerateInstanceVersion", null);
    std.debug.print("  -> {x}\n", .{@intFromPtr(@as(?*anyopaque, v))});

    std.debug.print("asking for vkCreateInstance...\n", .{});
    const ci = gipa("vkCreateInstance", null);
    std.debug.print("  -> {x}\n", .{@intFromPtr(@as(?*anyopaque, ci))});
}
