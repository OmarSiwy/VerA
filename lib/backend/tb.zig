//! Testbench generation — the second artifact. LRM ch9 (§9.4 display tasks).
//!
//! VerA's device output answers "what does the solver stamp?". This file
//! answers "what does the model SAY?", by making the same .va into a program:
//!
//!   .va ──codegen(display = .emit)──> device.zig ──┐
//!                                                  ├─> zig build-exe ─> ./NAME
//!   `//!` directives ────renderRunner────> tb.zig ─┘
//!
//! Running it prints a transcript: every `$strobe` the model executes, plus the
//! residual and Jacobian at each declared operating point. That transcript is
//! the test. A fixture is one .va and one expected transcript, and authoring a
//! new test is writing Verilog-A — not Zig, and not a table of magic numbers in
//! another language.
//!
//! WHY THE DIRECTIVES ARE COMMENTS. A device's inputs are node voltages the
//! host supplies; nothing in the source says which ones are interesting. That
//! has to come from somewhere, and a `//!` line is the only place to put it that
//! (a) keeps the fixture a single file, (b) survives the preprocessor untouched
//! — §2.4 makes it a comment — and (c) leaves the .va compilable by any other
//! Verilog-A tool, which a made-up pragma would not.
//!
//! DOD: the directive table is parsed once into flat arena slices, and the
//! sweep is expanded HERE rather than emitted as nested loops. The runner is
//! straight-line code with one block per operating point, so its output order is
//! a property of the text, not of a loop nest.

const std = @import("std");
const naming = @import("naming.zig");
const Lexer = @import("frontend").Lexer;
pub const Io = std.Io;
pub const Allocator = std.mem.Allocator;

/// The `//!` marker. Chosen over a bare `//` so an ordinary comment never
/// becomes a directive by accident, and over ``pragma`` so the file stays
/// portable Verilog-A.
pub const marker = "//!";

pub const Error = Allocator.Error || error{
    /// A `//!` line named a directive that does not exist. Silently ignoring it
    /// would turn a typo into a test that quietly checks nothing.
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
    /// unknown — `V(a,c)`, a branch POTENTIAL, being the case that reaches
    /// here. Its own error rather than `BadSyntax` because the report prints
    /// the error name and "BadSyntax" says nothing about which half was wrong.
    BadUnknownName,
};

/// One `name = value` binding: a model parameter, or a fixed unknown.
pub const Binding = struct { name: []const u8, value: f64 };

/// One `//! sweep <unknown> = v, v, …` line.
pub const Sweep = struct { name: []const u8, values: []const f64 };

/// §4.6.1 analysis kinds, spelled as the generated `AnalysisKind` enum does.
pub const Analysis = enum { static, ic, nodeset, dc, tran, ac, noise };

