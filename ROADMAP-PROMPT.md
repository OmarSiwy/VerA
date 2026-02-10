# Prompt: author `ROADMAP.md` for VerA (v0.0.1 → v1.0.0)

Everything below the line is the prompt. Paste it verbatim.

---

You are writing one document: `/home/omare/Documents/Projects/Zig/VerA/ROADMAP.md`.
It is a release plan that takes VerA from **v0.0.1 to v1.0.0**, where v1.0.0
means *100% conformance to the Verilog-AMS 2023 LRM, on a data-oriented,
SIMD-first architecture*.

You are not implementing anything. You are not fixing anything. You produce
exactly one new file and change no other file.

## 0. Hard constraints — violating any of these invalidates the deliverable

1. **Read-only.** You may `Read`, `Grep`, `Glob`, and `git show` / `git log`.
   You may **NOT** run `zig build`, `zig test`, `./zig-out/bin/vera`,
   `tools/golden-baseline.sh`, or anything that writes, compiles, or measures.
2. **Therefore you never state a measured number as current.** Every number in
   your output carries its source and its as-of date, in this form:
   `1489 pass / 41 FAIL / 28 XFAIL of 1558 (PLAN.md §0, as of 2026-09-21)`.
   A number without a citation is a defect in your deliverable.
3. **You do not invent work items.** Every task in the roadmap traces to a
   named source line in the reading list below. If you believe something is
   missing from all sources, put it in a final section titled
   `## Appendix: gaps I could not source` — never in the release tables.
4. **You write no code, no Zig, no fixtures, no build steps.**
5. One file. No edits to `PLAN.md`, `TODO.md`, `ARCHITECTURE.md`,
   `tests/fixtures/MANIFEST.md`, `build.zig.zon`, or anything else.

## 1. What VerA is

A Verilog-AMS compiler written in Zig, plus a digital simulator. It compiles
Verilog-A source into Zig device code that an external circuit simulator
(ARPice, a sibling repo) links and calls inside a Newton loop.

- `lib/` — the compiler: `preprocess → lex → parse → elaborate → lower+ssa →
  ifconv → prove → codegen`. ~67k lines.
- `src/` — what runs after compilation: `src/sim/` (digital Verilog
  interpreter over the shared AST), `src/vpi/` (VPI C ABI), `src/main.zig`
  (CLI). ~6.7k lines.
- `build.zig` — two tables and three loops; `module_specs` at `build.zig:41`
  is the module graph and `defineModules` **panics on a cycle**, so dependency
  order is enforced by the build, not by review. Read `build.zig:1-100`; the
  doc comment explains why there is exactly one suite step (`benchmark`) and
  why generated-device tests are deliberately not build-graph artifacts.
- `tests/fixtures/` — 1558 `.va`, 81 `.v`, 26 `.c`, 7 `.sp`, 4 `.vh` across 23
  chapter directories mirroring the LRM's chapters and annexes.
- `docs/` — the normative source: `VAMS-LRM-2023.pdf` plus per-chapter HTML
  (`ch1-intro.html` … `ch12-vpi-routines.html`, `annex-a-syntax.html` …
  `annex-h-glossary.html`). These are the spec. Cite clauses by number.

### Scope of v1.0.0 — decided, do not relitigate

**In scope: VerA only, both halves** — the `lib/` compiler *and* `src/sim`,
`src/vpi`, `src/main.zig`.

**Out of scope: ARPice.** It is a sibling repo at
`/home/omare/Documents/Projects/Zig/ARPice`. You may read
`ARPice/docs/verilog-ams-conformance-plan.md` (590 lines, 32 plan rows) because
it is the origin of the `A01`/`D07`/`M01`/`H01`/`Q03`/`X01` row IDs that every
VerA document uses — you need it to decode the vocabulary. You do **not**
schedule ARPice work. Where a VerA obligation cannot be closed without an
ARPice change (there are several — `u_nodeset` and `noise_tables` are both
dead exports that ARPice never reads), mark the item
`blocked-external: ARPice` and put it in a dedicated section, not on the
critical path.

