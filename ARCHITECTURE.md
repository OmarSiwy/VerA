# VerA — target architecture

Status: proposal, **phases 0 and 1 landed**. See §8 for what implementing them
taught, including two places where this document was wrong.

## 0. Verdict first

I read all 71k lines (`lib/` 64.5k, `src/` 6.4k) before writing this. The honest
finding is that **this codebase does not need a rewrite.** Three things are
already right and a rewrite would put them at risk:

- **The stage axis is already correct.** `preprocess → lex → parse → elaborate →
  lower+ssa → ifconv → prove → codegen` maps 1:1 onto directories, each IR form
  is entered once and exited once, and `build.zig:41` *enforces* the dependency
  order with a panic on cycles. There is no layering violation anywhere. `sim/`
  correctly takes only `frontend`.
- **The data layout is already data-oriented.** `Mir.insts` / `blocks` / `defs`
  are `MultiArrayList` (mir.zig:358), the AST is SoA columns (ast.zig:235),
  tokens are SoA (lexer.zig:45), handles are `enum(u32)` newtypes, provenance is
  a cold column with the reasoning written down (mir.zig:282). `proof.zig:202`
  carries a *measurement table* showing a SIMD attempt losing to `@memset`. This
  project already does DOD and already measures.
- **1557 fixtures and 561 in-file tests.** That is the only reason the migration
  below is safe.

What is actually wrong is narrow and specific:

| Problem | Where | Size |
|---|---|---|
| Two god structs | `Lower` (125 fields), `Gen` (91 fields) | plumbing across ~23k lines |
| One missing trait | analog-operator facts scattered over 5 files | ~700 lines of parallel switches |
| Pure logic trapped in god structs | constfold, discipline, domain tables, hoist policy | ~1.6k lines untestable in isolation |
| Unenforced normative contract | `node_order` ↔ `unit_modes` ↔ `naming` index order | silent-corruption class |
| Boilerplate | 78 diag builder chains, 8 VPI C-ABI preambles | ~400 lines |

So this document proposes a **full re-cut, not a rewrite**. Measured against the
current tree:

- **~70% of lines move to a new path unchanged** (mir, ssa, analysis, elaborate,
  ifconv, integer, lexer, token, ast, naming, unit_plan, kernel blobs,
  orchestrator, tb, scheduler, time).
- **~25% are split verbatim** along existing seams (parser, preprocessor, diag,
  diag_code, digital) — cut, not edited.
- **~5% (3–4k lines) are genuinely rewritten**: god-struct plumbing and the
  switches the op table replaces.

If that ratio ever drifts, the migration has gone wrong and should stop.

---

## 1. The data (DOD: six questions, answered)

The skill requires these stated before any code. For the central transform:

1. **In / out.** `[]const u8` (source) → `[]const u8` (Zig device text). Between
   them: tokens (SoA, ~5 B/tok) → AST (SoA, ~24 B/expr) → MIR (SoA, 21 B hot +
   4 B cold per instruction) + side tables → `Verdict` (1 byte per unit) →
   text.
2. **How many?** Per compilation: 10²–10⁵ tokens, 10³–10⁵ MIR instructions,
   10¹–10³ units, 10⁰–10² unknowns (hard cap 256, `codegen.zig:1700`). Small.
   **The compiler is not the hot loop.** See §5.
3. **How wide?** `Opcode` `u8` (68 variants). `Op` (analog operator) `u8` (14).
   Unknown index `u8` — the 256 cap is already enforced. Unit index `u16`.
   Value/Block/Inst `enum(u32)`. `no_tok = maxInt(u32)` is already the niche
   (mir.zig:295) — keep that pattern, do not add `?u32`.
4. **Access pattern.** Every backend pass is a **column walk**: proof reads
   `.op` and `.a`, the relooper reads `.op`/`.a`/`.b`/`.c`, diagnostics read
   `.tok` only on the cold path. Already correct. The *god structs* are the
   violation: `Gen` drags 91 fields through a walk that touches 6.
5. **Lifetime.** One arena per compilation; `CompileResult` owns it
   (`lib/root.zig`). Already correct. The new `Plan` types below are arena
   values, not heap objects.
