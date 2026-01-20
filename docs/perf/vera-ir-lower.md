# IR lowering performance review

Reviewed `src/ir/lower.zig` in full. Applied only local simplifications: reuse the AST nature walk and existing discipline lookup, remove private forwarding and unused parameter/error scaffolding, share the display-chain append, and append already-lowered table rows as a slice. Public declarations, data layouts, guards, and numerical expressions are unchanged.

The findings below are proposals, ranked by potential payoff on inputs that exercise them. This was source inspection only: no profiler, build, or test command was run. Runtime shares and speedups need measurement. These are CPU compilation costs; this file constructs MIR and does not execute a device kernel. No GPU performance claim or GPU ABI change is proposed.

## Memoize repeated finiteness scans

- **Where**: `src/ir/lower.zig:4186-4251`, `checkFiniteContribution` and `scanFinite`.
- **Now**: `scanFinite` recursively follows both binary operands without remembering visited MIR values. A shared DAG produced by repeated `x = x + x` assignments revisits the same descendants along every path, even when the initial value is a nonconstant probe. Work can grow exponentially with dependency depth until the existing depth limit stops it. The cost is redundant recomputation, repeated instruction/definition column reads, and a serialized recursive walk.
- **Change**: Give each `checkFiniteContribution` invocation a lazy scratch memo keyed by resolved `Mir.Value` and remaining scan depth. Each entry must retain both the optional constant result and the first nonfinite result encountered in that subtree. On a cache hit, propagate the stored offender only if `bad` is still unset. Keep the exact unary/binary opcode handling, left-before-right traversal, arithmetic expressions, and depth cutoff. Discard the memo after the check so later SSA changes cannot invalidate it.
- **Why it is faster**: Each reachable value/depth combination is evaluated once instead of once per incoming path. Including depth in the key preserves the existing cutoff even when a value is reached through paths of different lengths.
- **Est. payoff**: Potentially orders of magnitude on deeply shared DAGs; ordinary expression trees may gain nothing and pay memo overhead. At most 33 depth states per reached value replace repeated path visits. Total compilation share is unknown, needs profiling; no simulation runtime speedup is implied.
- **Risk**: Caching only the folded value can hide a nonfinite descendant in an otherwise nonconstant expression. Caching by value alone changes cutoff behavior. Changing traversal order can change the first diagnostic from NaN to infinity or vice versa. Scratch memory growth also needs measurement.
- **CPU / GPU / both**: CPU.

## Index branch reads before checking mixed probes

- **Where**: `src/ir/lower.zig:4336-4361`, `checkProbeBranches` and `contributedOn`.
- **Now**: The nested read loops compare every pair of access records. Every matching pair with opposite quantities then scans `contributions` to decide whether it is exempt. For R reads and C contributions, the sweep performs O(R²) comparisons and can approach O(R² C) work when many potential/flow reads refer to contributed branches. Repeated scans also load contribution rows containing fields irrelevant to this check.
- **Change**: Build a temporary set of contributed unordered node pairs, including both direct and indirect contributions. Group reads by the same unordered pair and retain the first potential-read index and first flow-read index. For each un-contributed group containing both, form the ordered pair of those indices; select the lexicographically earliest candidate. Use the original first record for node-name orientation and the original second record for the diagnostic token, matching today's nested-loop order.
- **Why it is faster**: Expected O(R + C) hash-table work replaces repeated pair comparisons and contribution scans. Only compact pair keys and read indices need to be hot during the sweep.
- **Est. payoff**: Potentially orders of magnitude for thousands of repeated reads; small modules may favor the current allocation-free loops. The crossover and total compilation share are unknown, need measurement.
- **Risk**: Reporting the first group encountered in hash iteration would change the diagnostic. Sorting or canonicalizing the original records would change node-name orientation. This rule deliberately ignores named-branch identity and treats direct and indirect contributions alike; preserve those semantics.
- **CPU / GPU / both**: CPU.

## Index direct contribution accumulators

