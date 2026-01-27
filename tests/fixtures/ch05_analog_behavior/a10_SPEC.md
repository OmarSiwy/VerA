# A10 — Analog event scheduling and host queries

Row A10 of `/home/omare/Documents/Projects/Zig/ARPice/docs/verilog-ams-conformance-plan.md`:

> - Honor dynamically changing timer start/period/enable controls, crossing
>   tolerances, breakpoint requests and step bounds in host scheduling.
> - Implement required simulation/hierarchy queries with actual host values and
>   correct dynamic-name, unknown-name and default behavior.
> - Test off-grid events, disabled/re-enabled timers, canceled wakeups, rejected
>   trial points, multiple analyses and hierarchical query paths.

Greenfield: no `w2/*` branch covers it. 12 `.va` fixtures plus 3 host decks are
written here. **8 of the 15 fail today** (fixtures 01, 03, 04, 07, 08, 09, 10,
12); the other 7 pass. What each passing file still excludes is stated per
fixture in the table below — "it passes today" is not by itself a reason to
keep a file, and the four kept `.va` pins are kept because each one names a
wrong implementation it rejects, not because it was already green.

**None of the three host decks fails**, and that is a statement about the host,
not about the decks: breakpoint placement, `$bound_step` and cross() timestep
control are all implemented in ARPice today. The decks pin them; they do not
push on them. The row's live pressure is entirely on the VerA side. See
"Host side" below for what was measured, with which binary, and why that
binary is not reproducible from source today.

## LRM clauses covered

Read from the offline HTML in `/home/omare/Documents/Projects/Zig/VerA/docs/`.

| clause | title | file |
|---|---|---|
| §5.10.3.1 | cross function | `ch5-analog.html` |
| §5.10.3.2 | above function | `ch5-analog.html` |
| §5.10.3.3 | timer function | `ch5-analog.html` |
| §9.15 | Analog Kernel Parameter System Functions (Table 9-27, Table 9-28) | `ch9-system.html` |
| §9.16 | Dynamic Simulation Probe Function | `ch9-system.html` |
| §9.17.2 | `$bound_step` Task | `ch9-system.html` |

Supporting, cited inside headers but not pinned on their own: §4.5.14
(constant vs dynamic arguments — Table 4-20 covers the clause-4 operators and
does **not** cover the clause-5 events, which is why the dynamic-period fixture
is legal), §4.6.1 (analysis names), §6.7 (hierarchical names).

## Ground truth established before writing (not from COVERAGE.md)

**Implemented, and previously unpinned by any fixture.**

| claim | where | evidence |
|---|---|---|
| timer breakpoints reach the host | `lib/backend/codegen.zig:7635 emitNextBreakpoint` → `tb.zig:1182` / `ARPice/src/analysis/Circuit.zig:699` | the host lands rows at *exactly* `2.5e-4` and `6.25e-4` — dumped from `/tmp/a10_bp.raw`, both coordinates bit-equal to the literal |
| `$bound_step` reaches the host | `codegen.zig:7156` writes `inst.bound_step`; `ARPice/src/analysis/tran/tran.zig:615-629` reads it | max accepted `dt` = `5.000000000000013e-05` on `a10_bound_step.sp`, exactly `0.05/freq`; the deck's own ceiling was `2e-5`… and would have been `2e-4` without it |
| a cross() is resolved sharply | `ARPice/src/analysis/tran/tran.zig:605-613` (`stateCtl(.query)` reject-and-shrink) | the latch in `a10_cross_timestep.sp` switches at `t = 5.0000005117e-4`, 0.5 ns past a crossing at `5e-4` |
| tolerance-without-direction is refused | E0517 | `error[E0517]: … a tolerance is given but the direction slot is empty` |
| `$simprobe` resolves a sibling *parameter* | `lib/ir/lower.zig:9150 lowerSimprobe` | fixture 09 claim 2 reads `got=2` |
| `$simparam$str` with a *foldable* string variable | constant propagation, then `codegen.zig:5588 strArg` | fixture 07 claims 1-3 pass |

**Not implemented.** Each is a fixture below, and each was confirmed by running
it, not by reading a doc:

1. `cross(expr, dir)` with `dir` outside `{-1, 0, +1}` fires as if `dir` were 0.
   `Gen.crossTest` (`codegen.zig:5279`) switches `+1 / -1 / else`, and the
   `else` arm is the both-edges test.
