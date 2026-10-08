# A compact model

A **compact model** is a device model written for circuit simulation: a
transistor, diode or resistor described by equations compact enough to
evaluate millions of times per simulation, with a **model card** of
parameters fitted to a fabrication process. BSIM4 and PSP, the MOSFET models
foundries ship, are compact models of several thousand lines of Verilog-A.

They are built from the pieces of the previous chapters: parameters with
ranges, internal nodes, charges through `ddt`, `$limit`, and temperature.
This chapter puts them together in the oldest MOSFET model in SPICE, level 1
(Shichman-Hodges), small enough to check by hand.

## The model

```verilog
{{#include ../examples/compact-model/nmos1.va}}
```

Section by section:

- **The card.** Every number the equations use is a parameter with a range
  (LRM §3.4.2), so a card outside the model's validity is refused when it
  is read, not discovered as a NaN halfway through a simulation. `tnom` is
  the temperature the card was measured at.
- **Temperature.** `$temperature` is the circuit's temperature in kelvin
  (LRM §9.15). Mobility falls as T<sup>bex</sup> and the threshold drifts
  by `tcv` per kelvin, so `beta` and `vth` are recomputed from the card at
  the simulation's temperature. At `tnom` they reduce to the card's values.
- **Internal nodes.** `di` and `si` are declared `electrical` but are not
  ports. The channel current flows between them, and the series
  resistances `rd` and `rs` connect them to the terminals. The simulator
  solves for their voltages as it does for any node.
- **A zero resistance.** `V(d, di) <+ 0` makes the branch a short: a
  potential source of 0 V instead of a resistor of 0 Ω, which would divide
  by zero. A branch whose contribution switches between a flow and a
  potential is a **switch branch** (LRM §5.6.5). Here the condition is a
  parameter, so it is fixed for a whole simulation.
- **Regions.** The channel equation has three pieces: cut-off, triode and
  saturation. Ordinary `if`/`else` selects one. The pieces meet with equal
  values and slopes at their boundaries, which Newton's method needs.
- **Limiting.** `$limit(V(g, si), "fetlim", vth)` recommends SPICE's gate
  voltage limiter to the simulator (LRM §9.17.3; [A diode, and
  $limit](diode.md)).
- **Charges.** Two linear gate capacitances, as charges through `ddt`
  (LRM §4.5.3). A production model computes its charges from the same
  physics as its current; the structure is the same.

## Checking it by hand

The header works out the current at six bias points. `//! solve` lets the
testbench find the internal nodes by Newton's method, and `//! sweep`
steps the gate and the drain:

```console
{{#include ../examples/compact-model/nmos1.out}}
```

At V(g) = 0.4 V the gate is below the 0.5 V threshold and no current flows.
At 1.5 V the transistor is in triode at a drain voltage of 0.5 V and in
saturation at 1 V and 2 V, and the three currents are the header's 0.37875,
0.51 and 0.52 mA. With `rd` and `rs` at zero, the internal nodes sit on the
terminals.

The two `flow(...)` unknowns are the currents through the shorted series
branches. A potential source fixes its voltage, not its current, so the
current is one more thing to solve for, and the device gets one unknown for
each branch that can be a potential source (LRM §5.4.2.2). Their names are
encoded to be valid Zig identifiers.

## A model card

The same model with a source resistance, set on the command line as a
simulator would set it from a card:

```console
{{#include ../examples/compact-model/rs.out}}
```

Now `si` rises above ground, so the transistor sees less than the applied
gate-source voltage and the current drops. The source branch is now a
resistor, so its `flow` unknown stays at zero. This is **source
degeneration**, and it is why a production model's series resistances
matter.

## Checking the device

Before handing a model to a simulator, `vera --check` generates the device
and type-checks it with Zig against the device contract, running the
contract's conformance checks on every declaration the device publishes:

```console
{{#include ../examples/compact-model/check.out}}
```

A warning-only compile with exit status 0 means the device meets the
contract. [VerA devices in your own simulator](../host/why.md) is what a
simulator does with it next.

## Exercises

1. Run the transistor at 400.15 K, 100 K above `tnom`, at V(g) = 1.5 V and
   V(d) = 2 V. Both the mobility and the threshold fall. Which wins: does
   the current rise or fall?

<details>
<summary>Solution</summary>

1. It falls. `beta` drops to (400.15/300.15)<sup>−1.5</sup> = 0.6496 of its
   value while `vgst` rises from 1.0 to 1.1 V; squared, that is a factor
   1.21, not enough to make up for 0.6496. The header derives
   0.408754 mA, against 0.52 mA at `tnom`:

```verilog
{{#include ../examples/compact-model/hot.va}}
```

```console
{{#include ../examples/compact-model/hot.out}}
```

</details>
