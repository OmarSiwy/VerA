# A01 — Analog expressions, functions and numeric conversions

Greenfield row: no `w2/*` branch covers it. Everything here is new, and
everything here lives outside `tests/fixtures/`, so `zig build torture --strict`
is untouched (still 1323/1323).

## LRM clauses covered

Read offline from `docs/`. Every clause number below was checked against the
actual heading text; none is invented.

| clause | file | what it gives this row |
|---|---|---|
| **§3.2** Integer and real data types | `ch3-datatypes.html` | array declaration ranges ("Both indices shall be constant expressions and shall evaluate to a positive integer, a negative integer, or zero (0)"), the `-2^31 .. 2^31-1` integer range, and the "Real variables are initialized to zero (0)" default |
| **§3.3** String data type | `ch3-datatypes.html` | "A string cannot be assigned to an integral type" — and, separately, that a string LITERAL still converts like a Verilog packed vector |
| **§3.4**, **§3.4.6** Parameters / String parameters | `ch3-datatypes.html` | "Parameters represent constants, hence it is illegal to modify their value at runtime. However, parameters can be modified at compilation time to have values which are different from those specified in the declaration assignment." — so a dimension written `[0:N]` is per-instance; §3.4.6 makes a string parameter a constant expression |
| **§4.2.1.1** Real to integer conversion | `ch4-expressions.html` | "rounding the real number to the nearest integer … exactly 0.5 … rounded away from zero" |
| **§4.2.1** Operators with real operands | `ch4-expressions.html` | the sentence below Table 4-2: "The result of using logical or relational operators on real numbers is an integer value 0 (false) or 1 (true)" — how every fixture here builds an unfoldable index |
| **§4.2.7** Logical equality | `ch4-expressions.html` | the `!=` used in the aliasing assertions |
| **§4.3.2** Transcendental functions | `ch4-expressions.html` | Table 4-15's `asin` domain `-1 <= x <= 1`, and "Input values outside of the valid range for the operator shall report an error" |
| **§4.7.2.3 / §4.7.2.4** Output / Inout arguments | `ch4-expressions.html` | "the argument passed … must be an analog variable reference"; the output-resets / inout-copies-in asymmetry |
| **§5.7** Analog procedural assignments | `ch5-analog.html` | LHS "shall be … an element of an integer, real or string array"; "a slice of an array variable"; the IEEE 1800 delegation for unpacked arrays |
| **§9.17.1** `$discontinuity` | `ch9-system.html` | "where *i* must be a non-negative integer"; `$discontinuity(-1)` as the `$limit` form |
| **§9.17.3** `$limit` | `ch9-system.html` | what `$discontinuity(-1)` means — another Newton iteration |
| **Annex A.8.5** Expression left-side values | `annex-a-syntax.html` | `array_analog_variable_rvalue ::= array_variable_identifier \| array_variable_identifier [ analog_expression ] { [ analog_expression ] } \| assignment_pattern` — the slice spelling, and the fact that a subscript is an `analog_expression`, not a `constant_expression` |

## Ground truth: what is ALREADY implemented

The plan's A01 bullet list overstates the gap. Everything in this table was
compiled and RUN before any fixture was written, and works correctly today —
so no fixture is spent on it, except where noted:

