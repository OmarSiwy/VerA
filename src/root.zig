//! VerA engine — module index & pipeline driver.
//!
//! Each file owns one engine "class" (a group of Verilog-AMS LRM sections).
//! This file is the facade: it re-exports every stage and owns the drivers that
//! sequence them, plus the ownership root (`CompileResult`) that every arena in
//! the engine hangs off.
//!
//! Architecture: a Verilog-A source becomes a loadable device through a
//! fixed, index-based, cache-friendly pipeline. The directories ARE the
//! pipeline — a file's position in it is its position on disk:
//!
//!   .va text
//!  frontend/  → preprocessor.zig  (class 1)  text → text
//!             → lexer.zig/token.zig (class 1) text → tokens (SoA {tag,start})
//!             → parser.zig/ast.zig  (class 2) tokens → AST (SoA, u32 handles)
//!  ir/        → elaborate.zig      (class 9) AST → flat design (§6.2.2)
//!             → lower.zig + ssa.zig → mir.zig (classes 3,4,5,7,9) AST → MIR
//!             → proof.zig          (class 6) MIR → per-unit finiteness verdict
//!  backend/   → codegen.zig+naming (classes 4,5,8,10) MIR → device.zig
//!             → orchestrator.zig  (§8.3 ABI) device.zig → .so (+ GPU kernels)
//!
//! The pipeline ENDS at the .so. There is no runtime stage here: §8.3's
//! simulation cycle — assemble, factor, iterate — belongs to the host that
//! dlopens the artifact, and VerA's contribution to its speed is the code it
//! emits, not a loop of its own. `tools/contract.zig` is the whole promise.
//!
//! `frontend/` and `ir/` are shared by all targets; only `backend/` differs. The
//! split exists so a second frontend lowering into this MIR, or a second backend
//! reading it, is a sibling file rather than a rewrite: `ir/` never imports
//! `backend/`, and the compiler enforces that because there is no such import.
//!
//! No file is reachable by neither import graph. The six kernel files
//! (`backend/{filter,str,rng,table,file,limit}_kernels.zig`) reach a device by
//! `@embedFile` rather than by import, so they must stay ADJACENT to codegen —
//! but each is also `@import`ed by a codegen test, which is the whole point of
//! their being real files: what the tests check is byte-for-byte what runs in
//! the device. `filter_kernels.zig` was registered here as the one exception
//! until wave 10 gave `zBilin` its test.
//!
//! ORPHAN: backend/kernels.zig — a test ROOT, not a pipeline stage. Reaching
//! the six kernel files meant compiling codegen.zig and the IR behind it, which
//! is why five of them had no tests at all; `zig build test-kernels` mounts
//! this root and runs them in 306 ms instead. Nothing imports it ON PURPOSE:
//! putting it in a device's import graph would pull test code into generated
//! source. It cannot rot into another `eval_batch.zig` — it holds no logic, only
//! a `test {}` of `@import`s, so an unreachable kernel still fails the guard.
//!
//! That register is THIS block, it is machine-read, and it holds exactly the
//! line above. An exception is one `//! ORPHAN: <path under src/> — <why>` line;
//! `tools/source_guards.zig` parses them as the allowlist for its "every
//! `src/backend/*.zig` is reachable from a root" test, and fails the build on a
//! backend file that is neither reachable nor listed. Do not add a line to
//! silence it without the `<why>`: an orphan that stayed silent is how
//! `eval_batch.zig` reached 702 lines nothing could call, and wave 12 deleted
//! it for exactly that.
//!
//! DOD ground rules that hold in EVERY file here:
//!   - SoA (MultiArrayList / flat Buf), never array-of-structs across a hot loop.
//!   - Cross-node references are typed `enum(u32)` handles, never pointers.
//!   - Arena ownership per compilation; caller owns allocation.
//!   - Smallest integer that fits; hot/cold field split.
//!
//! OWNERSHIP (the whole engine's rule, enforced here):
//!   Every byte produced by stages 1–5 — preprocessed text, token list, AST,
//!   MIR, Lower side tables — is allocated from ONE per-compilation arena that
//!   `CompileResult` owns. There are two deliberate exceptions, so
//!   `CompileResult.deinit` frees exactly three things:
//!     - `proof.Verdict`, gpa-owned because proof.zig frees its own error
//!       strings;
//!     - `device_zig`, gpa-owned because it is the one unboundedly growing
//!       buffer (182 MB on `hisimhv_va`) and an arena cannot regrow in place —
//!       see `codegen.generate`.
//!   Everything else is the arena.
//!   Diagnostics collect into ONE `diag.Bag` on that same arena and are
//!   gpa-duped at the boundary by `Bag.detach` — a failed compilation frees
//!   its arena on the way out, so a borrowed stage message would dangle.

