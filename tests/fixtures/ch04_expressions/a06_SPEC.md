# A06 — small-signal and noise behavior (everything except the tabulated-PSD host math)

Thirteen fixtures: eleven positive, two refusals. They cover AC stimulus
behavior, white/flicker PSD **values**, source naming, correlation amplitude,
analysis enablement, the two tabulated-input spellings VerA refuses, and the
derivative the small-signal analysis is linearized about.

`tests/pending/A06-noisetables/` owns the *interpolation and clamping* of
`noise_table`/`noise_table_log` in the ARPice host. Nothing here repeats it:
this row stops at the compiler boundary — what the device exports — plus the
two input spellings (file, array parameter) that never reach that boundary at
all today.

## Ground truth, measured, not read off COVERAGE.md

Every claim below was reproduced against `zig-out/bin/vera` at `45b505d`, and
re-run after the corrections in the last section of this file. Transcript lines
quoted anywhere here are pasted from `--run`/`--emit-exe` output, not typed.
Fixtures whose `//! noise`/`//! acstim` lines block the testbench build were
re-run with those lines stripped (`grep -v '^//! noise'`) so their `CHECK`s
could be observed; that is stated wherever such a number appears.

| clause | what the source actually does | evidence |
| --- | --- | --- |
| §4.6.3 activation, defaults, mag, phase 0/π | **works** | `a06_ac_stim_ac_analysis.va` and `a06_ac_stim_noise_analysis.va` run green today; no fixture in `tests/fixtures/` had ever run `ac_stim` in a small-signal analysis — `ch04_expressions/37_ac_stim.va` only pins the dc zero |
| §4.6.3 mag/phase as `analog_expression` | **works** (fixed 2026-09-20). Was `E0515`, "analog operator control argument is not a constant or parameter expression" — but `ac_stim` is not an analog operator and is absent from Table 4-20. The residual reads both through `ctrlEval` and `acStim` gained the `[n_u]f64` state vector `noisePsd` already took, so a solve-computed magnitude reaches the phasor export too. A device with one is no longer `lane_clean`: a control argument collapses to one scalar, which is the batch host's business to know | `a06_ac_stim_dynamic_magnitude.va` |
| §4.6.3 phase ≠ {0, π} | **dropped.** `codegen.zig:5430` lowers `ac_stim` to `mag * @cos(phase)` and its own comment says the quadrature component is lost; the 90° source's residual row measures **1.923132e-17 V** instead of a unit imaginary source. No `ac_gens` export exists | `a06_ac_stim_quadrature.va` |
| §4.6.4.1/.2 PSD values | **exported and correct** (`noisePsd` → `{.white = m.f1.v}`, `{.flicker = m.f2.v, .ef = 1.25}`), and **nothing asserts them**: the `//! noise` directive carries kind/branch/source id only | `a06_psd_white_flicker_export.va`, `a06_psd_bias_dependent.va` |
| §4.6.4.1 `name` argument | **parsed and discarded.** `Lower.NoiseSrc` has kind/id/pwr/exp/table; `contract.NoiseGen` has row/col/kind/source/table. No name field anywhere, so no contribution summary is possible | `a06_noise_source_name.va` |
| §4.6.4.6 correlation amplitude | **identity yes, amplitude no.** `V(a,b) <+ 2*n; V(c,d) <+ 3*n;` exports two rows sharing `#0` and *both* read `white = 1e-18`; `contract.zig`'s own comment: "Still not expressible: the per-use scaling coefficient" | `a06_noise_correlated_scale.va` |
| §4.6.4.3 file input | **works** (fixed 2026-09-20). The name "shall be constant", so `Lower.readNoiseTableFile` reads the pairs at compile time — sharing §9.21.1's `readTableFile`, whose text format is the same rule — and the comptime `noise_tables` export is indistinguishable from the vector form's | `a06_noise_table_file_input.va` |
| §4.6.4.3 array-parameter input | **works** (fixed 2026-09-20). `noise_tables` keeps the parameter's DECLARED DEFAULTS, which is all a comptime array can hold, and a new `noiseTablePoints(model)` carries the card's own knots (flat, `noise_tables` order, re-sorted at run time because a card may reorder the pairs). `contract.validateHost` makes a host that links such a device declare `noise_table_points = true`, so reading the defaults and stopping is a build error rather than a silently wrong spectrum. **The override itself is still untested**: `//! param` binds scalars only | `a06_noise_table_array_parameter.va` |
| §4.6.4.2 one-argument `flicker_noise` | **accepted**, exponent silently defaulted to 1, against Syntax 4-4 | `a06_flicker_noise_missing_exponent_rejected.va` |
| §4.6.3 non-literal analysis name | **accepted, then the generated device does not compile** ("unused function parameter") — a model error reported as an engine bug | `a06_ac_stim_name_not_literal_rejected.va` |
| derivative transfer | **exact.** `ddx` reads the AD dual (`tb.zig:879 ddxAt → a.d[i]`); the junction conductance matches `(id + is)/$vt` as an identity, measured `4.6458183712465816e-3 S` on both sides, and `ac_stim` adds nothing to it at any phase | `a06_small_signal_linearization.va`, `a06_ac_stim_quadrature.va` |
| §9.15 `$vt` | **VerA's own constant, not the LRM's.** `$vt` is hard-coded to CODATA2018 k/q at `codegen.zig:5519` (0.025851999786435535 V at 300 K) while Annex D.2's default fall-through gives `` `P_K/`P_Q `` = NIST1998 (0.025852026903638282 V). §9.15 states the identity kT/q and **supplies no number**, so neither is wrong — but no fixture may write either one down | `a06_small_signal_linearization.va`, `a06_psd_bias_dependent.va` |

