//! §4.6.3/§4.6.4 small-signal sources: lowered contributions -> `Noise`, the
//! flattened rows `noise_gens`, `noisePsd`, `ac_gens` and `acStim` are
//! emitted from, with §4.6.4.3/.4 tables folded and sorted. Refusals
//! (E0519/E0520) are recorded for `Gen.prepare` to report. Clauses:
//! §1.3.1.1, §4.6.3, §4.6.4, §4.6.4.1, §4.6.4.3, §4.6.4.4, §4.6.4.6.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lower;
const diag = @import("diag");
const Input = @import("input.zig").Input;

/// Every fallible call here fails only on allocation.
pub const Error = std.mem.Allocator.Error;

/// The small-signal plan: noise rows, folded tables, AC stimulus rows and
/// the refusals found on the way.
pub const Noise = struct {
    /// §4.6.4 `noise_gens` and `noisePsd`, one row each.
    rows: []NoiseRow = &.{},
    /// §4.6.4.3/.4 `noise_tables`, one entry per tabulated generator, folded
    /// and sorted. Position k is `rows[j].table == k`.
    tabs: []const []const [2]f64 = &.{},
    /// The same knots as `tabs`, in the same order, as MIR values, only for a
    /// table an A.8.2 `parameter_identifier` made model-dependent: `tabs`
    /// holds its declared defaults, and only this can state the card's. An
    /// empty slice is a table of literals. See `emitNoiseTablePoints`.
    tab_vals: []const []const [2]Mir.Value = &.{},
    /// §4.6.3 `ac_gens` and `acStim`, one row each. Same walk as `rows`,
    /// separated by `kind`: a stimulus is not a generator and must never
    /// reach `noise_gens`.
    ac_rows: []NoiseRow = &.{},
    /// The §4.6.4 export VerA will not write, as the message the generated
    /// `@compileError` carries. The first one wins; the diagnostics carry the
    /// rest.
    fatal: ?[]const u8 = null,
    /// Every refusal, in the order found, for the caller to report.
    refusals: std.ArrayList(Refusal) = .empty,

    /// One recorded E0519/E0520, for the caller to report at `tok`.
    pub const Refusal = struct { code: diag.Code, tok: u32, msg: []const u8 };
};

/// One row of `noise_gens` and of the `noisePsd` result. The two tables are
/// positional in each other (`PsdTerm` k belongs to `noise_gens[k]`), so
/// they are built once here.
pub const NoiseRow = struct {
    row: u16,
    col: u16,
    kind: Lower.NoiseKind,
    /// §4.6.4.6 dense generator id: rows sharing it are one generator.
    source: usize,
    /// §4.6.4.1/.2 the PSD itself: `S(f) = pwr` for white, `pwr/f^exp` for
    /// flicker. rv-resolved, so `.f_zero` means "no generator at this bias".
    /// Both `.f_zero` on a §4.6.4.3/.4 row, whose PSD is `table` instead.
    pwr: Mir.Value,
    exp: Mir.Value,
    /// §4.6.4.3/.4 index into `Noise.tabs`, null on a parametric row.
    table: ?u16 = null,
    /// §4.6.4.1/.2/.3 the source's label, empty when unnamed. See
    /// `Lower.NoiseSrc.name` for why it never merges rows.
    name: []const u8 = "",
    /// §4.6.4.6 the factor this branch applies to the generator, rv-resolved
    /// like `pwr`. `.f_zero` means the source never reached a contributed
    /// value, which cannot happen through `planNoise` and is read as 1.
    coeff: Mir.Value,
};

