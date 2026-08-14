//! The `.v` runner metadata both digital runners read: a fixture's raw source
//! -> its routing (`// digital-runner: reject`), its extra `vera` arguments,
//! its `//! reject`, `//! xfail` and `// digital-runner: warning` obligations
//! judged against a run's stderr, and its `//! expect vcd` dump comparison.
//! `devices.zig`, `native.zig`, `../ieee1364.zig`, `../torture.zig` and
//! `../harness.zig` (`collect`, `judge`, `judgeVcd`) import it directly.
//!
//! None of it is a `tb` directive: `tb.parse` describes the analog harness and
//! must not take a digital diagnostic as its evidence.
//!
//! Clauses: IEEE 1364-2005 §13.2 and §13.7.1 (`--libmap`, `-L`), §18.2 (the
//! VCD format's free white space and its writer-owned sections).

const std = @import("std");

/// Runner metadata, deliberately not a tb directive: tb.parse describes the
/// analog harness and must not interpret a digital diagnostic as its evidence.
pub fn negative(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), "// digital-runner: reject")) return true;
    }
    return false;
}

/// The `vera` arguments a digital case passes after its own path, one
/// `// digital-runner:` line each: `--std=SPEC`, `--event-budget=N`; `--libmap FILE` and
/// `files FILE...` (more sources, after the fixture), both relative to the
/// fixture's directory `dir`; and `-L LIB`.
pub fn runnerArgs(arena: std.mem.Allocator, source: []const u8, dir: []const u8) ![]const []const u8 {
    const key = "// digital-runner: ";
    var out: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = line[key.len..];
        var words = std.mem.tokenizeAny(u8, rest, " \t");
        const first = words.next() orelse continue;
        if (std.mem.startsWith(u8, first, "--std=") or std.mem.startsWith(u8, first, "--event-budget=")) {
            try out.append(arena, first);
        } else if (std.mem.eql(u8, first, "--libmap")) {
            try out.appendSlice(arena, &.{ first, try std.fs.path.join(arena, &.{ dir, words.next() orelse return error.BadDirective }) });
        } else if (std.mem.eql(u8, first, "-L")) {
            try out.appendSlice(arena, &.{ first, words.next() orelse return error.BadDirective });
        } else if (std.mem.eql(u8, first, "files")) {
            while (words.next()) |f| try files.append(arena, try std.fs.path.join(arena, &.{ dir, f }));
        }
    }
    try out.appendSlice(arena, files.items);
    return out.items;
}

/// Whether a `.v` is a digital transcript case: it has a golden or opts into
/// the digital reject runner. Anything else is support material.
pub fn caseSelected(has_golden: bool, source: []const u8) bool {
    return has_golden or negative(source);
}

/// Match a normal digital diagnostic exit, not a signal, successful program,
/// empty/bare reject, or unrelated failure. Every declared pattern must match.
pub fn rejectionMatches(source: []const u8, exit_code: u8, stderr: []const u8) bool {
    if (exit_code != 1 or std.mem.indexOf(u8, stderr, "error[") == null) return false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var count: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        var fields = std.mem.tokenizeAny(u8, line[3..], " \t\r");
        const key = fields.next() orelse continue;
        if (!std.mem.eql(u8, key, "reject")) continue;
        const pattern = std.mem.trim(u8, fields.rest(), " \t\r");
        if (pattern.len == 0) return false;
        var diagnostics = std.mem.splitScalar(u8, stderr, '\n');
        var found = false;
        while (diagnostics.next()) |diagnostic_raw| {
            const diagnostic = std.mem.trim(u8, diagnostic_raw, " \t\r");
            if (std.mem.startsWith(u8, diagnostic, "error[") and
                std.mem.indexOf(u8, diagnostic, pattern) != null) found = true;
        }
        if (!found) return false;
        count += 1;
    }
    return count != 0;
}

/// `//! xfail <reason>` on a digital case: the reason, "" for a bare marker,
/// null when there is none. The verdict algebra is `judge`'s: a failing case
/// is XFAIL, a passing one is an XPASS FAIL.
pub fn xfailReason(source: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        const rest = std.mem.trimStart(u8, line[3..], " \t");
        if (!std.mem.startsWith(u8, rest, "xfail")) continue;
        const tail = rest["xfail".len..];
        if (tail.len != 0 and tail[0] != ' ' and tail[0] != '\t') continue;
        return std.mem.trim(u8, tail, " \t");
    }
    return null;
}

