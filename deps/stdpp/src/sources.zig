const std = @import("std");
const it = @import("iter.zig");
const lanes = @import("lanes.zig");

pub fn Ref(comptime Source: type) type {
    return struct {
        pub const Item = Source.Item;
        pub const is_double_ended = it.hasBack(Source);
        pub const is_exact_size = it.hasLen(Source);
        source: *Source,
        pub fn next(self: *@This()) ?Item {
            return self.source.next();
        }
        pub fn nextBack(self: *@This()) ?Item {
            return self.source.nextBack();
        }
        pub fn len(self: *const @This()) usize {
            return self.source.len();
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            if (@hasDecl(Source, "sizeHint")) return self.source.sizeHint();
            if (is_exact_size) return .{ .lower = self.len(), .upper = self.len() };
            return .{};
        }
    };
}

fn Slice(comptime T: type, comptime mode: enum { value, reference, mutable }) type {
    return struct {
        pub const Item = switch (mode) {
            .value => T,
            .reference => *const T,
            .mutable => *T,
        };
        pub const random_access = mode == .value;
        pub const vectorizable = mode == .value and lanes.canLane(T);
        items: if (mode == .mutable) []T else []const T,
        pub fn span(self: *const @This()) usize {
            return self.items.len;
        }
        pub fn at(self: *@This(), i: usize) ?Item {
            return self.items[i];
        }
        pub fn block(self: *@This(), comptime N: usize, i: usize) lanes.Block(T, N) {
            return .{ .v = lanes.load(T, N, self.items[i..][0..N]), .m = @splat(true) };
        }
        pub fn advance(self: *@This(), n: usize) void {
            self.items = self.items[n..];
        }
        pub fn next(self: *@This()) ?Item {
            if (self.items.len == 0) return null;
            const value = if (mode == .value) self.items[0] else &self.items[0];
            self.items = self.items[1..];
            return value;
        }
        pub fn nextBack(self: *@This()) ?Item {
            if (self.items.len == 0) return null;
            const index = self.items.len - 1;
            const value = if (mode == .value) self.items[index] else &self.items[index];
            self.items = self.items[0..index];
            return value;
        }
        pub fn len(self: *const @This()) usize {
            return self.items.len;
        }
    };
}

pub fn fromSlice(comptime T: type, items: []const T) it.Iterator(Slice(T, .value)) {
    return .{ .state = .{ .items = items } };
}
pub fn fromSliceRef(comptime T: type, items: []const T) it.Iterator(Slice(T, .reference)) {
    return .{ .state = .{ .items = items } };
}
pub fn fromSliceMut(comptime T: type, items: []T) it.Iterator(Slice(T, .mutable)) {
    return .{ .state = .{ .items = items } };
}

fn Array(comptime A: type) type {
    if (@typeInfo(A) != .array) @compileError("fromArray takes an array value");
    return struct {
        pub const Item = @typeInfo(A).array.child;
        pub const random_access = true;
        pub const vectorizable = lanes.canLane(Item);
        items: A,
        front: usize = 0,
        back: usize = @typeInfo(A).array.len,
        pub fn next(self: *@This()) ?Item {
            if (self.front == self.back) return null;
            const value = self.items[self.front];
            self.front += 1;
            return value;
        }
        pub fn nextBack(self: *@This()) ?Item {
            if (self.front == self.back) return null;
            self.back -= 1;
            return self.items[self.back];
        }
        pub fn len(self: *const @This()) usize {
            return self.back - self.front;
        }
        pub fn span(self: *const @This()) usize {
            return self.back - self.front;
        }
        pub fn at(self: *@This(), i: usize) ?Item {
            return self.items[self.front + i];
        }
        pub fn block(self: *@This(), comptime N: usize, i: usize) lanes.Block(Item, N) {
            return .{ .v = lanes.load(Item, N, self.items[self.front + i ..][0..N]), .m = @splat(true) };
        }
        pub fn advance(self: *@This(), n: usize) void {
            self.front += n;
        }
    };
}
pub fn fromArray(items: anytype) it.Iterator(Array(@TypeOf(items))) {
    return .{ .state = .{ .items = items } };
}

