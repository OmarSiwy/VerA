//! The model's and the routines' unit tests: a design compiled with
//! `vera.compileSource` (or the digital `run.Harness`), opened, and its rows
//! and failure paths checked. The ABI, the header's constants and C object
//! lifetimes are `zig build test-vpi` (tests/fixtures/ch11_vpi/vpi_app.c against
//! src/vpi/vpi_user.h).

const std = @import("std");
const Ast = @import("frontend").Ast;
const Elaborate = @import("ir").Elaborate;
const callback = @import("callback.zig");
const code = @import("code.zig");
const delays = @import("delays.zig");
const handle = @import("handle.zig");
const iterate = @import("iterate.zig");
const property = @import("property.zig");
const root = @import("root.zig");
const run = @import("run.zig");
const value = @import("value.zig");

const ErrorInfo = root.ErrorInfo;
const Obj = root.Obj;
const Scope = root.Scope;
const StartupFn = root.StartupFn;
const asObj = root.asObj;
const close = root.close;
const open = root.open;
const runStartupTable = root.runStartupTable;
const vpiArray = root.vpiArray;
const vpiBranch = root.vpiBranch;
const vpiCell = root.vpiCell;
const vpiConfig = root.vpiConfig;
const vpiConstType = root.vpiConstType;
const vpiConstant = root.vpiConstant;
const vpiDefName = root.vpiDefName;
const vpiDirection = root.vpiDirection;
const vpiDiscipline = root.vpiDiscipline;
const vpiError = root.vpiError;
const vpiFlow = root.vpiFlow;
const vpiFullName = root.vpiFullName;
const vpiHandle = root.vpiHandle;
const vpiIndex = root.vpiIndex;
const vpiInout = root.vpiInout;
const vpiIntConst = root.vpiIntConst;
const vpiIntegerVar = root.vpiIntegerVar;
const vpiIsMemory = root.vpiIsMemory;
const vpiIterator = root.vpiIterator;
const vpiLibrary = root.vpiLibrary;
const vpiLocalParam = root.vpiLocalParam;
const vpiMemory = root.vpiMemory;
const vpiMemoryWord = root.vpiMemoryWord;
const vpiModule = root.vpiModule;
const vpiModuleArray = root.vpiModuleArray;
const vpiName = root.vpiName;
const vpiNature = root.vpiNature;
const vpiNegNode = root.vpiNegNode;
const vpiNet = root.vpiNet;
const vpiNode = root.vpiNode;
const vpiPLI = root.vpiPLI;
const vpiParameter = root.vpiParameter;
const vpiParent = root.vpiParent;
const vpiPort = root.vpiPort;
const vpiPortIndex = root.vpiPortIndex;
const vpiPosNode = root.vpiPosNode;
const vpiPotential = root.vpiPotential;
const vpiQuantity = root.vpiQuantity;
const vpiRealConst = root.vpiRealConst;
const vpiRealVar = root.vpiRealVar;
const vpiReg = root.vpiReg;
const vpiRegArray = root.vpiRegArray;
const vpiScalar = root.vpiScalar;
const vpiScope = root.vpiScope;
const vpiSize = root.vpiSize;
const vpiTopModule = root.vpiTopModule;
const vpiType = root.vpiType;
const vpiUndefined = root.vpiUndefined;
const vpiVarSelect = root.vpiVarSelect;
const vpiVector = root.vpiVector;
const vpi_chk_error = root.vpi_chk_error;
const vpi_compare_objects = root.vpi_compare_objects;
const vpi_free_object = root.vpi_free_object;
const vpi_get = property.vpi_get;
const vpi_get_str = property.vpi_get_str;
const vpi_handle = handle.vpi_handle;
const vpi_handle_by_index = handle.vpi_handle_by_index;
const vpi_handle_by_name = handle.vpi_handle_by_name;
const vpi_iterate = iterate.vpi_iterate;
const vpi_release_handle = root.vpi_release_handle;
const vpi_scan = iterate.vpi_scan;

const vera = @import("vera");

/// A three-deep design with something of every answered class at every level.
const nested_src =
    \\module top(p, n);
    \\  inout p, n; electrical p, n;
    \\  parameter real g = 2.0;
    \\  localparam integer tag = 7;
    \\  electrical mid;
    \\  reg [3:0] state;
    \\  sub u(p, n);
    \\  analog I(p,n) <+ g*V(p,n);
    \\endmodule
    \\module sub(a, b);
    \\  inout a, b; electrical a, b;
    \\  parameter real k = 1.0;
    \\  electrical inner;
    \\  reg flag;
    \\  leaf v(a, b);
    \\  analog I(a,b) <+ k*V(a,b);
    \\endmodule
    \\module leaf(x, y);
    \\  inout x, y; electrical x, y;
    \\  parameter real r = 3.0;
    \\  electrical deep;
    \\  analog I(x,y) <+ r*V(x,y);
    \\endmodule
;

fn openSource(src: []const u8) !vera.CompileResult {
    var res = try vera.compileSource(std.testing.allocator, src, .lint);
    errdefer res.deinit();
    try open(std.testing.allocator, res.lowered);
    return res;
}

test "the scope tree is the instance tree, with definition names" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const d = &root.design.?;
    try std.testing.expectEqual(@as(usize, 3), d.scopes.len);
    try std.testing.expectEqualStrings("top", d.objects[0].full);
    try std.testing.expectEqualStrings("top.u", d.objects[1].full);
    try std.testing.expectEqualStrings("top.u.v", d.objects[2].full);
    // §11.6.1 vpiDefName — the fact flattening erases.
    try std.testing.expectEqualStrings("top", d.scopes[0].def_name);
    try std.testing.expectEqualStrings("sub", d.scopes[1].def_name);
    try std.testing.expectEqualStrings("leaf", d.scopes[2].def_name);
}

test "each scope holds the declarations of its own level" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const d = &root.design.?;
    // §11.6.4: ports come from the definition, so a child instance has them
    // even though the flatten collapsed them into the parent's nets.
    try std.testing.expectEqual(@as(usize, 2), d.scopes[0].ports.len);
    try std.testing.expectEqual(@as(usize, 2), d.scopes[1].ports.len);
    try std.testing.expectEqualStrings("top.u.v.x", d.objects[d.scopes[2].ports[0]].full);
    // §11.6.8/§11.6.9/§11.6.12: one each per level, bucketed by §6.7 path.
    try std.testing.expectEqualStrings("top.mid", d.objects[d.scopes[0].nets[0]].full);
    try std.testing.expectEqualStrings("top.u.inner", d.objects[d.scopes[1].nets[0]].full);
    try std.testing.expectEqualStrings("top.u.v.deep", d.objects[d.scopes[2].nets[0]].full);
    try std.testing.expectEqualStrings("top.state", d.objects[d.scopes[0].regs[0]].full);
    try std.testing.expectEqualStrings("top.u.flag", d.objects[d.scopes[1].regs[0]].full);
    try std.testing.expectEqualStrings("top.u.v.r", d.objects[d.scopes[2].params[0]].full);
}

