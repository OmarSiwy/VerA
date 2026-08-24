# Testing plan: VerA to a conformance-complete v1.0.0

This file says how VerA is tested until every rule of both standards it
implements has evidence that ran, could fail, and was judged by something
other than the fixture author's own reading. `AGENTS.md` §2 defines v1.0.0 and
its measures; this file says how each one is tested, and adds what those
measures cannot see. A `ROADMAP.md` citation here means the revision main
deleted (`git show ae9633f1:docs/ROADMAP.md`, as `AGENTS.md` §1 says); its
open items now live in `docs/Vague_Decisions.md`. It holds no measured numbers (`AGENTS.md` §0 rule 1):
every number comes from a command named here.

It is step 2 of the restructure in `../UPDATE_APPS.md` (outside this repository):
step 1 shaped every unit and left notes in `docs/seams/s1-*.md`; step 2 makes
every unit testable and tested; step 3 fixes what step 2 proves broken. The
method is `../TESTING-METHODOLOGY.md` §2.3 (2026-10-03) and the `test-plan`
skill. Every command runs on Zig 0.17.0 (`flake.nix`).

---

## 0. Why the clause meters are not enough

On 2026-10-07 both clause meters read full: `zig build benchmark -- --coverage`
and `zig build test-1364 -- --coverage` list no one-way and no uncited clause.
A meter that reads full finds no more work, yet four blind spots remain:

1. **Granularity.** One positive and one `//! reject` fixture close a clause,
   however many rules it states. `tests/harness/coverage.zig`'s banner says
   so: "Both polarities cited does not establish ... all rules within a clause".
2. **Static.** A cite counts whether its fixture passed or not. An XFAIL
   still cites.
3. **One reader.** The fixture's author derives the expected value and the
   fixture then judges the compiler by it. Four fixtures here tested for a bug
   (`AGENTS.md` §6). Coverage and fuzzing cannot see a misread standard
   (methodology, Part 0 table).
4. **The judge is unchecked.** `//! reject` pins a substring, not "this is the
   only error" (`CLAUSE-AUDIT.md` §6.4). A deleted test takes its gate with it
   and nothing complains (`CLAUSE-AUDIT.md`, provenance: `4250899d` (cited as `2cc1c08` in CLAUSE-AUDIT.md, a hash this history no longer has) deleted
   twelve tests and their build steps).

So "complete" here means five things, and §3 builds each:

- **Finer denominators**, extracted from the standards' text by a script.
- **Dynamic evidence**: a cite counts only if its fixture passed in this run.
- **Evidence that can fail**: every check is shown to fail when its expected
  value is wrong, and the code behind it has a mutant the check kills.
- **A second oracle**: every behaviour is judged by at least one thing that
  does not share the author's reading.
- **Reverse traceability**: everything VerA does traces to a rule, or to a
  documented extension.

These produce one metric (§3.7): every rule of both standards carries an
evidence level, and the headline is the interval between the rules *proven*
and the rules *not yet refuted*.

---

## 1. The system under test

| Input | Output | Correct means |
|---|---|---|
| Verilog-AMS source (`.va`, `.vams`) | Zig device (`--emit-zig`), `.so`, testbench executable | LRM 2023 semantics; every `contract.validate` obligation; derivatives exact to the value |
| IEEE 1364 source (`.v`) | interpreter transcript (`--run`), native executable (`--emit-exe`), VCD | 1364-2005 semantics; a race's output is one of the outcomes the standard permits |
| VPI application (`.c`) | in-process VPI host run | LRM ch. 11-12; 1364 ch. 26-27 |
| SPICE deck (`.sp`, Annex E) | paired, compiled models | Annex E as `ROADMAP.md` §5.1 item 12 decides |
| Invalid source, any of the above | a named diagnostic that cites its clause | never a crash, never silent acceptance |

**State.** The digital scheduler (`src/sim/digital/`), the mixed coordinator
(`src/sim/mixed.zig`), and a device's `Instance`/`State`: held values, `$prev`
latches, the `vera_timepoint` cache, `stateCtl(.commit/.revert)`.

**Concurrency.** The compiler is single-threaded (`lib/` uses no `std.Thread`).

**Targets.** The device runs on host CPUs, x86_64 and aarch64. For NVPTX and
AMDGCN it is built but never run (`tests/status_gpu.zig`). The `vera` binary
is built for the five `publish.yaml` targets.

**Domains** (`test-plan` skill, DOMAINS.md):

| Domain | Components |
|---|---|
| compiler | pp, lexer, parser, elaborate, lower, prover, codegen, tb |
| numerical | derivative lanes, `$limit`, noise, stateful operators, the fixed-step testbench solver |
| stateful | digital scheduler, interpreter and native runtime, mixed coordinator, device state |
| GPU | the device on NVPTX/AMDGCN |
| SIMD | derivative lanes (`S.Of(mask)`), `batch_ok` instance lanes |
| parser / public API | `$readmem`, `$fscanf`, libmap, VCD writer, the VPI C API, `tools/contract.zig` |

---

## 2. Bug classes, their oracles, and the layer that runs them

Every row names an oracle that does not recompute the answer the way VerA does.
The layers are §5.

| # | Bug class | Oracle | Layer |
|---|---|---|---|
| 1 | Front end crashes or hangs on malformed input | no panic, no leak, only declared errors, every refusal diagnosed | L6, L10 |
| 2 | Invalid source accepted | ledger `-` rows with `reject-only`; Earley recognizer built from Annex A | §3, L5c |
| 3 | Valid source refused | ledger `+` rows; Earley accepts; Icarus/Verilator/OpenVAF accept | §3, L5c, L7 |
| 4 | Wrong analog value | OpenVAF→ngspice; hand derivation reviewed by a second reader; metamorphic | L2, L7, L8 |
| 5 | Wrong derivative | central finite difference | L4a |
| 6 | Unsound or over-strict finiteness prover | runtime finiteness over in-domain inputs; planted domain errors refused | L4b, L5b |
| 7 | Wrong 4-state value, width or sign | per-bit reference evaluator written from 1364 §5's tables | L3 |
| 8 | Interpreter and native disagree | each other (exists: `--fuzz`, `--native`) | L5a |
| 9 | Event order, NBA, races | Icarus on race-free designs; scheduler shuffle | L7, L9 |
| 10 | Mixed-signal timing | hand derivation; grid refinement and time shift | L2, L8 |
| 11 | `%g`/`%e`/`%f` formatting | libc `snprintf` (1364 §17.1.1.3 defers to C) | L3 |
| 12 | `$random`, `$dist_*` | the §17.9.3 C listing compiled as C | L3 |
| 13 | exp/log/pow accuracy | f128 or MPFR, ULP bound | L3 |
| 14 | Device state: held values, revert, retry | contract state machine; revert restores bytes | L4c |
| 15 | `batch_ok` lanes, `jac_f32`, lane pinning | per-point scalar evaluation | L4d, L4e |
| 16 | GPU miscompile | CPU evaluation of the same device | L11 |
| 17 | Nondeterministic device text | compile again; `vera` Debug vs ReleaseFast | L11 |
| 18 | Resource limit fails silently | bound passes, bound+1 gives a named diagnostic | L10 |
| 19 | OOM mishandled | `checkAllAllocationFailures` | L10 |
| 20 | VPI object model or handle misuse | Icarus `vvp` VPI; stateful handle-sequence fuzz | L7, L6 |
| 21 | Fixture is wrong (misread clause) | second oracle column; external disagreement triage | §3.3, L7 |
| 22 | Check that cannot fail | want perturbation; mutation | L2b, L13 |
| 23 | Gate lost silently | verdict ratchet, step inventory, canaries | §3.6 |
| 24 | Stack overflow or time cliff on a big input | adversarial sizes under a time and memory budget | L10 |

