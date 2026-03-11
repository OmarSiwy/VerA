//! Codegen self-checks: MIR in, device.zig text out, asserted by shape.
//!
//! Each test lowers a small source and checks the emitted text; the fixture suite checks behaviour.
//!
//! LRM clauses this file's code cites: §1, §3.4, §4.5, §4.5.8, §4.5.11, §4.5.15, §4.6.4, §4.6.4.3, §4.6.4.6, §5.4.3, §9.4, §9.5.1.
//!
//! Cut verbatim from `codegen.zig`.

const std = @import("std");
const codegen = @import("../codegen.zig");
const gen_kernel_text = @import("kernel_text.zig");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lower;
const proof = @import("ir").proof;
const diag = @import("diag");
const assert = codegen.assert;
const Output = codegen.Output;
const generate = codegen.generate;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub const Ast = @import("frontend").Ast;
pub const Preprocessor = @import("frontend").Preprocessor;
pub const Lexer = @import("frontend").Lexer;
pub const Parser = @import("frontend").Parser;
pub const ifconv = @import("ir").ifconv;

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
        // One diagnostic bag threaded through every stage (diag.zig).
        out.bag = diag.Bag.init(arena);
        const text = (try Preprocessor.process(arena, src, .{ .bag = &out.bag })).text;
        const toks = try Lexer.Lexer.tokenize(arena, text);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &out.bag);
        out.file = try p.parseSourceFile();
        // The annex E prelude came with `Preprocessor.process` (std_defs is on by
        // default), so its modules are the leading entries of `file.modules`.
        out.file.builtin_modules = Preprocessor.spice_module_count;
        out.low = Lower.init(arena, &out.mir, &out.file, text, toks.items(.start), &out.bag);
        _ = try out.low.lowerFile();
    }

    fn gen(self: *Harness, gpa: std.mem.Allocator) ![]const u8 {
        return (try self.genOut(gpa)).text;
    }

    /// Same, with §9.4 display tasks emitted — the printing artifact.
    fn genDisplay(self: *Harness, gpa: std.mem.Allocator) ![]const u8 {
        const v = try proof.prove(gpa, &self.mir, &self.low, &self.bag);
        defer v.deinit(gpa);
        var fatal = false;
        const a = self.arena_state.allocator();
        return (try generate(a, a, &self.mir, &self.low, v, &fatal, .{ .display = .emit })).text;
    }

    fn genOut(self: *Harness, gpa: std.mem.Allocator) !Output {
        const v = try proof.prove(gpa, &self.mir, &self.low, &self.bag);
        defer v.deinit(gpa);
        var fatal = false;
        // ponytail: the harness hands `generate` its arena as the output gpa, so
        // `deinit` reclaims the result with everything else and no test needs a
        // matching free. Ceiling: these fixtures are kilobytes; the arena regrow
        // cost `generate`'s gpa parameter exists to avoid only bites at MB scale.
        const a = self.arena_state.allocator();
        // The harness bag is arena-lived and never detached, so unlike the
        // driver's it is still the right one to hand codegen.
        return generate(a, a, &self.mir, &self.low, v, &fatal, .{ .diags = &self.bag });
    }

    fn deinit(self: *Harness) void {
        self.low.deinit();
        self.arena_state.deinit();
    }
};

pub const resistor_va =
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
;

test "codegen: --jac-f32 adds a permission decl and changes not one other byte" {
    // The whole claim of the mixed-precision work, pinned. `eval` is generic
    // over S and reaches it only through primitives that take and return f64
    // (`con`, `scale`, `addC`, `val`), so the WIDTH of the derivative a host
    // carries inside S is the host's choice and no arithmetic here depends on
    // it. If this flag ever starts moving other bytes, that genericity has been
    // broken somewhere and this test is where it shows up.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();

    const v = try proof.prove(std.testing.allocator, &h.mir, &h.low, &h.bag);
    defer v.deinit(std.testing.allocator);
    var fatal = false;
    const a = h.arena_state.allocator();
    const off = (try generate(a, a, &h.mir, &h.low, v, &fatal, .{})).text;
    const on = (try generate(a, a, &h.mir, &h.low, v, &fatal, .{ .jac_f32 = true })).text;

    try std.testing.expect(std.mem.indexOf(u8, off, "jac_f32") == null);
    const decl = "pub const jac_f32 = true;\n\n";
    const at = std.mem.indexOf(u8, on, decl) orelse return error.NoPermissionDecl;
    // Excise the block the flag added — comment header included — and what is
    // left has to be the default output byte for byte.
    const hdr = std.mem.lastIndexOf(u8, on[0..at], "/// This device permits").?;
    const stripped = try std.mem.concat(a, u8, &.{ on[0..hdr], on[at + decl.len ..] });
    try std.testing.expectEqualStrings(off, stripped);

    // `--jac-f32-host` is the stronger request and emits the permission too:
    // a host width without the permission is the one combination
    // `tools/contract.zig` rejects, so codegen must never produce it.
    const host = (try generate(a, a, &h.mir, &h.low, v, &fatal, .{ .jac_f32_host = true })).text;
    try std.testing.expect(std.mem.indexOf(u8, host, decl) != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "pub const jac_f32_host = true;") != null);
}

test "codegen: a core that reads analysis()/sim-state carries core_reads_simstate" {
    // A device-resident host republishes t/dt/kind on the HOST Instance only,
    // so a core reading them there evals stale — the decl is how it knows to
    // keep such a device off the device. The resistor must NOT carry it (its
    // updateState epilogue latch, when present, is not a core read).
    {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, resistor_va, &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expect(std.mem.indexOf(u8, src, "core_reads_simstate") == null);
    }
    {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator,
            \\module ak(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  analog I(p, n) <+ V(p, n) * (analysis("tran") ? 2.0 : 1.0);
            \\endmodule
        , &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const core_reads_simstate = true;") != null);
    }
}

test "codegen: core_reads_simstate counts `analog initial` and the Newton iteration" {
    // Both are Instance fields the HOST rewrites between evaluations
    // (`is_analog_initial` per sub-task, `newton_iteration` through
    // beginSolve/advanceIteration), which the old text scan did not list.
    const srcs = [_][]const u8{
        \\module ai(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  real g;
        \\  analog initial g = 2.0;
        \\  analog I(p, n) <+ g * V(p, n);
        \\endmodule
        ,
        \\module it(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ V(p, n) * $simparam("iteration", 1.0);
        \\endmodule
    };
    for (srcs) |text| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, text, &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const core_reads_simstate = true;") != null);
    }
}

test "codegen: State.t_prev exists only for a reader, and state_class is declared" {
    // A constant-td `absdelay` pushes its ring on `inst.abstime` and never
    // reads `t_prev`; `idt` integrates over `dt = abstime - t_prev`. A
    // nonlinear `ddt` lowers to the §5.6.1.2 path latches alone.
    const cases = [_]struct { src: []const u8, t_prev: bool, class: []const u8 }{
        .{ .src =
        \\module d(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ absdelay(V(p, n), 1e-9);
        \\endmodule
        , .t_prev = false, .class = ".history" },
        .{ .src =
        \\module l(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ idt(V(p, n), 0.0);
        \\endmodule
        , .t_prev = true, .class = ".history" },
        .{ .src =
        \\module c(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ V(p, n) * ddt(V(p, n));
        \\endmodule
        , .t_prev = false, .class = ".path_latch" },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, c.src, &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expectEqual(c.t_prev, std.mem.indexOf(u8, src, "t_prev: f64") != null);
        try std.testing.expectEqual(c.t_prev, std.mem.indexOf(u8, src, "state.t_prev = inst.abstime;") != null);
        const decl = try std.fmt.allocPrint(h.arena_state.allocator(), "pub const state_class: contract.StateClass = {s};", .{c.class});
        try std.testing.expect(std.mem.indexOf(u8, src, decl) != null);
    }
}

test "codegen: acceptQ is q and updateState off ONE core evaluation" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module c(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog I(p, n) <+ V(p, n) * ddt(V(p, n));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const at = std.mem.indexOf(u8, src, "pub fn acceptQ(comptime S: type,") orelse return error.NoAcceptQ;
    const body = src[at..][0 .. std.mem.indexOf(u8, src[at..], "\n}\n") orelse return error.NoEnd];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "@call(.always_inline, core,"));
    try std.testing.expect(std.mem.indexOf(u8, body, "inst.wq__0 = m.f") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "return qq;") != null);
}

test "codegen: one stably-named declaration for the model, thin dispatcher" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, src, "pub const U = enum(u8) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const num_ports: usize = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "r: f64 = 1000.0,") != null);
    // The declaration name is naming.zig's structural key, and it is NOT a MIR
    // index. Since the merge there is ONE of them per model: the per-contribution
    // keys still exist (naming.zig, proof.zig, the `Instance` state fields) but
    // no longer name a declaration.
    try std.testing.expect(std.mem.indexOf(u8, src, "fn res__common__core(comptime S: type,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const m = @call(.always_inline, core, .{ S, x, model, inst });") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "contract.validate(Self)") != null);
    // no reactive part ⇒ no q()
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(") == null);
    // NEVER a global MIR value index in a name
    try std.testing.expect(std.mem.indexOf(u8, src, "v12") == null);
}

pub const shared_va =
    \\module sh(p, n);
    \\  inout p, n;
    \\  electrical p, n, m;
    \\  parameter real r = 1000.0 from (0:inf);
    \\  real g;
    \\  analog begin
    \\    g = exp(V(p, n) / r) * V(p, m);
    \\    I(p, m) <+ g * 2.0;
    \\    I(m, n) <+ g * 3.0;
    \\  end
    \\endmodule
;

test "codegen: two contributions sharing a subexpression evaluate it ONCE" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, shared_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // One declaration, named structurally — no MIR index anywhere in it.
    try std.testing.expect(std.mem.indexOf(u8, src, "fn sh__common__core(comptime S: type,") != null);
    // ONE call for the whole residual, not one per contribution. This is the
    // runtime half of the merge: LLVM does not CSE repeated calls to a body of
    // this size (measured — see `planCommon`), so the count here IS the number
    // of times the model runs per Newton iteration.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, src, "const m = @call(.always_inline, core, .{ S, x, model, inst });"),
    );
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f0;") != null);
    // The costly part — `exp` — is emitted once. That is the whole scaling
    // defect. Counted past the file-scope helpers, several of which spell
    // `.exp()` themselves.
    const decls = src[std.mem.indexOf(u8, src, "// ---- the model, in one declaration ----").?..];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, decls, ".exp()"));

    // §4.3: `exp` of an unbounded probe is not provably finite, so both units
    // are `.strict` and the declaration they share must be too — compiling it
    // `.optimized` would assert `ninf` on behalf of a unit that never had it.
    const at = std.mem.indexOf(u8, src, "fn sh__common__core").?;
    try std.testing.expect(std.mem.indexOf(u8, src[at..], "@setFloatMode(.strict);") != null);
}

test "codegen: one declaration even for a single contribution" {
    // No threshold. A model with one contribution gets the same shape as a model
    // with fifty, because the shape is not an optimisation any more — `eval`
    // reads its targets out of one struct and there is nothing to opt out of.
    // The extra call is free: a one-contribution core is small enough for LLVM
    // to inline, which is exactly what it will not do for a 60 000-line one.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "fn res__common__core(") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "= @call(.always_inline, core, .{ S, x, model, inst });"));
}

test "codegen: the unit ranges tile the emission and each names its own decl" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1000.0 from (0:inf);
        \\  parameter real c = 1e-12;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / r;
        \\    I(p, n) <+ ddt(c * V(p, n));
        \\    V(p, n) <+ laplace_nd(V(p, n), {1.0}, {1.0, 1.0});
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const o = try h.genOut(std.testing.allocator);

    // The merged core and the §4.5.11 `__sec` coefficient reader derived from
    // the laplace operator — every shape `emitUnits` can still produce for a
    // model with no §9.4 display unit.
    try std.testing.expectEqual(@as(usize, 2), o.names.len);
    for (o.names, o.unit_lo, o.unit_hi, 0..) |name, lo, hi, i| {
        // Tiling — `Output`'s invariant, and what lets the writer rebuild
        // device.zig as prologue ++ imports ++ tail with nothing dropped.
        if (i != 0) try std.testing.expectEqual(o.unit_hi[i - 1], lo);
        const decl = try std.fmt.allocPrint(std.testing.allocator, "fn {s}(", .{name});
        defer std.testing.allocator.free(decl);
        // The range holds the declaration it is named for, and `unit_fn` points
        // at that declaration's keyword — where the writer splices `pub `,
        // without which `@import("u/<key>.zig").<key>` does not resolve.
        try std.testing.expect(std.mem.indexOf(u8, o.text[lo..hi], decl) != null);
        try std.testing.expect(lo <= o.unit_fn[i] and o.unit_fn[i] < hi);
        const at = o.text[o.unit_fn[i]..];
        try std.testing.expect(std.mem.startsWith(u8, at, decl) or
            std.mem.startsWith(u8, at, "pub fn "));
    }
    // The tail after the last unit is the dispatcher, not more units.
    try std.testing.expect(std.mem.indexOf(u8, o.text[o.unit_hi[o.unit_hi.len - 1]..], "pub fn eval(") != null);
    // The prologue before the first unit carries the types a unit file aliases.
    try std.testing.expect(std.mem.indexOf(u8, o.text[0..o.unit_lo[0]], "pub const Model = struct {") != null);
}

test "codegen: the unit prologue aliases the helper API and not its internals" {
    // "Every emitted helper is aliased" is now true by construction — `aliasesOf`
    // reads the same text `publish` does — so the test that policed it is gone.
    // What is NOT tautological is the `z` + uppercase clause: it is the only
    // thing standing between the prologue and a kernel file's private names, and
    // relaxing it changes the emitted bytes of every unit file. Pin both sides.
    const has = std.mem.indexOf;
    try std.testing.expect(has(u8, gen_kernel_text.prelude_str_txt, "const zScan = h.zScan;\n") != null);
    try std.testing.expect(has(u8, gen_kernel_text.prelude_file_txt, "const zFOpen = h.zFOpen;\n") != null);
    // str_kernels.zig's `pub const ZScan` and `const zstd`, file_kernels.zig's
    // `fn zfIo` and `const zf_max`: public in h.zig, never named by an emitted
    // body, so aliasing them would be legal, unreferenced, and pure noise.
    try std.testing.expect(has(u8, gen_kernel_text.prelude_str_txt, "ZScan") == null);
    try std.testing.expect(has(u8, gen_kernel_text.prelude_str_txt, "zstd") == null);
    try std.testing.expect(has(u8, gen_kernel_text.prelude_file_txt, "zfIo") == null);
    try std.testing.expect(has(u8, gen_kernel_text.prelude_file_txt, "zf_max") == null);
}

test "codegen: identical MIR yields a byte-identical file (determinism)" {
    var h1: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h1);
    defer h1.deinit();
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h2);
    defer h2.deinit();
    try std.testing.expectEqualStrings(try h1.gen(std.testing.allocator), try h2.gen(std.testing.allocator));
}

test "codegen: adding a contribution appends to the core, it does not renumber" {
    var h1: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h1);
    defer h1.deinit();
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n, m;
        \\  parameter real r = 1000.0 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / r;
        \\    I(m, n) <+ V(m, n) / r;
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();

    const a = try h1.gen(std.testing.allocator);
    const b2 = try h2.gen(std.testing.allocator);
    // The first contribution is still `f0` and `eval` still stamps it from
    // `m.f0`. That is what `planCommon`'s job-order numbering buys: the field
    // index of an existing target is insert-tolerant in the same sense
    // naming.zig makes a declaration name insert-tolerant, so `zig`'s
    // `TrackedInst` for the dispatcher does not churn on an unrelated edit.
    try std.testing.expect(std.mem.indexOf(u8, a, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, b2, "const c = m.f0;") != null);
    const ka = a[std.mem.indexOf(u8, a, "pub fn eval(").?..];
    const kb = b2[std.mem.indexOf(u8, b2, "pub fn eval(").?..];
    const na = std.mem.indexOf(u8, ka, "    }\n").? + 6;
    const nb = std.mem.indexOf(u8, kb, "    }\n").? + 6;
    try std.testing.expectEqualStrings(ka[0..na], kb[0..nb]);
}