## 2. The version baseline — decided, do not relitigate

`build.zig.zon:3` says `.version = "0.9.0"`. **That number is aspirational and
you are overriding it.** There are **zero git tags** in this repository
(`git tag` is empty across 323 commits since 2026-07-04). Nothing has ever
been released.

Your roadmap **re-baselines the current tree — HEAD of branch `ddt-capform` —
as v0.0.1**. Every release you plan, from v0.0.2 upward, is future work on the
existing code. Do not reconstruct history. Do not plan a rewrite
(`ARCHITECTURE.md §0` argues at length against one, and you must not contradict
it).

State the re-baseline explicitly in your document's first section, with the
reason: an untagged tree with 41 known failing fixtures and 463 uncovered
clauses is not a 0.9.

## 3. The reading list — read all of these before writing a line

In authority order. Where two disagree, the one higher in this list wins, and
you **note the conflict** rather than silently picking.

| # | Path | What it is | Authority |
|---|---|---|---|
| 1 | `PLAN.md` (16 KB) | The work plan. Written 2026-09-20, revised 2026-09-21. **Newest measurements in the repo** (§0). §1 buckets remaining work by shape and marks what parallelises. §5 is the single most important section in the repo for you — see §4 below. §6 is hard-won operational rules. | **Highest** for current state and near-term sequencing |
| 2 | `ARCHITECTURE.md` (31 KB, untracked) | Target architecture. §0 verdict (no rewrite). §1 answers the six DOD questions for the central transform. §2 the four placement axes. §3 target tree. §4 the traits. **§5 where SIMD actually is.** **§6 the 9-phase migration plan, phases 0–1 landed.** §7 deliberately-not-doing. §8 what landed and where the doc was wrong. | **Highest** for architecture; §6 is a ready-made release spine |
| 3 | `tests/fixtures/MANIFEST.md` (1036 lines) | Per-row defect register for the fixture suite. §4 per-row inventory, §5.1–5.8 the defect classes, **§6 implementation order**, §7 what the exercise does not establish. | Highest for fixture-level detail |
| 4 | `TODO.md` (21 KB) | Handoff document, 2026-09-20. §0 the four measures. §2 is *expensive knowledge* — how to run a fixture, the fixture header convention, the two traps, five architecture findings. §3.6 known-stale docs. **§4 ground rules.** | High for §2 and §4; **§1 and §3.1 measurements are SUPERSEDED by PLAN.md** |
| 5 | `git show 55e5117:docs/CLAUSE-AUDIT.md` | **685 lines. THIS FILE IS DELETED FROM THE WORKING TREE** (removed in `2cc1c08`) but is cited as the source of the two largest scope numbers in the project. Recover it with `git show`. §4 the 119 inherited IEEE 1364 §§17–18 obligations. §5 the obligation-kind taxonomy (mandatory / optional / implementation-defined / resource-limit / unspecified / non-normative) — **this taxonomy is how you define "100%"**. §6 the rejection-fixture audit. §7 the tally and worklist. | Highest for defining conformance; **flag its absence as a work item** |
| 6 | `build.zig:1-100` | Module graph, enforced dependency order, why there is one suite step. | Authoritative for gates |
| 7 | `ref/SIMD-Strategies/` | `01-techniques.md`, `02-zig-simd-api.md`, `03-gotchas.md`, `verify.zig`. The project's own SIMD reference. | Reference |
| 8 | `.claude/skills/simd-first/SKILL.md` | The project-local SIMD skill `ARCHITECTURE.md §5` is applying. | Reference |
| 9 | `docs/*.html` + `docs/VAMS-LRM-2023.pdf` | The LRM. 20 chapter/annex HTML files. | Normative |
| 10 | `tests/fixtures/*/COVERAGE.md` (one per chapter) and `*_SPEC.md` | Per-chapter coverage claims. **`TODO.md §3.6` says several of these carry stale counts.** | Low — treat as claims, not facts |
| 11 | `ARPice/docs/verilog-ams-conformance-plan.md` | Row-ID vocabulary only. Out of scope for scheduling. | Vocabulary |