2. A timer whose `period` is a solved quantity is **refused** — `error[E0515]`,
   citing "LRM 4.5" — and, before the refusal, schedules from a frozen value.
   §5.10.3.3 requires the opposite in as many words.
3. A negative `time_tol` on `timer()` compiles clean. §5.10.3.3 says the
   tolerance "shall be non-negative"; §9.17.2's identical rule for
   `$bound_step` is already refused as E0803, so this is an inconsistency
   inside VerA and not only against the LRM.
4. `$simparam$str("module")` answers the **flattened top** module's name at
   every depth (`codegen.zig:5595` returns `self.mir.name`); `"instance"`,
   `"path"`, `"analysis_name"` and `"cwd"` all answer `""`, and Table 9-28 has
   no "if they support the parameter" escape.
5. `$simparam`/`$simparam$str` with a name the **solution** chose falls back to
   the empty name. §9.15 admits "a string literal, a string parameter, or a
   string variable" with no foldability qualifier.
6. `$simprobe` cannot read an **output variable** — `lowerSimprobe` looks the
   pair up in `param_index`, the parameter table — although §9.16's subject is
   literally "an output variable named param_name".
7. `$simprobe` resolves **paths from the top**, not siblings of the caller. A
   probe written one level down misses its own sibling and hits a stranger.
8. A `start_time` that is **not in the future** still gets the single-shot fire.
   §5.10.3.3 conditions it — "shall trigger only once at the specified
   start_time (*if the start_time is in the future with respect to the current
   simulation time*)" — and `@(timer(-1n, 0))` fires once at t = 0 today. Added
   to fixture 01 after review; measured `got=1 want=0` on all five rows.

## Fixtures

Ordered; "today" is the observed verdict of the run command at the bottom.

