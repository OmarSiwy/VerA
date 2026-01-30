# Annex G coverage

Source: `docs/annex-g-changes.html`, read section by section.

HTML section-ID audit: `sG-1` `sG-2` `sG-2-1` `sG-2-2` `sG-2-3` `sG-2-4`. Six sections,
and Annex G is **informative**.

Twenty-two fixtures live in this folder. Twenty-one cite an Annex G clause; one
(`23_transition_fall_time_binding.va`) cites only §4.5.8 and is counted at the bottom,
not in the table. **Measured by grep, none of the twenty-two carries a `//! xfail`
line today** — this folder is fully green. The ledger below is kept as the history of
what was open and why, but its rows are the ones earlier waves closed without
re-stating them here; only `08`'s removal was verified against the compiler by the
wave that removed it, and `08` itself has since been deleted outright — that is a
withdrawal of the claim it carried, not a discharge of it, and the `G.7` 7793 row below
records why. The aggregate re-census owns the rest.

What makes an informative annex testable at all is one sentence in §G.1's own preamble:
*"The syntax and semantics of this document supersede any syntax, semantics, or
interpretations of previous revisions."* That is what turns a history row into a
requirement — not that v1.0 spelled it `delay()`, but that a 2023 front end must not
still accept `delay()`. Every reject fixture here is that sentence applied to one row,
and every one of them also cites the live clause that owns the current spelling, because
the row alone is not normative.

| HTML id | Rule | Fixtures |
|---|---|---|
| `G` (the annex title itself) | none — "This annex lists the changes made to the document for each revision." | none, and none is owed, for the reason this whole folder runs on: the annex is **informative**, so its own scope sentence cannot carry a requirement, and what it lists is history. `tests/harness.zig` reads the bare letter out of `Annex G (informative) Change history` as a clause, which is why it shows in `--coverage`; no fixture cites bare `G`. The one sentence that does turn a history row into a requirement is §G.1's supersession line, and it is quoted at the top of this file and cited by fifteen fixtures |
| `sG-1` | §G.1, seven revision tables, 238 data rows (G.1: 29, G.2: 33, G.3: 27, G.4: 42, G.5: 20, G.6: 53, G.7: 34). Informative history plus the supersession sentence above | 15 fixtures, covering 20 of the 238 rows. Broken out row by row in the next table. Tables G.3, G.5 and G.6 have no fixture at all |
| `sG-2` | "The following statements are not supported in the current version of Verilog-AMS HDL; they are only noted for backward compatibility." | No fixture cites `G.2` bare, and none should — this is a one-sentence frame with no construct of its own, and a bare `G.2` cite would be indistinguishable from a cite of Table G.2. Its four subclauses carry all the content and all four have fixtures |
| `sG-2-1` | Forever: "This statement is no longer supported." Still a reserved word (B.1), so it is not reachable as an identifier either | `04_obsolete_forever.va` (`G.2.1`, `5.9`) — `//! reject E0209` "expected an expression", plus the fragment `forever`. Green. The header records that VerA also emits E0205 on the stray `end` during resynchronisation and deliberately does not pin it |
| `sG-2-2` | NULL: no longer a statement; case, conditionals and the event statement do allow null statements *as defined by the syntax*. Four claims — three survivors and one prohibition | All four have a fixture and all four are green. Conditional arm: `05_null_statement_scope.va`, which pins *binding* (the `else` after `if (c) ;` still belongs to that `if`) rather than mere acceptance. Case arm: `14_null_case_arm.va`, A.6.7's `analog_case_item`, arms carrying distinct values so a swallowed `;` shows up as the next arm's body. Event body: `15_null_event_body.va`, A.6.5, run in dc against a `("tran")` event list so the event does *not* fire and the mis-parse is observable. Prohibition: `09_null_statement_unconditional_rejected.va` — green, `//! reject DiagnosticsReported` |
| `sG-2-3` | Generate: the v1.0 `generate index (start, end [, incr]) statement`, an analog statement unrolled at elaboration, Figure G-1 | `06_obsolete_generate.va` (`G.1`, `G.2.3`) — `//! reject E0209` plus the fragment `generate`. Green. The header is explicit that this is *not* §6.6.2's loop generate, which is current language owned by `ch06_hierarchy/generate_loop.va` — so a diagnostic containing the word `generate` proves nothing on its own, and the code pins *where* it dies. **Figure G-1's semantics are untested**: no fixture exercises the index-locality rule, the elaboration-time-only evaluation of the bounds, the sign-of-increment no-execute case, the lower==upper case, or the default increment. Nothing can — the construct is gone, and the only conforming answer to all six is the same rejection |
| `sG-2-4` | `` `default_function_type_analog`` is no longer supported | `07_obsolete_default_function_type.va` (`G.2.4`) — `//! reject E0115` "undefined macro", plus the directive name. Green. §10 leaves the name undefined, so an unknown-macro diagnosis is the conforming one. Its Table G.1 twin is `12_default_nodetype_rejected.va` |

