# Design review: #51, `$simparam` in a parameter default

- **Change**: one owner, `Lowered.simparamAnswer`, classifies a §9.15
  `$simparam(name [, expression])` as run-time, host field, VerA's own value,
  fallback or unknown; the analog block (`codegen/call.zig`), the
  parameter-default fold (`Analysis.foldStep`) and the `derive()` renderer
  (`host_expr.f64Const`) all switch on it. The two parameter paths used to
  handle only the host field, so a known name (`scale`) or an unknown name with
  a fallback (`minr`) read 0 with W1050.
- **Domain skill(s)**: `compiler-construction` (FIXTURES.md).
- **Hot/cold**: cold — evidence: none. All three run once per call site at
  compile time; the emitted device text for a `$simparam` in an analog block is
  unchanged.
- **Stages run**: R6, R7 (bug fix, §10.1).

## Containment (R6)

| Module | Error set | Boundary validation | Check budget (Principle 17.10) | Bounds |
| ------ | --------- | ------------------- | ------------------------------ | ------ |
| `ir` `lower/tables.zig` | none (pure) | the name is source input; an unknown literal without a fallback is still E0811 in `lowerSysCall` | one `.?`: every `host_simparams` row has a `simparamValueIn` default (a programmer error otherwise, pinned by the unit test) | no loop beyond `host_simparams`' six rows |
| `ir` `analysis.zig` | unchanged | none new | none new | the fold column's existing sweep bound |
| `backend` `call.zig`, `host_expr.zig` | `Error` (unchanged) | none new | none new | `f64Const`'s existing `depth` |

The switch over `SimparamAnswer` names every prong in all three users, so a
new class is a compile error at each.

## Test plan (R7)

| Bug class | Oracle | Layer | Tier | Harness / file |
| --------- | ------ | ----- | ---- | -------------- |
| a path answers in a different order | §9.15 + VD-072 values, by hand | unit | merge | `tables.zig` test `simparamAnswer` |
| a known name in a default falls to W1050 / its fallback | `shrink` = 1 (VD-072) | unit | merge | `codegen/test.zig` "§3.4 a default with no compile-time value is W1050" (now `small`) |
| an unknown name's fallback lost in a default | `1e-3`, `2e-3`, and `scale` → 3.0 not 6.0, by hand | fixture | merge | `ch09_system_tasks/simparam_fallback_as_parameter_default.va` |
| the upstream HICUM/L2 3.2 spelling | `minr` = 1e-3 and the `r >= minr` gate, by hand | fixture | merge | `ch09_system_tasks/simparam_minr_hicum_l2_default.va` |
| a run-time name read as a card-time constant | still W1050 (`dt`) | unit | merge | the same codegen test (`hot`) |

The missing oracle (Principle 19.4): the W1050 codegen test pinned the bug,
using a known name (`shrink`) as its example of "no compile-time value". It
now uses `dt`, and the `simparamAnswer` unit test fixes the order once for
all three readers.

Exit criteria: `zig build test` exits 0; both fixtures pass `//! nowarn` with
their VERDICTS.tsv rows; goldens move only where a default reads `$simparam`.

## Results (2026-10-17, base 44c80994)

- Fixture suite: 2612/2612 at base, 2614/2614 here (the two new fixtures);
  FAIL/XFAIL name lists both empty.
- `zig build test` exits 1 on both trees for the same two pre-existing steps:
  `backend` (`orchestrator.zig` test `linkArgv` trips its own
  `objs.len >= Part` assert, from 654bc5eb) and `printf_reference` (64 of
  129536 special conversions differ from glibc). With `linkArgv` skipped
  locally, `test-backend` runs 332/333 passed, 1 skipped.
- Goldens: 6 files move, all with a `$simparam` the literal fold now answers
  (a VerA constant or an unknown name's fallback no longer counts as a
  card-dependent value): `22_simparam`, `157_simparam_timescale`,
  `179_limit_initialize_limiting`, `a10_07_simparam_dynamic_name`,
  `combined/09_optional_port_environment`, `exhaustive/120_environment`.
  Each drops `setup` slots (and the names from `setup_simparams` a host
  cannot write) and computes the same constant in `eval`.
- Upstream `hicumL2_v320.va`: W1050 on `minr` at base, none here.
