//! Solve invariance: lowered MIR -> `Sinv`, the values that are the same at
//! every Newton iterate and time point, so `setup` computes them once per
//! card, instance and temperature. `pruneHeld` drops the §3.2 held slots a
//! card cannot observe. The emitter half (setup roots, `pub fn setup`) is
//! `codegen/setup.zig`. Clauses: §2.9, §3.2, §4.4, §5.2.1, §5.6.1.2, §5.10,
//! §5.10.2, §9.10, §9.15, §9.19.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const Analysis = @import("ir").Analysis;
const Input = @import("input.zig").Input;
const plan_args = @import("args.zig");

/// Every fallible call here fails only on allocation.
pub const Error = std.mem.Allocator.Error;
const none_u32 = std.math.maxInt(u32);

/// The answer, per value, per block and per loop header.
pub const Sinv = struct {
    /// Value → solve-invariant.
    val: []bool = &.{},
    /// Block → placeable: `setup` may compute what it defines.
    blk: []bool = &.{},
    /// Loop header → a branch inside it is per-eval, so `setup` stops there.
    loop_varying: []bool = &.{},
    /// Value → the placeable block `setup` computes it in, for an invariant
    /// value whose own block is not placeable (`Scan.speculable`); `none_u32`
    /// for every other value. `moved`/`moved_off` list the same values per
    /// home block in ascending value order.
    home: []u32 = &.{},
    moved: []Mir.Value = &.{},
    moved_off: []u32 = &.{},

    /// The values `setup` computes at the end of block `b`.
    pub fn movedTo(s: Sinv, b: u32) []const Mir.Value {
        if (s.moved_off.len == 0) return &.{};
        return s.moved[s.moved_off[b]..s.moved_off[b + 1]];
    }
};

/// One control dependence: block B depends on the branch at `a` through its
/// `then` edge (`then == true`) or its `else` edge.
pub const Cd = struct { a: u32, then: bool };

/// §5.10.2 `initial_step` with no analysis list, or §5.2.1 `analog initial`:
/// the condition `setup` treats as true. A qualified `initial_step("tran")`
/// is not one: in DC it keeps its initializer, so it is not a card function.
fn initCond(in: Input, cond: Mir.Value) bool {
    const def = in.mir.valueDef(in.an.rv(cond));
    if (def != .inst_result or in.mir.instOp(def.inst_result) != .call) return false;
    const d = in.mir.instData(def.inst_result).call;
    return switch (d.callee) {
        .analog_initial => true,
        .initial_step => d.args.len == 0,
        else => false, // else: every other callee is not the §5.10.2 first-point flag
    };
}

/// Returns the condition of the `branch` ending block `bi`, or null when the
/// block ends otherwise.
pub fn branchCond(in: Input, bi: u32) ?Mir.Value {
    const t = in.an.term[bi];
    if (t == .none or in.mir.instOp(t) != .branch) return null;
    return in.mir.instData(t).branch.cond;
}

fn thenOf(in: Input, bi: u32) u32 {
    return @backingInt(in.mir.instData(in.an.term[bi]).branch.then_block);
}

fn elseOf(in: Input, bi: u32) u32 {
    return @backingInt(in.mir.instData(in.an.term[bi]).branch.else_block);
}