6. **Parallelizable?** Per-unit emission is disjoint and could be a
   `std.Io.Group` over units. **Not proposed.** A 39-device catalog builds in
   ~5s (`src/main.zig:571`); this is not the bottleneck. Recorded as a
   possibility the layout below leaves open, not as work.

---

## 2. The rule

Your four axes, in precedence order. Every file's path is decided by applying
them top to bottom:

```
1. STAGE     which compiler step   → the directory
2. TRAIT     same shape            → one table drives every implementation
3. PURITY    decides vs. writes    → Plan (pure) / Emit (impure) file split
4. CONCERN   backend only          → opt / float / events / feat
```

Two corollaries that do the real work:

- **Purity is a file boundary, not a comment.** A `plan/` file takes
  `(arena, *const Mir, *const Facts, Options)` and returns a value. It has no
  writer, no `*Gen`, no diagnostics. It is therefore testable with
  `std.testing.allocator` and three lines of setup. Today `planPrecompute`,
  `planHoistPrefix` and `planCommon` are pure decisions that need a fully
  constructed 91-field `Gen` to call — which is exactly why `unit_plan.zig` has
  **0 tests** and `proof.zig` (already nearly pure) has **28**. The test count
  is the diagnostic.
- **A trait is a comptime-exhaustive table, never a vtable.** DOD rule 8: no
  hidden control flow. Adding an enum variant must fail to compile until its row
  exists.

---

## 3. Target tree

★ = new file. ▸ = split of an existing file, contents move mostly verbatim.
Everything unmarked moves path-only.

```
lib/
  root.zig                        facade — unchanged

  support/
    ids.zig                       Value/Block/StrId/ExprId newtypes, niche rules
  ★ contract.zig                  the normative index-order contract (§4.6)

  diag/
    root.zig
  ▸ bag.zig                       collection             (from diag.zig)
  ▸ render.zig                    text + json            (from diag.zig)
  ▸ source_map.zig                offset → line          (from diag.zig)
  ★ report.zig                    the one-call helpers   (§4.5)
  ▸ codes.zig                     the enum only, ~300 lines
  ▸ catalogue.zig                 the Info table, ~4.5k  (from diag_code.zig)

  frontend/
    root.zig  lexer.zig  token.zig  ast.zig  integer.zig  spice_cards.zig
    parser/
  ▸   root.zig                    Parser struct + recovery
  ▸   decl.zig  stmt.zig  expr.zig          (split of parser.zig, 4980)
    pp/
  ▸   root.zig                    directive loop         (from preprocessor.zig)
  ▸   macro.zig                   the expansion engine
  ▸   annex_d.zig                 the embedded VAMS tables — ~900 lines of DATA

  sema/
    elaborate.zig                 unchanged
  ▸ discipline.zig                PURE: §3.6 nature/discipline compat
                                  (lower.zig:2101-2428)
  ▸ constfold.zig                 PURE: constEval/foldExpr
                                  (lower.zig:10234-10677)

  ir/
    mir.zig                       unchanged — already SoA
    ssa.zig                       unchanged
  ★ op.zig                        THE ANALOG-OPERATOR TABLE (§4.1)
    lower/
  ▸   root.zig                    the driver, ~30 fields
  ▸   module.zig                  ports / nets / params
  ▸   stmt.zig  expr.zig  contrib.zig  systask.zig
  ★   tables.zig                  `Lowered` — the side tables, as an output type

  analysis/
    facts.zig                     was ir/analysis.zig — unchanged
    ifconv.zig                    unchanged
    proof/
  ▸   root.zig                    the walk
  ▸   domain.zig                  PURE: §4.3 domain tables
  ▸   interval.zig                PURE: interval arithmetic

  codegen/
    root.zig                      the driver, ~20 fields
    plan/                         ← PURE. no writer in this directory.
      unit.zig                    was unit_plan.zig — now testable
  ▸   hoist.zig                   precompute + prefix cache (codegen 834-1224)
  ▸   outline.zig                 chunking                 (the oc_* fields)
  ▸   common.zig                  shared-core live-outs    (codegen 739-807)
    emit/
  ★   writer.zig                  the emit abstraction (§4.4)
  ▸   topology.zig  model.zig  instance.zig
  ▸   expr.zig                    renderInst / renderVal / renderCond
  ▸   cfg.zig                     the relooper
  ▸   stamps.zig                  residual / charge / Jacobian
  ▸   dispatch.zig                eval / q / updateState / initState
    float/                        ← CONCERN: floats
  ▸   mode.zig                    strict vs optimized
  ▸   lanes.zig                   pinLanes / lane_clean / batch gating
  ▸   precision.zig               jac_f32 / jac_f32_host
    events/                       ← CONCERN: events
  ▸   operator.zig                §4.5 emission, driven by ir/op.zig
  ▸   state.zig                   updateState / stateCtl
  ▸   cross.zig                   §5.10.3 cross / above / timer
      filters.zig                 was cg_filters.zig
    feat/                         ← the FEATURE trait (§4.3)
  ★   root.zig                    the comptime feature list
      display.zig                 was cg_display.zig
      limit.zig                   was cg_limit.zig
  ▸   table_model.zig  rng.zig  file.zig  str.zig
    kernels/
  ★   root.zig                    the kernel gate table (§4.2)
      *.zig                       the existing blobs, unchanged
    naming.zig

  build/
    orchestrator.zig  tb.zig      unchanged

src/
  main.zig
  ★ cli/args.zig                  the flag table (§4.7)
  sim/
    root.zig  scheduler.zig  time.zig
    digital/
  ▸   root.zig                    the Run driver
  ▸   compile.zig                 AST → bytecode
  ▸   exec.zig                    the interpreter
  ▸   net.zig                     §7.9 resolution + strength
  ▸   display.zig                 §17 display / monitor / strobe
  vpi/
  ▸ root.zig                      the exports, nothing else
  ▸ design.zig                    the model build
  ★ entry.zig                     the C-ABI guard (§4.5)
```

