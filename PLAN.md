# The route to zero failures

Written 2026-09-20, after the parallel-agent run that took FAIL 137 → 63. This
is a work plan, not a status report — `TODO.md` is the status report and
`tests/fixtures/MANIFEST.md` is the per-row register.

It is deliberately blunt about two things: which work can be done in parallel
and which cannot, and why "0 FAIL" is not the same claim as "100% conformant".

---

## 0. Where this starts

```sh
zig build test                  # 111/111
zig build test-devices          # 46/66
zig build benchmark -- --strict # 1453 pass / 63 FAIL / 41 XFAIL of 1557 .va
```

Session start was 104/104, 5/66, and 1368 pass / 137 FAIL / 11 XFAIL. The XFAIL
count went UP on purpose: a marker is what an honest gap looks like, and
several rows that used to fail silently now say what they are waiting for.

---

## 1. What is left, by shape

| Bucket | Rows | Parallelisable |
|---|---|---|
| ch07 mixed-signal | 33 FAIL + 13 XFAIL = **46** | **No** — one sequential program |
| digital `.v` (d04 tasks, d08 UDPs/switches, m04 `wreal`, d10_11) | 20 | Yes, 2 agents, but they share one file |
| ch04 §4.5 operators + §4.6 noise inputs | 12 | Yes |
| ch06 hierarchy (paramset, escaped names, sign context) | 7 | Yes |
| ch10 directives (file-boundary state, reserved-word identifiers) | 5 | Yes |
| XFAIL outside ch07 (annex A 12, ch09 4, ch04 3, ch08 2, ch05 2, ch06 1, annex E 1) | 28 | Yes, 2 agents |
| stragglers in ch03/ch05/ch09/digital | 6 | Folds into the above |
| `.c` VPI fixtures + `.sp` decks | 33 | **Unmeasured** — needs runners before it needs fixes |

The 7 "asserts nothing" and 4 "want is an expression, not a literal" rows are
all ch07, so they are part of the mixed-signal work rather than fixture chores.

---

## 2. Wave A — seven independent agents

Every row here is independent of every other. File ownership is the merge
contract: an agent that stays inside its column merges clean.

| Agent | Scope | Owns |
|---|---|---|
| `hierarchy` | paramset chain, string-range selection, OOMR localparam, escaped name vs vector element, mixed-sign comparison context (§4.2.9), integer parameter override rounding, string-derived parameter | `lib/ir/elaborate.zig`, `lib/ir/lower.zig` |
| `directives` | default discipline crossing a file boundary, `` `begin_keywords ``/`` `end_keywords `` surviving the include that opened the region, `assert` and `net_resolution` as ordinary identifiers | `lib/frontend/preprocessor.zig`, `lib/frontend/lexer.zig` |
| `noise2` | §4.6.4.3's array-parameter and file-name `noise_table` inputs; `ac_stim` with a dynamic magnitude (widening `f64Expr`'s reach, which a previous agent scoped out on purpose) | `lib/ir/lower.zig`, `lib/backend/codegen.zig` |
| `digital-tasks` | d04 tasks and functions, fork/join, `disable` of a named block | `src/sim/digital.zig` |
| `digital-prims` | d08 UDPs, MOS/CMOS switches, bidirectional, strength reduction; m04 `wreal` | `src/sim/digital.zig` |
| `xfail-annexa` | the 12 `annex_a_syntax` XFAILs, one coherent syntax block | `lib/frontend/parser.zig`, `lib/frontend/ast.zig` |
| `runners` | wire the 26 `.c` VPI fixtures and the 7 `.sp` decks into build steps | `build.zig`, `tests/harness.zig` |

**`digital-tasks` and `digital-prims` share `src/sim/digital.zig`.** Run tasks
first, alone, and prims after it. Two agents rewriting a 2000-line file in
parallel is a merge nobody should have to do.

`digital-tasks` is the largest single item in the wave: tasks and functions
need a CALL STACK and statement execution inside `eval`, and the engine is a
pc-based suspendable interpreter that is not shaped for either. Expect it to
take longer than the other six together.

### What the `runners` agent is actually for

The 26 `.c` and 7 `.sp` fixtures are not failing. They are INVISIBLE — no build
step walks them, so they have never been run. Until they are wired, every
percentage in this repo is computed over a denominator that quietly excludes
them.

The `.sp` seven are not `//! spice` netlists, whatever an earlier brief
assumed. They are foreign-simulator decks — `.hdl` plus instance cards plus
`.tran`/`.noise`, paired with an `.expected.json` — with no `.va` under
compilation and no `ok=` assertions. Reaching them needs a deck runner that
loads the modules, builds the netlist, runs the named analysis and compares to
the JSON. That is `tests/harness.zig` work, not a CLI flag.

---

## 3. Wave B — the mixed-signal coordinator, one agent, sequential

46 rows, the largest block in the suite, and it does not decompose. Each step
gates the next, in the order `tests/fixtures/ch07_mixed_signal`'s own SPEC
derives:

1. the parser accepts `always`, `#` delay and `assign` in an analog-context module
2. `digital.zig` accepts a module with PORTS and an analog block
3. A2D delivery: cross → digital tick, with §8.4.3.3 half-precision-base rounding → unlocks m02 04/08/11
4. implicit D2A + region 3b → 02/10/12
5. explicit D2A + region 1b → 03/05/06/09
6. `absdelta` interpolation → 13
7. §8.4.2 DC iteration → 01

Step 2's blocker is **gone**: `E1100: digital execution requires exactly one
ordinary module` was replaced by real §6.2.2 instance-tree elaboration in this
session, which is why this wave is now worth starting at all.

What it still needs, and what makes it a design task rather than a wiring job:

- **A new runner.** `tb.zig` is a fixed-grid evaluator over the declared
  `//! time` points, with no mechanism to insert a solver-chosen timepoint.
  Several m01/m02 fixture rationales assume mid-step observation, and they
  cannot be satisfied by that shape at all.
- **`tb.zig`'s solver is a source TEMPLATE, not a function** — a Zig string
  literal emitted into each generated testbench. A coordinator in `src/sim/`
  cannot call it. This kills the cheapest imagined route.
- **Tick ↔ second conversion**, which `src/sim/time.zig`'s `Scale` already has
  (`realDelay`, `unsignedDelay`, and now `unitsAt`/`realAt`).
- `src/sim/scheduler.zig` is complete and unit-tested — six regions, future
  heap, cancellation, analog request coalescing — with **zero production
  callers** for the mixed-signal regions. The machinery exists; nothing posts
  to it.

M03 additionally needs §7.8's insertion phase (`elaborate.zig` documents its
absence) and §7.8.5 generated names as defparam targets. M04 needs `wreal` as a
net type, which is why `digital-prims` should land before Wave B.

---

## 4. Do this one first, and do it alone

**W0851 — a display task under a conditional in an analog block is silently
dropped.** Three separate agents hit it independently in one session. It blocks
`s01_05`/`s01_06`, the rewrite of every fixture whose want is piecewise in
time, and probably some of ch07.

The fix is about ten lines: `Lower.finishDisplays` skips every `conditional`
entry because the call's value does not dominate the chain root and so cannot
be `fadd`-chained; routing it through an SSA place instead (seeded in `.entry`,
written inside the guarded block, read at the end) makes it chainable.

It is small and it is NOT delegable, because it changes the behaviour of every
conditional print in the corpus and `tests/fixtures/check.vh:19` documents
relying on the current drop. It wants one person, one verdict diff, and a
careful look at what moves.

---

## 5. Why "0 FAIL" is not "100% conformant"

Three separate measures, and only the first one is what this plan drives to
zero.

**The 41 XFAILs are honest markers, not noise.** Each names a rule VerA does
not meet. Driving them to zero means implementing each gap — deleting the lines
would be a lie, and the harness already fails on XPASS to make sure nobody
does it by accident.

**Coverage is the larger half.** `docs/CLAUSE-AUDIT.md` §7.2 counts 463 clauses
with one-way evidence: 208 accepted-only, 99 refused-only, 156 uncited. A
clause that only has a rejection fixture is not covered — a refusal is not
positive evidence that the accepted form behaves. Only the ~148 tested both
ways can support a `verified` verdict under the plan's own completion rules.
None of Wave A or B touches this; it is a separate program of writing positive
fixtures for rules that already work.

**Compiler acceptance is not runtime evidence.** The completion rules want a
positive behavioural test, an invalid-input test, and a recorded result per
obligation. "It compiles" is the weakest of the three.

So: Wave A + Wave B gets the fixture suite green. Calling the compiler
conformant needs the 463 as well, and that is measured in quarters.

---

## 6. Operational notes, learned the expensive way

These cost real time this session. They are not style preferences.

- **Every agent gets its own worktree.** Two in-tree agents plus the main
  session shared one checkout; one ran `git reset --hard` and destroyed
  uncommitted work. Recovered from context, but only by luck.
- **`git commit` commits the INDEX.** A docs commit in this session silently
  swept in three pre-staged VPI test-file deletions that had nothing to do with
  it, and nothing noticed until an agent found `src/vpi/root.zig` citing files
  that no longer existed. Stage by explicit path; never `git add -A` in a
  shared tree.
- **`cd` to the repo root before anything that writes.** A drifting shell cwd
  landed inside an agent worktree and made four merges appear to have vanished.
  They had not.
- **Agents must diff FAIL NAME LISTS, not counts.** Two agents correctly
  reported that the baseline in their brief was stale, and were only able to
  claim "no regressions" because they compared names. A count can stay still
  while the membership changes.
- **Disk.** Each worktree's `.zig-cache` reaches ~10 GB. Six parallel agents
  filled the filesystem and killed the whole run mid-flight. Prune dead agents'
  caches between waves; budget ~12 GB per concurrent agent.
- **Size goldens compose.** When two agents each move the generated-device byte
  counts in `tests/bench.zig`, the merge conflict must be REGENERATED, not
  resolved to one side — both deltas are real.
