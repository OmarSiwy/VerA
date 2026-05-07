//! Source units in, stable emitted declaration names out, so `zig
//! -fincremental` (which tracks declarations by name) re-analyzes only units
//! that changed. Also fixes the canonical unit order and sanitizes identifiers
//! (§2.7, §2.8.1) injectively. No name may be built from a MIR or `nodes`
//! index: inserting one source line would renumber every later name.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const opdb = @import("ir").op;

/// Identifies one emitted source unit: §5.6 contribution or §4.5 analog operator.
pub const Unit = struct {
    role: Role,
    /// Contribution: access function plus node pair (`I_drain_source`).
    /// Operator: its callee name. An ordinal appears only via `disambig`.
    ///
    /// Must already be a `_`-joined path of `sanitize`d leaves: `unitName`
    /// does not re-sanitize, because sanitizing a joined path is not
    /// injective ({"a_b","c"} and {"a","b_c"} would collide).
    target: []const u8,
    /// Nonzero only for the later members of a (role, target) collision group.
    disambig: u16 = 0,
    /// The operator `call` a `.analog_op` unit was enumerated from; `.none`
    /// for every other role.
    inst: Mir.Inst = .none,
    /// That call's operator (`Mir.callee.opKind`); `.none` for every other role.
    op: opdb.OpKind = .none,
};

/// What an emitted unit is. `display` and `common` are never produced by
/// `enumerateUnits`: an entry in the canonical order would desynchronize
/// `proof.Verdict.unit_modes`. codegen names them directly with `unitName`.
pub const Role = enum {
    /// A §5.6 contribution.
    analog,
    /// A §4.5 analog operator, §5.10 event or §9.17 kernel-control call.
    analog_op,
    /// §9.4 the module's display tasks, chained into one root by
    /// `Lower.finishDisplays`; one per module.
    display,
    /// The declaration holding subexpressions shared by several units.
    common,
};

/// Longest name a caller must provide room for. Overflow is `error.NoSpaceLeft`,
/// never truncation. Sized so no legal model reaches it: two §2.7 identifiers
/// of 1024 characters at 3x sanitization, plus separators and a role.
pub const max_name_len = 8192;

// Sanitization: Verilog-A identifier to Zig identifier, injectively.
// §2.8.1 escaped identifiers carry arbitrary printable bytes, and `_` is the
// separator alphabet. The escape marker is `Z`, so a sanitized leaf never
// begins, ends or doubles a `_`, and every name has a unique parse:
//
//   name  := leaf "__" role "__" leaf-path ("__" digits)?
//   leaf  := [A-Za-z0-9_]*   with no "__", no leading/trailing "_"
//   escape:= "Z" hex hex     (so a literal 'Z' is escaped to "Z5a")

fn hexDigit(v: u8) u8 {
    return "0123456789abcdef"[v & 0xf];
}

/// Appends `name` to `b`, escaping every byte that would break injectivity or
/// Zig's identifier grammar.
fn sanitizeInto(b: *Buf, name: []const u8) error{NoSpaceLeft}!void {
    for (name, 0..) |c, i| {
        const bare = switch (c) {
            'a'...'z', 'A'...'Y' => true,
            // A Zig identifier may not start with a digit.
            '0'...'9' => i != 0,
            // Interior `_` survives (`v_ds`); a leading, trailing or doubled
            // one is escaped so no leaf produces or touches the separator.
            '_' => i != 0 and i + 1 < name.len and name[i + 1] != '_',
            else => false, // 'Z' included: it is the escape marker
        };
        if (bare) {
            try b.byte(c);
        } else {
            try b.byte('Z');
            try b.byte(hexDigit(c >> 4));
            try b.byte(hexDigit(c));
        }
    }
}

/// Sanitizes one identifier leaf into `buf` and returns the written prefix.
/// Injective: distinct inputs give distinct outputs. Every source name must
/// pass through this before it enters an emitted declaration name. Needs up to
/// `3 * name.len + 1` bytes; fails with `error.NoSpaceLeft` otherwise.
pub fn sanitize(buf: []u8, name: []const u8) error{NoSpaceLeft}![]const u8 {
    var b: Buf = .{ .buf = buf };
    try sanitizeInto(&b, name);
    // Annex B does not reserve Zig keywords or primitives (`pub`, `u32`), so
    // a model may use them as names. A trailing `Z` marks them rather than
    // `@"..."`, because consumers interpolate names bare (`model.{s}`); it
    // stays injective, since `sanitizeInto` emits `Z` only as `Z<hi><lo>`.
    const leaf = b.buf[0..b.len];
    if (std.zig.Token.keywords.has(leaf) or std.zig.primitives.isPrimitive(leaf)) try b.byte('Z');
    return b.buf[0..b.len];
}

