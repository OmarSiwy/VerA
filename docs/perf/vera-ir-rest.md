# Remaining IR performance review

Source review only; no profiler, build, or test command was run. Findings are
ordered by likely payoff on repeated device evaluation or large model compilations,
not by measured timings. Line references are after this cleanup. Compiler passes
here run on the CPU; the first finding follows their output into an actual host
GPU kernel.

All six files were read in full. The applied cleanup preserves public declarations,
data layouts, numeric operations, guards, and traversal order.

| File | Review outcome |
| --- | --- |
| `src/ir/elaborate.zig` | Removed unused private connection-binding parameters and a forwarding name lookup; reused stdlib membership searches without changing discipline order or matching. |
| `src/ir/proof.zig` | Removed the private predicate forwarding helper; reused `Analysis.blockInstsFlat` in both proof walks, preserving the exact instruction sequence. |
| `src/ir/analysis.zig` | Reused `Lower.sysFuncTy` through an explicit type mapping; retained the MIR-only `$held_int` case. |
| `src/ir/mir.zig` | Reviewed and unchanged. |
| `src/ir/ssa.zig` | Removed the private empty-phi forwarding builder; call sites use `Mir.emitPhi` directly. |
| `src/ir/ifconv.zig` | Reviewed and unchanged; scheduling changes below need separate validation. |

Two apparent reuse opportunities were rejected as non-equivalent. Proof's use
census includes every stored instruction row; if-conversion counts only linked
rows. Also, `Flatten.constReal` permits real division by zero and does not fold
power, whereas `Prover.foldBound` declines division by zero and folds power.
Neither pair can be replaced by one existing implementation without changing
behavior. No branchless rewrite of domain checks or interval arithmetic was made.

## Exclude zero-derivative operations from Jacobian dependencies

- **Where**: `src/ir/analysis.zig:735-776`, `defDeps` and `unknownDeps`;
  `src/ir/mir.zig:149-168` defines the committed-latch semantics.
- **Now**: `defDeps` unions operand bits for every unary/binary instruction,
  including comparisons and `path_prev`/`path_acc`. Those operations produce no
  current-iterate derivative, but their operand dependencies can survive into
  `jac_pattern`/`q_pattern`. Each unnecessary live column can cost a CPU scatter
  or a contended GPU atomic add. The device route is concrete: VerA's
  `Gen.renderOp` emits latches as `S.con(inst.pb__/pq__)`, pattern emission reads
  `unknownDeps`, and ARPice's `src/devices/kernels.zig` registers
  `engine.DeviceKernel(D).run`, which calls `evalRange` and generated `evalQ`/`eval`.
- **Change**: Add explicit zero-dependency cases in `defDeps` for the latch
  opcodes and comparison opcodes whose emitted derivative is zero. Keep the
  conservative rules for other opcodes and the >64-unknown fallback. Keep
  `dfree` separate: a comparison can have zero derivative while its value still
  depends on probes, and `Gen.pinLanes` uses `dFree` to decide lane uniformity.
- **Why it is faster**: Smaller structural row masks eliminate stamp operations
  and corresponding matrix slots. On the device this removes global atomic
  traffic, particularly costly when many instances share a row.
- **Est. payoff**: Potential order-one reduction in scatter work for rows whose
  extra dependencies come mostly from these operations; none for unaffected
  rows. Affected row counts and scatter's share of total solve time are unknown,
  needs profiling and measurement on GPU-eligible models.
- **Risk**: An incorrectly cleared bit drops a real Jacobian entry. Check emitted
  dual behavior, non-finite inputs, signed zero, switching boundaries, and latch
  commit/revert behavior before claiming equivalence. Regenerate host stamp tapes
  and kernels together; preserve the positional GPU buffer ABI and existing
  layout checks. This changes emitted sparsity and is not part of the cleanup.
- **CPU / GPU / both**: Both, through generated device evaluation.

## Cache finite backward slices shared by contribution units

- **Where**: `src/ir/proof.zig:1639-1698`, `Prover.verdict`.
- **Now**: Generation stamps avoid clearing `seen` per contribution, but every
  contribution still traverses its entire finite backward slice. If U roots share
  K finite ancestors, those ancestors can be decoded and pushed O(U*K) times.
  The mechanism is redundant graph traversal and repeated scratch-stack traffic,
  not a missing SIMD operation.
- **Change**: Build a reverse-use pool over alias-resolved operands once after
  `walk`. Propagate non-finiteness from the final `finite == false` values to
  users, including phi operands and select conditions exactly as `verdict` does.
  Use that closure to accept entirely finite roots without walking their slices.
  Retain the existing traversal for non-finite roots to select the same W0650
  culprit and preserve diagnostic ordering.
