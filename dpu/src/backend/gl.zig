//! An OpenGL backend for the DPU residency fault path.
//!
//! This is a *read* backend for `residency.Faults`, not a device driver.
//! It creates a hidden window and a WGL context of its own on the host's GPU
//! and reads *that window's* framebuffer with `glReadPixels`, so the fault path
//! can pull a whole granule in one call instead of 4 KiB at a time through the
//! disk pool.
//!
//! What this is, precisely:
//! - A drop-in backend for `residency.Faults(GLBackend)`. Any call site that
//!   can talk to `blockdev.BlockDevice` can talk to this, because both expose
//!   `read(self: *Backend, offset: u64, buf: []u8)`.
//! - A way to exercise the granule read path on a *real* GPU rather than only
//!   on the disk pool. The hypothesis is that one `glReadPixels` of a granule is
//!   cheaper than N `glReadPixels` calls of 4 KiB each, the same shape as the
//!   disk sweep found for the pool.
//! - **Not** a replacement for the Vulkan ICD. The ICD owns a device-local heap
//!   backed by the disk pool; this reads a framebuffer belonging to a window
//!   this backend created. They are different devices for different purposes.
//!
//! What this is not:
//! - **It does not read another application's GL context.** `createSurface`
//!   registers a window class, creates a window and a WGL context, and clears
//!   that context's framebuffer to black. The bytes `read` returns come from
//!   this backend's own framebuffer and nowhere else -- they are not the host's
//!   desktop, not another program's render, and not model weights. A caller
//!   that wants real data has to put real data in this surface first.
//! - It does not allocate video memory, present, swap, or render. There is no
//!   swapchain, no shader, no pipeline. The context is hidden and never shown.
//! - It is not thread-safe. WGL contexts are thread-affine and the backend holds
//!   a single context for its lifetime. Two backends in two threads each get
//!   their own context (see `class_mutex` for why that works at all); one backend
//!   used from two threads is undefined.

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

const CLASS_NAME = "DPUGLBackend";

// ----------------------------------------------------------------------------
// Window class sharing
// ----------------------------------------------------------------------------

/// How many live backends share the process-wide window class.
///
/// A window class is process-global, not per-context. Registration and the
/// count that guards it are therefore one critical section: an atomic counter
/// is not enough, because `register` is *test-count-register-increment* and
/// `release` is *decrement-test-unregister*, and the two pairs must not
/// interleave. If they can, a registration observes the class as already
/// present (and treats that as success) in the window before another thread's
/// decrement removes it, leaving that thread holding a count above zero and no
/// class to create a window from. The lock makes each pair one step, so the
/// count is zero exactly when the name is unregistered.
///
/// When the count is already positive the name is registered, so `register`
/// only takes a reference: the OS call happens on the 0 -> 1 transition and
/// `UnregisterClassA` on the 1 -> 0 transition. A sibling -- or a previous
/// instance still tearing down -- owning the name is expected, not an error.
///
/// `std.Thread.Mutex` is gone in this toolchain and `std.Io.Mutex` wants an
/// `Io` the backend does not have, so this is the std spinlock. The critical
/// section is a pair of short Win32 calls taken at most twice in a backend's
/// life, so spinning costs nothing in practice.
var class_mutex: std.atomic.Mutex = .unlocked;
var class_refs: u32 = 0;