test "codegen: §5.6.1.2 reactive split emits q(), §4.2.12 select stays lazy" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module cap(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real c = 1e-12 from (0:inf);
        \\  parameter real vmin = 1.0 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ c * ddt(V(p, n));
        \\    I(p, n) <+ V(p, n) > vmin ? ln(V(p, n)) : 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(comptime S: type") != null);
    // The reactive half is a SECOND field of the same core, reached by `q` —
    // the split survives the merge as two targets, not two declarations.
    try std.testing.expect(std.mem.indexOf(u8, src, "fn cap__common__core(") != null);
    // §4.2.3/§4.2.12 laziness (proof.zig's CODEGEN OBLIGATION): the `ln` must
    // sit INSIDE the arm, never in a preceding `const`. Matching a bare `if (`
    // is deliberate — `?:` lowers to a CFG diamond (`lowerTernary`) and a
    // `select` renders as the expression `(if (c) a else b)`, and BOTH satisfy
    // the obligation. What must never happen is `.log()` ahead of the guard.
    const unit = src[std.mem.indexOf(u8, src, "fn cap__common__core(").?..];
    const body = unit[0..std.mem.indexOf(u8, unit, "\n}\n").?];
    const guard = std.mem.indexOf(u8, body, "if (").?;
    const lg = std.mem.indexOf(u8, body, ".log()").?;
    try std.testing.expect(lg > guard);
}

test "codegen: evalQ fuses both residuals onto ONE core call" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module cap(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real c = 1e-12 from (0:inf);
        \\  parameter real r = 1e3 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ c * ddt(V(p, n));
        \\    I(p, n) <+ V(p, n) / r;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // `eval` and `q` survive untouched — the fusion is additive.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn eval(comptime S: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(comptime S: type") != null);
    const at = std.mem.indexOf(u8, src, "pub fn evalQ(comptime S: type").?;
    const fused = src[at..][0..std.mem.indexOf(u8, src[at..], "\n}\n").?];

    // The whole point: ONE core call for both halves. Two would make `evalQ`
    // exactly the `eval` + `q` it exists to replace.
    try std.testing.expect(std.mem.count(u8, fused, "@call(.always_inline, core, .{ S, x, model, inst })") == 1);
    // ...and it is hoisted ABOVE both blocks, not opened inside one of them.
    try std.testing.expect(std.mem.indexOf(u8, fused, "@call(.always_inline, core, .{ S, x, model, inst })").? <
        std.mem.indexOf(u8, fused, "blk:").?);
    try std.testing.expect(std.mem.indexOf(u8, fused, "struct { res: [n_u]S, q: [n_u]S }") != null);
    try std.testing.expect(std.mem.indexOf(u8, fused, "return .{ .res = rr, .q = qq };") != null);
    // Both halves stamp; a fused function with an empty half is the bug where
    // `emitStamps` wrote into the wrong block.
    try std.testing.expect(std.mem.count(u8, fused, "var   res = [_]S{S.con(0.0)} ** n_u;") == 2);
}

test "codegen: a device with no reactive half gets no evalQ" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1e3 from (0:inf);
        \\  analog I(p, n) <+ V(p, n) / r;
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Pairs with `q`: the contract rejects `evalQ` without one, so codegen
    // must not emit a fused entry point there is nothing to fuse.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn evalQ(") == null);
}

test "codegen: §5.8 control flow reconstructs into structured Zig" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sw(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real ron = 1.0 from (0:inf);
        \\  parameter real roff = 1e9 from (0:inf);
        \\  analog begin
        \\    real g;
        \\    g = 0.0;
        \\    if (V(p, n) > 0.5) g = 1.0 / ron; else g = 1.0 / roff;
        \\    I(p, n) <+ g * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "} else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "break :B") != null);
}

test "codegen: minmax tie derivatives use source-defined mask selection" {
    for ([_][]const u8{ "min", "$min", "max", "$max" }) |name| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "module m(p,q); inout p,q; electrical p,q; analog I(p) <+ {s}(V(p),V(q)); endmodule",
            .{name},
        );
        defer std.testing.allocator.free(input);
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, input, &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        const call = if (std.mem.endsWith(u8, name, "min")) "zMin(S, " else "zMax(S, ";
        try std.testing.expect(std.mem.indexOf(u8, src, call) != null);
        try std.testing.expect(std.mem.indexOf(u8, src, "return a.lt(b).sel(a, b);") != null);
        try std.testing.expect(std.mem.indexOf(u8, src, "return b.lt(a).sel(a, b);") != null);
    }
}

test "codegen: if-converted diamond emits an eager mask select in a strict unit" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module mix(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    real g;
        \\    if (V(p, n) > 0.5) g = 2.0 * V(p, n); else g = 0.5 * V(p, n);
        \\    I(p, n) <+ g * exp(V(p, n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    // root.zig runs this between lower and prove; the harness does the same.
    // The MIR is arena-owned, so the pass must append with the same arena.
    const n = try ifconv.run(h.arena_state.allocator(), &h.mir, h.low.contributions.items);
    try std.testing.expect(n >= 1);
    const src = try h.gen(std.testing.allocator);
    // exp(unbounded V) forfeits finiteness, so the unit is .strict — the
    // eager-sel license. Arms are plain arithmetic: mask form, no branch.
    try std.testing.expect(std.mem.indexOf(u8, src, ".sel(") != null);
    // Lane-true mask: `V > 0.5` renders in S space as the swapped `lt`, not
    // as a `.val()` i64 round-trip.
    try std.testing.expect(std.mem.indexOf(u8, src, ".lt(") != null);
    // The diamond is gone: nothing left for the relooper to label.
    try std.testing.expect(std.mem.indexOf(u8, src, "break :B") == null);
}

test "codegen: a value shared by select arms is computed once, not once per use" {
    var h: Harness = undefined;
    // bsim2's vgeff shape: `e` is computed BEFORE the `if`, and after
    // conversion its only readers are select arms. Inlined per arm position
    // it came out as four `exp` calls for the source's one.
    try Harness.run(std.testing.allocator,
        \\module sh(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    real e, g;
        \\    e = exp(V(p, n));
        \\    if (V(p, n) > 0.5) g = e * e + e; else g = 0.5 * e;
        \\    I(p, n) <+ g;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expect(try ifconv.run(h.arena_state.allocator(), &h.mir, h.low.contributions.items) >= 1);
    const src = try h.gen(std.testing.allocator);
    const unit = src[std.mem.indexOf(u8, src, "fn sh__").?..];
    const body = unit[0..std.mem.indexOf(u8, unit, "\n}\n").?];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, ".exp()"));
}

test "codegen: a domain-guarded arm stays lazy through if-conversion" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lg(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real vmin = 1.0 from (0:inf);
        \\  analog I(p, n) <+ V(p, n) > vmin ? ln(V(p, n)) : 0.0;
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try ifconv.run(h.arena_state.allocator(), &h.mir, h.low.contributions.items);
    const src = try h.gen(std.testing.allocator);
    // What this protects is §4.2.12 laziness, not a spelling: `ln` runs only
    // on the path `V > vmin` selects. The guard may come out as a lazy
    // `(if (c) a else b)` or as the CFG `if (c) { ... } else { ... }` that
    // ifconv keeps for a domain-restricted arm — both pass, an eager `.sel(`
    // or a `.log()` outside the then-arm fails.
    // Scoped to the unit body — the emitted math prelude also spells `.log()`.
    const unit = src[std.mem.indexOf(u8, src, "fn lg__").?..];
    const body = unit[0..std.mem.indexOf(u8, unit, "\n}\n").?];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, ".log()"));
    const lg2 = std.mem.indexOf(u8, body, ".log()").?;
    // The nearest `if (` before the `.log()` opens the arm holding it, and no
    // `else` between them makes that the THEN arm — the one `V > vmin` takes.
    const guard = std.mem.lastIndexOf(u8, body[0..lg2], "if (").?;
    try std.testing.expect(std.mem.indexOf(u8, body[guard..lg2], "else") == null);
    try std.testing.expect(std.mem.indexOf(u8, body[0..lg2], "model.vmin") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ".sel(") == null);
    // And the proof accepted `ln` UNDER that guard: without it V <= 0 is
    // reachable and the unit would drop to `.strict`.
    try std.testing.expect(std.mem.indexOf(u8, body, "@setFloatMode(.optimized)") != null);
}

test "codegen: a multi-use domain op under a guard keeps its CFG diamond" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ml(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    real y;
        \\    y = 0.0;
        \\    if (V(p, n) > 0.0) begin
        \\      real t;
        \\      t = ln(V(p, n));
        \\      y = t + 2.0 * t; // t shared: markSelectArms could not guard it
        \\    end
        \\    I(p, n) <+ y * 1.0e-3;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    // The guard's evidence only survives conversion on exclusively-owned
    // slices; a shared `ln` result must refuse, or the model silently drops
    // to `.strict` (and an integer `/` in the same shape turns REJECTED).
    const n = try ifconv.run(h.arena_state.allocator(), &h.mir, h.low.contributions.items);
    try std.testing.expectEqual(@as(u32, 0), n);
    // Still compiles and proves through the CFG dominance path.
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, ".log()") != null);
}

test "codegen: a §5.6 potential contribution gets its own branch-current unknown" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module vs(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real dc = 1.0;
        \\  analog V(p, n) <+ dc;
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // lowering only allocates `flow(a,b)` where the model PROBES I(a,b), so
    // codegen appends the unknown AFTER node_order — existing indices hold.
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28pZ2cnZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const u_kinds") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".sub(c);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const num_ports: usize = 2;") != null);
}

