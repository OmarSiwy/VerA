//! The processes of a native design -> how `rt.State` schedules each.
//!
//! In: every process `emit.native` found, as the pcs it reaches from its
//! entry. Out: which slots anything can wait on (a store to any other slot
//! wakes no one, so it is a plain store), and under the `static` schedule a
//! role per process with the tables that run it: combinational nodes in
//! topological order with the bits that dirty them (§5.2.1: a constant
//! select reads only the bits it names), and the watchers of the processes
//! that wait at one fixed event control.
//!
//! Clauses: IEEE 1364-2005 §11.4.1 (active events in any order), §6.1
//! continuous assignment, §9.7.5 `@*`, §9.7.2 edges.
const std = @import("std");
const Ast = @import("frontend").Ast;
const compile = @import("compile.zig");
const exec = @import("exec.zig");
const emit = @import("emit.zig");
const expr = @import("emit_expr.zig");
const Emitter = emit.Emitter;
const Error = emit.Error;

pub const Schedule = enum { fifo, static };

pub const Edge = enum { any, posedge, negedge };
pub const Term = struct { slot: u32, edge: Edge };

pub const Role = union(enum) {
    /// Queued and woken by the interpreter's rules.
    general,
    /// Suspends only at its entry, an event control whose terms are
    /// static: `rt.State.waiting[n]` while it waits there.
    triggered: u32,
    /// Combinational node n: run by a settle event in topological order,
    /// never queued after time 0.
    comb: u32,
};

pub const Proc = struct { entry: u32, pcs: []const u32, role: Role = .general };

pub const Watcher = struct { proc: u32, pc: u32, edge: Edge };

/// Node `node` reads the bits `mask` of plane word `word`: a change there
/// dirties it, a change anywhere else in the slot does not.
pub const Sense = struct { node: u32, word: u32, mask: u64 };

pub const Plan = struct {
    /// Per slot: an event control, driver or node may wait on it.
    watched: []const bool,
    /// Per node, the pc its evaluation starts at.
    node_pc: []const u32 = &.{},
    /// Per slot, the bits its node readers read, ascending by word
    /// (`rt.Design.comb`).
    comb_start: []const u32 = &.{},
    comb: []const Sense = &.{},
    watch_start: []const u32 = &.{},
    watchers: []const Watcher = &.{},
    triggered: u32 = 0,
    fan_start: []const u32,
    fan: []const u32,
};

/// `exec.suspendOn`'s terms of the event expression `e`, in its order.
pub fn terms(self: *Emitter, e: Ast.ExprId, out: *std.ArrayList(Term)) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    const edge: Edge = switch (ex.tag(e)) {
        .event_or => {
            try terms(self, ex.lhs(e), out);
            return terms(self, ex.rhs(e), out);
        },
        .event_posedge => .posedge,
        .event_negedge => .negedge,
        .event_function => return self.refuse("a VAMS analog event in a digital event control"),
        .event_driver_update => return self.refuse("VAMS §9.22.5 driver_update"),
        else => .any, // else: a plain name, the one other term checkEvent admits
    };
    const watched = if (edge == .any) e else ex.lhs(e);
    const at = r.slot(watched) catch return self.refuse("an event term the engine resolves only at run time");
    try out.append(self.arena, .{ .slot = at, .edge = edge });
}