/// Flattens every contribution's generator set into `Noise.rows`, in the
/// order `noise_gens` declares them; slices are owned by `self.arena`.
/// §4.6.4.6's shared-generator identity (`NoiseSrc.id`) is renamed densely in
/// first-seen order. §4.6.3's `ac_stim` arrives on the same set and leaves in
/// `ac_rows`: it is a stimulus, not a generator. Refusals are recorded, not
/// reported.
pub fn plan(self: Input) Error!Noise {
    var out: Noise = .{};
    var rows: std.ArrayList(NoiseRow) = .empty;
    var ac: std.ArrayList(NoiseRow) = .empty;
    var ids: std.ArrayList(u32) = .empty;
    var tabs: std.ArrayList([]const [2]f64) = .empty;
    var tab_vals: std.ArrayList([]const [2]Mir.Value) = .empty;
    for (self.lowered.contributions.items) |c| {
        if (c.noise_srcs.len == 0) continue;
        // §1.3.1.1 ground is not an unknown: a to-ground generator is
        // spelled row == col, and one on ground-ground has neither. The
        // residual may drop such a contribution silently (KCL at the
        // reference node is not an equation), but a vanishing generator is a
        // PSD the host will never ask for, so it is reported (E0520).
        if (c.hi == Lower.ground and c.lo == Lower.ground) {
            try refuseNoise(self, &out, .E0520, c.noise_srcs[0].tok, "this small-signal source is on a " ++
                "ground-ground branch, which has no row or column to export it in", .{});
            continue;
        }
        const row = if (c.hi != Lower.ground) c.hi else c.lo;
        const col = if (c.lo != Lower.ground) c.lo else row;
        for (c.noise_srcs) |s| {
            // §4.6.3 a stimulus has no PSD, no table and no §4.6.4.6
            // identity: one call is one source, and `addNoiseSrc` already
            // made two uses of one call one row. `source` is carried only so
            // the struct is shared; nothing reads it.
            if (s.kind == .ac_stim) {
                try ac.append(self.arena, .{
                    .row = row,
                    .col = col,
                    .kind = s.kind,
                    .source = 0,
                    .pwr = self.an.rv(s.pwr), // mag
                    .exp = self.an.rv(s.exp), // phase, radians
                    .name = s.name, // analysis_name
                    .coeff = if (s.coeff == .f_zero) .f_one else self.an.rv(s.coeff),
                });
                continue;
            }
            const seen = for (ids.items, 0..) |v, i| {
                if (v == s.id) break i;
            } else null;
            // §4.6.4.3/.4 the table, before the row: a generator VerA
            // cannot state gets no row, and the device is refused either
            // way. §4.6.4.6's shared generator shares its table too: one
            // call is one generator, so folding it twice would export the
            // same points under two indices.
            const table: ?u16 = switch (s.kind) {
                .thermal, .flicker, .ac_stim => null,
                .table, .table_log => if (seen) |i| rows_table: {
                    for (rows.items) |r| {
                        if (r.source == i and r.table != null) break :rows_table r.table;
                    }
                    break :rows_table (try planNoiseTable(self, &out, &tabs, &tab_vals, s)) orelse continue;
                } else (try planNoiseTable(self, &out, &tabs, &tab_vals, s)) orelse continue,
            };
            const sid = seen orelse blk: {
                try ids.append(self.arena, s.id);
                break :blk ids.items.len - 1;
            };
            try rows.append(self.arena, .{
                .row = row,
                .col = col,
                .kind = s.kind,
                .source = sid,
                .pwr = self.an.rv(s.pwr),
                .exp = self.an.rv(s.exp),
                .table = table,
                .name = s.name,
                .coeff = if (s.coeff == .f_zero) .f_one else self.an.rv(s.coeff),
            });
        }
    }
    out.rows = rows.items;
    out.tabs = tabs.items;
    out.tab_vals = tab_vals.items;
    out.ac_rows = ac.items;
    return out;
}