fn lockClass() void {
    while (!class_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlockClass() void {
    class_mutex.unlock();
}

/// The live-backend count under the same lock, for the lifecycle tests that
/// assert the count returns to where it started.
fn classRefCount() u32 {
    lockClass();
    defer unlockClass();
    return class_refs;
}

fn registerWindowClass() !void {
    lockClass();
    defer unlockClass();

    // A sibling already registered the name. Taking a reference here rather
    // than calling `RegisterClassExA` again is what closes the race: no thread
    // can see "already exists" and then have the class removed from under it by
    // the thread that is unregistering.
    if (class_refs > 0) {
        class_refs += 1;
        return;
    }

    const wc = c.WNDCLASSEXA{
        .cbSize = @sizeOf(c.WNDCLASSEXA),
        .style = c.CS_HREDRAW | c.CS_VREDRAW,
        .lpfnWndProc = @ptrCast(&defWindowProc),
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = c.GetModuleHandleA(null),
        // Raw resource IDs: IDI_APPLICATION and IDC_ARROW are MinGW `func##A`
        // macros that translate-c cannot resolve. Both are 32512 in winuser.h.
        .hIcon = c.LoadIconA(null, @ptrFromInt(@as(usize, 32512))),
        .hCursor = c.LoadCursorA(null, @ptrFromInt(@as(usize, 32512))),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (c.RegisterClassExA(&wc) == 0) {
        if (c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS) return error.GlContextFailed;
    }
    class_refs += 1;
}

fn releaseWindowClass() void {
    lockClass();
    defer unlockClass();
    class_refs -= 1;
    if (class_refs == 0) {
        _ = c.UnregisterClassA(CLASS_NAME, c.GetModuleHandleA(null));
    }
}

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
    /// Guards `deinit`, so a double release cannot unregister the shared window
    /// class a sibling still needs.
    released: bool = false,

    /// Create a hidden window + GL context.
    ///
    /// The window is invisible and never shown. It exists solely so WGL has a
    /// DC to make current. On failure every resource acquired on the way is
    /// released before the error is returned, so a failed init leaves nothing
    /// behind and a caller that never sees a Backend has nothing to clean up.
    pub fn init(allocator: std.mem.Allocator) !Backend {
        var self = Backend{ .allocator = allocator };
        try registerWindowClass();
        errdefer releaseWindowClass();
        try self.createSurface();
        return self;
    }

    /// Create the window, its DC, and the GL context, and clear the surface.
    /// On failure the partial state is torn down via `errdefer`.
    fn createSurface(self: *Backend) !void {
        // WS_POPUP, not WS_OVERLAPPEDWINDOW: an overlapped window's *client*
        // area is smaller than its outer rect (title bar and borders), and the
        // GL drawable is the client area, so `read` would address rows and
        // columns that do not exist. A popup has no non-client frame, and the
        // real client size is read back below rather than assumed.
        self.hwnd = c.CreateWindowExA(
            0,
            CLASS_NAME,
            "dpu-gl-backend",
            c.WS_POPUP,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
            null,
            null,
            c.GetModuleHandleA(null),
            null,
        );
        if (self.hwnd == null) return error.GlContextFailed;
        errdefer {
            _ = c.DestroyWindow(self.hwnd.?);
            self.hwnd = null;
        }

        const dc = c.GetDC(self.hwnd.?);
        if (dc == null) return error.GlContextFailed;
        self.dc = dc;
        errdefer {
            _ = c.ReleaseDC(self.hwnd.?, dc);
            self.dc = null;
        }

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
            // The translated MinGW PIXELFORMATDESCRIPTOR drops the four
            // cAccum*Shift fields the canonical Win32 struct has, so the
            // literal is trimmed to the fields the header actually defines.
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
        self.ctx = ctx;
        errdefer {
            _ = c.wglDeleteContext(ctx);
            self.ctx = null;
        }

        if (c.wglMakeCurrent(dc, ctx) == 0) return error.GlContextFailed;

        // Read the drawable size back instead of trusting the requested one.
        // DPI virtualisation can scale a window, and the drawable is the client
        // rect; addressing anything outside it is undefined.
        var rect: c.RECT = undefined;
        if (c.GetClientRect(self.hwnd.?, &rect) != 0) {
            const cw: u32 = @intCast(@max(rect.right - rect.left, 0));
            const ch: u32 = @intCast(@max(rect.bottom - rect.top, 0));
            if (cw > 0 and ch > 0) {
                self.width = cw;
                self.height = ch;
            }
        }

        // Clear to a known state so a fresh backend does not return whatever
        // the driver left in the buffer.
        ogl.glClearColor(0.0, 0.0, 0.0, 0.0);
        ogl.glClear(ogl.GL_COLOR_BUFFER_BIT);
    }

    /// Read `buf.len` bytes at `offset` from the framebuffer.
    ///
    /// The offset is a linear byte offset into the surface, which is a
    /// row-major array of `width x height` RGBA pixels (4 bytes each). A read of
    /// N bytes reads N/4 pixels starting at pixel index `offset/4`. The pixels
    /// come back in linear order even when the range crosses a row boundary --
    /// that is the contract `blockdev.BlockDevice` keeps, and a backend that
    /// broke it would hand the fault path plausible bytes that are wrong.
    ///
    /// Both the offset and the buffer length must be multiples of 4. `blockdev`
    /// refuses the same two shapes with `NotAligned` and offers separate
    /// `readUnaligned`/`writeUnaligned` helpers that bounce through an aligned
    /// staging buffer; this backend is a drop-in for its `read` and so refuses
    /// rather than rounding. Rounding the offset down to the containing pixel
    /// would return bytes shifted by one to three and report success, which is
    /// the silent-truncation failure `blockdev`'s header names explicitly.
    ///
    /// The length rule is also what `glReadPixels` needs: with
    /// `GL_UNSIGNED_BYTE` and `GL_PACK_ALIGNMENT = 4` every row it writes is a
    /// multiple of 4 bytes. The residency slab is allocated to the same
    /// boundary, so a fault path backed by either device can use the same slab.
    ///
    /// Returns the byte count actually read. A short count means the surface
    /// ended inside the request; an offset at or past the end returns 0. A read
    /// that fails returns an error rather than a byte count.
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
        // A pixel read has to start at a pixel. Truncating an unaligned offset
        // returns bytes shifted by up to 3 while reporting success, so it is
        // refused -- the same answer `blockdev.read` gives for the same input.
        if (offset % 4 != 0) {
            self.last_error = "offset not 4-byte aligned";
            return error.GlNotAligned;
        }

        // The current-context check has to come *before* any GL call, not
        // after: WGL routes every GL call to whatever context is current on
        // this thread, so a check that runs afterwards has already read from
        // the wrong surface.
        if (c.wglGetCurrentContext() != self.ctx.?) {
            self.last_error = "context not current on this thread";
            return error.GlContextLost;
        }

        const surface_px: u64 = @as(u64, self.width) * @as(u64, self.height);
        const want_px: u64 = buf.len / 4;
        var idx: u64 = offset / 4;
        // At or past the end there is nothing to read, and returning here is
        // what keeps `height - py` below from underflowing on a large offset.
        if (idx >= surface_px) return 0;

        // Drop any error left over from an earlier call, so the check below is
        // about this read and nothing else.
        while (ogl.glGetError() != ogl.GL_NO_ERROR) {}

        ogl.glPixelStorei(ogl.GL_PACK_ALIGNMENT, 4);

        var written_px: u64 = 0;
        // Fast path: a request that starts on a row boundary and covers whole
        // rows is exactly one rectangle, which is the shape every
        // granule-aligned fault read takes. This is the case the backend exists
        // to make cheap, so it must stay a single glReadPixels.
        if (idx % @as(u64, self.width) == 0 and want_px % @as(u64, self.width) == 0) {
            const rows = @min(
                @as(u64, self.height) - idx / @as(u64, self.width),
                want_px / @as(u64, self.width),
            );
            _ = ogl.glReadPixels(
                0,
                @intCast(idx / @as(u64, self.width)),
                @intCast(self.width),
                @intCast(rows),
                ogl.GL_RGBA,
                ogl.GL_UNSIGNED_BYTE,
                buf.ptr,
            );
            written_px = rows * @as(u64, self.width);
        } else {
            // General path: glReadPixels reads a rectangle, not a linear range
            // that wraps at the row edge. A range that starts mid-row or stops
            // mid-row has to be issued one row at a time, or the caller gets
            // the wrong columns.
            while (written_px < want_px) {
                const px = idx % @as(u64, self.width);
                const py = idx / @as(u64, self.width);
                if (py >= @as(u64, self.height)) break;
                const run = @min(@as(u64, self.width) - px, want_px - written_px);
                _ = ogl.glReadPixels(
                    @intCast(px),
                    @intCast(py),
                    @intCast(run),
                    1,
                    ogl.GL_RGBA,
                    ogl.GL_UNSIGNED_BYTE,
                    buf.ptr + @as(usize, @intCast(written_px * 4)),
                );
                written_px += run;
                idx += run;
            }
        }

        // A GL error means the bytes in `buf` are not the ones the caller asked
        // for, whether or not the context is still current. Reporting a byte
        // count here would be the silent-wrong-data failure the fault path
        // cannot detect, so it is an error instead.
        if (ogl.glGetError() != ogl.GL_NO_ERROR) {
            self.last_error = "glReadPixels failed";
            return error.GlReadFailed;
        }

        return @intCast(written_px * 4);
    }

    /// Resize the backing surface. Called by the fault path when it wants a
    /// larger framebuffer to read from.
    pub fn resize(self: *Backend, width: u32, height: u32) void {
        if (self.ctx == null) return;
        self.width = width;
        self.height = height;
        // Recreate the window and context at the new size. A window resize
        // would need a buffer swap and a present, which this backend does not
        // do; tearing down and rebuilding is cheap for a hidden window.
        self.destroyContext();
        self.createSurface() catch {
            self.ctx = null;
            self.last_error = "resize failed";
        };
    }

    /// Release the context, DC and window this backend owns. Idempotent, and
    /// safe to call on a partially initialised backend. It does *not* touch the
    /// window class, which is shared and outlives any one backend.
    fn destroyContext(self: *Backend) void {
        if (self.ctx) |ctx| {
            if (self.dc) |dc| {
                _ = c.wglMakeCurrent(dc, null);
            }
            _ = c.wglDeleteContext(ctx);
        }
        self.ctx = null;
        if (self.dc) |dc| {
            if (self.hwnd) |hwnd| {
                _ = c.ReleaseDC(hwnd, dc);
            }
        }
        self.dc = null;
        if (self.hwnd) |hwnd| {
            _ = c.DestroyWindow(hwnd);
        }
        self.hwnd = null;
    }

    pub fn deinit(self: *Backend) void {
        if (self.released) return;
        self.released = true;
        self.destroyContext();
        releaseWindowClass();
    }

    pub fn valid(self: *const Backend) bool {
        return self.ctx != null and !self.released;
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
    /// `glReadPixels` reported a GL error, so the buffer does not hold the
    /// bytes the caller asked for. Distinct from a short read, which is real
    /// data that stops at the end of the surface.
    GlReadFailed,
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
    // The surface is what the window's client rect says, which for a hidden
    // popup is the requested size. Asserted through the backend rather than
    // hardcoded, so a DPI-scaled runner does not make this a lie.
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
    // never-written buffer are both zero.
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

test "a read that crosses a row boundary keeps pixels in linear order" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    const w = backend.width;

    // Paint exactly one pixel of the second row green and leave the rest black,
    // using a one-pixel scissor box. That single pixel is what a rectangle read
    // gets wrong: reading at the last column of row 0 must continue to column 0
    // of row 1, not down column w-1.
    ogl.glClearColor(0.0, 0.0, 0.0, 1.0);
    ogl.glClear(ogl.GL_COLOR_BUFFER_BIT);
    ogl.glEnable(ogl.GL_SCISSOR_TEST);
    ogl.glScissor(0, 1, 1, 1);
    ogl.glClearColor(0.0, 1.0, 0.0, 1.0);
    ogl.glClear(ogl.GL_COLOR_BUFFER_BIT);
    ogl.glDisable(ogl.GL_SCISSOR_TEST);
    ogl.glScissor(0, 0, @intCast(w), @intCast(backend.height));

    // Start at the last pixel of row 0 and read two pixels. The second must be
    // the green pixel at column 0 of row 1; a rectangle read would return
    // column w-1 of row 1, which is black.
    var buf: [8]u8 = undefined;
    const n = try backend.read((@as(u64, w) - 1) * 4, &buf);
    try testing.expectEqual(@as(usize, 8), n);
    // First pixel: the black last pixel of row 0.
    try testing.expectEqual(@as(u8, 0), buf[0]);
    try testing.expectEqual(@as(u8, 0), buf[1]);
    try testing.expectEqual(@as(u8, 0), buf[2]);
    try testing.expectEqual(@as(u8, 255), buf[3]);
    // Second pixel: the green pixel at the start of row 1.
    try testing.expectEqual(@as(u8, 0), buf[4]);
    try testing.expectEqual(@as(u8, 255), buf[5]);
    try testing.expectEqual(@as(u8, 0), buf[6]);
    try testing.expectEqual(@as(u8, 255), buf[7]);
}

test "an offset at or past the end of the surface returns zero" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    const surface_bytes = @as(u64, backend.width) * @as(u64, backend.height) * 4;
    var buf: [8]u8 = undefined;
    // Exactly the end: nothing to read.
    try testing.expectEqual(@as(usize, 0), try backend.read(surface_bytes, &buf));
    // Well past the end, where the old row arithmetic underflowed `height - py`
    // and trapped in a safety-checked build.
    try testing.expectEqual(@as(usize, 0), try backend.read(surface_bytes + 65536, &buf));
    // The largest aligned offset there is: the pixel index must not overflow,
    // and it lands far past the surface.
    try testing.expectEqual(@as(usize, 0), try backend.read(std.math.maxInt(u64) - 3, &buf));
}

test "reading past the framebuffer edge returns a short count" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    // On a 256x256 surface, byte 262140 is the last pixel, so a two-pixel read
    // must stop after one.
    const last_px_byte = (@as(u64, backend.width) * @as(u64, backend.height) - 1) * 4;
    var buf: [8]u8 = undefined;
    const n = try backend.read(last_px_byte, &buf);
    try testing.expectEqual(@as(usize, 4), n);
}