Also skim, to ground the architecture releases in real file sizes:
`lib/ir/lower.zig` (12093 lines), `lib/backend/codegen.zig` (12176),
`lib/frontend/parser.zig` (5942), `lib/diag_code.zig` (4974),
`lib/frontend/preprocessor.zig` (4057), `src/sim/digital.zig` (3655),
`lib/ir/elaborate.zig` (3048), `lib/backend/tb.zig` (2565),
`lib/ir/proof.zig` (2541), `lib/diag.zig` (2218).

## 4. The four measures — the heart of the deliverable

`TODO.md §0` and `PLAN.md §5` both make the same point and it is the one thing
a weak plan gets wrong: **"0 FAIL" is not "100% conformant."** There are four
independent measures and none reduces to another. Your roadmap must track all
four separately, and every release must state what it moves on each.

| Measure | Last stated | Source |
|---|---|---|
| **A. Fixture suite green** — `benchmark --strict` | 1489 pass / 41 FAIL / 28 XFAIL of 1558 | `PLAN.md §0`, 2026-09-21 |
| **B. Inherited IEEE 1364 obligations** | 83 of 119 open (63 missing + 11 partial + 9 implemented-without-evidence); only 30 `verified` | `CLAUSE-AUDIT.md §7.1` via `TODO.md §0` |
| **C. AMS clauses with two-way evidence** | 463 of 611 have one-way evidence only (208 accepted-only, 99 refused-only, 156 uncited); only ~148 support a `verified` verdict | `CLAUSE-AUDIT.md §7.2` via `TODO.md §0` and `PLAN.md §5` |
| **D. Architecture migration** | phases 0–1 of 9 landed; 2–8 remain | `ARCHITECTURE.md §6`, §8 |

Three rules that fall out of this, and that your roadmap must encode:

- **A rejection fixture is not positive coverage** (`TODO.md §4` rule 4). 463
  of the existing fixtures assert a refusal. Closing measure C is a *separate
  program of writing positive fixtures for rules that already work* — it is
  not feature work, nobody is doing it, and it is the larger half.
- **Compiler acceptance is not runtime evidence** (`TODO.md §4` rule 5). Each
  obligation needs a positive behavioural test, an invalid-input test, and a
  recorded result. "It compiles" is the weakest of the three.
- **XFAILs are honest markers and must be implemented, not deleted**
  (`PLAN.md §5`). The harness fails on XPASS specifically so nobody can delete
  a marker without closing its gap.

Define v1.0.0 against `CLAUSE-AUDIT.md §5`'s obligation taxonomy, not against
"all tests pass." An implementation-defined behaviour needs *a document and a
test*. A resource limit must be *stated and must fail loudly*. An unspecified
behaviour must have *no test asserting one outcome*. Say so in your definition.

## 5. Conflicting numbers you will hit — reconcile, do not average

These are real inconsistencies in the sources. Your roadmap resolves each
explicitly, or lists it as an open question.

- `zig build test` is reported as **113/113** (`PLAN.md §0`), **104/104**
  (`TODO.md §1`), **404/404** (`TODO.md §2.3` and §4), and **561 in-file
  tests** / **514 tests** (`ARCHITECTURE.md §0`, §8). These are **different
  counters** — build steps vs. test units vs. in-file test blocks vs. a
  post-phase-1 count. Do not conflate them. Say which counter you mean.
- `benchmark --strict` gate is **1489/1558** (`PLAN.md §0`), **1390/1557**
  (`TODO.md §1`), and **1323/1323** (`TODO.md §2.3`). The 1323 predates the
  `tests/pending` merge. PLAN.md wins.
- `test-devices` is **47/66** (`PLAN.md §0`) and **5/66** (`TODO.md §1`).
  PLAN.md wins.
- Tree size: `ARCHITECTURE.md §0` says 71k lines (64.5k `lib/` + 6.4k `src/`);
  the tree now measures ~67.0k `lib/` + 6.7k `src/`. The doc predates the
  current HEAD. Note it; do not build a plan on either figure.
