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

The format is written up in the header of [`tools/contract.zig`](tools/contract.zig)
itself — required and optional decls, the scalar `S` protocol a host must
implement, and the rules physics code follows. Read it before writing a host or a
hand-written device; it sits beside `validate()`, which enforces every claim it
makes, so the two cannot drift. (This paragraph used to point at a
`docs/device-contract.md` that has never been committed.)

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
zig build conformance    # the same fixtures against OpenVAF (nix develop .#conformance)
```

`docs/*.html` is the Verilog-AMS LRM, one file per chapter and annex, which the
fixture tree in `tests/fixtures/` is organized to mirror.

## What is actually verified

1234 `.va` fixtures. Each states its own expected behavior in the file — `//!
reject <substring>` to demand a diagnostic, or a `CHECK` from `check.vh` whose
`ok=1` column is the assertion. There are no sidecar files.

They state what the **LRM** requires rather than what VerA does, so they are a
conformance suite for any Verilog-AMS compiler. One judge, `tests/harness.zig`,
and two runners plug into it: `tests/torture.zig` (VerA, in-process, builds and
RUNS each fixture) and `tests/external.zig` (any compiler that takes a `.va` path
and exits nonzero when it refuses one).

The suite replaced four runners (`conformance`, `exhaustive`, `sema`, `ledger`) that
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

A passing fixture is still not a claim that VerA is right where the fixture itself
records debt: a rejection the LRM does not sanction opens with a `DEBT` banner
naming the rule it violates. Three are left, down from 60 — the rest became real
requirements over seven waves. They stay green on purpose: a suite exists to
notice change, and a permanently-red fixture notices nothing.

Current, measured on this tree: **1234/1234 behave as they say they do, 0 XFAIL,
0 FAIL** (`--strict` passes), and no fixture asserts nothing. `/TODO.md` carries
the deliberate ceilings and the will-not-do list.

## VerA vs OpenVAF on the same fixtures — a wave-1 SNAPSHOT

**Every number in this section is from `bb2f60c`, when the suite was 1150 files and
VerA scored 812.** VerA's column is now 1150/1152 (above); OpenVAF's has not been
re-measured, and re-measuring one column alone would break the only thing the
table is good for, which is that both were scored by one judge on one tree. Re-run
`nix develop .#conformance` then `zig build conformance` before quoting it.

`openvaf-r` 2e06643 (OpenVAF-reloaded), `zig build conformance`, against `zig
build torture` on the same tree.

| | VerA | OpenVAF |
|---|---|---|
| behaves as the fixture states | **812** / 1150 | **778** / 1150 |
| outright FAIL | 0 | 372 |
| known unmet, `//! xfail` | 337 | — |
| cannot run (host limitation) | 1 | — |

**The two columns are not the same test, and VerA's is the harder one.** VerA is
compiled in-process, its device is built and executed, and every `ok=` column the
fixture computes is checked. OpenVAF is a subprocess that can only accept or
refuse a file, so its 778 means "compiled what must compile, refused what must be
refused" and no computed value was ever checked. The `//! reject` substrings are
VerA's diagnostic codes, which nobody else prints, so a rejection fixture only
requires that OpenVAF refused the file at all — and `//! xfail`, which is a
statement about VerA, is ignored for it.

Where the two disagree, per fixture:

| | count |
|---|---|
| both conform | 649 |
| only VerA conforms | 163 |
| only OpenVAF conforms | 129 |
| neither conforms | 209 |

OpenVAF's 372 split 61 / 311: **61** fixtures it accepts that the LRM says must
not compile, **311** it refuses that the LRM prints as legal (one of those by
running until a 30 s timeout, on `ch10_directives/46_macro_formal_must_be_simple_identifier.va`).
The 129 it conforms to and VerA does not are concentrated in `ch09_system_tasks`
(32), `ch03_data_types` (21), `ch04_expressions` (17) and `ch06_hierarchy` (11) —
that list was VerA's work queue, and it has since been worked off: 128 of the 129
were carried as an `//! xfail` with a reason, and the last was
`ch06_hierarchy/module_definition.va`, which had no port list and could not run at
all. Two xfails remain in the whole suite.

Neither number is a quality score for the other compiler: OpenVAF is a compact
model compiler for a simulator, and a large share of its 311 refusals are
constructs it deliberately does not implement (module instantiation, most of
chapter 9's file and display tasks, the mixed-signal chapter) rather than bugs.
What the table is for is that the same files measure both, so "VerA conforms here"
is a claim with an outside check on it.
