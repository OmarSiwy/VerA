# VerA tools and test runners: performance review

Static review only. All six assigned files were read in full, after the required standards, README, and CONSUMING documents. Repository references and the installed Zig 0.16.0 stdlib were inspected. No build, test, benchmark, or profiler was run. Findings below are proposals, ordered by likely opportunity within their affected workloads; their relative payoff needs measurement.

Cleanup coverage:

| File | Review outcome |
| --- | --- |
| `tools/contract.zig` | Replaced the manual `__sec` suffix comparison with `std.mem.endsWith`, retaining its length guard. No math, ABI, or public declarations changed. |
| `tools/source_guards.zig` | Reviewed and unchanged; see Nothing to do. |
| `tests/harness.zig` | Removed the unused coverage section counter; report grouping still uses `prev`. |
| `tests/bench.zig` | Replaced the private field-size summation with `std.MultiArrayList(T).capacityInBytes(1)`. Its stdlib implementation sums the same field sizes; totals remain `u64`. |
| `tests/torture.zig` | Reused `std.ascii.isDigit` in `asCode`; all format checks remain. |
| `tests/external.zig` | Removed the unused receiver from private `External.wrap`; wrapper contents and compiler arguments are unchanged. |

Other apparent duplication was retained deliberately. The assertion scanner has different grammar and error recovery from the compiler lexer/preprocessor, whose identifier helpers are private. The contract's software math is required on device targets without host libm; replacing it with host builtins would break that path. `compileFixture`'s text search for `@compileError` is also not interchangeable with `result.device_has_compile_error`: quoted text can match the former without setting the latter. Changing that rejection policy requires a separate behavioral decision.

## Drain both compiler pipes concurrently

- **Where**: `tests/external.zig:204-236`, `capture`.
- **Now**: The runner reads stdout to EOF before reading stderr. A compiler that fills stderr while keeping stdout open blocks on its stderr write while the parent waits on stdout: a serialized dependency chain through pipe backpressure. Even a large parent read buffer does not drain the other pipe.
- **Change**: Use the existing `std.process.run(gpa, io, .{ .argv = argv })`, which drains both streams with `Io.File.MultiReader`, then concatenate its stdout followed by stderr to preserve the current report order. Retain `died`, the exit-status check, and the existing `Run` fields. Keep the current unlimited-output policy; adding a limit is a separate decision.
- **Why it is faster**: The child can continue producing diagnostics while either stream is active. This removes pipe stalls and the possible deadlock without inventing a subprocess collector.
- **Est. payoff**: Unknown, needs profiling. Potentially changes a verbose invocation from waiting until an external timeout to completing normally; little benefit for quiet compilers. The fraction of conformance runtime spent stalled is unknown.
- **Risk**: `std.process.run` propagates stream errors that the current code swallows and has different cleanup behavior, so this is not a semantics-preserving substitution on every failure path. Validate interleaved large output, empty streams, signals, timeout statuses, and allocation failures before adopting it. Preserve stdout-then-stderr presentation.
- **CPU / GPU / both**: CPU.

## Reset scratch memory between sequential fixtures

- **Where**: `tests/harness.zig:238-286`, `run`; existing pattern at `tests/harness.zig:197-217`, `Job.work`.
- **Now**: The `-j1` path passes the run-lifetime arena to every `judge` call. Source text, parsed directives, runner text, and scratch paths accumulate across fixtures. The parallel worker already resets its own arena with `.retain_capacity`. Sequential retention increases the resident working set and can cause extra page faults and memory pressure.
- **Change**: Give the sequential branch a separate fixture arena, following `Job.work`. Reset it before each fixture, pass its allocator to `judge`, and retain the outer arena for the collected fixture paths and command-line state. Preserve the per-fixture flush.
- **Why it is faster**: Scratch allocation reuses memory sized for the largest fixture instead of continually growing storage for the sum of all fixtures. The working set stays smaller during a full sequential sweep.
- **Est. payoff**: Live scratch storage falls from the sum of fixture scratch sizes to approximately their maximum, plus arena overhead. Wall-time payoff is unknown, needs profiling; likely modest while memory is plentiful and larger under memory pressure. This affects sequential torture and conformance runs, not `Job.work`.
- **Risk**: Verify that compiler callbacks retain no references to the fixture arena after returning. Fixture paths and compiler configuration must remain in the outer lifetime. Retain streaming output, error propagation, and all parsing/read limits.
- **CPU / GPU / both**: CPU.

## Release each generated benchmark result after its timed sample

- **Where**: `tests/bench.zig:391-415`, `measure`; result retention in `tests/bench.zig:352-358`, `runPhase`.
- **Now**: For a single input, `kept` accumulates successful `CompileResult`s across all 25 repetitions and frees them only when `measure` returns. Each retained result holds its compilation arena and possibly a large generated device buffer. Later repetitions allocate around earlier live results, increasing page faults and resident memory.
- **Change**: After recording each repetition's end timestamp, deinitialize that repetition's retained results and call `kept.clearRetainingCapacity()`. Reserve only the single-input capacity needed. Keep the outer cleanup for errors, the 25 repetitions, the minimum estimator, and the batch path's existing teardown policy.
- **Why it is faster**: The allocator can reuse freed storage between repetitions. This removes growth in live compilation state while keeping teardown outside the timed interval.
- **Est. payoff**: At most 25 live successful results become at most one for the single-input sweep. This is a storage bound from the code, not a measured RSS or speedup. Time saved is unknown, needs profiling; the fixture batch is unaffected and may dominate a full benchmark run.
- **Risk**: This changes allocator/cache conditions between samples and therefore the interpretation and comparability of timing results. Evaluate it as a benchmark-methodology change, not an engine speedup. Keep size assertions, byte counts, failure cleanup, and timing boundaries intact.
- **CPU / GPU / both**: CPU.

