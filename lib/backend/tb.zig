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
const Io = std.Io;
const Allocator = std.mem.Allocator;

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
    fn needsPoint(self: NoiseWant) bool {
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
    fn needsPoint(self: AcWant) bool {
        return self.mag != null or self.phase != null;
    }
};

/// Guard against a fixture that asks for a million points and a gigabyte of
/// generated Zig. Hit only by a mistake — a real sweep is tens of points.
pub const max_points: usize = 4096;

// ---------------------------------------------------------------------------
// Directive parsing
// ---------------------------------------------------------------------------

/// Read the `//!` lines out of RAW source — before the preprocessor, which
/// deletes comments (§2.4). Lines that are not directives are ignored, so this
/// is safe to run over any .va.
pub fn parse(arena: Allocator, source: []const u8) Error!Directives {
    var d: Directives = .{};
    var params: std.ArrayList(Binding) = .empty;
    var bias: std.ArrayList(Binding) = .empty;
    var sweeps: std.ArrayList(Sweep) = .empty;
    var waves: std.ArrayList(Sweep) = .empty;
    var psweeps: std.ArrayList(Sweep) = .empty;
    var reject: std.ArrayList([]const u8) = .empty;
    var lrm: std.ArrayList([]const u8) = .empty;
    var spice: std.ArrayList([]const u8) = .empty;
    var noise: std.ArrayList(NoiseWant) = .empty;
    var acstim: std.ArrayList(AcWant) = .empty;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, marker)) continue;
        const body = std.mem.trim(u8, line[marker.len..], " \t");
        if (body.len == 0) continue;

        const kw_end = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
        const kw = body[0..kw_end];
        const rest = std.mem.trim(u8, body[kw_end..], " \t");

        if (std.mem.eql(u8, kw, "param")) {
            try parseBindings(arena, rest, &params);
        } else if (std.mem.eql(u8, kw, "bias")) {
            try parseBindings(arena, rest, &bias);
        } else if (std.mem.eql(u8, kw, "sweep") or std.mem.eql(u8, kw, "wave") or std.mem.eql(u8, kw, "psweep")) {
            const at = std.mem.indexOfScalar(u8, rest, '=') orelse return error.BadSyntax;
            // A parameter has no access-function spelling, so `psweep` takes the
            // name as written; `unknownName` would only strip a `V(...)` that
            // cannot be there.
            const raw_name = std.mem.trim(u8, rest[0..at], " \t");
            const name = if (std.mem.eql(u8, kw, "psweep")) raw_name else try unknownName(arena, raw_name);
            if (name.len == 0) return error.BadSyntax;
            const entry: Sweep = .{
                .name = try arena.dupe(u8, name),
                .values = try parseNumbers(arena, rest[at + 1 ..]),
            };
            try (if (std.mem.eql(u8, kw, "sweep")) &sweeps else if (std.mem.eql(u8, kw, "psweep")) &psweeps else &waves)
                .append(arena, entry);
        } else if (std.mem.eql(u8, kw, "temp")) {
            d.temp = try number(rest);
        } else if (std.mem.eql(u8, kw, "time")) {
            d.times = try parseNumbers(arena, rest);
        } else if (std.mem.eql(u8, kw, "solve")) {
            // A bare flag, and it composes with `bias`: `bias` still pins what
            // it names, `solve` frees only the rest. So a fixture that needs one
            // terminal grounded and another solved writes both lines, and no
            // per-unknown list is needed to say it.
            if (rest.len != 0) return error.BadSyntax;
            d.solve_free = true;
        } else if (std.mem.eql(u8, kw, "analysis")) {
            d.analysis = std.meta.stringToEnum(Analysis, rest) orelse return error.BadSyntax;
        } else if (std.mem.eql(u8, kw, "exit")) {
            d.expected_exit = std.fmt.parseInt(u8, rest, 10) catch return error.BadNumber;
        } else if (std.mem.eql(u8, kw, "reject")) {
            // The whole rest of the line is ONE substring, verbatim: the
            // expectations being migrated are message fragments like
            // `module instantiation is not supported`, which contain spaces and
            // commas and must not be split on either.
            if (rest.len == 0) return error.BadSyntax;
            try reject.append(arena, try arena.dupe(u8, rest));
        } else if (std.mem.eql(u8, kw, "noise")) {
            // `none` is the empty table, spelled rather than left as an absent
            // directive: "this model declares no generator" is a claim, and a
            // missing line is not one.
            if (!std.mem.eql(u8, rest, "none")) {
                try noise.append(arena, try parseNoiseEntry(arena, rest));
            }
            d.asserts_noise = true;
        } else if (std.mem.eql(u8, kw, "acstim")) {
            // `none` is the empty table, for the reason `noise none` is.
            if (!std.mem.eql(u8, rest, "none")) {
                try acstim.append(arena, try parseAcEntry(arena, rest));
            }
            d.asserts_acstim = true;
        } else if (std.mem.eql(u8, kw, "spice")) {
            // Verbatim, including a leading `+`: the reader joins continuations
            // itself, so what it sees is the card as the annex prints it.
            if (rest.len == 0) return error.BadSyntax;
            try spice.append(arena, try arena.dupe(u8, rest));
        } else if (std.mem.eql(u8, kw, "lrm")) {
            if (!validSection(rest)) return error.BadLrmSection;
            try lrm.append(arena, try arena.dupe(u8, rest));
        } else if (std.mem.eql(u8, kw, "xfail")) {
            // The whole rest of the line is the reason, verbatim — it is prose
            // a human reads out of a failing run, not an operand.
            if (rest.len == 0) return error.BadSyntax;
            d.xfail = try arena.dupe(u8, rest);
        } else if (std.mem.eql(u8, kw, "print")) {
            if (std.mem.eql(u8, rest, "none")) {
                d.print_residual = false;
            } else if (std.mem.eql(u8, rest, "residual")) {
                d.print_residual = true;
            } else return error.BadSyntax;
        } else {
            return error.UnknownDirective;
        }
    }

    d.params = params.items;
    d.bias = bias.items;
    d.sweeps = sweeps.items;
    d.waves = waves.items;
    d.psweeps = psweeps.items;
    d.reject = reject.items;
    d.lrm = lrm.items;
    d.noise = noise.items;
    d.acstim = acstim.items;
    // One text blob, in source order: `spice_cards` wants netlist text, not a
    // list of lines, and joining here keeps the continuation rule in one place.
    if (spice.items.len != 0) d.spice = try std.mem.join(arena, "\n", spice.items);
    return d;
}

/// Is this a `//! lrm` cite — `5.8`, `4.5.11`, `A.8.3`, `B`?
///
/// A chapter number or an annex letter, then dotted numbers. Loose on purpose:
/// nothing here has the LRM's table of contents, so this catches a typo or an
/// empty cite, not a section that does not exist.
fn validSection(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    const first = it.first();
    const annex = first.len == 1 and first[0] >= 'A' and first[0] <= 'H';
    if (!annex and !digits(first)) return false;
    while (it.next()) |part| if (!digits(part)) return false;
    return true;
}

fn digits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Is this a `//! noise` entry — `thermal(p,n)`, `flicker(d,s)`?
///
/// The KIND is checked and the node names are not. A misspelled kind is a
/// fixture that can never pass and whose failure would say nothing about the
/// model, so it is worth catching at parse time; a misspelled node is a fixture
/// whose `want` genuinely differs from the table, which is the assertion doing
/// its job. Nothing here could check a node anyway — directives are read out of
/// raw source, before the compiler has been told what unknowns exist.
fn validNoiseEntry(s: []const u8) bool {
    const open = std.mem.indexOfScalar(u8, s, '(') orelse return false;
    // `#<source>` after the branch is §4.6.4.6's correlation id — see the
    // `noise` directive doc. `#null` is a row with no identity declared.
    const hash = std.mem.indexOfScalarPos(u8, s, open, '#') orelse return false;
    if (hash == 0 or s[hash - 1] != ')') return false;
    const src = s[hash + 1 ..];
    // ponytail: reuse the nonempty decimal check; source IDs have no numeric bound.
    if (!std.mem.eql(u8, src, "null") and !digits(src)) return false;
    const kind = std.mem.trim(u8, s[0..open], " \t");
    // `table` is §4.6.4.3 AND §4.6.4.4: both export one kind, and which
    // interpolation applies is `noise_tables[k].interp`, not the row's tag.
    const kinds = [_][]const u8{ "thermal", "shot", "flicker", "table" };
    for (kinds) |k| {
        if (std.mem.eql(u8, kind, k)) break;
    } else return false;
    const inner = s[open + 1 .. hash - 1];
    const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return false;
    return std.mem.trim(u8, inner[0..comma], " \t").len != 0 and
        std.mem.trim(u8, inner[comma + 1 ..], " \t").len != 0;
}

/// One `//! noise` line: the topology, then whatever `key=value` fields follow.
///
/// The topology is taken as the run from the start of the line to the first
/// space AFTER the `#`, not to the first space anywhere, because the branch may
/// be written `thermal(p, n)#0` — `validNoiseEntry` already trims inside the
/// parentheses, so splitting on any space would cut a legal entry in half.
fn parseNoiseEntry(arena: Allocator, s: []const u8) Error!NoiseWant {
    const hash = std.mem.indexOfScalar(u8, s, '#') orelse return error.BadSyntax;
    var end = hash + 1;
    while (end < s.len and s[end] != ' ' and s[end] != '\t') end += 1;
    const topo = s[0..end];
    if (!validNoiseEntry(topo)) return error.BadSyntax;

    var w: NoiseWant = .{ .topo = try arena.dupe(u8, topo) };
    var fields = std.mem.tokenizeAny(u8, s[end..], " \t");
    while (fields.next()) |f| {
        const at = std.mem.indexOfScalar(u8, f, '=') orelse return error.BadSyntax;
        const key = f[0..at];
        const val = f[at + 1 ..];
        if (std.mem.eql(u8, key, "name")) {
            w.name = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "white")) {
            w.white = try number(val);
        } else if (std.mem.eql(u8, key, "flicker")) {
            w.flicker = try number(val);
        } else if (std.mem.eql(u8, key, "ef")) {
            w.ef = try number(val);
        } else if (std.mem.eql(u8, key, "rtol")) {
            w.rtol = try number(val);
        } else if (std.mem.eql(u8, key, "interp")) {
            if (!std.mem.eql(u8, val, "linear") and !std.mem.eql(u8, val, "log")) return error.BadSyntax;
            w.interp = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "points")) {
            var pts: std.ArrayList([2]f64) = .empty;
            var it = std.mem.tokenizeScalar(u8, val, ',');
            while (it.next()) |pair| {
                const colon = std.mem.indexOfScalar(u8, pair, ':') orelse return error.BadSyntax;
                try pts.append(arena, .{ try number(pair[0..colon]), try number(pair[colon + 1 ..]) });
            }
            if (pts.items.len == 0) return error.BadSyntax;
            w.points = pts.items;
        } else return error.BadSyntax;
    }
    return w;
}

/// One `//! acstim` line: the branch, then whatever `key=value` fields follow.
///
/// Simpler than `parseNoiseEntry` because §4.6.3 has less to say: there is no
/// kind tag (a stimulus has exactly one form) and no `#source` (§4.6.4.6's
/// correlation is a property of noise generators, and two stimuli at the same
/// phase are not "correlated", they are two sources). So the topology is the
/// parenthesised branch alone, and it is CANONICALISED rather than compared
/// verbatim — `(p, n)` and `(p,n)` are the same want, and the device's own
/// spelling has no space in it.
fn parseAcEntry(arena: Allocator, s: []const u8) Error!AcWant {
    if (s.len == 0 or s[0] != '(') return error.BadSyntax;
    const close = std.mem.indexOfScalar(u8, s, ')') orelse return error.BadSyntax;
    const inner = s[1..close];
    const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return error.BadSyntax;
    const row = std.mem.trim(u8, inner[0..comma], " \t");
    const col = std.mem.trim(u8, inner[comma + 1 ..], " \t");
    if (row.len == 0 or col.len == 0) return error.BadSyntax;

    var w: AcWant = .{ .topo = try std.fmt.allocPrint(arena, "({s},{s})", .{ row, col }) };
    var fields = std.mem.tokenizeAny(u8, s[close + 1 ..], " \t");
    while (fields.next()) |f| {
        const at = std.mem.indexOfScalar(u8, f, '=') orelse return error.BadSyntax;
        const key = f[0..at];
        const val = f[at + 1 ..];
        if (std.mem.eql(u8, key, "name")) {
            w.name = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "mag")) {
            w.mag = try number(val);
        } else if (std.mem.eql(u8, key, "phase")) {
            w.phase = try number(val);
        } else if (std.mem.eql(u8, key, "rtol")) {
            w.rtol = try number(val);
        } else return error.BadSyntax;
    }
    return w;
}

