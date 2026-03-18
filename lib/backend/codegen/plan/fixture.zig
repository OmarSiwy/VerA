//! Test-only: a hand-built `Mir` + `Lowered`, and the `Analysis` over them —
//! the "few lines of setup" a `plan/` function needs. `naming.zig`'s own
//! `Fixture` is the pattern; this one adds the analysis the planners read.
//!
//! Not a fixture parser: every test states its MIR instruction by instruction,
//! so what a plan is asked about is on the page next to what it answers.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lowered = @import("ir").Lowered;
const Ast = @import("frontend").Ast;

pub const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    mir: Mir = .{ .name = "mymod" },
    file: Ast.SourceFile = .empty,
    lowered: Lowered = undefined,

    /// `nets` become `Lowered.nodes` (unknowns 0..), and the entry block is
    /// created. `f` must not move afterwards: `lowered.file` points into it.
    pub fn init(f: *Fixture, nets: []const []const u8) !void {
        f.lowered = .{ .file = &f.file };
        const a = f.arena.allocator();
        for (nets) |n|
            try f.lowered.nodes.append(a, .{ .name = n, .kind = .net, .disc = "", .dir = .unspecified });
        _ = try f.mir.addBlock(a);
    }

    pub fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }

    pub fn alloc(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }

    /// `V(net)` — the probe value of unknown `u`.
    pub fn probe(f: *Fixture, u: u32) !Mir.Value {
        return f.mir.addBlockParam(f.alloc(), u);
    }

    pub fn call(f: *Fixture, name: []const u8, args: []const Mir.Value) !Mir.Value {
        const a = f.alloc();
        return f.mir.emitCall(a, .entry, try f.mir.internString(a, name), args);
    }

    /// Build the analysis over what the test has written so far.
    pub fn analysis(f: *Fixture) !Analysis {
        return Analysis.build(f.alloc(), &f.mir, &f.lowered);
    }
};
