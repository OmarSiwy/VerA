# s1-harness: the CLI and the test harness

Step-1 notes for `src/main.zig` (U72), the suite runner `tests/bench.zig`,
`tests/harness.zig`, `tests/torture.zig`, `tests/ieee1364.zig` (U74-U79),
`tests/test_all.zig`, `tests/exhaustive.zig` (U61), the `tests/*_host.zig`
and `vdev_*.zig` hosts (U18, U24-U33) and `tools/zrunner.zig` (U20).
Written 2026-10-03 against base `64357568`.

## Spine and ownership after step 1

`vera` (`src/main.zig` `main`): `cli/args.zig` `parse` (argv -> `Cli`) ->
refuse conflicting flags -> read the source -> `cli/digital.zig` `run` for a
`.v`, else `compileAnalog` (main.zig).

The suite (`tests/bench.zig` `main`) dispatches on the mode word; each mode is
one file:

| File | Owns (writes) | Mode / transform |
|---|---|---|
| bench.zig | the timing table, the `expected` device-size table, `fixture_reps`, `mode`, `elapsed` | `benchmark`: depth pass (`harness.run`) then the accept/reject timing pass |
| harness.zig | `Fixture` rows (`collect`), `Slot`s, `Counts`, `vera_exe` | `run` (spine): collect -> `Compiler.prepare` -> `judge` per fixture on N workers -> summary |
| harness/lint.zig | nothing (pure) | the assertion lint `decide` runs first |
| harness/coverage.zig | `Cite`s, the LRM contents table, `CLAUSES.tsv` rows | `--coverage` (measure C) |
| harness/digital.zig | nothing (pure) | `.v` runner metadata: routing, args, reject/xfail/warning obligations, VCD tokens |
| harness/devices.zig | the case list | `devices`, `ieee1364`: `vera --run` transcripts |
| harness/native.zig | `NativeSlot`s | `--native`: the same cases through `vera --emit-exe` |
| harness/fuzz.zig | the generated designs | `--fuzz N` |
| harness/c_fixtures.zig, spice_decks.zig | nothing kept | `vpi`, `spice` census |
| harness/sweep.zig | nothing kept (asserts `bench.expected_sizes`) | `--sweep`, and the size test on `zig build test` |
| harness/child.zig | nothing | one child run, both streams |
| torture.zig | `Ctx.batched`, `Chunk`s | the VerA `Compiler` plug (full and accept/reject) |
| ieee1364.zig | `Clause`/`Chapter` tables | `test-1364 -- --coverage` (measure B) |

The verdict algebra (`judge`/`decide`), the `ok=` tally (`countVerdicts`),
`//! checks N`, XPASS-fails and `--strict` are unchanged; only their files
moved. The sub-files are free functions; bench.zig, torture.zig and
ieee1364.zig import the sub-file they need directly, so harness.zig aliases
nothing.

## Behaviour-identity evidence

- Fixture suite at base and at the final commit, the suite binary run
  directly (AGENTS.md §0 rule 3): FAIL/XFAIL name lists, the `--strict`
  summary line, the per-fixture `fixture/demands/vera_out/vera_ok` columns,
  and `--coverage` for both `benchmark` and `test-1364`: see Measurements.
- `zig build test`, `test-devices` (996/996), `test-1364` (976/976),
  `test-vpi-fixtures` (76/76), `test-spice` (7/7) all exit 0.
- The suite's own unit tests: the 25 test names at base are all still run
  (26 now: the anonymous block that references the new sub-files).
- CLI: 69 command lines (usage errors in every flag that takes a value,
  `--explain`, each conflict, `.sv`/`.vhd`, `.va` and `.v` through `--lint`,
  `--emit-zig`, `-o`, `--check`, `--emit-exe`, `--run`, `--emit-so`, JSON and
  coloured diagnostics) give the same stdout, stderr, exit code and `-o` file
  from the base `vera` and the new one.
- `tests/exhaustive.zig`: a temporary unannotated `else` in src/main.zig
  still fails the guard with the same message (reverted, not committed).
- Goldens (`tools/golden-baseline.sh`, since replaced by `zig build golden`): IDENTICAL.

## Seam proposals

1. **The §3.4 shape-card recompile and the runner preparation are written
   twice.** `src/main.zig` `compileAnalog` and `tests/torture.zig`
   `runAndCheck` both compile, call `tb.shapeOverrides`, recompile when cards
   moved a shape parameter, then set `mixedPlan`, `opStates`,
   `validate_contract`, call `warnGridEvents` and `renderRunner` in the same
   order; `tests/vpi_host.zig` `buildAnalogLib` does the last half. A third
   copy will drift. Better: one `vera.tb` entry,
   `tb.prepare(gpa, arena, source, target, opts, directives) !Prepared`
   returning the final `CompileResult` and the runner text, with the CLI's
   "a `--param` of the same name wins" rule as an option. Owner: lib/backend/tb
   (and `lib/root.zig`). Callers: main.zig, torture.zig, vpi_host.zig.