pub const Range = struct {
    pub const Item = usize;
    pub const random_access = true;
    pub const vectorizable = true;
    front: usize,
    back: usize,
    pub fn next(self: *@This()) ?Item {
        if (self.front == self.back) return null;
        const value = self.front;
        self.front += 1;
        return value;
    }
    pub fn nextBack(self: *@This()) ?Item {
        if (self.front == self.back) return null;
        self.back -= 1;
        return self.back;
    }
    pub fn len(self: *const @This()) usize {
        return self.back - self.front;
    }
    pub fn span(self: *const @This()) usize {
        return self.back - self.front;
    }
    pub fn at(self: *@This(), i: usize) ?Item {
        return self.front + i;
    }
    pub fn block(self: *@This(), comptime N: usize, i: usize) lanes.Block(usize, N) {
        return .{ .v = std.simd.iota(usize, N) + @as(@Vector(N, usize), @splat(self.front + i)), .m = @splat(true) };
    }
    pub fn advance(self: *@This(), n: usize) void {
        self.front += n;
    }
};
pub fn range(start: usize, end: usize) it.Iterator(Range) {
    return .{ .state = .{ .front = start, .back = @max(start, end) } };
}

fn Empty(comptime T: type) type {
    return struct {
        pub const Item = T;
        pub fn next(_: *@This()) ?T {
            return null;
        }
        pub fn nextBack(_: *@This()) ?T {
            return null;
        }
        pub fn len(_: *const @This()) usize {
            return 0;
        }
    };
}
pub fn empty(comptime T: type) it.Iterator(Empty(T)) {
    return .{ .state = .{} };
}

fn Once(comptime T: type) type {
    return struct {
        pub const Item = T;
        value: ?T,
        pub fn next(self: *@This()) ?T {
            const value = self.value;
            self.value = null;
            return value;
        }
        pub fn nextBack(self: *@This()) ?T {
            return self.next();
        }
        pub fn len(self: *const @This()) usize {
            return @intFromBool(self.value != null);
        }
    };
}
pub fn once(value: anytype) it.Iterator(Once(@TypeOf(value))) {
    return .{ .state = .{ .value = value } };
}

fn Repeat(comptime T: type) type {
    return struct {
        pub const Item = T;
        value: T,
        pub fn next(self: *@This()) ?T {
            return self.value;
        }
        pub fn nextBack(self: *@This()) ?T {
            return self.value;
        }
        pub fn sizeHint(_: *const @This()) it.SizeHint {
            return .{ .lower = std.math.maxInt(usize) };
        }
    };
}
pub fn repeat(value: anytype) it.Iterator(Repeat(@TypeOf(value))) {
    return .{ .state = .{ .value = value } };
}

fn Function(comptime Op: type, comptime optional: bool) type {
    const Result = it.CallResult(Op, @TypeOf(.{}));
    return struct {
        pub const Item = if (optional) it.OptionalChild(Result) else Result;
        operation: Op,
        pub fn next(self: *@This()) ?Item {
            return it.invoke(&self.operation, .{});
        }
        pub fn sizeHint(_: *const @This()) it.SizeHint {
            return if (optional) .{} else .{ .lower = std.math.maxInt(usize) };
        }
    };
}
pub fn fromFn(operation: anytype) it.Iterator(Function(it.Callback(@TypeOf(operation)), true)) {
    return .{ .state = .{ .operation = operation } };
}
pub fn repeatWith(operation: anytype) it.Iterator(Function(it.Callback(@TypeOf(operation)), false)) {
    return .{ .state = .{ .operation = operation } };
}

fn Successors(comptime T: type, comptime Op: type) type {
    return struct {
        pub const Item = T;
        value: ?T,
        operation: Op,
        pub fn next(self: *@This()) ?T {
            const value = self.value orelse return null;
            self.value = it.invoke(&self.operation, .{value});
            return value;
        }
        pub fn sizeHint(self: *const @This()) it.SizeHint {
            return if (self.value == null) .{ .upper = 0 } else .{ .lower = 1 };
        }
    };
}
pub fn successors(comptime T: type, first: ?T, operation: anytype) it.Iterator(Successors(T, it.Callback(@TypeOf(operation)))) {
    return .{ .state = .{ .value = first, .operation = operation } };
}

