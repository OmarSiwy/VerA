# A05 — Table-model lookup (`$table_model`): pending fixtures

Thirteen fixtures (11 positive, 2 runtime-fatal) for the parts of §9.21 that
VerA does not implement. Every `want` is hand-derived in the fixture header from
the LRM plus closed-form arithmetic; none is a recorded output — and where the
clause states a rule as an identity with no value to write down, no digits are
written at all (04 is the whole of that case; see "Corrected after review").

Fixture 07 passes 5 of 5 at HEAD and the two benign-duplicate assertions of 13
pass at HEAD. They are marked as such in the table below and apply no pressure
on the gap; they must not be counted as coverage of it.

## Ground truth as of `ddt-capform` (45b505d)

Read, not taken from the plan:

* `src/backend/table_kernels.zig` (192 lines) implements exactly two schemes —
  linear (`1`) and closest-point (`D`) — plus `C`/`L` extrapolation. Its own
  header says so: "Unsupported spline and fatal-extrapolation modes reject in
  IR."
* `src/ir/lower.zig:8683` `parseTableCtl` rejects `2`, `3` and `I` at `:8721`
  with E0815 ("VerA implements Table 9-30's `1` and `D`"), and rejects `E` at
  `:8733` with E0815 ("`E` is not an extrapolation method VerA implements").
  Both are COMPILE-time refusals of legal models. (The plan and the review
  MANIFEST both give `:8660` for this; that line is inside the file-column
  check, and the two rejections are at `:8721`/`:8733` at `45b505d`. Opened and
  counted, not copied.)
* `src/ir/lower.zig:8625` reads a file data source during lowering
  (`readTableFile`), so a file named by a site that never executes is still a
  compile error ("cannot read the `$table_model` data source"). (`:8624` in the
  MANIFEST is the doc comment above the function.)
* `parseTableCtl` computes the dependent column as `nd + sel - 1` (`:8748`), i.e. from the
  number of DIMENSIONS. Table 9-32 computes it from the number of control
  SUB-STRINGS ("I,1CC,1CC;3" → column 6; "3,D,I,1;3" → column 7), which differs
  by one per ignored column. Unreachable today because `I` is rejected; it
  becomes wrong the moment `I` is accepted.
