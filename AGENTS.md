# AGENTS.md

Read this before touching anything. It is short because the long documents are
listed in §1 and you are going to read those too.

VerA is a Verilog-AMS compiler in Zig. It compiles Verilog-A into Zig device
code that an external simulator links and calls inside a Newton loop.
`lib/` is the compiler, `src/` is everything that runs after it.

---

## 0. The three rules that are not negotiable

**1. Never type a conformance number. Measure it.**
`tools/conformance.sh` is the only thing that may write measures A and C.
`CHANGELOG.md` is its output. `.github/workflows/publish.yaml` re-measures on
the runner and refuses any tag whose entry disagrees with the tree. If you find
yourself about to write a percentage into a document, run the script instead.

**2. Gate on `$?`, never on the tail of a log.**
`zig build test 2>&1 | tail` swallows the exit code. This has produced a green
report over a failing build in this repository before (`TODO.md §2.1`). In a
pipeline, `exit "${PIPESTATUS[0]}"`.

**3. Diff FAIL *name lists*, not counts.**
A count can stay still while the membership changes. Two agents were only able
to claim "no regressions" honestly because they compared names (`PLAN.md §6`).
Before and after any change:

```sh
zig build benchmark -- --strict 2>&1 | grep -E '^(FAIL|XFAIL)' | sort > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```

---

## 1. Read these, in this order

| Document | What it is | Use it for |
|---|---|---|
| `ROADMAP.md` | v0.0.1 → v1.0.0 release ladder | which release your work belongs to, and its gate |
| `CHANGELOG.md` | measured conformance per release | where the project actually stands |
| `PLAN.md` | the work plan, newest measurements | what is left and what parallelises |
| `ARCHITECTURE.md` | target architecture; §6 is a 9-phase migration | where a new file goes, and why |
| `tests/fixtures/MANIFEST.md` | per-row defect register, 1036 lines | the diagnosis for a specific failing row |
| `TODO.md` §2 and §4 | expensive knowledge and ground rules | how to run a fixture; the traps |
| `docs/*.html`, `docs/VAMS-LRM-2023.pdf` | the LRM — 20 chapter and annex files | the normative text. Cite by clause number |
| `git show 55e5117:docs/CLAUSE-AUDIT.md` | **deleted from the tree**; 685 lines | the definition of `verified` / `partial` / `missing`, and measure B |

`TODO.md §1` and `§3.1`'s measurements are superseded by `PLAN.md §0`, which is
itself superseded by the latest `CHANGELOG.md` entry. When two disagree, the
newest wins and **you say so** rather than picking silently.

---

## 2. The four measures

v1.0.0 is not "the tests pass". It is four independent numbers, and none
reduces to another. Every change you make should say which one it moves.

| | Measure | Command |
|---|---|---|
| **A** | Fixtures behaving as stated | `zig build benchmark -- --strict` |
| **B** | Inherited IEEE 1364 §§17–18 obligations closed | hand-read against `CLAUSE-AUDIT.md` §7.1 |
| **C** | LRM clauses with **two-way** evidence | `zig build benchmark -- --coverage` |
| **D** | `ARCHITECTURE.md` §6 phases landed | hand-read against `ARCHITECTURE.md` §8 |

Three consequences you will get wrong if you skip them:

- **A rejection fixture is not positive coverage.** Measure C is the large
  half and most of it is writing *positive* fixtures for rules that already
  work. A clause with only a `//! reject` fixture is one-way.
- **Compiler acceptance is not runtime evidence.** An obligation needs a
  positive behavioural test, an invalid-input test, and a recorded result.
  "It compiles" is the weakest of the three and closes nothing.
- **XFAIL markers are implemented, never deleted.** The harness FAILs on XPASS
  specifically so a marker cannot outlive its limitation.

---

## 3. The release ritual

Every version increment is a published GitHub release. There is no other way to
release, and there is no releasing without a measurement.

