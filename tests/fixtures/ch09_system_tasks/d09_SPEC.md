# D09 — Timing constructs and digital system facilities

Pending fixtures for the D09 row of
`/home/omare/Documents/Projects/Zig/ARPice/docs/verilog-ams-conformance-plan.md`
(lines 221-258). None of them pass today, and none of them is supposed to — with
the one exception the review found and this document now records: until the
`//! reject` directives were given substrings, the two refusal fixtures were
satisfied by the *absence* of the features they test. See "Corrected after
review" at the end.

## Ground truth established before writing (not taken from the plan)

* `src/sim/digital.zig` dispatches **four** system-task/function names and no
  others: `$signed` and `$unsigned` (line 138, as casts) and `$display` and
  `$finish` (line 140). Verified by grepping quoted `$…` literals in that file.
* `src/sim/digital.zig:694-732` implements `$display` over **`%b` and `%%`
  only**; any other conversion is refused with "only %b and %% display
  conversions are implemented", and a non-literal format is refused outright.
* `$timeformat`, `$printtimescale`, `$readmemb`, `$readmemh`, `$time`,
  `$stime`, `$realtime`, the sixteen `$async`/`$sync` PLA spellings, the five
  `$q_*` tasks and the `$display`/`$write` radix variants **do** appear in
  `lib/ir/lower.zig` — exclusively inside `isDigitalOnlySysFunc`
  (lines 6806-6856), a list of names to **refuse** in an analog block. That is
  a rejection list, not an implementation. `lib/backend/file_kernels.zig` and
  `lib/backend/cg_display.zig` implement the ANALOG side of the overlapping
  tasks; the plan (lines 231-234) says in as many words that this is not
  evidence for the digital row, and `cg_display.zig:128` even documents two
  deliberate deviations from the 1364 display-sizing heritage that must not
  carry over to a digital `reg`. (That source comment numbers the heritage
  "§17.1.1.2"; the sizing rule is §17.1.1.3 by `docs/CLAUSE-AUDIT.md:274-275`.
  The comment is in `src/` and out of scope here; it is named so the wrong
  number is not copied out of it again — this row did exactly that.)
* `$dumpfile` / `$dumpvars` / `$dumpports` appear **nowhere** in `src/`. The
  single hit for `$dumpvars` in the tree is an unrelated doc-comment example at
  `lib/frontend/preprocessor.zig:289`. Matches `docs/CLAUSE-AUDIT.md:357`.
* `specify` / `endspecify` / `specparam` / `$setup` / `$hold` / `$width` appear
  nowhere in `src/`. A module containing `specparam` is rejected at PARSE time
  with `E0205 unsupported module item: found specparam`.
* Branches `w2/systasks` and `w2/vcd` are byte-identical to `ddt-capform`
  (`45b505d`), with clean worktrees. Nothing from them is re-spec'd here
  because nothing exists.
* Verified positively implemented and therefore relied on: one-dimensional
  unpacked arrays with element indexing (`digital.zig:148-212, 307-312`),
  `timescale` handling and integral delays (`digital.zig:979`), `$finish(0)`
  as a silent terminator, and the §5.4 region ordering already pinned by
  `tests/digital/scheduling.v`. Real procedural delays are **not** wired:
  `digital.zig:979` calls only `signedDelay`/`unsignedDelay`, never
  `realDelay`, although `src/sim/time.zig` implements `realDelay` already.

## LRM clauses covered

Verilog-AMS 2023 (read from `docs/ch9-system.html`, `docs/ch2-lexical.html`):

| Clause | What it supplies |
|---|---|
| §9.4.1 / Table 9-1 | display-task argument model, null argument, no-argument newline, `$write` without newline, `$strobe` converged-solution sampling, the `$monitor` mechanism sentence, `$monitoron`/`$monitoroff` digital-only column |
| §9.4.3 / Tables 9-22, 9-23 | `%h %d %o %b %c %s`, the real conversions `%e %f %g %r`, the default-decimal rule for an unformatted argument, "the full formatting capabilities available in the C language" |
| §9.4.5 | `%s` right-justification and leading-zero suppression (**not fixtured here** — see below) |
| §9.4.7 | "the `%r` (or `%R`) format specifier may be used on real expressions in the digital context" (**not fixtured** — see below) |
| §9.5 / Table 9-2 | `$readmemb`/`$readmemh` digital-only column |
| §9.6 / Table 9-3 | `$printtimescale`, `$timeformat` digital-only; "Verilog AMS HDL does not extend the timescale tasks defined in IEEE Std 1364 Verilog" |
| §9.8, §9.9 | "does not extend" for PLA and stochastic queues — the inherited text governs verbatim |
| §9.10 / Table 9-7 | `$time`, `$stime`, `$realtime` digital-only; `$abstime` is the AMS addition |
| §9.14 / Table 9-11 | `$clog2` supported in both contexts |
| §2.6.2 Table 2-1 | the scale symbols `%r` renders with |