`build.zig`'s `module_specs` gains `sema` and `analysis` between `frontend` and
`codegen`. The existing cycle panic keeps enforcing the order for free.

---

## 4. The traits

### 4.1 `Op` — the analog operator. *The one that matters.*

Today, one operator's facts are spread across five files. For `transition`:
`lower.zig` ×9, `codegen.zig` ×53, `cg_filters.zig` ×3, plus its state fields in
`emitInstance`, its advance in `emitStateMachine`, its arity in `unit_plan`.
Adding §4.5.6 `ddx` variants means finding all of them.

This is a **table with one row per operator and one column per consumer**:

```zig
// lib/ir/op.zig — the single source of truth for §4.5 / §5.10.3 operators.
const std = @import("std");

pub const Op = enum(u8) {
    ddt, idt, idtmod, absdelay, transition, slew, last_crossing,
    laplace, zi, cross, above, timer, bound_step, discontinuity,
};

/// One `Instance` field this operator owns. `emitInstance` writes these; it
/// does not know what any of them mean.
pub const Slot = struct {
    suffix: []const u8,            // "prev" -> `<unit>__prev`
    ty: enum { f64, i64 },
    init: []const u8,              // "0.0"
};

pub const Row = struct {
    lrm: []const u8,               // "§4.5.3" — the doc comment, as data
    kernel: []const u8,            // "zDdt"
    gate: kernels.Gate,            // which kernel blob must be emitted (§4.2)
    slots: []const Slot,           // Instance state
    /// Does the kernel read the CURRENT input? (was codegen.opNeedsInput)
    needs_input: bool,
    /// Does updateState need `dt`? (was the inline switch at codegen.zig:7297)
    needs_dt: bool,
    /// §5.10.3: index of the `enable` arg — the one control arg that stays a
    /// runtime value. (was codegen.enableArgIdx)
    enable_arg: ?u8,
    /// Args folded at codegen time. `UnitPlan.callArgIsValue` reads this.
    ctl_args: u8,
};

pub const table = std.EnumArray(Op, Row).init(.{
    .ddt = .{
        .lrm = "§4.5.3", .kernel = "zDdt", .gate = .hist,
        .slots = &.{.{ .suffix = "prev", .ty = .f64, .init = "0.0" }},
        .needs_input = true, .needs_dt = false, .enable_arg = null, .ctl_args = 1,
    },
    .transition = .{
        .lrm = "§4.5.8", .kernel = "zTransition", .gate = .hist,
        .slots = &.{
            .{ .suffix = "from", .ty = .f64, .init = "0.0" },
            .{ .suffix = "to",   .ty = .f64, .init = "0.0" },
            .{ .suffix = "t0",   .ty = .f64, .init = "0.0" },
        },
        .needs_input = true, .needs_dt = true, .enable_arg = null, .ctl_args = 4,
    },
    .cross = .{
        .lrm = "§5.10.3.1", .kernel = "zCross", .gate = .timer,
        .slots = &.{.{ .suffix = "prev", .ty = .f64, .init = "0.0" }},
        .needs_input = true, .needs_dt = false, .enable_arg = 4, .ctl_args = 4,
    },
    // ... one row per variant. An omitted variant is a compile error.
});

/// The §9.17 spellings differ between the MIR callee (`$bound_step`) and the
/// naming.zig unit target (`bound_step`), and laplace/zi have four each. The
/// mapping stays a StaticStringMap — that part of today's `opKind` is right.
pub fn byName(name: []const u8) ?Op { ... }
```

