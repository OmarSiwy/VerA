//! Smoke test of the load-bearing claims in this reference against the pinned
//! compiler, plus one differential case per VerA vector/branchless kernel
//! (simd-first non-negotiable: every kernel lands with its case here).
//! Run: `zig run ref/SIMD-Strategies/verify.zig -O ReleaseFast -mcpu=native`
//! ponytail: spot-check, not a full differential test. The full discipline is T8.
const std = @import("std");
const builtin = @import("builtin");
const simd = std.simd;
const assert = std.debug.assert;

const V16 = @Vector(16, u8);

extern fn @"llvm.x86.ssse3.pshuf.b.128"(V16, V16) V16;
extern fn @"llvm.aarch64.neon.tbl1"(V16, V16) V16;
extern fn @"llvm.x86.pclmulqdq"(@Vector(2, u64), @Vector(2, u64), i8) @Vector(2, u64);

const has_ssse3 = builtin.cpu.arch.isX86() and
    std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3);
const has_pclmul = builtin.cpu.arch.isX86() and
    std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul);

/// out[i] = tbl[idx[i] & 15]. One instruction on x86 SSSE3 and on aarch64.
inline fn lookup16(tbl: V16, idx: V16) V16 {
    const lo = idx & @as(V16, @splat(0x0F));
    if (comptime has_ssse3) return @"llvm.x86.ssse3.pshuf.b.128"(tbl, lo);
    if (comptime builtin.cpu.arch == .aarch64) return @"llvm.aarch64.neon.tbl1"(tbl, lo);
    return lookup16Scalar(tbl, lo);
}

/// Portable oracle. Keep it even after shipping the intrinsic (T8 step 5).
fn lookup16Scalar(tbl: V16, idx: V16) V16 {
    const t: [16]u8 = tbl;
    const i: [16]u8 = idx;
    var out: [16]u8 = undefined;
    for (&out, i) |*o, x| o.* = t[x & 0x0F];
    return out;
}

fn prefixXorScalar(x: u64) u64 {
    var acc: u64 = 0;
    var run: u64 = 0;
    for (0..64) |b| {
        run ^= (x >> @intCast(b)) & 1;
        acc |= run << @intCast(b);
    }
    return acc;
}

fn maskEq(block: *const [64]u8, needle: u8) u64 {
    const V = @Vector(64, u8);
    const v: V = block.*;
    return @bitCast(v == @as(V, @splat(needle)));
}

