# Seam notes: s1-elab (UNITS.md U48)

Step-1 agent for `lib/ir/elaborate.zig` and `lib/ir/elaborate/**`. Base
`64357568`. Nothing outside that set was edited; every proposal below is for
the seam agents. Goldens byte-identical after every commit.

## Spine and ownership after step 1

`elaborate` (root): `alias.checkSource` → the §6.6 generate-instance table
(`Flatten.gen_instances`, one walk per module) → `pickTop` (one pass over
every instance) → E.3.3/§7.7/A.2.1.3/§7.4.2 checks → tree-of-one shortcut or
`Flatten.run`. `run`: seed the top unrenamed → `instance.walkInstances`
(per level: `override.collectDefparams`, `resolve.collectOoc`,
`insert.plan`, primitive attributes, then per instance `inlineInstance`:
ports, `override.collectOverrides` or `paramset.paramsetOverrides`, names,
`clone.*`, recurse) → E.3.2.2 primitive ports → `resolve.resolveMultiCandidates`
→ `override.reportUnusedDefparams` → publish through the `fate` table →
`alias.checkFlat`.

| file | owns (writes) |
|---|---|
| `elaborate.zig` | public types, `Ctx`, the spine, `pickTop`, `fate`, `Flatten` state |
| `instance.zig` (new) | the §6.2.2 walk: declaration lists, `unit_paths`, `names`, `implicit_nets`, `unconnected_inputs`, `port_concats`, `port_widths`, `ps_hidden`, `prim_ports` |
| `override.zig` (new) | §6.3/§6.3.1/§9.18/§9.19: `defparams`, `paramset_defparams` |
| `paramset.zig` | §6.4.2 selection, §6.4 paramset overrides; `selection_params` |
| `resolve.zig` | Annex F.2: `nets` (only via `addNet`), `disc_of`, `segs`, `port_resolved`, `ooc`, `signal_disciplines` |
| `clone.zig` | the AST clone; `expression_aliases`, `attribute_disciplines`, `pending_attributes` (settled by resolve) |
| `insert.zig` | §7.8.4 connect insertion: `inserts` |
| `names.zig` | name joining (`PathKey`, `join`, `bind`, `flat`), module lookup, access respelling, folding |
| `alias.zig` | §3.4.7 alias-read checks (no tables) |

`Flatten.unit` is the namespace in force, swapped by `inlineInstance`,
`collectOverrides`, `paramsetOverrides` and `clone.paramsetOomr`; it is the
one piece of shared mutable state several files write, by design (a stack).

## Measurements

ReleaseFast, `-Dcpu=x86_64_v2`, `vera --emit-zig`. Elaboration Ir is
callgrind with `--toggle-collect=elaborate.elaborate` (only Ir inside
`elaborate()`); deterministic. `psp_x4` is `psp103.va` instantiated four
times under one top (scratch workload, 4 × 50k cloned expression rows);
`tree155` is a synthetic fanout-5 depth-3 tree of parameterised leaves with
a defparam per level (155 instances); `tree64` is
`tests/fixtures/ch06_hierarchy/instance_tree_64_levels.va`, the deepest
fixture. The ARPice models are single modules: they take the tree-of-one
shortcut, so only the pre-walk work (`pickTop`, generate scan, checks) runs.

| workload | elaboration Ir before | after | change |
|---|---|---|---|
| psp103 | 903,545 | 454,965 | −49.6% |
| bsim4va | 663,602 | 334,955 | −49.5% |
| hisimhv_va | 1,530,540 | 768,660 | −49.8% |
| psp_x4 | 62,243,754 | 58,942,647 | −5.3% |
| tree155 | 4,918,683 | 4,120,551 | −16.2% |
| tree64 | 1,010,600 | 694,396 | −31.3% |

Whole-compile share of elaboration (before): psp103 0.07% of 1.36G Ir,
psp_x4 0.37% of 16.7G, tree155 12% of 39.9M. Peak RSS and wall time, best
of 7, interleaved runs (machine shared with other agents): psp103
30.5 → 29.6 MB, bsim4va 22.2 → 22.5 MB, hisimhv_va 47.3 → 47.2 MB, psp_x4
519.0 → 521.3 MB; all within the ±1.5 MB run-to-run spread, times within
noise (0.14-0.22 s, 0.11-0.16 s, 0.23-0.33 s, 4.6-6.0 s on both binaries).
Elaboration's own allocation is a few percent of peak even on psp_x4 (see
seam 1), so no RSS change was expected.

## Memory

