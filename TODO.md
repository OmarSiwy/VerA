# Verilog-AMS conformance — state, knowledge, and remaining work

Written 2026-09-20. This is a handoff document: everything a fresh session needs
to continue without re-deriving it. It is deliberately blunt about what is NOT
done.

**Read [`tests/fixtures/MANIFEST.md`](tests/fixtures/MANIFEST.md) next.** It is the
per-row defect register (950+ lines) and this file does not duplicate it.

> **§1 and §3.3 below were re-measured on 2026-09-20 after the `lib/` split.**
> `tests/pending` no longer exists as a separate tree — its fixtures were filed
> under the chapter they pin, so the progress meter and the gate are now one
> number and that number is NOT green. Everything in §2 (the expensive
> knowledge) still holds; §3.1's per-diagnostic table predates the merge and its
> counts are low.

---

## 0. How much is left, honestly

"100% Verilog-AMS conformance" is a multi-quarter program, not a backlog. Four
independent measures, none of which reduce to each other:

| Measure | Open | Total | Source |
|---|---|---|---|
| Pending fixtures not yet behaving as stated | **140** | 193 `.va` | `zig build benchmark -- --fixture-root=tests/pending --strict` |
| Pending fixtures **not measured at all** | **145** | 338 all kinds | §3.3 below |
| Inherited IEEE 1364 obligations open | **83** | 119 | `docs/CLAUSE-AUDIT.md` §7.1 |
| AMS clauses lacking two-way evidence | **463** | 611 | `docs/CLAUSE-AUDIT.md` §7.2 |

The 83 = 63 missing + 11 partial + 9 implemented-without-evidence. Only 30 are
`verified`, and those are genuinely backed (differential C oracles, byte-level
output checks) — the analog side is in good shape.

The 463 = 208 accepted-only + 99 refused-only + 156 uncited. **This is the
non-obvious half of the work.** A large part of "matching the spec" is not
writing features; it is pinning behavior that already works in both directions.
Only the 148 "tested both ways" can support a `verified` verdict, per the plan's
own completion rules.

Plan rows (`../ARPice/docs/verilog-ams-conformance-plan.md`): 32 total, roughly
2 done, 7 mostly, 14 partial, 9 none.

---

## 1. Current measured state

Reproduce all of it from a clean checkout:

```sh
cd VerA
zig build test --summary all          # 104/104 tests, 26/26 steps — GATE
zig build benchmark -- --strict       # 1390 pass / 133 FAIL / 34 XFAIL of 1557 .va
zig build test-devices                # 5/66 — the `vera --run` digital transcripts
zig build install                     # ./zig-out/bin/vera

cd ../ARPice
zig build test --summary all          # 297/297 tests, 351/353 steps
                                      # the 1 failing step is test-correctness (below)
```

ARPice circuit suite: **518/616**. Failure kinds: 80 `ValueMismatch`, 9
`SimulatorFailed`, 4 `MissingColumn`, 3 `RootCountMismatch`, 1 `NonfiniteOutput`,
1 `MissingTimeCoverage`.

**Do not treat the circuit suite as a gate.** The same unchanged tree has scored
492, 494 and 518 across runs with byte-identical generated device code. Only ~10
of the 98 failures are in the load-sensitive kinds the manifest fingered, so
either the nondeterminism is wider than those kinds or 518 was a lucky run. One
run establishes nothing. `ARPice@4b43d53` already records this.

### What the 133 are, by shape

Roughly half are COMPILER work and roughly half are FIXTURE work, and the split
matters because the second half is cheap:

| Shape | Count | Whose bug |
|---|---|---|
| `did not compile` / `NoModule` | 41 | compiler |
| `asserts nothing` | 14 | fixture — it runs green and claims nothing |
| `want is an expression, not a literal` | 11 | fixture |
| `expected a diagnostic, but it compiled cleanly` | 9 | compiler (a missing refusal) |
| `//!` directive: UnknownDirective | 7 | harness — `//! timescale`, `//! acstim` |
| codegen refused a construct (`@compileError`) | 6 | compiler |
| `N of M assertion(s) reported ok=0` | ~40 | compiler — wrong VALUE, the real conformance work |
| the generated testbench does not compile | 2 | compiler — an ENGINE bug, loudest of the lot |

By chapter: ch07 mixed-signal 35, ch05 analog 26, ch04 expressions 26, ch09
system tasks 13, annex E SPICE 10, ch06 hierarchy 8, ch10 directives 6, ch12 VPI
5, the rest 4.

### Commits landed

