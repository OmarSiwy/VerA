# Seam notes: s1-backend (UNITS.md U64, U68, U69, U70, U71, U08)

Step-1 agent for the backend driver, the testbench and the compiler facade:
`lib/backend/{naming,orchestrator,root,tb}.zig`, `lib/backend/tb/**`, the
new `lib/backend/driver/**`, `lib/root.zig` and `lib/big_arena.zig`. Base
`64357568`. Nothing outside that set was edited; every proposal below is for
the seam agents.

## Spine and ownership after step 1

- `lib/root.zig` `compileInArena`: preprocess, lex, parse, §3.7 wreal check,
  lower, `pruneHeld`, ifconv, prove, §9.4 W0850 drops. Owns `CompileResult`
  and its `BigArena`; codegen runs lazily from `generateOutput`.
- `lib/big_arena.zig`: owns `blocks`, the live large-block table. Writers:
  its own vtable functions. Readers: none outside.
- `lib/backend/naming.zig`: owns the canonical unit order (`enumerateUnits`)
  and the name grammar. Read by codegen and proof.
- `lib/backend/orchestrator.zig` `compileRelease`: spawn children, `writeTree`,
  write shims, send updates, collect, link, `publish`. Owns the build policy
  (options, argv, split, layout hash) and the on-disk tree.
  `driver/shim.zig` owns every byte of text written beside a device (frozen);
  `driver/server.zig` owns the compiler-server child protocol.
- `lib/backend/tb.zig`: owns the directive types. Pipeline a caller runs:
  `parse` (`tb/directive.zig`) → compile, `shapeOverrides` → `opStates`,
  `mixedPlan` → `renderRunner`/`renderVpiLib` (`tb/runner.zig`, over the
  fixed text in `tb/runner_text.zig`) → `buildExe`, or `stageExe` +
  `buildBatch` (`tb/exe.zig`).

## What changed

- `orchestrator.zig` split: the shim/engine-root templates moved verbatim to
  `driver/shim.zig` (`device`, `part`, `chunk`, `fileName`, `engine_root`),
  and `Server`/`send` to `driver/server.zig`. `orchestrator.zig`'s pub
  surface is unchanged.
- `tb/directive.zig`: the 27-arm `std.mem.eql` keyword chain is a `Keyword`
  enum (`std.meta.stringToEnum`) and an exhaustive `switch`. `marker` moved
  here from `tb.zig` (no outside reader). Helpers only this file calls are
  private.
- `tb/runner.zig`: the card tail (temperature, `derive`, shape check) was
  written five times and the point's unknowns twice; now `deriveCard` and
  `pointUnknowns`. The `print_residual` tail is one `print`. `expand` fills
  one block of cells instead of one allocation per point. The file follows
  its spine (facts, renderers, shared pieces in write order, table checks).
  `renderMixed` and `fmtF64` are private.
- `tb/exe.zig`: `buildExe` and `buildBatch` shared their argv head, binary
  path, work-dir open and run/collect step by copy; now `argvHead`,
  `binPath`, `openWorkDir`, `runZig`. `bind` is private.
- `tb.zig`: `Io`, `Allocator` and `marker` are no longer re-exported (no
  reader outside `tb/`). `runner_text.zig` lost two unused imports; the
  emitted text is untouched.
- `lib/root.zig`, `lib/backend/root.zig`: `backend.UnitPlan` is gone
  (s1-codegen proposal 2; `codegen.zig`'s test block still reaches its
  test). The §9.4 drop loop tests `opts.display` once, outside the loop.
- `big_arena.zig`: `large` is 16 KiB (was 64 KiB). See Memory.
- Doc comments on every pub declaration that lacked one; size asserts on
  `naming.Unit`.

Emitted-text check: the fixture suite stages every runner (`*.tb.zig`) and
batch root (`*.batch.zig`); the 1641 files staged at the base commit and at
the final commit are byte-identical (`diff -r` reports only six self-test
files that `zig build test` adds to the same directory).

## Memory

Sizes from `@sizeOf` on x86_64; counts from instrumented runs (2026-10-03).
RSS and instructions: ReleaseFast `vera --emit-zig`, best of 3, instructions
from `perf stat -e cpu_core/instructions/u` pinned to one core.