const std = @import("std");
const Allocator = std.mem.Allocator;

const token = @import("frontend/token.zig");
pub const Preprocessor = @import("frontend/preprocessor.zig");
const Lexer = @import("frontend/lexer.zig");
const Ast = @import("frontend/ast.zig");
const Parser = @import("frontend/parser.zig");
const Mir = @import("ir/mir.zig");
const Analysis = @import("ir/analysis.zig");
const Ssa = @import("ir/ssa.zig");
const Elaborate = @import("ir/elaborate.zig");
const Lower = @import("ir/lower.zig");
const ifconv = @import("ir/ifconv.zig");
const proof = @import("ir/proof.zig");
pub const diag = @import("diag");
const naming = @import("backend/naming.zig");
pub const codegen = @import("backend/codegen.zig");
const UnitPlan = @import("backend/unit_plan.zig");
const cg_display = @import("backend/cg_display.zig");
const cg_filters = @import("backend/cg_filters.zig");
pub const orchestrator = @import("backend/orchestrator.zig");
pub const tb = @import("backend/tb.zig");

/// The three build targets. Frontend is identical for all three; the backend
/// and float behavior differ.
pub const Target = enum {
    /// Frontend only: parse + lower + finiteness proof, emit diagnostics.
    /// No codegen, no `zig` spawn. Microseconds.
    lint,
    /// Self-hosted backend, incremental (resident `zig --listen` + -fincremental),
    /// strict float mode, CPU .so only. Fast edit→run loop.
    debug,
    /// LLVM backend, no incremental, per-unit float mode, CPU .so + GPU kernels.
    release_fast,
};

pub const Error = codegen.Error || error{
    /// One or more stages reported diagnostics. They are in the caller's
    /// `Options.diags` when one was supplied.
    CompileFailed,
    /// The source declared no `module` (LRM §6.2) — nothing to compile.
    NoModule,
    /// `.lint` produces no artifact by definition.
    NoArtifact,
    /// `.debug` builds through a session-scoped resident `zig build --listen=-`
    /// child; cross-process -fincremental does not exist on ELF 0.16.
    NoResidentChild,
};

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// Diagnostics only.
    file_name: []const u8 = "<source>",
    /// Searched in order for `include, ahead of the built-in annex D files.
    include_dirs: []const []const u8 = &.{},
    /// Prepend annex D.2 constants.vams + annex D.1 disciplines.vams (§3.6.2).
    std_defs: bool = true,
    /// Receives every diagnostic of the run — errors AND warnings, so a
    /// SUCCESSFUL compilation may still fill it (see W0650, the finiteness
    /// warning). Detached from the compilation arena before this call returns,
    /// so it stays valid after the `CompileResult` is freed; the caller must
    /// `deinit(gpa)` it.
    diags: ?*diag.Bag = null,
    /// Per-code lint levels — `--allow=W0650`, `--deny=W0651`, ... An error
    /// code cannot be allowed away; see `diag.Levels.set`.
    lint: diag.Levels = .empty,
    /// Class-6 knobs (solver compliance bound, overflow model). See proof.zig.
    proof: proof.Options = .{},
    /// Annex E.2 — SPICE netlist text whose `.MODEL` and `.SUBCKT` cards this
    /// compilation may resolve module names against (E.1.1's antecedent: "if a
    /// simulator ... is also able to read SPICE netlists"). One card per line,
    /// `+` continuations included; see `spice_cards.synthesize` for the subset
    /// that is read. Empty is the default and reads nothing.
    spice_netlist: []const u8 = "",
    /// §9.4 what to do with the model's display tasks. `.drop` (the default)
    /// makes the DEVICE: no text, no syscall in the Newton loop, GPU-clean, and
    /// a W0850 for every task that was dropped. `.emit` makes the EXECUTABLE:
    /// the prints are the artifact. See `codegen.Display`.
    display: codegen.Display = .drop,
    /// Emit `pub const jac_f32 = true` — this device tolerates a host scalar S
    /// whose DERIVATIVE half is single precision. See `codegen.Options.jac_f32`.
    jac_f32: bool = false,
    /// Also emit `pub const jac_f32_host = true` — the host should take that
    /// permission on its CPU instantiation, not only where f32 is free. Implies
    /// `jac_f32`. See `codegen.Options.jac_f32_host`.
    jac_f32_host: bool = false,
    /// Statements per outlined chunk function for huge bodies (0 = never).
    /// Defaults to codegen's own default; see `codegen.Options.outline_chunk`.
    outline_chunk: u32 = (codegen.Options{}).outline_chunk,
};

