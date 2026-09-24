//! §3.6 disciplines and natures, §3.11 net compatibility.
//!
//! In: discipline/nature declarations and net declarations. Out: `Lower.disciplines`,
//! per-node disciplines, and the §3.11 compatibility diagnostics.
//!
//! LRM clauses this file's code cites: §3.6, §3.6.1, §3.6.1.2, §3.6.1.3, §3.6.1.4, §3.6.2.1, §3.6.2.2, §3.11, §3.11.1, §3.13.1, §4.4, §5.5.1.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_discipline.f(self, ...)`; `lower.zig` aliases only what other modules call.
//!
//! The functions that take a `file: *const Ast.SourceFile` instead are the ONE
//! owner of the §3.6/§3.11 rules for the whole compiler: which declaration a
//! discipline name denotes (`declOf`), its domain (`domainOf`/`isContinuous`),
//! its access spellings (`accessOf`) and §3.11.1 compatibility
//! (`disciplineConflict`). Elaboration (`elaborate/resolve.zig`,
//! `elaborate/names.zig`) calls them rather than re-deriving any of it.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_node = @import("node.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const diag = @import("diag");
const Oom = Lower.Oom;
const ground = Lower.ground;
const DisciplineInfo = Lower.DisciplineInfo;
const tokenSpan = Lower.tokenSpan;
const err = Lower.err;
const errWith = Lower.errWith;
const emit = Lower.emit;

// ---- §3.6 disciplines & natures --------------------------------------------

/// Build the discipline table and the §3.6.1.4 access-name map. The
/// preprocessor inlines annex D.1, so `electrical`/`thermal`/… arrive as
/// ordinary declarations in `file.disciplines`.
pub fn collectDisciplines(self: *Lower) Oom!void {
    // §4.4 the two standard access identifiers always resolve.
    try self.access_kind.put(self.arena, "V", .potential);
    try self.access_kind.put(self.arena, "I", .flow);
    // §5.5.1 Syntax 5-3 / §4.4 the GENERIC access functions, which resolve on
    // every discipline that binds the half they name. Registering them here
    // rather than in a parallel table is what makes them "an alternative
    // spelling": everything downstream — `branchOf`, `contribIndex`,
    // `resolveLvalue`, the E0501/E0337 checks — sees an `Access` and cannot
    // tell which word produced it. The single exemption is the §3.6.1.4 name
    // match in `checkAccessMatch`.
    try self.access_kind.put(self.arena, lower_contrib.generic_potential, .potential);
    try self.access_kind.put(self.arena, lower_contrib.generic_flow, .flow);

    for (self.file.disciplines) |*d| {
        var info: DisciplineInfo = .{
            .is_discrete = domainOf(d) == .discrete,
            .has_potential = d.potential != .none,
            .has_flow = d.flow != .none,
        };
        // §3.6.2.1 "Conservative disciplines shall not have the same nature
        // specified for both the potential and the flow." The same clause makes
        // each nature's `access` the access function of its half, so one nature
        // on both bindings gives one NAME two meanings — and `access_kind`
        // below would keep whichever of the two it saw last.
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
            if (!std.mem.eql(u8, self.file.str(o.attr.name), "abstol")) continue;
            const v = lower_constfold.constEval(self, o.attr.value) orelse continue;
            switch (o.which) {
                .potential => info.potential_abstol = v.asReal(),
                .flow => info.flow_abstol = v.asReal(),
            }
        }
        try self.disciplines.put(self.arena, self.file.str(d.name), info);
    }
}