test "vpi_iterate walks a level and vpi_scan frees the iterator at the end" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("top", null);
    try std.testing.expect(top != null);
    const itr = vpi_iterate(vpiNet, top);
    try std.testing.expect(itr != null);
    try std.testing.expectEqual(vpiIterator, vpi_get(vpiType, itr));
    const first = vpi_scan(itr);
    try std.testing.expectEqualStrings("mid", std.mem.span(vpi_get_str(vpiName, first)));
    try std.testing.expect(vpi_scan(itr) == null);
    // §12.4/§12.35: exhaustion freed it, so the handle is now invalid rather
    // than merely spent.
    try std.testing.expect(vpi_scan(itr) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "an abandoned iterator is freed by vpi_free_object" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("top", null);
    const itr = vpi_iterate(vpiParameter, top);
    _ = vpi_scan(itr);
    try std.testing.expectEqual(@as(usize, 1), root.design.?.iters.count());
    try std.testing.expectEqual(@as(c_int, 1), vpi_free_object(itr));
    try std.testing.expectEqual(@as(usize, 0), root.design.?.iters.count());
}

test "the §6.7 upward scope search, and absolute names" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const leaf = vpi_handle_by_name("top.u.v", null);
    try std.testing.expect(leaf != null);
    // Its own declaration.
    try std.testing.expect(vpi_handle_by_name("deep", leaf) != null);
    // One its grandparent declares — found by walking up.
    const mid = vpi_handle_by_name("mid", leaf);
    try std.testing.expect(mid != null);
    try std.testing.expectEqualStrings("top.mid", std.mem.span(vpi_get_str(vpiFullName, mid)));
    // §12.3: two handles to one object are the same object.
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(mid, vpi_handle_by_name("top.mid", null)));
    try std.testing.expectEqual(@as(c_int, 0), vpi_compare_objects(mid, leaf));
    // §11.6.4's edge back to the module, from both tags.
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(
        vpi_handle(vpiScope, mid),
        vpi_handle(vpiModule, mid),
    ));
}

test "an invalid handle is an error, not a crash" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    // A pointer into the object array but off an element boundary, and one past
    // its end: the two shapes a stale or corrupted handle takes.
    const base = @intFromPtr(root.design.?.objects.ptr);
    const misaligned: vpiHandle = @ptrFromInt(base + 1);
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiType, misaligned));
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    const past: vpiHandle = @ptrFromInt(base + root.design.?.objects.len * @sizeOf(Obj));
    try std.testing.expect(vpi_get_str(vpiName, past) == null);
    try std.testing.expect(vpi_iterate(vpiNet, past) == null);
    try std.testing.expect(vpi_handle(vpiScope, past) == null);
    try std.testing.expect(vpi_handle_by_index(past, 0) == null);
    try std.testing.expect(vpi_handle_by_name("mid", past) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_free_object(past));
    // NULL is a handle too, and §12.5's NULL case is not one VerA answers.
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiType, null));
}

test "unsupported property requests report vpiError and vpiUndefined" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("top", null);
    const net = vpi_handle_by_name("top.mid", null);
    // §11.6.8 gives a net no direction and §11.6.1 gives a module no size.
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiDirection, net));
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiSize, top));
    try std.testing.expect(vpi_get_str(vpiDefName, net) == null);
    // A property VerA does not answer at all (vpiFile, §11.6.1's location).
    try std.testing.expectEqual(vpiUndefined, vpi_get(5, top));
    // And a successful call clears the status again (§12.2).
    try std.testing.expectEqual(vpiModule, vpi_get(vpiType, top));
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
}

test "§11.6.5–§11.6.7: nodes, a branch between them, and its two quantities" {
    var res = try openSource(
        \\module br(p, n);
        \\  inout p, n; electrical p, n;
        \\  electrical mid;
        \\  branch (p, mid) b;
        \\  analog I(b) <+ V(b);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("br", null);
    const mid = vpi_handle(vpiNode, vpi_handle_by_name("br.mid", null));
    try std.testing.expectEqual(vpiNode, vpi_get(vpiType, mid));
    const b = vpi_handle_by_name("br.b", null);
    try std.testing.expectEqual(vpiBranch, vpi_get(vpiType, b));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiNegNode, b), mid));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(
        vpi_handle(vpiPosNode, b),
        vpi_handle(vpiNode, vpi_handle_by_name("br.p", null)),
    ));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiModule, b), top));
    const q = vpi_handle(vpiFlow, b);
    try std.testing.expectEqual(vpiQuantity, vpi_get(vpiType, q));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiBranch, q), b));
    // Annex D's electrical: flow nature Current, potential nature Voltage.
    try std.testing.expectEqualStrings("Current", std.mem.span(vpi_get_str(vpiName, vpi_handle(vpiNature, q))));
    try std.testing.expectEqualStrings("Voltage", std.mem.span(vpi_get_str(vpiName, vpi_handle(vpiNature, vpi_handle(vpiPotential, b)))));
    try std.testing.expectEqualStrings("electrical", std.mem.span(vpi_get_str(vpiName, vpi_handle(vpiDiscipline, b))));
    // A quantity has no name, and a node draws no branch edge.
    try std.testing.expect(vpi_get_str(vpiName, q) == null);
    try std.testing.expect(vpi_handle(vpiPosNode, mid) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "§5.4.2/§11.6.6: an instance's `<+` declares an unnamed branch the instance iterates" {
    var res = try openSource(
        \\`include "disciplines.vams"
        \\module vsrc(p, n); inout p, n; electrical p, n;
        \\  analog V(p, n) <+ 1.25;
        \\endmodule
        \\module res(p, n); inout p, n; electrical p, n;
        \\  analog I(p, n) <+ V(p, n) / 500.0;
        \\endmodule
        \\module top; electrical a, gnd; ground gnd;
        \\  vsrc v1(.p(a), .n(gnd));
        \\  res r1(.p(a), .n(gnd));
        \\  res r2(.p(a), .n(gnd));
        \\endmodule
    );
    defer res.deinit();
    defer close();
    // One unnamed branch per instance, each in ITS scope, though all three
    // span the same pair (a, gnd).
    for ([_][]const u8{ "top.v1", "top.r1", "top.r2" }) |inst| {
        const it = vpi_iterate(vpiBranch, vpi_handle_by_name(@constCast(inst.ptr), null));
        try std.testing.expect(it != null);
        const b = vpi_scan(it).?;
        try std.testing.expect(vpi_scan(it) == null);
        const o = root.coldOf(asObj(b).?);
        try std.testing.expect(o.pos != null);
        try std.testing.expect(o.neg == null); // gnd is §1.3.1.1's reference
        try std.testing.expectEqual(vpiQuantity, vpi_get(vpiType, vpi_handle(vpiFlow, b)));
    }
    const v1 = root.coldOf(asObj(vpi_scan(vpi_iterate(vpiBranch, vpi_handle_by_name(@constCast("top.v1"), null))).?).?);
    try std.testing.expect(v1.contrib_pot != null and v1.contrib_flow == null);
    // r1 and r2 are two devices in parallel: lowering sums their `<+` into
    // one row, and each branch's flow is its own instance's share of it
    // (`Lowered.contrib_shares`), not the total.
    const r1 = root.coldOf(asObj(vpi_scan(vpi_iterate(vpiBranch, vpi_handle_by_name(@constCast("top.r1"), null))).?).?);
    const r2 = root.coldOf(asObj(vpi_scan(vpi_iterate(vpiBranch, vpi_handle_by_name(@constCast("top.r2"), null))).?).?);
    try std.testing.expect(r1.contrib_flow != null and !r1.flow_unknowable);
    try std.testing.expectEqual(r1.contrib_flow, r2.contrib_flow);
    try std.testing.expect(r1.contrib_share != null and r2.contrib_share != null);
    try std.testing.expect(r1.contrib_share.? != r2.contrib_share.?);
}

test "§5.6.8.2: a named branch another instance contributes to reads its own row" {
    var res = try openSource(
        \\`include "disciplines.vams"
        \\module child(b); inout b; electrical b, x;
        \\  branch (x, b) br;
        \\  analog I(br) <+ V(br) / 1000.0;
        \\endmodule
        \\module top(g); inout g; electrical g;
        \\  child drv(g);
        \\  analog I(drv.br) <+ 1m;
        \\endmodule
    );
    defer res.deinit();
    defer close();
    // The parent's `<+` lands on the child's own branch: one row, `shared`,
    // and all of it is that branch's flow, so there is no share to look up.
    const br = root.coldOf(asObj(vpi_scan(vpi_iterate(vpiBranch, vpi_handle_by_name(@constCast("top.drv"), null))).?).?);
    try std.testing.expect(br.contrib_flow != null and br.contrib_share == null and !br.flow_unknowable);
}

test "§11.6.20/§11.6.21: the analog process, its contribution and an identifier that IS its object" {
    var res = try openSource(
        \\module ct(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real g = 2.0;
        \\  branch (p, n) b;
        \\  analog I(b) <+ g * V(b);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("ct", null);
    const procs = vpi_iterate(code.vpiProcess, top);
    const proc = vpi_scan(procs);
    try std.testing.expect(vpi_scan(procs) == null);
    try std.testing.expectEqual(code.vpiAnalog, vpi_get(vpiType, proc));
    const c = vpi_handle(code.vpiStmt, proc);
    try std.testing.expectEqual(code.vpiContrib, vpi_get(vpiType, c));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiFlow, c));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiBranch, c), vpi_handle_by_name("ct.b", null)));
    const rhs = vpi_handle(code.vpiRhs, c);
    try std.testing.expectEqual(code.vpiMultOp, vpi_get(code.vpiOpType, rhs));
    // §11.6.18: the operand `g` is the parameter object itself.
    const ops = vpi_iterate(code.vpiOperand, rhs);
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_scan(ops), vpi_handle_by_name("ct.g", null)));
    try std.testing.expectEqual(code.vpiAccessFunc, vpi_get(vpiType, vpi_scan(ops)));
    try std.testing.expect(vpi_scan(ops) == null);
}

