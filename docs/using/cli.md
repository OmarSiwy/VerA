# The command line

`vera` takes one source file and a mode. A `.va` (or any non-`.v`) file is
Verilog-AMS and goes through the analog compiler; a `.v` file is digital
IEEE 1364 Verilog and goes through the event-driven engine, and may be
followed by more `.v` files holding the library cells it instantiates.

```text
vera [options] FILE.va
vera --run|--emit-exe [options] FILE.v [MORE.v ...]
vera --emit-zig|--check|--emit-so [options] FILE.v [MORE.v ...]
vera --explain CODE
```

## Exit status

| Status | Meaning |
|---|---|
| 0 | success; warnings do not fail |
| 1 | a diagnosed error in the source, or a failed build |
| 2 | a usage error: an unknown or malformed flag, or two flags that conflict |

Conflicting flags are refused by name whatever order they come in; a later
flag never silently wins over an earlier one of another kind.

## Modes

| Flag | What it does | Needs `zig` |
|---|---|---|
| `--lint` | parse, elaborate, lower and prove; generate nothing | no |
| `--emit-zig` | write the device's Zig source to stdout, or to `-o PATH` | no |
| `-o PATH` | implies `--emit-zig`, writing to `PATH` | no |
| `--emit-verilog` | a behavioural Verilog model of a `.va`, for digital simulators | no |
| `--check` | generate the device and type-check it with Zig against the contract, running the contract's conformance checks | yes |
| `--emit-exe` | build a self-checking testbench from the source's `//!` directives (or a `.v` design's executable) and print its path | yes |
| `--run` | `--emit-exe`, then run it; the testbench's exit status is `vera`'s | yes |
| `--emit-so` | build the device as a shared library for your simulator, through your `--dyn` module | yes |
| `--emit-osdi` | build the device as an OSDI 0.4 library that ngspice loads with `pre_osdi` (`--emit-so` under the `tools/osdi_dyn.zig` built into `vera`); `-o PATH` names it, default `<module>.osdi`, and its path is printed | yes |
| `--explain CODE` | print the long explanation of a diagnostic code | no |

With no mode flag, `vera FILE.va` is `vera --lint FILE.va`.

`--emit-exe` prints the artifact's path on **stdout** and every diagnostic on
**stderr**, so `P=$(vera --emit-exe model.va)` captures only the path.
Testbenches are covered in [Testbenches and `//!` directives](testbenches.md),
`--emit-so` in [Shared libraries, validation and GPUs](../host/linking.md),
`--emit-osdi` in [OSDI interoperability](../host/osdi.md), and
`--emit-verilog` below.

## Source options

| Flag | Meaning |
|---|---|
| `-I DIR` | add a directory to the `` `include `` search path (repeatable, in order) |
| `--param NAME=VALUE` | compile with top-module parameter `NAME` set to `VALUE` (LRM §3.4). A parameter that sizes an array or selects a generate arm is fixed at that value; any other stays a value the model card can change |
| `--spice PATH` | read a SPICE netlist; its `.MODEL` and `.SUBCKT` cards become modules the source can instantiate (LRM Annex E.2) |
| `--std=SPEC` | the source language, as a `` `begin_keywords `` specifier: `1364-1995`, `1364-2001`, `1364-2005`, `VAMS-2.3` or `VAMS-2023` (the default). A 1364 language frees every AMS keyword as an identifier |
| `--no-std-defs` | do not prepend the LRM Annex D prelude (`disciplines.vams`, `constants.vams`) |
| `--discipline-resolution=basic\|detail` | LRM §7.4.4's mode for undeclared interconnect (default `basic`; `detail` is Annex F.2.2) |
| `--libmap FILE`, `-L LIB` | a `.v` design's IEEE 1364-2005 §13 libraries: a library map file (repeatable), and the libraries an instance's cell is searched in |
| `--expect-module=NAME` | fail unless the compiled module is called `NAME` |

`` `include "disciplines.vams" `` and `` `include "constants.vams" `` always
resolve to VerA's built-in copies of LRM Annex D, so a model needs no files
beside it.

## Diagnostics

