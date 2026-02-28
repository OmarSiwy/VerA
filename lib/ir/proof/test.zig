//! Prover self-checks: source in, float-mode verdict and domain diagnostics out.
//!
//! Run on std.testing.allocator.
//!
//! LRM clauses this file's code cites: §3.2.1, §3.4.2, §4.2.4, §4.2.12, §4.3.1, §4.3.2, §5.6.1.3, §5.8.
//!
//! Cut verbatim from `proof.zig`. Functions take `self: *proof` and are called
//! directly, `proof_test.f(self, ...)`; `proof.zig` aliases only what other modules call.

const std = @import("std");
const proof = @import("../proof.zig");
const proof_prover = @import("prover.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Lower = @import("../lower.zig");
const diag = @import("diag");
const FloatMode = proof.FloatMode;
const Verdict = proof.Verdict;
const Options = proof.Options;
const unitCount = proof.unitCount;
const prove = proof.prove;
const proveOpts = proof.proveOpts;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub const Preprocessor = @import("frontend").Preprocessor;
pub const Lexer = @import("frontend").Lexer;
pub const Parser = @import("frontend").Parser;

pub const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    file: Ast.SourceFile,
    mir: Mir,
    low: Lower,
    bag: diag.Bag,

    fn run(gpa: std.mem.Allocator, src: []const u8, out: *Harness) !void {
        out.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .file = .empty,
            .mir = .{},
            .low = undefined,
            .bag = undefined,
        };
        const arena = out.arena_state.allocator();
        out.bag = diag.Bag.init(arena);
        const text = (try Preprocessor.process(arena, src, .{ .bag = &out.bag })).text;
        const toks = try Lexer.Lexer.tokenize(arena, text);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &out.bag);
        out.file = try p.parseSourceFile();
        // The annex E prelude came with `Preprocessor.process` (std_defs is on by
        // default), so its modules are the leading entries of `file.modules`.
        out.file.builtin_modules = Preprocessor.spice_module_count;
        out.low = Lower.init(arena, &out.mir, &out.file, text, toks.items(.start), &out.bag);
        try out.low.lowerFile();
    }

    /// Run the prover against this harness's own bag, so a test can assert on
    /// the CODES that came out rather than on prose.
    fn prove(self: *Harness, gpa: std.mem.Allocator, opts: Options) !Verdict {
        return proveOpts(gpa, &self.mir, &self.low, opts, &self.bag);
    }

    fn has(self: *const Harness, code: diag.Code) bool {
        return self.find(code) != null;
    }

    fn find(self: *const Harness, code: diag.Code) ?diag.Entry {
        for (self.bag.messages()) |mi| {
            const e = self.bag.get(mi);
            if (e.code == code) return e;
        }
        return null;
    }

    fn deinit(self: *Harness) void {
        self.low.deinit();
        self.arena_state.deinit();
    }
};

test "W0650: a .strict unit warns, names the culprit, and still compiles" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module diode(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  parameter real is = 1e-14 from (0:inf);
        \\  analog I(a, c) <+ is * (exp(V(a, c)) - 1.0);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    // LEGAL: an unbounded exp is spec-faithful (§4.3.2 "All x"), so the model
    // is ACCEPTED — the warning is about speed, not correctness.
    try std.testing.expect(v.ok());
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
    try std.testing.expect(!h.bag.failed());

    const e = h.find(.W0650) orelse return error.NoFinitenessWarning;
    try std.testing.expectEqual(diag.Severity.warning, e.severity);
    // The caret is on the contribution — the unit — not on some interior
    // instruction the user did not write.
    try std.testing.expect(!e.span.isNone());
    // The culprit is named. A probe is finite-but-unbounded, so `exp` of it is
    // what forfeits the proof.
    var lbuf: [diag.max_children]diag.Label = undefined;
    const labels = h.bag.labels(e, &lbuf);
    var mentions_probe = false;
    for (labels) |l| {
        if (std.mem.indexOf(u8, l.text, "probe") != null) mentions_probe = true;
    }
    try std.testing.expect(mentions_probe or std.mem.indexOf(u8, e.point, "probe") != null);
}

