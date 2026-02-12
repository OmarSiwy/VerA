# ROADMAP — v0.0.1 → v1.0.0

A release plan for VerA. Measured at `1789cb1` on 2026-09-21 by
`tools/conformance.sh`; the numbers below are that run's, and `CHANGELOG.md`
carries them per release from here on.

**How to read this.** §1 defines v1.0.0 as five checkable clauses. §2 says where
the project stands against them. §3 is the ladder — one row per release, each
with the command that decides it. §4 details each release. §5 is the work that
dominates everything else. §6–§7 are what this roadmap cannot schedule.
Appendix A records the number conflicts across the older documents and how each
was settled; it is evidence, not plan.

This document schedules work. It does not re-derive `ARCHITECTURE.md §6`'s
phases, `PLAN.md §1`'s buckets or `MANIFEST.md §6`'s order — it maps them onto
releases and names each one's gate.

---

## 0. The re-baseline

**HEAD of `ddt-capform` is v0.0.1.** `build.zig.zon` said `0.9.0`; that number
was aspirational and is overridden here. `git tag` returned zero tags across 323
commits since 2026-07-04 — nothing has ever been released, so no promise is
being broken.

Calling this tree 0.9 would mean carrying a number nothing measured. What is
actually true at the tag: **96.0% of fixtures behave as stated, and 32.0% of LRM
clauses carry evidence in both directions.** The second number is the one that
governs v1.0.0, and it is the reason 0.0.1 is the honest label.

Everything from v0.0.2 up is future work on this tree — not a reconstruction of
history, and not a rewrite. `ARCHITECTURE.md §0` argues against a rewrite and
this roadmap does not contradict it.

---

## 1. What v1.0.0 means

Five clauses, all true at one commit. Each is reproducible by a reader.

**A. The fixture suite is green over an honest denominator.**
`zig build benchmark -- --strict` reports **0 FAIL, 0 unasserted and 0 XFAIL**
over every fixture the tree contains. `zig build test` and
`zig build test-devices` exit 0, and so do the two steps v0.0.3 created —
**`test-vpi-fixtures` at 26/26 and `test-spice` at 7/7**, the latter still
proving only that the decks pair and compile, because executing one needs
ARPice (§6) and no release here can.

Zero XFAIL is a real obligation. The harness FAILs on XPASS precisely so a
marker cannot be deleted without its gap closing. A marker whose fixture turns
out to be one a *conforming* implementation fails is removed by correcting the
**fixture**, with the derivation recorded — never by loosening the compiler.

**B. Every inherited IEEE 1364 §§17–18 obligation is closed or classified.**
`CLAUSE-AUDIT.md §7.1`'s **127** rows reach 0 missing, 0 partial, 0
implemented-without-evidence. Each closed row carries a positive behavioural
test, an invalid-input test, and a recorded result. "It compiles" closes
nothing.

**127 and not 119**, since v0.0.2 re-derived the section at HEAD. The old 119
was not reproducible from the document's own table, which gave three different
totals; §7.1 now states the denominator, shows the per-section arithmetic, and
`tools/measure-b.sh` fails if it stops summing.

**C. Every LRM clause carries two-way evidence.**
All 612 clauses `zig build benchmark -- --coverage` finds in `docs/` are either
**tested both ways** — a positive fixture that compiles, runs and asserts, *and*
a `//! reject` that pins the prohibition — or explicitly classified under
`CLAUSE-AUDIT.md §5` as optional, implementation-defined, a resource limit,
unspecified, or non-normative. The three one-way buckets reach zero.

A rejection fixture is not positive coverage of the rule it refuses. This is
measure C's whole point and it is the largest single body of work in this plan.

**D. All nine `ARCHITECTURE.md §6` phases are landed.** Phases 0–1 are in.
Phases 2–8 each ship as their own branch and PR with byte-identical goldens.

**E. The non-mandatory classes carry what they require**, per
`CLAUSE-AUDIT.md §5`:

- every **implementation-defined** choice has *a document and a test* — §5.3
  lists six and notes there is no single published list of them;
- every **resource limit** is *stated and fails loudly*. The RNG row is the
  template: a named diagnostic, never silent truncation. §5.4, re-derived
  2026-09-21, marks **three** rows untested — the 30-channel mcd limit,
  descriptor-table scope, and a newly-enumerated 4096-byte scan white-space
  window. The two buffer rows moved 512 → **4096** and `s01_13` now pins a long
  record through both, though not the bound itself;
- every **unspecified** behaviour has *no test asserting one outcome* — §5.5's
  four rows, including digital race outcomes and `$ferror`'s errno.

**F. The binary ships for every supported target.** `publish.yaml` builds
`x86_64-linux`, `aarch64-linux`, `x86_64-macos` and `aarch64-macos` by
cross-compilation today. **`x86_64-windows` does not compile**: `src/main.zig`'s
argument loop calls `init.minimal.args.iterate()`, which Zig 0.16 refuses on
Windows in favour of `initAllocator` (verified 2026-09-21). It is one call site
and it is the only known portability defect. Fixing it is a CLI behaviour change
and belongs in its own release — scheduled at **v0.1.0**, which is already a
minor and already touches nothing else in `src/main.zig`.

**Explicitly not required.** SystemVerilog. IEEE 1364 Annex C additional
utilities. A Verilog-A-only subset mode — Annex C is a subset definition for
tools that choose it, and VerA does not. Any ARPice change (§6). Conformance
claims for a simulator VerA does not ship.

---

## 2. Measured state at v0.0.1

Measures A and C are **current**, taken at `1789cb1` on 2026-09-21. Measures B
and D are hand-read from documents and carry their own dates.

| | Measure | At v0.0.1 | Remaining | Source |
|---|---|---|---|---|
| **A** | Fixtures behaving as stated | **1495 / 1558 — 96.0%** (35 FAIL, 0 unasserted, 28 XFAIL) | 63 rows | `benchmark -- --strict`, 2026-09-21 |
| **B** | Inherited IEEE 1364 obligations closed | ~~36 / 119~~ → **30 / 127** (97 open: 65 missing, 20 partial, 10 without evidence, 2 untested resource limits; 27 `verified`) | 97 rows | `CLAUSE-AUDIT.md §7.1`, **re-derived 2026-09-21** |
| **C** | Clauses with two-way evidence | **196 / 612 — 32.0%** (257 accepted-only, 76 refused-only, 83 uncited) | 416 clauses | `benchmark -- --coverage`, 2026-09-21 |
| **D** | `ARCHITECTURE.md §6` phases landed | **2 / 9** (phases 0–1) | 7 phases | `ARCHITECTURE.md §8`, 2026-09-20 |