```sh
# 1. Land your work. Gates green, name lists diffed.
zig build test                       # must pass. This is the gate.
zig build benchmark -- --strict      # exit 1 until v1.0.0 — read the names

# 2. Write the entry. This RUNS the suites; it does not ask you for numbers.
tools/conformance.sh --changelog v0.1.0

# 3. Fill in B and D by hand — the two rows the script marks `hand-entered`.
#    Name the document and the date you read. Do not guess.

# 4. Commit, tag, push the tag. CI does the rest.
git add CHANGELOG.md && git commit -m "release: v0.1.0"
git tag v0.1.0 && git push origin v0.1.0
```

`publish.yaml` then re-runs `tools/conformance.sh --check v0.1.0` on a clean
runner. **If the tree measures something different from what you committed, the
release fails.** That is the feature. Re-measure, amend, re-tag.

Semver, applied literally: a **minor** (`0.N.0`) changes something a consumer
observes — source VerA newly accepts or refuses, device text it emits, or a row
in `build.zig`'s `module_specs`. A **patch** (`0.N.M`) closes rows without
changing any of those. Every `ARCHITECTURE.md §6` refactor phase is therefore a
patch, because it is byte-identical by construction.

`.github/workflows/bench.yaml` runs on every push and PR. It **reports** the
torture suite, clause coverage, digital transcripts and the footprint/speed
sweep into the job summary, and uploads the FAIL name list as an artifact. It
gates on `zig build test` alone — the conformance number is a progress meter
until v1.0.0, not a pass/fail.

---

## 4. Working on the code

**Where a file goes** is decided by what it must *import*, not by what it is
about. That rule was learned the expensive way: `ARCHITECTURE.md §8` records a
planned `support/contract.zig` that could not exist, because the assertion it
held needed three modules a bottom-of-stack file cannot import.

`build.zig`'s `module_specs` is the module graph and `defineModules` **panics on
a cycle**. Dependency order is enforced by the build, not by review.

**Refactor phases keep goldens byte-identical.**

```sh
tools/golden-baseline.sh before     # on the pre-change tree
# ... your phase ...
tools/golden-baseline.sh after
diff -r .zig-cache/vera-golden/{before,after} && echo IDENTICAL
```

One phase = one branch = one PR. Never two phases in flight in `lib/`. No
behaviour changes, no bug fixes, no "while I'm here" inside a phase — those are
separate commits before or after. **A phase that cannot keep goldens
byte-identical stops and gets re-scoped.**

**Tests move with the code they test, in the same commit.** A split that leaves
tests behind is how coverage silently drops.

**Fix at the root.** `asInt` had ten callers; guarding the crash site would have
left nine able to abort.

---

## 5. SIMD — read this before you optimise anything

**The compiler is not a SIMD target and you are not to make it one.**
Every backend walk is a chain: a dominator-tree walk, a data-dependent output
length, recursive SSA construction. `lib/ir/proof.zig` carries a measurement
table where a `@Vector` attempt **loses** at every size up to 24578.
`ARCHITECTURE.md §7` lists adding SIMD to the compiler as
deliberately-not-doing.

The three existing `@Vector` uses are the right three and are not touched:
`frontend/token.zig` (accumulator over the fixed keyword table),
`frontend/preprocessor.zig` (single-needle byte scan), and `backend/tb.zig`
(`@Vector(NL, f64)` — **in generated code**, and the real one).

**SIMD-first applies to the emitted device.** The generated `eval` runs millions
of times inside a host Newton loop; that is the hot loop this project exists to
make fast. The lane decisions — `pinLanes`, `lane_pinned`, `lane_clean`,
`jac_f32`, `cur_strict` — are what `ARCHITECTURE.md §6` phase 5 gathers into
`codegen/float/`.

**The hardware knobs stay.** `--unknown-bound=`, `--outline-chunk=N`, `jac_f32`
and the `abstol` table are physical-world tuning. Do not simplify them away.

---

## 6. Fixtures

Run one by hand — `--check` needs **both** flags, and the fixture's own
directory must be on the include path:

```sh
./zig-out/bin/vera --check --contract tools/contract.zig \
    -I tests/fixtures -I <the fixture's dir> <file.va>

# the self-checking testbench — prints the ok=0/ok=1 lines:
P=$(./zig-out/bin/vera --emit-exe --contract tools/contract.zig \
      -I tests/fixtures -I <fixture dir> <file.va> 2>/dev/null)
"$P"
```

