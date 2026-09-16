//! VAMS-2023 §8.5 / IEEE1364-2005 §11 event queues.
//! Payloads index caller-owned execution records. The caller executes each
//! returned event before calling next again; this module does not evaluate HDL.
const std = @import("std");

/// Integer ticks at the design's finest time precision. Scaling/rounding belongs
/// to elaboration; all 64 bits are retained, including times above 2^53.
pub const Time = u64;

/// Six current-time regions. The future heap is the seventh logical region.
/// VAMS §8.5.1 and §8.5.3.6 put explicit D2A before inactive; §8.5.2's
/// pseudocode reverses these two. We follow the explicit normative ordering;
/// see docs/simulator-scheduler.md for this unresolved standards discrepancy.
pub const Region = enum(u3) { active, explicit_d2a, inactive, nba, analog, monitor };
pub const FutureKind = enum(u1) {
    inactive,
    nba,

    fn region(self: FutureKind) Region {
        return switch (self) {
            .inactive => .inactive,
            .nba => .nba,
        };
    }
};

const SlotId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Handle = struct { slot: SlotId, generation: u32 };
pub const Event = struct { time: Time, region: Region, payload: u32, handle: Handle };

const State = enum(u2) { pending, cancelled, free, retired };
// MultiArrayList separates queue traversal/cancellation from payload dispatch.
const Slot = struct {
    next: SlotId = .none,
    payload: u32,
    generation: u32 = 0,
    region: Region,
    state: State = .pending,
};

