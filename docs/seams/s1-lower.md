# s1-lower: the IR lowering unit (U51)

Step-1 notes for `lib/ir/lower.zig` and `lib/ir/lower/`. Branch
`worktree-agent-a89ab66b4563a2415`, from `1d3618f8`. Every commit kept the
`vera --emit-zig` goldens byte-identical (3228 fixtures).

## Spine and ownership after step 1

`Lower.lower` → `lowerFile` (elaboration) → `lowerModule`, which is one line
per step, in this order: disciplines (discipline.zig), parameters
(`param.lowerParams`), discrete inputs (context.zig), ports and nets
(`node.declarePorts`, `declareNets`, `bindPortConnections`,
`resolveDisciplines`), aliasparams (`param.declareAliasParams`), branches
(`node.declareBranches`), variables (`var.markHeldVars`, `markMemArrays`,
`declareVarDecl`), the analog blocks (stmt.zig, and below it expr, control,
contrib, analog_op, event, systask, random, func, ...), then the end-of-block
reads and `systask.finishKernelCtl`/`finishDisplays`.

Each `Lowered` table has one writer: `nodes`/`vectors`/`flow_unknowns`
node.zig; `params`/`aliases` param.zig; `held_vars`/`mem_arrays` var.zig;
`contributions`/`charge_sites` contrib.zig; `displays` and the status channel
systask.zig; `rng_auto_seeds` random.zig; `timer_controls` event.zig;
`timepoints` stmt.zig; `limit_slots` limit.zig; `disciplines` discipline.zig;
the `discrete_*` tables context.zig. `uses` is a flag set any file may raise.
A sub-file's private state is its `State` on `Lower`, touched by that file
alone (event.zig's timer capture is now reached through `captureExpr`,
`replayedExpr` and `suspendCapture`, not by expr.zig and func.zig directly).

New files: `systask.zig` (§9.4/§9.5/§9.7/§9.17 statement tasks, from
event.zig and lower.zig), `random.zig` (§9.13, from event.zig), `var.zig`
(§3.2 variables, scopes, retention, from param.zig), `shape.zig` (array
shapes and assignment patterns, from param.zig). `Lowered`'s row types moved
from lower.zig into `tables.zig`; `Lower.<Name>` still resolves to each.

## Seam proposals

1. **Stale paths outside the unit.** The splits moved code that these
   non-owned files name by path. Nothing breaks; the text is wrong.
   - `docs/IMPLEMENTATION.md`: line 23 (`scratchOn`, now `lib/ir/lower/var.zig`),
     24 (`lowerKernelCtl`, now `systask.zig`), 26 (`lowerStatus`, now
     `systask.zig`), 42 (`lowerRandom`, now `random.zig`), 250 (`max_cells`,
     now `shape.zig`), 309 (the timer check is still `event.zig`; fine).
   - `docs/ROADMAP.md:320`: "`lib/ir/lower/param.zig` says nothing can observe
     it" is now `var.zig`.
   - `lib/backend/codegen/call.zig:1125` names `lower_event.lowerKernelCtl`
     (now `lower_systask.lowerKernelCtl`); `lib/backend/codegen/plan/setup.zig:639`
     names `lower_param.Exposed` (now `lower_var.Exposed`).
   - Fixture comments (`m01_02`, `m01_03`: `lib/ir/lower/param.zig scanHeld`;
     `s01_05`: `lower_event.armMonitor`) are out of scope for every step-1
     agent; whoever next edits those fixtures should update them.
   - `docs/UNITS.md` is generated: rerun `zig build archmap`.
   - Comments elsewhere spell `Lower.foo` for functions that live in a
     sub-file (`Lower.lowerRandom`, `Lower.armMonitor`, `Lower.finishDisplays`,
     ...). They never resolved literally; the names are unchanged, so grep
     still finds them.