Every consumer collapses to a column read:

```zig
// codegen/emit/instance.zig — was ~150 hand-written lines across 10 switch arms
for (units, 0..) |u, i| {
    const o = op.byName(u.target) orelse continue;
    for (op.table.get(o).slots) |s|
        try w.field("{s}__{s}", .{ names[i], s.suffix }, s.ty, s.init, op.table.get(o).lrm);
}
```

```zig
// codegen/events/state.zig — was the inline switch at codegen.zig:7297
const needs_dt = for (units) |u| {
    if (op.byName(u.target)) |o| if (op.table.get(o).needs_dt) break true;
} else false;
```

Deletes: `opNeedsInput`, `enableArgIdx`, the `uses_dt` switch, the
`emitInstance` arms, `lower.isHistoryless`. **One row added per new operator,
and the compiler names every site that still needs a decision.**

### 4.2 `Kernel` — the embedded runtime text

Fourteen blobs (`header_txt`, `math_txt`, `ops_txt`, `timer_txt`, `hist_txt`,
`filt_txt`, `str_txt`, `rng_txt`, `table_txt`, `file_txt`, `limit_txt`,
`display_txt`, `pscalar_txt`, `rscalar_txt`) each paired by hand with a boolean
on `Lower` and threaded through `buildPrelude` (`codegen.zig:1419-1600`). Same
shape fourteen times:

```zig
// lib/codegen/kernels/root.zig
pub const Gate = enum { core, math, ops, hist, filt, timer, str, rng, tbl, file, limit, display };

pub const Blob = struct {
    text: []const u8,
    deps: []const Gate,            // emitted before this one
    /// Which `Lowered` flag turns it on. `.core` is always on.
    live: *const fn (*const Lowered) bool,
};

pub const blobs = std.EnumArray(Gate, Blob).init(.{
    .core = .{ .text = @embedFile("core.zig.txt"), .deps = &.{}, .live = always },
    .hist = .{ .text = @embedFile("hist.zig.txt"), .deps = &.{.core}, .live = usesHistory },
    .rng  = .{ .text = @embedFile("rng.zig.txt"),  .deps = &.{.core}, .live = usesRng },
    // ...
});

/// Topologically ordered, deduped, deterministic. One loop replaces the
/// hand-threaded flag list in buildPrelude.
pub fn emitLive(w: *Writer, lowered: *const Lowered) !void { ... }
```

The blobs move from `const x_txt = \\...` to `@embedFile` of a real `.zig.txt`
file. Bonus: they become syntax-highlightable and diffable, and the 2.7k lines
of embedded strings leave `codegen.zig`.

### 4.3 `Feature` — one optional language feature's codegen

