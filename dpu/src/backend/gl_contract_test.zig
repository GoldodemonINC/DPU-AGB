//! A compile-time pin on the claim `gl.zig` makes about itself.
//!
//! `gl.zig`'s header says it is "a drop-in backend for
//! `residency.Faults(GLBackend)`". That is a claim about an interface, and an
//! interface claim asserted only in prose rots the moment either side moves.
//! This module makes the claim executable: it instantiates the *real* fault
//! path over the *real* OpenGL backend and forces the entry points to be
//! analysed. If `gl.Backend` stops matching what `residency.Faults` calls on a
//! backend -- `read(self: *Backend, offset: u64, buf: []u8)` returning a byte
//! count -- this file stops compiling.
//!
//! It is deliberately not a runtime test. `residency.Faults` needs an
//! allocator and a live backend to *run*, but the contract it imposes is a
//! type-level fact, so the pin is a compile-time assertion and therefore lives
//! in `zig build check` -- the gate with no display -- rather than behind the
//! `gl-test` step that needs a live WindowStation.
//!
//! Why this shape and not `refAllDecls`: Zig analyses a function body only when
//! something needs its code, so merely naming the type proves nothing. Taking
//! the address of each entry point is the codegen dependency that actually
//! pulls the body in, and it is what makes a signature drift a compile error.

const std = @import("std");
const residency = @import("residency");
const gl = @import("gl");

/// The fault path instantiated over the OpenGL backend. Named, so the compile
/// error -- when it comes -- points at one line rather than at a struct
/// literal inside a test.
const Faults = residency.Faults(gl.Backend);

comptime {
    // The address-of forms force body analysis; the typed forms below assert
    // the exact signatures the fault path relies on, so a backend that
    // changes the shape of `read` is red here rather than at a call site.
    _ = &Faults.read;
    _ = &Faults.init;
    _ = &Faults.deinit;
}

test "the OpenGL backend satisfies the residency fault path's Backend contract" {
    // `read` is the whole of the contract: the fault path calls
    // `backend.read(offset, buf)` and treats the result as a byte count.
    const ReadFn = *const fn (*Faults, u64, []u8) anyerror!usize;
    _ = @as(ReadFn, &Faults.read);

    // Instantiating the fault path at all is the other half: a backend whose
    // `read` does not coerce into `Faults.Error` would have failed above.
    try std.testing.expect(@sizeOf(Faults) > 0);
}
