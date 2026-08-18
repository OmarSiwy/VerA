//! §4.5.11 `laplace_*` / §4.5.12 `zi_*` filters — plan, then emit.
//!
//! Transformation: a filter operator's MIR call arguments → a CASCADE of
//! direct-form sections, `H = ∏ num[i]/den[i]`, emitted as one coefficient
//! reader per filter.
//!
//! This group already had the plan/emit seam the rest of the emitter lacks:
//! `filterPlan` returns a `FilterPlan` that `emitFilterSections` renders, so the
//! numeric decisions are made before any text exists. That is why it splits out
//! cleanly — `emitOperator` reaches in through `filterPlan` alone.
//!
//! Free functions over `*Gen`: Zig cannot extend a struct across files.
//!
//! The kernels these sections call are NOT here — they are
//! `backend/filter_kernels.zig`, `@embedFile`d verbatim into the device so the
//! numerics the tests check are the numerics the device runs.

const std = @import("std");
const Mir = @import("../ir/mir.zig");
const Analysis = @import("../ir/analysis.zig");
const Lower = @import("../ir/lower.zig");
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const VTy = Analysis.VTy;
const assert = std.debug.assert;

// =======================================================================
// §4.5.11 / §4.5.12 filters
// =======================================================================

/// One polynomial, ASCENDING powers of `s` (§4.5.11) or `z⁻¹` (§4.5.12),
/// as emitted expression text — a literal or `model.<p>`, so a model-card
/// override reaches the coefficient without a rebuild.
pub const Poly = []const []const u8;

/// A filter realised as a CASCADE of sections, `H = ∏ num[i]/den[i]`.
///
/// The root forms (`*_zp`, `*_zd` zeros, `*_np`, `*_zp` poles) stay
/// FACTORED: one section per real root, one per conjugate pair, each
/// multiplied out as a REAL quadratic. Expanding ∏(1 − s/ρₖ) into a single
/// coefficient vector is the Wilkinson operation — for a 6th-order filter
/// the coefficients span decades and the roots move visibly on the way
/// back out — so it is never done. Only the coefficient forms (`*_nd`,
/// `*_zd` denominator, `*_np` numerator) arrive as a polynomial already,
/// and those stay one direct-form section at their full degree.
pub const FilterPlan = struct {
    num: []const Poly = &.{},
    den: []const Poly = &.{},
    /// Sections = max(num.len, den.len); a missing side is the polynomial 1.
    ns: usize = 0,
    /// Highest degree over every section — the shape of the state arrays.
    deg: usize = 0,
    /// Do the coefficients read Model? Decides `__sec`'s parameter name.
    uses_model: bool = false,
    /// §4.5.12 sampling period T. Null for a laplace filter.
    period: ?[]const u8 = null,
    err: ?[]const u8 = null,

    /// Section `i` of one side; a side that ran out of sections is the
    /// polynomial 1, which is how a 3-zero / 1-pole filter still cascades.
    fn poly(g: FilterPlan, numerator: bool, i: usize) Poly {
        const list = if (numerator) g.num else g.den;
        return if (i < list.len) list[i] else &.{"1.0"};
    }
};

pub fn planErr(msg: []const u8) FilterPlan {
    return .{ .err = msg };
}

