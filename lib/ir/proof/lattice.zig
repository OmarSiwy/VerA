//! The lattice: intervals and math-function domains (§4.3.1/§4.3.2 Tables 4-14/4-15).
//!
//! Pure values and functions: `Interval` meet/join/containment and the `Domain` each MIR opcode
//! requires. No MIR walk, no allocation, no diagnostics.
//!
//! LRM clauses this file's code cites: §3.4.2, §4.2, §4.2.4, §4.2.5, §4.2.8, §4.3.1, §4.3.2.
//!
//! Cut verbatim from `proof.zig`.

const proof = @import("../proof.zig");
const Mir = @import("../mir.zig");
const math = proof.math;

// ---------------------------------------------------------------------------
// The lattice
// ---------------------------------------------------------------------------

/// Abstract value: a closed/open real interval. `⊤` is `(-inf, inf)` closed,
/// which is also the "no evidence" element, so a zero-initialised pass is sound.
///
/// NaN never appears as a bound: a NaN constant widens to ⊤ (unknown), and every
/// bound-producing arithmetic below folds a NaN endpoint to the matching
/// infinity. Empty (`lo > hi`) means unreachable and vacuously satisfies every
/// domain, which is exactly right for a contradictory guard.
///
/// STAYS AoS. `@sizeOf` is 24 with 5 bytes of padding, and both proposed
/// shrinks were MEASURED and do not pay:
///   - `packed struct(u8)` for the three flags gives `8 + 8 + 1` aligned to 8 =
///     **24 bytes, exactly what it replaces**. It moves the padding, it does not
///     remove it.
///   - A true SoA split (`iv_lo`/`iv_hi`/`iv_flags`) is 17 B/value, but at the
///     MEASURED corpus size — median `mir.defs.len` 26, p99 198, max 917 — that
///     is 266 bytes saved on the median compile, and every consumer here
///     (`ivOf`, `meet`, `join`, the transfer functions) reads a WHOLE interval,
///     so the split makes the hot accesses worse, not better. Nothing in this
///     file tests a column of intervals; a vector-comparable predicate would be
///     the reason to split, and it has no caller.
/// `seedValues`' fill, ReleaseFast on this machine (`suggestVectorLength(f64)`
/// = 4), ns per fill, min of 25:
///     n:            38      210      929    24578
///     AoS @memset   14.5     76.7    349.7  17174.6   <- what ships
///     SoA 3x@memset 14.1     70.6    320.5  10745.2
///     SoA @Vector   11.9     57.3    253.6  15615.8   <- LOSES to @memset at 24578
/// The explicit vector store is 45% SLOWER than `@memset` at the only length
/// where SIMD would have paid, and at the median it wins 2.6 ns on a ~1 ms
/// compile. Both readings say the same thing: keep the memset.
pub const Interval = struct {
    lo: f64 = -math.inf(f64),
    hi: f64 = math.inf(f64),
    /// `true` ⇒ the bound itself is EXCLUDED (LRM §3.4.2 `(`/`)`).
    lo_open: bool = false,
    hi_open: bool = false,
    /// LRM §3.4.2 `exclude 0` on an otherwise unbounded parameter: a hole an
    /// interval cannot represent, but the one hole a divisor proof needs.
    nonzero: bool = false,

    pub const top: Interval = .{};

    pub fn point(x: f64) Interval {
        if (math.isNan(x)) return top;
        return .{ .lo = x, .hi = x };
    }

    /// Bounded on both sides ⇒ every member is a finite double.
    pub fn bounded(i: Interval) bool {
        return math.isFinite(i.lo) and math.isFinite(i.hi);
    }

    pub fn isEmpty(i: Interval) bool {
        return i.lo > i.hi or (i.lo == i.hi and (i.lo_open or i.hi_open));
    }

    /// Does the interval EXCLUDE ±inf? (An open infinite bound excludes it.)
    pub fn excludesInf(i: Interval) bool {
        const lo_ok = math.isFinite(i.lo) or (i.lo == -math.inf(f64) and i.lo_open);
        const hi_ok = math.isFinite(i.hi) or (i.hi == math.inf(f64) and i.hi_open);
        return lo_ok and hi_ok;
    }

    pub fn gt(i: Interval, k: f64) bool { // x > k
        return i.lo > k or (i.lo == k and i.lo_open);
    }
    pub fn ge(i: Interval, k: f64) bool { // x >= k
        return i.lo >= k;
    }
    pub fn lt(i: Interval, k: f64) bool { // x < k
        return i.hi < k or (i.hi == k and i.hi_open);
    }
    pub fn le(i: Interval, k: f64) bool { // x <= k
        return i.hi <= k;
    }
    pub fn excludesZero(i: Interval) bool {
        return i.nonzero or i.gt(0) or i.lt(0);
    }

    /// Intersection — how guard evidence is applied.
    pub fn meet(a: Interval, b: Interval) Interval {
        var r = a;
        if (b.lo > r.lo) {
            r.lo = b.lo;
            r.lo_open = b.lo_open;
        } else if (b.lo == r.lo) {
            r.lo_open = r.lo_open or b.lo_open;
        }
        if (b.hi < r.hi) {
            r.hi = b.hi;
            r.hi_open = b.hi_open;
        } else if (b.hi == r.hi) {
            r.hi_open = r.hi_open or b.hi_open;
        }
        r.nonzero = r.nonzero or b.nonzero;
        return r;
    }

    /// Convex hull — how phi/select operands and `from` range lists combine.
    pub fn join(a: Interval, b: Interval) Interval {
        var r = a;
        if (b.lo < r.lo) {
            r.lo = b.lo;
            r.lo_open = b.lo_open;
        } else if (b.lo == r.lo) {
            r.lo_open = r.lo_open and b.lo_open;
        }
        if (b.hi > r.hi) {
            r.hi = b.hi;
            r.hi_open = b.hi_open;
        } else if (b.hi == r.hi) {
            r.hi_open = r.hi_open and b.hi_open;
        }
        r.nonzero = r.nonzero and b.nonzero;
        return r;
    }
};