/// The plan of `procs`; under `static` each one's `role` is set too.
pub fn build(self: *Emitter, procs: []Proc, schedule: Schedule) Error!Plan {
    const r = self.r;
    const a = self.arena;
    const watched = try a.alloc(bool, r.values.len);
    @memset(watched, false);
    for (0..r.fan_start.len -| 1) |s| watched[s] = r.fan_start[s] != r.fan_start[s + 1];
    var ts: std.ArrayList(Term) = .empty;
    for (procs) |p| for (p.pcs) |pc| {
        r.scope = r.code_scope.items[pc];
        switch (r.code.items[pc]) {
            .wait_event => |e| {
                ts.clearRetainingCapacity();
                try terms(self, e, &ts);
                for (ts.items) |t| watched[t.slot] = true;
            },
            .wait_slots => |slots| for (slots) |s| {
                watched[s] = true;
            },
            .wait_level => |x| for (x.slots) |s| {
                watched[s] = true;
            },
            .sample => |x| {
                const st = r.file.stmt(x.statement).assign;
                if (st.nonblocking or st.timing_is_delay) continue;
                ts.clearRetainingCapacity();
                try terms(self, st.timing, &ts);
                for (ts.items) |t| watched[t.slot] = true;
            },
            // A held slot is never `set`: the store must meet `rt`'s guard.
            .override_eval => |x| watched[x.slot] = true,
            else => {}, // else: only these four wait on a slot's value
        }
    };
    // §17.1.3 a change of a slot the monitor reads asks it to print; a
    // monitor may sit in any subroutine, so every one is looked at.
    var mon: std.ArrayList(u32) = .empty;
    for (r.code.items, 0..) |ins, pc| if (ins == .task and ins.task.task == .monitor) {
        r.scope = r.code_scope.items[pc];
        for (ins.task.args) |arg| if (arg != .none and r.file.exprs.tag(arg) != .str_literal)
            compile.sensitivity(r, arg, &mon) catch return self.refuse("a monitor argument the engine resolves only at run time");
    };
    for (mon.items) |s| watched[s] = true;
    // §18: which slots a `$dumpvars` selects is known only at run time, and
    // a dumped change must reach `rt`'s hook, which `set` bypasses.
    // ponytail: every slot of a dumping design; the catalog's alone if it matters.
    if (emit.dumps(r)) @memset(watched, true);
    if (schedule == .fifo) return .{ .watched = watched, .fan_start = r.fan_start, .fan = r.fan };

    // Candidates for a node, with the slots they read and write.
    // `bits` is null when a node re-runs on any change of an input.
    const Cand = struct { proc: u32, inputs: []const u32, outputs: []const u32, bits: ?Bits = null };
    var cands: std.ArrayList(Cand) = .empty;
    const proc_of = try a.alloc(u32, r.code.items.len);
    for (procs, 0..) |p, i| for (p.pcs) |pc| {
        proc_of[pc] = @intCast(i);
    };
    const reads = try a.alloc(std.ArrayList(u32), procs.len);
    @memset(reads, .empty);
    for (0..r.fan_start.len -| 1) |s| for (r.fan[r.fan_start[s]..r.fan_start[s + 1]]) |pc|
        try reads[proc_of[pc]].append(a, @intCast(s));
    var triggered: u32 = 0;
    const ranges = try disableRanges(self);
    for (procs, 0..) |*p, i| switch (r.code.items[p.entry]) {
        .continuous => |d| try cands.append(a, .{
            .proc = @intCast(i),
            .inputs = reads[i].items,
            .outputs = try a.dupe(u32, &.{r.nets[r.drivers[d].net].slot}),
            .bits = try driverBits(self, d),
        }),
        .wait_event, .wait_slots => if (!disabled(ranges, p.*) and try fixedWait(self, p.*)) {
            p.role = .{ .triggered = triggered };
            triggered += 1;
            if (try combinational(self, p.*)) |io| try cands.append(a, .{
                .proc = @intCast(i),
                .inputs = io.inputs,
                .outputs = io.outputs,
                // §9.7.5: `@*` lists every slot its body reads, so the body
                // is a function of the bits it reads. An explicit list may
                // omit one, and then any change of a listed slot must re-run it.
                .bits = if (r.code.items[p.entry] == .wait_slots) try bodyBits(self, p.*) else null,
            });
        },
        else => {}, // else: anything else suspends where the interpreter says
    };

    // Kahn's order over the candidates; one on or downstream of a cycle
    // stays event-driven.
    // ponytail: downstream of a cycle is demoted too; Tarjan keeps those if a design needs it.
    var readers: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    for (cands.items, 0..) |c, ci| for (c.inputs) |s| {
        const g = try readers.getOrPut(a, s);
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(a, @intCast(ci));
    };
    const indeg = try a.alloc(u32, cands.items.len);
    @memset(indeg, 0);
    for (cands.items) |c| for (c.outputs) |s| if (readers.get(s)) |rs| for (rs.items) |ci| {
        indeg[ci] += 1;
    };
    var queue: std.ArrayList(u32) = .empty;
    for (indeg, 0..) |d, ci| if (d == 0) try queue.append(a, @intCast(ci));
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        for (cands.items[queue.items[head]].outputs) |s| if (readers.get(s)) |rs| for (rs.items) |ci| {
            indeg[ci] -= 1;
            if (indeg[ci] == 0) try queue.append(a, ci);
        };
    }
    const node_pc = try a.alloc(u32, queue.items.len);
    const node_of = try a.alloc(?u32, procs.len);
    @memset(node_of, null);
    for (queue.items, 0..) |ci, n| {
        const p = &procs[cands.items[ci].proc];
        p.role = .{ .comb = @intCast(n) };
        node_of[cands.items[ci].proc] = @intCast(n);
        node_pc[n] = if (r.code.items[p.entry] == .continuous) p.entry else p.entry + 1;
    }

    // Per slot: the nodes it dirties, the watchers it wakes, the drivers
    // still queued by the interpreter's fan-out.
    const per = struct {
        fn table(comptime E: type, al: std.mem.Allocator, lists: []const std.ArrayList(E)) !struct { start: []u32, items: []E } {
            const start = try al.alloc(u32, lists.len + 1);
            var items: std.ArrayList(E) = .empty;
            for (lists, 0..) |l, s| {
                start[s] = @intCast(items.items.len);
                try items.appendSlice(al, l.items);
            }
            start[lists.len] = @intCast(items.items.len);
            return .{ .start = start, .items = items.items };
        }
    };
    const n_slots = r.values.len;
    const comb_lists = try a.alloc(std.ArrayList(Sense), n_slots);
    @memset(comb_lists, .empty);
    for (cands.items) |c| if (node_of[c.proc]) |n| for (c.inputs) |s| {
        // A slot the walk did not see is read whole.
        const masks: ?[]const u64 = if (c.bits) |b| (b.get(s) orelse null) else null;
        for (0..emit.words(r.values[s].width)) |j| {
            const m = if (masks) |ms| ms[j] else std.math.maxInt(u64);
            if (m != 0) try comb_lists[s].append(a, .{ .node = n, .word = self.off[s] + @as(u32, @intCast(j)), .mask = m });
        }
    };
    for (comb_lists) |l| std.mem.sort(Sense, l.items, {}, struct {
        fn lt(_: void, x: Sense, y: Sense) bool {
            return x.word < y.word or (x.word == y.word and x.node < y.node);
        }
    }.lt);
    const comb = try per.table(Sense, a, comb_lists);

    const fan_lists = try a.alloc(std.ArrayList(u32), r.fan_start.len -| 1);
    @memset(fan_lists, .empty);
    for (fan_lists, 0..) |*l, s| for (r.fan[r.fan_start[s]..r.fan_start[s + 1]]) |pc| if (node_of[proc_of[pc]] == null) try l.append(a, pc);
    const fan = try per.table(u32, a, fan_lists);

    const watch_lists = try a.alloc(std.ArrayList(Watcher), n_slots);
    @memset(watch_lists, .empty);
    for (procs) |p| switch (p.role) {
        .triggered => |t| {
            r.scope = r.code_scope.items[p.entry];
            ts.clearRetainingCapacity();
            switch (r.code.items[p.entry]) {
                .wait_event => |e| try terms(self, e, &ts),
                .wait_slots => |slots| for (slots) |s| try ts.append(a, .{ .slot = s, .edge = .any }),
                else => unreachable, // `fixedWait` admits only these two entries
            }
            for (ts.items) |term| try watch_lists[term.slot].append(a, .{ .proc = t, .pc = p.entry + 1, .edge = term.edge });
        },
        .general, .comb => {},
    };
    const watch = try per.table(Watcher, a, watch_lists);

    return .{
        .watched = watched,
        .node_pc = node_pc,
        .comb_start = comb.start,
        .comb = comb.items,
        .watch_start = watch.start,
        .watchers = watch.items,
        .triggered = triggered,
        .fan_start = fan.start,
        .fan = fan.items,
    };
}