test "a single-module design is a tree of one" {
    var res = try openSource(
        \\module only(p);
        \\  inout p; electrical p;
        \\  parameter real w = 1.0;
        \\  analog I(p) <+ w*V(p);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("only", null);
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiTopModule, top));
    try std.testing.expect(vpi_handle(vpiScope, top) == null);
    // §12.23: an empty set is NULL with NO error.
    try std.testing.expect(vpi_iterate(vpiReg, top) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    // §11.6.1 NOTE 1, and there is exactly one root.
    const roots = vpi_iterate(vpiModule, null);
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(top, vpi_scan(roots)));
    try std.testing.expect(vpi_scan(roots) == null);
}

test "port, reg and parameter properties come from the declaration" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const p = vpi_handle_by_name("top.p", null);
    try std.testing.expectEqual(vpiInout, vpi_get(vpiDirection, p));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiPortIndex, p));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiScalar, p));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiPortIndex, vpi_handle_by_name("top.n", null)));
    // §11.6.9 — a packed reg is a vector of its declared width.
    const state = vpi_handle_by_name("top.state", null);
    try std.testing.expectEqual(@as(c_int, 4), vpi_get(vpiSize, state));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiVector, state));
    // §3.4.5 as the SOURCE wrote it, not as the flatten rewrote it: `u.k` is a
    // child's `parameter`, which elaboration turned into a `localparam`.
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiLocalParam, vpi_handle_by_name("top.g", null)));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiLocalParam, vpi_handle_by_name("top.tag", null)));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiLocalParam, vpi_handle_by_name("top.u.k", null)));
    try std.testing.expectEqual(vpiRealConst, vpi_get(vpiConstType, vpi_handle_by_name("top.u.k", null)));
    try std.testing.expectEqual(vpiIntConst, vpi_get(vpiConstType, vpi_handle_by_name("top.tag", null)));
}

test "a vector net reports its folded §3.6.3 width" {
    var res = try openSource(
        \\module vec(p);
        \\  inout p; electrical p;
        \\  electrical [0:3] bus;
        \\  analog I(p) <+ V(p);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    const bus = vpi_handle_by_name("vec.bus", null);
    try std.testing.expectEqual(@as(c_int, 4), vpi_get(vpiSize, bus));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiScalar, bus));
}

test "vpi_handle_by_index reports the unsupported class rather than guessing" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const state = vpi_handle_by_name("top.state", null);
    try std.testing.expect(vpi_handle_by_index(state, 0) == null);
    var info: ErrorInfo = undefined;
    try std.testing.expectEqual(vpiError, vpi_chk_error(&info));
    try std.testing.expectEqual(vpiPLI, info.state);
    try std.testing.expectEqualStrings("NOINDEX", std.mem.span(info.code));
    try std.testing.expectEqualStrings("VerA", std.mem.span(info.product));
    // §12.2: vpi_chk_error itself does not reset the status.
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "handles survive the compilation they were built from" {
    // `Design` copies every string it reports, so freeing the CompileResult
    // leaves the handles valid.
    var res = try openSource(nested_src);
    defer close();
    const leaf = vpi_handle_by_name("top.u.v", null);
    res.deinit();
    try std.testing.expectEqualStrings("leaf", std.mem.span(vpi_get_str(vpiDefName, leaf)));
    try std.testing.expectEqualStrings("top.u.v.deep", std.mem.span(
        vpi_get_str(vpiFullName, vpi_handle_by_name("deep", leaf)),
    ));
}

var startup_calls: usize = 0;

fn countStartupCall() callconv(.c) void {
    startup_calls += 1;
}

test "§12.33.2 runs every entry of the table, in order, and stops at the 0" {
    startup_calls = 0;
    // A null table is a no-op: an application that registers nothing at startup
    // is a legal application.
    runStartupTable(null);
    try std.testing.expectEqual(@as(usize, 0), startup_calls);
    // "0 shall be last entry in list" — and an entry AFTER it is not reached,
    // which is what makes the terminator the terminator.
    const table = [_]?StartupFn{ &countStartupCall, &countStartupCall, null, &countStartupCall };
    runStartupTable(&table);
    try std.testing.expectEqual(@as(usize, 2), startup_calls);
}