| probed | verdict |
|---|---|
| §4.3.1 result typing: `min(5,2)/4 == 0` (integer) vs `min(5.0,2)/4 == 0.5`; `abs(-7)/2 == 3` vs `abs(-7.0)/2 == 3.5` | correct |
| §4.3.1 `pow(-2.0, 3.0) == -8.0` (the "if x < 0, all integer y" arm) | correct |
| §4.3.2 domain BOUNDARIES: `atan2(0,0)==0`, `asin(1)`, `acos(-1)`, `acosh(1)==0`, `sqrt(0)`, `hypot(3,4)==5`, `ln1p(-0.5)` | all correct to the last bit |
| runtime multidimensional read/write with independently varying subscripts, including a DESCENDING dimension (`real m[0:2][3:1]`) | correct — `assignRuntimeIndex` + `$idx` in `src/ir/lower.zig` |
| negative declared bounds (`real a[-2:2]`) with a runtime negative index | correct |
| §4.2.1.1 in a SUBSCRIPT, constant and runtime paths agreeing: `a[1.5]`, `a[x]` with `x=1.5`, and `a[x]` with `x=-1.5` all round away from zero | correct — and this is the "constant-folding agreement with runtime" item, already sound |
| constant-fold vs runtime agreement generally: `0.1+0.2` folded == computed (`0.30000000000000004`); `sin(0.7)` folded == runtime, bit for bit; `2147483647 + 1` wraps to `-2147483648` in BOTH paths | correct |
| §5.7 whole-array copy `integer A[10:1]; integer B[0:9]; A = B;` with `A[10]==B[0]`, `A[1]==B[9]` | correct |
| integer `/` and `%` by a value that cannot be proven non-zero | refused statically, E0601 — not a crash |
| §4.7.2.3/§4.7.2.4 with CONSTANT subscripts and array formals | already pinned by `tests/fixtures/ch04_expressions/109_function_array_inout_pattern.va` and `124_function_unassigned_output_inout.va` |

Two things this row DOES pin anyway, because nothing in `tests/fixtures/` says
them and the code that implements them is about to be touched: fixture 06 (the
invalid-index WRITE rule, the guard rail that stops 05 being "fixed" by
clamping) and fixture 07 (§4.2.1.1 conversion of a `$discontinuity` degree,
whose shared converter the two crash fixtures 91/92 attack).

## The defects, confirmed by running the compiler

1. **Partial slices do not exist.** `checkSubscriptCount` (`src/ir/lower.zig`)
   requires one subscript per declared dimension; its own header names
   `flag_array[3]` as the case it is refusing. → E0356. Fixtures 01, 02.
2. **An `output`/`inout` actual cannot be a dynamically indexed element.** The
   writeback tail of `inlineUserFuncPre` ends in `resolveLvalue(actual)`, whose
   `.index` arm demands `constEval` on every subscript — even though VerA has a
   perfectly good runtime-index write path (`assignRuntimeIndex`) it simply does
   not reach from there. → E0311. Fixture 04. (E0311's note cites "LRM 3.2.2", a
   clause number that does not exist in this standard; §3.2 is the array clause.)
3. **A parameterized dimension is baked from the parameter's DEFAULT.** The
   storage is scalarized at compile time from `[0:3]` while the index arithmetic
   in the same expression reads `model.N`, which the card set to 5. The two
   disagree by construction; writes past the folded bound are silently dropped
   and the read aborts the device. Fixture 03.
4. **An out-of-range runtime read aborts.** `emitIdx`
   (`src/backend/codegen.zig:4837`) closes its switch with
   `else => @panic("VerA: out-of-range array read is not implemented")`.
   Documented as a gap in that function's header. Fixture 05.
5. **A runtime out-of-domain transcendental argument is a quiet NaN.** §4.3.2
   says "shall report an error"; VerA reports nothing and the run exits 0.
   Fixture 08.
6. **`Const.asInt` crashes the compiler on a non-finite or out-of-i64 real.**
   `src/ir/lower.zig:800`, `.real => |r| @intFromFloat(@round(r))`, no range
   test. Reachable from at least two source constructs — a `$discontinuity`
   degree and an array subscript — both of which abort with
   `panic: integer part of floating point value out of bounds`, exit 134.
   Fixtures 91, 92. One guard in that function fixes both.
7. **`Const.asInt` silently answers 0 for a string.** `.str => 0`, same union.
   A `string`-typed degree therefore becomes `$discontinuity(0)`, the most
   severe announcement there is, with no diagnostic. Fixture 90.

## Fixtures