test "codegen: §4.6.4 two noise sources on one branch export TWO generators" {
    var h: Harness = undefined;
    // The clause's own shape: "multiple noise contributions to a single branch
    // are combined". `combined/13_noise_temperature_analysis.va` writes exactly
    // this, and a single-valued tag made the flicker statement overwrite the
    // thermal one — deleting from `noise_gens` the ONE generator the documented
    // Jacobian-derived fallback can actually compute.
    try Harness.run(std.testing.allocator,
        \\module rnoise(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real rs = 1000.0;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / rs;
        \\    I(p, n) <+ white_noise(1.6e-23 / rs, "thermal");
        \\    I(p, n) <+ flicker_noise(1e-20, 1.0, "flicker");
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // §4.6.4.6 each CALL is one generator, so the two rows carry distinct
    // dense `source` ids — two independent sources, not one shared.
    // §4.6.4.1/.2 the trailing `name` argument is a LABEL and rides out with
    // the row. Two calls sharing one name would still be two sources — the
    // clause combines them in the host's summary, not in the table — which is
    // why `source` is distinct here while `name` is free to repeat.
    try std.testing.expect(std.mem.indexOf(u8, src, ".kind = .thermal, .source = 0, .name = \"thermal\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".kind = .flicker, .source = 1, .name = \"flicker\" }") != null);
    // §4.6.4.1 before §4.6.4.2 — the sources append in statement order, so the
    // table is stable across builds and a host may index it positionally.
    try std.testing.expect(
        std.mem.indexOf(u8, src, ".kind = .thermal").? <
            std.mem.indexOf(u8, src, ".kind = .flicker").?,
    );
}

test "codegen: §4.6.4 noisePsd is the model's own PSD, and a guarded one reads zero" {
    var h: Harness = undefined;
    // The shape EVERY series resistance in a real model card writes: the
    // generator lives inside `if (r > 0)`, and its power divides by that very
    // `r`. Hoisting `4kT/r` to `precompute` evaluates it at r == 0 — an
    // infinity that becomes a NaN the instant the collapsed branch gives it a
    // zero adjoint gain. It has to stay a core live-out, which `probeBody`
    // seeds `S.con(0.0)` and only the taken branch assigns.
    try Harness.run(std.testing.allocator,
        \\module rn(p, n, m);
        \\  inout p, n, m;
        \\  electrical p, n, m;
        \\  parameter real rs = 0.0;
        \\  parameter real ich = 1e-3;
        \\  analog begin
        \\    I(p, n) <+ white_noise(2.0 * 1.602176634e-19 * abs(ich), "shot");
        \\    if (rs > 0.0) begin
        \\      I(n, m) <+ V(n, m) / rs;
        \\      I(n, m) <+ white_noise(1.6e-23 / rs, "rs");
        \\    end else begin
        \\      V(n, m) <+ 0.0;
        \\    end
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The hook exists and is positional against `noise_gens`.
    const at = std.mem.indexOf(u8, src, "pub fn noisePsd(").?;
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const noise_gens").? < at);
    // Both powers come out of the core, NOT off a Jacobian and NOT inline:
    // §4.6.4.1 states the density as the call's argument, so the shot row is
    // `2q|I|` and the thermal row is `4kT/rs` — the same call, different
    // arguments, and only the model knows which.
    const body = src[at..];
    const ret = std.mem.indexOf(u8, body, "return .{").?;
    try std.testing.expect(std.mem.indexOf(u8, body[0..ret], "core(R, xr, model, inst)") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body[ret .. ret + 120], ".white = m.f"));
    // The guarded power is a live-out seeded zero, never an `inst.pc__` read:
    // a precompute field would have divided by rs == 0 unconditionally.
    var k: usize = ret;
    while (std.mem.indexOfPos(u8, body, k, ".white = m.f")) |i| {
        const f = body[i + ".white = m.f".len ..];
        const end = std.mem.indexOfScalar(u8, f, '.').?;
        const decl = try std.fmt.allocPrint(std.testing.allocator, "    .f{s} = h[", .{f[0..end]});
        defer std.testing.allocator.free(decl);
        try std.testing.expect(std.mem.indexOf(u8, src, decl) != null);
        k = i + 1;
        if (k > ret + 120) break;
    }
}

test "codegen: §4.6.4.3/.4 a noise table is exported sorted, with its own interpolation" {
    var h: Harness = undefined;
    // The two clauses' arguments are IDENTICAL in shape — "the meaning and
    // restrictions on the input are the same as for noise_table()" — and they
    // differ only in how the points are joined, so the difference has to be in
    // the exported table and nowhere else. Written descending, because
    // §4.6.4.3 makes sorting the simulator's job.
    try Harness.run(std.testing.allocator,
        \\module ntab(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ noise_table('{1e6, 1e-24, 1.0, 1e-18});
        \\    I(p, n) <+ noise_table_log('{1.0, 1e-18, 1e6, 1e-24});
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // Ascending, whichever order the model wrote them in, and each table keeps
    // the interpolation of the FUNCTION that declared it. The literals are
    // `fmtF64`'s, which is every other constant in the emitted device too.
    const p18 = "0.000000000000000001"; // 1e-18
    const p24 = "0.000000000000000000000001"; // 1e-24
    try std.testing.expect(std.mem.indexOf(u8, src, ".{ .interp = .linear, .points = &.{ .{ 1.0, " ++ p18 ++ " }, .{ 1000000.0, " ++ p24 ++ " } } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".{ .interp = .log, .points = &.{ .{ 1.0, " ++ p18 ++ " }, .{ 1000000.0, " ++ p24 ++ " } } }") != null);
    // One exported kind for both clauses, each row naming its own table, and
    // both independent generators (§4.6.4.6: two calls, two sources).
    try std.testing.expect(std.mem.indexOf(u8, src, ".kind = .table, .source = 0, .table = 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".kind = .table, .source = 1, .table = 1 }") != null);
    // `noise_tables` is read by `noise_gens`, so it has to be declared first.
    try std.testing.expect(
        std.mem.indexOf(u8, src, "pub const noise_tables").? <
            std.mem.indexOf(u8, src, "pub const noise_gens").?,
    );
    // The parametric half of a table row is ZERO, or a host that adds
    // `white + flicker/f^ef` to the table's answer would double-count.
    // §4.6.4.6's coefficient is 1 on both: each table is contributed with no
    // factor, so the row scales its own spectrum by exactly one.
    const at = std.mem.indexOf(u8, src, "pub fn noisePsd(").?;
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, src[at..], ".{ .white = 0, .coeff = 1 }, // noise_tables["),
    );
}

test "codegen: §4.6.4.3 an array-parameter table exports the card's knots, a literal one does not" {
    // A.8.2's `noise_table_input_arg` names `parameter_identifier` FIRST, and
    // §3.4 makes a parameter's value the model card's. So the comptime
    // `noise_tables` can only be the DECLARED DEFAULT and the card's answer is
    // the extra hook — which must not appear on a device that has no
    // parameter in any table, or every host of every such device would be
    // obliged to read something `noise_tables` already told it.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module nparam(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real tbl[0:3] = '{1e6, 1e-24, 1.0, 1e-18};
        \\  analog I(p, n) <+ noise_table(tbl);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Sorted at compile time on the DEFAULTS, so `noise_tables` keeps the
    // invariant `contract.validate` enforces...
    try std.testing.expect(std.mem.indexOf(u8, src, ".points = &.{ .{ 1.0, 0.000000000000000001 }, .{ 1000000.0, 0.000000000000000000000001 } }") != null);
    // ...and the hook returns the same two knots in the same order, reading
    // the card, with the run-time sort a reordering card would need.
    const at = std.mem.indexOf(u8, src, "pub fn noiseTablePoints(model: *const Model) [2][2]f64 {").?;
    const end = std.mem.indexOfPos(u8, src, at, "\n}\n").?;
    const body = src[at..end];
    try std.testing.expect(std.mem.indexOf(u8, body, ".{ model.tblZ5b2Z5d, model.tblZ5b3Z5d }") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ".{ model.tblZ5b0Z5d, model.tblZ5b1Z5d }") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "contract.sortNoiseTable(pts[0..2]);") != null);
    // The default's order is the EXPORT's order: `noise_tables[k]` and the
    // hook's k-th pair are the same knot, so the sort permuted both.
    try std.testing.expect(std.mem.indexOf(u8, body, ".{ model.tblZ5b2Z5d, model.tblZ5b3Z5d }").? <
        std.mem.indexOf(u8, body, ".{ model.tblZ5b0Z5d, model.tblZ5b1Z5d }").?);

    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module nlit(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ noise_table('{1.0, 1e-18, 1e6, 1e-24});
        \\endmodule
    , &h2);
    defer h2.deinit();
    const lit = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, lit, "noiseTablePoints") == null);
}

test "codegen: §4.6.4.6 each use of a shared generator exports its own coefficient" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module shared(a, b, c, d);
        \\  inout a, b, c, d;
        \\  electrical a, b, c, d;
        \\  parameter real pwr = 1e-18;
        \\  real nz;
        \\  analog begin
        \\    nz = white_noise(pwr, "shared");
        \\    V(a, b) <+ 2.0 * nz;
        \\    V(d, c) <+ 3.0 * nz;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // ONE generator — both rows carry `.source = 0` — with TWO coefficients.
    // Without them both rows report the raw 1e-18 and a host computes this
    // module's output noise 4x and 9x low.
    const at = std.mem.indexOf(u8, src, "pub fn noisePsd(").?;
    try std.testing.expect(std.mem.indexOf(u8, src[at..], ".coeff = 2") != null);
    // §1.3.1.2: `V(d,c)` drives the same branch as `V(c,d)` with the sign
    // flipped, and the SIGN is what separates correlation from
    // anti-correlation — so it has to survive into the export.
    try std.testing.expect(std.mem.indexOf(u8, src[at..], ".coeff = -3") != null);
}

test "codegen: §4.6.4.6 a generator no single factor describes keeps coefficient 1" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sq(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  real nz;
        \\  analog begin
        \\    nz = white_noise(1e-18);
        \\    I(a, b) <+ nz * nz;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // A generator squared is not a linear source, so there is no coefficient
    // to report and the row falls back to the 1 it carried before the field
    // existed rather than inventing one.
    const at = std.mem.indexOf(u8, src, "pub fn noisePsd(").?;
    try std.testing.expect(std.mem.indexOf(u8, src[at..], ".coeff = 1") != null);
}

test "codegen: §4.6.4.6 one tabulated source on two branches is one table" {
    var h: Harness = undefined;
    // The clause's Example 1 shape with a §4.6.4.4 source: "Perfectly
    // correlated noise is generated by using the output of one noise function
    // for more than one noise source." One call is one generator, so the two
    // rows share a `source` — and must share the TABLE too, or the export
    // describes one generator with two copies of its own spectrum.
    try Harness.run(std.testing.allocator,
        \\module nshare(a, b, c);
        \\  inout a, b, c;
        \\  electrical a, b, c;
        \\  real nt;
        \\  analog begin
        \\    nt = noise_table_log('{1.0, 1e-18, 1e6, 1e-24});
        \\    I(a, b) <+ nt;
        \\    I(b, c) <+ 2.0 * nt;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, ".interp = ."));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, ".source = 0, .table = 0 }"));
}

test "codegen: §4.6.3 an ac_stim exports its phasor and no noise generator" {
    var h: Harness = undefined;
    // The whole of the export in one module: the stimulus reaches the
    // contribution through a VARIABLE (which is how every fixture writes it),
    // the phase is a quadrature one where `mag*cos(phase)` is 6.1e-17, and the
    // model also declares a real noise generator so the two tables are
    // observably separate.
    try Harness.run(std.testing.allocator,
        \\module stim(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real amp = 2.0;
        \\  real s;
        \\  analog begin
        \\    s = ac_stim("xf", amp, 1.5707963267948966);
        \\    I(p, n) <+ V(p, n) * 1e-3 + 3.0 * s;
        \\    I(p, n) <+ white_noise(1e-18);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // §4.6.3 is not §4.6.4: the stimulus has its own table and puts no row in
    // `noise_gens`, which would be a generator the model never declared.
    try std.testing.expect(std.mem.indexOf(u8, src, ".name = \"xf\" }") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "contract.NoiseGen(Self){"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "contract.AcGen(Self){"));
    // One call is one source: the variable reaching two places (the value and
    // the contribution) must not become two rows.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, ".name = \"xf\" }"));
    // The magnitude is a PARAMETER, so it cannot be comptime data: `acStim`
    // reads the card. And §4.6.4.6's per-use factor folds into it — a phasor
    // scales exactly — or a host is low by 3 on this source.
    const at = std.mem.indexOf(u8, src, "pub fn acStim(").?;
    try std.testing.expect(std.mem.indexOf(u8, src[at..], "(model.amp) * (3") != null);
    // Polar, not rectangular: `cos(π/2)` is 6.1e-17 and a stimulus that has
    // been through a complex conversion here is that far out of quadrature
    // before the host has done anything.
    try std.testing.expect(std.mem.indexOf(u8, src[at..], ".phase = 1.5707963267948966") != null);
}

test "codegen: §4.6.4 a generator VerA cannot export refuses the device" {
    // Both halves of the same rule: a `noise_gens` row that cannot be written
    // must take the DECL with it. Silently dropping the row would tell a host
    // the model declares no such noise, which is a PSD it can never ask for —
    // and `@compileError` is how codegen refuses (see `f64Expr`/E0515).
    const cases = [_][]const u8{
        // §1.3.1.1 a ground-ground branch has no row and no column (E0520).
        \\module ngnd(p);
        \\  inout p;
        \\  electrical p;
        \\  ground g;
        \\  electrical g;
        \\  analog begin
        \\    I(p) <+ V(p) * 1e-3;
        \\    I(g, g) <+ white_noise(1e-20);
        \\  end
        \\endmodule
        ,
        // §4.6.4.3 "Each frequency value must be unique" (E0519).
        \\module ndup(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ noise_table('{1.0, 1e-18, 1.0, 1e-24});
        \\endmodule
        ,
        // §4.6.4.3 pairs, not an odd tail (E0519).
        \\module nodd(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ noise_table('{1.0, 1e-18, 10.0});
        \\endmodule
        ,
        // NOT here: §4.6.4.3's FILE form. Its name "shall be constant", so
        // `Lower.readNoiseTableFile` reads the pairs at compile time and the
        // table it produces is indistinguishable from the vector form's. A
        // file that cannot be read is a lowering error on the .va, which never
        // reaches codegen at all.
        //
        // NOT here either: an array PARAMETER. It used to be refused rather
        // than frozen at its declared default, which a model card may
        // override; now `noise_tables` carries the defaults and
        // `noiseTablePoints` carries the card, so neither is frozen and
        // nothing is refused. The test below this one pins both halves.
        // §4.6.4.4 interpolates log(power), and log(0) is not on the line.
        \\module nlog0(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ noise_table_log('{1.0, 0.0, 1e6, 1e-24});
        \\endmodule
        ,
    };
    for (cases) |case| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, case, &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const noise_gens = @compileError(\"LRM 4.6.4:") != null);
        // And no half-written table beside it.
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const noise_tables") == null);
        try std.testing.expect(std.mem.indexOf(u8, src, "pub fn noisePsd(") == null);
    }
}

test "codegen: §5.6.7 indirect contribution is a nullor row, ASYMMETRIC-safe" {
    var h: Harness = undefined;
    // Deliberately asymmetric: probe − equation = V(pin,nin) − 2*V(out).
    // The mirrored row (equation − probe) is invisible on the textbook opamp
    // (`V(pin,nin) == 0`), so the fixture that pins the sign has to be one
    // whose two sides differ.
    try Harness.run(std.testing.allocator,
        \\module amp(out, pin, nin);
        \\  inout out, pin, nin;
        \\  electrical out, pin, nin;
        \\  analog V(out) : V(pin, nin) == 2.0 * V(out);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The source current is a solver unknown; the KCL stamps are its only
    // occurrence outside its own row (a nullor).
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28outZ2cgndZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "res[@intFromEnum(U.flowZ28outZ2cgndZ29)] = c;\n") != null);
    // ... and NOT the direct-contribution row `V(hi,lo) − c`.
    try std.testing.expect(std.mem.indexOf(u8, src, ".sub(c);") == null);

    // THE trap: the row must be a function of `x`, or the host's dual-number
    // Jacobian has a zero column and Newton can never move the source.
    const key = "fn amp__common__core(comptime S: type, x: [n_u]S";
    try std.testing.expect(std.mem.indexOf(u8, src, key) != null);
    const unit = src[std.mem.indexOf(u8, src, key).?..];
    const body = unit[0..std.mem.indexOf(u8, unit, "\n}\n").?];
    // probe − equation, in that order.
    const probe_at = std.mem.indexOf(u8, body, "U.pin").?;
    // `2.0 * V(out)` reaches the constant through `scale`, not through a
    // second dual — the derivative-free side of a product never becomes an S.
    const eqn_at = std.mem.indexOf(u8, body, "scale(2.0)").?;
    try std.testing.expect(std.mem.indexOf(u8, body, ".sub(") != null);
    try std.testing.expect(probe_at < eqn_at);
}

test "codegen: §5.6.7.1 two indirect contributions to one branch get one source each" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module two(p, n, c1, c2);
        \\  inout p, n, c1, c2;
        \\  electrical p, n, c1, c2;
        \\  analog begin
        \\    V(p, n) : V(c1) == V(p, n);
        \\    V(p, n) : V(c2) == 2.0 * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Two sources ⇒ two currents ⇒ two DISTINCT U members (a shared name would
    // be a duplicate enum field, which the Zig parser cannot catch).
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28pZ2cnZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28pZ2cnZ29Z231, // branch flow") != null);
    // Two targets ⇒ two distinct core fields ⇒ two rows in `eval`. (The
    // group-local ordinal naming.zig gives the second unit is still what keys
    // its §4.5 state and proof.zig's verdict; it just no longer names a decl.)
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f1;") != null);
}

test "codegen: §5.10.5 only a `timer` module gets a nextBreakpoint hook" {
    // The hook is OPTIONAL in tools/contract.zig, and emitting it
    // for a module with no timer would claim a schedule that does not exist —
    // the host reads "no breakpoints ever" and stops asking. `transition` is the
    // trap case: it is stateful and discontinuity-adjacent, but nothing about it
    // says WHERE a timepoint goes, only how fast the value moves.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tr(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, 1e-9);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn updateState(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "nextBreakpoint") == null);
}

test "codegen: §5.10.5 a timer whose start is a solved quantity emits NO hook" {
    // `nextBreakpoint` gets `*const Model` and no `Instance`, so the schedule
    // has to be a function of the parameters. A start_time read off the solution
    // is not, and there is no honest answer to give — a guessed one either hangs
    // the transient walk (an answer at or before `t`) or moves an edge. Silence
    // degrades to LTE step control, which is where every device is today.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tv(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer fired;
        \\  analog begin
        \\    @(timer(V(p, n), 1e-9)) fired = fired + 1;
        \\    I(p, n) <+ fired;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "__next") != null); // the timer IS compiled
    try std.testing.expect(std.mem.indexOf(u8, src, "nextBreakpoint") == null);
}

test "codegen: §4.5 operator state is keyed to the stable unit id" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tr(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real td = 1e-9 from (0:inf);
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, td, td);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "tr__analog_op__transition__from: f64 = 0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tr__analog_op__transition__t0: f64 = 0.0") != null);
    // The operator's INPUT is a core field now, not a declaration of its own —
    // but the state field, and therefore `naming.zig`'s key, is untouched.
    try std.testing.expect(std.mem.indexOf(u8, src, "zTransition(S, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const m = core(R, xr, model, inst);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn updateState(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const State = struct {") != null);
}

test "codegen: §4.5.11 laplace_nd emits a real filter, not a compile error" {
    // Was: asserted laplace was a LOUD @compileError. It is now implemented,
    // so the assertion is inverted — a stateful filter unit must be emitted.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lp(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ laplace_nd(V(p, n), {1.0}, {1.0, 1.0});
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "laplace_nd") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn updateState(") != null);
    // The cascade's `__sec(model)` call is the ONLY Model read in this module,
    // so the unit's parameter must stay NAMED. Was patched to `_`, which made
    // every filter-in-a-contribution device fail to compile on `model`.
    try std.testing.expect(std.mem.indexOf(u8, src, "__sec(model)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "core(comptime S: type, x: [n_u]S, model: *const Model") != null);
}

test "codegen: a non-const analog-operator control argument is a LOUD compile error" {
    // The invariant the previous test really guarded: unsupported constructs
    // must be loud, never a silent substitute value (a silent 0 corrupts the
    // device residual). §4.5.14 requires control arguments to be constant.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tv(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, V(p, n), 1e-9);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") != null);
}

test "codegen: §5.4.3 I(<p>) is a solver unknown pinned to the KCL sum at p" {
    var h: Harness = undefined;
    // §5.4.3's own diode example shape: the probed port also carries a `ddt`
    // contribution, so a DC-only port current would be silently wrong in tran.
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  parameter real cj = 1e-12;
        \\  real m;
        \\  analog begin
        \\    I(a, c) <+ 1e-3 * V(a, c) + ddt(cj * V(a, c));
        \\    m = I(<a>);
        \\    I(a, c) <+ 1e-9 * m;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // Its own unknown, appended after the ports so `num_ports` is untouched,
    // and classified a CURRENT by the existing `flow(` predicate.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const num_ports: usize = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28Z3caZ3eZ29, // branch flow") != null);

    // SIGN: `I(p,n) <+ c` stamps `+c` at hi, so res[a] is the current leaving
    // node a INTO the module — which is exactly §5.4.3's "flow into a port".
    // Hence `x − res[a]`, not `x + res[a]`.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3caZ3eZ29)] = x[@intFromEnum(U.flowZ28Z3caZ3eZ29)].sub(res[@intFromEnum(U.a)]);",
    ) != null);
    // THE REACTIVE HALF: q() carries `−q_a` on the same row, so the total
    // residual is x − (I_dc + d/dt q_a).
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3caZ3eZ29)] = res[@intFromEnum(U.a)].neg();",
    ) != null);
    // The row is emitted AFTER the contribution stamps it reads.
    const stamp_at = std.mem.indexOf(u8, src, "res[@intFromEnum(U.a)].add(c)").?;
    const row_at = std.mem.indexOf(u8, src, "= x[@intFromEnum(U.flowZ28Z3caZ3eZ29)].sub(").?;
    try std.testing.expect(stamp_at < row_at);
}

