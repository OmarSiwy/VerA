# Vendor attributes

An **attribute** is a `(* name = value *)` annotation on a declaration, a
statement or an operator (LRM §2.9). The LRM defines a few (`desc` and
`units` on a declaration, §2.9.2) and leaves the rest to the tool: a tool
reads the attributes it knows and ignores the others. So a model that uses
VerA's attributes still compiles in any other simulator, which simply does
not get what the attribute asks for.

VerA reads the LRM's `desc` and `units` (it publishes them to the host),
the attributes on this page, and one system task of its own,
`$vera_reject_step`. Every other attribute is parsed and ignored. Every
attribute value must be a constant expression (LRM §2.9; E0357 otherwise),
and an attribute written with no value is 1. Where attributes nest (a
prefix on a `begin ... end` block and another on a statement inside it),
the innermost one wins.

## `vera_lte`: leave a charge out of the truncation-error check

A simulator estimates the error of each time step from the device's
charges and rejects a step whose error is too large. SPICE's device
routines check some charges and not others: ngspice's level-1 MOSFET
(`mos1trun.c`) checks its three gate charges and never its junction
charges. `vera_lte = 0` says the
same thing in Verilog-A: the charge sites it covers are published with a
flag that leaves them out of the host's check (`q_lte`).

It goes on an analog statement, `(* vera_lte = 0 *) I(b, s) <+ ddt(qbs);`,
or on a `ddt` call itself, `ddt (* vera_lte = 0 *) (q)`. LRM A.8.2 allows
an attribute after a function name only for analog user-defined functions;
VerA extends it to `ddt`, because one `ddt` call is one charge. The value
must fold without the model card (E0523): the set of checked charges is part
of the device's shape, not of a card.

```verilog
{{#include ../examples/attributes/lte.va}}
```

```console
{{#include ../examples/attributes/lte.out}}
```

## `vera_interp`: interpolation in `absdelay`

`absdelay` (LRM §4.5.7) reads its input at an earlier time, which usually
lies between two stored points. `(* vera_interp = 1 *)` interpolates
linearly between them (the default); `= 2` uses a quadratic through three
points. It goes in the same two places as `vera_lte`, on the statement or
on the `absdelay` call. Another value is E0524.

## `vera_nodiff`: a coefficient with no derivative

The Jacobian of a VerA device is exact: every value carries its derivative
through every operation. Sometimes a model wants the opposite. A SPICE
simulator integrates a voltage-dependent capacitance with the capacitance
frozen at the present iterate, and stamps no dC/dV term; an exact Jacobian
of the same equations has one, and the two converge differently.

`(* vera_nodiff *)`, a prefix on a statement, stores every assignment
inside it with no derivative. The values do not change; only their
derivative lanes are dropped. `(* vera_nodiff = 0 *)` turns it back on
inside. The value must fold without the model card (E0525), and a
contribution inside is E0526: what it drops is a variable's derivative,
never a branch's.

```verilog
{{#include ../examples/attributes/nodiff.va}}
```

```console
{{#include ../examples/attributes/nodiff.out}}
```

The current's derivative with respect to `V(a)` is `cs`, 0.25: the stored
coefficient, with no term from its own dependence on `V(a)`. Without the
attribute it is 0.75.

## `vera_timepoint`: once per time point

The analog block runs at every Newton iteration (LRM §5.2), and a model may
have work that depends only on the time point: a table lookup on
`$abstime`, a random draw per step. `(* vera_timepoint *)`, a prefix on a
statement, runs that statement once per time point: the first evaluation at
a given `$abstime`, analysis and step runs it and stores what it assigned in
the instance; later iterations at the same point read the stored values. A
rejected step recomputes them (the device drops the cache when its state is
reset, committed or reverted). `= 0` turns it off; the value folds without
the card (E0529).

Because the statement runs once, its result must not depend on anything an
iteration can move. Inside one, a probe, `$limit`, a contribution, a
stateful analog operator, a noise function, an event, a system task or a string
assignment is E0530. Reading a value computed earlier in the block that an
iteration can move (a probe stored in a variable, a branch on one) is
E0531. Inside a loop, an analog function or `analog initial` it is E0532.

## `vera_scratch`: a variable that is not state

An analog variable keeps its value from one evaluation to the next, so
VerA's device carries it in the instance when it cannot prove every read
is preceded by a write in the same evaluation. For a stack or a scratch
buffer indexed at run time, that proof often fails, and the variable becomes
state the host must save and restore.

`(* vera_scratch *)`, a prefix on a variable declaration (module or named
block, scalar or array, real or integer), declares the variable is never
held: each evaluation starts it at its initializer, or zero when it has
none. A device whose only state was such variables has no state at all.
`= 0` turns it off; the value folds without the card (E0534). On anything
but a variable it is E0535; on a variable an `analog initial` or `@(...)`
body assigns, which is state by design, E0536; on a variable a digital
process or task assigns, E0537.

`(* vera_scratch = "uninit" *)` also skips the start value of a
runtime-indexed array, which saves the stores that zero it. **The author
promises every element is written before it is read in the same
evaluation.** A read before a write is the model's bug: a Debug or
ReleaseSafe device fills such an array with NaN (for an integer array, the
most negative integer), so the bug shows in the outputs; a ReleaseFast or
ReleaseSmall device reads an unspecified but stable value. Any other string
is E0538, and an initializer together with `"uninit"` is E0539.

## `vera_pin` and `vera_delay`: for `--emit-verilog`

These two only affect `vera --emit-verilog`, the behavioural Verilog
stand-in ([the command line](cli.md)).
`(* vera_pin = "digital" | "analog" | "power" | "ground" *)` on a port's
direction declaration says what the port becomes, as `--digital-pins` does
from the command line. `(* vera_delay = 2n *)` on a net's declaration
replaces the delay VerA derives for it (both edges); on a port it goes on
the direction declaration, like `vera_pin`.

## `$vera_reject_step`

`$vera_reject_step(t_retry)` is a VerA system task in the analog block. On
the accepted solution of a transient step that ends after `t_retry`, it
asks the host to reject the step and solve `t_retry` first (the device's
`updateState` returns `request_reject_at`). If several calls ask, the
earliest time wins; a static analysis ignores it. It lets a device that
knows where its next event lies make the host land on it:

```verilog
{{#include ../examples/attributes/retry.va}}
```

```console
{{#include ../examples/attributes/retry.out}}
```

The testbench prints the rejected attempt at 2 s, then solves 1.5 s and
2 s again. The rejected attempt already shows `hit = 1`: the request was
made earlier in the same evaluation, before the `above` event ran. In `analog initial` or an analog function the task is E0533.
The mixed-signal runner and the VPI host refuse a request rather than
honour it.