Counts are rows alive at the end of elaboration; psp103 alone is the tree of
one, so every flatten table is empty there (0); psp_x4 / tree155 counts in
parentheses come from a temporary instrumented build (not committed).

| type | size before → after | count on psp103 (psp_x4 / tree155) | bytes saved | what changed or why not |
|---|---|---|---|---|
| defparam/ooc lookup keys (`print` of `path ++ name`) | ~16-40 B garbage per probe → 0 | 0 (about one probe per parameter, alias, system parameter and port of every instance: ~850 per psp103 instance / ~1.5k) | all of it, plus Wyhash of a heap copy | `names.PathKey` + `getAdapted`: hash streamed over the two halves, no allocation |
| `Flatten.ooc` value | `Ast.NetDecl` 64 B → `Ast.StrId` 4 B | 0 (0 / 0) | 60 B per out-of-context declaration | only `.discipline` was ever read (E0902 message, `oocDiscipline`) |
| `Gated` (generate instance + scheme) | 80 B → removed | 0 (0 / 0) | 80 B per generate instance per level, plus a copy into `all` | `genInstances` appends instances and gates to two parallel lists; `all` is the one list |
| generate-instance lists | one list per (candidate × module) in `pickTop`, plus one per `inlineInstance` and one for the top | 1 per module, built once (~20 incl. Annex E prelude) | O(U·M) lists → M | `Flatten.gen_instances`, indexed by module; `pickTop` builds one instantiated-name set |
| `Segs.resolved` entry | key `usize` 8 + `?StrId` 8 = 16 B → 12 B | 0 (7 nets / 157 nets) | 4 B per cached level answer | arrival index fits `u32` |
| `Segs` | 96 B → 96 B, pinned | 0 (7 / 157) | 0 | three per-net containers (discs, paths, resolved); left: rows are few and the level walk (`levelOf`) needs per-net arrival order. A flat arrivals table sorted by net after the walk would remove two heap lists per net; not worth it at these counts |
| `override.Defparam` | 12 B, pinned | 0 (0 / 31) | 0 | already tight (`ExprId`, token, used flag) |
| `override.ParamBinding` | 12 B, pinned | 0 (transient) | 0 | already tight |
| `clone.HiddenName` | 12 B, pinned | 0 (one per block/function local per clone) | 0 | `?StrId` could take `.none` as its null niche (8 B) if no rename value is ever `.none`; not proven, left |
| `Flatten.Unit` | 160 B | ≤ depth + 2 live (stack) | 0 | four hash maps + `hier` (24 B) + path; one per live level, so size is irrelevant. Its maps are abandoned in the compilation arena when the unit pops (rename ≈ 9 B/entry × ~2.4k entries per psp103 instance ≈ 40 KB); freeing them needs a scratch allocator in `Ctx` (seam 3) |
| `Flatten` | 1328 B → 1344 B | 1 | −16 B | `gen_instances` slice added; one per compilation |
| `prim_ports` row | 80 B (`path` 16, `Ast.Port` 56, `bound` 4) | 0 (0 / 0) | 0 | a full `Port` copy where name/discipline/token are read; rows exist only for Annex E primitive ports. Left: an index would need the child module too, and the count is a handful |
| `pending_attributes` row | 24 B | 0 (0 / 0) | 0 | left |
| `Design` | 216 B | 1 | 0 | frozen (read by lowering); see seam 2 for its string-typed tables |
| `UnitPath` / `Inserted` / `PortWidth` / `PortConcat` / `NameSite` / `SignalDiscipline` / `ParamsetDefparam` | 40 / 112 / 32 / 48 / 24 / 32 / 24 B | 0 (units 5 / 157; inserts 0 / 0; signal disciplines 16 / 312) | 0 | frozen public rows, slices where `StrId` would do; seam 2 |
| cloned AST rows (`Ast.Node` 24 B SoA, `Ast.Stmt` 112 B + 4 B token, pool words, interned names) | unchanged | 0 (199,924 expr rows, 32,640 stmts, 12,564 pool words, 9,666 strings / 4,299, 530, 250, 722) | 0 | inherent to flatten-by-copy; seam 1. `Stmt`'s 112 B is s1-frontcore's |

`isPrimitive` is now an address-range test over Table E.1's contiguous rows
instead of a scan; `findModule` is still a linear scan over modules,
paramsets and the netlist (case-insensitive) per call, several calls per
instance. Not changed: no workload here shows it (5-20 modules); a
`StrId → module index` memo is safe (nothing it reads changes during
elaboration) once a netlist with thousands of subcircuits makes it show.

## Seam proposals