`cg_display`, `cg_limit`, `cg_filters` are the right idea with three different
shapes. Unify to four optional hooks, dispatched by `inline for` over a comptime
tuple — no function pointers, no vtable, monomorphized:

```zig
// lib/codegen/feat/root.zig
pub const list = .{
    @import("display.zig"),
    @import("limit.zig"),
    @import("table_model.zig"),
    @import("rng.zig"),
    @import("file.zig"),
    @import("str.zig"),
};

/// The shape every member must have. Checked at comptime; a missing hook that
/// the feature needs is a compile error, not a runtime surprise.
comptime {
    for (list) |F| {
        _ = @as(fn (Allocator, *const Mir, *const Lowered) anyerror!?F.Plan, F.collect);
        _ = @as(fn (*const F.Plan, *Writer) anyerror!void, F.decls);
    }
}

pub fn collectAll(arena: Allocator, mir: *const Mir, lo: *const Lowered) !Plans {
    var out: Plans = .{};
    inline for (list) |F| @field(out, F.name) = try F.collect(arena, mir, lo);
    return out;
}
```

Each feature file then reads:

```zig
// lib/codegen/feat/limit.zig
pub const name = "limit";
pub const Plan = struct { slots: []const Slot, prep: []const Mir.Value };

/// PURE — decides. No writer, no *Gen. This is the part that gets tests.
pub fn collect(arena: Allocator, mir: *const Mir, lo: *const Lowered) !?Plan { ... }

/// IMPURE — writes. Takes the plan and never decides anything.
pub fn decls(p: *const Plan, w: *Writer) !void { ... }
pub fn body(p: *const Plan, inst: Mir.Inst, w: *Writer) !void { ... }
```

That split is the whole point of the purity axis, in nine lines.

### 4.4 `Writer` — the emit abstraction

Today: `self.w(fmt, args)` and `self.b(fmt, args)` both `print` into the same
`ArrayList`, with indentation tracked in an `ind_base` field and signature
back-patching done by byte-offset splicing (`codegen.zig:3307`). It works, but
the caller carries formatting state that belongs to the sink.

```zig
// lib/codegen/emit/writer.zig
pub const Writer = struct {
    out: *std.ArrayList(u8),
    gpa: Allocator,
    indent: u8 = 0,

    pub fn line(w: *Writer, comptime fmt: []const u8, args: anytype) !void;
    pub fn open(w: *Writer, comptime fmt: []const u8, args: anytype) !void; // line + indent++
    pub fn close(w: *Writer, comptime s: []const u8) !void;                 // indent-- + line
    pub fn raw(w: *Writer, text: []const u8) !void;                         // kernel blobs

    /// Reserve a span to fill in later — replaces offset-splicing with a
    /// checked handle. `patch` asserts the replacement is the reserved width.
    pub fn hole(w: *Writer, width: u16) !Hole;
    pub fn patch(w: *Writer, h: Hole, text: []const u8) void;
};
```

Not a rewrite of emission — a rename of `w`/`b` plus `indent` moving one level
down. Cheap, and it makes `emit/` files readable as the text they produce.

### 4.5 Boilerplate: two helpers, ~400 lines

**78 sites** in `lower.zig` spell the same four lines:

```zig
var b = self.errWith(tok, .E0430);
b.msg("`{s}`", .{name});
b.note("the nature is declared here", .{});
try b.emit();
```

```zig
// lib/diag/report.zig — the builder stays for the rare multi-note case.
pub fn one(bag: *Bag, tok: u32, code: Code,
           comptime m: []const u8, ma: anytype) !void;
pub fn note(bag: *Bag, tok: u32, code: Code,
            comptime m: []const u8, ma: anytype,
            comptime n: []const u8, na: anytype) !void;
```

**8 sites** in `src/vpi/root.zig` spell the same C-ABI preamble (clear error,
check design, validate handle, describe on failure):

```zig
// src/vpi/entry.zig
inline fn open(comptime fname: []const u8) ?*Design {
    clearError();
    return &(design orelse {
        fail("NODESIGN", fname ++ ": no design is open", .{});
        return null;
    });
}
inline fn obj(comptime fname: []const u8, h: vpiHandle) ?*Obj { ... }
```

