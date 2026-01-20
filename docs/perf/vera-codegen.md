# Codegen performance review

Reviewed all of `src/backend/codegen.zig`, including its emitted runtime helpers and tests. Applied only the redundant precompute-cost-walk removal, an unused private helper removal, existing zero-spelling reuse, stdlib membership searches, and reuse of the fixed state-control predicate. Public interfaces, emitted arithmetic, and validation guards were preserved by inspection. No build, test, profiler, or benchmark was run.

The proposals below are ordered by potential payoff on workloads that exercise them; their relative importance needs profiling. Line references describe the edited file. GPU reach was checked in `../ARPice/src/devices/engine.zig`: the resident kernel calls `evalRange`, which invokes generated `D.evalQ`/`D.eval`. Its `gpuEligible` gate excludes history devices, so the delay finding is CPU-only. No proposal below was implemented.

## Choose chunk boundaries with fewer live values

- **Where**: `src/backend/codegen.zig:2714-2934`, `emitUnitBody`, `maybeCut`, `ocLocalIn`, and `openChunkFn`.
- **Now**: Opt-in outlining cuts at the next legal top-level boundary after a statement budget. Values spanning chunks occupy the `h`, `hi`, or `hs` arrays, whose addresses pass through sequential `@call(.never_inline, ...)` calls. The existing chunk-local classification already avoids many hoists, but the cut selection ignores how many values it forces across a boundary. Escaped arrays inhibit CPU register promotion and can cause GPU per-thread local-memory traffic and register spills; actual machine-code effects need inspection.
- **Change**: Record legal depth-one cut candidates during probing. Use `Place.def_off`, `max_def`, and `max_use` to conservatively score the live values crossing each candidate, then choose nearby cuts with fewer live values while keeping a bounded statement budget. Rerun the existing scope probe for the selected boundaries and retain its fallback when the return shape is unsuitable. Keep the existing chunk-local storage path and never-inline calls.
- **Why it is faster**: Keeping a producer and its consumers in one chunk can turn escaped-array loads/stores into local values and reduce the per-thread frame. This targets the remaining outlining overhead without reintroducing one enormous compiled function.
- **Est. payoff**: Unknown, needs profiling. Potentially substantial for large outlined bodies with many cross-chunk values; no benefit when outlining is disabled. These bodies can occupy much of device evaluation, but their share of total solve time is unknown. Measure CPU loads/stores and GPU local-memory traffic alongside downstream compilation time.
- **Risk**: Multi-definition slots, phi copies, loops, returned values, and zero seeds require conservative lifetimes. Preserve statement order, per-function float mode, return guards, and device layouts. Different compiler optimization across new boundaries can still affect floating-point results, so numerical validation is required before adoption.
- **CPU / GPU / both**: Both, generated device evaluation on the eligible resident-kernel path.

## Prepare literal table permutations once

- **Where**: `src/backend/codegen.zig:4007-4034`, `emitTable`; emitted `zTable` comes from `src/backend/table_kernels.zig`.
- **Now**: Each emitted lookup constructs the flat sample array and calls `zTable`. That helper initializes a row-index permutation and insertion-sorts it on every evaluation before calling `zTabAt`. Sorting is linear on sorted input and quadratic on adversarial row order; it also writes a per-call stack array. The lookup point changes during a solve, while wholly literal sample rows do not.
- **Change**: For wholly literal sample blocks, have `emitTable` emit immutable rows plus an immutable sorted permutation. Reuse the existing stable `zTabSort` logic at preparation time and add a coordinated prepared-table helper that shares `zTabAt` and the existing derivative reconstruction. Retain the current path for nonliteral samples. First inspect optimized output to check whether the compiler already eliminates sorting for the target model.
- **Why it is faster**: The repeated lookup no longer initializes and sorts the same permutation. GPU threads can read the prepared data instead of each maintaining and sorting their own local permutation.
- **Est. payoff**: Unknown, needs profiling. Removes an O(NP) to O(NP²) preparation step per lookup if it survives optimization; interpolation still runs. Most relevant for hundreds or thousands of rows evaluated repeatedly. The table's fraction of total solver runtime is unknown, and models without tables receive no benefit.
- **Risk**: Keep stable duplicate ordering, exact row values, dimension order, extrapolation rules, and the derivative arithmetic unchanged. Do not freeze parameter expressions using declared defaults. Extending this to dynamic sources requires a separate first-call snapshot/lifecycle design and review of any `Instance` layout change. The helper-file change requires coordination outside this audit's ownership.
- **CPU / GPU / both**: Both, for table-bearing devices that pass the host's GPU eligibility gate.

## Search deep delay history by logical time index

