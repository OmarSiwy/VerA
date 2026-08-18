# CHANGELOGS

Running log of autonomous work. Newest section at the top of each list. Written to be read cold
over coffee: the things that need a human are first, then what landed, then what I decided
without asking, then where I was wrong.

Every number here is **MEASURED** on the tree at the stated commit unless it says ESTIMATED.
The rule is TODO.md's: re-run the suite rather than trusting this file.

---

## ⚠ Needs your eye — nothing here is blocking, all of it is reversible

1. **`docs/conformance-plan.md` (745 lines) is deleted, and its deletion rode in `6bb63ba`.**
   It was already staged as deleted in your working tree before I started, so I did not decide
   this — but I did bundle it into a commit about `ifconv`, which is not where a reader would
   look for it. `git revert` or a split is one command if you want it back or want it separate.
   Four dangling pointers to it are fixed (TODO.md, tests/fixtures/TODO.md, tools/contract.zig).

2. **`git stash` is repo-global across worktrees and TWO AGENTS COLLIDED ON IT.** One agent
   took a clean baseline with `git stash && bench && git stash pop` and its pop restored a
   *different* agent's in-progress work into its tree. Both recovered (a patch copy is at
   `/tmp/other_agent_didyoumean.patch`; I verified the stash list is empty and the two branches
   are disjoint before merging). No work was lost, but the failure mode is silent and would have
   been much worse during a deletion wave. **Rule going forward: agents must not use `git stash`
   while others are running — use a patch file.**

3. **An unmerged worktree exists: `worktree-agent-a0033e63105e5f22e` at `6afca59`**, subject
   "Device fixes: inductor flux sign, kinduc M, tline Bergeron, switch edges, diode pnjlim,
   LTRA sections". Not mine, not merged into `refactor/frontend-ir-backend`. It overlaps wave
   13's device-physics items (specifically the inductor work), so if it is real work you want,
   tell me and I will merge it BEFORE wave 13 rather than have an agent redo it.

4. **You asked about sub-linear complexity; wave 12 deleted the only thing that could deliver
   it.** A compiler cannot beat O(N) on a fresh compile — it must read every byte. The only
   route to sub-linear *per edit* is an incremental frontend cache, and that is `root.Compilation`
   (`src/root.zig`, ~273 lines), which wave 12 deletes as having no consumer. I am proceeding
   with the deletion (doctrine: no member without a consumer; its own docstring argues against
   itself), but recording it here because rebuilding it later against the new bench would be a
   deliberate wave, not an accident.

5. **DONE — the prelude win landed in wave 14.** Measured **(Debug)** 902.5 ms → 181.9 ms on the
   `pp` phase (4.96×), −27% to MIR, output byte-identical. The estimate here said 909 ms; the
   honest figure is 716 ms, because 186 ms of stage 1 is genuinely user text and macro re-puts.
   **(Debug)**: wave 16 found `bench` had been run without `-Doptimize`, so every wave-8/14
   figure is a Debug figure; the shipping `pp` is **19.5 ms** (ReleaseFast, `bench -- fixtures`,
   this tree). The ratio is what the item was about and it survives. Left in this list only so
   the trail from "found, unscheduled" to "measured, landed" is visible.

---

## Landed

### Wave 16 — the instrument now says which mode it measured in

**Suite: 217/217 green.**

`tests/bench.zig` printed `case n phase min_ns bytes` and `build.zig` gave `bench_mod` the
tree's default `-Doptimize`, i.e. **Debug**. So `fixtures 1164 lint 247334891` and `fixtures
1164 lint 1969020854` were the same measurement of the same tree and nothing in the output told
them apart — the fifth instance of the defect `tools/contract.zig`'s header keeps a register of,
a number nobody can reproduce. Every wave-8 and wave-14 timing was quoted as if it were the
shipping figure and none of them was.

- **The timing table gained column 1: the mode**, from `@import("builtin").mode`. The footprint
  table did NOT — those are pure functions of the source and identical in every mode, so a
  column there would make `diff` of two runs report a difference that is not one, and `diff` is
  the comparison the file's header promises. A non-ReleaseFast run also prints one `#` line
  saying so.