Inherited IEEE 1364-2005 clauses. The 1364 text is **not** in `docs/` — the
shipped corpus is the Verilog-AMS LRM — so every number below is taken from the
repo's own inventory of the inherited clauses, `docs/CLAUSE-AUDIT.md`, with the
line that establishes it. Nothing here is taken from the plan's prose or from a
`src/` comment.

| Clause | Title, per the audit | Audit line | Used by |
|---|---|---|---|
| §17.1.1.3 | automatic sizing of displayed data | :275 | fixture 01 |
| §17.1.1.4 | unknown / high-impedance display | :276 | fixture 02 |
| §17.1.2 / §17.1.3 | `$strobe`; `$monitor`, `$monitoron`/`$monitoroff` | :280, :282-283 | fixtures 03, 04 |
| §17.2.9 | `$readmemb`/`$readmemh`, incl. "malformed and excess data" | :313 | fixtures 08, 09, 91 |
| §17.3 | timescale system tasks — `$printtimescale`, `$timeformat` | :323 | fixture 07 |
| §17.7 | simulation time system functions — `$time`, `$stime`, `$realtime` | :331-333 | fixtures 05, 06 |
| §17.11 | `$clog2` | :348 | fixture 10 |
| §18.1, §18.2 | VCD tasks and the four-state VCD file | :364-376 | fixtures 11, 12, 90 |

§17.1.1.2 is *format specifications* (:274) and is **not** cited by this row;
§17.3 and §17.7 are distinct clauses and are not interchangeable. Both mistakes
were in these files before the review — see "Corrected after review".

## Fixtures

Each `NN_name.v` pairs with `NN_name.expected.txt` (exact stdout), except the
two VCD fixtures which pair with `NN_name.expected.vcd`, and the two `9N_…`
refusals which have no golden.