/// §4.6.4.3/.4 folds one `noise_table`/`noise_table_log` argument into a
/// sorted `(frequency, power)` table appended to `tabs`, and returns its
/// index, or null after recording an E0519 refusal.
///
/// All four of A.8.2's `noise_table_input_arg` spellings land here. Three are
/// literals by now: the assignment pattern, a file name ("shall be constant",
/// so `Lower.readNoiseTableFile` already flattened it) and a `[msb:lsb]`
/// slice of a parameter. The fourth, an array parameter, is a table the model
/// card owns: `tabs` gets the declared defaults (all a comptime `noise_tables`
/// can hold) and `tab_vals` gets the knots as MIR values, which
/// `emitNoiseTablePoints` renders over `Model` so a card override moves them.
/// Folding the default alone would silently ignore the override (E0515's
/// trap).
///
/// §4.6.4.3 lets the simulator sort ("shall internally sort the pairs into
/// ascending frequency if required"); sorting here gives the host an
/// invariant. Uniqueness ("Each frequency value must be unique") cannot be
/// repaired by sorting, so a repeat is an error. A card can defeat both at run
/// time: the generated accessor re-sorts, and uniqueness becomes the host's
/// precondition (`contract.NoiseTable`).
fn planNoiseTable(
    self: Input,
    out: *Noise,
    tabs: *std.ArrayList([]const [2]f64),
    tab_vals: *std.ArrayList([]const [2]Mir.Value),
    s: Lower.NoiseSrc,
) Error!?u16 {
    const vals = s.table;
    if (vals.len == 0) {
        try refuseNoise(self, out, .E0519, s.tok, "the argument is not a vector of " ++
            "(frequency, power) pairs", .{});
        return null;
    }
    if (vals.len % 2 != 0) {
        try refuseNoise(self, out, .E0519, s.tok, "the table has {d} values, which is not " ++
            "a whole number of (frequency, power) pairs", .{vals.len});
        return null;
    }
    // One array of both halves, so the sort permutes the values and the
    // defaults together: `noise_tables[k]` and `noiseTablePoints`'s k-th pair
    // must be the same knot.
    const Knot = struct { f: f64, p: f64, fv: Mir.Value, pv: Mir.Value };
    const knots = try self.arena.alloc(Knot, vals.len / 2);
    var parametric = false;
    for (knots, 0..) |*k, i| {
        const fv = vals[2 * i];
        const pv = vals[2 * i + 1];
        // `resolve_params = false` first, so "is this knot a literal?" is
        // answered before "what is it by default?". A table with no
        // parameter in it must not gain an accessor, because that would
        // oblige every host of the device to read one.
        const lit = self.an.foldConst(fv, false) != null and
            self.an.foldConst(pv, false) != null;
        const f = self.an.foldConst(fv, true);
        const pwr = self.an.foldConst(pv, true);
        if (f == null or pwr == null) {
            try refuseNoise(self, out, .E0519, s.tok, "the table has no value at compile " ++
                "time: a knot is computed during the solve, and 4.6.4.3's input is " ++
                "a vector, a file or a parameter", .{});
            return null;
        }
        if (!lit) parametric = true;
        k.* = .{ .f = f.?.f, .p = pwr.?.f, .fv = fv, .pv = pv };
    }
    std.mem.sort(Knot, knots, {}, struct {
        fn lt(_: void, x: Knot, y: Knot) bool {
            return x.f < y.f;
        }
    }.lt);
    const pts = try self.arena.alloc([2]f64, knots.len);
    for (knots, pts) |k, *p| p.* = .{ k.f, k.p };
    for (pts, 0..) |p, i| {
        if (!(p[0] > 0) or !std.math.isFinite(p[0])) {
            try refuseNoise(self, out, .E0519, s.tok, "frequency {d} is not a positive " ++
                "number of hertz", .{p[0]});
            return null;
        }
        if (!(p[1] >= 0) or !std.math.isFinite(p[1])) {
            try refuseNoise(self, out, .E0519, s.tok, "power {d} is not a non-negative " ++
                "spectral density", .{p[1]});
            return null;
        }
        // §4.6.4.4 interpolates log(power), and log(0) is not a point on
        // the line the clause's own formula draws.
        if (s.kind == .table_log and p[1] == 0) {
            try refuseNoise(self, out, .E0519, s.tok, "noise_table_log interpolates " ++
                "log(power), so a zero power at {d} Hz has no logarithm", .{p[0]});
            return null;
        }
        if (i != 0 and pts[i - 1][0] == p[0]) {
            try refuseNoise(self, out, .E0519, s.tok, "frequency {d} Hz appears twice, and " ++
                "LRM 4.6.4.3 requires each frequency value to be unique", .{p[0]});
            return null;
        }
    }
    try tabs.append(self.arena, pts);
    if (parametric) {
        const mvs = try self.arena.alloc([2]Mir.Value, knots.len);
        for (knots, mvs) |k, *m| m.* = .{ k.fv, k.pv };
        // Positional against `tabs`, so a constant table ahead of this one
        // still occupies its index.
        while (tab_vals.items.len + 1 < tabs.items.len) try tab_vals.append(self.arena, &.{});
        try tab_vals.append(self.arena, mvs);
    }
    return @intCast(tabs.items.len - 1);
}

