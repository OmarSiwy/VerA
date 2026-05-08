//! The prover's lattice: `Interval` meet/join/containment and the `Domain` each MIR opcode
//! requires (§4.3.1/§4.3.2 Tables 4-14/4-15). Pure values: no MIR walk, no allocation,
//! no diagnostics. LRM §3.4.2, §4.2, §4.2.4, §4.2.5, §4.2.8, §4.3.1, §4.3.2.

const proof = @import("../proof.zig");
const Mir = @import("../mir.zig");
const math = proof.math;

/// Abstract value: a real interval with open or closed ends. `top` is `(-inf, inf)` closed,
/// which is also the "no evidence" element, so a zero-initialised pass is sound.
/// NaN never appears as a bound: a NaN constant widens to `top`, and the transfer functions
/// answer `top` or the wide infinity for a NaN endpoint. Empty (`lo > hi`) means unreachable
/// and vacuously satisfies every domain, which is right for a contradictory guard.
pub const Interval = struct {
    // Stays AoS (24 bytes): every consumer reads a whole interval, and packing the three flags
    // only moves the padding. `seedValues`' fill, ReleaseFast, ns per fill (min of 25):
    //     n:            38      210      929    24578
    //     AoS @memset   14.5     76.7    349.7  17174.6   <- ships
    //     SoA 3x@memset 14.1     70.6    320.5  10745.2
    //     SoA @Vector   11.9     57.3    253.6  15615.8   <- loses to @memset at 24578
    // Corpus MIR is small (median 26 values), so neither split pays.
    lo: f64 = -math.inf(f64),
    hi: f64 = math.inf(f64),
    /// `true`: the bound itself is excluded (LRM §3.4.2 `(`/`)`); likewise `hi_open`.
    lo_open: bool = false,
    hi_open: bool = false,
    /// LRM §3.4.2 `exclude 0` on an otherwise unbounded parameter: a hole an
    /// interval cannot represent, but the one hole a divisor proof needs.
    nonzero: bool = false,

    /// `(-inf, inf)`: no evidence.
    pub const top: Interval = .{};

    /// Returns the one-point interval `[x, x]`, or `top` for NaN.
    pub fn point(x: f64) Interval {
        if (math.isNan(x)) return top;
        return .{ .lo = x, .hi = x };
    }

    /// Returns whether both bounds are finite, so every member is a finite double.
    pub fn bounded(i: Interval) bool {
        return math.isFinite(i.lo) and math.isFinite(i.hi);
    }

    /// Returns whether no value satisfies the bounds (unreachable).
    pub fn isEmpty(i: Interval) bool {
        return i.lo > i.hi or (i.lo == i.hi and (i.lo_open or i.hi_open));
    }

    /// Returns whether the interval excludes ±inf; an open infinite bound excludes it.
    pub fn excludesInf(i: Interval) bool {
        const lo_ok = math.isFinite(i.lo) or (i.lo == -math.inf(f64) and i.lo_open);
        const hi_ok = math.isFinite(i.hi) or (i.hi == math.inf(f64) and i.hi_open);
        return lo_ok and hi_ok;
    }

    /// Returns whether every member x satisfies x > k.
    pub fn gt(i: Interval, k: f64) bool {
        return i.lo > k or (i.lo == k and i.lo_open);
    }
    /// Returns whether every member x satisfies x >= k.
    pub fn ge(i: Interval, k: f64) bool {
        return i.lo >= k;
    }
    /// Returns whether every member x satisfies x < k.
    pub fn lt(i: Interval, k: f64) bool {
        return i.hi < k or (i.hi == k and i.hi_open);
    }
    /// Returns whether every member x satisfies x <= k.
    pub fn le(i: Interval, k: f64) bool {
        return i.hi <= k;
    }
    /// Returns whether 0 is provably not a member (a sign or a §3.4.2 `exclude 0` hole).
    pub fn excludesZero(i: Interval) bool {
        return i.nonzero or i.gt(0) or i.lt(0);
    }

    /// Returns the intersection; guard evidence is applied this way.
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

    /// Returns the convex hull; phi and select operands and `from` range lists combine this way.
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

/// LRM Tables 4-14/4-15 domains, an opcode column of `Mir.opcode`.
pub const Domain = Mir.opcode.Domain;

/// Returns whether `v` is a 0/1 predicate (§4.2.5/§4.2.8).
/// Shared with ifconv.zig's `peelToBool`: what peels there must be exactly what `condFacts`
/// can mine, or a peel silently un-guards `b != 0 ? a/b : 0`.
pub fn isPredicateValue(mir: *const Mir, v: Mir.Value) bool {
    const def = mir.valueDef(mir.resolveAlias(v));
    if (def != .inst_result) return false;
    return Mir.opcode.get(mir.instOp(def.inst_result)).predicate;
}

/// Returns the LRM domain an opcode's argument must satisfy; `.all` means nothing to prove.
pub fn domainOf(op: Mir.Opcode) Domain {
    return Mir.opcode.get(op).domain;
}
