# AGENTS.md

Read this before touching anything. §0–§9 are VerA's rules; §10 and §11 are
the design review and its rulings (`PRINCIPLES.md` holds the reasoning). The
long documents are listed in §1 and you are going to read those too.

VerA is a Verilog-AMS compiler in Zig. It compiles Verilog-A into Zig device
code that an external simulator links and calls inside a Newton loop.
`lib/` is the compiler, `src/` is everything that runs after it.

---

## 0. The three rules that are not negotiable

**1. Never type a conformance number. Measure it.**
`tools/conformance.py` is the only thing that may write measures A, B and C.
At a release it writes them into `CHANGELOG.md` (§3). `.github/workflows/publish.yaml` re-measures on
the runner and refuses any tag whose entry disagrees with the tree. If you find
yourself about to write a percentage into a document, run the script instead.

**2. Gate on `$?`, never on the tail of a log.**
`zig build test 2>&1 | tail` swallows the exit code. This has produced a green
report over a failing build in this repository before (`TODO.md §2.1`). In a
pipeline, `exit "${PIPESTATUS[0]}"`.

**3. Diff FAIL *name lists*, not counts.**
A count can stay still while the membership changes. Two agents were only able
to claim "no regressions" honestly because they compared names.
Before and after any change:

```sh
# The build runner TRUNCATES a failed step's output, so grepping `zig build
# benchmark` finds 0 names and reads as a pass. Run the suite binary itself:
cmd=$(zig build benchmark -- --strict zzz-none 2>&1 | grep '^failed command:' | sed 's/^failed command: //')
set -- $cmd; "$1" "$2" --strict > out.txt 2> err.txt      # suite, vera
grep -E '^(FAIL|XFAIL) ' err.txt | sed 's|^\(X\?FAIL\) .*/tests/fixtures/|\1 |; s|:.*||' | sort > after.txt
diff before.txt after.txt          # an empty diff is a pass only if the run happened:
```

No fixture carries `//! xfail` today, so both lists can be legitimately empty. An
empty list counts only when `out.txt` holds the suite's
`N/M fixtures behave as they say they do` line; compare N/M too, so a fixture that
stopped being collected shows.

The same trick applies to `zig build test-devices` (the digital transcripts;
all cases pass as of 2026-09-24 and must keep passing).

---

## 1. Read these, in this order

