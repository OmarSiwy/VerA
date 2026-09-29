//! Testbench generation: a .va's `//!` directives in, a runner program out
//! that is built with the `display = .emit` device and prints a transcript
//! (every `$strobe`, plus residual and Jacobian per operating point).
//! Directives are comments (§2.4) so a fixture stays one portable .va file.
//! Sweeps are expanded here, so the runner is straight-line code whose output
//! order is the text's. LRM: §9.4.

const std = @import("std");
const naming = @import("naming.zig");
pub const Io = std.Io;
pub const Allocator = std.mem.Allocator;

/// The directive line prefix. A plain `//` comment is never a directive.
pub const marker = "//!";

/// Errors from directive parsing and point expansion.
pub const Error = Allocator.Error || error{
    /// A `//!` line named an unknown directive. Refused so a typo cannot
    /// silently check nothing.
    UnknownDirective,
    /// A directive's operand was not a number.
    BadNumber,
    /// A directive that needs `name = value` did not get one.
    BadSyntax,
    /// The cartesian product of the `sweep` lines exceeded `max_points`.
    TooManyPoints,
    /// A `//! lrm` cite is not a section number: see `validSection`.
    BadLrmSection,
    /// A `bias`/`sweep`/`wave` line named something that is not a solver
    /// unknown, such as the branch potential `V(a,c)`.
    BadUnknownName,
};

/// One `name = value` binding: a model parameter, or a fixed unknown.
pub const Binding = struct { name: []const u8, value: f64 };

/// One `//! limit` line: the `old` lanes that differ from `cur`, and the
/// wanted outputs, where `converged` names the verdict pseudo-lane.
pub const LimitCase = struct { old: []const Binding, want: []const Binding };

/// One `//! sweep <unknown> = v, v, …` line.
pub const Sweep = struct { name: []const u8, values: []const f64 };

/// §4.6.1 analysis kinds, spelled as the generated `AnalysisKind` enum does.
pub const Analysis = enum { static, ic, nodeset, dc, tran, ac, noise };

