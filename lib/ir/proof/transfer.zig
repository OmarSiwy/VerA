//! The prover's transfer functions: an opcode and its operands' intervals in,
//! the result's interval and finite bit out (`Abstract`). Pure arithmetic on
//! `lattice.Interval`: no MIR walk, no allocation, no diagnostics.
//! LRM §3.2, §4.2.4, §4.2.5, §4.2.8, §4.3.1 (Table 4-14), §4.3.2 (Table 4-15),
//! §4.5.13, §9.5, §9.10, §9.13, §9.15, §9.18.

const proof = @import("../proof.zig");
const proof_lattice = @import("lattice.zig");
const Mir = @import("../mir.zig");
const math = proof.math;
const std = @import("std");

/// A value's abstract state: its interval for the domain proof, and the
/// separate finiteness fact (the rules on `proof.FloatMode`) that sets the
/// float mode.
pub const Abstract = struct { iv: proof_lattice.Interval, finite: bool };

/// Integer results (§3.2): clamp to the i64 range so an integer expression
/// can never make a unit `.strict`. Relational/logical results are 0/1.
pub fn integerIv(op: Mir.Opcode) proof_lattice.Interval {
    if (Mir.opcode.get(op).bool01) return .{ .lo = 0, .hi = 1 };
    return .{ .lo = -9.223372036854776e18, .hi = 9.223372036854776e18 };
}

/// Returns unary `op` over an operand with interval `a` and finite bit `af`.
/// A monotone function maps the endpoints; an opcode with no rule answers
/// top and not finite, which is sound and only loses precision.
pub fn unaryTransfer(op: Mir.Opcode, a: proof_lattice.Interval, af: bool) Abstract {
    const monotone: ?[2]f64 = switch (op) {
        .exp => .{ gm.exp(a.lo), gm.exp(a.hi) },
        .expm1 => .{ math.expm1(a.lo), math.expm1(a.hi) },
        .ln => .{ gm.log(a.lo), gm.log(a.hi) },
        .ln1p => .{ math.log1p(a.lo), math.log1p(a.hi) },
        .log10 => .{ @log10(a.lo), @log10(a.hi) },
        .sqrt => .{ @sqrt(a.lo), @sqrt(a.hi) },
        .sinh => .{ math.sinh(a.lo), math.sinh(a.hi) },
        .tanh => .{ math.tanh(a.lo), math.tanh(a.hi) },
        .asinh => .{ math.asinh(a.lo), math.asinh(a.hi) },
        .atan => .{ math.atan(a.lo), math.atan(a.hi) },
        .asin => .{ math.asin(a.lo), math.asin(a.hi) },
        .atanh => .{ math.atanh(a.lo), math.atanh(a.hi) },
        .acosh => .{ math.acosh(a.lo), math.acosh(a.hi) },
        .floor => .{ @floor(a.lo), @floor(a.hi) },
        .ceil => .{ @ceil(a.lo), @ceil(a.hi) },
        // .path_prev/.path_acc take `else` (unbounded): the latch holds a
        // value from an EARLIER solve, which current branch guards do not
        // constrain, so an identity interval here would be too narrow.
        .if_cast, .opt_barrier => .{ a.lo, a.hi },
        else => null, // else: not monotone, or no transfer: the switch below
    };
    if (monotone) |bounds| {
        const lo = bounds[0];
        const hi = bounds[1];
        // A NaN endpoint means the operand straddles the function's domain
        // edge (ln(-1), sqrt(-4), asin(2), acosh(0.5)), and the endpoints
        // then do not span the in-domain range: sqrt over [-4,9] is [0,3],
        // not [3,+inf]. checkDomain has already refused to prove this
        // operand, so the only sound interval is top. Endpoints at the edge
        // stay exact and wide: ln(0) = -inf and atanh(1) = +inf are not NaN.
        if (math.isNan(lo) or math.isNan(hi)) return .{ .iv = .top, .finite = false };
        const iv: proof_lattice.Interval = .{
            .lo = @min(lo, hi),
            .hi = @max(lo, hi),
            .lo_open = a.lo_open,
            .hi_open = a.hi_open,
        };
        const overflows = op == .exp or op == .expm1 or op == .sinh;
        return .{ .iv = iv, .finite = af and (!overflows or iv.bounded()) };
    }
    return switch (op) {
        .fneg => .{ .iv = .{
            .lo = -a.hi,
            .hi = -a.lo,
            .lo_open = a.hi_open,
            .hi_open = a.lo_open,
        }, .finite = af },
        .fabs => .{ .iv = absIv(a), .finite = af },
        // §4.3.2 acos is decreasing on [-1,1]. Same straddle rule as the
        // monotone path above: an out-of-domain endpoint (acos(2) = NaN)
        // voids the endpoint claim.
        .acos => blk: {
            const lo = math.acos(a.hi);
            const hi = math.acos(a.lo);
            if (math.isNan(lo) or math.isNan(hi)) break :blk .{ .iv = .top, .finite = false };
            break :blk .{ .iv = .{ .lo = lo, .hi = hi }, .finite = af };
        },
        // §4.3.2 cosh is even and grows: bounded only if |x| is bounded.
        .cosh => blk: {
            const m = absIv(a);
            const iv: proof_lattice.Interval = .{ .lo = 1, .hi = math.cosh(m.hi) };
            break :blk .{ .iv = iv, .finite = af and iv.bounded() };
        },
        .sin, .cos => .{ .iv = .{ .lo = -1, .hi = 1 }, .finite = af },
        // §4.3.2 tan is unbounded between poles; the domain check has
        // already run, so only finiteness is left and it is not provable.
        .tan => .{ .iv = .top, .finite = false },
        else => .{ .iv = .top, .finite = false }, // else: ⊤, not finite, is sound for any opcode; only precision is lost
    };
}