- `TODO.md §3.6` lists four documents already known stale, including
  `docs/CONFORMANCE-GAPS.md` (which, like `CLAUSE-AUDIT.md`, **no longer
  exists in the working tree**).

## 6. The two work axes

Your release sequence must interleave two independent streams. Say which
stream each release belongs to.

### Axis 1 — conformance (measures A, B, C)

Sequenced in `PLAN.md §1` and `§3`, and `MANIFEST.md §6`. The shape as last
stated:

- **ch07 mixed-signal: 46 rows (33 FAIL + 13 XFAIL). Explicitly NOT
  parallelisable** — `PLAN.md §3` calls it one sequential program with a step
  order in `§3` "The step order". It is the single largest bucket and it gates
  M03/M04.
- digital `.v` — 19 rows (d08 UDPs/switches, m04 `wreal`, d10_11). Parallel.
- XFAIL outside ch07 — 14 rows. Parallel.
- 8 named stragglers, each with its diagnosis already recorded in `PLAN.md §1`
  (ch03 nodeset, ch04 §3.2 array dims, ch05 node alias, ch06 string parameter,
  ch09 eager `readTableFile`, the `s01_05`/`s01_06` pair which has **two**
  blockers and must land together, digital `d04_15`).
- 33 `.c` VPI fixtures + `.sp` decks — **unmeasured; needs runners before it
  needs fixes** (`PLAN.md §1`, `§2` "What the `runners` agent is actually for").
- Three confirmed unfixed defects in `TODO.md §3.7`: the §4.6.4.6 per-use noise
  coefficient (silent wrong answer, the fix's exact shape is specified there —
  `coeff` on `PsdTerm` not `NoiseGen`, signed, a ∂/∂n walk over the built MIR),
  the §4.6.4.3 table inputs refused as E0519, and the two dead exports.
- Fixture-quality debt: `MANIFEST.md §5` — 3 rows clean, 23 partial, and
  `§5.8` carries fixer-vs-reviewer disagreements that **need a human call, not
  another agent pass**. Schedule that as a human decision, not a task.

### Axis 2 — architecture (measure D)

`ARCHITECTURE.md §6` is already a 9-phase plan with per-phase risk, and phases
0 and 1 have landed. **Map phases 2–8 onto releases; do not re-derive them.**
Preserve its properties verbatim:

- The invariant at every phase boundary: `zig build test`, `zig build
  test-devices`, **and every fixture producing a BYTE-IDENTICAL `device.zig`
  before and after**. The harness exists: `tools/golden-baseline.sh <tag>`,
  ~25s for the whole suite, verified deterministic, `diff -r` between two tags
  is the gate. It is a shell script rather than a build step **on purpose** —
  the build graph cannot see fixture contents and would cache a pass for a
  golden nobody compared.
- One phase = one branch = one PR. Never two phases in flight in `lib/`.
- Phase 8 (`src/sim/digital/` split) is disjoint and may run concurrently.
- A phase that cannot keep goldens byte-identical **stops and gets re-scoped**.
- No behaviour changes inside a phase. Ever.
- **Every phase is independently shippable and independently revertible** —
  this property is why phases 1 and 2 come first, and your release boundaries
  must not break it.
- `ARCHITECTURE.md §8` warns that **both of the document's own line-count
  estimates were too optimistic** and instructs you to treat every remaining
  number in §6 as unverified. Carry that warning into your roadmap; do not
  present §6's line counts as sizing.

### SIMD — read §5 before writing a word about it

`ARCHITECTURE.md §5` is counterintuitive and a weak plan will get it backwards:

**The compiler is not a SIMD target.** Every backend walk is a chain
(dominator-tree walk, data-dependent output length, recursive SSA
construction). `lib/ir/proof.zig:202` contains a measurement table where a
`@Vector` attempt **loses** at every size up to 24578. `ARCHITECTURE.md §7`
lists "adding SIMD to the compiler" as deliberately-not-doing.