/// Optional warning obligations on a successful digital transcript. Match
/// actual diagnostic headers, never source excerpts or arbitrary stderr text.
/// A positive still needs its exact stdout oracle and a successful exit.
pub fn warningsMatch(source: []const u8, stderr: []const u8) bool {
    var diagnostics = std.mem.splitScalar(u8, stderr, '\n');
    while (diagnostics.next()) |raw| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, raw, " \t\r"), "error[")) return false;
    }
    const prefix = "// digital-runner: warning";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const suffix = line[prefix.len..];
        if (suffix.len != 0 and suffix[0] != ' ' and suffix[0] != '\t') continue;
        const pattern = std.mem.trim(u8, suffix, " \t\r");
        if (pattern.len == 0) return false;
        diagnostics.reset();
        var found = false;
        while (diagnostics.next()) |diagnostic_raw| {
            const diagnostic = std.mem.trim(u8, diagnostic_raw, " \t\r");
            if (std.mem.startsWith(u8, diagnostic, "warning[") and
                std.mem.indexOf(u8, diagnostic, pattern) != null) found = true;
        }
        if (!found) return false;
    }
    return true;
}

/// `//! expect vcd <produced> == <golden>`: `vera --run` of the `.v` writes
/// `<produced>` (relative to the run's working directory), which must equal
/// `<golden>` (relative to the fixture) once both are normalised (`vcdTokens`).
pub const VcdExpect = struct { produced: []const u8, golden: []const u8 };

/// Returns the fixture's `//! expect vcd` line, slices into `source`. Null when
/// there is none, or it is malformed (then `tb.parse` fails it as unknown).
pub fn vcdExpectation(source: []const u8) ?VcdExpect {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        var f = std.mem.tokenizeAny(u8, line[3..], " \t\r");
        if (!std.mem.eql(u8, f.next() orelse continue, "expect")) continue;
        if (!std.mem.eql(u8, f.next() orelse return null, "vcd")) continue;
        const produced = f.next() orelse return null;
        if (!std.mem.eql(u8, f.next() orelse return null, "==")) return null;
        const golden = f.next() orelse return null;
        if (f.next() != null) return null;
        return .{ .produced = produced, .golden = golden };
    }
    return null;
}

/// IEEE 1364-2005 §18.2: "The dump file is structured in a free format. White
/// space is used to separate commands", so a VCD is compared as TOKENS. The
/// `$date` (§18.2.3.2) and `$version` (§18.2.3.8) sections are required
/// header (§18.2.1) whose text is the writer's own, so each compares as its
/// keyword and `$end` (present, body dropped); a golden writes `$date $end`.
/// A `$comment` (§18.2.3.1) is what §18.1.5's dump limit inserts, so its body
/// compares, joined by single spaces into one token. The `$timescale` body is
/// joined with nothing, so `1 ns` and `1ns` are one token.
pub fn vcdTokens(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| {
        const header = std.mem.eql(u8, tok, "$date") or std.mem.eql(u8, tok, "$version");
        const comment = std.mem.eql(u8, tok, "$comment");
        const join = std.mem.eql(u8, tok, "$timescale");
        if (!header and !comment and !join) {
            try out.append(arena, tok);
            continue;
        }
        var body: std.ArrayList(u8) = .empty;
        while (it.next()) |t| {
            if (std.mem.eql(u8, t, "$end")) break;
            if (comment and body.items.len != 0) try body.append(arena, ' ');
            try body.appendSlice(arena, t);
        }
        if (header) try out.appendSlice(arena, &.{ tok, "$end" }) else try out.appendSlice(arena, &.{ tok, body.items, "$end" });
    }
    return out.items;
}