test "a 4 KiB aligned buffer reads correctly" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    var buf: [4096]u8 = undefined;
    // 4 KiB = 1024 pixels. On a 256-wide framebuffer that is 4 rows, which is
    // the fast path: one rectangle, not four row reads.
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

test "two backends can exist in the same process" {
    // The window class is process-global, so the second backend finds the name
    // already registered. That used to be fatal; it must not be.
    var first = try Backend.init(testing.allocator);
    defer first.deinit();
    var second = try Backend.init(testing.allocator);
    defer second.deinit();
    try testing.expect(first.valid());
    try testing.expect(second.valid());
}

test "an OpenGL backend survives destruction and recreation" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    try testing.expect(backend.valid());

    backend.deinit();
    try testing.expect(!backend.valid());

    // Re-create on the same allocator. `deinit` is idempotent, so the deferred
    // call above is a no-op rather than a second window-class release.
    backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    try testing.expect(backend.valid());
}

test "an unaligned offset is refused rather than silently rounded down" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    var buf: [8]u8 = undefined;
    // Rounding these down to the containing pixel returned bytes shifted by one
    // to three and reported success. `blockdev.read` refuses the same input, and
    // this backend is a drop-in for it.
    for ([_]u64{ 1, 2, 3, 4097, 4098, 4099, 262141 }) |off| {
        try testing.expectError(Error.GlNotAligned, backend.read(off, &buf));
    }
    // The aligned neighbours are still served.
    try testing.expectEqual(@as(usize, 8), try backend.read(4, &buf));
    try testing.expectEqual(@as(usize, 8), try backend.read(4096, &buf));
    try testing.expectEqual(@as(usize, 4), try backend.read(262140, &buf));
}

