//! Clause 9 system functions and tasks in analog context, and their arguments.
//!
//! In: `$`-calls. Out: MIR calls or folded values, and the host fields (`$simparam`) they read.
//!
//! LRM clauses this file's code cites: §3.4.7, §4.3.1, §9.2, §9.5, §9.5.4.2, §9.5.7, §9.15, §9.17.3, §9.18, §9.20, §9.22, §9.23.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_sysfunc.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_event = @import("event.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_limit = @import("limit.zig");
const lower_table_model = @import("table_model.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Elaborate = @import("../elaborate.zig");
const Lexer = @import("frontend").Lexer;
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const TypedValue = Lower.TypedValue;
const tokenSpan = Lower.tokenSpan;
const err = Lower.err;
const errWith = Lower.errWith;
const poison = Lower.poison;
const emit = Lower.emit;
const call = Lower.call;
const toReal = Lower.toReal;

// ---- ch9 system functions ---------------------------------------------------

/// ch9 system function in expression position. Everything not on the
/// deliberately-unsupported list becomes a `call`; codegen.emitCall dispatches
/// on the name and owns the simulator semantics.
pub fn lowerSysCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    if (lower_event.isDigitalOnlySysFunc(name)) { // §9.2
        try self.err(self.file.exprs.mainTok(e), .E0806, "`{s}`", .{name});
        return poison;
    }
    // §9.22/§9.23 — the driver access family, refused because this is not a
    // connect module (see `isConnectModuleOnlySysFunc` for why the test is a
    // name test today and what it narrows into later).
    if (lower_event.isConnectModuleOnlySysFunc(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0818);
        b.msg("`{s}` can only be called from a connect module", .{name});
        b.note("§9.22: \"Driver access functions can only be called from connect modules.\" This is a `module`", .{});
        try b.emit();
        return poison;
    }
    // §4.3.1 Table 4-14 gives these system spellings the same operand-sensitive
    // result types as their traditional spellings. A generic call's name-only
    // sysFuncTy cannot express that: it would turn integer division into real
    // division. Use typed arithmetic opcodes, after the context checks above.
    if (std.mem.eql(u8, name, "$abs") or std.mem.eql(u8, name, "$min") or
        std.mem.eql(u8, name, "$max")) return lower_expr.lowerBuiltin(self, e);
    // §3.4.7/§9.18: this module wrote `aliasparam m = $mfactor;`, so the two
    // names denote one location and the location is the parameter the alias
    // declared (`aliasSystemParam`). Both spellings read it — §3.4.7 rule 2 has
    // the equations use the ORIGINAL name, which is this one.
    if (self.mfactor_param) |pi| if (std.mem.eql(u8, name, "$mfactor"))
        return .{ .v = self.param_values.items[pi], .ty = .real };
    // §9.13 Table 9-10. Before everything below, because the seed is an inout
    // argument and the write-back is not something a `call` result can express.
    if (try lower_event.lowerRandom(self, ex.mainTok(e), name, ex.args(e))) |tv| return tv;
    // Annex G Table G.1: the OVI Verilog-A v1.0 spelling `$limexp` was replaced
    // in v2.0 by the bare `limexp` (§4.5.13). Not an alias — a `$` name is a
    // system function and `$limexp` is in neither Table 9-11 nor A.8.2, so the
    // name does not exist. One entry, not a table: it is the only retired v1.0
    // `$` spelling in G.1 that VerA ever accepted.
    if (std.mem.eql(u8, name, "$limexp")) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0808);
        b.msg("`$limexp`", .{});
        b.suggestHere("limexp");
        try b.emit();
        return poison;
    }
    // §9.17.3 fixes the arity of the two algorithms it names outright: fetlim
    // takes a third argument (the threshold voltage) and pnjlim a third and a
    // fourth (vte and vcrit). Checked HERE and not in cg_limit.zig, where the
    // count was already known: cg_limit's job is to decide whether the backend
    // can honour a well-formed call, and §4.5.15 lets it decline any of them
    // silently — a call that is not legal in the first place is a source error
    // and has to be reported whether or not codegen would have taken it.
    //
    // Only these two names, and only when the string is written literally: the
    // same clause says a simulator may treat an unknown or unsupported string
    // "just as if no string had been supplied", so nothing else here is an
    // error, and `$limit(V(a))` with no string at all is Syntax 9-12 line 1.
    if (std.mem.eql(u8, name, "$limit")) {
        const args = ex.args(e);
        if (args.len >= 2) {
            if (lower_constfold.constEval(self, args[1])) |c| switch (c) {
                .str => |s| {
                    const need: usize = if (std.mem.eql(u8, s, "pnjlim"))
                        4
                    else if (std.mem.eql(u8, s, "fetlim")) 3 else 0;
                    if (need != 0 and args.len < need) {
                        var b = self.errWith(self.file.exprs.mainTok(e), .E0809);
                        b.msg("`\"{s}\"` needs {d} arguments to `$limit`, got {d}", .{ s, need, args.len });
                        try b.emit();
                        return poison;
                    }
                },
                else => {},
            };
        }
    }
    // §9.15: "If param_name is not known, and the optional expression is not
    // supplied, then an error is generated." Answering a name this engine does
    // not have with a silent 0.0 is indistinguishable from a simulator that
    // really does carry that parameter and really does read zero, which is the
    // corruption the clause exists to prevent.
    //
    // Only when the name is a literal: §9.15 also allows "a string parameter or
    // a string variable", and a name that is not known until the solve cannot be
    // judged here — the fallback rule is the user's cover for that case.
    if (std.mem.eql(u8, name, "$simprobe")) return lower_hier_name.lowerSimprobe(self, e);
    // §9.15 Table 9-28's two HIERARCHY rows are elaboration facts, so they are
    // answered here and never reach codegen: "module" is "the name of the module
    // from which $simparam$str is called" and "instance" is "the hierarchical
    // name of the instance from which $simparam$str is called". Codegen sees
    // one flattened module and answered them with the TOP's name and "" — right
    // only for a call that happens to sit in the top module. `cur_unit` is the
    // instance that wrote this block, which is exactly what the clause asks for.
    if (std.mem.eql(u8, name, "$simparam$str") and self.cur_unit < self.unit_paths.len) {
        const a = ex.args(e);
        if (a.len >= 1) if (constStrArg(self, a[0])) |nm| {
            const u = self.unit_paths[self.cur_unit];
            if (std.mem.eql(u8, nm, "module"))
                return .{ .v = try self.mir.addStrConst(self.arena, u.module), .ty = .string };
            // §9.15's worked example produces "testbench.dut1": a top-level
            // module's instance name is its module name, and the path is joined
            // to it by §6.7's period. `path` already carries the separator.
            if (std.mem.eql(u8, nm, "instance")) {
                const top = if (self.unit_paths.len != 0) self.unit_paths[0].module else u.module;
                const full = if (u.path.len == 0)
                    top
                else
                    try std.fmt.allocPrint(self.arena, "{s}{c}{s}", .{ top, Elaborate.sep, u.path[0 .. u.path.len - 1] });
                return .{ .v = try self.mir.addStrConst(self.arena, full), .ty = .string };
            }
        };
    }
    if (std.mem.eql(u8, name, "$simparam")) {
        const args = ex.args(e);
        if (args.len == 1) {
            if (lower_constfold.constEval(self, args[0])) |c| switch (c) {
                .str => |s| if (simparamValue(self, s) == null and !simparamIsRuntime(s)) {
                    var b = self.errWith(self.file.exprs.mainTok(e), .E0811);
                    b.msg("`\"{s}\"`", .{s});
                    b.note("$simparam(\"{s}\", <expression>) supplies the value to use instead, and §9.15 makes that form legal for any name", .{s});
                    try b.emit();
                    return poison;
                },
                else => {},
            };
        }
        // The Newton-iterate counter costs an `Instance` field plus an
        // `updateState`/`stateCtl` pair, so it is emitted only for a model that
        // reads one of the two names that need it (`simparamIsRuntime`).
        if (args.len >= 1) if (constStrArg(self, args[0])) |s| {
            if (simparamIsRuntime(s)) self.uses_newton_iter = true;
            if (simparamHostField(s) != null) self.uses_host_simparam = true;
        };
    }
    const sys_args = if (ex.extraOf(e) < ex.pool.items.len) ex.args(e) else &[_]Ast.ExprId{};
    // §9.20 the two alias functions: six validity rules, all of them about the
    // CALL rather than the value, so all of them here (E0812) — and then the
    // alias, which is a `node_voltages` write and a constant return. The call
    // never reaches codegen: "one (1) if the hierarchical_reference_string
    // points to a valid continuous node and zero (0) otherwise" is decided by a
    // name lookup against the elaborated design, which is this pass's table.
    if (std.mem.eql(u8, name, "$analog_node_alias") or std.mem.eql(u8, name, "$analog_port_alias")) {
        return switch (try lower_hier_name.checkAliasCall(self, e, name, sys_args)) {
            .refused => poison,
            .bound => .{ .v = try self.mir.addIntConst(self.arena, 1), .ty = .integer },
            .unresolved => .{ .v = try self.mir.addIntConst(self.arena, 0), .ty = .integer },
        };
    }
    // §9.17.3 Syntax 9-12's THIRD form, `$limit(access, analog_function_identifier,
    // arg_list)`. The second argument names a §4.7 function, so it is not a value
    // and must not be looked up as one (E0314 was the whole gap).
    if (std.mem.eql(u8, name, "$limit") and sys_args.len >= 2) {
        if (lower_limit.limitUserFunc(self, sys_args[1])) |fd| {
            // "The arguments of the user-defined function shall all be declared
            // input." The simulator supplies all of them — the probe's value for
            // this iteration, the value $limit returned on the previous one, then
            // the call's tail — so an `output` formal would write back into the
            // solver's own iteration history mid-Newton-step, and §9.17.3 defines
            // no meaning for that.
            for (fd.args) |formal| {
                if (formal.direction == .input) continue;
                var b = self.errWith(self.file.exprs.mainTok(e), .E0814);
                b.msg("formal `{s}` of the `$limit` limiter `{s}` is declared `{s}`", .{
                    self.file.str(formal.name), self.file.str(fd.name), @tagName(formal.direction),
                });
                b.note("§9.17.3: \"The arguments of the user-defined function shall all be declared input\"", .{});
                try b.emit();
                return poison;
            }
            return lower_limit.lowerLimitUser(self, e, fd, sys_args);
        }
    }
    // §9.21 — Syntax 9-16 is not an ordinary argument list: it carries a data
    // SOURCE (arrays, or a file) and a control string, neither of which is a
    // value. `lowerTableModel` rewrites the call into one that is.
    if (std.mem.eql(u8, name, "$table_model")) return lower_table_model.lowerTableModel(self, e);
    // §9.5.4.2 `$sscanf` writes through its arguments, which a `call` cannot do
    // — `lowerScan` turns the one source call into the assignments it means.
    if (std.mem.eql(u8, name, "$sscanf"))
        return .{ .v = try lower_event.lowerScan(self, ex.mainTok(e), sys_args), .ty = .integer };
    // §9.5.4/§9.5.7 the same, for the three §9.5 calls with a destination
    // argument. Both halves are integer-valued (§9.5.4.1's character count,
    // §9.5.4.2's item count, §9.5.7's errno).
    if (try lower_event.lowerFileRead(self, ex.mainTok(e), name, sys_args)) |v|
        return .{ .v = v, .ty = .integer };
    // §9.5.3 the two writers are TASKS: their whole content is the assignment to
    // the string variable, and in expression position there is nothing to assign.
    if (std.mem.eql(u8, name, "$swrite") or std.mem.eql(u8, name, "$sformat")) {
        try self.err(self.file.exprs.mainTok(e), .E0813, "`{s}` is a task and has no value; call it as a statement", .{name});
        return poison;
    }
    // Engine extension (no LRM basis): `$prev(e)` — e at the last ACCEPTED
    // solve, via the same `path_prev` latch §5.6.1.2's reactive lowering
    // already plants on ddt operands (pb__k staged by updateState, advanced
    // only by stateCtl(.commit); before the first commit the latch reads its
    // 0.0 default). Exists so a model can spell SPICE's Meyer capacitance
    // averaging `(C + C_prev)/2` — plain Verilog-A has no accepted-step
    // memory. $prev of a value with no unknown dependence is the value
    // itself: a past constant IS the constant, so param-only uses emit
    // byte-identical code (same rule as `coeffIsConst`).
    if (std.mem.eql(u8, name, "$prev")) {
        const args = ex.args(e);
        if (args.len != 1 or args[0] == .none) {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0809);
            b.msg("`$prev` takes exactly 1 argument, got {d}", .{args.len});
            try b.emit();
            return poison;
        }
        const v = try self.toReal(try lower_expr.lowerExpr(self, args[0]));
        return .{
            .v = if (lower_contrib.coeffIsConst(self, v)) v else try self.emit(.path_prev, &.{v}),
            .ty = .real,
        };
    }
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (sys_args) |a| {
        if (a == .none) continue;
        try vals.append(self.arena, (try lowerSysArg(self, a, takesNetRef(name))).v);
    }
    const v = try self.call(name, vals.items);
    // §9.5 the remaining descriptor functions ($fopen, $ftell, $fseek, $rewind,
    // $feof): ordinary values, but each one moves or creates state the NEXT call
    // observes, so it is sequenced into the I/O phase like the tasks.
    if (lower_event.isFileFunc(name)) try lower_event.sequenceFileCall(self, ex.mainTok(e), name, v);
    return .{ .v = v, .ty = sysFuncTy(name) };
}