**SIMD-first applies to the emitted device, not to VerA.** The generated
`eval` is called millions of times inside a host Newton loop; `tb.zig:1394`'s
`@Vector(NL, f64)` is the real one. The lane-behaviour decisions — `pinLanes`,
`lane_pinned`, `lane_clean`, `jac_f32`, `cur_strict` — are currently five
fields scattered through a 91-field `Gen` struct, and gathering them into
`codegen/float/` is the justification for phase 5. Any "SIMD" release you plan
is about **the code VerA emits**, and about making the lane story readable in
one place.

The three existing `@Vector` uses in the compiler (`token.zig:532`,
`preprocessor.zig:1116`, `tb.zig:1394`) are the right three and are **not to be
touched**.

Likewise, keep the hardware knobs: `--unknown-bound=`, `--outline-chunk=N`,
`jac_f32`, the `abstol` table. `ARCHITECTURE.md §5` calls these physical-world
tuning that does not get simplified away.

## 7. Traps that produce a confidently wrong plan

Read `TODO.md §2.4` and `§2.5` and `PLAN.md §6` in full. The ones you must not
plan around:

- **A fixture a *conforming* implementation fails.** Four were found; assume
  more exist. The cheapest way to make one pass is to break the compiler. Four
  worked examples are in `TODO.md §2.4` (`$vt` vs. Annex D.2 constants,
  `absdelta`'s "more than", digital-context `integer` starting at **x** not 0,
  and "the second NBA cancels the first" — it does not, IEEE 1364 §9.2.2
  performs both). **Any release that "fixes failing fixtures" must first
  budget for auditing whether the fixture is right.**
- **A green signal that measures nothing.** A lazily-analysed Zig file is never
  type-checked; ARPice once reported 266/266 while a file did not compile
  because no root listed it.
- **`tb.zig`'s solver is a source template, not a function** (`tb.zig:1297` is
  a string literal). A coordinator in `src/sim/` cannot call it. This kills the
  cheapest imagined route to mixed-signal. `tb.zig:695` is a fixed-grid
  evaluator with no way to insert a solver-chosen timepoint, which makes
  several M01/M02 fixture rationales false. **Mixed-signal needs a new runner**
  — put it on the critical path for ch07.
- **`src/sim/scheduler.zig` is complete, unit-tested (six regions, future heap,
  cancellation, analog request coalescing) and has ZERO production callers.**
  Nothing in `src/` posts `.analog` or `.explicit_d2a`. Wiring it is work that
  looks done and is not.
- **All 13 `w2/*` branches are empty** — `git merge-tree` returns the base tree
  for every one. Nothing to merge, nothing to salvage, prune them. Do not plan
  around recovering them. (Note: `git branch -a` shows ~20 other branches; they
  are not `w2/*` and you should not assume anything about them.)
- `PLAN.md §6`'s operational rules are load-bearing if this roadmap is ever
  executed by parallel agents: one worktree per agent, stage by explicit path
  (`git commit` commits the index and a docs commit once swept in unrelated
  deletions), **diff FAIL name lists not counts**, budget ~12 GB `.zig-cache`
  per concurrent agent, and regenerate — never resolve — size-golden conflicts.

## 8. Output format

Write `/home/omare/Documents/Projects/Zig/VerA/ROADMAP.md` with exactly these
sections, in this order:

1. **`## 0. The re-baseline`** — why HEAD of `ddt-capform` is v0.0.1, not
   0.9.0. Two paragraphs maximum.
2. **`## 1. What v1.0.0 means`** — the definition of done, written against the
   four measures of §4 and `CLAUSE-AUDIT.md §5`'s obligation taxonomy. This
   section must be falsifiable: a reader must be able to check whether v1.0.0
   has been reached.
3. **`## 2. Measured state as of v0.0.1`** — one table, four rows (A/B/C/D),
   each with the number, the source, and the as-of date. Plus a short
   subsection listing every conflicting number from §5 above and how you
   resolved it.