One correction to the existing suite that this row found:
`tests/fixtures/ch04_expressions/lrm_4_6_4_3.va` is green and **vacuous**. It
compiles the §4.6.4.3 file form, binds it to a variable, checks the §4.6 zero
and carries no `//! noise` line — and the device it produces has **no
`noise_gens` declaration at all** (`vera --emit-zig | grep noise` → only the
`AnalysisKind` enum). The generator disappears without a diagnostic, which is
strictly worse than the E0519 the inline spelling of the same call receives.
`a06_noise_table_file_input.va` is the fixture that fails on it.

## LRM clauses covered

Read from `docs/ch4-expressions.html` and `docs/annex-a-syntax.html`.

* **§4.6** — "When not active, the small-signal source functions return zero (0)."
* **§4.6.1** Table 4-21 (analysis names) and Table 4-22 (which name is true in
  which pass), specifically the AC and NOISE columns, which no fixture reached.
* **§4.6.3** AC stimulus: defaults `("ac", 1, 0)`, name matching, "phase is
  given in radians", "models a source with magnitude mag and phase phase".
* **§4.6.4** "The noise functions are only active in small-signal noise analyses
  and return zero (0) otherwise", Syntax 4-4.
* **§4.6.4.1** `white_noise(pwr[, name])`, and the `name` sentence: "The
  contributions of noise sources with the same name from the same instance of a
  module are combined in the noise contribution summary."
* **§4.6.4.2** `flicker_noise(pwr, exp[, name])`, "power of pwr at 1Hz which
  varies in proportion to 1/f exp".
* **§4.6.4.3** the two non-pattern input spellings: "The vector can either be
  specified as an array parameter or an array assignment pattern"; "When the
  input is a file name … comments may be inserted before or after any frequency
  / power pair."
* **§4.6.4.5** the diode example — bias-dependent shot and flicker powers.
* **§4.6.4.6** Example 1, including the coefficients `c1`, `c2`.
* **§4.5.6** *Derivative operator* — `ddx`, the assertable spelling of the
  operating-point derivative §4.6.3 says the analysis is linearized about:
  "returns the partial derivative of its first argument with respect to the
  unknown indicated by the second argument, holding all other unknowns fixed and
  evaluated at the current operating point", and "If the expression does not
  depend explicitly on the unknown, then ddx() returns zero (0)." Its first
  example is this row's diode verbatim and its `vccs` example fixes the ±1/0
  values fixtures 4, 8, 9 and 10 assert. (An earlier draft of this row cited
  **§4.5.10** throughout; §4.5.10 is *last_crossing function* and licenses none
  of it.)