Call site drops from 9 lines to 2. The two return spellings (`null` vs
`vpiUndefined`) stay at the call site where they belong — that is the C ABI, not
duplication.

### 4.6 The contract file — the one genuine correctness gap

`proof.zig:47` states it as a comment: `unit_modes[i] ↔
lower.contributions.items[i]`. `naming.zig:229` states the parallel rule for
unit order. `codegen` depends on both. **Nothing enforces either.** Reordering an
`appendNode` call in `lower.zig` silently mis-indexes every unit's float mode —
a wrong-answer bug with no diagnostic.

```zig
// lib/support/contract.zig
//! The three index orders that must agree, and the assertion that they do.
//!
//!   lower.contributions[i]  ↔  naming.enumerateUnits()[i]  ↔  verdict.unit_modes[i]
//!
//! Called once at the end of lowering and once at the top of codegen. Costs
//! O(units) — a few hundred iterations on the largest model in the catalogue.

pub fn assertUnitOrder(lo: *const Lowered, units: []const naming.Unit,
                       v: ?*const proof.Verdict) void {
    std.debug.assert(units.len == lo.contributions.items.len);
    if (v) |verdict| std.debug.assert(verdict.unit_modes.len == units.len);
    for (units, lo.contributions.items) |u, c| std.debug.assert(u.matches(c));
}
```

This is phase 0 of the migration and the only item on this page that fixes a
live bug class rather than an ergonomic one.

### 4.7 CLI flags

`src/main.zig:175-282` is a 110-line `else if` chain over 30 flags, with the
conflict rules re-derived afterwards from six shadow booleans
(`lint_flag`, `display_drop_flag`, `codegen_flag`, `exe_flag`, ...). The
comment at 159-162 explains *why* the shadows exist, which is the tell.

```zig
// src/cli/args.zig
const Flag = struct {
    name: []const u8,
    arg: enum { none, value, inline_eq },
    field: []const u8,              // field of Options to set
    implies_codegen: bool = false,
};
const flags = [_]Flag{ ... };

/// Conflicts declared as data, checked once, reported by NAME — which is
/// already the behaviour main.zig:284-304 hand-rolls.
const conflicts = [_]Conflict{
    .{ .a = "--lint", .b = .any_codegen, .why = "--lint stops after the frontend" },
    .{ .a = "--emit-exe", .b = .flag("--display=drop"), .why = "the testbench IS the display output" },
};
```

~110 lines → ~40 + a table. Skipped: a general arg-parsing library. 30 flags do
not need one.

---

## 5. Where SIMD actually is

The `simd-loops` triage, run honestly on this project, gives an answer worth
writing down because it contradicts the instinct:

**The compiler is not a SIMD target.** Per compilation it walks 10³–10⁵ MIR
instructions once. That is below the "few hundred elements upward" bar only
sometimes, but more decisively: every backend walk is a **chain** — `emitCode`
walks a dominator tree, `renderInst` output length is data-dependent, SSA
construction is recursive. Triage says: report it and stop. `proof.zig:202`
already proves this empirically with a measurement table where a `@Vector`
attempt *loses* at every size up to 24578.

The three existing `@Vector` uses are exactly the right three and should not be
touched:

| Site | Shape | Why it qualifies |
|---|---|---|
| `token.zig:532` | accumulator over a fixed keyword table | contiguous, no dependency |
| `preprocessor.zig:1116` | single-needle byte scan | first-match reduce |
| `tb.zig:1394` | `@Vector(NL, f64)` in **generated** code | ← the real one |

**SIMD-first applies to the output, not the compiler.** The emitted device's
`eval` is called millions of times inside a Newton loop; that is the hot loop
this project exists to make fast. And the decisions that govern its lane
behaviour — `pinLanes`, `lane_pinned`, `lane_clean`, `jac_f32`, `cur_strict` —
are today **five fields scattered through a 91-field struct**, with no file you
can point at to answer "what makes a lane dirty?"