---

## 3. Conformance, completely: the requirement ledger

### 3.1 Six denominators, all extracted by a script

| | Requirement set | Extracted from | Closed when |
|---|---|---|---|
| **R1** | every normative sentence of the AMS LRM | `docs/ch*.html`, `docs/annex-*.html` | §3.3 |
| **R2** | every normative sentence of IEEE 1364-2005, `ROADMAP.md` §1 B's scope | `docs/1364-2005.pdf` (licensed, gitignored) | §3.3 |
| **R3** | every alternative of every grammar production | Annex A and the chapter Syntax boxes (`class="syntax"`) | a passing positive fixture derives it (L5c) |
| **R4** | every cell of a normative table: Table 9-x function × analog/digital context, operator and precedence tables, Table B.1, Annex D natures, VPI object/property/relation | the same HTML; VPI from ch. 11's diagrams | a passing fixture exercises that cell |
| **R5** | every diagnostic code (reverse direction) | `lib/diag_code.zig` | a passing `reject-only` fixture with a legal neighbour, or the code is deleted |
| **R6** | every implementation-defined choice and resource limit | `docs/Vague_Decisions.md` §6, §7 (`ROADMAP.md` §1 E) | documented and tested; a limit at bound and bound+1 |

`tools/conformance.py obligations` extracts R1-R4 and diffs them against the
ledger. It sits beside `lrm-audit`, `ieee1364-audit` and `keywords`, which
already parse the same sources. R2 runs only where the PDF exists, as
`ieee1364-audit` does.

### 3.2 The ledger

`tests/fixtures/OBLIGATIONS.tsv` (R1, R3, R4) and
`tests/fixtures/ieee1364/OBLIGATIONS.tsv` (R2):

```
# id         hash      modal    pol  kind   oracle     evidence
5.6.1.3:1    3f9a12c0  shall    +    -      hand       ch05_analog_behavior/value_retention.va
5.6.8.2:2    b71e004d  shall    +-   -      hand       a02_08_...va; a02_09_..._rejected.va
4.3.1:5      0c44e1aa  declar.  +    -      ref        exhaustive/min_max_nan.va
9.5.7:3      9e01b2f7  may      0    unspecified  -    errno value: §9.5.7 fixes none
A.6.4/12     5d2c...   syntax   +    -      earley     annex_a_syntax/19_jump_statements.va
```

- **id**: `<clause>:<n>`, the n-th normative sentence in the clause's own text
  (not its subclauses). A grammar alternative is `A.<box>/<n>`. A table cell is
  `T<table>/<row>/<col>`.
- **hash**: the first eight hex digits of SHA-256 over the sentence with its
  whitespace collapsed. The script recomputes it. A changed hash means the text
  moved: the row is re-read, never re-hashed blind. R2 commits the id and hash
  only, never the text (the PDF is licensed).
- **modal**: `shall`, `shall-not`, `must`, `may`, `can`, `error`,
  `impl-defined`, `unspecified`, or `declar.`, a declarative rule a reader
  added by hand.
- **pol**: `+` needs a passing positive fixture, `-` a passing `reject-only`
  fixture and a legal neighbour, `+-` both, `0` none (then `kind` says why).
- **kind**: `CLAUSE-AUDIT.md` §2 and §5's vocabulary. `-` is mandatory; the
  rest are `optional`, `implementation-defined`, `resource-limit`, `unspecified`,
  `non-normative` and (R2 only) `not-supported`.
- **oracle**: what judged the evidence, besides the author: `hand2` (a
  derivation checked by a second reader), `iverilog`, `verilator`, `ngspice`,
  `fd`, `ref` (an L3 reference), `earley`, `spec-example`. Plain `hand` is
  allowed while the work is in progress, never at release.

**The extractor misses declarative rules** ("The result is ..."), so every
clause that is not `non-normative` must have at least one row. A reader opens
each clause and adds the `declar.` rows by hand. The clause meters that read
full today guarantee that every clause gets visited.

**Fixture cites.** `//! lrm 5.6.1.3` stays clause-level and moves no ledger
row. `//! lrm 5.6.1.3:2` cites one sentence. `tb.parse`'s section syntax learns
`:<n>` and `/<n>`, and so do the `.c` fixtures' `lrm`/`lrm-reject` lines.

### 3.3 What counts as evidence

A row is closed when all of the following hold **in this run**:

a. **It ran and passed.** `--coverage --obligations` reads the strict run's
   verdict list, not the source tree. An XFAIL, FAIL or skipped fixture
   counts for nothing.
b. **Positive evidence asserts.** `ok=` lines under `//! checks N` on an
   observable the sentence fixes. "It compiles" closes nothing (`AGENTS.md` §2).
c. **Negative evidence isolates.** `//! reject-only <code>`: the named
   diagnostic is the *only* error. A `//! neighbour <file>` line names a legal
   variant that compiles and runs. This closes `CLAUSE-AUDIT.md` §6.3 as a
   mechanical check.
d. **It can fail.** Every `CHECK` in the fixture fails under want perturbation
   (L2b). For release, the code that implements the row has a mutant that the
   fixture kills (L13). This is `CLAUSE-AUDIT.md` §2's own definition of
   `verified`: "demonstrated to fail when the behavior is broken".
e. **A second oracle agrees** (the `oracle` column, not `hand`).

### 3.4 The reverse direction: code to requirement

- Every `.lrm` field in `lib/diag_code.zig` resolves to a ledger clause.
  `conformance.py comments` already compares code cites with fixture tags;
  extend it to the ledger.
- Every diagnostic code is emitted by a passing fixture (R5). Count today's
  gap: `comm -23 <(codes in diag_code.zig) <(codes in //! reject|warn lines)`.
