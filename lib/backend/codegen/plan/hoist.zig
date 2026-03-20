//! The temperature hoist: which values depend only on the model card and
//! `$temperature`, and so move out of `eval` into `Instance.pc__<k>` fields
//! that `precompute` fills once per card/temperature.
//!
//! PURE (ARCHITECTURE.md §2): `plan` takes the lowered module and the job list
//! and returns a `Precompute`. Kept apart from every other plan on purpose:
//! the setup split (`impl-codegen` 142a857) replaces this file, and the
//! emitter-side prefix cache in `codegen/hoist.zig`, as one unit.
//!
//! LRM clauses this file's code cites: §4.6.4, §9.10, §9.15, §9.19.
//!
//! Cut verbatim from `codegen/hoist.zig` (`pcClass`, `paramOnlyCall`,
//! `pcConsider`, `planPrecompute`); only the receiver changed.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lower = @import("ir").Lower;
const Input = @import("input.zig").Input;
const Job = @import("jobs.zig").Job;
const plan_args = @import("args.zig");
const Display = plan_args.Display;

pub const Error = std.mem.Allocator.Error;
const none_u32 = std.math.maxInt(u32);

/// Temperature/parameter-only hoist (ngspice's `<dev>temp` phase, done once
/// instead of per eval).
pub const Precompute = struct {
    /// Value → `Instance.pc__<k>` field index, or `none_u32`. Every body but
    /// `precompute` reads a mapped value as a leaf (unit_plan `pcHoisted`).
    idx: []u32 = &.{},
    /// The mapped roots, in field order — what `emitPrecompute` writes.
    vals: []Mir.Value = &.{},
};

// ------------------------------------------- the temperature hoist ----
//
// MEASURED MOTIVE (ARPice callgrind, tran/fourbitadder): log 8.2% +
// pow 6.4% + exp 5.1% + ldexp/frexp ~3% of TOTAL instructions sit inside
// BJT eval — `pow(t/tnom, xti)`-class factors recomputed per instance per
// Newton iteration. ngspice computes them once (bjttemp.c) at setup/.temp;
// the host already has the hook (`precompute` runs at finalize and on
// every reprep — parameter writes and setTemp both route through it).
//
// A value is HOISTABLE when its transitive inputs are only parameters,
// literals and `$temperature` — no §4.4 probe, no `$abstime`, no stateful
// operator, no phi (a loop-carried value is not one value) — AND every op
// on the way down is one the precompute body can re-spell with the exact
// VALUE semantics the in-eval rendering had (see `pscalar_txt`). A
// hoist ROOT is such a value, containing at least one libm-class op
// (anything cheaper is not the measured cost), read at least once from
// OUTSIDE the hoistable region. Roots become `Instance.pc__<k>` fields.

/// Three-state memo for `pcClass` — `unknown` doubles as the visit mark.
pub const PcCls = enum(u8) { unknown, no, yes };