| # | File | Pins | Expected value and derivation |
|---|---|---|---|
| 1 | `01_display_radix.v` | §9.4.3 Table 9-22 radix conversions, 1364 §17.1.1.3 automatic sizing of displayed data, `$displayb/h/o` defaults, `$write` newline suppression, `$display`'s null argument and no-argument forms | `reg [7:0]`: `%b`→8 digits, `%h`→⌈8/4⌉=2, `%o`→⌈8/3⌉=3, `%d`→3 columns (largest 8-bit value 255). `8'd7` → `[  7][7][07][007][00000111]`; `8'hA5`=165 → `[165][a5][245][10100101]` (octal groups from the LSB: 101=5, 100=4, 10=2). Bare argument → default decimal `165`; `,,` → one space; `$display;` → bare newline |
| 2 | `02_display_unknown_radix.v` | 1364 §17.1.1.4 whole-group collapse of x/z inside `%h`/`%o` | `8'b1010xxxx` → `%h ax`, `%o 2Xx` (LSB group `xxx`→`x`, next `1,0,x` MIXED→uppercase `X`, top partial 2-bit group `10`→`2`). `8'bzzzz0011` → `%h z3`, `%o zZ3`. `8'bxxxxxxxx` → `xx`, `xxx`, `%d`→`  x`. The partial top octal group is the off-by-one a MSB-first grouper fails |
| 3 | `03_strobe_scheduling.v` | §9.4.1 `$strobe` "when the simulator has converged", i.e. end-of-time-step SAMPLING, plus two strobes in one step | t=0: `display 0001`, `after 0100`, then after the NBA region `strobe 0010` — the strobe prints third and reports the value neither `$display` saw. t=1: both `s1 1001` and `s2 1001`, call order, settled value |
| 4 | `04_monitor.v` | §9.4.1 monitor mechanism (change-triggered, one line for simultaneous changes, silent on no change) + 1364 §17.1 `$monitoroff`/`$monitoron` and single-active-monitor replacement | 7 lines for 10 steps: setup `mon a=0 b=0`; `mon a=1 b=0`; one line `mon a=2 b=2` for two simultaneous changes; nothing at t=3 (2→2 is not a change); nothing at t=4 (off); `mon a=3 b=2` from `$monitoron`'s resume checkpoint; `mon a=4 b=2`; then the replacement monitor's `new a=4` and `new a=5` with the old format gone |
| 5 | `05_time_queries.v` | §9.10 / 1364 §17.7 scaling of `$time`/`$stime`/`$realtime` to the local time UNIT, and the 64-bit return width | `timescale 10ns/1ns`, so one unit is 10 scheduler ticks. After `#3` and `#4`: `3` and `7`, **not** 30 and 70. `cap = $time` into `reg [63:0]` → 61 zeros then `111`. `$time + 1` → `8` |
| 6 | `06_time_rounding.v` | 1364 §17.7 sub-unit rounding: `$time` is round-to-nearest with exact halves away from zero (§§4.8/4.8.2 as recorded in `docs/digital-time.md`) | `timescale 10ns/100ps`: at 5ns `$time`=1, `$realtime`=0.5; at 15ns `$time`=2, `$realtime`=1.5; at 20ns `$time`=2, `$realtime`=2. The repeated `2` at two different instants is the assertion. **Also blocked on real procedural delays** |
| 7 | `07_timeformat.v` | §9.6 / 1364 §17.3 `$timeformat` and `%t` converting from the scope's unit into the `units_number` scale | `timescale 10ns/1ns`, `$time`=3 after `#3` ⇒ 30ns. `(-9,0,"",0)`→`30`; `(-9,2,"",10)`→`     30.00` (5 chars right-justified in 10); `(-9,2," ns",0)`→`30.00 ns`; `(-6,3,"",0)`→`0.030`; `(-12,0,"",0)`→`30000`; `%t` of the literal `1` → `10` (one unit = 10ns) |
| 8 | `08_readmemh.v` + `.hex` | 1364 §17.2.9 default start address, `@` relocation, line and block comments, untouched addresses stay X | `reg [7:0] m [0:7]`, file `1a 2b / @4 / c3 / d4` ⇒ `1a 2b xx xx c3 d4 xx xx`. All four data words contain a hex letter so a decimal parse cannot agree |
| 9 | `09_readmemb_range.v` + `.bin` | 1364 §17.2.9 four-argument range form with start > finish (descending load), and x/z data digits | `$readmemb(f, m, 5, 2)` with words `0001 0010 x1z0 1111` loads m[5],m[4],m[3],m[2] in that order; printed ascending m[1]..m[6] ⇒ `xxxx 1111 x1z0 0010 0001 xxxx`, the reverse of the file order |
| 10 | `10_clog2.v` | 1364 §17.11 `$clog2` reached from a digital expression, and its digital typing | `0 0 1 2 10 10 11` for arguments 0,1,2,3,1000,1024,1025 (2⁹=512<1000≤1024=2¹⁰; an exact power does not round up; 1024<1025≤2048). `$clog2(255)`=8 into `reg [7:0]` → `00001000` |
| 11 | `11_vcd_dumpvars.v` + `.expected.vcd` | 1364 §18.1 `$dumpfile`/`$dumpvars(0, scope)`, §18.2 header, `$var` records with bit range, identifier codes, scalar vs vector encodings, leading-zero suppression, `#time` records, one record per settled step | `$timescale 1ns`; `a`→`!`, `v [3:0]`→`"`. `#0 $dumpvars 0! b0 " $end` (the SETTLED values, not the X held when `$dumpvars` ran); `#1 1!`; `#2 b1010 "`; `#3 x! bz01x "`. `4'b0000`→`b0`, `4'bz01x` keeps all four characters. File ends after `#3` — `$finish` flushes the step |
| 12 | `12_vcd_dumpoff_on.v` + `.expected.vcd` | 1364 §18.1 `$dumpoff` all-x checkpoint, `$dumpon` current-value resume checkpoint, `$dumpall` unconditional checkpoint | one scalar `a`→`!`. File sequence `0, 1, x(checkpoint), ⟨no #3 at all⟩, 0(resume), 1, 1(dumpall)` against the variable's actual `0,1,1,0,0,1,1`. The `$dumpon` record is `0!` — the value written while dumping was off, not the `1` last visible in the file |
| R1 | `90_dumpfile_twice_rejected.v` | 1364 §18.1 — at most one `$dumpfile` per simulation | refusal, `//! reject called more than once`; the module is otherwise minimal so a diagnostic for any other reason is the wrong fix |
| R2 | `91_readmem_overflow_rejected.v` + `.hex` | 1364 §17.2.9 — more data than the load range holds is diagnosed | refusal, `//! reject more data than the load range`; FIVE words into `reg [7:0] m [0:3]`, i.e. 5 − 4 = overflow by exactly one word past a four-address range |

12 positive, 2 refusals.

### The two refusals: what the bare `//! reject` was worth

