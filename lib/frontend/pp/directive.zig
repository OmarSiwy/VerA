//! Directives with operands: one directive's text in, the included file scanned
//! or a `Directives` event recorded out.
//! LRM §10.2, §10.3; IEEE 1364 §19.2, §19.5, §19.7, §19.9, §19.10.

const std = @import("std");
const diag = @import("diag");
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

/// Reads and scans the file an IEEE 1364 §19.5 `include names. `rest` is the
/// line after the word, starting at offset `off`; `at` is the '`'.
pub fn handleInclude(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    // The directive word, for the errors that have nothing better to point at.
    const sp = pp.spanAt(at, off);
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const open = r.peek() orelse return pp.fail(sp, .E0121, "", .{});
    // IEEE 1364-2005 §19.5 Syntax 19-6 has one form, `include "filename". C's
    // `<file>` is not in it, so `<` is E0122 like any other opener.
    if (open != '"') return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0122, "found `{c}`", .{open});
    const close: u8 = '"';
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

    const inc = (try readInclude(pp, path, name_span)) orelse {
        var b = pp.failWith(name_span, .E0126);
        b.msg("\"{s}\"", .{path});
        if (pp.opts.include_dirs.len == 0) {
            b.note("no include directories were configured; only the built-in annex D headers ({s}) are resolvable", .{"constants.vams, disciplines.vams"});
        } else {
            b.note("searched: {s}", .{try std.mem.join(pp.scratch, ", ", pp.opts.include_dirs)});
        }
        try b.emit();
        return error.PreprocessFailed;
    };

    try pp.includes.append(pp.scratch, path);
    defer _ = pp.includes.pop();
    // Registered under the opened path, so `__FILE__` and every diagnostic
    // inside the file name the file that was read (§10.7).
    try pp.runFile(inc.text, inc.path, null);
    // `scan` resyncs the map back to the parent file when `directive` returns.
}

/// The bytes of an `include and the path they were opened by, which §10.7
/// makes `__FILE__`: "the path by which a tool opened the file, not the short
/// name specified in `include". A built-in annex D file keeps the name written.
pub const Included = struct { text: []const u8, path: []const u8 };

/// Returns the `include file for `path`: an absolute path as written, else
/// the first hit in the include dirs, else a built-in annex D file by
/// basename. Null if nothing matched. The bytes are arena-owned.
pub fn readInclude(pp: *Pp, path: []const u8, span: diag.Span) Error!?Included {
    // IEEE 1364 §19.5: a full path name is opened as written; `join` skips
    // the empty base.
    const bases: []const []const u8 = if (std.fs.path.isAbsolute(path)) &.{""} else pp.opts.include_dirs;
    if (bases.len != 0) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir: std.Io.Dir = .cwd();
        for (bases) |base| {
            const full = try std.fs.path.join(pp.arena, &.{ base, path });
            if (dir.readFileAlloc(io, full, pp.arena, .limited(max_include_bytes))) |bytes| {
                return .{ .text = bytes, .path = full };
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.StreamTooLong => return pp.fail(span, .E1013, "\"{s}\" is larger than {d} bytes", .{ full, max_include_bytes }),
                else => {}, // try the next dir
            }
        }
    }
    const text = builtin_includes.get(std.fs.path.basename(path)) orelse return null;
    // `path` may slice a macro body on scratch, and the bag keeps the name.
    return .{ .text = text, .path = try pp.arena.dupe(u8, path) };
}

// ---------------------------------------------------------------------------
// Directives recorded as `Directives` events, and `line
// ---------------------------------------------------------------------------

/// Parses a §10.2 Syntax 10-1 `default_discipline and records its event;
/// §7.4 discipline resolution applies it. `rest` is everything after the word
/// on one logical line, starting at offset `off`.
pub fn handleDefaultDiscipline(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    // Both operands are optional; the bare form withdraws the default. The
    // discipline_identifier is simple or escaped (A.9.3); annex D.1 declares
    // `discipline \logic ;`, which only the escaped spelling can name. The
    // qualifier is one of fifteen keywords, and §2.8.2 makes an escaped
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
    try expectEnd(pp, &r, off, .E0127, "qualifier", "Syntax 10-1 is `default_discipline [ discipline_identifier [ qualifier ] ], and nothing more");
    try pp.events.disciplines.append(pp.scratch, .{
        .at = @intCast(pp.out.items.len),
        .qualifier = qual,
        // Published in `Output`, and `disc` may slice a macro body on scratch.
        .discipline = try pp.arena.dupe(u8, disc),
    });
}

/// Parses a §10.3 Syntax 10-2 `default_transition and records its event.
///
///   default_transition_directive ::= `default_transition transition_time
///   transition_time ::= constant_expression
///
/// The operand is mandatory (E0129) and must be a finite, non-negative time.
///
/// ponytail: reads one §2.6 number with scale factor (`4n`, `4e-9`), not a
/// full constant_expression. Upgrade path: emit the directive verbatim and let
/// the parser fold it, once a model writes `default_transition tr*2.
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
    try expectEnd(pp, &r, off, .E0129, "transition time", "Syntax 10-2 is `default_transition transition_time, and nothing more");
    try pp.mark(&pp.events.transitions, t);
}