/// `V(a)`, `x[a]` and a bare `a` all name the unknown `a`. The first two are
/// how a Verilog-A author already writes it and how the runner indexes it; both
/// are accepted so a fixture is not forced to learn a third spelling.
///
/// `I(...)` is NOT the same unknown as `V(...)` and does not strip to the bare
/// name. §5.4.2 makes a flow its OWN unknown — lower.zig `flowUnknown` interns
/// it as `flow(hi,lo)`, `portFlowUnknown` as `flow(<p>)` — so `I(a)` is the
/// branch (a, ground) flow, spelled `flow(a,gnd)` because §1.3.1.1 collapses
/// every ground onto the one reference node named `gnd`, and `I(<a>)` is the
/// §5.4.3 port flow. Stripping to `a` bound the node POTENTIAL instead, which is
/// a different quantity that happens to have a name in scope: silently the wrong
/// number rather than a miss `ix()` could report.
///
/// `ix()` looks the result up in the emitted `U` enum, whose members codegen
/// built with `naming.sanitize`, so a name that is not a legal Zig identifier
/// has to go through the same function — a §3.6.3 vector element is `p[0]` in
/// the source and `pZ5b0Z5d` in the enum.
///
/// A name that IS already a legal identifier is taken as written, and that is
/// not an optimisation: a §5.4.2 branch-flow unknown has no source spelling at
/// all, so a fixture that biases one writes the escaped form directly
/// (`flowZ28pZ2cnZ29`), and sanitizing that again would escape its `Z`s.
/// `isValidId` also rejects Zig keywords, so a net called `fn` still gets its
/// trailing `Z`.
///
/// WHY THIS STAYS A TEXT→TEXT MAPPING, after wave 11 keyed the unknowns on
/// `{kind, node pair}` and took the same re-derivation out of `codegen`. There
/// is no `Lower` here to ask: `parse` runs on the fixture's `//!` lines with an
/// arena and nothing else (its tests call it on a string), and the answer is
/// consumed by `ix()`, which resolves a name against the emitted `U` enum at the
/// runner's COMPILE time. So this file cannot hold a node index, only a member
/// name, and the convention above is the whole interface. What pins the two ends
/// together is codegen.zig's "the `U` block is the SPELLING contract" test and
/// this file's own §5.4.2 test, which spell the same members from both sides.
///
/// One residual, and it is the directive language's, not lowering's: `I(a)` on a
/// module that ALSO has a plain net called `gnd` is ambiguous here, because
/// `flow(a,gnd)` is what both (a, reference) and (a, gnd) print before
/// `uniqueSpelling` suffixes the later one. Such a fixture writes the member as
/// `emitTopology` prints it. See `ch05_analog_behavior/
/// net_named_gnd_is_not_ground.va`, which reads both currents in the model
/// instead and needs no binding at all.
fn unknownName(arena: Allocator, raw: []const u8) Error![]const u8 {
    var s = std.mem.trim(u8, raw, " \t");
    if (std.mem.startsWith(u8, s, "V(") and std.mem.endsWith(u8, s, ")")) {
        s = std.mem.trim(u8, s[2 .. s.len - 1], " \t");
        // §5.4.2's branch POTENTIAL is not a solver unknown. `node_voltages`
        // holds nets; a branch potential is V(a) - V(b), derived from two of
        // them, so there is no row to pin and `//! bias V(a,c) = 0.6` is asking
        // for something that does not exist.
        //
        // Diagnosed HERE, at directive-parse time, because of what used to
        // happen instead: the name fell through to `naming.sanitize`, `a, c`
        // became the identifier `aZ2cZ20c`, and the generated testbench failed
        // to build with `//! names unknown aZ2cZ20c` — which `torture.zig`
        // reports as "an ENGINE bug", since a testbench that will not compile
        // normally is one. A fixture's typo was indistinguishable from a
        // compiler defect.
        if (std.mem.indexOfScalar(u8, s, ',') != null) return error.BadUnknownName;
    }
    if (std.mem.startsWith(u8, s, "I(") and std.mem.endsWith(u8, s, ")")) {
        const inner = std.mem.trim(u8, s[2 .. s.len - 1], " \t");
        s = if ((inner.len != 0 and inner[0] == '<') or std.mem.indexOfScalar(u8, inner, ',') != null)
            try std.fmt.allocPrint(arena, "flow({s})", .{inner})
        else
            try std.fmt.allocPrint(arena, "flow({s},gnd)", .{inner}); // §5.4.2 I(a) ≡ I(a,gnd)
    }
    if (std.mem.startsWith(u8, s, "x[") and std.mem.endsWith(u8, s, "]")) s = s[2 .. s.len - 1];
    s = std.mem.trim(u8, s, " \t");
    if (s.len == 0 or std.zig.isValidId(s)) return s;
    // Worst case is three bytes out per byte in (`Z` plus two hex digits),
    // plus the one `Z` a Zig-reserved word picks up.
    const buf = try arena.alloc(u8, s.len * 3 + 1);
    return naming.sanitize(buf, s) catch unreachable;
}

/// `name = value` pairs, split on TOP-LEVEL commas.
///
/// Top-level, because §5.4.2's two-terminal branch flow is spelled `I(a,b)` and
/// its comma separates the access function's ARGUMENTS, not two bindings. A
/// plain `splitScalar(',')` cut it in half, so `//! bias I(a,b) = 0.25` was
/// `error.BadSyntax` while `//! sweep I(a,b) = 0.25` — which splits on the first
/// `=` and never sees the comma — worked. That asymmetry was a consequence of
/// this parser, not a decision about the directive language: `bias` and `sweep`
/// now spell an unknown the same way.
///
/// Only `(` nests. A `//!` name is an access function over identifiers, and the
/// one other bracket a fixture writes — a §6.5.2 element, `d[1]` — cannot
/// contain a comma.
fn parseBindings(arena: Allocator, rest: []const u8, out: *std.ArrayList(Binding)) Error!void {
    var depth: u32 = 0;
    var start: usize = 0;
    for (rest, 0..) |ch, i| switch (ch) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        ',' => if (depth == 0) {
            try oneBinding(arena, rest[start..i], out);
            start = i + 1;
        },
        else => {},
    };
    try oneBinding(arena, rest[start..], out);
}

fn oneBinding(arena: Allocator, item: []const u8, out: *std.ArrayList(Binding)) Error!void {
    const t = std.mem.trim(u8, item, " \t");
    if (t.len == 0) return;
    const at = std.mem.indexOfScalar(u8, t, '=') orelse return error.BadSyntax;
    const name = std.mem.trim(u8, t[0..at], " \t");
    if (name.len == 0) return error.BadSyntax;
    try out.append(arena, .{
        .name = try unknownName(arena, name),
        .value = try number(t[at + 1 ..]),
    });
}

fn parseNumbers(arena: Allocator, rest: []const u8) Error![]const f64 {
    var out: std.ArrayList(f64) = .empty;
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len == 0) continue;
        try out.append(arena, try number(t));
    }
    if (out.items.len == 0) return error.BadSyntax;
    return out.items;
}

/// A directive number. §2.6's engineering suffixes are accepted because a
/// Verilog-A author writes `1u`, not `1e-6`, three lines below in the source.
fn number(raw: []const u8) Error!f64 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len == 0) return error.BadNumber;
    const exp = Lexer.scaleExp(t[t.len - 1]) orelse
        return std.fmt.parseFloat(f64, t) catch error.BadNumber;

    // The suffix is folded into the EXPONENT and parsed once, which is what
    // `Lexer.scaleExp` exists to make possible and what the model's own lexer
    // does with the same spelling. This used to multiply by 1e-6 instead, and
    // `200 * 1e-6` is 1.9999999999999998e-4 where `200e-6` is 2.0e-4 — so a
    // `//! time 200u` point compared LESS THAN a `200u` written in the model,
    // and every `($abstime < 200u) || <claim>` guard was true at 200u. The
    // fixtures that use that idiom to fire an assertion at their last timepoint
    // were asserting nothing there.
    const head = std.mem.trim(u8, t[0 .. t.len - 1], " \t");
    if (head.len == 0) return error.BadNumber;
    var buf: [64]u8 = undefined;
    if (head.len + exp.len > buf.len) return error.BadNumber;
    @memcpy(buf[0..head.len], head);
    @memcpy(buf[head.len..][0..exp.len], exp);
    return std.fmt.parseFloat(f64, buf[0 .. head.len + exp.len]) catch error.BadNumber;
}

// ---------------------------------------------------------------------------
// Runner generation
// ---------------------------------------------------------------------------

/// Emit the runner's Zig source. `title` is what each transcript block is keyed
/// by — the fixture's file stem, so a failing diff names the fixture.
///
/// Everything is written with `std.debug.print`, which is also where the
/// generated `$strobe` writes: ONE stream, so the interleaving of the model's
/// own output with the harness's is deterministic and diffable. stdout is left
/// alone for a caller that wants to pipe something else.
pub fn renderRunner(arena: Allocator, title: []const u8, d: Directives) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(arena, runner_head);
    try print(&out, arena, "const title = \"{f}\";\n\n", .{std.zig.fmtString(title)});
    try out.appendSlice(arena, runner_body);

    // --- main -------------------------------------------------------------
    try out.appendSlice(arena,
        \\pub fn main() void {
        \\    var model: D.Model = .{};
        \\
    );
    for (d.params) |p| {
        // §3.4.1/§4.2.1.1 via `cardValue`: a card is written in reals and an
        // integer parameter rounds, away from zero on a tie. Writing the real
        // straight into an `i64` field was not even a wrong number — it was a
        // `zig build-exe` failure, "fractional component prevents float value
        // '-1.5' from coercion to type 'i64'".
        try print(&out, arena, "    model.{f} = cardValue(@TypeOf(model.{f}), {f});\n", .{
            std.zig.fmtId(p.name), std.zig.fmtId(p.name), fmtF64(p.value),
        });
        // §9.19 `$param_given` is answered from a companion field when codegen
        // emitted one. Setting the value without it would make an explicit
        // override read as "not given".
        try print(
            &out,
            arena,
            "    if (comptime @hasField(D.Model, \"{f}__given\")) @field(model, \"{f}__given\") = true;\n",
            .{ std.zig.fmtString(p.name), std.zig.fmtString(p.name) },
        );
    }
    // §6.3.4: the model card is complete only now, so this is where a parameter
    // defined over another one gets its value. It runs unconditionally — a
    // §3.4.5 localparam is re-derived even with no `//! param` line, since the
    // point of `derive` is also that a localparam is not overridable.
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "derive")) D.derive(&model);
        \\
        \\    var inst: D.Instance = .{};
        \\
    );
    try print(&out, arena, "    inst.temperature = {f};\n", .{fmtF64(d.temp)});
    try print(&out, arena, "    inst.analysis_kind = .{t};\n", .{d.analysis});
    // §2.8.3/§12.32: this testbench IS a host, so it answers for the device's
    // unresolved `$name`s like any other. It binds `no_vpi_app` rather than
    // being exempt from `validateHost` — an exemption for the tool's own host is
    // how a seam stops being tested, and it is the one host that certainly
    // exercises every device VerA emits.
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &no_vpi_app;
        \\    // Temperature/parameter-only prep: after the card and the
        \\    // temperature write, before the first evaluation — the same
        \\    // ordering the ARPice host keeps (finalize/reprep).
        \\    if (comptime @hasDecl(D, "precompute")) D.precompute(&inst, &model);
        \\
    );
    try out.appendSlice(arena,
        \\
        \\    std.debug.print("=== {s} ===\n", .{title});
        \\
    );

    // --- §4.6.4 the exported noise topology ---------------------------------
    //
    // Before the operating points, and once: `noise_gens` is a COMPTIME table,
    // a property of the model and not of a bias. Printing it per point would
    // repeat one fact N times and make a sweep's transcript say N times as much
    // as it knows.
    if (d.asserts_noise) {
        try out.appendSlice(arena,
            \\
            \\    // §4.6.4: what this device tells a host about its noise
            \\    // generators. Nothing in the model's own text can see this —
            \\    // §4.6.2 makes every source read 0 outside a small-signal
            \\    // analysis — so the table is the only place the clause is
            \\    // observable, and a `//! noise` line is how a fixture reaches it.
            \\    {
            \\        const want = [_][]const u8{
            \\
        );
        for (d.noise) |e| try print(&out, arena, "            \"{f}\",\n", .{std.zig.fmtString(e.topo)});
        try out.appendSlice(arena,
            \\        };
            \\        if (comptime @hasDecl(D, "noise_gens")) {
            \\            std.debug.print("noise count got={d} want={d} ok={d}\n", .{
            \\                D.noise_gens.len, want.len, @intFromBool(D.noise_gens.len == want.len),
            \\            });
            \\            inline for (D.noise_gens, 0..) |g, i| {
            \\                var buf: [192]u8 = undefined;
            \\                // `U`'s tag names ARE the spelling contract — the same
            \\                // names a `//! bias` line uses and the same ones a
            \\                // diagnostic prints — so a fixture writes what it reads
            \\                // in the source.
            \\                // `#k` is §4.6.4.6's correlation column: two rows
            \\                // printing the same `#k` share one physical generator;
            \\                // `#null` is a row that declared no identity.
            \\                const got = std.fmt.bufPrint(&buf, "{s}({s},{s})#{?d}", .{
            \\                    @tagName(g.kind),
            \\                    @tagName(@as(D.U, @enumFromInt(g.row))),
            \\                    @tagName(@as(D.U, @enumFromInt(g.col))),
            \\                    g.source,
            \\                }) catch "<too long>";
            \\                const w_i: []const u8 = if (i < want.len) want[i] else "<none>";
            \\                std.debug.print("noise[{d}] got={s} want={s} ok={d}\n", .{
            \\                    i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)),
            \\                });
            \\            }
            \\        } else {
            \\            // No table at all is the empty table: a device that
            \\            // declares no generator does not declare an empty one.
            \\            std.debug.print("noise count got=0 want={d} ok={d}\n", .{
            \\                want.len, @intFromBool(want.len == 0),
            \\            });
            \\        }
            \\    }
            \\
        );
        try emitNoiseComptime(arena, &out, d);
    }

    // --- §4.6.3 the exported AC stimulus topology ---------------------------
    if (d.asserts_acstim) try emitAcTopology(arena, &out, d);

    // --- one straight-line block per operating point ------------------------
    //
    // The SWEEP is the outer loop and TIME the inner one, and the §4.5 operator
    // state belongs to the inner walk: each sweep point is its own transient run
    // and starts from a fresh `State`, or the second bias would inherit the
    // first one's history and no transcript line would mean anything on its own.
    const points = try expand(arena, d);
    // §5.10.2 / Table 5-1: `initial_step` is active on the FIRST point of an
    // analysis and `final_step` on the LAST. What counts as "an analysis" here
    // is read off the runner's own shape. With `//! time` each sweep block is a
    // separate transient run — it restarts the time walk at dt = 0 with a fresh
    // `State` — so every block carries its own first and last point. Without it
    // the blocks are the steps of ONE dc sweep, and only the first and last step
    // of the whole sweep carry the events. A one-point fixture is both at once,
    // which is exactly the DCOP column of Table 5-1: both events, one point.
    const per_block = d.times.len > 1;
    var n: usize = 0;
    // `//! psweep` gives each point its OWN model card: §8.2 makes a parametric
    // sweep a series of sub-tasks, and §6.3.4 says anything derived from the
    // swept parameter has to be recomputed with it, which is `derive`'s job.
    // Without a psweep line not one byte of this changes — the shared `model`
    // built above is passed straight through, as it always was.
    const mdl = if (d.psweeps.len == 0) "model" else "pm";
    for (points) |pt| {
        try out.appendSlice(arena, "    {\n");
        if (d.psweeps.len != 0) {
            try out.appendSlice(arena, "        var pm = model;\n");
            for (d.psweeps, pt[d.sweeps.len..]) |s, v| {
                try print(&out, arena, "        pm.{f} = cardValue(@TypeOf(pm.{f}), {f});\n", .{
                    std.zig.fmtId(s.name), std.zig.fmtId(s.name), fmtF64(v),
                });
                try print(
                    &out,
                    arena,
                    "        if (comptime @hasField(D.Model, \"{f}__given\")) @field(pm, \"{f}__given\") = true;\n",
                    .{ std.zig.fmtString(s.name), std.zig.fmtString(s.name) },
                );
            }
            try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"derive\")) D.derive(&pm);\n");
            // §6.3.4 again: the hoisted prep derives from the swept card too.
            try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"precompute\")) D.precompute(&inst, &pm);\n");
        }
        // `forced` is the other half of the operating point: which unknowns the
        // HOST drives, as opposed to which ones the device's own equations
        // determine. Newton needs the distinction; a bare evaluation did not.
        // Its DEFAULT is the harness's netlist — every unknown tied to the
        // reference — and `//! solve` is what unties the ones no line names.
        try print(
            &out,
            arena,
            "        var x: [n_u]f64 = @splat(0.0);\n        var forced: [n_u]?f64 = @splat({s});\n" ++
                // §3.6.3.2: "the value ... will be used as a nodeset value by
                // the analog solver". A nodeset is an INITIAL GUESS and nothing
                // more — it seeds `x` and does not touch `forced`, so Newton is
                // free to walk away from it. On a system with more than one
                // solution that is the entire point: `a08_nodeset_01`'s cubic
                // has roots at 1, 2 and 3, and which one the solve lands on is
                // decided right here.
                //
                // VerA has emitted `u_nodeset` for as long as it has parsed net
                // initializers, and nothing had ever read it — so the clause
                // was implemented up to the device boundary and no further.
                //
                // Before the `//! bias` lines below, so a fixture that names an
                // unknown outright still wins: a bias is a constraint, a
                // nodeset is a suggestion.
                "        if (comptime @hasDecl(D, \"u_nodeset\")) for (D.u_nodeset, 0..) |nodeset_i, i| {{\n" ++
                "            if (nodeset_i) |v| x[i] = v;\n" ++
                "        }};\n" ++
                "        var state = newState(&{s}, &inst);\n",
            .{ if (d.solve_free) "null" else "0.0", mdl },
        );
        for (d.bias) |b|
            try print(&out, arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
        for (d.sweeps, pt[0..d.sweeps.len]) |s, v|
            try print(&out, arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(s.name), fmtF64(v) });
        for (d.times, 0..) |t, k| {
            for (d.waves) |wv| {
                // A short `wave` HOLDS its last value — that is how a step is
                // written without repeating the level once per remaining time.
                const v = wv.values[@min(k, wv.values.len - 1)];
                try print(&out, arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(wv.name), fmtF64(v) });
            }
            // §4.5.3 `ddt` divides by `dt`; the FIRST time is the DC point, so
            // it gets dt = 0 — which every operator kernel reads as "no history"
            // and answers with its DC form (§4.5.4 the initial condition,
            // §4.5.11 the filter's DC gain).
            const dt: f64 = if (k == 0) 0.0 else d.times[k] - d.times[k - 1];
            try print(&out, arena, "        inst.abstime = {f};\n        inst.dt = {f};\n", .{ fmtF64(t), fmtF64(dt) });
            // Both are written at every point, never left over from the last
            // one: the guard codegen emits reads the field as it stands when
            // `eval`/`display` runs, so a stale `true` would fire the body a
            // second time.
            try print(&out, arena, "        inst.is_initial_step = {};\n        inst.is_final_step = {};\n", .{
                k == 0 and (per_block or n == 0),
                k + 1 == d.times.len and (per_block or n + 1 == points.len),
            });
            // §5.2.1 `analog initial` is re-executed per SUB-TASK, which in this
            // runner is one point of the sweep: the first time step of every
            // block, whether or not that block is the first of the analysis.
            // That is the one place it differs from `is_initial_step` above, and
            // the difference is only visible under `//! psweep` — where the
            // clause's "if a parameter ... is changed during a sub-task ... the
            // analog initial block shall be re-executed" is exactly the case.
            try print(&out, arena, "        inst.is_analog_initial = {};\n", .{k == 0});
            // §5.6 the model is evaluated AT A SOLUTION: solve first, then let
            // the model print. Every `//!` value is still exactly itself — it
            // came in as a constraint row — and everything else is now the
            // number the device's own equations put there.
            try print(&out, arena, "        const solved{d} = solve(&x, &forced, &{s}, &inst);\n", .{ n, mdl });
            try print(&out, arena, "        point({d}, &x, {f}, &{s}, &inst);\n", .{ n, fmtF64(t), mdl });
            // §4.6.4.1/.2 the PSD is a function of the BIAS, so unlike the
            // topology it cannot be printed once beside the comptime table.
            // The first point is the one a fixture states: it is the only
            // point every fixture has, and pinning a density at a named bias
            // is the whole content of a bias-dependent `white=`.
            if (n == 0) try emitNoisePsd(arena, &out, d, mdl);
            // §4.6.3 the magnitude and phase are the model CARD's — a parameter
            // is a legal `mag` — so they need a card, which is this block's
            // `mdl`; `//! psweep` gives each point its own and the first point
            // is the one a fixture states, exactly as for the PSD above.
            if (n == 0) try emitAcStim(arena, &out, d, mdl);
            // §4.5.2 accepted-step bookkeeping. This is the whole reason the
            // stateful operators are observable at all: `eval` reads history out
            // of `Instance`, and only `updateState` ever writes it.
            try print(&out, arena, "        stepPost(&{s}, &inst, &x, &state, solved{d});\n", .{ mdl, n });
            n += 1;
        }
        try out.appendSlice(arena, "    }\n");
    }

    try out.appendSlice(arena, if (d.print_residual)
        \\}
        \\
        \\const print_residual = true;
        \\
    else
        \\}
        \\
        \\const print_residual = false;
        \\
    );
    return out.items;
}

