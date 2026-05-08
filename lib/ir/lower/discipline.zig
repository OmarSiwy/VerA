//! §3.6 disciplines and natures, §3.11 net compatibility.
//!
//! In: discipline/nature declarations and net declarations. Out: `Lower.disciplines`,
//! per-node disciplines, and the §3.11 compatibility diagnostics. The AST-only rules
//! live in `ir/discipline_rules.zig`.
//! LRM: §3.6, §3.6.1, §3.6.1.2-§3.6.1.4, §3.6.2.1, §3.6.2.2, §3.11, §3.11.1, §3.13.1, §4.4, §5.5.1.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_node = @import("node.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const rules = @import("../discipline_rules.zig");
const diag = @import("diag");
const Oom = Lower.Oom;
const ground = Lower.ground;
const DisciplineInfo = Lower.DisciplineInfo;
const tokenSpan = Lower.tokenSpan;
const err = Lower.err;
const errWith = Lower.errWith;
const emit = Lower.emit;

// ---- §3.6 disciplines & natures --------------------------------------------

/// Builds the discipline table and the §3.6.1.4 access-name map. The
/// preprocessor inlines annex D.1, so `electrical`, `thermal` and the rest arrive
/// as ordinary declarations in `file.disciplines`.
pub fn collectDisciplines(self: *Lower) Oom!void {
    // §4.4 the two standard access identifiers always resolve.
    try self.access_kind.put(self.arena, "V", .potential);
    try self.access_kind.put(self.arena, "I", .flow);
    // §5.5.1 Syntax 5-3 / §4.4 the generic access functions, which resolve on
    // every discipline that binds the half they name. Registered in the same map
    // so they are "an alternative spelling": downstream sees an `Access` and cannot
    // tell which word produced it, except `checkAccessMatch`'s §3.6.1.4 name match.
    try self.access_kind.put(self.arena, lower_contrib.generic_potential, .potential);
    try self.access_kind.put(self.arena, lower_contrib.generic_flow, .flow);

    for (self.file.disciplines) |*d| {
        var info: DisciplineInfo = .{
            .is_discrete = rules.domainOf(d) == .discrete,
            .has_potential = d.potential != .none,
            .has_flow = d.flow != .none,
        };
        // §3.6.2.1 "Conservative disciplines shall not have the same nature
        // specified for both the potential and the flow." The same clause makes
        // each nature's `access` the access function of its half, so one nature
        // on both bindings gives one name two meanings.
        if (info.has_potential and d.potential == d.flow)
            try self.err(d.main_tok, .E0338, "`{s}` binds `{s}` to both its potential and its flow", .{
                self.file.str(d.name), self.file.str(d.potential),
            });
        // §3.6.2.2 "It is an error for a discipline to have a domain binding of
        // discrete if it has nature bindings." Either half is enough; a
        // discrete net is solved by the digital kernel, which has no continuous
        // quantity for the nature to describe.
        if (info.is_discrete and (info.has_potential or info.has_flow))
            try self.err(d.main_tok, .E0339, "`{s}` declares `domain discrete` and binds a nature", .{
                self.file.str(d.name),
            });
        if (d.potential != .none) {
            const n = natureOf(self, d.potential);
            if (n.abstol) |a| info.potential_abstol = a;
            if (n.access) |acc| {
                info.potential_access = acc;
                try self.access_kind.put(self.arena, acc, .potential);
            }
        }
        if (d.flow != .none) {
            const n = natureOf(self, d.flow);
            if (n.abstol) |a| info.flow_abstol = a;
            if (n.access) |acc| {
                info.flow_access = acc;
                try self.access_kind.put(self.arena, acc, .flow);
            }
        }
        // §3.6.2.3 discipline-level attribute overrides win over the nature's.
        for (d.overrides) |o| {
            // §3.6.2.5 "To do so from a discipline declaration, the bound
            // nature and attribute needs to be defined."
            const bound = switch (o.which) {
                .potential => d.potential,
                .flow => d.flow,
            };
            if (bound == .none)
                try self.err(o.attr.main_tok, .E0370, "`{s}.{s}` in `{s}`, which binds no {s} nature", .{
                    @tagName(o.which), self.file.str(o.attr.name), self.file.str(d.name), @tagName(o.which),
                })
            else if (self.file.natureAttrExpr(bound, self.file.str(o.attr.name)) == null)
                try self.err(o.attr.main_tok, .E0370, "`{s}.{s}` in `{s}`: the bound nature `{s}` does not define `{s}`", .{
                    @tagName(o.which), self.file.str(o.attr.name), self.file.str(d.name), self.file.str(bound), self.file.str(o.attr.name),
                });
            if (!std.mem.eql(u8, self.file.str(o.attr.name), "abstol")) continue;
            const v = lower_constfold.constEval(self, o.attr.value) orelse continue;
            switch (o.which) {
                .potential => info.potential_abstol = v.asReal(),
                .flow => info.flow_abstol = v.asReal(),
            }
        }
        try self.out.disciplines.put(self.arena, self.file.str(d.name), info);
    }
}

