# The analog block

A module's behaviour lives in its **analog block**. This chapter covers what
runs there: variables, assignments, conditionals, loops, and printing. The
next chapters use these to build devices.

## A procedure, run at every iteration

`analog` is followed by one statement; `begin ... end` groups several into
one (LRM §5.2, §5.3). The statements run in order, top to bottom, like a
function body. What makes the block unusual is *when* it runs: the simulator
runs it at every point of the simulation, and at every Newton iteration
within a point, to evaluate the module's equations at its current guess of
the solution (LRM §5.2). It has no blocking delays or waits: it describes
continuous-time behaviour, and it must finish each time it starts.

This model is a conductance that saturates: it passes a current `g·v` while
the voltage stays within ±`vmax`, and a fixed `g·vmax` beyond that.

```verilog
{{#include ../examples/analog-block/clip.va}}
```

```console
{{#include ../examples/analog-block/clip.out}}
```

`//! sweep V(p) = -2, 0.5, 2` runs three operating points, one per value, and
the `$strobe` line prints at each. Both clipped points carry ±1 mA, as the
header comment derives.

## Variables

`real v, i;` declares two real variables: IEEE 754 doubles (LRM §3.2).
`integer` declares 32-bit two's complement integers. A real starts at 0, and
so does an integer assigned in an analog block; the analog block assigns
with `=` (LRM §5.7).

A variable is not a circuit quantity. `v = V(p, n);` copies the branch
voltage into `v` at this iteration; changing `v` later changes nothing in the
circuit. Only a **contribution**, `<+`, adds to the circuit's equations. That
is why the model computes `i` first, through whichever arm of the `if`
applies, and contributes it once at the end.

## Conditionals

`if`/`else if`/`else` chooses among statements (LRM §5.8). A contribution may
sit inside an arm. The LRM restricts what else may: the analog operators of
later chapters (`ddt`, `idt`, and the other filters) and event controls may
appear under a condition only when the condition is a constant expression,
one that depends on parameters alone (LRM §5.8.4).

`case` picks an arm by value (LRM §5.8.3), and `default` covers the rest:

```verilog
{{#include ../examples/analog-block/ladder.va}}
```

```console
{{#include ../examples/analog-block/ladder.out}}
```

`--param mode=1` overrides the parameter for one run; `mode` is the second
arm's selector, so the current doubles. ([Parameters](parameters.md) covers
overrides.)

## Loops

`for`, `while` and `repeat` work as in C (LRM §5.9). `ladder.va` sums the
conductances of `count` resistors of value `r`, `2r`, `3r`, and so on: with
three of them the bank conducts (1 + 1/2 + 1/3)/1 kΩ = 1.833 mS, and 0.5 V
draws 0.917 mA.

A loop may compute values, but it may not contribute, run an analog filter,
or wait for an event (LRM §5.9): how many times the body runs is only known
when the block runs, and a contribution's structure must be fixed before
then. VerA refuses the attempt:

```verilog
{{#include ../examples/analog-block/loop_contrib.va}}
```

```console
{{#include ../examples/analog-block/loop_contrib.out}}
```

(A `for` loop whose bounds are compile-time constants, using a `genvar`, may
contribute; LRM §5.9.3 calls it an analog `for` statement.)

## A note on W0650

`ladder.out` ends with a warning, W0650. Before it emits a device, VerA tries
to prove every contribution finite for every input. Here `g` is built up by a
loop, and VerA does not follow loops in that proof, so the contribution
compiles in Zig's strict float mode: correct, slightly slower. The warning
is about speed, not correctness. [Diagnostics](../using/diagnostics.md)
explains it and how to give the prover what it needs; this book leaves it
showing where it appears.

## Printing

`$strobe` prints when the simulator has converged on a solution (LRM §9.4),
so in a real simulation it prints once per accepted point, not once per
iteration. `$display` has the same format rules; `$write` omits the newline;
`$debug` prints at every iteration of the solver. The format strings follow
C's `printf`: `%g`, `%e`, `%f`, `%d`, `%s`.

A device inside a simulator does not print by itself: printing from the hot
loop of a circuit solver would cost more than the model. Instead it
*records* what each display task would print, and the simulator prints the
records once per accepted point (`--display=record`, the default for a
device). `--display=drop` compiles display tasks away entirely. A testbench
(`--run`, `--emit-exe`) is built with `--display=emit`, where the device
prints them itself. That is why the transcripts in this book print.

## Exercises

1. Rewrite the `for` loop in `ladder.va` as a `while` loop.
2. `ladder.va` recomputes `g` at every iteration, though it depends on
   parameters only. Move the loop into an `analog initial` block (LRM
   §5.2.1), which runs once before the simulation, and check that the
   current does not change.
3. Give `clip.va` separate limits, `vpos` above and `vneg` below, with
   `vneg = -0.25`. What does the −2 V point carry now?

<details>
<summary>Solutions</summary>

1. The loop variable needs its own increment:

```verilog
{{#include ../examples/analog-block/ladder_while.va}}
```

```console
{{#include ../examples/analog-block/ladder_while.out}}
```

2. `g` and `k` stay module variables, so the analog block can read what the
   initial block wrote:

```verilog
{{#include ../examples/analog-block/ladder_initial.va}}
```

```console
{{#include ../examples/analog-block/ladder_initial.out}}
```

3. The −2 V point is clipped at `g·vneg` = −0.25 mA:

```verilog
{{#include ../examples/analog-block/clip2.va}}
```

```console
{{#include ../examples/analog-block/clip2.out}}
```

</details>