/// Immediate post-dominators, with a virtual exit `nb` that every return
/// block, and every block that cannot reach one, flows to. Cooper, Harvey
/// and Kennedy's iteration over the reverse CFG, in its reverse postorder.
pub fn postDominators(in: Input) Error![]u32 {
    const a = in.arena;
    const nb = in.an.nb;
    const exit = nb;
    // Blocks with no successor end the body; a block that cannot reach one
    // (a loop with no exit) is given a virtual edge so every block has an
    // ipdom.
    const reaches = try a.alloc(bool, nb + 1);
    @memset(reaches, false);
    var stack: std.ArrayList(u32) = .empty;
    for (0..nb) |b| if (in.an.succs[b].len == 0) {
        reaches[b] = true;
        try stack.append(a, @intCast(b));
    };
    while (stack.pop()) |b| for (in.an.preds[b]) |p| {
        if (reaches[p]) continue;
        reaches[p] = true;
        try stack.append(a, p);
    };
    const to_exit = try a.alloc(bool, nb);
    for (0..nb) |b| to_exit[b] = in.an.succs[b].len == 0 or !reaches[b];

    // Postorder of the reverse CFG from `exit`: its successors there are the
    // CFG predecessors.
    const po = try a.alloc(u32, nb + 1);
    const num = try a.alloc(u32, nb + 1);
    @memset(num, none_u32);
    const seen = try a.alloc(bool, nb + 1);
    @memset(seen, false);
    var n_po: u32 = 0;
    const Frame = struct { b: u32, i: u32 };
    var dfs: std.ArrayList(Frame) = .empty;
    try dfs.append(a, .{ .b = exit, .i = 0 });
    seen[exit] = true;
    while (dfs.items.len != 0) {
        const top = &dfs.items[dfs.items.len - 1];
        const next: ?u32 = blk: {
            if (top.b == exit) {
                while (top.i < nb) : (top.i += 1) {
                    if (to_exit[top.i] and !seen[top.i]) break :blk top.i;
                }
                break :blk null;
            }
            const ps = in.an.preds[top.b];
            while (top.i < ps.len) : (top.i += 1) {
                if (!seen[ps[top.i]]) break :blk ps[top.i];
            }
            break :blk null;
        };
        if (next) |n| {
            top.i += 1;
            seen[n] = true;
            try dfs.append(a, .{ .b = n, .i = 0 });
        } else {
            num[top.b] = n_po;
            po[n_po] = top.b;
            n_po += 1;
            _ = dfs.pop();
        }
    }

    const ipdom = try a.alloc(u32, nb + 1);
    @memset(ipdom, none_u32);
    ipdom[exit] = exit;
    var changed = true;
    while (changed) {
        changed = false;
        var k = n_po;
        while (k > 0) {
            k -= 1;
            const b = po[k];
            if (b == exit) continue;
            var new: u32 = none_u32;
            // Reverse-graph predecessors of b are its CFG successors (and the
            // virtual exit).
            const extra: []const u32 = if (to_exit[b]) &.{exit} else &.{};
            for ([_][]const u32{ in.an.succs[b], extra }) |list| for (list) |s| {
                if (ipdom[s] == none_u32) continue;
                new = if (new == none_u32) s else intersect(ipdom, num, s, new);
            };
            if (new != none_u32 and ipdom[b] != new) {
                ipdom[b] = new;
                changed = true;
            }
        }
    }
    return ipdom;
}

fn intersect(ipdom: []const u32, num: []const u32, b1: u32, b2: u32) u32 {
    var f1 = b1;
    var f2 = b2;
    while (f1 != f2) {
        while (num[f1] < num[f2]) f1 = ipdom[f1];
        while (num[f2] < num[f1]) f2 = ipdom[f2];
    }
    return f1;
}

/// Per-block control dependences, flat: `cd[off[b]..off[b + 1]]`.
pub fn controlDeps(in: Input, ipdom: []const u32) Error!struct { off: []u32, cd: []Cd } {
    const a = in.arena;
    const nb = in.an.nb;
    var lists = try a.alloc(std.ArrayList(Cd), nb);
    @memset(lists, .empty);
    for (0..nb) |ai| {
        const A: u32 = @intCast(ai);
        if (branchCond(in, A) == null) continue;
        for ([_]u32{ thenOf(in, A), elseOf(in, A) }, [_]bool{ true, false }) |s, then| {
            var r = s;
            while (r != ipdom[A] and r < nb) : (r = ipdom[r]) {
                try lists[r].append(a, .{ .a = A, .then = then });
                if (ipdom[r] == none_u32) break;
            }
        }
    }
    const off = try a.alloc(u32, nb + 1);
    var n: u32 = 0;
    for (lists, 0..) |l, b| {
        off[b] = n;
        n += @intCast(l.items.len);
    }
    off[nb] = n;
    const cd = try a.alloc(Cd, n);
    for (lists, 0..) |l, b| @memcpy(cd[off[b]..][0..l.items.len], l.items);
    return .{ .off = off, .cd = cd };
}