/// A string literal argument, for the ch9 functions whose behaviour depends on
/// one. Null when the argument is any other expression.
pub fn constStrArg(self: *Lower, e: Ast.ExprId) ?[]const u8 {
    if (e == .none) return null;
    const c = lower_constfold.constEval(self, e) orelse return null;
    return switch (c) {
        .str => |s| s,
        else => null,
    };
}

/// The ch9 names whose argument IS a net or port reference — §9.19
/// `$port_connected`, §9.20 `$analog_node_alias`/`$analog_port_alias`. The
/// §9.22/§9.23 driver access family takes net references too, but
/// `isConnectModuleOnlySysFunc` refuses those calls before an argument is ever
/// lowered, so listing them here would gate a path they cannot reach.
pub fn takesNetRef(name: []const u8) bool {
    const fns = [_][]const u8{ "$port_connected", "$analog_node_alias", "$analog_port_alias" };
    for (fns) |f| if (std.mem.eql(u8, name, f)) return true;
    return false;
}

/// Direct output literals retain their lexical bytes (§9.4.2), unlike a
/// literal converted to string storage (§3.3). Reuse the lexer decoder only
/// when the AST node still points to a genuine quoted source token; synthesized
/// constants and identifier operands keep their existing conversion semantics.
pub fn outputLiteral(self: *Lower, e: Ast.ExprId) Oom!?[]const u8 {
    if (e == .none or self.file.exprs.tag(e) != .str_literal) return null;
    const span = self.tokenSpan(self.file.exprs.mainTok(e));
    const raw = self.src[span.start..span.end];
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"' or
        std.mem.indexOfScalar(u8, raw, '\\') == null) return null;
    return try Lexer.stringContents(self.arena, raw);
}