* No duplicate-point validation exists anywhere (no `error is generated` path
  for §9.21's conflicting-dependent rule).
* Branch `w2/tables` is empty — same SHA as `ddt-capform`, clean worktree. The
  existing `$table_model` fixtures in `tests/fixtures/ch09_system_tasks/`
  (37, 131, 155, 186, 187*) are from the earlier `ams_tables` work and cover
  linear/discrete lookup and the first-call array snapshot only.

Failure mode of each file re-established 2026-09-19 by running
`vera --check --contract tools/contract.zig -I tests/fixtures -I tests/pending/A05 <file>`
over all thirteen: 01–06 and 09–12 are refused at compile time by E0815 for the
feature each one is about (04 for `2`, 10 and 12 for `E`, 06 for `I`, the rest
for `3`); 08 is refused because the unexecuted site's file is read during
lowering; 07 and 13 compile, and their testbenches build and run — 07 green 5/5,
13 green on its two benign-duplicate lines and exiting 0 where it requires 1.

## LRM clauses covered

| Clause | What is pinned here |
| --- | --- |
| §9.21 | recursive per-dimension scheme; minimum data requirement; duplicate-point rule; lookup on an unknown |
| §9.21.1 | file layout, multiple dependents, comments/blank lines, "state of the data source is captured on the first call" |
| §9.21.2 | Table 9-30 `I`/`2`/`3`; Table 9-31 `C`/`L`/`E`; one-vs-two extrapolation characters, low end first |
| §9.21.3 | Table 9-32 rows: `"C,,3"` ≡ `"1CC,1LL,3LL"`, `"I,…;3"` column arithmetic, default dependent selector |
| §9.21.4 | spline end conditions from the extrapolation character (L → natural, C → zero end derivative); quadratic splines; closest-point tie "snaps away from zero" |
| §4.5.6 | `ddx` through a lookup — the derivative the Jacobian gets |

## Fixtures

| File | Pins | Expected value and derivation |
| --- | --- | --- |
| `01_cubic_spline_natural_ends.va` | `3LL` = natural cubic (§9.21.4 "linear extrapolation … leads to a natural spline") | x={0,1,2}, f={0,1,0}; M0=M2=0 and 4·M1=6[(0−1)−(1−0)] ⇒ M1=−3, so S(x)=−0.5x³+1.5x on [0,1]. S(0.25)=0.3671875, S(0.5)=0.6875, S(1)=1, S(1.5)=0.6875 (mirror). Linear extrapolation uses the SPLINE end slope S′(0)=1.5, S′(2)=−1.5 ⇒ f(−1)=f(3)=−1.5 (a secant off the last sample pair would give ∓1). |
| `02_cubic_spline_constant_ends.va` | `3CC` = clamped cubic, S′=0 at both ends ("If constant extrapolation is specified the end point derivative is set to zero") | Same samples. Clamped system gives M0=M2=6, M1=−6, so S(x)=(1−x)³−x³−(1−x)+2x on [0,1]. S(0.25)=0.15625, S(0.5)=0.5, S(0.75)=0.84375 (linear would give 0.25/0.5/0.75). Constant extrapolation "returns the table endpoint value" ⇒ f(−1)=f(3)=0. |
| `03_cubic_spline_mixed_ends.va` | the two extrapolation characters set the two end conditions INDEPENDENTLY | Two samples x={0,1}, f={0,1}; one cubic, four constraints, solved in four lines. `3CL` ⇒ S=1.5x²−0.5x³: S(0.25)=0.0859375, S(0.5)=0.3125, f(1.5)=1+1.5·0.5=1.75, f(−1)=0. `3LC` ⇒ S=1.5x−0.5x³: S(0.5)=0.6875, f(−0.5)=−0.75, f(2)=1. Same samples, same abscissa, 0.3125 vs 0.6875. |
| `04_quadratic_spline.va` | Table 9-30 `2`; only ONE end condition is available to a quadratic spline (3k coefficients vs 3k−1 constraints) — **which end gets it is not in the clause, so this file writes no interior digits** | x={0,1,2}, f={0,1,4}, `"2CL"`. Asserted: the three samples are reproduced exactly (0, 1, 4); the slope is continuous across the interior knot (`CHECKEQ` of the two one-sided quotients at h=1e−5, band 1e−3 — linear interpolation leaves a gap of 2 there); the third difference inside [1,2] at spacing 0.2 is 0 to 1e−9 (a cubic spline with the same end characters solves to M={12/7, 18/7, 0} and reads h³S‴=−0.0206; closest-point reads −6 — both measured, see below); `C` low end returns the endpoint value 0.0 at −1 and at −1000; the `L` high-end extrapolant's second difference is 0 (a quadratic continuation reads 2) and its slope equals the spline's own end slope (`CHECKEQ`, not digits: 4 under one reading, 3 under the other). Two-sample x={0,2}, f={0,4}: legal under `2` (§9.21's minimum data requirement) and exact at its own samples. |
| `05_control_default_filling.va` | Table 9-32's last row verbatim: `"C,,3"` ≡ `"1CC,1LL,3LL"` | 2×2×2 corner set of f(z,y,x)=4z+2y+x (8 rows = §9.21's 2^N minimum). A 2-point natural cubic has M0=M1=0, i.e. it degenerates to the straight line, so the lookup is trilinear and exact on an affine f: f(0.5,0.5,0.5)=3.5. Outer `C` clamps: f(2,·)=5.5, f(−1,·)=1.5 (linear would give 9.5 and −2.5). Empty middle sub-string stays `1LL`: f(0.5,2,0.5)=6.5 (constant would give 4.5). |
| `06_ignored_column_and_selector.va` | Table 9-30 `I` and the column arithmetic it forces | Dependent column = (leading columns consumed)+selector, where the leading count is the number of sub-strings **when an `interp_control` is written** and is N (the number of `table_inputs`) when it is empty — Table 9-32's first row is the second arm, and it is what 07's `";2"` uses. Read off Table 9-32's own "at least 6 columns"/"column 7" annotations. 4 columns junk\|x\|f1\|f2: `"I,1;1"`→col 3→15, `"I,1;2"`→col 4→150, `"I,1"`→default selector 1→15. Ignored column in the middle (`"1,I,1;1"`, shape of `"3,D,I,1;3"`) on f=2y+x ⇒ f(0.5,0.5)=1.5. The junk column is unsorted on purpose: a tool that treated it as an independent re-sorts the rows. |
| `07_file_multiple_dependents.va` | §9.21.1 multiple dependents in a FILE + selector; **passes 5/5 at HEAD** — an implemented-without-evidence behaviour, no pressure on the gap | `a05_two_dependents.tbl`, columns y x f1=x+y f2=2x−y, isolines y=0,1, x=0,1,2. Both dependents affine ⇒ linear scheme exact: at (0.5,1.5) f1=2.0, f2=2.5. Control omitted → column N+1 (2.0); `";2"` with a null interpolation control → 2.5; sample point (1,2) → 3.0. File also carries comments, indentation and blank lines (§9.21.1 text rules). |
| `08_file_loaded_on_first_executed_call.va` | §9.21.1 "The state of the data source is captured on the first call" applies to the FILE form too | Guarded site names `a05_never_read.tbl`, which does not exist; its guard `V(p,n)>100` is false at the biased point, so `dead` keeps −1.0 and nothing is read. The taken site loads `a05_two_dependents.tbl` at its first executed call: f1(0.5,1.5)=2.0, and a second evaluation of the same site is still 2.0. A **second** never-executed site names an array holding conflicting duplicates (x={0,1,1}, f={0,10,99}) — the error 13 requires at the call — and must not be diagnosed either: no first call, no capture, no data set, no error. Deleting the guards makes that check read `got=5 want=−1 ok=0` at HEAD, so "strip the never-read site and 08 passes" is no longer true. |
| `09_mixed_interpolation_dimensions.va` | §9.21's "schemes … may be specified on a per dimension basis" (Table 9-32's `"D,1,3"` row) | f(y,x)=g(y)+x with g={0,1,0} on y={0,1,2}, x={0,1}. `"3LL,1LL"`: isolines at x=0.5 give {0.5,1.5,0.5}; a spline is linear in its data, so the natural cubic is 01's shifted by 0.5 ⇒ 1.1875 at y=0.5 and 0.8671875 at y=0.25. `"1LL,1LL"` at the same point = 1.0. `"3LL,D"` at x=0.4 snaps to the x=0 samples ⇒ 0.6875. `"D,1LL"` at y=1.4 snaps to the y=1 isoline ⇒ 1.25. |
| `10_error_extrapolation_inside_is_legal.va` | Table 9-31 `E` is a RUNTIME condition on the point, not a compile-time refusal of the call | x={1,3}, f={2,6}: `"1EE"` at x=2 → 4.0; at the endpoints x=1 → 2.0 and x=3 → 6.0 (an endpoint bounds the interpolation region, it is not "beyond" it). 2-D f=2y+x: `"1LL,1EE"` at (2,0.5) → 4.5 (only the non-`E` dimension extrapolates); `"1EL,1LL"` at (2,0.5) → 4.5 (`E` first = low end only). |
| `11_spline_derivative_reaches_the_solver.va` | the derivative the lookup hands the Jacobian, via §4.5.6 `ddx` | bias V(p,n)=0.5. `"3LL"`: value 0.6875, S′(0.5)=−1.5(0.25)+1.5=1.125; wrt V(n) the branch flips sign ⇒ −1.125. `"3CC"`: value 0.5 — the SAME as linear — but S′(0.5)=3−0.75−0.75=1.5 vs linear 1.0, so value-only checks cannot separate them. `"D"`: tie at 0.5 snaps away from zero ⇒ 1.0, and a piecewise-constant lookup has slope exactly 0. |
| `12_error_extrapolation_is_fatal.va` (negative) | "Error extrapolation results in a fatal error being raised" | `//! sweep V(p)=2.0,5.0`, `//! exit 1`. Point 0 is inside [1,3] and asserts 4.0; point 1 is beyond the `E` high end and must terminate the run. Without termination point 1 prints `got=10 want=4 ok=0`, so the fixture fails in both directions, not only on the exit status. |
| `13_duplicate_points.va` (negative, with two positive assertions) | §9.21's two duplicate rules — the benign one as a value, the conflicting one **without any claim about when it is diagnosed** | Benign: x={0,1,1,2}, f={0,10,10,20}; the identical repeat "shall be ignored", leaving three samples ⇒ f(1.5)=15, f(1.0)=10 (**these two pass today**). Conflicting: f={0,10,**94+V(p,n)**,20} at the same x. §9.21 says only "an error is generated" and fixes no diagnosis point, so the dependent is made a function of the solution: an implementation cannot fold it at elaboration, and it may not refuse on the independents alone because on the independents alone the benign table is identical. Every conformant tool therefore errors at the capture (§9.21.1's first call), which the `V(p,n)>3.0` guard puts at the second sweep point ⇒ `//! exit 1`. VerA has no duplicate validation at all today, so the run exits 0 with four `ok=1` lines above it. |