Supporting counters:

| Counter | Number | As of |
|---|---|---|
| `zig build test` | pass | 2026-09-21 |
| `zig build test-devices` | **FAIL** | 2026-09-21 |
| Fixtures citing an LRM clause | 1488 of 1558 | 2026-09-21 |
| Fixture census `.va` / `.v` / `.c` / `.sp` / `.vh` | 1558 / 81 / 26 / 7 / 4 | 2026-09-21 |
| Measure A denominator after v0.0.3 widened the walk | **1570** (1558 `.va` + 12 `.v`) | 2026-09-21 |
| `test-vpi-fixtures` · `test-spice` | **13/26** · **7/7** | 2026-09-21 |
| Tree size `lib/` / `src/` | 66 995 / 6 693 lines | 2026-09-21 |
| Commits on this branch, none tagged | 323, since 2026-07-04 | 2026-09-21 |
| ARPice circuit suite | 518/616, **not a gate** | `TODO.md §1`, 2026-09-20 |

**Measure C's numbers moved, and the older documents are wrong about them.**
`CLAUSE-AUDIT.md` recorded 611 clauses split 148 / 208 / 99 / 156 on 2026-09-16
against a 1301-fixture tree. The tree is now 1558 fixtures and the run above
measures 612 clauses split **196 / 257 / 76 / 83**. Two-way evidence is up 48
clauses; accepted-only grew and uncited nearly halved. Every downstream count in
`PLAN.md §5` and `TODO.md §0` — including the widely quoted "463" — is stale.
The remaining figure is **416**.

Where §3 and §4 cite a document without a date: `PLAN.md` 2026-09-21,
`TODO.md` 2026-09-20, `MANIFEST.md` 2026-09-20, `ARCHITECTURE.md` 2026-09-20,
`CLAUSE-AUDIT.md` 2026-09-16 (recovered from `55e5117`).

Number conflicts across those documents are settled in **Appendix A**.

---

## 3. The release ladder

**The semver rule.** A **minor** (`0.N.0`) changes something a consumer can
observe: source VerA newly accepts or refuses, device text it emits, or a row in
`build.zig`'s `module_specs` — the embedder's contract. A **patch** (`0.N.M`)
closes rows without changing any of those. Consequence, deliberate: every
`ARCHITECTURE.md §6` refactor phase is a patch, because it is byte-identical by
construction, and most conformance releases are minors.

**Every release is a published tag.** `tools/conformance.sh --changelog vX.Y.Z`
writes the entry by running the suites; `.github/workflows/publish.yaml`
re-measures on a clean runner and refuses to publish an entry that disagrees
with the tree. See `AGENTS.md §3`.

`∥` marks releases that may run concurrently. Axis **A** is conformance
(measures A, B, C); axis **D** is architecture (one `ARCHITECTURE.md §6` phase).

| Version | Theme | Axis | Closes | Moves | Gate | After |
|---|---|---|---|---|---|---|
| **v0.0.1** | Re-baseline: tag HEAD, publish the measured state | — | nothing | records A/B/C/D | all four suites + `golden-baseline.sh v0.0.1` | — |
| **v0.0.2** | Restore `docs/CLAUSE-AUDIT.md`; re-derive B at HEAD | A | the file's absence; `TODO.md §3.6`'s stale list | B: *unverifiable* → *stated* | `zig build test` | v0.0.1 |
| **v0.0.3** | `runners`: the 26 `.c` and 7 `.sp` fixtures become visible | A | `PLAN.md §1`'s 33-row bucket; `MANIFEST.md §7.5` | A's **denominator**, not its numerator | the two runner steps this release creates | v0.0.1 · ∥ v0.0.2 |
| **v0.1.0** | Axis-A singletons: the stragglers, plus 14 XFAILs outside ch07; **and the Windows port** | A | `PLAN.md §1`, both buckets; §1 clause F | A | `--strict`, diffing the **FAIL name list**; `-Dtarget=x86_64-windows` builds | v0.0.1 · ∥ v0.1.1 |
| **v0.1.1** | Analog rows blocked on nothing: A01–A04, H01, then A05 | A | `MANIFEST.md §6` Phase 1; `TODO.md §3.2` | A | `--strict` | v0.0.1 · ∥ v0.2.0 |
| **v0.2.0** | The digital chain opens: D02, D03, D06, D08, D10 | A | `MANIFEST.md §6` Phase 2, first half | A, B | `zig build test-devices` | v0.0.2 · ∥ v0.0.3, v0.1.1 |
| **v0.2.1** | **Measure C opens**: the 76 refused-only clauses | A | 76 of 416 | C | `--coverage` | v0.0.1 |
| **v0.3.0** | ch07 steps 1–2: the three tokens, then ports + an analog block | A | `PLAN.md §3` steps 1–2; `m01_90`, `m01_91` | A | `--strict` | v0.2.0 |
| **v0.3.1** | §6 phase 2 — pure extractions | D | phase 2. **Zero conformance rows** | D: 3/9 | goldens `diff -r` clean, then `test` + `test-devices` | v0.0.1 · ∥ all of axis A |
| **v0.4.0** | The mixed-signal runner, then ch07 steps 3–5 | A | `PLAN.md §3` steps 3–5 | A | `--strict` | v0.3.0 |
| **v0.4.1** | §6 phase 3 — the cut-only splits | D | phase 3. **Zero conformance rows** | D: 4/9 | goldens `diff -r` clean | v0.3.1 |
| **v0.5.0** | ch07 steps 6–7: `absdelta` interpolation, §8.4.2 DC iteration | A | `PLAN.md §3` steps 6–7 | A: the largest bucket | `--strict` | v0.4.0 |
| **v0.5.1** | The three confirmed defects, and the `s01_05`/`s01_06` pair | A | `TODO.md §3.7` | A, B | `--strict` | v0.0.2 · ∥ v0.5.0 |
| **v0.6.0** | M03: §7.8 connectmodule insertion | A | the 13 `m03_*` XFAILs | A | `--strict` | v0.5.0 |
| **v0.6.1** | §6 phase 4 — `codegen/plan/` | D | phase 4. **Zero conformance rows** | D: 5/9 | goldens `diff -r` clean | v0.4.1 |
| **v0.6.2** | **Measure C, the bulk**: the 257 accepted-only clauses | A | 257 of 416 | C | `--coverage` | v0.2.1 · ∥ all of axis D |
| **v0.7.0** | §6 phase 5 — `codegen/{emit,float,events,feat}/`; the lane story | D | phase 5; `§5` | D: 6/9 | goldens `diff -r` clean | v0.6.1 |
| **v0.7.1** | §6 phase 8 — `src/sim/digital/` split | D | phase 8. **Zero conformance rows** | D: 7/9 | goldens clean + `test-devices` | v0.6.1 · ∥ v0.6.2–v0.7.0 |
| **v0.8.0** | Digital procedural: D04/D05, then D09's §17.1–§17.2 surface | A | `MANIFEST.md §6` Phase 2, second half | A, B | `zig build test-devices` | v0.2.0 · ∥ axis D |
| **v0.8.1** | §18 VCD — the 22 missing rows | A | `CLAUSE-AUDIT.md §4.4` | B | `zig build test-devices` | v0.8.0 |
| **v0.8.2** | §6 phase 6 — `ir/lower/` split, `Lowered` as an output type | D | phase 6. **Zero conformance rows** | D: 8/9 | goldens `diff -r` clean | v0.7.0 |
| **v0.8.3** | §6 phase 7 — the boilerplate | D | phase 7. **Zero conformance rows** | D: 9/9 | goldens `diff -r` clean | v0.8.2 |
| **v0.9.0** | VPI: P02 then P03 | A | `MANIFEST.md` P02/P03 | A: the 26 `.c` fixtures; B | `test-vpi`, `test-vpi-fixtures` at 26/26, then a step that RUNS them | v0.0.3 · ∥ axis D |
| **v0.9.1** | **Measure C, the tail**: the 83 uncited clauses | A | 83 of 416 | C: 416 → 0 | `--coverage` | v0.6.2 · ∥ axis D |
| **v0.9.2** | The published implementation-defined list; the stated resource limits | A | `CLAUSE-AUDIT.md §5.3`, `§5.4` | B, and §1 clause E | `test` + `--strict` | v0.0.2 · ∥ axis D |
| **v1.0.0** | The conformance statement | — | nothing new — it *asserts* | A/B/C/D | every `build.zig` step green + the statement published | all of the above |