// Heap entries move together; comparisons read the time/order key, and removal
// reads the slot. Slot storage cannot be reused while its entry is in the heap.
const Future = struct {
    time: Time,
    order: u64,
    slot: SlotId,

    fn compare(_: void, a: Future, b: Future) std.math.Order {
        return if (a.time == b.time) std.math.order(a.order, b.order) else std.math.order(a.time, b.time);
    }
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    now: Time = 0,
    slots: std.MultiArrayList(Slot) = .empty,
    heads: [6]SlotId = @splat(.none),
    tails: [6]SlotId = @splat(.none),
    future: std.PriorityQueue(Future, void, Future.compare) = .empty,
    free: SlotId = .none,
    sequence: u64 = 0,
    phase: union(enum) { idle, dispatch: Region, stopped } = .idle,

    pub const Error = std.mem.Allocator.Error || error{
        TooManyEvents,
        SequenceOverflow,
        TimeOverflow,
        TimeInPast,
        MonitorMutation,
        Stopped,
    };

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scheduler) void {
        self.slots.deinit(self.allocator);
        self.future.deinit(self.allocator);
        self.* = undefined;
    }

    /// Schedule at now. A2D notifications use ordinary active events; the caller
    /// posts analog requests when an implicit/explicit D2A dependency needs one.
    pub fn schedule(self: *Scheduler, region: Region, payload: u32) Error!Handle {
        try self.checkMutation();
        const handle = try self.allocate(region, payload);
        self.append(region, handle.slot);
        return handle;
    }

    /// Future work has precisely the two categories specified by §8.5.1.
    /// At the current time, inactive means #0; NBA stays in the NBA region.
    pub fn scheduleAt(self: *Scheduler, time: Time, kind: FutureKind, payload: u32) Error!Handle {
        try self.checkMutation();
        if (time < self.now) return error.TimeInPast;
        if (time == self.now) return self.schedule(kind.region(), payload);
        if (self.sequence == std.math.maxInt(u64)) return error.SequenceOverflow;
        const handle = try self.allocate(kind.region(), payload);
        errdefer self.release(handle.slot);
        try self.future.push(self.allocator, .{ .time = time, .order = self.sequence, .slot = handle.slot });
        self.sequence += 1;
        return handle;
    }

    pub fn scheduleAfter(self: *Scheduler, delay: Time, kind: FutureKind, payload: u32) Error!Handle {
        try self.checkMutation();
        const time = std.math.add(Time, self.now, delay) catch return error.TimeOverflow;
        return self.scheduleAt(time, kind, payload);
    }

    /// A handle only cancels its original pending event. Cancellation is lazy:
    /// its queue retains the slot until removal, preventing reuse under a heap
    /// entry or FIFO link. Cancelled future entries never advance the clock.
    pub fn cancel(self: *Scheduler, handle: Handle) Error!bool {
        try self.checkMutation();
        const index = @intFromEnum(handle.slot);
        if (index >= self.slots.len or self.slots.items(.generation)[index] != handle.generation or
            self.slots.items(.state)[index] != .pending) return false;
        self.slots.items(.state)[index] = .cancelled;
        return true;
    }

    /// Explicit termination discards pending dispatches; deinit releases their
    /// storage. This does not synthesize analog final_step or HDL finalization.
    pub fn finish(self: *Scheduler) void {
        self.phase = .stopped;
    }

    /// Complete the preceding dispatch and return one active event. Promotion
    /// moves a whole region into active; newly scheduled active work joins its
    /// tail. FIFO is our permitted choice among otherwise unordered active work,
    /// while preserving the mandated order of NBA updates (§11.4.1).
    ///
    /// During a returned monitor event, schedule/cancel reject mutation until
    /// the caller invokes next again. Empty returns null without changing time.
    pub fn next(self: *Scheduler) ?Event {
        if (self.phase == .stopped) return null;
        self.phase = .idle;
        while (true) {
            while (self.take(.active)) |slot| {
                const index = @intFromEnum(slot);
                if (self.slots.items(.state)[index] == .cancelled) {
                    self.release(slot);
                    continue;
                }
                const event: Event = .{
                    .time = self.now,
                    .region = self.slots.items(.region)[index],
                    .payload = self.slots.items(.payload)[index],
                    .handle = .{ .slot = slot, .generation = self.slots.items(.generation)[index] },
                };
                if (event.region == .analog) self.consumeAnalog(event.payload);
                self.release(slot);
                self.phase = .{ .dispatch = event.region };
                return event;
            }
            var promoted = false;
            inline for (.{ Region.explicit_d2a, Region.inactive, Region.nba, Region.analog, Region.monitor }) |region| {
                if (!promoted and self.heads[@intFromEnum(region)] != .none) {
                    self.heads[0] = self.heads[@intFromEnum(region)];
                    self.tails[0] = self.tails[@intFromEnum(region)];
                    self.heads[@intFromEnum(region)] = .none;
                    self.tails[@intFromEnum(region)] = .none;
                    promoted = true;
                }
            }
            if (promoted) continue;
            if (!self.advance()) return null;
        }
    }

    fn checkMutation(self: *const Scheduler) Error!void {
        switch (self.phase) {
            .stopped => return error.Stopped,
            .dispatch => |region| if (region == .monitor) return error.MonitorMutation,
            .idle => {},
        }
    }

    fn allocate(self: *Scheduler, region: Region, payload: u32) Error!Handle {
        const slot = if (self.free != .none) blk: {
            const id = self.free;
            const index = @intFromEnum(id);
            self.free = self.slots.items(.next)[index];
            self.slots.items(.next)[index] = .none;
            self.slots.items(.payload)[index] = payload;
            self.slots.items(.region)[index] = region;
            self.slots.items(.state)[index] = .pending;
            break :blk id;
        } else blk: {
            if (self.slots.len == std.math.maxInt(u32)) return error.TooManyEvents;
            const id: SlotId = @enumFromInt(self.slots.len);
            try self.slots.append(self.allocator, .{ .payload = payload, .region = region });
            break :blk id;
        };
        return .{ .slot = slot, .generation = self.slots.items(.generation)[@intFromEnum(slot)] };
    }

    fn release(self: *Scheduler, slot: SlotId) void {
        const index = @intFromEnum(slot);
        if (self.slots.items(.generation)[index] == std.math.maxInt(u32)) {
            // Exhausted generations retire permanently; stale handles never alias.
            self.slots.items(.state)[index] = .retired;
            return;
        }
        self.slots.items(.generation)[index] += 1;
        self.slots.items(.state)[index] = .free;
        self.slots.items(.next)[index] = self.free;
        self.free = slot;
    }

    fn append(self: *Scheduler, region: Region, slot: SlotId) void {
        const r = @intFromEnum(region);
        if (self.tails[r] == .none) {
            self.heads[r] = slot;
        } else self.slots.items(.next)[@intFromEnum(self.tails[r])] = slot;
        self.tails[r] = slot;
    }

    fn take(self: *Scheduler, region: Region) ?SlotId {
        const r = @intFromEnum(region);
        const slot = self.heads[r];
        if (slot == .none) return null;
        self.heads[r] = self.slots.items(.next)[@intFromEnum(slot)];
        if (self.heads[r] == .none) self.tails[r] = .none;
        self.slots.items(.next)[@intFromEnum(slot)] = .none;
        return slot;
    }

    fn advance(self: *Scheduler) bool {
        // Purge dead minima before choosing a time: cancellation must not cause
        // a phantom timestep, including when every future event was cancelled.
        while (self.future.peek()) |entry| {
            if (self.slots.items(.state)[@intFromEnum(entry.slot)] != .cancelled) break;
            _ = self.future.pop();
            self.release(entry.slot);
        }
        const first = self.future.peek() orelse return false;
        self.now = first.time;
        while (self.future.peek()) |entry| {
            if (entry.time != self.now) break;
            _ = self.future.pop();
            const index = @intFromEnum(entry.slot);
            if (self.slots.items(.state)[index] == .cancelled) {
                self.release(entry.slot);
            } else self.append(self.slots.items(.region)[index], entry.slot);
        }
        return true;
    }

    fn consumeAnalog(self: *Scheduler, payload: u32) void {
        // §8.5.3.7 consumes all ACTIVE requests for this macro-process in one
        // solve. A later request remains eligible for a new solve after feedback.
        // ponytail: linear scan of this active wave; add a per-macro index only
        // if measured large analog waves justify maintaining a second index.
        var previous: SlotId = .none;
        var cursor = self.heads[0];
        while (cursor != .none) {
            const index = @intFromEnum(cursor);
            const following = self.slots.items(.next)[index];
            if (self.slots.items(.region)[index] == .analog and self.slots.items(.payload)[index] == payload) {
                if (previous == .none) self.heads[0] = following else self.slots.items(.next)[@intFromEnum(previous)] = following;
                if (self.tails[0] == cursor) self.tails[0] = previous;
                self.release(cursor);
            } else previous = cursor;
            cursor = following;
        }
    }
};