/// The relative compare the `white`/`flicker`/`ef`/`points` fields use, emitted
/// as a local rather than added to the prelude: it exists only where a `//!
/// noise` line asked for a number, and a prelude declaration would be dead in
/// every other testbench.
const noise_close =
    \\        const nclose = struct {
    \\            fn f(g: f64, w: f64, rt: f64) bool {
    \\                return @abs(g - w) <= rt * @max(@abs(g), @abs(w));
    \\            }
    \\        }.f;
    \\
;

/// The §4.6.4 fields that are COMPTIME properties of the device: the source
/// label (§4.6.4.1/.2/.3) and the tabulated spectrum (§4.6.4.3/.4). Emitted
/// beside the topology block, one guarded statement per asserting line, so a
/// fixture that asserts none of them adds nothing.
fn emitNoiseComptime(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    var any_points = false;
    for (d.noise) |w| {
        if (w.points != null) any_points = true;
    }
    var any = any_points;
    for (d.noise) |w| {
        if (w.name != null or w.interp != null) any = true;
    }
    if (!any) return;
    try out.appendSlice(arena, "    if (comptime @hasDecl(D, \"noise_gens\")) {\n");
    if (any_points) try out.appendSlice(arena, noise_close);
    for (d.noise, 0..) |w, k| {
        if (w.name == null and w.interp == null and w.points == null) continue;
        try print(out, arena, "        if (comptime D.noise_gens.len > {d}) {{\n", .{k});
        if (w.name) |nm| try print(
            out,
            arena,
            "            std.debug.print(\"noise[{d}].name got={{s}} want={{s}} ok={{d}}\\n\", .{{\n" ++
                "                D.noise_gens[{d}].name, \"{f}\",\n" ++
                "                @intFromBool(std.mem.eql(u8, D.noise_gens[{d}].name, \"{f}\")),\n" ++
                "            }});\n",
            .{ k, k, std.zig.fmtString(nm), k, std.zig.fmtString(nm) },
        );
        if (w.interp != null or w.points != null) {
            // A `.table` row and only a `.table` row has a spectrum here. A
            // fixture that asserts `points` on a parametric row is asserting
            // something the export cannot carry, and that is a FAIL with a
            // reason rather than a crash on `g.table.?`.
            try print(out, arena,
                \\            if (D.noise_gens[{d}].table) |ti| {{
                \\                const tbl = D.noise_tables[ti];
                \\
            , .{k});
            if (w.interp) |ip| try print(
                out,
                arena,
                "                std.debug.print(\"noise[{d}].interp got={{s}} want={{s}} ok={{d}}\\n\", .{{\n" ++
                    "                    @tagName(tbl.interp), \"{s}\",\n" ++
                    "                    @intFromBool(std.mem.eql(u8, @tagName(tbl.interp), \"{s}\")),\n" ++
                    "                }});\n",
                .{ k, ip, ip },
            );
            if (w.points) |pts| {
                try out.appendSlice(arena, "                const want_pts = [_][2]f64{");
                for (pts, 0..) |p, i| try print(out, arena, "{s}.{{ {f}, {f} }}", .{
                    if (i == 0) " " else ", ", fmtF64(p[0]), fmtF64(p[1]),
                });
                try print(out, arena,
                    \\ }};
                    \\                var pts_ok = tbl.points.len == want_pts.len;
                    \\                if (pts_ok) for (tbl.points, want_pts) |g, wp| {{
                    \\                    if (!nclose(g[0], wp[0], {f}) or !nclose(g[1], wp[1], {f})) {{
                    \\                        pts_ok = false;
                    \\                        break;
                    \\                    }}
                    \\                }};
                    \\                std.debug.print("noise[{d}].points got={{any}} want={{any}} ok={{d}}\n", .{{
                    \\                    tbl.points, want_pts, @intFromBool(pts_ok),
                    \\                }});
                    \\
                , .{ fmtF64(w.rtol), fmtF64(w.rtol), k });
            }
            try print(out, arena,
                \\            }} else std.debug.print("noise[{d}].table got=none want=a table ok=0\n", .{{}});
                \\
            , .{k});
        }
        try out.appendSlice(arena, "        }\n");
    }
    try out.appendSlice(arena, "    }\n");
}

/// §4.6.4.1/.2 `white`, `flicker` and `ef`, read out of `noisePsd` at the
/// operating point this is emitted into. `model` is the caller's card name,
/// which `//! psweep` renames.
fn emitNoisePsd(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    var any = false;
    for (d.noise) |w| {
        if (w.needsPoint()) any = true;
    }
    if (!any) return;
    try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"noisePsd\")) {\n");
    try out.appendSlice(arena, noise_close);
    try print(out, arena, "            const psd = D.noisePsd(x, &{s}, &inst);\n", .{mdl});
    for (d.noise, 0..) |w, k| {
        if (!w.needsPoint()) continue;
        try print(out, arena, "            if (comptime D.noise_gens.len > {d}) {{\n", .{k});
        // §4.6.4.6: a density is scaled by the square of the use's
        // coefficient, an exponent is not scaled at all.
        const fields = [_]struct { []const u8, ?f64, bool }{
            .{ "white", w.white, true },
            .{ "flicker", w.flicker, true },
            .{ "ef", w.ef, false },
        };
        for (fields) |f| {
            const want = f[1] orelse continue;
            const got = if (f[2])
                try std.fmt.allocPrint(arena, "psd[{d}].{s} * psd[{d}].coeff * psd[{d}].coeff", .{ k, f[0], k, k })
            else
                try std.fmt.allocPrint(arena, "psd[{d}].{s}", .{ k, f[0] });
            try print(
                out,
                arena,
                "                std.debug.print(\"noise[{d}].{s} got={{d}} want={{d}} ok={{d}}\\n\", .{{\n" ++
                    "                    {s}, {f},\n" ++
                    "                    @intFromBool(nclose({s}, {f}, {f})),\n" ++
                    "                }});\n",
                .{ k, f[0], got, fmtF64(want), got, fmtF64(want), fmtF64(w.rtol) },
            );
        }
        try out.appendSlice(arena, "            }\n");
    }
    try out.appendSlice(arena, "        }\n");
}

