# A03 — Analog control flow and held state

Greenfield row. No unmerged `w2/*` branch touches it.

## LRM clauses covered

Read from the offline text in `/home/omare/Documents/Projects/Zig/VerA/docs/`
(`ch3-datatypes.html`, `ch4-expressions.html`, `ch5-analog.html`,
`ch6-hierarchy.html`, `ch8-scheduling.html`, `annex-a-syntax.html`).

| clause | file | the sentence pinned |
|---|---|---|
| **§5.3** Block statements | ch5 | "The statements within the block shall be executed in sequence, one after another in the given order and the control shall pass out of the block after the last statement is executed." |
| **§5.3.2** Block names | ch5 | "All named block variables are static—that is, an unique location exists for all variables and leaving or entering the block do not affect the values stored in them. All identifiers declared within a named sequential block can be accessed outside the scope in which they are declared. Named block variables cannot be assigned outside the scope of the block in which they are declared." plus the clause's own `moduleVar = myscope.localVar;` worked example. |
| **§5.9 / §5.9.3** Looping statements | ch5 | "The following restrictions are applied to looping statements (repeat, while and for) **except for analog_for statements** … Event control statements are not allowed". This is why fixture 02 uses a genvar `for`: it is the only loop that may contain an `@`, and `disable` may only appear under an `@`. |
| **§5.10** Analog event control | ch5 | "events have no time duration"; "events can be triggered and detected in different parts of the behavioral model"; "The analog event detection is non-blocking, meaning the execution of the procedural statement is skipped unless the analog event has occurred." |
| **§5.10.2** Global events | ch5 | "If no analysis list is specified, the `initial_step` global event is active during the solution of the first point (or initial DC analysis) of every analysis." Also its `bitErrorRate` example, `@(timer(0, period)) begin … bits = bits + 1; end`, which is the LRM's own blessing of a read-modify-write inside an event body: what it counts is event occurrences, not NR iterations. |
| **§5.10.3.3** timer | ch5 | "If the period expression evaluates to a value less than or equal to 0.0, the timer shall trigger only once at the specified start_time". |
| **§5.10.4** Named events | ch5 | the `-> ana_event` / `@(ana_event)` worked example, trigger before detection. |
| **§4.7.1** Defining an analog function | ch4 | "shall not use contribution statements or event control statements; … shall not use named blocks". |
| **§4.7.2.1 / .3 / .4** Returning a value | ch4 | identifier variable "is initialized to zero (0)"; output arguments "are initialized, zero (0) if numeric … which in turn means that the argument passed to it is reset to zero (0)"; inout arguments "do not get initialized like those defined as output", are "copy in and copy out", and "If a value was not assigned to the inout argument during the execution of the analog user-defined function, then the corresponding analog variable reference is left untouched". |
| **A.6.4 / A.6.5** | annex-a | `analog_event_statement ::= … \| { attribute_instance } disable_statement`, and `disable_statement ::= disable hierarchical_task_identifier ; \| disable hierarchical_block_identifier ;`. `analog_statement` has no `disable_statement` alternative — the event form is the only legal one. |
| **§3.2** Integer and real data types | ch3 | "Integer variables whose values are assigned in an analog context default to an initial value of zero (0)"; "Real variables are initialized to zero (0) at the start of a simulation"; Syntax 3-1's `{ dimension }` plus "a range which defines the upper and lower indices of the array" and the clause's own `real gain_factor[1:30]; // array of 30 gain multipliers` — an array is a set of locations, one per element. **There is no §3.2.2** (ch3 runs 3.1 → 3.2 → 3.2.1 → 3.3); see *Corrected after review*. |
| **§4.2.1.2** Integer to real conversion | ch4 | "Implicit conversion shall take place when an expression is assigned to a real" — used by fixture 06 for `parameter real p2 = p1;`. §4.2.1.1 is the other direction. |
| **§5.6.1.3** Value retention | ch5 | "**Unlike variables**, the contributed value for a branch is only valid for the current iteration." A variable therefore carries across NR iterations, which is why fixture 08 may not accumulate on the analog spine. |
| **§8.3.3** Convergence | ch8 | "In the analog kernel, the behavioral description is evaluated iteratively until the NR method converges." Nothing bounds the number of evaluations per timepoint. |
| **§6.7** | ch6 | a block label is a scope name. |

## Ground truth, read from the source — not from the plan

### `disable`: parsed, diagnosed, never lowered

`lib/ir/lower.zig` `lowerDisable`:

```zig
fn lowerDisable(self: *Lower, tok: u32) Oom!void {
    if (!self.in_event_stmt) {
        var b = self.errWith(tok, .E0401);
        b.help("only `@(<event>) disable <block>;` is legal", .{});
        return b.emit();
    }
    return self.err(tok, .E0402, "", .{});
}
```

Both arms are errors. `E0402`'s own text (`lib/diag_code.zig`) is "`disable` is
not implemented … The event form of `disable` parses but has no lowering".
So the row's first bullet is **0% implemented**, and the two existing fixtures
(`tests/fixtures/annex_c_analog_subset/27_disable_rejected.va`,
`annex_a_syntax/18_disable_statement.va`) are both refusals of the *illegal*
spelling — the plan's "permitted event-controlled disable cases" have no
coverage of any kind. Fixtures 01-03 are the whole positive side.

### Held state: implemented at module scope, by bare name

`lib/ir/lower.zig`:

* `markHeldVars` / `scanHeld` walk each `analog` block, and for every assignment
  target *inside* an `@(...)` body put the **bare source name** into
  `held_names: std.StringHashMapUnmanaged(void)`. An indexed target `x[i]`
  records `x`.
* `declareVarDecl` grants a persistent `Instance` slot only when
  `scope == .module and ty != .string and self.held_names.contains(name)`.
* `holdSlot` emits a synthetic `$held_real`/`$held_int` call at the DECLARATION,
  so a read lexically before the `@` also sees the retained value.
* End of `lowerFile`: `for (self.held_vars.items) |*h| h.final = try
  self.builder.readVariable(h.place, self.cur);` — the slot is saved at the end
  of the evaluation, not at the event.

The limitation is stated in the source itself, above `markHeldVars`:

```
// ponytail: MODULE-level variables only. A variable declared in a §5.3.2 named
// block inside the analog block still resets — its declaration is lowered once
// per execution of the block, so a slot keyed on the source name would collide
// with itself under a §6.6.1 unrolled `for`.
```

So of the row's second bullet — "track held variables by scoped identity,
including named-block locals, shadowing, arrays and function-local lifetime":

| sub-item | status | fixture |
|---|---|---|
| module-scope retention | implemented | (already covered by `tests/fixtures/ch05/event_cross_fires.va`) |
| arrays, runtime subscript | **implemented, untested** | 07 |
| read before the `@` | **implemented, untested** | 12 |
| retention across a function copy-out | **implemented, untested** | 08 |
| function-local lifetime (§4.7.2.1/.3) | **implemented, untested** | 09 |
| named events, no time duration | **implemented, untested** | 10 |
| **named-block locals** | **not implemented** | 04 |
| **scoped identity / shadowing** | **not implemented** (retention is keyed on the bare name) | 05 |
| **named-block local by hierarchical name** | **not implemented** (E0901) | 06 |

Five of the eight "implemented" cells had no fixture anywhere before this row,
which is the audit's "implemented without evidence" bucket; they are written as
guard rails because the fix for 04/05 re-keys the same allocator.

### Already covered elsewhere — deliberately not re-written here

Every refusal this row could want, except one, already exists and is green:

* bare `disable` on the analog spine → E0401, two fixtures (above);
* `@(...)` inside `repeat`/`while`/`for` → E0707, §5.8/§5.9;
* `@(...)` inside a non-constant conditional → `ch05/conditional_event_control_invalid.va`;
* nested `@(...)` → E0703, two fixtures;
* contribution inside an event body → E0406, two fixtures;
* `@(...)` inside an analog function → E0702, §4.7.1;
* named block inside an analog function → E0226, §4.7.1;
* `myscope.localVar = …` from outside the block → E0316, §5.7.

That is why this row ships **one** refusal (11) against **eleven** positives.

## Fixtures

Ordered: 01-03 `disable`, 04-06 scoped identity, 07-10 held state and
lifetimes, 11 refusal, 12 ordering.