/// Decode one `laplace_*`/`zi_*` call into its cascade. Lowering flattened
/// each vector argument as `<count>, e0, e1, …` (see `lower.appendVectorArg`),
/// so the argument list is g-describing.
pub fn filterPlan(g: *Gen, inst: Mir.Inst, args: []const Mir.Value) Error!FilterPlan {
    const name = g.mir.instData(inst).call.name;
    const z = std.mem.startsWith(u8, name, "zi_");
    // `*_zp`/`*_zd` give the ZEROS as roots; `*_zp`/`*_np` give the POLES
    // as roots. The two letters after the underscore say which.
    const tail = name[if (z) 3 else 8..];
    const num_roots = tail[0] == 'z';
    const den_roots = tail[1] == 'p';

    const saved = g.uses_model;
    g.uses_model = false;
    defer g.uses_model = saved;

    const nv = readVec(g, args, 1) orelse
        return planErr("LRM 4.5.11/4.5.12: the numerator argument of a filter must be a vector");
    const dv = readVec(g, args, nv.next) orelse
        return planErr("LRM 4.5.11/4.5.12: the denominator argument of a filter must be a vector");

    var num: std.ArrayList(Poly) = .empty;
    var den: std.ArrayList(Poly) = .empty;
    if (try filterSide(g, &num, nv.elems, num_roots, z, false)) |m| return planErr(m);
    if (try filterSide(g, &den, dv.elems, den_roots, z, true)) |m| return planErr(m);

    var p: FilterPlan = .{
        .num = num.items,
        .den = den.items,
        .ns = @max(num.items.len, den.items.len),
        .uses_model = g.uses_model,
    };
    for (0..p.ns) |i| {
        p.deg = @max(p.deg, @max(p.poly(true, i).len, p.poly(false, i).len) - 1);
    }

    if (z) {
        // §4.5.12 "T specifies the period of the filter, is mandatory, and
        // shall be positive."
        if (dv.next >= args.len) return planErr(
            "LRM 4.5.12: the sampling period T of a zi_* filter is mandatory",
        );
        if (g.an.foldConst(args[dv.next], 0, true)) |c| {
            if (!(c.f > 0.0)) return planErr(
                "LRM 4.5.12: the sampling period T of a zi_* filter shall be positive",
            );
        }
        p.period = try g.f64Expr(args[dv.next]);
        p.uses_model = g.uses_model;
        // §4.5.12 τ (transition time) and t0 (time of the first transition).
        // The emitted sampler steps abruptly at t = 0, and that is not a
        // stand-in for the general form — it is exactly what the clause
        // describes for τ = 0 ("If the transition time is specified as zero
        // (0), then the output is abruptly discontinuous") starting at t0 = 0.
        // So those two values are what the implementation MEANS and are
        // accepted; anything else is a different waveform, and a silent
        // different waveform is worse than a refusal.
        //
        // Whether a τ = 0 filter may be contributed straight to a branch is
        // the other half of the clause, and it is a property of the STATEMENT
        // rather than of the call — `lower.checkZeroTransitionZFilter` (E0518).
        for (args[@min(dv.next + 1, args.len)..]) |a| {
            const c = g.an.foldConst(a, 0, true) orelse return planErr(
                "LRM 4.5.12: the τ and t0 arguments of a zi_* filter must be constant expressions",
            );
            if (c.f < 0.0) return planErr(
                "LRM 4.5.12: the transition time τ of a zi_* filter shall be nonnegative",
            );
            if (c.f != 0.0) return planErr(
                "VerA implements only the τ = 0 / t0 = 0 form of a zi_* filter, whose output " ++
                    "is abruptly discontinuous at the sample (LRM 4.5.12)",
            );
        }
    }
    // §4.5.11 the optional ε argument only "deriv[es] an absolute
    // tolerance (if needed)"; VerA has no per-signal tolerance table, so
    // dropping it changes no value the device computes.
    return p;
}

pub const Vec = struct { elems: []const Mir.Value, next: usize };

/// Read one flattened vector argument: a literal count followed by that
/// many elements. The count is always an `int_const` (lowering emits it);
/// anything else means this argument was never a vector.
pub fn readVec(g: *const Gen, args: []const Mir.Value, i: usize) ?Vec {
    if (i >= args.len) return null;
    const def = g.mir.valueDef(g.an.rv(args[i]));
    if (def != .int_const or def.int_const < 0) return null;
    const n: usize = @intCast(def.int_const);
    if (i + 1 + n > args.len) return null;
    return .{ .elems = args[i + 1 ..][0..n], .next = i + 1 + n };
}