That is the entire justification for `codegen/float/` as a top-level concern
(your fourth axis). `float/lanes.zig` owning lane gating, `float/mode.zig`
owning strict-vs-optimized, and `float/precision.zig` owning the f32 Jacobian
permission is not tidiness — it is putting the SIMD story of the generated code
in one readable place, where the next person can find the knob.

Also honoured, per the skill's calibration note: the hardware knobs stay. The
`--unknown-bound=` compliance limit, `--outline-chunk=N`, `jac_f32` and the
`abstol` table are physical-world tuning and none of them get simplified away.

---

## 6. Migration plan

**The invariant, enforced at every phase boundary:**

```sh
zig build test                              # 561 in-file tests
zig build test-devices                      # digital transcript diffs
# and the one that matters:
#   every one of the 1557 fixtures in tests/fixtures must produce a
#   BYTE-IDENTICAL device.zig before and after the phase.
```

Byte-identity is the right gate because every phase below is explicitly
behaviour-preserving. The moment a phase needs a golden updated, it has stopped
being a refactor. Add a `zig build test-goldens --baseline <ref>` step in phase 0
that diffs generated output against a stashed baseline tree; it is ~40 lines of
`build.zig` and it is what makes the rest of this safe.

Tests are in-file (`lower.zig:10957+` ≈ 860 lines, `codegen.zig:9190+` ≈ 2640
lines). **Tests move with the code they test, in the same commit.** A split that
leaves tests behind is how coverage silently drops.

| # | Phase | Touches | Risk | Why here |
|---|---|---|---|---|
| **0** | Golden baseline step + `support/contract.zig` | build.zig, +1 file | none | Nothing else is safe without it. Fixes a live bug class. |
| **1** | `ir/op.zig` table; rewire the 5 consumers | +1 file, ~700 lines deleted | low | Pure addition then deletion. Biggest payoff per line. Proves the trait pattern before betting the god structs on it. |
| **2** | Pure extractions: `sema/constfold.zig`, `sema/discipline.zig`, `proof/domain.zig`, `proof/interval.zig` | ~1.6k lines moved | low | Mechanical. Each becomes unit-testable the day it lands. Shrinks `Lower` by ~800 lines before phase 4 touches it. |
| **3** | `diag/` and `frontend/` splits; `pp/annex_d.zig`; kernel blobs → `@embedFile` | ~12k lines moved verbatim | low | Cut-only, no edits. Gets the easy 12k out of the way so later diffs are readable. |
| **4** | `codegen/plan/` — hoist, outline, common extracted as pure functions | ~1.2k lines | **medium** | The first real re-cut. `Gen` 91 → ~55 fields. Do this before `emit/` so emission has a `Plan` to read. |
| **5** | `codegen/{emit,float,events,feat}/` — the concern split | ~6k lines | **medium** | `Gen` ~55 → ~20. Depends on 1 (op table) and 4 (plans). |
| **6** | `ir/lower/` split + `Lowered` as an output type | ~10k lines | **high** | Left latest deliberately: phases 1–2 already removed ~1.5k lines and the `Lowered` boundary is only clear once codegen's needs are explicit. `Lower` 125 → ~30 fields. |
| **7** | Boilerplate: `diag/report.zig` (78 sites), `vpi/entry.zig` (8 sites), `cli/args.zig` | ~400 lines | low | Pure win, no dependencies. Can land any time after 3 — scheduled last so it doesn't collide with 4–6's diffs. |
| **8** | `src/sim/digital/` split | ~3.4k lines | medium | Independent of `lib/` entirely. Can run in parallel with 4–6 on its own branch. |

**Sequencing rationale.** 1 and 2 are the load-bearing ones: they are low-risk,
they delete more than they add, and together they take ~2.3k lines out of the two
god structs *before* anything structural touches them. If the effort is
abandoned after phase 2, the codebase is strictly better and nothing is
half-migrated. That is the property to preserve — **every phase is independently
shippable and independently revertible.**

**Per-phase discipline:**
- One phase = one branch = one PR. Never two phases in flight in `lib/`.
- Phase 8 may run concurrently (disjoint tree).
- A phase that cannot keep goldens byte-identical stops and gets re-scoped.
- No behaviour changes, no bug fixes, no "while I'm here". Those are separate
  commits before or after, never inside.

