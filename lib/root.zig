//! The compiler's module index and pipeline driver: Verilog-A source text in,
//! MIR and a generated `device.zig` out (preprocess, lex, parse, lower, prove,
//! codegen). Re-exports each stage and owns `CompileResult`, the root every
//! per-compilation allocation hangs off. `build.zig`'s `module_specs` makes
//! `lib/` a dependency of `src/`, never the reverse.
//!
//! The spine is `compileInArena`: preprocess, lex, parse, the §3.7 wreal
//! check, lower, `pruneHeld`, if-conversion (each followed by the MIR
//! verifier under runtime safety), prove, then the §9.4 drop warnings.
//! Codegen runs later and lazily, from `CompileResult.generateOutput`.
//! This file's pub declarations are the `vera` module's API (`src/main.zig`,
//! `src/vpi`, `tests/*`), so their names and meanings are frozen.
//!
//! Clauses its code cites: §3.2, §3.4, §3.6.2, §3.7, §4.2.12, §4.3.2, §6.2,
//! §6.5.3, §7.4.4, §7.6, §9.4, §9.5, §9.5.1, §9.7.3, §10, §12.32.1, annex D.1,
//! D.2, E.1 and E.2; IEEE 1364-2005 §19.1 and §19.6.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The compilation arena (`CompileResult.arena`); `src/main.zig` also keeps a
/// `.v` design's tables in one.
pub const BigArena = @import("big_arena.zig");
/// §10 preprocessing (`Preprocessor.process`), for callers that need the
/// text without a compilation.
pub const Preprocessor = @import("frontend").Preprocessor;
/// IEEE 1364-2005 §19.6 library map files (`--libmap`).
pub const libmap = @import("frontend").libmap;
/// A `--param name=value` compile-time override (`Options.param_overrides`, LRM §3.4).
pub const ParamOverride = Lower.ParamOverride;
/// §7.4.4 resolution mode, `Options.discipline_resolution`.
pub const DisciplineResolution = @import("ir").Elaborate.DisciplineResolution;
/// The keyword set a `--std=` selects (`Options.language`).
pub const KeywordSet = token.KeywordSet;
/// Diagnostic codes, the `Bag` every stage reports into, and rendering.
pub const diag = @import("diag");
/// MIR to device.zig (`CompileResult.generateOutput`).
pub const codegen = @import("backend").codegen;
/// MIR to a behavioural Verilog module for digital simulation (`--emit-verilog`).
pub const beh_verilog = @import("backend").beh_verilog;
/// device.zig to a versioned `.so` (`buildArtifact`).
pub const orchestrator = @import("backend").orchestrator;
/// The fixture testbench: `//!` directives, runner text and its build.
pub const tb = @import("backend").tb;