| Document | What it is | Use it for |
|---|---|---|
| `CHANGELOG.md` | every change since v0.0.1, one bullet each (fixes cite their GitHub issue); at each release, `tools/conformance.py`'s measured table under the version heading | what changed and where the project stands; where to add your own bullet (§9) |
| `ARCHITECTURE.md` | the target module DAG (the rewrite's, adapted) and its in-place migration: Phases 0–12, then behaviour changes B1–B4 | where a new file goes, and why; which phase is in flight (§6). The previous plan, all nine phases landed, is `git show 297e97d^:ARCHITECTURE.md` |
| `git show d16471b^:TODO.md` §2 and §4 | expensive knowledge and ground rules (deleted from the tree) | how to run a fixture; the traps |
| `specification/*.html`, `specification/VAMS-LRM-2023.pdf` | the LRM: 20 chapter and annex files | the normative text. Cite by clause number |
| `specification/1364-2005.pdf` | IEEE 1364-2005, a licensed local copy. Gitignored: never commit it, a text extraction of it, or bundle it in a release | the inherited clauses; `tests/fixtures/ieee1364/CLAUSES.tsv` lists its headings |
| `specification/CLAUSE-AUDIT.md` | the clause audit | the definition of `verified` / `partial` / `missing`, and measure B |
| `specification/Vague_Decisions.md` | every implementation-defined choice, every resource limit and its diagnostic, and the open limit defects | what VerA picks where the LRM leaves it open; what to name when you add a buffer or a cap |
| `PRINCIPLES.md` | the design principles (Parts I–VII, adopted 2026-10-17 from `../VerAReWrite/AGENTS.md`): lean storage, zero-overhead abstraction, easy to modify, contained failure, proven by tests | the reasoning behind §10's design review and §11's rulings; Chapter 24's checklists |
| `git show 8b1514d4:<path>` (local tag `audit-docs-2026-09`) | removed audit notes: `docs/conformance-*.md`, `docs/CONFORMANCE.md`, `docs/PLAN.md`, `docs/rules/*.json`, `tests/fixtures/MANIFEST.md`, and each fixture directory's `COVERAGE.md` and `*_SPEC.md` | the history behind a comment that cites one (`<path> at 8b1514d4`). Their open items were carried into `specification/Vague_Decisions.md` |

Measurements in older documents are superseded by the latest `CHANGELOG.md`
entry, or by running the commands in §2. When two disagree, the newest wins and
**you say so** rather than picking silently.

### Skills to load first

Load these with the Skill tool before writing or reviewing code (other agents:
read `~/.claude/skills/<name>/SKILL.md`). Where a skill and this file
disagree, this file wins and you say so.

| Skill | Use it for here |
|---|---|
| `compiler-construction` | Every stage of `lib/`: SoA token and node rows with `extra_data`, interning, narrow stage outputs, coded diagnostics, refuse by clause, goldens and conformance fixtures that cite the LRM (§6). |
| `zig` | Zig 0.17 idioms and memory discipline; `zero-cost.md` before claiming an abstraction is free. Its `simd-first.md` does not override §5: the compiler stays scalar unless §5's measurements change. |
| `data-oriented-design` | Every new table or struct: the six questions in writing, narrowest field widths. |
| `codebase-clean-code` | Where a new file goes (by what it must import, §4), one owner per table, closed boundary enums with no `else =>`. |
| `assertions` | Programmer-error contracts, stated capacities and their named diagnostics (`specification/Vague_Decisions.md`). |
| `doc-comments` | Every `pub` item and every file's `//!` header (in → out, the clauses it cites). |
| `test-plan` | New fixture families, differential runs, release gates (§3). |
| `ponytail`, `code-review` | Least code once the layout is fixed; review before merging. |

### Which skill, when

Skills marked _(explicit)_ never fire on their own: invoke them by name when
this file sends you there.

| Situation | Skill |
|---|---|
| Which skill to reach for; who wins on conflict | `systems` _(explicit)_ |
| Build order before, during and after writing; rulings | `codebase-rules` |
| Program or subsystem layout; where a feature goes; pattern vs concrete code; change drills | `codebase-clean-code` (+ `LADDER.md`, `HIERARCHY.md`, `DECISIONS.md`) |
| Deep-module vocabulary: module, interface, depth, seam, adapter; the deletion test | `codebase-design` (+ `DEEPENING.md`, `DESIGN-IT-TWICE.md`) |
| A boundary someone else calls: the device contract, `--emit-so`, OSDI, VPI | `api-design` (+ `zig.md`) |
| Struct layout, SoA/AoS, field widths, hot/cold, profiling a hot path | `data-oriented-design` (+ `foundations.md`, `measurement.md`, `REFERENCE.md`, `zig.md`) |
| Writing or reviewing `.zig`; does an abstraction cost anything | `zig` (+ `comptime.md`, `memory.md`, `zero-cost.md`, `simd-first.md`, `migration-0.17.md`) |
| Programmer-error contracts, capacities, bounded loops | `assertions` (+ `zig.md`) |
| A `pub` item, error set or module needs its doc comment; the doc audit | `doc-comments` (+ `zig.md`) |
| A data-dependent branch in a hot loop (the emitted device, §5) | `branchless` |
| A hot scalar loop to vectorize, after `branchless` (the emitted device, §5) | `simd-loops`, then `simd-first` |
| The NVPTX/AMDGCN device backends | `gpu-kernel-optimization`, `gpu-parallel-algorithm-thinking` |
| A lexer, parser, AST, IR, interner, diagnostics, goldens | `compiler-construction` (+ `FIXTURES.md`) |
| `src/sim/spice/`, the testbench solver, device models | `spice-engine` (+ `LINEAR.md`, `NUMERICS.md`, `TESTING.md`) |
| `--emit-verilog` output, `.v` fixtures | `writing-perfect-verilog` |
| Test strategy, fuzzing, differential/golden testing, CI gates | `test-plan` (+ `DOMAINS.md`, `TECHNIQUES.md`, `SOURCES.md`) |
| The red → green loop; where tests go | `tdd` (+ `tests.md`, `mocking.md`) |
| Reviewing a diff: Standards axis and Spec axis | `code-review` |
| What should not have been built | `ponytail` (writing), `ponytail-review` (a diff), `ponytail-audit` (a repo) |
| Terminology, `GLOSSARY.md`, ADRs | `domain-modeling` (+ `ADR-FORMAT.md`, `GLOSSARY-FORMAT.md`) |
| Bringing existing code up to §10/§11, block by block | `codebase-improvement` |
| Finding deepening opportunities, as an HTML report | `improve-codebase-architecture` _(explicit)_ |
| Changing code that has no tests | `legacy-code` (+ `REFERENCE.md`) |
| Fowler's smell catalogue and refactoring moves | `refactoring-patterns` _(explicit)_ |
| DRY, orthogonality, reversibility, contracts, tracer bullets | `pragmatic-programmer` _(explicit)_ |
| Tests, review, dependencies, deprecation, large-scale change | `engineering-at-scale` _(explicit)_ |

The `rust`, `gui-architecture` and `rewrite-clean` rows of the rewrite's map
do not apply: VerA is Zig only, has no GUI, and is the rewrite's oracle, not
a rewrite.

---

## 2. The four measures

v1.0.0 is not "the tests pass". It is four independent numbers, and none
reduces to another. Every change you make should say which one it moves.

| | Measure | Command |
|---|---|---|
| **A** | Fixtures behaving as stated | `zig build benchmark -- --strict` |
| **B** | IEEE 1364-2005 clauses with **two-way** evidence; out-of-scope chapters `not-supported` (`CLAUSE-AUDIT.md` §5.7) | `zig build test-1364 -- --coverage` (§§17-18 obligation detail: `CLAUSE-AUDIT.md` §7.1) |
| **C** | LRM clauses with **two-way** evidence | `zig build benchmark -- --coverage` |
| **D** | `ARCHITECTURE.md` §6 phases landed | hand-read against its §6/§8 (`git show 297e97d^:ARCHITECTURE.md`) |

Three consequences you will get wrong if you skip them:

- **A rejection fixture is not positive coverage.** Measure C is the large
  half and most of it is writing *positive* fixtures for rules that already
  work. A clause with only a `//! reject` fixture is one-way.
- **Compiler acceptance is not runtime evidence.** An obligation needs a
  positive behavioural test, an invalid-input test, and a recorded result.
  "It compiles" is the weakest of the three and closes nothing. Neither does a
  kernel unit test alone, a compiled `.c` file, or a SPICE deck paired with a
  JSON file: none of them runs the compiler's output in a host.
- **A refusal needs a legal neighbour.** Isolate the invalid construct, pin its
  named diagnostic, and show a legal variant compiles, so the fixture tells a
  real restriction from a blanket refusal. A rule with no invalid form needs no
  invented rejection; say why in the header.
- **XFAIL markers are implemented, never deleted.** The harness FAILs on XPASS
  specifically so a marker cannot outlive its limitation.

---

## 3. The release ritual

Every version increment is a published GitHub release. There is no other way to
release, and there is no releasing without a measurement.

```sh
# 1. Land your work. Gates green, name lists diffed.
zig build test                       # must pass. This is the gate.
zig build benchmark -- --strict      # must exit 0 (it has since ae9633f1): read the names

# 2. Write the entry. This RUNS the suites; it does not ask you for numbers.
tools/conformance.py --changelog v0.1.0

# 3. Fill in D by hand: the one row the script marks `hand-entered`.
#    Name the document and the date you read. Do not guess.

# 4. Commit, tag, push the tag. CI does the rest.
git add CHANGELOG.md && git commit -m "release: v0.1.0"
git tag v0.1.0 && git push origin v0.1.0
```

`publish.yaml` then re-runs `tools/conformance.py --check v0.1.0` on a clean
runner. **If the tree measures something different from what you committed, the
release fails.** That is the feature. Re-measure, amend, re-tag.

Semver, applied literally: a **minor** (`0.N.0`) changes something a consumer
observes: source VerA newly accepts or refuses, device text it emits, or a row
in `build.zig`'s `module_specs`. A **patch** (`0.N.M`) closes rows without
changing any of those. Every `ARCHITECTURE.md §6` refactor phase is therefore a
patch, because it is byte-identical by construction.

Every push and PR runs one workflow per concern, each with its own status:
`test.yaml` (`zig build` and `zig build test` on Linux, macOS and Windows),
`cross.yaml`, `nix.yaml`, `conformance.yaml` (the fixture suite, clause
coverage, `test-1364`, `test-devices`, `test-vpi-fixtures`, `test-spice`,
the emitted Verilog and the footprint/speed sweep, one job each),
and `external.yaml` (the external suites). `pages.yaml` publishes the website after `conformance`
finishes on main. The gates: `test`, `cross`, `nix`, and `conformance`'s
fixture suite with 0 FAIL and 0 unasserted. Every verdict is gated by **name**: the
ratchet (`tools/conformance.py ratchet`) compares each fixture's verdict with
`tests/fixtures/VERDICTS.tsv`, so a new failure fails, and so does a fixed one
until `ratchet --update` records it. Only the
sweep and the audit-tool self-tests report without gating.

**Nix.** `flake.nix` exports `packages.<system>.default` (`vera`, built from
this tree in ReleaseFast with `-Dcpu=baseline`, as `publish.yaml` builds the
release), one package per release binary (`."0.9.0"`, `latest`),
`overlays.default` (`pkgs.vera`, `pkgs.veraPackages.<version>`),
`apps.default`, `checks` (each package plus a resistor through `vera --check`
in the sandbox) and `formatter` (`nix fmt`), on x86_64/aarch64 Linux and
Darwin (x86_64-darwin imports nixpkgs 26.05). Every package is wrapped with
the Zig its generated code targets and installs its own
`share/vera/contract.zig`; `vera` reads nothing else at run time (the
contract and the `sim` tree are embedded, `sim_sources`). `sources.json` is
written only by `tools/update-sources.py` from the releases and their
`SHA256SUMS`; `publish.yaml`'s `sources` job reruns it and commits to main
after each release. Do not edit it by hand.

---

## 4. Working on the code

**Three loops.** Run every one inside `nix develop`: the system `zig` may be
0.16, and VerA is 0.17.

1. **Edit: `zig build check --watch -fincremental`**, left running in the
   background of your worktree. `check` compiles every root `test` compiles
   (each `module_specs` module, the CLI in both `-Dlanguage`s, `test_all`,
   `osdi_dyn`, the suite runner) with no binary asked for, so it is semantic
   analysis only (`-fno-emit-bin`, self-hosted frontend), and a compile error
   shows in every root that sees the edited code. It catches compile errors
   only; nothing runs. The win is the long-lived incremental process: without
   `--watch` each run re-analyses everything. Never `-fincremental` without
   `--watch`, nor with a tmpfs `.zig-cache`. The device hosts (`hostTests`,
   `vdev_*`) are not in it: their roots import what `vera` emits.
   When you add a root to `test`, add it to `check` too, and never call
   `getEmittedBin`, `addRunArtifact` or `installArtifact` on a `check` compile,
   or it becomes a full build.
2. **Test: `zig build test-<module>`** (`test-ir`, `test-backend`, `test-cli`,
   …) for the module you touched, and one fixture by hand (§6). Zig caches a
   test run whose inputs did not change.
3. **Gate: `zig build test`**, once per commit, gated on `$?` (§0 rule 2),
   then the name-list diff (§0 rule 3). `failed command:` in build output is
   not always a failure: after `run test` it can mean only that the step wrote
   to stderr. A real failure prints `error: '<test name>' failed`; the exit
   code decides.

**Where a file goes** is decided by what it must *import*, not by what it is
about. That rule was learned the expensive way: `ARCHITECTURE.md §8` records a
planned `support/contract.zig` that could not exist, because the assertion it
held needed three modules a bottom-of-stack file cannot import.

`build.zig`'s `module_specs` is the module graph and `defineModules` **panics on
a cycle**. Dependency order is enforced by the build, not by review.

**How a big file is split** (lower/, codegen/, parser/, pp/, proof/, diag/,
elaborate/, tb/, sim/digital/, digital/): a sub-file holds free functions that keep
`self: *T` and are called directly, `lower_expr.lowerExpr(self, e)`, the
pattern of Zig's own `src/Sema/*.zig`. The root file aliases ONLY what other
modules call; that alias list IS the module's API. Every file opens with a
`//!` header: its transformation (in → out) and the LRM clauses its code cites.

**Stage outputs are narrow values.** Lowering returns `Lowered`
(`lib/ir/lowered.zig`); everything downstream takes `*const Lowered` and
cannot reach lowering's symbol tables. Calls carry a `Mir.Callee` enum
(`lib/ir/callee.zig`); per-opcode facts are columns of `lib/ir/opcode.zig` and
`lib/backend/codegen/opcode_zig.zig`. Add a variant and the compiler names every
site that needs a decision. Never add a string compare or a silent default.

**Exhaustiveness is enforced, not reviewed.** `tests/exhaustive.zig` (part of
`zig build test`) parses lib/ and src/ and fails on any `else =>` over a
boundary enum (Ast/Mir/Callee/token/...) unless the line carries
`// else: <why this is right for every present and future variant>`.

**Refactor phases keep goldens byte-identical.**

```sh
zig build golden -- before     # on the pre-change tree
# ... your phase ...
zig build golden -- after
zig build golden -- diff       # prints IDENTICAL, or exits 1 naming each file that differs
```

A snapshot holds, per fixture, `vera --emit-zig`'s stdout and stderr
(`.txt`, `.stderr`), the testbench runner `--emit-exe` renders for a `//!`
`.va` (`.runner.txt`), the tree `--emit-so` writes for a `.va` before `zig`
runs (`.so/`: `shim.zig`, the split device), and a `.v` design's
`--emit-exe` root (`.program.txt`). It does not hold a split build's part and
chunk shims, the engine root (`lib/zigbuild/shim.zig`'s tests pin those) or anything
`zig` produces. `tests/harness/golden.zig`'s header has the rules.

One phase = one branch = one PR. Never two phases in flight in `lib/`. No
behaviour changes, no bug fixes, no "while I'm here" inside a phase. Those are
separate commits before or after. **A phase that cannot keep goldens
byte-identical stops and gets re-scoped.**

**Tests move with the code they test, in the same commit.** A split that leaves
tests behind is how coverage silently drops.

**Fix at the root.** `asInt` had ten callers; guarding the crash site would have
left nine able to abort.

**Parse in full, then refuse by clause.** When VerA cannot execute a construct
yet, parse all of it and refuse it with a named diagnostic that cites the
clause. Never open a gate without an executor: "compiled, and the block silently
did nothing" is a wrong answer with no diagnostic, which is worse than a
refusal.

---

**Two dev shells.** `nix develop` is the build shell (Zig 0.17.0, the GPU
toolchains, iverilog and verilator for `test-beh-verilog`).
`nix develop .#benchmarking` adds profiling (perf, flamegraph, inferno) and
the **reference tools** VerA's accuracy is checked against: iverilog,
verilator and yosys (IEEE 1364), ngspice (an OSDI host: VerA's `.osdi` and
OpenVAF's run in the same deck), Xyce, gnucap, and OpenVAF-Reloaded
(`openvaf-r`, wrapped from its release binary in `flake.nix`, x86_64-linux
only). The external suites under `tests/fixtures/external/` run in this
shell; each folder's manifest pins the suite's URL, commit and license.

## 5. SIMD: read this before you optimise anything

**The compiler is not a SIMD target and you are not to make it one.**
Every backend walk is a chain: a dominator-tree walk, a data-dependent output
length, recursive SSA construction. `lib/prove/proof/lattice.zig` carries a measurement
table where a `@Vector` attempt **loses** at every size up to 24578.
`ARCHITECTURE.md §7` lists adding SIMD to the compiler as
deliberately-not-doing.

The compiler's two `@Vector` uses are the right two and are not touched:
`frontend/token.zig` (accumulator over the fixed keyword table) and
`frontend/preprocessor.zig` (single-needle byte scan). A 2026-09-23 re-triage
measured those scans again: nothing else pays.

**SIMD-first applies to the emitted device.** The generated `eval` runs millions
of times inside a host Newton loop; that is the hot loop this project exists to
make fast. The device's SIMD is the scalar family's DERIVATIVE lanes: every
value is `S.Of(mask)`, carrying exactly the lanes of the unknowns it depends
on, and `tools/contract.zig`'s `RefFamily` runs them as
`@Vector(popcount(mask), L)`. The lane decisions (`pinLanes`, `lane_pinned`,
`batch_ok`, `jac_f32`, `cur_strict`) live in `lib/backend/codegen/float/`
(`mode.zig`, `lanes.zig`), whose header says what makes a lane dirty and what
`batch_ok` promises: a family whose value type `V` is a vector of operating
points evaluates a `batch_ok` device exactly per point, which the
testbench's batch family (`tb/runner_text.zig`, `@Vector(NL, f64)`) asserts.

Measured and not built (2026-09):
- Instance lanes (several operating points per SIMD register, `batch_ok`),
  re-measured 2026-10-01 with vector exp/log/pow
  (`git show 6e59b3d4^:docs/measurements/batched-instances-2026-10-01.md`): when every point of a
  batch takes the same branches, 1.2-2.1× per instance on AVX2 (diode 1.35×,
  mos1 1.42×, bsim4va 1.58×, psp103 2.11× at W = 4; W = 8 spills its tiles
  and gains less). With points spread over regions, divergence and per-point
  value collapses make mos1 and bsim4va 0.37-0.55× and psp103 about 1.0×.
  Since 2026-10-02 diode, mos1, bsim4va and psp103 are `batch_ok` through
  the lead protocol (`batch_lead`, exact per point, divergent batches
  included). The batch key is the `Model` row and the `SimState` only: each
  point has its own `Instance`, read per point through the family's
  `instLane` when the device declares `batch_inst` (held values, `$prev`
  latches; mos1, bsim4va, psp103). A host buckets on the region signatures
  the previous batched call returned (`git show 6e59b3d4^:docs/measurements/batched-lead-2026-10-02.md`:
  1.06-1.30 runs per W = 4 batch on ARPice's generated decks; coherent
  batches 1.5-1.8× in instructions with per-point instances, mos1 about
  1.0-1.1× in cycles). AVX-512 W = 8 is estimated (llvm-mca,
  calibrated) at about 1.2-1.8×, NEON W = 2 at about 0.8-1.1×. The ABI keeps
  `S.V` and `batch_ok` for it.
- Liveness-coloured hoist slots: bsim4 33% slower (they defeat SROA).
- A no-inline core on the GPU: eval 2× slower.
- `strict` → `optimized` float mode: 0%.

**The hardware knobs stay.** `--unknown-bound=`, `jac_f32` and the `abstol`
table are physical-world tuning. Do not simplify them away. (`--outline-chunk`
was removed 2026-09-23 at the user's request: its GPU motive was DWARF, and
chunking measured 2.8x slower at runtime. See the commit that removed it.)

---

## 6. Fixtures

Run one by hand. `--check` needs **both** flags, and the fixture's own
directory must be on the include path:

```sh
./zig-out/bin/vera --check --contract tools/contract.zig \
    -I tests/fixtures -I <the fixture's dir> <file.va>

# the self-checking testbench, which prints the ok=0/ok=1 lines:
P=$(./zig-out/bin/vera --emit-exe --contract tools/contract.zig \
      -I tests/fixtures -I <fixture dir> <file.va> 2>/dev/null)
"$P"
```

`--emit-exe` prints the path on **stdout** and diagnostics on **stderr**.
Capture them separately or you get an empty path.

**The contract's conformance checks are opt-in.** `contract.validate`,
`validateHost`'s obligations, `checkFamily` and the Debug `su_ok` assert run
only where the root module declares `pub const vera_validate_contract = true`
(`contract.validating`). `zig build test` (`tools/zrunner.zig`), the fixture
suite and `vera --check` always turn them on; a hand-built testbench needs
`--validate-contract`. The ABI check always runs. **A host gets no obligation
checks unless it opts in:** declare the decl in the program's root module, or,
for an `--emit-so` build, in the `dyn` module (the generated shim forwards it).

The header quotes the LRM sentence, derives the expected value **by hand**, then
carries the machine-readable tags:

```
//! lrm 9.4.1
//! bias V(p) = 0.75, V(n) = 0.25
//! reject E0310     <- a SUBSTRING. A bare `//! reject` matches ANY diagnostic.
//!                     Always name the code or a distinctive phrase.
//! reject-run E0816 <- a RUN-TIME refusal: the fixture compiles and runs, and
//!                     the run must exit nonzero (1 unless `//! exit` says) with
//!                     an `error[` line holding each substring, and no other
//!                     `error[` line (always `reject-only`'s rule). Takes a
//!                     `//! neighbour`, `//! checks` and the checks before it.
//! warn W0853       <- the fixture still compiles and runs; each substring must
//!                     match a WARNING. Unnamed warnings pass (W0650 is off
//!                     unless named). `//! nowarn`: this source warns nothing.
//! xfail <reason>   <- "the fixture is right and VerA is not". FAILs on XPASS.
//! checks 6         <- exactly this many ok= verdicts. Derive N from the
//!                     assertions and points, never from a buggy transcript.
//!                     Not allowed with `//! reject`.
```

A verdict is the whole token `ok=1`; `ok=10` fails. Without `//! checks` the
runner only needs a nonempty, all-passing transcript.

Device-table directives assert what a device PUBLISHES to a host, as
`got=/want= ok=` lines: `//! noise` (`corr=<j>:<rho>` states §4.6.4.6's
correlation coefficient with row j, from the rows' shared `source` and the
signs of their `coeff`; a table row's `points=` and `psd=<f>:<S>,...` are read
through `contract.noiseTable` on the derived card), `//! acstim`, `//! qsite` (one line
per §5.6.1.2 charge site, `<row><sign>... lte|nolte`, rows in `U` order),
`//! meta <kind> <name> [desc="..."] [units="..."]` (one per §2.9.2
`decl_meta` row, `contract.DeclMeta`; `//! meta none`), and
`//! abstol <unknown> = v` (the §3.6.1.2 `u_abstol` entry).

**Vendor attributes.** VerA reads five §2.9 attributes. `vera_lte` is a
prefix on an analog statement (`(* vera_lte = 0 *) I(b, s) <+ ddt(qbs);`)
or a suffix on a `ddt` name (`ddt (* vera_lte = 0 *) (q)`, a slot A.8.2 gives
only analog functions and VerA extends). It leaves those charge sites out of
the host's truncation-error check (`q_lte`, `contract.QStamp`). Innermost
wins; the value must fold without the model card (E0523). `vera_interp`, in
the same slots on `absdelay`, picks 1 = linear (default) or 2 = quadratic (E0524).
`(* vera_nodiff *)`, a statement prefix, stores every assignment inside with
no derivative (a SPICE frozen coefficient); `= 0` turns it off inside, the
value folds without the card (E0525), and a contribution inside is E0526.
`(* vera_timepoint *)`, a statement prefix, runs the statement once per
timepoint: the first evaluation at a (`$abstime`, analysis, step flags) runs
it, `eval` stores what it assigned in `Instance` (`tp<b>_*`; the device is
`mutable_eval`), and later iterations read that back. `initState`, `setupInstance`,
`updateState` and `stateCtl(.commit/.revert)` drop the cache, so a rejected
step recomputes it. `= 0` turns it off; the value folds without the card
(E0529). Inside, a probe, `$limit`, contribution, stateful operator, noise
function, event, system task or string assignment is E0530; a value read
from before it that an iteration can move (a probe in a variable, a branch
on one) is E0531; inside a loop, analog function or `analog initial` it is
E0532. Held (§5.10) reads see the accepted state.
`(* vera_scratch *)`, a prefix on a variable declaration (module or named
block; scalars and arrays, real or integer), makes the variable never held:
every evaluation starts it at its initializer, the §3.2 zero when there is
none, so an unwritten slot of a runtime-indexed array reads 0 instead of
what an earlier evaluation left. It is for stacks and scratch buffers the
retention analysis cannot prove written before read; a device whose only
state was such a variable drops to `state_class = .none`. `= 0` turns it
off; the value folds without the card (E0534). On anything but a variable
(parameter, net, genvar, statement) it is E0535; on a variable an `analog
initial` or `@(...)` body assigns and a later read may see, E0536; on one
an `initial`/`always` block or a task assigns (§7.2.2 digital-owned), E0537.
`(* vera_scratch = "uninit" *)` also drops that start: a runtime-indexed
(memory-backed) array gets no initialising store at all, which is what a
64-deep stack of 8-lane duals spends a large part of its eval on (measured
on a 4-op tape, ReleaseFast: 233 → 201 Ir/eval). The author promises every
element is written before it is read in the same evaluation; **a
read-before-write is the author's bug**. Debug/ReleaseSafe devices fill the
array with NaN, value and every derivative lane (minInt for an integer
array), so the bug shows as NaN in the outputs; ReleaseFast/ReleaseSmall
store nothing and the value read is unspecified but stable: an empty
`asm volatile` taking the array's address with a `memory` clobber (no
instructions, CPU and GPU) makes LLVM treat the contents as defined, so the
read is never undef/poison it could exploit. The barrier costs the array's
SROA (116 Ir/eval without it). A scalar or a scalarized array keeps the zero
start (free in SSA). Any other string is E0538; an initializer with `"uninit"` is E0539.

**`$vera_reject_step(t_retry)`.** A VerA system task in an analog block:
on a transient step's accepted solution, `updateState` returns
`.request_reject_at = t_retry` when `t_retry < $abstime` (the earliest of
several calls wins; a static solve ignores it). Such a device emits no
`acceptQ`. The analog testbench undoes the step, solves and accepts
`t_retry`, then solves the rejected time again (`runner_text.retry`); the
mixed and VPI runners refuse a request. In `analog initial` or an analog
function it is E0533.
`--emit-verilog` alone reads two more on declarations: `vera_pin`
(`"digital"`, `"analog"`, `"power"`, `"ground"`) and `vera_delay` (seconds);
`lib/backend/beh_verilog.zig`'s header has the rules.
Every other attribute is parsed and ignored, and every attribute value is a
§2.9 constant_expression (E0357).

**`$limit` arguments.** §9.17.3 names the arguments a string "requires" and
leaves the rest to the implementation. VerA reads, after the algorithm's own,
an optional frame **sign** (`type`; the clamp runs on `sign·v`) and then an
optional **seed**: the value the site's branch starts at in `seed` (SPICE
MODEINITJCT), in the frame of the sign. A seed needs a sign before it (write
`1` for none); more arguments decline the site (W0853).

| algorithm | full call (1-based position of the seed) |
|---|---|
| `pnjlim`, `pnjlimds` | `$limit(V(a,k), "pnjlim", vte, vcrit, sign, seed)` (6) |
| `fetlim`, `fetlimds` | `$limit(V(g,s), "fetlim", vto, sign, seed)` (5) |
| `steplim` | `$limit(V(a,b), "steplim", step, sign, seed)` (5) |
| `limvds` | `$limit(V(d,s), "limvds", sign, seed)` (4) |

Seeded branches are solved into node values from a 0 V root (ground, else the
lowest port, else the lowest net); a pnjlim/pnjlimds leg with no seed starts at
its vcrit, and a fetlimds vgd or pnjlimds vbd leg is never seeded. A seed may
read card-derived variables, never the solution (E0527); one the tree cannot
take is W0854.

`check.vh` gives you `CHECK` (absolute tol), `CHECKR` (relative), `CHECKX`
(exact), `CHECKI` (integer), `CHECKEQ` (two VerA expressions against each
other). **When the LRM states an identity with no digits, assert the identity
with `CHECKEQ`** and say in the header why no digits are written.

**`.c` VPI fixtures** cite with the same grammar, as C99 `//!` lines after the
header comment, with polarity **per line** (one application can assert both a
result and a refusal):

```
//! lrm 12.16          <- a result this clause requires is CHECKed
//! lrm-reject 12.34   <- the routine refusing invalid input is CHECKed
//!                       (error return, vpi_chk_error).
//! inherited IEEE 1364-2005 27.14         <- the same two polarities, for
//! inherited-reject IEEE 1364-2005 27.14  <- measure B.
//! design ch12_vpi_routines/p03_rc_ac.va  <- RUN it under `zig build test`
//!                       against this design (path under tests/fixtures),
//! stdout p03-09: f_dc=0 ...  <- one line of its exact stdout, in order
//! stderr [<line>]       <- its exact stderr (bare: must be empty)
//! refuse <stderr text>  <- the host must refuse the design: exit 1 saying so
//! xfail <stderr text>   <- a known gap: it must exit 1 saying so
```

`build.zig` globs every `.c` with a `//! design` line into its runs
(`vpiRuns`); no other key exists. `--coverage` (both `benchmark` and
`test-1364`) counts the cites only for fixtures that run. A compile-only `.c` is listed as `~`
and moves no number. Tag a clause only where an assertion stands behind it.

### The trap that produces confidently wrong work

**A fixture that a *conforming* implementation fails.** The cheapest way to make
one pass is to break the compiler. Four have been found and fixed here; assume
more exist. Worked examples in `TODO.md §2.4`:

- `$vt` pinned to VerA's own CODATA2018 constant while §9.15 supplies no number.
- `absdelta(V, 0.5)` against a wave stepping exactly 0.5, where §5.10.3.4 fires
  on "**more than** delta". The fixture tested for a bug.
- Seven fixtures assuming a digital-context `integer` starts at 0. §3.2 says
  **x**; only analog-context assignment defaults to zero.
- "The second NBA cancels the first." IEEE 1364 §9.2.2 performs **both**.

So: **before you change the compiler to make a fixture pass, establish that the
fixture is right.** If you withdraw a claim from a fixture, name the row it
moved to.

---

## 7. Things that look done and are not

Checked against the code on 2026-09-27.

- **The mixed-signal path runs, with known limits.** ch07 steps 5-9 landed
  (x/z inputs, A2D crossings with inserted points, named events across the
  boundary, `absdelta`), a flattened child's discrete processes reach the
  runner, §7.8 connect modules run both halves, and §9.22 driver access lives in
  `src/sim/digital/driver.zig`. Not done: an A2D write does not re-solve the
  finished analog point; the next point sees it (`src/sim/mixed.zig`,
  `settleA2d`). A driver's state is one bit, so a vector `signal_name` is
  refused rather than read. `driver_update` does not fire for a connect
  module's own driver: `cm_driver_updates = false` is the user's 2026-09-24
  reading of §9.22.6, and `m04_12` asserts it.
- **The testbench solver is text, not a library.**
  `lib/backend/tb/runner_text.zig` is Zig source emitted into each generated
  testbench, so `src/sim/` cannot call it; the mixed runner drives it through a
  comptime interface. It steps fixed-step backward Euler with no
  truncation-error control and no step rejection, so a fixture can check an
  LTE rule only through what the device publishes.
- **The pure analog testbench is a fixed grid** over the declared `//! time`
  points. It prints the device's next breakpoint but inserts no point. Only the
  mixed runner inserts solver-chosen points (crossings, and timers through the
  optional `pendingBreakpoint` hook). A fixture whose reasoning needs an
  inserted point runs on the mixed path or puts the event on a declared point.
  The exception is `zig build test-spice`: a deck's `//! tran` runs
  `src/sim/spice/` (ESPice's Newton, transient and noise, copied CPU-only):
  ngspice's LTE and breakpoint step control, `$bound_step`, a
  `cross`/`above` flip (`stateCtl(.query)`) cut to 5e-5·tmax, and
  `$vera_reject_step` retries. `//! onoise` is its small-signal noise.
  Both are for generated decks.
- **VPI.** Every `.c` fixture compiles against `src/vpi/vpi_user.h`
  (`zig build test-vpi-fixtures`), and every one runs in-process under
  `zig build test` (its `//! design` line, and `vpi_app.c` under
  `test-vpi`), analog routines, analog task output arguments and `ac` sweeps
  included. Its `//! xfail` lines are the known gaps.
- **Setup split** (`lib/prove/setup.zig`, read by `codegen/setup.zig`) computes solve-invariant values
  once. Array operations are classified per evaluation, so an array filled
  once in `analog initial` is still recomputed every eval. A per-timepoint
  "step" tier was measured and not built: compact models gain 0-16 values each.
- **Known gaps are markers, in both trees.** `grep -rl '^//! xfail'
  tests/fixtures` lists them; `.v` fixtures under `tests/fixtures/ieee1364` carry
  them too. Decisions still to implement are the `CHANGE NEEDED` entries of `specification/Vague_Decisions.md` not marked `DONE`.

---

## 8. If you are running as one of several parallel agents

Learned expensively, and none of it is style preference:

- **Own worktree per agent.** Two in-tree agents plus a main session shared one
  checkout; one ran `git reset --hard` and destroyed uncommitted work.
- **No `Co-Authored-By:` trailers**, and no other AI attribution, in any commit
  message. Every commit is authored and committed by the repository's git user
  (`git config user.name` / `user.email`); never set `--author` to an agent.
- **Stage by explicit path. Never `git add -A` in a shared tree.** `git commit`
  commits the *index*: a docs commit once swept in three unrelated test-file
  deletions and nothing noticed for a session.
- **`cd` to the repo root before anything that writes.** A drifting shell cwd
  landed inside an agent worktree and made four merges appear to vanish.
- **Budget ~12 GB of `.zig-cache` per concurrent agent**, and delete a
  finished agent's cache before the next wave. Six parallel agents filled the
  filesystem and killed a run mid-flight.
- **Size goldens compose.** When two agents each move generated-device byte
  counts in `tests/harness/sweep.zig`, the conflict is **regenerated**, not resolved to
  one side. Both deltas are real.

**The shared build.** How several agents build one repository without racing
or starving each other, in the order it pays:

1. **One worktree per agent, one build per worktree:**
   `git worktree add -b <branch> ../VerA-<topic> <base>`. Two builds in one
   tree race on `.zig-cache` and `zig-out`, and a shared tree lets another
   agent's half-finished edit break your build.
2. **Each agent's edit loop is `zig build check --watch -fincremental`** (§4)
   in its own worktree, started once and left running. It is cheap enough to
   run in every worktree at once; a full build is not.
3. **Seed a new worktree.** The global cache (`~/.cache/zig`) is shared by
   every worktree, so dependencies compile once per machine; the worktree's own
   `.zig-cache` starts cold and can grow to gigabytes (the 12 GB budget above).
   Delete it when the branch merges, and remove the worktree.
4. **Cap concurrent full builds machine-wide.** A full `zig build test` or
   `zig build benchmark` takes every core and several GB of RAM: run at most
   two or three at once, and check `free -g` first. An agent waiting for a slot
   stays in its `check` loop.
5. **One integration branch.** Feature branches never merge each other. The
   integrator rebases a finished branch onto the integration branch,
   fast-forwards it, and runs the gate (§4 loop 3, then the name-list diff of
   §0 rule 3) once on the result, in the integration worktree only.

---

## 9. Before you say you are done

- [ ] Your change has a bullet in `CHANGELOG.md` under `## Unreleased`
      (see below).

- [ ] The design review §10.1 asks for this change ran, and its report is
      committed with it (R10 alone for a small diff).
- [ ] `zig build check` passes, and a root you added to `test` is in it (§4).
- [ ] `zig build test` exits 0. Checked `$?`, not a log tail.
- [ ] `zig build test` includes `zig fmt --check` (`zig build fmt-check` alone).
- [ ] FAIL/XFAIL **name lists** diffed (captured as §0 rule 3 shows, not from
      a build-runner log); nothing new entered either.
- [ ] `zig build test-devices` still passes every digital case, and
      `zig build test-vpi-fixtures` still compiles every `.c` fixture.
- [ ] `zig build` AND the suite runner compile, not only `zig build test`:
      `test` does not analyse every path of the CLI or the harness.
- [ ] Changed what `vera` prints, or the contract? `tools/doctest.py` passes:
      the user book (`docs/`) shows real transcripts and CI fails on drift.
      `--update` rewrites them; then re-read the prose around each one.
- [ ] No new `else =>` over a boundary enum without a `// else:` reason.
- [ ] Refactor phase? Goldens are byte-identical.
- [ ] Changed a fixture's expectation? The derivation is in its header and you
      established the fixture was wrong before changing the compiler.
- [ ] Said which of the four measures this moves, and by how much.
- [ ] Every number you wrote came from a command, or names the document and
      date it was read from.

### `CHANGELOG.md`

Releases run v0.9.0 to v1.0.0, the conformance journey: v1.0.0 is the
release that meets the four measures of §2. Every change adds one bullet under
`## Unreleased`, in the same commit as the change. Keep it light: one line
saying what a user of VerA would notice. A fix always names the GitHub issue
it closes, as `(#123)`; open the issue first if there isn't one. At a
release, `tools/conformance.py --changelog vX.Y.Z` turns `## Unreleased`
into `## vX.Y.Z — date`, puts the measured table under it above the bullets,
and opens a new empty `## Unreleased`. Only the script writes the table.

---

## 10. The design review

Adopted 2026-10-17 from `../VerAReWrite/AGENTS.md` §0.2 and §1. Chapter,
Principle, Part, Technique and Appendix numbers below are `PRINCIPLES.md`'s.

### 10.0 Precedence when sources disagree

1. **§0–§9 of this file**: VerA's measured, project-specific rules.
2. **§11** (VerA's rulings over the skills).
3. **`systems` conflict rules**, in its order: data layout beats code brevity;
   `ponytail` decides how little code to write, never what shape the data
   takes; the zero-cost proof comes before the abstraction.
4. **`codebase-rules` rulings**: Clean Code loses to the data in hot code
   only; pure by default, impure when the pieces are tested; testability is a
   seam question; measure before accepting any performance rung.
5. **The domain skill for the block** (`compiler-construction`,
   `spice-engine`, `gpu-kernel-optimization`, `writing-perfect-verilog`).
6. **The general skills.**
7. **`PRINCIPLES.md`.**

If a principle and a skill disagree and §11 does not settle it: the skill wins
on **mechanics** (how to do it in Zig 0.17), the principle wins on the
**requirement** (zero runtime overhead, containment, tests). Record the
conflict as a new §11 entry in the same change.

**Where its artifacts live.** Design-review reports in
`docs/dev/reviews/<yyyy-mm-dd>-<topic>.md`; seam records and drill tables in
`docs/dev/decisions.md`; ADRs in `docs/adr/`; `GLOSSARY.md` and `TESTING.md`
at the repo root. None exists yet: the first change that needs one creates
it. `docs/dev/` is outside the user book (`docs/SUMMARY.md` does not list it,
and `book.toml` sets `create-missing = false`). VerA's `ARCHITECTURE.md` is
in history (§1); the current map of where each file sits is the archmap block
(`zig build archmap`) and `build.zig`'s `module_specs`, so R9's "is
`ARCHITECTURE.md` current" reads "are §4, the archmap and `module_specs`
current".

The design review is a fixed sequence of stages, each with a skill, a question and a "Done when." A design passes when every stage's verdict is **pass** or an **exception the user accepted in writing**. It fails if any stage's verdict is missing.

### 10.1 When to run it

| Change                                                                        | Review                                                                   |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| New program, subsystem, module or crate                                       | Full (R0–R10)                                                            |
| New feature touching two or more tables, or adding a table                    | Full, scoped to the tables it touches                                    |
| New or moved seam; any rung change                                            | R4, R5, R8, R9                                                           |
| Change to a boundary: public API, FFI/C ABI, file format, wire format         | R1, R6, R7, R9                                                           |
| Change to a hot path (profiled, benchmarked, or in a loop over many elements) | R2, R4, R7, R8                                                           |
| Bug fix                                                                       | R6 and R7 (the missing oracle, Principle 19.4)                           |
| Any other diff                                                                | R10 only                                                                 |
| Existing code brought up to standard                                          | `codebase-improvement`, which runs the relevant stages per block         |
| Code with no tests                                                            | `legacy-code` first (characterization tests), then the stages above      |

### 10.2 The stages

Each stage lists: **Skill**, **Principles** (sections of this file), **Ask**, **Done when**.

**R0 — Scope and route.**

- Skill: `systems`, `codebase-rules`.
- Ask: Which domain skill owns this block? Is this new code, existing code, untested code or a rewrite? Is it hot or cold? ("Hot" needs evidence: a profile, a benchmark, or a call site in a loop over many elements; otherwise it is cold until proven, per `codebase-improvement`.)
- Done when: the review report names the change, its domain skill(s), its hot/cold verdict with evidence, and which stages apply (§10.1).

**R1 — Boundary.**

- Skill: `api-design`.
- Principles: Chapter 14, Chapter 18.
- Ask: Where does the boundary go, and is the usage code written first? Does each high tier of the interface have a path down to a low one (no integration discontinuity)? Is flow control the caller's?
- Done when: the usage code a real caller would write exists in the report, and the five characteristics (granularity, redundancy, coupling, retention, flow control) are assessed. Getting this wrong is the one mistake a later stage cannot fix (`codebase-rules`).

**R2 — Data.**

- Skill: `data-oriented-design` (Six Questions).
- Principles: Part I, Part II.
- Ask: All six, out loud: what goes in and out; how many; how wide (from the spec); access pattern; lifetime; parallelizable.
- Done when: every table has a producer, a consumer, a layout (SoA or justified AoS), each field's width with its stated range, a capacity constant with a unit, and a lifetime (arena named for its phase), and every transform is written as `name: reads → writes`. A width that cannot be stated is a spec gap to ask about, not a reason to widen.

**R3 — Owners and spines.**

- Skill: `codebase-clean-code` steps 2–3, `codebase-clean-code/HIERARCHY.md`.
- Principles: Chapter 13, Chapter 14.
- Ask: Who is the one owner of each table? Do the modules form a DAG? Does each pipeline have one spine, one line per transform? Does any outside write bypass a request table?
- Done when: the ownership map lists one owner per table, the module graph has no cycle and the build enforces it, every outside write goes through a named request table, and the spine runs end to end as stubs with every "which work" branch in the spine.

**R4 — Seams and the ladder, under the project budget.**

- Skill: `codebase-clean-code` steps 4–5, `codebase-clean-code/LADDER.md`.
- Principles: Part III, §11.1.
- Ask: For each place behaviour could vary: what varies (kind, backend, platform, dialect, policy, plugin), and what is the evidence (two cases today, or a drill)? Which is the cheapest rung that handles the axis? Is it allowed in this path under §11.1?
- Done when: every seam names its axis, evidence, rung, and why the rung below fails; every place without evidence is concrete code; no seam violates the hot-path budget in §11.1.

**R5 — Change drills.**

- Skill: `codebase-clean-code` step 6, `codebase-clean-code/DECISIONS.md` (drill table).
- Principles: Chapter 15.
- Ask: What are three likely changes? Get them from the user, or from the backlog, issues or decision log with the source cited; never invent them. For each: every edit (file and function), the change radius, the interface-weight change.
- Done when: every drill has a complete edit list and a numeric radius, and every failed drill is fixed (restructure first, climb one rung second) or recorded as an exception the user accepted.

**R6 — Failure containment.**

- Skill: `assertions`; `zig/memory.md`; `doc-comments` (ranks 1 and 4).
- Principles: Part V.
- Ask: Is every check classified as operating error or programmer error? Is outside data validated once at the boundary into refined types? Does each module return a narrow, explicit error set? Is every state change fallible-first, infallible-after (or `errdefer`-rolled-back)? Is there global mutable state? Is every loop and queue bounded? Which runtime checks ship in release, and why?
- Done when: no assert tests a value straight from outside; every boundary function owns its error return and every function behind it owns an assert; error sets are explicit at every module boundary; no global mutable state exists; every table has a capacity and every loop a bound; the check budget (Principle 17.10) is recorded for each module.

**R7 — Test plan.**

- Skill: `test-plan` (steps 1–7), `tdd` (seams), the domain skill's testing file (`spice-engine/TESTING.md`, `compiler-construction/FIXTURES.md`, `gpu-parallel-algorithm-thinking/verification.md`), `test-plan/DOMAINS.md`.
- Principles: Part VI.
- Ask: What are the bug classes, and what oracle sees each one? Which seams are tested, agreed with the user? Which layer and tier covers each bug class? What are the exit criteria?
- Done when: every bug class has an oracle that does not recompute the answer the way the code does; the tested seams are written down and confirmed with the user before the first test; every layer has a tier and the merge tier fits its budget; exit criteria are numbers or yes/no checks; `TESTING.md` is updated.

**R8 — Proof of zero overhead and of speed.**

- Skill: `zig/zero-cost.md` (probe protocol); `data-oriented-design/measurement.md`; `simd-loops`, `branchless`, `simd-first` for hot loops.
- Principles: Chapter 1, Chapter 12, Technique 21.15.
- Ask: For every seam at rung 5 or above and every new abstraction on a hot path, what is the probe verdict? For every speed claim, what is the number?
- Done when: every such pair reports FOLDED, IDENTICAL, EQUIVALENT or NEGATIVE and is wired into `zig build test`; rungs 6–9 state where their residue sits and its count per run; every speed claim carries a before/after benchmark; data size, code size and compile time are reported for abstractions that move them. A vectorized loop that benchmarks slower is reported and the scalar version kept.

**R9 — Record.**

- Skill: `codebase-clean-code` step 7 and `DECISIONS.md`; `domain-modeling` (`GLOSSARY.md`, ADRs).
- Principles: Principle 15.6.
- Ask: Does every seam have a seam record? Is the drill table written? Is `ARCHITECTURE.md` current (module DAG, spines, tables, seams, invariants, adding a feature, change drill)? Did any term get sharpened or any hard-to-reverse decision get made?
- Done when: someone who has not read the code can say from `ARCHITECTURE.md` which file a given feature goes in; every seam has a record (with its probe verdict at rung ≥5); new terms are in `GLOSSARY.md`; decisions are in `docs/adr/`.

**R10 — Code review of the result.**

- Skill: `code-review` (Standards and Spec axes; this file is a Standards source), then `ponytail-review`; `doc-comments` audit; for a whole repo, `ponytail-audit`.
- Principles: Chapter 24 (red flags).
- Ask: Does the diff follow this file and the skills (Standards)? Does it do what the spec asked, no more (Spec)? What should not have been built?
- Done when: both axes are reported separately and not reranked; every hard Standards violation is fixed; the doc audit passes; every `ponytail-review` deletion is applied or answered.

### 10.3 The review report

Write it to `docs/dev/reviews/<yyyy-mm-dd>-<topic>.md`:

```markdown
# Design review: <topic>

- **Change**: <one sentence>
- **Domain skill(s)**: <…>
- **Hot/cold**: <verdict> — evidence: <profile / benchmark / loop call site / none → cold>
- **Stages run**: <R0…R10 per §10.1>

## Data (R2)

| Table | Owner | Fields: width (range) | Layout | Capacity | Lifetime/arena | Producer → consumer |
| ----- | ----- | --------------------- | ------ | -------- | -------------- | ------------------- |

Transforms: `name: reads → writes`, one per line.

## Seams (R4) and drills (R5)

<seam records per codebase-clean-code/DECISIONS.md; drill table>

## Containment (R6)

| Module | Error set | Boundary validation | Check budget (Principle 17.10) | Bounds |
| ------ | --------- | ------------------- | ------------------------------ | ------ |

## Test plan (R7)

| Bug class | Oracle | Layer | Tier | Harness / file |
| --------- | ------ | ----- | ---- | -------------- |

Seams under test (confirmed with the user on <date>): <…>
Exit criteria: <numbers or yes/no>

## Proof (R8)

| Abstraction / seam | Rung | Probe verdict | Probe file | Data size | Code size | Benchmark (before → after) |
| ------------------ | ---- | ------------- | ---------- | --------- | --------- | -------------------------- |

## Checklist

| #   | Check | Source | Verdict | Evidence (file:line, probe, number) |
| --- | ----- | ------ | ------- | ----------------------------------- |

## Accepted exceptions

<each with who accepted it and the "revisit when" event>
```

The **Checklist** table carries every item from Chapter 24's design-review list and from `codebase-clean-code`'s "Reviewing an existing codebase" list that applies. Each row needs a verdict (pass / fail / n.a. with reason) and evidence. "Looks fine" is not evidence.

### 10.4 Exit criterion

The design is approved when every applicable stage is done by its "Done when," every new seam names its rung, cites a change drill it passes, and has its zero-cost proof at rung 5 or above, the test plan's merge-tier layers exist and fail against stubs (red before green), and the report is committed with the change.


---

## 11. VerA's rulings over the skills

Each ruling names the skill text it overrides or sharpens. §11.1–§11.6 are the
rewrite's §2.1–§2.6 as written, plus §11.5's open conflict and §11.6's last
bullet; §11.7–§11.10 are VerA's.

### 11.1 The runtime-overhead budget

The project rule is **no runtime overhead from abstraction**: an abstraction may cost compile time, build time or test time, never run-time work beyond the hand-written code (Principle 1.2). Applied to `codebase-clean-code/LADDER.md`:

| Rung | Mechanism                                         | In a hot path                                                                                                                                                                                                                          | In cold code                                                                                                                                                           | Condition                                                                                         |
| ---- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| 1    | Concrete code                                     | Allowed                                                                                                                                                                                                                                | Allowed                                                                                                                                                                | The default                                                                                       |
| 2    | Free function over plain data                     | Allowed                                                                                                                                                                                                                                | Allowed                                                                                                                                                                | Extract per `HIERARCHY.md`                                                                        |
| 3    | Table + transform (value table or table per kind) | Allowed                                                                                                                                                                                                                                | Allowed                                                                                                                                                                | Value table: compiler must refuse a missing row (`std.enums.EnumArray`) |
| 4    | Closed enum + exhaustive switch                   | Allowed only when it is the hand-written minimum for data that genuinely varies per element (the probe compares it with the hand tag-and-switch, not with a single concrete path); a switch repeated across transforms moves to rung 3 | Allowed                                                                                                                                                                | No `else =>` / `_ =>` (Principle 10.2; `tests/exhaustive.zig` enforces it)                                                            |
| 5    | Comptime or generic parameter                     | Allowed with a probe verdict of FOLDED, IDENTICAL, EQUIVALENT or NEGATIVE                                                                                                                                                              | Allowed                                                                                                                                                                | Code size reported per instantiation                                                              |
| 6    | Request table or command queue                    | Never per element; per request, with capacity reserved at the phase boundary so no growth call runs in the emitter loop                                                                                                                | Allowed                                                                                                                                                                | Residue location and count in the seam record                                                     |
| 7    | Function-pointer table indexed by kind            | Never per element; once per kind per pass, over a bucketed batch                                                                                                                                                                       | Allowed                                                                                                                                                                | Same                                                                                              |
| 8    | `dyn` / vtable                                    | **Forbidden**                                                                                                                                                                                                                          | Only at a cold boundary (a logger sink, a backend picked at startup, a test fake) and only when rung 5 cannot do the job because the choice is not known at build time | Seam record states why rung 5 fails                                                               |
| 9    | Process, wasm or ABI plugin boundary              | **Forbidden**                                                                                                                                                                                                                          | Only for untrusted, separately built or other-language code                                                                                                            | Snapshots in, request tables out, under capabilities                                              |

"Hot path" is a measured claim (R0). Code without that evidence is cold, and the cold column applies; the probe is still required for rung 5 if the code later becomes hot.

### 11.2 Clean Code and function size

`codebase-rules` already rules that Clean Code loses to the data in hot code only. This project adds: function extraction follows `codebase-clean-code/HIERARCHY.md` everywhere (extract when used in three or more places, when it defines an interface worth documenting, when the test plan names it, or when it has a table of input → expected-output cases). A spine or run-once sequence stays one function with labelled blocks. Function size follows cohesion, not line count (Principle 13.3).

### 11.3 The `code-review` smell baseline

`code-review` says a documented repo standard overrides its Fowler baseline. This project overrides these baseline fixes:

| Baseline smell      | Baseline fix                                 | This project's fix                                                                                                                                                                       |
| ------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Repeated Switches   | Replace with polymorphism, or one shared map | Bucket by kind and move to a table per kind (rung 3), or a value table (rung 3); climb to rung 7 only per §11.1. Never `dyn`                                                              |
| Feature Envy        | Move the method onto the data it envies      | Move the transform to the **owner** of the table it writes; reads stay `const` parameters                                                                                                |
| Data Clumps         | Bundle into one type                         | Bundle only if the fields are read together by the same transforms; otherwise keep parallel columns (SoA)                                                                                |
| Duplicated Code     | Extract the shared shape                     | Extract only if it is the same **knowledge** (Principle 13.5) and meets §11.2; similar-looking code that changes for different reasons stays separate (`pragmatic-programmer`, false DRY) |
| Primitive Obsession | Give the concept its own small type          | Same, as a zero-cost newtype or `enum(u32)` handle, with its width from R2                                                                                                               |
| Refused Bequest     | Drop inheritance, use composition            | Not applicable: no implementation inheritance exists in this codebase                                                                                                                    |

All other baseline smells apply as written, as judgement calls.

### 11.4 Abstraction timing

Two rules from the skills apply together and are not in conflict: a **seam** is introduced at the second real case today or when a drill needs it (`codebase-clean-code` step 4, Muratori's "compress at the second instance"); a **function** is extracted at the third use (`HIERARCHY.md`). "Rule of Three" in older text in this file means the second.

### 11.5 Runtime checks in release builds

The check budget in Principle 17.10 is the project policy. Comptime assertions are always on; boundary and control code ships with safety on (`-O ReleaseSafe`, `std.lang.Optimize.safe`); hot kernels may drop checks only with fuzz, property and differential evidence recorded in the review. `assertions` governs what each assert compiles to per build mode (`assertions/zig.md`).

**Open conflict (VerA).** The released `vera` is built `-Doptimize=ReleaseFast`
(`.github/workflows/publish.yaml`, `flake.nix`), where this ruling would make
the compiler, a boundary tool, ReleaseSafe. The release mode does not change
until a design review records ReleaseSafe's cost on `zig build benchmark` and
the user decides. Emitted devices are not covered: the host builds them, in
the mode it picks.

### 11.6 Testing rules that every change obeys

- No change merges without tests at agreed seams (`tdd`). Untested code is not done.
- Every test layer names its oracle (`test-plan`); a test whose expected value is computed the way the code computes it is tautological and does not count (`tdd`).
- Every bug fix adds the regression test **and** the oracle or generator that would have found it (Principle 19.4).
- Refactoring is done after green, in the review stage, never inside the red → green loop (`tdd`).
- `std.testing.checkAllAllocationFailures` can fail with
  `error.NondeterministicMemoryUsage` when an allocator sometimes grows a
  page-sized buffer in place: run the sweep on an allocator whose `resize`
  and `remap` always refuse (`Allocator.noResize`, `Allocator.noRemap`), so
  every growth is a counted allocation.

### 11.7 Conformance is the oracle, and it is measured

The rewrite's §2.7 holds VerA's own rules, already binding here: never type a
conformance number (§0 rule 1); gate on `$?` (§0 rule 2); diff name lists, not
counts (§0 rule 3, and the `VERDICTS.tsv` ratchet, §3); XFAIL markers are
implemented, never deleted (§2); establish that a fixture is right before
changing the compiler (§6); parse in full, then refuse by clause (§4); a
refusal needs a legal neighbour and acceptance is not runtime evidence (§2).
R7's oracle for a language rule is a fixture that cites its clause (§6).

### 11.8 Device generation and testbench generation stay apart

The rewrite's §2.8: the code that **generates devices** and the code that
**generates testbenches** (`--emit-exe`, `--check`, `--run`) do not import
each other, and a testbench reaches a device only through what any host gets,
the emitted source and `tools/contract.zig`. A fact the device emitter spells
is published in the device as a contract table, never re-derived from the IR
by a second spelling. A device feature that exists only for testbenches is a
contract feature every host can use, or it does not exist.

VerA today: `lib/backend/codegen/` and `lib/backend/tb/` share one module,
`backend`, so the build cannot enforce this. No file under either imports the
other, directly or through another file: since Phase 7 the testbench build
is `lib/zigbuild/exe.zig`, in a module that imports no compiler module. But
`tb/runner.zig` re-spells the `__xz`/`__w{k}`/`__1b` field names lowering
owns (inventory, 2026-10-17; `ARCHITECTURE.md` Phase 8 removes it). Both
read `lib/backend/naming.zig`. New code adds no
such edge; making the build enforce it is a refactor phase of its own (§4).

### 11.9 SIMD is for the emitted device

§5 overrides R8's and `simd-loops`'/`simd-first`'s push to vectorize hot
loops, for the compiler: its walks are chains, and the measurements in §5
stand until new ones replace them. "Hot" in §10 R0 means, in VerA, the
emitted device's `eval` and the simulator inner loops (`src/sim/`, the
testbench solver); a compiler pass is cold until a profile says otherwise.

### 11.10 Commit at every step

Each completed step (a document, a stage, a slice, a fix, a test) is its own
commit before the next step starts, under §8's rules (explicit paths, no AI
attribution). A refactor phase is still one branch and one PR (§4); its
commits are the steps inside it.