/// Everything the `//!` lines of one fixture said. Every field has a default, so
/// a .va with no directives at all is still runnable: one operating point with
/// every unknown at zero and every parameter at its §3.4 default.
pub const Directives = struct {
    /// §3.4 parameter overrides, in source order.
    params: []const Binding = &.{},
    /// Unknowns held at a fixed value across the whole sweep.
    bias: []const Binding = &.{},
    /// Swept unknowns. The operating points are the CARTESIAN PRODUCT, with the
    /// LAST line varying fastest — the same order a nested loop written in the
    /// directive order would visit, so the transcript reads top-down.
    sweeps: []const Sweep = &.{},
    /// §9.10 `$temperature`, in kelvin.
    temp: f64 = 300.15,
    /// §9.10 `$abstime` values. More than one makes each operating point run
    /// once per time, with `dt` set from the previous entry (§4.5.3 needs it)
    /// and the generated `updateState` called after each — so the §4.5 stateful
    /// operators see the history a transient solve would give them.
    times: []const f64 = &.{0.0},
    /// Per-timepoint values for an unknown: `//! wave V(in) = 0, 1, 1, 0`, one
    /// entry per `//! time`. A short list HOLDS its last value, which is how a
    /// step is written. Without this every §4.5 operator could only ever be
    /// shown its step response from zero.
    waves: []const Sweep = &.{},
    /// Swept PARAMETERS — the sub-tasks of a §8.2 parametric sweep, as opposed
    /// to `sweeps`, which moves an unknown within one solve. A parameter sweep
    /// needs its own model card per point (and its own `derive`, §6.3.4), so it
    /// is a separate list rather than another `sweep` line. Ordered after
    /// `sweeps` in the cartesian product, so it varies fastest.
    psweeps: []const Sweep = &.{},
    /// §4.6.1.
    analysis: Analysis = .dc,
    /// `//! solve`: the unknowns no other directive names are the DEVICE's to
    /// determine (§5.6 Newton on its own residual), not the harness's.
    ///
    /// Off by default, and that default is a NETLIST statement rather than
    /// timidity. A .va compiled alone is not a circuit: nothing says what its
    /// terminals connect to, so the harness supplies the only netlist it can —
    /// every unknown no `//!` line names is tied to the reference. That is what
    /// makes `//! bias V(p) = 0.5` on a two-terminal resistor mean "0.5 V
    /// ACROSS it" and not "one lead driven, the other left open", which is what
    /// a solve of the isolated device would answer instead: KCL through an open
    /// lead is zero current, so the far node follows the near one and the branch
    /// potential comes out 0. 100 fixtures state a rule that way.
    ///
    /// A fixture whose POINT is that the solver determines something says so
    /// with this line. §5.6.7's indirect contribution is the case that cannot be
    /// written any other way: its target IS a constraint's solution, so a
    /// fixture that declared the target would be asserting its own input.
    solve_free: bool = false,
    /// Print the residual and its Jacobian after each point's display output.
    /// `//! print none` leaves the transcript to the model's own `$strobe`s,
    /// which is what a fixture that tests §9.4 formatting wants.
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
    /// `//! spice <one netlist line>`, one per line, joined with newlines in
    /// source order: SPICE netlist text this fixture is compiled AGAINST.
    ///
    /// Annex E.2's model and subcircuit declarations are objects defined in a
    /// netlist, and E.1.1's requirement is conditional on the tool reading one —
    /// so a fixture for that clause has to be able to hand one over. This is the
    /// channel, and it is a TRANSPARENT one: the line carries the annex's card
    /// verbatim, `+` continuations and all, and the compiler does the reading
    /// (`spice_cards.synthesize`). Nothing here pre-digests it into names and
    /// ports, because a pre-digested interface would close the fixture while
    /// skipping the premise the fixture is about.
    ///
    /// It is a comment like every other directive (§2.4), so a .va using it is
    /// still compilable by another tool — which for this family is the point:
    /// such a tool reads the netlist off its own command line and the cards here
    /// document which netlist that must be.
    spice: []const u8 = "",
    /// `//! noise <kind>(<row>,<col>)#<source>`, one per expected `noise_gens`
    /// entry, in table order. `//! noise none` asserts the table is empty.
    /// `#<source>` is §4.6.4.6: two lines writing the same `#k` assert the rows
    /// share ONE generator (perfectly correlated); distinct `#k` assert
    /// independence.
    ///
    /// §4.6.4's generators are the one part of a model that is NOT observable
    /// from the model's own text: `white_noise` reads 0 outside a small-signal
    /// analysis (§4.6.2), so a `CHECK` over it can only ever pin the zero, and
    /// what the clause is actually about — WHICH generator was declared, on
    /// WHICH branch — leaves through the device's `noise_gens` table to a host.
    /// Until this directive the suite had no host reading it, so five clauses
    /// (§4.6.4.1 white_noise, .2 flicker_noise, .3/.4 the tables, .6 correlated
    /// sources) had nothing a fixture could assert about them beyond acceptance.
    ///
    /// The verdict stays the `ok=` column, so no harness change and no second
    /// judge: the runner prints one `got=/want= ok=` line per entry plus one for
    /// the count, and `countVerdicts` reads them like any other assertion.
    ///
    /// A fixture writes what the LRM REQUIRES the table to be. Where VerA
    /// exports something else it gets `//! xfail`, in the ordinary way — writing
    /// the gap into the `want` instead would invert the fixture and fail a
    /// conforming compiler.
    noise: []const NoiseWant = &.{},
    /// Whether any `//! noise` line was written at all. Separate from
    /// `noise.len`, because `//! noise none` is an ASSERTION that the table is
    /// empty and an absent directive is not — without this the runner could not
    /// tell "expect nothing" from "does not ask".
    asserts_noise: bool = false,
    /// `//! acstim (<row>,<col>) [name=<analysis>] [mag=<v>] [phase=<v>]`, one
    /// per expected `ac_gens` entry, in table order. `//! acstim none` asserts
    /// the table is empty.
    ///
    /// §4.6.3's twin of `noise`, and it exists for the same reason: a stimulus
    /// is a PHASOR, and the only real number a `CHECK` inside the analog block
    /// could read off one is `mag*cos(phase)` — which is precisely the
    /// real-part-only lowering the export exists to fix, so writing it down
    /// would bless the defect as the specification. The (magnitude, phase) pair
    /// leaves through `ac_gens`/`acStim` to a host that solves a complex
    /// system, and this line is how a fixture reaches it.
    acstim: []const AcWant = &.{},
    /// Whether any `//! acstim` line was written. Same split as
    /// `asserts_noise`: `//! acstim none` is a claim and silence is not.
    asserts_acstim: bool = false,
    /// `//! reject <substring>`, one per line. Non-empty makes this a REJECT
    /// fixture: it must NOT compile, and every substring here must appear
    /// somewhere in the resulting diagnostic. A fixture that cannot run states
    /// its expectation the same way one that can does — in the .va itself.
    reject: []const []const u8 = &.{},
    /// `//! lrm <section>`, one per line: the normative clause this fixture
    /// pins. It is not an expectation and changes no verdict — it is what lets
    /// a FAIL name the RULE that broke rather than only the file, and what a
    /// coverage report counts.
    lrm: []const []const u8 = &.{},
    /// `//! xfail <reason>`: the fixture states a genuine LRM requirement that
    /// VerA is KNOWN not to meet yet, and the reason says WHAT it does not do.
    /// It points both ways, because the gap does:
    ///   with `reject` — the LRM says the construct is an error and VerA
    ///                   still accepts it;
    ///   without       — the LRM prints this as a legal worked example, so it
    ///                   must compile and run green, and VerA cannot yet.
    /// The second is the common case: a fixture written `//! reject` because
    /// VerA lacks the construct inverts the test, since a CONFORMING compiler
    /// then fails it.
    xfail: ?[]const u8 = null,
    /// Not a directive: set by the CALLER from the compile (`mixedPlan`) when
    /// the module has a discrete half. The runner then drives the device from
    /// `sim.mixed` instead of the straight-line operating points.
    mixed: ?Mixed = null,
};