| Repo | Commit | What |
|---|---|---|
| ARPice | `678c7ce` | Q03: tree did not compile in any mode; lazy analysis hid it |
| VerA | `3e88218` | `asInt` aborted the compiler on a real with no nearest integer |
| VerA | `20d6961` | out-of-range array read `@panic`ed from inside generated device code |
| VerA | `2cc1c08` | the 2023 LRM replaces 2.4; the stale prose goes with it |
| VerA | `0984a12` | `lib/` split, one suite step, `tests/pending` merged into the tree |
| VerA | `4f67e47` | §4.6.4's `name` argument reached the parser and stopped there |
| VerA | `c4be543` | the per-use noise coefficient gap, marked where it cannot hide |

VerA on `ddt-capform`, ARPice on `spice-audit`.

**A second agent was editing `tests/fixtures/` concurrently on 2026-09-20.** The
fixture count moved 1516 → 1557 mid-session and the xfail count 11 → 34 without
either being this session's doing. Numbers above are a snapshot; re-measure
before trusting a delta.

---

## 2. Knowledge that is expensive to rediscover

### 2.1 How to actually run a fixture

This cost several attempts. `--check` needs **both** flags:

```sh
./zig-out/bin/vera --check --contract tools/contract.zig \
    -I tests/fixtures -I <the fixture's own dir> <file.va>

# self-checking testbench — prints the ok=0/ok=1 lines:
P=$(./zig-out/bin/vera --emit-exe --contract tools/contract.zig \
      -I tests/fixtures -I <fixture dir> <file.va> 2>/dev/null)
"$P"

./zig-out/bin/vera --run <file.v>     # digital source execution
```

- `--emit-exe` prints the binary path on **stdout**, diagnostics on **stderr**.
  Capture separately or you get an empty path.
- The fixture's own directory must be on the include path. The harness passes
  `f.dir` automatically; a manual invocation does not, and three D10 fixtures
  look broken if you forget (they are fine).
- `` `//!` directive: BadSyntax `` on the EXE build while `--check` exits 0 is
  usually the row's **genuine expected failure** (an unimplemented directive),
  not damage you caused.
- `zig build test 2>&1 | tail` swallows the build's exit code. Gate on `$?`
  explicitly or you will report a failing build as green. This happened.

### 2.2 The fixture convention