/// Struct-of-arrays rows: each field loads as its own contiguous vector.
fn Rows(comptime T: type) type {
    const M = std.MultiArrayList(T);
    const s = @typeInfo(T).@"struct";
    return struct {
        pub const Item = T;
        pub const random_access = true;
        pub const vectorizable = lanes.canLane(T);
        rows: M.Slice,
        front: usize = 0,
        back: usize,
        pub fn next(self: *@This()) ?T {
            if (self.front == self.back) return null;
            self.front += 1;
            return self.rows.get(self.front - 1);
        }
        pub fn nextBack(self: *@This()) ?T {
            if (self.front == self.back) return null;
            self.back -= 1;
            return self.rows.get(self.back);
        }
        pub fn len(self: *const @This()) usize {
            return self.back - self.front;
        }
        pub fn span(self: *const @This()) usize {
            return self.back - self.front;
        }
        pub fn at(self: *@This(), i: usize) ?T {
            return self.rows.get(self.front + i);
        }
        pub fn block(self: *@This(), comptime N: usize, i: usize) lanes.Block(T, N) {
            var v: lanes.Lanes(T, N) = undefined;
            inline for (s.field_names, s.field_types) |name, F| {
                const column = self.rows.items(@field(M.Field, name));
                @field(v, name) = lanes.load(F, N, column[self.front + i ..][0..N]);
            }
            return .{ .v = v, .m = @splat(true) };
        }
        pub fn advance(self: *@This(), n: usize) void {
            self.front += n;
        }
    };
}

fn MultiElem(comptime C: type) ?type {
    if (@typeInfo(C) != .@"struct") return null;
    const List = if (@hasDecl(C, "toMultiArrayList")) @typeInfo(@TypeOf(C.toMultiArrayList)).@"fn".return_type.? else C;
    if (!@hasDecl(List, "Slice") or @typeInfo(List.Slice) != .@"struct" or !@hasDecl(List.Slice, "get")) return null;
    const Elem = @typeInfo(@TypeOf(List.Slice.get)).@"fn".return_type.?;
    return if (C == std.MultiArrayList(Elem) or C == std.MultiArrayList(Elem).Slice) Elem else null;
}

fn Of(comptime C: type) type {
    const B = if (@typeInfo(C) == .pointer and @typeInfo(C).pointer.size == .one and @typeInfo(@typeInfo(C).pointer.child) != .array)
        @typeInfo(C).pointer.child
    else
        C;
    if (MultiElem(B)) |E| return it.Iterator(Rows(E));
    const S = if (@typeInfo(B) == .@"struct" and @hasField(B, "items")) @FieldType(B, "items") else B;
    const E = switch (@typeInfo(S)) {
        .pointer => |p| if (p.size == .slice) p.child else @typeInfo(p.child).array.child,
        else => @compileError("iter.of: unsupported container " ++ @typeName(C)),
    };
    return it.Iterator(Slice(E, .value));
}

/// Iterate any contiguous container by value: slices, array pointers,
/// ArrayList (anything with an `items` slice), MultiArrayList and its Slice.
/// The container must outlive the iterator and not be resized meanwhile.
pub fn of(container: anytype) Of(@TypeOf(container)) {
    const C = @TypeOf(container);
    const one = @typeInfo(C) == .pointer and @typeInfo(C).pointer.size == .one and @typeInfo(@typeInfo(C).pointer.child) != .array;
    const c = if (one) container.* else container;
    if (comptime MultiElem(@TypeOf(c)) != null) {
        const rows = if (@hasDecl(@TypeOf(c), "toMultiArrayList")) c else c.slice();
        return .{ .state = .{ .rows = rows, .back = rows.len } };
    }
    const items = if (@typeInfo(@TypeOf(c)) == .@"struct") c.items else c;
    return .{ .state = .{ .items = items } };
}