/// LRM Tables 4-14 / 4-15 domains. The operand of each must be proven in-domain
/// (else compile error), EXCEPT the "All x" group which governs float mode only.
pub const Domain = enum {
    all, // exp, expm1, sinh, cosh, tanh, sin, cos, floor, ceil, min, max, abs — §4.3.1/§4.3.2
    positive, // ln, log10                                   §4.3.1  (x > 0)
    gt_neg_one, // ln1p                                       §4.3.1  (x > -1)
    non_negative, // sqrt                                     §4.3.1  (x >= 0)
    unit_closed, // asin, acos                                §4.3.2  (-1 <= x <= 1)
    unit_open, // atanh                                       §4.3.2  (-1 < x < 1)
    ge_one, // acosh                                          §4.3.2  (x >= 1)
    nonzero_divisor, // '/', '%'                              §4.2 / §4.3.1
    tan_poles, // tan: x != n(π/2), n odd                     §4.3.2
    pow_sign, // pow(x,y) sign rules                          §4.3.1 Table 4-14
};

/// Map an Opcode to its LRM domain obligation. `.all` ⇒ nothing to prove.
/// For the binary members the obligation is on the SECOND operand
/// (`nonzero_divisor`) or on BOTH (`pow_sign`); everything else constrains the
/// single unary operand.
/// Is this value a 0/1 predicate (§4.2.5/§4.2.8)? Shared with ifconv.zig's
/// `peelToBool`: what peels there must be exactly what `condFacts` can mine
/// here, or a peel silently un-guards `b != 0 ? a/b : 0`.
pub fn isPredicateValue(mir: *const Mir, v: Mir.Value) bool {
    const def = mir.valueDef(mir.resolveAlias(v));
    if (def != .inst_result) return false;
    return switch (mir.instOp(def.inst_result)) {
        .flt, .fgt, .fle, .fge, .feq, .fne, .ilt, .igt, .ile, .ige, .ieq, .ine, .lognot => true,
        else => false,
    };
}

pub fn domainOf(op: Mir.Opcode) Domain {
    return switch (op) {
        .ln, .log10 => .positive,
        .ln1p => .gt_neg_one,
        .sqrt => .non_negative,
        .asin, .acos => .unit_closed,
        .atanh => .unit_open,
        .acosh => .ge_one,
        .tan => .tan_poles,
        .pow => .pow_sign,
        // NOT `.fdiv`: §4.2.4 makes ONLY `%`-by-zero an error. `x/0.0` is an
        // exact IEEE ±inf and is spec-legal, so it must not reject — it forfeits
        // finiteness instead (see the `.fdiv` transfer), which drops the unit to
        // `.strict`. Integer `/` and `%` stay errors: Zig's `@divTrunc(i64, 0)`
        // is illegal behavior, and integers have no inf to fall back on.
        .fmod, .idiv, .imod => .nonzero_divisor,
        else => .all,
    };
}