Both refusals carried a bare `//! reject` until the review. `tests/torture.zig:223`
returns true for **any** diagnostic, and both files produce one today — for the
feature being absent, not for the rule they cite. So both "passed" vacuously.
Each now names a substring that today's message does **not** contain; note that
`DiagnosticsReported`, `E1100` and the task name itself would all still match the
not-implemented message and are therefore not usable here. When the two rows land
and the messages get catalogue codes, replace the substrings with the codes —
that is the stronger form and the repo's majority convention.

### Verified failure mode today

Captured, not typed: this block is the stdout of

```sh
cd /home/omare/Documents/Projects/Zig/VerA/tests/pending/D09
V=/home/omare/Documents/Projects/Zig/VerA/zig-out/bin/vera
for f in *.v; do out=$("$V" --run "$f" 2>&1); rc=$?
  printf '%-31s exit=%d  %s\n' "$f" "$rc" \
    "$(printf '%s' "$out" | head -1 | sed 's/^error\[E1100\]: digital source execution failed: //')"
done
```

at `45b505d` (the `error[E1100]: digital source execution failed: ` prefix is on
every line and is stripped by the `sed` above). All fourteen fail, each at the
intended construct, none at parse time, and **none of the fourteen passes**:

```
01_display_radix.v              exit=1  only %b and %% display conversions are implemented
02_display_unknown_radix.v      exit=1  only %b and %% display conversions are implemented
03_strobe_scheduling.v          exit=1  digital system task `$strobe` is not implemented
04_monitor.v                    exit=1  digital system task `$monitor` is not implemented
05_time_queries.v               exit=1  only %b and %% display conversions are implemented
06_time_rounding.v              exit=1  this digital expression form is not implemented
07_timeformat.v                 exit=1  digital system task `$timeformat` is not implemented
08_readmemh.v                   exit=1  digital system task `$readmemh` is not implemented
09_readmemb_range.v             exit=1  digital system task `$readmemb` is not implemented
10_clog2.v                      exit=1  only %b and %% display conversions are implemented
11_vcd_dumpvars.v               exit=1  digital system task `$dumpfile` is not implemented
12_vcd_dumpoff_on.v             exit=1  digital system task `$dumpfile` is not implemented
90_dumpfile_twice_rejected.v    exit=1  digital system task `$dumpfile` is not implemented
91_readmem_overflow_rejected.v  exit=1  digital system task `$readmemh` is not implemented
```

(06 fails on `#0.5`, the real procedural delay, exactly as the file's header
says.) The two `exit=1` lines for 90 and 91 are the whole of the refusal defect
above: a diagnostic exists, so a bare `//! reject` was satisfied by it.

Notably the GRAMMAR already accepts everything used here: `$displayh`,
`$monitoroff`, `$dumpvars(0, scope)`, the four-argument `$readmemb`, the null
argument `$display("[", , "]")` and the bare `$display;`. The row is a runtime
row, not a parser row.

## Conventions these fixtures fix, which the standard leaves open

Two, both confined to the VCD goldens, both restated in the fixture headers:

1. **Identifier codes** are assigned sequentially from `!` (ASCII 33) in `$var`
   declaration order. §18.2 requires printable-ASCII codes but does not choose
   them. A conforming writer that picks differently would need the goldens
   regenerated; nothing else in them would change.
2. **Comparison is after normalisation**: delete the `$date`, `$version` and
   `$comment` sections wherever they occur and however they are broken across
   lines, and remove the whitespace inside the `$timescale` body so that a
   writer emitting `1 ns` and one emitting `1ns` both normalise to
   `$timescale 1ns $end`. Every other byte is compared exactly. This is the
   smallest normaliser that removes the non-deterministic parts of a VCD file.
   The command under "Build / run" implements exactly this and no more — it is
   token-based, because a VCD header command is not required to be one per line
   and a line-oriented `sed '/^\$date/,/^\$end/d'` deletes nothing when
   `$date … $end` is on one line, and deletes past the section when it is not
   anchored. The earlier `sed` in this document had both bugs and did not delete
   `$comment` at all.

Everything else in the goldens — record kinds, record order, value encodings,
timestamps, the one-record-per-settled-step rule — is normative.

## Deliberately NOT covered by these fixtures

* **`%s` numeric behaviour** (§9.4.5 right-justification, leading-zero
  suppression, embedded bytes). The plan assigns this to row **S01**, not D09.
  Left there to avoid two rows owning one expectation.
