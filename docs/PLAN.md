# The route to zero failures

Written 2026-09-20 after the run that took FAIL 137 → 63; revised 2026-09-21
after Wave A took it 55 → 41 and §2 turned out to be wrong about two of its own
agents. This is a work plan, not a status report — `TODO.md` is the status
report and `tests/fixtures/MANIFEST.md` is the per-row register.

It is deliberately blunt about two things: which work can be done in parallel
and which cannot, and why "0 FAIL" is not the same claim as "100% conformant".

---

## 0. Where this stands, after Wave A

```sh
zig build test                  # 113/113
zig build test-devices          # 47/66
zig build benchmark -- --strict # 1489 pass / 41 FAIL / 28 XFAIL of 1558 .va
```

Wave A ran on 2026-09-20/21: five agents, all five merged. **31 rows left the
FAIL/XFAIL list and NOTHING entered it** — 13 annex-A markers, 6 ch06, 5 ch10,
4 ch04 §4.5 (a stranded branch, see below), 3 ch04 §4.6, 1 d04. No XPASS, so no
marker was deleted without its gap being closed.

Written as 1453/63/41 above the wave; the 63 was measured before four §4.5
commits that were sitting unmerged in a dead agent worktree were found and
landed. PLAN §6's warning about that hazard earned its place twice over.

---

## 1. What is left, by shape

| Bucket | Rows | Parallelisable |
|---|---|---|
| ch07 mixed-signal | 33 FAIL + 13 XFAIL = **46** | **No** — one sequential program |
| digital `.v` (d08 UDPs/switches, m04 `wreal`, d10_11) | 19 | Yes, one agent — `digital-prims` |
| XFAIL outside ch07 (ch09 4, ch04 3, ch08 2, ch05 2, ch06 1, annex A 1, annex E 1) | 14 | Yes |
| stragglers in ch03/ch04/ch05/ch06/ch09/digital | 8 | Yes, one agent |
| `.c` VPI fixtures + `.sp` decks | 33 | **Unmeasured** — needs runners before it needs fixes |

The eight stragglers, each with its diagnosis already recorded:

  ch03 a08_nodeset_02_nodeset_bus_null_element
  ch04 a01_03_parameterized_dimension_override   §3.2 array dims elaborated from the DECLARED default while the index reads `model.N`
  ch05 a02_10_node_alias_reevaluated_when_a_parameter_changes
  ch06 h01_10_string_derived_parameter           `hostConditionalExpr` cannot render a string compare; cheaper route is the `!p.is_local` guard at codegen.zig:1982
  ch09 a05_08_file_loaded_on_first_executed_call `readTableFile` is eager at lowering
  ch09 s01_05 / s01_06                           see below — TWO blockers, not one
  digital d04_15_bare_event_trigger_in_analog_rejected  `lowerEventTrigger` wants the `in_event_stmt` gate `lowerDisable` already has, plus a diagnostic code

`s01_05`/`s01_06` are the instructive pair. They were blamed on W0851 for a
whole session; W0851 was lifted and they did not move. The real causes are (1)
§9.4.1 change detection, implemented nowhere — `Lower.isDisplayTask` lists
`$monitor` beside `$display` and gives it an unconditional inline print — and
(2) a §9.5 call rendering as the literal `0` in every unit but the display one
(`codegen.emitFileCallDropped`), so `fd` is 0 in the core and `$ftell(fd)` is
`$ftell(0)`. Fixing (2) alone flips neither row. They want to land together.

The 7 "asserts nothing" and 4 "want is an expression, not a literal" rows are
all ch07, so they are part of the mixed-signal work rather than fixture chores.

---

## 2. Wave A — DONE, and where this section was wrong

Five agents ran, all five merged, 31 rows out and none in. The scope table
below is kept because the file-ownership idea worked: every branch merged
clean except the one collision that was predicted, and that one was a
fixture add/add, not a code conflict.