test "codegen: a port whose only branch goes to ground still gets its unknown" {
    var h: Harness = undefined;
    // The self-referential form: I(p) <+ I(<p>) + V(p). Nothing else drives p.
    try Harness.run(std.testing.allocator,
        \\module g(p);
        \\  inout p;
        \\  electrical p;
        \\  analog I(p) <+ I(<p>) + V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28Z3cpZ3eZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3cpZ3eZ29)] = x[@intFromEnum(U.flowZ28Z3cpZ3eZ29)].sub(res[@intFromEnum(U.p)]);",
    ) != null);
    // No reactive part anywhere ⇒ no q() at all, so no port row is missing.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(") == null);
}

test "codegen: the `U` block is the SPELLING contract — all four name kinds, verbatim" {
    var h: Harness = undefined;
    // `node_voltages` is one string key space over four different kinds of name,
    // and only one of them has a source spelling. The KEY is lowering's private
    // business, but the spelling is not: it reaches the user three times over —
    // as an emitted `U` member (here), as the identifier a `//! bias`/`//! sweep`
    // line has to write (tb.zig's `unknownName`, pinned in its own test), and as
    // the name every diagnostic over an unknown prints. So it is pinned as the
    // whole block, byte for byte, and not one `indexOf` per kind: an insertion,
    // a reorder or a re-escape is a change to the host's ABI and to every
    // fixture that biases an unknown, and each of those is invisible to a
    // substring search.
    //
    // Ports first, then §3.6.3 internal nets, then §5.4.2/§5.4.3 flows — the
    // order `emitTopology` documents, which is also `num_ports`' meaning.
    // `naming.sanitize` is what makes `b[0]` and `flow(p,n)` legal Zig, and
    // `isValidId` leaves `p` and `n` alone.
    try Harness.run(std.testing.allocator,
        \\module m(p, b);
        \\  inout p;
        \\  inout [0:1] b;
        \\  electrical p, n;
        \\  electrical [0:1] b;
        \\  real x;
        \\  analog begin
        \\    x = I(p, n);
        \\    I(p, n) <+ x + I(<p>);
        \\    I(b[0], b[1]) <+ V(b[0], b[1]);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src,
        \\pub const U = enum(u8) {
        \\    p, // port
        \\    bZ5b0Z5d, // port
        \\    bZ5b1Z5d, // port
        \\    n, // internal
        \\    flowZ28pZ2cnZ29, // branch flow
        \\    flowZ28Z3cpZ3eZ29, // branch flow
        \\};
    ) != null);
}

test "codegen: §5.9 a loop the unit re-runs is not read out of the shared core" {
    var h: Harness = undefined;
    // Two units both slice the loop, so `planCommon` wants to hoist it — but
    // each also has private values inside it, so each re-materializes the loop.
    // Reading the hoisted counter and exit condition there is reading their
    // FINAL values, and the re-materialized loop then runs zero times.
    try Harness.run(std.testing.allocator,
        \\module l(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer i;
        \\  real a, b;
        \\  analog begin
        \\    a = 0.0;
        \\    b = 0.0;
        \\    for (i = 1; i <= 5; i = i + 1) begin
        \\      a = a + i;
        \\      b = b + i * 2;
        \\    end
        \\    I(p, n) <+ a * V(p, n);
        \\    I(p) <+ b * V(p);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    // `genDisplay`, not `gen`: since the merge the RESIDUAL cannot hit this bug
    // at all — there is one body, the loop is emitted where its values are
    // computed, and there is no cache holding a loop-carried value at its exit
    // state. §9.4 `display` is the one declaration that still opens with
    // `const c = core(...)`, so it is the only remaining consumer of the §5.9
    // `loop_recompute` fixpoint and therefore the only place this can regress.
    const src = try h.genDisplay(std.testing.allocator);
    // A body holding `while (true)` while reading `c.f<N>` inside it is the bug.
    var rest = src;
    while (std.mem.indexOf(u8, rest, "L")) |_| {
        const at = std.mem.indexOf(u8, rest, ": while (true)") orelse break;
        const end = std.mem.indexOfPos(u8, rest, at, "\n    }") orelse rest.len;
        try std.testing.expect(std.mem.indexOf(u8, rest[at..end], "c.f") == null);
        rest = rest[end..];
    }
    // The residual half of the guarantee, stated structurally: the merged core
    // reads no cache, so a `c.f` cannot appear in it anywhere, in or out of a
    // loop. This is what makes the hazard impossible rather than merely absent.
    const core_at = std.mem.indexOf(u8, src, "fn l__common__core(").?;
    const core_end = std.mem.indexOfPos(u8, src, core_at, "\n}\n").?;
    try std.testing.expect(std.mem.indexOf(u8, src[core_at..core_end], "c.f") == null);
}

test "codegen: §9.4 display tasks are void by default and print on request" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real g = 2.0;
        \\  analog begin
        \\    $strobe("g=%g n=%5d s=%s", g, 42, "x");
        \\    $write("no newline");
        \\    $error("bad");
        \\    I(p, n) <+ g * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    // A DEVICE never prints: no sink, nothing that blocks a GPU backend.
    const dev = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, dev, "std.debug.print") == null);
    try std.testing.expect(std.mem.indexOf(u8, dev, "pub fn display(") == null);

    // The EXECUTABLE does, with §9.4.3 conversions translated and the operands
    // sliced in (a missing slice renders every one of them as `S.con(0.0)`).
    const exe = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, exe, "pub fn display(") != null);
    // `%g` is a §9.4.3 Table 9-23 REAL conversion, so it composes its own
    // field through `str_kernels.zCReal` and arrives as `{s}`; `%5d` is the
    // documented zPadInt detour and `%s` is Zig's own verb.
    try std.testing.expect(std.mem.indexOf(u8, exe, "g={s} n={s:>5} s={s}\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, exe, "zCReal(&zb0, (S.con(model.g)).val(), 'g', 0, 0, -1)") != null);
    // §9.4.1 `$write` is the one that does not end the line.
    try std.testing.expect(std.mem.indexOf(u8, exe, "\"no newline\"") != null);
    // §9.7.3 the severity is a prefix, not something a reader must infer.
    try std.testing.expect(std.mem.indexOf(u8, exe, "ERROR: bad") != null);
}

test "codegen: §9.4.6 a display task under an `if` prints inside its arm" {
    // THE BUG THIS PINS (was W0851). A guarded display call does not dominate
    // the end-of-block chain root, so `finishDisplays` could not `fadd` it in —
    // and an unchained call is dead code the unit slice drops, taking the print
    // with it. The fix carries it through an SSA place written in the arm, so
    // the call keeps its position in the CFG and the phi makes it live.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module c(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    if (V(p, n) > 0.5) $strobe("hi");
        \\    else $strobe("lo");
        \\    $strobe("always");
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    const exe = try h.genDisplay(std.testing.allocator);
    const at = std.mem.indexOf(u8, exe, "fn c__display__tasks(").?;
    const body = exe[at..std.mem.indexOfPos(u8, exe, at, "\n}\n").?];
    // All three reach the output...
    for ([_][]const u8{ "\"hi\\n\"", "\"lo\\n\"", "\"always\\n\"" }) |lit|
        try std.testing.expect(std.mem.indexOf(u8, body, lit) != null);
    // ...and the two guarded ones are still GUARDED: each sits after an `if`
    // and before the unconditional one, which is emitted at the block's end.
    const hi = std.mem.indexOf(u8, body, "\"hi\\n\"").?;
    try std.testing.expect(std.mem.lastIndexOf(u8, body[0..hi], "if (") != null);
    try std.testing.expect(hi < std.mem.indexOf(u8, body, "\"always\\n\"").?);
    // A DEVICE still prints nothing at all (W0850 covers the whole family).
    const dev = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, dev, "std.debug.print") == null);
}

test "codegen: §9.5 a descriptor is an i64 in the DEVICE too, not only in the executable" {
    // THE BUG THIS PINS. `emitSysCall`'s §9.5 branch used to be gated on
    // `display == .emit`, so in a device the eight descriptor-RETURNING names
    // fell through to `void_tasks`' blanket `S.con(0.0)` — while
    // `Analysis.callTy` types every one of them `.int` and therefore declared
    // the slot `i64`. The emitted line was `const t0: i64 = S.con(0.0);`,
    // `--emit-zig` exited 0, and the failure landed in the HOST's build as
    // `expected type 'i64', found 'Dual'` against generated Zig in a cache
    // directory. `emitFileCallDropped` already switched on `callTy`; the gate
    // was all that kept it from running.
    //
    // `fd` FEEDS THE RESIDUAL on purpose. A descriptor whose value nothing reads
    // gets no slot, so the wrong type would be merely absent instead of wrong —
    // which is why this is the one shape that observes it.
    //
    // THE SUITE CANNOT GRADE THIS. `tests/torture.zig` compiles every fixture
    // with `.display = .emit` (there is no `//!` directive for the mode), so a
    // `.va` cannot reach the `.drop` path at all. This test is the grader.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module fdev(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer fd;
        \\  analog begin
        \\    fd = $fopen("nope.txt");
        \\    I(p, n) <+ V(p, n) * (fd + 1);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    // §9.5.1 "a zero is returned for the mcd or fd" — as an INTEGER. A device has
    // no host file table, so zero is the answer and not a stub.
    const dev = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, dev, ": i64 = @as(i64, 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, dev, ": i64 = S.con(") == null);
    // No kernel came with it: `buildPrelude` gates the descriptor table on
    // `display == .emit`, and a call to `zFOpen` here would not resolve.
    try std.testing.expect(std.mem.indexOf(u8, dev, "zFOpen") == null);

    // The printing artifact opens the file for real, in the display unit, and
    // latches the descriptor; the core's `fd` — the one the residual and
    // `updateState` see — is that latch, not the device's zero.
    const exe = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, exe, "zFKeep(") != null);
    try std.testing.expect(std.mem.indexOf(u8, exe, ": i64 = zFRes(") != null);
}

test "codegen: §9.4 a display unit that reads an operator input opens the cache" {
    // The display unit is the ONE unit not folded into the core, and an
    // operator's input is not a `mark`ed operand — so a `c.f*` rendered for it
    // used to arrive with no `const c = core(...)` above it and the printing
    // artifact did not compile. Same shape for ddt/transition/slew/laplace.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module dop(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    $strobe("y=%g", transition(V(p, n), 0.0, 1n, 1n));
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const exe = try h.genDisplay(std.testing.allocator);
    const at = std.mem.indexOf(u8, exe, "zTransition(S, c.f").?;
    const open = std.mem.lastIndexOf(u8, exe[0..at], "const c = @call(.always_inline, core, .{ S, x, model, inst });");
    const head = std.mem.lastIndexOf(u8, exe[0..at], "\nfn ") orelse 0;
    try std.testing.expect(open != null and open.? > head);
}

test "codegen: §2.6.1 an integer literal keeps all 64 bits" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module big(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer k;
        \\  analog begin
        \\    k = 4607182418800017408;
        \\    I(p, n) <+ V(p, n) * k;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // The integer side of the product carries no derivative, so it folds and
    // arrives as the f64 the multiply needs. `fmtF64` is `{d}`, which is the
    // shortest representation that ROUND-TRIPS — 4607182418800017400.0 parses
    // back to exactly 4607182418800017408, and every literal in every emitted
    // device already rests on that. What must not happen is the value changing.
    try std.testing.expect(std.mem.indexOf(u8, src, "scale(4607182418800017400.0)") != null);
    try std.testing.expectEqual(
        @as(f64, 4607182418800017408),
        try std.fmt.parseFloat(f64, "4607182418800017400.0"),
    );
    // `0.0 * k` would fold the contribution away entirely, which is why the
    // multiplicand here is a probe: the literal has to reach the device.
}

test "codegen: §3.2 the three sites that impose the 32-bit integer width agree" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module w(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer big = 2147483647 + 1;
        \\  parameter integer chained = big + 1;
        \\  localparam integer sh = 1 << 31;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) * (big + 1);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Site 1, `Lower.foldBinary`: a §4.2 constant expression, folded before the
    // Model field is written. 2^31 is one step past the top of §3.2's range.
    try std.testing.expect(std.mem.indexOf(u8, src, "big: i64 = -2147483648") != null);
    // §4.2.11 `<<` at the same width — `1 << 31` is the sign bit, not 2^31.
    try std.testing.expect(std.mem.indexOf(u8, src, "sh: i64 = -2147483648") != null);
    // Site 2, `analysis.foldConst`: a §6.3.4 default over another parameter,
    // folded for the field initializer and re-emitted in `derive` for the
    // overridden case. -2^31 + 1, so the two folds have to agree on -2^31 first.
    try std.testing.expect(std.mem.indexOf(u8, src, "chained: i64 = -2147483647") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "model.chained = @as(i32, @truncate(") != null);
    // Site 3, `codegen.intBin32`: the device. `+%` is the 64-bit wrap that keeps
    // the add from panicking; the truncation is §3.2's width. The left operand
    // is a PARAMETER, so neither fold can reach it and the wrap has to survive
    // as emitted code — which is the site this half of the test is about.
    try std.testing.expect(std.mem.indexOf(u8, src, "@as(i32, @truncate(((model.big) +% (@as(i64, 1)))))") != null);
}

test "codegen: a unit whose target is defined in one arm returns a VALUE, not undefined" {
    var h: Harness = undefined;
    // §4.5 the operator's input unit is sliced from the argument, which here is
    // only defined on the taken arm. Returning `undefined` from the other one is
    // undefined behavior in the device AND silently corrupts the operator's
    // history, because `updateState` pushes whatever comes back.
    // The condition is a §3.4 PARAMETER, which §5.8.1 licenses (a `constant_
    // primary` cannot move mid-analysis, so the operator never misses a step)
    // while `elabConst` still refuses to fold it away — a model card overrides
    // it. So the diamond is real and the operator is legal, which is exactly the
    // shape this test needs. A probe condition here would now be E0514.
    try Harness.run(std.testing.allocator,
        \\module g(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  parameter real en = 1.0;
        \\  analog begin
        \\    if (en > 0.5)
        \\      I(p, n) <+ transition(V(p, n), 0, 1n, 1n);
        \\    else
        \\      I(p, n) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const at = std.mem.indexOf(u8, src, "fn g__common__core(").?;
    // `"\n}\n"`, not `"\n}"`: the core's return type is an anonymous struct
    // written into the signature, and it closes with `\n} {`.
    const end = std.mem.indexOfPos(u8, src, at, "\n}\n").?;
    const body = src[at..end];
    // Hoisted slots share one `var h: [n]S`, so the carve-out is no longer a
    // property of each declaration — the array itself is declared `undefined`.
    // It is now the pair of facts below: the array is EXACTLY as long as the
    // number of zero-seeds, so no element of it can reach the `return`
    // unwritten. Assert both or the guarantee is not being tested.
    //
    // Targeted, not a blanket memset: the only hoists are the two returned
    // fields (the operator input, defined on one arm only, and the contribution
    // phi). Every other slot is a `const` at its definition, which is what
    // `probeBody` is for — so counting the hoists is counting exactly the values
    // that could reach the `return` without being written.
    try std.testing.expect(std.mem.indexOf(u8, body, "    var h: [2]S = undefined;") != null);
    var hoists: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "    h[")) continue;
        hoists += 1;
        try std.testing.expect(std.mem.endsWith(u8, line, "= S.con(0.0);"));
    }
    try std.testing.expectEqual(@as(usize, 2), hoists);
}

