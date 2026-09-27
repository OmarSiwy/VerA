//! Filter operator MIR call -> `FilterPlan` (a cascade of direct-form sections,
//! `H = ∏ num[i]/den[i]`) -> one `<unit>__sec` coefficient reader per filter.
//! LRM §4.5.11 (`laplace_*`), §4.5.12 (`zi_*`).
//! Planning makes every numeric decision before any text exists. The kernels the
//! sections call are `filter_kernels.zig`, spliced verbatim into the device.

const std = @import("std");
const Mir = @import("ir").Mir;
// ponytail: filter planning reuses Gen's analysis and expression renderers.
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;

// =======================================================================
// §4.5.11 / §4.5.12 filters
// =======================================================================

/// One polynomial in ascending powers of `s` (§4.5.11) or `z⁻¹` (§4.5.12), as
/// emitted expression text: a literal or `model.<p>`, so a model-card override
/// reaches the coefficient without a rebuild.
pub const Poly = []const []const u8;

/// A filter realised as a cascade of sections, `H = ∏ num[i]/den[i]`.
///
/// Root forms stay factored: one section per real root, one real quadratic per
/// conjugate pair. Expanding ∏(1 − s/ρₖ) into one coefficient vector is
/// ill-conditioned (Wilkinson), so it is never done. Coefficient forms arrive
/// as a polynomial and stay one direct-form section at full degree.
pub const FilterPlan = struct {
    num: []const Poly = &.{},
    den: []const Poly = &.{},
    /// Sections = max(num.len, den.len); a missing side is the polynomial 1.
    ns: usize = 0,
    /// Highest degree over every section: the shape of the state arrays.
    deg: usize = 0,
    /// True when the coefficients read Model; decides `__sec`'s parameter name.
    uses_model: bool = false,
    /// §4.5.12 sampling period T. Null for a laplace filter.
    period: ?[]const u8 = null,
    /// The LRM refusal planning produced; the plan is unusable when set.
    err: ?[]const u8 = null,
    /// The unit refusal `f64Expr` raised while planning (E0515: a coefficient
    /// or period the host cannot evaluate), replayed by `planOf` at every use
    /// so the body that renders this filter still collapses to it.
    fatal: ?[]const u8 = null,

    /// Section `i` of one side; a side that ran out of sections is the
    /// polynomial 1, which is how a 3-zero / 1-pole filter still cascades.
    fn poly(g: FilterPlan, numerator: bool, i: usize) Poly {
        const list = if (numerator) g.num else g.den;
        return if (i < list.len) list[i] else &.{"1.0"};
    }
};

