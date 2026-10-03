//! The one test compilation that imports every module: `refAllDecls` over all
//! of them (Zig analyses lazily, so an unreferenced `pub` decl is otherwise
//! never type-checked), plus the claims that span two modules neither of which
//! imports the other: the contract-name check below and `exhaustive.zig`.

const std = @import("std");

/// Every module, `pub` so the `refAllDecls` test below reaches each one.
pub const contract = @import("contract");
pub const diag = @import("diag");
pub const frontend = @import("frontend");
pub const kernels = @import("kernels");
pub const ir = @import("ir");
pub const backend = @import("backend");
pub const sim = @import("sim");
pub const vera = @import("vera");
pub const vpi = @import("vpi");

/// The stage-boundary exhaustiveness guard.
pub const exhaustive = @import("exhaustive.zig");

test {
    std.testing.refAllDecls(@This());
}

// ---------------------------------------------------------------------------
// Every `contract.<name>` the backend emits must be a decl contract.zig has.
//
// Codegen writes the reference as text into a device it never compiles, and
// the engine never links contract.zig, so a renamed decl would otherwise
// surface as a compile error inside a generated device on the host's side.
// ---------------------------------------------------------------------------

/// Enough Verilog-A to make codegen reach for the contract in several
/// directions at once: a state-carrying limiter, noise, a charge, an operating
/// point variable and a system task. Each one emits a different `contract.`
/// reference, and a device that only stamped a resistor would exercise three.
const wide_device =
    \\`include "disciplines.vams"
    \\module wide(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0.0:inf);
    \\  parameter real c = 1.0e-12 from [0.0:inf);
    \\  real vlim;
    \\  (* desc = "branch current" *) real i_op;
    \\  analog begin
    \\    vlim = $limit(V(p, n), "pnjlim", 0.025, 0.7);
    \\    i_op = vlim / r;
    \\    I(p, n) <+ i_op + ddt(c * V(p, n));
    \\    I(p, n) <+ white_noise(4.0 * `P_K * $temperature / r, "thermal");
    \\  end
    \\endmodule
;

/// Whether `contract` declares `name`, read from the module itself so there is
/// no third list to keep in step.
fn declares(name: []const u8) bool {
    inline for (@typeInfo(contract).@"struct".decl_names) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether `at` follows a `//` on its line. Enough because codegen emits no
/// string literal containing `//`.
fn inComment(text: []const u8, at: usize) bool {
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
    return std.mem.indexOf(u8, text[line_start..at], "//") != null;
}

test "every `contract.<name>` the backend emits is a decl contract.zig has" {
    const gpa = std.testing.allocator;
    var res = try vera.compileSource(gpa, wide_device, .build);
    defer res.deinit();
    const device = try res.generateDevice();

    var missing: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, device, i, "contract.")) |hit| {
        i = hit + "contract.".len;
        // A comment naming `contract.zig` is prose, not a decl the device
        // resolves.
        if (inComment(device, hit)) continue;
        // `@import("contract")` and its binding line are followed by nothing
        // identifier-shaped, so the scan skips them.
        var end = i;
        while (end < device.len and isIdentChar(device[end])) end += 1;
        if (end == i) continue;
        const name = device[i..end];
        if (declares(name)) continue;
        std.debug.print(
            "the emitted device spells `contract.{s}`, which tools/contract.zig does not declare\n",
            .{name},
        );
        missing += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), missing);

    // The scan is evidence only if it found something: a device that stopped
    // emitting the prefix would otherwise pass by matching nothing.
    try std.testing.expect(std.mem.indexOf(u8, device, "contract.validate(") != null);
}

// The split build writes `orchestrator.Part` tags into the shims as enum
// literals the host's `exportDevicePart` takes as `contract.DevicePart`.
test "orchestrator.Part and contract.DevicePart name the same parts" {
    const a = @typeInfo(vera.orchestrator.Part).@"enum".field_names;
    const b = @typeInfo(contract.DevicePart).@"enum".field_names;
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try std.testing.expectEqualStrings(x, y);
}
