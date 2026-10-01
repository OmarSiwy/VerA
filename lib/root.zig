//! The compiler's module index and pipeline driver: Verilog-A source text in,
//! MIR and a generated `device.zig` out (preprocess, lex, parse, lower, prove,
//! codegen). Re-exports each stage and owns `CompileResult`, the root every
//! per-compilation allocation hangs off. `build.zig`'s `module_specs` makes
//! `lib/` a dependency of `src/`, never the reverse.

const std = @import("std");
pub const BigArena = @import("big_arena.zig");
const Allocator = std.mem.Allocator;

const token = @import("frontend").token;
pub const Preprocessor = @import("frontend").Preprocessor;
pub const libmap = @import("frontend").libmap;
const Lexer = @import("frontend").Lexer;
const Ast = @import("frontend").Ast;
const Parser = @import("frontend").Parser;
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Ssa = @import("ir").Ssa;
const Elaborate = @import("ir").Elaborate;
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
/// A `--param name=value` compile-time override (`Options.param_overrides`, LRM §3.4).
pub const ParamOverride = Lower.ParamOverride;
pub const KeywordSet = token.KeywordSet;
const ifconv = @import("ir").ifconv;
const proof = @import("ir").proof;
pub const diag = @import("diag");
const naming = @import("backend").naming;
pub const codegen = @import("backend").codegen;
const UnitPlan = @import("backend").UnitPlan;
const cg_display = @import("backend").cg_display;
const cg_filters = @import("backend").cg_filters;
pub const orchestrator = @import("backend").orchestrator;
pub const tb = @import("backend").tb;

/// How far the pipeline runs. The Zig optimize mode and backend are
/// `orchestrator.Options.optimize` and `.backend`, set independently.
pub const Target = enum {
    /// Parse, lower and run the finiteness proof, then report diagnostics.
    /// No codegen and no `zig` child process.
    lint,
    /// Through codegen; `buildArtifact` can make a `.so`.
    build,
};

/// Failures of `compileSource` and `CompileResult.generateDevice`.
pub const Error = codegen.Error || error{
    /// One or more stages reported diagnostics. They are in the caller's
    /// `Options.diags` when one was supplied.
    CompileFailed,
    /// The source declared no `module` (LRM §6.2).
    NoModule,
    /// `.lint` produces no artifact by definition.
    NoArtifact,
};

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

/// Settings for one `compileSourceOpts` call.
pub const Options = struct {
    /// The name diagnostics print for the top-level source.
    file_name: []const u8 = "<source>",
    /// Searched in order for `include, ahead of the built-in annex D files.
    include_dirs: []const []const u8 = &.{},
    /// §3.4 compile-time values for the top module's parameters (`--param`).
    /// A shape parameter (`Lower.ParamInfo.shape`) is compiled to this value
    /// and its card may not move it; any other stays a run-time card value
    /// whose default this replaces.
    param_overrides: []const Lower.ParamOverride = &.{},
    /// Prepend annex D.2 constants.vams + annex D.1 disciplines.vams (§3.6.2).
    std_defs: bool = true,
    /// The source language, `vera --std=`. See `Parser.setLanguage`.
    language: KeywordSet = token.default_keyword_set,
    /// Receives every diagnostic of the run, errors and warnings, so a
    /// successful compilation may still fill it (W0650, the finiteness
    /// warning). Detached from the compilation arena before the call returns,
    /// so it stays valid after the `CompileResult` is freed; the caller must
    /// `deinit(gpa)` it.
    diags: ?*diag.Bag = null,
    /// Per-code lint levels (`--allow=W0650`, `--deny=W0651`). An error
    /// code cannot be allowed away; see `diag.Levels.set`.
    lint: diag.Levels = .empty,
    /// Class-6 knobs (solver compliance bound, overflow model). See proof.zig.
    proof: proof.Options = .{},
    /// SPICE netlist text (annex E.2) whose `.MODEL` and `.SUBCKT` cards this
    /// compilation may resolve module names against (E.1.1's antecedent: "if a
    /// simulator ... is also able to read SPICE netlists"). One card per line,
    /// `+` continuations included; see `spice_cards.synthesize` for the subset
    /// that is read. Empty is the default and reads nothing.
    spice_netlist: []const u8 = "",
    /// What to do with the model's display tasks (LRM §9.4). `.drop` makes a
    /// device: no text and no syscall in the Newton loop, with a W0850 for each
    /// dropped task. `.emit` makes an executable whose prints are the output.
    /// See `codegen.Display`.
    display: codegen.Display = .drop,
    /// Emits `pub const jac_f32 = true`: the device tolerates a host scalar S
    /// whose derivative half is single precision. See `codegen.Options.jac_f32`.
    jac_f32: bool = false,
    /// Also emits `pub const jac_f32_host = true`: the host should take that
    /// permission on its CPU instantiation, not only where f32 is free. Implies
    /// `jac_f32`. See `codegen.Options.jac_f32_host`.
    jac_f32_host: bool = false,
    /// Also emits `vpiContribs`, the §5.6 contribution rows a Clause 12
    /// analog host reads. See `codegen.Options.vpi_contribs`.
    vpi_contribs: bool = false,
};