- **Why it is faster**: The shared finite subgraph is processed once instead of
  once per unit. A reverse worklist handles cycles without recursive per-root
  memoization.
- **Est. payoff**: Potentially many-fold on verdict construction with thousands
  of roots sharing large finite slices; likely little gain for small models or
  roots that immediately fail finiteness. Whole-compilation share is unknown,
  needs profiling; it does not accelerate the already-generated solver kernel.
- **Risk**: Omitting condition/phi edges can incorrectly grant `.optimized`.
  Preserve alias handling, dead-row behavior, `error_count` forcing `.strict`,
  and the original warning witness walk. Extra indexing can lose on tiny MIR.
- **CPU / GPU / both**: CPU compilation.

## Revisit only affected branches between if-conversion rounds

- **Where**: `src/ir/ifconv.zig:47-131`, `run`, `countPreds`, `countUses`;
  `src/ir/ifconv.zig:172-242`, `tryConvert`.
- **Now**: Every successful round triggers another complete predecessor census,
  use census, and block scan, followed by one final unsuccessful round. With R
  rounds and I linked instructions, the censuses alone repeat O(R*I) work.
  Nested conversions and the explicit stale-use-count refusal in `classifyArm`
  are reasons another round may be needed.
- **Change**: First record branch-containing blocks in a dense ordered candidate
  list. For large multi-round cases, maintain reverse CFG/use indexes so a
  conversion marks its affected parent branches and alias users for the next
  round. Apply count deltas at round boundaries and visit marked blocks in the
  same ascending order. Preserve the existing round-start census semantics.
- **Why it is faster**: Unrelated blocks and operands stop participating in every
  retry. A simple candidate list is the first step; incremental counts are worth
  their maintenance cost only if census time actually dominates.
- **Est. payoff**: Potentially many-fold on deeply nested, large multi-round MIR;
  small or negative on a one-round model. R, conversion time, and its share of
  total compilation are unknown, needs profiling.
- **Risk**: Eagerly updating counts within a round changes eligibility and
  emitted instruction/alias order. Track contribution roots, rewritten phi
  operands, and newly aliased selects. Do not substitute proof's stored-row
  census for the linked-row census or weaken any domain/use-count guard.
- **CPU / GPU / both**: CPU compilation; this scheduling proposal keeps the
  emitted device computation unchanged.

## Index module lookup and incoming instance names once

- **Where**: `src/ir/elaborate.zig:184-231`, `pickTop`;
  `src/ir/elaborate.zig:1729-1740`, `Flatten.findModule`.
- **Now**: For each candidate root, `pickTop` scans every instance and every
  paramset, even after finding an incoming edge. `findModule` separately scans
  module lists for each instance and paramset query. Large hierarchies pay
  repeated name comparisons and cache traffic over module declaration rows.
- **Change**: Build an incoming-name set from instance names and a grouped
  paramset-name-to-target index for root selection. Build first-match lookup
  tables from interned `StrId` to module index for user and builtin exact
  matches; retain a separate case-insensitive netlist fallback in its original
  order. Continue choosing the first uninstantiated non-connect user module.
- **Why it is faster**: Root selection stops repeating the M-by-instances-by-
  paramsets scan, and repeated child lookups become indexed probes. Store
  indices rather than pointers into declaration tables.
- **Est. payoff**: Potentially many-fold for hundreds or thousands of modules or
  repeated instances; probably a loss for ordinary one-module input unless the
  shortcut remains cheap. Elaboration's fraction of total compilation is
  unknown, needs profiling.
- **Risk**: Preserve user-over-builtin precedence, duplicate-name first wins,
  paramset overload edges, SPICE case fallback, and all-cycle root selection.
  Root detection currently uses exact interned names; do not silently make it
  use `findModule`'s case-insensitive fallback. Diagnostics must retain order.
- **CPU / GPU / both**: CPU compilation.

## Reuse the structural analysis across proof and code generation

- **Where**: `src/ir/analysis.zig:179-217`, `build` and `buildStructure`;
  `src/ir/analysis.zig:236-516`, `buildCfg`;
  `src/ir/proof.zig:361-401`, `proveOpts`.
- **Now**: Proof builds aliases, CFG, dominators, natural loops, and instruction
  pools inside its scratch arena. Codegen subsequently calls `Analysis.build`,
  rebuilding those structures for the same post-if-conversion MIR. This duplicates
  allocations, instruction-pool fills, and dominator computation. The cleanup
  reuses the pools inside proof; it does not remove the second construction.