// ---------------------------------------------------------------------------
// CompileResult — the ownership root
// ---------------------------------------------------------------------------

/// Result of one frontend run (source → MIR → optionally device.zig).
///
/// The arena is HEAP-allocated on purpose: `Lower`, `Ssa.SsaBuilder` and the
/// AST stores all hold an `Allocator` whose `ptr` is the ArenaAllocator's
/// address, so moving the ArenaAllocator by value into this struct would
/// dangle every one of them. Keeping a pointer makes the result freely movable
/// — out of the function that built it, into a caller's own table, …
pub const CompileResult = struct {
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    /// Preprocessed source (arena). Every AST/MIR string borrows from it.
    source: []const u8,
    mir: *Mir,
    lower: *Lower,
    /// gpa-owned (its `unit_modes` slice is).
    verdict: proof.Verdict,
    target: Target,
    /// Stage 6 output; empty until `generateDevice` runs (never for `.lint`).
    /// GPA-OWNED, not arena — it is the one buffer that grows to hundreds of
    /// megabytes, and `ArenaAllocator.resize` cannot grow it in place. Freed by
    /// `deinit`; every consumer borrows it read-only and finishes first.
    ///
    /// `device.names`/`unit_lo`/`unit_hi` are the per-unit file map the
    /// orchestrator writes through `writeIfChanged` — see `codegen.Output`.
    device: codegen.Output = .{ .text = "" },
    /// Whether `device.text` contains an `@compileError` unit. Reported by
    /// codegen, so no caller has to substring-search a multi-megabyte output.
    device_has_compile_error: bool = false,
    /// Knobs that change WHAT stage 6 generates (§9.4 display handling today).
    codegen_opts: codegen.Options = .{},

    pub fn deinit(self: *CompileResult) void {
        self.gpa.free(self.device.text);
        self.verdict.deinit(self.gpa);
        freeArena(self.gpa, self.arena);
        self.* = undefined;
    }

    /// Stage 6. Idempotent — the generated text is cached on the result, so a
    /// caller that asks twice (the CLI does: once to write, once to hand to the
    /// orchestrator) pays codegen once.
    pub fn generateDevice(self: *CompileResult) codegen.Error![]const u8 {
        return (try self.generateOutput()).text;
    }

    /// Stage 6, with the per-unit file map the orchestrator needs.
    pub fn generateOutput(self: *CompileResult) codegen.Error!codegen.Output {
        if (self.device.text.len == 0) {
            self.device = try codegen.generate(
                self.gpa,
                self.arena.allocator(),
                self.mir,
                self.lower,
                self.verdict,
                &self.device_has_compile_error,
                self.codegen_opts,
            );
        }
        return self.device;
    }

    /// Source units in the codegen/proof sense (LRM §5.6 contributions).
    /// `verdict.unit_modes` is parallel to this.
    pub fn unitCount(self: *const CompileResult) usize {
        return proof.unitCount(self.lower);
    }
};

// ---------------------------------------------------------------------------
// Stages 1–5
// ---------------------------------------------------------------------------

/// Front-to-MIR driver. Runs stages 1–5 (preprocess → lex → parse → lower →
/// PROVE). On `.lint` this is the whole job.
pub fn compileSource(gpa: Allocator, source: []const u8, target: Target) Error!CompileResult {
    return compileSourceOpts(gpa, source, target, .{});
}