| # | file | pins | expected value and derivation | today |
|---|---|---|---|---|
| 01 | `01_disable_resumes_after_the_named_block.va` | A.6.4/A.6.5 + §5.3: `@(event) disable blk;` ends `blk` early and control passes *out of* it, so statements after `blk` still run. | `a = 11`, `b = 1011` at t = 0; `a = 111`, `b = 1111` at t = 1n. `a = 1`, `+10` before the disable, `+100` after it inside `seg`; `b = a + 1000` sits after `seg`. `initial_step` fires only at t = 0 (§5.10.2). A disable that aborted the analog block leaves `b` at its §3.2 default 0. | **E0402** |
| 02 | `02_disable_in_analog_for_does_not_exit_the_loop.va` | §5.9.3 + A.6.5: disabling the loop-body block ends one iteration, not the loop. | `n = 3` at both timepoints, `m = 0` at t = 0 and `m = 3` at t = 1n. Three iterations each increment `n` before the disable and `m` after it. Break-like behaviour gives `n = 1`; a no-op gives `m = 3` at t = 0. | **E0402** |
| 03 | `03_disable_inner_versus_outer_named_block.va` | A.6.5: the block identifier is an operand — `disable i1` and `disable o2` must differ though the code is identical. | `a = 101`, `b = 1` at t = 0; both `111` at t = 1n; `c = 5` always. Half 1: `1` then `+100` in the outer block (the `+10` in the inner is skipped). Half 2: `1` only (both the inner `+10` and the outer `+100` are skipped). Always-outermost unwinding gives `a = 1`; always-one-level gives `b = 101`. | **E0402** |
| 04 | `04_block_local_is_static_between_events.va` | §5.3.2 "All named block variables are static … an unique location exists for all variables". | `0, 1, 1, 11, 11` at t = 0, 1n, 2n, 3n, 4n. Block-local `integer n`, two one-shot timers: `n += 1` at 1n, `n += 10` at 3n. The flat intervals are the retention; `11` needs the retained `1` read back. | **fails**: reads `0, 1, 0, 10, 0` |
| 05 | `05_shadowed_block_locals_hold_independently.va` | §5.3.2 "The block names give a means of uniquely identifying all variables at any simulation time" — retention is keyed on (scope, name), not on the spelling. Three declarations named `n`. | `lo.n = 0, 1, 1, 2, 2`; `hi.n = 0, 0, 10, 10, 20`; module `n = 7` always. Timers at 1n/3n drive `lo.n += 1`, at 2n/4n drive `hi.n += 10`. One shared slot for "n" gives `hi.n = 11` at t = 2n and `lo.n = 11` at t = 3n. | **fails**: `lo.n` reads `0,1,0,1,0`, `hi.n` reads `0,0,10,0,10` |
| 06 | `06_named_block_local_by_hierarchical_name.va` | §5.3.2 "All identifiers declared within a named sequential block can be accessed outside the scope in which they are declared" — the clause's own worked example, verbatim. | `moduleVar = 1.5` exactly, `myscope.p2 = 1.0`. `p1 = 1` → local parameter `p2 = p1 = 1` → `localVar = 1.5 * 1`. 1.5 = 3/2 and the integer→real conversion is exact (§4.2.1.2), so `CHECKX` with no tolerance. | **fails**: E0901 ×2 |
| 07 | `07_held_array_element_between_events.va` | §3.2 + §5.10: retention is per array ELEMENT, under a runtime subscript. | `s[0] = 10` from 1n, `s[1] = 20` from 3n, `s[2] = 30` from 5n, `k = 0,1,1,2,2,3`, sum `0,10,10,30,30,60`. Body is `s[k] = 10*(k+1); k = k+1;` at three one-shot timers, so the value names its own slot: writing every firing to `s[0]` reads 30 there at t = 5n. | **passes** (guard rail) |
| 08 | `08_held_survives_an_inout_function_argument.va` | §4.7.2.4 copy-in/copy-out across a held variable, including its "left untouched" and "do not get initialized like those defined as `output`" sentences; §4.7.1 means a function-local can never itself be held. | `h = 0, 1, 1, 5, 5`; witnesses `w2 = 0,0,1,1,1` and `w4 = 0,0,0,0,5`. Timers write `h = 10.0` at 1n and `50.0` at 3n; the spine calls `snap(h)`, which returns the value copied in and copies out `y/10.0` only when `y >= 10.0` — **idempotent**, so nothing here counts evaluations (§8.3.3, §5.6.1.3). `w2 = 1` is the headline: 1 is not written anywhere in the file and is reachable only by copying 10.0 in at 1n, dividing, copying out, and carrying the slot to a point with no event. | **passes** (guard rail) |
| 09 | `09_function_locals_have_no_lifetime.va` | §4.7.2.1 identifier variable reset per call; §4.7.2.3 an output argument resets the caller's variable. | `r1 = r2 = 2.0` (`0+1+1`, twice in one evaluation — carry-over would give 4); `hi = 0, 10, 0, 10, 0`; `h = 0.0` at every point (passed as an output argument that is never assigned); `dd = 5.0` from `ignore = z + y` where `y` is the output formal — 5.0 only if the formal reads 0 *inside* the function while the caller's `h` held 10.0 at 1n and 3n; an implementation that copied the caller's value into an `output` formal returns 15.0 there. The `(hi, h)` pair is what makes the flat 0 a strong claim. | **passes** (guard rail) |
| 10 | `10_named_event_has_no_time_duration.va` | §5.10 "events have no time duration" + §5.10.4 trigger-then-detect. | `n = 0, 1, 1, 2, 2`. Two one-shot timers both `-> ev`; `@(ev) n = n + 1` below them. A flag that persisted once set reads `0,1,2,3,4`; one never delivered across the two statements reads `0` throughout. The former `m == 0` half is **withdrawn** — see *Corrected after review*. | **passes** (guard rail) |
| 11 | `11_disable_target_must_name_a_block_rejected.va` | A.6.5: the operand is a task or block identifier. `disable r` on a real variable has no derivation. | **refusal.** `//! reject names no named block`. The name resolves to a declared variable and a legal label `work` exists in the same file, so this is not a name-not-found test. | **fails**: E0402 fires first, so the substring never matches |
| 12 | `12_held_value_is_visible_before_its_event_statement.va` | §5.3 sequence + §5.10: a read before the `@` sees the retained value, a read after it sees this evaluation's event. | `pre = 0, 0, 1, 1, 2`; `post = 0, 1, 1, 2, 2`; `post - pre = 1` exactly at 1n and 3n. The one-event offset between the columns is the assertion. | **passes** (guard rail) |