/// Checks the rules the nature and discipline declarations must satisfy on their
/// own, before a module refers to them (LRM §3.6.1, §3.6.1.2, §3.13).
///
/// The uniqueness rules compare within one source file. §3.13.1 gives natures and
/// disciplines one global scope, but VerA prepends annex D's `disciplines.vams` to
/// every compilation, so comparing across that prelude would reject a model's own
/// `nature My_Voltage; access = V;` for a declaration its author did not write.
pub fn checkNatureTable(self: *Lower) Oom!void {
    const natures = self.file.natures;
    // §3.6.1.4 access identifier per nature, `.none` when it declares no
    // `access` of its own (a derived nature inherits it, §3.6.1.2).
    const access = try self.arena.alloc(Ast.StrId, natures.len);

    for (natures, access) |*n, *acc| {
        var abstol: bool = false;
        var units: u32 = Mir.no_tok;
        acc.* = .none;
        var acc_tok: u32 = Mir.no_tok;
        for (n.attrs, 0..) |a, ai| {
            const an = self.file.str(a.name);
            // §3.6.1.3 "The name of the attribute shall be unique in the nature
            // being defined". Otherwise the last value would silently win.
            // ponytail: O(n²) over the handful of attributes one nature has.
            for (n.attrs[0..ai]) |prev| {
                if (prev.name != a.name) continue;
                try self.err(a.main_tok, .E0343, "`{s}` is already an attribute of `{s}`", .{
                    an, self.file.str(n.name),
                });
                break;
            }
            try checkNatureAttrValue(self, n, a, an);
            if (std.mem.eql(u8, an, "abstol")) {
                abstol = true;
            } else if (std.mem.eql(u8, an, "units")) {
                units = a.main_tok;
            } else if (std.mem.eql(u8, an, "access")) {
                acc_tok = a.main_tok;
                if (self.file.exprs.tag(a.value) == .ident) acc.* = self.file.exprs.strOf(a.value);
            }
        }
        const name = self.file.str(n.name);
        if (n.parent == .none) {
            // §3.6.1: a nature definition "shall include all the required
            // attributes specified in 3.6.1.2"; that clause says of abstol,
            // access and units alike that each "is required for all base
            // natures". A nature meaning to inherit them says so with a parent.
            const missing: []const u8 = if (!abstol)
                "abstol"
            else if (acc_tok == Mir.no_tok)
                "access"
            else if (units == Mir.no_tok)
                "units"
            else
                "";
            if (missing.len != 0) {
                var b = self.errWith(n.main_tok, .E0332);
                b.msg("`{s}` has no `{s}`", .{ name, missing });
                b.help("or derive it from a base nature: `nature {s} : <parent>;`", .{name});
                try b.emit();
            }
        } else {
            if (units != Mir.no_tok) try self.err(units, .E0333, "`{s}`", .{name});
            if (acc_tok != Mir.no_tok) try self.err(acc_tok, .E0334, "`{s}`", .{name});
        }
    }

    // §3.6.1.2 idt_nature "shall be the name (not a string) of a nature which
    // is defined elsewhere", and a derived nature that overrides it "shall be
    // related (share the same base nature) to the nature the parent uses".
    // Both halves share one code: an unresolved name and an unrelated nature
    // leave the integral's tolerance equally undefined.
    for (natures) |*n| {
        const own = for (n.attrs) |a| {
            if (std.mem.eql(u8, self.file.str(a.name), "idt_nature")) break a;
        } else continue;
        // A non-identifier value is E0340's report, not a second one here.
        if (self.file.exprs.tag(own.value) != .ident) continue;
        const target = self.file.exprs.strOf(own.value);
        const target_base = rules.baseNatureOf(self.file, target);
        if (target_base == .none) {
            try self.err(own.main_tok, .E0341, "`{s}` is not a declared nature", .{self.file.str(target)});
            continue;
        }
        if (n.parent == .none) continue;
        const inherited = rules.idtNatureOf(self.file, n.parent);
        if (inherited == .none or rules.baseNatureOf(self.file, inherited) == target_base) continue;
        var b = self.errWith(own.main_tok, .E0341);
        b.msg("`{s}` is not related to `{s}`", .{ self.file.str(target), self.file.str(inherited) });
        b.note("`{s}` derives from `{s}`, whose `idt_nature` is `{s}`; an override shares its base nature", .{
            self.file.str(n.name), self.file.str(n.parent), self.file.str(inherited),
        });
        try b.emit();
    }

    // §3.13.2 "the access function of each base nature shall be unique". Keyed
    // on the nature NAME, so one nature declared twice (annex D's own headers
    // arrive that way when a fixture restates them) is one claim, not two.
    for (natures, access, 0..) |*a, a_acc, i| {
        if (a.parent != .none or a_acc == .none) continue;
        for (natures[i + 1 ..], access[i + 1 ..]) |*b, b_acc| {
            if (b.parent != .none or b_acc != a_acc or b.name == a.name) continue;
            if (fileOf(self, a.main_tok) != fileOf(self, b.main_tok)) continue;
            try self.err(b.main_tok, .E0335, "`{s}` and `{s}` both access `{s}`", .{
                self.file.str(a.name), self.file.str(b.name), self.file.str(b_acc),
            });
        }
    }

    // §3.13.1 natures and disciplines share ONE global scope.
    for (natures) |*n| {
        for (self.file.disciplines) |*d| {
            if (d.name != n.name or fileOf(self, d.main_tok) != fileOf(self, n.main_tok)) continue;
            try self.err(d.main_tok, .E0336, "`{s}` is already a nature", .{self.file.str(d.name)});
        }
    }

    // §3.6.1/§3.6.2 same-kind duplicates (E0336 above is the cross-kind case).
    // Without this the last declaration would silently win. Scoped per file,
    // like E0335 (see the doc comment).
    for (natures, 0..) |*a, i| {
        for (natures[i + 1 ..]) |*b| {
            if (b.name != a.name or fileOf(self, a.main_tok) != fileOf(self, b.main_tok)) continue;
            try self.err(b.main_tok, .E0342, "nature `{s}` is already declared", .{self.file.str(b.name)});
        }
    }
    for (self.file.disciplines, 0..) |*a, i| {
        for (self.file.disciplines[i + 1 ..]) |*b| {
            if (b.name != a.name or fileOf(self, a.main_tok) != fileOf(self, b.main_tok)) continue;
            try self.err(b.main_tok, .E0342, "discipline `{s}` is already declared", .{self.file.str(b.name)});
        }
    }

    // §3.6.2.7 "LIKE NATURES, a discipline can specify user-defined
    // attributes ... (see 3.6.1.3)", so §3.6.1.3's rule holds in the
    // discipline being defined: the name "shall be unique" and the value
    // "shall be constant". Same two codes as the nature half above.
    for (self.file.disciplines) |*d| for (d.attrs, 0..) |a, ai| {
        for (d.attrs[0..ai]) |prev| {
            if (prev.name != a.name) continue;
            try self.err(a.main_tok, .E0343, "`{s}` is already an attribute of discipline `{s}`", .{
                self.file.str(a.name), self.file.str(d.name),
            });
            break;
        }
        if (lower_constfold.constEval(self, a.value) == null)
            try self.err(a.main_tok, .E0340, "`{s}` of discipline `{s}` is not a constant expression", .{
                self.file.str(a.name), self.file.str(d.name),
            });
    };
}

