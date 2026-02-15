//! §10.4 `define, `undef and macro expansion.
//!
//! In: a `define body, or a macro use with its actual arguments. Out: the macro table entry,
//! or the expanded text (argument pre-expansion, recursion refused).
//!
//! LRM clauses this file's code cites: §1, §2.7, §2.8.1.
//!
//! Cut verbatim from `preprocessor.zig`.

const std = @import("std");
const Preprocessor = @import("../preprocessor.zig");
const diag = @import("diag");
const Error = Preprocessor.Error;
const max_expansion_depth = Preprocessor.max_expansion_depth;
const Macro = Preprocessor.Macro;
const Pp = Preprocessor.Pp;
const scan = Preprocessor.scan;
const stringStop = Preprocessor.stringStop;
const Rest = Preprocessor.Rest;
const indexOfString = Preprocessor.indexOfString;
const isSpace = Preprocessor.isSpace;
const isIdentStart = Preprocessor.isIdentStart;
const isIdentChar = Preprocessor.isIdentChar;

// ---------------------------------------------------------------------------
// §10.4 `define / `undef
// ---------------------------------------------------------------------------

/// `rest` is everything after the word "define" on one logical line; `at` is
/// the '`' and `off` the offset `rest` starts at.
pub fn handleDefine(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    // Syntax 10-3 writes two different nonterminals into adjacent lines:
    //   formal_argument_identifier ::= simple_identifier
    //   text_macro_identifier      ::= identifier
    // and A.9.3 makes `identifier` simple OR escaped. So the NAME may be
    // escaped and the formals may not — `escapedIdent` is used here and
    // `ident` stays in the formal loop below.
    const name = r.escapedIdent() orelse r.ident() orelse
        return pp.fail(pp.spanAt(at, off), .E0109, "", .{});

    var m: Macro = .{ .body = "" };
    // The '(' of a formal argument list must touch the macro name (§10.4).
    if (r.peek() == '(') {
        r.i += 1;
        m.is_func = true;
        var params: std.ArrayList([]const u8) = .empty;
        while (true) {
            r.skipSpace();
            if (r.peek() == ')') {
                r.i += 1;
                break;
            }
            const p = r.ident() orelse
                return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0110, "`{s}`", .{name});
            try params.append(pp.arena, p);
            r.skipSpace();
            const c = r.peek() orelse
                return pp.fail(pp.spanAt(off + r.i, off + r.i), .E0111, "`{s}`", .{name});
            if (c == ',') {
                r.i += 1;
                continue;
            }
            if (c == ')') {
                r.i += 1;
                break;
            }
            return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0112, "`{s}`", .{name});
        }
        m.params = params.items;
    }
    r.skipSpace();
    m.body = try joinContinuations(pp, std.mem.trimEnd(u8, r.s[r.i..], " \t\r"));

    // §10.4: "To avoid conflicts with predefined Verilog-AMS macros (10.5), the
    // `define compiler directive's macro text shall not begin with __VAMS_."
    // The target is the TEXT (Syntax 10-3's second operand), not the name — a
    // body is what can expand into a §10.5 predefined macro and shadow it.
    if (std.mem.startsWith(u8, m.body, "__VAMS_"))
        return pp.fail(pp.spanAt(off + r.i, off + r.s.len), .E0139, "`{s}` begins with __VAMS_", .{m.body});

    // §10.4: a redefinition silently replaces. Predefined macros keep their flag
    // so `resetall does not drop them.
    if (pp.macros.get(name)) |old| m.predefined = old.predefined;
    try pp.macros.put(pp.arena, name, m);
}

pub fn removeDefine(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    // Syntax 10-3: `undef's operand is a text_macro_identifier ::= identifier,
    // simple OR escaped (A.9.3) — a name `` `define \M-X `` could create is a
    // name `` `undef \M-X `` must be able to withdraw.
    const name = r.escapedIdent() orelse r.ident() orelse
        return pp.fail(pp.spanAt(at, off), .E0113, "", .{});
    // §10.4: "`undef shall have no effect on predefined Verilog-AMS macros".
    if (pp.macros.get(name)) |m| {
        if (m.predefined) return;
    }
    _ = pp.macros.remove(name);
}