* **`%r` engineering notation** (§9.4.7 + Table 9-23 + §2.6.2 Table 2-1). This
  is a genuine gap on BOTH sides — `lib/backend/cg_display.zig:673` maps `'r'`
  to a plain `{d}` and its own comment says "§9.4.3's engineering-notation `%r`
  scale suffix is NOT reproduced". It is not fixtured because §2.6.2 gives the
  input spellings (`K` and `k` both mean 1e3) without fixing the OUTPUT
  spelling, the digit count or the behaviour outside 1e-18…1e12, so no exact
  byte string is derivable from the text. It needs a written interpretation
  first, in the style of `docs/digital-time.md`'s rounding note. **Fixture this
  only after that interpretation exists.**
* **Mixed known/unknown `%d`.** `02_display_unknown_radix.v` exercises `%d`
  only on an entirely-unknown operand, where the answer is unambiguously `x`.
  The uppercase `X` spelling for a partially-unknown decimal operand is left to
  the implementation phase rather than guessed at.
* **`$printtimescale` banner text.** Table 9-3 lists it and §9.6 inherits it,
  but its exact transcript format is not derivable from the offline text, so it
  is specified below instead of fixtured.
* **`$finish(1)` / `$finish(2)` transcripts.** §9.7.1 Table 9-25 gives the
  three verbosity levels ("Prints nothing" / "simulation time and location" /
  "…and statistics about the memory and CPU time"), and the runner already
  implements 0 and 1 (`docs/digital-source-execution.md`). Level 2's statistics
  text is host- and run-dependent and cannot be a byte golden.
* **`$stime`'s 32-bit truncation.** Observing the low-32-bit wrap requires
  advancing past 2³² time units, which no bounded fixture can do. Pin it with a
  unit test on the conversion helper instead.
* **Multi-scope `$time` scaling and VCD `$scope`/`$upscope` nesting.** The
  runner executes exactly one portless module, so a second timescale or a
  nested instance is unreachable. Blocked on **D07**.
* **Extended VCD (§§18.3-18.4, `$dumpports…`).** Its strength encoding needs
  drive strengths, which the plan marks as the open part of **D03**. Nothing
  here touches it.
* **File I/O (§9.5.1-9.5.8 in the digital context), `$sdf_annotate` (§17.2.10),
  `$random`/`$dist_*` digital streams (§17.9), plusargs (§9.12), digital real
  math (§9.14 beyond `$clog2`), `$itor`/`$rtoi` (§9.11).** All open; the plan
  splits file I/O and format-conversion auditing into row **S01**, and the
  distribution row has its own reference-sequence requirements
  (`docs/RNG-REFERENCE-LIMITS.md`).

## Specified, not fixtured — the rest of the D09 inventory

These are the items the row owns that cannot be fixtured usefully yet, with
what a fixture would have to assert once the blocking work lands.

### Specify blocks, path delays, timing checks (plan line 223)

Status: **not even parsed.** `specparam` inside a module is rejected at parse
time with `E0205 unsupported module item: found specparam` (verified). There is
no `specify`, `endspecify`, `$setup`, `$hold`, `$width`, `$recovery` or `$skew`
anywhere in `src/`.

Order of work, and what each step must be able to assert:

1. **Grammar** — `specify_block` (A.7.1), `specparam_declaration` with
   `PATHPULSE$` specparams, `path_declaration` in its simple, edge-sensitive
   and state-dependent forms, `system_timing_check` (A.7.5).
2. **Specparams** — scope is the specify block (plus module-level specparams);
   they are overridable by SDF and by `defparam`-like annotation but not usable
   as ordinary parameters in non-specify contexts. First fixture: a specparam
   feeding a path delay, asserted by the observed output transition time.
3. **Path delays** — `(a => y)` parallel vs `(a *> y)` full connection; 1, 2, 3,
   6 and 12 delay-value lists and how they map onto 0→1, 1→0, 0→z, z→1, 1→z,
   z→0 transitions; `ifnone`; the §14.3.1 **negative-path-delay-clamps-to-zero**
   rule, which `src/sim/time.zig` already implements as `pathSignedDelay` and
   which `docs/digital-time.md` already distinguishes from the §9.7.1
   procedural rule. A path delay must OVERRIDE the primitive's own delay, so a
   fixture needs a gate with a distinct intrinsic delay and must observe the
   path value winning. **Blocked on D08** (gate primitives).
4. **Timing checks** — `$setup`, `$hold`, `$setuphold`, `$recovery`,
   `$removal`, `$recrem`, `$skew`, `$timeskew`, `$fullskew`, `$width`,
   `$period`, `$nochange`. Each needs a violation and a non-violation case at
   the exact boundary (a check with limit `n` must not fire at separation `n`
   and must fire at `n-1`), plus the **notifier** argument: a violation toggles
   the notifier reg, which is the only machine-readable evidence a fixture can
   assert without depending on warning text. Notifier toggling is the right
   first assertion for this whole sub-row.