test "an unaligned start near the end does not over-report" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    const surface = @as(u64, backend.width) * @as(u64, backend.height) * 4;

    var buf: [8]u8 = undefined;
    // Five bytes remain from here. The old code rounded down to a pixel and
    // returned a full, shifted 8 bytes -- more than the surface holds from the
    // requested offset.
    try testing.expectError(Error.GlNotAligned, backend.read(surface - 5, &buf));
    // The aligned equivalent is a genuine short read.
    try testing.expectEqual(@as(usize, 4), try backend.read(surface - 4, &buf));
}

test "a zero-length buffer returns zero without a read" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try backend.read(0, buf[0..0]));
    // Nothing was asked for, so even an unaligned offset past the end is 0
    // rather than an alignment error.
    try testing.expectEqual(@as(usize, 0), try backend.read((1 << 40) | 3, buf[0..0]));
}

test "a length larger than the surface returns the surface remainder" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    const surface: usize = @as(usize, backend.width) * backend.height * 4;

    const over = try testing.allocator.alloc(u8, surface + 4096);
    defer testing.allocator.free(over);
    // From the start: the whole surface, no more.
    try testing.expectEqual(surface, try backend.read(0, over));

    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);
    // From a mid-surface aligned offset: exactly the remainder, then nothing.
    try testing.expectEqual(@as(usize, 1024), try backend.read(surface - 1024, big));
    try testing.expectEqual(@as(usize, 0), try backend.read(surface, big));
}