// ---------------------------------------------------------------------------
// CompileResult
// ---------------------------------------------------------------------------

/// The output of one compilation: source to MIR, and optionally to device.zig.
///
/// Owns every allocation of the run. Preprocessed text, tokens, AST, MIR and
/// lowering's tables live in `arena`, a `BigArena`: its large tables are the
/// gpa's own blocks, grown in place and freed with it. Only `verdict.unit_modes` and
/// `device.text` are gpa-owned (the device text can reach hundreds of
/// megabytes, and an arena cannot grow a buffer in place). `deinit` frees all
/// three. The value is freely movable.
pub const CompileResult = struct {
    gpa: Allocator,
    // Heap-allocated because the AST stores and `Ssa.SsaBuilder` hold an
    // `Allocator` whose `ptr` is this arena's address: moving it by
    // value would dangle them.
    arena: *BigArena,
    /// Preprocessed source (arena). Every AST/MIR string borrows from it.
    source: []const u8,
    mir: *Mir,
    /// Lowering's output. The `Lower` that built it is gone: nothing after
    /// stage 4 can reach a symbol table, a scope or the SSA builder.
    lowered: *const Lowered,
    /// Its `unit_modes` slice is gpa-owned.
    verdict: proof.Verdict,
    target: Target,
    /// Codegen output; empty until `generateOutput` runs, which `.lint` never
    /// does. `text` is gpa-owned and freed by `deinit`; consumers borrow it.
    /// `names`, `unit_lo` and `unit_hi` are the per-unit file map the
    /// orchestrator writes (see `codegen.Output`).
    device: codegen.Output = .{ .text = "" },
    /// Whether codegen refused any construct, including metadata failures
    /// without an `@compileError` unit. Callers must not consume failed output.
    device_has_compile_error: bool = false,
    /// Settings that change what codegen generates.
    codegen_opts: codegen.Options = .{},

    /// Frees the arena and the two gpa-owned buffers; invalidates every slice
    /// borrowed from the result.
    pub fn deinit(self: *CompileResult) void {
        self.gpa.free(self.device.text);
        self.verdict.deinit(self.gpa);
        freeArena(self.gpa, self.arena);
        self.* = undefined;
    }

    /// Runs codegen and returns the device text. Idempotent: the text is
    /// cached on the result, so a second call costs nothing. The slice lives
    /// until `deinit`.
    pub fn generateDevice(self: *CompileResult) codegen.Error![]const u8 {
        return (try self.generateOutput()).text;
    }

    /// Runs codegen (once, as `generateDevice`) and returns the text with the
    /// per-unit file map the orchestrator needs.
    pub fn generateOutput(self: *CompileResult) codegen.Error!codegen.Output {
        if (self.device.text.len == 0) {
            self.device = try codegen.generate(
                self.gpa,
                self.arena.allocator(),
                self.mir,
                self.lowered,
                self.verdict,
                &self.device_has_compile_error,
                self.codegen_opts,
            );
        }
        return self.device;
    }
};

// ---------------------------------------------------------------------------
// Compilation
// ---------------------------------------------------------------------------

/// Compiles `source` to MIR with default `Options`: preprocess, lex, parse,
/// lower and prove. For `.lint` this is the whole job. The caller must
/// `deinit` the result.
pub fn compileSource(gpa: Allocator, source: []const u8, target: Target) Error!CompileResult {
    return compileSourceOpts(gpa, source, target, .{});
}