5. **`$sdf_annotate` (§17.2.10, Table 9-2 digital-only)** last, since it
   annotates the structures items 2-4 create.

### 17.5 — PLA modelling tasks (§9.8: AMS "does not extend" them)

Sixteen names, the full cross product of `$async`/`$sync` × `$and`/`$nand`/
`$or`/`$nor` × `$array`/`$plane`, all listed in Table 9-5 as digital-only and
all already present in `lib/ir/lower.zig:6832-6837` as analog-context refusals.
Note the lexical point that file already makes: the embedded `$` is an ordinary
identifier character (§2.8.3), so `$async$and$array` is ONE token — the lexer
must not split it.

What a fixture must assert:

* The personality is read from a memory with `$readmemb`, so this sub-row is
  **downstream of fixture 09** here. `$array` takes the personality as a
  memory; `$plane` takes it as an array of the same shape but with the
  complementary interpretation of a `0` entry.
* `$and`/`$or` are the AND-plane/OR-plane logic and `$nand`/`$nor` invert the
  output; a fixture needs one personality and all four logic spellings against
  it so the inversion is isolated.
* `$async` recomputes whenever an input or the personality changes; `$sync`
  recomputes only when the task is re-invoked. The distinguishing fixture is:
  drive an input, observe the async outputs move and the sync outputs hold,
  then re-invoke and observe them catch up.
* Four-state inputs: an x on an input that is a don't-care for a given product
  term must not make that term x.

Two fixtures suffice for the row's semantics (one async/one sync, each printing
all four logic variants over one personality); sixteen would be a combinatorial
dump.

### 17.6 — Stochastic analysis queues (§9.9: AMS "does not extend" them)

`$q_initialize`, `$q_add`, `$q_remove`, `$q_exam`, `$q_full`; Table 9-6, all
digital-only, all present in `lib/ir/lower.zig:6840-6842` as refusals only.

What a fixture must assert:

* `$q_initialize(q_id, q_type, max_length, status)` — `q_type` 1 = FIFO,
  2 = LIFO. The discipline is the first thing to pin: add 1, 2, 3 then remove
  three times gives `1, 2, 3` for FIFO and `3, 2, 1` for LIFO. That is a pure
  hand-derived integer sequence and is the single best fixture in this
  sub-row.
* `status` is an output code: 0 on success, and distinct nonzero codes for
  "queue full", "undefined q_id", "queue empty" and "unsupported q_type" or an
  out-of-range length. A fixture must assert the exact codes, so the code table
  has to be read out of the inherited text first — it is not in the AMS LRM.
* `$q_full(q_id, status)` returns 0/1 for room/no room; filling a queue to
  `max_length` and then adding once more must both set `$q_full` and produce
  the full status from `$q_add`, without silently growing the queue.
* `$q_exam(q_id, q_stat_code, q_stat_value, status)` reports the statistics
  (current length, mean inter-arrival time, maximum length, shortest and
  longest wait, average wait, total queued). The time-based statistics need the
  simulation clock and therefore compose with fixture 05's `$time` work; the
  count-based ones (current length, maximum length, total queued) are
  hand-derivable today and should be fixtured first.

### 17.10-17.11 — command-line input and math

* **`$test$plusargs(str)` / `$value$plusargs(fmt, var)`** (§9.12, Table 9-9,
  both contexts "Yes"). These are the only D09 items that need HOST input: the
  fixture is not self-contained, it is a pair of (argv, expected stdout). The
  runner currently has no way to pass plusargs to a `--run` program, so the
  first piece of work is a CLI surface for them, and the fixture harness must
  grow an "extra arguments" field. What to assert: `$test$plusargs` matches a
  PREFIX of a supplied `+arg` and returns 0/1; `$value$plusargs("N=%d", n)`
  matches the prefix `N=`, converts the remainder by the given format, writes
  `n` **only on a match**, and returns 0 leaving `n` untouched on no match.
  That last clause (no write on failure) is the one implementations get wrong.