/// §3.6.1.2/§3.6.1.3: the form each attribute's value has to take. `access = V`
/// introduces a callable name; `access = "V"` is a value nothing can call.
fn checkNatureAttrValue(self: *Lower, n: *const Ast.NatureDecl, a: Ast.NatureAttr, an: []const u8) Oom!void {
    const tag = self.file.exprs.tag(a.value);
    // §3.6.1.2: `access` "shall be an identifier (by name, not as a string)";
    // idt_nature/ddt_nature take "the name (not a string) of a nature".
    const wants_ident = std.mem.eql(u8, an, "access") or
        std.mem.eql(u8, an, "idt_nature") or
        std.mem.eql(u8, an, "ddt_nature");
    if (wants_ident) {
        if (tag != .ident) try self.err(a.main_tok, .E0340, "`{s}` of `{s}` must be an identifier, not a value", .{
            an, self.file.str(n.name),
        });
        return;
    }
    // §3.6.1.2: `units` "shall be a string"; §3.11.1's Units Value Rule compares it.
    if (std.mem.eql(u8, an, "units")) {
        if (tag != .str_literal) try self.err(a.main_tok, .E0340, "`units` of `{s}` must be a string", .{
            self.file.str(n.name),
        });
        return;
    }
    // §3.6.1.3 everything else, abstol included, "shall be constant". A nature is
    // declared outside every module (§3.13.1), so no runtime name could resolve.
    if (lower_constfold.constEval(self, a.value) == null)
        try self.err(a.main_tok, .E0340, "`{s}` of `{s}` is not a constant expression", .{
            an, self.file.str(n.name),
        });
}

