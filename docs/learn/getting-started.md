# Getting started

This chapter installs VerA, compiles a first model, and runs it. Along the
way it shows the four things you will do with every model in this book:
lint it, look at the Zig it becomes, run it in a testbench, and read a
diagnostic.

## Installing

You need `vera` and Zig 0.17.0. [Installing](../using/install.md) has the
details; the short version, from a checkout:

```sh
zig build -Doptimize=ReleaseFast
export PATH=$PWD/zig-out/bin:$PATH
```

## A first model

Verilog-AMS describes a circuit element by the equations it adds to the
circuit. A resistor says that the current through it is the voltage across it
divided by its resistance. Save this as `resistor.va`:

```verilog
{{#include ../examples/getting-started/resistor.va}}
```

Line by line:

- `` `include "disciplines.vams" `` brings in the standard **disciplines**
  (LRM Annex D.1). `electrical` is one: it says a node carries a potential
  `V` in volts and a flow `I` in amperes. VerA has the file built in.
- `module resistor(p, n);` declares a module with two **ports**, `p` and `n`
  (LRM §6.2).
- `inout p, n;` gives the ports a direction, and `electrical p, n;` gives them
  the discipline, which makes them analog nodes (LRM §3.6).
- `parameter real r = 1k from (0:inf);` declares a parameter with a default of
  1 kΩ (`1k` is a scale factor, LRM §2.6.2) and a **range**: any positive
  value (LRM §3.4.2). A simulator's model card may change it; a value outside
  the range is refused.
- `analog I(p, n) <+ V(p, n) / r;` is the model. `V(p, n)` reads the voltage
  from `p` to `n`, and `I(p, n) <+` **contributes** a current through the
  branch between them (LRM §5.6). The `analog` keyword makes this the
  module's analog block, evaluated at every iteration of the simulator's
  solver.

Check that it is legal Verilog-AMS:

```console
{{#include ../examples/getting-started/lint.out}}
```

No output and exit status 0: the model parses, elaborates, and passes VerA's
checks. `--lint` stops there and writes nothing.

## The device it becomes

VerA's output is Zig source. A simulator compiles it into its own solver loop,
so the generated file is the model's whole runtime:

```console
{{#include ../examples/getting-started/emit.out}}
```

`eval` is generic over `S`, a *scalar family* the simulator chooses. Each
value in the device carries its value and its derivatives with respect to
the circuit's unknowns, so one call returns the residual and its exact
Jacobian. The [simulator authors' part](../host/device.md) of this book
describes the generated device in full; you do not need it to write models.

## Running it

To see a model compute, VerA can build a **testbench**: a small program that
sets the model's unknowns, calls the device, and prints what it reports.
Directives in `//!` comments say where to evaluate it. Here, `//! bias V(p) =
2.0` holds `p` at 2 V; `n` is not named, so the testbench ties it to 0 V:

```verilog
{{#include ../examples/getting-started/hello.va}}
```

`$strobe` prints a line each time the analog block runs (LRM §9.4). Run it:

```console
{{#include ../examples/getting-started/hello.out}}
```

`--run` generated the device, generated a testbench around it, compiled both
with Zig, and ran the result. 2 V across 1 kΩ is 2 mA, as the model says.
[Testbenches and `//!` directives](../using/testbenches.md) lists every
directive; later chapters introduce them as they need them.

## When something is wrong

Misspell the parameter:

```verilog
{{#include ../examples/getting-started/typo.va}}
```

```console
{{#include ../examples/getting-started/typo.out}}
```

Every diagnostic has a code, a location, the LRM clause behind the rule, and
often a suggestion. `vera --explain CODE` prints the long form. Exit status 1
means the source has an error; 2 means the command line does.

## Exercises

1. Change the bias to `V(p) = -1.5` and predict the current before you run
   it.
2. Give `r` a value outside its range with `vera --run --param r=-5
   hello.va`. What does VerA say, and which clause does it cite?
3. Add a second parameter `g`, a conductance in siemens, and make the
   contribution `V(p, n) * g + V(p, n) / r`. Run it with `--param g=1m`.

<details>
<summary>Solutions</summary>

1. −1.5 mA: the contribution is linear, so the sign follows the bias.
2. See the transcript below: a parameter outside its declared range is
   refused (LRM §3.4.2).
3. With `r` = 1 kΩ and `g` = 1 mS, the two halves add: 2 V gives 4 mA.

```console
{{#include ../examples/getting-started/range.out}}
```

</details>