test "W0650: a fully-ranged model is provably finite and warns about nothing" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real rs = 1.0 from (0:inf);
        \\  analog I(p, n) <+ V(p, n) / rs;
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqual(FloatMode.optimized, v.unit_modes[0]);
    try std.testing.expect(!h.has(.W0650));
}

test "W0650: unknown_bound recovers the proof, and the warning goes away with it" {
    const src =
        \\module amp(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  analog I(a, c) <+ exp(V(a, c));
        \\endmodule
    ;
    var loose: Harness = undefined;
    try Harness.run(std.testing.allocator, src, &loose);
    defer loose.deinit();
    const a = try loose.prove(std.testing.allocator, .{});
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqual(FloatMode.strict, a.unit_modes[0]);
    try std.testing.expect(loose.has(.W0650));

    // The compliance limit is a property of the host's solver, not of the
    // language — declaring it is what makes the transcendental provable.
    var tight: Harness = undefined;
    try Harness.run(std.testing.allocator, src, &tight);
    defer tight.deinit();
    const b = try tight.prove(std.testing.allocator, .{ .unknown_bound = 100 });
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(FloatMode.optimized, b.unit_modes[0]);
    try std.testing.expect(!tight.has(.W0650));
}

test "W0650: --allow silences it without changing the verdict" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module amp(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  analog I(a, c) <+ exp(V(a, c));
        \\endmodule
    , &h);
    defer h.deinit();

    try h.bag.levels.set(h.arena_state.allocator(), .W0650, .allow);
    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(!h.has(.W0650));
    // Silencing the warning does NOT silence the consequence.
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "W0651: a range closed on infinity is called out separately" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real rs = 1.0 from [0:inf];
        \\  analog I(p, n) <+ V(p, n) / rs;
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    const e = h.find(.W0651) orelse return error.NoRangeWarning;
    try std.testing.expect(std.mem.indexOf(u8, e.message, "rs") != null);
    // It points at the DECLARATION, which is where the fix goes.
    try std.testing.expect(!e.span.isNone());
    // ...and the closed bound really did cost the unit its proof.
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
    try std.testing.expect(h.has(.W0650));
}

test "W0651: a §3.4.2 string value set is not a bound, so it is not an open one" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter string kind = "NMOS" from '{"NMOS", "PMOS"};
        \\  analog I(p, n) <+ (kind == "NMOS") * V(p, n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    // `paramInterval` answers `.top` for every string parameter — there is no
    // number in the range to close — and the fixture that pinned this
    // (ch03_data_types/17_string_parameter_range.va) collected two W0651 it
    // could do nothing about, since a green fixture does not fail on warnings.
    try std.testing.expect(!h.has(.W0651));
}

test "§3.4.2: an `exclude` proves nonzero only where its bracket is square" {
    // The three exclusions that differ ONLY in whether 0 is inside them. The
    // first still admits 0, so the divide is not provably safe and the unit has
    // to stay `.strict`; the other two really do remove 0 and earn `.optimized`.
    // Reading `(0:5)` as if it excluded its endpoints' *values* is unsound in
    // the dangerous direction: it hands fast-math a divisor the range permits
    // to be zero.
    const cases = [_]struct { range: []const u8, mode: FloatMode }{
        .{ .range = "exclude (0:5)", .mode = .strict },
        .{ .range = "exclude [0:5]", .mode = .optimized },
        .{ .range = "exclude 0", .mode = .optimized },
        // The open end that is NOT at zero must not change the verdict.
        .{ .range = "exclude (-5:0]", .mode = .optimized },
        .{ .range = "exclude [-5:0)", .mode = .strict },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  parameter real x = 1.0 from [-10:10] {s};
            \\  analog I(p, n) <+ V(p, n) / x;
            \\endmodule
        , .{c.range});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const v = try h.prove(std.testing.allocator, .{});
        defer v.deinit(std.testing.allocator);

        std.testing.expectEqual(c.mode, v.unit_modes[0]) catch |e| {
            std.debug.print("range: {s}\n", .{c.range});
            return e;
        };
    }
}