/// Parses an IEEE 1364 §19.9 `` `timescale <unit> / <precision> `` and records
/// its event. Each operand is on Table 19-1's grid (1, 10 or 100 and one of
/// six units). Every malformed form, and a precision coarser than the unit,
/// is E0142.
pub fn handleTimescale(pp: *Pp, rest: []const u8, off: usize) Error!void {
    // Marked null first and filled in on success; a `resetall also writes null.
    const event = pp.events.timescales.items.len;
    try pp.mark(&pp.events.timescales, null);
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
    pp.events.timescales.items[event].value = .{ .unit = unit, .precision = precision };
}

/// Emits E0142 naming what §19.9's grammar wanted. `r.i` is undefined after a
/// failed `timeLiteral`, so the span is the whole operand list.
fn badTimescale(pp: *Pp, off: usize, r: *const Rest, wanted: []const u8) Error {
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

/// Parses an IEEE 1364 §19.2 `default_nettype and records its region.
///
///   default_nettype_compiler_directive ::= `default_nettype default_nettype_value
///   default_nettype_value ::= wire | tri | tri0 | tri1 | wand | triand
///                           | wor | trior | trireg | uwire | none
///
/// The operand is mandatory and anything off the list is E0140. This is not
/// §10.2's qualifier list: that admits `integer`, `real`, `reg`, `wreal`,
/// `supply0` and `supply1` and lacks `uwire` and `none`. Name resolution
/// applies the region to undeclared names used as nets.
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
    try expectEnd(pp, &r, off, .E0140, "net type", "§19.2 is `default_nettype default_nettype_value, and nothing more");
    try pp.mark(&pp.events.nettypes, value);
}

/// Parses an IEEE 1364 §19.10 `` `unconnected_drive pull1 | pull0 `` and
/// records its region. The operand is mandatory (E0141); the operand-less
/// form is `` `nounconnected_drive ``.
pub fn handleUnconnectedDrive(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    const word = r.ident() orelse "";
    // Not a `stringToEnum`: `.float` is `nounconnected_drive's value, and
    // `unconnected_drive float` is not a directive.
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
    try expectEnd(pp, &r, off, .E0141, "pull value", "§19.10 takes one operand and nothing more");
    try pp.mark(&pp.events.drives, value);
}

/// Fails with `code` if anything but white space is left on the directive
/// line: the operand, named by `what`, is the last thing `syntax` allows.
fn expectEnd(pp: *Pp, r: *Rest, off: usize, code: diag.Code, what: []const u8, syntax: []const u8) Error!void {
    r.skipSpace();
    if (r.i == r.s.len) return;
    var b = pp.failWith(pp.spanAt(off + r.i, off + r.s.len), code);
    b.msg("`{s}` follows the {s}", .{ std.mem.trim(u8, r.s[r.i..], " \t\r"), what });
    b.note("{s}", .{syntax});
    try b.emit();
    return error.PreprocessFailed;
}

/// Reads one IEEE 1364 Table 19-1 time literal (`1`, `10` or `100` glued to
/// one of `s ms us ns ps fs`) as seconds, the unit §9.15 Table 9-27 asks for.
/// Null, with the cursor undefined, on anything else.
fn timeLiteral(r: *Rest) ?f64 {
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
    // A table of exact decimal literals, not magnitude * unit: 100 * 1e-6 is
    // 9.999999999999999e-5, one ulp off the 1e-4 a §9.15 reader expects.
    const decades = [_]f64{
        1e-15, 1e-14, 1e-13, 1e-12, 1e-11, 1e-10, 1e-9, 1e-8, 1e-7,
        1e-6,  1e-5,  1e-4,  1e-3,  1e-2,  1e-1,  1e0,  1e1,  1e2,
    };
    return decades[@intCast(mag + (units.get(unit) orelse return null) + 15)];
}

/// Parses an IEEE 1364 §19.7 `line <number> "<file>" <level> and remaps §10.7
/// `__LINE__` and `__FILE__` from the following line on. "All parameters in
/// the `line directive are required": the number "shall be a positive
/// integer", the level "shall be 0, 1, or 2", and nothing else may follow
/// (E0128). The level is checked and dropped, since VerA keeps the real
/// include stack. "Comments are not allowed on the same line": comments are
/// stripped before directives are read, so a strip mark on the line is one.
pub fn handleLine(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    if (pp.expand_site == null) {
        const text = pp.opts.bag.fileText(pp.cur_file_id);
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
        // ponytail: linear in the file's comments; a `line is rare.
        for (pp.opts.bag.fileMarks(pp.cur_file_id)) |m| if (m.out > line_start and m.out <= off + rest.len)
            return pp.fail(pp.spanAt(at, off + rest.len), .E0128, "a comment on the directive's line", .{});
    }
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