const token = @import("frontend").token;
const Lexer = @import("frontend").Lexer;
const Ast = @import("frontend").Ast;
const Parser = @import("frontend").Parser;
const deep_stack = @import("frontend").deep_stack;
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Ssa = @import("ir").Ssa;
const Elaborate = @import("ir").Elaborate;
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const ifconv = @import("ir").ifconv;
const proof = @import("ir").proof;
const verify = @import("ir").verify;
const naming = @import("backend").naming;
const cg_display = @import("backend").cg_display;
const cg_filters = @import("backend").cg_filters;

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
    /// §7.4.4 basic or detail discipline resolution
    /// (`--discipline-resolution=`); see `Elaborate.DisciplineResolution`.
    discipline_resolution: Elaborate.DisciplineResolution = .basic,
    /// Prepend annex D.2 constants.vams + annex D.1 disciplines.vams (§3.6.2).
    std_defs: bool = true,
    /// The source language, `vera --std=`. See `Parser.setLanguage`.
    language: KeywordSet = token.default_keyword_set,
    /// Receives every diagnostic of the run, errors and warnings, so a
    /// successful compilation may still fill it (W0650, the finiteness
    /// warning). Detached from the compilation arena before the call returns,
    /// so it stays valid after the `CompileResult` is freed; the caller must
    /// `deinit(gpa)` it. The bag must own nothing on entry (fresh from
    /// `Bag.init`, or after `deinit`): the call overwrites it without freeing
    /// what it held. A successful result keeps the pointer, and codegen
    /// reports into the bag (E0515), so it must outlive the result.
    diags: ?*diag.Bag = null,
    /// Per-code lint levels (`--allow=W0650`, `--deny=W0651`). An error
    /// code cannot be allowed away; see `diag.Levels.set`. Borrowed, not
    /// copied: the bag in `diags` reads it until that bag is freed, so it
    /// must outlive the bag.
    lint: diag.Levels = .empty,
    /// Class-6 knobs (solver compliance bound, overflow model). See proof.zig.
    proof: proof.Options = .{},
    /// SPICE netlist text (annex E.2) whose `.MODEL` and `.SUBCKT` cards this
    /// compilation may resolve module names against (E.1.1's antecedent: "if a
    /// simulator ... is also able to read SPICE netlists"). One card per line,
    /// `+` continuations included; see `spice_cards.synthesize` for the subset
    /// that is read. Empty is the default and reads nothing.
    spice_netlist: []const u8 = "",
    /// The file `spice_netlist` came from, so its `.INCLUDE`, `.LIB` and
    /// `.HDL` cards find files beside it; "" resolves them against the
    /// working directory.
    spice_path: []const u8 = "",
    /// What to do with the model's display tasks (LRM §9.4). `.record` makes a
    /// device whose `say` records them for its host (`contract.SaySite`), and
    /// `.drop` one without it: either way no text and no syscall in the
    /// Newton loop, and a W0850 for each task dropped. `.emit` makes an
    /// executable whose prints are the output. See `codegen.Display`.
    display: codegen.Display = .drop,
    /// Emits `pub const jac_f32 = true`: the device tolerates a host scalar S
    /// whose derivative half is single precision. See `codegen.Options.jac_f32`.
    jac_f32: bool = false,
    /// Also emits `pub const jac_f32_host = true`: the host should take that
    /// permission on its CPU instantiation, not only where f32 is free. Implies
    /// `jac_f32`. See `codegen.Options.jac_f32_host`.
    jac_f32_host: bool = false,
    /// Also emits `vpiContribs`, the §5.6 contribution rows a Clause 12
    /// analog host reads, and `vpiShares`, each instance's share of a row
    /// several share. See `codegen.Options.vpi_contribs`.
    vpi_contribs: bool = false,
    /// §12.32.1 the user analog system functions registered with sysfunctype
    /// vpiIntFunc: a call to one returns an integer. A VPI host that ran its
    /// startup routines before building the device passes them; with none,
    /// every unresolved `$name` returns a real.
    int_systfs: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// CompileResult
// ---------------------------------------------------------------------------

