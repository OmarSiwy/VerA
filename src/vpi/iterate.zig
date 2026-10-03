//! One-to-many traversal: §12.23 vpi_iterate and §12.35 vpi_scan. A
//! reference handle and a type -> a heap `Iter` over object indices (or over
//! handles it owns), live while it is a key of `Design.iters`: vpi_scan frees
//! it on exhaustion, vpi_free_object (root.zig) on request. IEEE 1364-2005
//! §26.6.22/§26.6.23 drivers and loads and §26.6.43 vpiUse are computed per
//! call rather than stored.

const std = @import("std");
const sim = @import("sim");
const callback = @import("callback.zig");
const code = @import("code.zig");
const property = @import("property.zig");
const root = @import("root.zig");
const coldOf = root.coldOf;
const run = @import("run.zig");
const systf = @import("systf.zig");

const Design = root.Design;
const Iter = root.Iter;
const Obj = root.Obj;
const asIter = root.asIter;
const asObj = root.asObj;
const codeProp = property.codeProp;
const describe = root.describe;
const enter = root.enter;
const fail = root.fail;
const handleOf = root.handleOf;
const no_obj = root.no_obj;
const object = root.object;
const typeName = root.typeName;
const typeOf = root.typeOf;
const vpiBranch = root.vpiBranch;
const vpiChild = root.vpiChild;
const vpiDirection = root.vpiDirection;
const vpiDiscipline = root.vpiDiscipline;
const vpiHandle = root.vpiHandle;
const vpiInout = root.vpiInout;
const vpiIntegerVar = root.vpiIntegerVar;
const vpiInternalScope = root.vpiInternalScope;
const vpiMemory = root.vpiMemory;
const vpiMemoryWord = root.vpiMemoryWord;
const vpiModule = root.vpiModule;
const vpiModuleArray = root.vpiModuleArray;
const vpiNature = root.vpiNature;
const vpiNet = root.vpiNet;
const vpiNetArray = root.vpiNetArray;
const vpiNode = root.vpiNode;
const vpiOutput = root.vpiOutput;
const vpiParameter = root.vpiParameter;
const vpiParent = root.vpiParent;
const vpiPort = root.vpiPort;
const vpiRealVar = root.vpiRealVar;
const vpiReg = root.vpiReg;
const vpiRegArray = root.vpiRegArray;
const vpiScope = root.vpiScope;
const vpiVarSelect = root.vpiVarSelect;
const vpiVariables = root.vpiVariables;

/// "If there are no objects of type `type` associated with the reference handle
/// `ref`, then `vpi_iterate()` shall return NULL."
///
/// So an EMPTY set and an UNSUPPORTED relationship have the same return value,
/// and the difference between them is the error status: a module with no regs
/// is NULL with no error, `vpi_iterate(vpiPort, some_net)` is NULL with one. An
/// application that does not check errors sees the documented empty loop either
/// way; one that does can tell a fact about the design from a limit of VerA's.
pub export fn vpi_iterate(obj_type: c_int, ref: vpiHandle) vpiHandle {
    const h = iterate(obj_type, ref);
    if (asIter(h)) |it| {
        it.use = ref;
        it.ty = obj_type;
    }
    return h;
}

