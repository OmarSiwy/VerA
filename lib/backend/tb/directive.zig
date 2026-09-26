//! Directive parsing: a fixture's `//!` header (analysis, bias, time, sweep, noise, ...).
//!
//! In: the fixture source. Out: the testbench plan (analyses, stimuli, expected rows).
//!
//! LRM clauses this file's code cites: §1.3.1.1, §2.4, §2.6, §3.6.3, §4.6.3, §4.6.4.3, §4.6.4.4, §4.6.4.6, §5.4.2, §5.4.3, §6.5.2.
//!
//! Cut verbatim from `tb.zig`.

const std = @import("std");
const tb = @import("../tb.zig");
const naming = @import("../naming.zig");
const Lexer = @import("frontend").Lexer;
const Allocator = tb.Allocator;
const marker = tb.marker;
const Error = tb.Error;
const Binding = tb.Binding;
const Sweep = tb.Sweep;
const Analysis = tb.Analysis;
const Directives = tb.Directives;
const NoiseWant = tb.NoiseWant;
const AcWant = tb.AcWant;

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
    var plusargs: std.ArrayList([]const u8) = .empty;
    var lrm: std.ArrayList([]const u8) = .empty;
    var spice: std.ArrayList([]const u8) = .empty;
    var noise: std.ArrayList(NoiseWant) = .empty;
    var qsites: std.ArrayList([]const u8) = .empty;
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
        } else if (std.mem.eql(u8, kw, "checks")) {
            if (d.expected_checks != null) return error.BadSyntax;
            if (!digits(rest)) return error.BadNumber;
            const count = std.fmt.parseInt(usize, rest, 10) catch return error.BadNumber;
            if (count == 0) return error.BadNumber;
            d.expected_checks = count;
        } else if (std.mem.eql(u8, kw, "plusargs")) {
            if (rest.len == 0) return error.BadSyntax;
            var args = std.mem.tokenizeAny(u8, rest, " \t");
            while (args.next()) |arg| {
                if (arg.len < 2 or arg[0] != '+') return error.BadSyntax;
                for (arg) |c| {
                    if (c < 0x21 or c > 0x7e or c == '\'' or c == '"' or c == '\\')
                        return error.BadSyntax;
                }
                try plusargs.append(arena, try arena.dupe(u8, arg));
            }
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
        } else if (std.mem.eql(u8, kw, "qsite")) {
            // §5.6.1.2 one expected charge site, in slot order, in the form
            // the runner prints (`tb.Directives.qsites`). `none`: no site.
            if (rest.len == 0) return error.BadSyntax;
            if (!std.mem.eql(u8, rest, "none")) try qsites.append(arena, try arena.dupe(u8, rest));
            d.asserts_qsite = true;
        } else if (std.mem.eql(u8, kw, "spice")) {
            // Verbatim, including a leading `+`: the reader joins continuations
            // itself, so what it sees is the card as the annex prints it.
            if (rest.len == 0) return error.BadSyntax;
            try spice.append(arena, try arena.dupe(u8, rest));
        } else if (std.mem.eql(u8, kw, "lrm")) {
            if (!validSection(rest)) return error.BadLrmSection;
            try lrm.append(arena, try arena.dupe(u8, rest));
        } else if (std.mem.eql(u8, kw, "inherited")) {
            // `IEEE 1364-2005 18.1 (...)` — a clause §1.1 inherits whole, in
            // the spelling the digital fixtures already use. NOT an `lrm`
            // cite: `--coverage` counts clauses of THIS LRM, and 1364's are
            // not (`harness.zig`'s `clausePrefix`). Checked, then dropped;
            // measure B is hand-read, so nothing consumes it yet.
            if (!validInherited(rest)) return error.BadLrmSection;
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
    d.plusargs = plusargs.items;
    if (d.expected_checks != null and d.reject.len != 0) return error.BadSyntax;
    d.lrm = lrm.items;
    d.noise = noise.items;
    d.qsites = qsites.items;
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
pub fn validSection(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    const first = it.first();
    const annex = first.len == 1 and first[0] >= 'A' and first[0] <= 'H';
    if (!annex and !digits(first)) return false;
    while (it.next()) |part| if (!digits(part)) return false;
    return true;
}

/// Is this an `//! inherited` cite — `IEEE 1364-2005 17.2.9`, optionally
/// followed by more clauses or a parenthesised note? Only the first clause is
/// checked, with `validSection`'s own looseness.
fn validInherited(s: []const u8) bool {
    const std_name = "IEEE 1364-2005 ";
    if (!std.mem.startsWith(u8, s, std_name)) return false;
    const rest = s[std_name.len..];
    return validSection(rest[0 .. std.mem.indexOfAny(u8, rest, " ,") orelse rest.len]);
}

pub fn digits(s: []const u8) bool {
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
pub fn unknownName(arena: Allocator, raw: []const u8) Error![]const u8 {
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
pub fn parseBindings(arena: Allocator, rest: []const u8, out: *std.ArrayList(Binding)) Error!void {
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
pub fn number(raw: []const u8) Error!f64 {
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
