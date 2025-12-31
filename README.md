# VerA

A Verilog-A compiler. One binary, one self-contained frontend, a device backend.

```
vera model.va                       lint
vera --emit-zig -o dev.zig model.va generate a device
vera --run model.va                 build and run a testbench
```

## Frontend

`.va` in-process, no external tools: preprocessor → lexer → parser → MIR/SSA →
finiteness proof → codegen.

### Verilog is not here right now

There was a second frontend for `.v` / `.sv` / `.vhd`, shelling out to
`verilator --json-only` / `sv2v` / `ghdl synth`. It was removed rather than kept
limping, because it had no IR: the translator read verilator's JSON AST and
spliced **Zig statements as strings** into a codegen template, so it shared
nothing with the Verilog-A side but the device contract. Nothing could be reused
across the two, in either direction.

Verilog returns through a shared IR that both frontends lower into, and that
backends read to emit either a simulator device or a netlist. That is the same
seam backend 3 needs, so the two jobs are one job. Until then `vera` rejects
those extensions by name instead of failing to parse them.

## Backends

1. **Testbench executable** — `--emit-exe` / `--run`. The `//!` lines in a source
   declare operating points; ch9 display tasks become real prints and a
   generated runner drives the module over them.
2. **Shared object** — `--emit-so`. Needs `--dyn PATH`, the export shim supplied
   by the host simulator, since that shim is the simulator's ABI and not the
   compiler's.
3. **Synthesis** — not implemented. See below.

Both implemented backends emit Zig that imports the `contract` module
(`tools/contract.zig`). That file ships here rather than in a consumer because it
is the codegen target; a simulator embedding VerA imports the same file, so there
is one definition of the ABI and no copy to drift.

The format is written up in [`docs/device-contract.md`](docs/device-contract.md)
— required and optional decls, the scalar `S` protocol a host must implement,
and what ends up in the `.so`. Read it before writing a host or a hand-written
device.

## Backend 3, and why it is not here yet

Verilog-A is continuous-time; synthesizable RTL is discrete-time. There is no
general mapping, so this splits in two:

**The digital subset** — `@(cross)`, `@(timer)`, `analog event`, and models that
are really behavioral digital (comparators, ADC/DAC boundary models, dividers).
These map to RTL directly. The gate is a *synthesizability predicate*, which is
the same shape as the finiteness proof `proof.zig` already runs.

**Fixed-point datapath** — everything else. Needs range/precision analysis over
MIR to choose word lengths, a discretization for `ddt`/`idt` at a declared sample
rate, transcendental lowering (`exp`/`log`/`sqrt`/`pow` to LUT+interpolation or
CORDIC), and a clock/reset/valid convention.

Emitted RTL wants to come back in as a device, which is why this and the Verilog
frontend are the same piece of work: both need one IR that a frontend lowers into
and a backend reads out of. `.va` → shared IR → netlist, and `.v` → shared IR →
device, are the two directions of one seam.

## Embedding

```zig
const dep = b.dependency("vera", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("vera", dep.module("vera"));         // the Verilog-A engine
exe.root_module.addImport("contract", dep.module("contract")); // the ABI
// the CLI wants contract as a PATH, not a module:
run.addFileArg(dep.path("tools/contract.zig"));
```

`contract` lives in `tools/`, not `src/`, because nothing in the compiler imports
it: every reference is a string inside generated code or a path handed to a child
`zig`. It is compiled into *devices*, never into `vera`.

## Build

```
zig build                # the vera binary
zig build test           # unit tests
zig build torture        # every fixture: compile, run, check its own assertions
zig build torture -- ch04       # only paths matching `ch04`
zig build torture -- --strict   # fixtures that assert nothing FAIL instead of warn
```

`docs/VAMS-LRM/` is the Verilog-AMS LRM, chapter and annex, which the fixture
tree in `tests/fixtures/` is organized to mirror.

## What is actually verified

One suite, `tests/torture.zig`, over 857 `.va` fixtures. Each states its own
expected behavior in the file — `//! reject <substring>` to demand a diagnostic,
or a `CHECK` from `check.vh` whose `ok=1` column is the assertion. There are no
sidecar files.

It replaced four runners (`conformance`, `exhaustive`, `sema`, `ledger`) that
disagreed about what a fixture is and needed three sidecar formats between them.
Three of the four could not answer the only question that matters — does the
generated device compute the right number? — because they never ran it.

**The want is a literal, and that is the whole design.** The old oracle was
VerA's own recorded output, so a wrong answer once recorded stayed frozen as
correct and a reviewer's only job was to accept a diff they had no way to check.
Now a fixture asserts against a number a human derived from the LRM, and
`torture.zig` refuses a want that is anything but a numeric literal — an
expression would let VerA supply its own expectation. See
`tests/fixtures/README.md`.

A passing fixture is still not a claim that VerA is right where the fixture
itself records debt: 60 rejections the LRM does not sanction open with a `DEBT`
banner naming the rule they violate. They stay green on purpose — a suite exists
to notice change, and a permanently-red fixture notices nothing.

Known blocker: a module with no port list is legal per Annex A.1.2 and compiles,
but `contract.validate` refuses the emitted device with `num_ports must be in
1..|U|`, so ~29 fixtures cannot be run at all until that is fixed in the engine.
