//! Fixture `//!` directive parsing: raw .va source in, `tb.Directives` out
//! (analysis, bias, time, sweeps, expected noise/acstim/qsite tables, ...).
//! LRM: §1.3.1.1, §2.4, §2.6, §3.6.3, §4.6.3, §4.6.4.3, §4.6.4.4, §4.6.4.6,
//! §5.4.2, §5.4.3, §6.5.2.

const std = @import("std");
const tb = @import("../tb.zig");
const naming = @import("../naming.zig");
const Lexer = @import("frontend").Lexer;
const Allocator = std.mem.Allocator;
const Error = tb.Error;
const Binding = tb.Binding;
const Sweep = tb.Sweep;
const Analysis = tb.Analysis;
const Directives = tb.Directives;
const NoiseWant = tb.NoiseWant;
const AcWant = tb.AcWant;
const AcDynWant = tb.AcDynWant;

/// The directive line prefix. A plain `//` comment is never a directive.
const marker = "//!";

/// Every keyword a `//!` line may open with, spelled as written. Any other
/// word is `error.UnknownDirective`, so a typo cannot silently check nothing.
const Keyword = enum {
    param,
    bias,
    sweep,
    wave,
    psweep,
    temp,
    time,
    solve,
    analysis,
    exit,
    checks,
    plusargs,
    reject,
    @"reject-only",
    neighbour,
    warn,
    nowarn,
    noise,
    acstim,
    acdyn,
    qsite,
    seed,
    abstol,
    limit,
    spice,
    lrm,
    inherited,
    xfail,
    print,
    tran,
    onoise,
    @"discipline-resolution",
    display,
    @"fd-exempt",
};

