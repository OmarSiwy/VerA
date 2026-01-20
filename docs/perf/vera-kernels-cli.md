# Kernel and CLI review

Static review only: no builds, tests, profilers, or assembly inspection were run. Payoffs below are hypotheses, ordered by likely benefit on the stated workloads; none is a measurement. Line numbers refer to the reviewed source after this cleanup. Changes requiring emitter, host, or ownership changes are proposals for coordinated follow-up work.

All eight files were read in full, following `/tmp/codexbrief/standards-vera.md`, `README.md`, and `CONSUMING.md`. Repository references and the installed Zig 0.16 stdlib were searched before replacing code.

| File | Cleanup outcome |
| --- | --- |
| `src/backend/file_kernels.zig` | Reused `std.mem.indexOfAny` for the first mode letter; combined append/write creation while preserving flags and error handling. |
| `src/backend/filter_kernels.zig` | Reviewed, unchanged; coefficient arithmetic, accumulation order, history writes, and static-analysis guards retained. |
| `src/backend/limit_kernels.zig` | Reviewed, unchanged; domain clamps, host log guard, select barriers, and differential oracles retained. |
| `src/backend/rng_kernels.zig` | Reviewed, unchanged; reference stream, rounding, limits, and per-distribution seed advancement retained. |
| `src/backend/str_kernels.zig` | Reused stdlib classification behind the existing helper names; used the assignment count as the next destination index. `zDigit` still rejects letters beyond hexadecimal even if passed a larger radix. |
| `src/backend/table_kernels.zig` | Reviewed, unchanged; stable ordering, exact isoline equality, extrapolation guards, and gradient arithmetic retained. |
| `src/root.zig` | Reused arena teardown; removed an error switch that returned every error unchanged. |
| `src/cli.zig` | Reused `missing` for three operand errors, preserving message text and exit status. |

Public declarations and fields remain unchanged, including helper names that codegen publishes in generated `h.zig`. No floating-point expression or constant was changed. Only the four source files marked changed above and this report were written.

GPU reachability was checked separately from Zig's use of the word “device.” VerA's `Artifact.gpu_kernel_paths` has no producer. The GPU finding below follows the actual sibling-host route: ARPice's `src/devices/kernels.zig` exports `engine.StateKernel`, its `run` calls generated `D.limit`, and `cg_limit.zig` emits these limiter calls. No GPU benefit is claimed for the other files without a corresponding exported workload.

## Prepare immutable table ordering and isoline offsets once

- **Where**: `src/backend/table_kernels.zig:48-90`, `zTabEnd`, `zTabLess`, `zTabSort`; `src/backend/table_kernels.zig:95-184`, `zTabAt`, `zTable`.
- **Now**: Every `zTable` evaluation fills a stack permutation and insertion-sorts it. Shuffled input can require quadratic comparisons and moves. `zTabAt` then discovers isoline runs again through indirect row loads and a serial scan from the first pair. These are redundant recomputation and dependent memory accesses on every Newton evaluation.
- **Change**: For provably immutable generated sample blocks, prepare the stable permutation once and store a flat hierarchy of isoline keys and start/end offsets. Emit constant metadata for constant rows; use instance-owned preparation for runtime model coefficients whose lifetime is established. Search each level's key array for the same bracketing pair, then retain `zTabAt`'s current recursion and interpolation expressions. Keep the existing `zTable` entry point for callers supplying changing rows. Coordinate preparation with `codegen.emitTable`.
- **Why it is faster**: Removes repeated sorting and run discovery. Contiguous key/offset arrays avoid loading every row's unrelated columns while locating an isoline; binary search replaces the linear pair walk for large levels.
- **Est. payoff**: Potentially an order of magnitude on repeated lookups over thousands of shuffled rows; small already-sorted tables may gain little. Whole-simulation share is unknown, needs profiling, and is zero for models without tables.
- **Risk**: Caching arbitrary public `zTable` inputs would change behavior. Preserve duplicate source order, exact equality, NaN behavior where reachable, and the current choice of the lower adjacent segment at an exact knot. Preserve constant-extrapolation early returns and every value/gradient operation. New instance storage requires coordinated generated-layout and host ABI handling.
- **CPU / GPU / both**: CPU.

## Read file lines in positional chunks

