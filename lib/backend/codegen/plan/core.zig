//! The shared core: values several units read, computed once per eval.
//!
//! In: the job list. Out: the core's live-out set, its field order, the
//! §5.6.1.2 path latches and §5.10 held values that read it, its name, and the
//! float mode it compiles in (the part of eval/q all units share).
//!
//! PURE (ARCHITECTURE.md §2): `plan` takes the lowered module and the jobs and
//! returns a `Core`. No `*Gen`, no writer.
//!
//! LRM clauses this file's code cites: §4.3, §4.5, §5.6.1.2, §5.9, §5.10, §9.4.
//!
//! Was `codegen/common.zig` (`planCommon`); only the receiver changed.

const std = @import("std");
const Mir = @import("ir").Mir;
const proof = @import("ir").proof;
const naming = @import("../../naming.zig");
const Input = @import("input.zig").Input;
const Job = @import("jobs.zig").Job;
const float_mode = @import("../float/mode.zig");
const plan_setup = @import("setup.zig");
const callee = Mir.callee;

pub const Error = std.mem.Allocator.Error || error{NameTooLong};
const none_u32 = std.math.maxInt(u32);

pub const Core = struct {
    /// Position of this Value in the core's returned struct, or `none_u32`.
    /// Only the unit TARGETS cross the declaration boundary; every one of the
    /// ~22 000 subexpressions behind them stays a local of the core.
    lo_idx: []u32 = &.{},
    /// The returned values, in job order — `lo_idx` is the index into this.
    lo_vals: []Mir.Value = &.{},
    /// §5.6.1.2 path-integrated reactive latches: rv-resolved operand of
    /// every `path_prev`/`path_acc`, each family deduplicated (CSE-shared
    /// sites share a latch — same committed value). `*_lo[k]` is the
    /// operand's slot in `lo_vals`. `path_prev` renders `S.con(inst.pb__k)`
    /// (operand at the last accepted solve), `path_acc` renders
    /// `S.con(inst.pq__k)` (sum of committed operands — the charge base).
    /// `updateState` STAGES both operands into `wb__/wq__` once per Newton
    /// iterate; `stateCtl(.commit)` — operating-point exit and transient
    /// accepted step — latches `pb = wb`, `pq += wq` and zeroes `wq` so a
    /// stray double commit adds 0, not a doubled increment.
    prev_vals: []Mir.Value = &.{},
    prev_lo: []u32 = &.{},
    acc_vals: []Mir.Value = &.{},
    acc_lo: []u32 = &.{},
    /// Core field index holding each held variable's end-of-block value, or
    /// `none_u32` when it folded to `.f_zero`.
    held_idx: []u32 = &.{},
    /// `<module>__common__core`, or empty for a model with no targets at all.
    name: []const u8 = "",
    /// §4.3 the STRICTEST mode of every job the core serves — `float/mode.zig`.
    mode: proof.FloatMode = .optimized,
    /// §5.10 per Value: a store into a held array that nothing `eval`/`q`
    /// returns can observe — `heldOnly`. Empty when none.
    held_only: []bool = &.{},
    /// Per Value: something `eval`/`q` returns reads it (`heldOnly`'s
    /// marking). Empty when the device stores into no held array.
    eval_need: []bool = &.{},
};