/// Turn one side of a filter into its sections. `roots` selects the
/// root-vector reading (pairs of real/imaginary parts) over the
/// coefficient reading. Returns a diagnostic, or null on success.
pub fn filterSide(
    g: *Gen,
    out: *std.ArrayList(Poly),
    elems: []const Mir.Value,
    roots: bool,
    z: bool,
    is_den: bool,
) Error!?[]const u8 {
    if (elems.len == 0) {
        // "The zeros argument may be represented as a null argument" — no
        // zeros means the numerator polynomial 1. An empty DENOMINATOR has
        // no such reading; it would be a division by nothing.
        if (is_den) return "LRM 4.5.11/4.5.12: the denominator of a filter shall not be empty";
        return null;
    }
    if (!roots) {
        var poly = try g.arena.alloc([]const u8, elems.len);
        var all_zero = true;
        for (elems, 0..) |e, i| {
            poly[i] = try g.f64Expr(e);
            const c = g.an.foldConst(e, 0, true);
            if (c == null or c.?.f != 0.0) all_zero = false;
        }
        if (is_den and all_zero)
            return "LRM 4.5.11/4.5.12: the denominator coefficients of this filter are identically zero";
        try out.append(g.arena, poly);
        return null;
    }
    // §4.5.11.1 "ζ is a vector of M pairs of real numbers … the first
    // number in the pair is the real part of the zero and the second is
    // the imaginary part."
    if (elems.len % 2 != 0)
        return "LRM 4.5.11/4.5.12: a root vector is a list of (real, imaginary) PAIRS, so its length must be even";
    const m = elems.len / 2;
    const used = try g.arena.alloc(bool, m);
    @memset(used, false);
    for (0..m) |k| {
        if (used[k]) continue;
        used[k] = true;
        // The conjugate PAIRING is structural — it decides how many
        // sections exist and of what degree — so the imaginary part has to
        // be known here. The real part may stay a runtime parameter.
        const im = g.an.foldConst(elems[2 * k + 1], 0, true) orelse
            return "LRM 4.5.11/4.5.12: the imaginary part of a filter root must be a constant expression " ++
                "(the conjugate pairing decides the section structure)";
        const re = try g.f64Expr(elems[2 * k]);
        const re_c = g.an.foldConst(elems[2 * k], 0, true);
        if (im.f == 0.0) {
            // "If a root is zero, then the term associated with it is
            // implemented as s, rather than (1 − s/r)". In z⁻¹ the LRM's
            // own wording says "z", which is a non-causal advance and
            // contradicts its H(z) formula (which is written in z⁻¹
            // throughout); the causal dual of `s` is the unit delay z⁻¹.
            if (re_c != null and re_c.?.f == 0.0) {
                try out.append(g.arena, &.{ "0.0", "1.0" });
            } else if (z) {
                // §4.5.12 (1 − z⁻¹ρ)
                try out.append(g.arena, try polyOf(g, &.{ "1.0", try neg(g, re) }));
            } else {
                // §4.5.11 (1 − s/ρ). A model card that sets ρ to 0 at run
                // time divides by zero — the same class of defect as a
                // zero-valued resistance, and LRM 4.2.4 makes only `%` by
                // zero an error.
                try out.append(g.arena, try polyOf(g, &.{
                    "1.0", try std.fmt.allocPrint(g.arena, "-1.0 / ({s})", .{re}),
                }));
            }
            continue;
        }
        // "If a root is complex, its conjugate shall also be present."
        const j = conjugateOf(g, elems, used, re, im.f) orelse
            return "LRM 4.5.11/4.5.12: a complex filter root has no conjugate partner " ++
                "(\"If a root is complex, its conjugate shall also be present\")";
        used[j] = true;
        // Multiplied out as a REAL quadratic — never through complex
        // arithmetic, and never by expanding the whole product.
        //   §4.5.11  (1 − s/ρ)(1 − s/ρ*) = 1 − 2a/(a²+b²)·s + 1/(a²+b²)·s²
        //   §4.5.12  (1 − z⁻¹ρ)(1 − z⁻¹ρ*) = 1 − 2a·z⁻¹ + (a²+b²)·z⁻²
        // ponytail: b ≠ 0 here, so a²+b² > 0 and the §4.5.11 divisions are
        // safe for any real part, including a == 0 — which is a pole pair
        // ON the imaginary axis, an UNDAMPED section that rings forever
        // under the trapezoidal rule. That is the transfer function the
        // model asked for, not a defect of this realisation.
        const bb = try g.fmtF64(im.f * im.f);
        const mag = try std.fmt.allocPrint(g.arena, "(({0s}) * ({0s}) + {1s})", .{ re, bb });
        try out.append(g.arena, if (z) try polyOf(g, &.{
            "1.0",
            try std.fmt.allocPrint(g.arena, "-2.0 * ({s})", .{re}),
            mag,
        }) else try polyOf(g, &.{
            "1.0",
            try std.fmt.allocPrint(g.arena, "-2.0 * ({s}) / {s}", .{ re, mag }),
            try std.fmt.allocPrint(g.arena, "1.0 / {s}", .{mag}),
        }));
    }
    return null;
}