Deliverable = **01, 02, 03, 04, 05, 06, 11** (must go green when A03 is
implemented) + **07, 08, 09, 10, 12** as guard rails that the fix must not
break. 11 of 12 are positive; 1 is a refusal.

## Why every event source here is a ONE-SHOT timer

`timer(<t>, 0.0)` fires at exactly `<t>` (§5.10.3.3) with no dependence on the
timestep the tool picks, so every expected value above is an integer, not a box.
Two alternatives were rejected after measuring them:

* **`cross()`** — §5.10.3.1 lets the simulator insert a resolution point just
  past the threshold, so the sampled value is `≈1.0` and not the grid value.
  `tests/fixtures/ch05/event_cross_fires.va` already handles that correctly with
  a bounded assertion; a retention fixture cannot.
* **a repeating `timer(start, period)`** — **it is broken in VerA today.**
  Measured on the grid `0, 1n, 2n, 3n, 4n, 5n`:

  ```
  @(timer(0, 1n)) bits = bits + 1;      ->  1, 2, 3, 3, 4, 5   (t = 3n is MISSED)
  @(timer(1n, 2n)) n = n + 1;           ->  fires at 1n and 3.5n, not 1n and 3n
  ```

  The next-fire time is accumulated in floating point, so `1e-9 + 2e-9` lands
  just past `3e-9` and the grid point is skipped. That is a **§5.10.3.3 timer
  defect, not an A03 defect** — it belongs to A04's stateful-operator audit —
  and no fixture is written for it here, but it is why the §5.10.2 worked
  example (`bitErrorRate`, `@(timer(0, period))`) could not be used as this
  row's model. Whoever picks it up: the fix is to schedule firing k at
  `start + k*period` rather than by repeated addition.

## Deliberately NOT covered

* **`disable` of a task, and `disable` across a hierarchy.** A.6.5's first
  alternative is `disable hierarchical_task_identifier`. Verilog-AMS gives the
  analog context no task (§4.7.1 functions are not tasks), and VerA refuses
  module instantiation, so there is no second scope to name. Both are out of
  reach from a single `.va`.
* **`disable` interacting with contributions.** E0402's explanation says
  "aborting a named block mid-solve would leave the contributions it had already
  made in the system of equations". Every fixture here keeps `I(p) <+ 0.0` on
  the spine, outside any disabled block, so none of them answers that question.
  It is the hard part of implementing the row and it needs its own decision
  first: §5.6.1.3 value retention says a branch keeps the last value contributed
  to it, which suggests a disabled block's already-executed contributions stand.
  Write the fixture once that is decided.
* **Digital-event-controlled analog blocks and `->` from an `always` block.**
  §5.10.5 and the `dig_event` half of §5.10.4's example. The plan assigns that
  to A03 "in cooperation with D05/M01"; it needs a digital process, which is a
  different runner (`tests/digital/*.v`, `vera --run`). Nothing here crosses
  that boundary.