2. **`Mir` is reachable only by reflection.** `tests/harness/sweep.zig` spells
   it `@typeInfo(@FieldType(vera.CompileResult, "mir")).pointer.child`
   because `lib/root.zig` does not export it. Better: `pub const Mir` in
   lib/root.zig. Callers: sweep.zig only.
3. **IEEE 1364 §13 library resolution lives in the CLI.**
   `src/cli/digital.zig` `libraries` maps each file to its library, checks
   `-L` names and builds the search order; `tests/vpi_host.zig` `digitalHost`
   has no equivalent, so a VPI `.v` design cannot use a library map. Better:
   `vera.libmap.resolve(arena, io, bag, paths, maps, search) !Resolved`
   (lib, more, search, incdirs) with the refusals as diagnostics, the CLI only
   reporting. Owner: lib/frontend/libmap. Callers: cli/digital.zig, vpi_host.zig.
4. **References by line number or old path, in files this agent does not own:**
   - `tools/conformance.sh:12-14, 51, 67` cited `bench.zig:828` and (fixed: `tools/conformance.py` names the files)
     `harness.zig:564`. The verdict row is now `tests/bench.zig` `summary` and
     the tally `tests/harness/coverage.zig` `report`; cite the function names.
   - `docs/CLAUSE-AUDIT.md:223, 500`: `tests/bench.zig`'s `digitalCases` is now
     `tests/harness/devices.zig`'s.
   - `tests/fixtures/ieee1364/08_udp/d08_reject_udp_*.v` and
     `tests/fixtures/digital/m04_2{0,1}_*.v` cite `torture.zig:<line>`
     (already stale at base); cite `verifyRejected` and `failureContains`.
   - `docs/IMPLEMENTATION.md:20` names `src/main.zig` `fileStem`; it is
     `lib/backend/orchestrator.zig` `fileStem` (stale at base).
   - `docs/UNITS.md` needs `zig build archmap` re-run: new files under
     `src/cli/` and `tests/harness/`.
   `engineCache`, `max_source_bytes` and `typeCheck` stayed in src/main.zig
   because docs/IMPLEMENTATION.md and docs/measurements cite them there.
