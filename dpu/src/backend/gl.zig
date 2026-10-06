//! An OpenGL backend for the DPU residency fault path.
//!
//! This is a *read* backend for `residency.Faults`, not a device driver.
//! It creates a hidden WGL context on the host's GPU and reads the
//! framebuffer with `glReadPixels`, so the fault path can pull a whole granule
//! out of video memory in one call instead of 4 KiB at a time through the disk
//! pool.
//!
//! What this is, precisely:
//! - A drop-in backend for `residency.Faults(GLBackend)`. Any call site that
//!   can talk to `blockdev.BlockDevice` can talk to this, because both expose
//!   `read(self: *Backend, offset: u64, buf: []u8)`.
//! - A way to test the granule hypothesis on the *real* GPU, not just on the
//!   disk pool. The hypothesis is that one `glReadPixels` of a granule is
//!   cheaper than N `glReadPixels` calls of 4 KiB each, the same shape as the
//!   disk sweep found for the pool.
//! - **Not** a replacement for the Vulkan ICD. The Vulkan ICD owns a
//!   device-local heap backed by the disk pool; this backend reads from the
//!   framebuffer of the host's existing GL context. They are different devices
//!   for different purposes.
//!
//! What this is not:
//! - It does not allocate video memory. `glReadPixels` reads what the context
//!   can see, which on a fresh context is whatever was last on the screen or
//!   a cleared buffer. The caller owns the interpretation of those bytes.
//! - It does not present, swap, or render. There is no swapchain, no shader,
//!   no pipeline. The context is hidden and never shown.
//! - It is not thread-safe. WGL contexts are thread-affine and the backend
//!   holds a single context for its lifetime. Two backends in two threads each
//!   get their own context; one backend used from two threads is undefined.

const std = @import("std");
const win = @import("win");
const c = win.c;

const ogl = @cImport({
    @cInclude("GL/gl.h");
    @cInclude("GL/wgl.h");
});

// WGL context creation and GL dispatch both need shared-library linkage.
// build.zig links opengl32 (GL entry points) and gdi32 (WGL entry points)
// for this module because a bare @cImport does not pull either in on MinGW.

// MinGW's translate-c of GL/gl.h does not expose GLsizei. It is a signed
// 32-bit integer in every OpenGL implementation this targets.
const GLsizei = i32;

// ----------------------------------------------------------------------------
// Context creation
// ----------------------------------------------------------------------------

