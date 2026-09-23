# Annex A source and evidence review

Review date: 2026-09-23. Source: supplied VAMS-2023 PDF, printed
355–386 (physical 368–399), Annex A preamble through A.10. Every page was
read as extracted text and visually inspected at 1700-pixel rendering width;
the visual pass includes every grammar block and all five detail footnotes.
Compared against the complete current `docs/annex-a-syntax.html`, base SHA-256
`e939de3bf79d7a42daf231734869f27a9ed55ac364b7d1923882f4cb41417ccf`.
This is a source-fidelity review, not proof of complete parser or runtime coverage.

## Main integration checkpoint

Integrated 2026-09-23. Main read this complete report and the HTML/fixture
patches, visually checked the signed-base source page (physical395), and read
the complete timing-event grammar chain in A.7.5.1–3. A mechanical comparison
against HEAD confirmed every decoded syntax block is unchanged. Fixture46's
executable body and non-LRM directives, including XFAIL, are unchanged.
The coverage introduction and A.1.1/A.1.5 rows now supersede their old claims.

Direct main checks reproduced E0232/exit1 for the new library-in-design
negative, and exit0/W0251 for both missing-event-control cases. Existing
fixture64, with legal posedge controls, exits0 as a syntax neighbor; its carrier
assertion is not timing behavior. The documentation suite passed28 tests.
Full strict/coverage integration is pending separately; no percentage or
whole-production closure is inferred from these bounded checks.

The completed strict run exited1. Its nonempty sorted FAIL/XFAIL name diff
against the Annex E/F/G/H checkpoint added only
`annex_a_syntax/audit_period_requires_event_control.va` and
`annex_a_syntax/audit_width_requires_event_control.va`, both XFAIL.
The isolated library-in-design negative passes. The legacy fixture46 marker
remains; withdrawing its invalid claim is not implementation closure.

## HTML corrections and source anomalies

| ID | Source / HTML anchor | Finding and disposition |
|---|---|---|
| A-TEXT-001 | p. 382 / `a-8-7` | All eight signed-base alternatives incorrectly bolded their entire `[s|S]` sequence. Restored literal apostrophe, s/S and base letter separately; brackets and alternative bar remain meta-symbols, matching source color/type. No character was changed. |
| A-TEXT-002 | pp. 385–386 / transcription note, `a-9-3`, `a-10` | Blanket interpretation of every plain bracket as optional syntax misleadingly admits empty identifiers. Editorial note now distinguishes lexical character classes and the mandatory A.10 restrictions. Source productions unchanged. |
| A-SOURCE-001 | pp. 369, 381 / `a-6-2`, `a-8-5` | Source contains undefined scalar/array analog lvalue nonterminals; array assignment already includes a semicolon before its parent adds another. Preserved with editorial warning, not a fabricated double-semicolon rejection requirement. |
| A-SOURCE-002 | p. 381 / `a-8-5` | Source spelling `array_ variable_identifier` contains an internal space. Preserved and labeled. |
| A-SOURCE-003 | p. 364 / `a-2-8` | `string_declaration` is referenced but not defined in this annex. Preserved and labeled; chapter declaration rules still apply. |
| A-SOURCE-004 | p. 382 / `a-8-7` | Source prints the underscore of `non_zero_unsigned_number` in ordinary type, unlike adjacent value productions. Preserved and explained, rather than claiming it is an HTML omission. |

The other grammar areas were compared, including inherited digital syntax:
A.1 source kinds/configuration/natures/disciplines/connectrules/paramsets;
A.2 declarations/strengths/delays/functions/tasks; A.3 primitive instances;
A.4 hierarchy and generates; A.5 UDP tables; A.6 analog and digital statements;
A.7 specify paths and timing checks; A.8 expressions/functions/lvalues/literals;
A.9 attributes/comments/identifiers/white space; A.10 lexical details.
No additional substantive transcription omission was established in this pass.
This does not resolve ambiguities in the presentation grammar: the preamble
explicitly requires semantic restrictions elsewhere in the manual.

## Concrete fixture defects and open evidence

The existing `tests/fixtures/annex_a_syntax/COVERAGE.md` is a useful index,
not an atomic-rule closure ledger. Its opening “states no semantics” is too
strong: A.10 states mandatory restrictions, and the preamble explicitly makes
the chapter restrictions necessary. Its historical counts and “green” labels
are not remeasurement results from this review.