* **§9.15** *Analog Kernel Parameter System Functions* — `$vt` "returns the
  thermal voltage (kT/q) at the given temperature", with **no number**. (An
  earlier draft cited §9.10, *Simulator time system functions*.)
* **A.8.2** `analog_small_signal_function_call` and `noise_table_input_arg`.

## One line per fixture

Positive unless marked.

1. **`a06_ac_stim_ac_analysis.va`** — §4.6.3/§4.6.4/Table 4-22 in `//! analysis ac`.
   `ac_stim()` = `ac_stim("ac")` = **1.0** (clause's defaults: mag 1, phase 0, and
   e^(j0) = 1 is real); `ac_stim("ac",2.5)` = **2.5**; ``ac_stim("ac",2.5,`M_PI)`` =
   **−2.5** (2.5·e^(jπ), and cos(`M_PI`) is −1 to the last bit in f64);
   `ac_stim("xf",2.5)` = **0.0**; all four noise functions = **0.0** (an ac
   analysis is not a noise analysis); `analysis("ac")` = 1 and
   `analysis("static"|"dc"|"noise"|"tran")` = 0. *Runs green today* — it is the
   evidence the row had none of.
2. **`a06_ac_stim_noise_analysis.va`** — §4.6.3 name matching where it bites, in
   `//! analysis noise`. `ac_stim()` and `ac_stim("ac",2.5)` = **0.0** (a noise
   analysis IS small-signal, so only the name comparison keeps them off — fixture
   37 cannot make this claim because it runs in dc); `ac_stim("noise",2.5)` =
   **2.5** and at phase π **−2.5** (Table 4-21 names this analysis "noise");
   Table 4-22's NOISE column. *Green today.*