/// §4.6.3 the COMPTIME half of the AC stimulus export: how many sources there
/// are, which branch each is on, and which analysis it answers to. One block,
/// not one per line: unlike `noise_gens`'s per-row tables there is nothing here
/// that needs a `k`-indexed statement of its own.
fn emitAcTopology(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    try out.appendSlice(arena,
        \\
        \\    // §4.6.3: what this device tells a host about its AC stimuli. The
        \\    // model's own text cannot see this either — what a `CHECK` on
        \\    // `ac_stim` reads back is the residual's real part, `mag*cos(phase)`
        \\    // — so the phasor leaves through `ac_gens`/`acStim` and a
        \\    // `//! acstim` line is how a fixture reaches it.
        \\    {
        \\        const want = [_][]const u8{
        \\
    );
    for (d.acstim) |e| try print(out, arena, "            \"{f}\",\n", .{std.zig.fmtString(e.topo)});
    try out.appendSlice(arena, "        };\n");
    // A parallel `?[]const u8` column rather than a second guarded block per
    // line: `inline for` makes the index comptime, so one lookup covers every
    // line and a line that asserts no name simply has none.
    try out.appendSlice(arena, "        const want_name = [_]?[]const u8{");
    for (d.acstim, 0..) |e, i| {
        if (e.name) |nm|
            try print(out, arena, "{s}\"{f}\"", .{ if (i == 0) " " else ", ", std.zig.fmtString(nm) })
        else
            try print(out, arena, "{s}null", .{if (i == 0) " " else ", "});
    }
    try out.appendSlice(arena,
        \\ };
        \\        _ = &want_name;
        \\        if (comptime @hasDecl(D, "ac_gens")) {
        \\            std.debug.print("acstim count got={d} want={d} ok={d}\n", .{
        \\                D.ac_gens.len, want.len, @intFromBool(D.ac_gens.len == want.len),
        \\            });
        \\            inline for (D.ac_gens, 0..) |g, i| {
        \\                var buf: [192]u8 = undefined;
        \\                // `U`'s tag names ARE the spelling contract, same as the
        \\                // `//! noise` block and the same as `//! bias`.
        \\                const got = std.fmt.bufPrint(&buf, "({s},{s})", .{
        \\                    @tagName(@as(D.U, @enumFromInt(g.row))),
        \\                    @tagName(@as(D.U, @enumFromInt(g.col))),
        \\                }) catch "<too long>";
        \\                const w_i: []const u8 = if (i < want.len) want[i] else "<none>";
        \\                std.debug.print("acstim[{d}] got={s} want={s} ok={d}\n", .{
        \\                    i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)),
        \\                });
        \\                if (i < want_name.len) if (want_name[i]) |wn| {
        \\                    std.debug.print("acstim[{d}].name got={s} want={s} ok={d}\n", .{
        \\                        i, g.name, wn, @intFromBool(std.mem.eql(u8, g.name, wn)),
        \\                    });
        \\                };
        \\            }
        \\        } else {
        \\            // No table at all is the empty table, for the reason the
        \\            // `noise_gens` block gives.
        \\            std.debug.print("acstim count got=0 want={d} ok={d}\n", .{
        \\                want.len, @intFromBool(want.len == 0),
        \\            });
        \\        }
        \\    }
        \\
    );
}

/// §4.6.3 `mag` and `phase`, read out of `acStim` at the operating point this
/// is emitted into. `model` is the caller's card name, which `//! psweep`
/// renames — the same contract `emitNoisePsd` has.
fn emitAcStim(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    var any = false;
    for (d.acstim) |w| {
        if (w.needsPoint()) any = true;
    }
    if (!any) return;
    try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"acStim\")) {\n");
    try out.appendSlice(arena, noise_close);
    try print(out, arena, "            const stim = D.acStim(&{s}, &inst);\n", .{mdl});
    for (d.acstim, 0..) |w, k| {
        if (!w.needsPoint()) continue;
        try print(out, arena, "            if (comptime D.ac_gens.len > {d}) {{\n", .{k});
        const fields = [_]struct { []const u8, ?f64 }{ .{ "mag", w.mag }, .{ "phase", w.phase } };
        for (fields) |f| {
            const want = f[1] orelse continue;
            try print(
                out,
                arena,
                "                std.debug.print(\"acstim[{d}].{s} got={{d}} want={{d}} ok={{d}}\\n\", .{{\n" ++
                    "                    stim[{d}].{s}, {f},\n" ++
                    "                    @intFromBool(nclose(stim[{d}].{s}, {f}, {f})),\n" ++
                    "                }});\n",
                .{ k, f[0], k, f[0], fmtF64(want), k, f[0], fmtF64(want), fmtF64(w.rtol) },
            );
        }
        try out.appendSlice(arena, "            }\n");
    }
    try out.appendSlice(arena, "        }\n");
}

/// The cartesian product of the sweep lines, last varying fastest. One
/// allocation per point.
/// A point is `sweeps.len + psweeps.len` wide: the unknown columns first, then
/// the parameter columns, so `psweep` varies fastest and a parameter sweep reads
/// as the inner loop it is.
fn expand(arena: Allocator, d: Directives) Error![]const []const f64 {
    const dims = d.sweeps.len + d.psweeps.len;
    if (dims == 0) return &.{&.{}};
    const col = struct {
        fn at(dd: Directives, k: usize) Sweep {
            return if (k < dd.sweeps.len) dd.sweeps[k] else dd.psweeps[k - dd.sweeps.len];
        }
    };
    var total: usize = 1;
    for (0..dims) |k| {
        total *|= col.at(d, k).values.len;
        if (total > max_points) return error.TooManyPoints;
    }
    const rows = try arena.alloc([]const f64, total);
    for (rows, 0..) |*row, n| {
        const cells = try arena.alloc(f64, dims);
        var rem = n;
        var k = dims;
        while (k > 0) {
            k -= 1;
            const vals = col.at(d, k).values;
            cells[k] = vals[rem % vals.len];
            rem /= vals.len;
        }
        row.* = cells;
    }
    return rows;
}

/// `{d}` on an f64 is shortest-round-trip, which is exact but can print `1e-14`
/// — legal Zig. What it must never print is `inf`/`nan`, which are not.
fn fmtF64(x: f64) std.fmt.Alt(f64, formatF64) {
    return .{ .data = x };
}

fn formatF64(x: f64, w: *Io.Writer) Io.Writer.Error!void {
    if (std.math.isNan(x)) return w.writeAll("std.math.nan(f64)");
    if (std.math.isInf(x)) return w.writeAll(if (x > 0) "std.math.inf(f64)" else "-std.math.inf(f64)");
    try w.print("{d}", .{x});
}

