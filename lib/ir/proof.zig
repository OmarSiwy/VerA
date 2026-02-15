//! Class 6 — Numerical safety / finiteness proof pass.
//!
//! LRM basis: §4.3.1/§4.3.2 math-function domains (Tables 4-14/4-15), §4.3.2
//! "input outside the valid range shall report an error", §3.4.2 parameter
//! value ranges, §3.6.1.2 nature tolerances, §4.5.15 operator restrictions,
//! §5.8.4 conditional restrictions.
//!
//! Transformation: MIR + Lower side tables → per-unit float-mode verdict, OR a
//! compile error for a provably-unsafe domain violation.
//!
//! CONTRACT:
//!   - Runs on EVERY target (lint/debug/release). Debug and Release accept the
//!     exact same set of models — no mode-specific semantics. Nothing in this
//!     file reads a target.
//!   - This pass does not synthesize runtime math-domain checks. System
//!     functions can validate their own argument domains in emitted kernels.
//!   - VerA is SPEC-FAITHFUL: `exp` (domain "All x", §4.3.2) is NEVER
//!     rejected — the LRM permits inf and makes `limexp` (§4.5.13) optional.
//!     Unprovable-finite units simply get `.strict` (below), not a rejection.
//!   - The engine NEVER inserts a clamp, a floor or a `limexp`.
//!   - DOMAIN CHECKS ARE THREE-WAY, not two (LRM §4.3.2 obliges reporting a
//!     value that IS out of range, not rejecting a program whose values MIGHT
//!     be):
//!         provably OUTSIDE  -> compile error
//!         provably INSIDE   -> ok, `.optimized` still reachable
//!         unprovable        -> ACCEPTED, forfeits `finite` -> unit `.strict`
//!     This is the same treatment `exp` gets above, and it is what keeps the
//!     accepted set EQUAL to the LRM's. Interval arithmetic cannot decide the
//!     common `x = V/(1+abs(V))` idiom (it must correlate two occurrences of
//!     V), so a stronger abstract domain would not rescue those legal models —
//!     only this policy does.
//!   - `/` BY ZERO IS NOT AN ERROR. §4.2.4's only zero rule is "It shall be an
//!     error to pass zero (0) as the second argument to the MODULUS operator".
//!     `x/0.0` is an exact IEEE ±inf, so it is accepted and forfeits `finite`.
//!     Rejecting it would refuse `I <+ V/r` — the plain resistor, and every
//!     foundry compact model, which divide by unranged parameters.
//!     Integer `/` and `%` DO stay errors: `@divTrunc(i64, 0)` is illegal
//!     behavior in Zig, and integers have no inf to fall back on.
//!
//! DOD: three SoA arrays indexed by `Mir.Value` (interval, finite bit, guard
//! ref). Instructions are walked once, in dominator-tree preorder. No per-op
//! allocation; all scratch lives in one arena that dies with `prove`.
//!
//! ─────────────────────────────────────────────────────────────────────────
//! UNIT ORDERING (normative — naming.zig and codegen.zig MUST match)
//!
//!   unit_modes[i]  ↔  lower.contributions.items[i]
//!
//! One unit per `Lower.Contribution` (which is already one per (access, node
//! pair), §5.6.1.3 — not one per `<+` statement; the exception is a §5.6.7
//! INDIRECT contribution, where each statement is its own equation and so its
//! own entry), in `Lower.contributions` append order, `naming.Role.analog`,
//! target = access + node pair. The mode is
//! the JOIN over both `resist_val` (→ eval) and `react_val` (→ q): a unit gets
//! `.optimized` only if BOTH its slices are proven finite, because codegen emits
//! one `@setFloatMode` per unit function. A §5.6.7 indirect contribution needs
//! no special case: its constraint row lives in `resist_val` like any other
//! unit value (`react_val` stays `.f_zero`), so the same slice walk rates it.
//!
//! A §5.4.3 PORT PROBE (`I(<p>)`, `lower.port_probes`) adds NO unit and does
//! not perturb this indexing. Like the branch-relation row of a §5.6 potential
//! contribution, its row (`x[flow(<p>)] − res[p]`) is assembled inline in
//! codegen's residual dispatcher out of values the contribution units already
//! produced; there is no separate body to rate, so naming.zig and this file
//! stay unchanged. If a future port form ever needs its own body, it becomes a
//! new unit kind and the rule below applies.
//!
//! `unitCount(lower)` is the authoritative length. If naming.zig ever emits
//! additional unit kinds (user functions §4.7, named blocks §5.3.2, analog-
//! operator sub-units §4.5), they MUST be appended AFTER the contribution units
//! and this file extended in the same commit — never interleaved.
//! ─────────────────────────────────────────────────────────────────────────
//!
//! SOUNDNESS MODEL (read before touching `finite`)
//!
//! `.optimized` compiles to `@setFloatMode(.optimized)`, which asserts nnan AND
//! ninf. A wrong `.optimized` is silent, Release-only, convergence-corrupting
//! UB, so every rule below errs toward `.strict`.
//!
//!   1. INPUTS ARE FINITE. Solver unknowns (§4.4 probes) and model-card
//!      parameters (§3.4) are finite IEEE doubles — that is the host artifact
//!      contract. Being *finite* is
//!      separate from being *bounded*: a probe is finite with an unknown
//!      magnitude, so its interval is (-inf, inf) but its `finite` bit is set.
//!      A parameter whose declared range explicitly ADMITS `inf` (`from [0:inf]`)
//!      is not finite.
//!   2. OVERFLOW IS TRACKED WHERE IT IS REAL. `exp`/`expm1`/`sinh`/`cosh`/`pow`
//!      overflow at ordinary device magnitudes (exp(710)), so they are proven
//!      exactly: unbounded argument ⇒ `.strict`.
//!   3. `+ - * /` on finite operands are assumed not to overflow
//!      (`Options.arith_overflow = .assume_absent`, the default): reaching 1e308
//!      in a residual means the Newton iterate already diverged, which is the
//!      host's convergence check, not a language property. Set
//!      `.tracked` to demand bounded intervals there too — that is the
//!      calibration knob, not a code change.
//!   4. Anything unmodelled (a `call`: analog operators §4.5, ch9 system
//!      functions) is non-finite. It costs `.strict`, never a wrong `.optimized`.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Mir = @import("mir.zig");
const Lower = @import("lower.zig");
const Analysis = @import("analysis.zig");
const diag = @import("diag");
pub const math = std.math;