/// Parses the `//!` lines of RAW source, before the preprocessor deletes
/// comments (§2.4). Other lines are ignored, so any .va is valid input.
/// Every slice in the result is allocated in `arena`. Fails on the first
/// malformed line, with the `tb.Error` that names what was wrong.
pub fn parse(arena: Allocator, source: []const u8) Error!Directives {
    var d: Directives = .{};
    var analysis: ?Analysis = null;
    var params: std.ArrayList(Binding) = .empty;
    var bias: std.ArrayList(Binding) = .empty;
    var sweeps: std.ArrayList(Sweep) = .empty;
    var waves: std.ArrayList(Sweep) = .empty;
    var psweeps: std.ArrayList(Sweep) = .empty;
    var reject: std.ArrayList([]const u8) = .empty;
    var neighbours: std.ArrayList([]const u8) = .empty;
    var warn: std.ArrayList([]const u8) = .empty;
    var plusargs: std.ArrayList([]const u8) = .empty;
    var lrm: std.ArrayList([]const u8) = .empty;
    var spice: std.ArrayList([]const u8) = .empty;
    var noise: std.ArrayList(NoiseWant) = .empty;
    var qsites: std.ArrayList([]const u8) = .empty;
    var acstim: std.ArrayList(AcWant) = .empty;
    var acdyn: std.ArrayList(AcDynWant) = .empty;
    var seeds: std.ArrayList(Binding) = .empty;
    var abstols: std.ArrayList(Binding) = .empty;
    var limits: std.ArrayList(tb.LimitCase) = .empty;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, marker)) continue;
        const body = std.mem.trim(u8, line[marker.len..], " \t");
        if (body.len == 0) continue;

        const kw_end = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
        const kw = std.meta.stringToEnum(Keyword, body[0..kw_end]) orelse return error.UnknownDirective;
        const rest = std.mem.trim(u8, body[kw_end..], " \t");

        switch (kw) {
            .param => try parseBindings(arena, rest, &params),
            .bias => try parseBindings(arena, rest, &bias),
            .sweep, .wave, .psweep => {
                const at = std.mem.indexOfScalar(u8, rest, '=') orelse return error.BadSyntax;
                // A parameter has no access-function spelling, so `psweep` takes the
                // name as written; `unknownName` would only strip a `V(...)` that
                // cannot be there.
                const raw_name = std.mem.trim(u8, rest[0..at], " \t");
                const name = if (kw == .psweep) raw_name else try unknownName(arena, raw_name);
                if (name.len == 0) return error.BadSyntax;
                const entry: Sweep = .{
                    .name = try arena.dupe(u8, name),
                    .values = try parseNumbers(arena, rest[at + 1 ..]),
                };
                try (if (kw == .sweep) &sweeps else if (kw == .psweep) &psweeps else &waves)
                    .append(arena, entry);
            },
            .temp => d.temp = try number(rest),
            .time => d.times = try parseNumbers(arena, rest),
            .solve => {
                // A bare flag, and it composes with `bias`: `bias` still pins what
                // it names, `solve` frees only the rest. So a fixture that needs one
                // terminal grounded and another solved writes both lines, and no
                // per-unknown list is needed to say it.
                if (rest.len != 0) return error.BadSyntax;
                d.solve_free = true;
            },
            // `//! analysis <kind> [<name>]`: the name is §9.15's
            // `analysis_name`, the kind's own spelling when omitted.
            .analysis => {
                const kind_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                analysis = std.meta.stringToEnum(Analysis, rest[0..kind_end]) orelse return error.BadSyntax;
                const name = std.mem.trim(u8, rest[kind_end..], " \t");
                if (std.mem.indexOfAny(u8, name, " \t\"\\") != null) return error.BadSyntax;
                if (name.len != 0) d.analysis_name = try arena.dupe(u8, name);
            },
            .exit => d.expected_exit = std.fmt.parseInt(u8, rest, 10) catch return error.BadNumber,
            .checks => {
                if (d.expected_checks != null) return error.BadSyntax;
                if (!digits(rest)) return error.BadNumber;
                const count = std.fmt.parseInt(usize, rest, 10) catch return error.BadNumber;
                if (count == 0) return error.BadNumber;
                d.expected_checks = count;
            },
            .plusargs => {
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
            },
            .reject, .@"reject-only" => {
                // The whole rest of the line is ONE substring, verbatim: message
                // fragments contain spaces and commas.
                if (rest.len == 0) return error.BadSyntax;
                try reject.append(arena, try arena.dupe(u8, rest));
                if (kw == .@"reject-only") d.reject_only = true;
            },
            .neighbour => {
                // A path, relative to the fixture's directory; the harness
                // checks that it names a collected positive fixture.
                if (rest.len == 0 or std.mem.indexOfAny(u8, rest, " \t") != null) return error.BadSyntax;
                try neighbours.append(arena, try arena.dupe(u8, rest));
            },
            .warn => {
                // One verbatim substring, as `reject`.
                if (rest.len == 0) return error.BadSyntax;
                try warn.append(arena, try arena.dupe(u8, rest));
            },
            .nowarn => {
                if (rest.len != 0) return error.BadSyntax;
                d.nowarn = true;
            },
            .noise => {
                // `none` is the empty table, spelled rather than left as an absent
                // directive: "this model declares no generator" is a claim, and a
                // missing line is not one.
                if (!std.mem.eql(u8, rest, "none")) {
                    try noise.append(arena, try parseNoiseEntry(arena, rest));
                }
                d.asserts_noise = true;
            },
            .acstim => {
                // `none` is the empty table, for the reason `noise none` is.
                if (!std.mem.eql(u8, rest, "none")) {
                    try acstim.append(arena, try parseAcEntry(arena, rest));
                }
                d.asserts_acstim = true;
            },
            .acdyn => try acdyn.append(arena, try parseAcDynEntry(arena, rest)),
            .qsite => {
                // §5.6.1.2 one expected charge site, in slot order, in the form
                // the runner prints (`tb.Directives.qsites`). `none`: no site.
                if (rest.len == 0) return error.BadSyntax;
                if (!std.mem.eql(u8, rest, "none")) try qsites.append(arena, try arena.dupe(u8, rest));
                d.asserts_qsite = true;
            },
            .seed => {
                if (rest.len == 0) return error.BadSyntax;
                if (!std.mem.eql(u8, rest, "none")) try parseBindings(arena, rest, &seeds);
                d.asserts_seed = true;
            },
            .abstol => {
                if (rest.len == 0) return error.BadSyntax;
                try parseBindings(arena, rest, &abstols);
            },
            .limit => {
                const at = std.mem.indexOf(u8, rest, "->") orelse return error.BadSyntax;
                var old: std.ArrayList(Binding) = .empty;
                var want: std.ArrayList(Binding) = .empty;
                try parseBindings(arena, rest[0..at], &old);
                try parseBindings(arena, rest[at + 2 ..], &want);
                if (want.items.len == 0) return error.BadSyntax;
                try limits.append(arena, .{ .old = old.items, .want = want.items });
            },
            .spice => {
                // Verbatim, including a leading `+`: the reader joins continuations
                // itself, so what it sees is the card as the annex prints it.
                if (rest.len == 0) return error.BadSyntax;
                try spice.append(arena, try arena.dupe(u8, rest));
            },
            .lrm => {
                if (!validSection(rest)) return error.BadLrmSection;
                try lrm.append(arena, try arena.dupe(u8, rest));
            },
            .inherited => {
                // `IEEE 1364-2005 18.1 (...)`: a clause §1.1 inherits whole. Not
                // an `lrm` cite, since `--coverage` counts this LRM's clauses only.
                // Checked here, then dropped: tests/ieee1364.zig reads these lines
                // from raw source for measure B (`zig build test-1364 -- --coverage`).
                if (!validInherited(rest)) return error.BadLrmSection;
            },
            .xfail => {
                // The whole rest of the line is the reason: prose for a human.
                if (rest.len == 0) return error.BadSyntax;
                d.xfail = try arena.dupe(u8, rest);
            },
            .tran => {
                const v = try parseNumbers(arena, rest);
                if (v.len != 2 or !(v[0] > 0) or !(v[1] > 0)) return error.BadSyntax;
                d.tran = .{ v[0], v[1] };
            },
            .onoise => {
                const at = std.mem.indexOfScalar(u8, rest, '=') orelse return error.BadSyntax;
                const name = try unknownName(arena, std.mem.trim(u8, rest[0..at], " \t"));
                if (name.len == 0) return error.BadSyntax;
                d.onoise = .{ .name = try arena.dupe(u8, name), .values = try parseNumbers(arena, rest[at + 1 ..]) };
            },
            // §7.4.4's mode, as `vera --discipline-resolution=` selects it.
            .@"discipline-resolution" => d.discipline_resolution = std.meta.stringToEnum(@TypeOf(d.discipline_resolution), rest) orelse return error.BadSyntax,
            // §9.4 `vera --emit-exe --display=record`: the device's `say`.
            .display => d.display_record = if (std.mem.eql(u8, rest, "record")) true else return error.BadSyntax,
            .@"fd-exempt" => {
                // As `xfail`: the reason is the claim, so it is required.
                if (rest.len == 0) return error.BadSyntax;
                d.fd_exempt = try arena.dupe(u8, rest);
            },
            .print => {
                if (std.mem.eql(u8, rest, "none")) {
                    d.print_residual = false;
                } else if (std.mem.eql(u8, rest, "residual")) {
                    d.print_residual = true;
                } else return error.BadSyntax;
            },
        }
    }

    // §5.10.3.1 a grid that advances time is a transient analysis: run as dc,
    // `cross` would never fire on it.
    d.analysis = analysis orelse if (d.times.len > 1) .tran else .dc;
    d.params = params.items;
    d.bias = bias.items;
    d.sweeps = sweeps.items;
    d.waves = waves.items;
    d.psweeps = psweeps.items;
    d.reject = reject.items;
    d.neighbours = neighbours.items;
    // A legal neighbour is the other half of a refusal; a fixture that is
    // not one has none.
    if (d.neighbours.len != 0 and d.reject.len == 0) return error.BadSyntax;
    d.plusargs = plusargs.items;
    if (d.expected_checks != null and d.reject.len != 0) return error.BadSyntax;
    d.warn = warn.items;
    // A refusal has no successful compile whose warnings could be judged.
    if ((d.warn.len != 0 or d.nowarn) and d.reject.len != 0) return error.BadSyntax;
    if (d.warn.len != 0 and d.nowarn) return error.BadSyntax;
    d.lrm = lrm.items;
    d.noise = noise.items;
    d.qsites = qsites.items;
    d.acstim = acstim.items;
    d.acdyn = acdyn.items;
    d.seeds = seeds.items;
    d.abstols = abstols.items;
    d.limits = limits.items;
    // One text blob, in source order: `spice_cards` wants netlist text, not a
    // list of lines, and joining here keeps the continuation rule in one place.
    if (spice.items.len != 0) d.spice = try std.mem.join(arena, "\n", spice.items);
    return d;
}

