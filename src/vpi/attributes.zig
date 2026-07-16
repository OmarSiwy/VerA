//! Parsed attribute/owner bindings -> IEEE 1364-2005 §26.6.42 attribute
//! objects, values, provenance and parent links. §3.8 / AMS §2.9 supply
//! default 1 and last-name-wins within each decorated language element.

const std = @import("std");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const root = @import("root.zig");
const code = @import("code.zig");

/// Is `o` one of IEEE 1364-2005 §26.6.42's decorated language elements, so
/// `vpi_iterate(vpiAttribute, o)` is a relationship (empty when undecorated)
/// rather than an error?
pub fn supports(o: *const root.Obj) bool {
    return switch (o.kind) {
        .module, .port, .net, .reg, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array => true,
        .code => switch (o.vtype) {
            code.vpiAlways,
            code.vpiInitial,
            code.vpiAnalog,
            code.vpiAssignStmt,
            code.vpiAssignment,
            code.vpiBegin,
            code.vpiCase,
            code.vpiContAssign,
            code.vpiDeassign,
            code.vpiDelayControl,
            code.vpiDisable,
            code.vpiEventControl,
            code.vpiEventStmt,
            code.vpiFor,
            code.vpiForce,
            code.vpiForever,
            code.vpiFork,
            code.vpiIf,
            code.vpiIfElse,
            code.vpiNamedBegin,
            code.vpiNamedFork,
            code.vpiNullStmt,
            code.vpiRelease,
            code.vpiRepeat,
            code.vpiRepeatControl,
            code.vpiWait,
            code.vpiWhile,
            code.vpiContrib,
            code.vpiTaskCall,
            code.vpiSysTaskCall,
            code.vpiOperation,
            code.vpiFuncCall,
            code.vpiSysFuncCall,
            code.vpiAccessFunc,
            code.vpiTask,
            code.vpiFunction,
            code.vpiNamedEvent,
            code.vpiNamedEventArray,
            code.vpiGate,
            code.vpiSwitch,
            code.vpiUdp,
            code.vpiPrimTerm,
            code.vpiModPath,
            code.vpiPathTerm,
            code.vpiTchk,
            code.vpiTchkTerm,
            code.vpiParamAssign,
            code.vpiTableEntry,
            => true,
            else => false, // else: helper objects, selects and constants are not decorated elements in §26.6.42
        },
        else => false, // else: values, iterators and analog topology are not §26.6.42 decorated language elements
    };
}

/// Appends a vpiAttribute row to `parent` for each attribute the source binds
/// to `owner`, its value folded (§3.8/AMS §2.9: no value is 1). A name
/// repeated on one element keeps the later spelling. `definition` is
/// vpiDefAttribute. A no-op for `code.none`. `error.NotElaborated`: a value
/// that does not fold, which the frontend should already have refused.
pub fn attach(b: *code.Builder, parent: u32, owner: Ast.AttributeOwner, definition: bool) root.Error!void {
    if (parent == code.none) return;
    for (b.file.attributes.items) |binding| {
        if (binding.owner.kind != owner.kind or binding.owner.tok != owner.tok) continue;
        for (binding.specs) |spec| {
            const name = b.file.str(spec.name);
            var found: ?u32 = null;
            for (b.objects.items[parent].attributes) |at| {
                const old = b.objects.items[at];
                if (std.mem.eql(u8, old.name, name) and old.props[0].value == @intFromBool(definition)) {
                    found = at;
                    break;
                }
            }
            // Declaration-list fan-out may copy an earlier prefix after a
            // later one was parsed. Source order, not append order, wins.
            if (found) |at| if (b.objects.items[at].src_tok >= spec.main_tok) continue;
            const at = found orelse try b.code(code.vpiAttribute, &.{.{ .tag = code.vpiParent, .to = parent }}, &.{}, &.{.{ .prop = code.vpiDefAttribute, .value = @intFromBool(definition) }});
            var value: ?root.Const = null;
            var bits: ?@import("frontend").Integer.Literal = null;
            if (spec.value == .none) {
                value = .{ .int = 1 };
            } else if (b.file.exprs.tag(spec.value) == .str_literal) {
                value = .{ .str = try b.arena.dupe(u8, b.file.str(b.file.exprs.strOf(spec.value))) };
            } else if (b.run) |r| {
                const scope = b.objects.items[parent].src_engine orelse b.engine;
                const v = r.vpiAttributeValue(b.arena, scope, spec.value) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.NotElaborated;
                switch (v) {
                    .bits => |lit| bits = lit,
                    .real => |real| value = .{ .real = real },
                }
            } else {
                value = constfold.fold(b.file, spec.value, AnalogEnv{ .b = b }) orelse return error.NotElaborated;
            }
            b.objects.items[at].name = try b.arena.dupe(u8, name);
            b.objects.items[at].src_tok = spec.main_tok;
            b.objects.items[at].value = value;
            b.objects.items[at].constant_bits = bits;
            if (found == null) b.objects.items[parent].attributes = try std.mem.concat(b.arena, u32, &.{ b.objects.items[parent].attributes, &.{at} });
        }
    }
}

