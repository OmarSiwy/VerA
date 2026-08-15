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
const vera = b.dependency("vera", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("va", vera.module("va"));            // Verilog-A engine
exe.root_module.addImport("contract", vera.module("contract")); // the ABI
// the CLI wants contract as a PATH, not a module:
run.addFileArg(vera.path("tools/contract.zig"));
```

`contract` lives in `tools/`, not `src/`, because nothing in the compiler imports
it: every reference is a string inside generated code or a path handed to a child
`zig`. It is compiled into *devices*, never into `vera`.

## Build

```
zig build                # the vera binary
zig build test           # unit tests + the conformance suite
zig build conformance    # Verilog-A fixtures vs .expected-error.txt
zig build exhaustive     # testbench transcripts vs .expected.txt (slow: spawns a compile per fixture)
zig build exhaustive -- --bless   # rewrite transcripts, then READ the diff
```

`docs/VAMS-LRM/` is the Verilog-AMS LRM, chapter and annex, which the fixture
tree in `tests/va/fixtures/` is organized to mirror.