Data file: `a05_two_dependents.tbl` (used by 07 and 08) — it must travel with the
`.va` files, the same way `ch09_table_model_2d.tbl` sits beside 37.

## Deliberately NOT covered

* **Which end a QUADRATIC spline's single free condition belongs to, and
  therefore every interior VALUE a quadratic spline produces.** §9.21.4 only
  says "it is not always possible" to honour both end conditions; it never says
  which end keeps its jump. Withdrawn from fixture 04, which used to assert the
  low-end reading's digits (S(0.5)=0.25, S(1.5)=2.25, f(3)=8, and 1.0 for the
  two-sample form). The claim stays with A05 — no other row owns §9.21.4 — and
  comes back the day either (a) the clause acquires an erratum naming the end,
  or (b) §9.21.2's "the first character specifies the extrapolation method used
  for the end with the lower coordinate value" is shown to bear on the SPLINE
  condition and not only on the extrapolant, which is the inference the old
  header made and did not earn. Until then 04 pins the properties both readings
  share; the full arithmetic for both readings is in its header, so restoring
  the digits is a two-line edit once the question is settled.
* **Quadratic/cubic in more than one dimension at once** (e.g. `"3,2"`). 09
  mixes one spline dimension with one non-spline dimension; a spline×spline
  product surface would need a second full hand solve per isoline for no new
  rule.