/// `compileSource` with explicit settings. When `opts.diags` is set it
/// receives every diagnostic even on failure, and the caller must
/// `deinit(gpa)` it. Fails with `error.CompileFailed` when a `--deny`
/// promoted a warning, even if every stage succeeded.
pub fn compileSourceOpts(
    gpa: Allocator,
    source: []const u8,
    target: Target,
    opts: Options,
) Error!CompileResult {
    const arena_state = try gpa.create(BigArena);
    arena_state.* = .init(gpa);

    var bag = diag.Bag.init(arena_state.allocator());
    bag.levels = opts.lint;

    const result = compileInArena(gpa, arena_state, source, target, opts, &bag);

    // A `--deny`ed warning is an error, so a compilation that only tripped one
    // still fails. Read before detaching, which moves the bag out.
    const denied = bag.failed();

    // The bag's messages, labels and file texts live in the compilation arena,
    // so they are copied out before the arena can be freed. This is why no
    // stage frees the arena on error.
    if (opts.diags) |out| {
        bag.detach(gpa) catch |err| {
            if (result) |r| {
                var ok = r;
                ok.deinit();
            } else |_| freeArena(gpa, arena_state);
            return err;
        };
        out.* = bag;
    }

    var ok = result catch |err| {
        freeArena(gpa, arena_state);
        return err;
    };
    if (denied) {
        ok.deinit();
        return error.CompileFailed;
    }
    return ok;
}

/// Runs every stage through the proof. Never frees `arena_state`: on success
/// it goes to the `CompileResult`, on failure the caller frees it once the bag
/// is detached.
fn compileInArena(
    gpa: Allocator,
    arena_state: *BigArena,
    source: []const u8,
    target: Target,
    opts: Options,
    bag: *diag.Bag,
) Error!CompileResult {
    const arena = arena_state.allocator();
    const pp = Preprocessor.process(arena, source, .{
        .include_dirs = opts.include_dirs,
        .file_name = opts.file_name,
        .std_defs = opts.std_defs,
        .spice_netlist = opts.spice_netlist,
        .bag = bag,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The message is already in the bag with its own file and span: the
        // preprocessor registers every file it opens, so a failure inside an
        // `include names that header rather than the top-level unit.
        error.PreprocessFailed => return error.CompileFailed,
    };
    const text = pp.text;
    const netlist_modules = pp.netlist_modules;

    // The annex D.2/D.1/E.1 prelude is a fixed byte prefix of `text` whenever
    // `std_defs` is on, so its tokens are lexed once per process and copied in
    // (`Preprocessor.preludeTokens`). Re-lexing it dominated a small `.lint`.
    var tokens = try Lexer.Lexer.tokenizeSeeded(arena, text, try Preprocessor.preludeTokens(opts.std_defs));
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);

    // Likewise the prelude's AST is parsed once per process and parsing resumes
    // at the token after it; `Preprocessor.preludeAst` carries the soundness
    // argument. Both seeds come from one snapshot gated on the same
    // `std_defs`, so `tags` begins with the prelude's tokens here too.
    var p = try Parser.Parser.initSeeded(arena, text, tags, starts, bag, try Preprocessor.preludeAst(opts.std_defs));
    p.setLanguage(opts.language);
    const file = try arena.create(Ast.SourceFile);
    // The Table E.1 primitives (annex E) are the first declarations in `text`,
    // and the annex E.2 netlist modules follow them before the user's source,
    // so together they lead `file.modules`. This is the one place that knows
    // whether the prelude was prepended; see `Ast.SourceFile.builtin_modules`.
    const builtins: u32 = if (opts.std_defs) Preprocessor.spice_module_count + netlist_modules else 0;
    file.* = p.parseSourceFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => {
            // The parser recovers at top level, so a diagnosed parse still
            // tells whether a §6.2 `module` was found. When none was (the file
            // held only `library`, `primitive`, `paramset` or `connectrules`),
            // NoModule is what the caller acts on; the reason is in the bag.
            // Prelude modules do not count.
            //
            // `connectmodule` and `macromodule` are A.1.2 `module_keyword`
            // alternatives and land in `file.modules`. A file of only connect
            // modules gets NoModule later, from `elaborate.pickTop` (§7.6).
            if (p.file.modules.len <= builtins) return error.NoModule;
            return error.CompileFailed;
        },
    };
    file.builtin_modules = builtins;
    file.netlist_modules = netlist_modules;
    // §3.7/§6.5.3 wreal structure rules. The digital runner calls the same
    // check, so both routes refuse the same wirings.
    try @import("frontend").wreal.check(file, starts, bag);
    if (bag.failed()) return error.CompileFailed;

    const mir = try arena.create(Mir);
    mir.* = .{};
    const lowered = try arena.create(Lowered);
    lowered.* = Lower.lower(arena, mir, file, text, starts, bag, .{
        .directives = pp.directives,
        .include_dirs = opts.include_dirs, // §9.21.1 a $table_model data file
        .param_overrides = opts.param_overrides, // §3.4 `--param`
        .displays_dropped = opts.display == .drop, // §3.2 retention, see `Exposed`
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoModule => {
            try bag.add(.lower, .E1001, .{}, "", .{});
            return error.NoModule;
        },
        error.DiagnosticsReported => return error.CompileFailed,
    };

    // §3.2: drop the held slots no card can observe. Runs before ifconv,
    // whose selects would hide the merges it reads. See `codegen.pruneHeld`.
    try codegen.pruneHeld(arena, mir, lowered);

    // If-convert pure diamonds to §4.2.12 selects before the proof: a
    // select's guard facts come from markSelectArms, so the proof sees the
    // evidence the CFG edge carried and codegen can emit proven-total
    // conditionals as `S.sel`. Arena, because ifconv appends to MIR tables.
    _ = try ifconv.run(arena, mir);

    // The proof gates every target and is the source of the W0650 finiteness
    // warning, which is why `.lint` runs it too.
    const verdict = try proof.proveOpts(gpa, mir, lowered, opts.proof, bag);
    errdefer verdict.deinit(gpa);
    // §4.3.2: a domain violation is a compile error on every target.
    if (!verdict.ok()) return error.CompileFailed;

    // §9.4/§9.5. Reported here, not in lowering, because whether a side effect
    // is kept depends on what the caller asked to build. The model is legal
    // either way, so these are warnings.
    for (lowered.displays.items) |d| {
        const span = lowered.tokenSpan(d.tok);
        if (opts.display == .drop) {
            // A §9.5 file task is kept for sequencing, not text; its answer is
            // §9.5.1's zero descriptor rather than a dropped print.
            if (Mir.callee.isFileCall(.fromName(d.name)))
                try bag.add(.lower, .W0850, span, "`{s}` — a device has no host file table, so §9.5.1's zero descriptor is the answer", .{d.name})
            else
                try bag.add(.lower, .W0850, span, "`{s}`", .{d.name});
        }
    }

    return .{
        .gpa = gpa,
        .arena = arena_state,
        .source = text,
        .mir = mir,
        .lowered = lowered,
        .verdict = verdict,
        .target = target,
        // `opts.diags`, not this bag: codegen runs after compileSourceOpts
        // detached the messages, so the caller's bag is the only one alive
        // when E0515 is raised.
        .codegen_opts = .{
            .display = opts.display,
            .jac_f32 = opts.jac_f32,
            .jac_f32_host = opts.jac_f32_host,
            .vpi_contribs = opts.vpi_contribs,
            .diags = opts.diags,
        },
    };
}