pub fn lowerFormatArg(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (try outputLiteral(self, e)) |bytes|
        return .{ .v = try self.mir.addStrConst(self.arena, bytes), .ty = .string };
    return lower_expr.lowerExpr(self, e);
}

pub fn lowerTaskArg(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!TypedValue {
    if (lower_event.isDisplayTask(name) or lower_event.isFileOutTask(name)) return lowerFormatArg(self, e);
    return lowerSysArg(self, e, takesNetRef(name));
}

/// A system call argument. For the `takesNetRef` names a bare net name lowers
/// to its node_order index, which is what codegen needs. For every OTHER task
/// the index is meaningless — `$strobe("%g", p)` printed p's INDEX — so the
/// path is gated by the caller (`net_ok`) and a net name elsewhere falls
/// through to `lowerExpr`, where §4.4's "a net is not a value" E0315 says to
/// probe it.
pub fn lowerSysArg(self: *Lower, e: Ast.ExprId, net_ok: bool) Oom!TypedValue {
    const ex = &self.file.exprs;
    if (net_ok and ex.tag(e) == .ident) {
        const name = self.file.str(ex.strOf(e));
        const is_value = self.vars.contains(name) or self.param_index.contains(name) or
            self.consts.contains(name);
        if (!is_value) {
            if (self.node_voltages.get(name)) |idx|
                return .{ .v = try self.mir.addIntConst(self.arena, idx), .ty = .integer };
        }
    }
    return lower_expr.lowerExpr(self, e);
}

/// §9.15 Table 9-27 — the simulation parameters THIS engine knows, and their
/// values. Null is the clause's "param_name is not known", which decides both
/// halves of the rule: with a fallback the fallback is returned, without one it
/// is an error (E0811, raised in `lowerSysCall`).
///
/// The table is here rather than in codegen — where the values are rendered —
/// because §9.15 states the error as a property of the CALL, and the two answers
/// have to come from one list or a name could be diagnosed as unknown and then
/// answered anyway. codegen calls this.
///
/// The list is short on purpose. Table 9-27 is prefaced "simulators shall accept
/// the strings in Table 9-27 ... IF THEY SUPPORT THE PARAMETER", so a row VerA
/// cannot answer honestly is better left unknown than answered with an invented
/// number: "gdev" is a property of a solver run this compiler does not host,
/// and "simulatorVersion" is required to increase monotonically across
/// releases, which a constant cannot do. The rows that ARE a property of the
/// run and that the device can answer from its own state are in
/// `simparamIsRuntime` instead — a constant is the wrong answer for those, not
/// a missing one.
pub fn simparamValue(self: *const Lower, name: []const u8) ?f64 {
    const eq = std.mem.eql;
    // The two rows that come out of the SOURCE. Unknown when no `timescale was
    // given, which is exactly what "as specified in `timescale" means.
    if (eq(u8, name, "timeUnit")) return if (self.directives.timescale()) |t| t.unit else null;
    if (eq(u8, name, "timePrecision")) return if (self.directives.timescale()) |t| t.precision else null;
    if (eq(u8, name, "gmin")) return 1e-12;
    // Table 9-27 gives `tnom` in DEGREES CELSIUS ("Default value of temperature
    // at which model parameters were extracted"), so the conforming default is
    // 27, not the 300.15 it once answered — the right temperature in the wrong
    // unit, which a model forming `$vt($simparam("tnom") + 273.15)` then read as
    // 300 K too hot.
    //
    // 27 is the DECLARED default only. `tnom` is also in `simparamHostField`,
    // so codegen renders the READ from the host's Model field and uses this
    // number for exactly one thing: the field initializer, i.e. what `Model{}`
    // means to a host that never writes the field (`paramDefault`).
    if (eq(u8, name, "tnom")) return 27.0;
    // Three unit-valued homotopy/geometry factors: a device compiled here is
    // never being stepped or shrunk, so 1.0 is the true answer, not a stand-in.
    if (eq(u8, name, "scale") or eq(u8, name, "shrink") or eq(u8, name, "sourceScaleFactor")) return 1.0;
    return null;
}

/// §9.15 runtime simulation parameters. The host advances this counter once
/// per evaluated Newton iteration via `advanceIteration`; accepted-step
/// updates do not change it. Unknown vendor names use the standard fallback.
pub fn simparamIsRuntime(name: []const u8) bool {
    return std.mem.eql(u8, name, "iteration");
}

/// §9.15 the simulation parameters whose value is the HOST's, published into a
/// reserved `Model` field the host writes before `derive()`. Returns the field
/// name, or null for a name that is a compile-time constant here.
///
///   tnom — Table 9-27, degrees Celsius. SPICE's `.options tnom` (ngspice
///          `CKTnomTemp`, default 27), which is the temperature a model card
///          that gives no `TNOM`/`TREF` of its own was extracted at. A
///          Verilog-A module cannot read it any other way: `$temperature` is
///          the OPERATING temperature and a `parameter` default is the
///          module's own text. Folding it to 27 made every `.options tnom`
///          in a deck a silent no-op, because a compact model derives its
///          whole parameter set from the nominal temperature.
///
/// The `__` suffix is VerA's namespace and cannot collide: `naming.sanitize`
/// escapes a trailing `_` and a `__` run (`Z5f`), so no Verilog-A identifier
/// reaches a field name of this shape. Same rule as `<p>__given`.
pub fn simparamHostField(name: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, name, "tnom")) "nom_temp__" else null;
}

