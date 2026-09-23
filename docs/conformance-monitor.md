# Monitor behavior: context-specific evidence

Source review, 2026-09-23: IEEE 1364-2005 §17.1.3 (printed page 286,
physical page 316), and AMS §9.4.1 (physical pages 238–239). The AMS text was
read against the HTML and Syntax 9-1 checked on rendered page 239. The HTML
now preserves its terminal/nonterminal distinction with bold literal tokens.
This review does not cover the remainder of Chapter 9 or all display formats.

## Do not merge the two trigger rules

Digital monitoring is inherited from IEEE §17.1.3: a change to a monitored
variable or expression triggers an end-of-time-step display, with changes to
the named time functions excepted. Same-time changes coalesce into one display
of the settled values. A digital value that changes and returns to its old
value has still changed during that time step.

AMS §9.4.1 explicitly concerns the **analog context**. It compares monitored
values against the preceding accepted step and excludes `$abstime`/`$realtime`
as triggers. Do not impose digital intra-step event semantics on analog Newton
iterations, or use the analog accepted-step comparison to suppress digital
changes. The old digital fixture header quoted the analog rule; its attribution
is corrected without changing its expected transcript.

## Requirement groups

| ID | Source / obligation | Evidence and limits |
|---|---|---|
| MON-001 | IEEE 17.1.3: one end-of-step display for same-time argument changes. | Existing `d09_04_monitor.v` observes coalescing of a/b changes. `audit_monitor_install_settled.v` exposes premature output when installing a monitor before an NBA changes its argument. Partial, not verified generally. |
| MON-002 | IEEE 17.1.3: changes trigger even when the final value matches the previous time step. | `audit_monitor_return_to_previous.v` fails: an active/inactive 0→1→0 sequence loses its required settled-value line. This is not an analog accepted-step test. |
| MON-003 | IEEE 17.1.3: time functions are not display triggers. | `audit_monitor_time_exception.v` fails: `$time` changing adds output when only an unmonitored variable changed. `$stime`, `$realtime`, nested expressions and mixed argument types remain separate untested cases here. |
| MON-004 | IEEE 17.1.3: only one display list is active; later calls replace it. | The existing monitor fixture observes replacement and a later change printed only by the new list. Pending callbacks, different scopes and replacement while disabled remain open. |
| MON-005 | IEEE 17.1.3: monitoroff suppresses monitoring; monitoron enables and displays even without a value change. | The existing fixture tests an off→on transition. `audit_monitoron_already_enabled.v` fails for repeated calls while already enabled; neither required output appears. Installation while disabled remains untested here. |
| MON-006 | IEEE 17.1.3: triggering is based on argument values, not formatted output bytes. | Executor compares rendered lines. Time exception and return-to-previous tests expose consequences; additional distinct-value/same-format-output cases and expression sensitivity still need source-derived oracles. |
| MON-007 | AMS 9.4.1: analog accepted-step comparison, time exceptions and coalescing. | Not closed by the digital transcripts. Must observe accepted host steps, avoid counting Newton iterations as accepted steps, and verify state across restarts/sweeps separately. |
| MON-008 | Syntax 17-3 and display-task references: forms, radix variants, argument rules and invalid inputs. | Full grammar/format matrix and isolated invalid-input evidence remain open. A legal unsupported form is not negative conformance coverage. |

All fixture names in this file are under `tests/fixtures/digital`. Each new
positive case carries a hand-derived exact transcript; none is weakened to an
expected rejection or changed to match the current executor's output.

## Recorded failures and root evidence

| Defect | Fixture | Required versus observed |
|---|---|---|
| MON-INSTALL-001 | `audit_monitor_install_settled.v` | Required first line `a=1`, after the time-zero NBA; observed extra `a=0` before that line. Later observations still match. |
| MON-RETURN-001 | `audit_monitor_return_to_previous.v` | Required another `a=0` line between the before/after markers; observed no line there. |
| MON-TIME-001 | `audit_monitor_time_exception.v` | Required output only at times 0 and 2; observed extra lines at 1 and 3. The real argument change at 2 still prints its current time correctly. |
| MON-ENABLE-001 | `audit_monitoron_already_enabled.v` | Required one additional `a=0` after each already-enabled monitoron call; observed neither line. Markers at different times avoid imposing same-slot print order. |

In `src/sim/digital.zig`, installation directly calls `monitorPrint(..., true)`;
that explains the eager setup line. `monitorPrint` compares rendered output
against `monitor_last`, explaining both time-only triggers and suppression
after a value returns. The monitor-enable path forces printing only for an
off→on transition. Its explanatory comments describe these choices as correct,
but the new source-derived cases demonstrate the limits of those claims.
No executor code or unit-test expectation has been changed in this checkpoint.

The full digital suite before/after comparison adds exactly these four positive
failure names and retains every previous failure. The existing monitor fixture
continues to pass. These are newly exposed behaviors, not implementation
regressions. They are outside measure A's population; C's citation polarity
inventory is not a measure of their execution. Historical B rows 17.1-12/13
must not claim complete digital verification from the older combined fixture.
The fresh analog strict run retains exactly the preceding nonempty FAIL/XFAIL
name list. Its report is regenerated by `tools/conformance.sh`; no conformance
increase is inferred from adding these digital transcripts.

This table is a partial rule/evidence inventory, not a complete denominator or
closure of IEEE §17.1.3. Analog behavior, all syntax/format variants and the
remaining contexts still require independent positive and invalid-input tests.