/// Per-unit float-mode decision. LRM §4.3 domains + finiteness.
pub const FloatMode = enum {
    /// Proven finite (no NaN/Inf possible) → codegen emits @setFloatMode(.optimized).
    optimized,
    /// Not provably finite (e.g. unbounded voltage exp) → @setFloatMode(.strict),
    /// where inf is IEEE-defined and spec-legal. NOT an error.
    strict,

    /// The mode a declaration SHARED by several units must compile in.
    ///
    /// SOUNDNESS: `.optimized` is full fast-math — it asserts `nnan` and `ninf`
    /// (see the note at the head of this file). A subexpression hoisted out of a
    /// `.strict` unit into a shared declaration is still reachable from that
    /// unit, so compiling it fast-math would assert a finiteness fact that unit
    /// never had. The join is therefore `.strict`-absorbing, and codegen folds
    /// every consumer of a common declaration through it (`Gen.planCommon`).
    ///
    /// The other direction is free: a `.optimized` unit that loses fast-math
    /// inside a shared callee is slower, never wrong — the same conservative
    /// direction the file-scope math helpers already take (codegen.math_txt).
    pub fn strictest(a: FloatMode, b: FloatMode) FloatMode {
        return if (a == .strict or b == .strict) .strict else .optimized;
    }
};