3. **`a06_ac_stim_dynamic_magnitude.va`** — §4.6.3 + A.8.2: both numeric
   arguments are `analog_expression` and `ac_stim` is absent from Table 4-20.
   With V(ctrl) = 2.0 V: `ac_stim("ac",V(ctrl))` = **2.0**,
   `ac_stim("ac",0.5*V(ctrl))` = **1.0**, ``ac_stim("ac",V(ctrl),`M_PI)`` =
   **−2.0** (magnitude and phase compose). *Passes since 2026-09-20.*
4. **`a06_ac_stim_quadrature.va`** — §4.6.3 phase. The (mag, phase) claim is the
   two `//! acstim` lines and **nothing else**: 2.0 ∠ π/3 →
   **(1.0, 1.7320508075688772)** = (2cos 60°, 2sin 60°); 1.0 ∠ π/2 →
   **(0.0, 1.0)**. The second is the sharp case — its real part is zero, so a
   real-part-only transfer deletes the source outright, and the measured
   residual row is 1.923132e-17 V. No `CHECK` can hold a phasor and none tries:
   the only real number one could name is `mag*cos(phase)`, which is the
   lowering under test. The four `CHECK`s present are **§4.5.6's**, asserting
   that a stimulus at π/3 and at π/2 contributes nothing to the linearization:
   `ddx(s,V(·))` = 0, and `ddx(V(p,n)/R + s, V(p))` = 1/R = **1e-3 S** — a
   non-zero want a wrong lowering perturbs. *Fails: `//!` directive:
   UnknownDirective; no `ac_gens` export.*
5. **`a06_small_signal_linearization.va`** — §4.6.3's "linearized about its
   operating point", via **§4.5.6** (whose first example is this fixture's diode
   verbatim). At 300 K and 0.6 V with is = 1e-14: `$vt` is asserted as §9.15's
   **identity** ``$temperature * (`P_K/`P_Q)`` at a 1e-7 band and **not** as
   digits — §9.15 supplies none, and the two defensible k/q sets differ by
   2.71e-8 absolute here, so any literal would fail a conforming implementation
   that picked the other set. `id` = **1.2010369553128491e-4 A** at 1e-4
   relative (wide enough for both sets, which the exponential spreads by 2.4e-5;
   narrow enough for a wrong `is` or exponent). `ddx(id,V(a))` is asserted as
   the identity **(id+is)/$vt** at a 1e-15 absolute band — measured
   4.6458183712465816e-3 S on both sides; the `+is` moves the 11th digit, so the
   band still separates an exact derivative from a divided difference.
   `ddx(ac_stim(...),V(a))` = **0.0** exactly (§4.5.6's zero case).
   *Green today, 6/6.*
6. **`a06_psd_white_flicker_export.va`** — §4.6.4.1/.2 the exported numbers.
   Thermal `white` = 4·P_K·300/1000 = **1.65678036e-23 A²/Hz** (annex D.2
   falls through to P_K_NIST1998 = 1.3806503e-23). Flicker `flicker` =
   **1e-20** (the density AT 1 Hz, so the coefficient itself) and `ef` =
   **1.25** — non-integer on purpose, since a hard-coded 1/f slope reads 1.0 and
   the two differ by 3.16× at 100 Hz (1e-22 vs 3.1622776601683795e-23).
   *Blocked on the `//! noise` value fields; the four `CHECK`s are green.*
7. **`a06_psd_bias_dependent.va`** — §4.6.4.5's diode: the PSD is evaluated at
   the solved state. At 300 K, 0.6 V, is = 1e-14, n = 1: id =
   1.2010369553128491e-4 A ⇒ `white` = 2·P_Q·id = **3.8485462795887857e-23
   A²/Hz** (P_Q_NIST1998 = 1.602176462e-19) and `flicker` = kf·id =
   **1.2010369553128491e-24 A²/Hz**, `ef` = 1.0. Discriminating: a PSD taken at
   the zero state reads 0, and a PSD guessed from the Jacobian reads 4kT·g =
   4qI = **exactly twice** the right answer (7.697100633608527e-23). `$vt` is
   asserted as §9.15's identity, as in fixture 5; the three derived `CHECK`s
   carry 1e-4 relative, and so do the two `//! noise` lines via `rtol=1e-4` —
   both densities travel through `$vt`, so neither may be pinned at the
   directive's 1e-12 default. *Blocked on the value fields; the four `CHECK`s
   are green, 4/4 measured.*
8. **`a06_noise_correlated_scale.va`** — §4.6.4.6 Example 1 with the
   coefficients kept. pwr = 1e-18, c1 = 2, c2 = 3 ⇒ branch (a,b) carries
   **4e-18 V²/Hz**, branch (c,d) **9e-18 V²/Hz**, cross term 6e-18 =
   sqrt(4e-18·9e-18), which is |ρ| = 1 — the clause's "perfectly correlated".
   That claim is the two `//! noise` lines and nothing else: §4.6.4 gives an
   active generator no deterministic scalar, so no `CHECK` can read a density.
   The three `CHECK`s present are **§4.5.6's** `vccs` values on the clause's own
   potential contributions — `ddx(V(a,b)+c1·nz, V(a))` = **+1**,
   `ddx(V(c,d)+c2·nz, V(d))` = **−1**, `ddx(cᵢ·nz, V(·))` = **0** — which is a
   smaller claim, stated as one. *Fails: `//!` directive: BadSyntax; and once
   the directive lands, on both rows exporting 1e-18, a factor of 4 and 9 low.*
9. **`a06_noise_source_name.va`** — §4.6.4.1's `name`. Three generators on one
   branch, two labelled `thermal` (1e-18, 3e-18) and one `excess` (5e-18). The
   labelled pair are INDEPENDENT (§4.6.4.6), so the combined summary line is
   **4.0e-18 A²/Hz** — densities add — and not (√1e-18+√3e-18)² = 7.46e-18,
   which is what combining them as correlated would give. Branch total
   **9.0e-18**. All of that is the three `//! noise … name=` lines: a label has
   no reading inside the analog block. The two `CHECK`s present are §4.5.6's,
   `ddx(V(p,n)/R + n0+n1+n2, V(p))` = **1/R = 1e-3 S** and −1e-3 from the other
   terminal. *Fails: `//!` directive: BadSyntax; no name field exists anywhere
   in the pipeline.*
10. **`a06_noise_table_file_input.va`** (+ `a06_noise_table_input.tbl`) —
    §4.6.4.3 file form, the clause's own printed example file plus one comment
    inserted *between* two pairs ("before or after any frequency / power pair" —
    the LRM's sample only shows head and tail comments). Export must be the
    seven knots `1e0:1.65758e-23 … 1e6:1.060851e-21`, `interp = linear`. The
    `.tbl` holds **7 '#' lines and 7 pairs = 14 lines**, so a '#'-blind reader
    reports 14 points, not 7. The powers do **not** all double per decade —
    see "Corrected after review" — so nothing checks the doubling. The one
    `CHECK` is §4.5.6's, `ddx(V(p,n)/R + nt, V(p))` = **1e-3 S**.
    *Passes since 2026-09-20.*
11. **`a06_noise_table_array_parameter.va`** — §4.6.4.3's first-named spelling,
    `parameter real tbl[0:5] = '{1.0,1e-18,1e3,1e-21,1e6,1e-24}`. Export must be
    three knots, `interp = linear`; the powers fall one decade per decade so a
    §4.6.4.4 mix-up shows as a different mode rather than as agreeing numbers.
    *Passes since 2026-09-20.*
12. **`a06_ac_stim_name_not_literal_rejected.va`** (refusal) — A.8.2 puts the
    quotation marks inside the production: `ac_stim ( [ " analysis_identifier "
    …)`. A string *parameter* is the near-miss, because §4.6.4.3 explicitly
    allows one for a file name. `//! reject **DiagnosticsReported**` — today it
    compiles and then emits a device that does not build, with no vera
    diagnostic at all, so the demand is exactly that a diagnostic exist.
13. **`a06_flicker_noise_missing_exponent_rejected.va`** (refusal) — Syntax 4-4
    brackets the name and not the exponent: `flicker_noise ( analog_expression ,
    analog_expression [ , string ] )`. `flicker_noise(1e-20)` must be refused;
    today the exponent silently defaults to 1, and `white_noise` already is the
    one-argument member of the family, so refusing loses nothing legal.
    `//! reject **DiagnosticsReported**`.

## Infrastructure these need (fixtures 4, 6–11)

One backward-compatible extension to `//! noise`, plus one new directive. Both
mirror the existing block in `lib/backend/tb.zig:583-638`, which already prints
one `got=/want= ok=` line per exported row; nothing else in the harness changes
and `countVerdicts` reads the new lines like any other.

```
//! noise <kind>(<row>,<col>)#<source> [name=<label>] [white=<v>] [flicker=<v>] [ef=<v>] [rtol=<v>]
//! noise table(<row>,<col>)#<source> [name=<label>] interp=linear|log points=<f>:<p>,<f>:<p>,…
//! acstim (<row>,<col>) [name=<label>] mag=<v> phase=<v>
```

* `validNoiseEntry` (`tb.zig:341`) currently requires everything after `#` to be
  digits, so today these lines are `error.BadSyntax`. Split the trailing
  `key=value` pairs off first, then apply the existing check to the id.
* Numeric fields compare at **1e-12 relative by default**, overridable per line
  by `rtol=`; `name=` compares byte-exact. `rtol=` is not decoration: a density
  that travels through `$vt` inherits §9.15's implementation-defined k/q, which
  the diode exponential spreads to 2.4e-5 relative, so **fixture 7's two lines
  carry `rtol=1e-4`** and at the 1e-12 default a conforming implementation using
  Annex D.2's own constants would fail them. Fixture 6's lines keep the default:
  its `white` is `4*`P_K`*300/1000`, pure Annex D.2 arithmetic with no `$vt` in
  the path, so the digits there are the implementation's only defensible answer.
  `white`/`flicker`/`ef` are read from `D.noisePsd(x, model, inst)[k]` at the
  **first operating point** (so a bias-dependent PSD is pinned at a stated bias,
  which is fixture 7's whole point); `points`/`interp` from
  `D.noise_tables[g.table.?]`.
* `//! acstim` needs the `ac_gens` export `codegen.zig:5430` already names as
  the upgrade path: `{row, col, mag, phase}` per stimulus, beside `noise_gens`.
* Fixtures 10 and 11 degrade usefully: strip the `name=`/`interp=`/`points=`
  suffix and they run **today** and fail on E0519, which is the gap they are
  about. Fixtures 4 and 6–9 lose their *principal* assertion if stripped — the
  §4.5.6 checks that remain are deliberately smaller claims, and each file says
  so in its own header rather than letting the reader mistake one for the other.

## Deliberately NOT covered

* **Tabulated interpolation and clamping**, linear and log — `A06-noisetables`
  owns it end to end, including the host integration.
* **The host's noise contribution summary itself.** Fixture 9 pins the labels
  reaching the export and derives what combining them must produce; printing the
  summary is ARPice's (`ac/noise.zig` has no per-source report at all).
* **`inoise_spectrum` / integrated noise / `.pnoise` / transient noise.** Host
  analyses, and `A06-noisetables` already names the three separate consumers of
  `NoiseSource` that each need their own oracle.
* **A model-card override of an array-parameter table.** Fixture 11 pins the
  declared default only; `//! param` binds scalars, and E0519's own explain text
  says the override is the harder half. Needs a vector-valued `//! param`.
* **`noise_table` on a parameter SLICE** (`tbl[0:3]`, the second A.8.2
  alternative) — same refusal as the whole-parameter form, one fixture is enough
  to move it.
* **Anti-correlation** (`c1 > 0, c2 < 0` in fixture 8). The sign is mentioned in
  that fixture's header because no non-negative density can encode it, but
  pinning it needs a signed cross-spectrum field that does not exist yet.
* **§4.6.2's dc-sweep variable carry-over** and the `nodeset`/`ic` columns of
  Table 4-22 — A08's row.
* **`$random`/`$arandom` large-signal noise** (§4.6.4's pointer to it) — A07.

## Corrected after review

An adversarial review found six defects in this row. All six are fixed here,
plus two found while re-verifying them (1b and 7); no compiler source,
`build.zig` or `tests/fixtures/` file was touched. Every clause number below was
re-opened in `docs/` during this pass, every ratio recomputed, and every fixture
that can run was re-run — the transcript excerpts in §"Ground truth" are pasted
from those runs.

**1. Class A — `$vt` pinned to VerA's own constant and mis-attributed.**
`a06_small_signal_linearization.va` and `a06_psd_bias_dependent.va` asserted
`$vt = 0.025851999786435535` (CODATA2018 k/q) at tolerances of 1e-13/1e-12 and
credited it to **§9.10**. §9.10 is *Simulator Time System Functions*; `$vt` is
**§9.15**, *Analog Kernel Parameter System Functions*, and §9.15 says only
"returns the thermal voltage (kT/q) at the given temperature" — **no number**.
An implementation using Annex D.2's own default fall-through (`` `P_K ``/`` `P_Q ``
= NIST1998, `preprocessor.zig:2252`) gets `$vt = 0.025852026903638282`, 1.05e-6
relative away, which the diode exponential amplifies to 2.4e-5 in `id` — so a
**conforming** implementation failed these fixtures, and the cheapest way to
make them pass was to change the compiler's constants to match the test.
Both now assert the identity with `CHECKEQ`:

```
`CHECKEQ("$vt is kT/q; the last digits of k and q are implementation-defined",
    $vt, $temperature * (`P_K / `P_Q), 1e-7);
```

**The digits are deliberately not written.** §9.15 states an identity and names
no constants; `CHECKEQ` exists in `tests/fixtures/check.vh` for exactly that
case ("the rules the LRM states as an identity with no value to write down").
The 1e-7 band is chosen so it admits every defensible k/q — the two candidate
sets differ by 2.71e-8 absolute at 300 K, a factor of ~3.7 inside the band —
while still failing a `$vt` that is wrong *in kind*: the wrong temperature,
q/kT inverted, or a missing factor all miss by ≥1e-3. Everything derived from
`$vt` (`id`, the shot-noise and flicker powers) moved from 1e-12/1e-13 to
**1e-4 relative**, which is four decades above the 2.4e-5 spread between the two
constant sets and still catches a wrong `is`, a wrong exponent, or the
factor-of-2 §4.6.4.5 confusion (that error is 100% out). *(This item was fixed
by hand before this pass; the missing half — fixture 7 had no `CHECKEQ` — has
been added here.)*

**1b. The same Class A trap, latent in fixture 7's `//! noise` lines.** Both
carry a density proportional to `id`, i.e. proportional to the k/q set §9.15
leaves free, and the directive grammar above specified a flat **1e-12 relative**
comparison. The directive does not exist yet, so nothing goes red today — but as
specified it would have failed a conforming implementation on the day it landed,
which is the same defect one step deferred. The grammar now takes an optional
`rtol=` and fixture 7's two lines carry **`rtol=1e-4`**, matching the `CHECKR`s
five lines below them; the header says why. Fixture 6 deliberately keeps the
1e-12 default — its `white` is `4*`P_K`*300/1000`, Annex D.2 arithmetic with no
`$vt` in the path, so there is exactly one defensible value and the digits are
writable.

**2. Class B — `//! lrm 4.5.10` for `ddx`.** §4.5.10 is *last_crossing
function*. `ddx` is **§4.5.6**, *Derivative operator*. Corrected in
`a06_small_signal_linearization.va`'s directive and twice in its prose, and in
this file's clause list. §4.5.6 is strictly the better cite: its **first
example** is this fixture's device verbatim (`idio = IS*(limexp(V(a,c)/$vt)-1);
gdio = ddx(idio, V(a));`), and its sentence "If the expression does not depend
explicitly on the unknown, then ddx() returns zero (0)" is the exact licence for
the `ddx(stim, V(a)) = 0` check. §4.5.10 licensed neither.

**3. Class C — the file-table fixture's "self-checking" claim was false.** Its
header said each power in §4.6.4.3's printed file "is twice the one a decade
below it, so a transcription slip of one digit is visible by eye". Re-derived
from the file, the six consecutive ratios are

| pair | ratio |
|---|---|
| 3.315160 / 1.657580 | 2.0 |
| 6.636320 / 3.315160 | **2.0018098673970486** |
| 13.26064 / 6.636320 | **1.9981917689321793** |
| 2.652128 / 1.326064 | 2.0 |
| 5.304256 / 2.652128 | 2.0 |
| 10.60851 / 5.304256 | **1.9999996229442922** |

The reviewer's figures are confirmed. Row 3 is the instructive one: 2 ×
3.315160e-23 is 6.63**0**320e-23, and row 4 divided by four is 3.315160e-23
*exactly*, so rows 2 and 4 bracket row 3 at precisely 4× — the printed
6.636320e-23 reads like a digit slipped inside the **standard** (9.05e-4
relative). Row 7 is 2 × 5.304256e-22 = 1.0608512e-21 rounded to the seven
significant digits the clause prints (1.89e-7). The `.tbl` keeps the LRM's
digits verbatim — fidelity to `docs/ch4-expressions.html` is the only thing it
is for — and the header now warns a reviewer **not** to "correct" them. The
`CHECK` that advertised the doubling is gone. The comment count was also wrong:
there are **7** `#` lines (4 head, 2 middle — the inserted comment wraps, and
§4.6.4.3 ends a comment at a newline — 1 tail) and **14** lines total, not 6 and
13.

**4. Class D — four fixtures asserted nothing that could fail.** All four are
repaired the same way: the checks that could not go red are deleted, the header
says in one named paragraph *where the fixture's claim actually lives*, and what
replaces them is **§4.5.6 against a non-zero want**, which is the one thing a
noise or stimulus generator is observable through inside an analog block.

| fixture | deleted, and why it had no teeth | replaced by |
|---|---|---|
| `a06_ac_stim_quadrature.va` | `2*cos(π/3)`, `2*sin(π/3)`, `cos(π/2)` — arithmetic over literals; the header itself said they "do not touch `ac_stim`" (and miscounted three as two) | `ddx(s,V(·))` = 0 at π/3 and π/2, and `ddx(V(p,n)/R + s, V(p))` = 1/R = 1e-3 S |
| `a06_noise_source_name.va` | `1e-18+3e-18` vs 4e-18; `1e-18+3e-18+5e-18` vs 9e-18; **`5e-18` vs `5e-18`** — a literal against itself; and `V(p,n)/R` vs 1e-3, which *looks* like a dc check but cannot move because `//! bias` pins x[p] and x[n] | `ddx(V(p,n)/R + n0+n1+n2, V(p))` = ±1/R |
| `a06_noise_correlated_scale.va` | `c1*c1*pwr` vs 4e-18 etc. — arithmetic over parameters whose values are five lines below | §4.5.6's `vccs` values on §4.6.4.6's own potential contributions: +1, −1, 0 |
| `a06_noise_table_file_input.va` | the false doubling ratio, plus the same pinned-probe `V(p,n)/R` | `ddx(V(p,n)/R + nt, V(p))` = 1/R |

**Withdrawn claims and where they went.** The (magnitude, phase) pair, the
per-source label, the per-branch correlated density and the seven file knots are
**not** re-asserted as `CHECK`s and cannot be. §4.6.3 defines a phasor and an f64
is not one; §4.6.4 gives an *active* noise generator no deterministic scalar
value; §4.6.4.1 gives a label no reading inside the analog block; §4.6.4.3 gives
the model no way to index a file table. Each claim now lives on exactly one
`//! noise` / `//! acstim` line, and the route back to a `CHECK` is named in
"Infrastructure these need" below: `validNoiseEntry` (`tb.zig:341`) must accept
`key=value` suffixes, `contract.NoiseGen` needs `name` and a per-use
coefficient, and `ac_gens` (row, col, mag, phase) must exist beside
`noise_gens`. Writing `mag*cos(phase)` down instead was considered and rejected:
that is the defect under test, and blessing it as the specification would hand
an implementer a green test for discarding the imaginary part.

**5. Both refusals had a false-positive `//! reject`.** They read
`//! reject ac_stim` and `//! reject flicker_noise`. `failureContains`
(`tests/torture.zig:211-220`) matches the pattern against `f.generated` — the
generated Zig — *before* it reaches any diagnostic, and the generated Zig
contains each construct's name twice, inside the module's own name
(`--emit-zig | grep -c` → 2 in both files). So either fixture went green on
**any** failure, including today's unused-function-parameter engine bug, which
is precisely the outcome `a06_ac_stim_name_not_literal_rejected.va` exists to
forbid. Both now read `//! reject DiagnosticsReported`, the repo's convention
for "a refusal is required, the code is not assigned yet" (48 files), which
holds only if at least one vera diagnostic was emitted. Swap in the code once
A.8.2's string-literal rule and Syntax 4-4's arity rule are assigned one.

**6. Hygiene.** The 26 MB `tests/pending/A06/.zig-cache` build spill is deleted;
`git status --porcelain` shows the single `?? tests/pending/` line.

**7. Three source line numbers were stale.** This file and two headers cited
`codegen.zig:5517` for the hard-coded k/q (it is **:5519**; :5516 is the comment
that repeats the §9.10 miscite), `codegen.zig:5421` for the `ac_stim` lowering
(the `@cos` is at **:5430**), and `tb.zig:357` for `validNoiseEntry` (its
declaration is at **:341**, called from :271 — the row's own fixture headers had
:341 right and only "Infrastructure these need" was off). All three re-read at
`45b505d` and corrected. Three citations outside `docs/` are not clause numbers,
but a header that points at the wrong line is the same defect in a smaller way.

**Not changed, and why.** The reviewer's Class C numbers for the file table were
re-derived independently here and agree to the last digit, so nothing is
disputed. No fixture was deleted: all four Class D files retain a real,
LRM-licensed assertion plus a directive-borne claim that is blocked rather than
absent, and the inventory stays at 13 fixtures (11 positive, 2 refusals).

## How to run these

Each fixture is self-contained and runs through the ordinary testbench path:

```
cd /home/omare/Documents/Projects/Zig/VerA
zig build                                  # zig-out/bin/vera
./zig-out/bin/vera --run \
    --contract tools/contract.zig \
    -I tests/fixtures \
    tests/pending/A06/a06_ac_stim_ac_analysis.va
```

`-I tests/fixtures` is only for `check.vh`. The `.tbl` asset is resolved beside
its `.va`, so fixture 10 must be run from this directory (or the file copied
next to it).

Under the suite, once the directives above land and the fixtures are green:

```
cp tests/pending/A06/a06_*.va tests/pending/A06/*.tbl tests/fixtures/ch04_expressions/
zig build torture -- --strict ch04
```

`suite_options.fixture_root` is pinned to `tests/fixtures` in `build.zig:428`,
so there is no way to point `torture` at `tests/pending` without editing it —
hence the copy. Expect **13 more fixtures**, 11 asserting values and 2 asserting
refusals.