/// ch9 return types. Everything not listed is real (§9.14/§9.15 dominate).
///
/// `pub` for one consumer: analysis.zig's "sysFuncTy and callTy agree" test.
/// The two type the same call from opposite sides of the MIR and their comments
/// have said MUST AGREE since both were written; the test is what turns that
/// into something a build can fail on.
pub fn sysFuncTy(name: []const u8) Ty {
    // Data: fixed system-call names -> MIR type, one lookup per lowered call.
    // The keys and enum values are static; no instance storage or allocation.
    // Calls are independent, but this cold lookup needs no lane kernel.
    const types = std.StaticStringMap(Ty).initComptime(.{
        .{ "$param_given", .integer },
        .{ "$port_connected", .integer },
        .{ "$test$plusargs", .integer },
        .{ "$value$plusargs", .integer },
        .{ "$rtoi", .integer },
        .{ "$clog2", .integer },
        .{ "$realtobits", .integer },
        .{ "$analog_node_alias", .integer },
        .{ "$analog_port_alias", .integer },
        .{ "$sscanf", .integer },
        .{ "$sscanf$int", .integer },
        .{ "$display$width", .integer },
        .{ "$idx$int", .integer },
        .{ "$fopen", .integer },
        .{ "$fgets", .integer },
        .{ "$fscanf", .integer },
        .{ "$fscanf$int", .integer },
        .{ "$ftell", .integer },
        .{ "$fseek", .integer },
        .{ "$rewind", .integer },
        .{ "$ferror", .integer },
        .{ "$feof", .integer },
        .{ "$simparam$str", .string },
        .{ "$sformat", .string },
        .{ "$sscanf$str", .string },
        .{ "$idx$str", .string },
        .{ "$fgets$str", .string },
        .{ "$fscanf$str", .string },
        .{ "$ferror$str", .string },
    });
    return types.get(name) orelse .real;
}
