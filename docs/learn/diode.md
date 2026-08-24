# A diode, and $limit

The diode is the first model in this book whose current is a strongly
nonlinear function of its voltage. That brings two new problems: numbers
that overflow, and a Newton solver that can overshoot. Verilog-AMS has a tool
for each: `limexp` (LRM §4.5.13) and `$limit` (LRM §9.17.3).

## The Shockley diode

The current through an ideal junction is `is · (exp(V / (n·Vt)) − 1)`, where
`Vt = kT/q` is the thermal voltage. `$vt` returns it at the simulation
temperature (LRM §9.15):

```verilog
{{#include ../examples/diode/diode.va}}
```

```console
{{#include ../examples/diode/diode.out}}
```

Each 60 mV of forward bias multiplies the current by about ten. The warning
at the end is W0650 again, and this time it describes a real hazard: `exp`
of a voltage over 26 mV overflows a double once the voltage passes about 18
V, and Newton's intermediate guesses can go that far.

## limexp

`limexp(x)` is `exp(x)` with a limit on how fast its output may change from
one Newton iteration to the next (LRM §4.5.13). The LRM leaves the algorithm
open. VerA's `limexp` follows `exp` up to an argument of 80 and continues
along the tangent line above it, so a wild guess produces a large, finite
current with a sensible derivative instead of an infinity:

```verilog
{{#include ../examples/diode/limexp.va}}
```

```console
{{#include ../examples/diode/limexp.out}}
```

At 0.7 V the two agree. At 3 V, `exp` has grown to about 10⁵⁰ and `limexp`
to about 10³⁶. Neither is a plausible diode current; what matters is that the
next Newton step, guided by `limexp`'s gentler slope, is not thrown as far.
At a converged solution of a real circuit the argument is far below 80, and
the two are the same function.

## Series resistance and an internal node

A real diode has a resistance in series with the junction. That needs an
internal node between the two, and now the junction voltage is not a port
voltage: the simulator has to solve for it.

```verilog
{{#include ../examples/diode/series_r.va}}
```

```console
{{#include ../examples/diode/series_r.out}}
```

With `//! solve`, the testbench runs Newton until the current through `rs`
equals the junction current, which is what the two equal columns show. Most
of the 0.8 V now falls across the junction, and the current is far below the
0.8 V curve of `diode.va`, because `rs` takes its share.

## $limit

`limexp` limits one exponential. `$limit` generalises it: it marks a branch
voltage as the argument of a nonlinearity and recommends an algorithm for
limiting how far it moves per iteration (LRM §9.17.3). The SPICE junction
limiter is `"pnjlim"`, which takes a step size `vte` and a critical voltage
`vcrit`, above which the exponential outruns Newton:

```verilog
vd = $limit(V(ai, k), "pnjlim", vte, vcrit);
I(ai, k) <+ is * (exp(vd / vte) - 1);
```

At a converged point `$limit` returns its first argument unchanged, so the
model's equations do not change. What changes is the path to convergence.

In VerA, the device does not apply the limit itself. It publishes a `limit`
function, and the simulator calls it between Newton iterations with the
previous and the proposed solution. A testbench never iterates that way, so
`//! limit` asks the device directly what it would do with a proposed step:

```verilog
{{#include ../examples/diode/pnjlim.va}}
```

```console
{{#include ../examples/diode/pnjlim.out}}
```

From 0.7 V, a step to 0.9 V is compressed logarithmically and the iteration
is marked not converged; from 0.88 V, the 20 mV step passes. The limited node
is `ai`, the internal node: a device limits only its own nodes, never a port.
[`$limit` arguments](../using/limit.md) lists every algorithm VerA knows, the
extra arguments it accepts, and the cold-start seed.

The usual choice of `vcrit` is the LRM's formula, `vte · ln(vte / (√2 ·
is))`. The example sets `vte` and `vcrit` directly, so its numbers can be
checked by hand.

## Exercises

1. Run `diode.va` at 350.15 K (`//! temp 350.15`). Does the current at 0.62
   V rise or fall? Why do real diodes do the opposite?
2. Set `rs` in `series_r.va` to 10 MΩ. Which takes more of the 0.8 V, the
   resistor or the junction?
3. Rewrite `pnjlim.va`'s `vcrit` as the LRM's formula from `vte` and `is`.
   What value does it take?

<details>
<summary>Solutions</summary>

1. It falls. `$vt` grows with temperature, so `V/$vt` shrinks, and with a
   fixed `is` the exponential is smaller. In a real junction `is` rises
   steeply with temperature and wins; a compact model scales `is` with
   temperature (see [A compact model](compact-model.md)).

```verilog
{{#include ../examples/diode/diode_hot.va}}
```

```console
{{#include ../examples/diode/diode_hot.out}}
```

2. About half each. The current must satisfy both `(0.8 − Vd) / 10 MΩ` and
   `is · exp(Vd / Vt)`; the second grows tenfold every 60 mV, so the junction
   voltage settles where the resistor's current is a few tens of nanoamperes,
   near 0.39 V. (A bisection of the same equation outside VerA gives Vd =
   0.3936 V and 40.6 nA.)

```console
{{#include ../examples/diode/series_big.out}}
```

3. `vte · ln(vte / (√2 · is))` with `vte = 25 mV` and `is = 1e-14 A` is
   0.025 · ln(1.7678e12) ≈ 0.7050 V. A parameter's default may be any
   constant expression of other parameters (LRM §3.4), and `` `M_SQRT2 ``
   comes from `constants.vams` (LRM Annex D.2):

```verilog
{{#include ../examples/diode/vcrit.va}}
```

```console
{{#include ../examples/diode/vcrit.out}}
```

</details>
