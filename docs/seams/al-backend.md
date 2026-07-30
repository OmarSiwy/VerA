# al-backend: `std.ArrayList` inventory of `lib/backend/`

Scope: every `std.ArrayList` declaration under `lib/backend/` at 5968850a
(118 declarations; the other 45 mentions are parameter or return types).
Kernel files (`lib/backend/kernels/`) hold none.

## ArrayList

### A: bounded by a declared limit (5, now fixed storage)

| Site | Bound |
|---|---|
| `cg_display.zig` `ops` (display, string format, file write) | `max_format_args` = 32 (E1010). `Ops` is `[32]PrintArg` plus a count. The count keeps going past 32 so E1010 still reports the call's real operand count. |
| `codegen/render.zig` `emitRng` `fn_name` | `"zRng"` plus the longest `Mir.Callee` tag, computed at comptime; a stack buffer. |
| `cg_filters.zig` `planFilter` `lets` | at most one `zRootSecs` let per side, so 2 |

### B: size known before filling (12, now allocated once)

| Site | Size |
|---|---|
| `codegen/setup_chunk.zig` `chunk` `all` | `countScalar('\n') + 1` over the body text |
| `codegen/setup_chunk.zig` `stripTail` `out` | `last + then + 2 (+ else + 1)` |
| `codegen/unit.zig` `sliceCore` `vals` | `countScalar(bool, keep, true)` |
| `codegen/unit.zig` `Hoist.grp`, `Hoist.pos` | one entry per hoist element (`n`) |
| `codegen/dispatch.zig` `emitAcDyn` `slots` | popcount of `dpat` rows (a whole row when folded above 64) |
| `codegen/plan/setup.zig` `postDominators` `stack`, `dfs`; `solve` `stack`; `timepointVarying` `stack` | each block is pushed at most once (`nb`, `nb + 1` with `exit`) |
| `tb/runner.zig` `opStates` | count of `.op_state` node kinds |
| `orchestrator.zig` `linkArgv` | head + strip + objects + engine |

### C: stays an ArrayList (101)

- **Emitted text** (`Gen.out`, `cg_display` `fmt`, `setup_chunk` `out`/`b`,
  `file.zig` `p`/`hz`, `noise.zig` `body`, `cg_filters` `t`,
  `orchestrator` `body`, `tb/exe` `root`, `tb/runner` `out` ×3, tests): the
  length depends on rendering.
- **Filtered, deduplicated or accumulated tables** whose length is a
  predicate over the input (`plan/core` `vals`/`pv`/`pl`/`qv`/`ql`,
  `cg_limit` `vals`/`seen`, `setup.zig` `vals`/`names`, `plan/jobs`,
  `plan/noise` ×6, `plan/qsite` ×3, `plan/topology` ×2, `plan/jac`,
  `plan/limit` ×6, `plan/names` `extra`, `state.zig` `tds`/`timers`,
  `unit.zig` `seeded`, `Gen.systf_names`/`hist`/`fam_masks`,
  `dispatch.Jac.guarded`, `setup_chunk` `fields`/`State.pieces`,
  `plan/setup` `merges`, `tb/runner` `shapeOverrides`, `naming`
  `enumerateUnits`): an exact count would repeat the filter, and these hold
  tens of entries.
- **Value worklists bounded only by `nv`** (`UnitPlan.live`, `UnitPlan`
  `work`, `plan/core` `Mark.work`): a unit's slice is a small part of `nv`, so
  allocating to the bound would raise peak RSS. They are reused across units
  (`clearRetainingCapacity`).
- **Per-body scratch reused across bodies** (`Probe.place`/`sc_end`/`sc_open`,
  `Hoist.idx`/`mask`/`gmask`/`glen`): `place`, `idx` and `mask` already fill
  with one `appendNTimes(n)`. The scope stack and the mask groups depend on
  the emitted text.
- **User input** (`tb/directive.zig` ×21: fixture header directives).
- **argv builders** (`orchestrator` `buildArgv`/`buildEngine`, `tb/exe`
  `argvHead`, which callers extend): one-shot lists of about 30 entries. A
  count formula would have to repeat every conditional append.

### Lists another unit owns that this one reads

`Lowered.contributions`, `held_vars`, `charge_sites`, `mem_arrays`,
`limit_slots` and `table_samples` (al-ir) are read through `.items` only.
`held_vars` is also shrunk in place by `plan/setup.pruneHeld`. Their shapes
are unchanged.

### C lists a seam change could move

- `naming.enumerateUnits`: if lowering recorded its operator-call count
  (it already walks those calls), the unit table could be sized
  `contributions + op_calls`.
- `plan/core.plan` `vals`: if `Lowered` counted `path_prev`/`path_acc`
  instructions, the bound would be `jobs + latches`.