/// Everything the `//!` lines of one fixture said. With no directives the
/// fixture runs one point, every unknown at zero and every parameter at its
/// §3.4 default. Slices are owned by the arena `parse` was given.
pub const Directives = struct {
    /// §3.4 parameter overrides, in source order.
    params: []const Binding = &.{},
    /// Unknowns held at a fixed value across the whole sweep.
    bias: []const Binding = &.{},
    /// Swept unknowns. The operating points are the cartesian product, last
    /// line varying fastest.
    sweeps: []const Sweep = &.{},
    /// §9.10 `$temperature`, in kelvin.
    temp: f64 = 300.15,
    /// §9.10 `$abstime` values. Each operating point runs once per time, with
    /// `dt` from the previous entry (§4.5.3) and `updateState` after each, so
    /// §4.5 stateful operators see transient history.
    times: []const f64 = &.{0.0},
    /// Per-timepoint values for an unknown: `//! wave V(in) = 0, 1, 1, 0`, one
    /// entry per `//! time`. A short list holds its last value.
    waves: []const Sweep = &.{},
    /// Swept parameters (§8.2 parametric sweep): each point gets its own model
    /// card and `derive` (§6.3.4). Varies fastest in the cartesian product.
    psweeps: []const Sweep = &.{},
    /// §4.6.1. Unwritten, `.tran` under a `//! time` grid, else `.dc`.
    analysis: Analysis = .dc,
    /// `//! solve`: unknowns no other directive names are solved by Newton on
    /// the device's own residual (§5.6). Off by default, every unnamed unknown
    /// is tied to the reference, so `//! bias V(p) = 0.5` on a resistor puts
    /// 0.5 V across it. Needed where the target is a solution, as in §5.6.7's
    /// indirect contribution.
    solve_free: bool = false,
    /// Print the residual and its Jacobian after each point's display output.
    /// `//! print none` leaves only the model's own output.
    print_residual: bool = true,
    /// Expected normal process exit status; signals always fail the fixture.
    expected_exit: u8 = 0,
    /// Optional exact number of runtime verdict columns across the whole run.
    /// A missing or duplicated check must not pass an exhaustive inventory.
    expected_checks: ?usize = null,
    /// Runtime argv entries, in source order. Repeatable `//! plusargs` lines
    /// split on ASCII space/tab only; no quoting, escaping or shell expansion.
    /// Each printable-ASCII token starts with '+' and contains another byte.
    plusargs: []const []const u8 = &.{},
    /// `//! spice <netlist line>` lines joined with newlines in source order:
    /// the Annex E SPICE netlist the fixture is compiled against. Verbatim,
    /// `+` continuations included; `spice_cards.synthesize` reads it.
    spice: []const u8 = "",
    /// `//! noise <kind>(<row>,<col>)#<source>`, one per expected `noise_gens`
    /// entry, in table order; `//! noise none` asserts an empty table. Equal
    /// `#k` on two lines assert one shared generator (§4.6.4.6), distinct `#k`
    /// independence. §4.6.4 generators read 0 outside small-signal analysis
    /// (§4.6.2), so the published table is what a fixture asserts. The runner
    /// prints one `got=/want= ok=` line per entry plus one for the count.
    noise: []const NoiseWant = &.{},
    /// Whether any `//! noise` line was written. `//! noise none` asserts an
    /// empty table; an absent directive asserts nothing.
    asserts_noise: bool = false,
    /// `//! acstim (<row>,<col>) [name=<analysis>] [mag=<v>] [phase=<v>]`, one
    /// per expected `ac_gens` entry, in table order; `//! acstim none` asserts
    /// an empty table. A §4.6.3 stimulus is a phasor that only a host sees
    /// (`ac_gens`/`acStim`), so the published table is what a fixture asserts.
    acstim: []const AcWant = &.{},
    /// Whether any `//! acstim` line was written (see `asserts_noise`).
    asserts_acstim: bool = false,
    /// `//! acdyn` lines, in source order (`AcDynWant`).
    acdyn: []const AcDynWant = &.{},
    /// `//! qsite <row><sign>... lte|nolte`, one per expected §5.6.1.2 charge
    /// site in slot order; `//! qsite none` asserts none. Each names the rows
    /// the site stamps and their sign (`g+ s-`; another weight prints as
    /// `g*0.5`) and whether `q_lte` checks it (`contract.QStamp`).
    qsites: []const []const u8 = &.{},
    /// Whether any `//! qsite` line was written (see `asserts_noise`).
    asserts_qsite: bool = false,
    /// `//! seed V(a) = v, ...`: exactly the lanes the device's §9.17.3 cold
    /// start (`seed`) returns non-null, with their values; every other lane
    /// must be null, and every non-null one must be in `limit_writes`.
    /// `//! seed none` asserts no lane is seeded. Lines accumulate.
    seeds: []const Binding = &.{},
    /// Whether any `//! seed` line was written (see `asserts_noise`).
    asserts_seed: bool = false,
    /// `//! abstol <unknown> = v, ...`: the §3.6.1.2 tolerance the device
    /// publishes for each named unknown (`u_abstol`). Lines accumulate.
    abstols: []const Binding = &.{},
    /// `//! limit V(a) = v, ... -> V(b) = w, ..., converged = 0|1`, one case per
    /// line: `limit` run at the first point's `x` as `cur`, with `old` = `cur`
    /// except the lanes left of `->`, must return the lanes right of it (and
    /// the verdict, if named). The testbench never limits on its own, so a
    /// published clamp is observable only through this.
    limits: []const LimitCase = &.{},
    /// `//! reject <substring>`, one per line. Non-empty makes this a reject
    /// fixture: it must not compile, and every substring must appear in the
    /// diagnostics.
    reject: []const []const u8 = &.{},
    /// `//! warn <substring>`, one per line: each must match a WARNING the
    /// compile reported, by code or text as `reject` matches. The fixture
    /// still compiles and runs; a warning nobody named does not fail it.
    warn: []const []const u8 = &.{},
    /// `//! nowarn`: the compile reports no warning at all. Never with `warn`.
    nowarn: bool = false,
    /// `//! lrm <section>`, one per line: the clauses this fixture pins. No
    /// verdict depends on it; failure reports and `--coverage` read it.
    lrm: []const []const u8 = &.{},
    /// `//! xfail <reason>`: the fixture states an LRM requirement VerA does
    /// not meet yet. With `reject`, VerA wrongly accepts the construct;
    /// without, VerA cannot yet compile and pass a legal example.
    xfail: ?[]const u8 = null,
    /// Not a directive: set by the caller from the compile (`mixedPlan`) when
    /// the module has a discrete half, so the runner drives the device from
    /// `sim.mixed` instead of fixed operating points.
    mixed: ?Mixed = null,
    /// Not a directive: the `U` indices of the §4.5.2 operator unknowns
    /// (`opStates`). Never forced, even without `//! solve`: each row is its
    /// operator's own equation, and a tied one would pin the operator at 0.
    op_states: []const u16 = &.{},
};

/// What a mixed-signal testbench needs from the compile besides the device:
/// the digital half to re-elaborate at startup (VAMS §7.2.2), and which
/// device parameters are its host-written discrete inputs.
pub const Mixed = struct {
    /// The compile's preprocessed text; `sim.digital.elaborate` parses it again.
    source: []const u8,
    /// The root module the device was lowered from.
    top: []const u8,
    /// The `timescale unit and precision in force, in seconds; null when the
    /// source gave none.
    unit: ?f64,
    precision: ?f64,
    /// Digital-owned names the analog block reads, each a `Model` field.
    inputs: []const []const u8,
    /// §8.5.3.6 digital names read under an explicit D2A event, each a
    /// `<name>__1b` `Model` field.
    snaps: []const []const u8 = &.{},
    /// §7.3.2 inputs read four-state, each with a `<name>__xz` `Model` field.
    xz: []const []const u8 = &.{},
    /// §8.5 the explicit D2A terms, in site order.
    events: []const @import("ir").Lowered.DiscreteEvent = &.{},
    /// §7.8.4 the inserted connect modules, which the source hierarchy the
    /// digital half re-elaborates does not hold.
    inserts: []const @import("ir").Lowered.Inserted = &.{},
    /// §7.3.6.4 analog variables a digital expression reads
    /// (`Lowered.discrete_reads`).
    reads: []const []const u8 = &.{},
    /// The device's §5.10 held variables: the `Instance` fields a read
    /// variable's value can be copied from.
    held: []const @import("ir").Lower.HeldVar = &.{},
};