| Flag | Meaning |
|---|---|
| `--diagnostics=text\|json` | how to report; `json` is one object per diagnostic for tools |
| `--color=auto\|always\|never` | colour in text diagnostics. `--explain` colours unless `--color=never` comes **before** it |
| `--allow=CODE`, `--warn=CODE`, `--deny=CODE`, `--forbid=CODE` | per-code lint level. An error code cannot be allowed |
| `--unknown-bound=X` | the solver compliance limit, in volts or amps, behind the W0650 finiteness proof (`vera --explain W0650`) |

[Diagnostics](diagnostics.md) explains the format and the levels.

## Build options

These matter to `--check`, `--emit-exe`, `--run` and `--emit-so`.

| Flag | Meaning |
|---|---|
| `--zig PATH` | the Zig compiler to run (default: `zig` on `PATH`) |
| `--optimize=MODE` | `Debug`, `ReleaseSafe`, `ReleaseFast` or `ReleaseSmall`. Default: Debug for a testbench, ReleaseFast for `--emit-so` |
| `--zig-backend=auto\|llvm\|native` | `auto` uses Zig's own x86_64 backend for Debug builds on x86_64 (fast to compile), LLVM otherwise. `native` does not optimise |
| `--debug-info` | keep DWARF in a ReleaseFast or ReleaseSmall artifact (stripped by default) |
| `--work-dir DIR` | where sources and artifacts are written (`--emit-so` requires it; testbenches default to `.zig-cache/vera-tb`) |
| `--contract PATH` | the `contract` module to build against (default: the copy built into this `vera`) |
| `--dyn PATH` | your host's `dyn` module, which exports the device (`--emit-so`) |
| `--validate-contract` | run the contract's conformance checks inside an `--emit-exe`/`--run` testbench (`--check` always runs them) |

## Device options

| Flag | Meaning |
|---|---|
| `--jac-f32` | mark the device as tolerating a single-precision Jacobian. It emits `pub const jac_f32 = true`, not different arithmetic: the host decides |
| `--jac-f32-host` | and ask the host to use it on its CPU path too |
| `--display=record\|drop\|emit` | LRM chapter 9 display tasks (`$strobe`, `$display`, ...). `record` (the default): the device records them, and its host prints the records once per accepted point. `drop`: compiled to nothing. `emit`: the device prints them itself, which is what `--emit-exe` and `--run` default to; with `--display=record` a testbench prints the device's records instead |

## Digital options (`.v` designs)

| Flag | Meaning |
|---|---|
| `--schedule=static\|fifo` | order of same-time events: combinational logic levelized (`static`, the default; IEEE 1364-2005 §11.4.1) or the interpreter's order |
| `--state=auto\|2\|4` | `auto` (default) simulates 4-state until no x or z is live, then 2-state; `4` always 4-state; `2` makes every x or z a 0, which is **not** IEEE 1364 4-state logic (E1101) |
| `--two-state` | `--state=2` |
| `--event-budget=N` | events allowed at one time step before a zero-delay loop is refused (default 10000000) |

## `--emit-verilog`

`vera model.va --emit-verilog -o model_beh.v` writes a behavioural Verilog
stand-in of an analog model, for digital simulators (Icarus Verilog,
Verilator). It keeps the module's name and port order. Digital pins become
logic; each net the model drives switches at VDD/2 after its own RC time
constant (τ·ln 2) plus any `transition` or `absdelay` delay; analog pins stay
undriven `inout wire`s.

| Flag | Meaning |
|---|---|
| `--digital-pins LIST\|FILE` | the ports that are logic: a comma- or space-separated list, or a file of names. `(* vera_pin = "digital" *)` on a port declaration says the same in the source |
| `--power-pins` | put the supply pins under `` `ifdef USE_POWER_PINS `` |
| `--vdd=X` | the logic-high potential in volts (default 1.8) |

`(* vera_pin = "digital"|"analog"|"power"|"ground" *)` and
`(* vera_delay = 2n *)` may be written on a port's direction declaration or a
net's declaration. Event-driven models (`@(cross ...)`, held variables) are
refused, since a combinational stand-in cannot reproduce them.

## The full list

This is `vera --help`, run against the current tree:

```console
{{#include ../examples/using/help.out}}
```