test "sanitize escapes Zig keywords and primitives" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("pubZ", try sanitize(&buf, "pub"));
    try std.testing.expectEqualStrings("fnZ", try sanitize(&buf, "fn"));
    try std.testing.expectEqualStrings("errorZ", try sanitize(&buf, "error"));
    try std.testing.expectEqualStrings("f64Z", try sanitize(&buf, "f64"));
    // Non-reserved names are untouched.
    try std.testing.expectEqualStrings("vth", try sanitize(&buf, "vth"));
    try std.testing.expectEqualStrings("public", try sanitize(&buf, "public"));
    // Injectivity at the boundary: a source name that already ends in `Z` has
    // that `Z` escaped, so it cannot collide with the keyword marker.
    const pubZ_src = try sanitize(&buf, "pubZ");
    try std.testing.expect(!std.mem.eql(u8, "pubZ", pubZ_src));
}

/// Bounded appender over a caller buffer, so `unitName` never allocates.
const Buf = struct {
    buf: []u8,
    len: usize = 0,

    fn byte(b: *Buf, c: u8) error{NoSpaceLeft}!void {
        if (b.len == b.buf.len) return error.NoSpaceLeft;
        b.buf[b.len] = c;
        b.len += 1;
    }

    fn str(b: *Buf, s: []const u8) error{NoSpaceLeft}!void {
        if (b.len + s.len > b.buf.len) return error.NoSpaceLeft;
        @memcpy(b.buf[b.len..][0..s.len], s);
        b.len += s.len;
    }
};

/// Writes `<module>__<role>__<target>[__<disambig>]` into `buf` and returns it.
/// No part is a position, and the suffix appears only for `disambig > 0`, so
/// a collision group's first member keeps its name when another is added.
/// Fails with `error.NoSpaceLeft` past `buf.len` (`max_name_len` suffices).
pub fn unitName(
    buf: []u8,
    module: []const u8,
    unit: Unit,
) error{NoSpaceLeft}![]const u8 {
    var b: Buf = .{ .buf = buf };
    try sanitizeInto(&b, module);
    try b.str("__");
    try b.str(@tagName(unit.role)); // closed set, already a legal leaf
    try b.str("__");
    try b.str(unit.target); // pre-sanitized, see Unit.target
    if (unit.disambig != 0) {
        try b.str("__");
        const printed = try std.fmt.bufPrint(b.buf[b.len..], "{d}", .{unit.disambig});
        b.len += printed.len;
    }
    return b.buf[0..b.len];
}