/// Is `v0` computable from parameters/literals/`$temperature` alone,
/// through ops the precompute body can mirror bit-exactly? Fills the memo
/// at the rv-RESOLVED index. Recursion depth is the expression depth;
/// the cap is a sound fail-safe (false never hoists).
pub fn pcClass(self: Input, cls: []PcCls, v0: Mir.Value, depth: u32) bool {
    const v = self.an.rv(v0);
    const i = @intFromEnum(v);
    switch (cls[i]) {
        .yes => return true,
        .no => return false,
        .unknown => {},
    }
    if (depth > 2048) return false;
    const ok: bool = switch (self.mir.valueDef(v)) {
        .undef, .float_const, .int_const => true,
        .str_const, .block_param => false,
        .param_ref => |p| Analysis.tyOfParam(self.lowered.params.items[p].ty) != .str,
        .inst_result => |inst| blk: {
            const row = self.mir.instRow(inst);
            switch (row.op) {
                .call => {
                    const d = self.mir.instData(inst).call;
                    // §9.19's two queries answer from the model card alone:
                    // `renderSysCall` spells `$param_given` as the Model
                    // field `<p>__given` and `$port_connected` as the
                    // literal 1, so both are as parameter-only as a
                    // `param_ref` and precompute can re-spell them
                    // character for character. Excluding them cost the
                    // whole `<dev>temp` phase of every machine-converted
                    // SPICE model: `if ($param_given(tox)) cox = …` guards
                    // the ladder, an unhoistable condition makes the
                    // select unhoistable, and one unhoistable select
                    // strands every value downstream of it in the core.
                    break :blk paramOnlyCall(self, d);
                },
                // A phi is not one value; the path latches read Instance
                // state `updateState`/commit have not written yet at
                // precompute time.
                .phi, .branch, .jump, .path_prev, .path_acc => break :blk false,
                .select => {
                    const d = self.mir.instData(inst).ternary;
                    break :blk pcClass(self, cls, d.cond, depth + 1) and
                        pcClass(self, cls, d.then_val, depth + 1) and
                        pcClass(self, cls, d.else_val, depth + 1);
                },
                else => switch (Mir.opClass(row.op)) { // else: every other opcode is a pure op, decided by its operands
                    .unary => break :blk pcClass(self, cls, @enumFromInt(row.a), depth + 1),
                    .binary => break :blk pcClass(self, cls, @enumFromInt(row.a), depth + 1) and
                        pcClass(self, cls, @enumFromInt(row.b), depth + 1),
                    .ternary, .phi, .branch, .jump, .call => break :blk false,
                },
            }
        },
    };
    cls[i] = if (ok) .yes else .no;
    return ok;
}

/// §9.15 `$simparam` with a literal name other than `iteration` (Table 9-27):
/// `call.zig` renders it as a Model field (`tnom`, which the host writes with
/// the card) or a constant (the rest, including the homotopy knobs VerA folds
/// today), so it is as parameter-only as a `param_ref`. `iteration` reads
/// `inst.newton_iteration`, which moves every Newton step. A fallback argument
/// renders through `f64Expr`, which reads Model alone.
fn simparamFixed(self: Input, d: anytype) bool {
    const nm = plan_args.strArg(self, d.args, 0) orelse return false;
    return !Lower.simparamIsRuntime(nm);
}

/// A call as parameter-only as a `param_ref` — `pcClass`'s and `hpPureInst`'s
/// one answer. §9.10 `$temperature` and the argument-free `$vt` read the
/// temperature the host sets with the card; §9.19's two queries and a
/// non-iteration `$simparam` are above.
pub fn paramOnlyCall(self: Input, d: anytype) bool {
    return switch (d.callee) {
        .@"$temperature", .@"$param_given", .@"$port_connected" => true,
        .@"$vt" => d.args.len == 0,
        .@"$simparam" => simparamFixed(self, d),
        else => false, // else: an ALLOWLIST — every other callee reads the solve, the time or state the host moves, until shown otherwise
    };
}

/// One use of `o` from outside the hoistable region: make it a root if it
/// qualifies. Ascending value order later turns `root` into `idx`.
fn pcConsider(self: Input, cls: []PcCls, root: []bool, o: Mir.Value) void {
    const v = self.an.rv(o);
    const i = @intFromEnum(v);
    if (cls[i] != .yes) return;
    if (root[i]) return;
    if (self.an.vty[i] != .real) return;
    // A tree that folds to a literal costs nothing per eval already.
    if (self.an.foldConst(v, 0, false) != null) return;
    // ponytail: every non-folding instruction qualifies, so a libm-cost
    // walk cannot change the answer. Add a cost model only if this policy changes.
    if (self.mir.valueDef(v) != .inst_result) return;
    root[i] = true;
}