pub const Verdict = struct {
    /// One entry per source unit — see UNIT ORDERING in the file header.
    unit_modes: []const FloatMode,
    /// Number of §4.3.2 domain violations reported into the `diag.Bag`. Zero ⇒
    /// the model is accepted and codegen may run. Non-zero ⇒ compile error;
    /// `unit_modes` is still filled (all `.strict`) so a lint front-end reports
    /// everything in one pass.
    ///
    /// The messages themselves are NOT here any more: they go straight into the
    /// shared bag, which is what gives them a source location, a code, a fix
    /// and a place in the global source ordering.
    error_count: u32,

    pub fn ok(self: Verdict) bool {
        return self.error_count == 0;
    }

    pub fn deinit(self: Verdict, gpa: std.mem.Allocator) void {
        gpa.free(self.unit_modes);
    }
};

pub const Options = struct {
    /// If the host guarantees |unknown| ≤ B for every solver unknown, set it and
    /// probe-dependent transcendentals become provable. `null` = unbounded
    /// (still finite — see SOUNDNESS MODEL 1). This is the hardware knob: a real
    /// solver has a real compliance limit that no language rule can see.
    unknown_bound: ?f64 = null,
    /// SOUNDNESS MODEL 3. `.tracked` refuses to assume `+ - * /` stay in range.
    arith_overflow: enum { assume_absent, tracked } = .assume_absent,
};

/// Stop after this many; one bad expression otherwise reports a cascade.
pub const max_errors = 64;

/// Number of source units — the length of `Verdict.unit_modes`. naming.zig must
/// agree with this (assert it there).
pub fn unitCount(lower: *const Lower) usize {
    return lower.contributions.items.len;
}

// The lattice: intervals and math-function domains (§4.3.1/§4.3.2 Tables 4-14/4-15) — proof/lattice.zig
const proof_lattice = @import("proof/lattice.zig");
pub const isPredicateValue = proof_lattice.isPredicateValue;
pub const domainOf = proof_lattice.domainOf;

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

/// Main entry. Prove domains, decide per-unit float mode. See UNIT ORDERING.
pub fn prove(
    gpa: std.mem.Allocator,
    mir: *const Mir,
    lower: *const Lower,
    bag: *diag.Bag,
) !Verdict {
    return proveOpts(gpa, mir, lower, .{}, bag);
}

pub fn proveOpts(
    gpa: std.mem.Allocator,
    mir: *const Mir,
    lower: *const Lower,
    opts: Options,
    bag: *diag.Bag,
) !Verdict {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var p: proof_prover.Prover = .{
        .gpa = gpa,
        .arena = scratch.allocator(),
        .mir = mir,
        .lower = lower,
        .opts = opts,
        .bag = bag,
    };

    // The CFG, the dominator tree and the natural loops, from the ONE builder
    // that owns them. This file used to carry a second Cooper/Harvey/Kennedy
    // copy computing `idom`/`rpo_num` and nothing else; `Analysis` computes
    // those PLUS `is_loop`/`loop_of`, which is the missing input for the
    // loop-carried widening ceiling `walk` records.
    p.an = try Analysis.buildStructure(p.arena, mir, lower);

    try p.seedValues(); // §3.4.2 param ranges, §4.2 constants, §4.4 probes
    try p.buildClasses(); // structural congruence, so guards reach every copy
    try p.markSelectArms(); // §4.2.12 `?:` guards its own arms
    try p.walk(); // the one linear pass: intervals + domain checks
    return p.verdict(); // per-unit join over the backward slices
}

// The prover: one dominator-order walk that rates every unit `.optimized` or `.strict` — proof/prover.zig
const proof_prover = @import("proof/prover.zig");

// Prover self-checks: source in, float-mode verdict and domain diagnostics out — proof/test.zig
const proof_test = @import("proof/test.zig");

test {
    _ = proof_lattice;
    _ = proof_prover;
    _ = proof_test;
}