fn print(out: *std.ArrayList(u8), arena: Allocator, comptime fmt: []const u8, args: anytype) Error!void {
    var aw: Io.Writer.Allocating = .fromArrayList(arena, out);
    defer out.* = aw.toArrayList();
    aw.writer.print(fmt, args) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// The runner's fixed text
// ---------------------------------------------------------------------------

const runner_head =
    \\// GENERATED BY VerA — DO NOT EDIT.
    \\// A runnable Verilog-A testbench: the device's own `$strobe` output plus
    \\// the residual and Jacobian at each `//!`-declared operating point.
    \\
    \\const std = @import("std");
    \\const D = @import("device");
    \\const contract = @import("contract");
    \\
    \\const n_u = @typeInfo(D.U).@"enum".fields.len;
    \\
    \\
;

const runner_body =
    \\/// §2.8.3/§12.32: this testbench is a HOST, and a host answers for every
    \\/// `$name` the compiler left to a VPI application. There is no application
    \\/// in a `vera --run` build, so this one answers zero — and that answer is
    \\/// the testbench's, written here where a reader can see it, not a value the
    \\/// compiler substituted behind everyone's back.
    \\///
    \\/// ZERO IS NOT A CLAIM ABOUT THE FUNCTION. §12.32.3's own sampnhold listing
    \\/// never initializes `sampler->value` before its first update callback, so
    \\/// the language fixes no value for an unregistered systf and there is
    \\/// nothing here to be wrong about. What a fixture over one of these may
    \\/// assert is what does NOT depend on the value: that the analog block runs
    \\/// straight through the call (§5.3.1), that the residual is still built.
    \\/// Asserting the 0.0 itself would pin this file's choice as if it were the
    \\/// LRM's, and a host-linked conforming tool would then fail the fixture.
    \\///
    \\/// The partials are zero for the same reason and one more: a systf whose
    \\/// derivative were left undefined would put a number nothing computed into
    \\/// the Jacobian, and Newton would chase it.
    \\fn noVpiApp(_: *anyopaque, _: usize, _: []const f64, partials: []f64) f64 {
    \\    @memset(partials, 0);
    \\    return 0;
    \\}
    \\var no_vpi_app: contract.SystfHost = .{ .ctx = undefined, .call = noVpiApp };
    \\
    \\/// What `contract.validateHost` checks this host by. The testbench is not
    \\/// exempt from it: an exemption for the tool's own host is how a seam stops
    \\/// being tested, and this is the host that runs against every device the
    \\/// torture suite compiles.
    \\pub const iteration_hooks = true;
    \\pub const mutable_eval = true;
    \\pub fn systf(_: *const D.Model) ?*const contract.SystfHost {
    \\    return &no_vpi_app;
    \\}
    \\comptime {
    \\    contract.validateHost(@This(), D);
    \\}
    \\
    \\/// §3.4.1: "If the type of the parameter is specified as integer or real,
    \\/// and the value assigned to the parameter conflicts with the type of the
    \\/// parameter, the value is converted to the type of the parameter (see
    \\/// 4.2.1.1)." A `//! param` card is written in reals, like any host's, so
    \\/// an integer parameter is handed one here.
    \\///
    \\/// §4.2.1.1: "Real numbers are converted to integers by rounding the real
    \\/// number to the nearest integer, rather than by truncating it ... If the
    \\/// fractional part of the real number is exactly 0.5, it shall be rounded
    \\/// away from zero." `@round` is exactly that tie rule; `lossyCast` then
    \\/// saturates rather than trapping, which is the model card's own guard
    \\/// against a number outside the field's width.
    \\fn cardValue(comptime T: type, v: f64) T {
    \\    return switch (@typeInfo(T)) {
    \\        .int => std.math.lossyCast(T, @round(v)),
    \\        else => v,
    \\    };
    \\}
    \\
    \\/// Index of the unknown a directive named. A miss is a compile error that
    \\/// names the directive, not a runtime surprise.
    \\fn ix(comptime name: []const u8) usize {
    \\    const u = comptime std.meta.stringToEnum(D.U, name) orelse
    \\        @compileError(title ++ ": `//!` names unknown `" ++ name ++ "`, which this module does not have");
    \\    return @intFromEnum(u);
    \\}
    \\
    \\/// Forward-mode dual: value plus one partial per solver unknown. This is
    \\/// the same scalar the engine instantiates for the Jacobian, written out
    \\/// here so the testbench has no dependency beyond the device itself.
    \\const Dual = struct {
    \\    v: f64,
    \\    d: [n_u]f64 = @splat(0.0),
    \\    const T = @This();
    \\
    \\    pub fn con(c: f64) T { return .{ .v = c }; }
    \\    pub fn val(a: T) f64 { return a.v; }
    \\    pub fn ddxAt(a: T, i: usize) f64 { return a.d[i]; }
    \\
    \\    fn map(a: T, v: f64, k: f64) T { // chain rule: k = df/da at a.v
    \\        var r: T = .{ .v = v };
    \\        for (0..n_u) |i| r.d[i] = k * a.d[i];
    \\        return r;
    \\    }
    \\    fn map2(a: T, b: T, v: f64, ka: f64, kb: f64) T {
    \\        var r: T = .{ .v = v };
    \\        for (0..n_u) |i| r.d[i] = ka * a.d[i] + kb * b.d[i];
    \\        return r;
    \\    }
    \\
    \\    pub fn add(a: T, b: T) T { return map2(a, b, a.v + b.v, 1.0, 1.0); }
    \\    pub fn sub(a: T, b: T) T { return map2(a, b, a.v - b.v, 1.0, -1.0); }
    \\    pub fn mul(a: T, b: T) T { return map2(a, b, a.v * b.v, b.v, a.v); }
    \\    pub fn div(a: T, b: T) T { return map2(a, b, a.v / b.v, 1.0 / b.v, -a.v / (b.v * b.v)); }
    \\    pub fn neg(a: T) T { return map(a, -a.v, -1.0); }
    \\    pub fn scale(a: T, c: f64) T { return map(a, a.v * c, c); }
    \\    pub fn addC(a: T, c: f64) T { return map(a, a.v + c, 1.0); }
    \\    pub fn exp(a: T) T { return map(a, @exp(a.v), @exp(a.v)); }
    \\    pub fn log(a: T) T { return map(a, @log(a.v), 1.0 / a.v); }
    \\    // §4.3.1 Table 4-14: the C forms, because exp(x)-1 and log(1+x) cancel
    \\    // for small x. The DERIVATIVES do not cancel, so they stay exp/1÷(1+x).
    \\    pub fn expm1(a: T) T { return map(a, std.math.expm1(a.v), @exp(a.v)); }
    \\    pub fn log1p(a: T) T { return map(a, std.math.log1p(a.v), 1.0 / (1.0 + a.v)); }
    \\    pub fn sqrt(a: T) T { return map(a, @sqrt(a.v), 0.5 / @sqrt(a.v)); }
    \\    pub fn sin(a: T) T { return map(a, @sin(a.v), @cos(a.v)); }
    \\    pub fn cos(a: T) T { return map(a, @cos(a.v), -@sin(a.v)); }
    \\    pub fn tanh(a: T) T { const t = std.math.tanh(a.v); return map(a, t, 1.0 - t * t); }
    \\    pub fn sinh(a: T) T { return map(a, std.math.sinh(a.v), std.math.cosh(a.v)); }
    \\    pub fn cosh(a: T) T { return map(a, std.math.cosh(a.v), std.math.sinh(a.v)); }
    \\    pub fn atan(a: T) T { return map(a, std.math.atan(a.v), 1.0 / (1.0 + a.v * a.v)); }
    \\    pub fn abs(a: T) T { return map(a, @abs(a.v), if (a.v < 0.0) -1.0 else 1.0); }
    \\    pub fn pow(a: T, c: f64) T {
    \\        return map(a, std.math.pow(f64, a.v, c), c * std.math.pow(f64, a.v, c - 1.0));
    \\    }
    \\    // §4.3.1 min/max are selections: the derivative is the winner's.
    \\    pub fn minC(a: T, c: f64) T { return if (a.v <= c) a else con(c); }
    \\    pub fn maxC(a: T, c: f64) T { return if (a.v >= c) a else con(c); }
    \\    pub fn min(a: T, b: T) T { return if (a.v <= b.v) a else b; }
    \\    pub fn max(a: T, b: T) T { return if (a.v >= b.v) a else b; }
    \\    // Contract masks and select. A comparison is piecewise constant, so
    \\    // its derivative is zero (`con`); like min/max, `sel` carries the
    \\    // winner's derivative.
    \\    pub fn lt(a: T, b: T) T { return con(@floatFromInt(@intFromBool(a.v < b.v))); }
    \\    pub fn le(a: T, b: T) T { return con(@floatFromInt(@intFromBool(a.v <= b.v))); }
    \\    pub fn eq(a: T, b: T) T { return con(@floatFromInt(@intFromBool(a.v == b.v))); }
    \\    pub fn sel(c: T, a: T, b: T) T { return if (c.v != 0.0) a else b; }
    \\};
    \\
    \\/// Value-form batch scalar: NL operating points per eval call, one per
    \\/// lane. Only instantiated for a device that declared `lane_clean` —
    \\/// codegen's promise that nothing in eval/q steers on a `.val()` of an
    \\/// x-dependent value, which is what makes `val` returning lane 0 safe:
    \\/// on a lane-clean device it is only ever called on lane-uniform values.
    \\const NL = 4;
    \\const VF = @Vector(NL, f64);
    \\const Vec = struct {
    \\    v: VF,
    \\    const T = @This();
    \\    fn map1(a: T, comptime f: anytype) T { // std.math fns are generic
    \\        var r: VF = undefined;
    \\        inline for (0..NL) |i| r[i] = f(a.v[i]);
    \\        return .{ .v = r };
    \\    }
    \\    pub fn con(c: f64) T { return .{ .v = @splat(c) }; }
    \\    pub fn val(a: T) f64 { return a.v[0]; }
    \\    pub fn ddxAt(_: T, _: usize) f64 { return 0.0; }
    \\    pub fn add(a: T, b: T) T { return .{ .v = a.v + b.v }; }
    \\    pub fn sub(a: T, b: T) T { return .{ .v = a.v - b.v }; }
    \\    pub fn neg(a: T) T { return .{ .v = -a.v }; }
    \\    pub fn mul(a: T, b: T) T { return .{ .v = a.v * b.v }; }
    \\    pub fn div(a: T, b: T) T { return .{ .v = a.v / b.v }; }
    \\    pub fn scale(a: T, c: f64) T { return .{ .v = a.v * @as(VF, @splat(c)) }; }
    \\    pub fn addC(a: T, c: f64) T { return .{ .v = a.v + @as(VF, @splat(c)) }; }
    \\    pub fn exp(a: T) T { return .{ .v = @exp(a.v) }; }
    \\    pub fn log(a: T) T { return .{ .v = @log(a.v) }; }
    \\    pub fn sqrt(a: T) T { return .{ .v = @sqrt(a.v) }; }
    \\    pub fn sin(a: T) T { return .{ .v = @sin(a.v) }; }
    \\    pub fn cos(a: T) T { return .{ .v = @cos(a.v) }; }
    \\    pub fn abs(a: T) T { return .{ .v = @abs(a.v) }; }
    \\    pub fn expm1(a: T) T { return map1(a, std.math.expm1); }
    \\    pub fn log1p(a: T) T { return map1(a, std.math.log1p); }
    \\    pub fn tanh(a: T) T { return map1(a, std.math.tanh); }
    \\    pub fn sinh(a: T) T { return map1(a, std.math.sinh); }
    \\    pub fn cosh(a: T) T { return map1(a, std.math.cosh); }
    \\    pub fn atan(a: T) T { return map1(a, std.math.atan); }
    \\    pub fn minC(a: T, c: f64) T { return .{ .v = @min(a.v, @as(VF, @splat(c))) }; }
    \\    pub fn maxC(a: T, c: f64) T { return .{ .v = @max(a.v, @as(VF, @splat(c))) }; }
    \\    pub fn min(a: T, b: T) T { return .{ .v = @min(a.v, b.v) }; }
    \\    pub fn max(a: T, b: T) T { return .{ .v = @max(a.v, b.v) }; }
    \\    pub fn pow(a: T, c: f64) T {
    \\        var r: VF = undefined;
    \\        inline for (0..NL) |i| r[i] = std.math.pow(f64, a.v[i], c);
    \\        return .{ .v = r };
    \\    }
    \\    const ones: VF = @splat(1.0);
    \\    const zeros: VF = @splat(0.0);
    \\    pub fn lt(a: T, b: T) T { return .{ .v = @select(f64, a.v < b.v, ones, zeros) }; }
    \\    pub fn le(a: T, b: T) T { return .{ .v = @select(f64, a.v <= b.v, ones, zeros) }; }
    \\    pub fn eq(a: T, b: T) T { return .{ .v = @select(f64, a.v == b.v, ones, zeros) }; }
    \\    pub fn sel(c: T, a: T, b: T) T { return .{ .v = @select(f64, c.v != zeros, a.v, b.v) }; }
    \\};
    \\
    \\comptime { // pinned to the contract's list, so a new primitive cannot miss one
    \\    contract.checkScalar(Dual);
    \\    contract.checkScalar(Vec);
    \\}
    \\
    \\/// The batch differential gate (ref/SIMD-Strategies T8): one vector eval
    \\/// over NL perturbed copies of the operating point must agree with NL
    \\/// scalar evals, lane by lane. Bit equality is the expectation — the same
    \\/// IEEE ops run in the same order per lane — with a 1e-12 relative escape
    \\/// for a vectorizer that contracts differently than the scalar pipeline.
    \\/// Prints nothing on success, so transcripts never move; a mismatch is a
    \\/// loud failure of the run.
    \\fn laneCheck(x: *const [n_u]f64, t: f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    \\    if (comptime !(@hasDecl(D, "lane_clean") and D.lane_clean)) return;
    \\    var xs: [NL][n_u]f64 = undefined;
    \\    var xv: [n_u]Vec = undefined;
    \\    for (0..NL) |k| {
    \\        const s = 1.0 + 1.0e-3 * @as(f64, @floatFromInt(k));
    \\        for (0..n_u) |i| xs[k][i] = x[i] * s + 1.0e-3 * @as(f64, @floatFromInt(k));
    \\    }
    \\    for (0..n_u) |i| {
    \\        // Through an array: a vector index must be comptime-known.
    \\        var lanes: [NL]f64 = undefined;
    \\        for (0..NL) |k| lanes[k] = xs[k][i];
    \\        xv[i] = .{ .v = lanes };
    \\    }
    \\    const rv = D.eval(Vec, xv, model, inst, t);
    \\    for (0..NL) |k| {
    \\        var xd: [n_u]Dual = undefined;
    \\        for (0..n_u) |i| {
    \\            xd[i] = .{ .v = xs[k][i] };
    \\            xd[i].d[i] = 1.0;
    \\        }
    \\        const rs = D.eval(Dual, xd, model, inst, t);
    \\        for (0..n_u) |i| {
    \\            const lanes: [NL]f64 = rv[i].v;
    \\            laneAssert("res", i, k, lanes[k], rs[i].v);
    \\        }
    \\    }
    \\    if (comptime @hasDecl(D, "q")) {
    \\        const qv = D.q(Vec, xv, model, inst, t);
    \\        for (0..NL) |k| {
    \\            var xd: [n_u]Dual = undefined;
    \\            for (0..n_u) |i| xd[i] = .{ .v = xs[k][i] };
    \\            const qs = D.q(Dual, xd, model, inst, t);
    \\            for (0..n_u) |i| {
    \\                const lanes: [NL]f64 = qv[i].v;
    \\                laneAssert("q", i, k, lanes[k], qs[i].v);
    \\            }
    \\        }
    \\    }
    \\}
    \\
    \\/// The fused differential gate: `evalQ` shares ONE core call between the
    \\/// two halves, so it must return exactly what the separate `eval` and `q`
    \\/// return. Same ops, same order, same core — bit equality, no epsilon.
    \\/// A mismatch means the shared-core hoist changed the physics, which is
    \\/// the only way this refactor can be wrong.
    \\fn fusedCheck(x: *const [n_u]f64, t: f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    \\    if (comptime !@hasDecl(D, "evalQ")) return;
    \\    const xd = seed(x);
    \\    const both = D.evalQ(Dual, xd, model, inst, t);
    \\    const res = D.eval(Dual, xd, model, inst, t);
    \\    const qq = D.q(Dual, xd, model, inst, t);
    \\    for (0..n_u) |i| {
    \\        fusedAssert("res", i, both.res[i].v, res[i].v);
    \\        fusedAssert("q", i, both.q[i].v, qq[i].v);
    \\        for (0..n_u) |j| {
    \\            fusedAssert("dres", i, both.res[i].d[j], res[i].d[j]);
    \\            fusedAssert("dq", i, both.q[i].d[j], qq[i].d[j]);
    \\        }
    \\    }
    \\}
    \\
    \\/// The structural-Jacobian gate. `jac_pattern`/`q_pattern` tell a host
    \\/// which local matrix entries this device can fill, and the host DELETES
    \\/// the stamps for the rest — it does not even reserve the matrix entry.
    \\/// So a cleared bit with a nonzero partial behind it is a silently missing
    \\/// Jacobian entry, and that is the one way the declaration can be wrong.
    \\/// The converse is legal: the pattern over-approximates on purpose, and a
    \\/// set bit that happens to be zero at this bias costs one stamp.
    \\fn patternCheck(x: *const [n_u]f64, t: f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    \\    const xd = seed(x);
    \\    const r = D.eval(Dual, xd, model, inst, t);
    \\    if (comptime @hasDecl(D, "jac_pattern")) patAssert("res", D.jac_pattern, &r);
    \\    if (comptime @hasDecl(D, "jac_rows")) rowAssert("res", D.jac_rows, &r);
    \\    if (comptime @hasDecl(D, "q")) {
    \\        const qr = D.q(Dual, xd, model, inst, t);
    \\        if (comptime @hasDecl(D, "q_pattern")) patAssert("q", D.q_pattern, &qr);
    \\        if (comptime @hasDecl(D, "q_rows")) rowAssert("q", D.q_rows, &qr);
    \\    }
    \\}
    \\
    \\fn patAssert(what: []const u8, pat: [n_u]u64, r: *const [n_u]Dual) void {
    \\    for (0..n_u) |i| for (0..n_u) |j| {
    \\        if (r[i].d[j] == 0.0) continue;
    \\        if ((pat[i] >> @intCast(j)) & 1 != 0) continue;
    \\        std.debug.print("pattern_check FAIL: d{s}[{s}]/dx[{s}] = {e} is outside the declared pattern\n", .{ what, u_names[i], u_names[j], r[i].d[j] });
    \\        std.process.exit(1);
    \\    };
    \\}
    \\
    \\/// The WRITTEN-ROW gate. A host drops a row outside `jac_rows`/`q_rows`
    \\/// entirely — no residual stamp, no charge-tape entry — so a clear bit
    \\/// with anything but a hard zero behind it is a term that vanishes from
    \\/// the netlist with no diagnostic. This is the check that fails if
    \\/// codegen ever writes `res[ru]` without going through `patRow`, and the
    \\/// value, not the derivative, is what it looks at: `isource` writes rows
    \\/// whose every partial is zero.
    \\fn rowAssert(what: []const u8, rows: u64, r: *const [n_u]Dual) void {
    \\    for (0..n_u) |i| {
    \\        if ((rows >> @intCast(i)) & 1 != 0) continue;
    \\        if (r[i].v == 0.0) continue;
    \\        std.debug.print("row_check FAIL: {s}[{s}] = {e} but the row is declared never written\n", .{ what, u_names[i], r[i].v });
    \\        std.process.exit(1);
    \\    }
    \\}
    \\
    \\fn fusedAssert(what: []const u8, i: usize, a: f64, b: f64) void {
    \\    if (@as(u64, @bitCast(a)) == @as(u64, @bitCast(b))) return;
    \\    std.debug.print("fused_check FAIL: {s}[{s}]: evalQ {e} vs split {e}\n", .{ what, u_names[i], a, b });
    \\    std.process.exit(1);
    \\}
    \\
    \\/// Bit equality is the expectation — the same IEEE ops run in the same
    \\/// order per lane — with a 1e-12 relative escape for a vectorizer that
    \\/// contracts differently than the scalar pipeline.
    \\fn laneAssert(what: []const u8, i: usize, k: usize, a: f64, b: f64) void {
    \\    if (@as(u64, @bitCast(a)) == @as(u64, @bitCast(b))) return;
    \\    if (@abs(a - b) <= 1.0e-12 * @max(@abs(a), @abs(b))) return;
    \\    std.debug.print("lane_check FAIL: {s}[{s}] lane {d}: batch {e} vs scalar {e}\n", .{ what, u_names[i], k, a, b });
    \\    std.process.exit(1);
    \\}
    \\
    \\/// §4.5.2 accepted-step bookkeeping. `void` for a module with no stateful
    \\/// operator, which is most of them — codegen emits the state machine only
    \\/// when one is present.
    \\const State = if (@hasDecl(D, "updateState") and @hasDecl(D, "initState")) D.State else void;
    \\
    \\fn newState(model: *const D.Model, inst: *D.Instance) State {
    \\    if (State == void) return {};
    \\    return D.initState(model, inst);
    \\}
    \\
    \\/// Commit the accepted solution, exactly as a transient solver does after
    \\/// a converged step. `eval` READS the history out of `Instance`; this is the
    \\/// only thing that ever writes it, so without this call every §4.5 operator
    \\/// would answer from zero history at every time point and the transcript
    \\/// would claim more than it proves.
    \\fn step(model: *const D.Model, inst: *D.Instance, x: *const [n_u]f64, state: *State) void {
    \\    if (State == void) return;
    \\    _ = D.updateState(model, inst, x.*, state);
    \\}
    \\
    \\/// Iteration history advances independently of accepted-time operators.
    \\/// §5.6.1.2 the accepted step's CHARGE, which is the other operand of the
    \\/// backward-Euler difference `solve` forms at the next time point. Taken
    \\/// before `step`, so it is the q of the state `eval` saw while this point
    \\/// was being solved and not of the history `updateState` is about to write.
    \\var q_prev: [n_u]f64 = @splat(0.0);
    \\
    \\fn commitCharge(model: *const D.Model, inst: *D.Instance, x: *const [n_u]f64) void {
    \\    if (comptime !@hasDecl(D, "q")) return;
    \\    const qq = D.q(Dual, seed(x), model, inst, inst.abstime);
    \\    for (0..n_u) |i| q_prev[i] = qq[i].v;
    \\}
    \\
    \\fn stepPost(model: *const D.Model, inst: *D.Instance, x: *const [n_u]f64, state: *State, solved: bool) void {
    \\    commitCharge(model, inst, x);
    \\    if (@hasDecl(D, "advanceIteration")) if (!solved) {
    \\        // Forced-point fixtures sample both lifetimes. Both updates must
    \\        // read the same evaluated state, even when their inputs depend
    \\        // on one another. These two fields are owned by iteration hooks.
    \\        var next = inst.*;
    \\        D.advanceIteration(model, &next, x.*);
    \\        step(model, inst, x, state);
    \\        if (@hasField(D.Instance, "limiter_previous")) inst.limiter_previous = next.limiter_previous;
    \\        if (@hasField(D.Instance, "newton_iteration")) inst.newton_iteration = next.newton_iteration;
    \\        return;
    \\    };
    \\    step(model, inst, x, state);
    \\}
    \\
    \\fn seed(x: *const [n_u]f64) [n_u]Dual {
    \\    var out: [n_u]Dual = undefined;
    \\    for (0..n_u) |i| {
    \\        out[i] = .{ .v = x[i] };
    \\        out[i].d[i] = 1.0;
    \\    }
    \\    return out;
    \\}
    \\
    \\const u_names = blk: {
    \\    const f = @typeInfo(D.U).@"enum".fields;
    \\    var names: [f.len][]const u8 = undefined;
    \\    for (f, 0..) |e, i| names[i] = e.name;
    \\    break :blk names;
    \\};
    \\
    \\/// One operating point: the bias, then whatever the model prints, then the
    \\/// residual it stamps and the Jacobian the solver would see.
    \\fn point(n: usize, x: *const [n_u]f64, t: f64, model: *const D.Model, inst: contract.InstancePtr(D)) void {
    \\    std.debug.print("--- point {d} ---\n", .{n});
    \\    for (0..n_u) |i| std.debug.print("  x[{s}] = {e:.6}\n", .{ u_names[i], x[i] });
    \\    if (inst.abstime != 0.0 or inst.dt != 0.0)
    \\        std.debug.print("  t = {e:.6}  dt = {e:.6}\n", .{ inst.abstime, inst.dt });
    \\
    \\    // §5.10.5 the host's breakpoint hook, when codegen emitted one (only a
    \\    // module with a `timer` has one). Printed OUTSIDE `print_residual`
    \\    // because it is not part of the residual and the fixtures that test it
    \\    // are `print none`; `@hasDecl` keeps every other transcript unchanged.
    \\    if (@hasDecl(D, "nextBreakpoint")) {
    \\        if (D.nextBreakpoint(model, t)) |bp|
    \\            std.debug.print("  next_bp = {e:.6}\n", .{bp})
    \\        else
    \\            std.debug.print("  next_bp = none\n", .{});
    \\    }
    \\
    \\    // Differential gates — silent on success, fail the run loudly.
    \\    laneCheck(x, t, model, inst);
    \\    fusedCheck(x, t, model, inst);
    \\    patternCheck(x, t, model, inst);
    \\
    \\    const xd = seed(x);
    \\    // §9.4 the model's own transcript. Runs BEFORE the residual print so a
    \\    // fixture's `$strobe` lines sit next to the bias that produced them.
    \\    if (@hasDecl(D, "display")) D.display(Dual, xd, model, inst, t);
    \\    if (!print_residual) return;
    \\
    \\    const res = D.eval(Dual, xd, model, inst, t);
    \\    for (0..n_u) |i| {
    \\        std.debug.print("  res[{s}] = {e:.6}\n", .{ u_names[i], res[i].v });
    \\        for (0..n_u) |j| {
    \\            if (res[i].d[j] == 0.0) continue;
    \\            std.debug.print("    d res[{s}]/d x[{s}] = {e:.6}\n", .{ u_names[i], u_names[j], res[i].d[j] });
    \\        }
    \\    }
    \\    // §5.6.1.2 the reactive half, when the model has one. Its derivative is
    \\    // the capacitance/inductance matrix the host multiplies by d/dt.
    \\    if (@hasDecl(D, "q")) {
    \\        const qq = D.q(Dual, xd, model, inst, t);
    \\        for (0..n_u) |i| {
    \\            if (qq[i].v == 0.0 and allZero(qq[i].d)) continue;
    \\            std.debug.print("  q[{s}] = {e:.6}\n", .{ u_names[i], qq[i].v });
    \\            for (0..n_u) |j| {
    \\                if (qq[i].d[j] == 0.0) continue;
    \\                std.debug.print("    d q[{s}]/d x[{s}] = {e:.6}\n", .{ u_names[i], u_names[j], qq[i].d[j] });
    \\            }
    \\        }
    \\    }
    \\}
    \\
    \\fn allZero(v: [n_u]f64) bool {
    \\    for (v) |e| if (e != 0.0) return false;
    \\    return true;
    \\}
    \\
    \\/// Pin an unknown at the value a `//! bias`, `//! sweep` or `//! wave` line
    \\/// gave it: the INITIAL GUESS Newton starts from, and the CONSTRAINT row it
    \\/// keeps. Both, from one directive, because a directive that names a value
    \\/// for an unknown is saying the host drives it.
    \\fn set(x: *[n_u]f64, forced: *[n_u]?f64, comptime name: []const u8, v: f64) void {
    \\    x[ix(name)] = v;
    \\    forced[ix(name)] = v;
    \\}
    \\
    \\/// §3.6.1.2 `abstol` — "the largest signal value that can be safely
    \\/// ignored" — per unknown, which is the absolute half of Newton's stopping
    \\/// test. The device declares it (codegen reads it off the net's discipline,
    \\/// §3.6.2.3 override included); the fallback is annex D's own defaults for
    \\/// `Voltage` and `Current`, for a hand-written device that declares neither
    \\/// table.
    \\const u_abstol: [n_u]f64 = if (@hasDecl(D, "u_abstol")) D.u_abstol else blk: {
    \\    var a: [n_u]f64 = @splat(1e-6);
    \\    if (@hasDecl(D, "u_kinds")) for (D.u_kinds, 0..) |k, i| {
    \\        if (k != .voltage) a[i] = 1e-12;
    \\    };
    \\    break :blk a;
    \\};
    \\
    \\/// The relative half. Tighter than a circuit simulator's default reltol
    \\/// because a fixture asserts a digit derived from the LRM, not a waveform:
    \\/// the systems here are small enough that the extra decades cost nothing.
    \\const solve_reltol = 1e-12;
    \\
    \\/// A cap, not a budget. Every fixture system converges in one step (linear)
    \\/// or a handful; reaching this means the iteration is not converging, and
    \\/// that has to be LOUD — see the exit below.
    \\const solve_max_iter = 100;
    \\
    \\/// §5.6 THE SOLVE, and it is a solve.
    \\///
    \\/// Verilog-A semantics are defined AT A SOLUTION of the nodal equations,
    \\/// never at an arbitrary point. §5.6.7's indirect contribution is a
    \\/// CONSTRAINT the simulator satisfies rather than an assignment — there is
    \\/// no way to express it by evaluating anything — and §5.4.2.2's "the
    \\/// potential of a source branch may be read" is a question about what the
    \\/// solver settled on. A harness that wrote `//! bias` into x[] and stopped
    \\/// could only ever hand a fixture back the number the harness itself just
    \\/// wrote.
    \\///
    \\/// So: Newton-Raphson on the residual the device stamps, with the Jacobian
    \\/// the forward-mode `Dual` above already carries. Dense LU with partial
    \\/// pivoting — a fixture's system is under ~10 unknowns, so a sparse
    \\/// factorisation or an ordering heuristic would be code with nothing to do.
    \\///
    \\/// ONE RULE BEYOND TEXTBOOK NEWTON, and it is what makes an isolated device
    \\/// solvable at all. A .va compiled alone is NOT a circuit. `I(p,n) <+ 0.0`
    \\/// stamps two identically-zero rows; a two-terminal module that never
    \\/// references ground leaves its common mode undetermined however nonlinear
    \\/// it is. Those are free directions of the device's own equations, not
    \\/// solver failures — a host pins them by CONNECTING the device to
    \\/// something. So a column with no usable pivot takes dx = 0 and its unknown
    \\/// HOLDS the operating point the `//!` lines declared, which is exactly the
    \\/// behaviour this harness had before it could solve at all. Convergence is
    \\/// then judged on the unknowns the system does determine, and only those.
    \\///
    \\/// ponytail: no gmin stepping, no source stepping, no continuation. Every
    \\/// system in the suite converges from the declared guess. Add the minimum
    \\/// and name it here if one ever does not.
    \\///
    \\/// §5.6.1.2's reactive half is folded in by BACKWARD EULER, because a
    \\/// fixture finally needed a transient solve: §5.4.3's port current is the
    \\/// whole of what the module stamps at the port, charge included, and
    \\/// `res[flow(<p>)] = x − res[p]` alone can only ever hand back the
    \\/// conduction half (ch05_analog_behavior/a02_06). So the row Newton sees is
    \\///
    \\///     eval(x) + (q(x) − q_prev) / dt
    \\///
    \\/// with `q_prev` the charge of the last accepted point (`commitCharge`).
    \\///
    \\/// ponytail: first order, fixed step, no LTE control and no step rejection
    \\/// — `//! time` states the steps and the suite asserts values a clause
    \\/// derives, not a waveform's accuracy. Trapezoidal or gear-2 is the upgrade
    \\/// if a fixture ever asserts a number the Euler truncation error moves.
    \\///
    \\/// dt = 0 is the DC point that opens a transient (`renderRunner` gives the
    \\/// first time step dt = 0 for exactly this reason, §4.5.3), and there the
    \\/// difference is undefined and the charge contributes nothing — so that
    \\/// point is still the resistive solve it always was.
    \\fn solve(x: *[n_u]f64, forced: *const [n_u]?f64, model: *const D.Model, inst: *D.Instance) bool {
    \\    // Nothing to determine: every unknown is one a `//!` line named, or the
    \\    // reference the harness ties the rest to without `//! solve`. x already
    \\    // holds the answer. Returning here is not only the cheap path — it is
    \\    // what keeps a `//! print none` fixture evaluated exactly as often as it
    \\    // was before there was a solver, so no §9.4 transcript moves.
    \\    for (forced) |f| {
    \\        if (f == null) break;
    \\    } else return false;
    \\    if (@hasDecl(D, "beginSolve")) D.beginSolve(inst);
    \\    var previous = x.*;
    \\    var worst: usize = 0;
    \\    var worst_dx: f64 = 0.0;
    \\    var iter: usize = 0;
    \\    while (iter < solve_max_iter) : (iter += 1) {
    \\        if (@hasDecl(D, "advanceIteration")) if (iter != 0) D.advanceIteration(model, inst, previous);
    \\        previous = x.*;
    \\        const xd = seed(x);
    \\        var r = D.eval(Dual, xd, model, inst, inst.abstime);
    \\        // §5.6.1.2 backward Euler — see the header. Value and derivative
    \\        // both, so the capacitance matrix reaches the Jacobian too.
    \\        if (comptime @hasDecl(D, "q")) if (inst.dt > 0.0) {
    \\            const qq = D.q(Dual, xd, model, inst, inst.abstime);
    \\            for (0..n_u) |i| {
    \\                r[i].v += (qq[i].v - q_prev[i]) / inst.dt;
    \\                for (0..n_u) |j| r[i].d[j] += qq[i].d[j] / inst.dt;
    \\            }
    \\        };
    \\        var a: [n_u][n_u]f64 = undefined;
    \\        var b: [n_u]f64 = undefined;
    \\        var scale: f64 = 0.0;
    \\        for (0..n_u) |i| {
    \\            if (forced[i]) |v| {
    \\                // The host drives this one, so its row is the constraint and
    \\                // not the device's KCL. Written as a Newton row (1·dx =
    \\                // v - x) rather than by assignment, so the value survives
    \\                // elimination against every other row exactly.
    \\                a[i] = @splat(0.0);
    \\                a[i][i] = 1.0;
    \\                b[i] = v - x[i];
    \\            } else {
    \\                a[i] = r[i].d;
    \\                b[i] = -r[i].v;
    \\            }
    \\            for (a[i]) |e| scale = @max(scale, @abs(e));
    \\        }
    \\        var dx: [n_u]f64 = undefined;
    \\        var solved: [n_u]bool = undefined;
    \\        luSolve(&a, &b, &dx, &solved, scale);
    \\        var settled = true;
    \\        worst_dx = 0.0;
    \\        for (0..n_u) |i| {
    \\            if (!solved[i]) continue;
    \\            const tol = u_abstol[i] + solve_reltol * @abs(x[i]);
    \\            if (@abs(dx[i]) > tol and @abs(dx[i]) > worst_dx) {
    \\                settled = false;
    \\                worst_dx = @abs(dx[i]);
    \\                worst = i;
    \\            }
    \\        }
    \\        for (0..n_u) |i| x[i] += dx[i];
    \\        const can_converge = if (@hasDecl(D, "checkConvergence")) D.checkConvergence(model, inst, x.*) else true;
    \\        if (settled and can_converge) return true;
    \\    }
    \\    // A testbench that does not converge must FAIL, loudly and by exit
    \\    // status, naming the unknown that would not settle. Falling through and
    \\    // letting the model assert against a half-iterated x would report a
    \\    // conformance verdict on arithmetic nobody solved.
    \\    std.debug.print(
    \\        "{s}: did not converge after {d} Newton iterations: x[{s}] still moving {e:.6} per step, tolerance {e:.6}\n",
    \\        .{ title, solve_max_iter, u_names[worst], worst_dx, u_abstol[worst] + solve_reltol * @abs(x[worst]) },
    \\    );
    \\    std.process.exit(1);
    \\}
    \\
    \\/// Dense LU with partial pivoting, rank-revealing exactly as far as `solve`
    \\/// needs: `solved[k]` is false for a column with no usable pivot, and
    \\/// `dx[k]` is then 0. Row `k` of the echelon form lives at `perm[…]`, so
    \\/// nothing is physically moved.
    \\fn luSolve(
    \\    a: *[n_u][n_u]f64,
    \\    b: *[n_u]f64,
    \\    dx: *[n_u]f64,
    \\    solved: *[n_u]bool,
    \\    scale: f64,
    \\) void {
    \\    // "Usable" is relative to the largest entry in the whole system: a
    \\    // structurally absent coupling and one that cancelled to rounding are
    \\    // both absence of information, and treating the second as a pivot is
    \\    // how a solver invents a 1e17 node voltage.
    \\    const eps = 1e-14 * scale;
    \\    var pivot: [n_u]usize = @splat(0);
    \\    var perm: [n_u]usize = undefined;
    \\    for (0..n_u) |i| perm[i] = i;
    \\    var rows: usize = 0; // rows consumed by a pivot so far
    \\    for (0..n_u) |k| {
    \\        var best = rows;
    \\        var best_v: f64 = -1.0;
    \\        for (rows..n_u) |i| {
    \\            const v = @abs(a[perm[i]][k]);
    \\            if (v > best_v) {
    \\                best_v = v;
    \\                best = i;
    \\            }
    \\        }
    \\        if (best_v <= eps) {
    \\            solved[k] = false;
    \\            continue;
    \\        }
    \\        std.mem.swap(usize, &perm[rows], &perm[best]);
    \\        const p = perm[rows];
    \\        pivot[k] = p;
    \\        solved[k] = true;
    \\        for (rows + 1..n_u) |i| {
    \\            const qr = perm[i];
    \\            if (a[qr][k] == 0.0) continue;
    \\            const f = a[qr][k] / a[p][k];
    \\            for (k..n_u) |j| a[qr][j] -= f * a[p][j];
    \\            b[qr] -= f * b[p];
    \\        }
    \\        rows += 1;
    \\    }
    \\    // Back-substitution over the pivoted columns, highest first. A free
    \\    // column contributes nothing to any row above it, because its dx is 0.
    \\    var k = n_u;
    \\    while (k > 0) {
    \\        k -= 1;
    \\        if (!solved[k]) {
    \\            dx[k] = 0.0;
    \\            continue;
    \\        }
    \\        const p = pivot[k];
    \\        var s = b[p];
    \\        for (k + 1..n_u) |j| s -= a[p][j] * dx[j];
    \\        dx[k] = s / a[p][k];
    \\    }
    \\}
    \\
    \\
;

// ---------------------------------------------------------------------------
// Building the executable
// ---------------------------------------------------------------------------

pub const BuildOptions = struct {
    /// Scratch: `device.zig` and `tb.zig` are written here, and the binary
    /// lands here too unless `out_path` says otherwise.
    work_dir: []const u8,
    /// Root of the `contract` module the generated device imports.
    contract: []const u8,
    /// Artifact name — the module name, so the binary is `./<module>`.
    name: []const u8,
    out_path: ?[]const u8 = null,
    zig_exe: []const u8 = "zig",
    /// `-O` for the testbench. Debug by default; see `buildExe` for why that is
    /// not the timid choice.
    optimize: std.builtin.OptimizeMode = .Debug,
};

pub const BuildResult = union(enum) {
    /// Path of the built binary (borrowed from the caller's allocator).
    ok: []const u8,
    /// `zig`'s stderr, verbatim. Generated code that does not compile is an
    /// ENGINE bug, and the only useful report is what the compiler said.
    failed: []const u8,

    pub fn deinit(self: BuildResult, gpa: Allocator) void {
        switch (self) {
            .ok, .failed => |p| gpa.free(p),
        }
    }
};

/// device.zig + runner.zig → one native binary.
///
/// `build-exe` directly rather than through orchestrator.zig: that path exists
/// to produce a hot-reloadable `.so` with a generation counter and an incremental
/// resident compiler, and none of that applies to a testbench that is built once
/// and run once.
///
/// `opts.optimize` defaults to Debug, and NOT because floats would move: Zig has
/// no `-ffast-math`, so float arithmetic is strict IEEE in every optimize mode
/// unless the code itself asks for `@setFloatMode(.optimized)`, which generated
/// devices do not. The two real reasons are that a testbench runs for
/// microseconds and compiles for seconds — so compile time is the whole cost —
/// and that Debug keeps the safety checks on, which turns a codegen bug into a
/// loud trap instead of a plausible wrong number.
pub fn buildExe(
    gpa: Allocator,
    io: Io,
    device_zig: []const u8,
    runner_zig: []const u8,
    opts: BuildOptions,
) !BuildResult {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, opts.work_dir);
    var dir = try cwd.openDir(io, opts.work_dir, .{});
    defer dir.close(io);

    // One arena for the command line. Every element of it is a `-M`, a `-O` or
    // a path join whose lifetime is this call, so a matching `defer free` per
    // string buys nothing over freeing the lot at once.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bin = if (opts.out_path) |p|
        try gpa.dupe(u8, p)
    else
        try std.fs.path.join(gpa, &.{ opts.work_dir, opts.name });
    errdefer gpa.free(bin);

    const m_root = try bind(arena, io, dir, opts, "tb", "root", runner_zig);
    const m_dev = try bind(arena, io, dir, opts, "device", "device", device_zig);

    // `--dep` binds to the NEXT `-M`, and the FIRST `-M` is the root module.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        opts.zig_exe,
        "build-exe",
        try std.fmt.allocPrint(arena, "-femit-bin={s}", .{bin}),
        try std.fmt.allocPrint(arena, "-O{t}", .{opts.optimize}),
        "--cache-dir",
        ".zig-cache",
    });
    try argv.appendSlice(arena, &.{ "--dep", "device" });
    try argv.appendSlice(arena, &.{ "--dep", "contract", m_root });
    try argv.appendSlice(arena, &.{ "--dep", "contract", m_dev });
    try argv.append(arena, try std.fmt.allocPrint(arena, "-Mcontract={s}", .{opts.contract}));

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });

    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var aw: Io.Writer.Allocating = .fromArrayList(gpa, &text);
    _ = reader.interface.streamRemaining(&aw.writer) catch {};
    text = aw.toArrayList();

    const term = try child.wait(io);
    const failed = switch (term) {
        .exited => |c| c != 0,
        else => true,
    };
    if (failed) {
        gpa.free(bin);
        return .{ .failed = try text.toOwnedSlice(gpa) };
    }
    text.deinit(gpa);
    return .{ .ok = bin };
}