/// §9.10/§9.15/§9.19 and the pure math functions: the calls whose value is a
/// function of the `Model` row (its card and `temperature__`) alone, which
/// `setup` computes into `Model.su`. An allowlist: a callee not here is
/// per-eval. §6.3.6 `$mfactor` is an `Instance` field, so not here: instances
/// sharing a row may differ in it.
fn callInvariant(in: Input, d: anytype) bool {
    return switch (d.callee) {
        .@"$temperature", .@"$vt", .@"$param_given", .@"$port_connected" => true,
        // §9.15 Table 9-27: every literal name but `iteration`, which moves
        // with each Newton step, and `dt`, with each timepoint. `tnom` is a Model field the host writes with
        // the card; a published homotopy knob (gmin, gdev, sourceScaleFactor)
        // is invariant within a solve, and the host re-runs `setup` after
        // writing one (`setup_simparams` lists which).
        .@"$simparam" => !Lower.simparamIsRuntime(plan_args.strArg(in, d.args, 0) orelse return false),
        // IEEE 1364 §17.11 math and the §9.11/§9.12.1 conversions: pure.
        .@"$sqrt", .@"$exp", .@"$expm1", .@"$ln", .@"$ln1p", .@"$log", .@"$log10", .@"$floor", .@"$ceil" => true,
        .@"$sin", .@"$cos", .@"$tan", .@"$asin", .@"$acos", .@"$atan" => true,
        .@"$sinh", .@"$cosh", .@"$tanh", .@"$asinh", .@"$acosh", .@"$atanh" => true,
        .@"$pow", .@"$hypot", .@"$atan2", .@"$rtoi", .@"$itor", .@"$clog2" => true,
        else => false, // else: an ALLOWLIST — every other callee reads the solve, the time or state the host moves, until shown otherwise
    };
}

const Scan = struct {
    in: Input,
    val: []bool,
    plc: []bool,
    varying: []bool,
    init_else: []bool,

    fn sv(s: *const Scan, v0: Mir.Value) bool {
        const v = s.in.an.rv(v0);
        return switch (s.in.mir.valueDef(v)) {
            .undef, .float_const, .int_const, .str_const, .param_ref => true,
            .block_param => false,
            .inst_result => s.val[@backingInt(v)],
        };
    }

    /// The §5.10.2 exception's incoming value: the held read of the variable
    /// whose end-of-block value is `phi` itself.
    fn heldEquiv(s: *const Scan, phi: Mir.Value, v0: Mir.Value) bool {
        const in = s.in;
        const def = in.mir.valueDef(in.an.rv(v0));
        if (def != .inst_result or in.mir.instOp(def.inst_result) != .call) return false;
        const d = in.mir.instData(def.inst_result).call;
        switch (d.callee) {
            .@"$held_real", .@"$held_int" => {},
            else => return false, // else: only the two §5.10 held reads name a held variable
        }
        const held = in.lowered.held_vars.items;
        if (held.len == 0) return false;
        // The `held_vars` index is the call's literal argument (`gen_call.heldIdx`).
        const c = in.an.foldConst(if (d.args.len != 0) d.args[0] else .zero, false) orelse return false;
        const i: usize = @intFromFloat(c.f);
        return in.an.rv(held[@min(i, held.len - 1)].final) == phi;
    }

    /// Does the edge `src -> y` run only when the initial step does not?
    fn initElseEdge(s: *const Scan, src: u32, y: u32) bool {
        if (s.init_else[src]) return true;
        const c = branchCond(s.in, src) orelse return false;
        return initCond(s.in, c) and elseOf(s.in, src) == y and thenOf(s.in, src) != y;
    }

    /// A pure op in a block `setup` does not place, over operands that are
    /// the same at every evaluation: `setup` computes it anyway, at its
    /// `home`, and the core reads it only where it would have computed it.
    /// Sound only for an op that cannot fault when its guard is false: a real
    /// outside its domain is NaN or inf. So no integer arithmetic (a zero
    /// divisor traps), no `%`, and none of the four functions whose domain
    /// check reports when `display == .emit` (`zDomain`).
    fn speculable(s: *const Scan, inst: Mir.Inst, blk: u32) bool {
        const in = s.in;
        if (in.an.loop_of[blk] != none_u32 or s.homeOf(blk) == none_u32) return false;
        const row = in.mir.instRow(inst);
        const info = Mir.opcode.get(row.op);
        switch (info.fold) {
            .unary, .binary, .math, .to_real => {},
            .none, .identity, .to_int => return false,
        }
        if (info.int and !info.bool01) return false;
        switch (info.domain) {
            .all, .positive, .gt_neg_one, .non_negative, .pow_sign, .tan_poles => {},
            .unit_closed, .unit_open, .ge_one, .nonzero_divisor => return false,
        }
        return switch (Mir.opClass(row.op)) {
            .unary => s.anchored(@fromBackingInt(@intCast(row.a))),
            .binary => s.anchored(@fromBackingInt(@intCast(row.a))) and s.anchored(@fromBackingInt(@intCast(row.b))),
            .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => false,
        };
    }

    /// An operand `setup` holds wherever it places a speculable op: a leaf,
    /// or an invariant value outside every loop. Its block dominates the
    /// user's, so it is placed at or above the user's `home`.
    fn anchored(s: *const Scan, v0: Mir.Value) bool {
        const v = s.in.an.rv(v0);
        if (s.in.mir.valueDef(v) != .inst_result) return s.sv(v);
        const b = s.in.an.def_block[@backingInt(v)];
        return s.val[@backingInt(v)] and b != none_u32 and s.in.an.loop_of[b] == none_u32;
    }

    /// The nearest placeable dominator of `b`, or `none_u32`.
    fn homeOf(s: *const Scan, b0: u32) u32 {
        var b = b0;
        while (!s.plc[b]) {
            const up = s.in.an.idom[b];
            if (up == none_u32 or up == b) return none_u32;
            b = up;
        }
        return b;
    }

    fn rule(s: *const Scan, v: Mir.Value) bool {
        const in = s.in;
        const def = in.mir.valueDef(v);
        if (def != .inst_result) return s.sv(v);
        const inst = def.inst_result;
        const blk = in.an.def_block[@backingInt(v)];
        if (blk == none_u32) return false;
        if (!s.plc[blk]) return s.speculable(inst, blk);
        const row = in.mir.instRow(inst);
        switch (row.op) {
            .call => {
                const d = in.mir.instData(inst).call;
                if (!callInvariant(in, d)) return false;
                for (d.args) |arg| if (!s.sv(arg)) return false;
                return true;
            },
            .phi => {
                const d = in.mir.instData(inst).phi;
                var k: u32 = 0;
                while (k < d.count) : (k += 1) {
                    const p = in.mir.phiPair(inst, k);
                    const src: u32 = @backingInt(p.block);
                    if (s.plc[src] and s.sv(p.value) and !s.initElseEdge(src, blk)) continue;
                    if (s.initElseEdge(src, blk) and s.heldEquiv(v, p.value)) continue;
                    return false;
                }
                return true;
            },
            // §5.6.1.2 the path latches move with every accepted step.
            .path_prev, .path_acc, .branch, .jump => return false,
            .select => {
                const d = in.mir.instData(inst).ternary;
                return s.sv(d.cond) and s.sv(d.then_val) and s.sv(d.else_val);
            },
            else => return switch (Mir.opClass(row.op)) { // else: every other opcode is pure; its class names the operands
                .unary => s.sv(@fromBackingInt(@intCast(row.a))),
                .binary => s.sv(@fromBackingInt(@intCast(row.a))) and s.sv(@fromBackingInt(@intCast(row.b))),
                .ternary => s.sv(@fromBackingInt(@intCast(row.a))) and s.sv(@fromBackingInt(@intCast(row.b))) and s.sv(@fromBackingInt(@intCast(row.c))),
                .phi, .branch, .jump, .call => false,
                // §3.2.2 array storage is per evaluation: a setup root is one
                // `Setup` scalar, and an array version is not one.
                // ponytail: an invariant array (an `analog initial` table)
                // is recomputed per eval; the upgrade is a `[N]f64` Setup field.
                .anew, .load, .store => false,
            },
        }
    }
};

