# OSDI interoperability

[OSDI](https://openvaf.semimod.de/docs/details/osdi/) is the C interface
OpenVAF's compiled models use: a shared object exporting a descriptor table
of parameters, nodes, Jacobian entries and function pointers, which ngspice
(through its `pre_osdi` command), Xyce and other simulators load. If your
simulator already loads `.osdi` files, that is the shortest path to running a
VerA-compiled model in it, at the costs [the first page](why.md) lists.

## `vera --emit-osdi` (forthcoming)

> **Not on `main` yet.** `--emit-osdi` is on branch `x-analog`
> (commit `f7ca9b7d`, "feat(cli): --emit-osdi, an OSDI 0.4 library of a .va
> (tools/osdi_dyn.zig)"). What follows describes that branch as read on
> 2026-10-06; it is unverified against a released VerA, and no CI job on
> `main` runs it yet.

On that branch, the flag builds a device as an OSDI 0.4 shared object:

```sh
vera --emit-osdi model.va              # writes <module>.osdi and prints its path
vera --emit-osdi model.va -o lib.osdi  # or names it
```

It is `--emit-so` under a `dyn` module VerA ships, `tools/osdi_dyn.zig`, so
it takes neither `--dyn` nor `--emit-zig`, `--emit-exe` or `--run`, and only
a `.va` source. That `dyn` module maps the [device contract](device.md) onto
OSDI 0.4 (layout from OpenVAF-Reloaded's `osdi_0_4.h` and ngspice-45's
`src/osdi/`):

| OSDI | From the contract |
|---|---|
| nodes | every unknown of `U`, ports first; a `current`/`flow` unknown is an OSDI flow node |
| Jacobian entries | every `(row, col)` in `jac_pattern \| q_pattern`, plus `jac_const` and `ac_dyn_slots` |
| parameters | every scalar `Model` parameter, listed twice (instance and model), since the contract does not say which a parameter is; `$mfactor` when `Instance` has `mfactor` |
| eval | one `evalQ` over the sparse reference family at the limited point: `seed` under ngspice's `INIT_LIM`, `limit` under `ENABLE_LIM` |
| noise | one OSDI source per `noise_gens` row, with `coeff² · (white + flicker/f^ef + table)` |
| `$bound_step` | `bound_step_offset` |

And what does not map, because OSDI 0.4 has no slot for it, per the
module's header:

- operating-point variables (opvars);
- correlated noise: each `noise_gens` row becomes an independent source;
- a step rejection the device asks for (`request_reject_at`);
- acceptance itself: OSDI has no accept callback, so `updateState` and
  `stateCtl(.commit)` run at every iterate of a static solve and, in a
  transient, at the last point evaluated before the simulator moves time
  forward.

So a device whose behaviour depends on state across accepted points (events,
`idt`, held variables) runs under OSDI with acceptance approximated as above.
The native contract, with `updateState`/`stateCtl` called at real accepted
points, is exact.

## Comparing against OpenVAF

The repository's `nix develop .#benchmarking` shell carries ngspice (an OSDI
host) and OpenVAF-Reloaded (`openvaf-r`, x86_64-linux only), so a VerA
`.osdi` and an OpenVAF `.osdi` of the same model can run in the same deck.
External accuracy suites that do exactly this are being added on the same
branch; until they land, there is no published comparison, and this book
quotes no numbers for one.