const t = std.testing;

test "seven logical regions follow normative AMS order and integer future time" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    // Deliberately enqueue in reverse region order. Future NBA was enqueued
    // before future inactive, but the latter resumes before the NBA updates.
    _ = try scheduler.scheduleAt(7, .nba, 8);
    _ = try scheduler.scheduleAt(7, .inactive, 7);
    _ = try scheduler.schedule(.monitor, 6);
    _ = try scheduler.schedule(.analog, 5);
    _ = try scheduler.schedule(.nba, 4);
    _ = try scheduler.schedule(.inactive, 3);
    _ = try scheduler.schedule(.explicit_d2a, 2);
    _ = try scheduler.schedule(.active, 1);
    const regions = [_]Region{ .active, .explicit_d2a, .inactive, .nba, .analog, .monitor, .inactive, .nba };
    for (regions, 1..) |region, payload| {
        const event = scheduler.next().?;
        try t.expectEqual(payload, event.payload);
        try t.expectEqual(region, event.region);
        try t.expectEqual(@as(Time, if (payload < 7) 0 else 7), event.time);
    }
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 7), scheduler.now);
}

test "NBA batch, inactive reentry and analog feedback settle before monitor" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    var value: u32 = 0;
    _ = try scheduler.schedule(.monitor, 10);
    _ = try scheduler.schedule(.analog, 6);
    _ = try scheduler.schedule(.nba, 1);
    _ = try scheduler.schedule(.nba, 2);
    var trace: [10]u32 = undefined;
    var count: usize = 0;
    while (scheduler.next()) |event| {
        trace[count] = event.payload;
        count += 1;
        switch (event.payload) {
            1 => {
                value = 1;
                _ = try scheduler.schedule(.active, 3);
            },
            2 => {
                value = 2;
                _ = try scheduler.schedule(.inactive, 4);
            },
            3 => try t.expectEqual(@as(u32, 2), value),
            4 => {
                _ = try scheduler.schedule(.nba, 5);
            },
            5 => value = 3,
            6 => {
                try t.expectEqual(@as(u32, 3), value);
                // The analog consumer publishes an ordinary active A2D event.
                _ = try scheduler.schedule(.active, 7);
            },
            7 => {
                value = 4;
                _ = try scheduler.schedule(.analog, 9);
                _ = try scheduler.schedule(.explicit_d2a, 8);
            },
            8, 9, 10 => try t.expectEqual(@as(u32, 4), value),
            else => unreachable,
        }
        try t.expectEqual(@as(Time, 0), event.time);
    }
    try t.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, trace[0..count]);
}