One line each: what it pins, the expected value, the derivation.

| fixture | pins | expected | derivation |
|---|---|---|---|
| `01_partial_slice_assignment.va` | §5.7 "a slice of an array variable", read and write, spelled as A.8.5's short subscript list | `row[3]=13`, `flag_array[2][0]=99`, `flag_array[2][3]=13`, `flag_array[1][0]=10` | `flag_array[i][j] = 10i+j`, so row 1 is `{10,11,12,13}`. `row = flag_array[1]` then `row[0]=99` then `flag_array[2] = row`. 13 (not 23) proves the whole row moved; 10 proves §5.7 assignment is a copy, not an alias |
| `02_slice_index_is_dynamic.va` | the slice subscript is an `analog_expression` (A.8.5), not a constant | `row[1]=21`, `flag_array[0][1]=21`, `flag_array[2][1]=21`, `flag_array[1][1]=11` | `V(p,n)=0.5`; §4.2.1 makes `V(p,n)>0.0` the integer 1, so `src=2`, `dst=0` and neither folds. Row 2 is `{20,21,22,23}`; copying it to row 0 must leave rows 1 and 2 alone |
| `03_parameterized_dimension_override.va` | §3.2 + §3.4: a dimension is a constant *expression*, so the model card decides how many elements the instance has | `b[N]=10.0`, `b[N-2]=6.0`, `b[0]=0.0` | `parameter integer N = 3` overridden to 5 by `//! param N = 5`; the loop writes `b[i] = 2i` for `i=0..5`, so `b[5]=10`, `b[3]=6`, `b[0]=0`. All small even integers, exact in IEEE 754. `b[N-2]=6.0` (not 2.0) is what proves the whole index range moved rather than just the upper bound |
| `04_dynamic_scalar_output_writeback.va` | §4.7.2.3/§4.7.2.4: an `output`/`inout` actual may be an array element with a runtime subscript (§5.7's "an element of … array", A.8.5's `analog_expression`) | `slot[1]=12.0`, `slot[2]=14.0`, `slot[0]=1.0`, `d=26.0`; then `slot[3]=6.0`, `t=6.0` | §4.7.1 Example 2: `area = 3*4 = 12`, `perim = 2*(3+4) = 14`, return `12+14 = 26`. `i=1`, `j=i+1=2`, `k=3i=3` all derived from the probe (§4.2.1), so unfoldable. The `inout` half starts from `slot[3]=1.0` and adds 5 → 6.0, which also proves the copy-IN happened (a tool applying the `output` reset rule gets 5.0) |
| `05_invalid_index_read_value.va` | an out-of-range runtime read must neither alias another element nor abort; its value is the element default | aliasing checks = `1`; `past_top = past_bot = 0.0` | `a = {1.0,2.0,3.0}`, `hi=5`, `lo=-1` (both from `V(p,n)>0.0` = 1). A clamp gives 3.0/1.0, a modulus gives 3.0 for `lo` — the two `CHECKI`s reject all of those without needing the default. The `0.0` comes from §5.7's IEEE 1800 delegation plus §3.2's real default and is flagged in the fixture header as the one want a reviewer would revisit |
| `06_invalid_index_write_preserves.va` | §5.7: an out-of-range subscript designates no element, so the assignment changes nothing. **PASSES TODAY** — guard rail | `a[2]=3.0`, `a[0]=1.0`, `a[1]=2.0` after writing 99.0 at index 5 and -99.0 at index -1 | a clamp puts 99.0 in `a[2]`, a modulus also puts 99.0 in `a[2]` (5 mod 3), a clamp low puts -99.0 in `a[0]`, and an unchecked flat offset scatters into `a[1]`. This is the file that stops 05 from being made green by clamping |
| `07_discontinuity_real_degree.va` | §9.17.1 + §4.2.1.1: the degree is a `constant_expression` converted per the real→integer rule; `$discontinuity(-1.0)` is the §9.17.3 veto. **PASSES TODAY** — guard rail | `$simparam("iteration") = 2`, `V(p,n) = 1e-10` | `I = V - 1e-10` with `//! solve` puts the single unknown at `V = 1e-10` in one exact Newton step. The guard fires on iteration 1 only, vetoes once, so the accepted point is iteration 2 — not 1 (conversion dropped) and not more (repeat veto). The unconditional `$discontinuity(2.0)` above it must NOT veto, or the solve would run to its iteration limit instead of stopping at 2 |
| `08_transcendental_domain_runtime_error.va` | §4.3.2: "Input values outside of the valid range for the operator shall report an error", for a value that is a SIGNAL and not a constant | point 0 prints `ok=1` twice with `asin(0.5) = 0.5235987755982989`; point 1 never prints and the run exits 1 | π/6 = 0.5235987755982988730771…; the bracketing doubles are …8815658893 (5.74e-17 low) and …8926681195 (5.36e-17 high), so the correctly rounded double is the upper, `0.5235987755982989` — deliberately NOT the same double as `pi/6` computed as a quotient, which lands one ulp low. Tolerance 1e-16 is under one ulp (1.11e-16). Shape copied from `tests/fixtures/ch09_system_tasks/173_fatal_terminates.va` |
| `90_discontinuity_string_degree_rejected.va` | §3.3 "A string cannot be assigned to an integral type" against §9.17.1's "*i* must be a non-negative integer" | refusal | a `string` PARAMETER (constant per §3.4.6, so this is not a constness complaint) has no integral conversion. Today it compiles as degree 0 via `Const.asInt`'s `.str => 0` |
| `91_discontinuity_degree_out_of_range_rejected.va` | §9.17.1 + §3.2's `-2^31 .. 2^31-1`: `$discontinuity(1e300)` names no integer | refusal | today: `panic: integer part of floating point value out of bounds`, exit 134 — no diagnostic at all. `$discontinuity(1.0/0.0)` panics at the same two frames |
| `92_nonfinite_array_subscript_rejected.va` | §3.2 + §4.2.1.1: an infinity has no nearest integer, so `a[1.0/0.0]` names no element | refusal, `//! reject E0310` | same `Const.asInt` line, reached through `lowerIndex` instead of `lowerKernelCtl`; `a[1e300]` is identical. One guard in the shared converter fixes 91 and 92 together |