test "codegen: §4.5.8/§4.5.9 an omitted rate argument copies the one that was given" {
    // §4.5.8: "If only a positive rise_time value is specified, the simulator
    // uses it for both rise and fall times." §4.5.9: max_neg_slew_rate "defaults
    // to the opposite of the max_pos_slew_rate."
    //
    // Both used to default to a NEUTRAL element instead of to the value that WAS
    // given — `fall = 0.0` and `max_neg = 1e300` — so the short spelling of each
    // operator behaved differently from the long spelling written with the same
    // number: the 3-argument `transition` transitioned twice as fast, and `slew`
    // held the rising edge while letting the falling edge through unlimited.
    //
    // Asserted on the emitted call rather than by diffing the two spellings,
    // because `slew(x, 2e8, -2e8)` renders `@abs(-2e8)` and the short form
    // renders `@abs(2e8)` — the same limit, different text.
    const cases = [_]struct { call: []const u8, want: []const u8 }{
        .{
            // §4.5.8 now passes rise and fall SEPARATELY (the averaged lag
            // constant is gone), so the copy shows up as the same number twice
            // in the last two argument positions of the call.
            //
            // `0.0000000022` and not `0.0000000022000000000000003`: this is the
            // tree's only pin on the §2.6.2 scale-factor decode, and the rule in
            // force is that `2.2n` is ONE `parseFloat` of the joined text
            // `2.2e-9`, not `2.2 * 1e-9`. The two differ by 1 ulp. Asserted as a
            // rule, with its LRM argument, in lexer.zig's "§2.6.2 a scale factor
            // rounds ONCE" test; re-blessed here when the parser stopped
            // carrying a second decoder that double-rounded.
            .call = "transition(V(p, n), 0, 2.2n)",
            .want = "0.0000000022, 0.0000000022)",
        },
        .{
            .call = "slew(V(p, n), 2e8)",
            .want = "inst.dt, 200000000.0, @abs(200000000.0))",
        },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  analog I(p, n) <+ {s};
            \\endmodule
        , .{c.call});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const out = try h.gen(std.testing.allocator);

        std.testing.expect(std.mem.indexOf(u8, out, c.want) != null) catch |e| {
            std.debug.print("{s}: expected to emit `{s}`\n", .{ c.call, c.want });
            return e;
        };
    }
}

test "codegen: §5.9.1 a short-circuit loop condition still reaches the loop's branch" {
    // §4.2.7 `&&` splits its expression across blocks, so after lowering the
    // condition of a `while` the CURRENT block is the short-circuit join, not
    // the loop header. `lowerWhile`/`lowerFor` used to emit the loop's own
    // branch into the header regardless: the header ended up with two
    // terminators, the `&&`'s rhs and join blocks lost their predecessor, and
    // codegen — which walks reachable blocks — declared slots for the values
    // defined in them and then never emitted a single assignment. The loop then
    // branched on an `undefined` local. Zig caught it as "unused local
    // variable" on `bsimsoi_va`; without that it is a read of undefined memory.
    //
    // Asserted structurally rather than on one temporary's name: EVERY declared
    // slot must be written somewhere in the body. That is the whole bug class,
    // and it does not move when slot numbering does.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module w(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    real x, y; integer i;
        \\    x = 1e6; y = V(p, n); i = 0;
        \\    while ((i <= 4) && (abs(y - x) > 1e-12)) begin
        \\      x = y;
        \\      y = 2.0 * y + 1.0;
        \\      i = i + 1;
        \\    end
        \\    I(p, n) <+ y;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The rhs of the `&&` is emitted at all — it used to be dropped entirely.
    try std.testing.expect(std.mem.indexOf(u8, src, ".abs()") != null);

    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const decl = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, decl, "var t")) continue;
        const name = decl[4 .. std.mem.indexOfScalar(u8, decl, ':') orelse continue];
        var buf: [32]u8 = undefined;
        const store = try std.fmt.bufPrint(&buf, "{s} = ", .{name});
        std.testing.expect(std.mem.indexOf(u8, src, store) != null) catch |e| {
            std.debug.print("slot `{s}` is declared but never assigned\n", .{name});
            return e;
        };
    }
}

test "codegen: §4.5.7 a delay computed from parameters renders as an expression over `model`" {
    // `td = len * sqrt(l * c)` is how every transmission line in the wild
    // spells its delay (devices/models/lossy_tline.va:135,
    // coupled_tlines.va:110). It is not a literal and not a bare parameter, so
    // it used to hit the `else` of `f64Expr` and paste an `@compileError` INTO
    // an expression in the generated Zig — which the Zig compiler then reported
    // as "unreachable code" at a line of generated code, with nothing naming
    // the model.
    //
    // §4.5.7 permits it: `absdelay(input, td [, maxdelay])` takes td as an
    // analog_expression, and with no maxdelay "the value of td when the
    // absdelay() is first evaluated shall be used" — which for an expression
    // over parameters is its value at every evaluation.
    //
    // Also pins the ASSIGNMENT: `td` is a `real` variable, not a parameter, so
    // this only works because the walk runs on SSA values rather than on names.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tl(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real len = 1.0 from (0:inf);
        \\  parameter real l = 250e-9 from (0:inf);
        \\  parameter real c = 100e-12 from (0:inf);
        \\  real td;
        \\  analog begin
        \\    td = len * sqrt(l * c);
        \\    I(p, n) <+ absdelay(V(p, n), td);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "inst.dt, (model.len) * (@sqrt((model.l) * (model.c))))",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") == null);
}

test "codegen: §5.6.5 a zero-short switch branch emits a collapse hook" {
    // diode.va's access-resistance idiom: rs > 0 selects a real resistor,
    // rs == 0 a retained 0 V short that ngspice would collapse at setup
    // (DIOsetup: posPrimeNode = posNode).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c, ai;
        \\  parameter real rs = 0.0 from [0:inf);
        \\  branch (a, ai) rsb;
        \\  analog begin
        \\    I(ai, c) <+ 1e-3 * V(ai, c);
        \\    if (rs > 0.0) I(rsb) <+ V(rsb) / rs;
        \\    else          V(rsb) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "pub fn collapse(model: *const Model, inst: *const Instance) [n_u]?u8",
    ) != null);
    // The internal node AND the branch-flow unknown both alias onto the port,
    // so the pair's stamps land on one slot and cancel.
    //
    // Asserted through the UNION-FIND emission, which replaced the
    // last-write-wins `out[victim] = target` these rows used to match. That
    // rewrite was the FIX for chained shorts — BSIM4 rgateMod=0 retains both
    // V(g,gm) and V(gm,gi), sharing gm, and last-write-wins left the chain's
    // first link dangling (see `collapse`'s own doc comment). The old spelling
    // is gone, so matching it asserted the bug rather than the fix.
    //
    // `ai` is aliased by the union and then resolved by the `if (r != u)` loop
    // over every unknown, so it is no longer written by name; the branch-flow
    // row still is, because it is not a union member.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "zCollapseUnion(&parent, @intFromEnum(U.ai), @intFromEnum(U.a));",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "out[@intFromEnum(U.flowZ28aZ2caiZ29)] = zCollapseRoot(&parent, @intFromEnum(U.a));",
    ) != null);
    // Min-index root, so `a` — a port at index 0 — is the target and never a
    // mover. That ordering is what lets the host resolve aliases ascending.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (ra < rb) parent[rb] = ra else parent[ra] = rb;",
    ) != null);
}

test "codegen: table capture is isolated from topology queries" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c; electrical a, c, ai;
        \\  parameter real rs = 0.0 from [0:inf);
        \\  branch (a, ai) rsb;
        \\  real xs[0:1], ys[0:1];
        \\  analog begin
        \\    if (rs > 0.0) I(rsb) <+ V(rsb) / rs;
        \\    else V(rsb) <+ 0.0;
        \\    xs[0]=0; xs[1]=1; ys[0]=$abstime; ys[1]=$abstime+2;
        \\    I(ai, c) <+ $table_model(0.5,xs,ys);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const collapse = src[std.mem.indexOf(u8, src, "pub fn collapse(") orelse return error.NoCollapse ..];
    try std.testing.expect(std.mem.indexOf(u8, collapse, "var pin = inst.*;") != null);
    try std.testing.expect(std.mem.indexOf(u8, collapse, "core(R, xr, model, &pin)") != null);
}

test "codegen: no collapse hook without the zero-short pattern" {
    // An unconditional resistor has nothing to collapse.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn collapse") == null);
}

test "codegen: a zero short still collapses after if-conversion makes its join a select" {
    // The diode idiom again, through ifconv as root.zig runs it. Both arms
    // are pure, so the diamond converts and the retention flag and the
    // potential accumulator become `select`s: `select(rs > 0, 0, 1)` and
    // `select(rs > 0, 0, 0)`. `zeroOnEveryPath` walked phis only, so the
    // converted form lost its collapse — and whether a model collapsed
    // hung on whether ifconv could convert the diamond (a late phi row in
    // the branching block stopped it, so ifconv finding the terminator by
    // opcode changed hisimhv_va's BRddp from collapsed to not).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c, ai;
        \\  parameter real rs = 0.0 from [0:inf);
        \\  branch (a, ai) rsb;
        \\  analog begin
        \\    I(ai, c) <+ 1e-3 * V(ai, c);
        \\    if (rs > 0.0) I(rsb) <+ V(rsb) / rs;
        \\    else          V(rsb) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expect(try ifconv.run(h.arena_state.allocator(), &h.mir, h.low.contributions.items) >= 1);
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn collapse(") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "zCollapseUnion(&parent, @intFromEnum(U.ai), @intFromEnum(U.a));",
    ) != null);
}

test "codegen: an OBSERVED zero short is not collapsed" {
    // §5.4.2 `I(rsb)` reads the branch-flow unknown, which `collapse` would
    // alias onto a node voltage: the model would read V(a), not its current.
    // static_switch_elision.va asserts the current and passed only because
    // ifconv converted its diamond (and the select form never collapsed);
    // the phi form — an arm ifconv keeps, here `sqrt` — read 0.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c, ai;
        \\  parameter real rs = 0.0 from [0:inf);
        \\  branch (a, ai) rsb;
        \\  real seen;
        \\  analog begin
        \\    seen = I(rsb);
        \\    I(ai, c) <+ 1e-3 * V(ai, c) + 0.0 * seen;
        \\    if (rs > 0.0) I(rsb) <+ V(rsb) / rs + 0.0 * sqrt(rs);
        \\    else          V(rsb) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn collapse") == null);
}

test "codegen: an x-steered zero short is NOT collapsed" {
    // The guard reads a probe, so which arm is retained changes per
    // evaluation; a build-time alias would be a lie. `buildFree` refuses it.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c, ai;
        \\  analog begin
        \\    I(ai, c) <+ 1e-3 * V(ai, c);
        \\    if (V(a, c) > 1.0) I(a, ai) <+ 1e3 * V(a, ai);
        \\    else               V(a, ai) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn collapse") == null);
}