/// Returns whether `s` is a `//! lrm` cite: a chapter number or annex letter,
/// then dotted numbers (`5.8`, `A.8.3`, `B`), then optionally `:<n>`, the
/// n-th normative sentence of that clause (`5.6.1.3:2`). Syntax only: a
/// well-formed section the LRM does not have still passes.
pub fn validSection(cite: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, cite, ':');
    if (colon) |c| if (!digits(cite[c + 1 ..]) or std.mem.eql(u8, cite[c + 1 ..], "0")) return false;
    const s = cite[0 .. colon orelse cite.len];
    var it = std.mem.splitScalar(u8, s, '.');
    const first = it.first();
    const annex = first.len == 1 and first[0] >= 'A' and first[0] <= 'H';
    if (!annex and !digits(first)) return false;
    while (it.next()) |part| if (!digits(part)) return false;
    return true;
}

/// Returns whether `s` is an `//! inherited` cite (`IEEE 1364-2005 17.2.9`,
/// optionally more clauses or a note). Only the first clause is checked.
fn validInherited(s: []const u8) bool {
    const std_name = "IEEE 1364-2005 ";
    if (!std.mem.startsWith(u8, s, std_name)) return false;
    const rest = s[std_name.len..];
    return validSection(rest[0 .. std.mem.indexOfAny(u8, rest, " ,") orelse rest.len]);
}