fn iterate(obj_type: c_int, ref: vpiHandle) vpiHandle {
    const d = enter("vpi_iterate") orelse return null;
    // IEEE 1364-2005 §26.6.39: object and time-queue associations, or a
    // NULL reference for global callbacks. Time queues are not Design rows.
    if (obj_type == callback.vpiCallback) {
        if (ref != null and asObj(ref) == null and run.asQueue(ref) == null) {
            _ = object("vpi_iterate", ref);
            return null;
        }
        const handles = callback.all(d.gpa, ref) catch {
            fail("NOMEM", "vpi_iterate: out of memory", .{});
            return null;
        };
        if (handles.len == 0) {
            d.gpa.free(handles);
            return null;
        }
        return newHandleIter(d, handles);
    }
    // §11.6.1 NOTE 1: "Top-level modules shall be accessed using vpi_iterate()
    // with a NULL reference object."
    if (ref == null) {
        if (obj_type == systf.vpiUserSystf) {
            const handles = systf.all(d.gpa) catch {
                fail("NOMEM", "vpi_iterate: out of memory", .{});
                return null;
            };
            if (handles.len == 0) {
                d.gpa.free(handles);
                return null;
            }
            return newHandleIter(d, handles);
        }
        if (obj_type == run.vpiTimeQueue) {
            const handles = run.timeQueues(d.gpa) catch {
                fail("NOMEM", "vpi_iterate: out of memory", .{});
                return null;
            };
            if (handles.len == 0) {
                d.gpa.free(handles);
                return null;
            }
            return newHandleIter(d, handles);
        }
        // §11.6.2's circled arrows: disciplines and natures are design-wide.
        // An empty set (a digital design) is NULL with no error (§12.23).
        if (obj_type == vpiDiscipline or obj_type == vpiNature or obj_type == code.vpiUdpDefn) {
            const items = if (obj_type == vpiDiscipline) d.disciplines else if (obj_type == vpiNature) d.natures else d.udp_defns;
            return if (items.len == 0) null else newIter(d, items);
        }
        if (obj_type != vpiModule) {
            fail("NOTRAVERSE", "vpi_iterate: {d} is not iterable from a NULL reference", .{obj_type});
            return null;
        }
        return newIter(d, d.top_modules);
    }
    const o = object("vpi_iterate", ref) orelse return null;
    if (obj_type == code.vpiAttribute and @import("attributes.zig").supports(o))
        return if (coldOf(o).attributes.len == 0) null else newIter(d, coldOf(o).attributes);
    if (obj_type == code.vpiUse) return uses(d, o);
    // A behavioural object's double arrows are its `lists` rows, as are a
    // vector's bits. An empty row is an empty set (NULL, no error —
    // §11.6.23 NOTE 2's default case item among them); a tag a behavioural
    // object has no row for is no relationship.
    for (o.lists) |l| if (l.tag == obj_type) return if (l.items.len == 0) null else newIter(d, l.items);
    if (o.kind == .code) {
        fail("NOTRAVERSE", "vpi_iterate: a {s} is the reference object of no relationship {d}", .{ typeName(o.vtype), obj_type });
        return null;
    }
    // §11.6.11 (IEEE 1364 §26.6.7-9): an array's elements. A memory's words by
    // the legacy vpiMemoryWord tag or as vpiReg; a variable array's by
    // vpiVarSelect; an instance array's members by vpiModule.
    const elements: bool = switch (o.kind) {
        .reg_array => obj_type == vpiMemoryWord or obj_type == vpiReg,
        .var_array => obj_type == vpiVarSelect,
        .net_array => obj_type == vpiNet,
        .module_array => obj_type == vpiModule,
        else => false, // else: only the four array classes hold elements
    };
    if (elements) return newIter(d, coldOf(o).members);
    if (obj_type == code.vpiRange and coldOf(o).range.len != 0) return newIter(d, coldOf(o).range);
    // The analog double arrows: node ->> net (§11.6.5), nature ->> nature
    // tagged vpiChild and nature ->> discipline (§11.6.2).
    const analog: ?[]const u32 = switch (o.kind) {
        .node => if (obj_type == vpiNet) coldOf(o).nets else null,
        .nature => if (obj_type == vpiChild) coldOf(o).children else if (obj_type == vpiDiscipline) coldOf(o).users else null,
        else => null, // else: no other class but module draws a double arrow VerA holds
    };
    if (analog) |items| return if (items.len == 0) null else newIter(d, items);
    switch (obj_type) {
        code.vpiDriver, code.vpiLoad, code.vpiLocalDriver, code.vpiLocalLoad => if (o.kind == .net or o.kind == .reg)
            return driversLoads(d, o, obj_type == code.vpiDriver or obj_type == code.vpiLocalDriver, obj_type == code.vpiLocalDriver or obj_type == code.vpiLocalLoad),
        else => {},
    }
    if (o.kind != .module) {
        fail("NOTRAVERSE", "vpi_iterate: a {s} is the reference object of no one-to-many relationship {d}", .{ @tagName(o.kind), obj_type });
        return null;
    }
    const s = &d.scopes[o.scope];
    for (s.lists) |l| if (l.tag == obj_type) return if (l.items.len == 0) null else newIter(d, l.items);
    const items: []const u32 = switch (obj_type) {
        vpiModule => s.children,
        vpiInternalScope => s.internal,
        vpiPort => s.ports,
        vpiNet => s.nets,
        vpiReg => s.regs,
        vpiParameter => s.params,
        vpiIntegerVar => s.integers,
        vpiRealVar => s.reals,
        // IEEE 1364 §26.6.9: the legacy vpiMemory method returns the reg
        // arrays, as vpiRegArray objects.
        vpiMemory, vpiRegArray => s.reg_arrays,
        vpiNetArray => s.net_arrays,
        vpiVariables => s.variables,
        vpiModuleArray => s.module_arrays,
        // §11.6.1's `nodes` and `branches` classes (§11.6.5, §11.6.6).
        vpiNode => s.nodes,
        vpiBranch => s.branches,
        else => {
            fail("NOTRAVERSE", "vpi_iterate: no one-to-many relationship {d} from a module", .{obj_type});
            return null;
        },
    };
    if (items.len == 0) return null;
    return newIter(d, items);
}