/// The output of one compilation: source to MIR, and optionally to device.zig.
///
/// Owns every allocation of the run. Preprocessed text, tokens, AST, MIR and
/// lowering's tables live in `arena`, a `BigArena`: its large tables are the
/// gpa's own blocks, grown in place and freed with it. Only
/// `verdict.unit_modes` and `device.text` are gpa-owned (the device text can
/// reach hundreds of megabytes, and an arena cannot grow a buffer in place).
/// `deinit` frees all three. The value is freely movable.
pub const CompileResult = struct {
    /// The allocator the result was compiled with; `deinit` frees with it.
    gpa: Allocator,
    // Heap-allocated because the AST stores and `Ssa.SsaBuilder` hold an
    // `Allocator` whose `ptr` is this arena's address: moving it by
    // value would dangle them.
    arena: *BigArena,
    /// Preprocessed source (arena). Every AST/MIR string borrows from it.
    source: []const u8,
    /// The top module's MIR (arena), if-converted and proven.
    mir: *Mir,
    /// Lowering's output. The `Lower` that built it is gone: nothing after
    /// stage 4 can reach a symbol table, a scope or the SSA builder.
    lowered: *const Lowered,
    /// Its `unit_modes` slice is gpa-owned.
    verdict: proof.Verdict,
    /// What the caller asked for; `buildArtifact` refuses a `.lint` result.
    target: Target,
    /// Codegen output; empty until the first successful `generateOutput`,
    /// which the pipeline itself never calls. `text` is gpa-owned and freed
    /// by `deinit`; consumers borrow it.
    /// `names`, `unit_lo` and `unit_hi` are the per-unit file map the
    /// orchestrator writes (see `codegen.Output`).
    device: codegen.Output = .{ .text = "" },
    /// Whether codegen refused any construct, including metadata failures
    /// without an `@compileError` unit. Callers must not consume failed output.
    device_has_compile_error: bool = false,
    /// Settings that change what codegen generates.
    codegen_opts: codegen.Options = .{},
    /// The source's nesting depth (`Parser.deepest`): codegen's walks run on
    /// a `deep_stack` reserved for it.
    nesting: u32 = 0,

    /// Frees the arena and the two gpa-owned buffers; invalidates every slice
    /// borrowed from the result.
    pub fn deinit(self: *CompileResult) void {
        self.gpa.free(self.device.text);
        self.verdict.deinit(self.gpa);
        freeArena(self.gpa, self.arena);
        self.* = undefined;
    }

    /// Runs codegen and returns the device text. Idempotent: the text is
    /// cached on the result, so a second call costs nothing and returns the
    /// same slice. The slice is borrowed and lives until `deinit`. A failed
    /// call caches nothing, so the next call runs codegen again.
    pub fn generateDevice(self: *CompileResult) codegen.Error![]const u8 {
        return (try self.generateOutput()).text;
    }

    /// Runs codegen (once, as `generateDevice`) and returns the text with the
    /// per-unit file map the orchestrator needs. Every slice in the returned
    /// value is borrowed from the result and lives until `deinit`.
    pub fn generateOutput(self: *CompileResult) codegen.Error!codegen.Output {
        if (self.device.text.len == 0) {
            // A stack the system will not reserve is memory it will not give;
            // the compile already reserved one this deep, so this is rare.
            self.device = deep_stack.run(self.nesting, codegen.generate, .{
                self.gpa,
                self.arena.allocator(),
                self.mir,
                self.lowered,
                self.verdict,
                &self.device_has_compile_error,
                self.codegen_opts,
            }) catch |err| switch (err) {
                error.DeepStackUnavailable => return error.OutOfMemory,
                else => |e| return e,
            };
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

/// `compileSource` with explicit settings. Caller owns the result and frees
/// it with `deinit`. When `opts.diags` is set it receives every diagnostic
/// even on failure, and the caller must `deinit(gpa)` it; on any failure
/// that bag is the only thing the call leaves allocated.
/// Fails with `error.CompileFailed` when a stage reported an error, or when a
/// `--deny` promoted a warning even if every stage succeeded;
/// `error.NoModule` when the source declares no module of its own (the
/// annex D/E prelude and a SPICE netlist's modules do not count).
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
        .spice_path = opts.spice_path,
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
    const seed = try Preprocessor.preludeAst(opts.std_defs);
    var p = try Parser.Parser.initSeeded(arena, text, tags, starts, bag, seed);
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
    file.builtin_natures = if (seed) |sd| @intCast(sd.file.natures.len) else 0;
    file.annex_d_included = pp.annex_d_included;
    file.netlist_modules = netlist_modules;
    file.netlist_unsupported = pp.netlist_unsupported;
    // Every stage from here walks the AST by recursion, so it runs on a stack
    // reserved for the nesting the parser measured (`deep_stack`).
    return deep_stack.run(p.deepest, lowerAndProve, .{ gpa, arena_state, file, text, starts, pp.directives, p.deepest, target, opts, bag }) catch |err| switch (err) {
        error.DeepStackUnavailable => {
            try bag.add(.lower, .E0241, .{}, "{d} levels deep", .{p.deepest});
            return error.CompileFailed;
        },
        else => |e| return e,
    };
}

/// The stages after the parse, through the proof, on the `deep_stack` thread
/// `compileInArena` starts; `nesting` is the parser's `deepest`.
fn lowerAndProve(
    gpa: Allocator,
    arena_state: *BigArena,
    file: *Ast.SourceFile,
    text: []const u8,
    starts: []const u32,
    directives: Preprocessor.Directives,
    nesting: u32,
    target: Target,
    opts: Options,
    bag: *diag.Bag,
) Error!CompileResult {
    const arena = arena_state.allocator();
    try Elaborate.spiceCase(arena, file);
    // §3.7/§6.5.3 wreal structure rules. The digital runner calls the same
    // check, so both routes refuse the same wirings.
    try @import("frontend").wreal.check(file, starts, bag);
    if (bag.failed()) return error.CompileFailed;

    const mir = try arena.create(Mir);
    mir.* = .{};
    const lowered = try arena.create(Lowered);
    lowered.* = Lower.lower(arena, mir, file, text, starts, bag, .{
        .directives = directives,
        .include_dirs = opts.include_dirs, // §9.21.1 a $table_model data file
        .param_overrides = opts.param_overrides, // §3.4 `--param`
        .displays_dropped = opts.display == .drop, // §3.2 retention, see `Exposed`
        .discipline_resolution = opts.discipline_resolution,
        .int_systfs = opts.int_systfs, // §12.32.1 vpiIntFunc
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoModule => {
            try bag.add(.lower, .E1001, .{}, "", .{});
            return error.NoModule;
        },
        error.DiagnosticsReported => return error.CompileFailed,
    };

    // The MIR's postcondition after each stage that writes it (Debug and
    // ReleaseSafe only). The proof and codegen take it `*const`.
    try verify.check(mir, lowered, "lowering");

    // §3.2: drop the held slots no card can observe. Runs before ifconv,
    // whose selects would hide the merges it reads. See `codegen.pruneHeld`.
    try codegen.pruneHeld(arena, mir, lowered);
    try verify.check(mir, lowered, "pruneHeld");

    // If-convert pure diamonds to §4.2.12 selects before the proof: a
    // select's guard facts come from markSelectArms, so the proof sees the
    // evidence the CFG edge carried and codegen can emit proven-total
    // conditionals as `S.sel`. Arena, because ifconv appends to MIR tables.
    _ = try ifconv.run(arena, mir);
    try verify.check(mir, lowered, "ifconv");

    // The proof gates every target and is the source of the W0650 finiteness
    // warning, which is why `.lint` runs it too.
    const verdict = try proof.proveOpts(gpa, mir, lowered, opts.proof, bag);
    errdefer verdict.deinit(gpa);
    // §4.3.2: a domain violation is a compile error on every target.
    if (!verdict.ok()) return error.CompileFailed;

    // §9.4/§9.5. Reported here, not in lowering, because whether a side effect
    // is kept depends on what the caller asked to build. The model is legal
    // either way, so these are warnings.
    try warnDroppedDisplays(bag, lowered, opts.display);

    return .{
        .gpa = gpa,
        .arena = arena_state,
        .source = text,
        .mir = mir,
        .lowered = lowered,
        .verdict = verdict,
        .target = target,
        .nesting = nesting,
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

/// Reports a W0850 for every display or file task in `lowered.displays` that
/// the device `display` asks for will not perform. `.emit` drops none.
fn warnDroppedDisplays(bag: *diag.Bag, lowered: *const Lowered, display: codegen.Display) Allocator.Error!void {
    if (display == .emit) return;
    for (lowered.displays.items) |d| {
        const c: Mir.Callee = .fromName(d.name);
        // §9.7.3 a device reports these through its status channel
        // (`contract.StatusSite`): kept, not dropped.
        if (c == .@"$fatal" or c == .@"$error") continue;
        // §9.4 a `.record` device's `say` records these; codegen names one
        // it cannot (`cg_display.planSay`).
        if (display == .record and cg_display.sayRecords(c)) continue;
        const span = lowered.tokenSpan(d.tok);
        // A §9.5 file task is kept for sequencing, not text; its answer is
        // §9.5.1's zero descriptor rather than a dropped print.
        if (Mir.callee.isFileCall(c))
            try bag.add(.lower, .W0850, span, "`{s}` — a device has no host file table, so §9.5.1's zero descriptor is the answer", .{d.name})
        else if (display == .record)
            try bag.add(.lower, .W0850, span, "`{s}` — a device's `say` records the printing tasks, not this one", .{d.name})
        else
            try bag.add(.lower, .W0850, span, "`{s}`", .{d.name});
    }
}

// ---------------------------------------------------------------------------
// Artifact build
// ---------------------------------------------------------------------------

/// Generates the device and builds it cold into a shared library
/// (`orchestrator.compileRelease`), `lib<name>.<generation>.so` in
/// `o.work_dir`. The host owns loading it and all simulation state. Caller
/// owns the returned `orchestrator.Result` and frees it with `deinit(gpa)`.
/// Fails with `error.NoArtifact` on a `.lint` result, before anything runs.
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
    try std.testing.expect(std.mem.find(u8, aw.writer.buffered(), "-->") != null);
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

/// A module whose analog block holds `pre`, then `n` copies of `open`, `mid`,
/// `n` copies of `close`, and `post`.
fn deepSource(gpa: Allocator, n: usize, c: DeepCase) ![]u8 {
    var src: std.ArrayList(u8) = .empty;
    errdefer src.deinit(gpa);
    try src.appendSlice(gpa, "module deep(p, n); inout p, n; electrical p, n; real r; integer k; analog begin ");
    try src.appendSlice(gpa, c.pre);
    for (0..n) |_| try src.appendSlice(gpa, c.open);
    try src.appendSlice(gpa, c.mid);
    for (0..n) |_| try src.appendSlice(gpa, c.close);
    try src.appendSlice(gpa, c.post);
    try src.appendSlice(gpa, " I(p, n) <+ r * V(p, n); end endmodule");
    return src.toOwnedSlice(gpa);
}

const DeepCase = struct { pre: []const u8 = "", open: []const u8, mid: []const u8, close: []const u8 = "", post: []const u8 = "", lint: usize = 100_000, device: usize = 100_000 };

test "nesting has no bound: 100,000 levels lint and generate a device" {
    // Every stage after the parse recurses per AST level and runs on a
    // `deep_stack` sized from `Parser.deepest`; 100,000 levels is far past
    // the 8 MiB stack the pipeline had (it overflowed near 3,000). For if
    // and ?: chains `lint` is the depth linted and `device` the depth taken
    // through codegen: the prover's per-branch facts make a lint quadratic
    // in their depth (7.6 s for 10,000 else-ifs in Debug), and codegen
    // indents each nested `if`, so its text is quadratic too, until
    // limits/elab lands; they run at 10,000 and 2,000, past the old 1,024
    // cap. The parser takes all three at 100,000 (`parser/test.zig`).
    const gpa = std.testing.allocator;
    for ([_]DeepCase{
        .{ .pre = "r = 1.0", .open = "", .mid = "", .close = " + 1.0", .post = ";" },
        .{ .pre = "r = ", .open = "(", .mid = "1.0", .close = ")", .post = ";" },
        .{ .pre = "r = ", .open = "-", .mid = "1.0", .post = ";" },
        .{ .pre = "k = ", .open = "{", .mid = "1'b1", .close = "}", .post = "; r = k;" },
        .{ .open = "begin ", .mid = "r = 1.0;", .close = " end" },
        .{ .pre = "r = ", .open = "V(p) > 1 ? 1 : ", .mid = "0", .post = ";", .lint = 10_000, .device = 2_000 },
        .{ .open = "if (V(p) > 1) r = 1; else ", .mid = "r = 0;", .lint = 10_000, .device = 2_000 },
        .{ .pre = "r = 0; ", .open = "if (V(p) > 1) ", .mid = "r = 1;", .lint = 10_000, .device = 2_000 },
    }) |c| {
        for ([_]usize{ c.lint, c.device }, [_]Target{ .lint, .build }) |n, target| {
            const src = try deepSource(gpa, n, c);
            defer gpa.free(src);
            var res = try compileSource(gpa, src, target);
            defer res.deinit();
            if (target == .build) {
                _ = try res.generateDevice();
                try std.testing.expect(!res.device_has_compile_error);
            }
        }
    }
}

test "a later stage whose stack cannot be reserved is E0241, naming the depth" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const src = try deepSource(gpa, 10, .{ .open = "begin ", .mid = "r = 1.0;", .close = " end" });
    defer gpa.free(src);
    deep_stack.refuse_for_test = true;
    defer deep_stack.refuse_for_test = false;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    try std.testing.expectError(error.CompileFailed, compileSourceOpts(gpa, src, .lint, .{ .diags = &bag }));
    try std.testing.expectEqual(diag.Code.E0241, bag.at(0).code);
    try std.testing.expect(std.mem.indexOf(u8, bag.at(0).message, "levels deep") != null);
}

test "10,000 sequential ifs compile: SSA, the prover and codegen walk them on no native stack per if" {
    // Each `if` is a join the next one's block is dominated by, so the
    // dominator tree, the SSA read of `x` and the emitted chain are all
    // 10,000 deep. `sqrt` keeps every diamond out of if-conversion (its
    // domain needs the guard, which the prover reads off the edge); `+ 1.0`
    // is converted to selects, which leaves a chain of jumps instead.
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |guarded| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "module seq(p); inout p; electrical p; real x;\nanalog begin\nx = 0.0;\n");
        for (1..10_001) |i| {
            if (guarded)
                try src.print(gpa, "if (V(p) > -{d}.0) x = x + sqrt(V(p) + {d}.0);\n", .{ i, i })
            else
                try src.print(gpa, "if (V(p) > -{d}.0) x = x + 1.0;\n", .{i});
        }
        try src.appendSlice(gpa, "I(p) <+ x;\nend\nendmodule\n");
        var res = try compileSource(gpa, src.items, .build);
        defer res.deinit();
        const text = try res.generateDevice();
        try std.testing.expect(!res.device_has_compile_error);
        const branches = std.mem.count(u8, text, "} else {");
        try std.testing.expectEqual(@as(usize, if (guarded) 10_000 else 0), branches);
    }
}

test "100,000-level ?: chain, else-if chain and nested ifs: device text is linear in the nesting" {
    // KNOWN: needs limits/frontend. The parser (E0241 at 1024 levels) and
    // lowering's AST walks recurse per level on this branch; codegen does not
    // (`cfg.emitTree`'s heap stack, `Gen.max_indent`). Live once the two
    // branches merge.
    if (true) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const n = 100_000;
    for ([_]enum { ternary, else_if, nested }{ .ternary, .else_if, .nested }) |shape| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "module deep(p); inout p; electrical p; real x;\nanalog begin\nx = 0.0;\n");
        switch (shape) {
            .ternary => {
                try src.appendSlice(gpa, "x = ");
                for (1..n + 1) |i| try src.print(gpa, "V(p) > -{d}.0 ? ", .{i});
                try src.appendSlice(gpa, "1.0");
                for (1..n + 1) |i| try src.print(gpa, " : {d}.0", .{n + 1 - i});
                try src.appendSlice(gpa, ";\n");
            },
            .else_if => {
                for (1..n + 1) |i| try src.print(gpa, "{s}if (V(p) > {d}.0) x = {d}.0;\n", .{ if (i > 1) "else " else "", i, i });
                try src.appendSlice(gpa, "else x = 0.5;\n");
            },
            .nested => {
                for (1..n + 1) |i| try src.print(gpa, "if (V(p) > -{d}.0) begin x = x + 1.0;\n", .{i});
                for (0..n) |_| try src.appendSlice(gpa, "end\n");
            },
        }
        try src.appendSlice(gpa, "I(p) <+ x * V(p);\nend\nendmodule\n");
        var res = try compileSource(gpa, src.items, .build);
        defer res.deinit();
        const text = try res.generateDevice();
        try std.testing.expect(!res.device_has_compile_error);
        // 1000 levels measured 0.6-1.6 KB a level; quadratic indentation
        // alone would be 200 KB a level at this depth.
        try std.testing.expect(text.len < 4096 * n);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            const lead = l.len - std.mem.trimStart(u8, l, " ").len;
            try std.testing.expect(lead <= codegen.Gen.indWidth(std.math.maxInt(u32)));
        }
    }
}