**Rules the table's shape enforces:**

- 26 releases: **17 on axis A, 7 on axis D**, two neither. All 7 D releases close
  **zero** conformance rows by construction. A release that wants to do both is
  two releases.
- `v0.7.1` (phase 8) touches `src/sim/digital/` only and is on no critical path.
  It is numbered for convenience and may be pulled forward the moment `v0.6.1`
  lands.
- `v0.9.x` is where the two streams converge and is therefore the least reliable
  part of the schedule. Everything before it is ordered by dependency;
  everything in it is ordered by what is left.

---

## 4. Per-release detail

### v0.0.1 — The re-baseline
**Scope.** Tag HEAD and publish the four measures. **Done for A and C** — they
are `CHANGELOG.md`'s v0.0.1 entry, measured by `tools/conformance.sh`. Take the
FAIL and XFAIL **name lists** as artifacts alongside the counts: a bucket that
does not sum is a bucket nobody will notice losing a row (Appendix A item 7).
**Does not do.** No code, no fixture, no `build.zig.zon` version bump.
**Exit.** The tag exists, `publish.yaml` has published it, and `CHANGELOG.md`
carries numbers a reader can reproduce.

### v0.0.2 — Restore the clause audit
**Scope.** Recover `docs/CLAUSE-AUDIT.md` (`git show
55e5117:docs/CLAUSE-AUDIT.md`, 685 lines, deleted in `2cc1c08`) and commit it.
Then reconcile it: §2 above already shows its clause split is wrong by 48
clauses against the current tree, so **re-derive §7.1's 119 obligation rows at
HEAD** — that is the half `--coverage` cannot answer and the only thing blocking
measure B. Walk its §7.3 worklist, which is cheap and mostly documentation.
Record whether `docs/CONFORMANCE-GAPS.md` is rebuilt or retired.
**Does not do.** No compiler change.
**Exit.** The file is tracked, §7.1 is re-derived at HEAD, and B has a number a
reader can check.

### v0.0.3 — `runners`
**Scope.** Wire the 26 `.c` VPI fixtures and the 7 `.sp` decks into build steps.
The `.sp` seven are foreign-simulator decks — `.hdl` plus instance cards plus
`.tran`/`.noise`, paired with an `.expected.json` — with no `.va` under
compilation and no `ok=` assertions, so this is `tests/harness.zig` work, not a
CLI flag. Widen `harness.zig`'s filter past `.va` so the `.v` reject fixtures are
read at all.
**Does not do.** Does not fix any of them. This makes them *visible*; whether
they pass is a later release's problem.
**Exit.** Both steps run and measure A reports over an honest denominator.

**Landed 2026-09-21.** Three steps, not two, and the shape differs from the plan
above in ways worth recording:

| | Result | Step |
|---|---|---|
| `.v` | **12 of 81** joined measure A — denominator **1558 → 1570**, 2 pass, 10 FAIL. 66 stay `test-devices`' (they have an `.expected.txt`); 3 are VPI support material with no directive | `benchmark -- --strict` |
| `.c` | **13 of 26 compile** against the shipped `src/vpi/vpi_user.h`. Split exactly by group: all 13 p03 compile against their own header, all 13 p02 fail because the shipped header has the eleven P01 object-model routines and none of §12.16's value access or §12.20's callbacks | **`test-vpi-fixtures`** (new) |
| `.sp` | **7 of 7** are paired with an oracle and name models that compile. **Not executed** — a deck needs a circuit simulator to link the device and turn the Newton loop, and that is ARPice (§6), so no release *here* can run one | **`test-spice`** (new) |

Three findings the wiring produced, all recorded in `CLAUSE-AUDIT.md §7.3`:

- **`harness.zig`'s seven unit tests had never run.** Zig collects `test` blocks
  from a test artifact's root and from what those tests reference; a plain
  `@import` is not enough. `zig build test` ran 4, all `bench.zig`'s. The dead
  ones include the assertion lint `build.zig` calls "what stops a fixture from
  asserting nothing while looking like it does". Now 16, all green.
- **Eight of the ten new `.v` FAILs are a directive-vocabulary gap, not a
  conformance verdict** — six cite the *inherited* standard, which `validSection`
  has no spelling for, and two use `//! expect vcd`, which nothing interprets.
  That gap is why nobody noticed the files were unread (item 14).
