//! The processes of a native design -> how `rt.State` schedules each.
//!
//! In: every process `emit.native` found, as the pcs it reaches from its
//! entry. Out: which slots anything can wait on (a store to any other slot
//! wakes no one, so it is a plain store), and under the `static` schedule a
//! role per process with the tables that run it: combinational nodes in
//! topological order with the slots that dirty them, and the watchers of
//! the processes that wait at one fixed event control.
//!
//! Clauses: IEEE 1364-2005 §11.4.1 (active events in any order), §6.1
//! continuous assignment, §9.7.5 `@*`, §9.7.2 edges.
const std = @import("std");
const Ast = @import("frontend").Ast;
const emit = @import("emit.zig");
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

pub const Plan = struct {
    /// Per slot: an event control, driver or node may wait on it.
    watched: []const bool,
    /// Per node, the pc its evaluation starts at.
    node_pc: []const u32 = &.{},
    comb_start: []const u32 = &.{},
    comb: []const u32 = &.{},
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
            else => {}, // else: only these three wait on a slot's value
        }
    };
    if (schedule == .fifo) return .{ .watched = watched, .fan_start = r.fan_start, .fan = r.fan };

    // Candidates for a node, with the slots they read and write.
    const Cand = struct { proc: u32, inputs: []const u32, outputs: []const u32 };
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
    for (procs, 0..) |*p, i| switch (r.code.items[p.entry]) {
        .continuous => |d| try cands.append(a, .{ .proc = @intCast(i), .inputs = reads[i].items, .outputs = try a.dupe(u32, &.{r.nets[r.drivers[d].net].slot}) }),
        .wait_event, .wait_slots => if (try fixedWait(self, p.*)) {
            p.role = .{ .triggered = triggered };
            triggered += 1;
            if (try combinational(self, p.*)) |io| try cands.append(a, .{ .proc = @intCast(i), .inputs = io.inputs, .outputs = io.outputs });
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
        fn table(al: std.mem.Allocator, lists: []const std.ArrayList(u32)) !struct { start: []u32, items: []u32 } {
            const start = try al.alloc(u32, lists.len + 1);
            var items: std.ArrayList(u32) = .empty;
            for (lists, 0..) |l, s| {
                start[s] = @intCast(items.items.len);
                try items.appendSlice(al, l.items);
            }
            start[lists.len] = @intCast(items.items.len);
            return .{ .start = start, .items = items.items };
        }
    };
    const n_slots = r.values.len;
    const comb_lists = try a.alloc(std.ArrayList(u32), n_slots);
    @memset(comb_lists, .empty);
    for (cands.items) |c| if (node_of[c.proc]) |n| for (c.inputs) |s| try comb_lists[s].append(a, n);
    const comb = try per.table(a, comb_lists);

    const fan_lists = try a.alloc(std.ArrayList(u32), r.fan_start.len -| 1);
    @memset(fan_lists, .empty);
    for (fan_lists, 0..) |*l, s| for (r.fan[r.fan_start[s]..r.fan_start[s + 1]]) |pc| if (node_of[proc_of[pc]] == null) try l.append(a, pc);
    const fan = try per.table(a, fan_lists);

    var watch_lists = try a.alloc(std.ArrayList(Watcher), n_slots);
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
    const watch_start = try a.alloc(u32, n_slots + 1);
    var watchers: std.ArrayList(Watcher) = .empty;
    for (watch_lists, 0..) |l, s| {
        watch_start[s] = @intCast(watchers.items.len);
        try watchers.appendSlice(a, l.items);
    }
    watch_start[n_slots] = @intCast(watchers.items.len);

    return .{
        .watched = watched,
        .node_pc = node_pc,
        .comb_start = comb.start,
        .comb = comb.items,
        .watch_start = watch_start,
        .watchers = watchers.items,
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
            .assign, .task, .branch, .jump, .case_select, .repeat_start, .repeat_next, .trigger, .init_var => {},
            .sample, .deposit, .disable_block, .disable_task, .call, .copy_out, .call_timed, .task_return, .pla_start, .fork, .join_arm, .override_on, .override_eval, .override_off, .switch_ctrl => return false,
        }
    }
    return true;
}

/// A fixed-wait process that is a node: every term is a plain name (any
/// change), its body writes only whole vectors or selects of them, and it
/// prints nothing. Its inputs are its terms; its outputs what it writes.
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
                const t = if (ex.tag(x.target) == .index) ex.lhs(x.target) else x.target;
                if (ex.tag(t) != .ident and ex.tag(t) != .hier_ident) return null;
                if (try self.element(x.target)) return null;
                try outputs.append(self.arena, r.slot(t) catch return null);
            },
            .task, .trigger, .init_var => return null,
            else => {}, // else: `fixedWait` already refused every suspension
        }
    }
    return .{ .inputs = inputs.items, .outputs = outputs.items };
}
