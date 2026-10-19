//! Unit analog-b's cross-cutting checks: the statement, contribution and
//! system-call lowering under every allocation failure, and the §4.6.4.6
//! noise coefficient and §5.6 per-`<+` lookups the hashed tables answer.
//!
//! LRM clauses this file's code cites: §1.3.1, §1.3.1.2, §4.6.4.6, §5.6.1.3,
//! §5.6.7.2.

const std = @import("std");
const Lower = @import("../lower.zig");
const Mir = @import("ir").Mir;

/// Sources that between them reach every file of the unit: a named block, a
/// case, an event with a timer, a display and a strobe, a `$bound_step`, a
/// `$limit` through a user limiter, a seeded distribution, a `$table_model`,
/// a filter, a noise source, an indirect branch and a contribution.
const oom_sources = [_][]const u8{
    \\module m(p, q, o);
    \\  inout p, q, o; electrical p, q, o;
    \\  parameter real g = 1.0;
    \\  real x, n;
    \\  integer s, k;
    \\  analog function real lim;
    \\    input vnew, vold; real vnew, vold;
    \\    lim = vnew;
    \\  endfunction
    \\  analog begin : blk
    \\    real y;
    \\    s = 7;
    \\    x = $rdist_uniform(s, 0.0, 1.0);
    \\    case (k) 0: y = 1.0; default: y = 2.0; endcase
    \\    @(timer(0, 1n)) k = k + 1;
    \\    @(cross(V(p) - 0.5, 1)) $strobe("x=%g", x);
    \\    $display("y=%g", y);
    \\    $bound_step(1n);
    \\    n = white_noise(1e-20, "th");
    \\    I(p) <+ g * $limit(V(p), lim) + 3.0 * n + ddt(1p * V(p));
    \\    I(q) <+ $table_model(V(q), '{0.0, 1.0}, '{0.0, 2.0}, "1LL") + transition(y, 0, 1n);
    \\    V(o) : V(q) == 0.0;
    \\  end
    \\endmodule
    ,
};

/// Lowers `src` with every buffer, the SSA builder's tables included, from
/// `gpa`; a failed allocation must come back as `error.OutOfMemory`.
fn lowerAll(gpa: std.mem.Allocator, src: []const u8) !void {
    var h: Lower.Harness = undefined;
    try h.init(gpa, src);
    defer h.deinit();
    h.low.builder.map = gpa;
    _ = try h.lower() orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
}

test "lower (analog-b): every allocation failure unwinds as OutOfMemory and leaks nothing" {
    for (oom_sources) |src| try std.testing.checkAllAllocationFailures(std.testing.allocator, lowerAll, .{src});
}

/// The one noise row of contribution 0 of `body`, lowered in a module with
/// electrical `p`, `q` and real variables `n`, `x`.
fn noiseRow(h: *Lower.Harness, body: []const u8) !Lower.NoiseSrc {
    const src = try std.testing.allocator.print(
        \\module m(p, q);
        \\  inout p, q; electrical p, q;
        \\  real n, x;
        \\  analog begin
        \\{s}
        \\  end
        \\endmodule
    , .{body});
    defer std.testing.allocator.free(src);
    try h.init(std.testing.allocator, src);
    const out = (try h.lower()) orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
    const srcs = out.contributions.items[0].noise_srcs;
    try std.testing.expectEqual(@as(usize, 1), srcs.len);
    return srcs[0];
}

fn constOf(mir: *const Mir, v: Mir.Value) ?f64 {
    return switch (mir.valueDef(mir.resolveAlias(v))) {
        .float_const => |x| x,
        .inst_result, .int_const, .undef, .str_const, .param_ref, .block_param => null,
    };
}