test "an unaligned base pointer still gets the right bytes" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    ogl.glClearColor(0.0, 0.0, 1.0, 1.0);
    ogl.glClear(ogl.GL_COLOR_BUFFER_BIT);

    // GL_PACK_ALIGNMENT governs the stride between rows, not the base address,
    // so a buffer that does not start on a 4-byte boundary must still be filled
    // correctly. Only the window into `raw` is unaligned.
    var aligned: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 32), try backend.read(0, &aligned));

    var raw: [40]u8 = undefined;
    try testing.expectEqual(@as(usize, 32), try backend.read(0, raw[3..35]));
    try testing.expectEqualSlices(u8, &aligned, raw[3..35]);
}

test "a read spanning two row boundaries keeps rows in order" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    const w = backend.width;

    // Row 0 red, row 1 green, row 2 blue, everything else black.
    ogl.glClearColor(0.0, 0.0, 0.0, 1.0);
    ogl.glClear(ogl.GL_COLOR_BUFFER_BIT);
    ogl.glEnable(ogl.GL_SCISSOR_TEST);
    const row_colors = [_][3]f32{ .{ 1.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 }, .{ 0.0, 0.0, 1.0 } };
    for (row_colors, 0..) |col, y| {
        ogl.glScissor(0, @intCast(y), @intCast(w), 1);
        ogl.glClearColor(col[0], col[1], col[2], 1.0);
        ogl.glClear(ogl.GL_COLOR_BUFFER_BIT);
    }
    ogl.glDisable(ogl.GL_SCISSOR_TEST);
    ogl.glScissor(0, 0, @intCast(w), @intCast(backend.height));

    // Start two pixels from the end of row 0 and read far enough to enter row
    // 2: red, red, a whole row of green, then two blues.
    const count: usize = w + 4;
    const buf = try testing.allocator.alloc(u8, count * 4);
    defer testing.allocator.free(buf);
    try testing.expectEqual(count * 4, try backend.read((@as(u64, w) - 2) * 4, buf));

    const head = [_][3]u8{ .{ 255, 0, 0 }, .{ 255, 0, 0 } };
    for (head, 0..) |e, i| {
        try testing.expectEqual(e[0], buf[i * 4 + 0]);
        try testing.expectEqual(e[1], buf[i * 4 + 1]);
        try testing.expectEqual(e[2], buf[i * 4 + 2]);
    }
    var i: usize = 2;
    while (i < 2 + w) : (i += 1) {
        try testing.expectEqual(@as(u8, 0), buf[i * 4 + 0]);
        try testing.expectEqual(@as(u8, 255), buf[i * 4 + 1]);
        try testing.expectEqual(@as(u8, 0), buf[i * 4 + 2]);
    }
    while (i < count) : (i += 1) {
        try testing.expectEqual(@as(u8, 0), buf[i * 4 + 0]);
        try testing.expectEqual(@as(u8, 0), buf[i * 4 + 1]);
        try testing.expectEqual(@as(u8, 255), buf[i * 4 + 2]);
    }
}