* **`final_step`, and the analysis-list forms `initial_step("tran")` etc.**
  (§5.10.2, Table 5-1.) Orthogonal to control flow and held state; the row uses
  the bare `initial_step` only, for its exact single firing.
* **Retention of a `string` variable.** `declareVarDecl` excludes `.string` from
  held slots on the stated ground that a string never reaches the residual.
  That reasoning is plausible but is an implementation claim, not an LRM one;
  §3.3 does not exempt strings from §5.10. Untested here.
* **Retention under a §6.6.1 unrolled `for` that re-declares the same block.**
  The exact collision the `markHeldVars` ponytail note names as the reason the
  feature is module-scope-only. Fixture 05 pins shadowing between two *distinct*
  blocks, which is the simpler half; two *instances* of one block needs the
  group-local ordinal the note describes and a fixture of its own.
* **The timer defect above.** Recorded, not fixtured — it is A04's.

## Corrected after review

Five defects were found by adversarial review and are fixed here. Each was
re-derived from `docs/` before the edit; every clause number below was opened.

1. **Fixture 08 asserted a solver iteration count (the worst kind of defect).**
   It previously put `d = bump(h);` on the *unconditional analog spine*, where
   `bump` added 1 to `h` through an inout formal, and asserted
   `h = 1, 11, 12, 11, 12` at tolerance `0.0`. There is no clause that fixes how
   many times the spine is evaluated per timepoint — §8.3.3 says only that "the
   behavioral description is evaluated iteratively until the NR method
   converges" — and §5.6.1.3's "**Unlike variables**, the contributed value for
   a branch is only valid for the current iteration" says a variable is *not*
   discarded between iterations, so an accumulator on the spine counts
   evaluations. A conforming tool that evaluates the spine twice per point reads
   `2, 12, 14, …` and fails. VerA passes it only because its commit/revert
   staging is planted when `fsmStateCtl()` is true and this file has only
   timers, i.e. the fixture was grading VerA against VerA.
   **Fix:** the function is now `snap`, whose inout mutation `if (y >= 10.0)
   y = y / 10.0;` is **idempotent** on every value the module reaches, so the
   answers are the same after one evaluation as after ten. New wants, derived
   in the file's header: `h = 0, 1, 1, 5, 5` (events write 10.0 at 1n and 50.0
   at 3n; `10.0/10.0` and `50.0/10.0` are exact in binary64, so `0.0` tolerance
   is meant literally), plus two held witnesses `w2` and `w4` captured by
   one-shot timers at 2n and 4n *before* the call. `w2 = 1` is the load-bearing
   number — `1` occurs nowhere in the file's source text and is reachable only
   by copy-in, the division, copy-out into the held slot, and that slot
   surviving to a timepoint with no event. The rewrite also picked up two
   sentences of §4.7.2.4 the old version did not exercise at all: an unassigned
   inout leaves the caller "untouched" (t = 2n and 4n), and an inout is not
   zero-initialized the way a §4.7.2.3 output is.
   *Scope of the finding:* it applies to the spine only. Fixtures 04, 05, 07, 10
   and 12 keep their read-modify-writes because theirs sit inside `@(...)`
   bodies, where what is counted is event occurrences — the idiom of §5.10.2's
   own `bitErrorRate` example, `@(timer(0, period)) begin … bits = bits + 1;
   end`, which counts bits and not iterations.

2. **§3.2.2 does not exist.** `docs/ch3-datatypes.html` runs 3.1 → 3.2 → 3.2.1 →
   3.3; the only textual "3.2.2" in the document is a cross-reference to Annex
   E.3.2.2. It was cited in the clause table above, in the body of
   `07_held_array_element_between_events.va`, and in that file's `//! lrm`
   directive (which passed `validSection` only because §3.2.2 is *shaped* like a
   section number). All three now read **§3.2**, and the body quotes what §3.2
   actually says about arrays — Syntax 3-1's `{ dimension }`, "a range which
   defines the upper and lower indices of the array", and the clause's own
   `real gain_factor[1:30]; // array of 30 gain multipliers`.

3. **§4.2.1.1 was the wrong direction in fixture 06.** The fixture converts the
   *integer* parameter `p1` to the *real* parameter `p2`; §4.2.1.1 is "Real to
   integer conversion". The clause that says "Implicit conversion shall take
   place when an expression is assigned to a real" is **§4.2.1.2**. Corrected in
   the fixture header and in the fixture table above.

