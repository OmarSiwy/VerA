# Backend code generation review

Source review only; no profiler, build, test, or generated artifact was run.
Payoffs below are hypotheses and operation-count bounds, not measurements.
Ordering reflects potential payoff on the stated workloads; actual whole-program
ranking is unknown and needs profiling. Line ranges refer to the reviewed files
after this cleanup. References to other files are read-only integration context.

All seven assigned files were read in full against the supplied standards,
README.md, and CONSUMING.md.

| File | Cleanup outcome |
| --- | --- |
| `src/backend/tb.zig` | Reused `digits` for the noise source ID validation, preserving the empty-string rejection. |
| `src/backend/cg_limit.zig` | Reviewed unchanged; numerical/control-flow proposals below require separate validation. |
| `src/backend/cg_display.zig` | Reused lowering's file-task classifier; removed a forwarding function, unreachable descriptor dispatch entries, and an unused alias. |
| `src/backend/orchestrator.zig` | Stopped the live-name membership scan at its first match. |
| `src/backend/unit_plan.zig` | Called the existing use-count operation directly; removed its private forwarding function and unused imports/aliases. |
| `src/backend/naming.zig` | Reviewed clean; unchanged. |
| `src/backend/cg_filters.zig` | Removed unused imports/aliases; coefficient formulas and validation are unchanged. |

The cleanup changes no public declarations or struct fields, numerical formulas,
tolerances, clamps, iteration limits, or emitted solver arithmetic. The following
performance work is deferred. Changes that require callers or host integration
also require coordination with those files' owners.

Two further reuse proposals remain deferred under the strict behavior constraint:
`cg_display.emitLine` could replace the duplicate `$ferror$str` emission, and
`ArrayList.print` could replace `tb.Writer.print`. The installed Zig 0.16 stdlib
reserves `fmt.len` before formatting; both replacements change reservation or
partial-output behavior on OOM. Decide that failure-path contract before applying
either replacement. Neither offers a demonstrated runtime payoff.

## Emit sweep data once and iterate over it

- **Where**: `src/backend/tb.zig:643-757`, `renderRunner`; `src/backend/tb.zig:767-793`, `expand`.
- **Now**: `expand` allocates one cell slice per Cartesian-product row, and `renderRunner` emits a separate block for every sweep point and repeats the time-step statements within each block. This creates allocation inside a loop and redundant parsing/semantic analysis of generated statements in the child compiler. Source size grows with sweep points times time points, even though the execution procedure is identical.
- **Change**: Emit immutable tables of sweep bindings, time values, and wave values, then one runner procedure with sweep and time loops. Resolve directive names to unknown indices at compile time. Preserve the existing counter `n`, state initialization per sweep, parameter override/derive/precompute sequence, and the exact event-flag expressions. A smaller first step is one contiguous `total * dims` backing allocation in `expand`, with row slices into it and checked size arithmetic.
- **Why it is faster**: The compiler analyzes one copy of the step procedure. A contiguous expansion removes per-row allocation and makes row traversal sequential.
- **Est. payoff**: Potentially a large reduction in runner compilation work near the 4,096-point ceiling; no benefit expected for single-point fixtures. Allocation count for the smaller step falls from one per row plus the row table to two total. Wall-clock speedup and the fraction of total compilation attributable to the runner are unknown, needs profiling.
- **Risk**: Transcript ordering, global point numbering, `initial_step`/`final_step`, and the distinction between DC sweeps and separate transient runs are observable. Preserve `stepPre`'s global `n != 0` condition and the current floating-point computation of `dt`. Existing tests also pin generated straight-line text. No GPU ABI change.
- **CPU / GPU / both**: CPU.

## Slice the unresolved limiter arguments out of the full core

- **Where**: `src/backend/cg_limit.zig:688-718`, `usesCore`/`needsCore`; `src/backend/cg_limit.zig:722-759`, `emit`; `src/backend/cg_limit.zig:935-949`, `writeArg`.
- **Now**: If even one algorithm argument or sign lacks an `lp_idx` entry, generated `limit` constructs a full `[n_u]R` input and calls `core`. It then reads only the clamp arguments from that result. Work not eliminated by the optimizer becomes redundant model evaluation at every Newton iteration; a large live core can also increase GPU register pressure and spills. Inspect optimized code first. The existing `planPrep` already eliminates this work for proven solve-constant arguments, so this finding applies only to the remaining path.
- **Change**: Build a private multi-target computation for the unresolved `argv` and sign values, preserving their original CFG, operand order, and domain guards. Render `writeArg` against this smaller result. Reuse the existing slicing/emission machinery, but retain `scValue`/`scBlock` as the solve-constancy proof: `UnitPlan.analyze` is not a replacement proof. Keep the current full-core path until differential validation covers loops, phis, state reads, and model overrides.
- **Why it is faster**: A handful of dynamic clamp arguments can require much less work and fewer live temporaries than the whole residual core. GPU occupancy may improve if this removes actual spills.
- **Est. payoff**: Potentially several-fold on the affected `limit` path when most of the core is unrelated; zero for devices whose arguments are all already prepared. The frequency of the fallback, actual spills, and its share of total simulation time are unknown, needs profiling.
- **Risk**: Losing a controlling branch or loop dependency changes limiter values and convergence. Keep evaluation at the original, unmodified `cur`, before source-ordered clamps write `x`; do not expand the hoisting proof to achieve the speedup. A private helper need not change `Model`, `Instance`, or the host ABI.
- **CPU / GPU / both**: Both. Confirmed route: the sibling host's `src/devices/engine.zig`, `limitRange` and GPU `StateKernel.run`, both call `D.limit`; `src/devices/kernels.zig` exports the state kernel. VerA's empty `gpu_kernel_paths` field itself launches nothing.

