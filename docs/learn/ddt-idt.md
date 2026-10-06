# Time: ddt and idt

Resistors relate a voltage to a current at the same instant. Capacitors and
inductors relate a voltage to how fast a current changes, or the reverse.
Verilog-AMS writes them with two **analog operators**: `ddt`, the time
derivative, and `idt`, the time integral (LRM §4.5.3, §4.5.4). An analog
operator keeps state from one time point to the next, which is new: until
now, every model computed its outputs from the present solution alone.

## A capacitor

The current into a capacitor is `c · dV/dt`:

```verilog
{{#include ../examples/ddt-idt/cap.va}}
```

```console
{{#include ../examples/ddt-idt/cap.out}}
```

`//! time` lists the time points, which makes the run a transient analysis,
and `//! wave V(p) = 0, 1, 2, 3` gives `p` one value per point. Between
points, the testbench lets the device record its state, so `ddt` can see where
`V(p, n)` was at the previous point.

The first point is the start of the analysis. There is no history yet, and
`ddt` returns 0, as it does in any DC analysis (LRM §4.5.3): in DC, a
capacitor is an open circuit. After that, each 1 V step over 1 µs gives 1 mA.

How a simulator turns `ddt` into numbers is its choice. The testbench uses
backward Euler, `(V_now − V_before)/dt`, at the step you give it, which is
exact for this ramp. A real simulator picks its own steps and method, and
checks its truncation error as it goes.

## What the simulator sees

VerA does not compute `ddt` inside the device. It hands the simulator the
**charge**, `c · V(p, n)`, and which rows it enters (+ on `p`, − on `n`),
and the simulator differentiates it in time with its own integration method.
`//! qsite` asserts what a device publishes:

```verilog
{{#include ../examples/ddt-idt/qsite.va}}
```

```console
{{#include ../examples/ddt-idt/qsite.out}}
```

`lte` says the simulator should include this charge when it estimates its
local truncation error. [Charges, truncation error and
state](../host/state.md) describes the interface in full.

## An inductor

An inductor's voltage is `l · dI/dt`: a potential source whose value
depends on its own current (LRM §5.6.4). In DC it is a short circuit. Here
it is driven through a resistor by a step:

```verilog
{{#include ../examples/ddt-idt/inductor.va}}
```

```console
{{#include ../examples/ddt-idt/inductor.out}}
```

The step is one time constant, `l/r` = 100 µs, and backward Euler halves the
remaining distance to the final 1 mA at each point: 0.5, 0.75, 0.875 mA, as
the header derives. The exact solution would be 1 − e⁻¹ ≈ 0.632 mA after one
time constant: a step that large is too coarse for accuracy, and a simulator
would take smaller ones.

## An integrator

`idt(x, ic)` integrates `x` over time, starting from `ic` (LRM §4.5.4). In a
DC analysis, and at the first point of a transient, it returns `ic`:

```verilog
{{#include ../examples/ddt-idt/integrator.va}}
```

```console
{{#include ../examples/ddt-idt/integrator.out}}
```

Without an initial condition, `idt` returns whatever value makes its argument
zero in DC, so it must sit inside a feedback loop that drives its argument to
zero; otherwise its output is undefined (LRM §4.5.4). Give an initial
condition unless that loop exists.

## Restrictions

Because they keep state, analog operators must run at every evaluation (LRM
§4.5.15). So they may not appear under a condition that can change during the
simulation, inside an ordinary `for`, `while` or `repeat` loop, inside an
event-triggered statement, or in a user-defined function. A condition built
only from parameters is fine; so is the analog `for` of LRM §5.9.3, over a
`genvar`.

## Exercises

1. In `cap.va`, change the wave to `0, 1, 1, 1`. What current flows at each
   point?
2. Write `V(out) <+ idt(k * V(in), ic)` with `ic = 0` and `V(in) = -1`. What
   is `V(out)` at 3 ms?
3. Why does an inductor need to be a potential source, while a capacitor can
   be a flow source?

<details>
<summary>Solutions</summary>

1. 0 at the first point (DC), 1 mA while the voltage rises, then 0 once it
   stops changing: a capacitor passes current only while its voltage moves.
   The transcript below runs it with `--param` unchanged and the new wave.

```verilog
{{#include ../examples/ddt-idt/cap_step.va}}
```

```console
{{#include ../examples/ddt-idt/cap_step.out}}
```

2. The integral of −1000 V/s over 3 ms is −3 V, from 0: `V(out)` = −3 V.

```verilog
{{#include ../examples/ddt-idt/integrator_neg.va}}
```

```console
{{#include ../examples/ddt-idt/integrator_neg.out}}
```

3. A capacitor's current is a function of its voltage, which the simulator
   solves for, so `I <+ c*ddt(V)` is a flow source like any conductance. An
   inductor's voltage is a function of its current; the branch current must
   be an unknown of the system, and only a potential source makes it one.
   (A flow-source inductor would need `I = (1/l)·idt(V)`, which LRM §4.5.4
   allows, but which leaves the DC solution undefined without an initial
   condition.)

</details>