pub fn plan(self: Input, jobs: []const Job, display: Display) Error!Precompute {
    const a = self.arena;
    const nv = self.an.nv;
    var out: Precompute = .{};
    out.idx = try a.alloc(u32, nv);
    @memset(out.idx, none_u32);

    const cls = try a.alloc(PcCls, nv);
    @memset(cls, .unknown);
    for (0..nv) |i| _ = pcClass(self, cls, @enumFromInt(@as(u32, @intCast(i))), 0);

    const root = try a.alloc(bool, nv);
    @memset(root, false);

    // Every use from a consumer that is NOT itself hoistable marks a root:
    // instruction operands (a branch/call/phi result is never hoistable, so
    // conditions, operator inputs and phi copies are covered by the same
    // rule), plus the unit targets the residual returns.
    for (0..self.mir.insts.len) |ii| {
        const inst: Mir.Inst = @enumFromInt(@as(u32, @intCast(ii)));
        const res = self.mir.instResult(inst);
        if (res != .undef and cls[@intFromEnum(self.an.rv(res))] == .yes) continue;
        switch (self.mir.instData(inst)) {
            .unary => |d| pcConsider(self, cls, root, d.operand),
            .binary => |d| {
                pcConsider(self, cls, root, d.lhs);
                pcConsider(self, cls, root, d.rhs);
            },
            .ternary => |d| {
                pcConsider(self, cls, root, d.cond);
                pcConsider(self, cls, root, d.then_val);
                pcConsider(self, cls, root, d.else_val);
            },
            .branch => |d| pcConsider(self, cls, root, d.cond),
            .call => |d| for (d.args, 0..) |arg, k| {
                // Control arguments render host-side through `f64Expr`
                // (never a pc read), so a field for one would go unread.
                if (plan_args.callArgIsValue(d.callee, k, display))
                    pcConsider(self, cls, root, arg);
            },
            .phi => |d| {
                var k: u32 = 0;
                while (k < d.count) : (k += 1)
                    pcConsider(self, cls, root, self.mir.phiPair(inst, k).value);
            },
            .jump => {},
        }
    }
    for (jobs) |job| {
        // §4.6.4 EXCEPT the noise PSDs. Hoisting one moves it out of the
        // `if (r > 0)` that declared it and evaluates it unconditionally —
        // `4kT/0` — where staying a core live-out gives it the zero seed
        // that is the right answer for a generator this bias does not have.
        // See `buildJobs`'s `$noise` queue.
        if (job.kind == .noise) continue;
        pcConsider(self, cls, root, job.target);
    }

    var vals: std.ArrayList(Mir.Value) = .empty;
    for (0..nv) |i| {
        if (!root[i]) continue;
        out.idx[i] = @intCast(vals.items.len);
        try vals.append(a, @enumFromInt(@as(u32, @intCast(i))));
    }
    out.vals = vals.items;
    return out;
}

const Fixture = @import("fixture.zig").Fixture;

test "a libm value of parameters and $temperature is hoisted; one reading a probe is not" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    try f.lowered.params.append(a, .{ .name = "is", .ty = .real, .default = .f_one });
    const is = try f.mir.addParamRef(a, 0);
    const t = try f.call("$temperature", &.{});
    const et = try f.mir.emit(a, .entry, .exp, &.{t}); // exp($temperature)
    const k = try f.mir.emit(a, .entry, .fmul, &.{ is, et }); // is * exp(T)
    const i = try f.mir.emit(a, .entry, .fmul, &.{ k, try f.probe(0) }); // … * V(a)
    const an = try f.analysis();
    const jobs = [_]Job{.{ .kind = .resist, .target = i, .mode = .strict, .comment = "" }};

    const pc = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &jobs, .drop);
    // `k` is read from outside the hoistable region (by `i`), so it is the
    // root; `et` is only read inside it, and `i` reads the solve.
    try std.testing.expectEqualSlices(Mir.Value, &.{k}, pc.vals);
    try std.testing.expectEqual(@as(u32, 0), pc.idx[@intFromEnum(k)]);
    try std.testing.expectEqual(none_u32, pc.idx[@intFromEnum(i)]);
}