/// IEEE 1364-2005 §26.6.25 simple expr ->> vpiUse: the objects (statements,
/// expressions, continuous assignments, terminals) that read or write `o`,
/// in object order. Details a): "For vectors, the vpiUse relationship shall
/// access any use of the vector or part-selects or bit-selects thereof", so
/// an object holding a select of `o` uses it too.
///
/// ponytail: a scan of every object per call, and a bit select's own uses
/// only (Details b adds the parent vector's and a containing part select's).
fn uses(d: *Design, o: *const Obj) vpiHandle {
    switch (o.kind) {
        .net, .reg, .integer, .real_var, .time_var, .parameter, .word, .var_select => {},
        .code => if (o.vtype != code.vpiNetBit and o.vtype != code.vpiRegBit) return useFail(o),
        .module, .port, .reg_array, .var_array, .net_array, .module_array, .constant, .discipline, .nature, .node, .branch, .quantity => return useFail(o),
    }
    const target: u32 = @intCast((@intFromPtr(o) - @intFromPtr(d.objects.ptr)) / @sizeOf(Obj));
    var out: std.ArrayList(vpiHandle) = .empty;
    for (d.objects) |*u| {
        if (u.kind != .code) continue;
        const hit = for (u.edges) |e| {
            // A select's vpiParent is the vector it selects from, not a use.
            if (e.tag != vpiParent and e.tag != vpiScope and e.tag != vpiModule and reaches(d, e.to, target)) break true;
        } else for (u.lists) |l| {
            if (for (l.items) |i| {
                if (reaches(d, i, target)) break true;
            } else false) break true;
        } else false;
        if (hit) out.append(d.gpa, handleOf(u)) catch {
            out.deinit(d.gpa);
            fail("NOMEM", "vpi_iterate: out of memory", .{});
            return null;
        };
    }
    if (out.items.len == 0) {
        out.deinit(d.gpa);
        return null;
    }
    const handles = out.toOwnedSlice(d.gpa) catch {
        out.deinit(d.gpa);
        fail("NOMEM", "vpi_iterate: out of memory", .{});
        return null;
    };
    return newHandleIter(d, handles);
}