/// Records one §4.6.4 export VerA refuses, for `Gen.prepare` to report the
/// way E0515 reports a control argument it cannot resolve: a source-level
/// diagnostic plus a generated `@compileError`, so a caller with no
/// diagnostic bag still cannot build a device whose noise table quietly lost
/// a generator. The first refusal also sets `fatal`.
fn refuseNoise(
    self: Input,
    out: *Noise,
    code: diag.Code,
    tok: u32,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    const msg = try self.arena.print(fmt, args);
    try out.refusals.append(self.arena, .{ .code = code, .tok = tok, .msg = msg });
    if (out.fatal == null)
        out.fatal = try self.arena.print("LRM 4.6.4: {s}", .{msg});
}

/// Returns `v` as a compile-time f64, or null when only the core can answer.
pub fn psdConst(mir: *const Mir, v: Mir.Value) ?f64 {
    return switch (mir.valueDef(v)) {
        .float_const => |x| x,
        .int_const => |x| @floatFromInt(x),
        .undef, .str_const, .param_ref, .block_param, .inst_result => null,
    };
}

const Fixture = @import("fixture.zig").Fixture;

test "a noise table is sorted, and a repeated frequency is refused" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    // noise_table({1e3, 2, 10, 4}) on I(a,b): stored ascending.
    const good = [_]Mir.Value{
        try f.mir.addFloatConst(a, 1e3), try f.mir.addFloatConst(a, 2),
        try f.mir.addFloatConst(a, 10),  try f.mir.addFloatConst(a, 4),
    };
    // noise_table({5, 1, 5, 2}) on I(b): 5 Hz twice.
    const dup = [_]Mir.Value{
        try f.mir.addFloatConst(a, 5), try f.mir.addFloatConst(a, 1),
        try f.mir.addFloatConst(a, 5), try f.mir.addFloatConst(a, 2),
    };
    const srcs0 = [_]Lower.NoiseSrc{.{ .kind = .table, .table = &good, .id = 1 }};
    const srcs1 = [_]Lower.NoiseSrc{.{ .kind = .table, .table = &dup, .id = 2 }};
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .noise_srcs = &srcs0 });
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 1, .lo = Lower.ground, .noise_srcs = &srcs1 });
    const an = try f.analysis();

    const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered });
    try std.testing.expectEqual(@as(usize, 1), n.rows.len);
    try std.testing.expectEqual(@as(?u16, 0), n.rows[0].table);
    try std.testing.expectEqualSlices([2]f64, &.{ .{ 10, 4 }, .{ 1e3, 2 } }, n.tabs[0]);
    try std.testing.expectEqual(@as(usize, 1), n.refusals.items.len);
    try std.testing.expectEqual(diag.Code.E0519, n.refusals.items[0].code);
    try std.testing.expect(std.mem.startsWith(u8, n.fatal.?, "LRM 4.6.4: frequency 5 Hz appears twice"));
}