// ---------------------------------------------------- the shared core ----
//
// WHY THIS EXISTS. `emitUnit` renders the full backward slice of one
// `Mir.Value` through a CFG all the units share, so ~105 units each emit the
// same core: `hisimhv_va` measured 1 220 929 emitted values across 58 units
// of which 22 214 distinct values appear in two or more — 190 MB of output
// from 614 K of source.
// CORPUS: `hisimhv_va` is one of the 38 foundry models in the ARPice host
// repo (`../ARPice/src/devices/models`; `VERA_MODELS` overrides the path).
// NOT vendored here and no fixture is within three orders of magnitude of
// it, so every number in this block needs that checkout to re-measure.
//
// Recomputing the shared subexpressions per unit was the ORIGINAL shape and
// it was deliberate: an anonymous subexpression was never promoted to a
// hidden shared decl, so that every unit stayed independently skippable by
// `zig -fincremental`. That justification does not hold, and naming.zig's
// header already concedes the same point for NAMED units — `zig` tracks a
// declaration by name and dirties its consumers correctly when it changes.
// A shared declaration is therefore BETTER for incrementality, not worse —
// one declaration to re-analyse instead of 58 copies of it — and the units'
// own tails stay independently skippable either way.
//
// WHY ONE DECLARATION AND NOT ONE PER VALUE. The obvious shape — a function
// per shared value, calling the functions of its operands — is wrong, and
// measurably so: the shared values form a DAG, so a value reachable by two
// paths would be recomputed once per path, and the cost is exponential in
// the DAG depth. The values have to be computed ONCE and PASSED.
//
// WHY *EVERY* TARGET IS IN IT, and not just the ≥K-shared subexpressions.
// Hoisting a shared region and leaving a per-unit tail behind was measured,
// and it is the wrong shape twice over:
//
//   SIZE. The tails are not tails. `emitCode` walks the whole reachable CFG
//   for every unit, so each one re-materialises every merge block and every
//   §5.9 loop whether or not it computes anything in them. On `hisimhv_va`
//   the 58 tails were 378 634 lines of which 10 830 — 2.86% — were
//   arithmetic; the median tail was 6 007 lines containing 6 operations.
//   Folding the targets into the core deletes all of it: 440 124 → 59 986
//   lines, 23.73 → 3.25 MB. The merged body is the same size as the core
//   already was (60 061 lines), because the tails carried no information.
//
//   RUNTIME. Every tail opened with `const c = core(...)`, so one `eval`
//   evaluated the core once per contribution — 40 times on `hisimhv_va`,
//   30 on `vbic13_4t`. LLVM does NOT recover this: built -OReleaseFast it
//   inlines all 30 `vbic13_4t` tails into the caller and still emits 30
//   calls to the core (`objdump | grep -c core` = 30), because it cannot
//   prove a 60 000-line two-pointer function `readonly willreturn`. Merging
//   is therefore a runtime fix, not a size optimisation: one core per
//   `eval`, one per `q`.
//   CORPUS: `vbic13_4t` is the public VBIC 1.3 four-terminal reference
//   Verilog-A, from the same 38-model set — likewise not vendored here.
//
// WHAT IS LOST. The per-unit `@setFloatMode` — see `Core.mode`. Nothing
// else: `contract.zig` exposes only `eval`/`q`, and engine.zig (:511, :534,
// :1216) always evaluates the whole residual, so a unit was never
// independently callable in the first place.

/// Decide what the one emitted body returns: every unit target, deduplicated
/// and in job order.
///
/// Job order — contributions in source order, then §4.5 operator inputs,
/// then §9.4 display — is what makes `f<k>` insert-tolerant in the same
/// sense `naming.zig` makes declaration names insert-tolerant: adding a
/// contribution at the end of a module appends fields, it does not renumber
/// them.
pub fn plan(in: Input, jobs: []const Job) Error!Core {
    const a = in.arena;
    var self: Core = .{};
    self.lo_idx = try a.alloc(u32, in.an.nv);
    @memset(self.lo_idx, none_u32);

    var vals: std.ArrayList(Mir.Value) = .empty;
    for (jobs) |job| {
        // §9.4 the display root stays OUT: the core runs once per `eval`,
        // and printing once per Newton iteration is exactly what
        // `emitDisplay` exists to prevent. It keeps its own declaration and
        // reads the core like the units used to.
        if (job.kind == .display) continue;
        const v = in.an.rv(job.target);
        if (v == .f_zero) continue; // an operator with no input; rendered inline
        if (self.lo_idx[@intFromEnum(v)] != none_u32) continue;
        self.lo_idx[@intFromEnum(v)] = @intCast(vals.items.len);
        try vals.append(a, v);
    }
    // Path-latch operands ride the same live-out queue: `updateState`'s
    // single core(R) sweep is where their staged values come from.
    {
        var pv: std.ArrayList(Mir.Value) = .empty;
        var pl: std.ArrayList(u32) = .empty;
        var qv: std.ArrayList(Mir.Value) = .empty;
        var ql: std.ArrayList(u32) = .empty;
        for (0..in.mir.insts.len) |ii| {
            const row = in.mir.insts.get(ii);
            if (row.op != .path_prev and row.op != .path_acc) continue;
            const fam_v = if (row.op == .path_prev) &pv else &qv;
            const fam_l = if (row.op == .path_prev) &pl else &ql;
            const v = in.an.rv(@enumFromInt(row.a));
            // ponytail: keep first-seen order with the stdlib membership scan.
            if (std.mem.indexOfScalar(Mir.Value, fam_v.items, v) != null) continue;
            if (self.lo_idx[@intFromEnum(v)] == none_u32) {
                self.lo_idx[@intFromEnum(v)] = @intCast(vals.items.len);
                try vals.append(a, v);
            }
            try fam_v.append(a, v);
            try fam_l.append(a, self.lo_idx[@intFromEnum(v)]);
        }
        self.prev_vals = pv.items;
        self.prev_lo = pl.items;
        self.acc_vals = qv.items;
        self.acc_lo = ql.items;
    }
    self.mode = float_mode.coreMode(jobs);
    self.lo_vals = vals.items;
    // §5.10 which core field each held variable's write-back reads. Done
    // here rather than by scanning `jobs` in `emitStateMachine`, because
    // `lo_idx` is only meaningful once every job has been folded in.
    self.held_idx = try a.alloc(u32, in.lowered.held_vars.items.len);
    for (in.lowered.held_vars.items, 0..) |h, i| {
        const v = in.an.rv(h.final);
        self.held_idx[i] = if (v == .f_zero) none_u32 else self.lo_idx[@intFromEnum(v)];
    }
    if (self.lo_vals.len == 0) return self;
    try heldOnly(in, jobs, &self);

    var buf: [naming.max_name_len]u8 = undefined;
    const n = naming.unitName(&buf, in.mir.name, .{
        .role = .common,
        // A single declaration, so the target is a fixed word rather than a
        // key: naming.zig's insert-tolerance is about the NAME not moving,
        // and this one cannot.
        .target = "core",
    }) catch return error.NameTooLong;
    self.name = try a.dupe(u8, n);
    return self;
}

