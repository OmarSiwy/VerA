//! Source expressions and resolved hierarchical paths → §3.4.7 alias-use
//! diagnostics. Binding names remain legal; value expressions must use the
//! original parameter. Source checking precedes folding and flattening;
//! the second check uses the alias paths recorded while instances are cloned.

const std = @import("std");
const elaborate = @import("../elaborate.zig");
const names = @import("names.zig");
const Kind = @import("../hier_param.zig").Kind;
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Ctx = elaborate.Ctx;
const Error = elaborate.Error;

/// Resolve a declaration's target without accepting an expression use of its
/// alias. Invalid declarations remain the existing E0303/E0331 checks' job.
pub fn original(file: *const Ast.SourceFile, params: []const Ast.ParamDecl, aliases: []const Ast.AliasParam, alias: Ast.AliasParam) ?Ast.StrId {
    for (params) |p| if (p.name == alias.alias) return null;
    var target = alias.target;
    for (0..aliases.len + 1) |_| {
        for (params) |p| if (p.name == target) return target;
        if (Kind.fromName(file.str(target)) != null) return target;
        target = for (aliases) |a| {
            if (a.alias == target) break a.target;
        } else return null;
    }
    return null; // cyclic alias declarations have no original parameter
}

pub fn checkSource(ctx: Ctx) Error!void {
    for (ctx.file.userModules()) |*m| {
        if (m.aliasparams.len == 0) continue;
        var scan: Scan = .{ .ctx = ctx, .aliases = m.aliasparams, .params = m.params };
        try scan.walk(m.*);
    }
    for (ctx.file.paramsets) |*ps| {
        if (ps.aliasparams.len == 0) continue;
        var scan: Scan = .{ .ctx = ctx, .aliases = ps.aliasparams, .params = ps.params };
        try scan.walk(ps.*);
    }
    if (ctx.bag.failed()) return error.DiagnosticsReported;
}

pub fn checkFlat(ctx: Ctx, top: *const Ast.ModuleDecl, aliases: []const Ast.AliasParam) Error!void {
    if (aliases.len == 0) return;
    var scan: Scan = .{ .ctx = ctx, .aliases = aliases, .top = top };
    try scan.walk(top.*);
    if (ctx.bag.failed()) return error.DiagnosticsReported;
}

const Scan = struct {
    ctx: Ctx,
    aliases: []const Ast.AliasParam,
    params: []const Ast.ParamDecl = &.{},
    /// Non-null only after flattening. Local identifier reads were already
    /// checked in their source scope; generated geometry storage may legally
    /// refer to an alias internally, so this pass checks hierarchical reads.
    top: ?*const Ast.ModuleDecl = null,

    fn expr(self: *Scan, e: Ast.ExprId) Error!void {
        if (e == .none) return;
        const file = self.ctx.file;
        const x = &file.exprs;
        if (self.top) |top| {
            if (x.tag(e) == .hier_ident) {
                const path = try names.flatReference(file, self.ctx.arena, top, e);
                for (self.aliases) |al| if (file.strings.eql(al.alias, path)) {
                    try self.reject(e, al.alias, al.target);
                    break;
                };
            }
        } else if (x.tag(e) == .ident) {
            for (self.aliases) |al| if (al.alias == x.strOf(e)) {
                if (original(file, self.params, self.aliases, al)) |target|
                    try self.reject(e, al.alias, target);
                break;
            };
        }
        var buf: [3]Ast.ExprId = undefined;
        for (x.children(e, &buf)) |child| try self.expr(child);
    }

    fn reject(self: *Scan, e: Ast.ExprId, alias: Ast.StrId, target: Ast.StrId) Error!void {
        const file = self.ctx.file;
        try self.ctx.bag.add(.lower, .E0373, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, file.exprs.mainTok(e)), "`{s}` is an alias; reference the original parameter `{s}`", .{ file.str(alias), file.str(target) });
    }

    /// Visit AST expression slots, never binding-name slots (`StrId`). This
    /// includes defaults, ranges, attributes, calls and dead branches, while
    /// `.alias(value)` and defparam/paramset assignment targets stay legal.
    /// Structural recursion also reaches function, task and generate bodies.
    fn walk(self: *Scan, value: anytype) Error!void {
        const T = @TypeOf(value);
        if (T == Ast.ExprId) return self.expr(value);
        if (T == Ast.StmtId) {
            if (value != .none) try self.walk(self.ctx.file.stmt(value));
            return;
        }
        switch (@typeInfo(T)) {
            .@"struct" => inline for (@typeInfo(T).@"struct".field_names) |name| try self.walk(@field(value, name)),
            .@"union" => switch (value) {
                inline else => |payload| try self.walk(payload), // else: every union variant's expression slots are visited
            },
            .optional => if (value) |v| try self.walk(v),
            .pointer => |p| switch (p.size) {
                .slice => for (value) |v| try self.walk(v),
                .one => try self.walk(value.*),
                .many, .c => @compileError("AST alias-use walk needs a bounded pointer"),
            },
            .array => for (value) |v| try self.walk(v),
            else => {}, // else: scalars, enums and binding identifiers contain no expression slots
        }
    }
};