/// Write one module's source into the work directory and return the `-M` that
/// binds it. The file is `<name>.<suffix>.zig` so two hosts sharing a work root
/// cannot overwrite each other's device.
fn bind(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    opts: BuildOptions,
    suffix: []const u8,
    binding: []const u8,
    text: []const u8,
) ![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.{s}.zig", .{ opts.name, suffix });
    try dir.writeFile(io, .{ .sub_path = file, .data = text });
    const path = try std.fs.path.join(arena, &.{ opts.work_dir, file });
    return std.fmt.allocPrint(arena, "-M{s}={s}", .{ binding, path });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "directives: defaults when the source has none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "module m; endmodule\n");
    try testing.expectEqual(@as(usize, 0), d.sweeps.len);
    try testing.expectEqual(@as(usize, 0), d.params.len);
    try testing.expectEqual(@as(f64, 300.15), d.temp);
    try testing.expectEqual(Analysis.dc, d.analysis);
    try testing.expect(d.print_residual);
    try testing.expect(!d.solve_free);
}

test "§5.6 `//! solve` unties the unknowns nothing else names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The DEFAULT netlist: every unknown tied to the reference. 100 fixtures
    // read a rule off `//! bias V(p) = …` on a two-terminal device, and mean the
    // potential ACROSS it — which is only true because the far terminal is
    // grounded and not left open.
    const tied = try renderRunner(arena, "065_tied", try parse(arena, "//! bias V(p) = 0.5\n"));
    try testing.expect(std.mem.indexOf(u8, tied, "var forced: [n_u]?f64 = @splat(0.0);") != null);
    try testing.expect(std.mem.indexOf(u8, tied, "set(&x, &forced, \"p\", 0.5);") != null);

    // With the line, only what a directive names stays pinned — so `bias` and
    // `solve` compose, and a fixture can ground one terminal and solve another.
    const d = try parse(arena, "//! bias V(ctrl) = 1.5\n//! solve\n");
    try testing.expect(d.solve_free);
    const free = try renderRunner(arena, "066_free", d);
    try testing.expect(std.mem.indexOf(u8, free, "var forced: [n_u]?f64 = @splat(null);") != null);
    try testing.expect(std.mem.indexOf(u8, free, "set(&x, &forced, \"ctrl\", 1.5);") != null);
    // And the solve runs BEFORE the model prints: §5.6 semantics are defined at
    // a solution, so a `$strobe` must not see a half-iterated x.
    const solve_at = std.mem.indexOf(u8, free, "solve(&x, &forced").?;
    try testing.expect(solve_at < std.mem.indexOf(u8, free, "point(0, &x").?);

    // It takes no operand: `//! solve V(p)` would suggest a per-unknown list
    // that `bias` already covers from the other side.
    try testing.expectError(error.BadSyntax, parse(arena, "//! solve V(p)\n"));
}