## Share sin and cos range reduction in device tangent evaluation

- **Where**: `tools/contract.zig:307-385`, `gm.remPio2`, `gm.softSin`, and `gm.softCos`.
- **Now**: Both software trig functions call `remPio2` for the same argument outside the small-angle path. Generated `zTan` computes `a.sin().div(a.cos())`; for the generated scalar `R`, these route through `contract.gm`. The sibling host's `StateKernel` calls `D.limit` and `D.updateState`, so these helpers actually reach device code. Unless optimization shares the work already, the pair repeats range reduction, including the dependent correction rounds and large-angle pre-reduction.
- **Change**: First inspect the emitted device assembly for a representative state kernel using tangent. If both reductions survive, introduce a paired device trig helper that computes the existing reduction once and feeds the unchanged `kernelSin` and `kernelCos`, with the existing quadrant signs and entry guards. Route only the scalar device tangent path through that helper. Preserve the separate public `sin` and `cos` behavior. Wiring a new shared helper through generated code requires a coordinated additive interface change outside this cleanup scope.
- **Why it is faster**: The paired operation executes one dependent range-reduction chain instead of two. The proposed target is redundant compute, not global-memory traffic; the helpers use scalar temporaries, and adding shared memory would not help this reuse.
- **Est. payoff**: Two reductions become one when both calls need reduction and the optimizer has not already combined them. The paired-call speedup is below 2x because both polynomials and the final division remain; actual kernel and total simulation payoff are unknown, needs profiling. Small-angle inputs or already-shared assembly may gain nothing. No hardware roofline is claimed without a target and generated instruction counts.
- **Risk**: Bitwise preservation requires the current tiny-angle, nonfinite, quadrant, and cancellation-correction behavior, with unchanged coefficients and floating-point evaluation order. Do not replace cos with a shifted sin, enable fast math, or lower precision. The paired result may increase register lifetimes and cause spills. Differential-check against the existing separate soft paths at all branch boundaries and large arguments. Keep `Model`, `Instance`, and kernel argument layouts unchanged.
- **CPU / GPU / both**: GPU; the host branches already call the host builtins and should remain unchanged.

## Copy ordinary HTML text in spans

- **Where**: `tests/harness.zig:697-745`, `renderText`, called by `lrmClauses`.
- **Now**: Ordinary prose is dispatched through a switch and appended one byte at a time, despite the output buffer already having capacity for the whole input. This scalar loop performs repeated classification, index updates, and stores over every chapter's text during coverage reporting.
- **Change**: In the ordinary-text arm, find the next `<`, `&`, or byte `0xC2` with `std.mem.indexOfAny`, then copy that span with `appendSliceAssumeCapacity`. Keep the existing tag, entity, and UTF-8 cases exactly as they are, including malformed-input handling. Start with the stdlib search and inspect its generated code before considering an explicit vector loop.
- **Why it is faster**: Bulk copying removes per-byte output bookkeeping and exposes contiguous search/copy operations to optimized stdlib implementations. Only special bytes require the stateful parsing branches.
- **Est. payoff**: Unknown, needs profiling. Most promising for long prose spans; frequent tags or entities reduce the benefit. This affects `--coverage` and its contents-page check only, and may be a small share beside file reads, sorting, and report output.
- **Risk**: Preserve a newline for every tag, unknown-entity pass-through, raw NBSP handling, missing terminators, and final partial spans. The present scalar implementation should remain the differential oracle until byte-for-byte equivalence is established. No fixture-verdict grammar changes belong in this work.
- **CPU / GPU / both**: CPU.

## Transfer generated failure text instead of copying it

- **Where**: `tests/torture.zig:199-218`, `compileFixture`; ownership consumers at `tests/torture.zig:142-148`, `verifyRejected`.
- **Now**: A generated `@compileError` triggers `gpa.dupe` of the entire device text before the compilation is destroyed. `CompileResult.device.text` is already GPA-owned and freed by `CompileResult.deinit`, so the failure path temporarily holds two buffers and performs an allocation plus a full-buffer copy.
- **Change**: Transfer `result.device.text` to `Failure.generated`, clear just the owning `result.device.text` slice before deinitializing the rest of the result, and keep the existing failure consumer's free. Continue using the current textual rejection check unless its policy is changed separately. This should replace the duplicate ownership rather than expose a borrowed slice after deinitialization.
- **Why it is faster**: The failure path avoids copying and allocating another device-sized buffer. Peak live storage decreases by approximately the copied text size.
- **Est. payoff**: Removes one allocation and one O(device-text-bytes) copy per generated-code rejection. Wall-time impact is unknown, needs profiling; this path handles only rejections that survive frontend diagnostics and reach generated `@compileError`, so total suite impact is likely small.
- **Risk**: Check every success and error exit for exactly one owner. In particular, the existing `generateDevice` OutOfMemory branch explicitly deinitializes a copied result before returning an error that also triggers `errdefer result.deinit()`; that pre-existing cleanup problem requires a separate correctness fix and allocation-failure coverage. Removing the new allocation also changes possible OutOfMemory outcomes, so the ownership transfer was not applied in this semantics-only pass. Preserve complete generated diagnostics and their lifetime.
- **CPU / GPU / both**: CPU.

## Nothing to do

- `tools/source_guards.zig`: reviewed and unchanged; stdlib searches, arena-backed worklists, and cold filesystem checks fit the workload, with no justified hot-loop or layout change found.