test "no design open is an error on every routine" {
    close();
    try std.testing.expect(vpi_handle_by_name("top", null) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(vpi_iterate(vpiModule, null) == null);
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiType, null));
    try std.testing.expect(vpi_get_str(vpiName, null) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_compare_objects(null, null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_release_handle(null));
}

// ---- the scope tree is elaboration's, read and not re-derived --------------

/// The `Scope` whose §6.7 path is `path`, or a test failure.
fn scopeAt(path: []const u8) !*const Scope {
    for (root.design.?.scopes) |*s| if (std.mem.eql(u8, s.path, path)) return s;
    std.debug.print("no scope at `{s}`\n", .{path});
    return error.TestExpectedEqual;
}

test "an instance array is one scope per element (§6.2.2, §6.7)" {
    // §6.2.2 `name_of_module_instance ::= module_instance_identifier [ range ]`,
    // and §6.7 addresses each element as `u[1].inner`. Elaboration inlines one
    // unit per element, so the VPI has one module per element.
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  sub u[1:0](p, n);
        \\endmodule
        \\module sub(a, b);
        \\  inout a, b; electrical a, b;
        \\  electrical inner;
        \\  analog I(a,b) <+ V(a,b);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    try std.testing.expectEqual(@as(usize, 3), root.design.?.scopes.len);
    try std.testing.expectEqualStrings("sub", (try scopeAt("u[0]")).def_name);
    try std.testing.expectEqualStrings("sub", (try scopeAt("u[1]")).def_name);
    const net = vpi_handle_by_name("top.u[1].inner", null);
    try std.testing.expect(net != null);
    try std.testing.expectEqual(vpiNet, vpi_get(vpiType, net));
    try std.testing.expect(vpi_handle_by_name("top.u[0].a", null) != null);
}

test "a paramset instance is an instance of the module §6.4.2 selected, through the chain" {
    // §6.4 "A chain of paramsets may be defined, but the last paramset in the
    // chain shall reference a module": `c` names `outer`, which names `mid`,
    // which names `leaf`. §6.4.2 selects between the two `pick`s by the range
    // that admits "PMOS", so `s` is a `pmod` and not the first `pick`'s `nmod`.
    // §12.12's example reads that module back as `vpiDefName`.
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  outer c(p, n);
        \\  pick #(.t("PMOS")) s(p, n);
        \\endmodule
        \\paramset outer mid;
        \\  real tag;
        \\  tag = 1.0;
        \\endparamset
        \\paramset mid leaf;
        \\  parameter real unused_item = 0; // A.1.9: one item declaration at least
        \\  .j = 2.0;
        \\endparamset
        \\paramset pick nmod;
        \\  parameter string t = "NMOS" from '{ "NMOS" };
        \\  .sign = 1.0;
        \\endparamset
        \\paramset pick pmod;
        \\  parameter string t = "PMOS" from '{ "PMOS" };
        \\  .sign = -1.0;
        \\endparamset
        \\module leaf(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real j = 0.0;
        \\  analog I(a,b) <+ j*V(a,b);
        \\endmodule
        \\module nmod(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real sign = 0.0;
        \\  analog I(a,b) <+ sign*V(a,b);
        \\endmodule
        \\module pmod(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real sign = 0.0;
        \\  analog I(a,b) <+ sign*V(a,b);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    try std.testing.expectEqualStrings("leaf", (try scopeAt("c")).def_name);
    try std.testing.expectEqualStrings("pmod", (try scopeAt("s")).def_name);
    try std.testing.expect(vpi_handle_by_name("top.c.j", null) != null);
}

test "an instance resolved by Annex E.2.1's case-insensitive netlist match has its scope" {
    // E.2.1 "if no exact match is found, the mixed-case name shall match the
    // same name defined within SPICE regardless of the case". That rule is
    // about which MODULE an instance names, and elaboration owns it.
    //
    // It is NOT a rule about `vpi_handle_by_name`: §12.21 searches "using the
    // scope search rules defined by the Verilog-AMS HDL", and §2.7 makes those
    // case-sensitive. So `TOP.Q` still finds nothing.
    var res = try vera.compileSourceOpts(std.testing.allocator,
        \\module top(c, b, e);
        \\  inout c, b, e; electrical c, b, e;
        \\  VeRtNpN q(c, b, e);
        \\endmodule
    , .lint, .{ .spice_netlist = ".MODEL VERTNPN NPN BF=80 IS=1E-18\n" });
    defer res.deinit();
    try open(std.testing.allocator, res.lowered);
    defer close();

    const q = try scopeAt("q");
    try std.testing.expect(std.ascii.eqlIgnoreCase("vertnpn", q.def_name));
    // The card synthesizes `module vertnpn(c, b, e, s)`: its ports are
    // the definition's, so the scope has all four.
    try std.testing.expectEqual(@as(usize, 4), q.ports.len);
    try std.testing.expect(vpi_handle_by_name("top.q", null) != null);
    try std.testing.expect(vpi_handle_by_name("TOP.Q", null) == null);
}

test "the scopes are elaboration's units, one for one" {
    // One owner per fact: `Elaborate.Design.units` is the instance tree the
    // flatten built. Every unit is a scope with its path and module, in the
    // same depth-first source order, and there is no other scope.
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  sub u[0:1](p, n);
        \\  ps w(p, n);
        \\endmodule
        \\paramset ps sub;
        \\  parameter real unused_item = 0; // A.1.9: one item declaration at least
        \\  .k = 2.0;
        \\endparamset
        \\module sub(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real k = 1.0;
        \\  leaf v(a, b);
        \\endmodule
        \\module leaf(x, y);
        \\  inout x, y; electrical x, y;
        \\  analog I(x,y) <+ V(x,y);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    const units = res.lowered.unit_paths;
    try std.testing.expectEqual(@as(usize, 7), units.len);
    try std.testing.expectEqual(units.len, root.design.?.scopes.len);
    for (units, root.design.?.scopes) |u, s| {
        try std.testing.expectEqualStrings(u.module, s.def_name);
        try std.testing.expectEqualStrings(std.mem.trimEnd(u8, u.path, &.{Elaborate.sep}), s.path);
    }
}

// ---- §11.6.10/§11.6.11 arrays and §6.2.2 instance arrays --------------------

test "an instance array is a vpiModuleArray over its members (§6.2.2, IEEE 1364 §26.6.1)" {
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  sub u[1:0](p, n);
        \\endmodule
        \\module sub(a, b);
        \\  inout a, b; electrical a, b;
        \\  analog I(a,b) <+ V(a,b);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("top", null);
    // A module in no array has no index, and that is not an error.
    try std.testing.expect(vpi_handle(vpiIndex, top) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiArray, top));

    const u = vpi_handle_by_name("top.u", null);
    try std.testing.expectEqual(vpiModuleArray, vpi_get(vpiType, u));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, u));
    const itr = vpi_iterate(vpiModule, u);
    var seen: u32 = 0;
    while (vpi_scan(itr)) |m| {
        try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, m));
        try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiModuleArray, m), u));
        var v: callback.Value = std.mem.zeroes(callback.Value);
        v.format = value.vpiIntVal;
        const index = vpi_handle(vpiIndex, m);
        try std.testing.expectEqual(vpiConstant, vpi_get(vpiType, index));
        value.vpi_get_value(index, &v);
        try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
        seen |= @as(u32, 1) << @intCast(v.value.integer);
        try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle_by_index(u, v.value.integer), m));
    }
    try std.testing.expectEqual(@as(u32, 3), seen);
    try std.testing.expect(vpi_handle_by_index(u, 2) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    // Iterating a module's instance arrays.
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_scan(vpi_iterate(vpiModuleArray, top)), u));
}