4. **Fixture 10's `m == 0` is withdrawn — it had no teeth and no clause.** The
   claim was that a `@(ev)` placed lexically *before* the `-> ev` sees nothing in
   the same pass. `m == 0` is equally the reading of a tool with no named events
   at all, of a tool whose `->` is a no-op, and of §3.2's zero default for a
   variable never assigned on any executing path; and the LRM does not fix it —
   §5.10.4's worked example only ever puts the trigger *before* the detection,
   and §5.10's bullet list does not say when within an evaluation a trigger
   becomes visible. A tool evaluating the block to a fixed point could justify
   `m = n`.
   **Where it went:** nowhere, on purpose. The question is "in what order, and
   over how many passes, does an analog block observe an event triggered inside
   its own evaluation", which belongs to **A10** (analog event scheduling,
   §5.10.3.x), not to a held-state row. It can come back as an A10 fixture the
   day a clause fixes the order; §8.3 fixes the analog/digital simulation cycle
   but is silent on intra-block trigger visibility, so there is nothing to cite
   today. `m` and its `CHECKEQ` are deleted from the file; `n = 0, 1, 1, 2, 2`
   remains and does have teeth (a no-op `->` reads 0 throughout).

5. **Fixture 09's `dd = 5.0` was a non-claim.** `ignore = z;` returns its input,
   so `dd == 5.0` holds in any compiler that has analog functions at all and
   said nothing about §4.7.2.1 or §4.7.2.3. The body is now `ignore = z + y;`
   where `y` is the **output** formal. §4.7.2.3's first sentence — "All output
   arguments of an analog user-defined function are initialized, zero (0) if
   numeric" — is about the formal, so 5.0 is the answer only if `y` reads 0
   inside the function *while the caller's `h` held 10.0*, which it does at
   t = 1n and t = 3n. An implementation that copied the caller's value into an
   `output` formal (treating it as §4.7.2.4's `inout`) returns 15.0 at exactly
   those two points. Verified: `got=5 want=5 ok=1` at all five timepoints.

Not changed, and why: the `//! reject names no named block` substring in fixture
11 is already specific (a bare `//! reject` would pass on the incidental E0402),
and the five already-passing guard rails remain disclosed as guard rails rather
than counted as coverage.

**Still open, disclosed rather than fixed.** The same §8.3.3 argument reaches the
*edge* of fixtures 04, 05, 07, 10 and 12: their accumulators sit under `@(...)`,
and §5.10.3.3 says only that at the timer's timepoint "the event evaluates to
True", not that the body runs once there. The reason they are left alone is that
§5.10.2's `bitErrorRate` example is written the same way and is unusable under
any other reading — the standard would not print a bit counter that counted NR
iterations. If a future erratum settles it the other way, those five fixtures
need the same idempotence treatment fixture 08 just received.

## Build / run

These live outside `tests/fixtures/`, so `zig build torture` does not see them
and the 1323/1323 gate is untouched. Run them directly:

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build                                   # refresh zig-out/bin/vera
for f in tests/pending/A03/*.va; do
  echo "##### $(basename "$f")"
  ./zig-out/bin/vera --run --display=emit \
    --contract tools/contract.zig \
    -I tests/fixtures \
    --work-dir "/tmp/a03/$(basename "$f")" "$f" 2>&1 | grep -E 'ok=0|^error'
done
```

Silence under a fixture's banner means it passes. Expected output today —
re-captured from an actual run after the *Corrected after review* edits, not
carried over: 01, 02, 03 and 11 print `error[E0402]`; 06 prints `error[E0901]`
twice; 04 prints 3 `ok=0` lines and 05 prints 5; 07, 08, 09, 10, 12 print
nothing. Drop the `grep` to see the `got=/want=/ok=` lines themselves — 08 now
prints 15 of them (3 checks x 5 timepoints), all `ok=1`.

To wire them into the green gate once A03 is implemented, move

* 01, 02, 03, 04, 05, 06, 10, 12 → `tests/fixtures/ch05_analog_behavior/`
* 07 → `tests/fixtures/ch05_analog_behavior/` (cites §3.2 for what an array is,
  but the rule under test is §5.10)
* 08, 09 → `tests/fixtures/ch04_expressions/`
* 11 → `tests/fixtures/annex_a_syntax/`, beside `18_disable_statement.va`

add each one-liner to that directory's `COVERAGE.md`, and they are picked up by:

```sh
zig build torture -- --strict ch05
zig build torture -- --strict ch04
zig build torture -- --strict annex_a
```