pub fn compileSourceOpts(
    gpa: Allocator,
    source: []const u8,
    target: Target,
    opts: Options,
) Error!CompileResult {
    const arena_state = try gpa.create(std.heap.ArenaAllocator);
    arena_state.* = .init(gpa);

    // ONE bag for the whole run, on the compilation arena.
    var bag = diag.Bag.init(arena_state.allocator());
    bag.levels = opts.lint;

    const result = compileInArena(gpa, arena_state, source, target, opts, &bag);

    // A `--deny=`d warning is an error by the user's own instruction, so a
    // compilation that only tripped one must still FAIL. Read before detaching,
    // which moves the bag out.
    const denied = bag.failed();

    // ORDER MATTERS: the bag's messages, labels and file texts all live in the
    // compilation arena, so they must be copied out BEFORE the arena can be
    // freed. This is why no stage frees the arena on error any more — the
    // errdefers that used to do it ran first and left `detach` reading freed
    // memory.
    if (opts.diags) |out| {
        out.* = bag;
        try out.detach(gpa);
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

/// Stages 1–5. Never frees `arena_state`: on success it goes to the
/// `CompileResult`, on failure the caller frees it once the bag is detached.
fn compileInArena(
    gpa: Allocator,
    arena_state: *std.heap.ArenaAllocator,
    source: []const u8,
    target: Target,
    opts: Options,
    bag: *diag.Bag,
) Error!CompileResult {
    const arena = arena_state.allocator();
    var defaults: []const Preprocessor.DefaultDiscipline = &.{};
    var transitions: []const Preprocessor.DefaultTransition = &.{};
    var timescale: ?Preprocessor.Timescale = null;
    // Annex E.2 — how many modules the `spice_netlist` cards contributed to the
    // prelude. Zero unless the caller supplied netlist text.
    var netlist_modules: u32 = 0;
    const text = Preprocessor.process(arena, source, .{
        .include_dirs = opts.include_dirs,
        .file_name = opts.file_name,
        .std_defs = opts.std_defs,
        .spice_netlist = opts.spice_netlist,
        .spice_netlist_modules = &netlist_modules,
        .defaults = &defaults,
        .transitions = &transitions,
        .timescale = &timescale,
        .bag = bag,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The message is already in the bag, with its own file and span — the
        // preprocessor registers every file it opens, so a failure inside an
        // `include names that header rather than the top-level unit.
        error.PreprocessFailed => return error.CompileFailed,
    };

    // --- stage 2: lex (class 1) ---------------------------------------------
    // The annex D.2/D.1/E.1 prelude is a fixed byte prefix of `text` whenever
    // `std_defs` is on, so its tokens are lexed once per PROCESS and memcpy'd
    // in — see `Preprocessor.preludeTokens`. MEASURED (ReleaseFast, min of 500,
    // the 6-line resistor below): 47.6 µs of a 155 µs `.lint` compilation was
    // re-lexing those 11,512 bytes.
    var tokens = try Lexer.Lexer.tokenizeSeeded(arena, text, try Preprocessor.preludeTokens(opts.std_defs));
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);

    // --- stage 3: parse (class 2) -------------------------------------------
    // The same prefix again: the prelude's AST is parsed once per PROCESS and
    // the compilation resumes at the token after it — see
    // `Preprocessor.preludeAst`, which carries the soundness argument (the ids
    // are already a prefix by insertion order; the decls are never written, so
    // they are shared rather than copied). MEASURED (ReleaseFast, min of 500,
    // the 6-line resistor below): parsing the prelude's 2,574 tokens was 82.7 µs
    // of a 109.7 µs `.lint`, against 47.6 µs to lex them. Both seeds come from
    // the same snapshot and are gated on the same `std_defs`, which is what
    // makes "`tags` begins with the prelude's run" true for stage 3 as well.
    var p = try Parser.Parser.initSeeded(arena, text, tags, starts, bag, try Preprocessor.preludeAst(opts.std_defs));
    const file = try arena.create(Ast.SourceFile);
    // Annex E — the shipped Table E.1 primitives are the first declarations in
    // `text`, so they are the first entries of `file.modules`. See
    // `Ast.SourceFile.builtin_modules`: everything that has to distinguish a
    // shipped primitive from the user's own module reads that count, and this is
    // the one place that knows whether the prelude was prepended at all.
    // Annex E.2's netlist-derived modules sit after Table E.1's own rows and
    // before the user's source, so they extend the same leading run.
    const builtins: u32 = if (opts.std_defs) Preprocessor.spice_module_count + netlist_modules else 0;
    file.* = p.parseSourceFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => {
            // The parser recovers at top level, so a diagnosed parse still
            // tells us whether a §6.2 `module` was found at all. When it was
            // not — the file held only design elements VerA has no parser for
            // (`library`, `primitive`) or none that make a device (`paramset`,
            // `connectrules`, parsed since the F.2 wave) — NoModule is the
            // outcome the caller acts on; the
            // precise reason is already in the bag. The prelude's own modules do
            // not count: they are never what was asked for.
            //
            // `connectmodule` and `macromodule` are NOT on that list: both are
            // alternatives of A.1.2's `module_keyword`, both parse, and both land
            // in `file.modules`. A file of nothing but connect modules still has
            // no device, but that is decided later and for a different reason —
            // §7.6 makes a connect module the insertion phase's to place, so
            // `elaborate.pickTop` never picks one and raises NoModule from there.
            if (p.file.modules.len <= builtins) return error.NoModule;
            return error.CompileFailed;
        },
    };
    file.builtin_modules = builtins;
    file.netlist_modules = netlist_modules;

    // --- stage 4: lower (classes 3,4,5,7,9) ---------------------------------
    const mir = try arena.create(Mir);
    mir.* = .{};
    const lower = try arena.create(Lower);
    lower.* = Lower.init(arena, mir, file, text, starts, bag);
    lower.default_disciplines = defaults;
    lower.default_transitions = transitions;
    lower.timescale = timescale;
    lower.include_dirs = opts.include_dirs; // §9.21.1 a $table_model data file
    {
        // SSA maps its matrix directly; the compilation arena cannot free it.
        defer lower.builder.deinit();
        lower.lowerFile() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoModule => {
                try bag.add(.lower, .E1001, .{}, "", .{});
                return error.NoModule;
            },
            error.DiagnosticsReported => return error.CompileFailed,
        };
    }

    // --- stage 4.5: if-convert pure diamonds to §4.2.12 select --------------
    // Before prove: a select's guard facts come from markSelectArms, so the
    // proof sees the same evidence the CFG edge carried, and codegen can emit
    // proven-total conditionals branchless (S.sel) instead of `if`.
    // The arena, not the gpa: ifconv appends to the arena-owned MIR tables.
    _ = try ifconv.run(arena, mir, lower.contributions.items);

    // --- stage 5: PROVE (class 6) — gates every target ----------------------
    // Also the source of the W0650 finiteness WARNING, which is why this runs
    // even when nothing downstream needs the verdict: a `.lint` run exists to
    // tell the user what their model costs.
    const verdict = try proof.proveOpts(gpa, mir, lower, opts.proof, bag);
    errdefer verdict.deinit(gpa);
    // §4.3.2: a domain violation is a compile error on every target.
    if (!verdict.ok()) return error.CompileFailed;

    // §9.4/§9.5. Reported HERE and not in lower.zig, because "was the side
    // effect kept?" is a property of what the caller asked to build, and lowering
    // does not know that. Both are warnings: the model is legal either way.
    for (lower.displays.items) |d| {
        const span = lower.tokenSpan(d.tok);
        if (opts.display == .drop) {
            // §9.5 the file family is on this list for SEQUENCING, not for text,
            // so the sentence it fell foul of is a different one — and the answer
            // it gets is one the LRM writes down rather than a dropped print.
            if (Lower.isFileCall(d.name))
                try bag.add(.lower, .W0850, span, "`{s}` — a device has no host file table, so §9.5.1's zero descriptor is the answer", .{d.name})
            else
                try bag.add(.lower, .W0850, span, "`{s}`", .{d.name});
        } else if (d.conditional) {
            try bag.add(.lower, .W0851, span, "`{s}`", .{d.name});
        }
    }

    return .{
        .gpa = gpa,
        .arena = arena_state,
        .source = text,
        .mir = mir,
        .lower = lower,
        .verdict = verdict,
        .target = target,
        // `opts.diags`, not the compilation's own bag: codegen runs AFTER
        // compileSourceOpts detached the messages into the caller's bag, so the caller's
        // is the only one still alive when E0515 is raised.
        .codegen_opts = .{
            .display = opts.display,
            .jac_f32 = opts.jac_f32,
            .jac_f32_host = opts.jac_f32_host,
            .diags = opts.diags,
            .outline_chunk = opts.outline_chunk,
        },
    };
}