2. **MIR growth garbage in the shared arena (owner: `lib/ir/mir.zig`).**
   Lowering runs in the caller's arena, and MIR's `insts`/`values`
   MultiArrayLists and its `u32`/`Value` payload lists grow there by
   reallocation, so every outgrown copy stays allocated until the arena dies.
   Measured with a counting allocator over `Lower.lower` (bytes requested):
   `MultiArrayList(InstRow)` 2.49 MB on psp103 and 12.8 MB on hisimhv_va,
   `MultiArrayList(ValueRow)` 0.91 / 4.63 MB, and `ArrayList(u32)` (most
   likely MIR's payload pool) 0.16 / 2.06 MB. Under doubling growth about half
   of each is dead copies: an estimated ~9 MB of hisimhv_va's ~50 MB peak RSS.
   Options, cheapest first: give `Mir` its own growable allocator (a GPA, so
   a reallocation frees the old block) and keep only the finished tables in
   the arena; or add `Mir.reserve(insts, values)` and let lowering pass an
   estimate from the AST size. Callers: `lib/root.zig` (creates the `Mir`),
   `Lower.init`, every `mir.emit*`.

3. **A lowering-private scratch arena.** Everything lowering-only (`vars`,
   `arrays`, `scope_log`, the sub-file `State`s, the retention walk, the
   `isStaticValue` scratch) lives in the caller's arena until codegen ends.
   On psp103 that is ~1 MB of the 5.0 MB lowering allocates. A second arena
   owned by `Lower` and freed in `deinit` would return it before codegen
   peaks. Not done here: many name strings flow from the private tables into
   `out` and MIR (`held_vars[].name`, `nodes.name`, callee names), and each
   would need an audit to stay in the caller's arena. Callers: `Lower.init`,
   `lib/root.zig`.

4. **Narrower `Lowered` rows (frozen shapes).** The backend reads these field
   by field, so step 1 only pinned their sizes. Per model they are short (psp103:
   847 `ParamInfo`, 12 `Node`, 18 `Contribution`), so the gain is ~25 KB per
   model; worth doing only alongside other changes to these readers.
   - `ParamInfo` 88 B: `name` (a 16 B slice) as a `u32` string-table id;
     `integer32`, `is_local`, `shape` and `source_signed: ?bool` as one packed
     flags byte; `source_width: ?u32` as `u16` with a sentinel. About 56 B.
   - `Node` 72 B (already SoA): `name` and `disc` as interned ids.
   - `Contribution` 48 B and `HeldVar` 56 B: `noise_srcs`/`inits` slices as
     `u32` start/len into one pool each.

5. **`Lower.unaryMathOp`/`binaryMathOp`/`simparam*`.** Codegen calls these
   lowering functions to classify names it meets (`codegen.zig:597`,
   `call.zig:323/592/983`, `plan/setup.zig:221`, `analysis.zig:1018`). They are
   name → opcode/field tables, not lowering: their natural home is the callee
   table (`lib/ir/callee.zig`) beside `Callee.fromName`, so codegen would stop
   importing the lowering pass for a table lookup.

## Bugs found

- `lib/ir/lower.zig`, `lowerModule`, the §5.10.4 named-event loop:
  `if (ev.dims.len != 0) return self.err(...)` returns from `lowerModule`, so
  nothing after it is lowered or diagnosed. Trigger: a module with
  `event ev[0:1];` and an analog block reading an undeclared name. Expected:
  E0235 and the undeclared name's error ("one run reports many errors",
  `Lower.Oom`'s doc). Actual: E0235 alone.
- The same E0235 reads "not supported inside a generate block: §5.10.4: a named
  event array in an analog device" for an array declared outside any generate
  block: the code's title is about generate blocks (note cites LRM 6.6.2).
  Expected: a code whose text is about the event array.

## Memory

Method: `data-oriented-design` (SKILL.md, zig.md, REFERENCE.md,
foundations.md, measurement.md). Sizes from `@sizeOf` on x86_64; counts from
a throwaway instrumented Debug build on the ARPice models (psp103 unless
noted); bytes are what lowering requested from the arena (a counting
allocator over `Lower.lower`, so outgrown copies count), because the arena
never returns them before codegen ends.

Arena through `Lower.lower`, before → after: psp103 9.78 → 4.92 MB,
bsim4va 6.06 → 3.76 MB, hisimhv_va 28.3 → 22.3 MB (most of what remains is
MIR's growth, proposal 2).

Peak RSS and time, ReleaseFast `vera --emit-zig`, base `1d3618f8` against
`8c53951c`, the two binaries run alternately, best of 20 each (the machine
was shared, load average ~26; a best-of-N peak RSS still moves ~1 MB between
sessions, so compare within a row):

| model | peak RSS before → after | CPU before → after |
|---|---|---|
| psp103 | 32.4 → 30.9 MB (-4.9%) | 139.1 → 132.1 ms (-5.0%) |
| bsim4va | 24.4 → 23.5 MB (-4.0%) | 99.9 → 96.6 ms (-3.3%) |
| hisimhv_va | 53.9 → 50.3 MB (-6.7%) | 226.5 → 219.1 ms (-3.3%) |

| type | size before → after | count on psp103 | bytes saved | what changed or why not |
|---|---|---|---|---|
| `isStaticValue` scratch (`Value` set, `Block` set, worklist) | per-call maps → `control.State`, reused | ~5k walks | 3.58 MB psp103 | Every condition allocated fresh sets in the arena and dropped them. Now cleared and reused; nested walks share the worklist above a base mark. |
| `readsUnknown` visited set | per-call map → `analog_op.State`, reused | one per `idt` | (in the row above) | Same fix, its own owner. |
| `Exposed.ws` (write targets per statement) | per-statement list → one buffer | every statement | 0.70 MB psp103 | Refilled per statement; `stmt` finishes with it before recursing. |
| `Exposed` sets (`defs`, `reads`, `writes`, `pend`, `reach`, `initial`) | 6 × `StringHashMap(void)` → 1 × `StringHashMap(Marks)`, `Marks` = packed u8 | 2397 keys (cap 4096) | ~133 KB psp103 | One key copy and one byte per key instead of six key copies. Consumers only probe the result, so order does not matter. |
| `ScopeEntry` | 88 → 24 B | 1543 rows (cap 1846) | ~183 KB psp103 | Both shadowed bindings inline (`?VarSlot`, `?ArrayInfo`); now two `u32` rows into append-only side tables. psp103 and bsim4va shadow nothing, hisimhv_va 42 variables. Size-asserted. |
| `out.params` / `param_values` growth | grown row by row → sized once | 847 | 135 KB | `ensureTotalCapacityPrecise` from the declaration count; array elements still grow it. |
| `heldKey` composed keys | one print per mention → interned | 0 on psp103; 4898 mentions on hisimhv_va | ~0.8 MB hisimhv_va | `var.State.held_keys` holds one copy per `<block>.<name>`. |
| `ParamInfo` | 88 B | 847 | 0 | Frozen: codegen and the prover read it field by field. Narrower shape in proposal 4. Size-asserted. |
| `Node` (`nodes`, MultiArrayList) | 72 B | 12 | 0 | Already SoA. Interned names in proposal 4. Size-asserted. |
| `Contribution` | 48 B | 18 | 0 | Frozen; few rows. Size-asserted. |
| `ChargeSite` | 24 B | 9 | 0 | Frozen; already tight. Size-asserted. |
| `HeldVar` | 56 B | 9 | 0 | Frozen; few rows. Size-asserted. |
| `NoiseSrc` | 56 B | 16 noise calls | 0 | Frozen; few rows. Size-asserted. |
| `MemArray` 32, `LimitSlot` 40, `TpBlock` 32, `TpSlot` 32, `Display` 32, `StatusSite` 24, `DiscreteEvent` 40, `Alias` 24, `Nodeset` 16, `VecRange` 16, `DisciplineInfo` 56, `NodeKind` 16, `FlowKey` 4, `PortProbe` 4 | unchanged | 0-356 (`Display` 356 on bsim4va) | 0 | Frozen `Lowered` rows, all short per module. |
| `TypedValue` | 8 B | every expression result (transient) | 0 | Already a `Value` and a `u8` tag. Size-asserted. |
| `VarSlot` | 16 B | 1543 (`vars`, cap 2048) | 0 | `reg_width: ?u32` could be a sentinel `u32` (12 B, ~8 KB); `vars` is probed by name and its capacity decides nothing visible, but the saving is too small to churn every reader. Size-asserted. |
| `BranchRead` 12, `Accum` 12, `BranchInfo` 8, `LoopCtx` 8, `RetCtx` 20 | unchanged | 20, 18, 3, transient, transient | 0 | Already index-only rows. `BranchRead` and `Accum` size-asserted. |
| `ArrayInfo` | 40 B | 0 (no arrays in these models) | 0 | Mostly a 16 B slice of `Bounds`; rare. |
| `Bounds` | 24 B | per array dimension | 0 | Two `i64` and a bool: subscripts are signed and unbounded by §3.2. |
| `consts` (`StringHashMap(Const)`) | 24 B values; grown → sized once | 847 (cap 2048) | ~84 KB | Only ever probed by name (the VPI copies values out with `get`), so it is sized from the declaration count in `lowerParams`. |
| `vars`, `param_index` maps | — | 1543, 847 | 0 | Left growing: `didYouMeanMap` walks both, and a walk's order follows the capacity, so pre-sizing could change a suggestion. |
| `Lower` | 3352 → 3520 B | 1 | -168 B | Gained `control_state` and `analog_op_state`; one per compilation. |
| `Lowered` | 1112 B | 1 | 0 | One per compilation. |
| sub-file `State`s (node 72, event 72, systask 104, random 32, var 168, stmt 32, table_model 32, hier_name 80, control 80, analog_op 24) | — | 1 each | 0 | One each per compilation. |
| `DeferredDisplay` 88, `DeferredTimer` 112, `TimerArray` 80, `CapturedExpr` 48 | unchanged | 0 on these models (356 displays on bsim4va are not deferred) | 0 | Only display and timer sites; cold. |
| MIR tables (`InstRow`, `ValueRow`, payload pools) | — | 26k insts psp103, 129k hisimhv_va | — | Not this unit's (`mir.zig`); half their arena bytes are dead growth copies. Proposal 2. |