- **Every `.sp` deck's `.hdl` reference is dangling**: the `.assets/`
  subdirectories were flattened into slug filenames and the decks were not
  updated (item 15). `test-spice` resolves it with a fallback rather than
  renaming six fixtures on a guess.

**Deferred, deliberately.** Linking or running the `.c` fixtures needs a
simulator host per design and the routines themselves — P02 and P03, v0.9.0.
Extending the directive language to say "inherited clause" is a change to that
language and is not a runner.

### v0.1.0 — The axis-A singletons
**Scope.** `PLAN.md §1`'s stragglers plus the 14 XFAILs outside ch07 (ch09 4,
ch04 3, ch08 2, ch05 2, ch06 1, annex A 1, annex E 1). **Take the list from
v0.0.1's measurement, not from `PLAN.md §1`** — `1789cb1` already landed four of
the eight it names, and a straggler list is exactly the kind of count that stays
still while its membership changes. The XFAIL set is 14 separate gap
implementations, not a chore: the harness FAILs on XPASS, so a marker comes off
only when the rule it names is implemented.
Also **the Windows port** (§1 clause F): `src/main.zig:173`'s
`init.minimal.args.iterate()` becomes the `initAllocator` form. One call site,
but it is a CLI behaviour change and the argument loop is where
`--emit-exe --display=drop` once silently built a testbench with every model
print dropped and exited 0 — so it lands as its own commit with its own check,
not folded into a fixture fix.
**Does not do.** Does not touch ch07. Does not change a fixture whose
expectation is wrong without first establishing that.
**Exit.** The FAIL and XFAIL **name lists** shrink by exactly the named rows and
nothing new enters either, and `zig build -Dtarget=x86_64-windows` succeeds.

### v0.1.1 — The analog rows blocked on nothing
**Scope.** `MANIFEST.md §6` Phase 1 — A01, A02, A03, A04, H01, each of which
"runs against HEAD today with the documented CLI" — then A05 once `E0815` and
the eager `readTableFile` lift.

**A05 is not a cold start.** `TODO.md §3.2` records uncommitted work in
`lib/backend/table_kernels.zig` and `lib/ir/lower.zig` implementing quadratic and
cubic splines with natural and clamped boundary conditions, taking A05 from 2/13
to 12/13 compiling. Finish and commit that rather than starting over. Read
§9.21.2 before choosing a spline — several cubics are defensible and only one is
correct here. Keep `table_kernels.zig` `@embedFile`d verbatim into every device
so the numerics tested are the numerics that run. `zTabRes` must keep producing
an analytic gradient: a table on a probe is a function of a solver unknown, and a
bare value tells the solver the table is flat and costs it the Newton step.
**Does not do.** Does not convert `readTableFile` halfway — §9.21 wants loading
at the first *executed* call, which is a larger change.
**Exit.** `--strict`; A01–A05 and H01 reach their rows' "nothing blocking" state.

### v0.2.0 — The digital chain opens
**Scope.** `MANIFEST.md §6` Phase 2's first half, in its stated order: D02
selects (`grep partSelect src/` is empty — nothing exists), D03 strengths (lexer,
parser, and the `(strength0, strength1)` fold), D06 delays, D08 gates/UDPs/
MOS-CMOS switches, D10 directives (one string in `predefined_macros`).
`$display`'s radix family belongs here and is the narrowest real defect in the
set: §9.4.3 Table 9-22 defines `%h/%d/%o/%b`, ten fixtures sit behind it, and
`d09_01_display_radix.expected.txt` is already hand-derived.
**Does not do.** No D04/D05 — that is v0.8.0. No `wreal` beyond the port/net type
M04 needs.
**Exit.** `test-devices` passes the rows it now reaches; `--strict` shows no
regression.

### v0.2.1 — Measure C opens
**Scope.** The **76 refused-only** clauses. For each, write the *positive*
fixture: a legal source exercising the rule, asserting the behaviour the clause
fixes, with the expected value hand-derived from the clause text in the header.
`CHECKEQ` is the tool where the LRM states an identity rather than digits.
These are first because they are cheapest — the compiler already refuses the
illegal half, so the subject matter is implemented and only the evidence is
missing.
**Does not do.** Does not re-open the rejection fixtures. Does not convert a
refusal into an acceptance.
**Exit.** `--coverage` reports refused-only at 0, and every new fixture's header
names its clause and its derivation.

### v0.3.0 — ch07 steps 1–2
**Scope.** Step 1 is not a grammar production: `parseDiscrete` already builds the
`Ast.DiscreteBlock` and the `E0205` beside it is `reportItem`, the *non-fatal*
spelling. `#` delay and `assign` as module items are the genuine missing
productions. Copy the pattern `xfail-annexa` established in `f4f76fd`: parse the
construct in full, then refuse it **by clause** rather than at a token — opening
the gate without an executor turns "refused" into "compiled, and the block
silently did nothing", which is worse. `m01_90` and `m01_91` need no runner and
flip here.
**Does not do.** No runner, no coordinator, no scheduler wiring. Step 2 — a
digital engine accepting ports and an analog block — belongs to v0.4.0 *with* the
runner, because a module with an analog block nobody ticks is the same
silent-nothing failure.
**Exit.** `--strict`; `m01_90` and `m01_91` pass.

### v0.3.1 — `ARCHITECTURE.md §6` phase 2
**Scope.** Pure extractions: `sema/constfold.zig`, `sema/discipline.zig`,
`proof/domain.zig`, `proof/interval.zig`. ~1.6k lines moved, each unit-testable
the day it lands. `module_specs` gains `sema` and `analysis` between `frontend`
and `codegen`, which is why this one is a minor and phases 3–8 are patches.
**Does not do.** No behaviour change, no bug fix, no "while I'm here" — those are
separate commits before or after, never inside.
**Exit.** `tools/golden-baseline.sh` `diff -r` clean against v0.0.1's snapshot,
plus `test` and `test-devices` green. **A phase that cannot keep goldens
byte-identical stops and gets re-scoped.**

### v0.4.0 — The runner, then ch07 steps 3–5
**Scope.** The runner first, because it gates everything after step 2. Two facts
make it a design task and not a wiring job: `tb.zig`'s solver is a source
*template* — a Zig string literal emitted into each generated testbench, which a
coordinator in `src/sim/` cannot call — and `tb.zig`'s evaluator is a fixed grid
over the declared `//! time` points with no mechanism to insert a solver-chosen
timepoint. That second fact is why several m01/m02 fixture rationales assuming
mid-step observation are false today.