/// A macro body is one logical line: `\`+newline collapses to a space. The
/// newlines it swallowed are re-emitted by the caller, so lines still line up.
pub fn joinContinuations(pp: *Pp, body: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, body, '\n') == null) return body;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(pp.arena, body.len);
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            var k = i + 1;
            while (k < body.len and (body[k] == ' ' or body[k] == '\t' or body[k] == '\r')) k += 1;
            if (k < body.len and body[k] == '\n') {
                // One separating space, unless the text already ends in one.
                if (out.items.len != 0 and out.items[out.items.len - 1] != ' ')
                    out.appendAssumeCapacity(' ');
                i = k;
                // Also eat the indentation of the continuation line.
                while (i + 1 < body.len and (body[i + 1] == ' ' or body[i + 1] == '\t')) i += 1;
                continue;
            }
        }
        if (body[i] == '\n' or body[i] == '\r') continue;
        out.appendAssumeCapacity(body[i]);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// §10.4 macro expansion
// ---------------------------------------------------------------------------

/// `at` points at '`', `after_name` past the macro name. Returns resume offset.
pub fn expand(pp: *Pp, text: []const u8, at: usize, after_name: usize, name: []const u8) Error!usize {
    if (!pp.emitting()) return after_name;
    // The whole use, backtick included: `FOO.
    const sp = pp.spanAt(at, after_name);

    const m = pp.macros.get(name) orelse {
        // §10.7. Not in `macros` because neither has a fixed body: both are
        // computed from where the use SITS, so they are expanded here, at the
        // one point that still knows the file and the offset. A user `define
        // of either name is found by the lookup above and wins, which costs
        // nothing to allow and is the only reading §10.4 leaves open.
        if (std.mem.eql(u8, name, "__LINE__")) {
            // "in the form of a simple decimal number" — an integer token, not
            // a string, so it is usable as `ln = `__LINE__;`.
            var buf: [16]u8 = undefined;
            try pp.out.appendSlice(pp.arena, std.fmt.bufPrint(&buf, "{d}", .{pp.currentLine(at)}) catch unreachable);
            return after_name;
        }
        if (std.mem.eql(u8, name, "__FILE__")) {
            // "in the form of a string literal" — §2.7, so the quotes are part
            // of the expansion and a '"' or '\' in the path has to be escaped
            // or the literal ends early (Windows paths are full of the latter).
            try pp.out.appendSlice(pp.arena, "\"");
            // §10.7 `__FILE__`: "the name of the current input file". The clause makes
            // the spelling "implementation dependent" and says a `line directive may
            // replace it, so the override wins when there is one.
            for (pp.file_override orelse pp.opts.bag.fileName(pp.cur_file_id)) |c| {
                if (c == '"' or c == '\\') try pp.out.appendSlice(pp.arena, "\\");
                try pp.out.append(pp.arena, c);
            }
            try pp.out.appendSlice(pp.arena, "\"");
            return after_name;
        }
        var b = pp.failWith(sp, .E0115);
        b.msg("`{s}", .{name});
        if (diag.didYouMeanMap(name, pp.macros)) |near| {
            // `sp` spans the whole use INCLUDING the backtick, so the rewrite
            // has to put one back — `suggestHere` would eat it.
            const repl = try std.fmt.allocPrint(pp.arena, "`{s}", .{near});
            b.suggest(.{ .span = sp, .replacement = repl }, "did you mean `{s}`?", .{near});
        }
        try b.emit();
        return error.PreprocessFailed;
    };

    var end = after_name;
    var args: []const []const u8 = &.{};
    if (m.is_func) {
        var k = after_name;
        while (k < text.len and isSpace(text[k])) k += 1;
        if (k >= text.len or text[k] != '(')
            return pp.fail(sp, .E0116, "`{s}` takes {d} argument(s)", .{ name, m.params.len });
        const parsed = try macroArgs(pp, text, k, at, name);
        args = parsed.args;
        end = parsed.end;
        // `M()` on a zero-parameter macro is an empty list, not one empty arg.
        if (m.params.len == 0 and args.len == 1 and args[0].len == 0) args = &.{};
        if (args.len != m.params.len)
            return pp.fail(sp, .E0117, "expected {d}, found {d}", .{ m.params.len, args.len });
    }

    for (pp.expanding.items) |active| {
        if (!std.mem.eql(u8, active, name)) continue;
        var b = pp.failWith(sp, .E0118);
        b.msg("`{s}`", .{name});
        b.note("expansion chain: {s}", .{try pp.joinChain(pp.expanding.items, name)});
        try b.emit();
        return error.PreprocessFailed;
    }
    if (pp.expand_depth >= max_expansion_depth)
        return pp.fail(sp, .E0119, "limit is {d}", .{max_expansion_depth});
    pp.expand_depth += 1;
    defer pp.expand_depth -= 1;

    // §10.4 defers text-macro semantics to IEEE Std 1364, whose rule is that a
    // macro's TEXT may not refer to the macro itself, directly or indirectly —
    // a property of the DEFINITION. A nested invocation in an ACTUAL argument
    // (`` `MAX(`MAX(a,b),c) ``) is not that: the C-preprocessor model, which
    // 1364's macro system transcribes, expands each argument FULLY before it is
    // substituted into the body. Splicing the RAW argument text and rescanning
    // it while `name` sits on `pp.expanding` turned every such use into a false
    // E0118. Pre-expansion happens here, BEFORE the name is pushed, so the
    // argument's own uses see the caller's stack — while a self-reference in
    // the BODY is still rescanned with the name on the stack and still E0118s.
    const body = if (m.is_func) blk: {
        var actuals = args;
        for (args, 0..) |a, first| {
            if (std.mem.indexOfScalar(u8, a, '`') == null) continue;
            // At least one argument invokes a macro: expand them all into a
            // copy. Backtick-free arguments (the overwhelming case) take the
            // branch above and are substituted verbatim, byte-identically to
            // what the splice-and-rescan model produced.
            const copy = try pp.arena.dupe([]const u8, args);
            for (copy[first..]) |*slot| slot.* = try expandArg(pp, slot.*, at);
            actuals = copy;
            break;
        }
        break :blk try substitute(pp, m.body, m.params, actuals);
    } else m.body;

    try pp.expanding.append(pp.arena, name);
    defer _ = pp.expanding.pop();

    // Provenance: the bytes about to be emitted came from a macro body, not
    // from the file. Only the OUTERMOST expansion is recorded — a nested one
    // resolves to the same invocation site anyway, so the extra segments would
    // buy nothing.
    const outermost = pp.expand_site == null;
    if (outermost) {
        const o: u32 = @intCast(pp.out.items.len);
        const site: u32 = @intCast(at);
        const inv: u32 = @intCast(pp.segs.items.len);
        // A zero-width verbatim segment pinning the invocation site, so
        // `resolve` walking out of the macro lands on the use, not on
        // wherever the enclosing segment happened to start.
        try pp.segs.append(pp.arena, .{ .out_start = o, .in_start = site, .file = pp.cur_file_id, .kind = .verbatim });
        try pp.segs.append(pp.arena, .{
            .out_start = o,
            .in_start = site,
            .file = pp.cur_file_id,
            .kind = .macro,
            .parent = inv,
            .macro = name,
        });
        pp.expand_site = site;
    }
    defer if (outermost) {
        pp.expand_site = null;
    };

    // Rescan the expansion so nested macro uses (§10.4) expand too. The cycle
    // guard above is what makes this terminate.
    try scan(pp, body);

    // The invocation may have spanned lines; keep the count.
    try pp.putNewlines(text[at..end]);
    // `scan` resyncs the map to `end` when this returns.
    return end;
}

