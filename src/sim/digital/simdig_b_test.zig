//! Corner cases of the interpreter files no single sibling's tests reach:
//! §4.8.2 conversions at the i32/i64 edges, §17 byte-packing at word
//! boundaries, a run's arena under repeated timing-check conditions, and
//! allocation failure through the system tasks. No LRM clause of its own:
//! each test cites the clause it checks.
const std = @import("std");
const diag = @import("diag");
const root = @import("root.zig");
const system = @import("system.zig");
const filled = @import("net.zig").filled;
const expectRun = root.expectRun;

test "§17.8 $rtoi takes -2^31 exactly and refuses one past it as x" {
    try expectRun(
        \\module m; integer i, j, k;
        \\initial begin i = $rtoi(-2147483648.0); j = $rtoi(-2147483648.9); k = $rtoi(-2147483649.0);
        \\$display("%0d %0d %b", i, j, k); end endmodule
    , "-2147483648 -2147483648 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n");
}

test "§4.8.2 a real rounds into a 64-bit integer down to -2^63, and NaN is x" {
    try expectRun(
        \\module m; reg signed [63:0] a, b; real n;
        \\initial begin a = -9223372036854775808.0; n = 0.0 / 0.0; b = n;
        \\$display("%0d %b", a, b[0]); end endmodule
    , "-9223372036854775808 x\n");
}

test "§17.1.1.7 text reads bytes across a word boundary, top byte partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 76 bits: a partial top byte 0x5 (bits 72..75), then 9 bytes, the
    // eighth of which (bits 56..63) ends word 0.
    const v = try filled(a, 76, false, .zero);
    v.values()[0] = 0x4847_4645_4443_4241;
    v.values()[1] = 0x549;
    try std.testing.expectEqualStrings("\x05IHGFEDCBA", (try system.text(a, v)).?);
}

test "§17.2.3 a string longer than a word packs into the value and reads back" {
    try expectRun(
        \\module m; reg [8*12:1] s;
        \\initial begin $sformat(s, "%s", "abcdefghijkl"); $display("%s|%h", s, s[72:65]); end endmodule
    , "abcdefghijkl|64\n");
}

test "§17.2.4.4 readWord spans words big-endian and drops bits above the width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const File = struct {
        var data: []const u8 = "";
        var pos: usize = 0;
        fn getc(_: i64) i64 {
            if (pos == data.len) return -1;
            pos += 1;
            return data[pos - 1];
        }
        fn none(_: i64) i64 {
            return 0;
        }
    };
    const io: @import("contract").FileIo = .{ .open = undefined, .close = File.none, .put = undefined, .getc = File.getc, .ungetc = undefined, .tell = File.none, .seek = undefined, .eof = File.none };
    // 70 bits = 9 bytes, 0xff first: only its low 6 bits survive.
    File.data = "\xff\x01\x02\x03\x04\x05\x06\x07\x08";
    File.pos = 0;
    const w = try system.readWord(a, io, 1, 70);
    try std.testing.expectEqual(@as(i64, 9), w.n);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), w.value.?.values()[0]);
    try std.testing.expectEqual(@as(u64, 0x3f), w.value.?.values()[1]);
    try std.testing.expectEqual(@as(u64, 0), w.value.?.unknowns()[1]);
}

test "§15.6 a conditioned timing check judged every tick stops growing the run arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try root.elaborate(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module c(clk, en); input clk, en; reg n;
        \\specify $period(posedge clk &&& en, 1, n); endspecify endmodule
        \\module t; reg clk, en; c u(clk, en);
        \\initial begin clk = 0; en = 1; end always #1 clk = ~clk; endmodule
    , .{}, &bag, &output.writer);
    var at_warm: usize = 0;
    for (1..2001) |k| {
        _ = try r.runUntil(k);
        if (k == 200) at_warm = arena.queryCapacity();
    }
    try std.testing.expectEqual(at_warm, arena.queryCapacity());
}

test "§5.2.1 an indexed part-select descending from a base below the vector" {
    // v[1 -: 4] of [7:0] selects bits 1 down to -2: 1 and 0 exist, -1 and
    // -2 do not (x), and a write there lands only in bits 1 and 0.
    try expectRun(
        \\module m; reg [7:0] v;
        \\initial begin v = 8'b0000_0010; $display("%b", v[1 -: 4]); v[1 -: 4] = 4'b0111; $display("%b", v); end endmodule
    , "10xx\n00000001\n");
}

fn runSystemTasks(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try root.run(arena.allocator(),
        \\module m; reg [8*10:1] s; integer n, a, st, j, i; real r;
        \\initial begin
        \\  $sformat(s, "%0d-%h", 12, 8'hab); n = $sscanf("7 2.5", "%d %f", a, r);
        \\  $q_initialize(1, 1, 2, st); $q_add(1, 3, 4, st); $q_remove(1, j, i, st);
        \\  $display("%s %0d %0d %g %0d %0d %0d", s, n, a, r, st, j, i);
        \\end endmodule
    , .{}, &bag, &output.writer);
    try std.testing.expectEqualStrings("12-ab 2 7 2.5 0 3 4\n", output.written());
}

test "allocation failure anywhere in $sformat, $sscanf, the queues and $display cleans up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runSystemTasks, .{});
}

test "§12.7 one expression read from two instances resolves per scope through the slot memo" {
    // `v` in `c` is one ExprId seen from two scopes; a memo keyed on the
    // expression alone would print 1 twice.
    try expectRun(
        \\module c; parameter P = 0; reg [3:0] v; initial begin v = P; #1 $display("%0d %0d", v, t.b.v); end endmodule
        \\module t; c #(1) a(); c #(2) b(); endmodule
    , "1 2\n2 2\n");
}