| type | size before → after | count on psp103 | bytes saved | what changed or why not |
|---|---|---|---|---|
| `BigArena` small/large split (`large`) | 64 KiB → 16 KiB threshold | 1 per compile | peak RSS psp103 −2.9 MB (−8.8%), bsim4va −2.8 MB (−11.5%), hisimhv −2.9 MB (−5.8%) | Lists of 16-64 KiB now grow in `smp_allocator` slabs, which take a dropped buffer back at once; in the arena every outgrown copy stayed dead until `deinit`. 4, 8 and 32 KiB measured worse. Instructions unchanged (±0.003%). |
| `BigArena.Block` | 16 → 16 B | ≤ 40 live (56 large allocations at 64 KiB) | 0 | Hash-map entry per large block; ≤ 50 live on hisimhv, immaterial. |
| `BigArena` | 72 → 72 B | 1 | 0 | One per compile. |
| `naming.Unit` | 32 → 32 B (asserted) | 18 (bsim4va 25, hisimhv 43) | 0 | `target` is a slice codegen reads by field; a string handle would save 12 B × 43 rows. |
| `naming.enumerateUnits` `assignDisambig` | O(n²) | n = 18..43 | 0 | Kept: 43² string compares is nothing. |
| `CompileResult` | 224 → 224 B | 1 | 0 | Frozen pub shape. |
| `Options` (`vera`) | 128 → 128 B | 1 | 0 | Frozen pub shape; passed by value once. |
| `tb.Directives` | 576 → 576 B | 1 per fixture | 0 | Eight `bool`s could be one packed flags byte, but `tests/harness.zig`, `tests/torture.zig`, `src/main.zig` read them by field. Not hot. |
| `tb.Binding` / `Sweep` / `LimitCase` | 24 / 32 / 32 B | per directive line | 0 | Cold, arena-owned. |
| `tb.NoiseWant` | 120 → 120 B | per `//! noise` line | 0 | Five optionals; cold. |
| `tb.AcWant` / `AcDynWant` | 72 / 64 B | per line | 0 | Cold. |
| `tb.Mixed` | 208 → 208 B | 1 per mixed fixture | 0 | Borrowed slices of `Lowered`. |
| `expand` result | 16 B header + 1 allocation per point → 16 B header, cells in one block | ≤ 4096 points | ≤ 4096 arena allocations per runner | Cold path; done because it was a per-element allocation. |
| `tb.BuildOptions` / `BuildResult` / `Staged` | 88 / 24 / 32 B | 1 per build | 0 | Cold. |
| `orchestrator.Module` / `Options` / `Artifact` / `Result` / `EngineResult` | 48 / 88 / 32 / 40 / 40 B | 1 per build | 0 | Cold, frozen. |
| `driver.Server` | `Child` + reader, 64 KiB arena buffer | 1 per piece (≤ 3 + chunks) | 0 | The buffer is the steady-state message size; bodies beyond it are read whole. |
| `writeTree` `body` | reused across units | 1 | 0 | Already cleared per unit, not reallocated. |

Before → after (ReleaseFast, peak RSS best of 3 / user instructions). One
psp103 run read 27 704 KB; the 29 672 KB shown is the best of five repeats,
which all fell within 29.6-30.0 MB. Wall time is not shown: the machine ran
at load 80-120 and best-of-3 user time moved by ±0.02 s either way.

| model | before | after |
|---|---|---|
| psp103 | 32 536 KB / 1 379 922 496 | 29 672 KB (−8.8%) / 1 379 873 163 |
| bsim4va | 24 040 KB / 1 005 421 342 | 21 276 KB (−11.5%) / 1 005 379 987 |
| hisimhv_va | 49 164 KB / 2 163 473 790 | 46 288 KB (−5.8%) / 2 163 401 272 |

## Seam proposals

1. **`Options.diags` copies every source text on every compile**
   (s1-diag proposal 1, `lib/root.zig` `compileSourceOpts`). Not done here:
   both fixes change a frozen contract. Detaching only on failure leaves a
   successful compile's bag borrowing the result's arena, so `Options.diags`'
   documented rule ("stays valid after the `CompileResult` is freed; the
   caller must `deinit(gpa)` it") changes for every caller: `src/main.zig`
   (renders after codegen), `tests/harness.zig`, `tests/torture.zig`,
   `tests/bench.zig`, `tests/vpi_host.zig`, `src/vpi`. Moving the bag into
   `CompileResult` adds a pub field. Sketch: `CompileResult.diags: diag.Bag`
   (arena-backed, valid until `deinit`), `Options.diags` kept as a
   compatibility path that still detaches; callers migrate, then the copy
   path is removed. About 1.4 MB on hisimhv_va (s1-diag's number).
2. **s1-codegen proposal 1 (move `cg_*` under `codegen/`).** Still blocked
   on one line each here: `lib/backend/root.zig` re-exports the three files
   because nothing else reaches their tests, and `lib/root.zig`'s
   refAllDecls names `cg_display`/`cg_filters`. When codegen moves them, add
   `_ = display; _ = filters; _ = limit;` to `codegen.zig`'s `test` block,
   then delete those re-exports and the two tuple entries. s1-codegen
   proposal 2 (drop `backend.UnitPlan`) is done.
3. **s1-codegen proposals 4 and 5** (`pruneHeld` to `ir`, naming's test
   fixture) need `ir` and codegen files; untouched. `lib/root.zig` calls
   `codegen.pruneHeld` in one place, so the move is a one-line change here.
4. **One argv vocabulary for `zig` children.** `orchestrator.buildArgv`,
   `linkArgv`, `buildEngine` and `tb/exe.argvHead` each spell `-O`, the
   backend flags and `-fstrip`; the orchestrator's carry `--listen=-` and
   `-fincremental`, the testbench's `-femit-bin`. A shared
   `orchestrator.zigFlags(optimize, backend, strip) []const []const u8` would
   keep them from drifting. Every argv is frozen, so it waits for a step
   that may re-verify them.
5. **`tb.Directives` flags.** `solve_free`, `print_residual`, `nowarn`,
   `validate_contract` and the four `asserts_*` could be one
   `packed struct(u8)`. Readers by field: `tests/harness.zig`,
   `tests/torture.zig`, `tests/vpi_host.zig`, `src/main.zig`. Saves 7 B on
   a once-per-fixture value; only worth doing with another change there.

## Bugs found

1. **`naming.max_name_len` does not cover the names it claims to.**
   `lib/backend/naming.zig` sizes `max_name_len = 8192` for "two §2.7
   identifiers of 1024 characters at 3x sanitization", but a contribution
   unit name holds three: the module and both nodes
   (`<module>__analog__I_<hi>_<lo>`). Trigger: a module and two nets with
   1024-character §2.8.1 escaped names of non-alphanumeric bytes, and a
   contribution between the nets. Expected: compiles. Actual:
   `unitName` returns `error.NoSpaceLeft` (3 × 3072 + 15 > 8192); the
   failure is reported, never truncated, so it is a limit defect, not a
   wrong name. Fix: size it for three leaves, or derive it from the leaf
   bound.