test "§3.4.2: a PUNCTURED sign-spanning divisor licenses no corner interval" {
    // `b` in [-10,10]\{0}: 1.0/b really ranges over (-inf,-0.1] ∪ [0.1,+inf).
    // The corners 1/±10 used to fabricate the COMPLEMENT [-0.1,0.1], from
    // which ln(0.3 - 1/b) was "proven" in-domain and the unit went
    // `.optimized` — whose nnan assertion ln(0.3 - 1/b) then violated at any
    // card with 0.3 - 1/b < 0 (silent Release UB). And the mirrored shape
    // ln(1/b - 0.5) was "proven" OUT of domain, an E0602 reject fabricated
    // against legal inputs (b = 0.1 gives ln(9.5)). Both must now be the
    // honest third verdict: accepted, `.strict`.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module p(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real b = 1.0 from [-10:10] exclude 0;
        \\  analog begin
        \\    I(p,n) <+ ln(0.3 - 1.0/b) * V(p,n);
        \\    I(p,n) <+ ln(1.0/b - 0.5) * V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok()); // neither shape is provably violating
    try std.testing.expect(!h.has(.E0602));
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "§4.3.1: pow with a sign-spanning base and an even exponent reaches 0" {
    // x in [-2,2]: pow(x,2) is [0,4] — the interior minimum at x = 0 is the
    // point the four corners (all = 4) miss. From the fabricated [4,4] BOTH
    // wrong directions were derived: sqrt(pow(x,2)-1) went `.optimized` (NaN
    // at |x| < 1 under fast-math = silent UB) and ln(2-pow(x,2)) was REJECTED
    // E0602 on a fabricated "known range [-2:-2]" (legal at |x| > sqrt(2)).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module q(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real x = 1.0 from [-2:2];
        \\  analog begin
        \\    I(p,n) <+ sqrt(pow(x,2.0) - 1.0) * V(p,n);
        \\    I(p,n) <+ ln(2.0 - pow(x,2.0)) * V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok());
    try std.testing.expect(!h.has(.E0602));
    try std.testing.expect(!h.has(.E0604));
    // Both `<+ I(p,n)` statements fold into ONE unit (§5.6.1.3, see UNIT
    // ORDERING) — and its joined slice is NaN-capable, so `.strict`.
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "§4.3.1: pow on a proven-positive base keeps its corner proof" {
    // The sound side of powIv must not have widened: base in [1,3], exponent
    // 2 → [1,9], bounded, so ln(pow) is proven in-domain and the unit stays
    // `.optimized`.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module w(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real g = 2.0 from [1:3];
        \\  analog I(p,n) <+ ln(pow(g, 2.0)) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.ok());
    try std.testing.expectEqual(FloatMode.optimized, v.unit_modes[0]);
}

test "audit: a domain-straddling monotone argument yields no narrow interval" {
    // sqrt over [-4,9] is [0,3] on the legal branch; the old NaN→+inf
    // endpoint fold claimed [3,+inf], from which asin(sqrt(s)-…) faced a
    // fabricated E0605 "provably > 1". Straddle must abstract to ⊤: accepted,
    // `.strict`, no rejection (legal cards exist: s = 0.25 → asin(0.5)).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module a(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real s = 0.25 from [-4:9];
        \\  analog I(p,n) <+ asin(sqrt(s)) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.ok());
    try std.testing.expect(!h.has(.E0605));
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "§3.2.1: an integer parameter is 32-bit, hence finite without a range" {
    // `q` unranged used to seed ⊤/non-finite and drag the unit `.strict`,
    // with a W0650 blaming an unrelated probe. A model-card integer cannot
    // hold an infinity — its type is the range.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module i(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer q = 3;
        \\  analog I(p,n) <+ q * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.ok());
    try std.testing.expectEqual(FloatMode.optimized, v.unit_modes[0]);
    try std.testing.expect(!h.has(.W0650));
}

