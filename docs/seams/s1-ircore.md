# s1-ircore: IR core and proof (U14, U15, U23, U43, U44, U45, U49, U53, U55, U56, U57)

Step-1 notes for `lib/ir/{mir,opcode,callee,op,ssa,dist,discipline_rules,
hier_param,analysis,ifconv,root,proof}.zig` and `lib/ir/proof/`, written
2026-10-03 against base `cd42503a` (step-1 lowering merged).

## Spine and ownership after step 1

The IR stage's spine is `lib/root.zig` `compileInArena`. It runs
`Lower.lower` (which uses `SsaBuilder` and writes `Mir`), then
`codegen.pruneHeld`, `ifconv.run` and `proof.proveOpts`
(`Analysis.buildStructure` → `seedValues` → `buildClasses` →
`markSelectArms` → `walk` → `verdict`). Codegen then runs `Analysis.build`.

| File | Owns (writes) | Readers |
|---|---|---|
| mir.zig | `Mir`: `insts`, `blocks`, `defs`, `alias`, `extra`, `strings`, constant maps; `reserve` | everything after lowering |
| opcode.zig / callee.zig / op.zig | comptime fact tables per `Opcode` / `Callee` / `OpKind` | lowering, analysis, proof, codegen |
| ssa.zig | `SsaBuilder`: memo map (`dir`, `cells`, `arm_cells`), `block_state`, pools | lowering; `lower/control.zig` reads `block_state` |
| analysis.zig | `Analysis`: CFG, dominators (`kid_pool`), loops, per-block pools, per-value columns | proof, codegen |
| ifconv.zig | rewrites `Mir` in place (selects, relinks) | — |
| proof.zig, proof/prover.zig | `Prover` tables (scratch arena), `Verdict` | `lib/root.zig`, codegen |
| proof/lattice.zig, proof/transfer.zig | pure `Interval` algebra and transfer functions | prover, ifconv (`isPredicateValue`) |
| dist.zig, discipline_rules.zig, hier_param.zig | static rule tables over the AST | elaboration, lowering |

Second writers of `Mir` (single-owner violations, proposals 4 and 5 below):
`codegen/plan/setup.zig` relinks `insts.next` and `blocks.first/last` and
writes `extra`, and `ifconv.rewritePhi` writes `extra` and `insts.c`.

## What changed (all goldens and the 64 ARPice models byte-identical)

1. **SSA reads climb single-predecessor blocks without memoizing**
   (`readFrom`). Two thirds of Braun's memo writes landed in `if` arms.
   One `ensureState` per read and one cell lookup per join.