## `sG-1` row by row

Twenty rows of 238. Everything not listed here is untested in this folder; §G.1
mostly points at normative rules that live in the chapter folders, and this table
only claims the rows a fixture in *this* folder actually exercises. (One row left this
table with `08_new_receiver_count.va`, below.)

| Table | Row / item | Fixture | State |
|---|---|---|---|
| G.1 | Analog time: `$realtime` → `$abstime`, *new* | `01_abstime_replaced_realtime.va` reads `$abstime` under `` `timescale 1ns/1ns`` at t = 1 us and demands 1e-6, i.e. seconds and not timescale units — nine orders of magnitude between right and wrong | green |
| G.1 | `$realtime :timescale = 1 sec` → `` `timescale`` def 1n, see `$abstime`, *definition* | `13_realtime_analog_context_rejected.va` — the refusal half. Table 9-7 gives `$realtime` "analog context: No" and §9.10 deprecates it, so the requirement is that the read be diagnosed, not that it return 1000 | green, `DiagnosticsReported` |
| G.1 | Implicit nodes `` `default_nodetype`` → `` `default_discipline``, and the `` `default_nodetype`` *Obsolete* row (two rows, one directive) | `12_default_nodetype_rejected.va` — `//! reject E0115` + `default_nodetype`. One keystroke from the legal IEEE 1364 `` `default_nettype``, which is why it is its own fixture | green |
| G.1 | Array setting `{2.1 = (1), 4.5 = (2)}` → `{2.1, 4.5}` | `11_brace_array_initialiser_rejected.va` — but see G.4 item 2: the apostrophe was added *later*, and the live rule is §3.4's `'{ }` assignment pattern, not this row | green, `DiagnosticsReported` |
| G.1 | Discontinuity function `discontinuity(x)` → `$discontinuity(x)`, *syntax* | `18_discontinuity_v1_spelling_rejected.va` — `//! reject E0214` "expected `<+` or `=`". The header is honest that this is a statement-*shape* error, not a name lookup, so the cite is the portable half | green |
| G.1 | Limiting exponential `$limexp(expr)` → `limexp(expr)`, *syntax* | `10_limexp_v1_spelling_rejected.va` | green, `DiagnosticsReported` |
| G.1 | Timestep control `bound_step(const_expr)` → `$bound_step(expr)`, *syntax* | `17_bound_step_v1_spelling_rejected.va` — `//! reject E0214`, same shape-not-lookup caveat as 18 | green |
| G.1 | Continuous waveform delay `delay()` → `absdelay()`, *syntax* (restated as G.2 item 11) | `16_delay_v1_spelling_rejected.va` — `//! reject E0512` "unknown function", which *is* the conforming outcome, so this is a regression guard and not a bug report. Header records the cite discrepancy: G.2 item 11 says 4.5.14 in v2.1 numbering; the shipped clause is §4.5.7 | green |
| G.1 | Time tolerance on `transition()`, *Extension* | `21_transition_time_tolerance.va` — transient, on a **falling** edge with `rise_time != fall_time`, so a front end that accepts five arguments by sliding `time_tol` into the `fall_time` slot is caught. Written as `CHECKEQ` identities because `time_tol` buys timestep placement and is not part of the waveform | green |
| G.1 | Forever, *Obsolete* | `04_obsolete_forever.va` | green |
| G.1 | Generate, *Obsolete* | `06_obsolete_generate.va` | green |
| G.1 | Null statement `;` → limited to case, conditional and event statements, *Obsolete* | `05`, `09`, `14`, `15` — see `sG-2-2` above | all four green |
| G.2 | item 2, "Not to use 'max' and use 'maxval' instead since `max` is a keyword" | `19_max_nature_attribute_rejected.va` — `//! reject E0208` "expected an identifier", which is exactly the right reason: B.1 makes `max` a reserved word, so it cannot stand where `nature_attribute` wants an `attribute_identifier` | green |
| G.2 | item 11, `absdelay` instead of `delay` | `16_delay_v1_spelling_rejected.va` | green |
| G.2 | item 13, `@(final_step)` without arguments should not have parenthesis | `20_final_step_empty_parens_rejected.va` — A.6.5 makes the analysis list non-empty and the whole parenthesised group optional, so `final_step()` has no derivation | green, `DiagnosticsReported` |
| G.4 | item 2, apostrophe before opening `{` in a list of values | `11_brace_array_initialiser_rejected.va` — header refuses to copy the annex's stale "3.4.2" and cites §3.4, §3.4.4 and §4.2.14 instead | green, `DiagnosticsReported` |
| G.7 | 7780, math functions `expm1()` and `ln1p()` | `02_2023_math_additions.va` — the `$`-prefixed spellings the item added, wants taken from CPython's libm. `$ln1p(-0.5)` is the discriminator: finite, where a forgotten "1 +" gives NaN | green |
| G.7 | 7793, `$receiver_count()` | **WITHDRAWN — `08_new_receiver_count.va` is deleted, and no fixture here claims this row.** The fixture was authored from an HTML transcription of chapter 9 that had been contaminated with Verilog-AMS 2.4 text, and the whole of its argument rested on a sentence the corrected chapter does not contain: "Non-normative: $receiver_count is not a subclause of 9.22 in Verilog-AMS 2.4". The 2023 document makes the function a normative subclause with its own syntax box — §9.22.2 (printed p.262, physical p.275) "`$receiver_count` returns an integer representing the number of receivers associated with the signal in question. The syntax is shown in Syntax 9-18", `receiver_count_function ::= $receiver_count ( signal_name )` — so the item is a real addition with a real owner, and the call-site argument the fixture fell back on belongs to `ch09_system_tasks/`'s §9.22 rows rather than here. What is left is a hole in VerA and not in the LRM — the function is not implemented — and that is pinned by the M04 driver/receiver row, which owns §9.22 (`tests/fixtures/ch07_mixed_signal/m04_SPEC.md`). The G.7 *item* is still a change worth a fixture; this folder simply no longer has one |
| G.7 | 7795, alternative Verilog style `$min()`, `$max()`, `$abs()` | `03_system_math_style.va` — selection by comparison, never by magnitude, so `$max(-2.0, -3.0)` is -2.0 and the classic magnitude bug returns -3.0. Every want is a dyadic rational, so `CHECKX` | green |
| G.7 | 7922, contribution to a port declared `input` is now a warning, not an error | `22_input_port_contribution_honoured.va` | green, and the only digit in this folder that comes out of a SOLVE — see the ledger |