## Index eager consumers before fusing statements

- **Where**: `src/backend/unit_plan.zig:553-614`, `fuseSingleUse` and `eagerlyUses`.
- **Now**: Each eligible producer scans the remainder of its block until it finds an eager consumer or a barrier. A long block with late consumers repeats instruction decoding and alias resolution, yielding quadratic scans in statement count. The outer pass also visits every block for each analyzed unit, including blocks with no needed producers.
- **Change**: Construct temporary dense tables keyed by resolved `Mir.Value` for the next eager consumer, plus the next barrier position per statement. Build them with a backward block walk using the exact operand rules in `eagerlyUses`. Use those positions to decide fusion directly, and visit only blocks containing eligible live producers once that block list is available.
- **Why it is faster**: Repeated suffix walks become one sequential pass and indexed lookups. This removes redundant decoding rather than replacing the guards with masks.
- **Est. payoff**: Potentially an order-of-magnitude improvement for this pass on very long blocks with distant single consumers; little gain on short blocks or adjacent consumers. Its fraction of total codegen time is unknown, needs profiling.
- **Risk**: The current scan tests consumption before testing whether the consuming statement is a call/barrier. Preserve that ordering, resolved aliases, folded exponents, display-only operands, lazy ternary arms, and cached/live-out exclusions. The scan currently sees all statements, so blindly indexing only live consumers could change decisions. Do not alter partial resets or the loop fixpoint. No runtime or GPU ABI change is intended.
- **CPU / GPU / both**: CPU compiler work.

## Retain one filter plan per call site

- **Where**: `src/backend/cg_filters.zig:72-146`, `filterPlan`; `src/backend/cg_filters.zig:166-281`, `filterSide` and `conjugateOf`.
- **Now**: The same filter is planned during instance declaration, coefficient-reader emission, operator rendering, and state-update emission in `codegen.zig`. Each call rebuilds section arrays and expression strings. Complex-root pairing additionally scans unused roots and repeats constant folding and speculative real-part rendering. These are redundant recomputation and allocations inside nested loops, not filter-kernel arithmetic costs.
- **Change**: Compute an immutable `FilterPlan` once per filter MIR instruction after the analysis/rendering context is stable, retain it in a compilation-lifetime table, and pass it to those emission sites. Within planning, lazily memoize each root's folded imaginary part and speculative real-part text so repeated pairing searches reuse them. Preserve first-unused conjugate selection and source section order.
- **Why it is faster**: Reusing the plan removes repeated section construction and pairing altogether at later emission sites. Memoizing root descriptions prevents the remaining search from repeatedly allocating the same text.
- **Est. payoff**: Potentially several-fold less work in filter planning when all emission sites are exercised; whole compilation benefit is unknown, needs profiling, and likely small for models without many filters or roots.
- **Risk**: `filterPlan` saves/restores `g.uses_model`, returns diagnostics as `p.err`, and speculative `f64Const` failures intentionally do not diagnose. Caching must preserve those effects and distinguish unresolved roots from rendered roots. Do not cache runtime coefficient values: model-card overrides must still reach `__sec(model)`. Do not expand root products, change cascade order, or alter coefficients. No device layout change is required for a compiler-only cache.
- **CPU / GPU / both**: CPU compiler work.

## Reuse split evaluations between differential checks

- **Where**: `src/backend/tb.zig:1060-1090`, emitted `fusedCheck` and `patternCheck`; `src/backend/tb.zig:1172-1201`, emitted `point`.
- **Now**: On devices exposing both fused evaluation and structural patterns, `fusedCheck` runs `evalQ`, `eval`, and `q`; immediately afterward `patternCheck` seeds the same point and reruns `eval` and `q`. This repeats full dual-number evaluations with identical inputs. `laneCheck` uses perturbed inputs and is a separate obligation.
- **Change**: Retain the independent split `eval`/`q` results produced by the fused check and feed those results to `patAssert`. Keep the fused result independently computed and compared. Retain the existing standalone pattern-check path for devices without `evalQ`.
- **Why it is faster**: The structural check needs the already-computed derivatives, so it can inspect those arrays without another model traversal.
- **Est. payoff**: Removes up to two full dual evaluations and a repeated seed operation per accepted point. Speedup and the share of total testbench runtime are unknown, needs profiling; compilation and transcript I/O may dominate overall fixture cost.
- **Risk**: Preserve all assertions and their failure order. Do not reuse results across `D.display`, which runs later and can perform accepted-point effects, or replace the split oracle with the fused result being tested. Keep all lane checks and exact-bit comparisons. No GPU ABI impact; this is the CPU testbench.
- **CPU / GPU / both**: CPU.