/// Fully macro-expand one collected actual argument (§10.4 via IEEE 1364 —
/// arguments are expanded BEFORE substitution, see the comment in `expand`).
/// Runs `scan` with the output redirected into a fresh arena list; `at` is the
/// invocation's '`', which becomes `expand_site` so that diagnostics raised
/// inside the argument, `__LINE__`, and the no-segment rule all behave exactly
/// as they do for a body rescan. Backtick-free text expands to itself and is
/// returned unscanned.
pub fn expandArg(pp: *Pp, arg: []const u8, at: usize) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, arg, '`') == null) return arg;
    const saved_out = pp.out;
    const saved_site = pp.expand_site;
    pp.out = .empty;
    if (pp.expand_site == null) pp.expand_site = @intCast(at);
    defer {
        pp.out = saved_out;
        pp.expand_site = saved_site;
    }
    try scan(pp, arg);
    return pp.out.items;
}

pub const MacroArgs = struct { args: []const []const u8, end: usize };

/// Splits a top-level comma list starting at the '(' at `lparen`. Nested
/// (), [], {} and string literals are opaque.
///
/// The nesting is a STACK of opener kinds, not one shared counter: with a
/// counter every one of `)]}` could close the argument list, so `` `ID(2.0] ``
/// compiled clean and crossed nestings like `[(],)` mis-sliced the arguments.
/// A closer that does not match its opener is E0120 — the `(` it leaves behind
/// really is unterminated, and saying so at the mismatch is the honest place.
pub fn macroArgs(pp: *Pp, text: []const u8, lparen: usize, at: usize, name: []const u8) Error!MacroArgs {
    var args: std.ArrayList([]const u8) = .empty;
    var opens: std.ArrayList(u8) = .empty;
    var i = lparen;
    var arg_start = lparen + 1;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '"' => i = stringStop(text, i),
            '(', '[', '{' => try opens.append(pp.arena, c),
            ')', ']', '}' => {
                // Non-empty: the first iteration pushes the '(' at `lparen`,
                // and the list returns the moment the stack empties.
                const open = opens.pop().?;
                const want: u8 = switch (open) {
                    '(' => ')',
                    '[' => ']',
                    else => '}',
                };
                if (c != want) {
                    var b = pp.failWith(pp.spanAt(i, i + 1), .E0120);
                    b.msg("`{s}`: `{c}` cannot close `{c}`", .{ name, c, open });
                    try b.emit();
                    return error.PreprocessFailed;
                }
                if (opens.items.len == 0) {
                    try args.append(pp.arena, std.mem.trim(u8, text[arg_start..i], " \t\r\n"));
                    return .{ .args = args.items, .end = i + 1 };
                }
            },
            ',' => if (opens.items.len == 1) {
                try args.append(pp.arena, std.mem.trim(u8, text[arg_start..i], " \t\r\n"));
                arg_start = i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return pp.fail(pp.spanAt(at, at + 1 + name.len), .E0120, "`{s}`", .{name});
}

/// Replace whole-identifier occurrences of the formals in `body`. String
/// literals are left alone, and the identifier right after a '`' is a macro
/// name, never a formal.
pub fn substitute(pp: *Pp, body: []const u8, params: []const []const u8, args: []const []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(pp.arena, body.len);

    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '"') {
            const start = i;
            i += 1;
            while (i < body.len and body[i] != '"') {
                if (body[i] == '\\' and i + 1 < body.len) i += 1;
                i += 1;
            }
            if (i < body.len) i += 1;
            try out.appendSlice(pp.arena, body[start..i]);
            continue;
        }
        if (c == '`') {
            const start = i;
            i += 1;
            while (i < body.len and isIdentChar(body[i])) i += 1;
            try out.appendSlice(pp.arena, body[start..i]);
            continue;
        }
        if (c == '\\') {
            // §2.8.1 escaped identifier: opaque up to the next white space,
            // exactly as `scan` and `stripComments` treat it. A formal spelled
            // INSIDE one is part of that identifier, not a use of the formal —
            // `` `define M(x) real \sig-x ; `` declares `\sig-x`, not `\sig-1`.
            const start = i;
            i += 1;
            while (i < body.len and !isSpace(body[i])) i += 1;
            try out.appendSlice(pp.arena, body[start..i]);
            continue;
        }
        if (isIdentStart(c)) {
            const start = i;
            while (i < body.len and isIdentChar(body[i])) i += 1;
            const word = body[start..i];
            const idx = indexOfString(params, word);
            try out.appendSlice(pp.arena, if (idx) |k| args[k] else word);
            continue;
        }
        try out.append(pp.arena, c);
        i += 1;
    }
    return out.items;
}