---

## 7. Deliberately not doing

- **Not re-architecting the pipeline.** AST → flat AST → MIR → verdict → text is
  correct and every stage is justified by what the next one needs. Both audit
  passes looked for a redundant IR form and found none.
- **Not externalising `diag_code.zig`.** 4785 lines of data, but Zig needs the
  tag names in the enum for `@tagName`, the codes are pinned by fixtures and
  never renumbered, and comptime residency means zero allocation when no
  diagnostic fires. Moving it to TOML buys nothing and costs a load. Split the
  enum from the catalogue (phase 3) and stop.
- **Not parallelising codegen.** Disjoint per unit, so the layout leaves it
  open, but 39 devices build in ~5s. Add it when a measurement asks.
- **Not adding SIMD to the compiler.** §5. The one place a `@Vector` was tried it
  lost, and the measurement is in the tree.
- **Not touching `mir.zig`, `ssa.zig`, `analysis.zig`, `elaborate.zig`,
  `naming.zig`, `integer.zig`.** They are already what this document is asking
  everything else to become.
- **Not introducing a vtable anywhere.** Every "trait" here is a comptime table
  or a comptime tuple. DOD rule 8.
- **Not splitting `parser.zig` by grammar production.** Three files (decl/stmt/
  expr) is the seam; twelve would be worse than one.

---

## 8. What landed, and where this document was wrong

Phases 0 and 1 are implemented. 514 tests pass and all 1557 fixtures produce
byte-identical output. Two corrections to the plan above, both found by reading
the code the plan described:

**§4.6 was in the wrong place.** `support/contract.zig` cannot work: the
assertion needs `naming.Unit`, `Lower` and the verdict length, and a
bottom-of-stack module can import none of them. It shipped as
`naming.assertCanonicalOrder` — which is where `proof.zig:168` had already said
to put it (*"naming.zig must agree with this (assert it there)"*), an
instruction written and never followed. **Rule learned: a file's home is decided
by what it must import, not by what it is about.** `support/` in §3 should be
read with that caveat; anything landing there must import nothing but `std`.

**§4.1's payoff was overstated.** I estimated −500 net lines from the op table.
Actual: **−115 in `codegen.zig`, +348 for `lib/ir/op.zig`** (117 of those
comment, most of it prose relocated from the arms it replaced). The gap is that
`emitInstance` does not collapse the way the audit summary implied — `absdelay`
queries `absdelayFreezes(opArgs)` and `laplace`/`zi` call `filterPlan` for their
array lengths, so 3 of 14 arms are genuinely data-dependent and stay. Nine
collapsed to one loop; five scattered `switch (opKind ...)` remain in
`codegen.zig` and are correct where they are.

Also wrong: `lower.isHistoryless` does **not** duplicate the op table. It is
`ddx or limexp` — the two §4.5 functions that own no state — which duplicates
`naming.isStatefulAnalogOp`'s exclusion. A real one-line dedup, a different one,
and not worth its own phase.

**What the table actually bought** is not line count, and the migration plan
should have said so. Before: adding an `OpKind` variant compiled silently and
gave the new operator `needs_input = false`, `enable_arg = null`, no state
fields and no `dt` — four wrong answers, no diagnostic. After: `error: missing
struct field`. Verified by adding a variant and watching it fail. That is the
same bug class as §4.6, and it is why both phases were worth a session even
though one of them adds more lines than it removes.

**Estimate accordingly.** Both of this document's line-count claims came from
audit summaries rather than from the code, and both were too optimistic.
Treat every remaining number in §6 as unverified until the phase is read.

**The harness.** `tools/golden-baseline.sh <tag>` snapshots stdout+stderr+exit
for all 1557 fixtures in ~25s and is verified deterministic; `diff -r` between
two tags is the gate. It is a shell loop rather than the §6 build step on
purpose — the build graph cannot see fixture contents, so a cacheable Run step
would cache a pass for a golden nobody compared (`build.zig`'s own note on
`test-devices` makes the same point).