Then step 2 (`digital.zig` accepting ports and an analog block), step 3 (A2D
delivery: cross → digital tick, §8.4.3.3 half-precision-base rounding → m02
04/08/11), step 4 (implicit D2A + region 3b → 02/10/12), step 5 (explicit D2A +
region 1b → 03/05/06/09).
**Does not do.** Does not assume the scheduler's `.analog` region is wired.
`src/sim/scheduler.zig` is complete and unit-tested with **zero production
callers** for the mixed-signal regions — nothing posts to it, and wiring it is
work that looks done and is not.
**Exit.** `--strict`; the named m01/m02 rows flip.

### v0.4.1 — `ARCHITECTURE.md §6` phase 3
**Scope.** `diag/` and `frontend/` splits, `pp/annex_d.zig`, kernel blobs to
`@embedFile`. Cut-only, ~12k lines moved verbatim. Tests move with the code they
test, in the same commit — a split that leaves tests behind is how coverage
silently drops.
**Does not do.** No edits to the moved text.
**Exit.** Goldens `diff -r` clean.

### v0.5.0 — ch07 steps 6–7
**Scope.** Step 6, `absdelta` interpolation → m02 13. Step 7, §8.4.2 DC iteration
→ m01 01. This is where the largest FAIL bucket reaches zero.
**Does not do.** Does not touch the 13 `m03_*` XFAILs — those need §7.8 insertion
and are v0.6.0.
**Exit.** `--strict`: ch07's FAIL count is 0.

### v0.5.1 — The three confirmed defects, and the `s01_05`/`s01_06` pair
**Scope.** `TODO.md §3.7`'s three:

- **§4.6.4.6's per-use noise coefficient.** VerA exports `white = pwr` where the
  clause wants `c1²·pwr`, so a host computes output noise low by `c1²` — a factor
  of 4 and 9 in `a06_noise_correlated_scale.va`, and the error is **silent**.
  `coeff` belongs on **`PsdTerm`, not `NoiseGen`**, because the coefficient may
  depend on bias. It is **signed** — the sign is the entire difference between
  correlation and anti-correlation, and only the host squares it. It is computed
  by a ∂/∂n walk over the already-built MIR DAG (`Mir.valueDef`/`instData`), not
  a second lowering: the noise source must enter linearly, so the walk needs only
  fadd/fsub/fneg/fmul/fdiv and refuses anything making `n` nonlinear.
- **§4.6.4.3's two non-vector table inputs**, refused as E0519.
- **`s01_05`/`s01_06`'s two blockers** — §9.4.1 change detection implemented
  nowhere, and a §9.5 call rendering as the literal `0` outside the display unit,
  so `fd` is 0 in the core and `$ftell(fd)` is `$ftell(0)`. **They land together;
  fixing either alone flips neither row.**

**Does not do.** Does not touch the two dead exports — those are host features,
§6 below.
**Exit.** `--strict`; `a06_noise_correlated_scale.va` loses its `//! xfail`.

### v0.6.0 — M03
**Scope.** §7.8's connectmodule insertion phase, which `elaborate.zig` documents
as absent, plus §7.8.5 generated names as defparam targets.
**Does not do.** Does not assume module instantiation is the blocker — fixture 10
already elaborates a two-instance hierarchy and solves.
**Exit.** The 13 `m03_*` XFAILs lose their markers.

### v0.6.1 — `ARCHITECTURE.md §6` phase 4
**Scope.** `codegen/plan/` — hoist, outline and common extracted as pure
functions. `Gen` 91 → ~55 fields. Before `emit/`, so emission has a `Plan` to
read.
**Does not do.** Phase 5. One phase = one branch = one PR; never two in flight in
`lib/`.
**Exit.** Goldens `diff -r` clean.

### v0.6.2 — Measure C, the bulk
**Scope.** The **257 accepted-only** clauses — the largest single item in this
roadmap. Same shape as v0.2.1 with the opposite gap: something already accepts
the construct and nothing pins what it rules out, so each needs the *negative*
half written, with its rejection narrowed to a **named diagnostic**. A bare
`//! reject` matches any diagnostic, which `torture.zig`'s `failureContains`
makes exact.
**Does not do.** Does not add a rejection fixture that pins VerA's ceiling rather
than the LRM's prohibition — those are different rows. A clause that states no
error has nothing to reject and belongs in §5's classified set instead.
**Exit.** `--coverage` reports accepted-only at 0 or classified.

### v0.7.0 — `ARCHITECTURE.md §6` phase 5
**Scope.** `codegen/{emit,float,events,feat}/`. The one architecture release with
a user-visible justification: the decisions governing the emitted device's lane
behaviour — `pinLanes`, `lane_pinned`, `lane_clean`, `jac_f32`, `cur_strict` —
are five fields scattered through a 91-field `Gen`, and this gathers them so
"what makes a lane dirty?" is one file. `Gen` ~55 → ~20.
**Does not do.** **Does not add SIMD to the compiler.** `ARCHITECTURE.md §7`
lists that as deliberately-not-doing, and `lib/ir/proof.zig`'s measurement table
— where a `@Vector` attempt *loses* at every size up to 24578 — is the evidence,
in the tree. The three existing `@Vector` uses are the right three and are not
touched: `frontend/token.zig`'s accumulator over the fixed keyword table,
`frontend/preprocessor.zig`'s single-needle byte scan, and `backend/tb.zig`'s
`@Vector(NL, f64)` — the last in **generated** code, and the real one. The
hardware knobs stay: `--unknown-bound=`, `--outline-chunk=N`, `jac_f32` and the
`abstol` table are physical-world tuning.
**Exit.** Goldens `diff -r` clean.

### v0.7.1 — `ARCHITECTURE.md §6` phase 8
**Scope.** `src/sim/digital/` split into `root`/`compile`/`exec`/`net`/`display`,
~3.4k lines.
**Does not do.** Does not change the interpreter's behaviour. If the transcripts
move, the phase is wrong.
**Exit.** Goldens `diff -r` clean plus `test-devices`.