5. **Considered and declined: the `Compiler` plug's function pointers.**
   `harness.Compiler` is a runtime vtable over two implementations
   (torture.zig's full and accept/reject plugs). A comptime generic would make
   `run`, `Job`, `judge` and `decide` generic for one indirect call per
   fixture against a `zig` compile per fixture. Kept; the type erasure is the
   stated reason in the struct's doc.

## Bugs found

1. **`-j1` aborts the run on a runner error; `-jN` reports it as a FAIL.**
   tests/harness.zig `run`, sequential branch: `counts.add(try judge(...))`
   propagates any error (`readFileAlloc`, a plug's error) out of `run`, so
   the suite stops with an error trace. The parallel branch (`Job.work`)
   catches it and prints `FAIL <path>: the runner itself failed: <err>`.
   Trigger: `zig build benchmark -- -j1 <filter>` over a fixture that cannot
   be read or whose `check` errors. Expected: the same FAIL line and the run
   continuing; actual: the run aborts.
2. **`countVerdicts` has no left boundary.** tests/torture.zig
   `countVerdicts` counts every `ok=` substring, so a transcript line
   `took=1` or `lookup_ok=1` counts as a passing verdict. AGENTS.md §6 says a
   verdict is the whole token `ok=1`. Trigger: a testbench that prints
   `took=1` and asserts nothing reads as asserted (`met`, not
   `unasserted`), and under `//! checks N` it shifts the count. Expected: only
   `ok=` at a token start counts. The right boundary (`ok=10` fails) is
   already enforced.
3. **An unreadable `.v` is silently not a fixture.** tests/harness.zig
   `fixtureExt` returns null on a read error (`catch return null`), so the
   fixture drops out of the walk and the count without a word. Expected: a
   FAIL naming the file. Low impact (needs a permission or I/O error).

## Memory

Counts are per suite run on this tree (2189 collected fixtures, 4119 cites,
612 LRM clauses, 808 IEEE 1364 clauses), the workload these types see; none
of them exists while `vera` compiles psp103.

| type | size before → after | count per run | bytes saved | what changed or why not |
|---|---|---|---|---|
| `harness.Fixture` | 80 → 48 B | 2189, collected twice by `benchmark` | 140 KB | `stem`/`dir` were slices of `path`; now derived (`stem()`, `dir()`); size asserted |
| `collect`'s `.v` reads | 367 KB held → one file | 456 golden-less `.v` sources | ~360 KB per collect | read into a per-file scratch arena, not the run arena |
| `exhaustive.zig` ASTs | all of lib/ and src/ → one file | ~180 files | test_all peak RSS 42 → 17 MB | per-file arena reset between files |
| `torture.Chunk` | 88 → 32 B | 274 | 15 KB | member offsets are below `batch_size`: `u8`; size asserted |
| `harness.Counts` | 32 → 16 B | 1 | 16 B | `u32`: a count of fixtures |
| `ieee1364.Chapter` | 64 → 32 B | ~30 | 1 KB | `u32` counters |
| `harness.Slot` | 24 B | 2189 | 0 | verdict + the fixture's owned report; nothing to drop |
| `coverage.Cite` | 40 B | 4119 | 0 | cold report; a `.c` cite has no fixture index to replace `path` with |
| `coverage.Clause` / `Classified` | 48 / 72 B | 612 / 124 | 0 | slices into the rendered HTML arena; cold |
| `ieee1364.Clause` | 40 B | 808 | 0 | slices into CLAUSES.tsv text; cold |
| `torture.Batched` (+ `Ctx.batched` map) | 24 B | ≤2189 | 0 | a `u8` index pads to 24 B; keyed by path because `check` gets a `Fixture`, not an index |
| `native.NativeVerdict` / `NativeSlot` | 24 / 40 B | ~1000 in `--native` | 0 | three bools and an enum sit in the slice's padding |
| `child.Captured` | 40 B | transient | 0 | two owned streams |
| `digital.VcdExpect` | 32 B | transient | 0 | two slices of the source |
| `torture.Tally` | 16 B | transient | 0 | |
| `sweep.Shape` / `Footprint` | 24 / 32 B | 15 (comptime) / 15 | 0 | comptime table; `usize` matches `.len` it is compared with |
| `zrunner.Test` / `TestResult` | 56 / 112 B | ≤ a few hundred per artifact | 0 | `name`/`namespace` are computed once from `test_fn.name`; the grouping copy is what fixes the output order |
| `args.Cli`, `digital.DeviceFlags` | one per process | 1 | 0 | one instance: packing its bools saves nothing |

## Measurements

Debug suite binary, this host under other agents' load (load average 31-56
during these runs), so wall times are noisy.

| | base `64357568` | final `a896414e` |
|---|---|---|
| `--strict` exit / stderr | 0 / `vera: 2189/2189 fixtures behave as they say they do` | 0 / byte-identical stderr |
| FAIL/XFAIL names | none (2189/2189 pass) | none, same (empty) list |
| `pass fail unasserted xfail` row | `2189 0 0 0` | `2189 0 0 0` |
| per-fixture `fixture demands vera_out vera_ok` columns | 2189 rows | identical except the speed row's timing |
| `--coverage` output, `benchmark` and `test-1364` (direct and via `zig build`) | | byte-identical |
| `--coverage` (benchmark) | 0.23-0.55 s, 17.1-19.5 MB | 0.22-0.34 s, 19.0-19.2 MB |
| `--coverage` (ieee1364) | 0.08-0.20 s, 9.1-9.9 MB | 0.08-0.11 s, 9.8-10.0 MB |
| test_all (exhaustive guard) | 0.41-1.14 s, 40.4-42.7 MB | 0.40-0.58 s, 15.1-17.3 MB |

`--strict` wall time, suite binary run directly from an empty
`.zig-cache/vera-suite`: base 94.0 s (first run), then paired runs base
181.3 s / final 375.6 s (base first, load rising 42 -> 55) and final 136.0 s /
base 110.4 s (final first), and 158.0 s for the final commit alone. The
in-process accept/reject compile total in the same runs (library code neither
side changed) moved from 6.7 s to 9.9 s, so the host's load swings these
numbers by about 50%; nothing in the harness change runs per fixture beyond a
`dirname`/`basename` slice and an arena reset, and no difference
attributable to it is measurable here. The wall time is the per-fixture
`zig` testbench builds.

ReleaseFast `vera --emit-zig`, best of 3 interleaved runs (the CLI change is
outside the compile, so these move only with noise):

| model | base | final |
|---|---|---|
| psp103 | 0.14 s, 31.0 MB | 0.18 s, 32.0 MB |
| bsim4va | 0.12 s, 22.3 MB | 0.12 s, 23.3 MB |
| hisimhv_va | 0.26 s, 47.6 MB | 0.26 s, 47.8 MB |

The base's own three runs spread 31.0-32.0 MB on psp103, so the 1 MB is
inside the noise.

## Merge notes and what was left

- `tests/bench.zig`'s `expected` device-size table (and its comment block)
  is byte-identical to the base at the same position relative to the code
  that stayed, so s1-device's edit of its numbers merges cleanly
  (simulated with `git merge-file`). `harness/sweep.zig` reads it as
  `bench.expected_sizes`.
- Not done: torture.zig is one plug of ~800 lines and was left whole (its
  reject and run halves share `compileFixture` and the batching); the
  `Compiler` vtable is kept (seam 5); `Cite` and `Batched` keep their slices
  (table above). `docs/UNITS.md` is not regenerated (not owned).