| Agent | Result |
|---|---|
| `hierarchy` | 6 ch06 rows. Also found, while diagnosing a seventh: `foldBinary` reached `Const.asReal`, which is 0 for every string, so `"slow" == "fast"` folded **true** and a genvar loop over it unrolled 3× instead of 1×. New ch03 fixture pins it. |
| `directives` | 5 ch10 rows — see below, only two were compiler work. |
| `noise2` | 3 ch04 §4.6 rows. The two defects underneath them are worth more: `ctrlEval` did not pin lanes, so `.val()`'s lane-0 collapse gave every lane the FIRST lane's operating point for any x-dependent control argument (`absdelay`'s dynamic `td` included) while the device still claimed `lane_clean`. |
| `digital-tasks` | 1 `.v` row (`disable` of a named block) — see below, the rest was not its work at all. |
| `xfail-annexa` | 13 annex-A markers. Gates, UDPs and `specify` now PARSE in full and are refused by CLAUSE (W0251/W0252/W0253) instead of dying at a token. |

**Two scope calls in the original table were wrong, and both cost real time.**

`digital-tasks` was budgeted here as "the largest single item in the wave …
expect it to take longer than the other six together", on the theory that tasks
and functions need a call stack inside a pc-based interpreter. **There is no
call stack to write.** `task`, `fork`, `join` and `automatic` sit in
`lib/frontend/token.zig`'s reserved-but-unimplemented table with no tags at
all, and `function` parses only as a continuation of `analog`. Five of the six
d04 rows die at `E0205` in the PARSER. The work is `xfail-annexa`'s column, not
`src/sim/`'s, and the agent that owned the file could only report that.

`directives` was given three rows described as file-boundary preprocessor
state. **They were not a compiler bug.** A past migration filed two `.vh`
headers under `tests/fixtures/digital/`; include search is `{fixture dir,
fixtures root}`, so all three died at `E0126: cannot find include file`. A
`git mv` fixed them — zero compiler lines. VerA's file-spanning directive state
was correct all along, and `TODO.md` §2.1's note that they "are fine" is what
masked the misfiling for a session.

The lesson is not "brief harder". It is that a row's SHAPE — which diagnostic,
from which phase — is cheap to measure and was not measured before the work was
carved up. Ten minutes of `vera --lint` on the failing rows would have moved
both of these to different agents.

### Still to run

| Agent | Scope | Owns |
|---|---|---|
| `digital-prims` | d08 UDPs, MOS/CMOS switches, bidirectional, strength reduction; m04 `wreal`; d10_11 | `src/sim/digital.zig` |
| `stragglers` | the eight singles in §1, each with its diagnosis already written down | scattered — one agent, sequentially |
| `runners` | wire the 26 `.c` VPI fixtures and the 7 `.sp` decks into build steps | `build.zig`, `tests/harness.zig` |

`digital-prims` was blocked until 2026-09-21 and nobody had noticed: a UDP
declaration was `E0201` and a gate instantiation `E0205`, so there was nothing
for the ENGINE to execute. `xfail-annexa` cleared that. It is unblocked now.

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

### Measured 2026-09-21, before any of it was carved up

§2's lesson applied to this wave BEFORE starting it: `vera --lint -I
tests/fixtures` on all 46 rows, first diagnostic each. Three corrections to
what the rest of this section assumed.

**The 46 are not 46.** All thirteen `m03_*` rows are XFAIL, not FAIL — every
one marked `known: VerA performs no §7.8 connect-module insertion`. They are a
separate program (§7.8 insertion plus §7.8.5 generated names as defparam
targets) and they do not gate, and are not gated by, anything below. Wave B's
FAIL set is 33: m01 (13), m02 (13), m04 (7).

**All 33 share ONE gate, and it is three tokens.**

```
E0205  unsupported module item: found `always`     12 rows
E0205  unsupported module item: found `assign`      8 rows
E0209  expected an expression: found `#`           13 rows
```

Nothing below step 1 has ever been reached by a fixture, because nothing below
step 1 has ever been reached by the PARSER. The step order stands; what changes
is that steps 3-7 have no evidence behind their estimates at all, and should
not be treated as if they do.

**`always` is already parsed.** `parseDiscrete` (parser.zig:2229) builds the
`Ast.DiscreteBlock` and appends it; the E0205 beside it is `reportItem`, the
NON-FATAL spelling, gated on `!self.in_connect_module and !self.digital`. So
step 1 for `always` is one condition, not a production. `#` delay and `assign`
as a module item are genuine missing productions.

**But do not just open the gate.** Accepting `always` in an analog-context
module without an executor turns "refused" into "compiled, and the block
silently did nothing" — a wrong number with no diagnostic, which is strictly
worse than E0205. The pattern to copy is the one `xfail-annexa` established for
gates and UDPs in `f4f76fd`: parse the construct in full, then refuse it by
CLAUSE (W0252 is "no event queue") rather than at a token. That keeps the
refusal honest while the AST becomes available to the rules that need it.

**Two rows are reachable now, without any runner.** `m01_90` and `m01_91` are
REJECTION fixtures — they want `LRM 7.3.7` and `LRM 7.3` in a diagnostic and
currently get E0205 on `function` and `always`. `Lower.checkDiscreteContext`
already implements four §7.2.2/§4.5.15/§4.7.3/§5.2.1 rules and E0430's own doc
comment already says "§7.3.7 states the mixed-signal half". Open the gate,
make E0430 cite the clause, add the §7.3 analog-net-written-from-a-digital-
process rule, and both flip. That is the cheapest real progress in this wave
and it needs no scheduler, no coordinator and no new runner.

### The step order

Each step gates the next, in the order `tests/fixtures/ch07_mixed_signal`'s own
SPEC derives:

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

## 4. ~~Do this one first, and do it alone~~ — DONE 2026-09-20

**W0851 — a display task under a conditional in an analog block is silently
dropped.** Fixed exactly as sketched: `display_cond_place`, an SSA place seeded
`.f_zero` in `.entry`, `fadd`-ed at each guarded call site and read once in
`finishDisplays`. The call keeps its position in the arm, so codegen emits it
inside the generated `if` and §9.4.6 is satisfied by placement rather than by
dropping. W0851 the diagnostic is deleted; `lib/backend/codegen.zig`'s
"§9.4.6 a display task under an `if` prints inside its arm" pins it.

**Verdict diff: none.** 1457/59/41 before and after, FAIL names identical,
111→112 unit tests, `test-devices` 20 FAIL unchanged. The change is strictly
additive — nothing that printed before moved or changed — which is also its one
wart: print order is MIR order, guarded calls sit at their statement and
unconditional ones are minted at the end of the block, so a module that prints
both shows the guarded lines first. Noted at `finishDisplays` with the upgrade
path (a source-order index on `Display`).

What it actually unblocked: `combined/16_file_display_diagnostics.va` now runs
its whole guarded open/write/flush/close lifecycle, and the fixture rewrites
whose want is piecewise in time are now writable.

**What it did NOT unblock, and this is new information.** `s01_05`/`s01_06`
measure the same −1/−3/−3/−3 they did before. The event-guarded `$fopen` now
runs, but its RESULT cannot leave the display unit: `codegen.emitFileCallDropped`
renders every §9.5 call as the literal `0` in any unit that is not the display
one, so the shared core computes `fd = 0`, `updateState` stores that 0 into the
held slot, and `$ftell(fd)` is `$ftell(0)`. A descriptor assigned in the analog
block and read as a VALUE is unrepresentable until a file call's result can be
carried out of the display unit — a persistent `Instance` slot the display unit
writes and the core reads, in the shape `held_vars` already has. That is the
real `s01_05`/`s01_06` blocker and it is a separate, unscoped item.

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
