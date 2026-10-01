//! Sources provide `pub const Item` and `pub fn next(*Self) ?Item`.
//! Optional sizeHint/len/nextBack capabilities are propagated conservatively.
//! Adapters copy state; fromRef/byRef borrow it. No operation owns or destroys
//! resources inside an Item. Allocation occurs only in explicit collectors.
const std = @import("std");
const adapters = @import("adapters.zig");
const sources = @import("sources.zig");
const lanes = @import("lanes.zig");
pub const SizeHint = struct { lower: usize = 0, upper: ?usize = null };
pub const fromSlice = sources.fromSlice;
pub const fromSliceMut = sources.fromSliceMut;
pub const fromSliceRef = sources.fromSliceRef;
pub const fromArray = sources.fromArray;
pub const fromFn = sources.fromFn;
pub const empty = sources.empty;
pub const once = sources.once;
pub const repeat = sources.repeat;
pub const repeatWith = sources.repeatWith;
pub const successors = sources.successors;
pub const range = sources.range;
pub const of = sources.of;

/// True when S declares `name` as a true bool; capability flags default off.
pub fn has(comptime S: type, comptime name: []const u8) bool {
    return @hasDecl(S, name) and @field(S, name);
}

pub fn from(source: anytype) Iterator(@TypeOf(source)) {
    return .{ .state = source };
}

pub fn fromRef(source: anytype) Iterator(sources.Ref(@typeInfo(@TypeOf(source)).pointer.child)) {
    return .{ .state = .{ .source = source } };
}

pub fn hasBack(comptime T: type) bool {
    if (@hasDecl(T, "is_double_ended")) return T.is_double_ended;
    return @hasDecl(T, "nextBack");
}

pub fn hasLen(comptime T: type) bool {
    if (@hasDecl(T, "is_exact_size")) return T.is_exact_size;
    return @hasDecl(T, "len");
}

// Function pointers, value captures with call(*Self, ...), and borrowed
// captures with call(*Capture, ...) share the same callback path.
pub fn Callback(comptime T: type) type {
    return if (@typeInfo(T) == .@"fn") *const T else T;
}

fn Receiver(comptime C: type) type {
    return if (@typeInfo(C) == .pointer) C else *C;
}

pub fn CallResult(comptime C: type, comptime Args: type) type {
    if (@typeInfo(C) == .pointer and @typeInfo(@typeInfo(C).pointer.child) == .@"fn") {
        return @typeInfo(@typeInfo(C).pointer.child).@"fn".return_type.?;
    }
    const T = if (@typeInfo(C) == .pointer) @typeInfo(C).pointer.child else C;
    return @TypeOf(@call(.auto, T.call, .{@as(Receiver(C), undefined)} ++ @as(Args, undefined)));
}

pub fn invoke(operation: anytype, args: anytype) CallResult(@typeInfo(@TypeOf(operation)).pointer.child, @TypeOf(args)) {
    const C = @typeInfo(@TypeOf(operation)).pointer.child;
    if (@typeInfo(C) == .pointer) {
        if (@typeInfo(@typeInfo(C).pointer.child) == .@"fn") return @call(.auto, operation.*, args);
        return @call(.auto, @typeInfo(C).pointer.child.call, .{operation.*} ++ args);
    }
    return @call(.auto, C.call, .{operation} ++ args);
}

pub fn UnaryResult(comptime C: type, comptime Item: type) type {
    return CallResult(C, @TypeOf(.{@as(Item, undefined)}));
}

pub fn OptionalChild(comptime T: type) type {
    if (@typeInfo(T) != .optional) @compileError("callback must return an optional value");
    return @typeInfo(T).optional.child;
}

pub fn Chunk(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("chunk capacity must be positive");
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,
        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }
    };
}