/// Does `p` suspend only at its entry, returning there after every pass?
fn fixedWait(self: *Emitter, p: Proc) Error!bool {
    for (p.pcs) |pc| {
        if (pc == p.entry) continue;
        switch (self.r.code.items[pc]) {
            .restart => |x| if (x.target != p.entry) return false,
            .delay, .wait_event, .wait_slots, .wait_level, .continuous, .stop => return false,
            // A synchronous call runs to completion (`emit.call`).
            .assign, .task, .branch, .jump, .case_select, .repeat_start, .repeat_next, .trigger, .init_var, .call => {},
            .sample, .deposit, .disable_block, .disable_task, .copy_out, .call_timed, .task_return, .pla_start, .fork, .join_arm, .override_on, .override_eval, .override_off, .switch_ctrl => return false,
        }
    }
    return true;
}

const Range = struct { lo: u32, hi: u32 };

/// The pc ranges a `disable` (§10.3) stops: a process reaching into one
/// keeps the interpreter's queued resumptions, which a disable cancels by pc.
fn disableRanges(self: *Emitter) Error![]const Range {
    const r = self.r;
    var out: std.ArrayList(Range) = .empty;
    for (r.code.items) |ins| switch (ins) {
        .disable_block => |b| try out.append(self.arena, .{ .lo = b.start, .hi = b.end }),
        .disable_task => |idx| for (r.subs.items[idx].ranges.items) |rg| try out.append(self.arena, .{ .lo = rg.start, .hi = rg.end }),
        else => {}, // else: no other instruction stops another process
    };
    return out.items;
}