Fixture-name audit, 22 files, all mapped above or below:
`01_abstime_replaced_realtime.va`, `02_2023_math_additions.va`, `03_system_math_style.va`,
`04_obsolete_forever.va`, `05_null_statement_scope.va`, `06_obsolete_generate.va`,
`07_obsolete_default_function_type.va`,
`09_null_statement_unconditional_rejected.va`, `10_limexp_v1_spelling_rejected.va`,
`11_brace_array_initialiser_rejected.va`, `12_default_nodetype_rejected.va`,
`13_realtime_analog_context_rejected.va`, `14_null_case_arm.va`, `15_null_event_body.va`,
`16_delay_v1_spelling_rejected.va`, `17_bound_step_v1_spelling_rejected.va`,
`18_discontinuity_v1_spelling_rejected.va`, `19_max_nature_attribute_rejected.va`,
`20_final_step_empty_parens_rejected.va`, `21_transition_time_tolerance.va`,
`22_input_port_contribution_honoured.va`, `23_transition_fall_time_binding.va`.

## The xfail ledger

Empty, measured: 22 files, 13 with a `//! reject` arm, 9 that run and assert, 0 `//! xfail`.
Seven rows stood here; `08_new_receiver_count.va` was the last removed from it, when §9.22's
call-site rule landed as E0818 — the reason it carried ("VerA lowers every §9.22
driver-access query to the constant 0") named a `codegen.zig` constant that is now deleted.
That fixture has since been deleted as well, 2.4-contaminated text being the whole of its
argument (see the `G.7` 7793 row above), so `08` is no longer a ledger entry here — it is a
withdrawal, and the code it pinned is not a conformance requirement.
The rows below are retained for the rules they record, and **all six are green**: each pins
`DiagnosticsReported`, so each went green the moment its rule got a diagnostic of any code,
which is exactly what the paragraph after the table said the phase label was for. Reasons
are given in the past tense where the compiler has moved. `23_transition_fall_time_binding.va` was the eighth and is gone: §4.5.8's
ramp landed with independent rise and fall times, so a falling edge is now traversed in
`fall_time`, linearly, and `2a - b` is 1.0 at every sampled point.
Six of the seven named no diagnostic code, and that was deliberate in every
case: VerA emits *nothing* today, so there is no stable code to pin, and a guessed code
leaves the marker stuck at XFAIL on the day the gap closes under a different one.
`DiagnosticsReported` is the honest trigger — each of these modules has exactly one
defect, so any diagnostic at all means someone diagnosed it. Two headers go further
and name the code that would be *wrong*: a CAPABILITY CLASS fires on the name in any
context, which is not the rule in question in `10`. Deleted `08` used to be the third
and the proof of that argument — the rule it wanted was about the CONTEXT, and E0818
says "can only be called from a connect module", which stays true and stays correctly
placed the day VerA has one. It is the reason the argument is kept here even though the
fixture is not: when `08` went, it took the claim with it and left the shape behind,
which is the same shape `10` still carries. VerA had one such
code, E0801 "unsupported system function"; it is retired, because every name on its
list (§9.13's draws, §9.21 `$table_model`, §9.16 `$simprobe`) turned out to be
implementable after all — which is itself the argument against pinning one.

| Fixture | Row it serves | Reason |
|---|---|---|
| `09_null_statement_unconditional_rejected.va` | G.1 Null row, `sG-2-2` prohibition | Green. VerA's `analog_seq_block` parser used to skip a stray `;` instead of rejecting it. A.6.4 gives `analog_statement` no null alternative and A.6.3's `analog_seq_block` takes `{ analog_statement }`, so a free-standing `;` inside `analog begin ... end` is underivable |
| `10_limexp_v1_spelling_rejected.va` | G.1 Limiting exponential | Green. VerA used to alias the retired v1.0 `$limexp()` beside `limexp()` in codegen. `$limexp` is absent from Table 9-11 and A.8.2, so the conforming diagnosis is an unknown function. Deleting the alias drops the call into codegen's abort path rather than into a diagnostic, which is the second reason no code is pinned |
| `11_brace_array_initialiser_rejected.va` | G.4 item 2, G.1 Array setting | Green. VerA used to accept a brace-only array initialiser. §3.4 *shall* have the `'{ }` assignment pattern so a list of values is distinguishable from a concatenation. The parameter is deliberately not referenced in the analog block: with `DiagnosticsReported` as the trigger, any second defect would XPASS the fixture and read as the apostrophe rule landing |
| `13_realtime_analog_context_rejected.va` | G.1 Analog time / `$realtime :timescale` | Green. VerA used to alias `$realtime` to `$abstime` in codegen — one branch returning `inst.abstime` — instead of refusing it in the analog context, and it marks `` `timescale`` `.ignored` in the preprocessor, so neither the analog-context rule nor the scaling exists. Two defects, one row |
| `20_final_step_empty_parens_rejected.va` | G.2 item 13 | Green. VerA used to tolerate an empty `analysis_list` in `@(final_step())`, parsing it as the no-argument form. Both legal forms already pass elsewhere (`ch05_analog_behavior/final_step.va`, `ch05_analog_behavior/initial_final_analysis_lists.va`); only the error was open |
| `22_input_port_contribution_honoured.va` | G.7 item 7922 | Green, and it is the only fixture here whose digit comes out of a SOLVE: no `//! bias` on `i`, so `//! solve` leaves it to the device, whose one KCL row (`res[i] = -1e-3`, `d res[i]/d x[i] = 1e-3` — a 1 mA source into a 1 kohm conductance) puts V(i) = 1. A compiler that parsed the contribution and dropped it, which the deleted pre-2023 error used to justify, reads 0 |

## What this annex needs that no fixture supplies

An empty cell above is a real gap. 218 of 238 rows have no fixture *in this folder*,
and most of them should not — a row reading "clarified the description of `$limit()`"
points at §9.17.3, and §9.17.3 belongs to `ch09_system_tasks/`. The list below is
scoped accordingly: it is the subset where the change is a *retirement* or a
*relaxation*, so the current chapter text no longer mentions the thing that went away
and a chapter fixture is unlikely to reach it. Each entry says whether the search for
an owner elsewhere was made and what it found.

- **Tables G.3, G.5 and G.6 in full — 100 rows, no fixture here cites any of them.**
  These are the v2.2→v2.3 list and the two Mantis tables, almost entirely additions
  and corrections to clauses that live in the chapter folders. Spot-checked: G.6 item
  2792 (`$monitor` in the analog context) has fixtures under `ch09_system_tasks/`, and
  G.6 item 4815 (empty disciplines deprecated) has `ch03_data_types/31_domainless_discipline.va`.
  The tables are not audited row by row here, and that is itself the gap — nobody has
  walked 100 rows to find out which have an owner.
- **Table G.1's retired `function` spelling.** The v1.0 form declared a user-defined
  analog function with the bare `function` keyword; v2.0 requires `analog function`.
  Nothing here rejects the bare form. `07_obsolete_default_function_type.va` covers the
  *directive* that used to make bare functions analog, which is the adjacent rule, not
  this one.
- **Table G.1's default changes.** `initial_step` and `final_step` moving from a `TRAN`
  default to `ALL`, and the empty-discipline / implicit-node default-definition rows.
  These are silent behaviour differences — a v1.0-era front end compiles identical
  source and answers differently — which is exactly the class a change-history fixture
  catches and a chapter fixture does not, because the chapter text only states the
  current default.
- **Table G.2 item 12, array specification before the variable identifier.** The
  retired form (`real [0:3] x;` rather than `real x[0:3];`) appears in no fixture in
  the tree. A syntax rejection with no owner anywhere.
- **Table G.7 item 7811, `transition()` when interrupted.** The word does not appear in
  any `.va` in the tree. `23_transition_fall_time_binding.va` covers §4.5.8's ramp
  shape on an uninterrupted edge; the interrupted-transition behaviour the 2023 rework
  added is untested everywhere. (VerA takes a reading — a reversal mid-ramp restarts
  from where the output is, see `zTransStep` — and nothing pins it.)
- **Table G.1's time tolerance on `timer()`, and G.7 item 7810.** The transition-filter
  twin of the G.1 row is `21_transition_time_tolerance.va`; the `timer()` half has no
  fixture here, though `ch05_analog_behavior/` does call `timer()` with three or more
  arguments. 7810's actual content — those tolerance arguments as *dynamic expressions*
  rather than constants, across `transition()`, `timer()`, `cross()`, `above()` and
  `absdelta()` — is not exercised by anything in this folder.
- **`sG-2-3` Figure G-1's six semantic paragraphs** (index locality, elaboration-time-only
  bounds, the no-execute sign cases, lower==upper, the default increment, the unrolling
  rule). Untestable by construction — the construct is gone and the only conforming
  answer to all six is the same rejection `06_obsolete_generate.va` already pins.
  Listed so a diff against the annex text does not read as an oversight.

Two rows that looked like gaps and are not, recorded so they are not re-opened:
Table G.1's port branch access `I(a,a)` → `I(<a>)` is covered on both halves —
`ch04_expressions/34_port_access.va` for the current form, and
`ch04_expressions/86_same_flow_terminals.va` (green, E0315) for Table 4-16's rejection
of the retired one, which is also Table G.4 item 6. Table G.1's `k` scalar row is an
*Extension*, not a retirement — v1.0 supported only `K` and v2.0 added lowercase `k` —
and `ch02_lexical/07_si_scale_factors.va` owns it. Table G.2 item 1, parameter range
checking on the final value, is owned by the `ch03_data_types/45_parameter_range_*`
family.

## Cite convention, and where it is inconsistent

Worth writing down because it will confuse the next reader. §G.1 is a single subclause
holding all seven tables; there is no §G.2 through §G.7. So a fixture pinning a row of
Table G.2 has nothing to cite but `G.1` — and a bare `//! lrm G.2` would be read as
§G.2 *Obsolete functionality*, an entirely different section. Four fixtures follow that
reasoning (`11`, `16`, `19`, `20` all cite `G.1` for content in Tables G.2 and G.4);
three others cite `G.7` directly (`02`, `03`, `22`), which is a table number and
not a subclause number. A fourth, deleted `08`, cited it the same way. `validSection` in `lib/backend/tb.zig` checks the *shape* of a
cite, not its existence in the HTML, so both pass. Neither is wrong so much as they are
two conventions, and the second one is only unambiguous because Table G.7's number
happens not to collide with a section.

Every fixture here also carries at least one live-clause cite alongside the Annex G one
— `9.10`, `4.5.7`, `4.5.13`, `A.6.4`, `3.4` — which is the part that actually anchors
the requirement. The Annex G cite says *why the fixture exists*; the chapter cite says
*what it tests*.

## The fixture that cites no Annex G clause

`23_transition_fall_time_binding.va` (`//! lrm 4.5.8`) is in this folder because it is
`21_transition_time_tolerance.va`'s sibling — same grid, same falling edge, same
`` `timescale``-free transient — and the two were written together to separate one
concern from another. `21` states only what the fifth argument fixes, VerA gets that
right, and it keeps guarding the argument binding. `23` states where the ramp *sits* —
which argument a falling edge binds to, and that the traversal is linear — and both now
hold. The ramp digit is still not repeated in `21`, for the reason it never was: one
rule, one place it is stated.

Analysis split: two fixtures are `//! analysis tran` (`21`, `23`, both on
`time 0, 1n, 3n` with `wave V(in) = 1, 0, 0`), one is `//! time 1e-6` (`01`), one is an
explicit `//! analysis dc` (`15`, because the null event body is only observable when
the event does not fire). The other eighteen are the default operating point, and
thirteen of those are `//! reject` fixtures that never reach a solve at all — leaving
five that actually run and check a number: `02`, `03`, `05`, `14` and `22`.