1. **Flatten by reference, not by copy.** Every instance deep-copies the
   child's whole body into the shared stores with renamed identifiers
   (`clone.cloneExpr`/`cloneStmt`): psp_x4 grows `file.exprs` from 50,899 to
   250,823 rows, statements from 8,239 to 40,879, interned strings from
   3,648 to 13,314. That is about 9 MB of 519 MB peak; the real cost is
   downstream, where lowering and codegen then process four textual copies
   (4.5 s vs 0.13 s for one psp103). A shared design would publish an
   instance table `{module index, path StrId, rename/override values,
   unit gate}` and let lowering lower a module body once per instance with
   that context (or once per distinct parameter binding). Callers that
   assume one flat module: `lib/ir/lower.zig:1092-1120` (`lowerModule` of
   `design.top`), `lower/expr.zig:434` (`flatReference` + `hier_names`),
   the VPI model (`src/vpi/model/analog.zig`), the mixed runner's flat
   discrete half. Large; a release of its own.
   A cheaper step inside the copy model: `cloneExpr` re-adds literal rows
   (`int_literal`, `real_literal`, `str_literal`, `pos_inf`, `neg_inf`)
   unchanged; returning the source id would share them. It is
   behaviour-identical only if no later stage keys per-occurrence state on
   a literal's `ExprId` (lowering's diagnostics de-duplication and
   `markDiscreteExprs` are the ones to check). Needs s1-lower's confirmation.

2. **`Design`'s string-typed tables.** `names` (`StringHashMap([]const u8)`),
   `UnitPath.module`/`.path`, `Inserted`'s seven slices (112 B a row),
   `PortWidth.net`, `PortConcat.name`/`.elems`, `NameSite.name`,
   `SignalDiscipline` (two slices), `ps_hidden` and
   `ParamsetDefparam.instance` all hold `[]const u8` where every value is
   already interned (`Ast.StrId`, 4 B): `Inserted` would be 28 B,
   `SignalDiscipline` 8 B, `NameSite` 8 B, and `UnitPath.decl` could be a
   module index. Readers slice and print these paths
   (`lower/contrib.zig:581`, `lower/hier_name.zig:338`, `lower/stmt.zig:210`,
   `backend/tb/runner.zig:577`, `src/sim/digital/driver.zig:68`,
   `src/vpi/model/analog.zig:115`), so the change is a reader-side
   `file.str(id)` at each. Row counts are small (instances, bridges,
   bound ports), so this is consistency more than memory.

3. **A scratch allocator in `Ctx`.** `Ctx` carries only the compilation
   arena, so every per-instance working map (`Unit.rename`/`connected`/
   `given`/`port_disc`, `over`, the `concats`/`widths` lists) outlives its
   instance. Adding `gpa: std.mem.Allocator` (caller: `lib/ir/lower.zig:1092`)
   would let `inlineInstance` put them in an arena freed when the unit pops.
   Measured saving on psp_x4 is about 0.2 MB, so low priority.

4. **Stale comment references outside this unit.** The walk's helpers are
   now free functions in `elaborate/instance.zig`: `Flatten.genInstances` is
   cited at `lib/frontend/parser/test.zig:888`,
   `lib/frontend/parser/generate.zig:209`, `lib/frontend/ast.zig:1395`;
   `Flatten.walkInstances` at `lib/frontend/parser/hier.zig:26`.
   `Elaborate.primitiveAccess` (`lib/frontend/parser/inst.zig:46`) was
   already `elaborate/names.zig`'s before this step. `Elaborate.max_depth`
   and `Elaborate.pickTop` (cited in `src/vpi/root.zig`) still exist.

## Bugs found

1. **`clone.joinLocal` derives the unit's path from an arbitrary rename
   entry** (`lib/ir/elaborate/clone.zig`, `joinLocal`, the `sample` lines).
   It takes the first entry the hash map iterates and cuts at its last
   `sep`. A port bound to the parent's net renames to a parent-namespace
   name (`p`, or `u.n` one level up), so when that entry comes first a
   §5.3.2 block label is joined against the parent's path or left
   unrenamed. Which entry comes first depends on hash order of `StrId`
   values, i.e. on unrelated interning order. Trigger shape: a child whose
   only module-level names are ports connected to parent nets, with a named
   block (`analog begin : blk ... end`), instantiated twice; both copies get
   label `blk` instead of `u1.blk`/`u2.blk`. Observable only through
   something that resolves the label (`disable blk` inside the child,
   §6.7 references to block-scope names, which VerA currently answers
   E0901 anyway), so not confirmed end to end. Expected: join against
   `self.unit.path`, which is exactly the prefix wanted.