test "directives: every form, including the §2.6 suffixes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        \\//! param is = 1e-14, n = 1.05
        \\//! bias V(c) = 0
        \\//! sweep V(a) = 0, 0.3, 0.6
        \\//! temp 350
        \\//! time 0, 1n
        \\//! analysis tran
        \\//! print none
        \\module m(a, c); endmodule
    );
    try testing.expectEqual(@as(usize, 2), d.params.len);
    try testing.expectEqualStrings("is", d.params[0].name);
    try testing.expectEqual(@as(f64, 1e-14), d.params[0].value);
    try testing.expectEqualStrings("c", d.bias[0].name);
    try testing.expectEqualStrings("a", d.sweeps[0].name);
    try testing.expectEqual(@as(usize, 3), d.sweeps[0].values.len);
    try testing.expectEqual(@as(f64, 0.6), d.sweeps[0].values[2]);
    try testing.expectEqual(@as(f64, 350), d.temp);
    try testing.expectEqual(@as(f64, 1e-9), d.times[1]);
    try testing.expectEqual(Analysis.tran, d.analysis);
    try testing.expect(!d.print_residual);
}

test "§5.4.2 `I(...)` names the flow unknown, not the node potential" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        \\//! bias V(a) = 1.0
        \\//! bias I(b) = 0.125
        \\//! sweep I(<c>) = 0, 1
        \\//! sweep I(a,b) = 0.25
        \\//! bias V(d[1]) = 2.0
        \\module m(a, b, c); endmodule
    );
    // `V(a)` is the node; the two `I` forms are the unknowns lower.zig's
    // `flowUnknown`/`portFlowUnknown` intern, sanitized as codegen spells them.
    try testing.expectEqualStrings("a", d.bias[0].name);
    try testing.expectEqualStrings("flowZ28bZ2cgndZ29", d.bias[1].name);
    try testing.expectEqualStrings("flowZ28Z3ccZ3eZ29", d.sweeps[0].name);
    // The other two spellings a fixture has to be able to write down: §5.4.2's
    // two-terminal branch, which is the ONLY unknown with no source spelling at
    // all, and a §6.5.2 vector element, whose name is `vecElem`'s `b[i]` and
    // never an invented `b__i`. Both must land on the member `emitTopology`
    // prints — see codegen.zig's "the `U` block is the SPELLING contract" test,
    // which pins the other end of the same two strings.
    try testing.expectEqualStrings("flowZ28aZ2cbZ29", d.sweeps[1].name);
    try testing.expectEqualStrings("dZ5b1Z5d", d.bias[2].name);
    // Wave 10 pinned this as `error.BadSyntax` — `bias`/`param` split on commas
    // before anything else, so the comma inside `I(a,b)` cut the binding in half
    // and the one unknown with no source spelling was unwritable on two of the
    // three directives that take one. Wave 11 decided it rather than documenting
    // it: `parseBindings` splits on TOP-LEVEL commas, so the same access
    // function means the same thing on every directive.
    const d2 = try parse(arena_state.allocator(), "//! bias I(a,b) = 0.25, V(z) = 3\n");
    try testing.expectEqualStrings("flowZ28aZ2cbZ29", d2.bias[0].name);
    try testing.expectEqual(@as(f64, 0.25), d2.bias[0].value);
    try testing.expectEqualStrings("z", d2.bias[1].name);
    // A binding with no `=` is still an error, and the top-level split must not
    // have swallowed that check with the comma.
    try testing.expectError(error.BadSyntax, parse(arena_state.allocator(), "//! bias I(a,b)\n"));
}

test "directives: a typo is an error, not a silently skipped test" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.UnknownDirective, parse(arena_state.allocator(), "//! sweeep V(a) = 1\n"));
    try testing.expectError(error.BadSyntax, parse(arena_state.allocator(), "//! sweep V(a)\n"));
    try testing.expectError(error.BadNumber, parse(arena_state.allocator(), "//! temp warm\n"));
}

test "directives: an lrm cite is a section, and an xfail points either way" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena, "//! lrm 4.5.11\n//! lrm A.8.3\n//! reject E0130\n//! xfail VerA accepts it\n");
    try testing.expectEqual(@as(usize, 2), d.lrm.len);
    try testing.expectEqualStrings("4.5.11", d.lrm[0]);
    try testing.expectEqualStrings("A.8.3", d.lrm[1]);
    try testing.expectEqualStrings("VerA accepts it", d.xfail.?);

    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm §5.8\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm 5.\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm Z.1\n"));
    try testing.expectError(error.BadLrmSection, parse(arena, "//! lrm\n"));

    // On a RUN fixture too: "the LRM prints this example and VerA cannot build
    // it yet" is the more common gap, and it has to be sayable.
    const run = try parse(arena, "//! xfail no array formals in analog functions\n");
    try testing.expectEqual(@as(usize, 0), run.reject.len);
    try testing.expectEqualStrings("no array formals in analog functions", run.xfail.?);
    // A reason is still required — a bare marker names no gap.
    try testing.expectError(error.BadSyntax, parse(arena, "//! xfail\n"));
}