/// Returns binary `op` over `x` and `y`; `f` is both operands' finite bit.
/// Rule 3 on `proof.FloatMode` keeps `+ - * /` finite on finite operands,
/// except a divisor that can be zero. No rule: top, not finite.
pub fn binaryTransfer(op: Mir.Opcode, x: proof_lattice.Interval, y: proof_lattice.Interval, f: bool) Abstract {
    // Rule 3 on `FloatMode`: `+ - * /` on finite operands stay finite.
    switch (op) {
        .fadd => {
            const iv: proof_lattice.Interval = .{
                .lo = addLo(x.lo, y.lo),
                .hi = addHi(x.hi, y.hi),
                .lo_open = x.lo_open or y.lo_open,
                .hi_open = x.hi_open or y.hi_open,
            };
            return .{ .iv = iv, .finite = f };
        },
        .fsub => {
            const iv: proof_lattice.Interval = .{
                .lo = addLo(x.lo, -y.hi),
                .hi = addHi(x.hi, -y.lo),
                .lo_open = x.lo_open or y.hi_open,
                .hi_open = x.hi_open or y.lo_open,
            };
            return .{ .iv = iv, .finite = f };
        },
        .fmul => {
            const iv = combine(x, y, mulOp);
            return .{ .iv = iv, .finite = f };
        },
        .fdiv => {
            // A divisor that can be zero yields ±inf (§4.2.4 permits it;
            // only `%` errors). That is not an overflow, so rule 3
            // must not apply, or an
            // inf-producing value would be marked finite under `.optimized`.
            if (!y.excludesZero()) return .{ .iv = .top, .finite = false };
            // A §3.4.2 puncture (`exclude 0` on a sign-spanning range)
            // proves the divisor nonzero but not one-signed, and corner
            // combination is sound for `/` only on a one-signed divisor:
            // 1/y over [-10,10]\{0} is (-inf,-0.1] ∪ [0.1,+inf), while the
            // corners 1/±10 give its complement [-0.1,0.1]. The nonzero fact
            // still stands for finiteness (±inf only via overflow, rule 3);
            // only the interval claim is void.
            const iv = if (y.gt(0) or y.lt(0)) combine(x, y, divOp) else proof_lattice.Interval.top;
            return .{ .iv = iv, .finite = f };
        },
        // §4.2.4 modulus: |result| < |divisor|, sign of the dividend.
        .fmod => {
            const m = absIv(y).hi;
            const iv: proof_lattice.Interval = if (math.isFinite(m))
                .{ .lo = if (x.ge(0)) 0 else -m, .hi = if (x.le(0)) 0 else m }
            else
                .top;
            return .{ .iv = iv, .finite = f };
        },
        .pow => {
            const iv = powIv(x, y);
            return .{ .iv = iv, .finite = f and iv.bounded() };
        },
        .hypot => {
            const iv: proof_lattice.Interval = .{ .lo = 0, .hi = addHi(absIv(x).hi, absIv(y).hi) };
            return .{ .iv = iv, .finite = f };
        },
        .atan2 => return .{ .iv = .{ .lo = -math.pi, .hi = math.pi }, .finite = f },
        .fmin => return .{ .iv = .{
            .lo = @min(x.lo, y.lo),
            .hi = @min(x.hi, y.hi),
        }, .finite = f },
        .fmax => return .{ .iv = .{
            .lo = @max(x.lo, y.lo),
            .hi = @max(x.hi, y.hi),
        }, .finite = f },
        else => return .{ .iv = .top, .finite = false }, // else: ⊤, not finite, is sound for any opcode; only precision is lost
    }
}