* **Runtime file-error paths other than "not read at all"**: a malformed row
  count, a non-numeric token or a file with fewer columns than the control
  string needs, once the read moves to runtime, should be runtime diagnostics.
  Those are compile-time E0815 messages today and would each need a second
  fatal-exit fixture; deferred until deferred loading exists and has an error
  channel to test.
* **Multiple INSTANCES of the same module**, and **timestep rejection/retry**
  around a capture. Both need a host netlist (`//! spice`, or an ARPice
  fixture), not a single-device testbench; A05's snapshot-per-instance
  requirement is stated in the plan but is a host-integration test.
* **Isoline ordering with randomly shuffled rows** — `zTabSort` already does
  this and 186 exercises unsorted 1-D data; re-testing it adds no pressure on
  the gap.
* **Warning on a benign duplicate.** §9.21 says the tool "may generate a
  warning"; 13 asserts only the required behaviour (the duplicate is ignored).
* **A conflicting duplicate diagnosed at ELABORATION.** §9.21 says only "an
  error is generated" and fixes no diagnosis point, so a compile-time refusal of
  a constant table is as conformant as a runtime fatal. 13 no longer requires
  either: its conflicting dependent is a function of the solution, which removes
  the choice instead of legislating it. The compile-time channel comes back only
  if the runner grows a form that accepts "rejected at compile time OR exit 1",
  at which point a constant-table variant of 13 can assert the disjunction.