* **`$clog2`** is fixtured (10).
* **Real math functions in the digital context** (§9.14 Table 9-11: `$ln`,
  `$log10`, `$exp`, `$sqrt`, `$pow`, `$floor`, `$ceil`, the trig and hyperbolic
  families, `$min`, `$max`, `$abs`, `$hypot`, `$atan2`). Every one of these is
  already implemented and fixtured on the ANALOG side under
  `tests/fixtures/ch09_system_tasks/`. The digital row is about **typing**, not
  about the numerics: integer arguments must convert to real (§4.2.1.2), the
  result is a real that an integral assignment converts back by §4.2.1.1
  rounding, and `$min`/`$max`/`$abs` are the three that take the type of their
  arguments rather than always producing a real. The right fixture is small:
  one file asserting `$min(3, 4)` is the INTEGER 3 while `$min(3.0, 4)` is the
  real 3.0, and `$rtoi($sqrt(2.0)*$sqrt(2.0))` round-trips, rather than
  re-testing the numerics the analog fixtures already cover. Blocked on digital
  `real` variables, which the runner does not declare today.

## Build / run

Nothing here is wired into `build.zig` yet, and nothing under `tests/fixtures/`
was touched, so `zig build torture -- --strict` stays at 1323/1323.

Manual, from this directory (the two `$readmem` fixtures resolve their data
files relative to the working directory):

```sh
cd /home/omare/Documents/Projects/Zig/VerA/tests/pending/D09
V=/home/omare/Documents/Projects/Zig/VerA/zig-out/bin/vera

# transcript fixtures
for f in 01 02 03 04 05 06 07 08 09 10; do
  n=$(echo "$f"*.v); n=${n%.v}
  "$V" --run "$n.v" | diff -u "$n.expected.txt" - || echo "FAIL $n"
done

# VCD normaliser — the "Conventions" rule, and nothing else. Token-based, so it
# is indifferent to whether a header command occupies one line or five.
# (Verified against gawk 5.4.0 on $date/$version/$comment written both ways.)
vcdnorm() {
  awk '
  BEGIN { RS = "\x01" }                      # one record = the whole file
  {
    s = $0; out = ""
    while (match(s, /\$date|\$version|\$comment|\$timescale/)) {
      kw = substr(s, RSTART, RLENGTH)
      head = substr(s, 1, RSTART - 1)
      rest = substr(s, RSTART + RLENGTH)
      e = index(rest, "$end")
      if (e == 0) { out = out head kw; s = rest; continue }
      body = substr(rest, 1, e - 1)
      s = substr(rest, e + 4)
      if (kw == "$timescale") {
        gsub(/[ \t\r\n]+/, "", body)
        out = out head "$timescale " body " $end"
      } else {
        sub(/[ \t]*$/, "", head)             # drop the indent the section sat on
        out = out head
        sub(/^[ \t]*\r?\n/, "", s)           # and the newline its $end ended
      }
    }
    printf "%s", out s
  }' "$1"
}

# VCD fixtures: run, then normalise and diff
"$V" --run 11_vcd_dumpvars.v && \
  vcdnorm d09_vcd.vcd | diff -u 11_vcd_dumpvars.expected.vcd -
"$V" --run 12_vcd_dumpoff_on.v && \
  vcdnorm d09_vcd_off.vcd | diff -u 12_vcd_dumpoff_on.expected.vcd -

# refusals: must exit nonzero AND the message must contain the substring the
# fixture's `//! reject` names — exiting nonzero alone is what the bare form
# accepted, and today's not-implemented message satisfies that.
"$V" --run 90_dumpfile_twice_rejected.v 2>&1 \
  | grep -q 'called more than once' || echo "FAIL 90 wrong or no diagnostic"
"$V" --run 91_readmem_overflow_rejected.v 2>&1 \
  | grep -q 'more data than the load range' || echo "FAIL 91 wrong or no diagnostic"
```

The whole block above was run at `45b505d`: it executes, every positive fixture
reports its FAIL line, and the two refusals now report `FAIL 9N wrong or no
diagnostic` instead of passing on the not-implemented message.

`vcdnorm` was checked against a hand-written VCD carrying a **multi-line**
`$date`, a **single-line** `$version`, a single-line `$comment`, and a
`$timescale` written as `$timescale\n  1 ns\n$end` — the three shapes the old
`sed` got wrong. Normalising it reproduces `11_vcd_dumpvars.expected.vcd` byte
for byte (`diff -u` silent, exit 0). That is the evidence for convention 2; the
golden was not edited to make it agree.

When wired up, the transcript fixtures follow the existing
`build.zig:143-163` pattern verbatim — `addFileArg` plus
`expectStdOutEqual(@embedFile(...))` — and the files move to `tests/digital/`
alongside `scheduling.v`. The two VCD fixtures need one new thing the build
does not have: a step that runs the program in a temporary working directory
and diffs a produced FILE rather than stdout, with the `vcdnorm` normalisation
above. The two refusals need the negative form (`expectExitCode` plus a stderr
substring), which `tests/torture.zig` already has an analogue of for
`//! reject` analog fixtures — and they need it to check the SUBSTRING, not
merely the exit code.