test "§3.2.1: even a `from [0:inf]` integer range is clamped finite by its type" {
    // The written range admits infinity, but no 32-bit integer holds one:
    // the type meet keeps the parameter finite, so neither W0651 (about the
    // PROOF cost of the closed bound) nor W0650 has anything true to say.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module j(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer m = 1 from [0:inf];
        \\  analog I(p,n) <+ m * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.ok());
    try std.testing.expectEqual(FloatMode.optimized, v.unit_modes[0]);
    try std.testing.expect(!h.has(.W0650));
    try std.testing.expect(!h.has(.W0651));
}

test "E0609: pow with a provably-negative base and provably-fractional exponent" {
    // §4.3.1 Table 4-14 "if x < 0, all integer y": every card in
    // [-10:-1] × {0.5} evaluates pow to NaN, so §4.3.2's "shall report an
    // error" is discharged statically — the same standard as E0602.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module e(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real m = -2.0 from [-10:-1];
        \\  analog I(p,n) <+ pow(m, 0.5) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(!v.ok());
    try std.testing.expect(h.has(.E0609));
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "E0609: pow(0, negative) is provably outside Table 4-14's zero-base row" {
    // "if x = 0, all y > 0" — an integer exponent does not rescue a zero
    // base; pow(0,-2) is +inf on every execution.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module z(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ pow(0.0, -2.0) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(!v.ok());
    try std.testing.expect(h.has(.E0609));
}

test "E0609: a straddling base or a possibly-integer exponent stays accepted" {
    // Three-way split: `u` unranged MIGHT be negative and `w` in [2.5:3.0]
    // MIGHT be the integer 3.0 — neither is a provable violation, so both
    // are accepted and forfeit finiteness (`.strict`), never rejected.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module s(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real u = 1.0;
        \\  parameter real m = -2.0 from [-10:-1];
        \\  parameter real w = 3.0 from [2.5:3.0];
        \\  analog begin
        \\    I(p,n) <+ pow(u, 0.5) * V(p,n);
        \\    I(p,n) <+ pow(m, w) * V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.ok());
    try std.testing.expect(!h.has(.E0609));
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "class-6 errors carry a real source span (Mir.InstRow.tok)" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer d = 0;
        \\  analog I(p, n) <+ V(p, n) * (10 % d);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(!v.ok());

    const e = h.find(.E0601) orelse return error.NoDivisorError;
    // The whole point of the provenance column: this used to be 0:0.
    try std.testing.expect(!e.span.isNone());
    // And the span must land on the source the user wrote, not the prelude.
    const src_text = h.bag.fileText(h.bag.locate(e.span, e.file).file);
    try std.testing.expect(std.mem.indexOf(u8, src_text, "10 % d") != null);
}

test "proof: unbounded voltage exp is .strict, never an error (LRM 4.3.2 'All x')" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module diode(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  parameter real is = 1e-14 from (0:inf);
        \\  parameter real vt = 0.026 from (0:inf);
        \\  analog I(a,c) <+ is * (exp(V(a,c)/vt) - 1.0);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok()); // exp is NEVER rejected
    try std.testing.expectEqual(@as(usize, 1), v.unit_modes.len);
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "proof: a §3.4.2 range discharges the ln domain and proves the unit finite" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module r(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real rs = 1k from (0:inf);
        \\  analog I(p,n) <+ ln(rs) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok());
    try std.testing.expectEqual(FloatMode.optimized, v.unit_modes[0]);
}

