//! §3.6 disciplines and natures and §3.11.1 compatibility, read from the AST
//! alone. The ONE owner of these rules: which declaration a discipline name
//! denotes (`declOf`), its domain (`domainOf`/`isContinuous`), its access
//! spellings (`accessOf`), nature derivation (`baseNatureOf`/`idtNatureOf`)
//! and §3.11.1 compatibility (`disciplineConflict`). Elaboration and lowering
//! both call them.

const std = @import("std");
const Ast = @import("frontend").Ast;

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
