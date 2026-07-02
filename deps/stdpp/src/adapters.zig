const std = @import("std");
const it = @import("iter.zig");
const lanes = @import("lanes.zig");
const has = it.has;

fn addedUpper(a: ?usize, b: ?usize) ?usize {
    return std.math.add(usize, a orelse return null, b orelse return null) catch null;
}
fn addedHints(a: it.SizeHint, b: it.SizeHint) it.SizeHint {
    return .{ .lower = a.lower +| b.lower, .upper = addedUpper(a.upper, b.upper) };
}

pub fn Map(comptime Up: type, comptime Op: type) type {
    return struct {
        pub const Item = it.UnaryResult(Op, Up.Item);
        pub const is_double_ended = Up.is_double_ended;
        pub const is_exact_size = Up.is_exact_size;
        pub const random_access = has(Up, "random_access");
        pub const masked = has(Up, "masked");
        pub const vectorizable = has(Up, "vectorizable") and lanes.isLanewise(Op) and lanes.canLane(Item);
        upstream: Up,
        operation: Op,
        pub fn span(self: *const @This()) usize {
            return self.upstream.span();
        }
        pub fn at(self: *@This(), i: usize) ?Item {
            return it.invoke(&self.operation, .{self.upstream.at(i) orelse return null});
        }
        pub fn block(self: *@This(), comptime N: usize, i: usize) lanes.Block(Item, N) {
            const b = self.upstream.block(N, i);
            return .{ .v = it.invoke(&self.operation, .{b.v}), .m = b.m };
        }
        pub fn advance(self: *@This(), n: usize) void {
            self.upstream.advance(n);
        }
        pub fn next(self: *@This()) ?Item {
            return it.invoke(&self.operation, .{self.upstream.next() orelse return null});
        }
        pub fn nextBack(self: *@This()) ?Item {
            return it.invoke(&self.operation, .{self.upstream.nextBack() orelse return null});
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return self.upstream.sizeHint();
        }
        pub fn len(self: *const @This()) usize {
            return self.upstream.len();
        }
    };
}

pub fn Filter(comptime Up: type, comptime Op: type) type {
    return struct {
        pub const Item = Up.Item;
        pub const is_double_ended = Up.is_double_ended;
        pub const random_access = has(Up, "random_access");
        pub const masked = true;
        pub const vectorizable = has(Up, "vectorizable") and lanes.isLanewise(Op);
        upstream: Up,
        predicate: Op,
        pub fn span(self: *const @This()) usize {
            return self.upstream.span();
        }
        pub fn at(self: *@This(), i: usize) ?Item {
            const item = self.upstream.at(i) orelse return null;
            return if (it.invoke(&self.predicate, .{item})) item else null;
        }
        pub fn block(self: *@This(), comptime N: usize, i: usize) lanes.Block(Item, N) {
            const b = self.upstream.block(N, i);
            const keep: @Vector(N, bool) = it.invoke(&self.predicate, .{b.v});
            return .{ .v = b.v, .m = b.m & keep };
        }
        pub fn advance(self: *@This(), n: usize) void {
            self.upstream.advance(n);
        }
        pub fn next(self: *@This()) ?Item {
            while (self.upstream.next()) |item| if (it.invoke(&self.predicate, .{item})) return item;
            return null;
        }
        pub fn nextBack(self: *@This()) ?Item {
            while (self.upstream.nextBack()) |item| if (it.invoke(&self.predicate, .{item})) return item;
            return null;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return .{ .upper = self.upstream.sizeHint().upper };
        }
    };
}

pub fn FilterMap(comptime Up: type, comptime Op: type, comptime stop_at_null: bool) type {
    return struct {
        pub const Item = it.OptionalChild(it.UnaryResult(Op, Up.Item));
        pub const is_double_ended = !stop_at_null and Up.is_double_ended;
        upstream: Up,
        operation: Op,
        done: bool = false,
        pub fn next(self: *@This()) ?Item {
            if (self.done) return null;
            while (self.upstream.next()) |item| {
                if (it.invoke(&self.operation, .{item})) |value| return value;
                if (stop_at_null) {
                    self.done = true;
                    return null;
                }
            }
            if (stop_at_null) self.done = true;
            return null;
        }
        pub fn nextBack(self: *@This()) ?Item {
            while (self.upstream.nextBack()) |item| if (it.invoke(&self.operation, .{item})) |value| return value;
            return null;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return .{ .upper = if (self.done) 0 else self.upstream.sizeHint().upper };
        }
    };
}