2. **The memo map is keyed by slot, not block.** A block gets a column at
   its first memo cell; arm cells (lowering's writes inside an arm) go to a
   per-block list behind a 32-bit place mask. Memo cells on psp103 fell
   1,692,741 → 587,701. The SSA builder resident at the end of lowering:
   psp103 10.3 → 4.1 MB, bsim4va 8.5 → 3.5 MB, hisimhv_va 15.5 → 7.7 MB.
3. **The prover reads aliases from `Analysis.alias`**, not `Mir.resolveAlias`.
4. **`Mir.reserve`, called from `Lower.lowerModule`** (proposal 1, done).
5. `Analysis.dom_kids` became a pool (`kid_pool`/`kid_off`, `domKids`). The
   prover's transfer functions moved to `proof/transfer.zig`. Comptime row
   budgets were added. Docs were refreshed.

Measured: ReleaseFast `vera --emit-zig`, base `cd42503a` → `ac1b9a65` plus
reserve. Peak RSS is the median of 9 alternating runs. Instructions are
`perf stat -e instructions:u`, `taskset -c 2`, min of 3. Callgrind is
`-Dcpu=x86_64_v2`.

| model | peak RSS | wall (best) | instructions | callgrind Ir |
|---|---|---|---|---|
| psp103 | 27.8 → 26.9 MB (-3.1%) | 0.12 → 0.10 s | 1366M → 1141M (-16.5%) | 1342M → 1116M (-16.9%) |
| bsim4va | 21.0 → 20.0 MB (-4.5%) | 0.09 → 0.07 s | 1004M → 762M (-24.1%) | 982M → 734M (-25.2%) |
| hisimhv_va | 43.9 → 42.8 MB (-2.5%) | 0.21 → 0.19 s | 2148M → 1800M (-16.2%) | 2123M → 1760M (-17.1%) |

Peak RSS moves less than the SSA saving because whole-run peak RSS is not
set in lowering (finding 1).

Final-tree check (2026-10-03, `ac1b9a65`, ReleaseFast, GNU time, best of 3):
psp103 0.10 s / 27.7 MB, bsim4va 0.07 s / 21.0 MB, hisimhv_va 0.18 s /
43.6 MB. These agree with the table within finding 2's ~1 MB build noise
floor. Gates on that tree: `zig build`, `zig build test`, `test-ir`,
ReleaseFast and ReleaseSafe builds all exit 0; goldens IDENTICAL.

## Findings

1. **Whole-run peak RSS is set by codegen's emit phase, not by lowering.**
   RSS traced at phase boundaries (`/proc/self/status` VmRSS, ReleaseFast),
   before → after this unit's changes:

   | model | end of lowering | after SSA free | after `Analysis.build` | whole-run peak |
   |---|---|---|---|---|
   | psp103 | 26.4 → 20.3 MB | 16.1 MB | 19.0 MB | 28.3 MB |
   | bsim4va | 22.3 → 17.4 MB | 13.9 MB | 17.6 MB | 22.0 MB |
   | hisimhv_va | 39.5 → 31.8 MB | 24.0 MB | 32.8 MB | 44.4 MB |

   The 9-12 MB between `Analysis.build` and the peak are codegen's. Massif
   (`--pages-as-heap=yes`, psp103, x86_64_v2 build) puts the peak at the end
   of the run, 46.3 MB mapped. The largest identifiable contributors are
   `setup_chunk.zig:183` `chunk` under `emitSetup` (4.2 MB, 9.1%),
   `plan/unit.zig:137` `UnitPlan.init` (3.0 MB, 6.5%), and the
   `Io.Writer.Allocating` growth in `setup_chunk.indent`/`stripTail`/`pieces`
   (2.9 MB, 6.2%). The next memory pass should target codegen's emit
   buffers (owner: s1-codegen), not lowering.
2. **Peak RSS has a ~1 MB noise floor between builds.** Two binaries that
   differ only in code layout differ by ~1 MB of whole-run peak RSS, stable
   across runs (file-backed text pages count toward RSS). Compare RSS only
   within one A/B session, and distrust deltas under ~1 MB.
3. **Braun's dead phis on loop-heavy models.** On hisimhv_va, 100,621 of the
   131,196 instruction rows are phis, and 98,020 of them are aliased away
   (dead). The 404,689 `extra` words are mostly their operand pairs. The
   `coupled_ltra*` models look the same (8-9 instructions per AST
   expression, against 0.55 on psp103). Not changed in step 1, for two
   reasons: `tests/bench.zig` pins `mir.defs.len` and `mir.insts.len`
   exactly, and fewer phi rows renumber Values. Step 3 candidate:
   collapse a trivial phi before it gets a row on the loop path, as the
   `pending` trick already does for acyclic joins.
4. **`lower/analog_op.zig` `noiseCoeff` is 6.7% of hisimhv_va's
   instructions** (callgrind, inlined `mir.zig` reads of `defs` columns).
   It is lowering's, not this unit's (owner: s1-lower).
5. **AGENTS.md §5 counts two `@Vector` uses in the compiler. There is a
   third**: `proof/transfer.zig` `combine` (`@Vector(4, f64)` with
   `@reduce`, moved here from `prover.zig` unchanged). It is left as is and
   not extended. `proof/lattice.zig`'s measurement table is kept.
6. **`Analysis` fixpoints re-decode every value each sweep.** `fixDeps` is
   2.7% + 1.9% of hisimhv_va. Each sweep calls `valueDef`/`instData` per
   value for each of up to four columns. An operand CSR built once in
   `buildStructure` would serve `fixDeps`, `buildValueTypes`, `buildArrOf`
   and `buildFoldColumn`. Step 3.

## Seam proposals

1. **`Mir.reserve` from lowering's AST count: DONE** (`844cc55d`, `perf(ir):
   pre-size Mir from lowering's AST-count estimate`).
   `pub fn reserve(self: *Mir, gpa, insts: u32, values: u32, extra: u32) !void`
   is called once from `Lower.lowerModule` before the entry block. It
   reserves 0.59 instructions, 0.54 values and 0.50 extra words per
   elaborated AST expression, capped at 2^20 expressions. Each ratio is the
   median over the 13 compiles above 5000 expressions (the ARPice models).
   Data: 1,915 compiles (fixtures and ARPice). Compact models sit on the
   ratio (psp103 0.55/0.47/0.23, bsim4va 0.59/0.51/0.52). Loop-heavy ones
   overshoot it (hisimhv_va 2.04/1.95/6.30, coupled_ltra 8.2/8.0/21.5) and
   grow from the estimate as before. An over-reservation costs address
   space, not RSS: large tables are the backing allocator's untouched
   pages.

   Method: alternating A/B, median of 11 runs, HEAD → reserve. Peak RSS
   psp103 28.4 → 27.1 MB, bsim4va 21.4 → 20.2 MB, hisimhv_va 44.1 → 42.9
   MB. Instructions +0.9% / +1.8% / +0.3%.

   Context (s1-lower proposal 2): the compile arena has been a `BigArena`
   since `d492f89e`, so "bytes requested" (s1-lower's ~9 MB) overstates the
   resident waste. Exact pre-sizing on hisimhv_va measured 1.7 MB. The
   rest is MultiArrayList's copy-on-grow transient.
2. **`ValueRow.payload` u64 → u32.** Only float and integer constants need
   64 bits: psp103 has 163 of 23,859 values, hisimhv_va 249 of 125,521.
   Move their bits to a side `consts: ArrayList(u64)` and make `payload`
   the index. That is 9 → 5 bytes per value: 95 KB on psp103, 0.5 MB on
   hisimhv_va. Callers: `lower/analog_op.zig:664-668` reads
   `defs.items(.kind)`/`.payload` directly. Every other reader goes through
   `valueDef`/`valueKind`, so first route analog_op through those.
3. **`InstRow.block` (4 bytes per row).** It is written by `addInst`,
   `moveTailBefore` and `splice`, and read only by `instBlock`, whose single
   external caller is `lower/analog_op.zig:900`. `Analysis.def_block` holds
   the same fact after lowering. Dropping the column saves 4 of 29 bytes
   per row (0.5 MB on hisimhv_va) if that caller can name its block
   another way.
4. **`codegen/plan/setup.zig:697-717` edits Mir's internals.** It re-implements
   `Mir.unlink` on `insts.items(.next)`/`blocks.items(.first/.last)`, then
   writes a call argument through `mir.extra.items[insts.items(.b)[i] + 1]`.
   Better: call `mir.unlink(block, inst)` and add
   `pub fn setCallArg(self: *Mir, inst: Inst, i: u32, v: Value) void`
   (asserts a call and `i < count`). Then only mir.zig writes Mir's tables.
   `ifconv.rewritePhi` writes `extra` and `insts.c` in place too. It is
   mine, but a `Mir.rewritePhiPairs` beside `setPhiPairs` would keep the
   encoding in one file.
5. **`lower/control.zig:296-305` walks `SsaBuilder.block_state` and
   `pred_pool` directly** (`sealed`, `preds_head`, `preds_len`), and
   `lower.zig:835` asserts `builder.dir.len == 0`. Better:
   `SsaBuilder.isSealed(block) bool` and
   `SsaBuilder.preds(block) PredIterator`, and drop the `dir` assert, since
   `deinit` already resets the struct. Callers: those two sites.
6. **`Analysis.preds`/`succs` are `[][]u32`**: a 16-byte slice and an arena
   allocation per block, built twice per compile (prover, then codegen).
   Readers: `codegen/plan/setup.zig` (100-166, 477, 576),
   `codegen/plan/limit.zig:224`. Better: one pool each, with
   `predsOf(b)`/`succsOf(b)` like `domKids`, which this step did internally.

## Bugs found

1. **`proof/prover.zig` `walkDom` recurses on dominator-tree depth.**
   `Analysis.buildCfg`'s Euler tour uses an explicit stack because "large
   models nest deeply enough to blow a recursive walk". `walkDom` walks the
   same tree recursively, with a frame holding `raw: [2]Fact` (64 bytes)
   and more. To trigger it: a module with a chain of tens of thousands of
   sequential `if`s, where each join's idom is the previous join. Expected:
   the proof completes. Actual (by inspection, not reproduced): stack
   overflow. The fix is an explicit stack with the `saved` mark per frame,
   as `buildCfg` does.
2. **`ssa.zig` `readVariableRecursive` has the same ceiling at roughly a
   few frames per join** (the existing `ponytail:` note, now narrowed to
   joins only). Same trigger, same fix shape.
3. Not a behaviour bug: the `defsIndex` doc said the index went stale when
   `cells` regrew. Indices into `cells` are stable. The doc is fixed, and
   the join arm now relies on that stability.

## Memory

Counts are on psp103 (ReleaseFast, base `cd42503a`) unless noted. "SoA" is
bytes per row across a MultiArrayList's columns.

| type | size before → after | count on psp103 | bytes saved | what changed or why not |
|---|---|---|---|---|
| SSA memo map (`dir` + `cells`) | block-keyed, chunks 29% full → slot-keyed + `arm_cells`, 70% full | 1,692,741 → 587,701 cells | ~6.2 MB at the end of lowering (hisimhv_va ~7.8 MB) | Changes 1-2 above. Measured by VmRSS around `SsaBuilder.deinit`. |
| `SsaBuilder.BlockState` | 17 → 29 B SoA | 4,234 | -51 KB | `slot`, `arm_head`, `arm_mask`; the price of the slot map. Size-asserted. |
| `PredNode` / `IncompletePhi` / `UserNode` / `ArmCell` | 8 / 12 / 8 / new 12 B | 5,682 / 8 / 4,997 / 3,396 | 0 | Already index-only. Size-asserted. |
| `user_head` | 4 B per value | 22,983 | 0 | Dense by design (O(1) user-list head). |
| `Mir.InstRow` | 29 B SoA (32 AoS) | 27,760 | 0 | Frozen: codegen reads `op/a/b/c/next/tok` columns directly. `block` column: proposal 3. Size-asserted. |
| `Mir` table growth | doubling, copy-on-grow → `reserve` once | 27,760 / 23,859 / 11,821 | 1.2-1.5 MB peak (A/B) | Proposal 1, done. |
| `Mir.ValueRow` | 9 B SoA | 23,859 | 0 | Frozen (`analog_op.zig` reads `payload`). Proposal 2: 5 B. Size-asserted. |
| `Mir.BlockRow` | 8 B | 4,234 | 0 | Two handles; minimal. Size-asserted. |
| `Mir.alias` | 4 B per value | 23,859 | 0 | Union-find parents; codegen and SSA need it. |
| `Mir.extra` | u32 pool | 11,821 words (10,071 live) | 0 | `setPhiPairs` abandons the old region: 15% dead on psp103, 0.6% on hisimhv_va. Compaction not worth a pass. |
| `Mir.fconst_map` / `iconst_map` | hash maps | 153 / 10 | 0 | Dedup only; codegen's `addIntConst` still writes after lowering. |
| `Mir.Def`, `Mir.InstData` | 24 B, ≤48 B | transient | 0 | Decoded views, never stored. |
| `PhiPair` | 8 B | per phi operand | 0 | Two `extra` words. Size-asserted. |
| `Analysis.dom_kids` | `[][]u32` (16 B header + 1 alloc per block) → `kid_pool`/`kid_off` (8 B) | 4,234 blocks, built twice | ~50 KB and 8,468 allocations per compile | One pool, as `inst_pool` already was. |
| `Analysis.preds` / `succs` | `[][]u32` | 4,234 each | 0 | Frozen (codegen reads them). Proposal 6. |
| `Analysis` per-value columns | `vty` 1, `def_block` 4, `alias` 4, `deps` 8 (+`xdeps`/`pdeps`/`acdyn` 8 each when distinct), `arr_of` 4, `folds` 2×9 | 23,869 | 0 | Each column is read alone by a hot pass, so SoA is already right. `FoldColumn` was compressed 24 → 9 B before step 1. |
| `Analysis` per-block columns | `rpo_num`, `idom`, `dom_in/out`, `loop_of`, `term`, the pool offsets: 4 B; `is_merge`/`is_loop`: 1 B | 4,234 | 0 | Already columns. |
| `proof.lattice.Interval` | 24 B | 23,869 | 0 | Kept AoS per its measurement table (SoA/`@Vector` lose). Size-asserted. |
| `prover.Fact` / `GuardRef` | 32 / 8 B | 2,732 / 23,869 | 0 | Prover scratch arena, freed on return. Size-asserted. |
| `Prover` class map key | 16 B | 17,211 classes | 0 | Arena scratch, freed on return. |
| `Prover.finite` / `uses` / `class_of` | 1 / 4 / 4 B per value | 23,869 | 0 | Random probes by value; a bit set would cost a shift per probe for ~20 KB. |
| `opcode.Info`, `callee.Info`, `dist.Dist`, `op.OpKind` | comptime tables | 81 opcodes, 183 callees, 16 rows | 0 | Static data; no runtime instances. |
| `hier_param.Values` / `Aliases` | 6×4 / 6×8 B | one per instance / one | 0 | Tiny. |