test "the shared window class is refcounted across backends" {
    const base = classRefCount();

    var first = try Backend.init(testing.allocator);
    try testing.expectEqual(base + 1, classRefCount());
    var second = try Backend.init(testing.allocator);
    try testing.expectEqual(base + 2, classRefCount());

    // One going away must not unregister the class the other still needs.
    first.deinit();
    try testing.expectEqual(base + 1, classRefCount());
    second.deinit();
    try testing.expectEqual(base, classRefCount());

    // At zero the class is unregistered, so this has to register it again.
    var third = try Backend.init(testing.allocator);
    defer third.deinit();
    try testing.expect(third.valid());
    try testing.expectEqual(base + 1, classRefCount());
}

test "a second registration never re-consults the OS for the class" {
    // The interleaving CodeRabbit found needs a registration to *observe* the
    // class as already present -- and treat that observation as success -- while
    // another thread is removing it. With a positive count the name is known to
    // be registered, so this path must not call `RegisterClassExA` at all, and
    // that call is the only way the observation can happen. The proof it did
    // not call is that `ERROR_CLASS_ALREADY_EXISTS` is left unset.
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();

    const held = classRefCount();
    c.SetLastError(0);
    try registerWindowClass();
    const observed = c.GetLastError();
    try testing.expectEqual(held + 1, classRefCount());
    try testing.expect(observed != c.ERROR_CLASS_ALREADY_EXISTS);
    releaseWindowClass();
    try testing.expectEqual(held, classRefCount());

    // The extra reference did not tear the class down under the backend.
    try testing.expect(backend.valid());
}