test "generateDevice runs codegen once and hands back the cached text" {
    const gpa = std.testing.allocator;
    var res = try compileSource(gpa, test_resistor, .build);
    defer res.deinit();
    // The pipeline itself never runs codegen.
    try std.testing.expectEqual(@as(usize, 0), res.device.text.len);

    const first = try res.generateDevice();
    try std.testing.expect(first.len != 0);
    try std.testing.expect(!res.device_has_compile_error);
    // Same slice, not an equal copy: the second call did not run codegen
    // (a second run would allocate a second gpa buffer).
    const second = try res.generateDevice();
    try std.testing.expect(first.ptr == second.ptr and first.len == second.len);
    const out = try res.generateOutput();
    try std.testing.expect(out.text.ptr == first.ptr);
}

test buildArtifact {
    // `.lint` is refused before codegen or the orchestrator runs, so these
    // options are never read: no directory, no child process.
    const gpa = std.testing.allocator;
    var res = try compileSource(gpa, test_resistor, .lint);
    defer res.deinit();
    try std.testing.expectError(error.NoArtifact, buildArtifact(gpa, std.testing.io, &res, .{
        .work_dir = "",
        .name = "res",
        .optimize = .debug,
        .backend = .self_hosted,
        .modules = &.{},
    }, 0));
    try std.testing.expectEqual(@as(usize, 0), res.device.text.len);
}

