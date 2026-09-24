//! `include (§10.3), §10.2 `default_discipline and friends, IEEE 1364 §19.7 `line.
//!
//! In: one compiler directive. Out: the included text, or the directive's effect recorded in
//! the side tables lowering reads (default discipline, transition, timescale).
//!
//! LRM clauses this file's code cites: §1, §2.6, §2.8.2, §4.5.8, §7.4, §9.15.

const std = @import("std");
const Preprocessor = @import("../preprocessor.zig");
const Lexer = @import("../lexer.zig");
const Error = Preprocessor.Error;
const max_include_depth = Preprocessor.max_include_depth;
const max_include_bytes = Preprocessor.max_include_bytes;
const Qualifier = Preprocessor.Qualifier;
const NetType = Preprocessor.NetType;
const Drive = Preprocessor.Drive;
const builtin_includes = Preprocessor.builtin_includes;
const Pp = Preprocessor.Pp;
const Rest = Preprocessor.Rest;
const isSpace = Preprocessor.isSpace;

// ---------------------------------------------------------------------------
// `include
// ---------------------------------------------------------------------------

pub fn handleInclude(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    // The directive word, for the errors that have nothing better to point at.
    const sp = pp.spanAt(at, off);
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const open = r.peek() orelse return pp.fail(sp, .E0121, "", .{});
    const close: u8 = switch (open) {
        '"' => '"',
        '<' => '>',
        else => return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0122, "found `{c}`", .{open}),
    };
    r.i += 1;
    const start = r.i;
    while (r.i < r.s.len and r.s[r.i] != close) r.i += 1;
    if (r.i >= r.s.len) return pp.fail(pp.spanAt(off + start - 1, off + r.i), .E0123, "", .{});
    const path = r.s[start..r.i];
    if (path.len == 0) return pp.fail(pp.spanAt(off + start - 1, off + r.i + 1), .E0124, "", .{});
    // The file name itself, quotes excluded.
    const name_span = pp.spanAt(off + start, off + r.i);
    // IEEE 1364 §19.5: "Only white space or a comment may appear on the same
    // line as the `include compiler directive." Comments are gone already.
    r.i += 1;
    r.skipSpace();
    if (r.i < r.s.len)
        return pp.fail(pp.spanAt(off + r.i, off + r.s.len), .E0144, "`{s}`", .{std.mem.trim(u8, r.s[r.i..], " \t\r\n")});

    if (pp.includes.items.len >= max_include_depth) {
        var b = pp.failWith(name_span, .E0125);
        b.msg("limit is {d}", .{max_include_depth});
        b.note("include chain: {s}", .{try pp.joinChain(pp.includes.items, path)});
        try b.emit();
        return error.PreprocessFailed;
    }

    const text = (try readInclude(pp, path)) orelse {
        var b = pp.failWith(name_span, .E0126);
        b.msg("\"{s}\"", .{path});
        if (pp.opts.include_dirs.len == 0) {
            b.note("no include directories were configured; only the built-in annex D headers ({s}) are resolvable", .{"constants.vams, disciplines.vams"});
        } else {
            b.note("searched: {s}", .{try std.mem.join(pp.arena, ", ", pp.opts.include_dirs)});
        }
        try b.emit();
        return error.PreprocessFailed;
    };

    try pp.includes.append(pp.arena, path);
    defer _ = pp.includes.pop();
    try pp.runFile(text, path, null);
    // `scan` resyncs the map back to the parent file when `directive` returns.
}

/// Search order: caller include dirs (in order), then the built-in annex D
/// files by basename. Returns null if nothing matched.
pub fn readInclude(pp: *Pp, path: []const u8) Error!?[]const u8 {
    if (pp.opts.include_dirs.len != 0) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir: std.Io.Dir = .cwd();
        for (pp.opts.include_dirs) |base| {
            const full = try std.fs.path.join(pp.arena, &.{ base, path });
            if (dir.readFileAlloc(io, full, pp.arena, .limited(max_include_bytes))) |bytes| {
                return bytes;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {}, // try the next dir
            }
        }
    }
    return builtin_includes.get(std.fs.path.basename(path));
}

