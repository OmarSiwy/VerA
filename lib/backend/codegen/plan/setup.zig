//! Solve invariance: which MIR values are the same at every Newton iterate and
//! every time point, so `setup` computes them once per card, instance and
//! temperature instead of `eval` recomputing them per iterate.
//!
//! PURE (ARCHITECTURE.md §2): `plan` takes the lowered module and returns a
//! `Sinv`. The emitter half — which of these values the core actually reads
//! (the setup ROOTS) and `pub fn setup` itself — is `codegen/setup.zig`, which
//! needs the unit planner's slice and the writer.
//!
//! LRM clauses this file's code cites: §3.2, §4.4, §5.2.1, §5.6.1.2, §5.10,
//! §5.10.2, §9.10, §9.15, §9.19.
//!
//! WHY ONE CLASSIFIER. Three answered the question before this file: the
//! temperature hoist's `pcClass` (re-spelled a value in a flat `precompute`),
//! the core prefix's `hpPure` (cached a TEXT prefix of the core) and
//! `cg_limit.scValue` (latched `$limit` arguments off a core call at x = 0).
//! Their whitelists had drifted (`$port_connected` was in two of the three),
//! the prefix stopped at the first probe-dependent statement — so bsim4va's
//! prefix was 267 of its 4 851 statements while its invariant work ran to
//! 3 556 — and each latched through a different scalar, one of which was not
//! the host's (the 1-ulp mos3 drift). This is the one answer, a fixpoint over
//! the MIR, and the host's own value scalar `V` computes it.
//!
//! THE RULES (`plan`), optimistic and monotone — every flag starts true and
//! only ever falls, so the fixpoint terminates:
//!   - a constant, parameter or `undef` is invariant; a §4.4 probe is not;
//!   - a pure operation is invariant when its operands are and its block is
//!     PLACEABLE;
//!   - a call is invariant only on the allowlist (`callInvariant`): the
//!     environment reads that answer from the card, the instance or its
//!     temperature, `$simparam` of every §9.15 Table 9-27 name but
//!     `iteration`, and the pure math functions — all over invariant args;
//!   - a phi is invariant when its block is placeable and every incoming edge
//!     comes from a placeable block with an invariant value — or is the
//!     §5.10.2 initial-step exception below;
//!   - a block is placeable when every branch it is CONTROL-DEPENDENT on
//!     (post-dominator frontier, per edge) tests an invariant condition from a
//!     placeable block, and no loop whose branches are not all invariant can
//!     reach it. Code after such a loop stays per-eval (v1).
//!
//! THE INITIAL-STEP RULE (research C.6, vbic). `@(initial_step)` and
//! `analog initial` bodies are the model's temperature prep in many models,
//! and every variable they assign is §5.10 held. Such a variable is
//! INITIAL-ONLY when its end-of-block value IS the merge
//! `phi(held read, assigned value)` at the event's join and the assigned
//! value is invariant: the held read is the previous evaluation's copy of
//! that same phi, so by induction every evaluation sees the assigned value,
//! and `setup` computes it by taking the event's arm unconditionally. A write
//! after the join (`k = k + 1`) breaks the identity: assuming the held read
//! invariant there would justify itself, so the phi is per-eval. The one
//! difference from evaluating it: an evaluation before the first initial step
//! used to read the declared initializer. A host evaluates an initial step
//! first; that is its obligation, stated on `setup`.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const Analysis = @import("ir").Analysis;
const Input = @import("input.zig").Input;
const plan_args = @import("args.zig");

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
};

/// One control dependence: block B depends on the branch at `a` through its
/// `then` edge (`then == true`) or its `else` edge.
pub const Cd = struct { a: u32, then: bool };

/// §5.10.2 `initial_step` with no analysis list, or §5.2.1 `analog initial`:
/// the condition `setup` treats as TRUE. A qualified `initial_step("tran")`
/// is not one — in DC it keeps its initializer, so it is not a card function.
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