test "a digital memory is a vpiRegArray of vpiReg words, each bound to its engine slot" {
    var h: run.Harness = undefined;
    try h.init(
        \\module m;
        \\  reg [7:0] mem [0:3];
        \\  integer counts [2:1];
        \\  real samples [1:0];
        \\  initial begin mem[2] = 8'h7e; counts[1] = 5; end
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();

    const top = vpi_handle_by_name("m", null);
    const mem = vpi_scan(vpi_iterate(vpiMemory, top));
    try std.testing.expectEqual(vpiRegArray, vpi_get(vpiType, mem));
    try std.testing.expectEqualStrings("vpiRegArray", std.mem.span(vpi_get_str(vpiType, mem)));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiIsMemory, mem));
    try std.testing.expectEqual(@as(c_int, 4), vpi_get(vpiSize, mem));
    const w2 = vpi_handle_by_index(mem, 2);
    try std.testing.expectEqual(vpiReg, vpi_get(vpiType, w2));
    try std.testing.expectEqual(@as(c_int, 8), vpi_get(vpiSize, w2));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiParent, w2), mem));
    try std.testing.expectEqualStrings("m.mem[2]", std.mem.span(vpi_get_str(vpiFullName, w2)));
    var v: callback.Value = std.mem.zeroes(callback.Value);
    v.format = value.vpiIntVal;
    value.vpi_get_value(w2, &v);
    try std.testing.expectEqual(@as(c_int, 0x7e), v.value.integer);
    // Every word, by the legacy tag.
    var words: u32 = 0;
    const itr = vpi_iterate(vpiMemoryWord, mem);
    while (vpi_scan(itr)) |_| words += 1;
    try std.testing.expectEqual(@as(u32, 4), words);

    // An integer array is an integer variable with vpiArray set, whose
    // elements are variable selects.
    const counts = vpi_handle_by_name("m.counts", null);
    try std.testing.expectEqual(vpiIntegerVar, vpi_get(vpiType, counts));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, counts));
    const c1 = vpi_scan(vpi_iterate(vpiVarSelect, counts));
    try std.testing.expectEqual(vpiVarSelect, vpi_get(vpiType, c1));
    value.vpi_get_value(c1, &v);
    try std.testing.expectEqual(@as(c_int, 5), v.value.integer);

    // A real array is a real variable with vpiArray set (§26.6.7).
    const samples = vpi_handle_by_name("m.samples", null);
    try std.testing.expectEqual(vpiRealVar, vpi_get(vpiType, samples));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, samples));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, samples));
}

test "a digital scope is the engine's instance, past a task frame and a loop generate (§11.2.2)" {
    var h: run.Harness = undefined;
    try h.init(
        \\module leaf #(parameter V = 0); reg [7:0] r; initial r = V; endmodule
        \\module top;
        \\  task t; begin end endtask
        \\  genvar i;
        \\  generate for (i = 0; i < 2; i = i + 1) begin : g
        \\    leaf #(i + 1) u();
        \\  end endgenerate
        \\  leaf #(8'h11) c();
        \\  initial t;
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();

    var v: callback.Value = std.mem.zeroes(callback.Value);
    v.format = value.vpiIntVal;
    for ([_]struct { []const u8, c_int }{ .{ "top.c.r", 0x11 }, .{ "top.g[0].u.r", 1 }, .{ "top.g[1].u.r", 2 } }) |want| {
        const name = try std.testing.allocator.dupeSentinel(u8, want[0], 0);
        defer std.testing.allocator.free(name);
        const r = vpi_handle_by_name(name, null) orelse return error.TestUnexpectedResult;
        value.vpi_get_value(r, &v);
        try std.testing.expectEqual(want[1], v.value.integer);
    }
    const g0 = vpi_handle_by_name("top.g[0].u", null);
    try std.testing.expectEqualStrings("leaf", std.mem.span(vpi_get_str(vpiDefName, g0)));
    // The generate iterations are path components, not scopes: all three
    // instances are children of `top`.
    var children: u32 = 0;
    const itr = vpi_iterate(vpiModule, vpi_handle_by_name("top", null));
    while (vpi_scan(itr)) |_| children += 1;
    try std.testing.expectEqual(@as(u32, 3), children);
}

test "IEEE 1364-2005 §13.6: vpiLibrary, vpiCell and vpiConfig of a configured module" {
    var h: run.Harness = undefined;
    try h.init(
        \\config cfg; design work.top; instance top.u use gate; endconfig
        \\module rtl; endmodule
        \\module gate; endmodule
        \\module top; rtl u(); endmodule
    );
    defer h.deinit();
    try run.simulate();
    const u = vpi_handle_by_name("top.u", null);
    try std.testing.expectEqualStrings("work", std.mem.span(vpi_get_str(vpiLibrary, u)));
    try std.testing.expectEqualStrings("gate", std.mem.span(vpi_get_str(vpiCell, u)));
    try std.testing.expectEqualStrings("work.cfg", std.mem.span(vpi_get_str(vpiConfig, u)));
}

test "an analog real array and real variable are §11.6.10's classes" {
    var res = try openSource(
        \\module ra(p);
        \\  inout p; electrical p;
        \\  real samples[1:0];
        \\  real x;
        \\  analog begin
        \\    samples[0] = V(p); samples[1] = 2*V(p); x = samples[0];
        \\    I(p) <+ x;
        \\  end
        \\endmodule
    );
    defer res.deinit();
    defer close();
    const arr = vpi_handle_by_name("ra.samples", null);
    try std.testing.expectEqual(vpiRealVar, vpi_get(vpiType, arr));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, arr));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, arr));
    const sel = vpi_handle_by_index(arr, 1);
    try std.testing.expectEqual(vpiVarSelect, vpi_get(vpiType, sel));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiParent, sel), arr));
    const x = vpi_handle_by_name("ra.x", null);
    try std.testing.expectEqual(vpiRealVar, vpi_get(vpiType, x));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiArray, x));
}

