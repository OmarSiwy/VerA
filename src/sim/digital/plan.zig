//! The processes of a native design -> how `rt.State` schedules each: the
//! slots anything can wait on (a store to any other is a plain store), and
//! under `static` a role per process with its tables: combinational nodes in
//! topological order with the bits that dirty them, and the watchers of
//! processes with one fixed event control. Also `stepLocal` for `--state=auto`.
//! IEEE 1364-2005 §11.4.2 (active events in any order), §6.1, §9.7.2, §9.7.5, §5.2.1.
const std = @import("std");
const Ast = @import("frontend").Ast;
const compile = @import("compile.zig");
const exec = @import("exec.zig");
const emit = @import("emit.zig");
const expr = @import("emit_expr.zig");
const Emitter = emit.Emitter;
const Error = emit.Error;
pub const Reach = @import("../rt/root.zig").Reach;

pub const Schedule = enum { fifo, static };

pub const Edge = enum { any, posedge, negedge };
/// `sel`: the term reads one bit of the slot, bit `bit` of value word `word`.
pub const Term = struct { slot: u32, edge: Edge, sel: ?struct { word: u32, bit: u6 } = null };

pub const Role = union(enum) {
    /// Queued and woken by the interpreter's rules.
    general,
    /// Suspends only at its entry, an event control whose terms are
    /// static; `rt.State.waiting[n]` holds its suspension stamp there,
    /// 0 while it runs.
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
    /// Per slot: what a change of it can wake.
    reach: []const Reach,
    /// Per node, the pc its evaluation starts at.
    node_pc: []const u32 = &.{},
    /// Per slot, the bits its node readers read, ascending by word
    /// (`rt.Design.comb`).
    comb_start: []const u32 = &.{},
    comb: []const Sense = &.{},
    /// Per slot, the triggered processes it wakes (`rt.Design.watchers`).
    watch_start: []const u32 = &.{},
    watchers: []const Watcher = &.{},
    /// The number of triggered processes.
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
        else => .any, // else: a plain name or bit-select, the other terms checkEvent admits
    };
    const src = r.eventBit(if (edge == .any) e else ex.lhs(e)) catch return self.refuse("an event term the engine resolves only at run time");
    try out.append(self.arena, .{
        .slot = src.slot,
        .edge = edge,
        .sel = if (src.bit == exec.whole_slot) null else .{ .word = self.off[src.slot] + src.bit / 64, .bit = @intCast(src.bit % 64) },
    });
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
    if (schedule == .fifo) return .{
        .watched = watched,
        .reach = try reachOf(self, procs, mon.items, r.fan_start, &.{}, &.{}),
        .fan_start = r.fan_start,
        .fan = r.fan,
    };

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
        // A resolved net's driver is queued: `rt.net` delays or folds it.
        .continuous => |d| if (emit.plainDriver(r, d)) try cands.append(a, .{
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

    // A node whose output an event control waits on stays a queued driver
    // or triggered process. `vera --run` queues each level of logic behind
    // what was queued before it ran, so a process started in between waits
    // before the output changes; one settle event would change it first.
    const waited = try reachOf(self, procs, mon.items, &.{}, &.{}, &.{});
    var kept: usize = 0;
    for (cands.items) |c| {
        if (for (c.outputs) |o| {
            if (waited[o].terms) break true;
        } else false) continue;
        cands.items[kept] = c;
        kept += 1;
    }
    cands.shrinkRetainingCapacity(kept);

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
    const order = try coneOrder(a, cands.items, queue.items);
    const node_pc = try a.alloc(u32, order.len);
    const node_of = try a.alloc(?u32, procs.len);
    @memset(node_of, null);
    for (order, 0..) |ci, n| {
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
        .reach = try reachOf(self, procs, mon.items, fan.start, comb.start, watch.start),
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

/// Per slot, what its change can wake: the tables' rows, an event control
/// a process files (every wait but a triggered process's or a node's entry;
/// a subroutine a process calls never waits), the monitor, a dump.
fn reachOf(self: *Emitter, procs: []const Proc, mon: []const u32, fan_start: []const u32, comb_start: []const u32, watch_start: []const u32) Error![]const Reach {
    const r = self.r;
    const reach = try self.arena.alloc(Reach, r.values.len);
    @memset(reach, .{});
    const has = struct {
        fn f(start: []const u32, s: usize) bool {
            return s + 1 < start.len and start[s] != start[s + 1];
        }
    }.f;
    for (reach, 0..) |*x, s| {
        x.fan = has(fan_start, s);
        x.comb = has(comb_start, s);
        x.watch = has(watch_start, s);
    }
    var ts: std.ArrayList(Term) = .empty;
    for (procs) |p| for (p.pcs) |pc| {
        if (pc == p.entry and p.role != .general) continue;
        r.scope = r.code_scope.items[pc];
        switch (r.code.items[pc]) {
            .wait_event => |e| {
                ts.clearRetainingCapacity();
                try terms(self, e, &ts);
                for (ts.items) |t| reach[t.slot].terms = true;
            },
            .wait_slots => |slots| for (slots) |s| {
                reach[s].terms = true;
            },
            .wait_level => |x| for (x.slots) |s| {
                reach[s].terms = true;
            },
            .sample => |x| {
                const st = r.file.stmt(x.statement).assign;
                if (st.nonblocking or st.timing_is_delay) continue;
                ts.clearRetainingCapacity();
                try terms(self, st.timing, &ts);
                for (ts.items) |t| reach[t.slot].terms = true;
            },
            else => {}, // else: only these four file an event control
        }
    };
    for (mon) |s| reach[s].mon = true;
    if (emit.dumps(r)) for (reach) |*x| {
        x.dump = true;
    };
    return reach;
}

/// `acyclic` (Kahn's order of the candidates that are nodes) reordered cone
/// by cone: a depth-first post-order over each node's writers, deepest
/// first, from the last node back, so a node lands just after the nodes it
/// reads, and mostly in their dirty word. Any topological order is one
/// §11.4.2 permits for the settle event.
fn coneOrder(a: std.mem.Allocator, cands: anytype, acyclic: []const u32) Error![]const u32 {
    var writers: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    for (acyclic) |ci| for (cands[ci].outputs) |s| {
        const g = try writers.getOrPut(a, s);
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(a, ci);
    };
    // Per node, the nodes that write what it reads, by longest path from a
    // source, deepest first: the chain a node ends is laid down before the
    // shallow inputs that join it.
    const level = try a.alloc(u32, cands.len);
    const preds = try a.alloc([]u32, cands.len);
    for (acyclic) |ci| {
        var ps: std.ArrayList(u32) = .empty;
        level[ci] = 0;
        for (cands[ci].inputs) |s| if (writers.get(s)) |l| for (l.items) |w| {
            try ps.append(a, w);
            level[ci] = @max(level[ci], level[w] + 1);
        };
        preds[ci] = ps.items;
    }
    for (acyclic) |ci| std.mem.sort(u32, preds[ci], level, struct {
        fn deeper(lv: []const u32, x: u32, y: u32) bool {
            return lv[x] > lv[y];
        }
    }.deeper);
    const done = try a.alloc(bool, cands.len);
    @memset(done, false);
    const Frame = struct { ci: u32, next: u32 = 0 };
    var stack: std.ArrayList(Frame) = .empty;
    var order: std.ArrayList(u32) = .empty;
    var i = acyclic.len;
    while (i > 0) {
        i -= 1;
        if (done[acyclic[i]]) continue;
        done[acyclic[i]] = true;
        try stack.append(a, .{ .ci = acyclic[i] });
        while (stack.items.len != 0) {
            const f = &stack.items[stack.items.len - 1];
            if (f.next == preds[f.ci].len) {
                try order.append(a, f.ci);
                _ = stack.pop();
                continue;
            }
            const w = preds[f.ci][f.next];
            f.next += 1;
            if (done[w]) continue;
            done[w] = true;
            try stack.append(a, .{ .ci = w });
        }
    }
    return order.items;
}

/// Does `p` suspend only at its entry, returning there after every pass?
fn fixedWait(self: *Emitter, p: Proc) Error!bool {
    // A term on one bit keeps its last value, which only `State.watch` holds.
    if (self.r.code.items[p.entry] == .wait_event) {
        self.r.scope = self.r.code_scope.items[p.entry];
        var ts: std.ArrayList(Term) = .empty;
        try terms(self, self.r.code.items[p.entry].wait_event, &ts);
        for (ts.items) |t| if (t.sel != null) return false;
    }
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
/// change) of a value, not a named event, its body writes only whole vectors or selects of them, and it
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
                // §9.7.3 a named event holds no value, so no change of one
                // would ever dirty a node.
                if (t.edge != .any or r.events.contains(t.slot)) return null;
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
            const width = r.values[at].width;
            const range = expr.vecRange(r, at, width);
            const sel: ?exec.Sel = if (ex.tag(rg) == .range) blk: {
                const b = r.part_selects.get(.{ .spec = r.specOf(r.scope), .e = e }).?;
                break :blk .{ .first = range.position(b.lsb), .count = @intCast(@abs(b.msb - b.lsb) + 1) };
            } else if (compile.constantExpression(r, rg)) blk: {
                const v = exec.eval(r, self.arena, rg, 0) catch return self.refuse("a constant the engine does not fold");
                // An x/z index names no bit.
                break :blk if (v.asInt()) |i| .{ .first = range.position(i), .count = 1 } else .{ .first = 0, .count = 0 };
            } else null;
            const g = try out.getOrPut(self.arena, at);
            const s = sel orelse {
                g.value_ptr.* = null;
                return readBits(self, rg, out);
            };
            if (!g.found_existing) {
                const ms = try self.arena.alloc(u64, emit.words(width));
                @memset(ms, 0);
                g.value_ptr.* = ms;
            }
            const ms = g.value_ptr.* orelse return;
            for (0..s.count) |i| {
                const p = s.first + @as(i64, @intCast(i));
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

/// The slots `rt.Design.dead` names. At a time-step boundary every process
/// is suspended; a slot is dead there when each read of it, in every
/// activation, follows a whole-slot blocking write in that activation, so
/// the value it holds at the boundary is never read (`rt.State.boundary`).
/// Activations follow `emit.reach`'s control flow: a suspension, a fork, a
/// `disable` resumes a process in a new one, which starts knowing nothing
/// written; a subroutine body starts knowing its inputs (§10.2.2 copy-in).
/// A slot something outside the processes reads (`Plan.watched`: an event
/// control, a driver, a node, the monitor, a dump) is never dead.
pub fn stepLocal(self: *Emitter, procs: []const Proc) Error![]const u32 {
    const r = self.r;
    const a = self.arena;
    const n = r.code.items.len;
    // The candidates: slots some instruction writes whole, as bit indices.
    const bit = try a.alloc(?u32, r.values.len);
    @memset(bit, null);
    var cands: std.ArrayList(u32) = .empty;
    const writes = try a.alloc(?u32, n);
    for (writes, 0..) |*w, pc| {
        w.* = null;
        const at = wholeWrite(self, @intCast(pc)) orelse continue;
        if (self.watched[at] or r.reals.contains(at)) continue;
        if (bit[at] == null) {
            bit[at] = @intCast(cands.items.len);
            try cands.append(a, at);
        }
        w.* = bit[at];
    }
    if (cands.items.len == 0) return &.{};
    const nw = (cands.items.len + 63) / 64;
    // Per pc, the candidates written on every path into it this activation.
    // ponytail: pcs x candidates bits; per-process sets if that outgrows memory.
    const in = try a.alloc(u64, n * nw);
    @memset(in, std.math.maxInt(u64));
    const seen = try a.alloc(bool, n);
    @memset(seen, false);
    var work: std.ArrayList(u32) = .empty;
    const none = try a.alloc(u64, nw);
    @memset(none, 0);
    for (procs) |p| try meet(a, in, seen, &work, nw, p.entry, none);
    for (self.subs_todo.items) |idx| {
        const sub = r.subs.items[idx];
        const known = try a.dupe(u64, none);
        for (sub.decl.ports, sub.frame.ports) |port, at| if (port.direction != .output) if (bit[at]) |b| {
            known[b / 64] |= @as(u64, 1) << @intCast(b % 64);
        };
        try meet(a, in, seen, &work, nw, sub.entry, known);
    }
    const out = try a.alloc(u64, nw);
    while (work.pop()) |pc| {
        @memcpy(out, in[pc * nw ..][0..nw]);
        if (writes[pc]) |b| out[b / 64] |= @as(u64, 1) << @intCast(b % 64);
        if (self.block_ends.get(pc)) |ends| for (ends.items) |e| try meet(a, in, seen, &work, nw, e, none);
        const next = pc + 1;
        switch (r.code.items[pc]) {
            .stop, .continuous => {},
            .jump => |t| try meet(a, in, seen, &work, nw, t, out),
            .restart => |x| try meet(a, in, seen, &work, nw, x.target, out),
            .branch => |b| for ([_]u32{ next, b.otherwise }) |t| try meet(a, in, seen, &work, nw, t, out),
            .case_select => |c| {
                try meet(a, in, seen, &work, nw, c.fallback, out);
                const arms = r.file.stmt(c.statement).case_stmt.arms.len;
                for (r.case_targets.items[c.targets..][0..arms]) |t| try meet(a, in, seen, &work, nw, t, out);
            },
            .repeat_start => |x| for ([_]u32{ next, x.end }) |t| try meet(a, in, seen, &work, nw, t, out),
            .repeat_next => |x| for ([_]u32{ next, x.body }) |t| try meet(a, in, seen, &work, nw, t, out),
            .task => |t| if (t.task != .finish) try meet(a, in, seen, &work, nw, next, out),
            .assign, .init_var, .trigger, .deposit, .call, .copy_out, .override_eval, .override_off => try meet(a, in, seen, &work, nw, next, out),
            .delay, .wait_event, .wait_slots, .wait_level, .sample => try meet(a, in, seen, &work, nw, next, none),
            .disable_block => |b| {
                try meet(a, in, seen, &work, nw, next, out);
                if (pc >= b.start and pc < b.end) try meet(a, in, seen, &work, nw, b.end, out);
            },
            .disable_task => |idx| {
                try meet(a, in, seen, &work, nw, next, out);
                for (r.subs.items[idx].ranges.items) |rg| if (pc >= rg.start and pc < rg.end) try meet(a, in, seen, &work, nw, rg.end, out);
            },
            .pla_start => |loop| for ([_]u32{ next, loop }) |t| try meet(a, in, seen, &work, nw, t, none),
            .fork => |f| for (if (f.arms.len == 0) &[_]u32{f.end} else f.arms) |t| try meet(a, in, seen, &work, nw, t, none),
            .join_arm => |j| try meet(a, in, seen, &work, nw, j.end, none),
            .override_on => |o| {
                try meet(a, in, seen, &work, nw, next, out);
                try meet(a, in, seen, &work, nw, o.start, none);
            },
            .call_timed, .task_return, .switch_ctrl => return &.{}, // `emit.reach` refuses these
        }
    }
    // A read of a candidate not written before it in its activation keeps
    // the candidate's boundary value alive.
    const live = try a.alloc(bool, cands.items.len);
    @memset(live, false);
    var reads: std.ArrayList(u32) = .empty;
    for (0..n) |pc| if (seen[pc]) {
        reads.clearRetainingCapacity();
        if (!try readsAt(self, @intCast(pc), &reads)) return &.{};
        for (reads.items) |at| if (at < bit.len) if (bit[at]) |b| {
            if (in[pc * nw + b / 64] >> @intCast(b % 64) & 1 == 0) live[b] = true;
        };
    };
    var dead: std.ArrayList(u32) = .empty;
    for (cands.items, live) |at, l| if (!l) try dead.append(a, at);
    return dead.items;
}

/// `in[to] &= set`; `to` is queued when that is its first set or changes it.
fn meet(a: std.mem.Allocator, in: []u64, seen: []bool, work: *std.ArrayList(u32), nw: usize, to: u32, set: []const u64) Error!void {
    var changed = !seen[to];
    for (in[to * nw ..][0..nw], set) |*w, s| {
        changed = changed or w.* & s != w.*;
        w.* &= s;
    }
    seen[to] = true;
    if (changed) try work.append(a, to);
}

/// The slot the instruction at `pc` writes whole with a blocking write.
fn wholeWrite(self: *Emitter, pc: u32) ?u32 {
    const r = self.r;
    const ex = &r.file.exprs;
    r.scope = r.code_scope.items[pc];
    const target = switch (r.code.items[pc]) {
        .init_var => |x| return x.slot,
        .assign => |x| if (x.nonblocking) return null else x.target,
        .copy_out => |x| x.target,
        else => return null, // else: only these three write a slot at their own pc
    };
    if (ex.tag(target) != .ident and ex.tag(target) != .hier_ident) return null;
    return r.slot(target) catch null;
}

/// Append every slot the instruction at `pc` reads; false when a name
/// does not resolve to one.
fn readsAt(self: *Emitter, pc: u32, out: *std.ArrayList(u32)) Error!bool {
    const r = self.r;
    const ex = &r.file.exprs;
    r.scope = r.code_scope.items[pc];
    switch (r.code.items[pc]) {
        .assign => |x| {
            if (ex.tag(x.target) != .ident and ex.tag(x.target) != .hier_ident) if (!try exprReads(self, x.target, out)) return false;
            return exprReads(self, x.value, out);
        },
        .copy_out => |x| {
            try out.append(self.arena, x.slot);
            if (ex.tag(x.target) != .ident and ex.tag(x.target) != .hier_ident) return exprReads(self, x.target, out);
            return true;
        },
        .init_var => |x| return exprReads(self, x.value, out),
        .delay => |x| return exprReads(self, x.amount, out),
        .task => |t| for (t.args) |e| if (!try exprReads(self, e, out)) return false,
        .branch => |b| return exprReads(self, b.condition, out),
        .case_select => |c| {
            const cs = r.file.stmt(c.statement).case_stmt;
            if (!try exprReads(self, cs.scrutinee, out)) return false;
            for (cs.arms) |arm| for (arm.labels) |l| if (!try exprReads(self, l, out)) return false;
        },
        .repeat_start => |x| return exprReads(self, x.count, out),
        .wait_event => |e| return exprReads(self, e, out),
        .wait_level => |x| return exprReads(self, x.cond, out),
        .sample => |x| return stmtReads(self, x.statement, out),
        .deposit => |x| return stmtReads(self, x.statement, out),
        .call => |x| for (x.args) |e| if (!try exprReads(self, e, out)) return false,
        .override_eval => |x| return exprReads(self, x.value, out),
        .continuous, .wait_slots, .trigger, .restart, .jump, .stop, .disable_block, .disable_task, .fork, .join_arm, .pla_start, .override_on, .override_off, .repeat_next, .switch_ctrl, .call_timed, .task_return => {},
    }
    return true;
}

fn stmtReads(self: *Emitter, s: Ast.StmtId, out: *std.ArrayList(u32)) Error!bool {
    var v: StmtReads = .{ .self = self, .out = out };
    try self.r.file.stmtEdges(s, &v);
    return v.ok;
}

/// `readsAt` of a statement's own expressions, both edges: a target's
/// selects are read, and reading its base too only keeps more alive.
const StmtReads = struct {
    self: *Emitter,
    out: *std.ArrayList(u32),
    ok: bool = true,

    pub fn expr(v: *StmtReads, e: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {
        if (v.ok) v.ok = try exprReads(v.self, e, v.out);
    }

    pub fn stmt(_: *StmtReads, _: Ast.StmtId) Error!void {}
};

/// Append every slot `e` reads, a function call's result among them.
fn exprReads(self: *Emitter, e: Ast.ExprId, out: *std.ArrayList(u32)) Error!bool {
    if (e == .none) return true;
    const r = self.r;
    const ex = &r.file.exprs;
    switch (ex.tag(e)) {
        .ident, .hier_ident => {
            try out.append(self.arena, r.slot(e) catch return false);
            return true;
        },
        .call => {
            const idx = r.sub_base.get(r.instanceOf(r.scope)).? + r.call_subs.get(e).?;
            try out.append(self.arena, r.subs.items[idx].frame.result);
        },
        else => {}, // else: every other form reads only through its children
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (!try exprReads(self, c, out)) return false;
    return true;
}