/// Returns the solve-invariance fixpoint; every slice is owned by `in.arena`.
/// Optimistic and monotone: every flag starts true and only falls.
///   - A constant, parameter or `undef` is invariant; a §4.4 probe is not.
///   - A pure op is invariant when its operands are and its block is
///     placeable, or, when it cannot fault, whatever its block
///     (`Scan.speculable`); `setup` then computes it at its `home`.
///   - A call is invariant only on the allowlist (`callInvariant`), over
///     invariant arguments.
///   - A phi is invariant when its block is placeable and every incoming edge
///     comes from a placeable block with an invariant value, or is the
///     initial-step exception below.
///   - A block is placeable when every branch it is control-dependent on
///     (post-dominator frontier, per edge) tests an invariant condition from a
///     placeable block, and no loop with a per-eval branch can reach it.
///
/// §5.10.2 initial-step exception: every variable `@(initial_step)` or
/// `analog initial` assigns is §5.10 held. It is initial-only when its
/// end-of-block value is the event join's `phi(held read, assigned value)` and
/// the assigned value is invariant: by induction every evaluation sees the
/// assigned value, so `setup` takes the event's arm unconditionally. A write
/// after the join (`k = k + 1`) breaks the identity. This relies on the host
/// evaluating an initial step before any other point, an obligation stated on
/// `setup`.
pub fn plan(in: Input) Error!Sinv {
    var r = try solve(in, true);
    const a = in.arena;
    const s: Scan = .{ .in = in, .val = r.val, .plc = r.blk, .varying = r.loop_varying, .init_else = &.{} };
    r.home = try a.alloc(u32, in.an.nv);
    @memset(r.home, none_u32);
    r.moved_off = try a.alloc(u32, in.an.nb + 1);
    @memset(r.moved_off, 0);
    var n: u32 = 0;
    for (Mir.Value.first_dynamic..in.an.nv) |i| {
        const v: Mir.Value = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
        const b = in.an.def_block[i];
        if (!r.val[i] or b == none_u32 or r.blk[b] or in.an.rv(v) != v) continue;
        r.home[i] = s.homeOf(b);
        r.moved_off[r.home[i] + 1] += 1;
        n += 1;
    }
    for (0..in.an.nb) |b| r.moved_off[b + 1] += r.moved_off[b];
    r.moved = try a.alloc(Mir.Value, n);
    const fill = try a.dupe(u32, r.moved_off[0..in.an.nb]);
    for (r.home, 0..) |h, i| if (h != none_u32) {
        r.moved[fill[h]] = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
        fill[h] += 1;
    };
    return r;
}