test "IEEE 1364-2005 §26.6.22/§26.6.23: drivers and loads of nets and regs" {
    var h: run.Harness = undefined;
    try h.init(
        \\module m(i, o);
        \\  input i;
        \\  output o;
        \\  wire w;
        \\  reg r;
        \\  assign w = r & i;
        \\  not (o, w);
        \\endmodule
    );
    defer h.deinit();
    const top = vpi_handle_by_name("m", null);
    // `i` and `o` are implicit nets (§12.3.3); by name they are the ports.
    var nets: [4]vpiHandle = undefined;
    var n: usize = 0;
    const itr = vpi_iterate(vpiNet, top);
    while (vpi_scan(itr)) |x| : (n += 1) nets[n] = x;
    try std.testing.expectEqual(@as(usize, 3), n);
    const Want = struct { name: []const u8, implicit: bool = false, drivers: []const c_int, loads: []const c_int };
    // Each set as its members' types, in object order.
    for ([_]Want{
        .{ .name = "w", .drivers = &.{code.vpiContAssign}, .loads = &.{code.vpiPrimTerm} },
        .{ .name = "i", .implicit = true, .drivers = &.{vpiPort}, .loads = &.{code.vpiContAssign} },
        .{ .name = "o", .implicit = true, .drivers = &.{code.vpiPrimTerm}, .loads = &.{vpiPort} },
        .{ .name = "r", .drivers = &.{}, .loads = &.{code.vpiContAssign} },
    }) |want| {
        const obj = for (nets[0..n]) |x| {
            if (std.mem.eql(u8, std.mem.span(vpi_get_str(vpiName, x)), want.name)) break x;
        } else vpi_handle_by_name("m.r", null);
        if (vpi_get(vpiType, obj) == vpiNet) try std.testing.expectEqual(@as(c_int, @intFromBool(want.implicit)), vpi_get(code.vpiImplicitDecl, obj));
        for ([_]c_int{ code.vpiDriver, code.vpiLoad }, [_][]const c_int{ want.drivers, want.loads }) |tag, types| {
            var got: [4]c_int = undefined;
            var k: usize = 0;
            const it = vpi_iterate(tag, obj);
            try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
            if (it != null) while (vpi_scan(it)) |x| : (k += 1) {
                got[k] = vpi_get(vpiType, x);
            };
            try std.testing.expectEqualSlices(c_int, types, got[0..k]);
        }
    }
}

test "IEEE 1364-2005 §26.6.13 switches, pull sources and strengths; §26.6.6 l local drivers across a port" {
    var h: run.Harness = undefined;
    try h.init(
        \\module m;
        \\  wire w, z;
        \\  reg a, c;
        \\  pullup (w);
        \\  nmos (w, a, c);
        \\  and (strong0, pull1) g1 (z, a, c);
        \\  leaf u(.x(w));
        \\endmodule
        \\module leaf(x);
        \\  input x;
        \\  wire y;
        \\  buf (y, x);
        \\endmodule
    );
    defer h.deinit();
    const top = vpi_handle_by_name("m", null);
    var prims: [3]vpiHandle = undefined;
    var n: usize = 0;
    const itr = vpi_iterate(code.vpiPrimitive, top);
    while (vpi_scan(itr)) |x| : (n += 1) prims[n] = x;
    try std.testing.expectEqual(@as(usize, 3), n);
    // Gates, then pull sources, then switches.
    try std.testing.expectEqualStrings("g1", std.mem.span(vpi_get_str(vpiName, prims[0])));
    try std.testing.expectEqual(@as(c_int, 0x40), vpi_get(code.vpiStrength0, prims[0]));
    try std.testing.expectEqual(@as(c_int, 0x20), vpi_get(code.vpiStrength1, prims[0]));
    try std.testing.expectEqual(code.vpiGate, vpi_get(vpiType, prims[1]));
    try std.testing.expectEqual(code.vpiPullupPrim, vpi_get(code.vpiPrimType, prims[1]));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiSize, prims[1]));
    try std.testing.expectEqual(@as(c_int, 0x20), vpi_get(code.vpiStrength1, prims[1]));
    try std.testing.expectEqual(code.vpiSwitch, vpi_get(vpiType, prims[2]));
    try std.testing.expectEqual(@as(c_int, 13), vpi_get(code.vpiPrimType, prims[2]));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, prims[2]));

    const count = struct {
        fn f(tag: c_int, obj: vpiHandle) usize {
            var k: usize = 0;
            const it = vpi_iterate(tag, obj);
            if (it != null) while (vpi_scan(it)) |_| {
                k += 1;
            };
            return k;
        }
    }.f;
    const w = vpi_handle_by_name("m.w", null);
    // The pullup's and the switch's output terms; the buf in u reads w
    // through the collapsed port, a load of w but not a local one.
    try std.testing.expectEqual(@as(usize, 2), count(code.vpiLocalDriver, w));
    try std.testing.expectEqual(@as(usize, 0), count(code.vpiLocalLoad, w));
    try std.testing.expectEqual(@as(usize, 1), count(code.vpiLoad, w));
    var ux: vpiHandle = null;
    const nets = vpi_iterate(vpiNet, vpi_handle_by_name("m.u", null));
    while (vpi_scan(nets)) |x| if (std.mem.eql(u8, std.mem.span(vpi_get_str(vpiName, x)), "x")) {
        ux = x;
    };
    // Details l: an input port drives its net locally; across the port the
    // pullup and the switch drive it too.
    try std.testing.expectEqual(@as(usize, 1), count(code.vpiLocalDriver, ux));
    try std.testing.expectEqual(@as(usize, 3), count(code.vpiDriver, ux));
}

// ---- root.zig's own pieces --------------------------------------------------

test "OptU32 packs null as none and round-trips every other value" {
    try std.testing.expectEqual(root.OptU32.none, root.OptU32.of(null));
    try std.testing.expectEqual(@as(?u32, null), root.OptU32.none.get());
    for ([_]u32{ 0, 1, 0x7fff_ffff, std.math.maxInt(u32) - 1 }) |v| try std.testing.expectEqual(@as(?u32, v), root.OptU32.of(v).get());
}

test "every declared class has a vpiType with a spelling" {
    for (std.enums.values(root.Kind)) |k| {
        if (k == .code) continue;
        // A variable array's type follows its element type.
        for ([_]Ast.Type{ .integer, .real }) |ty| {
            const o: Obj = .{ .kind = k, .owner = .none, .name = "", .full = "", .ty = ty };
            try std.testing.expect(!std.mem.eql(u8, "vpiUndefined", root.typeName(root.typeOf(&o))));
        }
    }
}