/// Decodes one `laplace_*`/`zi_*` call into its cascade, or a plan whose `err`
/// names the violated §4.5.11/§4.5.12 rule. Lowering flattened each vector
/// argument as `<count>, e0, e1, …`, so the argument list is self-describing.
pub fn filterPlan(g: *Gen, inst: Mir.Inst, args: []const Mir.Value) Error!FilterPlan {
    // `*_zp`/`*_zd` give the ZEROS as roots; `*_zp`/`*_np` give the POLES
    // as roots. The two letters after the underscore say which.
    const z: bool, const num_roots: bool, const den_roots: bool = switch (g.mir.instData(inst).call.callee) {
        .laplace_zd => .{ false, true, false },
        .laplace_zp => .{ false, true, true },
        .laplace_nd => .{ false, false, false },
        .laplace_np => .{ false, false, true },
        .zi_zd => .{ true, true, false },
        .zi_zp => .{ true, true, true },
        .zi_nd => .{ true, false, false },
        .zi_np => .{ true, false, true },
        else => unreachable, // else: `planAll` plans only a `.laplace`/`.zi` unit, whose call is one of these eight
    };

    const saved = g.uses_model;
    g.uses_model = false;
    defer g.uses_model = saved;

    const nv = readVec(g, args, 1) orelse
        return .{ .err = "LRM 4.5.11/4.5.12: the numerator argument of a filter must be a vector" };
    const dv = readVec(g, args, nv.next) orelse
        return .{ .err = "LRM 4.5.11/4.5.12: the denominator argument of a filter must be a vector" };

    var num: std.ArrayList(Poly) = .empty;
    var den: std.ArrayList(Poly) = .empty;
    if (try filterSide(g, &num, nv.elems, num_roots, z, false)) |m| return .{ .err = m };
    if (try filterSide(g, &den, dv.elems, den_roots, z, true)) |m| return .{ .err = m };

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
        if (dv.next >= args.len) return .{
            .err = "LRM 4.5.12: the sampling period T of a zi_* filter is mandatory",
        };
        if (g.an.foldConst(args[dv.next], true)) |c| {
            if (!(c.f > 0.0)) return .{
                .err = "LRM 4.5.12: the sampling period T of a zi_* filter shall be positive",
            };
        }
        p.period = try g.f64Expr(args[dv.next]);
        p.uses_model = g.uses_model;
        // §4.5.12 τ and t0. The emitted sampler steps abruptly at t = 0, which
        // is exactly the clause's τ = 0 form ("the output is abruptly
        // discontinuous") with t0 = 0. Any other value is a different
        // waveform, so it is refused rather than silently approximated.
        // Whether a τ = 0 filter may feed a branch directly is a property of
        // the statement: `lower.checkZeroTransitionZFilter` (E0518).
        for (args[@min(dv.next + 1, args.len)..]) |a| {
            const c = g.an.foldConst(a, true) orelse return .{
                .err = "LRM 4.5.12: the τ and t0 arguments of a zi_* filter must be constant expressions",
            };
            if (c.f < 0.0) return .{
                .err = "LRM 4.5.12: the transition time τ of a zi_* filter shall be nonnegative",
            };
            if (c.f != 0.0) return .{
                .err = "VerA implements only the τ = 0 / t0 = 0 form of a zi_* filter, whose output " ++
                    "is abruptly discontinuous at the sample (LRM 4.5.12)",
            };
        }
    }
    // §4.5.11 the optional ε argument only "deriv[es] an absolute
    // tolerance (if needed)"; VerA has no per-signal tolerance table, so
    // dropping it changes no value the device computes.
    return p;
}

/// Plans every §4.5.11/§4.5.12 operator once into `Gen.filters`, indexed by
/// unit, so the emitters that read a plan share one fold. Allocates in
/// `g.arena`; must run before any `planOf`.
pub fn planAll(g: *Gen) Error!void {
    g.filters = try g.arena.alloc(?FilterPlan, g.names.units.len);
    @memset(g.filters, null);
    const saved_tok = g.ctrl_tok;
    defer g.ctrl_tok = saved_tok;
    for (g.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.inst == .none) continue;
        const k = u.op;
        if (k != .laplace and k != .zi) continue;
        // `emitOperator` set this before planning, and E0515 falls back to it
        // for a coefficient with no token of its own.
        g.ctrl_tok = g.mir.instTok(u.inst);
        const saved = g.fatal;
        g.fatal = null;
        var p = try filterPlan(g, u.inst, g.mir.instData(u.inst).call.args);
        p.fatal = g.fatal;
        g.fatal = saved;
        g.filters[i] = p;
    }
}

/// Returns filter unit `unit`'s plan, replaying the refusal planning raised the
/// way `f64Expr` raises it (sticky `any_fatal`, first `fatal` wins).
/// Precondition: `planAll` ran and `unit` is a `laplace`/`zi` unit.
pub fn planOf(g: *Gen, unit: usize) FilterPlan {
    const p = g.filters[unit].?;
    if (p.fatal) |m| {
        g.any_fatal = true;
        if (g.fatal == null) g.fatal = m;
    }
    return p;
}

/// One flattened vector argument: its elements and the index of the argument
/// after it.
pub const Vec = struct { elems: []const Mir.Value, next: usize };

/// Reads the flattened vector argument at `i`: a literal count followed by that
/// many elements. Returns null when `args[i]` is not an `int_const` count, which
/// means the argument was never a vector.
pub fn readVec(g: *const Gen, args: []const Mir.Value, i: usize) ?Vec {
    if (i >= args.len) return null;
    const def = g.mir.valueDef(g.an.rv(args[i]));
    if (def != .int_const or def.int_const < 0) return null;
    const n: usize = @intCast(def.int_const);
    if (i + 1 + n > args.len) return null;
    return .{ .elems = args[i + 1 ..][0..n], .next = i + 1 + n };
}