pub fn Inspect(comptime Up: type, comptime Op: type) type {
    return struct {
        pub const Item = Up.Item;
        pub const is_double_ended = Up.is_double_ended;
        pub const is_exact_size = Up.is_exact_size;
        pub const random_access = has(Up, "random_access");
        pub const masked = has(Up, "masked");
        upstream: Up,
        operation: Op,
        pub fn span(self: *const @This()) usize {
            return self.upstream.span();
        }
        pub fn at(self: *@This(), i: usize) ?Item {
            const item = self.upstream.at(i) orelse return null;
            it.invoke(&self.operation, .{item});
            return item;
        }
        pub fn advance(self: *@This(), n: usize) void {
            self.upstream.advance(n);
        }
        pub fn next(self: *@This()) ?Item {
            const item = self.upstream.next() orelse return null;
            it.invoke(&self.operation, .{item});
            return item;
        }
        pub fn nextBack(self: *@This()) ?Item {
            const item = self.upstream.nextBack() orelse return null;
            it.invoke(&self.operation, .{item});
            return item;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return self.upstream.sizeHint();
        }
        pub fn len(self: *const @This()) usize {
            return self.upstream.len();
        }
    };
}

pub fn Take(comptime Up: type) type {
    return struct {
        pub const Item = Up.Item;
        pub const is_double_ended = Up.is_double_ended and Up.is_exact_size;
        pub const is_exact_size = Up.is_exact_size;
        pub const random_access = has(Up, "random_access") and !has(Up, "masked");
        pub const vectorizable = random_access and has(Up, "vectorizable");
        upstream: Up,
        remaining: usize,
        pub fn span(self: *const @This()) usize {
            return @min(self.remaining, self.upstream.span());
        }
        pub fn at(self: *@This(), i: usize) ?Item {
            return self.upstream.at(i);
        }
        pub fn block(self: *@This(), comptime N: usize, i: usize) lanes.Block(Item, N) {
            return self.upstream.block(N, i);
        }
        pub fn advance(self: *@This(), n: usize) void {
            self.remaining -= n;
            self.upstream.advance(n);
        }
        pub fn next(self: *@This()) ?Item {
            if (self.remaining == 0) return null;
            self.remaining -= 1;
            return self.upstream.next();
        }
        pub fn nextBack(self: *@This()) ?Item {
            const keep = self.len();
            if (keep == 0) return null;
            const item = self.upstream.nthBack(self.upstream.len() - keep);
            self.remaining = keep - 1;
            return item;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            const h = self.upstream.sizeHint();
            return .{ .lower = @min(self.remaining, h.lower), .upper = @min(self.remaining, h.upper orelse self.remaining) };
        }
        pub fn len(self: *const @This()) usize {
            return @min(self.remaining, self.upstream.len());
        }
    };
}

pub fn Skip(comptime Up: type) type {
    return struct {
        pub const Item = Up.Item;
        pub const is_double_ended = Up.is_double_ended and Up.is_exact_size;
        pub const is_exact_size = Up.is_exact_size;
        upstream: Up,
        remaining: usize,
        pub fn next(self: *@This()) ?Item {
            const n = self.remaining;
            self.remaining = 0;
            return self.upstream.nth(n);
        }
        pub fn nextBack(self: *@This()) ?Item {
            if (self.len() == 0) return null;
            return self.upstream.nextBack();
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            const h = self.upstream.sizeHint();
            return .{ .lower = h.lower -| self.remaining, .upper = if (h.upper) |n| n -| self.remaining else null };
        }
        pub fn len(self: *const @This()) usize {
            return self.upstream.len() -| self.remaining;
        }
    };
}

pub fn StepBy(comptime Up: type) type {
    return struct {
        pub const Item = Up.Item;
        pub const is_double_ended = Up.is_double_ended and Up.is_exact_size;
        pub const is_exact_size = Up.is_exact_size;
        upstream: Up,
        step: usize,
        first: bool = true,
        fn countFor(self: *const @This(), n: usize) usize {
            return if (self.first) n / self.step + @intFromBool(n % self.step != 0) else n / self.step;
        }
        pub fn next(self: *@This()) ?Item {
            const skip = if (self.first) 0 else self.step - 1;
            self.first = false;
            return self.upstream.nth(skip);
        }
        pub fn nextBack(self: *@This()) ?Item {
            if (self.len() == 0) return null;
            const trailing = (self.upstream.len() - @intFromBool(self.first)) % self.step;
            return self.upstream.nthBack(trailing);
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            const h = self.upstream.sizeHint();
            return .{ .lower = self.countFor(h.lower), .upper = if (h.upper) |n| self.countFor(n) else null };
        }
        pub fn len(self: *const @This()) usize {
            return self.countFor(self.upstream.len());
        }
    };
}