- **Where**: `src/ir/lower.zig:4642-4682`, `contribIndex` and `newContrib`; `src/ir/lower.zig:4705-4717`, `discardOpposite`; `src/ir/lower.zig:7270-7276`, `flowAccum`.
- **Now**: Finding an accumulator, clearing its opposite quantity, and reading a retained flow each scan the contribution table. These lookups inspect only kind, access, node IDs, and branch identity, but traverse rows that also contain diagnostic tokens, result values, and noise slices. Repeated statements and unrolling multiply the scans and unnecessary cache traffic.
- **Change**: Maintain a module-local scratch index from `(access, hi, lo, br)` to the existing contribution index for direct entries. Populate it when `newContrib` creates a direct contribution. Use that index in `contribIndex`, query the opposite access in `discardOpposite`, and query `.flow` in `flowAccum`. Preserve the public contribution and accumulator layouts and their append order; store indices, not pointers into growing arrays. Keep indirect entries outside this deduplication index.
- **Why it is faster**: Expected constant-time compact-key lookups replace O(C) full-row scans for each operation. For S lookup operations, expected lookup work falls from O(S C) to O(S), while MIR emission and SSA updates remain unchanged.
- **Est. payoff**: A multiple-fold improvement is plausible in the lookup portion for large contribution tables, but requires measurement. Typical small compact models may see no benefit. The lookup fraction of total compilation time is unknown, needs profiling.
- **Risk**: Omitting `br` merges distinct named branches; treating opposite orientations differently from today's canonical targets also changes behavior. Indirect assignments must remain separate equations. Opposite-quantity clearing must retain all three existing SSA writes in order. Any index must stay synchronized with contribution creation, including error exits, without changing externally visible layouts or ordering.
- **CPU / GPU / both**: CPU.

## Pack inlined argument scratch into flat buffers

- **Where**: `src/ir/lower.zig:9032-9079`, `src/ir/lower.zig:9117-9143`, and `src/ir/lower.zig:9160-9203`, `inlineUserFuncPre`.
- **Now**: Each scalar actual gets a separate one-element `arena.dupe`; each scalar formal slot gets another. Array arguments and output writeback values allocate individual slices too. Three outer lists hold slice descriptors. Repeated inlining and unrolling therefore incur allocation inside argument loops, extra descriptors, and pointer chasing through many small allocations.
- **Change**: Replace the per-formal actual slices with one invocation-local `Mir.Value` buffer plus offset/count records. Use the same scheme for the `VarSlot` buffer and output writeback values. Reserve the known scalar capacity and grow for arrays at the same point their bounds are currently evaluated. Build ranges as arguments are processed, then access them by offset after buffers have finished growing. Keep nested invocations' scratch independent until caller writeback is complete.
- **Why it is faster**: Flat buffers eliminate per-scalar allocations and pack the data consumed by the binding and writeback loops. Known scalar-only calls can reserve each buffer once; mixed calls need buffer growth rather than a separate allocation for every formal.
- **Est. payoff**: Potentially a several-fold reduction in argument-scratch allocation work; the effect on overall inlining time and compilation time is unknown, needs profiling. Most benefit is expected from many calls to short functions with multiple arguments, where body lowering does not dominate.
- **Risk**: Evaluating bounds or actuals in a sizing prepass could change diagnostics and side effects. Array bounds are evaluated in different scopes at different stages today; do not collapse those evaluations. Preserve output initialization, formal order, caller/callee scope isolation, and writeback order. Slices must not survive buffer reallocation.
- **CPU / GPU / both**: CPU.

## Cache structural ddt membership

- **Where**: `src/ir/lower.zig:4737-4794`, `splitTerm` and `containsDdt`; `src/ir/lower.zig:4850-4904`, `lowerReactive`.
- **Now**: `splitTerm` scans a term for `ddt`, then `lowerReactive` scans child subtrees again at each multiplication along the reactive spine. A deeply nested product such as `((ddt(x) * a) * b) * ...` repeatedly traverses the same left spine. Dependency depth D can produce O(D²) AST visits, despite the expression store already using SoA columns.
- **Change**: Add a lazy, lowering-local tri-state byte table indexed by `Ast.ExprId` for unknown/absent/present structural membership. Populate entries through `containsDdt` using its exact existing tag cases and child order. Treat `.none` as absent without indexing it. Initialize the table after elaboration has finished modifying the AST, and keep this structural cache separate from scope-dependent constant evaluation.
- **Why it is faster**: Each visited AST node's structural answer is computed once and later queries become indexed byte loads. The repeated-spine case approaches O(D) visits without changing how reactive coefficients or MIR values are computed.
- **Est. payoff**: Potentially a multiple-fold improvement in membership scanning for long product chains or repeatedly lowered bodies; shallow expressions may gain nothing. Total compilation share is unknown, needs profiling, and the extra table consumes approximately one byte per expression.
- **Risk**: Stale entries after AST mutation, incorrect sentinel handling, or broadening the tag traversal can change classification and diagnostics. Cache only membership: reassociating coefficient arithmetic or caching lowered values across scopes would change numerical behavior. No public AST/MIR layout change is needed.
- **CPU / GPU / both**: CPU.

## Nothing to do

No whole file was classified as clean: the sole owned source file, `src/ir/lower.zig`, was reviewed in full and changed. Its existing ID widths, public layouts, guarded arithmetic, and numerical evaluation order were left intact. No GPU kernel in this file requires a separate finding.
