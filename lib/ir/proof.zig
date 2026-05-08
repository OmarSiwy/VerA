//! Numerical-safety pass: MIR and `Lowered` in, a float-mode `Verdict` per contribution unit out,
//! plus a compile error for any argument provably outside its math-function domain.
//! LRM §4.3.1/§4.3.2 (Tables 4-14/4-15), §4.2.4, §3.4.2, §3.6.1.2, §4.5.15, §5.8.4.
//! Domain checks are three-way: provably outside is an error, provably inside keeps `.optimized`,
//! unprovable is accepted and costs `.strict`. `exp` and `/` by zero are never errors.
//! The pass reads no target, inserts no clamp or `limexp`, and emits no runtime check.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Mir = @import("mir.zig");
const Lower = @import("lower.zig");
const Lowered = Lower.Lowered;
const Analysis = @import("analysis.zig");
const diag = @import("diag");
/// `std.math`, shared with the `proof/` sub-files.
pub const math = std.math;

/// The float mode a unit's code may compile in (LRM §4.3).
/// `.optimized` asserts nnan and ninf, so a wrong `.optimized` is silent undefined behavior in
/// release builds, and every finiteness rule errs toward `.strict`:
///  1. Solver unknowns (§4.4) and model-card parameters (§3.4) are finite doubles by the host
///     contract; a probe's magnitude is still unknown. A parameter whose range admits `inf` is not
///     finite.
///  2. `exp`, `expm1`, `sinh`, `cosh` and `pow` overflow at device magnitudes, so their result is
///     finite only for a bounded argument.
///  3. `+ - * /` on finite operands do not overflow, unless `Options.arith_overflow` is `.tracked`.
///  4. A `call` the prover does not model is not finite.
pub const FloatMode = enum {
    /// Proven finite: codegen emits `@setFloatMode(.optimized)`.
    optimized,
    /// Not provably finite: `@setFloatMode(.strict)`, where inf and NaN are IEEE-defined. Not an error.
    strict,

    /// Returns the mode for code shared by both units: `.strict` absorbs.
    /// A subexpression shared with a `.strict` unit stays reachable from it, so compiling it
    /// fast-math would assert a finiteness fact that unit never had. Codegen folds the shared
    /// core's mode through this join (`codegen/float/mode.zig` `coreMode`).
    pub fn strictest(a: FloatMode, b: FloatMode) FloatMode {
        return if (a == .strict or b == .strict) .strict else .optimized;
    }
};

/// The prover's result: one float mode per contribution unit and the domain-error count.
pub const Verdict = struct {
    /// `unit_modes[i]` rates `lowered.contributions.items[i]`: one unit per access and node pair
    /// (§5.6.1.3), or per statement for a §5.6.7 indirect contribution. A unit is `.optimized`
    /// only if both its `resist_val` and `react_val` slices are proven finite. §5.4.3 port probes
    /// add no unit. Any new unit kind must be appended after the contribution units.
    /// Allocated with the `gpa` passed to `prove`; free with `deinit`.
    unit_modes: []const FloatMode,
    /// §4.3.2 domain violations reported into the `diag.Bag`. Zero means the model is accepted.
    /// On errors `unit_modes` is still filled, all `.strict`, so a lint front end reports
    /// everything in one pass.
    error_count: u32,

    /// Returns true when no domain error was reported.
    pub fn ok(self: Verdict) bool {
        return self.error_count == 0;
    }

    /// Frees `unit_modes`; `gpa` must be the allocator passed to `prove`.
    pub fn deinit(self: Verdict, gpa: std.mem.Allocator) void {
        gpa.free(self.unit_modes);
    }
};

/// Prover knobs.
pub const Options = struct {
    /// A host bound B with |unknown| <= B for every solver unknown. It makes probe-dependent
    /// transcendentals provable. `null` means unbounded but still finite (rule 1 on `FloatMode`).
    /// This is the hardware knob: a real solver has a compliance limit no language rule can see.
    unknown_bound: ?f64 = null,
    /// Rule 3 on `FloatMode`: `.tracked` refuses to assume `+ - * /` stay in range.
    arith_overflow: enum { assume_absent, tracked } = .assume_absent,
};

/// Maximum domain errors reported; one bad expression otherwise reports a cascade.
pub const max_errors = 64;

/// Returns the number of units, the length of `Verdict.unit_modes`.
/// `naming.assertCanonicalOrder` asserts that codegen agrees.
pub fn unitCount(lowered: *const Lowered) usize {
    return lowered.contributions.items.len;
}

const proof_lattice = @import("proof/lattice.zig");
/// Returns whether a value is a 0/1 predicate (§4.2.5/§4.2.8).
pub const isPredicateValue = proof_lattice.isPredicateValue;
/// Returns the LRM domain an opcode's argument must satisfy.
pub const domainOf = proof_lattice.domainOf;

/// Proves domains and rates each unit with default `Options`; see `proveOpts`.
pub fn prove(
    gpa: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
    bag: *diag.Bag,
) !Verdict {
    return proveOpts(gpa, mir, lowered, .{}, bag);
}

/// Proves every §4.3.2 domain, reports violations into `bag`, and rates each unit.
/// Caller owns the returned `Verdict` and must free it with `deinit(gpa)`.
pub fn proveOpts(
    gpa: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
    opts: Options,
    bag: *diag.Bag,
) !Verdict {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var p: proof_prover.Prover = .{
        .gpa = gpa,
        .arena = scratch.allocator(),
        .mir = mir,
        .lowered = lowered,
        .opts = opts,
        .bag = bag,
    };

    p.an = try Analysis.buildStructure(p.arena, mir, lowered);

    try p.seedValues(); // §3.4.2 param ranges, §4.2 constants, §4.4 probes
    try p.buildClasses(); // structural congruence, so guards reach every copy
    try p.markSelectArms(); // §4.2.12 `?:` guards its own arms
    try p.walk(); // the one linear pass: intervals + domain checks
    return p.verdict(); // per-unit join over the backward slices
}

const proof_prover = @import("proof/prover.zig");
const proof_test = @import("proof/test.zig");

test {
    _ = proof_lattice;
    _ = proof_prover;
    _ = proof_test;
}