- Every `Callee` variant (`lib/ir/callee.zig`), opcode row
  (`lib/ir/opcode.zig`), parser production function and diagnostic emission
  site is hit by a passing fixture: coverage marks (L12).
- Every system task, function and attribute VerA accepts is in an R4 table or
  in `docs/Vague_Decisions.md` §6 as a vendor extension (`$vera_reject_step`, `vera_*`).

Anything VerA does that no rule asks for is either documented as an extension
or deleted.

### 3.5 The text the ledger comes from

- `docs/*.html` is a transcription. `conformance.py lrm-audit` diffs it against
  `docs/VAMS-LRM-2023.pdf` section by section; that diff is a release gate.
- Errata (`ROADMAP.md` §5.8) and readings the standards leave open
  (`docs/Vague_Decisions.md` §2, §3) each become a row. The row is either
  `unspecified` (`docs/Vague_Decisions.md` §8), where tests assert the set of
  permitted outcomes and never pick one, or a decision recorded in
  `docs/Vague_Decisions.md` with a fixture. At v1.0.0 no reading is left open.

### 3.6 Checking the checker

- **Canaries.** `tests/fixtures/canary/` holds deliberately wrong fixtures,
  each expected to FAIL:
  - a wrong want;
  - an `xfail` marker on a fixture that passes;
  - `ok=10`;
  - a `//! checks` count that is off by one;
  - a reject substring that matches only an incidental diagnostic;
  - a compile-only "positive" fixture;
  - a `reject-only` fixture with a second error.
  `zig build test` runs the harness over them. A judge that cannot say no fails
  the gate. They count in no measure.
- **Verdict ratchet.** `tests/fixtures/VERDICTS.tsv` lists every fixture and
  its verdict, written by `conformance.py`. CI regenerates it and fails on any
  difference. A regression, a fix, a deleted fixture and a new one all appear
  in the diff, so `AGENTS.md` §0 rule 3 is enforced, not remembered. This
  replaces `bench.yaml`'s `continue-on-error`.
- **Step inventory.** CI reads the suite steps from `zig build -l` and diffs
  them against `tests/STEPS.txt`. A step deleted along with its tests fails CI.
- **Restore what `4250899d` (cited as `2cc1c08` in CLAUSE-AUDIT.md, a hash this history no longer has) deleted** (`CLAUSE-AUDIT.md` §7.3 item 10):
  `git show 4250899d^:tests/rng_reference.c` and the eleven others, with their
  steps, re-homed under today's layout.

### 3.7 The conformance metric

The ledger is the denominator. Each row's evidence earns a **level**, and the
metric is the distribution of levels. It is never one hand-picked count.

| Level | Name | The row's evidence, in this run |
|---|---|---|
| E0 | unknown | no evidence, or the row is not classified yet |
| E1 | cited | a fixture cites the row (what today's clause meters count) |
| E2 | passing | the citing fixtures ran and passed (§3.3 a, b) |
| E3 | discriminating | it has the polarity the row needs (`reject-only` plus a neighbour for `-`), and every check survives perturbation (§3.3 c, d) |
| E4 | independent | a second oracle agrees (§3.3 e) |
| E5 | verified | the implementing code has a mutant this evidence kills (L13): `CLAUSE-AUDIT.md` §2's `verified` |
| **F** | **failing** | a fixture that is certain of its expected value fails or is `xfail` on this row: a **known nonconformance** |

A row's level is the highest one whose conditions all hold. A row at F stays
at F whatever else it has. Rows with `pol = 0` (`optional`, `unspecified`,
`non-normative`, `not-supported`) are reported, but they sit outside the
mandatory denominator.

**The headline is an interval**, not a percentage:

- **proven** = mandatory rows at E5 ÷ mandatory rows. VerA conforms at least
  this much, by evidence that can fail.
- **not refuted** = 1 − (mandatory rows at F ÷ mandatory rows). VerA conforms
  at most this much, as far as anything has checked.

The gap between the two numbers is the untested part. Work closes the gap from
both ends: a new test either raises a row to E5 or moves it to F. A bug fix
moves F to E5. v1.0.0 is the interval [1, 1].

`conformance.py` prints it, and only `conformance.py` writes it (`AGENTS.md` §0
rule 1). There is one block per denominator: AMS (R1, R3, R4, R5) is measure C
at obligation granularity, and IEEE 1364 (R2) is measure B at obligation
granularity. Each block has one row per chapter, so the table shows where the
work is:

```
CONFORMANCE  <commit>  <date>       rows  mand   E0  E1  E2  E3  E4  E5   F   proven  not-refuted
AMS  ch2  lexical                     .    .     .   .   .   .   .   .   .     .        .
AMS  ch5  analog behaviour            .    .     .   .   .   .   .   .   .     .        .
...
AMS  A    grammar (R3)                .    .     .   .   .   .   .   .   .     .        .
AMS  R5   diagnostics                 .    .     .   .   .   .   .   .   .     .        .
AMS  total                            .    .     .   .   .   .   .   .   .     .        .
1364 ch9  behavioural modelling       .    .     .   .   .   .   .   .   .     .        .
...
1364 total                            .    .     .   .   .   .   .   .   .     .        .
```

- `--changelog vX.Y.Z` writes this block into the release entry.
  `publish.yaml`'s `--check` recomputes every column except R2's text-drift
  check, which needs the licensed PDF and runs at release on a machine that
  has it.
- The merge gate fails when **any row's level drops** (names, not counts:
  `tests/fixtures/LEVELS.tsv` lists each row's level and is diffed like
  `VERDICTS.tsv`). A drop that is correct, such as a fixture found wrong,
  goes in the same commit as the change that causes it, with its reason.
- E5 needs a mutation run, which is weekly. Between runs a row keeps the E5
  its last run earned, unless a file it depends on has changed since.

**Why this metric cannot be gamed the usual ways:**
- The denominator is extracted from the standards' text, not chosen by the
  person being measured.
- Each level needs the one below it.
- A refusal counts only on a `-` row. On a `+` row it is F.
- A stale pass cannot count, because evidence is read from this run.
- A fixture that cannot fail stops at E2.
- A deleted fixture drops its rows, and `LEVELS.tsv` shows the drop.

---

## 4. Step 2: one agent per slice, then the seams

### 4.1 Work units

`docs/UNITS.md` (`zig build archmap`) is the work queue. A unit is an import
cycle. A multi-file unit lists its **hubs**, frozen as seams, and its
**slices**, each of which "can be owned alone while its `pub` signatures hold".
One agent owns one slice, or one single-file unit. The `s1-*` areas in
`docs/seams/` group them, and the step-1 notes are each agent's first read.

Waves go bottom-up by layer, so a caller's tests are written after its
callee's:

| Wave | Contents | Why first |
|---|---|---|
| 0 | harness integrity (§3.6), `zrunner` xfail and fuzz hook (§4.4), kcov and edge-coverage tooling (L12) | every later agent measures with these |
| 1 | layers 0-4: kernels, `token`, `integer`, `lexer`, `diag`, `ast`, `constfold`, `wreal`, `libmap`, `scheduler`, `time`, `contract` | leaves; pure functions; exhaustive-friendly |
| 2 | layers 5-8: parser slices, preprocessor slices, `mir`, `discipline_rules`, `hier_param`, `sim/fmt`, `rt/logic` | the front end |
| 3 | layers 9-14: elaborate, `ssa`, lower slices, `digital` slices, `mixed`, `analysis`, `proof`, `ifconv` | the middle |
| 4 | layers 15-26: codegen plan and slices, `naming`, orchestrator, tb, `lib/root`, cli, vpi slices | the back end and the API |
| 5 | seam agents, one per hub and per `Uses` edge that carries a stage value (§4.3) | needs both sides tested |
| 6 | whole-system layers L5-L13 | cross-unit by nature |

The ledger (§3) is a parallel track worked by chapter, not by code: one
reader per LRM chapter or annex extracts and classifies rows, links evidence,
and files a missing-fixture item for each open row.

`AGENTS.md` §8 binds every wave: own worktree, stage by path, and about 12 GB
of `.zig-cache` per agent. Size each wave to the disk.

### 4.2 The slice protocol

An agent walks its slice top to bottom. Its tests go in the slice's files, or
in the unit's `test.zig` slice, and they move with the code (`AGENTS.md` §4).
Step 2 changes no behaviour, so goldens stay byte-identical
(`zig build golden -- before/after/diff`). Testability seams a test needs
(an injected `Io`, a split pure function) follow `legacy-code`: the smallest
change, with a characterization test first.

For each slice, in order:

1. **Inventory.** List every `pub` decl (the root's alias list is the API),
   every error return, every `switch` over a boundary enum, every
   `unreachable`/`@panic`, and every loop bound.
2. **Oracle per behaviour.** A clause and its hand-derived value, a naive
   reference, a round trip, or an invariant. Never the function's own
   algorithm rerun.
3. **Tests at the seam.** Call through `pub` signatures, not internals.
4. **Boundary inputs**, whichever apply:
   - empty, one, many, the bound, bound+1;
   - widths 1, 31, 32, 33, 63, 64, 65, 128, 129;
   - every digit class: 0/1/x/z/?/_;
   - ±0, denormals, ±inf, NaN;
   - empty strings, bytes above 0x7F;
   - the deepest nesting the slice allows.
5. **Exhaustive** where the domain is small (§L3). **Fuzz** where the slice
   takes bytes or a structure from outside (§L6).
6. **Every allocator-taking `pub` fn** passes
   `std.testing.checkAllAllocationFailures`. Every I/O path is driven to each
   of its error returns.
7. **Coverage.** Run the slice's tests and the suite under kcov (lines) and
   edgecov (machine-code edges, L12). Each uncovered line or edge gets a test,
   or an `unreachable` with its argument, or goes on the step-3 delete list.
8. **Conformance.** The slice's `//!` header lists the clauses it cites. Each
   of those clauses' ledger rows has evidence, or the agent files the missing
   fixture.
9. **Mutation** (L13) on the slice. A surviving mutant gets a new test, or a
   note saying why it is equivalent.
10. **Report.** `docs/seams/s2-<slice>.md`, in the s1 format:
    - an inventory table: decl → behaviours → tests → oracle;
    - kcov and edgecov before and after, each with its command;
    - every uncovered line or edge, and why;
    - xfails, mutants that survived, bugs found.

**Done** when every `pub` decl has a test, every line and edge is covered or
argued, every boundary enum arm is hit, every error return has been forced,
every cited clause's rows have evidence, and `zig build test` is green with
the slice's xfails listed.

### 4.3 The seam protocol

A seam is a hub, or a `Uses` edge that carries a stage value: `Lowered`
(`lib/ir/lower/tables.zig`), MIR and `Mir.Callee`, the device text and its
contract. The seam agent tests the contract, not either side:

- **The producer's postcondition, as a verifier.** Write a check over the
  narrow value and run it at the boundary in Debug and ReleaseSafe. For MIR
  this is `lib/ir/verify.zig`, which does not exist yet (`grep -rn 'fn verify'
  lib/ir` finds nothing). It checks:
  - SSA definitions dominate their uses;
  - operand arity and types match the `opcode.zig` columns;
  - every `Callee` is resolved;
  - derivative masks stay within the unknowns, and lane reads within the mask.
  It runs after lowering and after every MIR pass.
- **Every variant crosses the seam.** `tests/exhaustive.zig` already forces a
  decision for each variant at compile time. The seam test also *reaches* each
  variant with a fixture (coverage marks, L12).
- **The device-host seam** is `tools/contract.zig`. `validate`/`validateHost`
  run in every suite. Its runtime obligations are tested as a state machine
  (L4c).

### 4.4 The handoff to step 3

Step 2 writes the test, and step 3 makes it pass. A failing test goes across
only if its expected value is certain: a derivation in the test's comment that
cites a clause or an L3/L7 oracle. If it is not certain, the agent settles the
fixture first (`AGENTS.md` §6, "the trap").

- **Unit tests.** `tools/zrunner.zig` learns xfail. A test whose name starts
  `xfail(<reason>): ` must fail, and passing it is an XPASS FAIL, the
  fixture rule (`AGENTS.md` §2) applied to unit tests. Skips must match
  `tests/SKIPS.txt` (for example, no GPU), so a skip cannot hide a test.
- **Fixtures.** `//! xfail <reason>` as today.
- **The step-3 queue** is `grep -rn 'xfail(' lib src tests` plus
  `grep -rl '^//! xfail' tests/fixtures`. Step 3 implements, and the XPASS
  forces the marker out in the same commit.
- **Step 3's own gate.** A rewrite keeps every step-2 test green, keeps
  goldens byte-identical unless it is a declared behaviour fix, and states the
  measure it moves. A SIMD or branchless rewrite in the compiler also needs a
  scalar oracle test (every length 0 to 4×width, every offset) and a benchmark
  that shows a win, because `AGENTS.md` §5 records `@Vector` losing in the
  compiler at every size measured.
- **Fuzzing under zrunner.** `std.testing.fuzz` calls `@import("root").fuzz`,
  and zrunner defines none. zrunner gains a `fuzz` that replays the corpus plus
  N seeded inputs, so fuzz tests run as ordinary tests in `zig build test`.
  Coverage-guided runs use a separate `zig build fuzz` artifact on the default
  server-mode runner.

---

## 5. Whole-system layers

**L1. Assertions.** Add the MIR verifier (§4.3). Use pair assertions on lane
masks in the prover and in `codegen/float/`. Nightly, run the strict suite with
`vera` built ReleaseSafe, so every fixture passes through a compiler with its
safety checks on, and with devices built Debug (`su_ok`). Measure assertion
density with
`grep -rc 'assert(' lib | awk -F: '{s+=$2} END {print s}'` against the
function count. TigerStyle asks for two per function. Treat it as a direction,
not a gate.

**L2. Fixtures**, the existing suite, plus:

- a. Sentence cites, `reject-only` and `neighbour` (§3.2, §3.3).
- b. **Want perturbation.** `zig build benchmark -- --perturb` rewrites every
  want in a passing fixture at once and expects every `ok=` to become `ok=0`:
  - `CHECK`: w ± 10·tol;
  - `CHECKR`: w·(1 ± 10·rtol);
  - `CHECKX`: the next float;
  - `CHECKI`: w + 1;
  - `CHECKEQ`: one side + δ.
  One compile per fixture. `tests/harness/lint.zig` already refuses
  tautologies and computed wants statically; this catches a check that is
  never reached, or whose tolerance accepts anything.
- c. Dynamic coverage (§3.3 a).

**L3. Exhaustive and reference oracles.** Each reference shares no code with
VerA.

- `lib/frontend/ref4.zig` (it imports only `integer.zig`, so it is a frontend
  module test), a per-bit 4-state evaluator written from 1364 §5's tables
  (bitwise, reduction, equality, relational, shift, arithmetic x-propagation;
  width and sign from §5.4-§5.5). Exhaustive: every operator, widths 1-4, all
  4^w values per operand, signed and unsigned. Random: the widths in
  `tests/harness/fuzz.zig`'s `fuzz_widths`. Compared against
  `lib/frontend/integer.zig`'s folds, the interpreter, and native code, with
  many expressions per generated file as `--fuzz` does.
- **Formatting.** `$display`/`$sformat` `%d %h %o %b %e %f %g %t` and widths,
  against libc `snprintf` linked into the test. Inputs: ±0, denormals, inf,
  nan, powers of ten at rounding boundaries, `1234.5678` (`ROADMAP.md` §5.5,
  `s01_01`), and 10⁶ random doubles. Both the analog `cg_display` path and the
  digital `src/sim` path.
- **RNG.** The restored `rng_reference.c` (the §17.9.3 listing) against
  `rng_kernels.zig`, over seeds, every distribution and its argument ranges.
- **Math.** `contract.gm`'s exp/log/pow and the rest against f128, with the
  bound written into `docs/Vague_Decisions.md` §7. Every f32 input exhaustively for any
  f32 path (`jac_f32`); for f64, hard cases (reduction boundaries, denormals,
  ±0, inf, NaN) plus random values.
- **Literals.** Every base × size {1, 31, 32, 33, 64, 65, 128} × digit class
  through the lexer, against a regex built from Annex A's number productions.

**L4. Device certificates.** `zig build benchmark -- --certify` runs on every
runnable analog fixture and on the compact models (`diode`, `mos1`, `bsim4va`,
`psp103`). It covers the bias points each fixture declares plus K random points
within `--unknown-bound=`.

- a. **Derivatives against a central difference**, for `eval` and `evalQ`:
  ```zig
  // Sketch: shapes follow tools/contract.zig's RefFamily and Rows.
  fn checkJacobian(comptime D: type, m: *const D.Model, inst: *const D.Instance,
                   x0: [n_u]f64, sim: contract.SimState) !void {
      const AD = contract.RefFamily(f64, &all_lanes, .{ .dense = true });
      const V = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{ .dense = true });
      const ad = D.eval(AD, &x0, m, inst, sim);
      for (0..n_u) |j| {
          const h = std.math.cbrt(std.math.floatEps(f64)) * @max(@abs(x0[j]), 1.0);
          var xp = x0; xp[j] += h;
          var xm = x0; xm[j] -= h;
          // Skip when x±h straddle a branch: the region signature
          // (`batch_lead`) differs between them.
          const rp = D.eval(V, &xp, m, inst, sim);
          const rm = D.eval(V, &xm, m, inst, sim);
          inline for (ad.res, rp.res, rm.res) |a, p, q| {
              const fd = (p.v - q.v) / (2 * h);
              if (!(@abs(fd - a.d[j]) <= atol_row + 1e-6 * @abs(a.d[j])))
                  return error.JacobianMismatch;
          }
      }
  }
  ```
  The truncation error of a central difference is O(h²·f‴). With
  h = ε^(1/3)·max(|x|, 1) that is about ε^(2/3), roughly 4e-11 relative,
  so 1e-6 has margin and still catches a wrong term. Compare `$limit` sites
  where the limiter is inactive.
- b. **Prover soundness.** For every device the prover accepts, evaluate it
  with random model cards inside the declared `from` ranges and with x inside
  the unknown bound: every output must be finite. A NaN or inf is a prover bug,
  or a missing range that should have been a diagnostic. The mirror test is
  L5b's planted domain error, which must be refused with a named code.
- c. **State machine.** For every stateful device, drive random sequences over
  `initState`, `setupInstance`, `eval`, `updateState` and
  `stateCtl(.commit/.revert)` against the contract's transitions.
  - A revert after any sequence restores `State` byte for byte.
  - A `$vera_reject_step` retry equals a fresh solve at `t_retry`.
  `tests/revert_host.zig` does this for one device; generalise it.
- d. **Batch exactness.** Every `batch_ok` device at W ∈ {2, 4, 8}, with
  independent random points (divergent regions included), equals the per-point
  scalar evaluation bitwise. That is what `codegen/float/`'s header promises.
  Per-point `Instance` reads (`batch_inst`) are included.
- e. **`jac_f32`.** The f32 Jacobian is within its stated relative bound of the
  f64 one.

**L5. Generators** (Csmith/YARPGen pattern). They are seeded and run out of
process. Each program costs a Zig compile, so a file batches hundreds of cases,
as `tests/harness/fuzz.zig` does (400 per file). A failure is reduced on the
generator's own AST (delta debugging) and checked in as a fixture.

- a. **V-smith.** Extend `tests/harness/fuzz.zig` from expressions to:
  - statements, `if`/`case`/loops;
  - tasks and functions, NBAs, events;
  - `generate`, hierarchy.
  Designs are race-free by construction: one writer process per variable, and
  NBAs only across processes. Oracles: `--run` vs native (exists), Icarus (L7),
  ref4 for expressions. **Swarm:** each file enables a random subset of
  features.
- b. **VA-smith.** Random analog modules:
  - branches, direct and indirect contributions;
  - `exp`, `ln`, `sqrt`, `pow`, `limexp`, `abs`, `min`/`max`, conditionals;
  - `ddt`, `idt`, parameters with ranges, analog functions, bounded loops.
  Domain-safe by construction (`sqrt(x*x + 1)`), with a swarm toggle that
  plants exactly one out-of-domain site. Oracles:
  - L4a and L4b;
  - Debug vs ReleaseFast device, and `--zig-backend=llvm` vs `native`;
  - CPU vs GPU (L11), and OpenVAF→ngspice inside its subset (L7);
  - **a tree-walking f64 evaluator in the generator itself**, which knows its
    own AST: the analog reference interpreter VerA does not have.
- c. **Grammar.** `conformance.py grammar` reads every Syntax box into BNF.
  1. An Earley recognizer over that BNF is the reference acceptor.
  2. A derivation generator derives every alternative k times.
  3. One-token mutations (delete, duplicate, swap) are applied to every fixture.
  Oracle: VerA accepts at parse level (no syntax-class diagnostic; semantic
  ones are allowed) exactly when Earley does. Each disagreement is a VerA bug,
  a BNF transcription error (`lrm-audit`), or a context rule the BNF cannot
  state, which is then recorded. R3 counts alternatives derived by passing
  fixtures: the generator finds the gaps, and a person writes the fixture with
  its semantics.

**L6. In-process coverage-guided fuzzing** (`std.testing.fuzz`, Zig 0.17).

Targets:
- the preprocessor (macros, `ifdef` nesting, includes from an in-memory
  directory);
- the lexer, the parser, and the full `.lint` compile (parse, elaborate,
  lower, prove);
- the SPICE card reader and the libmap reader;
- the `$readmem` and `$fscanf` format readers;
- VPI handle sequences: a stateful target where Smith picks a routine and a
  live handle.

Oracle: no panic and no leak (fuzz mode resets `std.testing.allocator` for each
input); only declared errors; every `CompileFailed` carries at least one
diagnostic whose clause resolves; rendering never panics.

Zig 0.17's fuzzer has no comparison feedback (methodology §1.2), so targets
build tokens from the keyword table and Annex A instead of raw bytes. The
corpus is a sample of fixtures plus every crasher; it replays in plain
`zig build test`.

```zig
fn lintNeverPanics(_: void, s: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const src = buf[0..s.slice(&buf)];
    const gpa = std.testing.allocator;
    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var res = vera.compileSourceOpts(gpa, src, .lint, .{ .diags = &bag }) catch |err| switch (err) {
        error.CompileFailed => {
            try std.testing.expect(bag.failed());
            return;
        },
        error.NoModule, error.OutOfMemory => return,
        else => |e| return e, // anything else is a finding
    };
    res.deinit();
}

test "fuzz: .lint never panics, and every refusal is diagnosed" {
    try std.testing.fuzz({}, lintNeverPanics, .{ .corpus = &corpus });
}
```

**L7. External differential.** An external engine is evidence by agreement,
not an authority. Each disagreement is triaged as a VerA bug, an engine bug, or
a reading of the standard (`docs/Vague_Decisions.md` §2, §3), and recorded in
`tests/fixtures/<engine>.tsv` beside the existing `VERILATOR.tsv`.

- **Digital.** Icarus Verilog becomes the primary second engine: it is
  4-state and event-driven. Verilator stays (`conformance.py verilator`), but it
  is 2-state, so many of its disagreements are expected. The inputs are every
  `.v` with a transcript and all V-smith output. For VPI, the `vpi_runs` `.c`
  fixtures that use only 1364 ch. 26-27 routines run under `vvp -M`.
- **Analog.** OpenVAF compiles a fixture to OSDI and ngspice runs it (`ngspice`
  is installed here; OpenVAF in nixpkgs is unverified). This applies to pure
  device fixtures within OpenVAF's subset. Compare the DC operating point and
  AC at ngspice `reltol=1e-9`. Compare transient only where ngspice can match
  the testbench's fixed-step backward Euler (`AGENTS.md` §7). Xyce/ADMS is an
  optional third engine for breaking ties.
- Add `iverilog`, `verilator`, `openvaf` and `kcov` to a `devShells.testing`
  in `flake.nix`.

**L8. Metamorphic and EMI**, run over existing fixtures. The output must be
identical (transcript, or `ok=` lines; device values bitwise where the
transform is exact).

- Dead `if (0)` statements, dead generate branches, unused parameters and
  functions.
- Rename every identifier (escaped ones too), reorder module declarations,
  split the file into includes.
- Wrap statements in `begin`/`end` or named blocks. Flatten a child instance
  by hand-transform.
- Analog: V(a,b) = −V(b,a); an indirect contribution where it is equivalent
  (§5.6.7); paramset vs direct parameters; `aliasparam`.
- Scale every current contribution and conductance by k = 2^m: solution
  currents scale by k exactly.
- Digital: `--schedule=static` vs `fifo`, `--state=2` vs 4 on x-free designs,
  `--vera-snapshot` (all three exist).
- Mixed: doubling the grid moves each event by at most the old step; shifting
  every time by T shifts the output of an LTI fixture by T.

**L9. Deterministic simulation of the scheduler.** Add a test-only
`--schedule=shuffle:<seed>`. It permutes same-time events within a region, in
the order IEEE 1364 §11.4 leaves undefined, and never across regions.

- Oracle: a race-free design (all V-smith output, and fixtures marked
  `//! race-free`) prints the same transcript under every seed.
- A fixture whose transcript changes is racy: it must assert its permitted set
  (`unspecified`), or be fixed.
- Failures replay by seed. The mixed coordinator gets the same treatment
  wherever §8 allows a choice. Merge: 10 seeds on a sample; nightly: 1000.

**L10. Faults, limits, sizes.**
- **OOM.** `checkAllAllocationFailures` over `compileSourceOpts` (`.lint` and
  `.build`) on one fixture per chapter directory. Today it covers one bad
  source (`lib/root.zig`). Oracle: `OutOfMemory` propagates, nothing leaks, and
  no partial file is written.
- **I/O.** An unreadable include, an include cycle, an unwritable
  `--work-dir`, `$fopen` failure, a full tmpfs, a missing `zig` child: each
  gives a named diagnostic.
- **R6 limits** at the bound and at bound+1; the RNG row is the template
  (`CLAUSE-AUDIT.md` §5.4).
- **Sizes**, under `timeout` and an RSS limit:
  - expression nesting 10⁴ and 10⁵, `begin` nesting 10⁴, 10⁵ statements;
  - 10⁶ generate iterations, 64k-bit literals;
  - recursive and deep macros, 10⁴ modules, hierarchy 10³ deep.
  Oracle: success, or a named limit diagnostic, within budget. Never SIGSEGV.
  Unbounded recursion is how SQLite's `median()` overflowed its stack after
  fuzzing had passed (methodology Part 0).
- `--sweep` gains thresholds, so a footprint or time regression fails nightly.

**L11. Determinism and targets.**
- `zig build golden` over every fixture with `vera` built Debug, ReleaseSafe
  and ReleaseFast: the snapshots are identical, which catches uninitialised
  memory and UB inside the compiler. Also run twice, from another cwd, and with
  `vera` built for aarch64 under qemu.
- Devices on x86_64 baseline, v3 and v4, and on aarch64 under qemu;
  `test-1364 -- --native` in every schedule and state mode (exists).
- **GPU.** A self-hosted runner (sm_89 and gfx1100, the README's build table)
  evaluates every runnable analog fixture's device on the GPU. It must match the
  CPU bitwise where the float mode is `strict`, else within a ULP bound. Run
  compute-sanitizer memcheck and racecheck once. Until this runs, the
  conformance statement says "compiles for NVPTX/AMDGCN; not executed".
- macos-latest nightly. windows-latest after v0.14.0, VPI excluded
  (`ROADMAP.md` §1 F).

**L12. Coverage as a map of the gaps.**
- **kcov lines.** Run `vera` under kcov during the strict suite
  (`--include-path=lib,src`), and the unit tests through a `-Dkcov` build
  option that wraps each test run. It is a ratchet per unit, not a target.
- **edgecov: machine-code edges** (Kelley's rung 3; no tool exists for Zig).
  1. Build with `-ffuzz`, which emits SanitizerCoverage inline 8-bit counters
     and a PC table.
  2. Link a small `tools/edgecov.zig` that defines
     `__sanitizer_cov_8bit_counters_init` and `__sanitizer_cov_pcs_init`,
     keeps both ranges, and writes them out at exit.
  3. Symbolize the PCs (`llvm-symbolizer`) and report, per unit, every edge
     never taken by a passing test.
  Verify on 0.17 that a non-fuzz build accepts the flag without the fuzzer
  runtime. If it does not, kcov lines plus marks is the fallback.
- **Coverage marks** (TigerBeetle `marks.zig`). Behind `-Dmarks=true`, zero
  cost otherwise. Place them at every diagnostic emission site, every `Callee`
  and opcode arm in lowering and codegen, and every parser production
  function. The report lists the marks no passing fixture hits (§3.4).

**L13. Mutation.** There is no Zig tool. `conformance.py mutate <file>`
applies one mutant at a time:
- flip `<`/`<=`, `==`/`!=`, `and`/`or`, `+`/`-`;
- change a constant by ±1;
- delete a statement;
- give a switch arm its neighbour's body.

For each mutant it rebuilds `vera`, then runs `zig build test` and the fixtures
that cite the clauses in the file's `//!` header. Every file lists its clauses
(`AGENTS.md` §4), so the selection is mechanical. A surviving mutant means a
requirement whose evidence cannot fail: the ledger row loses its closure until
a test kills the mutant or a note shows it is equivalent. Weekly over the files
changed since the last run; the full sweep before a release.

---

## 6. Gates

| Tier | Budget | Runs |
|---|---|---|
| Local | < 1 min | `zig build --watch -fincremental`, `zig build test-<module>`, the fixtures of the touched directory (`benchmark -- <filter>`) |
| **Merge** (required; merge queue) | ≤ 30 min wall, sharded | `zig build test` (fmt, `exhaustive.zig`, canaries, fuzz corpus replay, xfail rules) in Debug and ReleaseSafe; the strict suite sharded by fixture directory, with the `VERDICTS.tsv` ratchet; `test-1364`, `test-devices`, `test-vpi-fixtures`, `test-spice`; the §3.7 metric, with the `LEVELS.tsv` ratchet (no row's level drops); R5; golden determinism on a fixed sample; step inventory |
| Nightly | hours | L4 over every fixture and model; V-smith and VA-smith 1 h each; the grammar differential; `zig build fuzz --fuzz=<limit> -j<N>` 1 h per target; Icarus, Verilator, OpenVAF; scheduler shuffle at 1000 seeds; ReleaseSafe `vera` over the whole suite; perturbation; kcov, edgecov and marks reports; qemu aarch64; macOS; the GPU runner; adversarial sizes; `--sweep` thresholds |
| Weekly | hours | mutation over changed files |
| Release | unbounded | all of the above; the full mutation sweep; `lrm-audit`; the R2 hash check on a machine holding the licensed PDF; ≥ 24 CPU-h per generator and fuzz target; every target; `conformance.py --changelog` |

The one change to `bench.yaml`: the suites stop being `continue-on-error`
reports and become ratchets that fail on membership change, never on a
nonzero count. Until v1.0.0 a FAIL may stay, but only by name, in
`VERDICTS.tsv`, where its arrival and departure are reviewed.

---

## 7. Exit criteria for v1.0.0

`ROADMAP.md` §1 A-G stand. Added, each answerable by a script or a yes/no:

| | Criterion | Command |
|---|---|---|
| H0 | The §3.7 interval is [1, 1] in both blocks: every mandatory row is at E5, and none is at F | `conformance.py` |
| H1 | Ledger complete:<br>• every extracted sentence is a row<br>• every normative clause has ≥ 1 row<br>• every hash matches the text<br>• every row with pol ≠ 0 is closed per §3.3<br>• no `hand` oracle<br>• no open reading | `conformance.py obligations --check` |
| H2 | Every grammar alternative is derived by a passing positive fixture; Earley and VerA show no unexplained disagreement in the last nightly run | `conformance.py grammar --check` |
| H3 | Every R4 table cell is closed | `obligations --check` |
| H4 | Every diagnostic code has a passing `reject-only` fixture and a neighbour, or is deleted; every `.lrm` resolves | `obligations --check` |
| H5 | No `CHECK` survives perturbation | `benchmark -- --perturb` |
| H6 | Every file in `lib/` and `src/` has been swept; every surviving mutant is killed, shown equivalent, or recorded | `conformance.py mutate --report` |
| H7 | L4 a-e: no failure over all fixtures and models, ≥ 10⁶ points in total | `benchmark -- --certify` |
| H8 | Every generator and fuzz target has run ≥ 24 CPU-h with no unexplained divergence; the last 25% of the run found no new coverage; every finding is checked in | the nightly logs |
| H9 | Every disagreement with Icarus, Verilator and OpenVAF→ngspice is triaged; no open row says "VerA bug" | `tests/fixtures/*.tsv` |
| H10 | Golden snapshots are byte-identical across `vera` build modes, runs and hosts | `golden -- diff` |
| H11 | Every target the statement claims has run the suite | the CI matrix |
| H12 | Every R6 limit is tested at the bound and at bound+1; no adversarial input crashes within budget | the L10 step |
| H13 | kcov and edgecov are not below the last release for any unit; every mark is hit, or its code is deleted | L12 reports |
| H14 | Every canary FAILs; the step inventory has not changed, or the change was reviewed | `zig build test` |
| H15 | Every `docs/seams/s2-*.md` slice is done (§4.2), and no xfail remains | `grep -rn 'xfail(' lib src tests` is empty |

---

## 8. Order of work

The cheapest and highest-leverage items come first. Each names the measure it
moves.

1. **Gate integrity**: canaries, `VERDICTS.tsv`, step inventory, `zrunner` xfail
   and fuzz hook, restoring the `4250899d` (cited as `2cc1c08` in CLAUSE-AUDIT.md, a hash this history no longer has) tests. Changes nothing a consumer
   sees, so it is a patch (v0.9.1's harness rows). Moves A by making it
   trustworthy.
2. **The metric's scaffold** (§3.7), printed from day one. Until the
   sentence ledger exists, it bootstraps with one row per clause (today's
   `CLAUSES.tsv` rows), so the table and `LEVELS.tsv` exist before they are
   fine-grained. E0-E2 are computable at once. Each later item unlocks a
   level: item 3 E3, the `oracle` column E4, L13 E5.
3. **`reject-only`, `neighbour`, want perturbation, dynamic coverage.** Finds
   vacuous fixtures. Moves C.
4. **L4 certificates, the Jacobian check first.** A patch if they find nothing;
   a fix they force is a minor. Moves A, and adds H7.
5. **Wave 0, then waves 1-4 of §4**, with the R1 ledger track running beside
   them. Maps to v0.14.x's measure C tail.
6. **R3 grammar and Earley; R5 catalogue.** C.
7. **L3 references, Icarus, scheduler shuffle.** v0.13.x's measure B evidence.
8. **L5, L6, L8, L10.** v0.14.x E.
9. **Seam agents (wave 5), the MIR verifier, kcov/edgecov/marks, mutation,
   targets and GPU** (wave 6).
10. **R2**, the 1364 ledger. It is the largest, and it can only be extracted
   locally.

---

## 9. What this plan cannot see

- **Mixed signal has no free external engine.** Its oracles are hand
  derivations, metamorphic relations and L9. It is the weakest area, so spend
  reviewer time there.
- **R2 can only be extracted where the licensed PDF is.** CI checks the
  ledger's shape, not drift in the text.
- **The modal-verb extractor misses declarative rules.** R1 and R2 are only as
  complete as the read of each clause (§3.2).
- **An external engine can share a misreading.** Agreement is evidence, not
  proof. That is why `hand2` exists.
- **A GPU target with no runner is untested.**
- **The testbench is fixed-step backward Euler** (`AGENTS.md` §7). LTE and
  step control belong to the host, so only what the device publishes can be
  tested.

---

## 10. Decisions this plan needs

1. **`AGENTS.md` §2.** Add H0-H15 there, or fold H0-H4 into B and C as an
   obligation-level command and the rest into a new "independent evidence"
   item.
2. **`AGENTS.md` §2 and §6.** The `:<n>` cites, `reject-only`, `neighbour`,
   `race-free`, and zrunner's `xfail(` prefix join the directive tables.
3. **R6's home.** `docs/Vague_Decisions.md` §6 and §7 hold §1 E's list.
4. **Step 3 vs `AGENTS.md` §5.** `../UPDATE_APPS.md` asks for SIMD "whenever we
   can"; §5 records `@Vector` losing in the compiler at every size measured.
   §4.4's gate (a scalar oracle and a measured win) lets the two coexist; say
   which rule governs.

---

## 11. What exists (2026-10-08)

Every item below runs; numbers come from the commands, never from this file.

| Piece | Where | Run |
|---|---|---|
| Requirement ledger (R1) | `tests/fixtures/OBLIGATIONS.tsv`; extractor in `tools/conformance.py` | `conformance.py obligations [--update]` |
| The metric (§3.7) | `conformance.py metric` | `metric --verdicts=F --perturbed=F [--levels=OUT]` |
| Verdict and level ratchets (§3.6) | `tests/fixtures/VERDICTS.tsv`, `LEVELS.tsv` | `conformance.py ratchet --verdicts=F [--levels=F] [--update]` |
| Step inventory (§3.6) | `tests/STEPS.txt` | `conformance.py steps [--update]` |
| Canaries (§3.6) | `tests/canary/`, `EXPECT.tsv`; `tests/harness/canary.zig` | `zig build test-canary` (on `test`) |
| `reject-only`, `neighbour`, sentence cites (§3.2-§3.3) | `lib/backend/tb/directive.zig`; harness, digital runner, `test-1364` all honour them | the strict suite |
| Promotions and links | `conformance.py promote-reject-only`, `link-neighbours`, `link-sentences` | after `benchmark -- --probe-reject-only` |
| Want perturbation (L2b) | `tests/fixtures/check.vh` (`VERA_PERTURB`), `tests/torture.zig` | `benchmark -- --perturb [--verdicts=F]` |
| Derivative certificate (L4a) | `fdCheck` in `lib/backend/tb/runner_text.zig`; `//! fd-exempt <reason>` | `benchmark -- --certify` |
| Prover-soundness certificate (L4b) | `finiteCheck` in `lib/backend/tb/runner_text.zig`, for a device whose every contribution unit is `.optimized` (`finite_proved`, set by `tests/torture.zig`); `//! fd-exempt` | `benchmark -- --certify` |
| State certificate (L4c) | `stateCheck` in `lib/backend/tb/runner_text.zig`: commit, `updateState`, `stateCtl(.revert)` at each accepted point; `//! fd-exempt` | `benchmark -- --certify` |
| In-process fuzzing (L6) | `tests/fuzz.zig`; zrunner's `fuzz` replays seeded inputs under `test` | `zig build fuzz --fuzz=N` (coverage-guided) |
| zrunner `xfail(` (§4.4) | `tools/zrunner.zig` | `zig build test` |
| Icarus differential (L7) | `conformance.py icarus` → `tests/fixtures/ICARUS.tsv` | through the queue, bounded per process |
| Mutation (L13, E5) | `conformance.py mutate` → `tests/fixtures/MUTANTS.tsv` | through the queue, W1 incremental |

**The build queue.** Everything heavy goes through one machine-wide lock with
a memory cap per job: `../.build-queue/vq` (outside the repository).
- W1 (`../vera-worker`) runs `zig build --watch -fincremental` for checks of
  a few seconds (`vq check [TREE] [-- CMD]`).
- W2 (`../vera-base`) runs the normal-build gates (`vq run -- CMD`).
- External tools run in place with `vq run --here`.

On 2026-10-07 an Icarus run with no per-process bound OOM-killed the session
(one oversized design drove `ivl` to 20 GB). Since then every oracle child is
`ulimit`-bounded, at most four run at once, and every queued job sits in a
cgroup with `MemoryMax`.