/// Index of the unused root that is the conjugate of (`re`, `im`): same
/// real part, negated imaginary part. Real parts are compared as EMITTED
/// TEXT, so `model.a` pairs with `model.a` without needing its value.
pub fn conjugateOf(g: *Gen, elems: []const Mir.Value, used: []const bool, re: []const u8, im: f64) ?usize {
    for (used, 0..) |u, j| {
        if (u) continue;
        const jm = g.an.foldConst(elems[2 * j + 1], 0, true) orelse continue;
        if (jm.f != -im) continue;
        // `f64Const`, not `f64Expr`: this is a SPECULATIVE render used only
        // to pair roots, so a root that does not resolve is "not the
        // conjugate", not a diagnostic. The real render reports it.
        const jre = (g.f64Const(elems[2 * j], 0, false) catch continue) orelse continue;
        if (std.mem.eql(u8, jre, re)) return j;
    }
    return null;
}

pub fn polyOf(g: *Gen, items: []const []const u8) Error!Poly {
    return g.arena.dupe([]const u8, items);
}

pub fn neg(g: *Gen, e: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(g.arena, "-({s})", .{e});
}

/// `<unit>__sec(model)` — the cascade's CONTINUOUS coefficients, rebuilt
/// from Model on every call so a model-card override lands without a
/// recompile. Public because it is also the exact transfer function: a host
/// doing `.ac`/`.noise` builds `H(jω) = ∏ num_i(jω)/den_i(jω)` from exactly
/// these numbers, which the real-valued residual cannot carry.
pub fn emitFilterSections(g: *Gen, n: []const u8, p: FilterPlan, z: bool) Error!usize {
    const var_name = if (z) "z⁻¹" else "s";
    try g.w(
        "/// §4.5.{s} cascade sections of `{s}`: H = ∏ [i][0]({s}) / [i][1]({s}),\n" ++
            "/// coefficients ascending. Read from Model on every evaluation.\n",
        .{ if (z) "12" else "11", n, var_name, var_name },
    );
    const at_fn = g.out.items.len;
    try g.w("pub fn {s}__sec({s}: *const Model) [{d}][2][{d}]f64 {{\n    return .{{\n", .{
        n, if (p.uses_model) "model" else "_", p.ns, p.deg + 1,
    });
    for (0..p.ns) |i| {
        try g.w("        .{{ ", .{});
        for ([_]bool{ true, false }, 0..) |numerator, s| {
            if (s == 1) try g.w(", ", .{});
            try g.w(".{{ ", .{});
            const poly = p.poly(numerator, i);
            for (0..p.deg + 1) |c| {
                if (c != 0) try g.w(", ", .{});
                try g.w("{s}", .{if (c < poly.len) poly[c] else "0.0"});
            }
            try g.w(" }}", .{});
        }
        try g.w(" }},\n", .{});
    }
    try g.w("    }};\n}}\n\n", .{});
    return at_fn;
}

