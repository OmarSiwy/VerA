//! The scalar family in the emitted text (`contract.family_fns`): every body
//! is generic over a FAMILY, each real typed by the unknowns it may depend on.
//!
//! In: a MIR value's unknown set (`Analysis.unknownDeps`). Out: the mask
//! literals and the `zTo`/`zOf` wrappers the renderers splice in, and the
//! per-device `lane_masks` table. The helpers the text calls are
//! `kernel_text.family_txt` and `family_dev_txt`.
//!
//! A real value is typed `zOf(S, m)`, `m` the unknowns it may depend on. Zig
//! infers every other value's type from its expression, so a mask is written
//! only where values MERGE: a hoisted slot, a lazy `if`'s arms, an array
//! element, a kernel's result, a returned field, a residual row. `zTo` widens
//! into the merge and is a compile error on a value whose lanes the mask
//! misses, so an unsound mask cannot drop a lane silently.

const std = @import("std");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const Mir = @import("ir").Mir;
const Error = codegen.Error;

/// The unknowns `v` may depend on: its mask before `zdr` cuts it.
pub fn mask(self: *const Gen, v: Mir.Value) u64 {
    return self.an.unknownDeps(v);
}

/// `zTo(S, 0x<m>, ` — the caller writes the value and the closing `)`.
pub fn openTo(self: *Gen, m: u64) Error!void {
    try self.b("zTo(S, 0x{x}, ", .{m});
}

/// `zOf(S, 0x<m>)`, as text for a `{s}` slot.
pub fn ofText(self: *Gen, m: u64) Error![]const u8 {
    return std.fmt.allocPrint(self.arena, "zOf(S, 0x{x})", .{m});
}

/// One real the shared core declares at mask `m`, for `lane_masks`: the
/// values a host's `eval` and `q` carry. `setup` runs on the value scalar,
/// and the dry run of a body (`probeBody`) declares nothing.
pub fn note(self: *Gen, m: u64) Error!void {
    if (self.probing or !self.emitting_common or self.su.mode) return;
    try self.fam_masks.append(self.arena, m);
}

/// `lane_masks`: every distinct mask a real was declared at, cut to the
/// emitted `deriv_reads`, with how many were. A host sizes its lane types
/// from it; the device fixes no width.
pub fn emitLaneMasks(self: *Gen, deriv_reads: u64) Error!void {
    const ms = self.fam_masks.items;
    for (ms) |*m| m.* &= deriv_reads;
    std.mem.sort(u64, ms, {}, std.sort.asc(u64));
    try self.w(
        \\/// Every distinct `Of` mask a real in this device is declared at, and
        \\/// how many are (`contract.laneMasks`).
        \\pub const lane_masks = [_]contract.LaneUse{{
        \\
    , .{});
    var i: usize = 0;
    while (i < ms.len) {
        var j = i;
        while (j < ms.len and ms[j] == ms[i]) j += 1;
        try self.w("    .{{ .mask = 0x{x}, .uses = {d} }},\n", .{ ms[i], j - i });
        i = j;
    }
    try self.w("}};\n\n", .{});
}
