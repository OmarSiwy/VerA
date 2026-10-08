# Mixed signal: discrete nets and connect modules

The last two chapters described two different worlds. An analog block
computes continuous quantities, solved at whatever time points the
simulator picks. A digital process computes discrete values that change
only at events, at integer multiples of a time unit. Verilog-AMS lets one
design use both, and defines how they talk (LRM chapter 7).

Every value belongs to a **domain**, continuous or discrete (LRM §7.2.1),
and which one is decided by where it is assigned: an assignment in an
`analog` block is in the continuous **context**, one in an `initial` or
`always` block in the discrete context, and "it shall be an error to assign
to a given variable in both contexts" (LRM §7.2.2). Reading is free: either
side may read the other's nets and variables. This chapter shows the three
ways the two sides meet, from the simplest.

## Reading a digital value in an analog block

A one-bit digital-to-analog converter: a digital process owns the `reg`
`q`, and the analog block reads it to set an output voltage:

```verilog
{{#include ../examples/mixed-signal/dac.va}}
```

```console
{{#include ../examples/mixed-signal/dac.out}}
```

A discrete bit reads as an integer in the continuous context (LRM §7.3.1,
Table 7-1), so `q == 1` is an ordinary integer comparison. The analog block
does not watch `q`: it reads whatever `q` holds when it runs.

A design with a digital half runs on VerA's **mixed-signal runner** rather
than the fixed-grid testbench of the earlier chapters. It runs the digital
events and the analog solves in time order, and it adds a time point
wherever an event needs one: here the point at 5 ns, when `q` changes,
which the `//! time` list does not contain.

## Detecting an analog event in digital code

The other direction: a digital process woken by an analog event.
`always @(cross(...))` is legal in a digital block, and the event's
arguments are evaluated in the continuous context (LRM §7.3.5):

```verilog
{{#include ../examples/mixed-signal/comparator.va}}
```

```console
{{#include ../examples/mixed-signal/comparator.out}}
```

This is where the mixed-signal runner differs most from the analog
testbench. `V(in)` crosses 0.6 V at 15 ns and again at 36 ns, between the
listed points, and the runner finds both crossings and inserts a point just
after each, as LRM §5.10.3.1 asks of `cross`: the event "shall occur after
the threshold crossing". The digital `$display` prints the digital time,
in the `` `timescale `` unit of 1 ns.

## Connect modules

In the examples so far, one module held both halves. In a real design the
digital and analog parts are separate modules, and a net can be driven by a
digital output in one module and loaded by an analog block in another. Such
a net is **mixed**, and the language bridges it with a **connect module**:
a module, declared with `connectmodule`, that converts between a discrete
discipline on one port and a continuous one on the other (LRM §7.5, §7.6).
You write the connect modules and a `connectrules` block that says which
to use; the elaborator then inserts one wherever a mixed net needs it
(LRM §7.7, §7.8):

```verilog
{{#include ../examples/mixed-signal/connect.va}}
```

```console
{{#include ../examples/mixed-signal/connect.out}}
```

`driver` knows only logic; `top` knows only electrical. Neither instantiates
`d2a`: VerA found the mixed port `u1.q`, matched its disciplines and
direction to `d2a`'s ports (a `ddiscrete` input, an `electrical` output),
and inserted it. The voltage is the header's: 0 V before 5 ns, and the
divider's 0.9 V after.

The connect module is an ordinary model, so its accuracy is yours to
choose: this one is an ideal source behind 1 kΩ. A production D2A adds
rise and fall times with `transition`; an A2D compares against thresholds,
often with `above` or `cross`.

## What VerA does not do yet

The mixed-signal path runs the cases above, with limits a design can meet:

- A digital value written as a result of an analog event is seen by the
  analog side from the next point on; the finished analog point is not
  solved again.
- `driver_update` and the other driver-access functions (LRM §9.22) keep
  one bit of state per driver, so a vector `signal_name` is refused.
- The mixed runner, like the analog testbench, steps with backward Euler and
  no truncation-error control. It is for checking a model's behaviour, not
  for accurate waveforms.

[Implementation-defined choices](../using/implementation.md) lists every
choice VerA makes where the LRM leaves one open, including the mixed-signal
ones.

## Exercises

1. The connect statement may pass parameters to the connect module it
   inserts (LRM §7.7.3). Make `d2a` drive a 3.3 V logic family without
   editing `d2a` itself. What does `V(a)` read after 5 ns?

<details>
<summary>Solution</summary>

1. `connect d2a #(.vdd(3.3));`. The divider halves 3.3 V, so `V(a)` reads
   1.65 V:

```verilog
{{#include ../examples/mixed-signal/connect33.va}}
```

```console
{{#include ../examples/mixed-signal/connect33.out}}
```

</details>
