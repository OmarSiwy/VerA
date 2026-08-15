# VerA

A Verilog-A and Verilog compiler. One binary, two frontends, a shared device
backend.

```
vera model.va                       lint
vera --emit-zig -o dev.zig model.va generate a device
vera --run model.va                 build and run a testbench
vera gates.v                        translate Verilog
```

The frontend is picked from the file extension, so a build loop can walk a
directory of mixed-HDL models and call one tool.

## Frontends

| Source | Path |
|---|---|
| `.va` | in-process: preprocessor → lexer → parser → MIR/SSA → finiteness proof → codegen |
| `.v` | `verilator --json-only`, AST read back |
| `.sv` | `sv2v` → `.v` |
| `.vhd` `.vhdl` | `ghdl synth` → `.v` |

Only the Verilog-A path is self-contained. The Verilog family shells out —
`verilator` must be on `PATH`, plus `sv2v` / `ghdl` for those extensions. Without
them `zig build test` skips the 36 Verilog fixtures rather than failing.

## Backends

1. **Testbench executable** — `--emit-exe` / `--run`. The `//!` lines in a source
   declare operating points; ch9 display tasks become real prints and a
   generated runner drives the module over them.
2. **Shared object** — `--emit-so`. Needs `--dyn PATH`, the export shim supplied
   by the host simulator, since that shim is the simulator's ABI and not the
   compiler's.
3. **Synthesis** — not implemented. See below.

Both implemented backends emit Zig that imports the `contract` module
(`src/contract.zig`). That file ships here rather than in a consumer because it
is the codegen target; a simulator embedding VerA imports the same file, so there
is one definition of the ABI and no copy to drift.

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

Emitted RTL feeds the existing `.v` frontend, so synthesis closes a loop rather
than opening a new one: `.va` → RTL → verilator (back to a device) or yosys (to
gates).

## Embedding

```zig
const vera = b.dependency("vera", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("vera", vera.module("vera"));
exe.root_module.addImport("contract", vera.module("contract"));
// the CLI wants contract as a PATH, not a module:
run.addFileArg(vera.path("src/contract.zig"));
```

## Build

```
zig build                # the vera binary
zig build test           # unit tests + both conformance suites
zig build conformance    # Verilog-A fixtures vs .expected-error.txt
zig build exhaustive     # testbench transcripts vs .expected.txt (slow: spawns a compile per fixture)
zig build exhaustive -- --bless   # rewrite transcripts, then READ the diff
```

`docs/va/` is the Verilog-AMS LRM, chapter and annex, which the fixture tree in
`tests/va/fixtures/` is organized to mirror.
