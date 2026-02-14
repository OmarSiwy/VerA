# IEEE expression sizing, signed evaluation and truncation audit

2026-09-23. Complete §§5.4–5.6 read, printed62–67 / physical92–97,
including Table5-22, footnote and every example. Visually inspected physical93
and96 for the complete size table and extension/truncation wording. Source:
docs/1364-2005.pdf SHA256
3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e.
Bounded dependencies reread: §5.1.10 bitwise introduction/AND table,
§5.1.13 conditional introductory semantics, §4.8 minimum integer width.
This does not claim complete IEEE Clause5 or all operator tables newly read.

Existing conformance-expressions.md and lexical/type ledgers remain relevant
to AMS extensions. Existing root digital expressions.v already exercises many
context boundaries; it was read and freshly executed rather than duplicated.
No shared expression code, HTML or existing fixture was modified.

## Source-backed rule groups

| ID | Clause | Atomic distinctions and evidence boundary |
|---|---|---|
| WIDTH-CONTEXT | 5.4/5.4.1/5.4.2 | Assignment destination contributes width, not signedness. Propagate context through arithmetic before evaluating intermediate results, so carry/product may survive. Existing expressions covers addition/product and129-bit carry; not every arithmetic operator/width combination. |
| WIDTH-SELF | Table5-22/5.4.3 | Concatenation operands, logical/reduction operands, shift/power RHS and conditional predicate are self-determined. A wider destination cannot restore overflow lost inside these boundaries. Existing expressions has representatives; replication, delay and function-return contexts need their own evidence. |
| WIDTH-COMPARE | 5.5.2 | Comparison operands share type and max width with each other, independently of the enclosing expression; result is one-bit unsigned. Existing comparison-boundary case covers one distinction, not every signed/unsigned and x/z pair. |
| TYPE-SIGNED | 5.5/5.5.1 | Decimal signed, based unsigned unless s; unsigned context operand forces unsigned common type; all signed stays signed except specific exceptions. Destination signedness does not propagate into RHS type. Existing mixed arithmetic/shift/conditional cases remain bounded. |
| TYPE-BOUNDARY | 5.5.1 | Bit/part selects and concatenations unsigned, including full-vector part-select; comparisons unsigned. New signed-boundaries fixture rejected at packed select before observations. |
| TYPE-CAST | 5.5 | signed/unsigned cast changes sign metadata, not input width/bits. New isolated cast-width fixture passes source's4-bit negative example extended into8bits. |
| TYPE-REAL | 5.5.1/5.5.2 | Real dominates common type; nonreal operand of a real-result operation is evaluated as self-determined before real conversion. Real-to-integer coercion signed. Independent nested-real runtime evidence remains open; inherited math return-type audit is not universal expression closure. |
| EXT-SIGNED | 5.5.3/5.5.4 | RHS sign controls extension even into unsigned destination; x/z sign bits replicate, unsigned/concat pads0. New unknown-extension fixture passes; signed arithmetic unknown produces allx. |
| EXT-UNSIZED | Table5-22 footnote | Unsized top-x/z constant extends that state into a context wider than32. New129-bit positive rejected at unsized fill, so no runtime evidence. Sized unsigned unknown remains zero-padded above its declared width. |
| TRUNC-MSB | 5.6 | Discard MSBs, independent of declaration index direction; low x/z preserved. Truncating sign bit may change sign. New ascending/descending fixture passes source's negative-to-positive example. Width mismatch does not require warning or error. |

These are obligation groups, not a complete cross-product or certified rule
denominator. No parser acceptance or incidental unsupported diagnostic is
counted as behavioral success.

## New fixture derivations and measured outcomes

All files are tests/fixtures/digital/audit_expr_NAME.v with exact expected
transcripts. Root vera --run was invoked from the agent worktree.

- cast_width: -4'sd4 has4-bit1100. unsigned cast zero-extends to00001100;
  signed cast of4'b1100 sign-extends to11111100. Exit0, exact expected line.