Eight positive fixtures, three refusals.

### Observed today

Captured, not typed. Re-captured at review time by running the two loops in
**Build / run** below against a fresh `zig build install`, filtering each run's
combined output with `grep -E '^(error|thread|.*ok=)'` and appending the shell's
own `$?`. Nothing below is retyped from memory; the only editing is that filter
and the replacement of the panic's live thread id with `…`.

```
##### 01_partial_slice_assignment.va
  error[E0313]: unknown variable: `row`
  error[E0356]: wrong number of array subscripts: `flag_array` is declared with 2 dimension(s) and is indexed with 1
  error[E0356]: wrong number of array subscripts: `flag_array` is declared with 2 dimension(s) and is indexed with 1
  error[E0314]: unknown identifier: `row`
  error: could not compile due to 4 previous error(s)
  exit 1
##### 02_slice_index_is_dynamic.va
  error[E0313]: unknown variable: `row`
  error[E0356]: wrong number of array subscripts: `flag_array` is declared with 2 dimension(s) and is indexed with 1
  error[E0356]: wrong number of array subscripts: `flag_array` is declared with 2 dimension(s) and is indexed with 1
  error: could not compile due to 3 previous error(s)
  exit 1
##### 03_parameterized_dimension_override.va
  thread … panic: VerA: out-of-range array read is not implemented
  exit 1
##### 04_dynamic_scalar_output_writeback.va
  error[E0311]: array index is not a constant expression: indexing `slot`
  error[E0311]: array index is not a constant expression: indexing `slot`
  error[E0311]: array index is not a constant expression: indexing `slot`
  error: could not compile due to 3 previous error(s)
  exit 1
##### 05_invalid_index_read_value.va
  thread … panic: VerA: out-of-range array read is not implemented
  exit 1
##### 06_invalid_index_write_preserves.va
  a write past the top changes no element got=3 want=3 ok=1
  a write below the bottom changes no element got=1 want=1 ok=1
  and neither scatters into the middle of the array got=2 want=2 ok=1
  exit 0
##### 07_discontinuity_real_degree.va
  $discontinuity(-1.0) converts to -1 and vetoes exactly one iteration got=2 want=2 ok=1
  and the vetoed solve still lands on the same operating point got=0.0000000001 want=0.0000000001 ok=1
  exit 0
##### 08_transcendental_domain_runtime_error.va
  printed at the in-domain point only got=1 want=1 ok=1
  asin(0.5) is pi/6, correctly rounded got=0.5235987755982989 want=0.5235987755982989 ok=1
  printed at the in-domain point only got=0 want=1 ok=0
  asin(0.5) is pi/6, correctly rounded got=-nan want=0.5235987755982989 ok=0
  exit 0
##### 90_discontinuity_string_degree_rejected.va   exit 0, device emitted   (should refuse)
##### 91_discontinuity_degree_out_of_range_rejected.va   exit 134
  thread … panic: integer part of floating point value out of bounds
  src/ir/lower.zig:804:26 in asInt  <- src/ir/lower.zig:6769 in lowerKernelCtl
##### 92_nonfinite_array_subscript_rejected.va           exit 134
  thread … panic: integer part of floating point value out of bounds
  src/ir/lower.zig:804:26 in asInt  <- src/ir/lower.zig:7050 in lowerIndex
```

