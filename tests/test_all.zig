//! The one compilation that has every module at once.
//!
//! `zig test` collects tests only from the ROOT module's own file set, so each
//! module in `build.zig`'s `module_specs` gets a test artifact of its own and
//! its tests stay beside the code they are about. That is the right home for
//! nearly everything, and this file does not duplicate it.
//!
//! What lands HERE is the residue: a claim that spans two modules which neither
//! of them can make, because neither imports the other. There are two today:
//! the contract check below, and `exhaustive.zig`, which reads the source of
//! every module against enums from `frontend` and `ir` at once.
//!
//! `refAllDecls` over every module is the second job. Zig analyses lazily, so a
//! `pub` decl nothing references is never type-checked: without this, `zig build
//! test` means "the files parse" rather than "the engine compiles".

const std = @import("std");

pub const contract = @import("contract");
pub const diag = @import("diag");
pub const frontend = @import("frontend");
pub const kernels = @import("kernels");
pub const ir = @import("ir");
pub const backend = @import("backend");
pub const sim = @import("sim");
pub const vera = @import("vera");
pub const vpi = @import("vpi");

/// The stage-boundary exhaustiveness guard and its ratchet list.
pub const exhaustive = @import("exhaustive.zig");

test {
    std.testing.refAllDecls(@This());
}

// ---------------------------------------------------------------------------
// Every `contract.<name>` the backend EMITS must be a decl contract.zig has.
//
// The two sides never meet at compile time. `codegen.zig` writes the reference
// as text into a device it will not compile; `contract.zig` is compiled into
// that device later, by a child `zig` in the host's build, where a typo becomes
// the HOST's error and not ours. Neither module imports the other — that is the
// whole design, contract ships to devices and the engine never links it — so
// neither module's test artifact can hold this claim.
//
// The failure it catches is cheap to make and expensive to find: renaming a
// decl in contract.zig leaves every string in codegen.zig still spelling the
// old one, `zig build test` stays green, and the break surfaces as a compile
// error inside a generated device on someone else's machine.
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

/// The names a device is allowed to spell after `contract.`, taken from the
/// module itself rather than from a list kept beside it: a list would be a
/// third thing to keep true, and the point of this test is that there are only
/// two.
fn declares(name: []const u8) bool {
    inline for (@typeInfo(contract).@"struct".decls) |d| {
        if (std.mem.eql(u8, d.name, name)) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Is `at` preceded by a `//` on its own line? Codegen emits no string
/// containing `//`, so scanning back to the newline is enough and a real
/// tokenizer would be a second parser to keep true.
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
        // A COMMENT IS NOT A USE. Emitted code explains itself, and an
        // explanation naming `contract.zig` or `contract.StateCtlOp` is prose
        // about the module, not a decl the device will resolve. Skipping the
        // whole comment rather than blacklisting `zig` keeps this from failing
        // the next time codegen writes a sentence.
        if (inComment(device, hit)) continue;
        // `@import("contract")` and the declaration line that binds it are the
        // reference itself, not a use of a decl. Both are followed by a quote
        // or by nothing identifier-shaped, so the scan below skips them for
        // free — but a qualified use inside a STRING the device emits is not
        // distinguishable here, and there are none: codegen writes device text,
        // never a device that writes device text.
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

    // The scan is only evidence if it found something to check. A codegen
    // change that stopped emitting the prefix entirely would otherwise pass
    // this test by matching nothing at all.
    try std.testing.expect(std.mem.indexOf(u8, device, "contract.validate(") != null);
}