fn disabled(ranges: []const Range, p: Proc) bool {
    for (ranges) |rg| for (p.pcs) |pc| if (pc >= rg.lo and pc < rg.hi) return true;
    return false;
}

/// A fixed-wait process that is a node: every term is a plain name (any
/// change), its body writes only whole vectors or selects of them, and it
/// prints nothing. Its inputs are its terms; its outputs what it writes. A
/// system function that writes (`$random`'s seed) would write what is not
/// an output, so a body that calls one is no node.
fn combinational(self: *Emitter, p: Proc) Error!?struct { inputs: []const u32, outputs: []const u32 } {
    const r = self.r;
    const ex = &r.file.exprs;
    var inputs: std.ArrayList(u32) = .empty;
    r.scope = r.code_scope.items[p.entry];
    switch (r.code.items[p.entry]) {
        .wait_event => |e| {
            var ts: std.ArrayList(Term) = .empty;
            try terms(self, e, &ts);
            for (ts.items) |t| {
                if (t.edge != .any) return null;
                try inputs.append(self.arena, t.slot);
            }
        },
        .wait_slots => |slots| try inputs.appendSlice(self.arena, slots),
        else => return null,
    }
    var outputs: std.ArrayList(u32) = .empty;
    for (p.pcs) |pc| {
        r.scope = r.code_scope.items[pc];
        switch (r.code.items[pc]) {
            .assign => |x| {
                if (expr.effects(self, x.value) or expr.effects(self, x.target)) return null;
                const t = if (ex.tag(x.target) == .index) ex.lhs(x.target) else x.target;
                if (ex.tag(t) != .ident and ex.tag(t) != .hier_ident) return null;
                if (try self.element(x.target)) return null;
                try outputs.append(self.arena, r.slot(t) catch return null);
            },
            .task, .trigger, .init_var, .call => return null,
            .branch => |b| if (expr.effects(self, b.condition)) return null,
            .case_select => |c| if (expr.effects(self, r.file.stmt(c.statement).case_stmt.scrutinee)) return null,
            .repeat_start => |x| if (expr.effects(self, x.count)) return null,
            else => {}, // else: `fixedWait` already refused every suspension
        }
    }
    return .{ .inputs = inputs.items, .outputs = outputs.items };
}

/// Per slot, the bits an expression reads, one mask per plane word; null
/// when it reads the whole slot.
const Bits = std.AutoHashMapUnmanaged(u32, ?[]u64);

fn driverBits(self: *Emitter, d: u32) Error!?Bits {
    const r = self.r;
    const x = switch (r.drivers[d].source) {
        .expr => |x| x,
        .bridge, .gate, .udp, .mos, .pull => return null,
    };
    r.scope = r.drivers[d].scope;
    var out: Bits = .empty;
    try readBits(self, x.e, &out);
    return out;
}