/// `placing == false` drops the one rule about placement rather than
/// invariance (nothing a per-eval loop can reach is placeable). A block after
/// such a loop that depends only on invariant branches then counts as fixed,
/// and so does what it computes: `setup` cannot compute those values, but
/// they are the same at every evaluation of a card, which is all `pruneHeld`
/// asks.
fn solve(in: Input, placing: bool) Error!Sinv {
    const a = in.arena;
    const nb = in.an.nb;
    const nv = in.an.nv;
    const ipdom = try postDominators(in);
    const cds = try controlDeps(in, ipdom);
    var s: Scan = .{
        .in = in,
        .val = try a.alloc(bool, nv),
        .plc = try a.alloc(bool, nb),
        .varying = try a.alloc(bool, nb),
        .init_else = try a.alloc(bool, nb),
    };
    @memset(s.val, true);
    @memset(s.plc, true);
    const reach = try a.alloc(bool, nb);
    var stack: std.ArrayList(u32) = .empty;
    while (true) {
        var changed = false;
        // Loops with a per-eval branch, and everything they can reach.
        @memset(s.varying, false);
        for (0..nb) |bi| {
            const c = branchCond(in, @intCast(bi)) orelse continue;
            const h = in.an.loop_of[bi];
            if (h != none_u32 and !s.sv(c)) s.varying[h] = true;
        }
        @memset(reach, false);
        for (0..nb) |bi| if (s.varying[bi]) {
            reach[bi] = true;
            try stack.append(a, @intCast(bi));
        };
        while (stack.pop()) |b| for (in.an.succs[b]) |x| {
            if (reach[x]) continue;
            reach[x] = true;
            try stack.append(a, x);
        };
        // Placeable blocks, and the initial-step else arms.
        for (0..nb) |bi| {
            var ok = !(placing and reach[bi]);
            var ie = false;
            for (cds.cd[cds.off[bi]..cds.off[bi + 1]]) |d| {
                const c = branchCond(in, d.a).?;
                if (initCond(in, c)) {
                    if (!d.then) {
                        ie = true;
                        ok = false;
                    }
                } else if (!s.sv(c)) ok = false;
                if (!s.plc[d.a]) ok = false;
            }
            s.init_else[bi] = ie;
            if (s.plc[bi] and !ok) {
                s.plc[bi] = false;
                changed = true;
            }
        }
        for (Mir.Value.first_dynamic..nv) |i| {
            if (!s.val[i]) continue;
            const v: Mir.Value = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
            if (in.an.rv(v) != v) {
                // An alias carries its target's answer.
                if (!s.sv(v)) {
                    s.val[i] = false;
                    changed = true;
                }
                continue;
            }
            if (!s.rule(v)) {
                s.val[i] = false;
                changed = true;
            }
        }
        if (!changed) break;
    }
    return .{ .val = s.val, .blk = s.plc, .loop_varying = s.varying };
}

/// Is `v` a value `setup` may hand eval? Invariant, computed (not a literal
/// the renderer folds), one value per evaluation (outside every loop), and of
/// a type `Setup` has a field for.
pub fn candidate(in: Input, sinv: []const bool, v: Mir.Value) bool {
    const i = @backingInt(v);
    if (i < Mir.Value.first_dynamic or !sinv[i]) return false;
    if (in.mir.valueDef(v) != .inst_result) return false;
    if (in.an.vty[i] == .str) return false;
    const b = in.an.def_block[i];
    if (b == none_u32 or in.an.loop_of[b] != none_u32) return false;
    return in.an.foldConst(v, false) == null;
}