test "proof: an UNPROVABLE ln domain is accepted and forced .strict (LRM 4.3.2)" {
    // §4.3.2 obliges reporting a value that IS out of range, not rejecting a
    // program whose values MIGHT be. `k` is unranged, so ln(k) straddles the
    // domain boundary: accept it, and forfeit `.optimized`.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real k = 1.0;
        \\  analog I(p,n) <+ ln(k) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok()); // accepted — the LRM permits it
    // THE SAFETY PROPERTY: a NaN-capable unit must never reach `.optimized`,
    // whose `nnan` assertion it would violate (silent, Release-only UB).
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "proof: a PROVABLY-violated ln domain is still an error (LRM 4.3.2 'shall report')" {
    // Entirely negative range: statically decidable, so the §4.3.2 error
    // obligation is discharged at compile time.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad2(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real k = -2.0 from [-10:-1];
        \\  analog I(p,n) <+ ln(k) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(!v.ok());
    try std.testing.expect(h.has(.E0602));
    const e = h.find(.E0602).?;
    try std.testing.expect(std.mem.indexOf(u8, e.message, "ln()") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.message, "parameter `k`") != null);
    // The location is the whole point of Mir.InstRow.tok: class-6 diagnostics
    // used to report at 0:0.
    try std.testing.expect(!e.span.isNone());
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "proof: a dominating §5.8 guard discharges the domain of a node probe" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module g(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    if (V(p,n) > 0.0)
        \\      I(p,n) <+ ln(V(p,n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok());
}

test "proof: `/` by a possibly-zero divisor is ACCEPTED and forced .strict (LRM 4.2.4)" {
    // §4.2.4's only zero rule is "It shall be an error to pass zero (0) as the
    // second argument to the MODULUS operator" — division by zero is not an
    // error, it is an exact IEEE +-inf. This is the plain resistor `V/r`, the
    // most common statement in all of Verilog-A; rejecting it would make
    // VerA stricter than the LRM.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real a = 1.0;
        \\  parameter real b = 1.0 exclude 0;
        \\  analog I(p,n) <+ V(p,n)/a + V(p,n)/b;
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok()); // `a` unranged is legal
    // ...but it can produce inf, so the unit forfeits fast-math. Without this
    // the `ninf` assertion of `.optimized` is violated at run time only.
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "proof: integer `%` by a possibly-zero divisor remains an error (LRM 4.2.4)" {
    // No IEEE escape for integers: Zig's @rem by zero is illegal behavior,
    // and the device has no guarded form of it.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer k = 1;
        \\  analog I(p,n) <+ (10 % k) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(!v.ok());
    try std.testing.expect(h.has(.E0601));
    try std.testing.expect(std.mem.indexOf(u8, h.find(.E0601).?.message, "divisor") != null);
}

test "proof: the §4.2.12 select guard covers `x > 0 ? ln(x) : 0`" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module s(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ (V(p,n) > 0.0) ? ln(V(p,n)) : 0.0;
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok());
}

test "proof: the unit count is the contribution count (the naming.zig contract)" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module two(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real c = 1p;
        \\  analog begin
        \\    I(p,n) <+ V(p,n);
        \\    I(p,n) <+ ddt(c * V(p,n));
        \\    V(p,n) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expectEqual(unitCount(&h.low), v.unit_modes.len);
    try std.testing.expectEqual(@as(usize, 2), v.unit_modes.len);
}

test "proof: Options.unknown_bound is the calibration knob for a real solver" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module e(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  analog I(a,c) <+ exp(V(a,c));
        \\endmodule
    , &h);
    defer h.deinit();

    const loose = try h.prove(std.testing.allocator, .{});
    defer loose.deinit(std.testing.allocator);
    try std.testing.expectEqual(FloatMode.strict, loose.unit_modes[0]);

    // A host that clamps its unknowns to a compliance limit gets the fast path.
    const tight = try h.prove(std.testing.allocator, .{ .unknown_bound = 100 });
    defer tight.deinit(std.testing.allocator);
    try std.testing.expect(tight.ok());
    try std.testing.expectEqual(FloatMode.optimized, tight.unit_modes[0]);
}

test "proof: random distribution names do not prove finite results" {
    for ([_][]const u8{ "$rng$uniform", "$rng$normal", "$rng$exponential", "$rng$poisson", "$rng$chi_square", "$rng$t", "$rng$erlang" }) |name|
        try std.testing.expect(!proof_prover.callAbstract(name).finite);
}

test "proof: `1.0/$vt(V)` and `1.0/limexp(V)` are .strict with W0650 (§9.15, §4.5.13)" {
    // $vt(0) = 0 (kT/q at T = 0), and limexp(x) is exp(x) below its knee,
    // which is 0.0 in f64 below about -745: both divisors can be zero, so
    // `.optimized` (ninf) over either division is UB. Both used to prove.
    for ([_][]const u8{ "$vt", "limexp" }) |f| {
        var h: Harness = undefined;
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  analog I(p,n) <+ 1.0 / {s}(V(p,n));
            \\endmodule
        , .{f});
        defer std.testing.allocator.free(src);
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const v = try h.prove(std.testing.allocator, .{});
        defer v.deinit(std.testing.allocator);
        try std.testing.expect(v.ok());
        try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
        try std.testing.expect(h.has(.W0650));
    }
}