/// Returns the module's units in the canonical order, which
/// `proof.Verdict.unit_modes` and codegen's declaration emission both index:
///
///   1. every `Lowered.contributions[i]` in table order, role `.analog`
///      (§5.6.7 indirect statements are never deduped, so several to one
///      branch form a collision group);
///   2. every §4.5 operator, §5.10 event and §9.17 kernel-control `call`, in
///      `Mir.blockIter` then `Mir.blockInsts` order, role `.analog_op`. The
///      §9.17 `$bound_step`/`$discontinuity` calls come last, in that order.
///
/// The order is a pure function of the source; `disambig` counts 0, 1, 2 in
/// it. The slice and every `Unit.target` are allocated from `gpa`, which
/// should be the per-compilation arena.
pub fn enumerateUnits(gpa: std.mem.Allocator, mir: *const Mir, lowered: *const Lowered) ![]Unit {
    var units: std.ArrayList(Unit) = .empty;
    errdefer units.deinit(gpa);
    var scratch: [max_name_len]u8 = undefined;

    // (1) §5.6 contributions: node names, never `nodes` rows.
    for (lowered.contributions.items) |c| {
        var b: Buf = .{ .buf = &scratch };
        // §4.4: the two access roles are closed even when a user nature renames
        // the access identifier (§3.6.1.4), so V/I is the canonical spelling.
        try b.str(switch (c.access) {
            .potential => "V",
            .flow => "I",
        });
        for ([2]u16{ c.hi, c.lo }) |n| {
            try b.byte('_');
            // §1.3.1.1 ground is not a `nodes` row. "0" cannot collide: a real
            // net's leading digit is escaped.
            if (n == Lower.ground) try b.byte('0') else try sanitizeInto(&b, lowered.nodeName(n));
        }
        try units.append(gpa, .{ .role = .analog, .target = try gpa.dupe(u8, b.buf[0..b.len]) });
    }

    // (2) §4.5 stateful operators. `Instance` state fields are keyed on these
    // names, so adding an unrelated operator must not rename existing state.
    var blocks = mir.blockIter();
    while (blocks.next()) |block| {
        var insts = mir.blockInsts(block);
        while (insts.next()) |inst| {
            if (mir.instOp(inst) != .call) continue;
            const callee = mir.instData(inst).call.callee;
            // An `OpKind` other than `.none` owns state or a monitored event.
            const k = Mir.callee.opKind(callee);
            if (k == .none) continue;
            // The `$` of a §9.17 task is dropped rather than escaped to `Z24`.
            // No collision: every other target here is an annex B keyword.
            const spelling = @tagName(callee);
            const bare = if (spelling[0] == '$') spelling[1..] else spelling;
            // A synthetic variant `op$variant` (`absdelay$quad`) shares `op`'s
            // state, so it takes `op`'s name: hosts find state by field name.
            const op_name = bare[0 .. std.mem.indexOfScalar(u8, bare, '$') orelse bare.len];
            const t = try gpa.dupe(u8, try sanitize(&scratch, op_name));
            try units.append(gpa, .{ .role = .analog_op, .target = t, .inst = inst, .op = k });
        }
    }

    assignDisambig(units.items);
    return units.toOwnedSlice(gpa);
}

/// Asserts the canonical order `enumerateUnits` documents: (a) proof rated
/// exactly the contribution units, (b) they are the prefix of `units`, and
/// (c) only `.analog_op` units follow. A violation would make codegen read
/// another unit's float mode, and `.optimized` on an unproven unit is
/// undefined behaviour in release builds. Debug-only, O(units).
pub fn assertCanonicalOrder(units: []const Unit, lowered: *const Lowered, unit_modes_len: usize) void {
    const n_contrib = lowered.contributions.items.len;
    std.debug.assert(unit_modes_len == n_contrib); // (a)
    std.debug.assert(units.len >= n_contrib);
    for (units[0..n_contrib]) |u| std.debug.assert(u.role == .analog); // (b)
    for (units[n_contrib..]) |u| std.debug.assert(u.role == .analog_op); // (c)
}

/// Sets each unit's `disambig` to the number of earlier units sharing its
/// (role, target).
// ponytail: O(n²) over units. A module has tens of them; switch to a
// StringHashMap keyed on role++target if a model ever shows up with thousands.
fn assignDisambig(units: []Unit) void {
    for (units, 0..) |*u, i| {
        var n: u16 = 0;
        for (units[0..i]) |prev| {
            if (prev.role == u.role and std.mem.eql(u8, prev.target, u.target)) n += 1;
        }
        u.disambig = n;
    }
}

// ponytail: an operator's target is its callee name, so N `ddt`s in one module
// take disambig 0..N-1 and inserting one renames the later ones. Qualifying the
// target with the enclosing contribution needs lower.zig to record that link.

const Ast = @import("frontend").Ast;
const diag = @import("diag");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    mir: Mir = .{ .name = "mymod" },
    file: Ast.SourceFile = .empty,
    /// Naming is tested on a hand-built `Lowered` with no source behind it.
    lowered: Lowered = undefined,

    fn init(f: *Fixture) !void {
        f.lowered = .{ .file = &f.file };
        const a = f.arena.allocator();
        for ([_][]const u8{ "drain", "gate", "source" }) |n|
            try f.lowered.nodes.append(a, .{ .name = n, .kind = .net, .disc = "", .dir = .unspecified });
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }

    fn names(f: *Fixture, out: *std.ArrayList([]const u8)) !void {
        const a = f.arena.allocator();
        const units = try enumerateUnits(a, &f.mir, &f.lowered);
        for (units) |u| {
            var buf: [max_name_len]u8 = undefined;
            try out.append(a, try a.dupe(u8, try unitName(&buf, f.mir.name, u)));
        }
    }
};