test "§2.6 a scale factor is an exponent, not a multiplier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The claim is BIT equality with the same spelling written in the model,
    // which is what `Lexer.scaleExp` produces. `200 * 1e-6` rounds twice and is
    // a different double from `200e-6`; a directive that used the first spelled
    // a time no `$abstime < 200u` in a model could ever reach.
    const d = try parse(arena, "//! time 0, 200u, 1n, 2.5m, 1K\n");
    try testing.expectEqual(@as(f64, 0.0), d.times[0]);
    try testing.expectEqual(@as(f64, 200e-6), d.times[1]);
    try testing.expectEqual(@as(f64, 1e-9), d.times[2]);
    try testing.expectEqual(@as(f64, 2.5e-3), d.times[3]);
    try testing.expectEqual(@as(f64, 1e3), d.times[4]);
    // The one that actually regressed: not merely close, EQUAL. The old
    // spelling has to be built at RUNTIME to reproduce it — Zig's comptime
    // float arithmetic is arbitrary-precision, so `200.0 * 1e-6` written as a
    // literal is already the correctly rounded answer and would prove nothing.
    var two_hundred: f64 = 200;
    _ = &two_hundred;
    const multiplied = two_hundred * 1e-6;
    try testing.expect(d.times[1] == 200e-6);
    try testing.expect(multiplied != 200e-6);
    try testing.expect(d.times[1] != multiplied);

    // A bare suffix is not a number, and neither is a suffix on nothing.
    try testing.expectError(error.BadNumber, parse(arena, "//! temp u\n"));
    // A plain float still goes straight through.
    const plain = try parse(arena, "//! temp 300.15\n");
    try testing.expectEqual(@as(f64, 300.15), plain.temp);
}

test "§5.4.2 a branch potential is not a solver unknown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `V(a)` names the net `a`; `V(a,c)` names a POTENTIAL DIFFERENCE, which is
    // derived from two unknowns and is not one. Diagnosed at parse time rather
    // than sanitized into an identifier: `a, c` used to become `aZ2cZ20c` and
    // surface as a testbench that would not build, which the runner reports as
    // an engine bug rather than as the fixture's typo it is.
    try testing.expectError(error.BadUnknownName, parse(arena, "//! bias V(a,c) = 0.6\n"));
    try testing.expectError(error.BadUnknownName, parse(arena, "//! bias V(a, c) = 0.6\n"));
    try testing.expectError(error.BadUnknownName, parse(arena, "//! sweep V(a,c) = 0, 1\n"));

    // A branch FLOW is an unknown and keeps working — §5.4.2 gives it a row.
    // Its name is sanitized because `flow(a,c)` is not a Zig identifier and the
    // `U` member codegen emits for it is not either; the two go through the
    // same `naming.sanitize`, which is what makes the directive and the emitted
    // enum agree on one spelling.
    const flow = try parse(arena, "//! bias I(a,c) = 0.25\n");
    try testing.expectEqualStrings("flowZ28aZ2ccZ29", flow.bias[0].name);

    // Whitespace inside the access function is not part of the name.
    const spaced = try parse(arena, "//! bias V( a ) = 0.5\n");
    try testing.expectEqualStrings("a", spaced.bias[0].name);
}

test "§4.6.4 `//! noise` states the exported generator table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena, "//! noise thermal(a,b)#0\n//! noise flicker(d,s)#null\n");
    try testing.expect(d.asserts_noise);
    try testing.expectEqual(@as(usize, 2), d.noise.len);
    try testing.expectEqualStrings("thermal(a,b)#0", d.noise[0].topo);
    try testing.expectEqualStrings("flicker(d,s)#null", d.noise[1].topo);
    // A line with no `key=value` tail asserts the topology and NOTHING else,
    // which is what keeps every pre-existing `//! noise` line meaning what it
    // meant: an absent field is not an assertion that the field is empty.
    try testing.expect(d.noise[0].name == null);
    try testing.expect(d.noise[0].white == null);
    try testing.expect(!d.noise[0].needsPoint());

    // `none` is a CLAIM that the table is empty. It has to be distinguishable
    // from an absent directive, or a fixture could not say "this model declares
    // no generator" — which is the assertion that catches a source leaking into
    // a device that should have none.
    const none = try parse(arena, "//! noise none\n");
    try testing.expect(none.asserts_noise);
    try testing.expectEqual(@as(usize, 0), none.noise.len);

    const silent = try parse(arena, "//! analysis dc\n");
    try testing.expect(!silent.asserts_noise);

    // A misspelled KIND can never match, and its failure would say nothing
    // about the model, so it is caught here instead.
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise pink(a,b)#0\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal a,b\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a)#0\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(,b)#0\n"));
    // The §4.6.4.6 source id is mandatory (a digit string or `null`): a line
    // without one asserts nothing about correlation, which is half of what the
    // directive exists to pin.
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a,b)\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a,b)#\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a,b)#x\n"));
    // A node name is NOT checked: nothing here has been told what unknowns the
    // module has, and a wrong one is the assertion working rather than a typo.
    const odd = try parse(arena, "//! noise shot(nosuchnode,b)#3\n");
    try testing.expectEqual(@as(usize, 1), odd.noise.len);
}

test "§4.6.4 a `//! noise` line states the row's contents as well as its place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena,
        \\//! noise thermal(p,n)#0 name=thermal white=4e-18
        \\//! noise flicker(p,n)#1 name=flicker flicker=1e-20 ef=1.25 rtol=1e-4
        \\//! noise table(p,n)#2 name=tbl interp=log points=1.0:1e-18,1e3:1e-21
        \\
    );
    try testing.expectEqual(@as(usize, 3), d.noise.len);

    // The topology is what it always was — the fields are a TAIL, so the same
    // string still reaches `noise_gens`'s compare.
    try testing.expectEqualStrings("thermal(p,n)#0", d.noise[0].topo);
    try testing.expectEqualStrings("thermal", d.noise[0].name.?);
    try testing.expectEqual(@as(f64, 4e-18), d.noise[0].white.?);
    try testing.expectEqual(@as(f64, 1e-12), d.noise[0].rtol); // the default
    try testing.expect(d.noise[0].needsPoint());

    try testing.expectEqual(@as(f64, 1e-20), d.noise[1].flicker.?);
    try testing.expectEqual(@as(f64, 1.25), d.noise[1].ef.?);
    try testing.expectEqual(@as(f64, 1e-4), d.noise[1].rtol);

    // `interp`/`points` are comptime table data, so the table row asserts
    // nothing that needs a bias.
    try testing.expectEqualStrings("log", d.noise[2].interp.?);
    try testing.expectEqualSlices([2]f64, &.{ .{ 1.0, 1e-18 }, .{ 1e3, 1e-21 } }, d.noise[2].points.?);
    try testing.expect(!d.noise[2].needsPoint());

    // A branch written with a space inside the parentheses still parses: the
    // topology ends at the first space AFTER the `#`, not at the first space.
    const spaced = try parse(arena, "//! noise thermal(p, n)#0 name=x\n");
    try testing.expectEqualStrings("thermal(p, n)#0", spaced.noise[0].topo);

    // An unknown key is a fixture asserting something the runner will silently
    // not check, which is the one failure mode this directive cannot afford.
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a,b)#0 whte=1\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise thermal(a,b)#0 name\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise table(a,b)#0 interp=spline\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! noise table(a,b)#0 points=1.0\n"));
}

test "§4.6.3 `//! acstim` states the exported stimulus table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try parse(arena,
        \\//! acstim (p,n) name=ac mag=2.0 phase=1.0471975511965976
        \\//! acstim (q, n) mag=1.0 phase=1.5707963267948966 rtol=1e-6
        \\
    );
    try testing.expect(d.asserts_acstim);
    try testing.expectEqual(@as(usize, 2), d.acstim.len);
    try testing.expectEqualStrings("(p,n)", d.acstim[0].topo);
    try testing.expectEqualStrings("ac", d.acstim[0].name.?);
    try testing.expectEqual(@as(f64, 2.0), d.acstim[0].mag.?);
    try testing.expectEqual(@as(f64, 1e-12), d.acstim[0].rtol); // the default
    try testing.expectEqual(@as(f64, 1e-6), d.acstim[1].rtol);
    try testing.expect(d.acstim[0].needsPoint());

    // Canonicalised, so the space a human writes is not a different want than
    // the one the device spells.
    try testing.expectEqualStrings("(q,n)", d.acstim[1].topo);
    // `name=` is OPTIONAL — an absent one asserts nothing, because §4.6.3
    // defaults `analysis_name` to "ac" and a fixture may not care.
    try testing.expect(d.acstim[1].name == null);

    // "This model declares no stimulus" is a claim and silence is not.
    const none = try parse(arena, "//! acstim none\n");
    try testing.expect(none.asserts_acstim);
    try testing.expectEqual(@as(usize, 0), none.acstim.len);

    // An unknown key is a fixture asserting something nothing will check.
    try testing.expectError(error.BadSyntax, parse(arena, "//! acstim (a,b) magnitude=1\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! acstim (a,b) mag\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! acstim a,b mag=1\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! acstim (a) mag=1\n"));
    try testing.expectError(error.BadSyntax, parse(arena, "//! acstim (,b) mag=1\n"));
}

test "expected process exit status is explicit and bounded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(0, (try parse(arena, "")).expected_exit);
    try testing.expectEqual(1, (try parse(arena, "//! exit 1\n")).expected_exit);
    try testing.expectEqual(255, (try parse(arena, "//! exit 255\n")).expected_exit);
    try testing.expectError(error.BadNumber, parse(arena, "//! exit 256\n"));
    try testing.expectError(error.BadNumber, parse(arena, "//! exit -1\n"));
}

test "sweep expansion is the cartesian product, last fastest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! sweep V(a) = 0, 1
        \\//! sweep V(b) = 10, 20, 30
    );
    const pts = try expand(arena, d);
    try testing.expectEqual(@as(usize, 6), pts.len);
    try testing.expectEqualSlices(f64, &.{ 0, 10 }, pts[0]);
    try testing.expectEqualSlices(f64, &.{ 0, 20 }, pts[1]);
    try testing.expectEqualSlices(f64, &.{ 0, 30 }, pts[2]);
    try testing.expectEqualSlices(f64, &.{ 1, 10 }, pts[3]);
    try testing.expectEqualSlices(f64, &.{ 1, 30 }, pts[5]);
}

test "a wave is per-timepoint and holds its last value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! time 0, 1n, 2n, 3n
        \\//! wave V(in) = 0, 1
        \\//! bias V(out) = 0
    );
    try testing.expectEqual(@as(usize, 4), d.times.len);
    try testing.expectEqualStrings("in", d.waves[0].name);
    try testing.expectEqual(@as(usize, 2), d.waves[0].values.len);

    const src = try renderRunner(arena, "060_wave", d);
    // Four time points, one `x[…] = 1` per point after the first, and exactly
    // one `step(...)` per point: the state has to advance or the operators
    // answer from zero history every time.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, src, "        point("));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, src, "        stepPost(&model"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "= newState("));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, src, "set(&x, &forced, \"in\", 1);"));
}

test "each sweep point starts its transient from a fresh State" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! sweep V(a) = 0, 1, 2
        \\//! time 0, 1n
    );
    const src = try renderRunner(arena, "061_reset", d);
    // Three sweep points × two times, and a `newState` per sweep point — not
    // per time, and not once for the whole run.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "        point("));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, src, "= newState("));
    // Point numbers are global, so no two transcript blocks share a label.
    try testing.expect(std.mem.indexOf(u8, src, "point(5, &x") != null);
}

test "§5.10.2 global events mark the first and last point of each analysis" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A dc sweep is ONE analysis: first step only, last step only.
    const swept = try renderRunner(arena, "062_sweep", try parse(arena, "//! sweep V(a) = 0, 1, 2\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, swept, "inst.is_initial_step = true;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, swept, "inst.is_final_step = true;"));
    try testing.expect(std.mem.indexOf(u8, swept, "inst.is_initial_step = true;\n        inst.is_final_step = false;\n        inst.is_analog_initial = true;\n        const solved0 = solve(&x, &forced, &model, &inst);\n        point(0,") != null);
    try testing.expect(std.mem.indexOf(u8, swept, "inst.is_initial_step = false;\n        inst.is_final_step = true;\n        inst.is_analog_initial = true;\n        const solved2 = solve(&x, &forced, &model, &inst);\n        point(2,") != null);
    // §5.2.1 the `analog initial` flag is NOT `is_initial_step`: a dc sweep is one
    // analysis with three SUB-TASKS, so the block re-executes at all three points
    // while the global event fires at one.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, swept, "inst.is_analog_initial = true;"));

    // With `//! time` each sweep block is its own transient run, so each gets
    // its own first and last timepoint.
    const tran = try renderRunner(arena, "063_tran", try parse(arena, "//! sweep V(a) = 0, 1\n//! time 0, 1n, 2n\n"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "inst.is_initial_step = true;"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "inst.is_final_step = true;"));
    // Two blocks, so two sub-tasks: one analog-initial pass each, at dt = 0.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "inst.is_analog_initial = true;"));

    // The single-point default is the Table 5-1 DCOP column: both events fire.
    const op = try renderRunner(arena, "064_op", .{});
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, op, "inst.is_initial_step = true;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, op, "inst.is_final_step = true;"));
}

test "renderRunner emits parseable Zig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! param g = 2m
        \\//! sweep V(p) = 0, 1
        \\//! bias V(n) = 0
    );
    const src = try renderRunner(arena, "001_demo", d);
    const z = try arena.dupeZ(u8, src);
    var ast = try std.zig.Ast.parse(testing.allocator, z, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
    // The sweep really did become two straight-line blocks.
    try testing.expect(std.mem.indexOf(u8, src, "point(0, &x") != null);
    try testing.expect(std.mem.indexOf(u8, src, "point(1, &x") != null);
    // §3.4.1/§4.2.1.1: the card's value goes through `cardValue`, which is what
    // converts it when `g` turns out to be an `integer` parameter.
    try testing.expect(std.mem.indexOf(u8, src, "model.g = cardValue(@TypeOf(model.g), 0.002)") != null);
}