pub fn While(comptime Up: type, comptime Op: type, comptime taking: bool) type {
    return struct {
        pub const Item = Up.Item;
        upstream: Up,
        predicate: Op,
        boundary: bool = false,
        pub fn next(self: *@This()) ?Item {
            if (taking and self.boundary) return null;
            while (self.upstream.next()) |item| {
                if (!taking and self.boundary) return item;
                if (it.invoke(&self.predicate, .{item})) {
                    if (taking) return item;
                } else {
                    self.boundary = true;
                    return if (taking) null else item;
                }
            }
            return null;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            if (taking and self.boundary) return .{ .upper = 0 };
            if (!taking and self.boundary) return self.upstream.sizeHint();
            return .{ .upper = self.upstream.sizeHint().upper };
        }
    };
}

pub fn Enumerate(comptime Up: type) type {
    return struct {
        pub const Item = struct { index: usize, value: Up.Item };
        pub const is_double_ended = Up.is_double_ended and Up.is_exact_size;
        pub const is_exact_size = Up.is_exact_size;
        pub const random_access = has(Up, "random_access") and !has(Up, "masked");
        pub const vectorizable = random_access and has(Up, "vectorizable");
        upstream: Up,
        index: usize = 0,
        pub fn span(self: *const @This()) usize {
            return self.upstream.span();
        }
        pub fn at(self: *@This(), i: usize) ?Item {
            return .{ .index = self.index + i, .value = self.upstream.at(i) orelse return null };
        }
        pub fn block(self: *@This(), comptime N: usize, i: usize) lanes.Block(Item, N) {
            const b = self.upstream.block(N, i);
            const base: @Vector(N, usize) = @splat(self.index + i);
            return .{ .v = .{ .index = std.simd.iota(usize, N) + base, .value = b.v }, .m = b.m };
        }
        pub fn advance(self: *@This(), n: usize) void {
            self.index += n;
            self.upstream.advance(n);
        }
        pub fn next(self: *@This()) ?Item {
            const item = self.upstream.next() orelse return null;
            const result = Item{ .index = self.index, .value = item };
            self.index += 1;
            return result;
        }
        pub fn nextBack(self: *@This()) ?Item {
            const item = self.upstream.nextBack() orelse return null;
            return .{ .index = self.index + self.upstream.len(), .value = item };
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return self.upstream.sizeHint();
        }
        pub fn len(self: *const @This()) usize {
            return self.upstream.len();
        }
    };
}

pub fn Chain(comptime Left: type, comptime Right: type) type {
    if (Left.Item != Right.Item) @compileError("chain sources must have the same Item type");
    return struct {
        pub const Item = Left.Item;
        pub const is_double_ended = Left.is_double_ended and Right.is_double_ended;
        left: Left,
        right: Right,
        left_done: bool = false,
        right_done: bool = false,
        pub fn next(self: *@This()) ?Item {
            if (!self.left_done) {
                if (self.left.next()) |item| return item;
                self.left_done = true;
            }
            if (!self.right_done) {
                if (self.right.next()) |item| return item;
                self.right_done = true;
            }
            return null;
        }
        pub fn nextBack(self: *@This()) ?Item {
            if (!self.right_done) {
                if (self.right.nextBack()) |item| return item;
                self.right_done = true;
            }
            if (!self.left_done) {
                if (self.left.nextBack()) |item| return item;
                self.left_done = true;
            }
            return null;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return addedHints(if (self.left_done) .{ .upper = 0 } else self.left.sizeHint(), if (self.right_done) .{ .upper = 0 } else self.right.sizeHint());
        }
    };
}