// ---------------------------------------------------------------------------
// Stages 6–8 — codegen + hand-off to the orchestrator
// ---------------------------------------------------------------------------

/// Stage 6 then 7–8. VerA's responsibility ends at the artifact: the host
/// owns dlopen/dlclose and simulation state.
///
/// `resident` is the session-scoped `zig build --listen=-` child required by
/// `.debug`; pass `null` for `.release_fast`, which always builds cold.
pub fn buildArtifact(
    gpa: Allocator,
    io: std.Io,
    result: *CompileResult,
    o: orchestrator.Options,
    generation: u32,
    resident: ?*orchestrator.ResidentChild,
    // Inferred error set: the orchestrator spawns a process and talks a pipe
    // protocol, so its failures are OS-shaped and open-ended. Naming them in
    // `Error` would mean re-listing every IO error the child can produce.
) !orchestrator.Result {
    if (result.target == .lint) return error.NoArtifact;
    const device = try result.generateOutput();
    return switch (result.target) {
        .lint => unreachable,
        .debug => (resident orelse return error.NoResidentChild).rebuild(gpa, device, generation),
        .release_fast => orchestrator.compileRelease(gpa, io, o, device, generation),
    };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn freeArena(gpa: Allocator, a: *std.heap.ArenaAllocator) void {
    a.deinit();
    gpa.destroy(a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    // One test root: pull in every stage so `zig build test` runs their tests.
    _ = token;
    _ = Preprocessor;
    _ = Lexer;
    _ = Ast;
    _ = Parser;
    _ = Mir;
    _ = Analysis;
    _ = Ssa;
    _ = Elaborate;
    _ = Lower;
    _ = proof;
    _ = naming;
    _ = codegen;
    _ = UnitPlan;
    _ = cg_display;
    _ = cg_filters;
    _ = orchestrator;
    // `diag` is a MODULE now: a cross-module `_ = @import(...)` contributes
    // zero tests, so listing it here would quietly drop 20. `test-diag` runs
    // them.
    _ = tb;
}

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
    try std.testing.expectEqual(@as(usize, 2), res.lower.num_ports);
    try std.testing.expect(res.verdict.ok());
    try std.testing.expectEqual(res.unitCount(), res.verdict.unit_modes.len);
    // Direct OS mappings must be gone before returning the arena-owned MIR.
    try std.testing.expectEqual(@as(usize, 0), res.lower.builder.defs.len);
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
    for (bag.messages()) |mi| try std.testing.expect(diag.info(bag.get(mi).code).title.len != 0);

    // And so must rendering, which reads the FILE TEXT the bag detached.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try diag.render(&bag, &aw.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "-->") != null);
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
    var a = try compileSource(gpa, test_resistor, .debug);
    defer a.deinit();
    var b = try compileSource(gpa, test_resistor, .debug);
    defer b.deinit();
    try std.testing.expectEqualStrings(try a.generateDevice(), try b.generateDevice());
}

// The static lib exports no symbol and Zig analyses lazily, so nothing in the
// pipeline is type-checked unless something references it. This test is the
// integration guard: it forces semantic analysis of every top-level pub decl of
// every stage, so `zig build` (which depends on compiling the test roots) means
// "the whole engine type-checks", not just "the files parse".
test "every top-level pub decl of every stage type-checks" {
    inline for (.{ @This(), token, Preprocessor, Lexer, Ast, Parser, Mir, Analysis, Ssa, Elaborate, Lower, proof, naming, codegen, UnitPlan, cg_display, cg_filters, orchestrator }) |stage| {
        std.testing.refAllDecls(stage);
    }
}