| fixture | pins | expected value and derivation | today |
|---|---|---|---|
| `01_timer_nonpositive_period_fires_once.va` | §5.10.3.3 "the timer shall trigger only once at the specified start_time (if the start_time is in the future with respect to the current simulation time)" — both halves of the sentence, including the parenthetical. | `zero_fired = neg_fired = 0` at t = 0 and 1 ns, `= 1` at 2, 3 and 5 ns. Both timers start at 2 ns; the start time is in the future for the first two rows, fires on the third ("at that time point, the event evaluates to True"), and a non-positive period forbids a second fire. `0` and `-1n` are written separately because a `next += period` implementation leaves one stuck and walks the other backwards. Third counter, added after review: `timer(-1n, 0)` names an instant behind every row of the run, so the parenthetical's condition is false throughout and `past_fired = 0` on all five rows. It demands *fewer* events than HEAD raises, so it cannot be satisfied by loosening an event test. | **fail** — `past_fired = 1` on every row (fires once at t = 0); the two period claims pass |
| `02_timer_enable_resumes_on_grid.va` | §5.10.3.3 "it will start generating events once enable returns to being nonzero **as if it had never been disabled**". | counts `0, 1, 1, 1, 2, 3` at t = 0, 1, 3, 5, 7, 9 ns. `timer(1n, 2n)` fires on the absolute grid 1/3/5/7/9 ns; the enable (`V(en) > 0.5`, driven by `//! wave`) is low at 3 and 5 ns. The 7 ns row is the claim: a schedule frozen while disabled would owe the 3 ns fire and be shifted, a restarted one would next fire at 8 ns and read 1 at 9 ns. Excludes both of those, and a tool that reads timer()'s fourth argument as anything but the enable (which reads 0 everywhere). | **pass** — kept as a pin |
| `03_timer_dynamic_period.va` | §5.10.3.3 "If the start_time or period expressions change value during the evaluation of the analog block, the next event will be scheduled based on the latest value". | counts `1, 2, 3, 3, 4` at t = 0, 2, 4, 6, 8 ns. `per` is 2 ns until `V(ctl)` steps high at 4 ns, then 4 ns: fires at 0 (next 2n), 2n (next 4n), 4n (period is now 4n, next 8n), nothing at 6n, fires at 8n. A frozen period reads 4 at 6 ns; a retroactive `k*period` grid reads 2 there. | **fail** — reads 1 at every row, then `error[E0515]` refuses the whole file |
| `04_cross_direction_out_of_range_is_inert.va` | §5.10.3.1 "For any other values of dir, the cross() function does not generate an event and does not act to control the timestep", restated as "there are two ways to disable the cross function … giving a value other than -1, 0, or 1 to dir". | `n = 0` and `held = 0.0` at all three rows, exactly. `V(p)` walks 0 → 0.5 → 1.5, so `V(p)-1.0` has one rising crossing that a `dir` of +1 or 0 would catch; `dir = 2` must catch nothing. | **fail** — `n = 1`, `held = 1.5` |
| `05_cross_tolerances_are_not_the_enable.va` | §5.10.3.1 tolerance arguments: non-negative, "If a value of zero (0.0) is specified, the simulator shall apply a suitable value", the box the event must land in, and "there are two ways to disable the cross function, either by specifying enable as 0, or giving a value other than -1, 0, or 1 to dir". | `n_tol` and `n_zero` both `0, 0, 1` over the same ramp; the captured sample lies in `[1.0, 1.5]` (the clause's box: at or after the crossing value 1.0, at or before the last declared point). Third counter, added after review: `cross(expr, +1, 0, 0, 0)` — the same call with Syntax 5-16's *fifth* argument written as 0 — stays `0` on every row. (b) and (c) differ only in whether the enable slot is written and are required to answer differently, which is what turns "argument 4 is `expr_tol`, not the enable" from prose into an assertion. Excludes: a tool that borrows timer()'s `(start, period, time_tol, enable)` order for cross(), and a tool that ignores the enable argument. | **pass** — kept as a pin; the companion disabling rule (a `dir` outside `{-1,0,+1}`) is fixture 04, which fails |
| `06_above_fires_in_dc_sweep_cross_does_not.va` | §5.10.3.2 "During a dc sweep, the above() function shall also generate an event when the expression crosses zero from below" together with "The cross() function will not generate events for non-transient analyses". | over the sweep `V(p) = 0, 0.4, 0.6, 1.0` against a 0.5 threshold: `n_above = 0, 0, 1, 1`, `n_cross = 0` throughout, `held = 0.6`. The 4th point is edge-triggering: the expression was already positive, so no second event — which is what separates `above()` from `expr > 0`. Excludes three wrong tools in one run: one that raises no analog event outside a transient (`n_above` stays 0), one that lowers `above()` as a level test (`n_above` reads 2 on the 4th point), and one that treats `cross()` and `above()` as synonyms (`n_cross` moves). | **pass** — kept as a pin |
| `07_simparam_dynamic_name.va` | §9.15 "The argument param_name is a string value, either a string literal, a string parameter, or a string variable", plus Table 9-28 `analysis_type` and the unknown-name fallback rule. | `$simparam$str(nm) == "dc"` for `nm = "analysis_type"` (§4.6.1 spelling, `//! analysis dc` picks it), the literal form agrees, `$simparam(nm, 2.5) == 2.5` exactly for an unknown name, and the same query with a name chosen by a ternary on `V(p)` still answers `"dc"`. | **fail** on the solution-chosen name only (the other three pass and pin the folded path) |
| `08_simparam_str_hierarchy_names.va` | §9.15 Table 9-28 `"module"` = "the name of the module from which $simparam$str is called", `"instance"` = "the hierarchical name of the instance", with the clause's own `dut` / `testbench.dut1` example fixing the spelling. | inside the child: `"a10_simstr_child"` and `"a10_simstr_top.u1"`. Inside the top: `"a10_simstr_top"` — the control, since a flattened elaboration gets that one right for free and without it the two readings are indistinguishable. | **fail** on both child claims |
| `09_simprobe_reads_a_sibling_output_variable.va` | §9.16 "queries the simulator for **an output variable** named param_name in a sibling instance", "The intended use of this function is to allow dynamic monitoring of instance quantities". | `$simprobe("u_dev","id") = 1.0` — `V(a,b) = 0.75 − 0.25 = 0.5` exactly from the `bias` line, times `gain = 2.0` from the instantiation — and `$simprobe("u_dev","gain") = 2.0`. Fallbacks of −1.0 keep the file runnable so an unresolved probe shows as `got=-1` instead of a compile error. | **fail** on the output variable; the parameter half passes |
| `10_simprobe_scope_is_the_parent.va` | §9.16 "the simulator will look for an instance called inst_name **in the parent of the current instance** i.e. a sibling of the instance containing the $simprobe() expression". | three levels, monitor buried in `u_mid`: `$simprobe("u_a","gain") = 3.0` (its real sibling) and `$simprobe("u_mid.u_a","gain",-1.0) = -1.0` (not an instance in its parent, so §9.16's fallback). −1.0 is chosen because it is not 3.0: resolving that string *is* the defect. | **fail** on both, in opposite directions — `-1` where 3 is required, `3` where −1 is required |
| `11_cross_tolerance_without_direction_rejected.va` | §5.10.3.1 "If either or both tolerances are defined, then the direction shall also be defined." | refusal. `//! reject direction` — a named substring, not a bare `//! reject`, which `tests/torture.zig:223` would satisfy with *any* diagnostic. The word `direction` is what makes the message name the offending argument rather than merely the call. | **pass** (E0517) — kept as a pin; an unpinned refusal is one refactor away from becoming a silent default |
| `12_timer_negative_time_tol_rejected.va` | §5.10.3.3 "The tolerance (time_tol) … shall be non-negative", with zero already given its own meaning. | refusal. `//! reject non-negative`. | **fail** — compiles clean |
| `a10_timer_breakpoints.sp` (host) | §5.10.3.3 "The analog simulator **places a time point** within time_tol of an event." | rows at exactly `t = 0`, `2.5e-4`, `6.25e-4` carrying `v(out) = 0, 1, 2`. Two single-shot timers, both start times strictly between the deck's printsteps, so the coordinate exists only because the model asked for it; `selected_values` demands the exact coordinate, so a grid that merely straddles the event fails with `MissingCoordinate`. Start times are plain decimals, not `250u`, because a §2.6 scale factor is a multiplication and lands one ulp away. `selected_values` compares the axis with `==` (`test_correctness.zig:587`), so this is a bit-exact coordinate demand. Excludes any host that only straddles the event. | **pass** — re-run 2026-09-19: rows at `0.00025` → 1.0 and `0.000625` → 2.0, both bit-equal to the literal |
| `a10_bound_step.sp` (host) | §9.17.2 "the simulator shall ensure that the next time step taken is no larger than the smallest $bound_step() argument currently active", on the clause's own `vsine` example. | `v(src) = ±1.0` at `t = 2.5e-4` and `7.5e-4` (quarter and three-quarter cycle of a 1 kHz sine) to 3 %. The load is purely resistive, so no truncation-error control shortens a step and the grid is `dt_max = min(1e-3, 2e-4)`; honoured, `h = 5e-5` and linear interpolation near the peak errs by `(ωh)²/8 = 1.2 %`; ignored, `h = 2e-4` errs by 20 %. | **pass** — re-run 2026-09-19: 206 points, max `dt = 5.000000000000013e-05` (exactly `0.05/freq` to 2.6e-15 relative), interpolated `v(src)` = `+0.9905383996` at 2.5e-4 and `−0.9905383996` at 7.5e-4, i.e. 0.95 % off the peak against a 3 % band |
| `a10_cross_timestep.sp` (host) | §5.10.3.1 "cross() controls the timestep to accurately resolve the crossing" and "the event shall occur after the threshold crossing, and while the signal remains in the box defined by … expr_tol and time_tol". | `v(out) = 0` at `t = 4.99e-4` and `= 1` at `5.02e-4`. `PWL(0 0 1m 1)` is 1 V/ms, so the 0.5 V threshold is crossed at exactly `5e-4`; `time_tol = 1e-6` puts the whole event inside `[5e-4, 5.01e-4]`, and the samples sit 1 µs before and 2 µs after. The deck's step ceiling is `2e-5`, so a simulator without crossing control latches late and interpolates to something strictly between 0 and 1. | **pass** — re-run 2026-09-19: 80 points, `v(out)` switches at `t = 5.0000005117e-4` (0.51 ns past the analytic crossing, inside the 1 µs box), sampled `0.0` at 4.99e-4 and `1.0` at 5.02e-4, and the accepted grid shrinks from `dt = 2e-5` to `dt = 1e-9` around the event |

Reject fixtures: 2. Positive fixtures: 13. (The row's rule is at most as many
refusals as positives.)

## Corrected after review

The approval manifest flagged this row in §5.2 ("none fabricated"), §5.4
(already-passing fixtures) and §6 (host numbers measured against a stale
binary). What changed, and why:

1. **A citation that does not survive being opened — found here, not by the
   review.** `07_simparam_dynamic_name.va` cited **§3.3.1** for "a string
   comparison is an integer". **There is no §3.3.1**: `docs/ch3-datatypes.html`
   runs 3.2 → 3.3 *String data type* → 3.4, and the sentence that actually
   carries the claim is in **Table 3-3 inside §3.3** — "Str1 == Str2 Equality.
   … Result is 1 if they are equal and 0 if they are not." Header corrected to
   §3.3/Table 3-3 with the quotation, and the dead subclause named as dead so
   the correction is not silently absorbed. The manifest's "A10 — none
   fabricated" was one clause too generous.

2. **An argument position stated wrongly.** `05_…`'s header said "argument 4 is
   the enable, argument 3 is time_tol". For `cross()` that is false — Syntax
   5-16 is `cross(expr, dir, time_tol, expr_tol, enable)`, so the enable is
   argument **5**. Argument 4 is the enable in `timer()`, and the header had
   imported timer's shape into cross's clause. Corrected, and the two spellings
   are now contrasted explicitly, since that confusion is the failure the file
   exists to catch.

3. **§5.4, fixture 05 — the positional claim is now asserted, not narrated.**
   The file previously argued in prose that argument 4 is not the enable and
   then checked only tolerance-carrying calls, all of which fire. Added
   `cross(expr, +1, 0, 0, 0)`, which must fire on no row while the otherwise
   identical four-argument call fires on the last row. Two calls differing only
   in the enable slot and required to answer differently is the smallest thing
   that can state the rule. It also picks up the first of §5.10.3.1's "two ways
   to disable the cross function"; fixture 04 already had the second. Still
   passes at HEAD — see point 5 for why that is now recorded honestly rather
   than dressed up.

4. **§5.4, fixture 01 — real content, and it fails.** §5.10.3.3's single-fire
   sentence ends in a parenthetical the fixture had quoted and then ignored:
   "*(if the start_time is in the future with respect to the current simulation
   time)*". Added a third timer, `timer(-1n, 0)`, whose start time is behind
   every row of the run, asserting 0 fires. Measured at HEAD: `got=1 want=0` on
   all five rows — VerA fires it once at t = 0. This is a live conformance gap
   the row had missed, and it demands *fewer* events than HEAD raises, so it
   cannot be satisfied by weakening an event test. Fixture 01 moves from **pass**
   to **fail**; the row's live count goes 7 → 8 of 15.

5. **§5.4, the four remaining green `.va` pins and the three decks — relabelled,
   with the wrong implementation each one rejects named in the table.** 02, 05,
   06 and 11 stay because each excludes a specific wrong tool (a timer that
   restarts or freezes its grid across a disable; a cross that reads timer's
   argument order; a tool that treats `above()` as a level test or as a synonym
   for `cross()`; a `//! reject` with a substring rather than the worthless bare
   form). None of them is true of any compiler. The three decks stay for the
   same reason and with the same caveat made explicit in the opening section:
   they pin implemented host behaviour, they do not push on it, and the row's
   pressure is entirely VerA-side. Nothing was weakened to make a file pass, and
   nothing was deleted, because nothing in this row asserts something true of
   every implementation.

6. **§6 — the host numbers' provenance is now on the page.** ARPice does not
   build (`src/analysis/pss/hb.zig:286: root source file struct 'posix' has no
   member named 'getenv'`), so the documented `zig build` step in "Host side"
   was a command that does not work. The section now shows the failure, names
   the one binary that exists (path, sha256, mtime) and records that it was
   linked three minutes *before* ARPice HEAD. All three decks were **re-run
   against it on 2026-09-19** and every figure in the deck rows is read out of
   that run's `.raw` files, not remembered. `zig build test -- --filter a10_`
   has never run and is now labelled as a prediction checked by hand against the
   checker source, not as a test result.

7. **One finding handed on rather than shipped as a thin fixture.** A second
   `$bound_step` in the same analog block is refused with `E0201`, which is a
   real gap against §9.17.2's "smallest … currently active". No fixture was
   written for it: nothing in `tb.zig`'s fixed-grid evaluator can observe step
   control, so the fixture could only have asserted "it compiles". It is
   recorded under "Deliberately NOT covered" with the diagnostic and the reason,
   together with the negative probe that shows the *cross-instance* minimum is
   already correct in ARPice.

## Deliberately NOT covered

- **`absdelta`** (§5.10.3.4). The fourth monitored event, and the one VerA
  refuses outright with a capability message (E0513, and
  `docs/CLAUSE-AUDIT.md:505` already records that the clause must not be
  counted). It is a whole operator, not a scheduling corner; it belongs to
  whichever row implements it.
- **`initial_step` / `final_step` across multiple analyses** (§5.10.2, Table
  5-1). The plan line says "multiple analyses"; Table 5-1 is a 5-column × 13-row
  matrix whose rows are *analysis kinds*, and the generated testbench runs one
  `//! analysis` per file. Pinning it properly means one fixture per column, in
  a row that owns global events.
- **`$simparam` values that are the host's** — `gmin`, `scale`, `gdev`,
  `imax`, `imelt`, `simulatorVersion`. Table 9-27 is prefaced "if they support
  the parameter" and fixes no number, so any digit written here would record
  VerA's defaults rather than the LRM;
  `tests/fixtures/ch09_system_tasks/22_simparam.va` already says so in its
  header and this row does not reopen it. `"iteration"` is the one row whose
  value moves, and it is A09's (Newton lifetimes), not A10's.
- **Table 9-28 `"path"`**. The clause's example only shows it from inside a
  named task (`testbench.dut1.mytask`) and says nothing about what a call
  sitting directly in an `analog` block appends. `"cwd"` and `"analysis_name"`
  are likewise unpinned: `cwd` is the host's filesystem and `analysis_name`
  ("tran1", "mydc") is a name the deck gives an analysis, which these decks do
  not.
- **Canceled wakeups and rejected trial points as such.** Both are host-internal
  events with no observable in a `.raw` file: the `selected_values` and
  `samples` checks see the *accepted* grid only. `a10_cross_timestep.sp` is the
  closest reachable statement — the reject-and-shrink loop in
  `tran.zig:605-613` is what produces its 0.5 ns resolution — but a fixture that
  counted rejections would have to read a counter the host does not export.
- **More than one *simultaneously active* `$bound_step`** — §9.17.2's "the
  simulator shall ensure that the next time step taken is no larger than the
  smallest `$bound_step()` argument currently active" only has content when
  several bounds are active at once. Two findings, both from probes run
  2026-09-19 and neither turned into a fixture:
  - Two calls in one analog block are **refused** by VerA:
    `error[E0201]: construct is not in the supported subset: $bound_step`
    on the second call. That is a live gap against the clause's own wording, but
    a `.va` fixture for it could assert nothing beyond "it compiles" —
    `tb.zig:695` walks the declared `//! time` list and cannot observe step
    control at all — so it would be a fixture with no teeth, and the rule is that
    those get deleted, not shipped. It belongs with whichever row can observe an
    accepted grid.
  - Across *instances* the host is already right: a deck with a `0.05/1000 =
    5e-5` bound and a second instance bounding `0.01` accepted a grid with max
    `dt = 5.000000000000013e-05`, i.e. the minimum won. No fourth deck was added,
    because it would have passed on arrival and pinned nothing new.
- **`$bound_step` below the minimum step** ("If the value is less than the
  simulator's minimum allowable time step, the simulator's minimum time step
  shall be used instead"). The minimum is explicitly the simulator's own
  ("refer to the simulator's documentation"), so there is no LRM number to
  assert; what a fixture could assert is that the run still terminates, which is
  a liveness property this harness does not express.
- **The second half of §5.10.3.1's pairing rule** — "If expr_tol is specified,
  time_tol shall also be specified". Same shape and same diagnostic as fixture
  11, and a second refusal buys no positive coverage.
- **`above()` during the initial condition analysis preceding a transient**
  (§5.10.3.2, "if the expression is positive at the conclusion of the initial
  condition analysis … above() shall generate an event"). Fixture 06 covers the
  dc-sweep half; the initialization half needs a tran whose t = 0 row is
  distinguishable from its first stepped row, which this grid cannot express
  without also pinning what the host does at t = 0.

## Build / run

These live outside `tests/fixtures/`, so `zig build torture` does not see them —
which is the point: 8 of them fail, and that gate is green at 1323/1323.

VerA side:

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build                                    # refresh zig-out/bin/vera
for f in tests/pending/A10/*.va; do
  echo "##### $(basename "$f")"
  ./zig-out/bin/vera --run --display=emit \
    --contract tools/contract.zig \
    -I tests/fixtures \
    --work-dir "/tmp/a10/$(basename "$f")" "$f" 2>&1 | grep -E 'ok=|error'
done
```

Every `ok=` column must read `ok=1`, and 11/12 must be refused with the
substring on their `//! reject` line. To wire them into the green gate once the
clauses are honoured, move 01-06 and 11-12 into
`tests/fixtures/ch05_analog_behavior/`, 07-10 into
`tests/fixtures/ch09_system_tasks/`, add their one-liners to each directory's
`COVERAGE.md`, and they are picked up by:

```sh
zig build torture -- --strict
```

Host side (three decks plus `a10_host.assets/`). **Read this before trusting any
number in the deck rows above: ARPice does not build from source today.**

```
$ cd /home/omare/Documents/Projects/Zig/ARPice && zig build -Doptimize=ReleaseFast --prefix zig-out
src/analysis/pss/hb.zig:286:22: error: root source file struct 'posix' has no member named 'getenv'
Build Summary: 328/333 steps succeeded (2 failed)
```

That is Q03 in the approval manifest, and it is not this row's to fix (`src/` is
out of scope for a fixtures-only phase). The consequence has to be stated rather
than papered over: **every host-side number in this document was produced by a
prebuilt binary, not by a build from the current source.** Its identity:

| | |
|---|---|
| path | `/home/omare/Documents/Projects/Zig/ARPice/zig-out/bin/espice` |
| sha256 | `1830d15156ca4df965487229793104c6005064e9eeedb288f1735b28a5b5db35` |
| mtime | 2026-09-16 16:48:23 −0400 |
| ARPice HEAD | `4b43d53`, committed 2026-09-16 16:51:14 −0400 — three minutes *after* the binary was linked |

So the binary is stale by at most whatever `4b43d53` changed, and it is the only
espice that exists. The three deck rows in the table above were **re-run against
it on 2026-09-19** and every figure quoted there is from that run, read out of
the `.raw` files directly (rawfile header + little-endian f64 payload); none of
them is remembered or retyped. They become reproducible the moment `hb.zig:286`
is fixed, and they must be re-captured at that point — not assumed.

```sh
cd /home/omare/Documents/Projects/Zig/VerA/tests/pending/A10
/home/omare/Documents/Projects/Zig/ARPice/zig-out/bin/espice a10_timer_breakpoints.sp -r /tmp/a10_bp.raw
/home/omare/Documents/Projects/Zig/ARPice/zig-out/bin/espice a10_bound_step.sp      -r /tmp/a10_bs.raw
/home/omare/Documents/Projects/Zig/ARPice/zig-out/bin/espice a10_cross_timestep.sp  -r /tmp/a10_cr.raw
```

Wired up — `ARPice/tests/fixture_catalog.zig` walks `tests/fixtures`
recursively, so no `build.zig` edit is needed:

```sh
cp -r a10_host.assets a10_*.sp a10_*.expected.json \
      /home/omare/Documents/Projects/Zig/ARPice/tests/fixtures/tran/
cd /home/omare/Documents/Projects/Zig/ARPice && zig build test -- --filter a10_
```

That last command **has never been run**, for the same reason: `zig build test`
cannot link. What was checked instead was the oracle semantics by hand, against
the checker source, on the re-captured `.raw` data — `selected_values` compares
the axis with `==` and so needs the bit-exact coordinate
(`tests/test_correctness.zig:585-591`), and `match: "samples"` linearly
interpolates the column at each axis value (`:508-533`). Under those two rules
all three oracles are satisfied by the 2026-09-19 data. Anyone landing Q03 should
treat that as a prediction to confirm, not as a recorded test result.

The `netlist_sha256` in each oracle is the SHA-256 of its own `.sp` and is
checked at `ARPice/tests/test_correctness.zig:156`; re-hash after any edit to a
deck.
