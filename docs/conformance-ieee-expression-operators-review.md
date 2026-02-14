# Remaining IEEE Clause5 operators and operands audit

2026-09-23. Read complete §§5.1.1–5.1.7,5.1.9,5.1.12,5.1.14,
§§5.2–5.3 and their introductory operator material, tables and examples.
Printed41–49,53,54–62 / physical71–79,83,84–92. Previously reviewed
equality, bitwise, reduction and conditional sections remain with their prior
reports; §§5.4–5.6 remain in conformance-ieee-expression-width-review.md.
This completes the assigned residual text traversal, not executable closure.
Source docs/1364-2005.pdf SHA256
3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e.
Visual checks: physical73 Tables5-2/3,76 Tables5-6/7/8,91 Syntax5-2.
Other tables/syntax received text review only in this checkpoint.

## Source distinctions and atomic obligation groups

| ID | Source | Requirement / remaining evidence boundary |
|---|---|---|
| OP5-REAL | 5.1.1 Tables5-2/3 | Only listed operators accept real operands; logical/relational results onebit. IEEE forbids real modulus, unlike AMS extension. Do not classify valid AMS real-modulus use as universal invalid input. |
| OP5-PRECEDENCE | 5.1.2 Table5-4 | Equal precedence associates left-to-right except conditional right-to-left; parentheses override. Exponentiation is not silently given a different associativity by analogy with another language. Full adjacent precedence and associativity matrix remains open. |
| OP5-LITERALS | 5.1.3/5.1.6 | Based unsigned versus signed/decimal affects interpretation, not stored bits; destination width participates separately. Informative native-integer numeric examples may assume32bits; fixed-width tests avoid making that implementation choice normative. |
| OP5-EVALUATION | 5.1.4 | Permits early determination without evaluating whole expression, including shown bitwise example. Do not import AMS-specific short-circuit obligations into IEEE-only evidence without reconciling contexts. Observable function-side-effect constraints need dedicated source analysis. |
| OP5-ARITH | 5.1.5 | Integer division truncates towardzero, remainder sign follows dividend, zero divisor yieldsallx; any arithmeticx/z operand yieldsallx. New independent fixed-width test passes. AMS analog error obligations are separate. |
| OP5-POWER | 5.1.5 Table5-6 | Integral exponent self-determined; integer0**0=>1,0**negative=>x, negative exponent truncating cases; real-domain results can be unspecified. Existing root expressions covers selected integer cases; no oracle pins a real result where source leaves it unspecified. |
| OP5-RELATION | 5.1.7 | Any unknown operand bit gives1-bitx even when other bits suggest an ordering; common signedness and extension follow operands. New relational unknown check passes; full operator/width matrix remains open. |
| OP5-LOGICAL | 5.1.9 | Scalar0/1/x truth results; known controlling values resolve ambiguity. Mixed vector known1 is true; no known1 withx/z remains ambiguous. New distinguishing cases pass. |
| OP5-SHIFT | 5.1.12 | Counts treated unsigned/self-determined; x/z count=>unknown; left fillszero; right arithmetic sign-fill only if resulting expression signed. Existing width report/root expressions covers selected cases, not every unknown-count/width combination. |
| OP5-CONCAT | 5.1.14 | Direct unsized numbers prohibited; replication constant known nonnegative constant; zero requires positive-width immediate sibling. Operands evaluated once even at countzero. Replication not legal as assignment target/output/inout connection. New structural neighbor/negatives pass but do not observe evaluation count. |
| OP5-SELECT | 5.2.1 | Vector/reg/integer/time/nonreal-parameter selects; scalar or real selects illegal. Indexed width positiveconstant, base dynamic, direction tied to declared significance. Partial out-of-range reads insertx; writes affect only in-range bits; total out-of-range no write. Source notes permit compile-time diagnostics for certain invalid indices, so do not demand universal acceptance of static out-of-range selects. |
| OP5-ARRAY | 5.2.2 | Every dimension indexed; nested memory indirection legal; out-of-range or anyx/z index readsunknownword. New one-dimensional witness passes; multidimensional/selected-element boundaries remain separately unsupported. |
| OP5-STRING | 5.2.3 | Packed8-bitASCII numeric operand; leftzero padding remains in concatenation/equality; emptystring equalsNUL0, not ASCII digit0. New packed-string positive rejects before execution. AMS string type is a separate extension. |
| OP5-MTM | 5.3 | Triplets permitted wherever expressions occur; compound expression combines corresponding members. New allowed-result test rejects legal grammar. It does not assume defaulttypical or require a specific tool selection policy. |