test "codegen: §4.5 a control argument that is a solve result is E0515, not generated Zig" {
    // The other half: a control argument the CLAUSE makes constant and that
    // genuinely cannot be resolved must be a diagnostic at the `.va` line. An
    // `@compileError` pasted into an expression is not one — it reads as an
    // engine bug in generated code.
    //
    // §4.5.8's rise_time, not §4.5.7's td: Table 4-20 lists every one of
    // `transition`'s times among the CONSTANT expression arguments and
    // `absdelay`'s td among the DYNAMIC ones, so `absdelay(V(p,n), V(c))` —
    // which this used to spell — is a legal program and is now compiled (see
    // `dynCtrlArgs` and
    // ch04_expressions/a04_03_absdelay_td_frozen_without_maxdelay.va).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  analog I(p, n) <+ transition(V(p, n), 0, V(c));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    var found = false;
    for (h.bag.messages()) |mi| {
        const e = h.bag.get(mi);
        if (e.code != .E0515) continue;
        found = true;
        try std.testing.expectEqual(diag.Stage.codegen, e.stage);
        // A node probe has no instruction of its own to point at, which is what
        // `ctrl_tok`'s fallback to the operator call exists for.
        try std.testing.expect(e.span.end > e.span.start);
    }
    try std.testing.expect(found);
    // Refused as a whole unit — an `@compileError` STATEMENT that replaces the
    // body, never one pasted into the middle of an expression (which is what
    // `inst.abstime - (@compileError(…))` was, and what Zig reported as
    // "unreachable code" at a line of generated code).
    try std.testing.expect(std.mem.indexOf(u8, src, "\n    @compileError(\"LRM 4.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "(@compileError") == null);
}

test "codegen: metadata control failure stays fatal with and without diagnostics" {
    // §4.5.14 permits first-use capture of a nonliteral constant argument.
    // Dynamic maxdelay is currently unsupported, not invalid source. Whatever
    // that limitation's diagnostic, callers must never receive a success flag
    // merely because a later unit reset the per-body `fatal` field.
    for ([_]bool{ false, true }) |with_diags| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator,
            \\module sampled(p, n, c);
            \\  inout p, n, c;
            \\  electrical p, n, c;
            \\  analog I(p,n) <+ absdelay(V(p,n), 1e-9, V(c));
            \\endmodule
        , &h);
        defer h.deinit();
        const v = try proof.prove(std.testing.allocator, &h.mir, &h.low, &h.bag);
        defer v.deinit(std.testing.allocator);
        try std.testing.expect(!h.bag.failed());
        const a = h.arena_state.allocator();
        var fatal = false;
        _ = try generate(a, a, &h.mir, &h.low, v, &fatal, .{
            .diags = if (with_diags) &h.bag else null,
        });
        try std.testing.expect(fatal);
        try std.testing.expectEqual(with_diags, h.bag.failed());
    }
}

test "codegen: §12.32.3 an unregistered system function is W0852 and a host call, not a refusal" {
    // The other side of the test above, and the distinction the whole W0852
    // ruling rests on: an unregistered `$name` has no value the LRM fixes, so
    // the unit must still compile — but not silently. §12.32.3's own sampnhold
    // listing, which is what puts one of these in a contribution.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sampnhold(out, in);
        \\  inout out, in;
        \\  electrical out, in;
        \\  parameter real period = 1e-3;
        \\  analog V(out) <+ $sampler(V(in), period);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    var found = false;
    for (h.bag.messages()) |mi| {
        const e = h.bag.get(mi);
        if (e.code != .W0852) continue;
        found = true;
        try std.testing.expectEqual(diag.Stage.codegen, e.stage);
        try std.testing.expect(e.span.end > e.span.start); // the call, not the file
    }
    try std.testing.expect(found);
    // Compiles. A refusal here would reject legal source (§2.8.3), which is the
    // regression this line exists to catch.
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") == null);

    // §2.8.3/§12.32: the name is EXPORTED for a host to bind, not answered here.
    // The `0.0` this test used to require is gone deliberately — a substitute
    // value is what the seam replaced.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const systf_calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".{ .name = \"$sampler\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "inst.systf.?") != null);
}

test "codegen: a systf call reassembles the host's value and partials into one S" {
    // The shape §12.22.1 forces, and the reason it is forced: `eval` is generic
    // over S and a function POINTER cannot be, so the host returns a value and
    // writes partials and the call site rebuilds the dual. Each graft term is
    // `arg.addC(-arg.val()).scale(p)` — VALUE zero, DERIVATIVE p·d(arg) — so on
    // the plain-f64 instantiation the residual reads the host's value exactly
    // and on the dual one it also carries the host's slope.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module twice(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ $foo(V(p,n)) + $foo(V(p,n)) + $bar(V(p,n));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // Deduplicated by NAME, because that is what §12.32 registers: two calls to
    // `$foo` are one table entry and one binding, and `$bar` is the second.
    const tbl = src[std.mem.indexOf(u8, src, "pub const systf_calls").?..];
    try std.testing.expect(std.mem.indexOf(u8, tbl, ".{ .name = \"$foo\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, tbl, ".{ .name = \"$bar\" }") != null);
    try std.testing.expect(std.mem.count(u8, tbl[0..std.mem.indexOf(u8, tbl, "};").?], ".name =") == 2);
    // …and the indices the call sites pass follow the table, not the call order.
    try std.testing.expect(std.mem.count(u8, src, "zsh.call(zsh.ctx, 0,") == 2);
    try std.testing.expect(std.mem.count(u8, src, "zsh.call(zsh.ctx, 1,") == 1);

    // The graft, spelled out. `.val()` feeds the host, `.addC(-...).scale(...)`
    // brings the partial back; dropping either half is the failure this pins.
    try std.testing.expect(std.mem.indexOf(u8, src, ".val() }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".addC(-zsv[0]).scale(zsp[0])") != null);
}

test "codegen: host parameter derivation reconstructs unconverted pure conditional phis" {
    // Harness intentionally skips if-conversion. The public driver also tests
    // the converted selects through the 90_dependent_control execution fixtures.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module conditional_parameter(p);
        \\  inout p; electrical p;
        \\  parameter real a = 0.0;
        \\  parameter real b = 0.3;
        \\  localparam integer decision = (a > 0.0) && (a < b);
        \\  localparam real value = decision ? (b > 0.0 ? b : 2.0) : 3.0;
        \\  analog I(p) <+ value * V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "model.decision = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "model.value = @as(f64, if (") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "(model.a) < (model.b)") != null);
}

test "codegen: an unsupported dependent default diagnoses instead of freezing" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module unsupported_parameter;
        \\  parameter integer amount = 2;
        \\  localparam integer size = $clog2(amount);
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.UnsupportedParameterDefault, h.gen(std.testing.allocator));
    for (h.bag.messages()) |mi| if (h.bag.get(mi).code == .E1004) return;
    return error.MissingDiagnostic;
}

test "codegen: §3.4 a default with no compile-time value is W1050, a derived one is silent" {
    // The guard on the `0` field initializer, and the line it must NOT cross.
    // `hot` reads §9.18's simulator table, which has no value until the host
    // runs — nothing folds it and nothing derives it, so `Model{}.hot` ships as
    // 0 and the host has to write the field. `warm` is 2*`base`, which §6.3.4
    // makes a `derive()` line; the same `0` initializer is honest there because
    // `derive` overwrites it, so warning about it would be noise on every
    // dependent parameter in the suite.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module pd(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real base = 3.0;
        \\  parameter real warm = 2.0 * base;
        \\  parameter real hot  = $simparam("gmin", 1e-12);
        \\  analog I(p, n) <+ V(p, n) * (warm + hot);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    var hits: usize = 0;
    for (h.bag.messages()) |mi| {
        const e = h.bag.get(mi);
        if (e.code != .W1050) continue;
        hits += 1;
        try std.testing.expectEqual(diag.Stage.codegen, e.stage);
        try std.testing.expect(e.span.end > e.span.start); // the declaration
    }
    try std.testing.expectEqual(@as(usize, 1), hits);
    // A warning, never a refusal: the device still compiles, because §9.18 says
    // nothing that makes this source illegal.
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") == null);
    // And `warm` is the derived half of the claim: initializer 0.0, `derive`
    // writing the §6.3.4 value over it.
    try std.testing.expect(std.mem.indexOf(u8, src, "model.warm = (2.0) * (model.base);") != null);
}

test "codegen: §9.15 $simparam(\"tnom\") is the HOST's nominal temperature" {
    // The defect this fixes: `tnom` folded to the constant 27, so a SPICE deck
    // setting `.options tnom` was silently ignored by every model — and a
    // compact model derives its whole parameter set from the nominal
    // temperature, so 2 K of error moves the I-V curve by percent.
    //
    // ngspice's shape, per model setup (b4set.c:1950): `if (!tnomGiven) tnom =
    // CKTnomTemp`. Here that is the `__given` guard `emitDerive` already writes
    // for every derived parameter, over a Model field the host writes once.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tn(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real tnom  = $simparam("tnom");
        \\  parameter real tnomk = $simparam("tnom") + 273.15;
        \\  analog I(p, n) <+ V(p, n) * (tnom + tnomk);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // ONE host-written field, on Model — `.options tnom` is one number per RUN,
    // so an Instance copy would replicate a global per instance, and two reads
    // of the same simparam must not become two fields.
    try std.testing.expect(std.mem.count(u8, src, "nom_temp__: f64 = 27.0,") == 1);

    // Table 9-27's declared default still IS the field initializer, in Celsius,
    // so `Model{}` — a host that writes nothing — is bit-identical to the old
    // folded constant. That is what keeps every existing fixture unmoved, and
    // `tnomk` pins that `27.0 + 273.15` folds to the literal `300.15` exactly.
    try std.testing.expect(std.mem.indexOf(u8, src, "tnom: f64 = 27.0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tnomk: f64 = 300.15,") != null);

    // Precedence: the card wins. `__given` is the same flag §9.19 uses, raised
    // by the host's `applyKv` when the model card named the parameter.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (!model.tnom__given) model.tnom = model.nom_temp__;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (!model.tnomk__given) model.tnomk = (model.nom_temp__) + (273.15);") != null);

    // A default that reads the host's table is no longer W1050: `derive()`
    // overwrites the field, which is that warning's own silence condition.
    for (h.bag.messages()) |mi| try std.testing.expect(h.bag.get(mi).code != .W1050);
}

test "codegen: §9.15 $simparam(\"tnom\") read from the body is the same field" {
    // Not only the §3.4 default position: a model that asks mid-body gets the
    // host's value too, or the two spellings of one question would disagree.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tb(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ V(p, n) * $simparam("tnom");
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "nom_temp__: f64 = 27.0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "S.con(model.nom_temp__)") != null);
}

test "codegen: §9.13 the emitted draws are IEEE 1364 §17.9.3's, digit for digit" {
    // Same arrangement as the scanner below: the kernels are `@embedFile`d into
    // every device, so what is checked here is byte-for-byte what runs there.
    //
    // §9.13.3 binds this family to IEEE 1364 §17.9.3's C listing (Table 9-26),
    // so there ARE digits to pin. Every literal below was produced by COMPILING
    // AND RUNNING that listing — the copy in Icarus Verilog's vpi/sys_random.c,
    // cross-checked against Verilator's verilated_probdist.cpp; provenance and
    // URLs in rng_kernels.zig's header — with `zig cc`, never hand-computed.
    // The log/sqrt-free rows (`uniform`, `rtl_dist_uniform`, the LCG steps) are
    // compared EXACTLY: they are pure IEEE-754 mul/add/div and the port must
    // reproduce the C bit for bit. The transcendental rows allow libm-vs-@log
    // ulp drift and nothing more — their SEEDS are still exact, because the
    // seed path is integer arithmetic and admits no drift at all.
    const k = @import("kernels").rng_kernels;
    const eps = std.testing.expectApproxEqRel;
    // $random from seed 7 = rtl_dist_uniform(&s, INT_MIN, INT_MAX), twice — the
    // second pair proves the write-back rejoined the reference stream.
    try std.testing.expectEqual(@as(f64, -2146999808), k.zRngRand(7));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngRandNext(7));
    try std.testing.expectEqual(@as(f64, 1181502348), k.zRngRand(483484));
    try std.testing.expectEqual(@as(f64, -965981971), k.zRngRandNext(483484));
    try std.testing.expectEqual(@as(f64, -2144582656), k.zRngRand(42));
    // One plain `uniform()` step, the Instance latch's advance.
    try std.testing.expectEqual(@as(f64, 483484), k.zRngNext(7));
    try std.testing.expectEqual(@as(f64, -483482), k.zRngNext(-7));
    try std.testing.expectEqual(@as(f64, -1844104698), k.zRngNext(0)); // 259341593 escape
    try std.testing.expectEqual(@as(f64, 69070), k.zRngNext(1));
    try std.testing.expectEqual(@as(f64, 2147345511), k.zRngNext(2147483646));
    // Table 9-26 `$rdist_uniform` → `uniform`: exact, mul/add only.
    try std.testing.expectEqual(@as(f64, 0.0011265279204053513), k.zRngUniform(7, 0.0, 10.0));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngUniformNext(7, 0.0, 10.0));
    try std.testing.expectEqual(@as(f64, 7.7508995236036071), k.zRngUniform(483484, 0.0, 10.0));
    // `$dist_uniform` → `rtl_dist_uniform`: an integer on the CLOSED range.
    try std.testing.expectEqual(@as(f64, 0), k.zRngIUniform(7, 0, 10));
    try std.testing.expectEqual(@as(f64, 1), k.zRngIUniform(7, 1, 6));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngIUniformNext(7, 0, 10));
    // The transcendental rows, each with its exact reference seed.
    try eps(@as(f64, 1.151634785351684), k.zRngNormal(7, 0.0, 1.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -1368524349), k.zRngNormalNext(7, 0.0, 1.0));
    try eps(@as(f64, 27.273600318905594), k.zRngExponential(7, 3.0), 1e-12);
    try std.testing.expectEqual(@as(f64, 483484), k.zRngExponentialNext(7, 3.0));
    try std.testing.expectEqual(@as(f64, 0), k.zRngPoisson(7, 3.0));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngPoissonNext(7, 3.0));
    try eps(@as(f64, 18.691952590208434), k.zRngChiSquare(7, 4.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -965981971), k.zRngChiSquareNext(7, 4.0));
    try eps(@as(f64, 0.53274261066788675), k.zRngT(7, 4.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -1368524349), k.zRngTNext(7, 4.0));
    try eps(@as(f64, 14.018964442656326), k.zRngErlang(7, 2.0, 3.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -965981971), k.zRngErlangNext(7, 2.0, 3.0));
    // §9.13.1's width sentence: "a 32-bit signed integer; it can be positive or
    // negative" — both signs occur along the reference stream, and every draw
    // stays inside the width.
    var neg = false;
    var pos = false;
    var sd: i64 = 1;
    for (0..64) |_| {
        const r = k.zRngRand(sd);
        try std.testing.expect(r >= -2147483648.0 and r <= 2147483647.0);
        try std.testing.expectEqual(r, @round(r));
        if (r < 0) neg = true else pos = true;
        sd = @intFromFloat(k.zRngRandNext(sd));
    }
    try std.testing.expect(neg and pos);
    // Repeatability (§9.13.2 "shall always return the same value given the same
    // seed") and finiteness for these particular seeds and ordinary parameters.
    // The family is not finite in general; the proof pass must stay conservative.
    for ([_]i64{ -2147483647, -7, 0, 1, 7, 42, 2147483646 }) |s| {
        try std.testing.expectEqual(k.zRngNext(s), k.zRngNext(s));
        try std.testing.expect(k.zRngNext(s) != @as(f64, @floatFromInt(s))); // inout: different
        try std.testing.expect(std.math.isFinite(k.zRngT(s, 4.0)));
        try std.testing.expect(std.math.isFinite(k.zRngNormal(s, 0.0, 1.0)));
        try std.testing.expect(std.math.isFinite(k.zRngChiSquare(s, 4.0)));
        try std.testing.expect(k.zRngPoisson(s, 3.0) >= 0.0);
    }
}

test "codegen: §9.5.4.2 the emitted scanner is the one the fixtures assert" {
    // The kernels are `@embedFile`d into every device, so the rows checked here
    // are byte-for-byte the code that runs there — the same arrangement
    // `filter_kernels.zig` has, and the reason both live in real Zig files.
    //
    // Every row below is a sentence of §9.5.4.2, and the numbers are the ones
    // tests/fixtures/ch09_system_tasks/{048,162,09,06} hold VerA to.
    const k = @import("kernels").str_kernels;
    // "the number of successfully matched and assigned input items is returned"
    try std.testing.expectEqual(@as(i64, 1), k.zScanN("42", "%d"));
    try std.testing.expectEqual(@as(i64, 42), k.zScanI("42", "%d", 0));
    // A suppressed field is consumed, takes no argument and is not counted.
    try std.testing.expectEqual(@as(i64, 1), k.zScanN("12 34", "%*d %d"));
    try std.testing.expectEqual(@as(i64, 34), k.zScanI("12 34", "%*d %d", 0));
    // "a decimal digit string that specifies an optional numerical maximum
    // field width" — the field ends there, even mid-number.
    try std.testing.expectEqual(@as(i64, 12), k.zScanI("12345", "%2d", 0));
    // "0 in the event of an early matching failure", and EOF (-1) when the
    // input ends before any conversion at all.
    try std.testing.expectEqual(@as(i64, 0), k.zScanN("hello", "%d"));
    try std.testing.expectEqual(@as(i64, -1), k.zScanN("", "%d"));
    // "%s Matches a string" then "%f ... Matches a floating point number".
    try std.testing.expectEqual(@as(i64, 2), k.zScanN("abc 5.5", "%s %f"));
    try std.testing.expectEqualStrings("abc", k.zScanS("abc 5.5", "%s %f", 0));
    try std.testing.expectEqual(@as(f64, 5.5), k.zScanR("abc 5.5", "%s %f", 1));
    // Literal text in the control string must match, and %e reads back what
    // §9.4.3's `%10.4e` wrote (09_string_formatting.va's round trip).
    const txt = try std.fmt.bufPrint(k.zSBuf(0), "value={e:>10.4}", .{0.5});
    try std.testing.expectEqual(@as(f64, 0.5), k.zScanR(txt, "value=%e", 0));
    try std.testing.expectEqual(@as(i64, 0), k.zScanN(txt, "other=%e"));
    // Two call sites, two scratch rows: §9.5.3 gives each writer its own string
    // variable, so one must not overwrite the other's bytes.
    const hex = try std.fmt.bufPrint(k.zSBuf(1), "{x}", .{@as(i64, 4096)});
    try std.testing.expectEqual(@as(i64, 1000), k.zScanI(hex, "%d", 0));
    try std.testing.expectEqualStrings("value= 5.0000e-1", txt);
}

test "codegen: §9.5 the emitted descriptors are the ones the fixtures assert" {
    // Same arrangement as the two above: the kernels are `@embedFile`d into the
    // printing artifact, so what runs here is byte-for-byte what runs there.
    //
    // Every claim below is a sentence of §9.5.1/§9.5.4/§9.5.5/§9.5.7/§9.5.8, and
    // the digits are the ones tests/fixtures/ch09_system_tasks/{07,046,049,050,
    // 051,053,054,158,11} hold VerA to.
    const k = @import("kernels").file_kernels;
    // The kernels resolve a path relative to the process cwd — which is exactly
    // what makes `ch09_047_missing.dat` a claim about a DIRECTORY, and why
    // tests/torture.zig runs each fixture in its own — so the name is what has to
    // be unique here.
    const path = ".zig-cache/vera-file-kernels-test.dat";
    const absent = ".zig-cache/vera-file-kernels-absent.dat";

    // §9.5.1 "the most significant bit (bit 31) of a fd is reserved and shall
    // always be set", and "three file descriptors are pre-opened ...
    // 32'h8000_0000, 32'h8000_0001, and 32'h8000_0002", so a fresh channel's
    // small number is greater than 2.
    const w = k.zFOpen(path, "w", false);
    try std.testing.expect(w & 2147483648 != 0);
    try std.testing.expect(w & 2147483647 > 2);
    // §9.5.2's output side at the byte level: four bytes in, four bytes out.
    try std.testing.expectEqual(@as(i64, 4), k.zFPut(w, "abc\n"));
    _ = k.zFClose(w);

    const r = k.zFOpen(path, "r", false);
    try std.testing.expect(r & 2147483648 != 0);
    // §9.5.5 "$ftell ... the offset from the beginning of the file of the current
    // byte" — 0 before any read.
    try std.testing.expectEqual(@as(i64, 0), k.zFTell(r));
    // §9.5.8 "returns zero otherwise": nothing has been read, so no EOF.
    try std.testing.expectEqual(@as(i64, 0), k.zFEof(r));
    // §9.5.4.1 "until a newline character is read AND TRANSFERRED to str ... the
    // number of characters read is returned in code" — 4, not the 3 a C `fgets`
    // minus its delimiter gives.
    try std.testing.expectEqual(@as(i64, 4), k.zFGets(r));
    try std.testing.expectEqualStrings("abc\n", k.zFLine(4, r));
    try std.testing.expectEqual(@as(i64, 4), k.zFTell(r));
    // The read that runs off the end is the one §9.5.8 promises a nonzero answer
    // for; the first need not have touched EOF.
    try std.testing.expectEqual(@as(i64, 0), k.zFGets(r));
    try std.testing.expect(k.zFEof(r) != 0);
    // §9.5.5 "$fseek ... 2 sets position to EOF plus offset", and the return is a
    // STATUS: "otherwise, code is set to 0".
    try std.testing.expectEqual(@as(i64, 0), k.zFSeek(r, 0, 2));
    try std.testing.expectEqual(@as(i64, 4), k.zFTell(r));
    // "$rewind is equivalent to $fseek (fd,0,0)" — in status and in effect.
    try std.testing.expectEqual(@as(i64, 0), k.zFSeek(r, 0, 0));
    try std.testing.expectEqual(@as(i64, 0), k.zFTell(r));
    // §9.5.7 "if the most recent operation did not result in an error, then the
    // value returned shall be zero, and the string variable str shall be empty".
    try std.testing.expectEqual(@as(i64, 0), k.zFError(r));
    try std.testing.expectEqualStrings("", k.zFErrorStr(0, r));
    _ = k.zFClose(r);

    // §9.5.1 "if a file cannot be opened (either the file does not exist and the
    // type specified is r ...) a zero is returned for the mcd or fd", and
    // "applications can call $ferror to determine the cause of the most recent
    // error".
    const bad = k.zFOpen(absent, "r", false);
    try std.testing.expectEqual(@as(i64, 0), bad);
    try std.testing.expect(k.zFError(bad) != 0);
    try std.testing.expect(k.zFErrorStr(k.zFError(bad), bad).len != 0);

    // §9.5.1's other overload: "the multichannel descriptor mcd is a 32-bit
    // integer in which a SINGLE BIT is set", bit 0 "always refers to the standard
    // output", and bit 31 "shall always be CLEARED".
    const mcd = k.zFOpen(path, "", true);
    try std.testing.expect(mcd & 2147483648 == 0);
    try std.testing.expect(mcd != 0 and mcd & (mcd - 1) == 0);
    try std.testing.expect(mcd != 1);
    _ = k.zFClose(mcd);
    // "The $fopen function shall reuse channels that have been closed."
    try std.testing.expectEqual(mcd, k.zFOpen(path, "", true));
    _ = k.zFClose(mcd);
}