/// VerA's `vera_timepoint` (§2.9): the calls whose value is the same at
/// every Newton iteration of one timepoint, given their arguments. The
/// solve-invariant ones (`callInvariant`), the time and analysis the host
/// keys the cache on, the accepted held state, the cache itself, and the
/// pure synthetic reads lowering mints. An allowlist, as `callInvariant` is.
fn callTimepoint(in: Input, d: anytype) bool {
    if (callInvariant(in, d)) return true;
    return switch (d.callee) {
        .@"$abstime", .@"$realtime", .analysis, .analog_initial, .initial_step, .final_step => true,
        // §9.15 `dt` moves with the timepoint, never within one; `iteration` does.
        .@"$simparam" => std.mem.eql(u8, plan_args.strArg(in, d.args, 0) orelse return false, "dt"),
        .@"$held_real", .@"$held_int", .@"$tp_hit", .@"$tp_int", .@"$tp_real" => true,
        .@"$idx", .@"$idx$int", .@"$idx$str", .limexp, .@"$str$cat", .@"$str$repeat" => true,
        else => false, // else: an ALLOWLIST — every other callee may read the iterate or state an iteration moves
    };
}

/// VerA's `vera_timepoint` (§2.9): a value of statement `t`, or a branch
/// condition inside it, that can move between the Newton iterations of one
/// timepoint (E0531), or null. Optimistic and monotone like `solve`: every
/// value starts fixed and only falls.
///   - A probe varies; a constant or parameter does not.
///   - A call varies unless `callTimepoint` allows it over fixed arguments.
///   - A pure op, select, load or store varies with an operand; an `anew` is
///     fixed (zero, the accepted held state, or the cache).
///   - A phi varies with an incoming value. Outside the statement it varies
///     also when an incoming edge's predecessor ends in, or is control-
///     dependent on, a varying branch: `if (V(a) > 0) y = 1; else y = 2;`.
///     Inside, every branch is checked itself, so data suffices.
pub fn timepointVarying(in: Input, t: Lower.TpBlock) Error!?Mir.Value {
    const a = in.arena;
    const nb = in.an.nb;
    const nv = in.an.nv;
    const inside = try a.alloc(bool, nb);
    @memset(inside, false);
    var stack: std.ArrayList(u32) = .empty;
    const miss: u32 = @backingInt(t.miss);
    const join: u32 = @backingInt(t.join);
    inside[miss] = true;
    try stack.append(a, miss);
    while (stack.pop()) |b| for (in.an.succs[b]) |x| {
        if (x == join or inside[x]) continue;
        inside[x] = true;
        try stack.append(a, x);
    };
    const cds = try controlDeps(in, try postDominators(in));
    const vary = try a.alloc(bool, nv);
    @memset(vary, false);
    var changed = true;
    while (changed) {
        changed = false;
        for (Mir.Value.first_dynamic..nv) |i| {
            if (vary[i]) continue;
            const v: Mir.Value = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
            const r = in.an.rv(v);
            const now = if (r != v) varies(in, vary, r) else tpRule(in, vary, inside, cds, v);
            if (!now) continue;
            vary[i] = true;
            changed = true;
        }
    }
    for (0..nb) |bi| {
        if (!inside[bi]) continue;
        if (branchCond(in, @intCast(bi))) |c| if (varies(in, vary, c)) return c;
    }
    // An alias is the value it names, wherever that is: a pass-through phi
    // the SSA builder placed inside and then folded away reads nothing here.
    for (Mir.Value.first_dynamic..nv) |i| {
        const v: Mir.Value = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
        const b = in.an.def_block[i];
        if (vary[i] and in.an.rv(v) == v and b != none_u32 and inside[b]) return v;
    }
    return null;
}

fn varies(in: Input, vary: []const bool, v0: Mir.Value) bool {
    const v = in.an.rv(v0);
    return switch (in.mir.valueDef(v)) {
        .undef, .float_const, .int_const, .str_const, .param_ref => false,
        .block_param => true,
        .inst_result => vary[@backingInt(v)],
    };
}