## Running these

Per file, today. `//! bias`, `//! sweep`, `//! param`, `//! time` and the rest
are parsed by `src/backend/tb.zig:216-294` (`bias` at `:228`, `sweep` at `:230`)
and honoured by the generated
testbench, so 13's two sweep points and 08's and 11's biases really do appear in
the transcript below. Only `//! exit` is unchecked outside `zig build torture`
(`tests/torture.zig:361`), so a fatal-status fixture run by hand shows the
assertions and not the verdict.

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build install

# compile-check (both flags: check.vh lives in tests/fixtures)
./zig-out/bin/vera --check --contract tools/contract.zig \
    -I tests/fixtures -I tests/pending/A05 \
    tests/pending/A05/01_cubic_spline_natural_ends.va

# build and run the self-checking testbench (path on stdout, diagnostics on stderr)
P=$(./zig-out/bin/vera --emit-exe --contract tools/contract.zig \
      -I tests/fixtures -I tests/pending/A05 \
      tests/pending/A05/13_duplicate_points.va 2>/dev/null)
"./$P"
```

Captured 2026-09-19 at `45b505d` + this directory, not typed:

```
$ ./zig-out/bin/vera --check ... 01_cubic_spline_natural_ends.va
error[E0815]: $table_model data source or control string: VerA implements Table 9-30's `1` and `D`; `3` is not implemented
  --> tests/pending/A05/01_cubic_spline_natural_ends.va:65:5
   |
65 |     `CHECK("natural cubic at x=0.25: -0.5(0.25)^3 + 1.5(0.25)",
   |     ^^^^^^^^^^^^
   |
   = note: LRM 9.21
   = help: run `vera --explain E0815` for a detailed explanation

$ "./$P"     # 13_duplicate_points
=== 13_duplicate_points ===
--- point 0 ---
  x[p] = 1.000000e0
  x[n] = 0.000000e0
an identical duplicate point is ignored, not treated as a second sample got=15 want=15 ok=1
the surviving sample is returned at its own abscissa got=10 want=10 ok=1
...
--- point 1 ---
  x[p] = 5.000000e0
  x[n] = 0.000000e0
an identical duplicate point is ignored, not treated as a second sample got=15 want=15 ok=1
the surviving sample is returned at its own abscissa got=10 want=10 ok=1
...
$ echo $?
0            # the fixture's failure: `//! exit 1` is not met, no error was generated
```

Wired into the gate — `build.zig:428` pins the suite root to `tests/fixtures`,
and `` `include "check.vh" `` resolves relative to it, so wiring means moving
the files in:

```sh
cp tests/pending/A05/*.va tests/pending/A05/a05_two_dependents.tbl \
   tests/fixtures/ch09_system_tasks/     # renumber to the suite's NNN_ prefixes
zig build torture -- ch09_system_tasks --strict
```

Do that only when the feature lands: these fixtures are expected to fail today
and must not be added to `tests/fixtures/` before then, or the 1323/1323 gate
goes red.

## Corrected after review

The adversarial review named A05 in five places — §5.2 (the `ddx` miscite),
§5.3 twice (04's wants; 06/07's contradiction, with 13's deferral rule in the
same bullet), §5.4 (08's lack of teeth, with 07's already-green status) and
§5.6 (the `//! bias`/`//! sweep` claim in this document). All five are actioned
below, item 8 is a defect found while re-checking, and items 1-8 were each
re-run or re-opened rather than taken on trust.