test "§12.2: a message past the 512-byte buffer is cut short and still terminated" {
    close();
    const long: [600]u8 = @splat('m');
    root.fail("LONG", "{s}", .{&long});
    var info: ErrorInfo = undefined;
    try std.testing.expectEqual(vpiError, vpi_chk_error(&info));
    const message = std.mem.span(info.message);
    try std.testing.expectEqual(@as(usize, 511), message.len);
    try std.testing.expect(std.mem.allEqual(u8, message, 'm'));
    try std.testing.expectEqualStrings("LONG", std.mem.span(info.code));
    // The application's call site is reported absent, not invented.
    try std.testing.expect(info.file == null);
    try std.testing.expectEqual(@as(c_int, 0), info.line);
    // vpi_chk_error leaves the status as it found it.
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

var probe_starting = false;
var probe_get: c_int = 0;
var probe_refused = false;
var probe_timed: vpiHandle = null;
var probe_compile: vpiHandle = null;

fn noteNothing(_: *callback.CbData) callconv(.c) c_int {
    return 0;
}

fn probeStartup() callconv(.c) void {
    probe_starting = root.starting;
    probe_get = vpi_get(vpiType, null);
    var info: ErrorInfo = undefined;
    _ = vpi_chk_error(&info);
    probe_refused = info.code != null and std.mem.eql(u8, std.mem.span(info.code), "STARTUP");
    var t: callback.Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 1, .real = 0 };
    const timed: callback.CbData = .{ .reason = callback.cbAfterDelay, .cb_rtn = noteNothing, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    probe_timed = callback.vpi_register_cb(&timed);
    const compiled: callback.CbData = .{ .reason = callback.cbEndOfCompile, .cb_rtn = noteNothing, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    probe_compile = callback.vpi_register_cb(&compiled);
}

test "IEEE 1364-2005 §26.2.4: during startup only the registrations answer" {
    close();
    defer close();
    const table = [_]?StartupFn{ &probeStartup, null };
    runStartupTable(&table);
    try std.testing.expect(probe_starting);
    try std.testing.expect(!root.starting);
    try std.testing.expectEqual(vpiUndefined, probe_get);
    try std.testing.expect(probe_refused);
    // A time callback waits for the run; an end-of-compile one is legal now.
    try std.testing.expect(probe_timed == null);
    try std.testing.expect(probe_compile != null);
}

test "§12.17 vpi_get_vlog_info: the host's invocation and the product" {
    var argv0 = "vera".*;
    var argv = [_][*c]u8{&argv0};
    root.setInvocation(1, &argv);
    defer root.setInvocation(0, null);
    var info: root.VlogInfo = undefined;
    try std.testing.expectEqual(@as(c_int, 1), root.vpi_get_vlog_info(&info));
    try std.testing.expectEqual(@as(c_int, 1), info.argc);
    try std.testing.expectEqualStrings("vera", std.mem.span(info.argv[0]));
    try std.testing.expectEqualStrings("VerA", std.mem.span(info.product));
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_get_vlog_info(null));
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "a pointer one row below the object array is no handle" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();
    const base = @intFromPtr(root.design.?.objects.ptr);
    try std.testing.expect(asObj(@ptrFromInt(base - @sizeOf(Obj))) == null);
    try std.testing.expect(root.issued(@ptrFromInt(base - @sizeOf(Obj))) == null);
    const first = asObj(@ptrFromInt(base)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first == &root.design.?.objects[0]);
}

test "§12.19-§12.21, IEEE 1364-2005 §27.18 and §26.6.43: the lookup routines' refusals" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();
    const top = vpi_handle_by_name("top", null);
    // §12.21: a NULL name; a name absent from the design and from a scope.
    try std.testing.expect(vpi_handle_by_name(null, null) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(vpi_handle_by_name("top.nothing", null) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(vpi_handle_by_name("nothing", top) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    // §27.18: a NULL index array, and two indices on a class that takes one.
    const indices = [_]c_int{ 0, 1 };
    try std.testing.expect(handle.vpi_handle_by_multi_index(top, 1, null) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(handle.vpi_handle_by_multi_index(top, 2, &indices) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    // §26.6.43: an iterator's one edge is vpiUse, the reference it was made
    // from; any other is no relationship.
    const itr = vpi_iterate(vpiNet, top);
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(root.vpiUse, itr), top));
    try std.testing.expect(vpi_handle(vpiScope, itr) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 1), vpi_free_object(itr));
    // A relationship a net's diagram does not draw.
    try std.testing.expect(vpi_handle(vpiPosNode, vpi_handle_by_name("top.mid", null)) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "IEEE 1364-2005 §26.6.34: a forever loop is a vpiForever, and spells its type" {
    var h: run.Harness = undefined;
    try h.init(
        \\module f;
        \\  reg r;
        \\  initial forever #5 r = ~r;
        \\endmodule
    );
    defer h.deinit();
    const procs = vpi_iterate(code.vpiProcess, vpi_handle_by_name("f", null));
    const init = vpi_scan(procs);
    _ = vpi_free_object(procs);
    const loop = vpi_handle(code.vpiStmt, init);
    try std.testing.expectEqual(code.vpiForever, vpi_get(vpiType, loop));
    try std.testing.expectEqualStrings("vpiForever", std.mem.span(vpi_get_str(vpiType, loop)));
}

test "§12.11: a continuous assignment's delays, derived where not written, and the counts refused" {
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module d;
        \\  reg a;
        \\  wire w;
        \\  assign #(2, 7) w = a;
        \\endmodule
    );
    defer h.deinit();
    const assigns = vpi_iterate(code.vpiContAssign, vpi_handle_by_name("d", null));
    const ca = vpi_scan(assigns) orelse return error.TestUnexpectedResult;
    _ = vpi_free_object(assigns);
    var da: [3]callback.Time = undefined;
    var dl: delays.Delay = .{ .da = &da, .no_of_delays = 3, .time_type = callback.vpiScaledRealTime, .mtm_flag = 0, .append_flag = 0, .pulsere_flag = 0 };
    delays.vpi_get_delays(ca, &dl);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    // Rise and fall as written; turn-off is IEEE 1364 §7.14's min(rise, fall).
    for (da, [_]f64{ 2, 7, 2 }) |t, want| try std.testing.expectEqual(want, t.real);
    for ([_]c_int{ 0, 4 }) |n| {
        dl.no_of_delays = n;
        delays.vpi_get_delays(ca, &dl);
        try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    }
}

test "§12.29: vpi_put_delays reaches the engine driver of a gate in a generated instance" {
    // The instance's model scope (1) is not its engine scope: the loop
    // iteration `b[0]` is an engine scope of its own between it and `top`.
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module leaf; reg a; wire y; buf g(y, a); endmodule
        \\module top;
        \\  genvar i;
        \\  generate for (i = 0; i < 1; i = i + 1) begin : b
        \\    leaf u();
        \\  end endgenerate
        \\endmodule
    );
    defer h.deinit();
    const g = vpi_handle_by_name("top.b[0].u.g", null) orelse return error.TestUnexpectedResult;
    var da = [2]callback.Time{
        .{ .type = callback.vpiSimTime, .high = 0, .low = 3, .real = 0 },
        .{ .type = callback.vpiSimTime, .high = 0, .low = 4, .real = 0 },
    };
    var dl: delays.Delay = .{ .da = &da, .no_of_delays = 2, .time_type = callback.vpiSimTime, .mtm_flag = 0, .append_flag = 0, .pulsere_flag = 0 };
    delays.vpi_put_delays(g, &dl);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    // The one driver the gate became: rise 3, fall 4, turn-off min(3, 4).
    const tok = (asObj(g) orelse return error.TestUnexpectedResult).src_tok;
    var hits: usize = 0;
    for (h.run.drivers) |drv| {
        if (drv.tok != tok) continue;
        hits += 1;
        try std.testing.expect(drv.delay.present);
        try std.testing.expectEqual(@as(u64, 3), drv.delay.rise);
        try std.testing.expectEqual(@as(u64, 4), drv.delay.fall);
        try std.testing.expectEqual(@as(u64, 3), drv.delay.off);
    }
    try std.testing.expectEqual(@as(usize, 1), hits);
}

test "§12.30/IEEE 1364 §19.8: a scaled time is in the unit of the object's own module, past a generate" {
    // `leaf` is in microseconds, `top` in nanoseconds, and the tick is the
    // finest precision, 1 ns. `u`'s model scope (1) is the engine's loop
    // iteration `b[0]`, a scope of `top`'s, so only the engine scope finds
    // `leaf`'s unit: 2 us is 2000 ticks, where `top`'s unit would make it 2.
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1us/1ns
        \\module leaf; reg a; endmodule
        \\`timescale 1ns/1ns
        \\module top;
        \\  genvar i;
        \\  generate for (i = 0; i < 1; i = i + 1) begin : b
        \\    leaf u();
        \\  end endgenerate
        \\endmodule
    );
    defer h.deinit();
    const a = vpi_handle_by_name("top.b[0].u.a", null) orelse return error.TestUnexpectedResult;
    const two: callback.Time = .{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = 2 };
    try std.testing.expectEqual(@as(?u64, 2000), run.ticksOf(two, a));
}

/// The message of the error the previous call recorded; "" for none.
fn lastMessage() []const u8 {
    var info: ErrorInfo = undefined;
    if (vpi_chk_error(&info) == 0) return "";
    return std.mem.span(info.message);
}

/// The port of instance `inst` named `name`, or null.
fn portNamed(inst: vpiHandle, name: []const u8) vpiHandle {
    const itr = vpi_iterate(vpiPort, inst);
    var found: vpiHandle = null;
    while (vpi_scan(itr)) |p| {
        if (found == null and std.mem.eql(u8, std.mem.span(vpi_get_str(vpiName, p)), name)) found = p;
    }
    return found;
}

test "IEEE 1364-2005 §1.7 Annex G: a name VerA does not answer is refused by that name" {
    var h: run.Harness = undefined;
    try h.init(
        \\module m(a);
        \\  input a;
        \\  wire w;
        \\endmodule
    );
    defer h.deinit();
    const m = vpi_handle_by_name("m", null) orelse return error.TestUnexpectedResult;
    const a = portNamed(m, "a") orelse return error.TestUnexpectedResult;
    // A property (vpi_get and vpi_get_str), an object or relationship
    // (vpi_handle and vpi_iterate) and a callback reason, each Annex G's.
    try std.testing.expectEqual(vpiUndefined, vpi_get(8, m));
    try std.testing.expect(std.mem.find(u8, lastMessage(), "vpiCellInstance") != null);
    try std.testing.expect(vpi_get_str(15, m) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "vpiDefFile") != null);
    try std.testing.expect(vpi_handle(80, a) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "vpiLowConn") != null);
    try std.testing.expect(vpi_iterate(127, m) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "vpiTaskFunc") != null);
    const save: callback.CbData = .{ .reason = 15, .cb_rtn = noCb, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&save) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "cbStartOfSave") != null);
    // The legal neighbours on the same objects answer, with no error.
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiTopModule, m));
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    try std.testing.expect(vpi_iterate(code.vpiTask, m) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
}

fn noCb(_: *callback.CbData) callconv(.c) c_int {
    return 0;
}

test "§12.22: vpi_handle_multi(vpiInterModPath) is one path per port pair, holding its delays" {
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module gate(a, y, w);
        \\  input a; output y; input [1:0] w;
        \\  buf (y, a);
        \\endmodule
        \\module top;
        \\  reg r; wire n, z; wire [1:0] v;
        \\  gate u1(r, n, v);
        \\  gate u2(n, z, v);
        \\endmodule
    );
    defer h.deinit();
    const y1 = portNamed(vpi_handle_by_name("top.u1", null), "y") orelse return error.TestUnexpectedResult;
    const a2 = portNamed(vpi_handle_by_name("top.u2", null), "a") orelse return error.TestUnexpectedResult;
    const w2 = portNamed(vpi_handle_by_name("top.u2", null), "w") orelse return error.TestUnexpectedResult;
    const multi = @import("systf.zig").vpi_handle_multi;
    const imp = @import("systf.zig").vpiInterModPath;

    const p = multi(imp, y1, a2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    try std.testing.expectEqual(imp, vpi_get(vpiType, p));
    try std.testing.expectEqualStrings("vpiInterModPath", std.mem.span(vpi_get_str(vpiType, p)));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(p, multi(imp, y1, a2)));
    // IEEE 1364-2005 §26.6.16: ->> its ports, the output first.
    const itr = vpi_iterate(vpiPort, p);
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_scan(itr), y1));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_scan(itr), a2));
    try std.testing.expect(vpi_scan(itr) == null);
    try std.testing.expect(vpi_handle(vpiModule, p) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));

    // No put yet: no delay. Then two, turn-off §7.14's min(rise, fall).
    var da: [9]callback.Time = undefined;
    var dl: delays.Delay = .{ .da = &da, .no_of_delays = 3, .time_type = callback.vpiScaledRealTime, .mtm_flag = 0, .append_flag = 0, .pulsere_flag = 0 };
    delays.vpi_get_delays(p, &dl);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    for (da[0..3]) |t| try std.testing.expectEqual(@as(f64, 0), t.real);
    const before = h.bag.count();
    da[0] = .{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = 4 };
    da[1] = .{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = 2 };
    dl.no_of_delays = 2;
    delays.vpi_put_delays(p, &dl);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    dl.no_of_delays = 3;
    delays.vpi_get_delays(p, &dl);
    for (da[0..3], [_]f64{ 4, 2, 2 }) |t, want| try std.testing.expectEqual(want, t.real);
    // The put is not silent: the run's diagnostics say no simulation applies it.
    try std.testing.expectEqual(before + 1, h.bag.count());
    try std.testing.expectEqual(vera.diag.Code.W0251, h.bag.at(before).code);
    // Read in ticks: 4 ns is 4 ticks of the 1 ns precision.
    dl.time_type = callback.vpiSimTime;
    delays.vpi_get_delays(p, &dl);
    try std.testing.expectEqual(@as(c_uint, 4), da[0].low);
    // Pulse limits other than the delay are refused, not dropped.
    dl.time_type = callback.vpiScaledRealTime;
    dl.pulsere_flag = 1;
    for (&da, 0..) |*t, k| t.* = .{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = @floatFromInt(k) };
    delays.vpi_put_delays(p, &dl);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));

    // Not a path: an input first, one port twice, two sizes, a non-port.
    try std.testing.expect(multi(imp, a2, y1) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "not an output or inout port") != null);
    try std.testing.expect(multi(imp, y1, y1) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(multi(imp, y1, w2) == null);
    try std.testing.expect(std.mem.find(u8, lastMessage(), "same size") != null);
    try std.testing.expect(multi(imp, vpi_handle_by_name("top.n", null), a2) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}
