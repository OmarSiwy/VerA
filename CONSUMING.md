# Consuming VerA

For the author of a simulator that wants to run Verilog-AMS models — ARPice, or
any other host.

VerA is a **compiler**. It turns `.va` into a device: a Zig type satisfying the
contract in [`tools/contract.zig`](tools/contract.zig), which your simulator
instantiates, stamps and solves. It owns the frontend, the IR, the finiteness
proof and codegen. It does not own the simulation.

**Host responsibilities.** Delegating these services to a host does not remove
them from the full Verilog-AMS conformance target. The combined compiler and host
must implement and test them; see [the open requirements](docs/CONFORMANCE-GAPS.md).

| yours | why |
|---|---|
| the Newton loop, the matrix, the timestep controller | §8.3's simulation cycle is the simulator's |
| netlist parsing, instancing, topology | a `.va` is one device, not a circuit |
| `dlopen`/`dlclose`, artifact lifetime | VerA's responsibility ends at the artifact |
| the C ABI of a loaded `.so` | you name the symbols — see `exportDevice` below |
| VPI (Clauses 11–12) | it is a live-simulation C API; see [VPI](#vpi-clauses-1112) |

Everything below is checked mechanically, at `comptime`, so a mismatch is a
readable compile error and not a null hook at 3 a.m. Two checks, and only one is
yours to call:

- **`contract.validate(D)`** — the device. Codegen emits
  `comptime { contract.validate(Self); }` into every device it generates, so
  this one runs whether you ask or not. Call it yourself on a HAND-WRITTEN
  device.
- **`contract.validateHost(H, D)`** — you. Nothing calls this for you. See
  [§4.2](#42-it-is-not-optional).

---

## 1. Wiring

`build.zig.zon`:

```zig
.dependencies = .{
    .vera = .{ .path = "../VerA" },   // or .url/.hash
},
```

`build.zig`:

```zig
const vera = b.dependency("vera", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("vera", vera.module("vera"));         // the engine
exe.root_module.addImport("contract", vera.module("contract")); // the ABI
```

Two modules, and a third thing that is not a module:

- **`vera`** — the compiler, if you want to compile in-process. Root is
  `src/root.zig`.
- **`contract`** — the ABI your host and every generated device both import.
  One file, one definition, no copy to drift.
- **`tools/contract.zig` as a PATH** — `vera.path("tools/contract.zig")`. The
  same file again, because a generated device is compiled by a *child* `zig`
  process that needs it on a command line, not as a module of yours. Both ways
  are the point of it living in `tools/` and not `src/`: nothing in the
  compiler imports it. It is a shipped artifact compiled into DEVICES.

## 2. Two ways in

### The CLI

```
vera model.va                                          lint
vera --emit-zig -o dev.zig model.va                    device source
vera --emit-so  --dyn PATH --contract PATH model.va    loadable device
vera --run --contract PATH model.va                    build + run a testbench
```

`--emit-so` needs `--dyn PATH`: the export shim is **yours**, because it is your
ABI and not the compiler's (§3.4). `--contract PATH` points the child `zig` at
`tools/contract.zig`.

Other flags a host tends to want: `--check` (type-check the generated device
with `zig`, no link — proves the artifact compiles *here*, where the `.va` is,
instead of in your build), `--display=emit|drop` (§9.4, below), `--no-std-defs`
(skip the Annex D prelude), `--diagnostics=json`,
`--allow`/`--warn`/`--deny`/`--forbid=CODE`, `--expect-module=NAME`,
`--work-dir DIR`, `--zig PATH`, `--explain CODE`.

### In-process

```zig
const vera = @import("vera");

var bag: vera.diag.Bag = .init(gpa);
defer bag.deinit(gpa);

var result = try vera.compileSourceOpts(gpa, source, .release_fast, .{
    .file_name = path,
    .include_dirs = &.{ dir },
    .diags = &bag,
    .display = .drop,
});
defer result.deinit();

const device_zig = try result.generateDevice();
```

`vera.Target` picks the backend and is not a style knob:

| target | stages | backend | artifact |
|---|---|---|---|
| `.lint` | 1–5 | none | none — microseconds, no `zig` spawn |
| `.debug` | 1–8 | self-hosted, incremental | CPU `.so` |
| `.release_fast` | 1–8 | LLVM | CPU `.so` |

`.debug` builds through a session-scoped resident `zig build --listen=-` child
(`orchestrator.ResidentChild`); without one `buildArtifact` returns
`error.NoResidentChild`. Cross-process `-fincremental` does not exist on ELF
0.16, which is why the child is session-scoped rather than per-build.

**A successful compile can still fill the bag.** W0650 (not provably finite),
W0850 (a dropped display task), W0852 (an unregistered systf) are warnings on a
device that is fine. Read the bag either way; `Options.diags` is detached from
the compilation arena before the call returns, so it outlives the
`CompileResult` and you `deinit(gpa)` it yourself.

## 3. The device contract

### 3.1 Required

```zig
pub const U: enum(u8)          // solver unknowns, DENSE, values 0..n-1
pub const num_ports: usize     // ports are a PREFIX of U; 0 is legal (§6.2)
pub const Model: struct        // every field defaulted
pub const Instance: struct     // every field defaulted
pub fn eval(comptime S: type, x: [n]S, m: *const Model, i: contract.InstancePtr(Self), t: f64) [n]S
```

`U` must be `enum(u8)` with values `0..n-1` — that is what makes the residual
index an array index. It also caps a device at **256 unknowns**; past that
codegen refuses with E1003 rather than emitting an artifact whose 257th tag
fails to type-check in *your* build.

`num_ports <= |U|`, with ports first. Zero is legal and is not a degenerate
case: §6.2 makes the port list optional, and such a device's residual is over
its own private nodes and solves fine.

### 3.2 The scalar protocol

Physics is generic over an opaque `S` that **you** instantiate — a plain f64
form for the residual, a derivative-carrying dual for the Jacobian. That is the
whole reason `eval` takes `comptime S: type`.

```
con addC scale · add sub neg mul div · exp log expm1 log1p sqrt pow(a,c)
sin cos tanh sinh cosh atan · abs minC maxC min max · val
```

`expm1`/`log1p` are primitives and not `exp(x)-1` / `log(1+x)`: §4.3.1
Table 4-14 names the C library forms precisely because those two compositions
cancel.

Rules generated physics follows, and yours must too if you hand-write a device:

- everything not depending on `x` (params, temperature, geometry) stays plain
  f64; only x-dependent chains use `S` ops;
- never branch on an `S` with `if` — use `.val()` for topology decisions and
  `minC`/`maxC`/`min`/`max` for clamps.

### 3.3 Optional decls

Every one is opt-in; a device that declares none is still a device. Several are
**paired** — declaring one without the other is a compile error, because a
table with no values or values with no table is a hook nobody can call.

| decl | what | pairs with |
|---|---|---|
| `q` | §5.6.1.2 charges | — |
| `evalQ` | both residuals from ONE model evaluation — **see below** | `q` |
| `limit` / `seed` | pnjlim/fetlim, cold-start (SPICE MODEINITJCT) | — |
| `collapse` | node collapsing | — |
| `initState` / `updateState` / `stateCtl` / `State` | accepted-step FSM state | each other |
| `u_kinds` / `u_abstol` | §3.6.1.2 per-unknown kind and tolerance | — |
| `u_nodeset` | §3.6.3.2 per-unknown starting guess, `[|U|]?f64` | — |
| `noise_gens` / `noisePsd` | §4.6.4 topology / PSD | each other |
| `ac_stamps` / `acStamp` | small-signal `G + jwC` | each other |
| `op_vars` / `opValues` | §3.2.1 output variables | each other |
| `systf_calls` | §2.8.3/§12.32 — **see §4** | your `systf` |
| `mc_param` | Monte Carlo principal parameter | — |
| `derive` | §6.3.4/§3.4.5 params defined over params | — |
| `precompute` | instance-mutating parameter prep | — |
| `constant` | constant-Jacobian declaration | — |
| `mutable_eval` | exclusive mutable access during evaluation | host `mutable_eval = true` |
| `nextBreakpoint` | §9.17 breakpoint scheduling | — |
| `AnalysisKind` | §4.6.1 `analysis()`, ordinals pinned to `contract.AnalysisKind` | — |
| `display` | §9.4 + §9.5, the side-effect phase | `--display=emit` only |
| `attempt` | convergence aid, `fn (Model, f64) Model` — **no consumer**, see below | — |

A positional table plus a hook indexed at position `k` is the idiom throughout —
`noise_gens[k]` describes element `k` of `noisePsd`'s result, and so on. Nothing
is name-keyed, because a `[]const u8` lookup is a runtime search that cannot be
comptime-validated.

### `evalQ` — call this one in a transient

```zig
pub fn evalQ(comptime S: type, x: [n]S, m: *const Model, i: *const Instance, t: f64)
    struct { res: [n]S, q: [n]S }
```

Emitted whenever `q` is. Returns exactly what `eval` and `q` return — the
generated testbench asserts it bit-for-bit, value and derivative, at every
accepted step — for **half** the work.

`eval` and `q` each open their own call to the module's shared core, so a host
that wants both runs the entire model twice. That is an artifact of there being
two entry points, not of the physics: codegen already hoists every subexpression
the two halves share into one core whose returned struct carries both halves'
targets, and the dispatchers only read different fields of it. Measured on a
host SPICE, `<module>__common__core` showed up twice per instance evaluation
with identical inclusive cost, against device evaluation that was ~90% of a
transient.

So:

- needs the resistive half only (DC, operating point) → call `eval`;
- needs both (every transient step) → call `evalQ`, **not** `eval` then `q`.

`eval` and `q` are unchanged and remain the §3.1 contract; this is purely
additive, and a host that ignores it keeps working at the old cost.

`attempt` is the one row here that is declared and not consumed. Its site names
`batch.zig:616` as the caller and that file no longer exists (the SIMD batch
evaluator was deleted for being uninstantiable), so nothing in this tree calls
it and no test covers it. Treat it as reserved: implement it only if you have
measured that you want it, and expect the shape to move.

`display` deserves a note: it is present ONLY in a device built with
`--display=emit`, which is the testbench artifact. A device compiled for a
solver does not have it, and that is deliberate — §9.5.9 puts every file write
at the accepted point, and text inside `eval` would fire once per Newton
iteration.

### First-call table snapshots

A device with array-source `$table_model` calls declares `mutable_eval = true`.
`contract.InstancePtr(D)` is then `*D.Instance`; otherwise it remains
`*const D.Instance`. Use this type for evaluation entry points, including `q`,
`evalQ` and `display`. The host capability type must declare
`pub const mutable_eval = true` before `validateHost` accepts these devices.

The host must provide exclusive access to each instance during evaluation.
The first executed table call captures its source arrays; later calls use those
stored values. The capture survives rejected timesteps and is distinct from
accepted-time state. Allocate a fresh instance for a fresh simulation lifetime.
Auxiliary preparation hooks evaluate with a copy and do not initialize the live
snapshot. The generated-host tests exercise this separation and rollback.

ARPice supplies mutable access and keeps these devices on the CPU. Its evaluation
test checks independent instance ownership and GPU exclusion. Other hosts must
supply the same lifetime and ownership behavior before advertising support.

### Newton iteration hooks

Devices using user-function `$limit`, `$simparam("iteration")`, or
`$discontinuity(-1)` expose iteration hooks separately from `updateState`.
A host must implement their call order and declare `pub const iteration_hooks = true`
in its host capability type before `contract.validateHost` accepts these devices.
This declaration acknowledges implementation; it does not install a scheduler.

- Call optional `beginSolve(inst)` before the first evaluation of each new solve.
- Call optional `advanceIteration(model, inst, previous_x)` once between evaluated
  Newton iterates, with the previous iterate's vector. Do not call it for finite
  difference/Jacobian probes or after the accepted final evaluation.
- A false return from optional `checkConvergence(model, inst, x)` vetoes
  convergence. Call it on every acceptance path, including zero-step exits.
- `updateState` remains accepted-time bookkeeping. `stateCtl(.commit/.revert)`
  saves/restores iteration history; commit does not reset the iteration counter.

The standalone testbench and ARPice's direct Newton/JFNK host implement these
hooks. ARPice keeps such devices on the CPU, including in mixed GPU circuits.
Its `test-iteration` target exercises generated-device failure, rollback and
retry through Circuit and both solvers. Auxiliary analysis drivers still need
accepted/rejected-time lifecycle coverage. Native transmission-line migration
and full VPI support remain separate open work in
[CONFORMANCE-GAPS.md](docs/CONFORMANCE-GAPS.md).

### 3.4 What YOU write

**Host-written `Instance` fields.** Not decls — you reach them by name, so the
contract pins the NAME and the TYPE. Presence stays optional (a hand-written
resistor needs none); a typo does not.

```
temperature      f64    §9.15, kelvin
abstime          f64    §9.10
dt               f64    §9.10, feeds ddt/idt; 0 in a static analysis
mfactor          f64    §9.15/E.4.1
is_initial_step  bool   §5.10.2
is_final_step    bool   §5.10.2
bound_step       f64    §9.17.2, written by updateState, read by you
analysis_kind    enum   §4.6.1 — ORDINALS must match contract.AnalysisKind
systf            ?*const contract.SystfHost   §2.8.3/§12.32 — see §4
```

`analysis_kind` is converted by ordinal
(`@enumFromInt(@intFromEnum(host_kind))`), so tag ORDER is load-bearing, not
just the tag set. `validateSimState` enforces it. This check exists because
`temperature` was once probed as `"temp"` and read null for every generated
device, with no diagnostic and every waveform silently pinned at its t=0 value.

**The export shim, if you load `.so`s.** `--emit-so` generates one line:

```zig
comptime { @import("dyn").exportDevice(@import("device"), "<name>"); }
```

`dyn` is a module of yours whose root exposes

```zig
pub fn exportDevice(comptime D: type, comptime name: []const u8) void
```

In ARPice that is `src/devices/engine.zig`, and what it exports —
`arp_abi_version`, `arp_layout_hash`, `arp_device` — is **ARPice's** naming, not
VerA's. VerA fixes nothing about the C ABI of a loaded device. It hands you the
type; the symbols are yours.

`orchestrator.Options.modules` must contain `contract` and `dyn`, and **order is
load-bearing**: it is hashed into `layout_hash` and fixes argv order. Compare
`layout_hash` before trusting a `.so` — it pins optimize mode, backend and
module roots.

## 4. VPI (Clauses 11–12)

VPI is a **C API into a running simulator**: handles onto modules, nodes,
branches, quantities (§11.6), and ~50 routines to traverse and read them
(Clause 12). It is yours end to end. VerA cannot implement it — every routine
needs a live simulation — and refusing `vpi_get()` in `.va` source (E0512) is
the conforming answer for a compiler, permanently.

**One clause reaches across, and it is mandatory for you.**

§2.8.3 makes `$name` grammatical and lists "defined using the VPI as described
in Clause 11 and Clause 12" as one of the places a system function may come
from. §12.32 `vpi_register_analog_systf()` is that place. So a `.va` may
legally call a `$name` this compiler has never heard of, and §12.32.3's own
listing puts one in a contribution:

```verilog
V(out) <+ $sampler(V(in), period);
```

VerA does not invent a value for it. It exports the name:

```zig
pub const systf_calls = [_]contract.Systf{
    .{ .name = "$sampler" },
};
```

and every call site reads its value — **and its derivatives** — from what you
bind into `Instance.systf`.

### 4.1 What you implement

```zig
pub const SystfHost = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, k: usize, args: []const f64, partials: []f64) f64,
};
```

`k` indexes `systf_calls`. `partials` is exactly `args.len` long and is **not**
zeroed on entry: write every slot, zero included. An entry left alone is a
derivative you are claiming without computing.

Entries are keyed by NAME, not call site — §12.32: *"the task or function name
shall be unique in the domain in which it is registered."* Two calls to one
`$name` are one entry and one binding.

**Why value-plus-partials and not `fn (k, args: []S) S`.** `eval` is generic
over `S` and gets instantiated at least twice, and a function POINTER cannot be
generic over `S`. So the boundary is concrete. That is not a workaround: it is
§12.22.1 "Derivatives for analog system task/functions" and §12.32's `derivtf` /
`p_vpi_stf_partials`, arrived at from the opposite direction. A systf inside a
contribution is inside the residual, and **the residual must stay a pure
function of `x` or your Newton iteration cannot converge** — the same invariant
that keeps §9.5 file I/O and `$random` out of `eval`. A value with no derivative
would break it; a value with its derivative does not.

The call site reassembles the dual itself:

```zig
var zsr = S.con(host_value);
zsr = zsr.add(arg0.addC(-arg0_val).scale(partials[0]));   // value 0, slope p·d(arg)
```

so on the plain-f64 instantiation every graft term is exactly zero and the
residual reads your value; on the dual it also carries your slope.

### 4.2 It is not optional

```zig
comptime { contract.validateHost(@This(), D); }
```

in whatever type of yours declares `systf` — for ARPice that is
`src/devices/engine.zig`, beside `exportDevice`. It is a no-op for every device
that names no systf, so it costs nothing to add unconditionally, and adding it
unconditionally is the point: the day a model calls one, you find out at build
time instead of at the first Newton step.

`validateHost` is a `@compileError` if `D.systf_calls` is non-empty and you
declare no

```zig
pub fn systf(_: *const D.Model) ?*const contract.SystfHost
```

`validate(D)` cannot ask this — it runs where the *device* is defined, and a
`.va` compiled to a `.so` does not know which simulator will load it. The
requirement "somebody must implement this" only exists where the two meet.

**Failing your build is the right severity.** With no binding there is no value
— not a wrong one, an absent one. §12.32.3's listing never initializes
`sampler->value` before its first update callback, so the language fixes no
default to fall back to, and a device evaluating a systf nothing computed would
put a number out of thin air into your residual.

`vera --run` is a host too and is **not exempt**: `src/backend/tb.zig` binds a
`no_vpi_app` returning zero with zero partials, and calls `validateHost` on
itself. An exemption for the tool's own host is how a seam stops being tested.

### 4.3 What it does NOT give you

A systf is **not a device**. It has no ports, no terminals, no discipline, is
not netlist-referenceable and has no `.MODEL`. §12.22.2's example is called
`$resistor` and that is a trap — read it: the `.va` module is still what stamps.

```verilog
analog begin
  current = 0.0;
  $resistor(current, V(p,n), r);   // your C fills a value + its d/dV
  I(p,n) <+ current;               // ← the MODULE is the device
end
```

To define a device from C, write to this contract. That is the door; VPI is a
different one into a different room.

## 5. Rules a host must not break

1. **`eval`/`q` are pure functions of `x`.** No I/O, no RNG draw, no clock read,
   no systf without derivatives. Break it and Newton chases a moving target.
   This is why §9.4 display, §9.5 file I/O and `$random` all live in the
   per-accepted-point phase (`display`, `updateState`) and not in the residual.
2. **4-state values do not go in `U`.** A logic value is not a number; putting
   one there forces `eval` to branch on `S.val()`, which the protocol forbids.
3. **Model blobs get copied; `Instance` does not.** The `.so` seam copies
   `Model` through your loader, so a `Model` field must be POD. `Instance` may
   hold exactly one pointer into you — `systf` — and the contract admits that
   type by name rather than by shape, precisely so nothing puts a pointer in
   `Model`.
4. **`derive` runs after you finish writing the card**, before you build an
   `Instance`. A §6.3.4 parameter defined over another one has no value until
   then, and a §3.4.5 localparam is re-derived unconditionally.
5. **Compare `layout_hash`** before trusting a `.so`.

## 6. Degraded paths that are conformant

Not every optional hook is a debt on you. Declining these is a correct answer,
not a fudge:

- **No `noisePsd`** — you fall back to reading 4kT·g off the Jacobian you
  already have. That covers `.thermal`. §4.6.4.2's `kf·I^af / f^ef` is not in a
  Jacobian, so a `.flicker` row in `noise_gens` is topology you are told about
  and a PSD you must decline. (Codegen emits no `noisePsd` today either, so
  there is nothing to call yet — `noise_gens` is the whole §4.6.4 surface.)
- **No file table for §9.5** — §9.5.1 reserves 0 as `$fopen`'s failure return. A
  device whose host offers no files genuinely cannot open one, so 0 is the
  correct answer and every later operation on it is a no-op with a defined
  result (§9.5.4.1, §9.5.7, §9.5.8).
- **No `u_abstol`** — you invent one tolerance for every unknown. Slower
  convergence, not a wrong answer.
- **No `u_nodeset`** — you start the solve wherever you would have started it.
  §3.6.3.2 makes the declared value "a nodeset value for the potential of the
  net by the analog solver": an initial guess, never a constraint. Reading it
  can only change how many Newton steps you take — and which solution you land
  on if the circuit has more than one, which is exactly what the model author
  wrote it for. `null` means that unknown was given no value; 0.0 is a real
  nodeset and must not be confused with it. Do NOT treat it as an initial
  condition — §5.10.2's `initial_step`/`.ic` is a value the solve must HOLD,
  and this one it must be free to leave.

Declining `systf` is **not** on this list. See §4.2.

## 7. Ceilings you inherit

Written at their sites with a `ponytail:` comment and an upgrade path. The ones
that change what a host can do:

- **`|U| <= 256`** — `U` is `enum(u8)`. E1003 past it. Upgrading to `enum(u16)`
  is an ABI break: every linked host recompiles.
- **`absdelay`** — fixed 32-sample history, linear interpolation.
- **§4.6.4.3/.4 `noise_table` / `noise_table_log` are CONSTANT tables only.**
  They export as `NoiseGen.kind = .table` plus the entry
  `noise_tables[gen.table.?]` — `{ interp: .linear | .log, points: []const
  [2]f64 }`, ascending in frequency, unique, validated by `contract.validate` —
  and `contract.noiseTableAt(t, f)` is the clause's own interpolation, clamped
  to the end powers outside the table's range. Such a row's `PsdTerm` reads
  all-zero, so `white + flicker/f^ef + table` is one formula for every kind.
  The ceiling is that the points are COMPTIME data: the clause's file form and
  its array-parameter form are both E0519, the latter because a model card may
  override a parameter after this compiler has gone and folding the default
  would ignore it in silence. Upgrade path for both: build the points into
  `Model` in `derive` and export an accessor instead of an array.
- **§4.6.4.6 correlated noise is not expressible.** Sharing one generator
  between contributions needs a `source` field on `NoiseGen`, and there is
  none — two `.thermal` rows are indistinguishable from two independent
  generators. Graded by
  `tests/fixtures/ch04_expressions/150_noise_source_through_variable.va`
  (XFAIL).
- **A noise source assigned to a variable and then contributed** exports
  nothing — the export walks the contributed expression, and by then the source
  is an identifier. Same fixture; the two halves land together.
- **GPU kernel emission is always empty.** `Artifact.gpu_kernel_paths` is a
  declared field with no producer; emission lives in the host.
- **The `.so` build is one `build-lib` per device**, no batching.

## 8. Checking your work

```
zig build test           # engine + suite machinery
zig build test-contract  # the contract's own checks, including validateHost
zig build torture        # 1164 LRM fixtures, compiled AND RUN
zig build conformance    # the same fixtures against another compiler
zig build torture -- --coverage   # LRM clauses cited, one-sided, uncited
```

`tests/fixtures/**.va` state what the **LRM** requires, not what VerA does, so
they are a conformance suite for any Verilog-AMS compiler — and for a host, the
torture runner is a worked example of one: `src/backend/tb.zig` builds a real
Newton solve on the residual a device stamps, with the Jacobian its own dual
arithmetic carries and a dense LU under it. If you are unsure what a hook is
supposed to do, that file calls it.

## 9. Checklist for a host

Everything a simulator has to do, in the order it has to do it. Items 1–4 are
what ARPice already does; **item 5 is the one it does not**, and is the reason
this file exists.

1. Depend on `vera`; import the `vera` and `contract` modules, and reach
   `tools/contract.zig` as a PATH for the child `zig`.
2. Provide a `dyn` module exposing
   `pub fn exportDevice(comptime D: type, comptime name: []const u8) void`, and
   list `contract` and `dyn` in `orchestrator.Options.modules` **in a fixed
   order** — the order is hashed into `layout_hash`.
3. Write the host-owned `Instance` fields you support (§3.4), and convert
   `analysis_kind` by ordinal. Probe with `@hasField`; the contract pins the
   names and types so a typo fails rather than reading null.
4. Instantiate `S` twice — plain f64 for the residual, a dual for the Jacobian —
   over the primitive set in §3.2. Never call `eval`/`q` for anything but a pure
   function of `x` (§5.1).
5. **Declare `systf` and call `contract.validateHost(@This(), D)`** (§4). Until
   you do, a model that calls a `$name` this compiler does not define builds a
   device whose `Instance.systf` is null, and reaches it.
6. Compare `layout_hash` before trusting a `.so`.

`@hasDecl`-guard every optional hook (§3.3) and take the degraded path (§6)
where you decline one. `systf` is not among the ones you may decline.