## New fixtures and outcomes

All under tests/fixtures/digital/audit_expr_NAME.v. Positive siblings contain
independently derived exact transcripts. Direct current-root vera --run,
own-worktree cwd; no compiler edits or full builds.

- arithmetic_unknowns: signed8-bit−10/3=>−3,remainder−1;
  11/−3=>−3,remainder2. Divide/modulo by0 and addingz yield8x bits;
  1x00>0000 yieldsx. Exit0, all expected lines.
- logical_unknowns: !0000=>1,!1xzz=>0,!0xzz=>x;0&&x=>0,1&&z=>x,
  known-true vectors&&=>1;1||z=>1,0||x=>x,zero||known1=>1.
  Exit0, all expected lines.
- memory_address_unknown: memory0=1,memory1=10; nestedlookup gives1010.
  Address3 outside[0:1],00x and00z each givewordxxxx. Exit0, allfourlines.
- mintypmax_context: (1:2:3)*10+(3:2:1) yields13,22 or31 under the
  selected corresponding corner; membership must1. No middle-corner assumption.
  Exit1/E0207 atcolon in ordinary parenthesized expression. Legalpositive
  retained; no generic rejection credit. Unordered triples are permitted per
  separately read7.14.1, not a reason to reject this source.
- string_numeric_padding:16-bit"A" and"B" concatenate to00410042,
  not packed"AB"; emptystring equals8'h00 and differsfrom"0".
  Exit1/E1100 at first string assignment; later checks supply no runtimecredit.
- concat_zero_neighbor: {4'ha,{0{1'b1}},4'h5} yieldsa5. Exit0 exactline.
- concat_unsized_rejected: directunsized1 operand; digital-negativeopt-in,
  exit1/E1100 `unsized constant numbers are not allowed as concatenation operands`.
- zero_replication_alone_rejected: isolated {0{1'b1}} has no positive-width
  sibling; destinationwidth doesnot qualify. Digital-negativeopt-in,
  exit1/E1100 `zero replication requires an immediately enclosing concatenation
  with a positive-width operand`.

The negative fixtures use specific diagnostic markers and the actual digital
route; the neighboring valid concatenation executes. These tests intentionally
do not rely on diagnostic text echoed from comments or generic unsupported
execution. Existing source files/expectations remain unchanged.

## Source fidelity and uncertainty notes

Syntax5-2's printed constant conditional production omits a colon between
its final two constant-expression terms. The rendered page confirms the
omission; retain it as source erratum, not a new legal conditional grammar.
The unsigned native-integer division example's decimal result assumes32bits;
this audit uses explicit8-bit arithmetic and makes no exactintegerwidth claim.
Real power at zero/nonpositive exponent or negative base/nonintegral exponent
has source-unspecified result; no forced finite/NaN/error oracle was added.

Array addressing and packed part-select restrictions are not interchangeable.
The passing unknown memory lookup doesnot establish partial vector writes,
and a packed-select implementation refusal doesnot become valid invalid-input
evidence. Likewise, constant numeric replication doesnot prove once-only
evaluation of side-effectful operands, especially zero replication.

No exhaustive operator truth-table denominator, conformance percentage or full
gate is asserted. Source traversal and bounded runtime evidence remain separate.

## Root handoff boundary

Main read this complete report and the eight proposed fixture sources on
2026-09-23. Their integration remains pending while the current strict run
uses a stable fixture tree. Complete source traversal and worker observations
above are attributed as such; this does not independently certify every
operator/context rule or source rendering. Existing width and analog-function
evidence remain separate.

Root integration follow-up: the eight fixture sources and six positive
transcripts are now integrated. Main independently checked the zero-replication
grammar restriction, packed-string padding rules and min:typ:max expression
context/corresponding-member rules against IEEE5.1.14,5.2.3 and5.3. The
source's missing colon in Syntax5-2 is not used to derive a new grammar rule.
Fresh full digital execution is running under
`/tmp/vera-expression-operators-devices.log`; legal-input failures remain
required positives, not generic rejection fixtures.

The full digital run subsequently exits1. Its exact FAIL/XFAIL name comparison
against the readmem-token checkpoint adds only `audit_expr_mintypmax_context`
and `audit_expr_string_numeric_padding`, the two legal-input failures described
above. All pre-existing failure names remain and the other six new cases pass.
Logs and sorted names are `/tmp/vera-expression-operators-devices.{log,names}`.