test "§4.6.4.6 noise coefficient: the factor, its §1.3.1.2 sign, and the shapes with none" {
    const Want = union(enum) { factor: f64, nonlinear, runtime };
    const cases = [_]struct { body: []const u8, want: Want }{
        .{ .body = "n = white_noise(1); I(p) <+ 3.0 * n;", .want = .{ .factor = 3.0 } },
        // `I(q,p) <+ c*n` drives the canonical (p,q) branch with -c.
        .{ .body = "n = white_noise(1); I(q, p) <+ 3.0 * n;", .want = .{ .factor = -3.0 } },
        .{ .body = "n = white_noise(1); I(p) <+ n / 4.0 + V(p);", .want = .runtime },
        // The generator squared has no single factor.
        .{ .body = "n = white_noise(1); I(p) <+ n * n;", .want = .nonlinear },
        // A diamond: the coefficient is the phi of the arms' factors.
        .{ .body = "n = white_noise(1); if (V(q) > 0) x = 2.0 * n; else x = 5.0 * n; I(p) <+ x;", .want = .runtime },
    };
    for (cases) |c| {
        var h: Lower.Harness = undefined;
        defer h.deinit();
        const row = try noiseRow(&h, c.body);
        switch (c.want) {
            .factor => |f| {
                try std.testing.expect(!row.nonlinear);
                try std.testing.expectEqual(f, constOf(&h.mir, row.coeff).?);
            },
            .nonlinear => {
                try std.testing.expect(row.nonlinear);
                try std.testing.expectEqual(Mir.Value.f_one, row.coeff);
            },
            .runtime => {
                try std.testing.expect(!row.nonlinear);
                try std.testing.expect(row.coeff != .f_zero);
                try std.testing.expectEqual(@as(?f64, null), constOf(&h.mir, row.coeff));
            },
        }
    }
}

test "§5.6 the per-`<+` lookups: indirect pairs, opposite quantities and probe pairs are unordered or per branch" {
    try Lower.expectBodies(&.{
        // §5.6.7.2 on the reversed pair: E0409 whichever spelling comes second.
        .{ .src = "analog begin V(p, q) : V(p) == 0.0; I(q, p) <+ 1e-6; end", .code = .E0409 },
        // §1.3.1: a contribution on the reversed spelling makes (p,q) a source.
        .{ .src = "analog begin x = V(p, q) + I(p, q); I(q, p) <+ x * 1m; end", .code = null },
    });
}

test "§5.6.1.3 a parallel named branch keeps what it retained" {
    // `I(b)` is another branch, so `V(a)` survives it; `I(a)` is the same
    // branch, so it discards what `V(a)` retained.
    const cases = [_]struct { flow: []const u8, kept: f64 }{
        .{ .flow = "b", .kept = 1.0 },
        .{ .flow = "a", .kept = 0.0 },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p, q);
            \\  inout p, q; electrical p, q;
            \\  branch (p, q) a, b;
            \\  analog begin
            \\    V(a) <+ 1.0;
            \\    I({s}) <+ 2.0;
            \\  end
            \\endmodule
        , .{c.flow});
        defer std.testing.allocator.free(src);
        var h: Lower.Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        const out = (try h.lower()) orelse {
            h.dump();
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(@as(usize, 2), out.contributions.items.len);
        // `wrote_val` is §5.6.1.3's retention flag: 1 kept, 0 discarded.
        try std.testing.expectEqual(c.kept, constOf(&h.mir, out.contributions.items[0].wrote_val).?);
    }
}

test "Clause 9 calls in expression position: the argument rules lowering judges" {
    try Lower.expectBodies(&.{
        // §9.5.1 Table 9-24: "rw" is no `type` form; "r+b" is.
        .{ .src = "analog begin iv = $fopen(\"o.txt\", \"rw\"); I(p) <+ iv; end", .code = .E0889 },
        .{ .src = "analog begin iv = $fopen(\"o.txt\", \"r+b\"); I(p) <+ iv * V(p); end", .code = null },
        // §9.5.1/§9.5.2: a descriptor is "a 32-bit integer".
        .{ .src = "analog begin iv = $feof(r); I(p) <+ iv; end", .code = .E0888 },
        // `$prev` takes exactly one argument.
        .{ .src = "analog begin x = $prev(V(p), 1.0); I(p) <+ x; end", .code = .E0809 },
        .{ .src = "analog begin x = $prev(V(p)); I(p) <+ x * V(p); end", .code = null },
        // §9.5.3: the string writers are tasks, with no value.
        .{ .src = "analog begin iv = $swrite(sv, \"a\"); I(p) <+ iv; end", .code = .E0813 },
        // §9.19: a port identifier, not a variable.
        .{ .src = "analog begin iv = $port_connected(x); I(p) <+ iv; end", .code = .E0822 },
        .{ .src = "analog begin iv = $port_connected(q); I(p) <+ iv * V(p); end", .code = null },
        // §9.15 Table 9-28's hierarchy rows fold here.
        .{ .src = "analog begin sv = $simparam$str(\"module\"); I(p) <+ V(p); end", .code = null },
        // §9.17.3: the first argument is an access function, and the second a
        // string or an analog function (a variable is neither, §2.8).
        .{ .src = "analog I(p) <+ $limit(x, \"pnjlim\", 0.025, 0.6);", .code = .E0891 },
        .{ .src = "analog I(p) <+ $limit(V(p), x);", .code = .E0891 },
        // §9.13.2: a degree of freedom is a count in the reference domain.
        .{ .src = "analog begin iv = $dist_chi_square(seed, 1.5); I(p) <+ iv; end", .code = .E0816 },
        .{ .src = "analog begin iv = $dist_chi_square(seed, 2); I(p) <+ iv * V(p); end", .code = null },
    });
}