/// Returns the abstract value of a `call` whose range the LRM fixes. Everything else is top
/// and not finite: an unmodelled call costs `.strict`, never a wrong `.optimized`.
pub fn callAbstract(c: Mir.Callee) Abstract {
    const positive: proof_lattice.Interval = .{ .lo = 0, .lo_open = true, .nonzero = true };
    const non_negative: proof_lattice.Interval = .{ .lo = 0 };
    // §9.5 the descriptor family is finite: every §9.5 call is integer-valued
    // (`callee.ty`), and in a residual unit, the only kind `proof` rates,
    // the emitter renders it as the literal 0 §9.5.1 reserves; the descriptor
    // operation happens only in the display unit (`codegen.Gen.emitting_display`).
    // No interval: §9.5.1's fd has bit 31 set, so there is nothing useful to bound.
    if (Mir.callee.isFileCall(c)) return .{ .iv = .top, .finite = true };
    return switch (c) {
        // §9.10 environment parameter functions; §9.18 $mfactor. `limexp` is
        // not here: its range is its argument's (`Prover.callTransfer`).
        .@"$vt", // thermal voltage kT/q > 0, argument-free; see callTransfer
        .@"$temperature", // absolute temperature, kelvin
        .@"$mfactor", // multiplicity factor > 0
        => .{ .iv = positive, .finite = true },
        .@"$abstime", .@"$realtime" => .{ .iv = non_negative, .finite = true },
        // §9.13 reference algorithms can overflow or underflow (Erlang's product,
        // Student-t's divisor, and unbounded real scale parameters). A distribution
        // name alone proves no finite value; retain strict floating-point mode.
        else => .{ .iv = .top, .finite = false }, // else: the prover models no other call's range
    };
}

// Endpoint arithmetic: a NaN sum (inf-inf) folds to the wide side. A unary NaN
// endpoint is not folded: it means the operand straddles the domain edge, and
// `unaryTransfer` answers top.

fn addLo(a: f64, b: f64) f64 {
    const r = a + b;
    return if (math.isNan(r)) -math.inf(f64) else r;
}

fn addHi(a: f64, b: f64) f64 {
    const r = a + b;
    return if (math.isNan(r)) math.inf(f64) else r;
}

/// `a * b`, the `combine` kernel of `*`.
pub fn mulOp(a: f64, b: f64) f64 {
    return a * b;
}
fn divOp(a: f64, b: f64) f64 {
    return a / b;
}
fn powOp(a: f64, b: f64) f64 {
    return gm.pow(a, b);
}

/// The devices' exp/log/pow, so a bound is the value a device computes.
const gm = @import("contract").gm;

