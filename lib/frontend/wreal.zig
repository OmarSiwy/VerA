//! §3.7 and §6.5.3, the two `wreal` rules about STRUCTURE rather than value.
//!
//! In: a parsed source file. Out: E0918 (a wreal net with a second driver in
//! its module) and E0919 (a port joining a wreal to a net type other than
//! wire/tri/wreal) in the bag.
//!
//! An AST query with no stage state, so it lives at the bottom of the stack
//! both of its callers import: the elaborator (`ir`, a `.va` design, §7.4.2
//! "the real-value nets shall obey the rules imposed by 3.7") and the digital
//! runner (`sim`, a `.v` design). One copy of the rule for both.
//!
//! LRM clauses this file's code cites: §3.7, §6.5.3, §7.4.2.

const std = @import("std");
const diag = @import("diag");
const Ast = @import("ast.zig");

/// Checked on the parsed file, before elaboration, so a file that breaks one
/// hears the LRM's reason.
// ponytail: drivers are counted per module (assigns and the declaration's
// own `=`); a driver arriving through a port is not. Counting those needs the
// elaborated net, which `declare` builds after this.
pub fn check(file: *const Ast.SourceFile, starts: []const u32, bag: *diag.Bag) std.mem.Allocator.Error!void {
    const ex = &file.exprs;
    for (file.modules) |*m| {
        for (m.nets) |n| if (n.kind == .wreal) try wrealDrivers(file, starts, bag, m, n.name, n.init != .none);
        for (m.ports) |p| if (p.kind == .wreal) try wrealDrivers(file, starts, bag, m, p.name, false);
        for (m.instances) |inst| {
            const child = for (file.modules) |*c| {
                if (c.name == inst.module) break c;
            } else continue;
            for (inst.ports, 0..) |conn, i| {
                if (conn.expr == .none or ex.tag(conn.expr) != .ident) continue;
                const port = if (conn.name == .none) (if (i < child.ports.len) child.ports[i] else continue) else for (child.ports) |p| {
                    if (p.name == conn.name) break p;
                } else continue;
                // A name the parent never declared as a net is a variable
                // (a real expression, which 3.7 allows) or an implicit wire.
                const outer = netKind(m, ex.strOf(conn.expr)) orelse continue;
                if ((outer == .wreal) == (port.kind == .wreal)) continue;
                const other = if (outer == .wreal) port.kind else outer;
                if (other == .wire or other == .tri) continue;
                const start = starts[@min(conn.main_tok, starts.len - 1)];
                try bag.add(.lower, .E0919, .{ .start = start, .end = start }, "`{s}` is a {s} and port `{s}` is a {s}", .{
                    file.str(ex.strOf(conn.expr)), @tagName(outer), file.str(port.name), @tagName(port.kind),
                });
            }
        }
    }
}

fn wrealDrivers(file: *const Ast.SourceFile, starts: []const u32, bag: *diag.Bag, m: *const Ast.ModuleDecl, name: Ast.StrId, declared: bool) std.mem.Allocator.Error!void {
    var count: u32 = @intFromBool(declared);
    for (m.assigns) |a| {
        if (a.target == .none or file.exprs.tag(a.target) != .ident or file.exprs.strOf(a.target) != name) continue;
        count += 1;
        if (count != 2) continue;
        const start = starts[@min(a.main_tok, starts.len - 1)];
        try bag.add(.lower, .E0918, .{ .start = start, .end = start }, "`{s}` is already driven", .{file.str(name)});
    }
}

/// The declared net type of `name` in `m`, or null if `m` declares no such net.
fn netKind(m: *const Ast.ModuleDecl, name: Ast.StrId) ?Ast.NetKind {
    for (m.ports) |p| if (p.name == name) return p.kind;
    for (m.nets) |n| if (n.name == name) return n.kind;
    return null;
}
