# `$limit` arguments

`$limit` (LRM §9.17.3) lets a model recommend how the solver should limit
the change of a nonlinear argument between Newton iterations, the way SPICE
limits junction voltages. The LRM names the arguments a built-in algorithm
*requires* (for `"pnjlim"`, `vte` and `vcrit`; for `"fetlim"`, the threshold
voltage) and leaves the rest to the implementation. This page is what VerA
does with them.

## The algorithms

The LRM names `"pnjlim"` and `"fetlim"` but leaves their algorithms to the
simulator. VerA's are ngspice's, transcribed from its
`src/spicelib/devices/devsup.c`. That matters for `pnjlim`: ngspice
compresses a large step as `vold + vte·(2 + ln(arg − 2))`, with
`arg = (vnew − vold)/vte`, where the older SPICE3f5 used
`vold + vte·ln(1 + arg)`, so the two give different iterates.

| Algorithm | Limits | Required arguments |
|---|---|---|
| `"pnjlim"` | a pn-junction voltage (ngspice `DEVpnjlim`) | `vte`, `vcrit` |
| `"pnjlimds"` | a MOS bulk junction, in the drain/source mode (VerA's own name; below) | `vte`, `vcrit` |
| `"fetlim"` | a MOS gate voltage (ngspice `DEVfetlim`) | `vto` |
| `"fetlimds"` | a MOS gate voltage, in the drain/source mode (VerA's own name; below) | `vto` |
| `"steplim"` | any value, to at most `step` per iteration (ngspice's per-model absolute clamp) | `step` |
| `"limvds"` | a drain-source voltage (ngspice `DEVlimvds`) | none |

A user-defined analog function as the second argument works as the LRM
describes: VerA passes it the new value, the previous return value, and any
further arguments.

`fetlimds` and `pnjlimds` exist because ngspice's MOS loads (`mos1load.c` and
the BSIM loads) do not limit both gate legs. They `fetlim` the gate voltage
that controls the channel in the present mode (`vgs` when the old `vds` is
non-negative, `vgd` otherwise), run `limvds` on the channel and derive the
other leg; the bulk is limited the same way. Write both gate legs as
`fetlimds` (and both bulk legs as `pnjlimds`) next to a `limvds` on the
channel, and VerA emits them as that one mode-aware ladder. A static
both-legs clamp limits the wrong frame at a `vds = 0` crossing, and Newton can
cycle between two points. An algorithm name VerA does not know is declined,
as LRM §9.17.3 allows.

## VerA's extra arguments

After the algorithm's own arguments, VerA reads up to two more:

- a frame **sign**, `type`: the clamp runs on `sign · v` (so a PMOS model can
  limit in its own polarity, as SPICE's `type` does), and
- a **seed**: the value the branch starts from on a cold start (SPICE's
  `MODEINITJCT`), in the frame of the sign. A seed needs a sign before it;
  write `1` for none.

| Algorithm | Full call | Seed position |
|---|---|---|
| `pnjlim`, `pnjlimds` | `$limit(V(a,k), "pnjlim", vte, vcrit, sign, seed)` | 6 |
| `fetlim`, `fetlimds` | `$limit(V(g,s), "fetlim", vto, sign, seed)` | 5 |
| `steplim` | `$limit(V(a,b), "steplim", step, sign, seed)` | 5 |
| `limvds` | `$limit(V(d,s), "limvds", sign, seed)` | 4 |

More arguments than these decline the site, with warning W0853: the call then
returns its first argument unlimited, which the LRM allows ("the simulator may
simply choose to have `$limit()` return the value of its first argument").

Seeded branches are solved into node values from a 0 V root (ground, else
the lowest-numbered port, else the lowest net). A `pnjlim`/`pnjlimds` leg with
no seed starts at its `vcrit`; a `fetlimds` gate-drain leg or a `pnjlimds`
bulk-drain leg is never seeded. A seed may read values derived from the model
card but never the solution (E0527); a seed the node tree cannot take is
warning W0854.

## Who does the limiting

VerA's device does not limit by itself inside `eval`. It **publishes** the
clamp: a `limit` function that maps the previous and the proposed solution to
the limited one, and a `seed` function for the cold start, together with
masks of which unknowns they read and write. A clamp moves only the device's own internal nodes:
a limiter that moved a port would fight the sources and the other devices on
it. Your simulator calls them between Newton iterations; [Charges, truncation error and
state](../host/state.md) shows where. A testbench never limits on its own, so
a fixture asserts the clamp with `//! limit`:

```verilog
{{#include ../examples/limit/pnjlim.va}}
```

```console
{{#include ../examples/limit/pnjlim.out}}
```