test "proof: $vt(T) and limexp(x) keep their argument's evidence" {
    // A positive, bounded argument still proves: the fix narrows the claim
    // to what the argument supports, it does not drop to top.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real t = 300 from [250:400];
        \\  parameter real x = 1 from [-10:10];
        \\  analog I(p,n) <+ V(p,n) / $vt(t) + V(p,n) / limexp(x);
        \\endmodule
    , &h);
    defer h.deinit();
    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.ok());
    try std.testing.expectEqual(FloatMode.optimized, v.unit_modes[0]);
}

test "proof: an unprovable integer `/` or real `%` divisor is accepted as .strict (LRM 4.2.4)" {
    // §4.2.4's one zero rule makes `%` by zero an error when the divisor IS
    // zero; `/` has none. The file's three-way rule: unprovable -> accept.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer k = 2;
        \\  parameter real r = 3.0;
        \\  analog I(p,n) <+ (10 / k) * V(p,n) + V(p,n) % r;
        \\endmodule
    , &h);
    defer h.deinit();
    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.ok());
    try std.testing.expect(!h.has(.E0601));
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
    // Accepted, but not silently: the device yields 0 for `10 / 0`.
    const w = h.find(.W0653) orelse return error.NoIntDivisorWarning;
    try std.testing.expectEqual(diag.Severity.warning, w.severity);
    try std.testing.expect(!w.span.isNone());
}

test "W0653: only for an unproven INTEGER `/`, and a range or a guard silences it" {
    // The same division with the divisor ranged, and guarded, proves; the
    // real `%` and real `/` over an unranged parameter never raise W0653.
    for ([_][]const u8{
        "parameter integer k = 2 exclude 0; analog I(p,n) <+ (10 / k) * V(p,n);",
        "parameter integer k = 2 from [1:inf); analog I(p,n) <+ (10 / k) * V(p,n);",
        "parameter integer k = 2; analog if (k != 0) I(p,n) <+ (10 / k) * V(p,n);",
        "parameter real r = 3.0; analog I(p,n) <+ V(p,n) % r + V(p,n) / r;",
    }) |body| {
        var h: Harness = undefined;
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  {s}
            \\endmodule
        , .{body});
        defer std.testing.allocator.free(src);
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const v = try h.prove(std.testing.allocator, .{});
        defer v.deinit(std.testing.allocator);
        try std.testing.expect(v.ok());
        try std.testing.expect(!h.has(.W0653));
    }
}

test "W0653: a parameter derivation's integer `/` is announced too" {
    // codegen/call.zig renders `-7 / k` in the derived default with the same
    // zero-yields-0 guard; this is the compile-time half of that.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer k = 2;
        \\  parameter integer q = -7 / k;
        \\  analog I(p,n) <+ q * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();
    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.ok());
    try std.testing.expect(h.has(.W0653));
}

test "W0653: --allow silences it and changes nothing else" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer k = 2;
        \\  analog I(p,n) <+ (10 / k) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();
    try h.bag.levels.set(h.arena_state.allocator(), .W0653, .allow);
    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(v.ok());
    try std.testing.expect(!h.has(.W0653));
}

test "proof: a provably-zero divisor is still E0601, for `/` and real `%` alike" {
    for ([_][]const u8{ "(10 / k) * V(p,n)", "V(p,n) % r" }) |e| {
        var h: Harness = undefined;
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  integer k;
            \\  real r;
            \\  analog begin
            \\    k = 0;
            \\    r = 0.0;
            \\    I(p,n) <+ {s};
            \\  end
            \\endmodule
        , .{e});
        defer std.testing.allocator.free(src);
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const v = try h.prove(std.testing.allocator, .{});
        defer v.deinit(std.testing.allocator);
        try std.testing.expect(!v.ok());
        try std.testing.expect(h.has(.E0601));
    }
}
