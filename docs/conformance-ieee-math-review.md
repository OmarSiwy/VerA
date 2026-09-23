# Inherited IEEE math-function review

Reviewed2026-09-23 against IEEE1364-2005 §17.11–17.11.2, printed323–324 /
physical353–354, including every Table17-18 row. Full text and both rendered
source pages inspected. Licensed PDF hash/provenance is recorded in
`conformance-ieee1364.md`; no licensed source text or images are redistributed
here. AMS2023 §9.14 printed241/physical254 was text-read and compared with the
current Chapter9 HTML; its extension and alias statements do not reproduce all
inherited requirements. Chapter9 owner independently reviewed that page.

Main integration checkpoint (2026-09-23): main read this report and every new
fixture/transcript, independently checked the complete IEEE17.11 source text
and Table17-18, and integrated the four digital pairs. Full digital execution
and exact failure-name comparison are pending separately; no new passing result
is inferred merely from copying the worker's observations.

Subsequent main execution: the full digital gate reproduces the three named
math failures (wide clog2, constant declaration and real result). Explicit
filtered execution selects and passes the unsigned test. The main unit gate
exits0; no previous digital failure changes membership. These finite witnesses
contradict the historical whole-clause verified label, which is now partial in
`CLAUSE-AUDIT.md`; its historical aggregate totals are not silently recomputed.

## Applicable rules and evidence boundaries

| ID | Source | Obligation and coverage needed |
|---|---|---|
|IMATH-CONST|17.11|Math system functions are usable in constant expressions, subject to IEEE Clause5. Runtime evaluation of literal arguments alone does not demonstrate declaration/parameter elaboration.|
|IMATH-CEIL|17.11.1|$clog2 computes the integer ceiling of base-two logarithm. Exercise exact powers and values immediately on each side, not just9.|
|IMATH-ZERO|17.11.1|Explicit zero-operand result is0. One also gives0 mathematically.|
|IMATH-UNSIGNED|17.11.1|Interpret argument as unsigned, including signed packed values and negative integer variables. Preserve operand width; do not use a signed logarithm or clamp negatives to0.|
|IMATH-WIDE|17.11.1|Arbitrary-sized vectors are permitted. Operand widths beyond host64-bit storage cannot be silently replaced with0.|
|IMATH-REALTYPE|17.11.2|Every listed real math function accepts real arguments and returns a real. Integer-assignment results alone may hide an integer implementation.|
|IMATH-CLIB|17.11.2/Table17-18|Behavior matches the corresponding C math-library operation. Requires per-function numerical/argument-order/domain/boundary evidence, with C-standard/environment dependencies explicitly resolved.|
|IMATH-ANALOG|AMS9.14|Inherited functions are extended into analog context; exceptclog2 they alias the operators in4.3.1/Table4-14. Digital success does not prove analog lowering and vice versa.|

Table17-18 inventory for expanding IMATH-REALTYPE/CLIB: `$ln`, `$log10`,
`$exp`, `$sqrt`, `$pow`, `$floor`, `$ceil`, `$sin`, `$cos`, `$tan`, `$asin`,
`$acos`, `$atan`, `$atan2`, `$hypot`, `$sinh`, `$cosh`, `$tanh`, `$asinh`,
`$acosh`, `$atanh`. The natural logarithm maps to C `log`, not C `log10`;
`atan2` argument order is preserved. These are rule groups, not an atomic
denominator. AMS-only additions are not retroactively entries of the IEEE table.

### Existing evidence inspected

`digital/d09_10_clog2.v` covers zero,one,small exact/non-exact powers and
assignment to a narrow packed result. Its comment says a real result cannot
produce the expected narrow assignment, which is not a valid discriminator:
assignment conversion can produce the same integral result. Its Table9-11
reference belongs to AMS9.2, not9.14. No existing fixture was edited here.

`ch09_system_tasks/074_clog2.va` covers8 and9; `17_math_unary.va` and
`exhaustive/122_bit_conversions.va` add ordinary positive arguments.
`ch04_expressions/11_standard_math_system.va` and individual Chapter9 math
fixtures test analog numeric values and aliases; alias equality alone cannot
detect an identical defect in both spellings. The extreme-hypot fixture
`ch04_expressions/159_hypot_fmod_extreme_magnitude.va` importantly distinguishes
safe magnitude handling from naive squaring. None of these proves digital
real-math execution. Domain rejection fixture114 combines multiple bad calls,
so one diagnostic may mask a missing guard on another operation.