test "inserting a contribution for a different target renames nothing" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();

    // I(drain,source) and V(gate,gnd)
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 2 });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 1, .lo = Lower.ground });

    var before: std.ArrayList([]const u8) = .empty;
    try f.names(&before);
    try std.testing.expectEqualStrings("mymod__analog__I_drain_source", before.items[0]);
    try std.testing.expectEqualStrings("mymod__analog__V_gate_0", before.items[1]);

    // Every pre-existing name must come back byte-identical.
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 1, .lo = 2 });

    var after: std.ArrayList([]const u8) = .empty;
    try f.names(&after);
    try std.testing.expectEqual(@as(usize, 3), after.items.len);
    for (before.items, after.items[0..before.items.len]) |b, x| {
        try std.testing.expectEqualStrings(b, x);
    }
    try std.testing.expectEqualStrings("mymod__analog__I_gate_source", after.items[2]);
}

test "same-target collisions take group-local ordinals, first stays bare" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();

    _ = try f.mir.addBlock(a);
    const ddt = try f.mir.internString(a, "ddt");
    const transition = try f.mir.internString(a, "transition");
    const ln = try f.mir.internString(a, "ln"); // not an analog operator: no unit
    _ = try f.mir.emitCall(a, .entry, ddt, &.{});
    _ = try f.mir.emitCall(a, .entry, ln, &.{});
    _ = try f.mir.emitCall(a, .entry, transition, &.{});
    _ = try f.mir.emitCall(a, .entry, ddt, &.{});

    var got: std.ArrayList([]const u8) = .empty;
    try f.names(&got);
    try std.testing.expectEqual(@as(usize, 3), got.items.len);
    try std.testing.expectEqualStrings("mymod__analog_op__ddt", got.items[0]);
    try std.testing.expectEqualStrings("mymod__analog_op__transition", got.items[1]);
    try std.testing.expectEqualStrings("mymod__analog_op__ddt__1", got.items[2]);
}

test "sanitize is injective on the names that would otherwise collide" {
    var b0: [max_name_len]u8 = undefined;
    var b1: [max_name_len]u8 = undefined;

    // readable common case survives untouched
    try std.testing.expectEqualStrings("v_ds", try sanitize(&b0, "v_ds"));

    // pairs that a naive `_`-join would map together
    const pairs = [_][2][]const u8{
        .{ "a_b", "a" }, // vs a later leaf "b"
        .{ "_a", "Za" },
        .{ "a_", "a" },
        .{ "a__b", "a_b" },
        .{ "bus[0]", "bus0" },
        .{ "Z", "Z5a" },
        .{ "0", "Z30" },
    };
    for (pairs) |p| {
        const s0 = try sanitize(&b0, p[0]);
        const s1 = try sanitize(&b1, p[1]);
        try std.testing.expect(!std.mem.eql(u8, s0, s1));
        // and no sanitized leaf may contain the "__" separator or touch its edges
        try std.testing.expect(std.mem.indexOf(u8, s0, "__") == null);
        try std.testing.expect(s0[0] != '_' and s0[s0.len - 1] != '_');
    }
}

test "names never overflow silently" {
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, unitName(&small, "a_very_long_module", .{
        .role = .analog,
        .target = "I_a_b",
    }));
}

test "§9.17 kernel-control units drop the `$` and stay after the operator units" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();

    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 2 });
    _ = try f.mir.addBlock(a);
    const ddt = try f.mir.internString(a, "ddt");
    const bs = try f.mir.internString(a, "$bound_step");
    const disc = try f.mir.internString(a, "$discontinuity");
    _ = try f.mir.emitCall(a, .entry, ddt, &.{});
    // `Lower.finishKernelCtl` appends these last, in this order.
    _ = try f.mir.emitCall(a, .entry, bs, &.{});
    _ = try f.mir.emitCall(a, .entry, disc, &.{});

    var got: std.ArrayList([]const u8) = .empty;
    try f.names(&got);
    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    // Contributions first: proof indexes `unit_modes` by this order.
    try std.testing.expectEqualStrings("mymod__analog__I_drain_source", got.items[0]);
    try std.testing.expectEqualStrings("mymod__analog_op__ddt", got.items[1]);
    // The `$` is dropped, not escaped to `Z24`.
    try std.testing.expectEqualStrings("mymod__analog_op__bound_step", got.items[2]);
    try std.testing.expectEqualStrings("mymod__analog_op__discontinuity", got.items[3]);
}