1. **Class B, miscitation — `11_spline_derivative_reaches_the_solver.va` cited
   §4.5.14 for `ddx`.** §4.5.14 is *Constant versus dynamic arguments* and does
   not mention `ddx`. Corrected to **§4.5.6** in the `//! lrm` directive, in the
   file header and in the clause table above. §4.5.6 is also better evidence
   than the old cite could have been: it ends with the LRM's own
   `one = ddx(vin,V(pin)); minusone = ddx(vin,V(nin))` example and the sentence
   "The names of the variables indicate the values of the partial derivatives:
   +1, -1, or 0", which is the precedent the fixture's −1.125 want rests on.
   That quotation is now in the header.

2. **Class C, disputed values — `04_quadratic_spline.va`.** The review is right
   and the arithmetic reproduces: on x={0,1,2}, f={0,1,4} with `"2CL"` the low-
   end reading gives S(0.5)=0.25, S(1.5)=2.25, S′(2)=4, f(3)=8, while the
   high-end reading (`L` ⇒ S″=0 on the last interval) gives S=1+3u on [1,2] and
   S=−x+2x² on [0,1], hence S(0.5)=0.0, S(1.5)=2.5, S′(2)=3, f(3)=7; the
   two-sample form gives 1.0 and 2.0 respectively. §9.21.4 does not choose, and
   the old header's appeal to §9.21.2's "first character … lower coordinate
   value" is about the EXTRAPOLANT, not about the spline's free condition. Five
   of the six wants are withdrawn (see "Deliberately NOT covered") and the file
   now asserts only what both readings share, using `CHECKEQ` for the two
   quantities the clause states as identities with no value to write down (slope
   continuity at the interior knot; extrapolation slope = spline end slope).
   It still has teeth, measured rather than argued: run against `"1CL"` the
   knot-continuity check reads `got=0.9999999999954489 want=3.000000000019653
   ok=0`, and against `"DCL"` the third-difference check reads `got=-6 want=0
   ok=0`. A cubic substituted for the `2` would read −0.0206 there.

3. **Class C, contradiction — 06 and 07 encoded two incompatible column rules.**
   06's "dependent column = number of sub-strings + selector" is right for
   Table 9-32's `"I,1CC,1CC;3"` (column 6) and `"3,D,I,1;3"` (column 7) but is
   not the whole rule: Syntax 9-16 makes `interp_control` optional, and when it
   is absent Table 9-32's first row governs instead ("Dimensionality of the data
   is assumed to be N. Column N+1 is taken as the dependent"), with N read off
   the number of `table_inputs`. That is the arm 07's `";2"` uses, and it is why
   07's 2.5 is right and HEAD already answers it. Both headers now state the
   rule with its two arms and cross-reference each other. No want changed in
   either file.

4. **Class C, over-specification — 13 required the conflicting-duplicate error
   to be DEFERRED.** §9.21 says only "an error is generated". With the old
   four-literal table a compile-time refusal was conformant and failed the
   fixture — the worst class of defect, one an implementer "fixes" by making the
   compiler worse. The conflicting dependent is now `94.0 + V(p,n)`, so no
   implementation can know at elaboration whether the two points at x=1 conflict
   and none may refuse on the independents alone (the benign table has the same
   independents and §9.21 requires those duplicates to be IGNORED). Every
   conformant tool lands at the same place — the capture, §9.21.1's first call —
   and `//! exit 1` is the only expressible outcome rather than one of two. The
   timing claim is withdrawn in "Deliberately NOT covered" with the condition
   that would restore it.

5. **Class D, no teeth — 08's only new content was "it compiles".** Also right:
   deleting the never-executed site left three checks that ran green at HEAD. A
   second never-executed site is added, failing for a different reason (an array
   with conflicting duplicates, the error 13 requires at the call), so the file
   now pins the rule rather than one incident of it, and the stripped variant no
   longer passes — measured: `an unexecuted site does not validate its data
   either got=5 want=-1 ok=0`. What 08 cannot have is a positive runtime
   witness, because by construction an unexecuted site produces no value; that
   limit is stated in the header instead of being hidden. The array-snapshot
   witness that looked like the obvious fix was rejected on purpose: VerA
   captures per CALL SITE, and `tests/fixtures/ch09_system_tasks/
   187_table_snapshot_function.va` already asserts that reading (a site whose
   first call is skipped captures the MUTATED array, `skipped == 101`), so a
   second-site re-read check would have contradicted a green fixture and failed a
   conforming implementation. The measured HEAD answer for such a check is 1500,
   neither of the two values the naive derivation predicts.