fn tpRule(in: Input, vary: []const bool, inside: []const bool, cds: anytype, v: Mir.Value) bool {
    const def = in.mir.valueDef(v);
    if (def != .inst_result) return varies(in, vary, v);
    const inst = def.inst_result;
    return switch (in.mir.instData(inst)) {
        .unary => |d| varies(in, vary, d.operand),
        .binary => |d| varies(in, vary, d.lhs) or varies(in, vary, d.rhs),
        .ternary => |d| varies(in, vary, d.cond) or varies(in, vary, d.then_val) or varies(in, vary, d.else_val),
        .call => |d| blk: {
            if (!callTimepoint(in, d)) break :blk true;
            for (d.args) |x| if (varies(in, vary, x)) break :blk true;
            break :blk false;
        },
        .anew, .branch, .jump => false,
        .load => |d| varies(in, vary, d.arr) or varies(in, vary, d.index),
        .store => |d| varies(in, vary, d.arr) or varies(in, vary, d.index) or varies(in, vary, d.value),
        .phi => |d| blk: {
            const blk_v = in.an.def_block[@backingInt(v)];
            const out = blk_v == none_u32 or !inside[blk_v];
            for (0..d.count) |k| {
                const pp = in.mir.phiPair(inst, @intCast(k));
                if (varies(in, vary, pp.value)) break :blk true;
                if (!out) continue;
                const pb: u32 = @backingInt(pp.block);
                if (branchCond(in, pb)) |c| if (varies(in, vary, c)) break :blk true;
                for (cds.cd[cds.off[pb]..cds.off[pb + 1]]) |cd| {
                    if (varies(in, vary, branchCond(in, cd.a).?)) break :blk true;
                }
            }
            break :blk false;
        },
    };
}

/// §3.2 drops the held slots the card makes unobservable, rewriting `mir` and
/// `lowered.held_vars` in place.
///
/// A `.unless_invariant` held variable has no read that reaches a later write
/// of the same evaluation (`lower_param.Exposed`), so its held value is
/// observed only where it merges with a write: a phi or a select fed by the
/// `$held_*` seed. When every such merge is solve-invariant (its block and
/// incoming edges depend only on invariant branches, a select's condition is
/// invariant), a fixed card either writes the variable before every read or
/// never writes it, so the slot always equals the declared initializer. The
/// seed becomes an alias of the initializer and the remaining rows are
/// renumbered.
///
/// Runs between lowering and if-conversion (lib/root.zig stage 4.4): it needs
/// `plan`'s invariance, and a select must not yet hide the merges it reads.
/// Every candidate is still held while the plan runs, so a condition over one
/// reads as varying, which is conservative.
pub fn pruneHeld(arena: std.mem.Allocator, mir: *Mir, lowered: *Lowered) Error!void {
    const held = &lowered.held_vars;
    for (held.items) |h| {
        if (h.why == .unless_invariant) break;
    } else return;
    const an = try Analysis.build(arena, mir, lowered);
    const in: Input = .{ .arena = arena, .mir = mir, .an = &an, .lowered = lowered };
    const s = try solve(in, false);
    var merges: std.ArrayList(Mir.Inst) = .empty;
    for (0..an.nb) |bi| {
        var it = mir.blockInsts(@fromBackingInt(@intCast(@as(u32, @intCast(bi)))));
        while (it.next()) |inst| switch (mir.instOp(inst)) {
            .phi, .select => try merges.append(arena, inst),
            else => {}, // else: only a phi or a select merges a held value with a write
        };
    }
    const web = try arena.alloc(bool, an.nv);
    var kept: usize = 0;
    for (held.items) |h| {
        if (h.why != .unless_invariant or try observed(in, s, merges.items, web, h.seed)) {
            held.items[kept] = h;
            kept += 1;
            continue;
        }
        const seed = an.rv(h.seed);
        const inst = mir.valueDef(seed).inst_result;
        const b = an.def_block[@backingInt(seed)];
        const next = mir.insts.items(.next);
        var prev: Mir.Inst = .none;
        var cur = mir.blocks.items(.first)[b];
        while (cur != inst) : (cur = next[@backingInt(cur)]) prev = cur;
        const after = next[@backingInt(inst)];
        if (prev == .none) mir.blocks.items(.first)[b] = after else next[@backingInt(prev)] = after;
        if (mir.blocks.items(.last)[b] == inst) mir.blocks.items(.last)[b] = prev;
        next[@backingInt(inst)] = .none;
        mir.setAlias(seed, h.init);
    }
    held.shrinkRetainingCapacity(kept);
    // The seed's argument is its row (`gen_call.heldIdx`). A held array's
    // seed is its `anew`, which carries no row: its `mem_arrays` entry does.
    for (held.items, 0..) |h, i| {
        if (h.array != none_u32) {
            lowered.mem_arrays.items[h.array].held = @intCast(i);
            continue;
        }
        const inst = mir.valueDef(an.rv(h.seed)).inst_result;
        mir.extra.items[mir.insts.items(.b)[@backingInt(inst)] + 1] = @backingInt(try mir.addIntConst(arena, @intCast(i)));
    }
}