/// Analog attributes use the same final parameter constants the VPI model
/// publishes, resolving the source spelling in the declaring instance.
const AnalogEnv = struct {
    b: *code.Builder,

    /// `constfold`'s leaf hook: a parameter's folded value, or one of the
    /// conversion calls the analog validator folds. Null: not a constant.
    pub fn leaf(env: AnalogEnv, e: Ast.ExprId) ?root.Const {
        // These are the conversion calls the analog constant-expression
        // validator folds (lower/constfold.zig, AMS §9.11/§9.14).
        if (env.b.file.exprs.tag(e) == .sys_call) {
            const ex = &env.b.file.exprs;
            const args = ex.args(e);
            if (args.len != 1) return null;
            const name = env.b.file.str(ex.strOf(e));
            const clog = std.mem.eql(u8, name, "$clog2");
            const v = (if (clog) constfold.foldSized(env.b.file, args[0], env) else constfold.fold(env.b.file, args[0], env)) orelse return null;
            if (v == .str) return null;
            if (clog) return .{ .int = constfold.clog2(v.asIntExact() orelse return null, constfold.clog2Width(env.b.file, args[0], env) orelse return null) };
            if (std.mem.eql(u8, name, "$itor")) return .{ .real = @floatFromInt(v.asIntExact() orelse return null) };
            if (std.mem.eql(u8, name, "$rtoi")) {
                const t = @trunc(v.asReal());
                if (!(t >= -2147483648.0 and t <= 2147483647.0)) return null;
                return .{ .int = @intFromFloat(t) };
            }
            return null;
        }
        if (env.b.file.exprs.tag(e) != .ident) return null;
        const at = env.b.lookup(env.b.file.str(env.b.file.exprs.strOf(e)));
        if (at == code.none or env.b.objects.items[at].kind != .parameter) return null;
        return env.b.objects.items[at].value;
    }
    fn parameter(env: AnalogEnv, e: Ast.ExprId) ?@import("ir").Lower.ParamInfo {
        if (env.b.file.exprs.tag(e) != .ident) return null;
        const at = env.b.lookup(env.b.file.str(env.b.file.exprs.strOf(e)));
        if (at == code.none) return null;
        const full = env.b.objects.items[at].full;
        const lowered = (env.b.analog orelse return null).lowered orelse return null;
        if (full.len <= env.b.top_name.len) return null;
        const name = full[env.b.top_name.len + 1 ..];
        for (lowered.params.items) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
    /// `constfold`'s signedness hook; an `integer` parameter is signed.
    pub fn signed(env: AnalogEnv, e: Ast.ExprId) ?bool {
        if (env.b.file.exprs.tag(e) != .ident) return constfold.clog2Signed(env.b.file, e, env);
        const p = env.parameter(e) orelse return null;
        return if (p.integer32) true else p.source_signed;
    }
    /// `constfold`'s width hook: 32 for an `integer` parameter, else the
    /// source width.
    pub fn width(env: AnalogEnv, e: Ast.ExprId) ?u32 {
        const p = env.parameter(e) orelse return null;
        return if (p.integer32) 32 else p.source_width;
    }
};
