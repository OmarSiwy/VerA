//! Lane-generic execution for random-access pipelines.
//!
//! Zig 0.16 does not run LLVM's loop vectorizer, so a counted scalar loop stays
//! scalar. Pipelines whose source and callbacks allow it run here instead, as
//! explicit @Vector blocks plus a scalar tail. A random-access state exposes:
//!   span() usize          indices still available (before filtering)
//!   at(i) ?Item           element i; null when a filter rejects it
//!   block(N, i) Block     N elements from i, plus a keep-mask
//!   advance(n)            consume the first n indices
//! `block` is only called when every callback in the pipeline is lanewise.
const std = @import("std");
const builtin = @import("builtin");
const it = @import("iter.zig");

/// Lanes per vector for scalar T on the compilation target; null = no SIMD.
/// Unlike std.simd.suggestVectorLength this uses 256-bit floats on AVX1, and
/// 512-bit 8/16-bit ints only with AVX-512BW. Respects prefer-256/128 tuning.
pub fn width(comptime T: type) ?comptime_int {
    const cpu = builtin.cpu;
    const size = @max(8, std.math.ceilPowerOfTwo(u16, @bitSizeOf(T)) catch unreachable);
    if (!cpu.arch.isX86()) return std.simd.suggestVectorLength(T);
    const float = @typeInfo(T) == .float;
    const reg: u16 = if (cpu.has(.x86, .prefer_128_bit))
        128
    else if (cpu.has(.x86, .avx512f) and !cpu.has(.x86, .prefer_256_bit) and (size >= 32 or cpu.has(.x86, .avx512bw)))
        512
    else if (cpu.has(.x86, .avx2) or (float and cpu.has(.x86, .avx)))
        256
    else if (cpu.has(.x86, .sse2))
        128
    else
        return null;
    return reg / size;
}

/// Lane count for an item: chosen by its narrowest scalar, so one load of the
/// narrowest field fills a register and wider fields use several. An all-float
/// item keeps its float type, so AVX1 gets 256-bit lanes for it.
pub fn widthOf(comptime T: type) ?comptime_int {
    return width(Narrowest(T));
}

fn Narrowest(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .bool => u8,
        .int, .float => T,
        .@"struct" => |s| blk: {
            var n: type = Narrowest(s.field_types[0]);
            for (s.field_types[1..]) |F| {
                const m = Narrowest(F);
                // Prefer the narrower; on ties an int wins (ints decide AVX1 width).
                if (@bitSizeOf(m) < @bitSizeOf(n) or (@bitSizeOf(m) == @bitSizeOf(n) and @typeInfo(m) == .int)) n = m;
            }
            break :blk n;
        },
        else => u64,
    };
}

pub fn hasFloat(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => true,
        .@"struct" => |s| for (s.field_types) |F| {
            if (hasFloat(F)) break true;
        } else false,
        else => false,
    };
}