test "VCD comparison keeps the header sections, the comments, and joins the timescale" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try vcdTokens(a, "$date today $end $version VerA 1.0\n$end\n$timescale 1 ns $end\n$comment x  y $end #0 0! b1 \" ");
    const want = [_][]const u8{ "$date", "$end", "$version", "$end", "$timescale", "1ns", "$end", "$comment", "x y", "$end", "#0", "0!", "b1", "\"" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
    const e = vcdExpectation("// prose\n//! expect vcd a.vcd == ../g/a.vcd\n").?;
    try std.testing.expectEqualStrings("a.vcd", e.produced);
    try std.testing.expectEqualStrings("../g/a.vcd", e.golden);
    try std.testing.expect(vcdExpectation("//! expect vcd a.vcd ../g/a.vcd\n") == null);
    try std.testing.expect(vcdExpectation("//! lrm 9.1\n") == null);
}

test "digital positive warning obligations inspect diagnostic headers" {
    const source = "// digital-runner: warning W1150\n// digital-runner: warning memory data count\n";
    const warning = "warning[W1150]: memory data count differs from requested range\n";
    try std.testing.expect(warningsMatch(source, warning));
    try std.testing.expect(!warningsMatch(source, ""));
    try std.testing.expect(!warningsMatch(source, "warning[W1150]: unrelated\n12 | // memory data count\n"));
    try std.testing.expect(!warningsMatch(source, "memory data count W1150\n"));
    try std.testing.expect(!warningsMatch(source, "error[W1150]: memory data count\n"));
    try std.testing.expect(!warningsMatch("// digital-runner: warning\n", warning));
    try std.testing.expect(warningsMatch("module ordinary; endmodule", warning));
    try std.testing.expect(!warningsMatch("module ordinary; endmodule", "error[E1100]: failure\n"));
    try std.testing.expect(warningsMatch("initial $display(\"// digital-runner: warning absent\");", ""));
    try std.testing.expect(warningsMatch("// digital-runner: warningish comment", ""));
}

test "digital negative routing is explicit and diagnostics are specific" {
    const source = "// digital-runner: reject\n//! reject E1100\n//! reject no arguments\n";
    try std.testing.expect(negative(source));
    try std.testing.expect(!negative("//! reject E1100\n"));
    try std.testing.expect(!negative("initial $display(\"// digital-runner: reject\");"));
    const diagnostic = "error[E1100]: function takes no arguments";
    try std.testing.expect(rejectionMatches(source, 1, diagnostic));
    try std.testing.expect(!rejectionMatches(source, 0, diagnostic));
    try std.testing.expect(!rejectionMatches(source, 255, diagnostic));
    try std.testing.expect(!rejectionMatches(source, 1, "error[E1100]: unsupported real"));
    try std.testing.expect(!rejectionMatches(source, 1, "error[E1100]: unrelated failure\n12 | // no arguments\n"));
    try std.testing.expect(rejectionMatches(source, 1, "error[E1100]: first failure\nerror[E0001]: no arguments\n"));
    try std.testing.expect(!rejectionMatches("//! reject\n", 1, diagnostic));
    try std.testing.expect(!rejectionMatches("//! lrm 9.10\n", 1, diagnostic));
    try std.testing.expect(rejectionMatches("//! reject E1100\n//! xfail pending\n", 1, diagnostic));
    try std.testing.expectEqualStrings("pending", xfailReason("//! reject E1100\n  //! xfail pending \n").?);
    try std.testing.expectEqualStrings("", xfailReason("//! xfail\n").?);
    try std.testing.expect(xfailReason("// xfail prose\n//! xfailed\n") == null);
    try std.testing.expect(caseSelected(false, source));
    try std.testing.expect(caseSelected(true, "module positive; endmodule"));
    try std.testing.expect(!caseSelected(false, "//! reject E1100\n"));
    try std.testing.expect(!caseSelected(false, "module support; endmodule"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const args = try runnerArgs(arena.allocator(), "// digital-runner: reject\n// digital-runner: files a.v b.vg\n// digital-runner: --std=1364-2005\n// digital-runner: --libmap m/lib.map\n// digital-runner: -L gateLib\n", "d");
    const want = [_][]const u8{ "--std=1364-2005", "--libmap", "d/m/lib.map", "-L", "gateLib", "d/a.v", "d/b.vg" };
    try std.testing.expectEqual(want.len, args.len);
    for (want, args) |w, a| try std.testing.expectEqualStrings(w, a);
    try std.testing.expectEqual(0, (try runnerArgs(arena.allocator(), "// digital-runner: reject\n", "d")).len);
}