### New digital transcript fixtures and observations

Run each with the existing root executable, without rebuilding:

`zig-out/bin/vera --run <owned-worktree>/tests/fixtures/digital/audit_ieee_math_<name>.v`

Binary SHA256 at observation:
`306285380ce47f95c1a8dba3db2378b2e9396bbb5e8a558c4887dee516535a75`.
Expected transcripts were derived before execution and remain normative wants,
not copies of failing output. Each is discoverable by the existing digital
transcript runner when integrated with its adjacent expected file.

| Name | Independent oracle | Observed result |
|---|---|---|
|clog2_unsigned|Signed8-bit allones→8; signed32-bit allones→32; signed8-bit128pattern→7; zero/one→0; native integer allones result>=32.|Exit0, exact expected stdout.|
|clog2_wide|65-bit2^64→64;2^64+1→65;129-bit2^128→128.|Exit0 but prints0 for allthree: behavioral failure.|
|constant_expression|$clog2(9) sets declaration width4; replication count$clog2(8)=3 creates0111.|Exit1/E1100, declaration bounds restricted to literals. No runtime reached.|
|real_result|sqrt(2.25)=1.5 lies strictly between1.25and1.75; pow(-2,3)=-8; floor(-1.25)=-2;ceil(-1.25)=-1.|Exit1/E1100 at sqrt expression, before later checks. Not independent execution evidence for pow/floor/ceil.|

The digital runner does not invert `//! xfail` markers; these remain honest
failing transcript cases until implementation, not unsupported markers. Main
must measure the integrated suite and FAIL-name changes. No full suite, build,
conformance percentage or closure claim was made by this review.

### Width correction made before handoff

IEEE§4.8 (printed33, read as dependency) permits integer widths of at least32,
not necessarily exactly32. Therefore the fixture uses an explicitly32-bit
packed variable for its exact32 assertion and only `>=32` for native integer
-1. The earlier draft fixed integer to32 and was corrected before handoff.
This distinction was coordinated with the Chapter9 owner, who is testing the
analog signed-input boundary. A wider conforming integer implementation must
not fail our test.

### Implementation inspection (not execution proof)

Current `src/sim/digital.zig` clog2 evaluation explicitly returns0 for operands
wider than64bits, matching the observed wide-input failure. Its system-function
map contains time/stime/clog2, not the IEEE real-math set. The generated analog
`zClog2(a:i64)` helper in `lib/backend/codegen.zig` returns0 whena<=1; that is
a high-risk mismatch for negative integer operands interpreted unsigned.
The Chapter9 owner is independently testing this analog path; do not infer its
runtime result from the digital test or helper inspection.

## Remaining open boundaries

- Expand every real function independently across digital runtime, constant
  elaboration and applicable analog alias paths; a failure on the first call
  does not count as executing all functions later in the fixture.
- Test signed/unsigned packed clog2 widths across storage words, leading zeros,
  width-preserving expressions and exact-power boundaries. Unknown-bit input
  behavior is not specified by17.11 itself; do not invent a mandatory zero or
  mandatory diagnostic from this clause alone.
- Separate real-return typing from implicit assignment conversion. Include
  argument conversions and each mandatory unary/binary arity under the actual
  call syntax rules; do not claim17.11 alone mandates a particular error code.
- Derive atan2 quadrants/argument order, negative integral exponents, signed
  floor/ceil and inverse-function boundaries independently. Alias comparisons
  are supplementary, not an independent numerical oracle.
- Establish the applicable C-library dependency before asserting exact NaN,
  infinity, signed-zero, domain/range-error or rounding details. Do not demand
  one libc's last bit or errno behavior merely because17.11 references C math.
  Reconcile AMS operator-domain requirements separately by context.
- Include large/small hypot without overflow/underflow, exponential ranges,
  cancellation-sensitive inverse hyperbolics and values near singularities.
  Tolerances must follow an explicit error argument; a selected implementation
  constant or a blanket tolerance is not proof of full numerical behavior.
- The AMS HTML inherits IEEE rules by reference. This ledger makes the missing
  unsigned/zero/arbitrary-width/constant-expression obligations explicit without
  presenting paraphrases as additional AMS source paragraphs.