## Stream discarded compiler messages without allocating their bodies

- **Where**: `src/backend/orchestrator.zig:489-523`, `ResidentChild.update`.
- **Now**: Every server frame is copied into a fresh `readAlloc` buffer before its tag is dispatched, including `file_system_inputs`, timing, and test messages that are immediately discarded. This is allocation inside a protocol loop and an unnecessary memory copy. It also places discarded payload size on the peak-memory path.
- **Change**: Dispatch on `header.tag` first. For ignored messages, call `Io.Reader.discardAll(header.bytes_len)` and map read failures to `CompilerGone` as today. Retain owned body handling for error bundles, and retain version comparison and digest length checks for recognized frames. Optimize those small recognized frames only after the discard path is measured.
- **Why it is faster**: Ignored data passes through the reader's existing buffer without an allocated copy and free per frame.
- **Est. payoff**: Eliminates the payload-sized allocation and copy for every ignored frame; likely a small total benefit beside a cold compile, potentially more visible on warm updates with large input lists. Runtime share and wall-clock improvement are unknown, needs profiling.
- **Risk**: Consuming an incomplete frame incorrectly would desynchronize the protocol. Preserve exact frame lengths, truncated-read failure handling, success termination on an empty error bundle, and child recovery. Removing allocations changes possible OOM outcomes, so this is deferred rather than included in a strict cleanup. Keep publication as a fresh-inode copy. No GPU ABI change.
- **CPU / GPU / both**: CPU.

## Resolve limiter ladders once per stable limit list

- **Where**: `src/backend/cg_limit.zig:194-219`, `collect`; `src/backend/cg_limit.zig:232-263`, `ladderOf`/`limvdsClaimed`; `src/backend/cg_limit.zig:766-775`, `emit`.
- **Now**: Ladder discovery scans the entire limit list to count gate legs, then scans for the channel limiter. `collect` repeats it while checking and filtering dangling sites; `emit` repeats it for both legs. For each `limvds`, `limvdsClaimed` scans gate sites and invokes ladder discovery again. Worst-case discovery work is cubic in the number of limit sites, with repeated loads of fields unrelated to a particular match.
- **Change**: Keep a temporary ladder-index table and a claimed-channel bitmap for each stable list. During collection, compute validity against the complete unfiltered list before compacting. After compaction, recompute once against final indices and consume that plan during emission. Use dense indices into `g.limits`, and preserve the current first matching channel and earliest-leg emission rule.
- **Why it is faster**: Membership and ladder lookup become direct indexed reads during emission instead of nested rediscovery. The validity decision remains independent of compaction order.
- **Est. payoff**: Potentially large on synthetic models with hundreds or thousands of limit sites; ordinary small limiter lists likely see little benefit. Overall codegen share is unknown, needs profiling.
- **Risk**: Filtering invalidates indices. A stale or reordered plan can omit a clamp, run it twice, or reverse source order, changing numerical behavior. More than two legs on a gate must still decline every invalid site; retain all writable-node checks. Keep this compiler scratch outside the generated ABI.
- **CPU / GPU / both**: CPU compiler work; the proposal preserves the emitted CPU/GPU clamp sequence.

## Copy literal format runs in bulk

- **Where**: `src/backend/cg_display.zig:477-505`, `translateFormat`.
- **Now**: Ordinary text pays a loop iteration, several character comparisons, and an `ArrayList.append` capacity check for every byte. Braces pay two appends. This is a scalar byte loop with redundant append bookkeeping, especially for long literal messages; no branch-miss rate has been measured.
- **Change**: Find the next byte in `%{}` with `std.mem.indexOfAnyPos`, append the preceding literal slice once, and retain the current parsing at each special byte. Start with the stdlib search, without adding a custom SIMD scanner or branchless parser.
- **Why it is faster**: Long literal runs become one bulk copy instead of per-byte appends. The control-dependent conversion grammar stays in the existing parser.
- **Est. payoff**: Could substantially reduce formatter-translation work for long literal runs, but likely negligible for short or conversion-heavy strings. Total codegen share and wall-clock payoff are unknown, needs profiling.
- **Risk**: Preserve brace doubling, `%%`, a trailing `%`, `%m`/`%l` operand accounting, width/precision overflow handling, and output order. Allocation and partial-output behavior on OOM need review before implementation. Display execution remains in the accepted-point phase; no GPU kernel or ABI is involved.
- **CPU / GPU / both**: CPU compiler work.

## Nothing to do

- `src/backend/naming.zig`: reviewed clean. The injective sanitizer, bounded scratch, stable source-derived keys, and canonical order are load-bearing; the existing `assignDisambig` comment already identifies its quadratic ceiling and a map upgrade for thousands of units. No additional change is justified without that workload.