## Corrected after review

The adversarial review of `tests/pending/MANIFEST.md` attributed four findings to
D09 (§5.2 Class B, §5.4 Class D, §5.6 reproduction, and the general rule that a
bare `//! reject` is worthless). All are actioned here; nothing outside
`tests/pending/D09/` was touched.

1. **Six miscited inherited clauses (§5.2).** Fixed in the fixture headers, in
   the `//!` directives, and in this document's clause table:
   * `01_display_radix.v` — field sizing is §**17.1.1.3** ("automatic sizing of
     displayed data", `docs/CLAUSE-AUDIT.md:275`), not §17.1.1.2, which is
     "format specifications" (:274). Two places in the file.
   * `02_display_unknown_radix.v` — the x/z group collapse is §**17.1.1.4**
     ("unknown / high-impedance display", :276), not §17.1.1.2. Two places.
   * `05_time_queries.v`, `06_time_rounding.v` — `$time`/`$stime`/`$realtime`
     are §**17.7** (:331-333), not §17.3.
   * `07_timeformat.v` — `$timeformat` is §**17.3** (:323), not §17.7. The two
     clauses were swapped throughout the row, including in this document.
   The 1364-2005 text is not in `docs/`, so none of these numbers can be checked
   by opening the clause; each is now anchored to the line of
   `docs/CLAUSE-AUDIT.md` that establishes it, and the clause table above records
   the anchor next to every number the row uses.

2. **Both refusals had a bare `//! reject` (general rule 5).** `90` now demands
   `called more than once`, `91` demands `more data than the load range`. Both
   substrings were chosen so that today's `E1100 … is not implemented` message
   does **not** contain them — which `DiagnosticsReported`, `E1100` and the task
   names all do. Each header records the required wording and says to replace it
   with the catalogue code when the row lands.

3. **The VCD normaliser did not implement its own stated convention (§5.6).**
   The old `sed '/^\$date/,/^\$end/d; /^\$version/,/^\$end/d'` deleted no
   `$comment`, collapsed no `$timescale` whitespace, and — being line-oriented
   and anchored — deletes nothing when `$date … $end` lands on one line, while
   over-deleting when the section is not line-anchored. Replaced with the
   token-based `vcdnorm` above, which does exactly what convention 2 says and is
   checked against the golden. Convention 2 itself is now slightly stronger:
   the `$timescale` body has its whitespace **removed** rather than collapsed,
   so `1 ns` and `1ns` both normalise to the golden's `$timescale 1ns $end`.
   The fixture headers of 11 and 12 were updated to match.

4. **`91_readmem_overflow_rejected.hex` contradicted its own header.** The file
   held six words while the header said "one word past the end, the smallest
   overflow there is". 6 − 4 = 2. Corrected by trimming the file to five words
   (`11 22 33 44 55`), 5 − 4 = 1, which makes the header true and the fixture
   strictly harder — a coarse count check must still catch a one-word overflow.
   Separately, that fixture's header now states plainly that 1364 §17.2.9 is not
   on disk, so the **severity** of the excess-data rule (error vs warning) cannot
   be verified here; the fixture's position, and the falsifier that would force
   it to become a stdout fixture instead of a refusal, are written into the file.

### Disagreement with one review finding

§5.4 lists D09 among the rows that "each keep one or more already-passing
fixtures, all disclosed in their SPEC.md", though it attaches no count to D09
(the counts it does give are A02 5/13, A10 8/15, H01 4/12, A01 2/11, D03 1/13,
H04 1/11, S01 2/13). For the twelve **positive** fixtures the finding is wrong,
and the captured transcript under "Verified failure mode today" is the evidence:
all twelve exit 1 at their intended construct at `45b505d`. Zero pass.

The finding is right about the two **refusals**, under the reading that a bare
`//! reject` is satisfied by the not-implemented diagnostic — 90 and 91 did
"pass" today, for the absence of the feature they test. That is item 2 above and
it is now fixed. Under that reading the count for D09 is **2 of 14, both
refusals, and neither disclosed** — this document previously claimed all fourteen
fail, which was true of the compiler's behaviour and false of the fixtures'
verdicts. Both statements are now in the document.

No claim was withdrawn from this row, so nothing moved to another row. The items
D09 declines to fixture are unchanged and still listed under "Deliberately NOT
covered" (`%s` numerics → **S01**; `%r` engineering notation → needs a written
interpretation first; extended VCD §§18.3-18.4 → blocked on **D03** strengths;
multi-scope `$time` and VCD scope nesting → blocked on **D07**).