- **`zig build bench` does NOT force ReleaseFast on itself**, and this was the live question.
  `-O` is a *per-module* flag — `std.Build.Module` appends one per module — and the code being
  timed is in `vera_mod`, not `bench_mod`. Overriding `bench_mod` alone times a ReleaseFast
  harness driving a Debug engine, which is a third number nobody wants, and it makes
  `builtin.mode` inside `bench.zig` describe the harness rather than the engine — breaking the
  label this wave installs. Doing it honestly means a second `vera` module at a mode nothing
  else in the build uses. Printing the mode costs one column and closes the same hole, so the
  step description and the file header carry the recommendation instead:
  **`-Doptimize=ReleaseFast` is the number that means anything.**
- **MEASURED, both modes, same tree, `-- fixtures`, 1164 fixtures, min of 25:**

| phase | Debug | ReleaseFast | ratio |
|---|---|---|---|
| pp | 187.1 ms | **19.5 ms** | 9.6× |
| lint | 1959.5 ms | **247.0 ms** | 7.9× |
| codegen | 2161.8 ms | **266.2 ms** | 8.1× |
| rewrite | 2514.0 ms | **329.4 ms** | 7.6× |

- **Re-labelled or re-measured every Debug figure in the tree**: the wave-14 table and the
  wave-8 curve in this file, `preprocessor.zig`'s snapshot docstring, `analysis.zig`'s
  `buildStructure` docstring, and TODO.md §2's noise-floor and `pp` figures. The `before`
  columns cannot be re-measured — that code is gone — so those are labelled `(Debug)` and the
  ReleaseFast `after` is stated next to them. TODO.md's 211.7 µs/fixture was already ReleaseFast
  and is now labelled as such.
- **One figure moved in the claim's favour.** `vera --lint` on a 6-line model, 3,189 µs vs
  2,235 µs with `--no-std-defs`, is ReleaseFast (Debug is 16.1 ms) — but it is a shell loop, and
  1.32 ms of both terms is `fork`+`exec`, measured by looping `vera --version`. Net: **0.76 vs
  0.18 ms**. The prelude's *parsing* is most of a one-shot compile, not the "~30%" recorded.

### Wave 15 — derive the aliases; MEASURE the MIR row and refuse to rewrite it — `b533573`

**Suite: 217/217 · torture 1162/1164 (2 XFAIL, 0 FAIL) · test-contract green.**

**T0.4** — the nine `prelude_*_txt` alias blocks are derived at comptime from the helper text.
The "KEEP IN SYNC" comment and the test policing it are gone; **−66 lines**, emitted bytes
unchanged (proved with a temporary test holding the old text verbatim, then removed once it could
only compare the derivation with itself).

My brief was wrong twice. Deriving from "the exact predicate `publish` applies" **would have
shipped a broken prelude**: the five `@embedFile` blocks arrive *already* `pub`, so `publish`
leaves them untouched, and that predicate drops every `zScan`/`zFOpen`/`zRng*`/`zTab*`/`zBilin`
alias — the majority. And the sync rule never caught anything: the deleted test's block list
omitted `file_txt`, so the twelve `zF*` aliases were **unpoliced hand-maintenance the whole
time**, while the comment claimed a narrower scope than the ten blocks it governed.

**THE MIR ROW: measured, and refused.** Recorded in TODO.md §2 with the numbers.

The audit's sizes were right (25 B/inst SoA, 9 B `ValueRow` + 4 B alias). The *inference* was
not. All 1,164 fixtures' MIR together is **992 KB**; the largest single fixture is **44 KB**;
this box's L2 is 32 MB. The whole corpus is 3% of L2 and one fixture is L1-resident. The most
generous accounting of the layout is ~7 ns/inst against a marginal **670–1,241 ns/inst** — 1% of
lint, of which the Air shape removes at most half. Bench noise on the batch is 1.3%. **The entire
theoretical win is below the instrument's noise floor.**

Air's 9 B is worth it because Zig compiles functions with millions of instructions. VerA's
largest real MIR is 44 KB. Copying the shape without the scale is cargo cult — and this is
exactly the outcome the measurement gate existed to produce.

Two more spec errors worth keeping: **`Ref` folding is not local to `mir.zig`** — the Value space
indexes nine side arrays outside it (`analysis`, `unit_plan`, `codegen`) at 27 B per value,
*twice* the 13 B the fold deletes, and codegen's slot lookup is
`if (i < an.nv and plan.slot[i] != none)`, so an off-by-one in renumbering **does not trap — it
names a different cached slot in the emitted device.** And the `tok` split aims at a walk that no
longer exists: `analysis.zig` already hoists `i_op`/`i_res` as raw column slices, with a comment
saying why.