### v0.8.0 — Digital procedural and the §17.1–§17.2 surface
**Scope.** D04/D05, which `MANIFEST.md §6` calls greenfield from the lexer:
`fork`/`join`/`task`/`wait`/`automatic` are reserved-but-untagged in `token.zig`,
`@*` is not lexed, intra-assignment `#`/`@` is unaccepted, named blocks are
rejected. Then D09's §17.1/§17.2 obligations: the `$display`/`$write` families,
`$strobe`/`$monitor` with §9.4.1 change detection, `%m`, null arguments, the
zero-argument `$strobe`/`$fflush` forms, the `$fdisplay` family,
`$fgetc`/`$ungetc`/`$fread`, `$readmem*`.
**Does not do.** Does not close the analog half of any split row — where a row
splits analog/digital, **the analog verdict and the digital verdict are different
rows**.
**Exit.** `test-devices`; §4.1/§4.2's missing and partial rows close.

### v0.8.1 — VCD
**Scope.** All 22 rows of `CLAUSE-AUDIT.md §4.4`: `$dumpfile`, `$dumpvars`,
`$dumpoff`/`$dumpon`, `$dumpall`, `$dumplimit`, `$dumpflush`, then the four-state
file syntax, scope and identifier declarations, periodic and checkpoint records,
and the extended §18.3/§18.4 `$dumpports*` surface. 18.1-01 and 18.1-06 are file
handling that already exists; the rest are blocked on D03's packed nets and D05's
time axis, so only reachable after v0.2.0 and v0.8.0.
**Does not do.** Does not teach `--coverage` about the inherited clauses — that
is `CLAUSE-AUDIT.md §7.3` item 9 and stays open. Today a complete VCD
implementation and no VCD implementation produce the same coverage report.
**Exit.** `test-devices`, and the absence `grep -rn 'dump' src/` currently finds
is gone.

### v0.8.2 — `ARCHITECTURE.md §6` phase 6
**Scope.** `ir/lower/` split with `Lowered` as an output type. `Lower` 125 → ~30
fields. Left latest deliberately: phases 1–2 already removed ~1.5k lines and the
`Lowered` boundary is only clear once codegen's needs are explicit.
**Does not do.** Phase 7 in the same branch.
**Exit.** Goldens `diff -r` clean.

### v0.8.3 — `ARCHITECTURE.md §6` phase 7
**Scope.** `diag/report.zig` (78 sites), `vpi/entry.zig` (8 sites), `cli/args.zig`
(~110 lines → ~40 plus a table). Scheduled last so it does not collide with
phases 4–6's diffs; it can land any time after phase 3.
**Does not do.** Does not add a general arg-parsing library — 30 flags do not need
one.
**Exit.** Goldens `diff -r` clean.

### v0.9.0 — VPI
**Scope.** P02 first, then P03. P02 needs the object model plus a *running*
scheduler: `tests/vpi_host.zig` is lint-only today and 11 of its 13 fixtures need
a running simulation. P03 needs all of that plus a host that can solve
DC/transient/AC with a bound `SystfHost`. Both need the 26 `.c` fixtures wired,
which is v0.0.3.
**Does not do.** Does not schedule ARPice's `SystfHost` binding — §6.
**Exit.** `test-vpi` green, then the `test-vpi-p03` step this release creates —
`grep -c 'P03\|p03' build.zig` is currently 0.

### v0.9.1 — Measure C, the tail
**Scope.** The **83 uncited** clauses — the ones no fixture names at all, open by
default. The most expensive of the three classes per clause: each needs a clause
*read* before it needs a fixture, and reading it may move it into one of §5's
non-mandatory classes instead of producing a fixture at all.
**Does not do.** Does not assert an outcome for anything in `§5.5`'s unspecified
class.
**Exit.** `--coverage` reports 0 uncited.