test "codegen: §9.21 the emitted table interpolator is the one the fixtures assert" {
    const k = @import("kernels").table_kernels;
    // A one-derivative stand-in for the device's scalar: enough of the interface
    // `zTable` uses (`con`/`val`/`add`/`addC`/`scale`) to see the Jacobian, which
    // is the half of the answer no fixture can read.
    const S = struct {
        v: f64,
        d: f64 = 0.0,
        const T = @This();
        pub fn con(c: f64) T {
            return .{ .v = c };
        }
        pub fn val(a: T) f64 {
            return a.v;
        }
        pub fn add(a: T, b: T) T {
            return .{ .v = a.v + b.v, .d = a.d + b.d };
        }
        pub fn addC(a: T, c: f64) T {
            return .{ .v = a.v + c, .d = a.d };
        }
        pub fn scale(a: T, c: f64) T {
            return .{ .v = a.v * c, .d = a.d * c };
        }
    };
    // §9.21.1's printed sample set: f(x,y) = 0.5x + y on three isolines of y,
    // laid out `y x f(x,y)` — 12 rows of 3 columns, outermost-first. The same
    // twelve rows 155_table_model_lrm_sample_set.va and ch09_table_model_2d.tbl
    // carry.
    const rows = [_]f64{
        0.0, 1.0, 0.5, 0.0, 2.0, 1.0, 0.0, 3.0, 1.5,
        0.0, 4.0, 2.0, 0.0, 5.0, 2.5, 0.0, 6.0, 3.0,
        0.5, 1.0, 1.0, 0.5, 3.0, 2.0, 0.5, 5.0, 3.0,
        1.0, 1.0, 1.5, 1.0, 2.0, 2.0, 1.0, 4.0, 3.0,
    };
    // Figure 9-2's own lookup and its own answer: bracket y=0.25 by the 0.0/0.5
    // isolines, interpolate each at x=3.5 (1.75 and 2.25), interpolate those in
    // y. Every intermediate is dyadic, so this is exact.
    const f = k.zTable(S, 12, 3, 2, 2, "1LL1LL", rows, [_]S{ .{ .v = 0.25 }, .{ .v = 3.5, .d = 1.0 } });
    try std.testing.expectEqual(@as(f64, 2.0), f.v);
    // The scheme is piecewise linear and the samples lie on 0.5x + y, so ∂f/∂x
    // is 0.5 — the Jacobian entry a probe in the lookup slot owes the solver.
    try std.testing.expectEqual(@as(f64, 0.5), f.d);

    // §9.21.1 "if the user provides the data in random order the system will
    // sort the data into isolines in each dimension". Same table, rows reversed:
    // without the sort the isolines are shredded and the answer is quietly wrong.
    var back: [36]f64 = undefined;
    for (0..12) |r| for (0..3) |c| {
        back[r * 3 + c] = rows[(11 - r) * 3 + c];
    };
    const g = k.zTable(S, 12, 3, 2, 2, "1LL1LL", back, [_]S{ .{ .v = 0.25 }, .{ .v = 3.5 } });
    try std.testing.expectEqual(@as(f64, 2.0), g.v);

    // 131_table_model_array_control.va: one dimension, two samples on f(x) = 2x,
    // "1LL;1" — halfway between them.
    const line = [_]f64{ 1.0, 2.0, 3.0, 6.0 };
    const h1 = k.zTable(S, 2, 2, 1, 1, "1LL", line, [_]S{.{ .v = 2.0, .d = 1.0 }});
    try std.testing.expectEqual(@as(f64, 4.0), h1.v);
    try std.testing.expectEqual(@as(f64, 2.0), h1.d);
    // Table 9-31: linear extrapolation "extends linearly to the requested point
    // from the endpoint using a slope consistent with the selected interpolation
    // method" — so f(0) = 0 and f(5) = 10 off both ends…
    try std.testing.expectEqual(@as(f64, 0.0), k.zTable(S, 2, 2, 1, 1, "1LL", line, [_]S{.{ .v = 0.0 }}).v);
    try std.testing.expectEqual(@as(f64, 10.0), k.zTable(S, 2, 2, 1, 1, "1LL", line, [_]S{.{ .v = 5.0 }}).v);
    // …while constant extrapolation "returns the table endpoint value", and the
    // two ends are independent: `"CL"` clamps below 1.0 and still extrapolates
    // above 3.0. A swapped pair would pass every symmetric test there is.
    const cl = k.zTable(S, 2, 2, 1, 1, "1CL", line, [_]S{.{ .v = 0.0, .d = 1.0 }});
    try std.testing.expectEqual(@as(f64, 2.0), cl.v);
    try std.testing.expectEqual(@as(f64, 0.0), cl.d); // clamped ⇒ flat
    try std.testing.expectEqual(@as(f64, 10.0), k.zTable(S, 2, 2, 1, 1, "1CL", line, [_]S{.{ .v = 5.0 }}).v);
    try std.testing.expectEqual(@as(f64, 6.0), k.zTable(S, 2, 2, 1, 1, "1LC", line, [_]S{.{ .v = 5.0 }}).v);
    try std.testing.expectEqual(@as(f64, 0.0), k.zTable(S, 2, 2, 1, 1, "1LC", line, [_]S{.{ .v = 0.0 }}).v);
    // §9.21.2's dependent selector picks a COLUMN: two dependents over the same
    // isolines, and `;2` reads the second.
    const two = [_]f64{ 1.0, 2.0, 20.0, 3.0, 6.0, 60.0 };
    try std.testing.expectEqual(@as(f64, 4.0), k.zTable(S, 2, 3, 1, 1, "1LL", two, [_]S{.{ .v = 2.0 }}).v);
    try std.testing.expectEqual(@as(f64, 40.0), k.zTable(S, 2, 3, 1, 2, "1LL", two, [_]S{.{ .v = 2.0 }}).v);

    // Discrete lookup preserves the chosen value and has zero derivative.
    const discrete = [_]f64{ 3, 30, -1, 10, -3, -30, 1, 20 };
    for ([_]f64{ -10, -2, -1.25, 0.25, 2, 10 }, [_]f64{ -30, -30, 10, 20, 30, 30 }) |at, expected| {
        const picked = k.zTable(S, 4, 2, 1, 1, "DLL", discrete, [_]S{.{ .v = at, .d = 1 }});
        try std.testing.expectEqual(expected, picked.v);
        try std.testing.expectEqual(@as(f64, 0), picked.d);
    }
    const extreme = [_]f64{ -1.7e308, 4, -1.6e308, 8 };
    try std.testing.expectEqual(@as(f64, 8), k.zTable(S, 2, 2, 1, 1, "DCL", extreme, [_]S{.{ .v = 1.7e308 }}).v);
    // Different sample coordinates on each isoline; the selected outer line
    // contributes its inner gradient, while the discrete coordinate stays flat.
    const mixed = [_]f64{ -1, 0, 10, -1, 4, 18, 3, 1, 20, 3, 5, 32 };
    const outer_d = k.zTable(S, 4, 3, 2, 2, "DLL1LL", mixed, [_]S{ .{ .v = 1, .d = 1 }, .{ .v = 3 } });
    const inner_d = k.zTable(S, 4, 3, 2, 2, "DLL1LL", mixed, [_]S{ .{ .v = 1 }, .{ .v = 3, .d = 1 } });
    try std.testing.expectEqual(@as(f64, 26), outer_d.v);
    try std.testing.expectEqual(@as(f64, 0), outer_d.d);
    try std.testing.expectEqual(@as(f64, 3), inner_d.d);
    const outer_l = k.zTable(S, 4, 3, 2, 2, "1LLDLL", mixed, [_]S{ .{ .v = 0, .d = 1 }, .{ .v = 2, .d = 1 } });
    try std.testing.expectEqual(@as(f64, 18.5), outer_l.v);
    try std.testing.expectEqual(@as(f64, 0.5), outer_l.d);
}

test "codegen: §4.5.11 the bilinear transform is the one the emitted filter runs" {
    // `filter_kernels.zig` is `@embedFile`d, so — like the four kernels above —
    // what is exercised here is byte-for-byte what a device runs. It was the
    // tree's one file reachable by neither import graph AND by no test, which is
    // why this is characterization: a reviewer hand-checked D=2 and D=3 and found
    // the kernel correct, and these rows are that check made runnable.
    const k = @import("kernels").filter_kernels;
    // §4.5.11's trapezoidal substitution `s = k(1−z⁻¹)/(1+z⁻¹)`, cleared by
    // `(1+z⁻¹)ᴰ`. Multiplied out for D = 2 that is
    //   q₀ = p₀ + p₁k + p₂k², q₁ = 2p₀ − 2p₂k², q₂ = p₀ − p₁k + p₂k²,
    // and with p = [1,2,3], k = 2 every term is dyadic, so this is exact.
    const q2 = k.zBilin(2, .{ 1.0, 2.0, 3.0 }, 2.0);
    try std.testing.expectEqual([3]f64{ 17.0, -22.0, 9.0 }, q2);

    // The two evaluations of the transform that hold at EVERY degree, and the
    // reason a wrong sign in either inner loop cannot hide:
    //   z = 1  (z⁻¹ = 1)  ⇒ (1−z⁻¹) = 0, so only the i = 0 term lives: Σqⱼ = p₀·2ᴰ.
    //     That is DC gain, and it is what `zLaplace`'s `dt <= 0` arm computes the
    //     other way (`H(0) = num[0]/den[0]`); the two must agree or a filter's
    //     operating point disagrees with its first transient step.
    //   z = −1 (z⁻¹ = −1) ⇒ (1+z⁻¹) = 0, so only i = D lives: Σ(−1)ʲqⱼ = p_D·kᴰ·2ᴰ.
    const p3 = [4]f64{ 1.5, -2.0, 0.25, 4.0 };
    inline for (.{ 1.0, 2.0, 8.0 }) |kk| {
        const q3 = k.zBilin(3, p3, kk);
        var dc: f64 = 0.0;
        var ny: f64 = 0.0;
        for (q3, 0..) |c, j| {
            dc += c;
            ny += if (j % 2 == 0) c else -c;
        }
        try std.testing.expectApproxEqRel(p3[0] * 8.0, dc, 1e-12);
        try std.testing.expectApproxEqRel(p3[3] * kk * kk * kk * 8.0, ny, 1e-12);
    }
    // D = 0 is a bare gain: no substitution to make, nothing to clear.
    try std.testing.expectEqual([1]f64{7.0}, k.zBilin(0, .{7.0}, 3.0));
}

test "codegen: §4.5.15 the emitted limiters are the ones the annex E fixtures assert" {
    // `limit_kernels.zig` is `@embedFile`d into every device with an honoured
    // `$limit`, so the shapes pinned here are the shapes that run there. They
    // need pinning HERE and nowhere else: `tb.zig` generates calls to
    // `updateState`/`display`/`eval`/`q` only, so no fixture ever executes
    // `D.limit`, and until this file existed the limiters were a string literal
    // that nothing in the tree could call.
    //
    // §4.5.15 leaves the algorithm implementation-defined; what the LRM does fix
    // is §9.17.3's "when the simulator has converged, the return value of the
    // $limit() function is the value of the access function reference". Every
    // TRANSPARENCY row below is that sentence, and it is also what makes
    // `cg_limit.emitClamp`'s `if (vl != vn) ok = false;` a truthful convergence
    // flag rather than a permanent `false`. The rest are ngspice `devsup.c`.
    const k = @import("kernels").limit_kernels;
    const vt = 0.025852; // kT/q at 300 K, the `$vt` every junction model passes
    const vcrit = 0.6;

    // TRANSPARENCY. A bias below `vcrit` is returned BIT-identically — this is
    // the row `annex_e_spice/limit_pnj.va` asserts through the device.
    try std.testing.expectEqual(@as(f64, 0.3), k.zPnjlim(0.3, 0.3, vt, vcrit));
    // `DEVpnjlim` damps only past `vcrit` AND past a two-`vt` step; the damped
    // answer lands strictly between the two iterates, so the clamp pulls the
    // step back without reversing it. (0.6255 V here, but the bracket is the
    // claim: a sign slip in `vold ± vt*(2+log(…))` leaves it.)
    const damped = k.zPnjlim(1.0, 0.5, vt, vcrit);
    try std.testing.expect(damped > 0.5 and damped < 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6254615), damped, 1e-7);
    // Cold start: `vold <= 0` has no exponential to step back along, so the
    // answer is the logarithmic one, `vt*ln(vnew/vt)` — far below `vnew`.
    try std.testing.expectApproxEqAbs(@as(f64, 0.094499), k.zPnjlim(1.0, 0.0, vt, vcrit), 1e-6);
    // Reverse bias is FLOORED, and the two floors are different formulas:
    // `-vold-1` from a forward-biased previous iterate, `2*vold-1` from a
    // reverse-biased one. A swap passes at vold = -1 and nowhere else.
    try std.testing.expectEqual(@as(f64, -1.5), k.zPnjlim(-5.0, 0.5, vt, vcrit));
    try std.testing.expectEqual(@as(f64, -1.4), k.zPnjlim(-5.0, -0.2, vt, vcrit));
    try std.testing.expectEqual(@as(f64, -1.0), k.zPnjlim(-1.0, 0.5, vt, vcrit)); // above the floor: transparent

    // TRANSPARENCY, `limit_fet.va`'s digits exactly: vnew = vold = 0.3, vth = 0.7.
    try std.testing.expectEqual(@as(f64, 0.3), k.zFetlim(0.3, 0.3, 0.7));
    // `DEVfetlim` off-region (`vold < vto`): turning on stops at `vto+0.5`,
    // turning off steps by at most `vtsthi = |2(vold-vto)|+2` = 3.4 V here.
    try std.testing.expectEqual(@as(f64, 1.2), k.zFetlim(5.0, 0.0, 0.7));
    try std.testing.expectEqual(@as(f64, -3.4), k.zFetlim(-5.0, 0.0, 0.7));
    // Middle region (`vto <= vold < vto+3.5`): a window of `vto-0.5 … vto+4`.
    // (`vto ± c` is computed, not written, so these two are the only rows here
    // that cannot be spelled as an exact literal.)
    try std.testing.expectApproxEqAbs(@as(f64, 4.7), k.zFetlim(10.0, 1.0, 0.7), 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), k.zFetlim(-10.0, 1.0, 0.7), 1e-15);

    // TRANSPARENCY, `limit_vds.va`'s digits: 0.4 V from a cold 0 V is inside
    // both of `DEVlimvds`'s low-`vold` bounds (+4 rising, −0.5 falling).
    try std.testing.expectEqual(@as(f64, 0.4), k.zLimvds(0.4, 0.0));
    try std.testing.expectEqual(@as(f64, 4.0), k.zLimvds(10.0, 0.0));
    try std.testing.expectEqual(@as(f64, -0.5), k.zLimvds(-3.0, 0.0));
    // Past 3.5 V the bound becomes multiplicative going up (`3*vold+2`) and a
    // floor of 2 V coming down — the fixture header's "only a previous iterate
    // at or above 3.5 V would answer max(0.4, 2) = 2".
    try std.testing.expectEqual(@as(f64, 14.0), k.zLimvds(100.0, 4.0));
    try std.testing.expectEqual(@as(f64, 2.0), k.zLimvds(1.0, 4.0));
}