/// What a mixed-signal testbench needs from the compile besides the device:
/// the digital half to re-elaborate at startup (VAMS §7.2.2), and which
/// device parameters are its host-written discrete inputs.
pub const Mixed = struct {
    /// The compile's preprocessed text; `sim.digital.elaborate` parses it again.
    source: []const u8,
    /// The root module the device was lowered from.
    top: []const u8,
    /// The `timescale in force, in seconds; null when the source gave none.
    unit: ?f64,
    precision: ?f64,
    /// Digital-owned names the analog block reads, each a `Model` field.
    inputs: []const []const u8,
    /// §8.5.3.6 digital names read under an explicit D2A event, each a
    /// `<name>__1b` `Model` field.
    snaps: []const []const u8 = &.{},
    /// §8.5 the explicit D2A terms, in site order.
    events: []const @import("ir").Lowered.DiscreteEvent = &.{},
};

/// One `//! noise` line, split into the part that names the ROW and the parts
/// that state its CONTENTS:
///
///     //! noise <kind>(<row>,<col>)#<src> [name=<s>] [white=<v>] [flicker=<v>]
///                                        [ef=<v>] [rtol=<v>]
///     //! noise table(<row>,<col>)#<src> [name=<s>] interp=linear|log
///                                        points=<f>:<p>,<f>:<p>,…
///
/// Every field after `topo` is OPTIONAL and asserts nothing when absent, so
/// every line written before this existed keeps meaning exactly what it did:
/// the row is at this position, on this branch, with this correlation id.
///
/// The split exists because the topology is a COMPTIME property of the model
/// and the PSD is not. `topo` is checked against `noise_gens` once; `white`,
/// `flicker` and `ef` are read from `noisePsd` at the FIRST operating point,
/// which is what lets a fixture pin a bias-dependent density at a stated bias
/// instead of at whatever the last sweep step happened to be.
pub const NoiseWant = struct {
    /// `kind(row,col)#source`, verbatim, compared byte-exact against the
    /// device's own spelling of the row.
    topo: []const u8,
    /// §4.6.4.1/.2/.3 the source label. Byte-exact; `name=` with an empty
    /// value asserts the model supplied no name.
    name: ?[]const u8 = null,
    /// §4.6.4.1 `S(f) = white`, and §4.6.4.2's `flicker`/`ef` in `S(f) =
    /// flicker/f^ef`. Each is read out of `noisePsd(x, model, inst)[k]`.
    ///
    /// `white` and `flicker` are the EFFECTIVE density the branch carries —
    /// `coeff²·white` — and not the raw field. §4.6.4.6's coefficient is a
    /// property of the use and not of the generator, so which of the two
    /// exported fields carries the factor is an implementation's business; the
    /// spectrum reaching a host is not. `ef` is an exponent and is untouched
    /// by it.
    white: ?f64 = null,
    flicker: ?f64 = null,
    ef: ?f64 = null,
    /// Relative tolerance for the three above. The default is tight because a
    /// fixture asserts a number it DERIVED, not a measurement; a line whose
    /// value travels through §9.15's implementation-defined k/q has to say so
    /// by widening this, and say why in its header.
    rtol: f64 = 1e-12,
    /// §4.6.4.3/.4 `noise_tables[noise_gens[k].table.?]`. `interp` is the
    /// clause — `linear` is §4.6.4.3 and `log` is §4.6.4.4 — and `points` is
    /// the sorted knot list the device exports, which is not the order the
    /// model necessarily wrote them in.
    interp: ?[]const u8 = null,
    points: ?[]const [2]f64 = null,

    /// Does this line assert anything that needs a BIAS? The comptime topology
    /// block can answer everything else without solving.
    pub fn needsPoint(self: NoiseWant) bool {
        return self.white != null or self.flicker != null or self.ef != null;
    }
};