### v0.9.2 — The implementation-defined list and the resource limits
**Scope.** `CLAUSE-AUDIT.md §5.3`'s six choices gathered into **one published
list**, which the audit says does not exist ("this table should become that
list"), with a test per choice. Then §5.4's four outstanding rows: a >512-byte
scan line, a >512-byte formatted string, two instances both opening files, and a
fixture exhausting the 30-channel mcd limit. The RNG row is the template — a
stated bound, a loud failure, a fixture.
**Does not do.** Does not decide §5.5's unspecified rows for them.
**Exit.** Every implementation-defined choice has a document **and** a test;
every resource limit is stated and fails loudly under a fixture.

### v1.0.0 — The conformance statement
**Scope.** Publish what §1 defines: measures A–D at their targets, plus the
implementation-defined list and the resource-limit table as the documents the
taxonomy requires. This release adds no code. If it needs to, the ladder is not
finished.
**Does not do.** Does not claim SystemVerilog, Annex C's subset, or anything
about ARPice.
**Exit.** §1's five clauses hold at one commit, reproducibly, and
`publish.yaml`'s `--check` passes against a v1.0.0 CHANGELOG entry reading 0
FAIL, 0 XFAIL, 612/612.

---

## 5. The long pole

**Measure C is 416 clauses and nobody is assigned to it.** It is larger than
measures A and B combined and larger than the entire ch07 program. `PLAN.md §5`
said it plainly and nothing has changed: *"None of Wave A or B touches this; it
is a separate program of writing positive fixtures for rules that already
work."*

**What it costs.** 416 clauses, each needing a clause read, a hand-derived
expected value, and — for most — the missing half of a pair. The unit is a
*clause*, not a fixture row, so the only rate in the sources does not transfer:
Wave A cleared 31 fixture rows in a two-day wave across five agents, but those
were diagnosed defects in files whose shape was already measured. This is writing
new evidence for rules that already work. `PLAN.md §5` says "measured in
quarters" and that remains the honest unit. This roadmap does not invent a rate;
see Appendix C.

**Why it cannot be parallelised naively.** The first trap in `TODO.md §2.4` is a
fixture that a *conforming* implementation fails, and the cheapest way to make
one pass is to break the compiler. Four were found and fixed; the note says to
assume more exist. Measure C is 416 attempts to write exactly that kind of
fixture, at a scale where review is the only defence — and the review record is
not encouraging. `MANIFEST.md §7` reports that two adversarial passes over 26
rows each found a fresh crop of fabricated quotations, non-reproducing
measurements and false completeness claims, **seven of them authored by the
repair pass itself, in rows an earlier review had certified clean**, and adds
"There is no reason to assume a third would not."

Five agents writing 416 fixtures faster than one reviewer can open the clauses
they cite is not speed; it is a second `MANIFEST.md §5.1`. **Every measure-C
fixture ships with its derivation in its header and is reviewed by someone who
opened the clause.**

**Where it starts and how it is ordered.** v0.2.1, and it runs continuously
through v0.9.1. The three checkpoints are milestones of one program, not three
bursts; between them the work continues on every release's spare capacity. They
are ordered by cost per clause:

| Checkpoint | Class | Count | Why here |
|---|---|---|---|
| v0.2.1 | refused-only | **76** | Cheapest. The compiler already refuses the illegal half, so the subject matter is implemented and only the positive evidence is missing. |
| v0.6.2 | accepted-only | **257** | The bulk. Each needs a negative fixture narrowed to a named diagnostic, and a judgement about whether the clause forbids anything at all. |
| v0.9.1 | uncited | **83** | Most expensive per clause: a clause read comes before a fixture, and may reclassify rather than produce one. |

**If it starts at v0.9 it does not finish, and v1.0.0 does not exist.**

---

## 6. Blocked on ARPice

ARPice's halves are **out of scope and unscheduled**; no release above waits on
them. VerA's halves *are* in scope. Keeping the two apart is what stops a VerA
obligation being marked done because a host change is pending, or the reverse.

| Item | What is dead | VerA's half (scheduled above) | ARPice's half |
|---|---|---|---|
| **`u_nodeset`** | VerA emits it (§3.6.3.2 net initializers, in `codegen.zig`, `lower.zig`, `tb.zig`); `grep -rn u_nodeset ARPice/src` = **0 hits** | `MANIFEST.md`'s A08-nodeset row: the parser must accept a null array element **and** lowering must stop dropping vector-net initializers — two independent gaps plus an unresolved spec question | `src/analysis/dc/op.zig` plus the `seedFn` rewrite in `eval.zig`, so a nodeset reaches `x` and not `lim_x` |
| **`noise_tables`** | VerA emits it; `grep -rn noise_tables ARPice/src` = **0 hits** | A06's `//! noise` directive support, blocked at `tb.zig`'s `validNoiseEntry`, plus the absent `//! acstim` | Four sites: `device_ir.zig`, `eval.zig`, `ac/noise.zig`, and — do not miss it — `pss/pnoise.zig` |
| **§4.6.4.6's `coeff`** | VerA exports `white = pwr` where the clause wants `c1²·pwr`; a host reads output noise low by `c1²` | v0.5.1 ships `coeff` on `PsdTerm`, signed | ARPice reads `noisePsd` and must learn the field, or it keeps the old answer against a default of 1.0 |
| **X01 / LTRA / TXL** | The LTRA/TXL AC stamp does not exist at all; `ltra_native.zig` CAP=8192 and `txl_native.zig` CAP=2048 silently discard samples past capacity. A sine deck past CAP diverges from ngspice-44.2 by **0.852 V on a 0.5 V signal**; under CAP it agrees to 6.3e-5 | Annex E parsing (H04) and the `--spice` CLI flag, without which 8 of H04's 11 cannot be run singly | Growable history, and the AC stamp |
| **P03's host** | `tests/vpi_host.zig` stops at `.lint`; P03 needs a host solving DC/transient/AC with a bound `SystfHost`, and ARPice binds none | v0.9.0 ships the P03 surface into `src/vpi/vpi_user.h` with implementations and a `test-vpi-p03` step | The binding |
| **A10's decks** | "The decks pass; that is a statement about the host, not about the decks" | VerA's analog half, already landing | The deck runner |
| **ARPice's circuit suite** | 518/616 is **not a gate** — the same unchanged tree scored 492, 494 and 518 across runs with byte-identical generated device code | — | Do not use it as a conformance signal for either repo |

---

## 7. Blocked on a human decision

These need a call, not another agent pass.

1. **Does `driver_update` fire for a connect module's own driver?**
   (`MANIFEST.md §5.8` item 7.) Under the literal reading of §9.22 ¶1/¶3 and
   §9.22.4, every `updates=` column in M02's and M04's fixture 12 shifts by one
   and all four `ok=` read 0. **Settle before v0.8.0 touches those rows.**
2. **Can `";2"` carry a dependent selector with no interpolation control?**
   (item 8.) An implementer following fixture 06 literally still breaks 07.
3. **Does a labelled regression gate belong in a row whose job is to fail?**
   (item 1.) The fixer and the reviewer are both right, and the question governs
   five rows, not one — X01's two `.op` decks, A05's fixture 07, A04's fixture
   09, A01's fixtures 06/07, A10's three host decks. **Answer it once.** Items 3,
   4, 5, 9 and 10 are the same shape at lower stakes.
4. **A06's `$vt` band.** A conforming tool on Annex D.2's `P_K_SPICE`/
   `P_Q_SPICE` or `PHYSICAL_CONSTANTS_OLD` still fails two fixtures — 2 of 5
   defensible constant sets, down from 4 of 5. Either widen the band to admit all
   five or state why two are wrong.
5. **The five fabricated quotations and two fabricated mechanism claims the
   repair pass authored** (`MANIFEST.md §5.1(b)`). §7 says delete them, and in
   A10's case ship the §9.17.2 fixture the fabrication was used to excuse. That
   is a scope decision, not a task.
6. **Twenty figures published as measured that do not reproduce**
   (`§5.1(d)`). Re-measure or delete. A document whose value is that its numbers
   were run cannot carry a table of numbers that were not.
7. **`docs/CONFORMANCE-GAPS.md`: rebuild or retire?** `CLAUSE-AUDIT.md §5.3` says
   its table should become the single published list of implementation-defined
   choices, and that list is a v0.9.2 deliverable. The decision is available now
   and delays v0.9.2 if deferred.
8. **May a fixture rest on an inherited clause not in the shipped corpus?**
   (item 11.) Four rows do it in load-bearing positions. `CLAUSE-AUDIT.md §7.3`
   item 8 offers the fix — add IEEE 1364-2005 to `docs/`, or confirm §§17–18
   numbering another way. Until decided, those four cannot close under measure B.

---

## Appendix A — Conflicting numbers across the older documents

Every one of these is a real inconsistency in `PLAN.md`, `TODO.md`,
`MANIFEST.md` or `ARCHITECTURE.md`. They are recorded so nobody re-litigates
them, and so a reader who finds an old number knows which way it was settled.
**From v0.0.1 onward, `CHANGELOG.md` is the single source for measures A and C
and this class of conflict should not recur.**

1. **Measure C's split.** `CLAUSE-AUDIT.md` (2026-09-16, 1301 fixtures) recorded
   611 clauses as 148 / 208 / 99 / 156. The 2026-09-21 run on 1558 fixtures
   measures **612 as 196 / 257 / 76 / 83**. The measured run wins. The widely
   quoted "463 remaining" is **416**.
2. **Measure A.** `PLAN.md §0` (2026-09-21) says 1489 / 41 FAIL / 28 XFAIL; the
   run at `1789cb1` measures **1495 / 35 / 28**. `1789cb1` landed six rows after
   `PLAN.md` was revised. The measured run wins.
3. **`benchmark --strict` denominators.** `TODO.md §2.3`'s `1323/1323` is a
   *different population* — the frozen `tests/fixtures` before `tests/pending`
   merged into it — so its denominator is not 1558 and never will be.
   `TODO.md §1`'s `1390/1557` is superseded by `TODO.md`'s own header note.
4. **`zig build test` is reported as 113/113, 104/104, 404/404, 561 and 514.**
   Four different counters, none wrong: **26/26** is *build steps*; **404/404**
   predates the `lib/` split, which cut one test artifact into one per module;
   **561** is *in-file test blocks* counted in source; **514** is that same
   counter after phase 1 landed; **113/113** and **104/104** are the test count
   one day apart. This roadmap means the test count whenever it says
   `zig build test`.
5. **`test-devices` is 47/66 and 5/66 in the older documents; it measures 48/66
   at HEAD, 2026-09-21.** `PLAN.md §0`'s 47/66 predates the port-net-type fix;
   `TODO.md §1`'s 5/66 predates the §6.2.2 elaboration work. The runner's
   selection is narrower than the 81 `.v` files present, and deliberately: it
   takes a `.v` only when a `<stem>.expected.txt` sits beside it. Since v0.0.3
   the other 15 are accounted for — 12 joined measure A, 3 are VPI support
   material. **As measured 2026-09-21 this step FAILs.**
6. **Tree size.** `ARCHITECTURE.md §0` says 71k (64.5k + 6.4k); the tree measures
   67.0k + 6.7k. The doc predates HEAD. Neither figure is used for sizing here,
   and `ARCHITECTURE.md §8` warns that both of its own line-count estimates were
   too optimistic and that every remaining §6 number is unverified.
7. **`PLAN.md §1`'s buckets do not partition the failing rows and must not be
   summed.** ch07 (46) + digital (19) + XFAIL-outside-ch07 (14) + stragglers (8)
   = 87 against 63 failing rows, because `m04` and `d04_15` are counted in more
   than one bucket. Separately §1 enumerates 27 XFAILs where §0 reports 28. **The
   name list is the artifact; the counts are not.**
8. **Line citations in `MANIFEST.md` and `TODO.md` have drifted.** `build.zig:428`
   for `fixture_root` is `:122`; `harness.zig:787` for the `.va` filter is
   `:849`; `lower.zig:8660`/`:8624`/`:8671` for `E0815` and `readTableFile` are
   `:9448` and `:9681`; `tb.zig:341` for `validNoiseEntry` is `:451`. **This
   roadmap therefore cites sections and symbols, not line numbers.**
9. **A fixture count cannot be sourced from `zig build test`.** The fixture walk
   sits behind `benchmark`; `test` builds from per-module artifacts and the suite
   runner's own unit tests. Any sentence of the form "N fixtures pass, per
   `zig build test`" is unsupported. Measure A is always
   `zig build benchmark -- --strict`.

---

## Appendix B — Documents this roadmap depends on that do not exist

| Document | State | Recovery | Cost while missing |
|---|---|---|---|
| `docs/CLAUSE-AUDIT.md` | **Deleted** in `2cc1c08`; 685 lines; measured 2026-09-16 | `git show 55e5117:docs/CLAUSE-AUDIT.md` | **Measure B is unverifiable.** It is the source of §7.1's 119 rows / 83 open / 30 `verified`, and it is the definition of `verified`, `partial`, `missing`, `implemented-without-evidence`, `optional`, `implementation-defined`, `non-normative`, `resource limit` and `unspecified` that §1 is written against. Its measure-C half is now superseded by the `--coverage` run (Appendix A item 1), but §7.1 has no command and cannot be re-derived without it. **Restoring it is v0.0.2.** |
| `docs/CONFORMANCE-GAPS.md` | **Deleted.** `TODO.md §3.6` still describes it as merely stale (375 units, 1313 fixtures, 295 host units) | Not recoverable at the paths checked; ARPice's plan still links to it | Its counts are quoted in ARPice's plan and are stale by `TODO.md`'s own reckoning. Its *role* — the single published list of implementation-defined choices — is a v0.9.2 deliverable. Rebuild-or-retire is §7 decision 7. |
| `docs/VAMS-LRM-2023.pdf` + 20 chapter/annex HTML files | **Present** | — | These are the spec, and `--coverage` reads its table of contents out of them at run time. Cited by clause number throughout. |

---

## Appendix C — Gaps I could not source

Needed by this roadmap, traceable to no source line. Listed here rather than in
the ladder, which is for traced work.

1. **A rate for measure C.** No source states how long one clause's evidence
   takes, so §5 gives quarters without a number of them. v0.2.1 should produce a
   measured rate over its 76 clauses, and the ladder should be re-planned
   against it.
2. **A release cadence, a team size, and an executor.** Nothing says who runs
   this ladder or how long a release takes. `PLAN.md §6`'s operational rules are
   written for parallel *agents*, not people. Without this, §3's ordering is
   meaningful and its numbering is nominal.
3. **Who owns measure C.** Every source says nobody does; none says who should.
4. **Whether the 26 `.c` and 7 `.sp` fixtures are expected to pass.** v0.0.3
   makes them visible; nothing states the target. `PLAN.md §1` calls the bucket
   "unmeasured; needs runners before it needs fixes", which implies a target
   without stating one. §1 clause A assumes all 33 are passable.
5. **The disposition of the ~20 non-`w2/*` branches.** All 13 `w2/*` branches are
   empty and should be pruned; `TODO.md §2.5` explicitly warns not to assume
   anything about the others (`cur-vera`, `gpu-vera`, `hoist-vera`,
   `refactor/frontend-ir-backend`, …). Auditing them is cheap and unsourced; it
   is not in the ladder.
6. **A gate for the fixture-quality debt.** `MANIFEST.md §5` leaves 23 rows
   partial and §5.1 says the repair pass introduced the failure mode it was
   convened to remove. No source says what a *third* pass would gate on, or who
   would own it.
7. **Whether `ARCHITECTURE.md` should be tracked.** It is 31 KB of the project's
   own architecture and is untracked. The same commit that deleted
   `CLAUSE-AUDIT.md` was a docs commit that also deleted three test files nothing
   had been updated to reflect. Nothing says whether that is policy or accident.