test "a source with no module of its own is NoModule, with or without the prelude" {
    // §6.2. `compileInArena` sets `builtin_modules` to the annex E prelude's
    // count; were it short, a Table E.1 primitive would be taken as the top
    // and this would compile.
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |std_defs| {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        try std.testing.expectError(error.NoModule, compileSourceOpts(gpa, "", .lint, .{
            .diags = &bag,
            .std_defs = std_defs,
        }));
        // Lowering finds no module and says so, once.
        var e1001: usize = 0;
        for (0..bag.count()) |i| {
            if (bag.at(i).code == .E1001) e1001 += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), e1001);
    }
}

test "a parse error is NoModule only when no module of the source's own was parsed" {
    // `endmodule` with no `module` is E0201; the parser recovers at top level,
    // so in the second source it still parses `res`, and the failure is the
    // diagnosed parse, not a missing module.
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NoModule, compileSource(gpa, "endmodule\n", .lint));
    try std.testing.expectError(error.CompileFailed, compileSource(gpa, "endmodule\n" ++ test_resistor, .lint));
}

test "without the prelude, a source that includes the annex D files itself compiles" {
    // `std_defs = false` drops the prepended annex D.1/D.2 text and the
    // Table E.1 primitives with it, so nothing is a builtin module and the
    // user's `res` is the top.
    const gpa = std.testing.allocator;
    var res = try compileSourceOpts(gpa, "`include \"disciplines.vams\"\n" ++ test_resistor, .lint, .{ .std_defs = false });
    defer res.deinit();
    try std.testing.expectEqualStrings("res", res.mir.name);
    try std.testing.expect(res.verdict.ok());
}