/// One `//! acstim` line:
///
///     //! acstim (<row>,<col>) [name=<analysis>] [mag=<v>] [phase=<v>] [rtol=<v>]
///
/// `NoiseWant` one clause over, and split for the same reason: the BRANCH and
/// §4.6.3's `analysis_name` are properties of the model TEXT and are checked
/// against `ac_gens` once, while `mag` and `phase` are the model CARD's — a
/// parameter is a legal magnitude — and are read out of `acStim(...)` at the
/// first operating point.
///
/// Every field after `topo` is optional and asserts nothing when absent.
pub const AcWant = struct {
    /// `(row,col)`, canonicalised at parse time so `(p, n)` and `(p,n)` are the
    /// same want, then compared byte-exact against the device's own spelling.
    topo: []const u8,
    /// §4.6.3 `analysis_name` — which small-signal analysis this source is
    /// active in, NOT a label: §4.6.4's `name` is a report heading and this one
    /// selects the analysis. Byte-exact.
    name: ?[]const u8 = null,
    /// §4.6.3 "models a source with magnitude mag and phase phase … phase is
    /// given in radians". Read out of `acStim(model, inst)[k]`.
    mag: ?f64 = null,
    phase: ?f64 = null,
    /// Relative tolerance for the two above, tight by default for the reason
    /// `NoiseWant.rtol` gives: a fixture asserts a number it derived.
    rtol: f64 = 1e-12,

    /// Does this line need the model card — i.e. a point block — to answer?
    pub fn needsPoint(self: AcWant) bool {
        return self.mag != null or self.phase != null;
    }
};

/// Guard against a fixture that asks for a million points and a gigabyte of
/// generated Zig. Hit only by a mistake — a real sweep is tens of points.
pub const max_points: usize = 4096;

// Directive parsing: a fixture's `//!` header (analysis, bias, time, sweep, noise, ...) — tb/directive.zig
const tb_directive = @import("tb/directive.zig");
pub const parse = tb_directive.parse;

// Runner generation: the testbench `main` for one fixture — tb/runner.zig
const tb_runner = @import("tb/runner.zig");
pub const renderRunner = tb_runner.renderRunner;
pub const mixedPlan = tb_runner.mixedPlan;

// The runner's fixed text: the Newton solver and the `@Vector(NL, f64)` lanes it drives — tb/runner_text.zig
const tb_runner_text = @import("tb/runner_text.zig");

// Building the executable: device.zig + runner into one `zig build-exe` — tb/exe.zig
const tb_exe = @import("tb/exe.zig");
pub const buildExe = tb_exe.buildExe;

// Testbench self-checks — tb/test.zig
const tb_test = @import("tb/test.zig");

test {
    _ = tb_directive;
    _ = tb_runner;
    _ = tb_runner_text;
    _ = tb_exe;
    _ = tb_test;
}
