# A resistor

The [first chapter](getting-started.md) wrote a resistor in one line. This
one takes it apart: what `electrical` means, the two ways the LRM writes a
resistor, and how a model states units and temperature.

## Disciplines and natures

A port or net becomes an analog node when it has a **discipline** (LRM
§3.6.2). A discipline names two **natures**: the node's *potential* and the
*flow* through it. This is the `electrical` discipline, as
`disciplines.vams` (LRM Annex D.1) defines it, and as VerA has it built in:

```verilog
// Current in amperes
nature Current;
   units       = "A";
   access      = I;
   idt_nature  = Charge;
   abstol      = 1e-12;
endnature

// Potential in volts
nature Voltage;
   units      = "V";
   access     = V;
   idt_nature = Flux;
   abstol     = 1e-6;
endnature

discipline electrical;
   potential    Voltage;
   flow         Current;
enddiscipline
```

A nature's `access` attribute names the **access function** that reads or
contributes it: `V(p, n)` is the potential of `electrical` nets, `I(p, n)` the
flow. `abstol` is the smallest value of that quantity the solver needs to
resolve (LRM §3.6.1.2). `idt_nature` names the nature of its time integral, so
`idt` of a current is a charge (LRM §3.6.1). Other disciplines in the same file
describe other physics: `thermal` has `Temp` (kelvin) and `Pwr` (watts),
`kinematic` a position and a force, and so on. The rules are the same.

(The file guards each `abstol` with an `` `ifdef `` so a user can override it
before including it; the excerpt above shows the defaults.)

## Potential and flow

Every branch, between two nodes, has a potential across it and a flow
through it (LRM §5.6.1.1). A contribution sets one of them, and that makes the
branch a **source** of that kind (LRM §5.4.2.2):

- `I(b) <+ expr` makes `b` a **flow source**: a current source whose value is
  `expr`. Its potential is still readable: `V(b)`.
- `V(b) <+ expr` makes `b` a **potential source**: a voltage source. Its flow
  is still readable: `I(b)`.

LRM §5.6.3 uses this to write a resistor two ways. As a *conductor*, a current
source whose value is the voltage across it divided by `r`:

```verilog
{{#include ../examples/resistor/conductor.va}}
```

```console
{{#include ../examples/resistor/conductor.out}}
```

`branch (p, n) res;` names the branch between `p` and `n`
([Branches](branches.md) has more on named branches). The testbench prints the
residual: 1 mA leaves `p` and enters `n`, and the Jacobian holds ±1/r.

As a *resistor*, a voltage source whose value is `r` times the current
through it:

```verilog
{{#include ../examples/resistor/resistor.va}}
```

```console
{{#include ../examples/resistor/resistor.out}}
```

The two are the same element, but not the same equations. A potential source
fixes the voltage across it, so the simulator cannot eliminate the branch's
current: it becomes an unknown of its own, the third `x[...]` line, with a
row of its own, `V(p) − V(n) − r·I = 0`. `//! solve` lets the testbench
find it: 1 mA, as before. The flow form is smaller (no extra unknown), and
the potential form can express what the flow form cannot: `V(res) <+ 0` is an
ideal short, where `1/r` would divide by zero.

## Checking the device

`--check` generates the device and type-checks it with Zig against VerA's
device contract, the interface a simulator compiles it against. No output
means it passed:

```console
{{#include ../examples/resistor/check.out}}
```

You rarely need it for your own models, since VerA's code generator is tested
against the same contract; it is the command to run before you report a
bug in the generated code.

## Units, descriptions and temperature

Parameters take two standard attributes, `desc` and `units` (LRM §3.4.3,
§2.9.2), which a simulator shows in its help and operating-point listings.
`$temperature` reads the simulation temperature in kelvin (LRM §9.15), and
`//! temp` sets it in a testbench:

```verilog
{{#include ../examples/resistor/resistor_tc.va}}
```

```console
{{#include ../examples/resistor/resistor_tc.out}}
```

At 350.15 K the resistance has risen 5% to 1050 Ω, and 1 V draws 0.952 mA.
VerA warns W0650 here, and for a good reason: for some temperature,
`1 + tc1·(T − tnom)` is zero, and `V/rt` is not finite there.

## Exercises

1. Run `resistor_tc.va` with `--param tc1=0`. What current do you expect?
2. Write a thermal resistance: power flows through it in proportion to the
   temperature difference across it, `Pwr = Temp / rth`, with `rth = 50`
   K/W. What power does 10 K across it carry? (An unknown that is not a
   voltage is named in a directive by its bare net name: `//! bias a = 310`.)
3. Which of the two resistor forms can represent `r = 0`, and why?

<details>
<summary>Solutions</summary>

1. With `tc1 = 0` the temperature has no effect, so 1 V across 1 kΩ is 1 mA:

```console
{{#include ../examples/resistor/tc0.out}}
```

2. 10 K / 50 K/W = 0.2 W:

```verilog
{{#include ../examples/resistor/thermal.va}}
```

```console
{{#include ../examples/resistor/thermal.out}}
```

3. The potential form. `V(res) <+ r * I(res)` with `r = 0` is `V(res) <+ 0`,
   an ideal short, and the branch current is still an unknown the solver can
   find. The flow form needs `V(res) / r`, which divides by zero. (Both
   examples here declare `r` in `(0:inf)`, so VerA refuses `r = 0` for either
   with E0361; widen the range to try it.)

</details>