4. **`## 3. The release ladder`** — one table:

   | Version | Theme | Axis | Closes | Measures moved | Gate | Depends on |
   |---|---|---|---|---|---|---|

   Rules for this table:
   - **Semver, honestly.** Pre-1.0: a minor bump (0.N.0) is a release where
     the *shape* of what VerA accepts or emits changes; a patch bump (0.N.M)
     closes rows without changing shape. State your rule in one line before
     the table and then follow it.
   - Every row names its **gate** — the specific command whose exit code
     decides the release, from `build.zig`'s real steps (`test`,
     `test-<module>`, `test-devices`, `benchmark`, `run`) or
     `tools/golden-baseline.sh`. No invented steps.
   - Every row names what it **closes** by row ID or fixture bucket, traceable
     to `PLAN.md §1`, `MANIFEST.md §6`, or `ARCHITECTURE.md §6`.
   - **Architecture phases keep their byte-identity invariant.** A release
     containing an `ARCHITECTURE.md §6` phase has `golden-baseline diff -r
     clean` as its gate and closes zero conformance rows. Do not mix a
     refactor phase and a behaviour change into one release.
   - Mark parallelisable releases. `PLAN.md §1`'s table already says which
     buckets parallelise and which do not; ch07 does not.
5. **`## 4. Per-release detail`** — one subsection per version. Each states:
   scope, the sources it traces to (file + section), what it explicitly does
   *not* do, and its exit criterion. Keep each under 200 words. Cite; do not
   re-narrate the sources.
6. **`## 5. The long pole`** — measure C. 463 clauses needing positive
   fixtures, nobody assigned, measured in quarters. Be blunt about what it
   costs and why it cannot be parallelised naively (a fixture that a conforming
   implementation fails is worse than no fixture). Say where in the ladder it
   starts, because if it starts at 0.9 it will not finish.
7. **`## 6. Blocked on ARPice`** — the out-of-scope items (`u_nodeset`,
   `noise_tables`, and anything else you find), with what VerA must ship
   anyway.
8. **`## 7. Blocked on a human decision`** — `MANIFEST.md §5.8`'s disputes and
   anything else needing a call rather than an agent.
9. **`## Appendix: gaps I could not source`** — anything you believe is
   necessary but could not trace to a source line.
10. **`## Appendix: documents this roadmap depends on that do not exist`** —
    `docs/CLAUSE-AUDIT.md` (recoverable at `git show 55e5117:` , deleted in
    `2cc1c08`) and `docs/CONFORMANCE-GAPS.md`. Restoring or rebuilding
    `CLAUSE-AUDIT.md` should appear as a real task in the ladder, early —
    measures B and C are unverifiable without it.

Tone: match `PLAN.md` and `ARCHITECTURE.md`. Both are blunt, numeric, and
name the places their own previous version was wrong. Do not write marketing
prose. Do not use the word "robust". Do not pad with a risks-and-mitigations
table of generic risks — the specific traps in §7 above are the risks.

Length: as long as it needs to be and no longer. `PLAN.md` does its job in
16 KB.

## 9. Self-check before you finish

Confirm each of these in a short closing note to me (not in `ROADMAP.md`):

- [ ] Every number in `ROADMAP.md` carries a source and an as-of date.
- [ ] I ran no build, test, or binary.
- [ ] I created exactly one file and edited none.
- [ ] Every release row traces to `PLAN.md`, `TODO.md`, `MANIFEST.md`,
      `ARCHITECTURE.md`, or the recovered `CLAUSE-AUDIT.md`.
- [ ] I read `ARCHITECTURE.md §5` and my roadmap puts SIMD in the *emitted
      device*, not in the compiler.
- [ ] No release mixes an `ARCHITECTURE.md §6` refactor phase with a behaviour
      change.
- [ ] ch07 mixed-signal is scheduled as one sequential program, not fanned out.
- [ ] I did not propose a rewrite.
- [ ] All four measures (A/B/C/D) appear in the ladder, and measure C starts
      before v0.9.
- [ ] I listed every conflicting number I found and how I resolved it.