- **Where**: `src/backend/file_kernels.zig:248-282`, `zFGets`.
- **Now**: The line loop calls `readPositionalAll` with a one-byte buffer for every byte, up to the existing 512-byte ceiling. Each byte serializes another I/O call; syscall overhead can dominate scanning an ordinary text file.
- **Change**: Trial bounded positional reads into the available line space, find the first newline with `std.mem.indexOfScalar`, and advance `ZFSlot.pos` only by the consumed prefix. Start without persistent read-ahead storage: positional reads do not advance the OS file cursor, so a later call can reread the tail. Retain the one-byte path wherever required to preserve unusual file/error behavior.
- **Why it is faster**: Amortizes I/O overhead across many characters and searches contiguous memory. Logical `$ftell` position remains independent of how many bytes a positional request fetched.
- **Est. payoff**: Potentially an order of magnitude on long-line, syscall-bound reads; needs measurement. Only affects accepted-point file input, not a solver artifact with display dropped; total-runtime share is unknown, needs profiling.
- **Risk**: Preserve included newlines, the 512-byte limit, EOF detection timing, partial-error return/count/position behavior, and visibility of externally modified files. A bulk request can encounter an error beyond a newline that the current call would never read. This is why the proposal was not implemented as cleanup.
- **CPU / GPU / both**: CPU.

## Reuse bilinear coefficients across Newton evaluations

- **Where**: `src/backend/filter_kernels.zig:19-39`, `zBilin`; `src/backend/filter_kernels.zig:73-117`, `zLaplace`, `zLaplaceStep`.
- **Now**: Both transient paths transform numerator and denominator for every section on every call, even when coefficients and `dt` have not changed. `zBilin` rebuilds polynomial products with nested loops and dependent updates; its scalar work grows cubically with degree before compiler specialization.
- **Change**: Prepare each section's discrete numerator/denominator once per exact coefficient-and-timestep version, then reuse the arrays for residual evaluation and accepted-step updates. Keep preparation outside the pure residual. Coordinate the generated `__sec(model)` calls and state lifecycle with codegen; leave the public kernel signatures usable as they are.
- **Why it is faster**: Repeated evals perform only section accumulation instead of reconstructing the same coefficients. Existing separate input/output history arrays already fit the access pattern.
- **Est. payoff**: Potentially several-fold on higher-degree filters evaluated many times at one timestep; likely smaller for degree-one sections. Filter share of total runtime is unknown, needs profiling.
- **Risk**: Rejected attempts, timestep changes, model changes, and initialization must invalidate correctly. Do not replace the transform with a reordered binomial formula. `zSec` and `zSecR` initialize accumulation differently and finish with reciprocal scaling versus division; merging them changes rounding. Keep all static/domain guards. Added cache fields require coordinated layout changes. Splitting `zPush` into two copy operations also needs an aliasing contract for its slices and was not done.
- **CPU / GPU / both**: CPU; no exported filter workload was established for a GPU claim.

## Share each random draw with its seed write-back

- **Where**: `src/backend/rng_kernels.zig:127-188`, rejection and distribution cores; `src/backend/rng_kernels.zig:244-257`, `zRngTCore`, `zRngErlangCore`; `src/backend/rng_kernels.zig:277-403`, emitted value/`Next` pairs.
- **Now**: Lowering represents a seeded source call as a value call plus a seed-update call. Each starts from the incoming seed. Data-dependent rejection/product loops therefore replay to obtain the final seed when both outputs are live. The LCG and product updates form serialized dependency chains. The compiler may eliminate discarded final arithmetic, so the full cost is not necessarily doubled.
- **Change**: Coordinate MIR/lowering and `emitRng` to evaluate a shared internal result containing the variate and final seed once per original call, then project both outputs. Retain all existing public entry points. Restrict sharing to cases where the paired wrappers have identical domain behavior; keep the present paths otherwise.
- **Why it is faster**: Removes replay of the same rejection sequence or per-degree loop without changing the random algorithm. Renaming the current scalar generator to a stdlib PRNG would not preserve the required stream.
- **Est. payoff**: Up to roughly 2x on loop-dominated paired draws before compiler elimination; needs measurement. No gain when only one output is live. Total-runtime share is unknown, needs profiling, and can be substantial only in models that repeatedly use these distributions.
- **Risk**: Preserve the exact wrapping seed sequence, zero-seed escape, rejection order, degree ceiling, rounding, and per-point purity. Some value/`Next` guards differ for NaN parameters, so unconditional fusion is unsafe. Do not use a one-step seed advance for a variable-length distribution or parallelize dependent draws from one seed.
- **CPU / GPU / both**: CPU; GPU distribution support/reachability was not established.

## Trial a GPU guard around inactive junction damping