/// One OpenGL backend. Created once, used for the lifetime of the fault path
/// that owns it.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    dc: ?c.HDC = null,
    ctx: ?c.HGLRC = null,
    hwnd: ?c.HWND = null,
    width: u32 = 256,
    height: u32 = 256,
    /// The last error from a `read`, so a caller can distinguish "nothing to
    /// read" from "the context died".
    last_error: ?[]const u8 = null,

    /// Create a hidden window + GL context.
    ///
    /// The window is invisible and never shown. It exists solely so WGL has a
    /// DC to make current. On failure the backend is left in a state where
    /// every `read` returns an error rather than crashing.
    pub fn init(allocator: std.mem.Allocator) !Backend {
        var self = Backend{ .allocator = allocator };
        try self.createContext();
        return self;
    }

    fn createContext(self: *Backend) !void {
        const wc = c.WNDCLASSEXA{
            .cbSize = @sizeOf(c.WNDCLASSEXA),
            .style = c.CS_HREDRAW | c.CS_VREDRAW,
            .lpfnWndProc = @ptrCast(&defWindowProc),
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = c.GetModuleHandleA(null),
            .hIcon = c.LoadIconA(null, @ptrFromInt(@as(usize, 32512))),
            .hCursor = c.LoadCursorA(null, @ptrFromInt(@as(usize, 32512))),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = "DPUGLBackend",
            .hIconSm = null,
        };
        if (c.RegisterClassExA(&wc) == 0) return error.GlContextFailed;

        self.hwnd = c.CreateWindowExA(
            0,
            "DPUGLBackend",
            "dpu-gl-backend",
            c.WS_OVERLAPPEDWINDOW,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
            null,
            null,
            wc.hInstance,
            null,
        );
        if (self.hwnd == null) return error.GlContextFailed;

        const dc = c.GetDC(self.hwnd.?);
        if (dc == null) return error.GlContextFailed;
        self.dc = dc;

        const pfd: c.PIXELFORMATDESCRIPTOR = .{
            .nSize = @sizeOf(c.PIXELFORMATDESCRIPTOR),
            .nVersion = 1,
            .dwFlags = c.PFD_DRAW_TO_WINDOW | c.PFD_SUPPORT_OPENGL | c.PFD_DOUBLEBUFFER,
            .iPixelType = c.PFD_TYPE_RGBA,
            .cColorBits = 24,
            .cRedBits = 0,
            .cRedShift = 0,
            .cGreenBits = 0,
            .cGreenShift = 0,
            .cBlueBits = 0,
            .cBlueShift = 0,
            .cAlphaBits = 0,
            .cAlphaShift = 0,
            .cAccumBits = 0,
            .cAccumRedBits = 0,
            .cAccumGreenBits = 0,
            .cAccumBlueBits = 0,
            .cAccumAlphaBits = 0,
            .cDepthBits = 24,
            .cStencilBits = 8,
            .cAuxBuffers = 0,
            .iLayerType = c.PFD_MAIN_PLANE,
            .bReserved = 0,
            .dwLayerMask = 0,
            .dwVisibleMask = 0,
            .dwDamageMask = 0,
        };

        const pf = c.ChoosePixelFormat(dc, &pfd);
        if (pf == 0) return error.GlContextFailed;

        if (c.SetPixelFormat(dc, pf, &pfd) == 0) return error.GlContextFailed;

        const ctx = c.wglCreateContext(dc);
        if (ctx == null) return error.GlContextFailed;

        if (c.wglMakeCurrent(dc, ctx) == 0) {
            _ = c.wglDeleteContext(ctx);
            return error.GlContextFailed;
        }
        self.ctx = ctx;

        // Clear to a known state so a fresh backend does not return whatever
        // was on the screen before it started.
        ogl.glClearColor(0.0, 0.0, 0.0, 0.0);
        ogl.glClear(ogl.GL_COLOR_BUFFER_BIT);
    }

    /// Read `buf.len` bytes at `offset` from the framebuffer.
    ///
    /// The offset is interpreted as a row-major pixel offset into a
    /// `width x height` framebuffer of RGBA pixels (4 bytes each). A read of
    /// N bytes therefore reads N/4 pixels from pixel index `offset/4`.
    ///
    /// The buffer must be 4-byte aligned, because `glReadPixels` with
    /// `GL_UNSIGNED_BYTE` and `GL_PACK_ALIGNMENT = 4` requires it. This is the
    /// same alignment contract `blockdev` imposes for `NO_BUFFERING`, and the
    /// residency slab is allocated to it, so a fault path backed by either
    /// device can use the same slab.
    ///
    /// Returns the caller's byte count, or an error when the context is gone
    /// or the read fails.
    pub fn read(self: *Backend, offset: u64, buf: []u8) !usize {
        if (self.ctx == null) {
            self.last_error = "context not current";
            return error.GlContextLost;
        }
        if (buf.len == 0) return 0;
        if (buf.len % 4 != 0) {
            self.last_error = "buffer not 4-byte aligned";
            return error.GlNotAligned;
        }

        // Pixel index = byte offset / 4 (RGBA = 4 bytes per pixel).
        const pixel_index: u64 = offset / 4;
        const px = @as(u32, @intCast(pixel_index % @as(u64, self.width)));
        const py = @as(u32, @intCast(pixel_index / @as(u64, self.width)));
        const width: GLsizei = @intCast(@min(@as(u64, self.width) - px, buf.len / 4));
        const height: GLsizei = @intCast(@min(
            @as(u64, self.height) - py,
            @as(u64, buf.len / 4) / @as(u64, @intCast(width)),
        ));

        if (width == 0 or height == 0) return 0;

        ogl.glPixelStorei(ogl.GL_PACK_ALIGNMENT, 4);
        _ = ogl.glReadPixels(@intCast(px), @intCast(py), width, height, ogl.GL_RGBA, ogl.GL_UNSIGNED_BYTE, buf.ptr);

        // A failed read leaves the buffer untouched and returns an error. We
        // cannot tell from the return value alone whether glReadPixels fired,
        // because GL errors are sticky and driver-dependent; the safest signal
        // is that the context is still current.
        if (c.wglGetCurrentContext() != self.ctx.?) {
            self.last_error = "context lost during read";
            return error.GlContextLost;
        }
        const bytes_read = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        return bytes_read;
    }

    /// Resize the backing framebuffer. Called by the fault path when it wants
    /// a larger surface to read from.
    pub fn resize(self: *Backend, width: u32, height: u32) void {
        if (self.ctx == null) return;
        self.width = width;
        self.height = height;
        // Recreate the context on the new size. A window resize would require
        // a buffer swap and a present, which this backend does not do; instead
        // we tear down and rebuild, which is cheap for the hidden window this
        // backend uses.
        self.destroyContext();
        self.createContext() catch {
            self.ctx = null;
            self.last_error = "resize failed";
        };
    }

    fn destroyContext(self: *Backend) void {
        if (self.ctx) |ctx| {
            if (self.dc) |dc| {
                _ = c.wglMakeCurrent(dc, null);
            }
            _ = c.wglDeleteContext(ctx);
        }
        self.ctx = null;
        if (self.dc) |dc| {
            _ = c.ReleaseDC(self.hwnd.?, dc);
        }
        self.dc = null;
    }

    pub fn deinit(self: *Backend) void {
        self.destroyContext();
        if (self.hwnd) |hwnd| {
            _ = c.DestroyWindow(hwnd);
        }
        // UnregisterClass is best-effort here; a leaked class atom is not a
        // resource leak in the sense this project usually means.
        _ = c.UnregisterClassA("DPUGLBackend", c.GetModuleHandleA(null));
    }

    pub fn valid(self: *const Backend) bool {
        return self.ctx != null;
    }

    pub fn info(self: *const Backend) Info {
        return .{
            .width = self.width,
            .height = self.height,
            .valid = self.valid(),
            .last_error = if (self.last_error) |e| e else "",
        };
    }
};