test "whole inactive promotion uses FIFO active choice and permits another delta" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    _ = try scheduler.scheduleAfter(0, .inactive, 1);
    _ = try scheduler.schedule(.inactive, 2);
    try t.expectEqual(@as(u32, 1), scheduler.next().?.payload);
    _ = try scheduler.schedule(.active, 3);
    _ = try scheduler.schedule(.inactive, 4);
    // Once promoted, the remaining inactive event is an active event too.
    for ([_]u32{ 2, 3, 4 }) |payload| try t.expectEqual(payload, scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
}

test "analog solve consumes active duplicates but later feedback requests run" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    _ = try scheduler.schedule(.analog, 10);
    _ = try scheduler.schedule(.analog, 20);
    const duplicate = try scheduler.schedule(.analog, 10);
    _ = try scheduler.schedule(.analog, 10);
    try t.expectEqual(@as(u32, 10), scheduler.next().?.payload);
    try t.expect(!try scheduler.cancel(duplicate));
    _ = try scheduler.schedule(.analog, 10); // new request after the first solve
    _ = try scheduler.schedule(.active, 30);
    for ([_]u32{ 20, 30, 10 }) |payload| try t.expectEqual(payload, scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "monitor dispatch rejects event mutation until the caller completes it" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    const later = try scheduler.scheduleAt(10, .inactive, 3);
    _ = try scheduler.schedule(.monitor, 1);
    _ = try scheduler.schedule(.monitor, 2);
    for ([_]u32{ 1, 2 }) |payload| {
        try t.expectEqual(payload, scheduler.next().?.payload);
        try t.expectError(error.MonitorMutation, scheduler.schedule(.active, 99));
        try t.expectError(error.MonitorMutation, scheduler.scheduleAt(20, .inactive, 99));
        try t.expectError(error.MonitorMutation, scheduler.cancel(later));
    }
    try t.expectEqual(@as(u32, 3), scheduler.next().?.payload);
    _ = try scheduler.schedule(.active, 4);
    try t.expectEqual(@as(u32, 4), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "cancelling earliest or all future events does not create phantom times" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    const first = try scheduler.scheduleAt(2, .inactive, 1);
    const second = try scheduler.scheduleAt(3, .nba, 2);
    _ = try scheduler.scheduleAt(9, .nba, 3);
    try t.expect(try scheduler.cancel(first));
    try t.expect(try scheduler.cancel(second));
    try t.expect(!try scheduler.cancel(first));
    const event = scheduler.next().?;
    try t.expectEqual(@as(u32, 3), event.payload);
    try t.expectEqual(@as(Time, 9), event.time);
    try t.expect(!try scheduler.cancel(event.handle));
    const last = try scheduler.scheduleAt(100, .inactive, 4);
    try t.expect(try scheduler.cancel(last));
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 9), scheduler.now);
}

test "current cancellation and generation retirement cannot alias new events" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    const old = try scheduler.schedule(.active, 1);
    try t.expect(try scheduler.cancel(old));
    try t.expect(scheduler.next() == null);
    const replacement = try scheduler.schedule(.active, 2);
    try t.expectEqual(old.slot, replacement.slot);
    try t.expect(old.generation != replacement.generation);
    try t.expect(!try scheduler.cancel(old));
    try t.expectEqual(@as(u32, 2), scheduler.next().?.payload);
    var exhausted = try scheduler.schedule(.active, 3);
    exhausted.generation = std.math.maxInt(u32);
    scheduler.slots.items(.generation)[@intFromEnum(exhausted.slot)] = exhausted.generation;
    try t.expect(try scheduler.cancel(exhausted));
    try t.expect(scheduler.next() == null);
    const fresh = try scheduler.schedule(.active, 4);
    try t.expect(fresh.slot != exhausted.slot);
    try t.expect(!try scheduler.cancel(exhausted));
    try t.expectEqual(@as(u32, 4), scheduler.next().?.payload);
}

