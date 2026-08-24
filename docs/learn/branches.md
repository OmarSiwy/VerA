# Branches and contributions

A model is a set of branches between nodes, each contributing a potential or
a flow. This chapter covers the ways to name them, what happens when several
contributions meet, internal and ground nodes, and the two kinds of branch
that change shape while the simulation runs: switch branches and implicit
contributions.

## Named and unnamed branches

`I(p, n)` refers to the **unnamed branch** between `p` and `n`. `branch (p, n)
b;` declares a **named branch** (LRM §3.12), and `I(b)` then means the same
thing. Naming helps when a model reads one branch several times, and when two
branches share a pair of nodes but must stay distinct. A branch has a
direction: from its first node to its second, so `I(p, n)` flows from `p` to
`n` (LRM §5.6.1.1).

## Internal nodes

A net that is not a port is an **internal node**: it belongs to the module,
and the simulator solves for its potential like any other node. Here are two
resistors in series, with the middle node internal:

```verilog
{{#include ../examples/branches/divider.va}}
```

```console
{{#include ../examples/branches/divider.out}}
```

`//! solve` tells the testbench to solve every unknown no directive names, by
Newton's method on the device's residual. Without it, the testbench ties such
unknowns to 0 V. With 4 V across 1 kΩ and 3 kΩ, 1 mA flows and `mid` sits 3 V
above `n`.

## Contributions add

Two contributions to the same branch in one evaluation add up (LRM §5.6.1.2).
That is how a model attaches parasitics: contribute the main element, then
contribute the extras to the same branch.

```verilog
{{#include ../examples/branches/parallel.va}}
```

```console
{{#include ../examples/branches/parallel.out}}
```

If no statement contributes to a branch in an evaluation, and it is not a
probe, it is a flow source of value 0: an open circuit (LRM §5.6.1.3).

## Ground, and one-terminal access

`ground gnd;` makes a net the global reference node (LRM §3.6.4). It is not an
unknown: its potential is 0 by definition. An access function with one node,
`V(a)` or `I(a)`, is the branch from `a` to ground (LRM §5.6.1.1).

```verilog
{{#include ../examples/branches/ground.va}}
```

```console
{{#include ../examples/branches/ground.out}}
```

The testbench lists only `x[a]`: `gnd` is the reference, not an unknown.

## Probes

A branch that no statement contributes to is a **probe** (LRM §5.4.2.1). If
its flow is read anywhere, it is a *flow probe*: an ammeter, a branch whose
potential is 0. Otherwise it is a *potential probe*: a voltmeter, which
draws no flow. Reading both the flow and the potential of a probe is an
error. Exercise 1 below builds an ammeter.

## Switch branches

A branch can change kind between evaluations: a potential source in one, a
flow source in the next. LRM §5.6.5 calls it a **switch branch**. The classic
use is an ideal switch, a short (`V <+ 0`) when closed and an open circuit
(`I <+ 0`) when open:

```verilog
{{#include ../examples/branches/switch.va}}
```

```console
{{#include ../examples/branches/switch.out}}
```

Closed, the switch joins `p` and `n` into one 1 V node between the source and
the load; open, `p` floats up to the source's 2 V and `n` falls to 0 V. The
simulator solves both with one matrix structure; only the row's contents
change.

## Implicit contributions

The value of a contribution may depend on the branch's own target: `I(b) <+
f(I(b))`. The simulator then finds the value that satisfies the equation, not
merely evaluates the right-hand side (LRM §5.6.6):

```verilog
{{#include ../examples/branches/implicit.va}}
```

```console
{{#include ../examples/branches/implicit.out}}
```

The header derives the fixed point by hand: 0.125 A and 0.5 V. Reading
`I(b)` on the right-hand side made the branch's flow an unknown of the
solve, which is why the testbench lists one more `x[...]` than there are
nodes.

## Exercises

1. Put an ammeter between the two resistors of `divider.va`: split `mid` into
   `mid1` and `mid2` and read the flow of an uncontributed branch between
   them. What does it read?
2. Predict what this module does, then run it (the LRM clause that decides it
   is §5.6.1.3):

   ```verilog
   V(p, n) <+ 1;
   I(p, n) <+ 1m;
   ```

<details>
<summary>Solutions</summary>

1. The probe reads the 1 mA flowing through the divider, and since a flow
   probe has zero potential, `mid1` and `mid2` are both at 3 V:

```verilog
{{#include ../examples/branches/ammeter.va}}
```

```console
{{#include ../examples/branches/ammeter.out}}
```

2. Contributing a flow to a branch that holds a potential discards the
   potential (LRM §5.6.1.3), so the branch ends the evaluation as a 1 mA
   current source, whatever the voltage across it:

```verilog
{{#include ../examples/branches/both.va}}
```

```console
{{#include ../examples/branches/both.out}}
```

</details>