6. **Class D, already-green disclosure.** 07 passes 5/5 at HEAD and 13's two
   benign-duplicate assertions pass at HEAD. Both facts were in the table
   before; they are now also in this document's opening paragraph, so the row's
   thirteen files are not read as thirteen failing ones.

7. **Reproduction defect — this document said the CLI ignores `//! bias` and
   `//! sweep`.** It does not. `src/backend/tb.zig:228` and `:230` parse `bias`,
   `sweep`, `wave` and `psweep`, and the emitted testbench honours them; 13's
   transcript above shows two sweep points. Only `//! exit` is unchecked outside
   `zig build torture` (`tests/torture.zig:361`, the sole consumer of
   `d.expected_exit`). "Running these" is rewritten and its transcript was
   captured by running, not typed.

8. **Source line numbers in "Ground truth" were wrong and are now opened.**
   This document (and the review MANIFEST it inherited them from) cited
   `src/ir/lower.zig:8660` for `parseTableCtl`'s E0815 rejections and `:8624`
   for `readTableFile`. At `45b505d` the function starts at `:8683`, the
   interpolation-character rejection is at `:8721`, the extrapolation-character
   rejection at `:8733`, the dependent-column arithmetic at `:8748`, and
   `readTableFile` at `:8625`. Corrected. `src/backend/tb.zig` (`bias` `:228`,
   `sweep` `:230`), `tests/torture.zig:361` (`d.expected_exit`, its sole
   consumer), `build.zig:428` (`fixture_root`) and
   `src/backend/table_kernels.zig` (192 lines) were opened and are right as
   written.

Re-verification pass (all of the below re-run at `45b505d` + this directory,
not carried over): the thirteen compile-checks reproduce exactly the split in
"Ground truth" (11 refused, 07 and 13 compile); 07 prints 5 `ok=1`; 13 prints
two `ok=1` at each of its two sweep points and exits 0. The three *measured*
claims this document makes about counterfactual variants were re-measured and
are byte-exact: 04 with `"2CL"` → `"1CL"` gives `the slope is continuous across
the interior knot got=0.9999999999954489 want=3.000000000019653 ok=0`; with
`"DCL"` gives `the third difference … got=-6 want=0 ok=0`; 08 with its two
guards removed gives `an unexecuted site does not validate its data either
got=5 want=-1 ok=0`. §4.5.6 was opened (it is *Derivative operator*, it carries
the `one`/`minusone`/`zero` `vccs` example verbatim, and §4.5.14 is *Constant
versus dynamic arguments* and contains no `ddx`), as were §9.21's
duplicate-point paragraph, §9.21.1's capture sentence, Table 9-31's `C`/`L`/`E`
prose, §9.21.2's two-character low-then-high rule, all eight rows of
Table 9-32, and §9.21.4's "both end points" and "not always possible"
sentences. Every quotation in every header in this directory matches the HTML.

Not changed, and why: the review's own numbers for 04 were re-derived here
rather than copied, and they hold — including the ones it only asserted
(S(0.5)=0.0 and f(3)=7 under the high-end branch). The cubic counter-value the
04 header quotes was likewise re-solved: with `3CL` on x={0,1,2}, f={0,1,4} the
moment system (M0/3 + M1/6 = 1, M0/6 + 2M1/3 + M2/6 = 2, M2 = 0) gives
M0 = 12/7, M1 = 18/7, so S‴ = (M2−M1)/h = −18/7 on [1,2] and the third
difference at spacing 0.2 is 0.008·(−18/7) = −0.0206, four orders above 04's
1e−9 band. No disagreement with the reviewer remains open on this row.
