//! `vera` — one binary, both frontends.
//!
//! The language is chosen by the input file's extension, which is the same rule
//! a build loop already applies when it walks a directory of models:
//!
//!   .va                 → the Verilog-A engine   (src/va/main.zig)
//!   .v .sv .vhd .vhdl   → the Verilog family     (src/vf/main.zig)
//!
//! This file ONLY routes. Each frontend keeps its own flag set and its own
//! usage text, because they are not the same tool wearing two hats: the
//! Verilog-A side has a diagnostic catalogue, lint levels and four emit
//! targets, while the Verilog side is a translator with two flags. Merging the
//! flag sets would mean inventing errors for the combinations that do not
//! exist.
//!
//!   vera FILE.va [options]     see `vera --help`
//!   vera FILE.v  [options]     see `vera --help x.v`

const std = @import("std");
const va = @import("va/main.zig");
const vf = @import("vf/main.zig");

pub fn main(init: std.process.Init) !u8 {
    var r: Router = .{};
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| r.feed(arg);

    return switch (r.result()) {
        .va => va.run(init),
        .vf => vf.run(init),
    };
}

const Frontend = enum { va, vf };

/// Flags whose NEXT argv entry is a value rather than the input file. Without
/// this list `vera -o out.v model.va` would route a Verilog-A compile to the
/// Verilog frontend on the strength of the OUTPUT name. `--expect-module=` and
/// friends are `=`-joined and so cannot be confused for a path.
const takes_value = [_][]const u8{
    "-o", "-I", "--explain", "--contract", "--dyn", "--work-dir", "--zig",
};

/// Streaming argv classifier. A struct rather than a loop inside `main` so the
/// routing rule — the part with the `-o` trap in it — is reachable from a test
/// without standing up a real `std.process.Init`.
const Router = struct {
    skip_next: bool = false,
    found: ?Frontend = null,

    fn feed(self: *Router, arg: []const u8) void {
        if (self.skip_next) {
            self.skip_next = false;
            return;
        }
        for (takes_value) |f| {
            if (std.mem.eql(u8, arg, f)) {
                self.skip_next = true;
                return;
            }
        }
        if (std.mem.startsWith(u8, arg, "-")) return;
        // FIRST positional with a known extension wins; a second input file is
        // that frontend's error to report, not ours to preempt.
        if (self.found == null) self.found = classify(arg);
    }

    /// Nothing recognizable on the command line — `--help`, `--explain W0650`,
    /// or a plain usage error. The Verilog-A frontend owns all three, and its
    /// usage text is the one worth printing.
    fn result(self: Router) Frontend {
        return self.found orelse .va;
    }
};

fn classify(path: []const u8) ?Frontend {
    const e = std.fs.path.extension(path);
    if (std.mem.eql(u8, e, ".va")) return .va;
    for ([_][]const u8{ ".v", ".sv", ".vhd", ".vhdl" }) |v| {
        if (std.mem.eql(u8, e, v)) return .vf;
    }
    return null;
}

test "routing picks the frontend from the input file, not from -o" {
    const cases = [_]struct { argv: []const []const u8, want: Frontend }{
        .{ .argv = &.{"model.va"}, .want = .va },
        .{ .argv = &.{"gates.v"}, .want = .vf },
        .{ .argv = &.{"cpu.sv"}, .want = .vf },
        .{ .argv = &.{"alu.vhdl"}, .want = .vf },
        // The trap: an output path that looks like a Verilog source.
        .{ .argv = &.{ "-o", "out.v", "model.va" }, .want = .va },
        .{ .argv = &.{ "--emit-zig", "-o", "d.zig", "diode.va" }, .want = .va },
        // Value-taking flags must not swallow the real input either.
        .{ .argv = &.{ "--contract", "src/contract.zig", "bsim.va" }, .want = .va },
        .{ .argv = &.{ "-I", "inc", "and2.v" }, .want = .vf },
        // No input, or an unknown extension: fall back to the frontend that
        // owns --help and --explain.
        .{ .argv = &.{"--help"}, .want = .va },
        .{ .argv = &.{ "--explain", "W0650" }, .want = .va },
        .{ .argv = &.{"notes.txt"}, .want = .va },
    };
    for (cases) |c| {
        var r: Router = .{};
        for (c.argv) |a| r.feed(a);
        try std.testing.expectEqual(c.want, r.result());
    }
}