test "codegen: §4.5.15 signed $limit clamps sign*v and seeds sign*vcrit" {
    // The frame-sign extension: `$limit(V(a,b), "pnjlim", vt, vc, type)`.
    // devsup.c limiters assume forward = positive; a PNP passes type = -1 and
    // the emitted clamp must (1) run the kernel on sg·v, (2) hand back
    // sg·result, (3) seed the junction at sign·vcrit. The unsigned spelling
    // must stay byte-identical to what it was — no sg indirection.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  parameter real vt = 0.025852;
        \\  parameter real vc = 0.6;
        \\  parameter real type = -1.0;
        \\  analog I(mid, p) <+ ($limit(V(mid), "pnjlim", vt, vc, type) - V(p)) / 1.0;
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    // The ±1 is recovered ONCE per distinct sign at the top of `limit` and
    // each clamp aliases it — every clamp on a MOSFET reads the same latched
    // `type`, so re-spelling the compare per site cost 8 Ir per instance per
    // Newton iterate for an answer that cannot have changed between them.
    try std.testing.expect(std.mem.indexOf(u8, s, "const zsg__") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, " < 0) -1.0 else 1.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "const sg: f64 = zsg__") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "sg * zPnjlim(sg * vn, sg * vo") != null);
    // The live sets. The probe is `V(mid)` — mid against §1.3.1.1 ground, not
    // against the port — so `mid` (bit 1) is the only unknown either half
    // touches and `p` (bit 0) stays clear in both.
    try std.testing.expect(std.mem.indexOf(u8, s, "pub const limit_reads: u64 = 0x2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "pub const limit_writes: u64 = 0x2;") != null);
    // Seed picks the branch by the sign's runtime value.
    try std.testing.expect(std.mem.indexOf(u8, s, "s[@intFromEnum(U.mid)] = if (") != null);
    // Convergence verdict unchanged: pnjlim still reports through `ok`.
    try std.testing.expect(std.mem.indexOf(u8, s, "if (vl != vn) ok = false;") != null);

    // Unsigned control: no sg anywhere.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  parameter real vt = 0.025852;
        \\  parameter real vc = 0.6;
        \\  analog I(mid, p) <+ ($limit(V(mid), "pnjlim", vt, vc) - V(p)) / 1.0;
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s2, "sg") == null);
    try std.testing.expect(std.mem.indexOf(u8, s2, "zPnjlim(vn, vo") != null);
}

test "codegen: §4.5.15 a fetlimds pair + limvds emit ngspice's mode ladder" {
    // The mos-family frame swap (mos1load.c:351-373): both gate legs spelled
    // "fetlimds" plus a limvds on the channel emit ONE rung that branches on
    // the sign of the OLD vds, fetlims only the controlling leg, and gives
    // limvds mode-dependent write targets — `di` in normal mode (vgs is
    // preserved, vgd derived), `si` in inverse mode (`vds =
    // -DEVlimvds(-vds,-vdso)`, vgd preserved, vgs derived).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(g, d, s);
        \\  inout g, d, s; electrical g, d, s, di, si;
        \\  parameter real vto = 0.7;
        \\  parameter real type = -1.0;
        \\  real vgs, vgd, vds;
        \\  analog begin
        \\    vgs = type * $limit(V(g, si), "fetlimds", type * vto, type);
        \\    vgd = type * $limit(V(g, di), "fetlimds", type * vto, type);
        \\    vds = type * $limit(V(di, si), "limvds", type);
        \\    I(d, di) <+ (V(d) - V(di)) / 10.0;
        \\    I(s, si) <+ (V(s) - V(si)) / 10.0;
        \\    I(di, si) <+ 1e-3 * (vgs + vgd + vds);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    // The branch condition is the limiter's own memory, in the device frame.
    try std.testing.expect(std.mem.indexOf(u8, s, "const vdso = old[@intFromEnum(U.di)] - old[@intFromEnum(U.si)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "if (sgt * vdso >= 0.0) {") != null);
    // Normal arm: +frame limvds, correction to the drain side.
    try std.testing.expect(std.mem.indexOf(u8, s, "const dl = sgt * zLimvds(sgt * dn, sgt * vdso);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "x[@intFromEnum(U.di)] += dl - dn;") != null);
    // Inverse arm: −frame limvds, correction to the source side.
    try std.testing.expect(std.mem.indexOf(u8, s, "const dl = -sgt * zLimvds(-sgt * dn, -sgt * vdso);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "x[@intFromEnum(U.si)] -= dl - dn;") != null);
    // The limvds site is CLAIMED by the ladder — no standalone clamp shape.
    try std.testing.expect(std.mem.indexOf(u8, s, "zLimvds(sg * vn") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "zLimvds(vn, vo") == null);

    // A dangling fetlimds (no second leg, no limvds) is declined whole, not
    // half-honoured as a static clamp — that would be the bug back again.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m2(g, s);
        \\  inout g, s; electrical g, s, si;
        \\  parameter real vto = 0.7;
        \\  analog I(si, s) <+ ($limit(V(g, si), "fetlimds", vto) - V(s)) / 1.0;
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s2, "no complete mode ladder") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2, "pub fn limit(") == null);
}

test "codegen: cross-fed held state emits stateCtl with accepted twins" {
    // The hysteresis-FSM hook (contract.zig StateCtlOp): a module whose held
    // state is written from cross edges gets stateCtl + accepted-copy twins,
    // so the transient can land its conductance flip sharp. A held variable
    // fed only by a timer does NOT — breakpoints already place those edges.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sw(p, n, c);
        \\  inout p, n, c; electrical p, n, c;
        \\  integer latched;
        \\  analog begin
        \\    @(cross(V(c) - 0.5, +1)) latched = 1;
        \\    @(cross(V(c) - 0.5, -1)) latched = 0;
        \\    I(p, n) <+ ((latched > 0) ? 1.0 : 1.0e-9) * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s, "pub fn stateCtl(") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "__held__latched__acc") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "__prev__acc = inst.") != null);

    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tmr(p, n);
        \\  inout p, n; electrical p, n;
        \\  integer armed;
        \\  analog begin
        \\    @(timer(1n)) armed = 1;
        \\    I(p, n) <+ ((armed > 0) ? 1.0 : 1.0e-9) * V(p, n);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s2, "stateCtl") == null);
    try std.testing.expect(std.mem.indexOf(u8, s2, "__acc") == null);
}

test "codegen: a $prev-only model still gets latch staging and commit" {
    // `$prev` plants a path_prev site with NO path_acc sibling (the reactive
    // lowering always pairs them, a source site arrives alone), so every gate
    // on the latch machinery must key on pathLatches(), not acc_lo — this is
    // the model that fails silently (pb__ stuck at 0.0) if one reverts.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module avg(p, n);
        \\  inout p, n; electrical p, n;
        \\  real g;
        \\  analog begin
        \\    g = 1.0 + 0.1 * V(p, n);
        \\    I(p, n) <+ 0.5 * (g + $prev(g)) * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s, "S.con(inst.pb__0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "inst.wb__0 = ") != null); // updateState stages
    try std.testing.expect(std.mem.indexOf(u8, s, "inst.pb__0 = inst.wb__0;") != null); // commit latches
    try std.testing.expect(std.mem.indexOf(u8, s, "pub fn stateCtl(") != null);

    // $prev of a value with no unknown dependence is the value itself — no
    // latch, no hook, byte-identical to writing the parameter.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module k(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real c = 2.0;
        \\  analog I(p, n) <+ $prev(c) * V(p, n);
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s2, "pb__") == null);
    try std.testing.expect(std.mem.indexOf(u8, s2, "stateCtl") == null);
}

test "codegen: every .val()-collapsing helper is on the lane-pin ledger" {
    // The `lane_clean` promise is only as good as its pins, and the pins are
    // hand-placed at emission sites — fixture 158 (zPow) proved a forgotten
    // one ships a false promise. This binds the two mechanically: any helper
    // in the emitted math/ops templates whose BODY reads `.val(` must appear
    // here, and adding one without deciding its pin fails this test, not a
    // customer's batch run. A helper is on the ledger either because its
    // emission site calls `pinLanes` (see each site's comment) or because it
    // steers only on lane-UNIFORM state (dt, ic, inst history — never x).
    const pinned = [_][]const u8{
        "zPow",   "zHypot",  "zFmod", "zFloor",   "zCeil",
        "zAtan2", "zLimexp", "zWrap", "zLimitUf",
    };
    const uniform = [_][]const u8{
        "zDdt",        "zIdt",      "zIdtAcc", "zIdtmod", "zSlew", "zTransFrac",
        "zTransition", "zAbsdelay", "zLog10",  "zTan",    "zAsin", "zAcos",
        "zAsinh",      "zAcosh",    "zAtanh",  "zPadInt",
    };
    const text = gen_kernel_text.math_txt ++ gen_kernel_text.ops_txt;
    var it = std.mem.splitSequence(u8, text, "\nfn ");
    _ = it.first(); // preamble before the first helper
    while (it.next()) |chunk| {
        const paren = std.mem.indexOfScalar(u8, chunk, '(') orelse continue;
        const fn_name = chunk[0..paren];
        // Body = up to the next helper (the split already bounded it).
        if (std.mem.indexOf(u8, chunk, ".val(") == null) continue;
        for (pinned) |p| {
            if (std.mem.eql(u8, fn_name, p)) break;
        } else for (uniform) |u| {
            if (std.mem.eql(u8, fn_name, u)) break;
        } else {
            std.debug.print("helper `{s}` reads .val() but is on neither ledger\n", .{fn_name});
            return error.TestUnexpectedResult;
        }
    }
}

test "codegen: §4.5.15 only pnjlim reports non-convergence" {
    // The kernels above are pure functions; this pins the one line of
    // `cg_limit.emitClamp` that turns `zPnjlim`'s transparency into the
    // contract's `converged` verdict. ngspice sets `icheck` from `DEVpnjlim`
    // alone, and exactly on the paths where it moved `vnew` — so "the value
    // changed" IS the flag. Nothing executes `D.limit` (see the test above), so
    // the emitted text is the only place this claim is visible.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  parameter real vt = 0.025852;
        \\  parameter real vc = 0.6;
        \\  analog I(mid, p) <+ ($limit(V(mid), "pnjlim", vt, vc) - V(p)) / 1.0;
        \\endmodule
    , &h);
    defer h.deinit();
    const pnj = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, pnj, "if (vl != vn) ok = false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, pnj, ".converged = ok }") != null);

    // fetlim clamps too, but its clamp is trajectory shaping and not a statement
    // about the residual — so the device reports converged and carries no `ok`
    // at all. An unconditional `var ok` would be an unused-variable compile
    // error in the emitted device, which no fixture would ever reach.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  analog I(mid, p) <+ ($limit(V(mid), "fetlim", 0.7) - V(p)) / 1.0;
        \\endmodule
    , &h2);
    defer h2.deinit();
    const fet = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, fet, "zFetlim(") != null);
    try std.testing.expect(std.mem.indexOf(u8, fet, "var ok = true;") == null);
    try std.testing.expect(std.mem.indexOf(u8, fet, "vl != vn") == null);
    try std.testing.expect(std.mem.indexOf(u8, fet, ".converged = true }") != null);
}

test "codegen: declared integer conversions reach real field initializers" {
    // Fixture execution calls derive(); these assertions also cover Model{}
    // before derivation, so correct derive code cannot hide an incorrect seed.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module converted(p);
        \\  inout p; electrical p;
        \\  parameter integer a = 4294967297.0;
        \\  parameter real b = a / 2;
        \\  parameter integer aa[1:0] = '{4294967297.0,4294967299.0};
        \\  parameter real c = aa[1] / 2;
        \\  parameter real d = aa[0] / 2;
        \\  analog I(p) <+ (b+c+d) * V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    const generated = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, generated, "b: f64 = 0.0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "c: f64 = 0.0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "d: f64 = 1.0,") != null);
}

test "codegen: unused distributions retain validation without forcing draw loops" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p,n);
        \\  inout p,n; electrical p,n;
        \\  integer seed;
        \\  real unused;
        \\  analog begin
        \\    seed = 7;
        \\    unused = $rdist_chi_square(seed,2147483647);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // The draw functions are defined, but an unused variate and seed do not
    // introduce a billion-iteration draw. Only the required check is invoked.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "zRngChiSquare("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "zRngChiSquareNext("));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "zRngCheck("));
}

test "codegen: §3.6.3.2 a net initializer is exported as a nodeset, not as a value" {
    // The clause's own first example, `electrical a = 5.0;`, plus the two
    // spellings it does not print: the initializer on a net that is also a
    // module PORT, and one written over a parameter (§3.4 makes a parameter
    // reference a constant_expression, so `= vstart` is legal).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ns(p, n);
        \\  inout p, n;
        \\  electrical p = 1.5, n;
        \\  parameter real vstart = 2.25;
        \\  electrical mid = vstart;
        \\  analog begin
        \\    I(p, mid) <+ V(p, mid);
        \\    I(mid, n) <+ V(mid, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // One optional table over U, in U's order: port `p`, port `n`, net `mid`.
    // `n` is null and not 0.0 — "a null value ... indicates that no nodeset
    // value is being specified", and a host must be able to tell the two apart.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const u_nodeset = [n_u]?f64{\n    1.5,\n    null,\n    2.25,\n};") != null);

    // A NODESET, so nothing in the residual may read it: `eval` is a function
    // of x alone, and a starting point that leaked into it would be a clamp.
    const at = std.mem.indexOf(u8, src, "pub fn eval(").?;
    try std.testing.expect(std.mem.indexOf(u8, src[at..], "u_nodeset") == null);
}

test "codegen: §3.6.3.2 a module with no net initializer exports no nodeset table" {
    // The decl is OPTIONAL and its absence is the answer "this module states no
    // opinion" — a table of nulls would say the same thing in more bytes and
    // would move every existing device's emitted source.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module plain(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ V(p, n);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "u_nodeset") == null);
}

test "codegen: the hoisted prefix is latched through P, the host's value chain" {
    // eval reads the latch back as `S.con(inst.hp[k])`, so it must hold what
    // the host's S would have computed: `P`'s a*(1/b), not `R`'s a/b. Filled
    // through R, mos3 had 2 of 512 residuals 1 ulp off the un-latched Dual.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module pg(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real gain = 1.0;
        \\  analog I(p,n) <+ ($param_given(gain) ? gain : 0.0) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "inst.hp_ok = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const mh = core(P, xp, model, inst);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const P = struct {") != null);
}