pub const Info = struct {
    width: u32,
    height: u32,
    valid: bool,
    last_error: []const u8,
};

fn defWindowProc(hwnd: c.HWND, msg: u32, wparam: usize, lparam: usize) c.LRESULT {
    return c.DefWindowProcA(hwnd, msg, @intCast(wparam), @intCast(lparam));
}

// ----------------------------------------------------------------------------
// Errors
// ----------------------------------------------------------------------------

pub const Error = error{
    GlContextFailed,
    GlContextLost,
    GlNotAligned,
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "an OpenGL backend can be created and destroyed" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    try testing.expect(backend.valid());
}

test "an OpenGL backend reports its info" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    const info = backend.info();
    try testing.expect(info.valid);
    try testing.expectEqual(@as(u32, 256), info.width);
    try testing.expectEqual(@as(u32, 256), info.height);
    try testing.expectEqualStrings("", info.last_error);
}

test "reading from a fresh OpenGL backend returns black pixels" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    var buf: [256]u8 = undefined;
    const n = try backend.read(0, &buf);
    try testing.expectEqual(@as(usize, 256), n);

    // The context was cleared to black on creation.
    for (&buf) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "a read returns the pixels the context was filled with" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    // Fill the framebuffer with a colour no zeroed buffer can produce, then
    // read it back through `read`. This is what separates a real glReadPixels
    // from a buffer that merely stayed undefined: the all-zero test above
    // cannot tell those apart, because a cleared-to-black framebuffer and a
    // never-written buffer are both zero. If `read` were a no-op, the
    // channels below would be whatever `undefined` happened to hold.
    ogl.glClearColor(0.25, 0.5, 0.75, 1.0);
    ogl.glClear(ogl.GL_COLOR_BUFFER_BIT);

    var buf: [8]u8 = undefined;
    const n = try backend.read(0, &buf);
    try testing.expectEqual(@as(usize, 8), n);

    // 0.25, 0.5, 0.75, 1.0 as 8-bit channels. The window is +/-2 rather than
    // exact because the float-to-unorm rounding is the driver's, not ours;
    // what matters is that the values came back at all, and that they differ.
    const want = [4]u8{ 64, 128, 191, 255 };
    for (want, 0..) |expected, i| {
        const got = buf[i];
        const diff = if (got > expected) got - expected else expected - got;
        try testing.expect(diff <= 2);
    }
    try testing.expect(buf[0] != buf[1] and buf[1] != buf[2]);
}

test "reading past the framebuffer edge returns a short count" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    // 256x256 RGBA framebuffer = 262144 bytes. Reading at offset 262140
    // should return 4 bytes, not crash.
    var buf: [8]u8 = undefined;
    const n = try backend.read(262140, &buf);
    try testing.expectEqual(@as(usize, 4), n);
}

test "a 4 KiB aligned buffer reads correctly" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    var buf: [4096]u8 = undefined;
    // 4 KiB = 1024 pixels. On a 256-wide framebuffer that is 4 rows.
    const n = try backend.read(0, &buf);
    try testing.expectEqual(@as(usize, 4096), n);
    for (&buf) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "reading from an unaligned buffer is refused" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    var buf = [_]u8{0} ** 5; // 5 bytes, not 4-byte aligned length
    const result = backend.read(0, &buf);
    try testing.expectError(Error.GlNotAligned, result);
}

test "an OpenGL backend survives destruction and recreation" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    try testing.expect(backend.valid());

    backend.deinit();
    try testing.expect(!backend.valid());

    // Re-create on the same allocator.
    backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    try testing.expect(backend.valid());
}