| ID | Existing evidence | Required correction / remaining obligation |
|---|---|---|
| A-EVID-001 | `46_library_source_text.va` | Invalid required-positive oracle. It mixes a `library_declaration` with a carrier module in one input. A.1.1 admits no module in `library_text`; A.1.2 admits no library declaration in `source_text`. Its own header acknowledges E0232 is correct. Future acceptance must not become the conformance goal. Convert the mixed input to a specific rejection regression; move the positive obligation to separate library-map input, referenced design source and observable binding through a real map-reader invocation. That interface remains open. |
| A-EVID-002 | `47_configuration_source_text.va`, coverage A.1.5 row | Fixture has three rule arms (default/liblist, instance/use, cell/liblist), not all five; instance/liblist and cell/use remain distinct variants. Carrier voltage does not depend on binding; W0253 explicitly reports ignored configuration. Need selection-sensitive configured design, not merely an accepted config block. |
| A-EVID-003 | `54`–`59`, `63`, `64` carrier assertions | Syntax witnesses are not independent behavioral checks of strengths, delays, gates, UDPs, paths or timing checks. W0251/W0252 and discarded constructs cannot close inherited digital behavior. Each syntax alternative also needs invalid boundaries; one keyword does not cover its whole production family. |
| A-EVID-004 | `64_timing_checks_unsupported.va` | Header explicitly admits a union parser accepts a bare reference where `$width`/`$period` require event control. Two new isolated rejection fixtures below pin this gap. Existing positive forms with `posedge` remain relevant syntax witnesses, not notifier/timing behavior. |
| A-EVID-005 | `35_escaped_system_identifier_rejected.va` | Correctly rejects an undeclared ordinary escaped identifier; does not prove escaped names beginning with `$` are forbidden user identifiers. Its header makes the distinction. Pair with a declared escaped-name positive, separately test whitespace after a genuine system prefix, and retain the A.10 detail-4 reference. |
| A-EVID-006 | Whole directory | Clause tags are not an enumeration of every alternative, optional-present/absent arm, repetition boundary, ordering restriction, lexical boundary or semantic interaction. Need rule-level mapping plus independently derived observable oracles and invalid-input evidence. Passing a finite suite cannot by itself prove all programs conform. |

The source has full digital grammar, not a Verilog-A-only grammar. Missing
digital runtime evidence is not an exclusion from full AMS conformance. In
particular A.3, A.5, A.6 digital statements and A.7 require coordination with
IEEE gate/UDP/scheduling/timing semantics, not simply duplicating analog carriers.

## New targeted negative fixtures

`audit_width_requires_event_control.va` and
`audit_period_requires_event_control.va` derive rejection directly from
A.7.5.1–A.7.5.3 (printed 375–376): `controlled_reference_event` derives a
`controlled_timing_check_event`, whose event control is mandatory. A bare input
identifier is insufficient. This is not the optional event-control production
used by other timing-check arguments.

Both were run with the existing root `zig-out/bin/vera --check --contract
tools/contract.zig`, absolute root include/contract paths and own fixture
directory on the include path. Both exited 0 and emitted only W0251: currently
accepted invalid syntax. Both therefore carry XFAIL plus the intended specific
diagnostic substring `timing check requires an event control`. That phrase is
not an observed compiler diagnostic and does not occur in the echoed invalid
source line. Full benchmark XFAIL/XPASS enforcement remains for main integration.
No runtime timing behavior is claimed and no full build was run by this agent.

## Integration and measurement boundaries

Own patch: `docs/annex-a-syntax.html`, this report, three uniquely named
fixtures, and quarantine comments/tag withdrawal on legacy fixture 46.
Fixture 46's executable checks and XFAIL are retained unchanged: it is an
implementation-regression row, not a required normative positive. Its required
map-reader obligation is now the open A-EVID-001 row above. Measure A still
counts this legacy regression and therefore is not a normative denominator.
`audit_library_declaration_in_design_rejected.va` separately pins E0232 for
the source-derived design-input restriction: the targeted check exited 1 with
E0232, as required. Mechanical comparison confirmed every HTML syntax block's
decoded text is unchanged, and fixture 46's HDL, XFAIL and non-LRM machine
directives are unchanged. The old coverage ledger requires
reconciliation with this explicit superseding record. Source review
clarifies measure B obligations; the new rows affect measure A only when the
official suite is measured, and do not close measure C by themselves. No
measurement or complete-coverage percentage is asserted here.