// ---------------------------------------------------------------------------
// Artifact build
// ---------------------------------------------------------------------------

/// Generates the device and builds it cold into a shared library
/// (`orchestrator.compileRelease`). The host owns loading it and all
/// simulation state. Fails with `error.NoArtifact` on a `.lint` result.
pub fn buildArtifact(
    gpa: Allocator,
    io: std.Io,
    result: *CompileResult,
    o: orchestrator.Options,
    generation: u32,
    // Inferred error set: the orchestrator's failures are the open-ended OS
    // errors of a child process and its pipe.
) !orchestrator.Result {
    if (result.target == .lint) return error.NoArtifact;
    return orchestrator.compileRelease(gpa, io, o, try result.generateOutput(), generation);
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn freeArena(gpa: Allocator, a: *BigArena) void {
    a.deinit();
    gpa.destroy(a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_resistor =
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0.0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
;

test "lint: source → MIR, arena freed clean" {
    var res = try compileSource(std.testing.allocator, test_resistor, .lint);
    defer res.deinit();

    try std.testing.expectEqualStrings("res", res.mir.name);
    try std.testing.expectEqual(@as(u16, 2), res.lowered.num_ports);
    try std.testing.expect(res.verdict.ok());
    try std.testing.expectEqual(proof.unitCount(res.lowered), res.verdict.unit_modes.len);
}

test "IEEE 1364 §19.1 cell membership survives the preprocessor" {
    // The module's cell tag survives after the directives are gone from the
    // text. No fixture can check this: §19.1 tags a module and changes no
    // value a model can print.
    const gpa = std.testing.allocator;
    {
        var res = try compileSource(gpa, "`celldefine\n" ++ test_resistor ++ "\n`endcelldefine\n", .lint);
        defer res.deinit();
        try std.testing.expect(res.mir.is_cell);
    }
    {
        var res = try compileSource(gpa, test_resistor, .lint);
        defer res.deinit();
        try std.testing.expect(!res.mir.is_cell);
    }
    {
        // §10.1 scope: the region ends at the closing directive, so a module
        // below `endcelldefine is not a cell.
        var res = try compileSource(gpa, "`celldefine\n`endcelldefine\n" ++ test_resistor, .lint);
        defer res.deinit();
        try std.testing.expect(!res.mir.is_cell);
    }
}

test "diagnostics outlive the compilation arena" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    try std.testing.expectError(error.CompileFailed, compileSourceOpts(
        gpa,
        "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n",
        .lint,
        .{ .diags = &bag },
    ));
    // The arena is gone by now; reading the messages must still be valid.
    try std.testing.expect(!bag.isEmpty());
    try std.testing.expect(bag.failed());
    for (0..bag.count()) |i| try std.testing.expect(diag.info(bag.at(i).code).title.len != 0);

    // So must rendering, which reads the file text the bag detached.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try diag.render(&bag, &aw.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "-->") != null);
}

fn compileBadWithDiags(gpa: Allocator) !void {
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    const src = "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n";
    _ = compileSourceOpts(gpa, src, .lint, .{ .diags = &bag }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    return error.TestUnexpectedResult;
}

test "an allocation failure while detaching diagnostics leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileBadWithDiags, .{});
}

test "a clean compilation reports no diagnostics but still hands back the bag" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    var res = try compileSourceOpts(
        gpa,
        "module r(p, n); inout p, n; electrical p, n;\n" ++
            "  parameter real rs = 1.0 from (0:inf);\n" ++
            "  analog I(p, n) <+ V(p, n) / rs;\n" ++
            "endmodule\n",
        .lint,
        .{ .diags = &bag },
    );
    defer res.deinit();
    try std.testing.expect(!bag.failed());
    // A fully-ranged resistor is provably finite, so not even W0650 fires.
    try std.testing.expect(bag.isEmpty());
    try std.testing.expectEqual(proof.FloatMode.optimized, res.verdict.unit_modes[0]);
}

test "lint levels: --deny promotes a warning into a hard failure" {
    const gpa = std.testing.allocator;
    const src =
        \\module amp(a, c); inout a, c; electrical a, c;
        \\  analog I(a, c) <+ exp(V(a, c));
        \\endmodule
        \\
    ;

    // Default: W0650 fires, but a warning does not fail a compilation.
    {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var res = try compileSourceOpts(gpa, src, .lint, .{ .diags = &bag });
        defer res.deinit();
        try std.testing.expect(!bag.failed());
        try std.testing.expectEqual(@as(u32, 1), bag.warn_count);
    }

    // --deny=W0650: same diagnostic, now an error, and the compile fails.
    {
        var levels: diag.Levels = .empty;
        defer levels.deinit(gpa);
        try levels.set(gpa, .W0650, .deny);

        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        try std.testing.expectError(error.CompileFailed, compileSourceOpts(
            gpa,
            src,
            .lint,
            .{ .diags = &bag, .lint = levels },
        ));
        try std.testing.expect(bag.failed());
        try std.testing.expectEqual(@as(u32, 1), bag.err_count);
    }

    // --allow=W0650: not collected at all, and still a clean compile.
    {
        var levels: diag.Levels = .empty;
        defer levels.deinit(gpa);
        try levels.set(gpa, .W0650, .allow);

        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var res = try compileSourceOpts(gpa, src, .lint, .{ .diags = &bag, .lint = levels });
        defer res.deinit();
        try std.testing.expect(bag.isEmpty());
        // Silencing the lint does not change the generated code.
        try std.testing.expectEqual(proof.FloatMode.strict, res.verdict.unit_modes[0]);
    }
}

test "determinism: a no-op recompile reproduces identical device.zig" {
    const gpa = std.testing.allocator;
    var a = try compileSource(gpa, test_resistor, .build);
    defer a.deinit();
    var b = try compileSource(gpa, test_resistor, .build);
    defer b.deinit();
    try std.testing.expectEqualStrings(try a.generateDevice(), try b.generateDevice());
}

// Zig analyses lazily, so an unreferenced decl is never type-checked. This
// forces analysis of every top-level pub decl of every stage.
test "every top-level pub decl of every stage type-checks" {
    inline for (.{ @This(), BigArena, token, Preprocessor, Lexer, Ast, Parser, Mir, Analysis, Ssa, Elaborate, Lower, proof, naming, codegen, UnitPlan, cg_display, cg_filters, orchestrator }) |stage| {
        std.testing.refAllDecls(stage);
    }
}