/// Lowers `body` (as `expectBodies` does) with `tbl` written to `t.tbl` in a
/// fresh directory on the include path; null means it lowered clean.
fn tableVerdict(body: []const u8, tbl: []const u8) !?@import("diag").Code {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "t.tbl", .data = tbl });
    const dir = ".zig-cache/tmp/" ++ tmp.sub_path;
    const gpa = std.testing.allocator;
    const src = try gpa.print(
        \\module m(p, q);
        \\  inout p, q; electrical p, q;
        \\{s}
        \\endmodule
    , .{body});
    defer gpa.free(src);
    var h: Lower.Harness = undefined;
    try h.init(gpa, src);
    defer h.deinit();
    const dirs = [_][]const u8{dir};
    h.low.include_dirs = &dirs;
    if (try h.lower() != null) return null;
    return h.bag.at(0).code;
}

test "§9.21.1 data files and §4.6.4.3 noise_table files: the shared format" {
    const D = @import("diag").Code;
    const cases = [_]struct { body: []const u8, tbl: []const u8, want: ?D }{
        // Comments anywhere, blank lines, tabs and CRLF are all format.
        .{ .body = "analog I(p) <+ $table_model(V(p), \"t.tbl\");", .tbl = "# x y\n0 0\n\n1\t2 # end\r\n", .want = null },
        // Rows of unequal width are no data set: the first call's error, not
        // the compilation's (§9.21.1 "captured on the first call").
        .{ .body = "analog I(p) <+ $table_model(V(p), \"t.tbl\");", .tbl = "0 0\n1\n", .want = null },
        // A file of only comments holds no data set either.
        .{ .body = "analog I(p) <+ $table_model(V(p), \"t.tbl\");", .tbl = "# nothing\n\n", .want = null },
        // One input needs a dependent column too.
        .{ .body = "analog I(p) <+ $table_model(V(p), \"t.tbl\");", .tbl = "0\n1\n", .want = .E0815 },
        // Table 9-30 `I` spends a column on no dimension: three columns, one
        // input, the dependent is column 3.
        .{ .body = "analog I(p) <+ $table_model(V(p), \"t.tbl\", \"I,1LL;1\");", .tbl = "9 0 0\n9 1 2\n", .want = null },
        // Fewer sub-strings than dimensions: the rest keep `1LL`.
        .{ .body = "analog I(p) <+ $table_model(V(p), V(q), \"t.tbl\", \"1CC\");", .tbl = "0 0 0\n0 1 1\n1 0 1\n1 1 2\n", .want = null },
        // §4.6.4.3: pairs, one per line.
        .{ .body = "analog I(p) <+ noise_table(\"t.tbl\");", .tbl = "1 1e-20\n10 1e-21\n", .want = null },
        .{ .body = "analog I(p) <+ noise_table(\"t.tbl\");", .tbl = "1 1e-20 3\n", .want = .E0519 },
        .{ .body = "analog I(p) <+ noise_table(\"t.tbl\");", .tbl = "1 x\n", .want = .E0519 },
        .{ .body = "analog I(p) <+ noise_table(\"vera_no_such.tbl\");", .tbl = "", .want = .E0519 },
    };
    for (cases) |c| try std.testing.expectEqual(c.want, try tableVerdict(c.body, c.tbl));
}

test "§5.8.1 isStaticValue: a block or value judged static once stays judged, and nothing else is" {
    try Lower.expectBodies(&.{
        // The second `if` reuses the first's verdict on the entry chain, and
        // its own merge of two static arms is static too.
        .{ .src = "analog begin x = g; if (g > 0) x = 2 * g; if (x > 0) r = ddt(V(p)); I(p) <+ r; end", .code = null },
        // A static walk first, then a merge one arm of which reads a probe:
        // the earlier verdicts must not leak into the dynamic one.
        .{ .src = "analog begin x = g; if (g > 0) x = 2 * g; if (x > 0) r = 1; if (V(q) > 0) x = V(p); if (x > 0) r = ddt(V(p)); I(p) <+ r; end", .code = .E0514 },
    });
}