/// §5.10 the stores into a held array that nothing `eval`/`q` returns can
/// observe — true per store result Value, empty when there is none. Those
/// callers read the contributions, the charges, the retention flags and the
/// table captures (`evalRoot`); the held arrays' end-of-block values are
/// `updateState`'s and `acceptQ`'s. So their instantiation of the core skips
/// the stores (`held = false`), and a copy-on-write held array
/// (`render.cow`) is then never copied: coupled_ltra's and ltra's
/// accepted-point history append made every Newton iterate copy 147 KB and
/// 327 KB of history in.
///
/// Aggressive dead-code marking (Cytron et al.): a value is needed when an
/// eval root, an argument of a call that is not a §4.5/§5.10 operator (those
/// take effect only through their result), or an operand of a needed
/// instruction reads it — an array load reading its version and every
/// version before it — and so is the condition of every branch a needed
/// instruction or phi edge is control-dependent on. A store nothing needed
/// reads is skippable.
fn heldOnly(in: Input, jobs: []const Job, out: *Core) Error!void {
    const a = in.arena;
    const n: u32 = @intCast(in.mir.insts.len);
    var any = false;
    for (0..n) |ii| {
        const inst: Mir.Inst = @enumFromInt(@as(u32, @intCast(ii)));
        if (in.mir.instOp(inst) != .store) continue;
        const id = in.an.arrOf(in.mir.instResult(inst)) orelse continue;
        if (in.lowered.mem_arrays.items[id].held != none_u32) any = true;
    }
    if (!any) return;

    const cds = try plan_setup.controlDeps(in, try plan_setup.postDominators(in));
    var m: Mark = .{ .in = in, .cds = .{ .off = cds.off, .cd = cds.cd }, .need = try a.alloc(bool, in.an.nv), .blk = try a.alloc(bool, in.an.nb) };
    @memset(m.need, false);
    @memset(m.blk, false);
    for (jobs) |job| if (evalRoot(job.kind)) try m.mark(job.target);
    for (0..n) |ii| {
        const inst: Mir.Inst = @enumFromInt(@as(u32, @intCast(ii)));
        if (in.mir.instOp(inst) != .call) continue;
        const d = in.mir.instData(inst).call;
        if (callee.opKind(d.callee) != .none) continue;
        for (d.args) |x| try m.mark(x);
    }
    while (m.work.pop()) |v| try m.visit(v);

    const skip = try a.alloc(bool, in.an.nv);
    @memset(skip, false);
    var some = false;
    for (0..n) |ii| {
        const inst: Mir.Inst = @enumFromInt(@as(u32, @intCast(ii)));
        if (in.mir.instOp(inst) != .store) continue;
        const r = in.an.rv(in.mir.instResult(inst));
        const id = in.an.arrOf(r) orelse continue;
        if (in.lowered.mem_arrays.items[id].held == none_u32 or m.need[@intFromEnum(r)]) continue;
        skip[@intFromEnum(r)] = true;
        some = true;
    }
    out.eval_need = m.need;
    if (some) out.held_only = skip;
}