/// The bits a combinational body reads: every expression of every
/// instruction `combinational` admits, `compile.readSlots`'s walk.
fn bodyBits(self: *Emitter, p: Proc) Error!?Bits {
    const r = self.r;
    const ex = &r.file.exprs;
    var out: Bits = .empty;
    for (p.pcs) |pc| {
        r.scope = r.code_scope.items[pc];
        switch (r.code.items[pc]) {
            .assign => |x| {
                try readBits(self, x.value, &out);
                var t = x.target;
                while (ex.tag(t) == .index) : (t = ex.lhs(t)) try readBits(self, ex.rhs(t), &out);
            },
            .branch => |b| try readBits(self, b.condition, &out),
            .case_select => |c| {
                const case = r.file.stmt(c.statement).case_stmt;
                try readBits(self, case.scrutinee, &out);
                for (case.arms) |arm| for (arm.labels) |lb| try readBits(self, lb, &out);
            },
            .repeat_start => |x| try readBits(self, x.count, &out),
            .jump, .repeat_next, .restart, .wait_event, .wait_slots => {},
            .delay, .task, .continuous, .wait_level, .sample, .deposit, .trigger, .disable_block, .init_var, .call, .copy_out, .disable_task, .call_timed, .task_return, .pla_start, .fork, .join_arm, .override_on, .override_eval, .override_off, .switch_ctrl, .stop => return null,
        }
    }
    return out;
}

/// Record in `out` the bits `e` reads (`compile.sensitivity`'s walk): a
/// constant select of a vector reads the bits it names (§5.2.1), anything
/// else the whole of every slot it names.
fn readBits(self: *Emitter, e: Ast.ExprId, out: *Bits) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    switch (ex.tag(e)) {
        .ident, .hier_ident => try out.put(self.arena, r.slot(e) catch return self.refuse("a name the engine resolves only at run time"), null),
        .index => if (try self.element(e)) {
            // An element names a slot only at run time: `sensitivity` lists
            // every element, and those it reads whole.
            var x = e;
            while (ex.tag(x) == .index) : (x = ex.lhs(x)) try readBits(self, ex.rhs(x), out);
        } else {
            const at = r.slot(ex.lhs(e)) catch return self.refuse("a name the engine resolves only at run time");
            const rg = ex.rhs(e);
            const sel: ?exec.Sel = if (ex.tag(rg) == .range) blk: {
                const b = r.part_selects.get(.{ .spec = r.specOf(r.scope), .e = e }).?;
                break :blk .{ .first = b.lsb, .count = @intCast(@abs(b.msb - b.lsb) + 1), .step = if (b.msb >= b.lsb) 1 else -1 };
            } else if (compile.constantExpression(r, rg)) blk: {
                const v = exec.eval(r, self.arena, rg, 0) catch return self.refuse("a constant the engine does not fold");
                // An x/z index names no bit.
                break :blk if (v.asInt()) |i| .{ .first = i, .count = 1, .step = 1 } else .{ .first = 0, .count = 0, .step = 1 };
            } else null;
            const g = try out.getOrPut(self.arena, at);
            const s = sel orelse {
                g.value_ptr.* = null;
                return readBits(self, rg, out);
            };
            const width = r.values[at].width;
            if (!g.found_existing) {
                const ms = try self.arena.alloc(u64, emit.words(width));
                @memset(ms, 0);
                g.value_ptr.* = ms;
            }
            const ms = g.value_ptr.* orelse return;
            const range = expr.vecRange(r, at, width);
            for (0..s.count) |i| {
                const index = s.first + @as(i64, @intCast(i)) * s.step;
                const p = if (range.msb >= range.lsb) index - range.lsb else range.lsb - index;
                if (p < 0 or p >= width) continue;
                ms[@intCast(@divFloor(p, 64))] |= @as(u64, 1) << @intCast(@mod(p, 64));
            }
        },
        .int_literal, .logic_literal, .str_literal, .real_literal => {},
        else => { // else: every other form reads what its operands read
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (c != .none) try readBits(self, c, out);
        },
    }
}