pub fn Zip(comptime Left: type, comptime Right: type) type {
    return struct {
        pub const Item = struct { left: Left.Item, right: Right.Item };
        pub const is_exact_size = Left.is_exact_size and Right.is_exact_size;
        pub const is_double_ended = Left.is_double_ended and Right.is_double_ended and is_exact_size;
        pub const random_access = has(Left, "random_access") and has(Right, "random_access") and
            !has(Left, "masked") and !has(Right, "masked");
        pub const vectorizable = random_access and has(Left, "vectorizable") and has(Right, "vectorizable");
        left: Left,
        right: Right,
        done: bool = false,
        /// Unlike next(), never evaluates the longer side past the shorter one.
        pub fn span(self: *const @This()) usize {
            return if (self.done) 0 else @min(self.left.span(), self.right.span());
        }
        pub fn at(self: *@This(), i: usize) ?Item {
            return .{ .left = self.left.at(i) orelse return null, .right = self.right.at(i) orelse return null };
        }
        pub fn block(self: *@This(), comptime N: usize, i: usize) lanes.Block(Item, N) {
            const a = self.left.block(N, i);
            const b = self.right.block(N, i);
            return .{ .v = .{ .left = a.v, .right = b.v }, .m = a.m & b.m };
        }
        pub fn advance(self: *@This(), n: usize) void {
            self.left.advance(n);
            self.right.advance(n);
        }
        pub fn next(self: *@This()) ?Item {
            if (self.done) return null;
            const a = self.left.next() orelse {
                self.done = true;
                return null;
            };
            const b = self.right.next() orelse {
                self.done = true;
                return null;
            };
            return .{ .left = a, .right = b };
        }
        pub fn nextBack(self: *@This()) ?Item {
            if (self.done) return null;
            const common = self.len();
            while (self.left.len() > common) _ = self.left.nextBack();
            while (self.right.len() > common) _ = self.right.nextBack();
            if (common == 0) {
                self.done = true;
                return null;
            }
            return .{ .left = self.left.nextBack().?, .right = self.right.nextBack().? };
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            if (self.done) return .{ .upper = 0 };
            const a = self.left.sizeHint();
            const b = self.right.sizeHint();
            const upper = if (a.upper) |n| @as(?usize, @min(n, b.upper orelse n)) else b.upper;
            return .{ .lower = @min(a.lower, b.lower), .upper = upper };
        }
        pub fn len(self: *const @This()) usize {
            return if (self.done) 0 else @min(self.left.len(), self.right.len());
        }
    };
}

pub fn Flatten(comptime Up: type) type {
    const Inner = it.Iterator(Up.Item);
    return struct {
        pub const Item = Inner.Item;
        pub const is_double_ended = Up.is_double_ended and Inner.is_double_ended;
        upstream: Up,
        front: ?Inner = null,
        back: ?Inner = null,
        outer_done: bool = false,
        pub fn next(self: *@This()) ?Item {
            while (true) {
                if (self.front) |*inner| {
                    if (inner.next()) |item| return item;
                    self.front = null;
                }
                if (!self.outer_done) {
                    if (self.upstream.next()) |inner| {
                        self.front = it.from(inner);
                        continue;
                    }
                    self.outer_done = true;
                }
                if (self.back) |*inner| {
                    if (inner.next()) |item| return item;
                    self.back = null;
                }
                return null;
            }
        }
        pub fn nextBack(self: *@This()) ?Item {
            while (true) {
                if (self.back) |*inner| {
                    if (inner.nextBack()) |item| return item;
                    self.back = null;
                }
                if (!self.outer_done) {
                    if (self.upstream.nextBack()) |inner| {
                        self.back = it.from(inner);
                        continue;
                    }
                    self.outer_done = true;
                }
                if (self.front) |*inner| {
                    if (inner.nextBack()) |item| return item;
                    self.front = null;
                }
                return null;
            }
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            if (self.outer_done and self.front == null and self.back == null) return .{ .upper = 0 };
            return .{};
        }
    };
}

pub fn Scan(comptime Up: type, comptime Acc: type, comptime Op: type) type {
    return struct {
        pub const Item = it.OptionalChild(it.CallResult(Op, @TypeOf(.{ @as(*Acc, undefined), @as(Up.Item, undefined) })));
        upstream: Up,
        accumulator: Acc,
        operation: Op,
        pub fn next(self: *@This()) ?Item {
            const item = self.upstream.next() orelse return null;
            return it.invoke(&self.operation, .{ &self.accumulator, item });
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return .{ .upper = self.upstream.sizeHint().upper };
        }
    };
}

pub fn Fuse(comptime Up: type) type {
    return struct {
        pub const Item = Up.Item;
        pub const is_double_ended = Up.is_double_ended;
        pub const is_exact_size = Up.is_exact_size;
        upstream: Up,
        done: bool = false,
        pub fn next(self: *@This()) ?Item {
            if (self.done) return null;
            const item = self.upstream.next() orelse {
                self.done = true;
                return null;
            };
            return item;
        }
        pub fn nextBack(self: *@This()) ?Item {
            if (self.done) return null;
            const item = self.upstream.nextBack() orelse {
                self.done = true;
                return null;
            };
            return item;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return if (self.done) .{ .upper = 0 } else self.upstream.sizeHint();
        }
        pub fn len(self: *const @This()) usize {
            return if (self.done) 0 else self.upstream.len();
        }
    };
}