/// The jobs `eval`, `q` and `evalQ` read out of the core (`dispatch.zig`).
fn evalRoot(k: Job.Kind) bool {
    return switch (k) {
        .resist, .react, .retained, .table_effect => true,
        // `updateState`/`acceptQ`, `limit`, `seed`, `checkConvergence`,
        // `noisePsd`, `acStim`, the schedule and §9.4 display read these.
        .op_input, .ctrl, .held, .limit_arg, .limit_old, .reject_iteration, .noise, .ac_stim, .timer_period, .display => false,
    };
}

const Mark = struct {
    in: Input,
    cds: struct { off: []const u32, cd: []const plan_setup.Cd },
    need: []bool,
    blk: []bool,
    work: std.ArrayList(Mir.Value) = .empty,

    fn mark(m: *Mark, v0: Mir.Value) Error!void {
        const v = m.in.an.rv(v0);
        if (m.need[@intFromEnum(v)]) return;
        m.need[@intFromEnum(v)] = true;
        try m.work.append(m.in.arena, v);
    }

    /// Block `b` runs only as the branches it is control-dependent on say.
    fn block(m: *Mark, b: u32) Error!void {
        if (b >= m.blk.len or m.blk[b]) return;
        m.blk[b] = true;
        for (m.cds.cd[m.cds.off[b]..m.cds.off[b + 1]]) |c| {
            try m.mark(plan_setup.branchCond(m.in, c.a).?);
            try m.block(c.a);
        }
    }

    fn visit(m: *Mark, v: Mir.Value) Error!void {
        const def = m.in.mir.valueDef(v);
        if (def != .inst_result) return;
        const inst = def.inst_result;
        try m.block(m.in.an.def_block[@intFromEnum(v)]);
        switch (m.in.mir.instData(inst)) {
            .unary => |d| try m.mark(d.operand),
            .binary => |d| {
                try m.mark(d.lhs);
                try m.mark(d.rhs);
            },
            .ternary => |d| {
                try m.mark(d.cond);
                try m.mark(d.then_val);
                try m.mark(d.else_val);
            },
            .call => |d| for (d.args) |x| try m.mark(x),
            .load => |d| {
                try m.mark(d.arr);
                try m.mark(d.index);
            },
            .store => |d| {
                try m.mark(d.arr);
                try m.mark(d.index);
                try m.mark(d.value);
            },
            // A phi's value is its operand on the edge taken, and the edge
            // taken is its predecessor's branch.
            .phi => |d| for (0..d.count) |j| {
                const p = m.in.mir.phiPair(inst, @intCast(j));
                try m.mark(p.value);
                const pb: u32 = @intFromEnum(p.block);
                try m.block(pb);
                if (plan_setup.branchCond(m.in, pb)) |c| try m.mark(c);
            },
            .anew, .branch, .jump => {},
        }
    }
};

const Fixture = @import("fixture.zig").Fixture;

test "live-outs are deduplicated in job order; display stays out; held values index them" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const vb = try f.probe(1);
    try f.lowered.held_vars.append(a, .{ .name = "h", .ty = .real, .init = .f_zero, .seed = .f_zero, .final = vb });
    const an = try f.analysis();
    const jobs = [_]Job{
        .{ .kind = .resist, .target = vb, .mode = .optimized, .comment = "" },
        .{ .kind = .react, .target = va, .mode = .optimized, .comment = "" },
        .{ .kind = .held, .target = vb, .mode = .strict, .comment = "" }, // shared with job 0
        .{ .kind = .display, .target = va, .mode = .strict, .comment = "" },
    };

    const c = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &jobs);
    try std.testing.expectEqualSlices(Mir.Value, &.{ vb, va }, c.lo_vals);
    try std.testing.expectEqual(@as(u32, 0), c.lo_idx[@intFromEnum(vb)]);
    try std.testing.expectEqualSlices(u32, &.{0}, c.held_idx);
    // One `.strict` consumer makes the shared body strict (§4.3); the display
    // job is not a consumer.
    try std.testing.expectEqual(proof.FloatMode.strict, c.mode);
    try std.testing.expectEqualStrings("mymod__common__core", c.name);
}
