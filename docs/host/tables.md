# Noise, AC and tolerances

Some of what a device knows is not a residual: the noise sources a
small-signal analysis needs, the AC stimuli, the tolerance of each unknown.
The device publishes these as compile-time tables plus pure functions you
may call at any state vector, in any order.

```verilog
{{#include ../examples/host/nres.va}}
```

```console
{{#include ../examples/host/tables.out}}
```

## Noise

`noise_gens` is the list of LRM §4.6.4 generators. Position `k` is a
generator of `kind` (`thermal`, `shot`, `flicker`, `table`) on the branch
`(row, col)`, and position `k` of `noisePsd(S, x, &model, &inst, sim)` is its
spectral density at the state vector `x`, as a `PsdTerm`:

```zig
pub const PsdTerm = struct {
    white: f64,
    flicker: f64 = 0,
    ef: f64 = 1,
    corr_with: ?u8 = null,
    corr: f64 = 0,
    coeff: f64 = 1,
};
```

The density generator `k` contributes is `coeff² · (white + flicker/f^ef)`,
or `coeff² · noiseTableAt(noise_tables[...], f)` for a table row (whose
`white` and `flicker` are zero, so adding both shapes is right for every
row). You must apply `coeff`: it is the signed factor the contribution
applies (the `c1` of `V(a,b) <+ c1*n`), may depend on the bias, and its sign
is what distinguishes correlation from anti-correlation between two rows.

Correlation (LRM §4.6.4.6): rows with the same non-null `source` are one
generator contributed to several branches, fully correlated; their cross
term is `coeff_i · coeff_j` times the shared spectrum. Distinct values, and
null, are independent. `corr_with`/`corr` name a partner and a real
correlation coefficient (BSIM4's `tnoiMod`, PSP's `igid`). `name` is the
LRM's optional label, for grouping a noise report; it says nothing about
correlation.

`noise_tables` holds LRM §4.6.4.3/.4 `noise_table` and `noise_table_log`
spectra as `(frequency, power)` knots (`NoiseTable`, sorted, checked by
`validate`); `contract.noiseTableAt(t, f)` interpolates one, clamping to the
end values outside the table as both clauses require. When a table's knots
are model parameters the device also declares `noiseTablePoints(&model)`,
which returns the card's knots, and `derive` stores them, sorted, in the
row's own `Model.noise_table_points__` (a plain `[n][2]f64`, so it is copied
with the row to a GPU or a row tape). Read every table through
`contract.noiseTable(D, &model, k)`: the row's knots for such a table,
`noise_tables[k]` for any other; its `points` point into `model`.
`validateHost` requires your host to declare `noise_table_points = true` for
such a device, because reading only `noise_tables` would silently use the
defaults.

## AC stimuli

`ac_gens` lists LRM §4.6.3 `ac_stim` calls: position `k` is a stimulus on
`(row, col)` active only in the small-signal analysis named `name`
(`contract.acStimActive(name, kind, label)`: "ac" and "noise" are those
kinds, any other name the analysis you label with it), and
position `k` of `acStim(S, x, ...)` is its phasor `mag · e^(j·phase)`
(`AcPhasor`, phase in radians; `mag` may be negative, never take its
absolute value). The resistive residual carries only the phasor's real part,
so a host solving a complex small-signal system reads this table instead of
that residual term; adding both counts it twice.

## Frequency-dependent partials

A partial that flows through LRM §4.5.7 `absdelay`, §4.5.11 `laplace_*` or
§4.5.12 `zi_*` depends on frequency. Such a device lists the local Jacobian
slots (`row * n_u + col`) in `ac_dyn_slots`; under kind `.ac` or `.noise`,
`eval`, `q` and `evalQ` omit those partials, and
`acDyn(F, &model, &inst, &x, sim, omega, &out)` writes the omitted part of
each slot, so your small-signal matrix is

```text
A(ω)[slot] = G[slot] + jω·C[slot] + out[k]
```

`F` is `f64` or a vector of frequencies. `validateHost` requires a host to
declare `calls_ac_dyn`: `true` once every small-signal matrix adds `acDyn`'s
terms, `false` if it runs no small-signal analysis.

## Per-unknown metadata

| Declaration | Meaning |
|---|---|
| `u_kinds: [n_u]UnknownKind` | `voltage`, `current` or `flow` per unknown, for picking a tolerance (`vntol` against `abstol`) and units |
| `u_abstol: [n_u]f64` | LRM §3.6.1.2's `abstol` of each unknown's nature, after any §3.6.2.3 discipline override: the absolute half of a Newton stopping test |
| `u_nodeset: [n_u]?f64` | LRM §3.6.3.2 net initializers (`electrical n = 5.0;`): a starting guess, not a condition the solve must hold |

## Host-written fields

Some `Instance` fields are yours to write when present (`@hasField`), with a
fixed name and type that `validate` checks: `mfactor` (LRM §6.3.6
`$mfactor`; the device leaves the scaling of its rows to you), `bound_step`
(written by the device), `plusargs` (your command line, for
`$test$plusargs`), `cwd` and `analysis_name` (for `$simparam$str`). The last
two are host pointers; a host that copies Instances to a GPU or binds only
numbers writes their twins instead, `Model.cwd_idx__` and
`Model.analysis_name_idx__` (`u32`), indices into the table it puts in
`contract.host_strings` (0, the default, is "not written"). The device reads
the table on the CPU only. The `Model`'s other `__` fields are on
[the device page](device.md).

## The rest

| Declaration | Meaning |
|---|---|
| `decl_meta` | the module's LRM §2.9.2 `desc` and `units` attributes, one `DeclMeta` row per parameter, output variable or net that has one, for a help message or an operating-point report. Read by no entry point |
| `mc_param` | the name of the float field of `Model` or `Instance` Monte Carlo varies |
| `status_sites` | the device's `$fatal`/`$error` calls ([state](state.md)) |
| `say_sites`, `say(S, &x, &model, inst, sim, &out)` | the LRM §9.4 display tasks (`$strobe`, `$display`, `$write`, `$debug`, `$warning`, `$info`) as records: call `say` once per accepted point with a `contract.Say` buffer, then `contract.formatSay(D, &out, name, writer)` prints them. LRM §9.4.1 shows `$debug` at every iteration: a host that does so also calls `say` after each Newton iteration with `Say.pass = .iteration`, then `.accepted` at the accepted point. `$monitor` and a non-constant string argument are not recorded (W0850) |
| `display(S, &x, ...)` | the display phase of an artifact built with `--display=emit`, which prints from inside the device instead of recording; per accepted point, and a `$finish` inside it exits the process |
| `file_io: FileIo` | the device's LRM §9.5 descriptor table, for a mixed simulation whose digital half must share descriptors (§9.5.1.2) |
| `systf_calls` | `$name`s the compiler left to a VPI application (LRM §2.8.3, §12.32), one entry per call site. Point `inst.systf` at a `SystfHost`, whose `call(ctx, k, args, partials)` returns call `k`'s value and its partials (and whose optional `out` answers the arguments the application wrote, LRM §12.22.2); `validateHost` requires your host to declare `systf`, a `fn (*const Model) ?*const contract.SystfHost` |