// ---------------------------------------------------------------------------
// §10.2 `default_discipline, IEEE 1364 §19.7 `line
// ---------------------------------------------------------------------------

/// §10.2 Syntax 10-1. `rest` is everything after the word on one logical line;
/// `off` is the offset `rest` starts at.
///
/// Nothing is applied here — the directive's effect is §7.4 discipline
/// resolution, which needs the module's declarations and so cannot run in a
/// text stage. What this does is PARSE it (a wrong qualifier is a syntax error
/// the front end owes the user, and it is exactly the typo the closed list
/// exists to catch, two adjacent identifiers being easy to duplicate) and
/// record the event with the output offset it takes effect from.
pub fn handleDefaultDiscipline(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    // Both operands are optional; the bare form WITHDRAWS the default. The
    // discipline_identifier is an A.9.3 `identifier`, simple OR escaped —
    // annex D.1 itself declares `discipline \logic ;`, so the escaped spelling
    // is the only way to name that one here. The qualifier stays `ident()`:
    // Syntax 10-1 closes it over fifteen KEYWORDS, and §2.8.2 makes an escaped
    // identifier never a keyword.
    const disc = r.escapedIdent() orelse r.ident() orelse "";
    const word = if (disc.len == 0) "" else r.ident() orelse "";
    const qual = std.meta.stringToEnum(Qualifier, word);
    if (word.len != 0 and qual == null) {
        var b = pp.failWith(pp.spanAt(off + r.i - word.len, off + r.i), .E0127);
        b.msg("`{s}` is not a qualifier", .{word});
        b.note("Syntax 10-1 allows one of: {s}", .{"integer, real, reg, wreal, wire, tri, wand, triand, wor, trior, trireg, tri0, tri1, supply0, supply1"});
        try b.emit();
        return error.PreprocessFailed;
    }
    // Anything after the qualifier is not in Syntax 10-1 either. Reported with
    // the same code so the rule reads as one rule.
    r.skipSpace();
    if (r.i < r.s.len and std.mem.trim(u8, r.s[r.i..], " \t\r").len != 0) {
        var b = pp.failWith(pp.spanAt(off + r.i, off + r.s.len), .E0127);
        b.msg("`{s}` follows the qualifier", .{std.mem.trim(u8, r.s[r.i..], " \t\r")});
        b.note("Syntax 10-1 is `default_discipline [ discipline_identifier [ qualifier ] ], and nothing more", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    try pp.defaults.append(pp.arena, .{
        .at = @intCast(pp.out.items.len),
        .qualifier = qual,
        .discipline = disc,
    });
}

/// §10.3 Syntax 10-2:
///
///   default_transition_directive ::= `default_transition transition_time
///   transition_time ::= constant_expression
///
/// No brackets round the operand, so it is MANDATORY — see E0129 for why the
/// bare form is a diagnostic rather than a request for the simulator default.
///
/// `constant_expression` in full is a parser's job and this is a text stage, so
/// what is read here is one §2.6 number, scale factor included: `4n`, `4e-9`,
/// `0.000000004`. That is every `default_transition anyone writes, and the
/// alternative — deferring the directive to the parser the way §10.6
/// `begin_keywords is deferred — buys an expression grammar for an operand the
/// LRM only ever illustrates as a literal.
/// ponytail: upgrade path is emitting the directive verbatim and letting the
/// parser fold it, the day a model writes `default_transition tr*2.
pub fn handleDefaultTransition(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and !isSpace(r.s[r.i])) r.i += 1;
    const text = r.s[start..r.i];
    if (text.len == 0) {
        var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0129);
        b.msg("`default_transition needs a transition time and this one has none", .{});
        b.note("Syntax 10-2 is `default_transition transition_time, and the operand is not optional", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    const t = Lexer.parseReal(text) catch {
        return pp.fail(pp.spanAt(off + start, off + r.i), .E0129, "`{s}` is not a transition time", .{text});
    };
    // §4.5.8 gives the value straight to rise_time and fall_time, and both are
    // times: a negative one describes an edge that finishes before it starts.
    // (E0516 says the same of a rise_time written at the call.)
    if (!(t >= 0.0) or !std.math.isFinite(t)) {
        return pp.fail(pp.spanAt(off + start, off + r.i), .E0129, "a transition time cannot be `{s}`", .{text});
    }
    r.skipSpace();
    if (r.i < r.s.len and std.mem.trim(u8, r.s[r.i..], " \t\r").len != 0) {
        var b = pp.failWith(pp.spanAt(off + r.i, off + r.s.len), .E0129);
        b.msg("`{s}` follows the transition time", .{std.mem.trim(u8, r.s[r.i..], " \t\r")});
        b.note("Syntax 10-2 is `default_transition transition_time, and nothing more", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    try pp.mark(&pp.transitions, t);
}

/// IEEE Std 1364 §19.9 `` `timescale <unit> / <precision> ``.
///
/// Both operands are on Table 19-1's closed grid — a magnitude of 1, 10 or 100
/// and one of six unit names — so a hand-written table of six exponents is the
/// whole conversion, and nothing here has to parse a general real.
///
/// EVERY way of getting it wrong is E0142. §19.9 gives the directive a closed
/// grammar and one semantic constraint ("The time precision shall be at least
/// as precise as the time unit"), and a stream that breaks either wrote a
/// directive with no reading — there is no second interpretation to fall back
/// to. Until this code existed a malformed operand left the timescale UNSET,
/// which pushed the mistake to §9.15's "not known" (E0811) at the far end of
/// the compilation, or to the digital executor, or nowhere at all when the
/// model never asked.
pub fn handleTimescale(pp: *Pp, rest: []const u8, off: usize) Error!void {
    // The digital consumer must distinguish malformed timing from no directive.
    // Kept, even though a malformed directive now fails the compilation: a
    // `resetall writes the same null, and `resetall is not an error.
    const event = pp.timescale_events.items.len;
    try pp.mark(&pp.timescale_events, null);
    var r: Rest = .{ .s = rest };
    const unit = timeLiteral(&r) orelse return badTimescale(pp, off, &r, "a Table 19-1 time unit");
    r.skipSpace();
    if (r.peek() != '/') return badTimescale(pp, off, &r, "`/` and then the time precision");
    r.i += 1;
    const precision = timeLiteral(&r) orelse return badTimescale(pp, off, &r, "a Table 19-1 time precision");
    // "The time precision shall be at least as precise as the time unit"
    // (§19.9). A card that has them backwards is not a timescale.
    if (precision > unit) {
        var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0142);
        b.msg("the time precision is coarser than the time unit", .{});
        b.note("§19.9: \"The time precision shall be at least as precise as the time unit\"", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    r.skipSpace();
    if (r.i < r.s.len) return badTimescale(pp, off, &r, "nothing more");
    pp.timescale_events.items[event].value = .{ .unit = unit, .precision = precision };
}

/// E0142 at the cursor, naming what §19.9's grammar wanted there. `r.i` is
/// undefined after a failed `timeLiteral`, so the span is the whole operand
/// list — which is the thing the user has to rewrite anyway.
pub fn badTimescale(pp: *Pp, off: usize, r: *const Rest, wanted: []const u8) Error {
    const wrote = std.mem.trim(u8, r.s, " \t\r");
    var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0142);
    if (wrote.len == 0) {
        b.msg("`timescale has no operands", .{});
    } else {
        b.msg("`{s}` is not a `timescale", .{wrote});
    }
    b.note("§19.9 is `timescale <time_unit>/<time_precision>; here it wanted {s}", .{wanted});
    b.note("each operand is 1, 10 or 100 glued to one of s ms us ns ps fs", .{});
    b.emit() catch |e| return e;
    return error.PreprocessFailed;
}

/// IEEE Std 1364 §19.2:
///
///   default_nettype_compiler_directive ::= `default_nettype default_nettype_value
///   default_nettype_value ::= wire | tri | tri0 | tri1 | wand | triand
///                           | wor | trior | trireg | uwire | none
///
/// A CLOSED alternation with no brackets round it, so the operand is mandatory
/// and anything off the list is a syntax error — the same shape as §10.2's
/// `qualifier`, and E0140 says so the same way E0127 does. The two lists are
/// NOT the same list: §10.2 admits `integer`, `real`, `reg`, `wreal`, `supply0`
/// and `supply1`, none of which §19.2 lets an implicit net be, and §19.2 admits
/// `uwire` and `none`, which are not qualifiers.
///
/// Nothing is applied here. §19.2 decides what happens to an UNDECLARED name
/// used as a net, which is a question only name resolution can ask, so what
/// this does is parse the directive and publish the region it opens —
/// `Lower.nodeOf` and `Elaborate.walkInstances` are the two places that ask.
pub fn handleDefaultNettype(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    const word = r.ident() orelse "";
    const value = std.meta.stringToEnum(NetType, word) orelse {
        var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0140);
        if (word.len == 0) {
            b.msg("`default_nettype needs a net type and this one has none", .{});
        } else {
            b.msg("`{s}` is not a net type", .{word});
        }
        b.note("§19.2 allows one of: wire, tri, tri0, tri1, wand, triand, wor, trior, trireg, uwire, none", .{});
        try b.emit();
        return error.PreprocessFailed;
    };
    r.skipSpace();
    if (r.i < r.s.len) {
        var b = pp.failWith(pp.spanAt(off + r.i, off + r.s.len), .E0140);
        b.msg("`{s}` follows the net type", .{std.mem.trim(u8, r.s[r.i..], " \t\r")});
        b.note("§19.2 is `default_nettype default_nettype_value, and nothing more", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    try pp.mark(&pp.nettypes, value);
}

/// IEEE Std 1364 §19.10 `` `unconnected_drive pull1 | pull0 ``. The operand is
/// a two-way alternation and it is mandatory; the directive that takes none is
/// spelled `` `nounconnected_drive `` and is a different row of Table 10-1.
pub fn handleUnconnectedDrive(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    const word = r.ident() orelse "";
    // `.float` is `nounconnected_drive's value and has no spelling here, so it
    // is excluded rather than looked up — `unconnected_drive float` is not a
    // directive.
    const value: Drive = if (std.mem.eql(u8, word, "pull0"))
        .pull0
    else if (std.mem.eql(u8, word, "pull1"))
        .pull1
    else {
        var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0141);
        if (word.len == 0) {
            b.msg("`unconnected_drive needs a pull value and this one has none", .{});
        } else {
            b.msg("`{s}` is not a pull value", .{word});
        }
        b.note("§19.10 is `unconnected_drive pull1 | pull0; the form with no operand is `nounconnected_drive", .{});
        try b.emit();
        return error.PreprocessFailed;
    };
    r.skipSpace();
    if (r.i < r.s.len) {
        var b = pp.failWith(pp.spanAt(off + r.i, off + r.s.len), .E0141);
        b.msg("`{s}` follows the pull value", .{std.mem.trim(u8, r.s[r.i..], " \t\r")});
        b.note("§19.10 takes one operand and nothing more", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    try pp.mark(&pp.drives, value);
}

/// One IEEE 1364 Table 19-1 time literal — `1`, `10` or `100` glued to one of
/// `s ms us ns ps fs` — as a count of SECONDS, which is the unit §9.15
/// Table 9-27 asks for. Null (cursor undefined) on anything else.
pub fn timeLiteral(r: *Rest) ?f64 {
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') r.i += 1;
    const mag: i8 = if (std.mem.eql(u8, r.s[start..r.i], "1"))
        0
    else if (std.mem.eql(u8, r.s[start..r.i], "10"))
        1
    else if (std.mem.eql(u8, r.s[start..r.i], "100")) 2 else return null;
    const unit = r.ident() orelse return null;
    const units = std.StaticStringMap(i8).initComptime(.{
        .{ "s", 0 },   .{ "ms", -3 },  .{ "us", -6 },
        .{ "ns", -9 }, .{ "ps", -12 }, .{ "fs", -15 },
    });
    // Composed as ONE decimal literal and not as magnitude × unit: 100 * 1e-6
    // is 9.999999999999999e-5, and a §9.15 reader comparing against the 1e-4
    // it wrote would be one ulp out for a reason that is arithmetic, not
    // timekeeping. The grid is 18 wide, so the table IS the multiplication.
    const decades = [_]f64{
        1e-15, 1e-14, 1e-13, 1e-12, 1e-11, 1e-10, 1e-9, 1e-8, 1e-7,
        1e-6,  1e-5,  1e-4,  1e-3,  1e-2,  1e-1,  1e0,  1e1,  1e2,
    };
    return decades[@intCast(mag + (units.get(unit) orelse return null) + 15)];
}

/// IEEE Std 1364 §19.7 `line <number> "<file>" <level>, which §10.7 names as
/// the way `__LINE__` (and possibly `__FILE__`) is remapped. The number is
/// that of the line FOLLOWING the directive. "All parameters in the `line
/// directive are required": the number "shall be a positive integer", the
/// level "shall be 0, 1, or 2", and "only white space may appear on the same
/// line".
///
/// The level is checked and dropped: it says whether the remap enters, leaves
/// or stays in a file, which only matters to a tool that reconstructs an
/// include stack out of `line directives. VerA has the real one.
/// ponytail: §19.7 also forbids a COMMENT on the line; comments are stripped
/// before directives are read, so that one is not diagnosed.
pub fn handleLine(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') r.i += 1;
    if (r.i == start)
        return pp.fail(pp.spanAt(off, off + r.s.len), .E0128, "", .{});
    const n = std.fmt.parseInt(u32, r.s[start..r.i], 10) catch
        return pp.fail(pp.spanAt(off + start, off + r.i), .E0128, "`{s}` does not fit a line number", .{r.s[start..r.i]});
    if (n == 0) return pp.fail(pp.spanAt(off + start, off + r.i), .E0128, "the line number must be a positive integer", .{});

    r.skipSpace();
    if (r.peek() != '"') return pp.fail(pp.spanAt(off + r.i, off + r.s.len), .E0128, "the file name is missing", .{});
    const q = r.i + 1;
    r.i = q;
    while (r.i < r.s.len and r.s[r.i] != '"') r.i += 1;
    if (r.i >= r.s.len)
        return pp.fail(pp.spanAt(off + q - 1, off + r.i), .E0128, "unterminated file name", .{});
    const file = r.s[q..r.i];
    r.i += 1;
    r.skipSpace();
    const level = r.i;
    if (r.i >= r.s.len or r.s[r.i] < '0' or r.s[r.i] > '2')
        return pp.fail(pp.spanAt(off + level, off + r.s.len), .E0128, "the level must be 0, 1 or 2", .{});
    r.i += 1;
    if (std.mem.trim(u8, r.s[r.i..], " \t\r\n").len != 0)
        return pp.fail(pp.spanAt(off + level, off + r.s.len), .E0128, "`{s}` is not a level", .{std.mem.trim(u8, r.s[level..], " \t\r\n")});
    pp.file_override = file;

    pp.line_from = pp.physicalLine(at) + 1;
    pp.line_to = n;
}