test "timestamps exceed float precision and overflow cannot wrap into the past" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    const large: Time = (1 << 53) + 1;
    _ = try scheduler.scheduleAt(large + 1, .inactive, 2);
    _ = try scheduler.scheduleAt(large, .inactive, 1);
    try t.expectEqual(large, scheduler.next().?.time);
    try t.expectEqual(large + 1, scheduler.next().?.time);
    try t.expectError(error.TimeInPast, scheduler.scheduleAt(large, .nba, 3));
    _ = try scheduler.scheduleAt(std.math.maxInt(Time), .nba, 4);
    try t.expectEqual(std.math.maxInt(Time), scheduler.next().?.time);
    try t.expectError(error.TimeOverflow, scheduler.scheduleAfter(1, .inactive, 5));
    _ = try scheduler.scheduleAfter(0, .nba, 6);
    try t.expectEqual(@as(u32, 6), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "future NBA insertion order is preserved even with recycled slots" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    _ = try scheduler.schedule(.active, 0);
    _ = try scheduler.schedule(.active, 0);
    _ = scheduler.next();
    _ = scheduler.next();
    const first = try scheduler.scheduleAt(10, .nba, 1);
    const second = try scheduler.scheduleAt(10, .nba, 2);
    try t.expect(@intFromEnum(first.slot) > @intFromEnum(second.slot));
    try t.expectEqual(@as(u32, 1), scheduler.next().?.payload);
    try t.expectEqual(@as(u32, 2), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
}

test "finish is terminal and does not advance or dispatch queued events" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    const pending = try scheduler.schedule(.active, 1);
    _ = try scheduler.scheduleAt(50, .nba, 2);
    scheduler.finish();
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
    try t.expectError(error.Stopped, scheduler.schedule(.active, 3));
    try t.expectError(error.Stopped, scheduler.cancel(pending));
    scheduler.finish();
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    for (0..64) |i| {
        _ = try scheduler.schedule(.active, @intCast(i));
        _ = try scheduler.scheduleAt(1 + @as(Time, @intCast(i)), .nba, @intCast(i));
    }
    var count: usize = 0;
    while (scheduler.next() != null) count += 1;
    try t.expectEqual(@as(usize, 128), count);
}

test "allocation failure releases queue storage and partial future insertion" {
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{});
}

test "failed future allocation leaves prior queue work and reusable slots intact" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var scheduler = Scheduler.init(failing.allocator());
    defer scheduler.deinit();
    _ = try scheduler.schedule(.active, 1);
    _ = try scheduler.schedule(.active, 2);
    _ = scheduler.next(); // one reusable slot; the other event stays pending
    failing.fail_index = failing.alloc_index;
    try t.expectError(error.OutOfMemory, scheduler.scheduleAt(10, .nba, 99));
    failing.fail_index = std.math.maxInt(usize);
    _ = try scheduler.schedule(.active, 3);
    for ([_]u32{ 2, 3 }) |payload| try t.expectEqual(payload, scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
    _ = try scheduler.scheduleAt(10, .nba, 4);
    try t.expectEqual(@as(u32, 4), scheduler.next().?.payload);
}

test "future sequence exhaustion reports before changing queued work" {
    var scheduler = Scheduler.init(t.allocator);
    defer scheduler.deinit();
    _ = try scheduler.schedule(.active, 1);
    scheduler.sequence = std.math.maxInt(u64);
    try t.expectError(error.SequenceOverflow, scheduler.scheduleAt(10, .nba, 99));
    try t.expectEqual(@as(u32, 1), scheduler.next().?.payload);
    try t.expect(scheduler.next() == null);
    try t.expectEqual(@as(Time, 0), scheduler.now);
}
