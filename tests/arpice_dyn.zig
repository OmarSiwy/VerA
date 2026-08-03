//! The `--dyn` host for checking a Verilog-A device really compiles.
//! In: a VerA device type D. Out: one exported C symbol, `bench_evalq`, that
//! runs `D.evalQ` over the sparse reference family with every operand taken
//! from the caller, so nothing folds and the device's eval and charge code is
//! compiled. A no-op dyn exports nothing and Zig never analyses the device
//! (measured 2026-10-04: every model's .so was 1312-1320 bytes).
//! A real host (ARPice's vtable) also compiles updateState: a lower bound.
//! Used by tools/report.py's model-build timing. CI's consumer check builds
//! ARPice itself (.github/workflows/bench.yaml arpice-consumer).

/// Opt into the contract's conformance checks (AGENTS.md §6).
pub const vera_validate_contract = true;

const std = @import("std");
const contract = @import("contract");

pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    _ = name;
    @export(&Bench(D).evalQ, .{ .name = "bench_evalq" });
}

fn Bench(comptime D: type) type {
    return struct {
        const n = contract.nU(D);
        const S = contract.RefFamily(f64, &lanes, .{ .dense = false });
        const lanes = blk: {
            var a: [n]u8 = undefined;
            for (&a, 0..) |*l, i| l.* = i;
            break :blk a;
        };
        // Every operand comes from the caller, so nothing folds: the whole
        // device is compiled, as a host's Newton loop would compile it.
        fn evalQ(x: *const [n]f64, m: *const D.Model, inst: *D.Instance, sim: *const contract.SimState, out: *anyopaque) callconv(.c) void {
            const r = D.evalQ(S, x, m, inst, sim.*);
            @as(*@TypeOf(r), @ptrCast(@alignCast(out))).* = r;
        }
    };
}