**What the measurement found instead — the next real win.** 87% of fixture-batch lint is a
*per-compilation constant*: 211.7 µs per fixture **(ReleaseFast**, lint 246.4 ms / 1,164;
re-measured in wave 16 at 247.0 ms / 1,164 = 212.2 µs**)**, spent producing **237 bytes** of MIR.
Wave 14 cached the prelude's *preprocessing*; every compilation still **lexes, parses and
lowers** the same ~11.8 KB of expanded Annex D/E. `vera --lint` on a 6-line model is 3,189 µs,
and 2,235 µs with `--no-std-defs`. **That is ~30%, not 1%.**

**Wave 16 correction, and it is in the CLAIM's favour.** Those two CLI figures are ReleaseFast
(the Debug binary is 16.1 ms/run, nowhere near 3,189 µs), so they are not part of the Debug
re-labelling — but they are a *shell loop*, and a shell loop measures `fork`+`exec` too.
Re-measured, min of two 500-run loops, ReleaseFast: **2.08 ms/run**, **1.50 ms/run** with
`--no-std-defs`, and `vera --version` in the same loop is **1.32 ms/run**, which is the process
floor and is inside both. Net of it the prelude is **0.76 ms vs 0.18 ms of a fresh process** —
the headroom is bigger than "~30%", not smaller. The in-process figure the bench prints for the
same shape (`contrib n=1`, `lint`, 186 µs) is the post-snapshot cost and agrees with the 0.18 ms.

### Wave 14 — the prelude runs once, and a near-miss miscompile — `35a60f2`

**Suite: 217/217 · torture 1162/1164 (2 XFAIL, 0 FAIL) · test-contract green.**

Measured on the merge with `zig build bench -- fixtures`, **output bytes byte-identical**.
**Every number in this table is DEBUG** — that invocation takes the default `-Doptimize`, and
wave 16 made the bench print its mode precisely because this was not visible here. The `before`
column cannot be re-measured (the code is gone); the `after` column re-measured in the mode that
ships is in the second table:

| phase | before (Debug) | after (Debug) | delta |
|---|---|---|---|
| pp | 902.5 ms | **181.9 ms** | −720.6 ms (**4.96×**) |
| lint | 2699.5 ms | **1969.0 ms** | −730.5 ms (−27%) |
| codegen | 2905.9 ms | 2202.5 ms | −703.4 ms |

| phase | after, ReleaseFast (wave 16, `bench -Doptimize=ReleaseFast -- fixtures`, 1164) |
|---|---|
| pp | **19.5 ms** |
| lint | **247.0 ms** |
| codegen | **266.2 ms** |

Annex D.2 + D.1 + Table E.1 were re-expanded from scratch on every compilation. They depend on
`std_defs` alone, so they now run once per process into a snapshot and are replayed. **The honest
number is 716 ms, not the 909 ms my estimate implied** — 79% of stage 1 was prelude; 186 ms
remains for user text, the memcpy and ~90 macro re-puts.