pub fn Peekable(comptime Up: type) type {
    return struct {
        pub const Item = Up.Item;
        pub const is_double_ended = Up.is_double_ended;
        pub const is_exact_size = Up.is_exact_size;
        upstream: Up,
        cached: bool = false,
        value: ?Item = null,
        pub fn peek(self: *@This()) ?Item {
            if (!self.cached) {
                self.value = self.upstream.next();
                self.cached = true;
            }
            return self.value;
        }
        pub fn next(self: *@This()) ?Item {
            if (!self.cached) return self.upstream.next();
            self.cached = false;
            return self.value;
        }
        pub fn nextBack(self: *@This()) ?Item {
            if (!self.cached) return self.upstream.nextBack();
            if (self.value == null) return null;
            if (self.upstream.nextBack()) |item| return item;
            self.cached = false;
            return self.value;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            if (!self.cached) return self.upstream.sizeHint();
            if (self.value == null) return .{ .upper = 0 };
            return addedHints(self.upstream.sizeHint(), .{ .lower = 1, .upper = 1 });
        }
        pub fn len(self: *const @This()) usize {
            if (!self.cached) return self.upstream.len();
            return if (self.value == null) 0 else self.upstream.len() + 1;
        }
    };
}

pub fn Reverse(comptime Up: type) type {
    return struct {
        pub const Item = Up.Item;
        pub const is_double_ended = true;
        pub const is_exact_size = Up.is_exact_size;
        upstream: Up,
        pub fn next(self: *@This()) ?Item {
            return self.upstream.nextBack();
        }
        pub fn nextBack(self: *@This()) ?Item {
            return self.upstream.next();
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return self.upstream.sizeHint();
        }
        pub fn len(self: *const @This()) usize {
            return self.upstream.len();
        }
    };
}

pub fn Cycle(comptime Up: type) type {
    return struct {
        pub const Item = Up.Item;
        original: Up,
        current: Up,
        done: bool = false,
        pub fn next(self: *@This()) ?Item {
            if (self.done) return null;
            if (self.current.next()) |item| return item;
            self.current = self.original;
            const item = self.current.next() orelse {
                self.done = true;
                return null;
            };
            return item;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            if (self.done) return .{ .upper = 0 };
            // Shared pointer captures can change a copy's behavior, so even an
            // originally nonempty source doesn't prove this is infinite.
            return .{};
        }
    };
}

pub fn Intersperse(comptime Up: type) type {
    return struct {
        pub const Item = Up.Item;
        upstream: Up,
        separator: Item,
        pending: ?Item = null,
        first: bool = true,
        done: bool = false,
        pub fn next(self: *@This()) ?Item {
            if (self.done) return null;
            if (self.pending) |item| {
                self.pending = null;
                return item;
            }
            const item = self.upstream.next() orelse {
                self.done = true;
                return null;
            };
            if (self.first) {
                self.first = false;
                return item;
            }
            self.pending = item;
            return self.separator;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return if (self.done) .{ .upper = 0 } else .{};
        }
    };
}

pub fn Chunks(comptime Up: type, comptime capacity: usize) type {
    return struct {
        pub const Item = it.Chunk(Up.Item, capacity);
        pub const is_exact_size = Up.is_exact_size;
        upstream: Up,
        pub fn next(self: *@This()) ?Item {
            const chunk = self.upstream.nextChunk(capacity);
            return if (chunk.len == 0) null else chunk;
        }
        fn count(n: usize) usize {
            return n / capacity + @intFromBool(n % capacity != 0);
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            const h = self.upstream.sizeHint();
            return .{ .lower = count(h.lower), .upper = if (h.upper) |n| count(n) else null };
        }
        pub fn len(self: *const @This()) usize {
            return count(self.upstream.len());
        }
    };
}

pub fn Copied(comptime Up: type) type {
    if (@typeInfo(Up.Item) != .pointer or @typeInfo(Up.Item).pointer.size != .one)
        @compileError("copied requires single-item pointers");
    return struct {
        pub const Item = @typeInfo(Up.Item).pointer.child;
        pub const is_double_ended = Up.is_double_ended;
        pub const is_exact_size = Up.is_exact_size;
        upstream: Up,
        pub fn next(self: *@This()) ?Item {
            return (self.upstream.next() orelse return null).*;
        }
        pub fn nextBack(self: *@This()) ?Item {
            return (self.upstream.nextBack() orelse return null).*;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return self.upstream.sizeHint();
        }
        pub fn len(self: *const @This()) usize {
            return self.upstream.len();
        }
    };
}