`--emit-exe` prints the path on **stdout** and diagnostics on **stderr**.
Capture them separately or you get an empty path.

The header quotes the LRM sentence, derives the expected value **by hand**, then
carries the machine-readable tags:

```
//! lrm 9.4.1
//! bias V(p) = 0.75, V(n) = 0.25
//! reject E0310     <- a SUBSTRING. A bare `//! reject` matches ANY diagnostic.
//!                     Always name the code or a distinctive phrase.
//! xfail <reason>   <- "the fixture is right and VerA is not". FAILs on XPASS.
```

`check.vh` gives you `CHECK` (absolute tol), `CHECKR` (relative), `CHECKX`
(exact), `CHECKI` (integer), `CHECKEQ` (two VerA expressions against each
other). **When the LRM states an identity with no digits, assert the identity
with `CHECKEQ`** and say in the header why no digits are written.

### The trap that produces confidently wrong work

**A fixture that a *conforming* implementation fails.** The cheapest way to make
one pass is to break the compiler. Four have been found and fixed here; assume
more exist. Worked examples in `TODO.md §2.4`:

- `$vt` pinned to VerA's own CODATA2018 constant while §9.15 supplies no number.
- `absdelta(V, 0.5)` against a wave stepping exactly 0.5, where §5.10.3.4 fires
  on "**more than** delta" — the fixture tested for a bug.
- Seven fixtures assuming a digital-context `integer` starts at 0. §3.2 says
  **x**; only analog-context assignment defaults to zero.
- "The second NBA cancels the first." IEEE 1364 §9.2.2 performs **both**.

So: **before you change the compiler to make a fixture pass, establish that the
fixture is right.** If you withdraw a claim from a fixture, name the row it
moved to.

---

## 7. Things that look done and are not

- `src/sim/scheduler.zig` is complete and unit-tested — six regions, future
  heap, cancellation, analog request coalescing — with **zero production
  callers** for the mixed-signal regions. Nothing in `src/` posts `.analog` or
  `.explicit_d2a`.
- `tb.zig`'s solver is a source **template**, a Zig string literal emitted into
  each generated testbench. A coordinator in `src/sim/` cannot call it.
- `tb.zig`'s evaluator is a **fixed grid** over the declared `//! time` points.
  There is no way to insert a solver-chosen timepoint, which makes several
  mixed-signal fixture rationales false.
- All 13 `w2/*` branches are **empty** — `git merge-tree` returns the base tree
  for each. Nothing to merge. The other ~20 branches are unaudited; assume
  nothing about them.

---

## 8. If you are running as one of several parallel agents

Learned expensively, and none of it is style preference (`PLAN.md §6`):

- **Own worktree per agent.** Two in-tree agents plus a main session shared one
  checkout; one ran `git reset --hard` and destroyed uncommitted work.
- **Stage by explicit path. Never `git add -A` in a shared tree.** `git commit`
  commits the *index*: a docs commit once swept in three unrelated test-file
  deletions and nothing noticed for a session.
- **`cd` to the repo root before anything that writes.** A drifting shell cwd
  landed inside an agent worktree and made four merges appear to vanish.
- **Budget ~12 GB of `.zig-cache` per concurrent agent.** Six parallel agents
  filled the filesystem and killed a run mid-flight.
- **Size goldens compose.** When two agents each move generated-device byte
  counts in `tests/bench.zig`, the conflict is **regenerated**, not resolved to
  one side — both deltas are real.

---

## 9. Before you say you are done

- [ ] `zig build test` exits 0. Checked `$?`, not a log tail.
- [ ] FAIL/XFAIL **name lists** diffed; nothing new entered either.
- [ ] Refactor phase? Goldens are byte-identical.
- [ ] Changed a fixture's expectation? The derivation is in its header and you
      established the fixture was wrong before changing the compiler.
- [ ] Said which of the four measures this moves, and by how much.
- [ ] Every number you wrote came from a command, or names the document and
      date it was read from.