**The design I specified would have shipped a silent miscompile.** I said to cache the prelude
*bytes* and `@memcpy` them. The bytes are the smallest part of what those three `runFile` calls
produce — they also install ~90 `constants.vams` macros, three `diag.Bag` file registrations, and
`SourceMap` segments that name their file **by index into `Bag.files`**. Caching bytes alone
compiles, passes the determinism test, and **loses `` `M_PI `` for every model in the tree.**

Worse, and the reason the commit adds a test: **the existing determinism test cannot catch this
class of bug.** It compares two `process` runs, and after the change both take the cached path —
so a snapshot that dropped the macros is byte-identical in both and passes. I had called that
test "your first-line guard that a cache did not alias." It is not. The new test re-runs the
prelude the long way and compares text, segments, macro set *and* file registrations.

Also spent five known bounds statically per standing rule 0. The two that matter are reported as
**counts, not times**, because they are per-diagnostic and below the bench noise floor — which is
the honest way to state them. `placed` drops one arena alloc per rendered diagnostic; and
`didYouMeanMap`'s comment claimed its collect was needed "so the tie-break sees every candidate",
but the tie-break is a running minimum over a total order and **a test already asserted the
order-independence** — one alloc per suggestion at 11 call sites, gone. `editDistance` scratch
1560 B → 195 B, losing two ~520-byte row copies per input character. Where a bound is *not*
proved, it is now named as a ceiling instead of assumed.

Other corrections: `std.once` does not exist in Zig 0.16 (I specified it); `include_dirs` is not
part of the prelude key, so this is a snapshot keyed on nothing rather than a cache — which is
what keeps it inside standing rule 0 instead of becoming the unbounded cache the rule warns
about.

### Waves 12 + 13 — −950 lines, and two premises that were wrong — `7290679`

**Suite: 216/216 · torture 1162/1164 (2 XFAIL, 0 FAIL) · test-contract green.**
Test count *falls* 221 → 216 because the deletions took their own tests with them (4 inside
`eval_batch.zig` grading its own `TestDiode`, 2 for `root.Compilation`, +1 new).

**Wave 12 deleted 950 lines of Zig** in the mandated order — privatize, then `eval_batch.zig`
(702 lines publishing a second, incompatible device ABI no host could use), then
`root.Compilation`, then re-verify citations. The order matters: four items edit `src/root.zig`,
and a cheapest-first sort does the cheap one three times.

Three plan errors, all caught by building it:
- **`pub` had to stay on five names, not four.** `tests/bench.zig` calls
  `vera.Preprocessor.process` to time stage 1 — and wave 8 created that file *after* the
  "only four are reachable" measurement was taken.
- **`pub const FloatMode` must NOT be added.** I insisted the commit would not compile without
  it; both uses spell `proof.FloatMode`, qualified through a const that stays in scope after
  losing `pub`. Adding it would have landed a pub member with no consumer — in the commit whose
  subject is deleting exactly those.
- **My acceptance criterion was unsatisfiable as written.** "Zero emitted device text changed" is
  impossible when `str_kernels.zig` is `@embedFile`d byte-for-byte into every §9.5-using device,
  so removing its citation to a just-deleted file *necessarily* moves emitted bytes. The
  checkable criterion is zero emitted **code** changed: measured 0 of 740 by comment-stripped
  diff.

Both deletions' measured prose is preserved in TODO.md §2 with its numbers — the batch
evaluator's 14 wrong CSR cells and 3.05 vs 3.04 ms, and the three design answers the incremental
cache had already bought — so the next person re-derives neither.

**Wave 13's headline is that its own premise was wrong.** Two-slot `disc_of` does *not* decide
XFAIL-1: Annex F.2 step 4.b's candidate list is **domain-filtered, not arrival-ordered**, and the
mixed-port bullet needs a segment from the *other* domain. The fixture's signal has three
segments `{continuous, continuous, discrete}`; two arrival slots hold the two continuous ones and
drop the discrete witness the error is *about*. It would have "passed" only because that fixture
happens to instantiate its continuous leaves first — a member with no consumer **and** a shape
that has to change again. The agent kept a single `StrId` and wrote XFAIL-1's three real
remaining costs into §1.

Likewise my `grep "ddt(I("` = 0 understated item 4's blast radius: the real predicate is "a
potential contribution whose *resistive* half is zero", which `V(out) <+ ddt(V(dt[k]))` also
satisfies — so `analog_genvar_loop.va` was **already standing on the bug and passing**.

Measured, not estimated: `declaredDiscipline` on a 20,001-instance chain, `vera --check`
**8.10 s → 7.49 s** (−7.5%), with the run-to-run spread collapsing (10.22/8.10 → 7.50/7.49).

### Wave 11 — identity from structure, not from the printed name — `91f6e03`

**Suite: 221/221 · torture 1160/1162 (2 XFAIL, 0 FAIL) · test-contract green.**
The `gnd` XFAIL wave 10 opened is **closed**, so XFAIL goes 3 → 2. It XPASSed first, and an
XPASS fails the run — the protocol working exactly as designed.

`node_voltages` was one string key space holding user nets, §5.4.2 branch flows, §5.4.3 port
flows, §6.5.2 vector elements and §6.7 flattened paths, with three comments claiming collisions
were impossible. Now: a `NodeKind` union carrying the tolerance node as payload, a
`FlowKey{hi,lo}` map so a branch is keyed on its node **pair**, and `node_voltages` holding nets
only — which is what every one of its callers already meant. `codegen.isFlowUnknown` is an array
read instead of `startsWith("flow(")`; `abstolOf` reads a payload instead of re-parsing
`flow(a,b)` back apart.

**Two plan errors found by building it — the first would have silently sunk the wave:**

1. **There is a FOURTH site.** `codegen.buildNames` formats `flow(hi,lo)` and matches it against
   `node_order` *as a string* to find lowering's slot. After the key split landed in lowering the
   fixture was **still XFAIL** — both branches format `flow(a,gnd)`, so the aliasing simply moved
   down to the codegen layer. My plan listed three sites plus `tb`.
2. **A `{kind,name}` composite key does not close the hole**, which my acceptance criterion
   implicitly assumed it would. Splitting identity from spelling makes two slots legitimately
   want *one* spelling — the reference node and a net called `gnd` — and the emitted `U` has one
   member per slot. A spelling uniquifier is required, not optional.

The escaping was also cheaper than I specified: done in `parser.internTok`, all five join sites
are correct unchanged, so `elaborate.zig`'s diff is 14 lines of comment and `lower.flatName` is
untouched.

**Zero transcript diffs, proven not asserted**: all 1161 fixtures emitted by a pre-change binary
saved before any edit, and by the post-change binary. Exactly two files differ — the fixture
under test (one line: which unknown `I(a,gnd)` reads) and the new one.

Wave 12's documentation half landed alongside: 11 dangling `.html` citations and 7 `(ch.N)`
parentheticals retargeted individually, plus **`tools/source_guards.zig`** — two guards, each
demonstrated failing on a planted violation. Guard (b) walks the real import graph from both
roots and is what makes a 702-line orphan structurally unrepeatable rather than a one-time
cleanup. Citations in this repo are now machine-checked.

**A correction I owe:** I told the agent to add provenance to `// CORPUS:` lines. Those do not
exist — `grep -rn "CORPUS" src/ tools/ tests/` returns 0 hits. I passed that claim on from the
audit without verifying it. The agent found the *real* provenance in git history instead
(`git log -S`, deleted `tests/baseline.sh`): the 38 foundry models live in the ARPice host repo
at `../ARPice/src/devices/models`. One number — `unit_plan.zig`'s 14,930 of 16,242 temps — has
no attributable model, and the comment now says that rather than implying a source.