const test_netlist =
    \\.SUBCKT RDIV IN OUT
    \\R1 IN OUT 1K
    \\.ENDS RDIV
    \\
;

test "annex E.2: a SPICE netlist's modules lead the file but are never the top" {
    // The `.SUBCKT` becomes `module rdiv`, placed before the source. Counted
    // among the builtins it is not a candidate top: `res` is. Were it left
    // out of the count, `rdiv` (first, and instantiated by nothing) would be
    // the top, and an empty source would compile.
    const gpa = std.testing.allocator;
    {
        var res = try compileSourceOpts(gpa, test_resistor, .lint, .{ .spice_netlist = test_netlist });
        defer res.deinit();
        try std.testing.expectEqualStrings("res", res.mir.name);
    }
    try std.testing.expectError(error.NoModule, compileSourceOpts(gpa, "", .lint, .{ .spice_netlist = test_netlist }));
}

const test_unbounded_exp =
    \\module amp(a, c); inout a, c; electrical a, c;
    \\  analog I(a, c) <+ exp(V(a, c));
    \\endmodule
    \\
;

test "a --deny fails the compilation even with no bag to report into, and frees it" {
    // The denied W0650 lands in the arena's own bag, which is freed with the
    // arena; the testing allocator fails the test on a leak.
    const gpa = std.testing.allocator;
    var levels: diag.Levels = .empty;
    defer levels.deinit(gpa);
    try levels.set(gpa, .W0650, .deny);
    try std.testing.expectError(error.CompileFailed, compileSourceOpts(gpa, test_unbounded_exp, .lint, .{ .lint = levels }));
}