/// Is object `at` the object `target`, or a part or bit select of it?
fn reaches(d: *const Design, at: u32, target: u32) bool {
    if (at == target) return true;
    if (at == no_obj) return false;
    const x = &d.objects[at];
    if (x.kind != .code) return false;
    switch (x.vtype) {
        code.vpiPartSelect, code.vpiIndexedPartSelect, code.vpiNetBit, code.vpiRegBit => {},
        else => return false, // else: only a select names a part of another object
    }
    for (x.edges) |e| if (e.tag == vpiParent) return e.to == target;
    return false;
}

fn useFail(o: *const Obj) vpiHandle {
    fail("NOTRAVERSE", "vpi_iterate: a {s} is no simple expression, so it has no vpiUse", .{typeName(typeOf(o))});
    return null;
}

/// IEEE 1364-2005 §26.6.22/§26.6.23: the drivers (`drivers`) or loads of net
/// or reg `o`. A prim term drives what its output terminal names, loads what
/// an input names, and does both through an inout; a continuous assignment
/// drives its left side and loads what its right side reads; a force or
/// assign stmt does too while one is active (§26.6.6 Details i, j). A net
/// collapsed across a port is one simulated net (§12.3.10), so what drives
/// or loads it in another instance is listed too (Details b). `local`
/// (vpiLocalDriver/vpiLocalLoad, Details l) keeps what `o`'s own module
/// contains, "including any ports connected to the net (output and inout
/// ports are loads, input and inout ports are drivers)"; the module's ports
/// are listed for vpiDriver and vpiLoad as well.
///
/// ponytail: a scan of every object per call; the parent's instance ports,
/// delay terms and cont assign bits are not listed. Each needs its own
/// relation built at `open`.
fn driversLoads(d: *Design, o: *const Obj, drivers: bool, local: bool) vpiHandle {
    var out: std.ArrayList(vpiHandle) = .empty;
    for (d.objects, 0..) |*x, i| {
        if (local and x.owner != o.owner) continue;
        const hit = switch (x.kind) {
            .code => switch (x.vtype) {
                code.vpiPrimTerm => mentions(d, edgeTo(x, code.vpiExpr), o) and switch (codeProp(x, vpiDirection)) {
                    vpiOutput => drivers,
                    vpiInout => true,
                    else => !drivers,
                },
                code.vpiContAssign => mentions(d, edgeTo(x, if (drivers) code.vpiLhs else code.vpiRhs), o),
                code.vpiForce, code.vpiAssignStmt => activeOverride(d, x) and mentions(d, edgeTo(x, if (drivers) code.vpiLhs else code.vpiRhs), o),
                else => false, // else: §26.6.22/§26.6.23 list no other behavioural class
            },
            .port => o.kind == .net and x.owner == o.owner and std.mem.eql(u8, x.name, o.name) and switch (x.direction) {
                .input => drivers,
                .output => !drivers,
                .inout => true,
                .unspecified => false,
            },
            else => false, // else: no other class drives or loads a net or reg
        };
        if (hit) out.append(d.gpa, handleOf(&d.objects[i])) catch {
            out.deinit(d.gpa);
            fail("NOMEM", "vpi_iterate: out of memory", .{});
            return null;
        };
    }
    if (out.items.len == 0) return null;
    const handles = out.toOwnedSlice(d.gpa) catch {
        out.deinit(d.gpa);
        fail("NOMEM", "vpi_iterate: out of memory", .{});
        return null;
    };
    return newHandleIter(d, handles);
}

/// §26.6.6 i, j: activity belongs to the statement maintaining an override,
/// not to the object whose loads or drivers are being queried. In particular
/// a load is on the RHS, while the override registry is keyed by the LHS.
fn activeOverride(d: *const Design, o: *const Obj) bool {
    if (coldOf(o).override_expr == .none) return false;
    const r = run.attached() orelse return false;
    var it = r.overrides.valueIterator();
    while (it.next()) |layers| {
        if (if (o.vtype == code.vpiForce) layers.force else layers.assign) |range|
            if (overrideRange(d, o, r, range)) return true;
        if (o.vtype == code.vpiForce) for (layers.parts.items) |part|
            if (overrideRange(d, o, r, part.range)) return true;
    }
    return false;
}