### Wave 10 — characterization, and the pins bite — `94bf67c`

**Suite: 219/219 · torture 1158/1161 (3 XFAIL, 0 FAIL) · test-contract green.** +4 fixtures.

The bar this wave was that every test arrive with a **named one-line mutation that makes it
fail**, applied and shown. All did. Two of those mutations measure how blind the suite was:

- Respelling a §6.5.2 vector element (`vecElem`'s `"{s}[{d}]"` → `"{s}__{d}"`) was noticed by
  **exactly one of 216 tests** — the new one.
- Dropping `cloneExpr`'s ternary else-arm clone left **every fixture green** before this wave.
  Now it prints `got=5 want=2`.

**XFAIL went 2 → 3, deliberately.** A net *named* `gnd` that is not *declared* `ground` aliases
`I(a)` and `I(a,gnd)` onto one unknown — `flowUnknown` formats `nodeName` into the branch key and
`internNode` dedupes by that string. Measured: KCL forces +1 mA and −1 mA on the two branches,
and the emitted `U` carries one flow member for both. `//! xfail` is the only honest verdict:
`//! reject` would invert the fixture (the LRM permits a net called `gnd`), and green-pinning
today's numbers would freeze +1 mA where the LRM says −1 mA. Wave 11 closes it; the day it does,
the fixture XPASSes and fails the run, which is the point.

`cg_limit.zig`'s `helpers_txt` string literal became a real `limit_kernels.zig`, so all six
kernel files are now `@embedFile`d **and** `@import`ed — the property that makes "the rows
checked here are byte-for-byte the code that runs there" actually true. Nothing in the tree
executes `D.limit` (`tb.zig` emits only `updateState`/`display`/`eval`/`q`), so those 15 rows
test the kernel directly because nothing else can.

**Agent corrections:**
- My `%l` fix named the wrong file. `lower.zig`'s `checkFormatPairing` **already** handled `'l'`;
  the arm needing the widening was `cg_display.translateFormat`'s.
- I cited §9.4.2 for format specifications. It is **§9.4.3**; §9.4.2 is escape sequences.
- My WAVE-PLAN line numbers for the two `lower.zig` spelling assertions were **26–31 low** — the
  cited range is a §5.4.3 reject test containing no `"flow("` literal at all.
- `//! bias I(a,b)` is `error.BadSyntax`: `parseBindings` splits on `,` before `unknownName` sees
  it, so `tb.zig`'s comma arm is live for `sweep`/`wave` and dead for `bias`/`param`. My
  "third site" framing was "one and a half sites". Pinned with an `expectError` for wave 11 to
  decide deliberately.
- A pre-existing §9.5.4.2 gap found but not fixed: `checkScanFormat` accepts `o h x b c` (not in
  the clause's table) and refuses `r` and `m` (which are in it). Real conformance gap, logged.

### Wave 9 — the five host-visible bugs — `4d6207c`

**Suite: 215/215 · torture 1155/1157 (2 XFAIL, 0 FAIL) · test-contract green.**
Five fixtures added, all passing (1152 → 1157 total).

Four agents in parallel worktrees. All five bugs share one property, which is why seven waves
of conformance work never saw them: **the suite grades VerA's own testbench**, so a defect
living in the artifact handed to a host is structurally outside its view.

| Bug | Before | After |
|---|---|---|
| `\|U\| > 256` | `--emit-zig` exit 0; **host's** build dies on `enum tag value '256' too large for type 'u8'` | E1003 at `emitTopology`, exit 1. Boundary measured exact: 256 emits and passes `--check`, 257 refuses |
| `--display=drop` | `const t0: i64 = S.con(0.0);` — **nine ch09 fixtures shipped devices no host could compile, while scoring green** | `const t0: i64 = @as(i64, 0);` |
| SPICE keyword nodes | `.SUBCKT AMP (INPUT OUTPUT)` → E0208 in a file the user never wrote | spelled as §2.8.1 escaped identifiers; Annex E.3 connects by order so the spelling is never typed |
| Parameter defaults | 9 of 9 assertions `got=0`, exit 0, no diagnostic | 9 of 9 pass |
| `sysFuncTy`/`callTy` | the pair whose comment says "MUST agree" disagreed on two rows | agreement is now a looping test, not a hope |

Plus two trust-boundary one-liners: `parameter real p = 1 from 5;` reached a debug `assert`
(**UB rather than a panic in ReleaseFast** — undefined behaviour driven by a source file), and
a string parameter drew two spurious W0651.

**Agent corrections to my spec, all verified:**
- I estimated the `sysFuncTy` change would touch "~6 fixtures". Measured: **2**. The agent swept
  `--emit-zig` over all 1152 fixtures with both binaries and diffed — exact, and cheaper than
  the full torture run I claimed it justified.
- My prescribed fix for the parameter fold was **insufficient**. Lifting arms into the MIR
  folder fixes `(1 << w) - 1` and `(w > 2)` — the two cases I reproduced — but leaves
  `(w > 2) ? 5 : 6` at 0, because `lowerTernary` builds a CFG diamond and a phi, not a
  `select`, so a MIR value-fold can never see it. Needed `ParamInfo.folded` carried from
  lowering.
- I said to route the `from 5` assert to "the existing E0210". The agent opened E0210, found it
  says *"expected `)`"* — which does not state this condition — and correctly used E0207
  instead, citing my own rule back at me.
- **No fixture can grade `--display=drop`.** `torture.zig` hardcodes `.display = .emit` and
  `tb.Directives` has no field for the mode. That is *precisely why* nine ch09 fixtures shipped
  broken devices for seven waves. The grader is a codegen unit test instead.
- WAVE-PLAN's "`annex_e_spice` stays 42/42" was off by one; that group was **41/41** before.

### Wave 8 — the instrument, and the number decode — `b47ed53`

**Suite: 209/209 · torture 1150/1152 (2 XFAIL, 0 FAIL) · test-contract green.**

Two agents in parallel worktrees, merged and then verified on the union (neither had tested
against the other; the union count is 209, which is why neither agent's own number was right).

- **`tests/bench.zig` + a `bench` step now exist.** Four phase timers on existing seams, curve
  at n = 1/8/64/512/4096, TSV on stdout, N=25 report min. It **can fail**, demonstrated rather
  than assumed: reverting `writeIfChanged`'s content compare trips its `expected 0, found 4`
  assert. This is now the gate on every performance claim in the repo.
- **`tests/external.zig` was running in no step.** Wired into `test_step`. It had NOT bit-rotted
  (I predicted it might).
- **Round-once decode landed.** `2.2n` is now one `parseFloat` of the joined text. Deleted
  `siScale`, three duplicate scanners, and `TestLex` — a 104-line second lexer that the parser
  tests were running against instead of the real one. Net −247 lines.

**The measured curve — nothing in this compiler is quadratic. ALL DEBUG** (wave 16: this run
predates the bench printing its mode, and `zig build bench` with no `-Doptimize` is Debug; the
same curve in ReleaseFast is TODO.md §2's table, ~8–12× smaller and the same shape):

| axis | n=1 | 512 | 4096 | 512→4096 |
|---|---|---|---|---|
| contrib | 1.32M ns | 14.1M | 104M | 7.4× |
| vals | 1.30M ns | 10.5M | 84.5M | 8.0× |
| inst | 1.33M ns | 25.3M | 206M | 8.1× |

8× input → 7.4–8.1× time out to 4096, including elaboration-by-flattening (4096 instances =
206 ms Debug, ~50 µs each; 23.8 ms ReleaseFast, ~5.8 µs each). **This retroactively killed
several O(n²) findings from the original audit** — and the ratio, which is the whole argument,
is a ratio within one mode and does not move. Evidence beat argument, which is what the bench
was for.

### Tier 0 cleanup — `783259c`, `25286ba`, `6bb63ba`

- **`diag_code.info`: 16,848 B of Debug `.text` → 124 B** (136×), test binary 42 MB → 17 MB.
  The 233-arm switch is now evaluated at comptime into a `[235]Info` table. Kept BOTH properties
  the old code had: it still fails to compile on a missing arm, and still binds code→text by
  name (a hand-written array literal would bind by position, where one misplaced entry silently
  prints E0313's explanation under E0314).
- **Deleted `compilePreprocessed`** — a `pub fn` in the library API that **did not compile**
  (passed 7 args to a 10-param function). It survived because `root.zig` was absent from its own
  `refAllDecls` guard list. Fixed at the root: `@This()` joins the tuple.
- **Deleted `ifconv.zig`** (228 lines). `root.zig` called it "a complete MIR→MIR pass"; it was
  not complete. Its `terminatorOf` took the last instruction in a block, while `ssa.zig`'s
  consumer contract explicitly guarantees a `.phi` can sit *after* the terminator — so it saw
  1 of 428 branches.

---

## Decisions taken without asking

Per standing instruction. Each is reversible; each has a reason.

1. **Refined the "never allocate" rule to "never allocate for a KNOWN size"** (`14c3886`).
   Applied literally it would have broken two things this tree already gets right: the codegen
   output buffer is deliberately gpa-backed because an arena cannot regrow in place
   (`root.zig:46-48`), and a fixed buffer that can overflow is worse than the allocation it
   replaced (the 512-byte `$sformat` site is a registered ceiling with a collision hazard). The
   checkable form is now one question per site: *what is the bound, and where is it written
   down?*
2. **T0.6 was reclassified from "free deletion" to a decision.** It changes emitted device text.
   See "Where I was wrong" below.
3. **Agents are forbidden from running `zig build torture` in parallel.** It spawns a child
   `zig build-exe` per fixture across 1152 fixtures; four concurrent runs would thrash the
   machine and make every bench number worthless. Agents verify their own fixtures directly
   against `./zig-out/bin/vera`; I run one integration torture after merging.
4. **Deleted an audit agent's uncommitted experiment** rather than landing it. It was a
   half-finished T0.6 in `parser.zig` that broke `codegen.zig:5526`. The lesson it taught is
   recorded as wave 8 item 1, and the experiment itself was replaced by a correct
   implementation.

---

## Where I was wrong — corrections to things I asserted earlier

Kept because a plan whose errors are invisible is worse than one with none.

1. **"T0.6 is a free deletion, no behavior change."** Wrong twice over. Routing the parser
   through `lexer.parseReal` changes emitted device numbers, and `codegen.zig:5502` pins the old
   value. Worse, deleting the parser's over-scan **silently downgraded three normative §2.6.1
   reject fixtures** (`4' h5`, `8'y11`, `4af`) to a wrong diagnostic — first torture run was
   1147/1152 with 3 FAIL. Each of those fixtures *argues its clause*; re-blessing them would
   have traded a §2.6.1 message for a fix-it offering to insert a semicolon inside a number.
   Fixed in the parser (`gluedNumberText`), and the first cut of *that* broke a fourth fixture
   (`1g`, which the fixture states outright is "the integer 1 followed by an identifier").
2. **"TODO.md's 207/207 is stale."** It was accurate at wave 7. *I* made it stale by deleting
   exactly two tests and not updating the number. Now 209/209, measured on the merge.
3. **"`zig build test` is green"** — asserted while the tree was dirty with an agent's edit. It
   was 204/205. The clean tree was green, but I had not checked the tree was clean.
4. **I specified `std.time.Timer` in the bench spec. It does not exist in Zig 0.16.** The agent
   replaced it with `Io.Timestamp.now(io, .awake)`.
5. **I specified four disjoint phase timers.** They cannot be disjoint without adding entry
   points that exist only to be timed — the API the doctrine deletes. Each row is a prefix of
   the next; the reader subtracts.
6. **I suggested `ifconv` might be "part of the SIMD story."** It is the opposite: its own header
   insists arms stay lazy, and a lazy select is still a branch. It cannot produce branch-free
   code.

---

## In flight

Nothing. The queued sequence (waves 8–14) is complete. See "What is left" below.

**The two miscompiles that motivated wave 9** (reproduced by hand before the fix):

```verilog
parameter integer w   = 4;
parameter integer a2  = (1 << w) - 1;   // expect 15 → emits 0
parameter integer cmp = (w > 2);        // expect 1  → emits 0
```
Exit 0, no diagnostic. `analysis.zig:697`'s `else => null` covers shifts, all six relationals,
bitwise and logical ops. A real `hfet2.va` ships 4 wrong parameters this way.

And `codegen.zig:861` emits `pub const U = enum(u8)` with nothing bounding `u_names.len`, so a
>256-unknown model compiles clean here and dies in the *host's* build.

Both were invisible to the suite for seven waves because **the suite grades VerA's own
testbench** — bugs living in the artifact handed to a host are structurally outside its view.
Both are fixed and pinned as of `4d6207c`.

---

## What is left

The queued sequence (waves 8–15) is **complete**. Every item is landed or measured-and-refused.

**The one thing I would do next, and it is measured, not guessed:** cache the prelude's
*parsing*, not just its preprocessing. Wave 15 measured that 87% of fixture-batch lint is a
per-compilation constant — 211.7 µs (ReleaseFast) spent producing 237 bytes of MIR — because every
compilation re-lexes, re-parses and re-lowers the same ~11.8 KB of expanded Annex D/E. Measured
headroom: `vera --lint` on a 6-line model is 3,189 µs, and 2,235 µs with `--no-std-defs`. **~30%**
— and wave 16 re-measured it net of the 1.32 ms `fork`+`exec` those two numbers both contain
(2.08 vs 1.50 ms/run, ReleaseFast, min of two 500-run loops): **0.76 vs 0.18 ms**, so ~30% is a
floor, not the estimate.
It is strictly harder than wave 14 (an AST and a MIR borrow the arena and the interner, where the
prelude snapshot borrowed nothing), which is why it is a wave and not a patch.

**Refused, with numbers, so nobody re-derives them** (all now in TODO.md §2): the Air-shaped MIR
row (below the noise floor); a batch/SIMD evaluator inside VerA (14 wrong CSR cells, 3.05 vs
3.04 ms, prefetch slower); the `contributions` full-table scans (max `<+` count across all
fixtures is 8); `RVec(N)` (the shipped `eval` takes scalar `*const Model`, so N lanes are N bias
points of one instance, never N instances).

**Still open, and honestly costed in TODO.md §1:** the two XFAILs. XFAIL-1 (Annex F.2 step 4.b)
needs domain-partitioned discipline slots, `connectrules` past E0201, and a mixed-port predicate
that does not exist — wave 13 proved the "two-slot" shortcut I proposed would not have worked.
XFAIL-2 (§9.4 display operand re-timing) re-times what two-thirds of the suite prints.