pub fn Iterator(comptime State: type) type {
    if (@typeInfo(State) != .@"struct" and @typeInfo(State) != .@"union" and @typeInfo(State) != .@"enum")
        @compileError("iterator source must declare Item and next(*Self); use fromRef to borrow a source");
    if (!@hasDecl(State, "Item") or !@hasDecl(State, "next"))
        @compileError("iterator source must declare pub const Item and pub fn next(*Self) ?Item");
    if (@TypeOf(State.next) != fn (*State) ?State.Item)
        @compileError("source next must have signature fn (*Self) ?Item");
    return struct {
        const Self = @This();
        pub const Item = State.Item;
        pub const is_double_ended = hasBack(State);
        pub const is_exact_size = hasLen(State);
        pub const random_access = has(State, "random_access");
        pub const masked = has(State, "masked");
        pub const vectorizable = has(State, "vectorizable");
        /// Lanes per block when the pipeline runs as SIMD, else null.
        pub const lane_count: ?comptime_int = if (vectorizable) lanes.widthOf(Item) else null;
        state: State,

        pub fn span(self: *const Self) usize {
            return self.state.span();
        }
        pub fn at(self: *Self, i: usize) ?Item {
            return self.state.at(i);
        }
        pub fn block(self: *Self, comptime N: usize, i: usize) lanes.Block(Item, N) {
            return self.state.block(N, i);
        }
        pub fn advance(self: *Self, n: usize) void {
            self.state.advance(n);
        }

        /// Lanes for a terminal whose own callback type is Op, else null.
        fn vectorWidth(comptime Op: type) ?comptime_int {
            return if (lanes.isLanewise(Op)) lane_count else null;
        }

        const Hit = struct { out: usize, item: Item };

        /// The last full block, re-read so it ends at n, with lanes before
        /// `i` (already processed) masked off. Requires N <= n and i < n.
        /// Overlapping reads replace a scalar tail; lanewise callbacks are
        /// pure, so evaluating them twice on those lanes is unobservable.
        fn tailBlock(self: *Self, comptime N: usize, i: usize, n: usize) lanes.Block(Item, N) {
            var b = self.state.block(N, n - N);
            const fresh = std.simd.iota(u32, N) >= @as(@Vector(N, u32), @splat(@intCast(N - (n - i))));
            b.m = b.m & fresh;
            return b;
        }

        /// First kept item whose predicate equals `want`; consumes through it.
        /// `out` counts kept items before it (the position in output order).
        fn firstHit(self: *Self, op: anytype, comptime want: bool) ?Hit {
            var i: usize = 0;
            var out: usize = 0;
            const n = self.state.span();
            if (comptime vectorWidth(@typeInfo(@TypeOf(op)).pointer.child)) |N| if (n >= N) {
                const U = 4;
                const wanted: @Vector(N, bool) = @splat(want);
                const Found = struct { base: usize, b: lanes.Block(Item, N), hits: lanes.Mask(N) };
                const found: ?Found = search: {
                    // memchr shape: U blocks per branch, hit masks OR-ed.
                    const unrolled = n - n % (U * N);
                    while (i < unrolled) : (i += U * N) {
                        var blocks: [U]lanes.Block(Item, N) = undefined;
                        var hits: [U]lanes.Mask(N) = undefined;
                        var any_hit: lanes.Mask(N) = 0;
                        inline for (0..U) |u| {
                            blocks[u] = self.state.block(N, i + u * N);
                            const p: @Vector(N, bool) = invoke(op, .{blocks[u].v});
                            hits[u] = lanes.bits(blocks[u].m & (p == wanted));
                            any_hit |= hits[u];
                        }
                        if (any_hit != 0) inline for (0..U) |u| {
                            if (hits[u] != 0) break :search .{ .base = i + u * N, .b = blocks[u], .hits = hits[u] };
                            if (masked) out += @popCount(lanes.bits(blocks[u].m));
                        };
                        if (masked) inline for (blocks) |b| {
                            out += @popCount(lanes.bits(b.m));
                        };
                    }
                    while (i < n) : (i += N) {
                        const tail = i + N > n;
                        const b = if (tail) self.tailBlock(N, i, n) else self.state.block(N, i);
                        const base = if (tail) n - N else i;
                        const p: @Vector(N, bool) = invoke(op, .{b.v});
                        const hits = lanes.bits(b.m & (p == wanted));
                        if (hits != 0) break :search .{ .base = base, .b = b, .hits = hits };
                        if (masked) out += @popCount(lanes.bits(b.m));
                    }
                    break :search null;
                };
                const f = found orelse {
                    self.state.advance(n);
                    return null;
                };
                const j = @ctz(f.hits);
                const before = (@as(lanes.Mask(N), 1) << @intCast(j)) - 1;
                out = if (masked) out + @popCount(lanes.bits(f.b.m) & before) else f.base + j;
                self.state.advance(f.base + j + 1);
                return .{ .out = out, .item = lanes.lane(Item, N, f.b.v, j) };
            };
            while (i < n) : (i += 1) if (self.state.at(i)) |x| {
                if (invoke(op, .{x}) == want) {
                    self.state.advance(i + 1);
                    return .{ .out = out, .item = x };
                }
                out += 1;
            };
            self.state.advance(n);
            return null;
        }

        /// Reassociating fold: independent vector accumulators (8 for floats,
        /// to cover add latency; 4 for ints), combined lane-wise at the end.
        /// Valid only for an associative, commutative reducer whose identity
        /// is `identity`; floats round differently (but deterministically)
        /// from an ordered fold. `seen` reports whether any item was kept.
        fn foldLanes(self: *Self, identity: anytype, op: anytype) struct { value: @TypeOf(identity), seen: bool } {
            const Acc = @TypeOf(identity);
            const n = self.state.span();
            var result = identity;
            if (comptime vectorWidth(@typeInfo(@TypeOf(op)).pointer.child)) |N| if (comptime lanes.canLane(Acc)) if (n >= N) {
                const U = comptime if (lanes.hasFloat(Acc)) 8 else 4;
                const V = lanes.Lanes(Acc, N);
                var acc: [U]V = @splat(lanes.splatLanes(Acc, N, identity));
                var kept_any: @Vector(N, bool) = @splat(false);
                // Filtered blocks: when the identity is representable as an
                // item, blank rejected lanes on the narrow input instead of
                // selecting on the (often wider) accumulator. f(acc, e) == acc
                // because f must also combine accumulators (a monoid on Acc).
                const i = if (masked) (if (neutralItem(identity)) |e|
                    self.foldBlocks(op, N, U, &acc, &kept_any, n, true, lanes.splatLanes(Item, N, e))
                else
                    self.foldBlocks(op, N, U, &acc, &kept_any, n, false, undefined)) else self.foldBlocks(op, N, U, &acc, &kept_any, n, false, undefined);
                if (i < n) {
                    const b = self.tailBlock(N, i, n);
                    acc[1 % U] = lanes.select(Acc, N, b.m, invoke(op, .{ acc[1 % U], b.v }), acc[1 % U]);
                    kept_any = kept_any | b.m;
                }
                comptime var width = U;
                inline while (width > 1) : (width /= 2) inline for (0..width / 2) |k| {
                    acc[k] = invoke(op, .{ acc[k], acc[k + width / 2] });
                };
                for (0..N) |j| result = invoke(op, .{ result, lanes.lane(Acc, N, acc[0], j) });
                self.state.advance(n);
                return .{ .value = result, .seen = !masked or @reduce(.Or, kept_any) };
            };
            var seen = false;
            for (0..n) |i| if (self.state.at(i)) |x| {
                result = invoke(op, .{ result, x });
                seen = true;
            };
            self.state.advance(n);
            return .{ .value = result, .seen = seen };
        }

        /// Full blocks of foldLanes; returns the index of the first unread one.
        inline fn foldBlocks(self: *Self, op: anytype, comptime N: usize, comptime U: usize, acc: anytype, kept_any: *@Vector(N, bool), n: usize, comptime blank_input: bool, neutral: lanes.Lanes(Item, N)) usize {
            const Acc = @TypeOf(acc[0]);
            var i: usize = 0;
            const unrolled = n - n % (U * N);
            while (i < unrolled) : (i += U * N) inline for (acc, 0..) |*a, u| {
                a.* = absorb(op, N, a.*, self.state.block(N, i + u * N), kept_any, blank_input, neutral);
            };
            const blocks = n - n % N;
            while (i < blocks) : (i += N) acc[0] = absorb(op, N, acc[0], self.state.block(N, i), kept_any, blank_input, neutral);
            _ = Acc;
            return i;
        }

        inline fn absorb(op: anytype, comptime N: usize, a: anytype, b: lanes.Block(Item, N), kept_any: *@Vector(N, bool), comptime blank_input: bool, neutral: lanes.Lanes(Item, N)) @TypeOf(a) {
            if (!masked) return invoke(op, .{ a, b.v });
            kept_any.* = kept_any.* | b.m;
            if (blank_input) return invoke(op, .{ a, lanes.select(Item, N, b.m, b.v, neutral) });
            const AccScalar = @typeInfo(@TypeOf(a)).vector.child;
            return lanes.select(AccScalar, N, b.m, invoke(op, .{ a, b.v }), a);
        }

        fn neutralItem(identity: anytype) ?Item {
            const Acc = @TypeOf(identity);
            if (Acc == Item) return identity;
            if (@typeInfo(Acc) == .int and @typeInfo(Item) == .int) return std.math.cast(Item, identity);
            return null;
        }

        pub fn next(self: *Self) ?Item {
            return self.state.next();
        }
        pub fn sizeHint(self: *const Self) SizeHint {
            if (@hasDecl(State, "sizeHint")) return self.state.sizeHint();
            if (is_exact_size) return .{ .lower = self.state.len(), .upper = self.state.len() };
            return .{};
        }
        pub fn len(self: *const Self) usize {
            if (!is_exact_size) @compileError("len requires an exact-size source");
            return self.state.len();
        }
        pub fn nextBack(self: *Self) ?Item {
            if (!is_double_ended) @compileError("nextBack requires a double-ended source");
            return self.state.nextBack();
        }
        pub fn byRef(self: *Self) Iterator(sources.Ref(Self)) {
            return fromRef(self);
        }
        pub fn map(self: Self, operation: anytype) Iterator(adapters.Map(Self, Callback(@TypeOf(operation)))) {
            return .{ .state = .{ .upstream = self, .operation = operation } };
        }
        pub fn filter(self: Self, predicate: anytype) Iterator(adapters.Filter(Self, Callback(@TypeOf(predicate)))) {
            return .{ .state = .{ .upstream = self, .predicate = predicate } };
        }
        pub fn filterMap(self: Self, operation: anytype) Iterator(adapters.FilterMap(Self, Callback(@TypeOf(operation)), false)) {
            return .{ .state = .{ .upstream = self, .operation = operation } };
        }
        /// Permanently stops at the first null result (stronger than Rust's map_while).
        pub fn mapWhile(self: Self, operation: anytype) Iterator(adapters.FilterMap(Self, Callback(@TypeOf(operation)), true)) {
            return .{ .state = .{ .upstream = self, .operation = operation } };
        }
        pub fn inspect(self: Self, operation: anytype) Iterator(adapters.Inspect(Self, Callback(@TypeOf(operation)))) {
            return .{ .state = .{ .upstream = self, .operation = operation } };
        }
        pub fn take(self: Self, limit: usize) Iterator(adapters.Take(Self)) {
            return .{ .state = .{ .upstream = self, .remaining = limit } };
        }
        pub fn skip(self: Self, amount: usize) Iterator(adapters.Skip(Self)) {
            return .{ .state = .{ .upstream = self, .remaining = amount } };
        }
        pub fn stepBy(self: Self, step: usize) Iterator(adapters.StepBy(Self)) {
            std.debug.assert(step > 0);
            return .{ .state = .{ .upstream = self, .step = step } };
        }
        pub fn takeWhile(self: Self, predicate: anytype) Iterator(adapters.While(Self, Callback(@TypeOf(predicate)), true)) {
            return .{ .state = .{ .upstream = self, .predicate = predicate } };
        }
        pub fn skipWhile(self: Self, predicate: anytype) Iterator(adapters.While(Self, Callback(@TypeOf(predicate)), false)) {
            return .{ .state = .{ .upstream = self, .predicate = predicate } };
        }
        pub fn enumerate(self: Self) Iterator(adapters.Enumerate(Self)) {
            return .{ .state = .{ .upstream = self } };
        }
        pub fn chain(self: Self, other: anytype) Iterator(adapters.Chain(Self, Iterator(@TypeOf(other)))) {
            return .{ .state = .{ .left = self, .right = from(other) } };
        }
        pub fn zip(self: Self, other: anytype) Iterator(adapters.Zip(Self, Iterator(@TypeOf(other)))) {
            return .{ .state = .{ .left = self, .right = from(other) } };
        }
        pub fn flatten(self: Self) Iterator(adapters.Flatten(Self)) {
            return .{ .state = .{ .upstream = self } };
        }
        pub fn flatMap(self: Self, operation: anytype) Iterator(adapters.Flatten(Iterator(adapters.Map(Self, Callback(@TypeOf(operation)))))) {
            return self.map(operation).flatten();
        }
        pub fn scan(self: Self, initial: anytype, operation: anytype) Iterator(adapters.Scan(Self, @TypeOf(initial), Callback(@TypeOf(operation)))) {
            return .{ .state = .{ .upstream = self, .accumulator = initial, .operation = operation } };
        }
        pub fn fuse(self: Self) Iterator(adapters.Fuse(Self)) {
            return .{ .state = .{ .upstream = self } };
        }
        pub fn peekable(self: Self) Iterator(adapters.Peekable(Self)) {
            return .{ .state = .{ .upstream = self } };
        }
        pub fn peek(self: *Self) ?Item {
            if (!@hasDecl(State, "peek")) @compileError("peek requires .peekable()");
            return self.state.peek();
        }
        pub fn nextIf(self: *Self, predicate: anytype) ?Item {
            const item = self.peek() orelse return null;
            var operation: Callback(@TypeOf(predicate)) = predicate;
            if (!invoke(&operation, .{item})) return null;
            return self.next();
        }
        pub fn rev(self: Self) Iterator(adapters.Reverse(Self)) {
            if (!is_double_ended) @compileError("rev requires a double-ended source");
            return .{ .state = .{ .upstream = self } };
        }
        /// Repeats a value-copy of this cursor; pointer captures remain shared.
        pub fn cycle(self: Self) Iterator(adapters.Cycle(Self)) {
            return .{ .state = .{ .original = self, .current = self } };
        }
        pub fn intersperse(self: Self, separator: Item) Iterator(adapters.Intersperse(Self)) {
            return .{ .state = .{ .upstream = self, .separator = separator } };
        }
        /// Includes a final partial chunk; unused array slots are undefined.
        pub fn chunks(self: Self, comptime capacity: usize) Iterator(adapters.Chunks(Self, capacity)) {
            return .{ .state = .{ .upstream = self } };
        }
        pub fn copied(self: Self) Iterator(adapters.Copied(Self)) {
            return .{ .state = .{ .upstream = self } };
        }

        pub fn advanceBy(self: *Self, n: usize) usize {
            var consumed: usize = 0;
            while (consumed < n) : (consumed += 1) _ = self.next() orelse break;
            return consumed;
        }
        pub fn nth(self: *Self, n: usize) ?Item {
            if (self.advanceBy(n) != n) return null;
            return self.next();
        }
        pub fn nthBack(self: *Self, n: usize) ?Item {
            var consumed: usize = 0;
            while (consumed < n) : (consumed += 1) _ = self.nextBack() orelse return null;
            return self.nextBack();
        }
        pub fn nextChunk(self: *Self, comptime capacity: usize) Chunk(Item, capacity) {
            var result: Chunk(Item, capacity) = .{};
            while (result.len < capacity) : (result.len += 1) result.items[result.len] = self.next() orelse break;
            return result;
        }
        pub fn fold(self: *Self, initial: anytype, reducer: anytype) @TypeOf(initial) {
            var operation: Callback(@TypeOf(reducer)) = reducer;
            var result = initial;
            if (random_access) {
                const n = self.state.span();
                for (0..n) |i| if (self.state.at(i)) |item| {
                    result = invoke(&operation, .{ result, item });
                };
                self.state.advance(n);
                return result;
            }
            while (self.next()) |item| result = invoke(&operation, .{ result, item });
            return result;
        }
        /// fold that may regroup and reorder: `reducer` must be associative and
        /// commutative with `identity` as its identity. With a lanewise reducer
        /// on a vectorizable pipeline this runs as SIMD.
        pub fn foldAssoc(self: *Self, identity: anytype, reducer: anytype) @TypeOf(identity) {
            var operation: Callback(@TypeOf(reducer)) = reducer;
            if (!random_access) return self.fold(identity, reducer);
            return self.foldLanes(identity, &operation).value;
        }
        pub fn rfold(self: *Self, initial: anytype, reducer: anytype) @TypeOf(initial) {
            var operation: Callback(@TypeOf(reducer)) = reducer;
            var result = initial;
            while (self.nextBack()) |item| result = invoke(&operation, .{ result, item });
            return result;
        }
        pub fn tryFold(self: *Self, initial: anytype, reducer: anytype) CallResult(Callback(@TypeOf(reducer)), @TypeOf(.{ initial, @as(Item, undefined) })) {
            var operation: Callback(@TypeOf(reducer)) = reducer;
            var result = initial;
            while (self.next()) |item| result = try invoke(&operation, .{ result, item });
            return result;
        }
        pub fn reduce(self: *Self, reducer: anytype) ?Item {
            return self.fold(self.next() orelse return null, reducer);
        }
        pub fn forEach(self: *Self, callback: anytype) void {
            var operation: Callback(@TypeOf(callback)) = callback;
            if (random_access) {
                const n = self.state.span();
                for (0..n) |i| if (self.state.at(i)) |item| invoke(&operation, .{item});
                return self.state.advance(n);
            }
            while (self.next()) |item| invoke(&operation, .{item});
        }
        pub fn tryForEach(self: *Self, callback: anytype) UnaryResult(Callback(@TypeOf(callback)), Item) {
            var operation: Callback(@TypeOf(callback)) = callback;
            while (self.next()) |item| try invoke(&operation, .{item});
        }
        pub fn count(self: *Self) usize {
            var result: usize = 0;
            if (random_access) {
                const n = self.state.span();
                var i: usize = 0;
                // Lanewise callbacks are pure, so unfiltered vectorizable
                // pipelines need not evaluate anything.
                if (lane_count) |N| {
                    if (!masked) {
                        self.state.advance(n);
                        return n;
                    }
                    if (n >= N) {
                        const unrolled = n - n % (4 * N);
                        while (i < unrolled) : (i += 4 * N) inline for (0..4) |u| {
                            result += @popCount(lanes.bits(self.state.block(N, i + u * N).m));
                        };
                        const blocks = n - n % N;
                        while (i < blocks) : (i += N) result += @popCount(lanes.bits(self.state.block(N, i).m));
                        if (i < n) result += @popCount(lanes.bits(self.tailBlock(N, i, n).m));
                        i = n;
                    }
                }
                while (i < n) : (i += 1) result += @intFromBool(self.state.at(i) != null);
                self.state.advance(n);
                return result;
            }
            while (self.next()) |_| result += 1;
            return result;
        }
        pub fn last(self: *Self) ?Item {
            var result: ?Item = null;
            while (self.next()) |item| result = item;
            return result;
        }
        pub fn find(self: *Self, predicate: anytype) ?Item {
            var operation: Callback(@TypeOf(predicate)) = predicate;
            if (random_access) return if (self.firstHit(&operation, true)) |h| h.item else null;
            while (self.next()) |item| if (invoke(&operation, .{item})) return item;
            return null;
        }
        pub fn rfind(self: *Self, predicate: anytype) ?Item {
            var operation: Callback(@TypeOf(predicate)) = predicate;
            while (self.nextBack()) |item| if (invoke(&operation, .{item})) return item;
            return null;
        }
        pub fn findMap(self: *Self, callback: anytype) UnaryResult(Callback(@TypeOf(callback)), Item) {
            var operation: Callback(@TypeOf(callback)) = callback;
            while (self.next()) |item| if (invoke(&operation, .{item})) |result| return result;
            return null;
        }
        pub fn position(self: *Self, predicate: anytype) ?usize {
            var operation: Callback(@TypeOf(predicate)) = predicate;
            if (random_access) return if (self.firstHit(&operation, true)) |h| h.out else null;
            var index: usize = 0;
            while (self.next()) |item| : (index += 1) if (invoke(&operation, .{item})) return index;
            return null;
        }
        pub fn rposition(self: *Self, predicate: anytype) ?usize {
            var operation: Callback(@TypeOf(predicate)) = predicate;
            while (self.nextBack()) |item| if (invoke(&operation, .{item})) return self.len();
            return null;
        }
        pub fn any(self: *Self, predicate: anytype) bool {
            return self.find(predicate) != null;
        }
        pub fn all(self: *Self, predicate: anytype) bool {
            var operation: Callback(@TypeOf(predicate)) = predicate;
            if (random_access) return self.firstHit(&operation, false) == null;
            while (self.next()) |item| if (!invoke(&operation, .{item})) return false;
            return true;
        }
        pub fn sum(self: *Self, comptime Acc: type) Acc {
            var result: Acc = 0;
            while (self.next()) |item| result += item;
            return result;
        }
        pub fn sumWrapping(self: *Self, comptime Acc: type) Acc {
            if (random_access) return self.foldAssoc(@as(Acc, 0), lanes.ops.add);
            var result: Acc = 0;
            while (self.next()) |item| result +%= item;
            return result;
        }
        pub fn product(self: *Self, comptime Acc: type) Acc {
            var result: Acc = 1;
            while (self.next()) |item| result *= item;
            return result;
        }
        pub fn min(self: *Self) ?Item {
            if (comptime random_access and @typeInfo(Item) == .int) {
                var op = lanes.ops.min;
                const r = self.foldLanes(@as(Item, std.math.maxInt(Item)), &op);
                return if (r.seen) r.value else null;
            }
            const Compare = struct {
                fn call(_: *@This(), a: Item, b: Item) std.math.Order {
                    return std.math.order(a, b);
                }
            };
            return self.minBy(Compare{});
        }
        pub fn max(self: *Self) ?Item {
            if (comptime random_access and @typeInfo(Item) == .int) {
                var op = lanes.ops.max;
                const r = self.foldLanes(@as(Item, std.math.minInt(Item)), &op);
                return if (r.seen) r.value else null;
            }
            const Compare = struct {
                fn call(_: *@This(), a: Item, b: Item) std.math.Order {
                    return std.math.order(a, b);
                }
            };
            return self.maxBy(Compare{});
        }
        pub fn minBy(self: *Self, comparator: anytype) ?Item {
            var operation: Callback(@TypeOf(comparator)) = comparator;
            var best = self.next() orelse return null;
            while (self.next()) |item| if (invoke(&operation, .{ item, best }) == .lt) {
                best = item;
            };
            return best;
        }
        pub fn maxBy(self: *Self, comparator: anytype) ?Item {
            var operation: Callback(@TypeOf(comparator)) = comparator;
            var best = self.next() orelse return null;
            while (self.next()) |item| if (invoke(&operation, .{ item, best }) != .lt) {
                best = item;
            };
            return best;
        }
        pub fn isSorted(self: *Self) bool {
            const Compare = struct {
                fn call(_: *@This(), a: Item, b: Item) bool {
                    return a <= b;
                }
            };
            return self.isSortedBy(Compare{});
        }
        /// Comparator returns true when the adjacent pair is in order.
        pub fn isSortedBy(self: *Self, comparator: anytype) bool {
            var operation: Callback(@TypeOf(comparator)) = comparator;
            var previous = self.next() orelse return true;
            while (self.next()) |item| {
                if (!invoke(&operation, .{ previous, item })) return false;
                previous = item;
            }
            return true;
        }
        pub fn eq(self: *Self, other: anytype) bool {
            const Equal = struct {
                fn call(_: *@This(), a: Item, b: Item) bool {
                    return std.meta.eql(a, b);
                }
            };
            return self.eqBy(other, Equal{});
        }
        pub fn eqBy(self: *Self, other: anytype, comparator: anytype) bool {
            var right = from(other);
            var operation: Callback(@TypeOf(comparator)) = comparator;
            while (self.next()) |left| {
                const item = right.next() orelse return false;
                if (!invoke(&operation, .{ left, item })) return false;
            }
            return right.next() == null;
        }
        pub fn cmp(self: *Self, other: anytype) std.math.Order {
            const Compare = struct {
                fn call(_: *@This(), a: Item, b: Item) std.math.Order {
                    return std.math.order(a, b);
                }
            };
            return self.cmpBy(other, Compare{});
        }
        pub fn cmpBy(self: *Self, other: anytype, comparator: anytype) std.math.Order {
            var right = from(other);
            var operation: Callback(@TypeOf(comparator)) = comparator;
            while (self.next()) |left| {
                const item = right.next() orelse return .gt;
                const order = invoke(&operation, .{ left, item });
                if (order != .eq) return order;
            }
            return if (right.next() == null) .eq else .lt;
        }

        /// Caller owns the returned slice. Does not destroy resource-owning items.
        pub fn collect(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Item {
            var list: std.ArrayList(Item) = .empty;
            errdefer list.deinit(allocator);
            try self.extend(&list, allocator);
            return list.toOwnedSlice(allocator);
        }
        /// Append everything to `list`. Exact-size pipelines reserve once and
        /// write without per-item capacity checks (Rust's TrustedLen extend).
        /// On allocation failure, items already appended stay in `list`.
        pub fn extend(self: *Self, list: *std.ArrayList(Item), allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
            while (true) {
                const hint = self.sizeHint();
                if (hint.upper == hint.lower and hint.lower > 0)
                    try list.ensureTotalCapacityPrecise(allocator, list.items.len + hint.lower)
                else
                    try list.ensureUnusedCapacity(allocator, @max(hint.lower, 8));
                const room = list.unusedCapacitySlice();
                const written = self.writeInto(room);
                list.items.len += written;
                if (written < room.len) return;
            }
        }
        /// Sink provides append(*Self, Item) !void. Stops immediately on error.
        pub fn collectInto(self: *Self, sink: anytype) @TypeOf(sink.append(@as(Item, undefined))) {
            while (self.next()) |item| try sink.append(item);
        }
        /// Fill caller-owned storage, leaving the next item unconsumed if full.
        /// Vectorized for random-access pipelines; filtered ones left-pack
        /// kept lanes (vpcompress on AVX-512, a vpermd table on AVX2).
        pub fn writeInto(self: *Self, output: []Item) usize {
            if (random_access) {
                const n = self.state.span();
                var i: usize = 0;
                var w: usize = 0;
                if (lane_count) |N| {
                    if (!masked) {
                        const end = @min(n, output.len);
                        const unrolled = end - end % (4 * N);
                        while (i < unrolled) : (i += 4 * N) inline for (0..4) |u| {
                            lanes.store(Item, N, self.state.block(N, i + u * N).v, output[i + u * N ..][0..N]);
                        };
                        const blocks = end - end % N;
                        while (i < blocks) : (i += N) lanes.store(Item, N, self.state.block(N, i).v, output[i..][0..N]);
                        w = i;
                    } else {
                        while (i + N <= n and w + N <= output.len) : (i += N) {
                            const b = self.state.block(N, i);
                            w += lanes.compact(Item, N, b.v, b.m, output[w..][0..N]);
                        }
                    }
                }
                while (i < n and w < output.len) : (i += 1) if (self.state.at(i)) |x| {
                    output[w] = x;
                    w += 1;
                };
                self.state.advance(i);
                return w;
            }
            var written: usize = 0;
            while (written < output.len) : (written += 1) output[written] = self.next() orelse break;
            return written;
        }
        pub fn partition(self: *Self, allocator: std.mem.Allocator, predicate: anytype) std.mem.Allocator.Error!struct { matched: []Item, rest: []Item } {
            var matched: std.ArrayList(Item) = .empty;
            errdefer matched.deinit(allocator);
            var rest: std.ArrayList(Item) = .empty;
            errdefer rest.deinit(allocator);
            var operation: Callback(@TypeOf(predicate)) = predicate;
            while (self.next()) |item| {
                if (invoke(&operation, .{item})) try matched.append(allocator, item) else try rest.append(allocator, item);
            }
            const left = try matched.toOwnedSlice(allocator);
            errdefer allocator.free(left);
            return .{ .matched = left, .rest = try rest.toOwnedSlice(allocator) };
        }
        pub fn isPartitioned(self: *Self, predicate: anytype) bool {
            var operation: Callback(@TypeOf(predicate)) = predicate;
            var seen_false = false;
            while (self.next()) |item| {
                if (invoke(&operation, .{item})) {
                    if (seen_false) return false;
                } else seen_false = true;
            }
            return true;
        }
    };
}
