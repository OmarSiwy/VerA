# VerA

A Verilog-AMS compiler that emits Zig. You hand it a `.va` device model, it hands
back a `device.zig` with `eval`, `jacobian` and `psd` entry points, which a circuit
simulator compiles into its own Newton loop as a shared library, a testbench, or a
GPU kernel.

Verilog-AMS 2023 is a superset of Verilog 1364-2005 and of Verilog-A, which the
standard discontinued in favour of AMS. VerA targets the 2023 LRM.

Pre-release. The only tag is `v0.0.1`, and the numbers below are measured, not
projected. Read [what works and what does not](#what-works-and-what-does-not)
before depending on it.

## Why emit source instead of machine code

The generated `eval` runs millions of times inside a host solver. That is the only
hot loop that matters, so it gets handed to a real optimising compiler as source
rather than being lowered here. Zig gives one backend that covers CPU, NVPTX and
AMDGCN from the same text, so the device that runs on a host core and the device
that runs on a GPU are the same emitted statements.

Derivatives propagate by composition through the emitted arithmetic, so the
Jacobian is not a separate symbolic pass that can drift from the residual.

## The pipeline

```
.va  ->  preprocess  ->  lex  ->  parse  ->  AST
                                              |
         elaborate (§6.2.2 hierarchy flattening)
                                              |
         lower + SSA  ->  MIR  ->  analysis  ->  proof  ->  if-conversion
                                              |
         codegen  ->  device.zig  ->  zig  ->  .so / testbench / kernel
```

`lib/frontend` does the first row, `lib/ir` the second, `lib/backend` the third.
`src/` is the CLI driver plus a separate digital Verilog-2005 interpreter that
shares the frontend and nothing else.

The proof pass is the unusual one. Before anything is emitted it checks the
§4.3.2 math-function domains and proves each analog unit finite, so a device that
would produce a NaN inside somebody else's Newton loop fails at compile time
instead.

## Build

Needs Zig 0.16.0.

```sh
zig build                          # debug
zig build -Doptimize=ReleaseFast   # what you actually ship
```

The binary lands at `zig-out/bin/vera`.

## Use

```sh
# generate the device
vera model.va --emit-zig -o device.zig

# type-check it here, so a codegen bug names the .va instead of
# surfacing three cache steps later as an error in generated code
vera model.va --check --contract tools/contract.zig

# all the way to a shared library
vera model.va --emit-so --contract tools/contract.zig

# build a self-checking testbench and run it
vera model.va --run --display=emit --contract tools/contract.zig -I tests/fixtures

# frontend only
vera model.va --lint

# what does E0310 mean
vera --explain E0310
```

Exit status is 0 on success (warnings do not fail), 1 on a diagnosed error, 2 on a
usage error. Conflicting flags are usage errors rather than last-one-wins.

`vera --help` lists every flag. The ones worth knowing:

`--jac-f32` records that the device tolerates a single-precision derivative half.
It emits a `pub const`, not different arithmetic: the width is the host's to pick,
and a host can take the permission on its GPU kernel while declining it on its CPU
path. `--outline-chunk=N` splits a huge body into `noinline` chunks, which is the
GPU lever described below. `--unknown-bound=X` tunes the solver compliance limit
behind the W0650 finiteness warning. `--spice PATH` reads a netlist alongside the
source so Annex E.2 `.MODEL` and `.SUBCKT` cards become instantiable modules.

## Conformance

Measured at `1789cb1` on 2026-09-21. Reproduce with the command in each row.

```
                                             pass / total
va fixtures behave as stated   95.4%  |######################################  |  1497 / 1570
spice decks pair with oracle  100.0%  |########################################|     7 / 7
vpi .c fixtures compile        50.0%  |####################                    |    13 / 26
lrm clauses, two-way evidence  32.2%  |#############                           |   197 / 612
ieee 1364 obligations closed   23.6%  |#########                               |    30 / 127
```

| Row | Command | Detail |
|---|---|---|
| va fixtures | `zig build benchmark -- --strict` | 45 FAIL, 28 XFAIL, 0 unasserted |
| lrm clauses | `zig build benchmark -- --coverage` | 256 accepted-only, 76 refused-only, 83 uncited |
| obligations | `docs/CLAUSE-AUDIT.md §7.1` | 65 missing, 20 partial, 10 without evidence, 2 untested limits |
| vpi | `zig build test-vpi-fixtures` | the 13 failures need §12.16 to §12.20, which the header lacks |
| spice | `zig build test-spice` | they pair and compile; none execute yet |

"Two-way evidence" means a clause has both a fixture that exercises it legally and
a fixture that gets refused for violating it. One-sided coverage is counted as a
gap, which is why that row is low: 257 clauses are accepted by the compiler with
nothing pinning what they rule out.

A head-to-head against another Verilog-A compiler exists as
`zig build benchmark -- --against-openvaf`, but no result from it is recorded in
this tree, so none is quoted here.

Run `zig build -Doptimize=ReleaseFast` before `benchmark`. The default debug build
is several times slower and is not the shipping number.

## Performance

### GPU compilation

The reason `--outline-chunk` exists. Measured on bsim4va with zig 0.16 and LLVM
21 at `-OReleaseFast`, targeting nvptx64:

| bsim4va core | NVPTX compile | PTX emitted |
|---|---|---|
| monolithic | 2 min 24 s | 1.2 GB |
| `--outline-chunk=300` | 1.3 s | 26 MB |

The monolithic version triggers a register-file spill storm in the NVPTX backend.
Chunking is roughly a hundredfold on both axes, so pass `--outline-chunk=300` when
a GPU kernel root will compile the model.

### Host eval, which is the other side of that trade

Per 1e6 bsim4va evaluations. Lower is better.

```
monolithic (default)   3.18 s  |#############
chunk 2000             5.87 s  |#######################
chunk 300, local vars  7.58 s  |##############################
chunk 300              9.99 s  |########################################
```

Chunking costs 1.8x to 3x at runtime because cross-chunk values live in the shared
hoist arrays where the monolith held them in registers. Chunk-local `var`s claw
some back and bigger chunks help, but no size met a 2% budget, so outlining is off
by default. The emitted statements are identical either way, verified bit-for-bit
on `f`, `q` and every partial across bsim4va, hisimhv and bsimsoi.

Build time moves the opposite direction. With debug info on, chunking is 2.6x to
3.5x faster (bsim4va 6.4 s to 2.3 s, hisimhv 14 s to 4.1 s). With `-fstrip`, which
is how release hosts build, it is neutral to slightly negative (1.35 s to 1.95 s):
the monolith's superlinear term was DWARF, and stripping already removes it.

### The compiler itself is not a SIMD target

Stated here because it looks like an obvious optimisation and it was measured and
rejected. `seedValues`' fill at `-OReleaseFast`, ns per fill, min of 25, with
`suggestVectorLength(f64)` = 4:

| n | 38 | 210 | 929 | 24578 |
|---|---|---|---|---|
| AoS `@memset` (ships) | 14.5 | 76.7 | 349.7 | 17174.6 |
| SoA 3x `@memset` | 14.1 | 70.6 | 320.5 | 10745.2 |
| SoA `@Vector` | 11.9 | 57.3 | 253.6 | 15615.8 |

The explicit vector store is 45% slower than `@memset` at 24578, the only length
where SIMD would have paid, and at the median corpus size (`mir.defs.len` median
26, p99 198) it wins 2.6 ns on a compile that takes about a millisecond. Every
backend walk here is a chain anyway: a dominator-tree traversal, a data-dependent
output length, recursive SSA construction.

SIMD belongs in the emitted device, where `backend/tb.zig` does use
`@Vector(NL, f64)`. That is the loop this project exists to make fast.

## What works and what does not

Working:

- Verilog-A parsing, elaboration, lowering and device codegen, exercised by every
  one of the 1497 passing fixtures
- Testbench generation, including the self-checking `check.vh` assertion macros
- The §8.3 shared-library ABI and its orchestrator
- Unit tests across all modules (`zig build test`)
- NVPTX and AMDGCN codegen paths
- SPICE deck ingestion for Annex E.2 `.MODEL` and `.SUBCKT`

Not working, in rough order of how much is missing:

- Chapter 7 mixed-signal. There is no analog-to-digital or digital-to-analog
  wiring and no scheduler coordination between the two engines. 46 fixtures sit
  here.
- `zig build test-devices`, the digital transcript diff, currently fails.
- VPI beyond the §11 object model. Value access and callbacks (§12.16 to §12.20)
  are absent from `src/vpi/vpi_user.h`, which is what half the C fixtures need.
- SPICE decks validate but do not execute, because the simulator that would run
  them is not in this repository.
- 7 of the 9 planned refactor phases.

The testbench uses a fixed grid over the operating points a source declares in its
`//!` header lines. There is no adaptive timestepping, because timestepping is the
host simulator's job.

## Tests

```sh
zig build test                              # unit tests, every module
zig build test-frontend                     # or any single module
zig build benchmark -- --strict             # the fixture suite
zig build benchmark -- --coverage           # lrm clause coverage
zig build test-devices                      # digital .v transcripts
zig build test-vpi-fixtures                 # the .c vpi fixtures
zig build test-spice                        # the .sp decks
```

Fixtures live under `tests/fixtures/ch01..ch12` and `tests/fixtures/annex_a..h`,
and each one names the clause it tests in its header:

```verilog
//! lrm 4.2.1.3
//! bias V(p) = 0.75, V(n) = 0.25
//! reject E0310
`include "check.vh"
```

`//! reject CODE` means the fixture must fail with that diagnostic. `//! xfail`
marks a known gap, and the harness fails on an unexpected pass so a marker cannot
outlive the bug it describes.

Before you "fix" a failing fixture, check that the fixture is right. `AGENTS.md`
§6 lists four cases where a conforming implementation is the thing that fails the
test.

## Documentation

`AGENTS.md` is the working guide: module layering rules, the SIMD ceiling, fixture
traps, and the hazards of running parallel agents in shared worktrees.
`docs/ROADMAP.md` holds the release ladder and the measured state each gate is
judged against. `docs/CLAUSE-AUDIT.md` is the per-obligation register of what is
still open. `docs/PLAN.md` is the current work breakdown. The LRM itself is in
`docs/`, as a PDF and as per-chapter HTML.

## Layout

```
lib/frontend/   preprocessor, lexer, parser, AST
lib/ir/         elaborate, lower, SSA, MIR, analysis, proof, if-conversion
lib/backend/    codegen, naming, the embedded kernels, testbench template,
                shared-library orchestrator
lib/diag.zig    the diagnostic catalogue behind --explain
src/main.zig    the CLI
src/sim/        digital Verilog-2005 interpreter
src/vpi/        §11 VPI object model
tools/          contract.zig, the conformance and baseline scripts
tests/          the harness, the torture runner, and the fixtures
```

`build.zig` declares the module graph and panics at configure time if `lib/`
imports `src/` or if a module's dependency order is violated.

## License

No license file yet. Until one lands, all rights are reserved.