- **Change**: Give the completed structural analysis compilation lifetime and
  pass it to both stages. Let codegen extend it with value types and dependency
  tables. Retain standalone public entry points as convenience constructors.
  This requires coordinated integration with the owners of `root.zig` and
  `backend/codegen.zig`; neither was edited here.
- **Why it is faster**: One alias/CFG construction replaces two, including the
  dependent instruction-chain walks needed to build each flat pool.
- **Est. payoff**: Approximately half the duplicated structural-construction
  work on an emitting compilation, before integration overhead. No lint-only
  gain. Structural construction's share of total runtime is unknown, needs
  profiling; this is not a claim of 2x end-to-end speed.
- **Risk**: Proof's arena currently dies before codegen. Sharing requires an
  explicit lifetime and an unchanged MIR/alias forest after construction.
  Preserve standalone calls, unreachable-block handling, and deterministic
  predecessor/dominator order. No device ABI change is needed.
- **CPU / GPU / both**: CPU compilation.

## Propagate derivative facts only to affected users

- **Where**: `src/ir/analysis.zig:631-697`, `buildDfree` and `defDfree`;
  `src/ir/analysis.zig:709-768`, `buildDeps` and `defDeps`.
- **Now**: Both lattices repeatedly scan every value until nothing changes.
  `buildDeps` decodes even constants and already-stable instructions each round;
  `buildDfree` skips settled false entries but still scans the full value space.
  Loop-carried phis can require more rounds than acyclic definition-order data.
- **Change**: Build a compact alias-resolved reverse operand-use pool and seed a
  worklist from probes and other relevant leaves. Re-evaluate only users whose
  operands changed; keep the two lattices' rules and initial values distinct.
  Use a pending marker to avoid duplicate queued values. Keep a direct sweep for
  small or acyclic inputs if indexing overhead loses there.
- **Why it is faster**: Stable subgraphs stop being decoded on every round.
  Work follows changed facts instead of repeatedly reading O(R*V) values.
- **Est. payoff**: Potentially several-fold on these passes for large cyclic
  models with many rounds; small or negative for one/two-sweep inputs. Their
  share of compilation time is unknown, needs profiling. The final tables and
  resulting device runtime should be identical for this scheduling change.
- **Risk**: Cyclic phis, aliases, argument-less calls, and the >64-probe fallback
  must retain their current answers. Do not derive `dfree` from `deps == 0`:
  their consumers require different guarantees, especially if the first proposal
  is implemented. Worklist memory can exceed the savings on small models.
- **CPU / GPU / both**: CPU compilation.

## Reuse argument-cloning scratch across expression calls

- **Where**: `src/ir/elaborate.zig:1940-2010`, `cloneExpr` and `cloneArgs`.
- **Now**: Each cloned call allocates a temporary `[]Ast.ExprId`, recursively
  fills it, then copies it into the expression extra pool. The temporary is not
  retained as output, but its storage remains in the compilation arena. Repeated
  instantiation multiplies this allocation and memory traffic by call count.
- **Change**: Use one `Flatten` scratch list with save/restore length discipline,
  as `SsaBuilder.addPhiOperands` already does. Reserve each frame's slots, clone
  operands in the same order, append the resulting slice through `addExprList`,
  and restore the saved length. Reacquire slices after recursion. Copy source
  argument IDs into stable frame storage before recursive appends, since the
  source argument list is borrowed from a growable extra pool.
- **Why it is faster**: Temporary storage grows with maximum concurrent cloning
  depth/arity rather than the total number of call sites. It reduces allocator
  bookkeeping and arena footprint without changing persistent AST layout.
- **Est. payoff**: Likely a modest cloning-time improvement and a clearer memory
  reduction in hierarchies with many repeated calls; neither is measured.
  Cloning's fraction of total compilation is unknown, needs profiling.
- **Risk**: Recursive scratch growth invalidates borrowed slices; preserve source
  IDs and index frames rather than keeping pointers. Preserve expression append
  order, provenance tokens, scoped renaming, and sys-call rewrite behavior.
  This is more invasive than a safe wrapper removal and was not applied.
- **CPU / GPU / both**: CPU compilation.

## Nothing to do

- `src/ir/mir.zig`: reviewed and clean; keep the SoA columns, typed handles,
  bit-exact constant interning, and checked alias resolution.
- `src/ir/ssa.zig`: after removing the forwarding builder, no additional
  performance change is recommended without new evidence; retain the documented
  place-major zero-page matrix, geometric growth, flat pools, and shared scratch.
  Its documented recursive-read depth ceiling remains a separate follow-up.

No other owned file is unreviewed: their applied cleanup or deferred findings
are recorded above. Builds and tests remain for centralized verification.