pub fn main() void {
    // T1 — runtime 16-way table lookup, intrinsic vs scalar oracle, 50k pairs.
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    for (0..50_000) |_| {
        var tbl: [16]u8 = undefined;
        var idx: [16]u8 = undefined;
        rand.bytes(&tbl);
        rand.bytes(&idx);
        const got: [16]u8 = lookup16(tbl, idx);
        const want: [16]u8 = lookup16Scalar(tbl, idx);
        assert(std.mem.eql(u8, &got, &want));
    }

    // T1 — nibble classification: lo_class & hi_class.
    {
        const lo_tbl: V16 = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0 };
        const hi_tbl: V16 = .{ 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        const bytes: V16 = @splat(0x20); // hi=2, lo=0
        const cls: [16]u8 = lookup16(lo_tbl, bytes) & lookup16(hi_tbl, bytes >> @splat(4));
        assert(cls[0] == (1 & 3));
    }

    // T2 — @Vector(64,u8) compare bitcasts to a u64 mask; lane 0 is the low bit.
    {
        var block: [64]u8 = @splat('.');
        block[0] = 'x';
        block[5] = 'x';
        block[63] = 'x';
        const m = maskEq(&block, 'x');
        assert(m == (1 | (1 << 5) | (1 << 63)));
        assert(@ctz(m) == 0);
        assert(63 - @clz(m) == 63);
        assert(@popCount(m) == 3);
        assert((m & (m -% 1)) == ((1 << 5) | (1 << 63)));
    }

    // T2 — run boundaries.
    {
        const m: u64 = 0b0111_0000;
        assert(m & ~(m << 1) == 0b0001_0000); // run start
        assert(m & ~(m >> 1) == 0b0100_0000); // run end
    }

    // T3 — mergeShift is alignr: real bytes from the previous block.
    {
        const prev: @Vector(4, u8) = .{ 1, 2, 3, 4 };
        const cur: @Vector(4, u8) = .{ 5, 6, 7, 8 };
        assert(@reduce(.And, simd.mergeShift(prev, cur, 3) == @Vector(4, u8){ 4, 5, 6, 7 }));
        assert(@reduce(.And, simd.mergeShift(prev, cur, 2) == @Vector(4, u8){ 3, 4, 5, 6 }));
    }

    // T4 — saturating subtract as a threshold test on UTF-8 lead bytes.
    {
        const lead: @Vector(4, u8) = .{ 0x41, 0xC3, 0xE2, 0xF0 };
        const hit = lead -| @as(@Vector(4, u8), @splat(0xDF));
        assert(@reduce(.And, hit == @Vector(4, u8){ 0, 0, 3, 17 }));
    }

    // T5 — carry propagation finds odd-length backslash-run ends.
    {
        const B: u64 = 0b1110;
        const starts = B & ~(B << 1);
        const odd_starts = starts & 0xAAAA_AAAA_AAAA_AAAA;
        const carries = B +% odd_starts;
        assert((carries ^ B) == 0b1_0000);
    }

    // T5 — prefix XOR via clmul vs scalar, 100k inputs.
    if (comptime has_pclmul) {
        for (0..100_000) |_| {
            const x = rand.int(u64);
            const v: @Vector(2, u64) = .{ x, 0 };
            const ones: @Vector(2, u64) = .{ ~@as(u64, 0), 0 };
            assert(@"llvm.x86.pclmulqdq"(v, ones, 0)[0] == prefixXorScalar(x));
        }
    }

    // T5 — lane-wise cousin.
    {
        const p = simd.prefixScan(.Add, 1, simd.iota(u8, 8));
        assert(@reduce(.And, p == @Vector(8, u8){ 0, 1, 3, 6, 10, 15, 21, 28 }));
    }

    // Gotcha 3 — the two "rights" point in opposite directions.
    {
        const v: @Vector(4, u8) = .{ 10, 20, 30, 40 };
        assert(@reduce(.And, simd.shiftElementsRight(v, 1, 99) == @Vector(4, u8){ 99, 10, 20, 30 }));
        assert(@reduce(.And, simd.shiftElementsLeft(v, 1, 99) == @Vector(4, u8){ 20, 30, 40, 99 }));
    }

    // ── VerA kernel cases land below this line, one block per kernel. ──

    // Eager §4.2.12 select (codegen.zig renderInst / contract `sel`): the
    // safety claim is that a DEAD arm's NaN/inf is discarded by the pick —
    // that is what licenses evaluating both arms in a `.strict` unit. Pin
    // that @select does exactly that, per lane, and agrees with the scalar
    // lazy `if` on 100k random mask/arm triples.
    {
        const V4f = @Vector(4, f64);
        const nan = std.math.nan(f64);
        const inf = std.math.inf(f64);
        const mask: V4f = .{ 1.0, 0.0, 1.0, 0.0 };
        const then_v: V4f = .{ 2.0, nan, inf, nan };
        const else_v: V4f = .{ nan, 3.0, nan, -inf };
        const zeros4: V4f = @splat(0.0);
        const r = @select(f64, mask != zeros4, then_v, else_v);
        assert(r[0] == 2.0 and r[1] == 3.0 and r[2] == inf and r[3] == -inf);
        for (0..100_000) |_| {
            var m: [4]f64 = undefined;
            var a: [4]f64 = undefined;
            var b: [4]f64 = undefined;
            for (0..4) |i| {
                m[i] = @floatFromInt(rand.int(u1));
                a[i] = rand.float(f64);
                b[i] = rand.float(f64);
            }
            const rv: [4]f64 = @select(f64, @as(V4f, m) != zeros4, @as(V4f, a), @as(V4f, b));
            for (0..4) |i| {
                const want = if (m[i] != 0.0) a[i] else b[i]; // the scalar oracle
                assert(rv[i] == want);
            }
        }
    }

    // Batch value-form S (one operating point per lane): the differential
    // gate is `laneCheck` in every generated testbench (src/backend/tb.zig),
    // which runs on each fixture that earned `lane_clean` — a corpus-wide
    // check no standalone case here could match.

    // §4.5.15 branchless SPICE limiters (src/backend/limit_kernels.zig):
    // `@import("../../src/…")` from here is "import of file outside module
    // path" under `zig run`, so the differential case (1e6 random tuples plus
    // boundary and signed-zero hits, asserting bit-identity against the
    // branchy ngspice oracles) lives as a `test` block in limit_kernels.zig
    // itself, where `zig build test-va` collects it via codegen.zig's import.

    std.debug.print("ok — zig {f}, ssse3={}, pclmul={}\n", .{
        builtin.zig_version, has_ssse3, has_pclmul,
    });
}