pub fn branchCond(in: Input, bi: u32) ?Mir.Value {
    const t = in.an.term[bi];
    if (t == .none or in.mir.instOp(t) != .branch) return null;
    return in.mir.instData(t).branch.cond;
}

fn thenOf(in: Input, bi: u32) u32 {
    return @intFromEnum(in.mir.instData(in.an.term[bi]).branch.then_block);
}

fn elseOf(in: Input, bi: u32) u32 {
    return @intFromEnum(in.mir.instData(in.an.term[bi]).branch.else_block);
}

/// Immediate post-dominators, with a virtual exit `nb` that every return
/// block — and every block that cannot reach one — flows to. Cooper, Harvey
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
    for (lists) |*l| l.* = .empty;
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
/// function of the card, the instance and its temperature alone. An
/// ALLOWLIST — a callee not here is per-eval.
fn callInvariant(in: Input, d: anytype) bool {
    return switch (d.callee) {
        .@"$temperature", .@"$vt", .@"$mfactor", .@"$param_given", .@"$port_connected" => true,
        // §9.15 Table 9-27: every literal name but `iteration`, which moves
        // with each Newton step. `tnom` is a Model field the host writes with
        // the card; the homotopy knobs (gmin, gdev, sourceScaleFactor) are
        // folded today and are invariant within a solve if published, with the
        // host re-running `setup` after writing one — `setup_simparams` lists
        // which.
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
            .inst_result => s.val[@intFromEnum(v)],
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

    /// Does the edge `src → y` run only when the initial step does NOT?
    fn initElseEdge(s: *const Scan, src: u32, y: u32) bool {
        if (s.init_else[src]) return true;
        const c = branchCond(s.in, src) orelse return false;
        return initCond(s.in, c) and elseOf(s.in, src) == y and thenOf(s.in, src) != y;
    }

    fn rule(s: *const Scan, v: Mir.Value) bool {
        const in = s.in;
        const def = in.mir.valueDef(v);
        if (def != .inst_result) return s.sv(v);
        const inst = def.inst_result;
        const blk = in.an.def_block[@intFromEnum(v)];
        if (blk == none_u32 or !s.plc[blk]) return false;
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
                    const src: u32 = @intFromEnum(p.block);
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
                .unary => s.sv(@enumFromInt(row.a)),
                .binary => s.sv(@enumFromInt(row.a)) and s.sv(@enumFromInt(row.b)),
                .ternary => s.sv(@enumFromInt(row.a)) and s.sv(@enumFromInt(row.b)) and s.sv(@enumFromInt(row.c)),
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

/// The fixpoint. See the header for the rules.
pub fn plan(in: Input) Error!Sinv {
    return solve(in, true);
}

/// `placing == false` drops the one rule that is about PLACEMENT rather than
/// invariance — nothing a per-eval loop can reach is placeable — so a block
/// after such a loop that depends only on invariant branches counts as fixed,
/// and so does what it computes. `setup` cannot compute those values (it stops
/// at the loop), but they are still the same at every evaluation of a card,
/// which is all `pruneHeld` asks.
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
            const v: Mir.Value = @enumFromInt(@as(u32, @intCast(i)));
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

/// A value `setup` may hand eval: invariant, computed (not a literal the
/// renderer folds), one value per evaluation (outside every loop), and a type
/// `Setup` has a field for.
pub fn candidate(in: Input, sinv: []const bool, v: Mir.Value) bool {
    const i = @intFromEnum(v);
    if (i < Mir.Value.first_dynamic or !sinv[i]) return false;
    if (in.mir.valueDef(v) != .inst_result) return false;
    if (in.an.vty[i] == .str) return false;
    const b = in.an.def_block[i];
    if (b == none_u32 or in.an.loop_of[b] != none_u32) return false;
    return in.an.foldConst(v, false) == null;
}

/// §3.2 retention the card decides. A `.unless_invariant` held variable has no
/// read that reaches a later write of the same evaluation (`lower_param.
/// Exposed`), so its held value is observed only where it MERGES with a write:
/// a phi, or a select, fed by the `$held_*` seed. When every such merge is
/// solve-invariant — its block and every incoming edge depending only on
/// invariant branches (`solve` without placement), a select's condition
/// invariant — then for a fixed card the variable is either written
/// before every read of every evaluation or never written, and a slot holding
/// it can never differ from the declared initializer. So the slot is dropped:
/// the seed becomes an alias of the initializer and leaves its block, and the
/// remaining rows are renumbered.
///
/// A MIR rewrite between lowering and if-conversion (root.zig stage 4.4),
/// because the question needs `plan`'s invariance, which is backend, and the
/// answer changes what lowering produced. The plan runs with every candidate
/// still held, so a condition over one reads as varying: conservative.
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
        var it = mir.blockInsts(@enumFromInt(@as(u32, @intCast(bi))));
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
        const b = an.def_block[@intFromEnum(seed)];
        const next = mir.insts.items(.next);
        var prev: Mir.Inst = .none;
        var cur = mir.blocks.items(.first)[b];
        while (cur != inst) : (cur = next[@intFromEnum(cur)]) prev = cur;
        const after = next[@intFromEnum(inst)];
        if (prev == .none) mir.blocks.items(.first)[b] = after else next[@intFromEnum(prev)] = after;
        if (mir.blocks.items(.last)[b] == inst) mir.blocks.items(.last)[b] = prev;
        next[@intFromEnum(inst)] = .none;
        mir.setAlias(seed, h.init);
    }
    held.shrinkRetainingCapacity(kept);
    // The seed's argument is its row (`gen_call.heldIdx`).
    for (held.items, 0..) |h, i| {
        const inst = mir.valueDef(an.rv(h.seed)).inst_result;
        mir.extra.items[mir.insts.items(.b)[@intFromEnum(inst)] + 1] = @intFromEnum(try mir.addIntConst(arena, @intCast(i)));
    }
}

/// Does a merge of `seed`'s forward web vary from one evaluation to the next?
fn observed(in: Input, s: Sinv, merges: []const Mir.Inst, web: []bool, seed: Mir.Value) Error!bool {
    const mir = in.mir;
    const an = in.an;
    @memset(web, false);
    web[@intFromEnum(an.rv(seed))] = true;
    var changed = true;
    while (changed) {
        changed = false;
        for (merges) |m| {
            const r = an.rv(mir.instResult(m));
            if (web[@intFromEnum(r)]) continue;
            const blk = an.def_block[@intFromEnum(r)];
            var feeds = false;
            var fixed = blk != none_u32 and s.blk[blk];
            switch (mir.instData(m)) {
                .phi => |d| for (0..d.count) |k| {
                    const p = mir.phiPair(m, @intCast(k));
                    feeds = feeds or web[@intFromEnum(an.rv(p.value))];
                    fixed = fixed and s.blk[@intFromEnum(p.block)];
                },
                .ternary => |d| {
                    feeds = web[@intFromEnum(an.rv(d.then_val))] or web[@intFromEnum(an.rv(d.else_val))];
                    fixed = fixed and s.val[@intFromEnum(an.rv(d.cond))];
                },
                else => unreachable, // else: `merges` holds phis and selects only
            }
            if (!feeds) continue;
            if (!fixed) return true;
            web[@intFromEnum(r)] = true;
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
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };

    const s = try plan(in);
    try std.testing.expect(s.val[@intFromEnum(t)] and s.val[@intFromEnum(et)] and s.val[@intFromEnum(k)]);
    try std.testing.expect(!s.val[@intFromEnum(i)]);
    // §9.15 `iteration` moves with every Newton step.
    try std.testing.expect(!s.val[@intFromEnum(it)]);
    try std.testing.expect(s.blk[0]);
    try std.testing.expect(candidate(in, s.val, k));
    try std.testing.expect(!candidate(in, s.val, i));
}