test "a failed compilation with no bag leaks nothing" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.CompileFailed, compileSource(
        gpa,
        "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n",
        .lint,
    ));
}

/// Lints `src` with `display` and returns how many W0850 rows have a
/// headline containing `needle` ("" counts every W0850 row).
fn countW0850(src: []const u8, display: codegen.Display, needle: []const u8) !usize {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var res = try compileSourceOpts(gpa, src, .lint, .{ .diags = &bag, .display = display });
    defer res.deinit();
    var n: usize = 0;
    for (0..bag.count()) |i| {
        const e = bag.at(i);
        if (e.code == .W0850 and std.mem.find(u8, e.message, needle) != null) n += 1;
    }
    return n;
}

test "§9.4 W0850 names each task the requested device drops, and no other" {
    const strobe =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ V(p, n);
        \\    $strobe("v=%g", V(p, n));
        \\  end
        \\endmodule
        \\
    ;
    // §9.4.1 `$monitor` needs change detection across accepted points, state
    // a device does not keep, so `say` does not record it
    // (`cg_display.sayRecords`; ch09_system_tasks/say_device_records.va).
    const monitor =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ V(p, n);
        \\    $monitor("%g", V(p));
        \\  end
        \\endmodule
        \\
    ;
    const severity =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  analog begin
        \\    if (V(p, n) > 1.0) $error("v=%g", V(p, n));
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
        \\
    ;
    const file =
        \\module d(p, n); inout p, n; electrical p, n;
        \\  integer fd;
        \\  analog begin
        \\    fd = $fopen("vera_never_written.dat");
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
        \\
    ;
    // `.drop`: the print is gone, and the warning names the task alone.
    try std.testing.expectEqual(1, try countW0850(strobe, .drop, "`$strobe`"));
    try std.testing.expectEqual(0, try countW0850(strobe, .drop, "records"));
    // `.record`: `say` records `$strobe`, but not `$monitor`.
    try std.testing.expectEqual(0, try countW0850(strobe, .record, ""));
    try std.testing.expectEqual(1, try countW0850(monitor, .record, "records the printing tasks"));
    // `.emit`: the executable prints; nothing is dropped.
    try std.testing.expectEqual(0, try countW0850(strobe, .emit, ""));
    try std.testing.expectEqual(0, try countW0850(monitor, .emit, ""));
    // §9.7.3: `$error` reaches the host through the status channel whatever
    // the display mode, so it is never reported as dropped.
    try std.testing.expectEqual(0, try countW0850(severity, .drop, ""));
    try std.testing.expectEqual(0, try countW0850(severity, .record, ""));
    // §9.5.1: a device has no file table; `$fopen` answers the zero
    // descriptor under `.drop` and `.record` alike (a file task is no
    // printing task, so `say` does not take it).
    try std.testing.expectEqual(1, try countW0850(file, .drop, "zero descriptor"));
    try std.testing.expectEqual(1, try countW0850(file, .record, "zero descriptor"));
    try std.testing.expectEqual(0, try countW0850(file, .emit, ""));
}

// Zig analyses lazily, so an unreferenced decl is never type-checked. This
// forces analysis of every top-level pub decl of every stage.
test "every top-level pub decl of every stage type-checks" {
    inline for (.{ @This(), BigArena, token, Preprocessor, Lexer, Ast, Parser, Mir, Analysis, Ssa, Elaborate, Lower, proof, naming, codegen, cg_display, cg_filters, orchestrator }) |stage| {
        std.testing.refAllDecls(stage);
    }
}