/// Appends one side of a filter to `out` as sections. `roots` selects the
/// root-vector reading (real/imaginary pairs) over the coefficient reading.
/// Returns an LRM diagnostic, or null on success.
pub fn filterSide(
    g: *Gen,
    out: *std.ArrayList(Poly),
    elems: []const Mir.Value,
    roots: bool,
    z: bool,
    is_den: bool,
) Error!?[]const u8 {
    if (elems.len == 0) {
        // "The zeros argument may be represented as a null argument": no
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
            const c = g.an.foldConst(e, true);
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
        // The conjugate PAIRING is structural: it decides how many
        // sections exist and of what degree), so the imaginary part has to
        // be known here. The real part may stay a runtime parameter.
        const im = g.an.foldConst(elems[2 * k + 1], true) orelse
            return "LRM 4.5.11/4.5.12: the imaginary part of a filter root must be a constant expression " ++
                "(the conjugate pairing decides the section structure)";
        const re = try g.f64Expr(elems[2 * k]);
        const re_c = g.an.foldConst(elems[2 * k], true);
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
                const negative = try std.fmt.allocPrint(g.arena, "-({s})", .{re});
                try out.append(g.arena, try g.arena.dupe([]const u8, &.{ "1.0", negative }));
            } else {
                // §4.5.11 (1 − s/ρ). A card that sets ρ to 0 at run time
                // divides by zero, like a zero resistance; LRM 4.2.4 makes
                // only `%` by zero an error.
                try out.append(g.arena, try g.arena.dupe([]const u8, &.{
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
        // Multiplied out as a real quadratic, never through complex
        // arithmetic and never by expanding the whole product.
        //   §4.5.11  (1 − s/ρ)(1 − s/ρ*) = 1 − 2a/(a²+b²)·s + 1/(a²+b²)·s²
        //   §4.5.12  (1 − z⁻¹ρ)(1 − z⁻¹ρ*) = 1 − 2a·z⁻¹ + (a²+b²)·z⁻²
        // ponytail: b ≠ 0 here, so a²+b² > 0 and the §4.5.11 divisions are
        // safe for any real part. a == 0 is an undamped pole pair on the
        // imaginary axis; that is the transfer function the model asked for.
        const bb = try g.fmtF64(im.f * im.f);
        const mag = try std.fmt.allocPrint(g.arena, "(({0s}) * ({0s}) + {1s})", .{ re, bb });
        try out.append(g.arena, if (z) try g.arena.dupe([]const u8, &.{
            "1.0",
            try std.fmt.allocPrint(g.arena, "-2.0 * ({s})", .{re}),
            mag,
        }) else try g.arena.dupe([]const u8, &.{
            "1.0",
            try std.fmt.allocPrint(g.arena, "-2.0 * ({s}) / {s}", .{ re, mag }),
            try std.fmt.allocPrint(g.arena, "1.0 / {s}", .{mag}),
        }));
    }
    return null;
}

/// Returns the index of the unused root conjugate to (`re`, `im`): same real
/// part, negated imaginary part. Real parts compare as emitted text, so
/// `model.a` pairs with `model.a` without its value.
pub fn conjugateOf(g: *Gen, elems: []const Mir.Value, used: []const bool, re: []const u8, im: f64) ?usize {
    for (used, 0..) |u, j| {
        if (u) continue;
        const jm = g.an.foldConst(elems[2 * j + 1], true) orelse continue;
        if (jm.f != -im) continue;
        // `f64Const`, not `f64Expr`: a speculative render, so a root that does
        // not resolve is "not the conjugate", not a diagnostic.
        const jre = (g.f64Const(elems[2 * j], 0, false) catch continue) orelse continue;
        if (std.mem.eql(u8, jre, re)) return j;
    }
    return null;
}

/// Emits `pub fn <n>__sec(model)`, the cascade's coefficients read from Model
/// on every call so a card override needs no recompile. It is `pub` in the
/// device because a host doing `.ac`/`.noise` builds `H(jω)` from exactly these
/// numbers. Returns the output offset where the fn starts.
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