- **Where**: `src/backend/limit_kernels.zig:60-65`, `klog`; `src/backend/limit_kernels.zig:96-122`, `zPnjlim`.
- **Now**: The host already returns early when `damp` is false. The GPU source computes all three damping candidates before selecting, with `klog` reaching `contract.gm.log` and its software `softLog`. These are arithmetic and control-flow sequences, not free GPU instructions. Some arguments trigger short special cases, so three full logarithm costs cannot be assumed.
- **Change**: Trial the existing `if (!damp) return floored;` guard on GPU builds too, leaving all clamped candidate expressions and selection order intact. Compare emitted NVPTX/AMDGCN and actual `StateKernel` timing on coherent near-converged batches and mixed damping batches before choosing a version.
- **Why it is faster**: A wave whose junctions all skip damping avoids the log candidates and their dependent arithmetic. This is an expensive-work guard, not a proposal to replace cheap per-element selects with branches.
- **Est. payoff**: Unknown, needs profiling. Potentially material within `zPnjlim` on mostly undamped batches; could regress on mixed batches. The limiter's fraction of total GPU solve time is also unknown; eval, gathering, and state updates remain.
- **Risk**: Divergent warps/wavefronts may serialize paths, and LLVM may predicate the branch back into the existing form. Preserve physical-domain clamps, signed-zero choices, exact returned bits, and convergence reporting. No kernel arguments or Model/Instance layouts need change. Keep the already-guarded CPU path and all numerical oracles.
- **CPU / GPU / both**: GPU.

## Parse each scan once for all assigned destinations

- **Where**: `src/backend/str_kernels.zig:45-215`, `zScan`, `zScanN`, `zScanI`, `zScanR`, `zScanS`.
- **Now**: A scan assigning M destinations invokes the complete scan for the count and again for each requested item. Every pass walks the control string and converts fields, including `parseFloat` for real fields. This is redundant parsing and conversion across output projections, with scalar cursor dependencies inside each pass.
- **Change**: Coordinate lowering and `emitScan` to run one scanner into caller-owned, call-site-sized result storage and project the count and assigned items from that storage. Keep the current pure public functions for independent calls and preserve their all-format scan behavior. A flat assigned-value table is sufficient; no global memoization keyed by string pointers.
- **Why it is faster**: Eliminates repeated tokenization and real conversion for identical source/format bytes. It also avoids building a separate caching abstraction with invalidation problems.
- **Est. payoff**: Potentially several-fold for long formats with many destinations; the source-level upper bound is removal of M extra passes, not a measured speedup. Usually negligible for a short single-field scan. Total-runtime share is unknown, needs profiling.
- **Risk**: Preserve suppression, field widths, partial matching, EOF counts, destination defaults, integer wrapping, and float conversion. String results must borrow storage that remains valid, especially the `zFRead` line latch. File input must still occur exactly once in the accepted-point phase. Global `zSBuf` scratch does not authorize concurrent instance evaluation.
- **CPU / GPU / both**: CPU.

## Preserve unchanged check-source files for Zig cache reuse

- **Where**: `src/cli.zig:413-421`, `main`; `src/cli.zig:541-580`, `typeCheck`.
- **Now**: Every check rewrites the complete generated device at the same check path before spawning Zig, even when bytes are identical. This changes file metadata and forces generated-source cache validation/AstGen work that the orchestrator's existing `writeIfChanged` is designed to avoid. The check source is also separate from the later shared-object build tree.
- **Change**: Arrange shared access to the existing `orchestrator.writeIfChanged` behavior and use it for `typeCheck`'s device write. It is currently private, so this requires coordination with its owner rather than a copied implementation here. Keep spawning the requested check and keep the `--emit-so` validation path; skipping those checks is a separate behavior change.
- **Why it is faster**: Repeated identical checks can reuse Zig's source cache and avoid a full file write. The benefit scales with generated text size, not with the number of CLI flags.
- **Est. payoff**: Potentially noticeable for repeated checks of multi-megabyte generated devices; unknown, needs measurement. Child compiler startup and semantic analysis remain. It affects compile latency only, with no effect on simulation runtime.
- **Risk**: Retain all input validation, compiler errors, exit statuses, and contract-module resolution. Preserve write failure behavior; same-stem concurrent CLI invocations already share a path and need separate handling before claiming concurrent safety. An identical-file skip changes filesystem observables, so it was kept out of this semantics-preserving pass.
- **CPU / GPU / both**: CPU.

## Nothing to do

- `src/root.zig`: clean after the small reuse/error-forwarding cleanup; generated output is already cached, frontend prelude work is seeded, and arena/provenance lifetimes are deliberate, so no independent performance change is proposed.