/// Returns whether `s` is a nonempty run of ASCII decimal digits.
fn digits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Returns whether `s` is a `//! noise` topology such as `thermal(p,n)#0`.
/// The kind is checked; node names are not, since directives are parsed before
/// the unknowns exist and a misspelled node fails the assertion anyway.
fn validNoiseEntry(s: []const u8) bool {
    const open = std.mem.indexOfScalar(u8, s, '(') orelse return false;
    // `#<source>` after the branch is §4.6.4.6's correlation id; `#null` is
    // a row with no identity declared.
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

/// Parses one `//! noise` line: the topology, then `key=value` fields.
/// The topology ends at the first space after the `#`, because the branch may
/// contain spaces (`thermal(p, n)#0`).
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

/// Splits a leading `(<row>,<col>)` off `s`: both names trimmed, and the text
/// after the `)`.
fn parsePair(s: []const u8) Error!struct { row: []const u8, col: []const u8, rest: []const u8 } {
    if (s.len == 0 or s[0] != '(') return error.BadSyntax;
    const close = std.mem.indexOfScalar(u8, s, ')') orelse return error.BadSyntax;
    const inner = s[1..close];
    const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return error.BadSyntax;
    const row = std.mem.trim(u8, inner[0..comma], " \t");
    const col = std.mem.trim(u8, inner[comma + 1 ..], " \t");
    if (row.len == 0 or col.len == 0) return error.BadSyntax;
    return .{ .row = row, .col = col, .rest = s[close + 1 ..] };
}

/// Parses one `//! acstim` line (§4.6.3): the branch, then `key=value` fields.
/// A stimulus has no kind tag and no `#source`. The branch is canonicalised to
/// `(p,n)`, the device's spelling, so `(p, n)` compares equal.
fn parseAcEntry(arena: Allocator, s: []const u8) Error!AcWant {
    const pr = try parsePair(s);
    var w: AcWant = .{ .topo = try arena.print("({s},{s})", .{ pr.row, pr.col }) };
    var fields = std.mem.tokenizeAny(u8, pr.rest, " \t");
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

/// Parses one `//! acdyn` line (`tb.AcDynWant`): the slot, then `f`, `re` and
/// `im`, all required, and an optional `tol`.
fn parseAcDynEntry(arena: Allocator, s: []const u8) Error!AcDynWant {
    const pr = try parsePair(s);
    var f: ?f64 = null;
    var re: ?f64 = null;
    var im: ?f64 = null;
    var tol: f64 = 1e-12;
    var fields = std.mem.tokenizeAny(u8, pr.rest, " \t");
    while (fields.next()) |fd| {
        const at = std.mem.indexOfScalar(u8, fd, '=') orelse return error.BadSyntax;
        const key = fd[0..at];
        const val = try number(fd[at + 1 ..]);
        if (std.mem.eql(u8, key, "f")) {
            f = val;
        } else if (std.mem.eql(u8, key, "re")) {
            re = val;
        } else if (std.mem.eql(u8, key, "im")) {
            im = val;
        } else if (std.mem.eql(u8, key, "tol")) {
            tol = val;
        } else return error.BadSyntax;
    }
    return .{
        .row = try arena.dupe(u8, pr.row),
        .col = try arena.dupe(u8, pr.col),
        .f = f orelse return error.BadSyntax,
        .re = re orelse return error.BadSyntax,
        .im = im orelse return error.BadSyntax,
        .tol = tol,
    };
}

/// Returns the emitted `U` enum member a directive name refers to.
/// `V(a)`, `x[a]` and `a` all name node `a`. `I(a)` is the §5.4.2 flow
/// `flow(a,gnd)` (§1.3.1.1: every ground is `gnd`), `I(a,b)` is `flow(a,b)`
/// and `I(<p>)` the §5.4.3 port flow `flow(<p>)`. A name that is not a Zig
/// identifier goes through `naming.sanitize`, as codegen spells `U`; a legal
/// identifier is taken as written, so an escaped member (`flowZ28pZ2cnZ29`)
/// is not escaped twice. Fails with `error.BadUnknownName` for a branch
/// potential `V(a,b)`, which is not an unknown. Result may alias `raw` or be
/// allocated in `arena`.
///
/// This is a text mapping because `ix()` resolves it against `U` at the
/// runner's compile time. `I(a)` is ambiguous on a module with a net named
/// `gnd`; such a fixture writes the member as `emitTopology` prints it.
fn unknownName(arena: Allocator, raw: []const u8) Error![]const u8 {
    var s = std.mem.trim(u8, raw, " \t");
    if (std.mem.startsWith(u8, s, "V(") and std.mem.endsWith(u8, s, ")")) {
        s = std.mem.trim(u8, s[2 .. s.len - 1], " \t");
        // §5.4.2's branch potential V(a,c) is derived from two nets and has
        // no row to pin. Refused here: sanitized into an identifier, it would
        // fail the testbench build, which the harness reports as an engine bug.
        if (std.mem.indexOfScalar(u8, s, ',') != null) return error.BadUnknownName;
    }
    if (std.mem.startsWith(u8, s, "I(") and std.mem.endsWith(u8, s, ")")) {
        const inner = std.mem.trim(u8, s[2 .. s.len - 1], " \t");
        s = if ((inner.len != 0 and inner[0] == '<') or std.mem.indexOfScalar(u8, inner, ',') != null)
            try arena.print("flow({s})", .{inner})
        else
            try arena.print("flow({s},gnd)", .{inner}); // §5.4.2 I(a) ≡ I(a,gnd)
    }
    if (std.mem.startsWith(u8, s, "x[") and std.mem.endsWith(u8, s, "]")) s = s[2 .. s.len - 1];
    s = std.mem.trim(u8, s, " \t");
    if (s.len == 0 or std.zig.isValidId(s)) return s;
    // Worst case is three bytes out per byte in (`Z` plus two hex digits),
    // plus the one `Z` a Zig-reserved word picks up.
    const buf = try arena.alloc(u8, s.len * 3 + 1);
    return naming.sanitize(buf, s) catch unreachable;
}

/// Appends the `name = value` pairs in `rest`, split on top-level commas so
/// the comma in §5.4.2's `I(a,b)` stays inside its name. Only `(` nests: a
/// §6.5.2 element `d[1]` holds no comma. Names are resolved by `unknownName`.
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

/// Parses a directive number, accepting §2.6 scale factors (`1u`).
fn number(raw: []const u8) Error!f64 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len == 0) return error.BadNumber;
    const exp = Lexer.scaleExp(t[t.len - 1]) orelse
        return std.fmt.parseFloat(f64, t) catch error.BadNumber;

    // The suffix becomes an exponent and the text is parsed once, as the
    // model's lexer does: `200 * 1e-6` is not `200e-6`, and a `//! time 200u`
    // point must equal `200u` written in the model.
    const head = std.mem.trim(u8, t[0 .. t.len - 1], " \t");
    if (head.len == 0) return error.BadNumber;
    var buf: [64]u8 = undefined;
    if (head.len + exp.len > buf.len) return error.BadNumber;
    @memcpy(buf[0..head.len], head);
    @memcpy(buf[head.len..][0..exp.len], exp);
    return std.fmt.parseFloat(f64, buf[0 .. head.len + exp.len]) catch error.BadNumber;
}
