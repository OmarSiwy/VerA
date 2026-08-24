# Digital Verilog (IEEE 1364)

Verilog-AMS is a superset of IEEE 1364-2005 Verilog (LRM §1.1): the digital
half of the language, with its regs, wires, `initial` and `always` blocks and
event-driven scheduling, is plain Verilog. VerA compiles that half too. A
file ending in `.v` is digital Verilog, and `vera --run design.v` simulates
it.

This chapter is a short tour of the digital language for readers coming
from the analog side. It cites IEEE 1364-2005 clauses as "IEEE 1364-2005
§9.2".

## A clock and a counter

```verilog
{{#include ../examples/digital/counter.v}}
```

```console
{{#include ../examples/digital/counter.out}}
```

The pieces:

- `` `timescale 1ns/1ns `` sets the unit of a delay and the precision of
  simulated time (IEEE 1364-2005 §19.8). `#5` is 5 ns.
- `reg clk;` declares a variable that holds its value until a process
  assigns it again. `reg [3:0] count;` is four bits wide.
- An `initial` block runs once, from time 0; an `always` block runs again
  each time it finishes (IEEE 1364-2005 §9.9). `always #5 clk = ~clk;` waits
  5 ns and inverts the clock, forever.
- `@(posedge clk)` waits for a rising edge (IEEE 1364-2005 §9.7.2).
- `count <= count + 1` is a **nonblocking** assignment: the new value is
  computed now and written at the end of the time step (IEEE 1364-2005
  §9.2.2).
- `$display` prints a line (IEEE 1364-2005 §17.1.1), `$time` is the current
  time in the module's unit (§17.7.1), and `$finish` ends the simulation
  (§17.4.1). The last line of the transcript is VerA reporting where
  `$finish` was called and at which tick.

`--run` on a `.v` file runs VerA's event-driven engine directly, inside the
`vera` process: no Zig compiler is involved, so it starts at once.

## Blocking and nonblocking

The two assignment operators differ in *when* the target changes:

```verilog
{{#include ../examples/digital/swap.v}}
```

```console
{{#include ../examples/digital/swap.out}}
```

A blocking assignment `=` updates its target before the next statement
runs (IEEE 1364-2005 §9.2.1), so `b = a` reads the `a` that was just
overwritten. A nonblocking `<=` reads its right-hand side immediately and
schedules the write (§9.2.2), so both reads happen before either write and
the values swap. The rule of thumb that follows: use `<=` in clocked
`always` blocks, where every flip-flop must see the values from before the
edge, and `=` for combinational logic and temporaries.

## Four-state values

Every bit of a digital value is `0`, `1`, `x` (unknown) or `z` (high
impedance, an undriven wire) (IEEE 1364-2005 §4.1):

```verilog
{{#include ../examples/digital/xstate.v}}
```

```console
{{#include ../examples/digital/xstate.out}}
```

`r` was never assigned, so it is `x`; `w` has no driver, so it is `z`.
Arithmetic with an unknown operand is unknown in every bit, and `r == 0` is
neither true nor false: it is `x`.

## A compiled executable

`--run` interprets the design. `vera --emit-exe design.v` instead compiles
it, through Zig, into a native executable and prints its path; the
executable prints what `--run` would. Two flags shape that build:

- `--state=auto|2|4` picks the logic. `auto` (the default) simulates
  four-state until no `x` or `z` is live, then switches to the faster
  two-state code. `--state=2` (or `--two-state`) makes every `x` and `z` a
  `0` from the start. That is **not** IEEE 1364 four-state logic, and the
  same design can print different results:

```console
{{#include ../examples/digital/xstate2.out}}
```

- `--schedule=static|fifo` picks the order of events that happen at the same
  time. IEEE 1364-2005 §11.4.2 lets a simulator take active events off the
  queue in any order, so a design whose output depends on that order has a
  race (§11.5), and either answer is correct. `static`, the default,
  levelizes combinational logic; `fifo` keeps the interpreter's order. A
  design without races prints the same either way.

## Exercises

1. Change the counter into a decade counter: on the rising edge after 9 it
   goes back to 0. Run it long enough to see the wrap.
2. Swap two regs using only blocking assignments.

<details>
<summary>Solutions</summary>

1. An `if` inside the clocked block chooses between the two nonblocking
   updates. With `$finish` at 120 ns, the falling edges at 100 and 110 ns
   show the wrap:

```verilog
{{#include ../examples/digital/mod10.v}}
```

```console
{{#include ../examples/digital/mod10.out}}
```

2. A temporary holds the first value while it is overwritten:

```verilog
{{#include ../examples/digital/swap_tmp.v}}
```

```console
{{#include ../examples/digital/swap_tmp.out}}
```

</details>

The next chapter puts a digital process and an analog block in the same
design.