- unknown_extension: signed4-bitx101/z101 widen toxxxxx101/zzzzz101;
  unsignedx101 and concatenated signed operand widen to0000x101. Signed
  cast restores sign extension; addition of signed unknown and signed0 yields
  xxxxxxxx. Exit0, both expected lines match. The final fixture has no packed
  select, keeping that unsupported operation from masking extension behavior.
- truncation_direction:8'sh8f is negative, but its low5bits01111 represent
  positive15 in both [0:4] and [4:0] signed declarations. Low4bits of
  8'b1010xz10 remainxz10. Exit0, both expected lines match.
- signed_boundaries: signed8'h80 widens toff80; full part-select and concat
  widen to0080; bit7 widens to0001. An explicitly signed destination receiving
  the unsigned full part-select still gets+128. Exit1/E1100 at unsupported
  packed select. Later expectations are intended, not executed evidence;
  cast behavior is independently isolated above.
- unsized_unknown_extension:129-bit contexts receiving 'hx/'hz must be
  entirelyx/z. In contrast4'bx has only fourx bits and125leadingzero bits.
  Explicit129-bit patterns supply the comparison oracle. Exit1/E1100:
  unsized four-state literal context fill is not implemented. No rejection
  marker is added to this legal positive.

Current root expressions.v exits0 and exactly matches its existing transcript.
That measured match does not establish that every expectation is portable;
see the independent oracle issue below. No full builds or gates were run.

## Existing oracle portability issue

expressions.v's unsigned-arithmetic-shift observation expects1 for
`((negative>>>count)+0)<32'h80000000`, with native integer negative=-1 and
count=1. With32-bit integer/unsized0 this becomes unsigned0x7fffffff and is
less than0x80000000. IEEE §4.8 permits integer widths above32; with a wider
native integer the shifted unsigned value remains above that threshold and
a conforming result is0. This is an implementation-width regression, not a
portable conformance discriminator as currently written. A fixed-width
alternative must explicitly size BOTH the signed operand and the added zero;
changing only the declaration leaves an unsized0 capable of widening it again.
Existing root fixture is left unchanged for coordinated review; this withdrawn
portable claim is assigned to WIDTH-CONTEXT, not hidden by weakening results.

## Source tensions and negative-test policy

§5.5.4 broadly describes any nonlogical operation on a signed x/z operand as
allx, whereas bitwise/conditional clauses supply bit-specific truth tables.
Do not turn that broad sentence into a new oracle forcing allx for every
bitwise or conditional expression. The new allx case is arithmetic addition,
where the result is unambiguous; the wider wording interaction remains an
explicit source-interpretation boundary. Likewise distinguish extending
new high bits with a sign x/z from replacing already-present low bits.

Truncation and assignment-size mismatch are expressly allowed without warning.
Neither deserves an invented invalid-input fixture. Cast arity/type legality,
illegal selects and invalid replication counts belong to their precise syntax
and operand clauses; legal-but-unsupported inputs remain positive debt. Any
future genuine digital negative must opt into the digital runner explicitly
and require a distinctive diagnostic, not generic unsupported execution.

No conformance measurement, full-Clause5 closure or exhaustive coverage is
claimed. Integration owns complete gates and FAIL-name-list comparison.

Root integration, 2026-09-23: main read the report and every new fixture, and
independently checked IEEE4.8's minimum-width rule. All five pairs are now in
the root tree. The existing unsigned-arithmetic-shift expression now sizes
both its negative operand and zero to32 bits, retaining the intended unsigned
context propagation and result1 on wider-native-integer implementations too.
Root `--run expressions.v` exits zero and matches its entire unchanged expected
transcript. The full root digital runner now confirms the three passing new
cases and the two documented unsupported legal cases, with no pre-existing
failure-name changes. Root unit gate passes; strict/final measurement is pending.