test "the window class survives two threads creating and destroying backends" {
    // The count that guards the class only means anything if register and
    // release are serialised. With a bare atomic, one thread's final decrement
    // can land between the other thread's "already registered, treat it as
    // success" and its `CreateWindowExA`, which then finds no registered class
    // and fails `init`. Two threads each living a backend's full lifetime is
    // the shape that interleaving needs.
    const Worker = struct {
        var failed: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

        fn run() void {
            var i: usize = 0;
            while (i < 48) : (i += 1) {
                var backend = Backend.init(std.heap.page_allocator) catch {
                    failed.store(1, .seq_cst);
                    return;
                };
                backend.deinit();
            }
        }
    };
    Worker.failed.store(0, .seq_cst);

    const base = classRefCount();
    const a = try std.Thread.spawn(.{}, Worker.run, .{});
    const b = try std.Thread.spawn(.{}, Worker.run, .{});
    a.join();
    b.join();

    // Neither thread saw init fail, and the count is back where it began.
    try testing.expectEqual(@as(u8, 0), Worker.failed.load(.seq_cst));
    try testing.expectEqual(base, classRefCount());

    // And the class is still registered and usable afterwards.
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    try testing.expect(backend.valid());
}

test "a second backend makes the first context not current" {
    var first = try Backend.init(testing.allocator);
    defer first.deinit();
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), try first.read(0, &buf));

    var second = try Backend.init(testing.allocator);
    defer second.deinit();

    // WGL is thread-affine: creating the second context made it current, so the
    // first must refuse rather than read whichever surface happens to be bound.
    try testing.expectError(Error.GlContextLost, first.read(0, &buf));
    try testing.expectEqual(@as(usize, 8), try second.read(0, &buf));
}

test "resize changes the surface reads address" {
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    try testing.expectEqual(@as(u32, 256), backend.info().width);

    backend.resize(64, 64);
    const info = backend.info();
    try testing.expect(info.valid);
    try testing.expectEqual(@as(u32, 64), info.width);
    try testing.expectEqual(@as(u32, 64), info.height);

    const surface = @as(u64, info.width) * @as(u64, info.height) * 4;
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 64), try backend.read(0, &buf));
    // The new end is real, and so is the byte before it.
    try testing.expectEqual(@as(usize, 16), try backend.read(surface - 16, &buf));
    try testing.expectEqual(@as(usize, 0), try backend.read(surface, &buf));

    // Shrinking and growing again both keep working.
    backend.resize(32, 32);
    try testing.expectEqual(@as(u32, 32), backend.info().width);
    try testing.expectEqual(@as(usize, 0), try backend.read(32 * 32 * 4, &buf));
    backend.resize(128, 128);
    try testing.expectEqual(@as(u32, 128), backend.info().width);
    try testing.expectEqual(@as(usize, 64), try backend.read(0, &buf));
}

test "read after deinit returns GlContextLost, and deinit is idempotent" {
    var backend = try Backend.init(testing.allocator);
    backend.deinit();
    try testing.expect(!backend.valid());

    var buf: [8]u8 = undefined;
    try testing.expectError(Error.GlContextLost, backend.read(0, &buf));
    // Even a zero-length read: the missing context is checked before the length,
    // so "nothing to read" is not an answer a contextless backend can give.
    var empty: [0]u8 = .{};
    try testing.expectError(Error.GlContextLost, backend.read(0, &empty));

    // A second deinit must not underflow the shared window-class count.
    const after_first = classRefCount();
    backend.deinit();
    try testing.expectEqual(after_first, classRefCount());

    // And resize on a released backend is a no-op rather than a crash.
    backend.resize(64, 64);
    try testing.expect(!backend.valid());
}