Header quotes the LRM sentence being pinned and derives the expected value by
hand, then machine-readable tags, then `` `include "check.vh" ``:

```
//! lrm 9.4.1
//! bias V(p) = 0.75, V(n) = 0.25
//! reject E0310          <-- a SUBSTRING, and a bare `//! reject` matches ANY
//!                           diagnostic (tests/torture.zig:223). Always name
//!                           the code or a distinctive phrase.
//! xfail <reason>        <-- honest "vera is wrong, fixture is right". Fails on
//!                           XPASS, so it cannot outlive the limitation.
```

`tests/fixtures/check.vh` macros: `CHECK` (absolute tol), `CHECKR` (relative),
`CHECKX` (exact), `CHECKI` (integer), `CHECKEQ` (two VerA expressions against
each other).

**`CHECKEQ` is the tool for implementation-defined values.** Its own header says
it is for "rules the LRM states as an identity with no value to write down". Use
it wherever the LRM specifies a relationship but no digits — see §2.4.

### 2.3 Gates and scope

- `zig build benchmark -- --strict` = **1323/1323**. This is the gate. Breaking it
  is a failed change, not a tradeoff.
- `zig build test` = 404/404. Also a gate.
- The `tests/pending` run is **expected to fail** and carries no `expectExitCode`. It
  is a progress meter, not a gate.
- `tests/fixtures/` is frozen. Do not add, edit or delete anything there while
  working on pending rows.

### 2.4 Two traps that produce confidently wrong work

**A fixture that a *conforming* implementation fails.** The cheapest way to make
it pass is to break the compiler. Four were found and fixed; assume more exist.
Concrete instances:

- `$vt` pinned to VerA's own hard-coded CODATA2018 constant while §9.15 supplies
  no number at all. Annex D.2's default `` `P_K ``/`` `P_Q `` are NIST1998, a
  1.05e-6 difference that the diode exponential amplifies to 2.4e-5. Fixed by
  asserting `$vt == $temperature * (`P_K / `P_Q)` via `CHECKEQ` with a band
  admitting either set.
- `absdelta(V, 0.5)` against a wave stepping exactly 0.5, where §5.10.3.4 fires
  on "**more than** delta". The literal reading never fires; the fixture passed
  only an implementation using `>=`. It tested for a bug.
- Seven M02 fixtures assumed a digital-context `integer` starts at 0. §3.2 says
  **x** — only analog-context assignment defaults to zero. `n = n + 1` is x
  forever.
- "The second NBA cancels the first." IEEE 1364 §9.2.2 performs **both**.
  §8.4.4's "canceling" is the D2A connectmodule's transition filter, which is
  M04's machinery.

**A green signal that measures nothing.** A lazily-analysed Zig file is never
type-checked — ARPice reported 266/266 passing while `pss/hb.zig` did not
compile, because `src/analysis/root.zig` listed no `pss/*`. Import implementation
files for sema, not just test files.

### 2.5 Architecture findings

- **`tb.zig`'s solver is a source *template*, not a function.** `tb.zig:1297` is
  a Zig string literal emitted into each generated testbench. A coordinator in
  `src/sim/` **cannot call it**. This kills the cheapest imagined route to
  mixed-signal.
- **`tb.zig:695` is a fixed-grid evaluator** — a loop over the declared `//! time`
  points. There is no mechanism to insert a solver-chosen timepoint, which is
  why several M01/M02 fixture rationales that assume mid-step observation are
  false. `tb.zig` is the wrong vehicle for mixed-signal fixtures; a new runner is
  needed.
- **`digital.zig:1023` refuses on twelve conditions in one `if`** — `is_connect`,
  ports, params, aliasparams, branches, instances, defparams, genvars, events,
  functions, analog, attrs. Deleting `m.analog.len != 0` opens nothing.
- **Nothing in `src/` posts `.analog` or `.explicit_d2a`.** `src/sim/scheduler.zig`
  is complete and unit-tested (six regions, future heap, cancellation, analog
  request coalescing) with zero production callers for the mixed-signal regions.
  Every other `.analog` hit in `src/` is the AST's analog-block list, a different
  thing.
- Time: scheduler is `u64` ticks (`scheduler.zig:8`); analog is `f64` seconds.
  `src/sim/time.zig` already has the `Scale` conversion (`realDelay`,
  `unsignedDelay`).
- **All 13 `w2/*` branches are empty.** `git merge-tree ddt-capform w2/<x>`
  returns `ddt-capform^{tree}` for every one; each reflog has a single
  "Created from HEAD". Nothing to merge, nothing to salvage. Prune them.

---

## 3. Remaining work

### 3.1 Ranked by fixtures blocked at the compile gate

Measured by compiling all 193 `.va` and recording the first diagnostic.
**108 compile fine and fail on values** — the work is mostly semantics, not
parsing.

| Diagnostic | Fixtures | Meaning | Rows | Where |
|---|---|---|---|---|
| — | 108 | compiles, wrong value | all | — |
| `E0205` | 21 | unsupported module item (`always`) | M01 6, M02 8, M03 2, M04 5 | needs the coordinator |
| `E0209` | 14 | expected an expression | M01 7, M02 5, A08 1 | parser gaps |
| `E0815` | 11 | `$table_model` source/control string | A05 | `lower.zig:8660` — **mostly fixed by uncommitted work, see §3.2** |
| `E0904` | 10 | instance names no module | H04 9, H01 1 | elaboration / D07 |
| `E0515` | 5 | control arg not constant | A04 3, A06 1, A10 1 | |
| `E0907` | 4 | override names no parameter | M03 3, H04 1 | |
| `E0402` | 4 | `disable` is not implemented | A03 | `lowerDisable` is a 2-arm stub |
| `E0519`,`E0313` | 2 each | | A06, A01 | |
| `E0901`,`E0902`,`E0914`,`E1004`,`E0208`,`E0813`,`E0517`,`E0310`,`E0311`,`E0820` | 1–2 | | various | |

### 3.2 Recommended order

**A05 `$table_model` is ALREADY IN PROGRESS in the working tree** — uncommitted
changes to `lib/backend/table_kernels.zig` (+281) and `lib/ir/lower.zig` (+~70)
implementing quadratic and cubic splines with natural/clamped boundary
conditions, citing Tables 9-30/9-31 and §9.21.4, plus `I`-column projection.
It builds, and it takes A05 from 2/13 to **12/13 compiling**. Whoever picks this
up: finish and commit that work rather than starting over, and check the gate
(§1) before anything else. The remainder below is what was still open when this
file was written:
- quadratic (`2`) and cubic (`3`) spline modes with the boundary conditions
  §9.21.2 specifies — **read the clause, do not pick a textbook spline**; several
  cubics are defensible and only one is correct here
- fatal extrapolation (`E`) and the remaining control-string combinations
- `readTableFile` (`lower.zig:8671`) currently reads **eagerly at compile time**;
  §9.21 requires loading at the first *executed* runtime call. Separate, larger
  change — do not half-convert it.

Constraints for whoever does it: `lib/backend/table_kernels.zig` is `@embedFile`d
verbatim into every device *and* imported by codegen's tests, so the numerics
tested are the numerics that run — preserve that. The lookup is a **recursion
over dimensions** where every interpolation is one-dimensional (§9.21's own
text); splines slot in per-dimension, do not restructure into an N-D formula.
`zTabRes` carries an exact **gradient** deliberately — a table on a probe is a
function of a solver unknown, and returning a bare value tells the solver the
table is flat and costs it the Newton step. Every scheme must produce its
analytic derivative. Nothing allocates; keep it comptime-sized.

Then, roughly in this order:
1. `E0402` `disable` (4 fixtures, one feature, A03)
2. `E0904` / `E0907` — elaboration and parameter override (14 fixtures, H04+M03+H01)
3. The 108 value-failures, row by row — this is where per-clause conformance
   actually lives
4. Digital chain `D02` selects → `D03` strengths → `D04`. `grep partSelect src/`
   is empty; nothing exists. 63 of the 83 open inherited obligations are here.
5. Mixed-signal coordinator (§3.4) — its own design task
6. `P02`/`P03` VPI values and callbacks — needs a *running* scheduler;
   `tests/vpi_host.zig` is lint-only today

### 3.3 Unmeasured fixtures — 33 of 1671

Mostly closed. `zig build test-devices` now runs the `.v` fixtures through
`vera --run` and diffs their transcripts, which was this table's first row.

| Kind | Count | Measured by | State |
|---|---|---|---|
| `.va` | 1557 | `zig build benchmark -- --strict` | 1390 pass / 133 FAIL / 34 XFAIL |
| `.v` | 81 | `zig build test-devices` | **5/66** — 15 fixtures the runner does not select |
| `.c` | 26 | — | still nothing; VPI needs a running scheduler |
| `.sp` | 7 | — | still needs a `--spice` CLI flag |

**5/66 on the digital side is the headline, and it is one refusal.** The engine
accepts "a portless module with only variables and initial processes"
(`src/sim/digital.zig`, E1100). Everything D03 through D09 asks for is outside
that: drive strengths on a continuous assign (`assign (strong1, highz0) w = a`
is E0209, "expected an expression" — the parser has no `drive_strength`), gates,
UDPs, delays, `wreal`, and `$display` conversions other than `%b` and `%%`.

The narrowest real defect in that list, and the one 10 fixtures sit behind:
**`$display` implements `%b` and `%%` and nothing else** (`digital.zig:713`).
§9.4.3 Table 9-22 defines `%h/%d/%o/%b` and the inherited IEEE 1364 §17.1.1.3
sizes each field from the operand's declared width; §17.1.1.4 gives the
`x`/`X`/`z`/`Z` rendering of a partly-unknown digit group.
`d09_01_display_radix.expected.txt` is already written out by hand and derived
in its own header — the want exists, only the printer does not. `$strobe`,
`$monitor`, `$timeformat`, `$readmemh`/`$readmemb` and `$clog2` are each a
separate "not implemented" from the same file.

### 3.4 The mixed-signal coordinator (M01–M04, ~53 fixtures)

Not a wiring job. Both engines exist in isolation; the coordinator is new code.
Required, in the order M02's own SPEC derives:

1. parser accepts `always` + `#` delay + `assign` in an analog-context module
2. `digital.zig` accepts modules with ports and an analog block (12-condition
   refusal at `:1023`)
3. A2D delivery: cross → digital tick with §8.4.3.3 half-precision-base rounding
   → unlocks M02 04/08/11
4. implicit D2A + region 3b → unlocks 02/10/12
5. explicit D2A + region 1b → unlocks 03/05/06/09
6. `absdelta` interpolation → unlocks 13
7. §8.4.2 DC iteration → unlocks 01

Plus: a new runner (not `tb.zig`), and tick↔second conversion via
`src/sim/time.zig`'s `Scale`. M03 additionally needs the §7.8 insertion phase
(`elaborate.zig:54-58` documents its absence) and §7.8.5 generated names as
defparam targets. M04 needs `wreal` as a net type and real variables + `%g` in
the digital engine.

### 3.5 Fixture-quality debt

`MANIFEST.md` §5: **3 rows clean** (`A06-noisetables`, `D03`, `D06`), **23
partial**, 0 regressed. Open defects are per-row in §5.1–5.8. Dominant remaining
shape: the repair fixed `SPEC.md` and left the same error in the fixture's own
prose, or vice versa. Two examples: `A01/08_...va:29` still narrates a corrected
transcript string; `A02/01_...va:51` still names `res[flowZ28pZ2cgZ29]`, a branch
unknown the module never declares.

§5.8 carries fixer-vs-reviewer disagreements with **both** derivations — those
need a human call, not another agent pass.

### 3.6 Known-stale documentation

- `MANIFEST.md` §3 says the Q03 fix is "uncommitted" — it is `ARPice@678c7ce`.
- `A09/SPEC.md:9` "src/ unmodified" and both A09/X01 "built at HEAD" — were true
  when written, now need rebasing onto the commit.
- `docs/CONFORMANCE-GAPS.md` numbers (375 units, 1313 fixtures, 295 host units)
  are stale; actual 404 / 1323 / 297.
- `CLAUSE-AUDIT.md` §7.3 lists 5 cheap `COVERAGE.md` corrections, none done.

### 3.7 Other confirmed defects, not yet fixed

- **§4.6.4.6's per-use noise coefficient never reaches the export, and the error
  is silent.** `V(a,b) <+ c1*n` exports `white = pwr`, not `c1²·pwr`, so a host
  computes the module's output noise low by `c1²` — a factor of 4 and 9 in
  `a06_noise_correlated_scale.va`, which now carries the `//! xfail` that says
  so. `tools/contract.zig:665` has named the fix since before this session; the
  shape it has to take is `coeff` on **`PsdTerm`, not `NoiseGen`**, because the
  coefficient may depend on the bias (`I(a,b) <+ V(a,b)*white_noise(p)` is a
  legal modulated source). That gives `S_k(f) = coeff²·(white + flicker/f^ef)`,
  the same relation for a §4.6.4.3 table row whose COMPTIME spectrum cannot
  absorb a runtime factor, and `coeff_i·coeff_j·pwr` for the cross term — where
  the SIGN is the whole difference between correlation and anti-correlation, so
  `coeff` is signed and only the host squares it. Computing it is a ∂/∂n walk
  over the already-built MIR DAG (`Mir.valueDef`/`instData`), NOT a second
  lowering of the AST: the noise source must enter linearly, so the walk needs
  only fadd/fsub/fneg/fmul/fdiv and refuses anything that makes `n` nonlinear.
  Cross-repo: ARPice reads `noisePsd` and must learn the field, or it keeps the
  old answer against a default of 1.0.
- **§4.6.4.3's two non-vector table inputs are refused.** The clause says the
  argument "can either be specified as an array parameter or an array assignment
  pattern", and separately that it may be a file name. Both are E0519 today
  (`a06_noise_table_array_parameter.va`, `a06_noise_table_file_input.va`),
  because `noise_tables` is a comptime export and neither input is comptime
  data. The file half may be cheap — `readTableFile` (`lower.zig`) already reads
  a §9.21 table file and the formats are the same shape.
- **`u_nodeset` is a dead export.** VerA emits it (`codegen.zig`, §3.6.3.2 net
  initializers); `grep -rn u_nodeset ARPice/src` = **0 hits**. Fix is
  `ARPice/src/analysis/dc/op.zig:24` plus the `seedFn` rewrite at
  `eval.zig:1392-1406` so a nodeset reaches `x` and not `lim_x`.
- **`noise_tables` is a dead export.** Same shape. Four sites:
  `device_ir.zig:79`, `eval.zig:1714`, `ac/noise.zig:42`, and — do not miss it —
  `pss/pnoise.zig:41`.
- **X01 LTRA history overflow is live.** `ltra_native.zig:61` CAP=8192,
  `txl_native.zig:42` CAP=2048, samples silently discarded past it. A sine deck
  past CAP diverges from ngspice-44.2 by **0.852 V on a 0.5 V signal**; the same
  deck under CAP agrees to 6.3e-5. The LTRA/TXL **AC stamp does not exist at all**.

---

## 4. Ground rules

1. `benchmark --strict` 1323/1323 and `zig build test` 404/404 are gates. Gate on
   `$?`, not on reading the tail of a log.
2. Fix at the root. `asInt` had ten callers; guarding the crash site would have
   left nine able to abort.
3. Reuse before writing — `zeroOf(VTy)` at `codegen.zig:3286` already existed for
   the array-default fix; `CHECKEQ` already existed for implementation-defined
   values; `envFlag` already existed for the cached env read.
4. A rejection fixture is **not** positive coverage. 463 of 1327 existing fixtures
   assert a refusal.
5. Compiler acceptance is not runtime evidence. The plan's completion rules
   require a positive behavioral test, an invalid-input test, and a recorded
   result per obligation.
6. When the LRM leaves latitude, assert the identity, not digits. Say in the
   header why the digits are not written.
7. If you withdraw a claim from a fixture, name the row it moved to.