/// One `//! noise` line:
///
///     //! noise <kind>(<row>,<col>)#<src> [name=<s>] [white=<v>] [flicker=<v>]
///                                        [ef=<v>] [rtol=<v>]
///     //! noise table(<row>,<col>)#<src> [name=<s>] interp=linear|log
///                                        points=<f>:<p>,<f>:<p>,…
///
/// Fields after `topo` are optional and assert nothing when absent. `topo` is
/// checked against `noise_gens` at comptime; `white`, `flicker` and `ef` are
/// read from `noisePsd` at the first operating point.
pub const NoiseWant = struct {
    /// `kind(row,col)#source`, verbatim, compared byte-exact against the
    /// device's own spelling of the row.
    topo: []const u8,
    /// §4.6.4.1/.2/.3 the source label. Byte-exact; `name=` with an empty
    /// value asserts the model supplied no name.
    name: ?[]const u8 = null,
    /// §4.6.4.1 `S(f) = white` and §4.6.4.2 `S(f) = flicker/f^ef`, read from
    /// `noisePsd(...)[k]`. `white` and `flicker` are the effective density
    /// including §4.6.4.6's `coeff²`, not the raw field; `ef` is unscaled.
    white: ?f64 = null,
    flicker: ?f64 = null,
    ef: ?f64 = null,
    /// Relative tolerance for the three above. Tight by default: a fixture
    /// asserts a derived number. A value through §9.15's k or q widens it.
    rtol: f64 = 1e-12,
    /// §4.6.4.3/.4 `noise_tables[noise_gens[k].table.?]`: `interp` is `linear`
    /// (§4.6.4.3) or `log` (§4.6.4.4), and `points` is the exported knot list,
    /// sorted by frequency.
    interp: ?[]const u8 = null,
    points: ?[]const [2]f64 = null,

    /// Returns whether this line asserts a bias-dependent density, which needs
    /// an operating point.
    pub fn needsPoint(self: NoiseWant) bool {
        return self.white != null or self.flicker != null or self.ef != null;
    }
};

/// One `//! acstim` line:
///
///     //! acstim (<row>,<col>) [name=<analysis>] [mag=<v>] [phase=<v>] [rtol=<v>]
///
/// Fields after `topo` are optional. `topo` and `name` are checked against
/// `ac_gens` at comptime; `mag` and `phase` may depend on the model card and
/// are read from `acStim(...)` at the first operating point.
pub const AcWant = struct {
    /// `(row,col)` without spaces, compared byte-exact with the device's spelling.
    topo: []const u8,
    /// §4.6.3 `analysis_name`: the small-signal analysis this source is active
    /// in. Byte-exact.
    name: ?[]const u8 = null,
    /// §4.6.3 magnitude and phase (radians), read from `acStim(...)[k]`.
    mag: ?f64 = null,
    phase: ?f64 = null,
    /// Relative tolerance for the two above (see `NoiseWant.rtol`).
    rtol: f64 = 1e-12,

    /// Returns whether this line reads the model card, which needs a point block.
    pub fn needsPoint(self: AcWant) bool {
        return self.mag != null or self.phase != null;
    }
};

/// One `//! acdyn` line:
///
///     //! acdyn (<row>,<col>) f=<Hz> re=<v> im=<v> [tol=<v>]
///
/// `acDyn`'s term at local Jacobian entry (row, col), `U` tag names, at
/// ω = 2πf and the first operating point (`contract.acDynSlots`). A slot the
/// device does not list reads 0.
pub const AcDynWant = struct {
    row: []const u8,
    col: []const u8,
    f: f64,
    re: f64,
    im: f64,
    /// Absolute tolerance on each part.
    tol: f64 = 1e-12,
};

/// Most operating points one fixture may expand to (`error.TooManyPoints`).
pub const max_points: usize = 4096;

const tb_directive = @import("tb/directive.zig");
pub const parse = tb_directive.parse;

const tb_runner = @import("tb/runner.zig");
pub const renderRunner = tb_runner.renderRunner;
pub const renderVpiLib = tb_runner.renderVpiLib;
pub const mixedPlan = tb_runner.mixedPlan;
pub const warnGridEvents = tb_runner.warnGridEvents;
pub const opStates = tb_runner.opStates;
pub const shapeOverrides = tb_runner.shapeOverrides;

const tb_runner_text = @import("tb/runner_text.zig");

const tb_exe = @import("tb/exe.zig");
pub const buildExe = tb_exe.buildExe;
pub const BuildOptions = tb_exe.BuildOptions;

const tb_test = @import("tb/test.zig");

test {
    _ = tb_directive;
    _ = tb_runner;
    _ = tb_runner_text;
    _ = tb_exe;
    _ = tb_test;
}