/// §4.3.1 Table 4-14 pow(x,y) over a box. Corner combination is sound only where pow is
/// monotone in each argument separately, which fails in the ways a negative base admits:
///   - even integer exponent: interior minimum at x = 0 (the corners of pow([-2,2], 2) are
///     all 4, while the range is [0,4]);
///   - non-integer exponent: pow(neg, frac) is NaN (§4.3.1's "if x < 0, all integer y"),
///     which corners at integer endpoints never see;
///   - negative exponent: pole at x = 0, and IEEE pow(+0,-odd) = +inf is the wrong side of
///     the two-sided pole a base interval reaching 0 straddles.
fn powIv(x: proof_lattice.Interval, y: proof_lattice.Interval) proof_lattice.Interval {
    // x >= 0: pow = exp(y·ln x) is monotone in x for fixed y and in y for
    // fixed x, so box extrema sit at corners; IEEE fills the x = 0 edge
    // (pow(0,neg)=+inf, pow(0,0)=1) on the corners too. `combine`'s NaN guard
    // covers the exotic corners.
    if (x.ge(0)) return combine(x, y, powOp);
    // Base can be negative: only an exponent pinned to one known integer k
    // supports any claim (an integer-valued range mixes parities, and a
    // possibly-fractional exponent means possible NaN); otherwise top.
    const k = y.lo;
    if (!(y.lo == y.hi and math.isFinite(k) and k == @trunc(k))) return .top;
    if (k >= 0) {
        // Even k: x^k = |x|^k exactly, monotone in |x|; absIv restores the
        // interior 0 a sign-spanning base reaches. Odd k: monotone on all of R.
        // (Doubles >= 2^53 are all even integers, so @mod stays honest there.)
        if (@mod(k, 2) == 0) {
            const m = absIv(x);
            return .{ .lo = powOp(m.lo, k), .hi = powOp(m.hi, k) };
        }
        return .{ .lo = powOp(x.lo, k), .hi = powOp(x.hi, k) };
    }
    // k < 0: pole at 0. Sound only for a strictly negative base (x.hi < 0; an
    // open-at-0 bound is not enough: IEEE pow(+0, -odd) is +inf while the
    // one-sided limit from below is -inf). x^k is then monotone on the side.
    if (x.hi < 0) {
        const a = powOp(x.lo, k);
        const b = powOp(x.hi, k);
        return .{ .lo = @min(a, b), .hi = @max(a, b) };
    }
    // Punctured or zero-touching negative base with a negative exponent: the
    // same two-sided pole as the fdiv puncture, so top.
    return .top;
}

/// Returns the hull of `f` at the four corners of the box, closed (openness does not carry
/// through a product). A NaN corner (0*inf, 0/0, inf/inf) returns `top`.
/// Precondition: `f` is monotone in each argument separately over the box. `*` always is;
/// `/` only for a one-signed divisor (the `.fdiv` transfer checks); `pow` only for x >= 0
/// (`powIv` checks).
pub fn combine(x: proof_lattice.Interval, y: proof_lattice.Interval, f: *const fn (f64, f64) f64) proof_lattice.Interval {
    const c: @Vector(4, f64) = .{ f(x.lo, y.lo), f(x.lo, y.hi), f(x.hi, y.lo), f(x.hi, y.hi) };
    if (@reduce(.Or, c != c)) return .top; // a NaN corner
    return .{ .lo = @reduce(.Min, c), .hi = @reduce(.Max, c) };
}

fn absIv(a: proof_lattice.Interval) proof_lattice.Interval {
    if (a.ge(0)) return a;
    if (a.le(0)) return .{ .lo = -a.hi, .hi = -a.lo, .lo_open = a.hi_open, .hi_open = a.lo_open };
    return .{ .lo = 0, .hi = @max(@abs(a.lo), @abs(a.hi)) };
}

test "proof: random distribution names do not prove finite results" {
    for ([_][]const u8{ "$rng$uniform", "$rng$normal", "$rng$exponential", "$rng$poisson", "$rng$chi_square", "$rng$t", "$rng$erlang" }) |name|
        try std.testing.expect(!callAbstract(Mir.Callee.fromName(name)).finite);
}
