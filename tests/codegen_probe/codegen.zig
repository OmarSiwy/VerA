//! Codegen probe for the code `lib/device/codegen/render.zig` emits to start
//! a §3.2 memory-backed array each evaluation. Build with
//! `zig build-obj -OReleaseFast -mcpu=x86_64_v3 -fstrip -femit-asm=k.s -fno-emit-bin`.
//! It was `zFill`, a hand-written `@Vector(4, T)` store loop behind a
//! volatile read that kept LLVM off Zig 0.16's byte-wise compiler_rt
//! `memset`. Under 0.18 a plain `@memset` of a run-time value is the same
//! 51-53 packed stores, and of zero (what the emitter writes) a call into the
//! fast `memset`: 19.5 vs 51 cycles for 203 `f64`.
//!
// expect: fill_f64 vector>=40
// expect: fill_dual vector>=10

/// A §3.2 `real` array of 203 elements set to a run-time value.
export fn fill_f64(a: [*]f64, len: usize, v: f64) void {
    _ = len;
    @memset(a[0..203], v);
}

/// An array of 3-lane duals (a dense family's `zOf(S, m)`).
export fn fill_dual(a: [*][4]f64, len: usize, v: *const [4]f64) void {
    _ = len;
    @memset(a[0..100], v.*);
}