/// Which source file a token came from (§3.13.1 scope comparisons). Only the
/// preprocessor's segment map still knows; the prelude and user text are one stream.
fn fileOf(self: *const Lower, tok: u32) diag.FileId {
    return self.bag.locate(self.tokenSpan(tok), null).file;
}

/// The attributes `natureOf` resolves for one nature; null when neither it nor a parent sets one.
pub const NatureAttrs = struct {
    abstol: ?f64 = null,
    access: ?[]const u8 = null,
    /// §3.6.1.2 `units`, read for §3.11.1's Units Value Rule.
    units: ?[]const u8 = null,
};

/// Returns a nature's `abstol`, `access` and `units`, walking a derived nature's
/// parents for what it does not override (LRM §3.6.1.1, §3.6.1.2, §3.6.1.4).
pub fn natureOf(self: *Lower, name: Ast.StrId) NatureAttrs {
    var out: NatureAttrs = .{};
    // ponytail: share the AST's 16-hop walk; extend it there if deeper inheritance is needed.
    if (self.file.natureAttrExpr(name, "abstol")) |v| {
        if (lower_constfold.constEval(self, v)) |c| out.abstol = c.asReal();
    }
    if (self.file.natureAttrExpr(name, "access")) |v| {
        if (self.file.exprs.tag(v) == .ident) out.access = self.file.str(self.file.exprs.strOf(v));
    }
    if (self.file.natureAttrExpr(name, "units")) |v| {
        if (self.file.exprs.tag(v) == .str_literal) out.units = self.file.str(self.file.exprs.strOf(v));
    }
    return out;
}

// ---- §3.11 net compatibility -----------------------------------------------

/// Returns the declaration of the discipline named `name`, or null.
pub fn disciplineDecl(self: *const Lower, name: []const u8) ?*const Ast.DisciplineDecl {
    return rules.declOf(self.file, self.file.strings.find(name) orelse return null);
}

/// Returns why disciplines `an` and `bn` are incompatible, or null when they are
/// compatible or either is undeclared (LRM §3.11.1).
pub fn nodeDisciplineConflict(self: *const Lower, an: []const u8, bn: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, an, bn)) return null;
    const a = self.file.strings.find(an) orelse return null;
    const b = self.file.strings.find(bn) orelse return null;
    return rules.disciplineConflict(self.file, a, b);
}

/// Reports E0355 when nodes `hi` and `lo` have incompatible disciplines. Used for
/// access-function arguments (LRM §3.11), branch terminals (§3.12) and port
/// connections (§7.4.3).
pub fn checkNetCompat(self: *Lower, tok: u32, hi: u16, lo: u16) Oom!void {
    // §1.3.1.1: ground is the global reference, not a second net; `V(p)` spans one discipline.
    if (hi == ground or lo == ground) return;
    const an = self.out.nodes.items(.disc)[hi];
    const bn = self.out.nodes.items(.disc)[lo];
    // A net with no discipline is E0337's to report.
    if (an.len == 0 or bn.len == 0) return;
    const why = nodeDisciplineConflict(self, an, bn) orelse return;
    var d = self.errWith(tok, .E0355);
    d.msg("`{s}` is of discipline `{s}` and `{s}` is of discipline `{s}`", .{
        lower_node.nodeName(self, hi), an, lower_node.nodeName(self, lo), bn,
    });
    d.note("{s}", .{why});
    try d.emit();
}