fn overrideRange(d: *const Design, o: *const Obj, r: *const sim.digital.Run, range: sim.digital.PcRange) bool {
    // A VPI force has an empty range; it activates no HDL source statement.
    if (range.start == range.end) return false;
    if (r.instanceOf(r.code_scope.items[range.start]) != d.scopes[o.owner.?].engine) return false;
    return switch (r.code.items[range.start]) {
        .override_eval => |op| op.value == coldOf(o).override_expr and op.force == (o.vtype == code.vpiForce),
        else => false, // else: only an override_eval maintains a procedural continuous assignment
    };
}

/// `x`'s single arrow `tag`, or `no_obj`.
fn edgeTo(x: *const Obj, tag: c_int) u32 {
    for (x.edges) |e| if (e.tag == tag) return e.to;
    return no_obj;
}

/// Does expression `e` read `target`'s storage: is it the same slot (or the
/// same object), a select of it, or an operation or call with such an
/// operand?
fn mentions(d: *const Design, e: u32, target: *const Obj) bool {
    if (e == no_obj) return false;
    const x = &d.objects[e];
    if (x == target or (x.slot != null and x.slot == target.slot and x.kind != .code)) return true;
    if (x.kind != .code) return false;
    switch (x.vtype) {
        code.vpiPartSelect, code.vpiNetBit, code.vpiRegBit => return mentions(d, edgeTo(x, vpiParent), target),
        code.vpiOperation, code.vpiFuncCall, code.vpiSysFuncCall => for (x.lists) |l| {
            if (l.tag != code.vpiOperand and l.tag != code.vpiArgument) continue;
            for (l.items) |i| if (mentions(d, i, target)) return true;
        },
        else => {}, // else: no other class is an expression with operands
    }
    return false;
}

/// An iterator over `handles`, which it takes ownership of.
fn newHandleIter(d: *Design, handles: []vpiHandle) vpiHandle {
    const h = newIter(d, &.{});
    if (asIter(h)) |it| it.handles = handles else d.gpa.free(handles);
    return h;
}

fn newIter(d: *Design, items: []const u32) vpiHandle {
    const it = d.gpa.create(Iter) catch {
        fail("NOMEM", "vpi_iterate: out of memory", .{});
        return null;
    };
    it.* = .{ .items = items };
    d.iters.put(d.gpa, @intFromPtr(it), it) catch {
        d.gpa.destroy(it);
        fail("NOMEM", "vpi_iterate: out of memory", .{});
        return null;
    };
    return @ptrCast(it);
}

/// "Once `vpi_scan()` returns NULL, the iterator handle is no longer valid and
/// can not be used again" (§12.35), and §12.4 spells out the consequence: "The
/// iterator object shall automatically be freed when vpi_scan() returns NULL".
///
/// So exhaustion frees the iterator, and scanning it again is an invalid-handle
/// error rather than a use-after-free.
pub export fn vpi_scan(itr: vpiHandle) vpiHandle {
    const d = enter("vpi_scan") orelse return null;
    const it = asIter(itr) orelse {
        fail("BADHANDLE", "vpi_scan: {s} is not a handle to a live iterator", .{describe(itr)});
        return null;
    };
    if (it.handles) |hs| {
        if (it.at >= hs.len) {
            destroyIter(d, it);
            return null;
        }
        it.at += 1;
        return hs[it.at - 1];
    }
    if (it.at >= it.items.len) {
        destroyIter(d, it);
        return null;
    }
    const idx = it.items[it.at];
    it.at += 1;
    return handleOf(&d.objects[idx]);
}

/// Frees `it` and the handles it owns, and removes it from `d.iters` first,
/// so its handle is invalid (`asIter` null) before the memory is.
pub fn destroyIter(d: *Design, it: *Iter) void {
    _ = d.iters.remove(@intFromPtr(it));
    if (it.handles) |hs| d.gpa.free(hs);
    d.gpa.destroy(it);
}