/// §3.6.1/§3.6.1.2/§3.13 — the rules the nature+discipline TABLE has to satisfy
/// on its own, before a module refers to any of it. One pass, because all of
/// them read the same two declaration lists.
///
/// WHY THE UNIQUENESS RULES ARE PER-FILE. §3.13.1 gives natures and disciplines
/// one global scope, but VerA prepends annex D's `disciplines.vams` to EVERY
/// compilation whether or not the source included it. A model that declares its
/// own `nature My_Voltage; access = V;` never asked for annex D's `Voltage`, so
/// comparing across the prelude would reject it for a declaration its author did
/// not write. Within one file the comparison is exactly §3.13.1's.
pub fn checkNatureTable(self: *Lower) Oom!void {
    const natures = self.file.natures;
    // §3.6.1.4 access identifier per nature, `.none` when it declares no
    // `access` of its own (a derived nature inherits it — §3.6.1.2).
    const access = try self.arena.alloc(Ast.StrId, natures.len);

    for (natures, access) |*n, *acc| {
        var abstol: bool = false;
        var units: u32 = Mir.no_tok;
        acc.* = .none;
        var acc_tok: u32 = Mir.no_tok;
        for (n.attrs, 0..) |a, ai| {
            const an = self.file.str(a.name);
            // §3.6.1.3 "The name of the attribute shall be unique in the nature
            // being defined". Two values for one name leave `<nature>.<attr>`
            // with no single reading — and the LAST one silently winning is
            // exactly the failure mode that has no symptom.
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
    // Both halves are one code: the integral's tolerance comes from that
    // nature, and a name that resolves to nothing and a name that resolves to
    // an unrelated quantity leave it equally undefined.
    for (natures) |*n| {
        const own = for (n.attrs) |a| {
            if (std.mem.eql(u8, self.file.str(a.name), "idt_nature")) break a;
        } else continue;
        // A non-identifier value is E0340's report, not a second one here.
        if (self.file.exprs.tag(own.value) != .ident) continue;
        const target = self.file.exprs.strOf(own.value);
        const target_base = baseNatureOf(self.file, target);
        if (target_base == .none) {
            try self.err(own.main_tok, .E0341, "`{s}` is not a declared nature", .{self.file.str(target)});
            continue;
        }
        if (n.parent == .none) continue;
        const inherited = idtNatureOf(self.file, n.parent);
        if (inherited == .none or baseNatureOf(self.file, inherited) == target_base) continue;
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

    // §3.6.1/§3.6.2 same-KIND duplicates. E0336 above is the cross-kind case
    // only, and a name declared twice as the same kind is the one that has no
    // symptom: `disciplines`/the nature walk keep the last, so every net of the
    // name silently gets the second declaration's access functions.
    // Same per-file scoping as E0335, and for the same reason (see the header).
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
}

/// §3.6.1.2/§3.6.1.3 — the FORM each attribute's value has to take. The LRM
/// spells three of them out and then makes one blanket statement about the
/// rest, so this is four arms and not a table.
///
/// The identifier/string distinction is one character wide and means two
/// different things: `access = V` introduces a callable name into every module
/// that uses the discipline, `access = "V"` is a value nothing can call.
pub fn checkNatureAttrValue(self: *Lower, n: *const Ast.NatureDecl, a: Ast.NatureAttr, an: []const u8) Oom!void {
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
    // §3.6.1.2: `units` "shall be a string" — §3.11.1's Units Value Rule
    // compares two natures on it, which needs one comparable spelling.
    if (std.mem.eql(u8, an, "units")) {
        if (tag != .str_literal) try self.err(a.main_tok, .E0340, "`units` of `{s}` must be a string", .{
            self.file.str(n.name),
        });
        return;
    }
    // §3.6.1.3 everything else — abstol included — "shall be constant". A
    // nature is declared at source-text level (§3.13.1), outside every module,
    // so there is no scope here in which a runtime name could resolve.
    if (lower_constfold.constEval(self, a.value) == null)
        try self.err(a.main_tok, .E0340, "`{s}` of `{s}` is not a constant expression", .{
            an, self.file.str(n.name),
        });
}

/// §3.11.1 Derived Nature Rule — the base a (possibly derived) nature bottoms
/// out at. Two natures are RELATED when this answers the same name for both.
/// `.none` when the name resolves to no nature at all.
pub fn baseNatureOf(file: *const Ast.SourceFile, name: Ast.StrId) Ast.StrId {
    var want = name;
    var hops: u32 = 0;
    while (hops < 16) : (hops += 1) {
        const nat = for (file.natures) |*n| {
            if (n.name == want) break n;
        } else return if (hops == 0) .none else want;
        if (nat.parent == .none) return want;
        if (nat.parent_access) |half| {
            const d = declOf(file, nat.parent) orelse return want;
            const bound = switch (half) {
                .potential => d.potential,
                .flow => d.flow,
            };
            if (bound == .none) return want;
            want = bound;
        } else want = nat.parent;
    }
    return want;
}

/// The `idt_nature` a nature ends up with, its own or an inherited one.
pub fn idtNatureOf(file: *const Ast.SourceFile, name: Ast.StrId) Ast.StrId {
    var want = name;
    var hops: u32 = 0;
    while (hops < 16) : (hops += 1) {
        const nat = for (file.natures) |*n| {
            if (n.name == want) break n;
        } else return .none;
        for (nat.attrs) |a| {
            if (std.mem.eql(u8, file.str(a.name), "idt_nature") and
                file.exprs.tag(a.value) == .ident)
                return file.exprs.strOf(a.value);
        }
        if (nat.parent == .none) return .none;
        if (nat.parent_access != null) return .none;
        want = nat.parent;
    }
    return .none;
}

/// Which source file a token came from (§3.13.1 scope comparisons). The
/// preprocessor's segment map is the only thing that still knows: by lowering,
/// the prelude and the user's text are one byte stream.
pub fn fileOf(self: *const Lower, tok: u32) diag.FileId {
    return self.bag.locate(self.tokenSpan(tok), null).file;
}

pub const NatureAttrs = struct {
    abstol: ?f64 = null,
    access: ?[]const u8 = null,
    /// §3.6.1.2 `units`, read for §3.11.1's Units Value Rule — the one rule
    /// that relates two natures with no derivation between them.
    units: ?[]const u8 = null,
};

/// §3.6.1.1 walk a (possibly derived) nature for `abstol` (§3.6.1.2),
/// `access` (§3.6.1.4) and `units` (§3.6.1.2). Derived natures inherit what
/// they do not override.
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

/// §3.11.1's five NATURE rules, in the order that makes each one's job visible.
///
///   Non-Existent Binding Rule  "A nature is compatible with a non-existent
///                              discipline binding."
///   Self Rule (Nature)         "A nature is compatible with itself."
///   Base Nature Rule           "A derived nature is compatible with its base."
///   Derived Nature Rule        "Two natures are compatible if they are derived
///                              from the same base nature."
///   Units Value Rule           "Two natures are compatible if they have the
///                              same value for the units attribute."
///
/// The Non-Existent Binding Rule is also what makes §3.11.1's Natureless
/// Discipline Rule fall out with no arm of its own: a discipline that binds no
/// nature is `.none` on both halves, so it conflicts with nobody.
pub fn naturesCompatible(file: *const Ast.SourceFile, a: Ast.StrId, b: Ast.StrId) bool {
    if (a == .none or b == .none) return true;
    if (a == b) return true;
    // The Base and Derived Nature Rules are ONE comparison: `baseNatureOf`
    // answers a base nature with itself, so "derived from its base" and
    // "derived from a common base" are the same equality.
    const base = baseNatureOf(file, a);
    if (base != .none and base == baseNatureOf(file, b)) return true;
    const ua = unitsOf(file, a) orelse return false;
    const ub = unitsOf(file, b) orelse return false;
    return std.mem.eql(u8, ua, ub);
}

/// §3.6.1.2 a nature's `units` string, inherited (§3.6.1.1): what
/// `natureOf(...).units` answers, without the `Lower` that `abstol` needs.
fn unitsOf(file: *const Ast.SourceFile, name: Ast.StrId) ?[]const u8 {
    const v = file.natureAttrExpr(name, "units") orelse return null;
    if (file.exprs.tag(v) != .str_literal) return null;
    return file.str(file.exprs.strOf(v));
}

/// §3.6.2.2 the domain a discipline is IN, or null when it is domainless.
///
/// `unspecified` is not the same answer as domainless. §3.11.1's own worked
/// example says so: "electrical and continuous_elec are compatible disciplines
/// because the DEFAULT domain for discipline electrical is continuous" —
/// electrical declares no `domain` attribute and is still continuous, because
/// it binds natures. Only a discipline that declares no domain AND binds
/// nothing is the deprecated `domainless` of that same example.
pub fn domainOf(d: *const Ast.DisciplineDecl) ?Ast.DisciplineDecl.Domain {
    return switch (d.domain) {
        .continuous, .discrete => d.domain,
        .unspecified => if (d.potential != .none or d.flow != .none) .continuous else null,
    };
}

/// §3.13.1 the declaration a discipline name denotes, or null. Every
/// discipline lookup in the compiler goes through here, so no two stages can
/// answer the question differently.
///
/// The LAST declaration wins. A name can only be declared twice across files
/// (E0342 refuses it within one), and the case that matters is the Annex D
/// prelude VerA prepends to every compilation: Annex D makes those
/// declarations a file the description includes, so a description that does
/// not include it and declares its own `electrical` has exactly one
/// `electrical` by the LRM — its own. The prelude is the prefix of
/// `file.disciplines`, so the description's declaration is the later one.
/// `collectDisciplines` builds lowering's `disciplines` table in declaration
/// order with an overwriting `put`, which is the same answer.
pub fn declOf(file: *const Ast.SourceFile, name: Ast.StrId) ?*const Ast.DisciplineDecl {
    var i = file.disciplines.len;
    while (i > 0) {
        i -= 1;
        if (file.disciplines[i].name == name) return &file.disciplines[i];
    }
    return null;
}

/// `declOf` for a name lowering holds as a string (`node_disciplines`).
pub fn disciplineDecl(self: *const Lower, name: []const u8) ?*const Ast.DisciplineDecl {
    return declOf(self.file, self.file.strings.find(name) orelse return null);
}

/// §3.6.2.2 is `name` a continuous discipline? False for `.none` and for a name
/// no discipline declares.
pub fn isContinuous(file: *const Ast.SourceFile, name: Ast.StrId) bool {
    const d = declOf(file, name) orelse return false;
    return domainOf(d) == .continuous;
}

/// §3.6.1.4 the access-function spelling of one half of discipline `name`:
/// the `access` identifier of the nature bound to that half, inherited per
/// §3.6.1.1. Null when the discipline is undeclared, binds nothing to the
/// half, or the nature's `access` is not an identifier (E0340's case).
pub fn accessOf(file: *const Ast.SourceFile, name: Ast.StrId, half: Ast.PotentialOrFlow) ?Ast.StrId {
    const d = declOf(file, name) orelse return null;
    const nature = switch (half) {
        .potential => d.potential,
        .flow => d.flow,
    };
    if (nature == .none) return null;
    const v = file.natureAttrExpr(nature, "access") orelse return null;
    if (file.exprs.tag(v) != .ident) return null;
    return file.exprs.strOf(v);
}

/// §3.11.1's DISCIPLINE rules. Null when the two are compatible; otherwise the
/// rule that refuses them, worded for the diagnostic's note.
///
///   Self Rule (Discipline)       "A discipline is compatible with itself."
///   Domainless Discipline Rule   "compatible with all disciplines as there is
///                                no nature or domain conflict."
///   Domain Incompatibility Rule  "Disciplines with different domain attributes
///                                are incompatible."
///   Potential / Flow Incompatibility Rules — deferred to `naturesCompatible`.
pub fn disciplineConflict(file: *const Ast.SourceFile, an: Ast.StrId, bn: Ast.StrId) ?[]const u8 {
    if (an == bn) return null;
    const a = declOf(file, an) orelse return null;
    const b = declOf(file, bn) orelse return null;
    const da = domainOf(a) orelse return null;
    const db = domainOf(b) orelse return null;
    const unrelated = "neither the same nature, nor derived from a common base nature, nor agreed on `units`";
    if (da != db)
        return "3.11.1 Domain Incompatibility Rule: disciplines with different domain attributes are incompatible; 3.11 says such nets need a `connect` statement (7.4)";
    if (!naturesCompatible(file, a.potential, b.potential))
        return "3.11.1 Potential Incompatibility Rule: the two potential natures are " ++ unrelated;
    if (!naturesCompatible(file, a.flow, b.flow))
        return "3.11.1 Flow Incompatibility Rule: the two flow natures are " ++ unrelated;
    return null;
}

/// `disciplineConflict` for two names lowering holds as strings.
pub fn nodeDisciplineConflict(self: *const Lower, an: []const u8, bn: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, an, bn)) return null;
    const a = self.file.strings.find(an) orelse return null;
    const b = self.file.strings.find(bn) orelse return null;
    return disciplineConflict(self.file, a, b);
}

/// §3.11: "Certain operations can be done on nets only if the two (or more)
/// nets are compatible. For example, if an access function has two nets as
/// arguments, they must be compatible." §3.12 states the same requirement for
/// the two terminals of a branch declaration, and §7.4.3 for a continuous-time
/// port connection — one rule (§3.11.1), so one helper and one code.
pub fn checkNetCompat(self: *Lower, tok: u32, hi: u16, lo: u16) Oom!void {
    // §1.3.1.1 collapses every ground onto one global reference node, which is
    // not a second NET the rule can be about: `V(p)` is `V(p, gnd)` and spans
    // one discipline.
    if (hi == ground or lo == ground) return;
    const an = self.node_disciplines.items[hi];
    const bn = self.node_disciplines.items[lo];
    // A net with no discipline at all is E0337's, not this rule's: §3.11
    // compares two disciplines and here there is only one.
    if (an.len == 0 or bn.len == 0) return;
    const why = nodeDisciplineConflict(self, an, bn) orelse return;
    var d = self.errWith(tok, .E0355);
    d.msg("`{s}` is of discipline `{s}` and `{s}` is of discipline `{s}`", .{
        lower_node.nodeName(self, hi), an, lower_node.nodeName(self, lo), bn,
    });
    d.note("{s}", .{why});
    try d.emit();
}