- **Where**: `src/backend/codegen.zig:7051-7105`, emitted `zAbsdelay`, `zHistAt`, and `zHistPush`; the fixed capacity is declared at `src/backend/codegen.zig:6444`.
- **Now**: After the endpoint clamps, `zHistAt` scans backward through up to 512 timestamps. Each iteration computes a wrapped predecessor and branches on the bracket test, creating a serial dependency chain. Recent queries are cheap, but an interior query deep in the ring repeatedly walks much of the same history during Newton evaluation. The separate timestamp/value arrays already avoid loading values until a bracket is found.
- **Change**: After establishing a finite, nondecreasing accepted-time invariant, retain the endpoint and recent-bracket fast paths and binary-search the remaining logical sequence `ts[(head + k) % n]`. Select exactly the bracket that the current newest-first scan would select, including equal timestamps. Keep the existing scan for inputs for which the ordering invariant is unavailable; avoid rescanning the whole ring merely to validate every query.
- **Why it is faster**: Deep searches require logarithmically many timestamp probes instead of a long serial walk. The value loads and interpolation remain unchanged.
- **Est. payoff**: Unknown, needs profiling. A 512-entry search has roughly nine binary-search levels rather than up to 512 scan iterations; this is an operation-count comparison, not a measured speedup. Recent queries may favor the existing scan. Overall payoff depends on delay-heavy transient models and the number of evaluations per accepted step.
- **Risk**: The helper itself does not enforce monotonic or finite timestamps, so unconditional binary search is unsafe. Preserve seeded duplicates, wraparound, exact-knot selection, NaN fallback behavior, oldest clamps, the `span <= 0` guard, and the exact interpolation operation order. Keep the frozen history capacity and state layout.
- **CPU / GPU / both**: CPU; the current resident GPU gate excludes history devices.

## Render f64 expressions into one temporary buffer

- **Where**: `src/backend/codegen.zig:4148-4266`, `f64Const`; related string assembly is in `slotRefStr` and `renderToArena`.
- **Now**: Recursive unary and binary rendering allocates an arena string at each node using `allocPrint`, then copies child strings into their parents. Slot references can allocate once for the slot name and again for `.val()`. Unmaterialized expression chains therefore recopy their prefixes and retain intermediate strings until arena teardown. The depth-32 guard and existing materialized-slot reuse bound this cost but do not eliminate it.
- **Change**: Keep the public `f64Const` interface. Add a private recursive writer using one per-call growable scratch buffer, copy only the completed expression into the arena, and release scratch storage. Reuse the existing spelling and formatting decisions. Preserve the original output position observed by `probeUse`; do not let scratch writes change placement evidence. Avoid caching rendered unit expressions across probe, hoist assignment, and final emission.
- **Why it is faster**: Appending fragments once removes per-node retained strings and repeated parent copies, reducing allocator work and memory bandwidth during generation.
- **Est. payoff**: Unknown, needs profiling. Benefits parameter-heavy or control-expression-heavy generation where intermediate strings are a significant allocation source. Existing slot reuse limits the opportunity; no direct device-runtime speedup is expected. Its share of overall compilation, including Zig compilation, is unknown.
- **Risk**: Preserve the depth guard, `devSafe` check, fold/slot precedence, `.val()` placement, parentheses, usage flags, probe offsets, null results, and diagnostics. A renderer refactor must not change which expression is evaluated or fold through a live slot. Keep this a proposal until generated-output comparisons are available.
- **CPU / GPU / both**: CPU, compiler execution only.

## Index operator instructions by unit

- **Where**: `src/backend/codegen.zig:896-923`, `buildUnits`; `src/backend/codegen.zig:2429-2448`, `opInstOf`, `opArgs`, and `opInputIdx`.
- **Now**: `buildUnits` constructs an instruction-to-unit `op_unit` array. Every reverse lookup in `opInstOf` scans that entire instruction-indexed array until it finds the unit. `opArgs` and `opInputIdx` repeat these scans from job construction and operator/state emission, rereading irrelevant instruction entries.
- **Change**: During the existing unit-enumeration walk, also fill a dense unit-to-instruction table using u32 instruction IDs and a sentinel for non-operator units. Make `opInstOf` index that table with bounds and sentinel handling. Retain the existing forward mapping and its observable surface; decide where the new private planner storage belongs before changing exposed `Gen` fields.
- **Why it is faster**: K reverse queries over I instructions become O(I + K) setup/access work instead of up to O(K × I) scanning. The reverse table scales with units rather than all MIR instructions.
- **Est. payoff**: Unknown, needs profiling. Most relevant when a large MIR also has many analog operators and repeated metadata queries; likely negligible for a small stateless device. Measure the query count and instruction scan volume. The share of total compilation is unknown.
- **Risk**: Preserve naming's enumeration order, missing-unit behavior, and the first matching instruction if the mapping ever ceases to be unique. Do not replace externally nameable fields or change unit IDs. Requires storage/API review beyond this cleanup.
- **CPU / GPU / both**: CPU, compiler execution only.

## Nothing to do

No owned file was entirely clean: `src/backend/codegen.zig` was reviewed in full and changed. Existing per-type hoist arrays, chunk-local placement, shared helper emission, numerical/domain guards, and scalar-interface distinctions were retained. The apparently write-only `Job.sec_of` field was also retained because it is reachable through exposed generator state; removing it would require an API decision, and its performance value is unestablished.