Reading it: 01/02/04 exit 1 with a diagnostic (the honest missing-feature
refusals); 03/05 exit 1 by aborting the *generated device* at run time, which is
not a diagnostic; 08 exits **0** — `//! exit 1` is only graded by the torture
runner, `--run` does not enforce it, so the two `ok=0` lines are 08's whole
signal today.

Two lines of the old block were hand-edited and are corrected above: 07 printed
`got=0.0000000001`, not `got=1e-10` (`check.vh`'s `%g` is shortest-repr), and
08's fourth line prints `want=0.5235987755982989`, not `want=0.523599` — the
`want` string is the same on both of 08's `asin` lines, because it is the same
literal. 01's summary line also elided one diagnostic (E0314) and 02's elided
the message text. Every value asserted by a fixture was already right; only the
transcript's fidelity was not.

06 and 07 pass and are meant to. The other nine are the deliverable.

## Deliberately NOT covered

- **The non-negative `$discontinuity` degree's VALUE.** Unobservable from a
  `.va`: VerA lowers it to `inst.discontinuity_order`, `src/backend/tb.zig`
  never prints that field and ARPice never reads it
  (`src/analysis/solvers/converger.zig:294` mentions it in a comment only). 07
  pins that a real degree is accepted and is not a veto, which is as far as the
  source language can see. Distinguishing `$discontinuity(2.0)` from
  `$discontinuity(0)` needs an ARPice fixture once the converger consumes the
  field; that belongs to whoever wires the host side.
- **`$discontinuity("two")` with a string LITERAL.** §3.3 keeps Verilog's
  packed-vector behaviour for literals, so that converts to `0x74776F`, a legal
  (if useless) non-negative degree. It is NOT a rejection and is not asserted
  either way. Only the `string`-TYPED case (90) is.
- **`$bound_step`'s argument conversion.** Same clause family (§9.17.2), same
  `Const` union, different task; it takes a real and does not go through
  `asInt`, so its exceptional-value behaviour is a separate question.
- **String and integer element defaults for an out-of-range read.** 05 does the
  `real` case only; `""` for `string` and the integer default are the same code
  path with a different `zeroOf`.
- **Denormals.** The FOCUS names them; nothing here exercises one. VerA does no
  flush-to-zero anywhere that was found, and a denormal fixture would pin the
  Zig backend's float mode rather than a Verilog-AMS clause.
- **Hierarchical / multi-instance dimension overrides.** 03 overrides one
  parameter on one flat instance. Two instances of the same module with
  different `N`, which is where a compile-time scalarization really breaks,
  needs module instantiation and is blocked on the same thing every other row
  is blocked on.
- **Finite-difference derivatives and `ddx`.** That is row A04.
- **The host.** No ARPice fixture is written. Every defect above is visible in
  VerA's own testbench, so there is nothing a `.sp` + `.expected.json` pair
  would add that the `.va` files do not already show one layer in.
- **The exit CODE in 08.** §4.3.2 says "report an error" and does not say the
  run terminates. `//! exit 1` follows §9.7.3's `$fatal` convention, which VerA
  already uses and which matches VerA's own treatment of a CONSTANT out-of-domain
  argument as a hard error. If the project decides a runtime domain violation is
  a continuable §9.7 `$error`, drop the `//! exit 1` line and keep the two
  assertions — the silent NaN is wrong under either reading.

## Corrected after review

1. **§4.2.5 → §4.2.1, six places.** The sentence "The result of using logical or
   relational operators on real numbers is an integer value 0 (false) or 1
   (true)" was attributed to §4.2.5 in fixtures 02, 04, 05, 06 and 08 and in the
   clause table above. Opened `ch4-expressions.html`: that sentence sits in
   **§4.2.1 Operators with real operands**, immediately under Table 4-2. §4.2.5
   Relational operators is a real clause and does say "yields the value zero (0)
   … or the value one (1)", but it never says *integer*, does not contain the
   quoted text, and covers only `< > <= >=` — while fixture 05 also leans on
   `!=`, which is §4.2.7. Fixture 05's prose already cited §4.2.1 correctly, so
   the row had been contradicting itself. **Nothing is withdrawn**: the claim is
   unchanged and stays in A01; only the clause number moved, and the `//! lrm`
   directives moved with it so `--coverage` credits §4.2.1 rather than §4.2.5.
   No fixture's asserted value changed.
2. **§3.4's override sentence is now quoted, not paraphrased.** Fixture 03's
   header had "parameters … can be modified at compile time to have a value
   which is different from the one specified in the declaration assignment"
   inside quotation marks. The LRM reads "parameters can be modified at
   **compilation** time to have **values** which are different from **those**
   specified in the declaration assignment", and the surrounding sentences
   ("Parameters represent constants…", "A parameter can be modified with the
   defparam statement or in the module_instantiation statement") are what make
   it load-bearing here. The full passage is now transcribed verbatim, in the
   fixture and in the clause table. The conclusion is unchanged.
3. **Fixture 92's `//! reject` no longer admits a wrong-reason diagnostic.** It
   was `//! reject index`, a substring that also matches E0311's title "array
   index is not a constant expression" — a diagnostic this very row provokes on
   purpose in fixture 04, and exactly the wrong verdict for `a[1.0/0.0]`, which
   *is* a constant expression and merely has no integer. It is now
   `//! reject E0310`, naming the code `src/ir/lower.zig:4137` already emits for
   a constant subscript outside the declared range. If the project mints a new
   code for "this constant has no integer value", move the directive to that
   code rather than widening it back to a substring.
4. **The "Observed today" block was re-captured by running, not typed.** Two
   lines had been hand-edited (`want=0.523599` on one of 08's two `asin` lines,
   which print the same literal; `got=1e-10` for 07, which prints
   `got=0.0000000001`), and 01/02's lines elided diagnostics. The block, the
   capture method, and the command that produced it are now the same thing. Also
   corrected: the run loop's claim that "08 must exit 1" — `--run` does not
   grade `//! exit`, only `zig build torture` does.

### Disputed, with the reasoning rather than a silent edit

The review's Class D line counts A01 as keeping "2 of 11 already-passing
fixtures" and notes that disclosing this is not a fix. Those two are **06** and
**07**, and neither is weakened or removed, because neither is a no-teeth
fixture — a fixture that passes today is only toothless if it would pass on
*any* implementation, and these fail on named, plausible, non-strawman ones:

- **06** asserts three values, each of which is the answer to a *different*
  wrong out-of-range write rule, all three of which are live design choices
  somebody would actually take: `a[2]==3.0` fails under clamp-to-top **and**
  under modulus wrap (`5 mod 3 == 2`); `a[0]==1.0` fails under clamp-to-bottom;
  `a[1]==2.0` fails under an unchecked flat offset into scalarized storage,
  which is the failure mode VerA's own lowering would have. It is also the
  anti-fix interlock for 05: the cheapest way to make 05 stop panicking is to
  clamp the subscript, and that turns 06 red. Deleting it would leave 05
  fixable by breaking §5.7.
- **07** fails under two named readings: if the §4.2.1.1 real→integer
  conversion of the degree is dropped, `$discontinuity(-1.0)` never becomes the
  §9.17.3 veto and the accepted point is iteration 1; if the unconditional
  `$discontinuity(2.0)` above it is also treated as a veto, the solve runs to
  its iteration limit instead of stopping at 2. Asserting *2* discriminates
  both directions at once. The one thing it genuinely cannot see — the value of
  a non-negative degree — is already listed under "Deliberately NOT covered"
  with the reason (`inst.discontinuity_order` is never printed and never read).

If the standard for this row is "no fixture may pass at HEAD", 06 and 07 fail it
and their content dies with them. The position taken here is that an interlock
against a wrong fix is coverage, and it is recorded rather than quietly kept.

## Blocked on

Nothing. Every fixture compiles-or-fails against today's `zig build` with no new
infrastructure. Fixture 03 needs the `//! param` directive, which
`src/backend/tb.zig:228` already parses.

## Build / run

These live outside `tests/fixtures/`, so `zig build torture` does not see them.

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build                                   # refresh zig-out/bin/vera

# the eight positive fixtures — this is verbatim what produced the block above
for f in tests/pending/A01/0*.va; do
  echo "##### $(basename "$f")"
  out=$(./zig-out/bin/vera --run --display=emit \
    --contract tools/contract.zig \
    -I tests/fixtures \
    --work-dir "/tmp/a01/$(basename "$f")" "$f" 2>&1); rc=$?
  echo "$out" | grep -E '^(error|thread|.*ok=)' | sed 's/^/  /'
  echo "  exit $rc"
done

# the three refusals: each must produce a diagnostic, not exit 134
for f in tests/pending/A01/9*.va; do
  echo "##### $(basename "$f")"
  ./zig-out/bin/vera --emit-zig -I tests/fixtures "$f" >/dev/null
  echo "  exit=$?"
done
```

Every `ok=` column must read `ok=1`, and `90`–`92` must exit non-zero **with a
diagnostic on stderr** (exit 134 is a crash, not a refusal). 08's `//! exit 1`
is *not* graded by `--run` — only `zig build torture` reads that directive — so
under the loop above 08 exits 0 both before and after the fix, and its two
`ok=` lines are what has to flip.

To wire them into the green gate once A01 is implemented, move them into
`tests/fixtures/` by clause — `01`, `02`, `05`, `06` to `ch05_analog_behavior/`;
`03`, `92` to `ch03_data_types/`; `04` to `ch04_expressions/`; `08` to
`ch04_expressions/`; `07`, `90`, `91` to `ch09_system_tasks/` — add their
one-liners to each directory's `COVERAGE.md`, and they are picked up by:

```sh
zig build torture -- --strict
```