/// Does a merge of `seed`'s forward web vary from one evaluation to the next?
fn observed(in: Input, s: Sinv, merges: []const Mir.Inst, web: []bool, seed: Mir.Value) Error!bool {
    const mir = in.mir;
    const an = in.an;
    @memset(web, false);
    web[@backingInt(an.rv(seed))] = true;
    var changed = true;
    while (changed) {
        changed = false;
        for (merges) |m| {
            const r = an.rv(mir.instResult(m));
            if (web[@backingInt(r)]) continue;
            const blk = an.def_block[@backingInt(r)];
            var feeds = false;
            var fixed = blk != none_u32 and s.blk[blk];
            switch (mir.instData(m)) {
                .phi => |d| for (0..d.count) |k| {
                    const p = mir.phiPair(m, @intCast(k));
                    feeds = feeds or web[@backingInt(an.rv(p.value))];
                    fixed = fixed and s.blk[@backingInt(p.block)];
                },
                .ternary => |d| {
                    feeds = web[@backingInt(an.rv(d.then_val))] or web[@backingInt(an.rv(d.else_val))];
                    fixed = fixed and s.val[@backingInt(an.rv(d.cond))];
                },
                else => unreachable, // else: `merges` holds phis and selects only
            }
            if (!feeds) continue;
            if (!fixed) return true;
            web[@backingInt(r)] = true;
            changed = true;
        }
    }
    return false;
}

const Fixture = @import("fixture.zig").Fixture;

test "a value of parameters and $temperature is solve-invariant; one reading a probe is not" {
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
    const it = try f.call("$simparam", &.{try f.mir.addStrConst(a, "iteration")});
    const dt = try f.call("$simparam", &.{try f.mir.addStrConst(a, "dt")});
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };

    const s = try plan(in);
    try std.testing.expect(s.val[@backingInt(t)] and s.val[@backingInt(et)] and s.val[@backingInt(k)]);
    try std.testing.expect(!s.val[@backingInt(i)]);
    // §9.15 `iteration` moves with every Newton step.
    try std.testing.expect(!s.val[@backingInt(it)]);
    // `dt` moves with every timepoint, so `setup` must not hoist it.
    try std.testing.expect(!s.val[@backingInt(dt)]);
    try std.testing.expect(s.blk[0]);
    try std.testing.expect(candidate(in, s.val, k));
    try std.testing.expect(!candidate(in, s.val, i));
}

test "a pure op of parameters under a bias-dependent branch is invariant and computed at its placeable dominator; an integer divide is not" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    try f.lowered.params.append(a, .{ .name = "mj", .ty = .real, .default = .f_one });
    try f.lowered.params.append(a, .{ .name = "n", .ty = .integer, .default = .zero });
    const mj = try f.mir.addParamRef(a, 0);
    const n = try f.mir.addParamRef(a, 1);
    // entry: if (V(a) > 0) then else; then/else: join.
    const then_b = try f.mir.addBlock(a);
    const else_b = try f.mir.addBlock(a);
    const join = try f.mir.addBlock(a);
    const c = try f.mir.emit(a, .entry, .fgt, &.{ try f.probe(0), try f.mir.addFloatConst(a, 0.0) });
    _ = try f.mir.emitBranch(a, .entry, c, then_b, else_b);
    const p = try f.mir.emit(a, else_b, .pow, &.{ try f.mir.addFloatConst(a, 0.5), mj }); // pow(0.5, mj)
    const d = try f.mir.emit(a, else_b, .idiv, &.{ n, n }); // n / n
    _ = try f.mir.emitJump(a, then_b, join);
    _ = try f.mir.emitJump(a, else_b, join);
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };

    const s = try plan(in);
    try std.testing.expect(!s.blk[@backingInt(else_b)]);
    try std.testing.expect(s.val[@backingInt(p)]);
    try std.testing.expectEqual(@as(u32, 0), s.home[@backingInt(p)]);
    try std.testing.expectEqualSlices(Mir.Value, &.{p}, s.movedTo(0));
    try std.testing.expect(candidate(in, s.val, p));
    // An integer divide by zero traps, so it stays under its guard.
    try std.testing.expect(!s.val[@backingInt(d)]);
}