pub fn canLane(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool => true,
        .@"struct" => |s| blk: {
            if (s.layout == .@"packed" or s.field_names.len == 0) break :blk false;
            for (s.field_types) |F| if (!canLane(F)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// T with every scalar widened to @Vector(N, scalar); structs become
/// structs of vectors with the same field names.
pub fn Lanes(comptime T: type, comptime N: usize) type {
    return switch (@typeInfo(T)) {
        .int, .float, .bool => @Vector(N, T),
        .@"struct" => |s| blk: {
            var names: [s.field_names.len][]const u8 = undefined;
            var types: [s.field_names.len]type = undefined;
            for (s.field_names, s.field_types, 0..) |name, F, i| {
                names[i] = name;
                types[i] = Lanes(F, N);
            }
            break :blk @Struct(.auto, null, &names, &types, &@splat(.{}));
        },
        else => @compileError("no lane representation for " ++ @typeName(T)),
    };
}

pub fn Block(comptime T: type, comptime N: usize) type {
    return struct { v: Lanes(T, N), m: @Vector(N, bool) };
}

pub fn Mask(comptime N: usize) type {
    return @Int(.unsigned, N);
}

pub fn bits(m: anytype) Mask(@typeInfo(@TypeOf(m)).vector.len) {
    return @bitCast(m);
}

/// Broadcast a scalar to V's shape; identity when V is scalar. Lanewise
/// callbacks use this because Zig never broadcasts scalars implicitly.
pub inline fn splat(comptime V: type, s: anytype) V {
    return if (@typeInfo(V) == .vector) @splat(s) else s;
}

pub fn splatLanes(comptime T: type, comptime N: usize, x: T) Lanes(T, N) {
    if (@typeInfo(T) != .@"struct") return @splat(x);
    var r: Lanes(T, N) = undefined;
    const s = @typeInfo(T).@"struct";
    inline for (s.field_names, s.field_types) |name, F| @field(r, name) = splatLanes(F, N, @field(x, name));
    return r;
}

pub fn select(comptime T: type, comptime N: usize, m: @Vector(N, bool), a: Lanes(T, N), b: Lanes(T, N)) Lanes(T, N) {
    if (@typeInfo(T) != .@"struct") return @select(T, m, a, b);
    var r: Lanes(T, N) = undefined;
    const s = @typeInfo(T).@"struct";
    inline for (s.field_names, s.field_types) |name, F| @field(r, name) = select(F, N, m, @field(a, name), @field(b, name));
    return r;
}

/// Contiguous load for scalars; a per-field transpose for array-of-structs.
pub fn load(comptime T: type, comptime N: usize, src: *const [N]T) Lanes(T, N) {
    if (@typeInfo(T) != .@"struct") return src.*;
    var r: Lanes(T, N) = undefined;
    const s = @typeInfo(T).@"struct";
    inline for (s.field_names, s.field_types) |name, F| {
        var column: [N]F = undefined;
        for (src, &column) |e, *c| c.* = @field(e, name);
        @field(r, name) = load(F, N, &column);
    }
    return r;
}

pub fn lane(comptime T: type, comptime N: usize, v: Lanes(T, N), j: usize) T {
    if (@typeInfo(T) != .@"struct") {
        const a: [N]T = v; // vectors cannot be indexed at a runtime index
        return a[j];
    }
    var r: T = undefined;
    const s = @typeInfo(T).@"struct";
    inline for (s.field_names, s.field_types) |name, F| @field(r, name) = lane(F, N, @field(v, name), j);
    return r;
}

pub fn store(comptime T: type, comptime N: usize, v: Lanes(T, N), dst: *[N]T) void {
    if (@typeInfo(T) != .@"struct") {
        dst.* = v;
        return;
    }
    for (dst, 0..) |*d, j| d.* = lane(T, N, v, j);
}

/// Left-pack the kept lanes of `v` into dst[0..popCount(m)] and return that
/// count. All N slots of dst may be written. AVX-512 uses vpcompress, AVX2
/// 32-bit lanes use a vpermd table, everything else a branchless store loop.
pub fn compact(comptime T: type, comptime N: usize, v: Lanes(T, N), m: @Vector(N, bool), dst: *[N]T) usize {
    const kept = @popCount(bits(m));
    const cpu = builtin.cpu;
    const scalar = @typeInfo(T) == .int or @typeInfo(T) == .float;
    if (scalar and comptime builtin.zig_backend == .stage2_llvm and cpu.arch == .x86_64) {
        const size = @bitSizeOf(T);
        if (comptime cpu.has(.x86, .avx512f) and (size == 32 or size == 64) and
            (N * size == 512 or cpu.has(.x86, .avx512vl)))
        {
            compressStore(T, N, v, m, dst);
            return kept;
        }
        if (comptime cpu.has(.x86, .avx2) and size == 32 and N == 8) {
            const I = @Vector(8, i32);
            const idx: I = @as(@Vector(8, u8), permute_table[bits(m)]);
            const packed_bits = avx2_permd(@bitCast(v), idx);
            dst.* = @bitCast(packed_bits);
            return kept;
        }
    }
    var w: usize = 0;
    const keep: [N]bool = m;
    for (0..N) |j| {
        dst[w] = lane(T, N, v, j);
        w += @intFromBool(keep[j]);
    }
    return w;
}

fn compressStore(comptime T: type, comptime N: usize, v: @Vector(N, T), m: @Vector(N, bool), dst: *[N]T) void {
    const name = std.fmt.comptimePrint("llvm.masked.compressstore.v{d}{s}{d}", .{
        N, if (@typeInfo(T) == .float) "f" else "i", @bitSizeOf(T),
    });
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const f = @extern(*const fn (@Vector(N, Bits), [*]Bits, @Vector(N, bool)) callconv(.c) void, .{ .name = name });
    if (@typeInfo(T) == .float) {
        const Fv = @Vector(N, T);
        const g = @extern(*const fn (Fv, [*]T, @Vector(N, bool)) callconv(.c) void, .{ .name = name });
        g(v, dst, m);
    } else f(@bitCast(v), @ptrCast(dst), m);
}

extern fn @"llvm.x86.avx2.permd"(@Vector(8, i32), @Vector(8, i32)) @Vector(8, i32);
const avx2_permd = @"llvm.x86.avx2.permd";

/// For each 8-bit keep-mask: indices of the set bits, low lane first.
const permute_table: [256][8]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256][8]u8 = undefined;
    for (&t, 0..) |*row, mask| {
        var w: usize = 0;
        for (0..8) |j| if (mask >> j & 1 != 0) {
            row[w] = j;
            w += 1;
        };
        while (w < 8) : (w += 1) row[w] = 0;
    }
    break :blk t;
};

/// Marks a callback as lanewise: pure, total for every lane (including lanes a
/// preceding filter rejected), and generic so it accepts both T and
/// @Vector(N, T). Lanewise pipelines may evaluate it on rejected elements,
/// out of order, and fewer times than the scalar pipeline would.
/// Stateful callback structs opt in with `pub const lanewise = true;`.
pub fn lanewise(comptime f: anytype) Lanewise(f) {
    return .{};
}

pub fn Lanewise(comptime f: anytype) type {
    return struct {
        pub const lanewise = true;
        pub const call = switch (@typeInfo(@TypeOf(f)).@"fn".param_types.len) {
            1 => call1,
            2 => call2,
            else => @compileError("lanewise callbacks take one or two arguments"),
        };
        fn call1(_: *@This(), a: anytype) @TypeOf(f(a)) {
            return f(a);
        }
        fn call2(_: *@This(), a: anytype, b: anytype) @TypeOf(f(a, b)) {
            return f(a, b);
        }
    };
}

pub fn isLanewise(comptime C: type) bool {
    const T = if (@typeInfo(C) == .pointer) @typeInfo(C).pointer.child else C;
    return @typeInfo(T) == .@"struct" and it.has(T, "lanewise");
}

/// Ready-made lanewise operations.
pub const ops = struct {
    pub const add = lanewise(addFn);
    pub const min = lanewise(minFn);
    pub const max = lanewise(maxFn);
    fn addFn(a: anytype, b: anytype) @TypeOf(a) {
        return a +% @as(@TypeOf(a), b);
    }
    fn minFn(a: anytype, b: anytype) @TypeOf(a) {
        return @min(a, b);
    }
    fn maxFn(a: anytype, b: anytype) @TypeOf(a) {
        return @max(a, b);
    }
};

test "compact matches a scalar left-pack for every 8-lane mask" {
    const v: @Vector(8, u32) = .{ 10, 11, 12, 13, 14, 15, 16, 17 };
    for (0..256) |mask| {
        const m: @Vector(8, bool) = @bitCast(@as(u8, @intCast(mask)));
        var got: [8]u32 = undefined;
        const n = compact(u32, 8, v, m, &got);
        var want: [8]u32 = undefined;
        var w: usize = 0;
        for (0..8) |j| if (mask >> @intCast(j) & 1 != 0) {
            want[w] = 10 + @as(u32, @intCast(j));
            w += 1;
        };
        try std.testing.expectEqual(w, n);
        try std.testing.expectEqualSlices(u32, want[0..w], got[0..n]);
    }
}

test "Lanes maps structs field by field" {
    const P = struct { x: f32, id: u16 };
    const L = Lanes(P, 4);
    try std.testing.expect(@FieldType(L, "x") == @Vector(4, f32));
    const src = [_]P{ .{ .x = 1, .id = 7 }, .{ .x = 2, .id = 8 }, .{ .x = 3, .id = 9 }, .{ .x = 4, .id = 10 } };
    const v = load(P, 4, &src);
    try std.testing.expectEqual(src[2], lane(P, 4, v, 2));
}
