# S01 — Formatting, strings and files

Row S01 of `/home/omare/Documents/Projects/Zig/ARPice/docs/verilog-ams-conformance-plan.md`
(lines 477-487):

> - Add numeric `%s` with correct operand width, leading-zero and embedded-byte
>   behavior through display/write/string/file variants; integer path is assigned.
> - Audit every standard format conversion, signedness, width, precision, locale
>   independence and strength/four-state formatting as digital values become usable.
> - Remove file-scanning shortcuts that consume more input than required; test
>   successive scans on one line, multiline fields, `$ftell`, EOF and failed matches.
> - Audit all file/memory read/write/seek/descriptor tasks, scratch-buffer limits,
>   per-instance isolation and errors. Test observable bytes and file positions.

13 `.va` fixtures. **12 of the 13 fail today**; exactly 1 (`07_strobe_…`) passes
and is kept as a regression pin for behaviour that is implemented and was
previously unasserted — see the note under its table row for the exact
counterfactual, so that "green" is not mistaken for "vacuous". Before the
review, 06 also passed; it no longer does, and the reason is in "Corrected after
review" below — it was passing for the wrong reason.

The reserved branch `w2/systasks` contributes nothing: it resolves to the same
commit as `ddt-capform` (`45b505d`), `git diff --stat ddt-capform...w2/systasks`
is empty and its worktree is clean. Nothing here re-specs it.

## LRM clauses covered

Read from the offline HTML in `/home/omare/Documents/Projects/Zig/VerA/docs/`.

| clause | title | file |
|---|---|---|
| §2.6.2 / Table 2-1 | Real constants — scaled symbols `T G M K,k m u n p f a` | `ch2-lexical.html` |
| §9.4.1 | Behavior of the Display Tasks in the Analog Context — the `$monitor` mechanism sentence, `$write`'s missing newline, `$debug` per iteration | `ch9-system.html` |
| §9.4.3 / Table 9-23 | Format Specifications — "the full formatting capabilities available in the C language", `%e %f %g %r` | `ch9-system.html` |
| §9.4.6 | Behavior of the Display Tasks in the Analog Block During Iterative Solving | `ch9-system.html` |
| §9.5.1 / Table 9-24 | Opening and Closing Files — the `"w"` truncation every fixture below relies on for idempotence | `ch9-system.html` |
| §9.5.2 | File Output System Tasks — `$fmonitor`/`$fstrobe` "work just like their counterparts" | `ch9-system.html` |
| §9.5.3 | Formatting Data to a String — `$sformat`, the text oracle used throughout | `ch9-system.html` |
| §9.5.4.1 | Reading a Line at a Time — `$fgets` returns "the number of characters read" | `ch9-system.html` |
| §9.5.4.2 | Reading Formatted Data — the conversion table, field definition, left-unread rule, 0-vs-EOF | `ch9-system.html` |
| §9.5.5 | File Positioning — `$ftell` | `ch9-system.html` |
| §9.5.8 | Detecting EOF — `$feof` | `ch9-system.html` |
| §9.5.9 | Behavior of the File I/O Tasks During Iterative Solving | `ch9-system.html` |

Cited inside headers but not pinned on their own: §3.3 (`string` is not a
fixed-width type), §4.2.1.1 (real→integer rounding for `%d`), §4.2.5 (a
comparison is an integer, which is why every verdict is an operand and not a
branch). C11 7.21.6.1 is quoted where §9.4.3 makes it normative.

## Ground truth established before writing (source, not COVERAGE.md)

Everything below was confirmed by reading `src/` and by running the fixture, not
by reading a doc.

**Implemented and correct** (so not re-specified, except where a fixture pins it
anyway as a control): the whole `%h %o %b %c %d %s %e %m %l` conversion set for
analog operands; C width/precision/flags on `%e`; `%-w.pf` left justification;
`%08h` zero fill on a radix conversion; `%s` numeric-operand width and
leading-zero behaviour (already pinned by
`tests/fixtures/ch09_system_tasks/188_numeric_string*.va` — the plan's first
bullet is **done**, contrary to the row text); the §9.5.1 mcd/fd bit encodings;
`$ftell`/`$fseek`/`$rewind`/`$feof`/`$ferror`/`$fflush`/`$fclose`; `$sscanf` with
`%d %o %h %x %b %c %f %e %g %s`, field widths and `*` suppression.

**Not implemented.** Each is a fixture below.

1. `%g` does not choose the shorter of the two renderings —
   `src/backend/cg_display.zig` renders a real through Zig's shortest-round-trip
   formatting, so `%g` of `1e8` prints `100000000` where Table 9-23's "whichever
   format results in the shorter printed output" demands `1e+08`, five
   characters against nine. `%g` of `1e-5` prints `0.00001` for the same reason.
   **Not claimed as a defect:** `%.3g` of `1234.5678` printing `1234.568`.
   That is precision read as *fractional* digits, which is what §9.4.3's own
   worked example ("`%10.3g` sets a minimum field width of 10 with three (3)
   fractional digits") says it is, even though the preceding half-sentence makes
   C — where the precision counts *significant* digits — normative. The clause
   contradicts itself and this row does not pick a side; see "Withdrawn after
   review" below.
2. `%+f` and `% f` drop the sign character: `%+08.1f` of `2.5` prints `000002.5`.
   `%09.2f` of `-3.5` prints `0000-3.50` — the pad goes in front of the sign.
   `cg_display.PrintArg.Mode.cint` handles this for integers; there is no real
   counterpart.
3. `%f` rounds half away from zero, not half to even: `%.0f` of `2.5` prints `3`.
4. `%r` is not engineering notation at all — it renders the same as `%g`, with no
   Table 2-1 scale symbol. Table 9-23 defines it as the one conversion
   Verilog-AMS adds to C, so this is a missing feature and not a deviation.
5. `$monitor`/`$fmonitor` have **no change detection**: `Lower.isDisplayTask`
   (`src/ir/lower.zig:6146`) lists `$monitor` beside `$display`, and
   `cg_display.emitDisplayTask` gives them the same unconditional print. The
   §9.4.1 mechanism sentence — "if the variable or an expression in the argument
   list changes value compared with the last accepted step" — is not implemented
   anywhere in `src/`. There is a **second, separate** defect stacked on it, and
   fixtures 05 and 06 name both so neither is mistaken for the other: a display
   or file task under an event guard is dropped, `W0851` *"display task under a
   conditional is not emitted"* (captured from `--run`; under `--check`, where
   there is no host file table at all, the same two calls are dropped under
   `W0850` instead). §5.10.2 makes `@(initial_step)` a legal place for `$fopen`
   and `$fmonitor`, and registering the monitor **exactly once** is the only way
   to measure a cross-step obligation, so W0851 has to be lifted before the
   §9.4.1 mechanism can be observed by any fixture at all. Today both fixtures
   read `$ftell` on an unassigned `fd`, which returns −1.
6. `$fscanf` **consumes a whole line per call**. `file_kernels.zFRead` is
   literally `zFLine(zFGets(d), d)`, and its own comment names the shortcut: "a
   LINE is consumed, where C's `fscanf` consumes only what the format matched".
   Consequences, all measured: `$ftell` after `%d` on `"12 34\n"` is 6 instead of
   2; the second scan skips `34` and returns `56`; a control string with two
   directives cannot span two lines; a failed match moves the position to the end
   of the line instead of leaving the offending character unread.
7. `$fscanf` with a **real destination emits a device that does not compile** —
   `@floatFromInt(zScanR(...))` where `zScanR` already returns `f64`. The
   `$sscanf` form of the same conversion is fine, so the defect is in the
   `$fscanf` lowering alone. This is a hard failure, not a wrong number.
8. `%r` and `%m` are **refused** in `$sscanf`/`$fscanf` by `E0813`, whose own
   note enumerates "§9.5.4.2's codes are %d %o %h %x %b %c %f %e %g %s" — a set
   that drops two rows the LRM table has and adds `%o %h %x %b` which it does not.
   (The extra radix codes are harmless and are not made an issue here.)
9. **Scratch-buffer ceilings of 512 bytes**, both documented in-source as
   shortcuts rather than as anything a clause states:
   `str_kernels.zSBuf` (one `[512]u8` per `$sformat`/`$swrite`/`$fdisplay` call
   site) makes a longer record format to the EMPTY string, so a 601-byte
   `$fdisplay` writes **zero** bytes; `file_kernels.ZFSlot.line` (`[512]u8`)
   makes `$fgets` of a 600-byte line return 512 and leave the tail behind.

## Fixtures

Ordered; "today" is the observed verdict of the run command at the bottom.

| fixture | pins | expected value and derivation | today |
|---|---|---|---|
| `01_real_g_conversion_is_significant_digits.va` | §9.4.3 "the full formatting capabilities available in the C language" **and** Table 9-23's "whichever format results in the shorter printed output", for `%g` **with no precision field**. | Four strings, each derived twice — once from C and once from Table 9-23's shorter-output rule — with the two derivations agreeing, which is the condition for asserting a row at all. With `P` the precision (default 6) and `X` the `%e` exponent: `P > X >= -4` selects `%f` with precision `P-1-X`, else `%e` with precision `P-1`, then trailing zeros are stripped. `%g` 1234.5678 → `1234.57` (X=3; 7 chars vs 12); 1e-5 → `1e-05` (X=-5; 5 vs 7); 1e8 → `1e+08` (X=8; 5 vs 9); 1.23456789e-4 → `0.000123457` (X=-4, the boundary; 11 vs 12). The two **explicit-precision** rows that were here are withdrawn — see "Withdrawn after review". | **fail**, all four (measured: VerA prints `1234.5678`, `0.00001`, `100000000`, `0.000123456789`) |
| `02_real_flags_sign_before_zero_fill.va` | §9.4.3 + C11 7.21.6.1p6 flag characters `+`, ` `, `0`, `-`. | `%+08.1f` 2.5 → `+00002.5` (sign first, then four pad zeros); `% .2f` 1.0 → `" 1.00"`; `%09.2f` -3.5 → `-00003.50`; `%-9.2f\|` -3.5 → `-3.50    \|` (control). | **fail** on the first three; the control passes |
| `03_real_conversion_rounds_half_to_even.va` | §9.4.3 + C11 7.21.6.1p13 "correctly rounded", i.e. IEEE 754 roundTiesToEven. | Five exact ties: `%.0f` of 2.5→`2`, 3.5→`4`, 0.5→`0`, 1.5→`2`; `%.1f` of 0.25→`0.2`. 2.5 and 3.5 are written as a pair because round-half-away gets 3.5 right and 2.5 wrong. | **fail** on 2.5, 0.5 and 0.25; 3.5 and 1.5 pass by coincidence, which is the point of the pair |
| `04_real_engineering_notation.va` | Table 9-23 `%r`/`%R` "engineering notation, using the scale factors defined in 2.6.2" + Table 2-1. | Mantissa in [1,1000) and exponent a multiple of three, so each magnitude has one answer: 0.0015 → mantissa 1.5, symbol `m` (109); 1.5e6 → 1.5, `M` (77); 2e-13 → 200, `f` (102) — *not* 0.2p. The text is scanned back with `%f%c` rather than string-compared, because the mantissa's digit count is not fixed by any clause. 1e3 is avoided as an operand: Table 2-1 spells that row "K, k" and the LRM never says which an output prints. | **fail**, all nine claims |
| `05_monitor_suppresses_an_unchanged_step.va` | §9.4.1 "for each accepted step, IF the variable or an expression in the argument list changes value compared with the last accepted step … the entire argument list is displayed **at the end of the time step**". | Measured **across** steps, not inline — see "Corrected after review". `$fopen`/`$fmonitor` run once under §5.10.2's `@(initial_step)`; `$ftell` at the *top* of step k is what the monitor wrote at the ends of steps 0..k−1. `//! wave V(p) = 0.5` held over four times, monitored `4*V(p,n)` = 2 at every step, record `"2\n"` = 2 bytes, so `$ftell` reads 0, 2, 2, 2 and `bytes - 2*($abstime > 0) == 0` on all four rows. An unconditional printer leaves 0,2,4,6 → 0,0,2,4; a printer that never reports leaves 0,0,0,0 → 0,−2,−2,−2. One file, both directions. | **fail**, all four rows (measured −1, −3, −3, −3: `W0851` drops the guarded `$fopen`, so `$ftell(fd)` is `$ftell(0)` = −1) |
| `06_monitor_reports_every_change.va` | The other half of the same sentence — "for each accepted step" is a per-step obligation — plus the record's **content**. | Same cross-step measurement as 05. `//! wave V(p) = 0.25, 2.5, 25.0, 250.0` (all dyadic-exact, as are their products with 4), monitored `4*V(p,n)` = 1, 10, 100, 1000 — four records of **deliberately different lengths** 2, 3, 4, 5 bytes, so the running total is a function of the values and not merely a count of records. `$ftell` reads 0, 2, 5, 9 = (t²+3t)/2, written as `2*bytes - ($abstime² + 3*$abstime) == 0`. Never reports → 0,−4,−10,−18; reports once then stops → 0,0,−6,−14; reports every step with a fixed 2-byte record → 0,0,−2,−6; per-iteration → positive at every t>0. | **fail**, all four rows (measured −2, −6, −12, −20). It passed before the review and should not have — see "Corrected after review" |
| `07_strobe_writes_once_per_accepted_solution.va` | §9.4.6 "All display tasks, except `$debug`, shall not display output unless an iteration has been accepted" and §9.5.9's file form. | `//! solve` on an exponential junction driven by 1 mA. At V=0, f(0) = −1e−3 A and f′(0) = Is/Vt + Gmin = 3.861e−13 + 1e−12 = 1.386e−12 S, so the first Newton correction is −f/f′ = **+7.22e8 V** — upward, nine orders of magnitude past a root near 0.656 V. No conforming solver lands in one iteration. `$fstrobe(fd,"s")` must still leave exactly 2 bytes. **Counterfactual:** one record per Newton iteration reads 2N with N ≥ 2, in practice tens of bytes; no record at all reads 0. | **pass** — kept as the regression pin for the one thing in this row VerA already gets right, and as the positive control for the `$debug` row below |
| `08_fscanf_successive_scans_on_one_line.va` | §9.5.4.2 field definition, "trailing white space (including newline characters) is left unread", the EOF case; §9.5.5 `$ftell`; §9.5.8 `$feof`. | File `"12 34\n56\n"` (9 bytes). Four `%d` scans: (1,12,pos 2), (1,34,pos 5), (1,56,pos 8, `$feof`=0), (EOF, pos 9, `$feof` nonzero). EOF is asserted as "negative" because §9.5.5/§9.5.4.2 delegate its value to IEEE 1364; every position is fixed by the byte layout. | **fail** — reads 12 then *56*, positions 6/9/9 |
| `09_fscanf_directive_spans_lines.va` | §9.5.4.2 "White space characters (spaces, tabs, NEWLINES, or formfeeds) … cause input to be read up to the next nonwhite space character"; "an ordinary character (not %) that must match the next character of the input stream". | `"12\n34\n"` scanned with `"%d %d"` → code 2, a=12, b=34, position 5. Control: `"7,8\n"` with `"%d,%d"` → code 2, `x+10*y`=87, position 3 — a delimiter-splitting reader passes this one and fails the first. | **fail** on the multiline half and on the comma case's position |
| `10_fscanf_failed_match_leaves_input.va` | §9.5.4.2 "the offending input character is left unread in the input stream" and 0-vs-EOF; §9.5.4.1 `$fgets`. | `"abc\n"`: `%d` → code 0 and `$ftell` **0**; `$fgets` then returns 4 and the string is `"abc\n"`; only the following `%s` is EOF. Pins that a failed scan is recoverable, which is the property the line-consuming shortcut destroys. | **fail** — position 4 after the failed scan, so the `$fgets` reads nothing |
| `11_fscanf_real_destination.va` | §9.5.4.2 "if the destination is a real…", i.e. a real destination is legal; the `f, e, or g` row's number grammar. | `"5.5 -2.25e2 7\n"` with `"%f %f %d"` → code 3, 5.5, -225.0 (both dyadic, so exact equality), 7. | **fail — the generated device does not compile** (`expected integer type, found 'f64'`) |
| `12_sscanf_engineering_and_path_codes.va` | §9.5.4.2's `r` and `m` conversion codes; §2.6.2 Table 2-1 as the alphabet `%r` accepts. | `"1.5m"`→0.0015, `"2.5K"`→2500 exactly (Table 2-1 spells 1e3 "K, k", so an *input* scanner must take both), `"-3n"`→-3e-9, `"4"`→4.0 (a scale symbol is optional), each returning 1. For `%m`: `"42"` with `"%m%d"` leaves 42 in the integer destination, because the code "does not read data from the input file or str argument". The path *string* is not compared to a literal — no clause fixes its spelling for a top-level module. | **fail — refused at compile time**, `E0813` five times |
| `13_long_record_is_not_truncated.va` | §9.4.3/C field width, §9.5.2, §9.5.4.1 "the number of characters read is returned in code", §9.5.5. | `$fdisplay(fd,"%600.2f",3.5)` → 596 spaces + `3.50` + newline = **601** bytes; `$fgets` of it returns 601 and leaves position 601. Second half: a 600-byte line assembled from seven `$fwrite` calls (5×100 + 99 + newline) must read back as 600 — so the read ceiling is still exercised if only the write ceiling gets fixed. | **fail** — the 601-byte write produces a **0-byte** file; the 600-byte read returns 512 |

Reject fixtures: **none**. Nothing in this row is illegal source; every gap is a
missing or wrong behaviour, so every fixture is positive. (No `//! reject` file
means no bare-`//! reject` exposure: `tests/torture.zig:223` passes on any
diagnostic, and this row asks the runner nothing of the kind.)

## Corrected after review

Three findings were raised against this row. All three are accepted; none is
re-litigated here, and nothing in `src/`, `build.zig` or `tests/fixtures/` was
touched to make any of them go away.

1. **Fixture 01 asserted C `%g` against §9.4.3's own worked example.** The
   clause contradicts itself in one sentence: "the full formatting capabilities
   available in the C language" makes C normative (C11 7.21.6.1p8 — the `%g`
   precision counts **significant** digits), and then the very next clause of the
   same sentence says `%10.3g` is "a minimum field width of 10 with three (3)
   **fractional** digits". Both cannot hold. The two explicit-precision rows —
   `%.3g` of 1234.5678 asserted `1.23e+03`, `%.2g` of 0.012345 asserted `0.012` —
   picked the C side silently, so a tool following the printed example would
   fail them. They are **withdrawn**, not weakened; see below for where they
   went. The four no-precision rows are untouched and gained a second,
   independent derivation from Table 9-23's shorter-output rule, written out in
   the header as character counts; the contradiction cannot arise where there is
   no digit for the example to reinterpret. Measured today: `%.3g` prints
   `1234.568` and `%.2g` prints `0.01` — both the *example's* answers, and this
   row no longer objects to either.
2. **Fixtures 05 and 06 specified a synchronous `$fmonitor`, which §9.4.1 rules
   out.** Both invoked `$fmonitor` and then read the file — 06 re-opened and
   `$fscanf`'d it — inside the *same* analog-block evaluation, and closed the
   descriptor before the step ended. §9.4.1 puts the record "at the end of the
   time step"; §9.5.9 says a write during an iterative solve happens only on
   acceptance. Either way the record lands **after** the measurement, so a
   conforming implementation read 0 and 05's first row read −2 while 06
   collapsed outright. 06 was green only because VerA's `$fmonitor` is literally
   `$fdisplay` — the one reading §9.4.1 excludes. Both now open the descriptor
   **once** under §5.10.2's `@(initial_step)` and read `$ftell` at the top of the
   *next* step, so the quantity measured is what previous steps wrote and no
   statement in the current step has touched it. Registering once also closes
   the latitude a re-invoked `$monitor` would have ("sets up a mechanism" afresh
   each step). 06 additionally dropped its `$fscanf` read-back, which coupled its
   verdict to the scanner defects fixtures 08-11 own, and its wave was changed to
   `0.25, 2.5, 25.0, 250.0` so the four records have four *different* lengths —
   the byte total now pins the record's content, which is what the read-back was
   there for. Both fixtures now fail at HEAD, for two separately-named reasons
   (no §9.4.1 change detection, and W0851 dropping the event-guarded calls).
3. **Two of 13 fixtures were already green.** After (2), **one** is:
   `07_strobe_…`. It is kept deliberately, not by oversight — §9.4.6 is the one
   thing in this row VerA implements correctly and nothing else here would catch
   a regression in it — and its counterfactual is exact rather than rhetorical:
   a per-iteration writer answers ≥ 4 bytes and in practice tens, a non-writer
   answers 0. Its header's Newton arithmetic was **wrong in sign** (it said the
   first correction was −7e8 V); the residual at V = 0 is negative, so −f/f′ is
   *positive* and the overshoot is upward. Re-derived: f(0) = −1e−3 A,
   f′(0) = 1e−14/0.0259 + 1e−12 = 1.386e−12 S, first correction **+7.22e8 V**.
   Magnitude and conclusion unchanged; the header records the correction rather
   than quietly swapping the digit.

## Withdrawn after review — where the `%g` precision rows went

`$sformat(e, "%.3g", 1234.5678) == "1.23e+03"` and
`$sformat(f, "%.2g", 0.012345) == "0.012"` are removed from fixture 01 and from
row S01. **No row owns them now**, and none is given them: no clause in the
offline LRM set settles the question, because the only sentence that speaks to a
`%g` precision field is §9.4.3's self-contradicting one and its printed example
decides *against* C. This is a genuinely open question about the standard's text,
not a gap in an implementation, so parking it in another row would only move the
contradiction.

What would let them come back, in order of preference:

* an Accellera erratum or a later LRM revision correcting the "three (3)
  fractional digits" example — then the row is C's and fixture 01 regains both
  rows verbatim;
* the IEEE 1364-2005 §17.1.1.2 text landing in `docs/`, **if** it states the C
  `%g` precision rule without the gloss. It is not in the offline set today —
  the same reason this SPEC gives for not writing the `%v` strength spellings
  from memory.

Until one of those happens, VerA's `1234.568` for `%.3g` is the reading the LRM
prints, and it is recorded above under "Not implemented" as explicitly **not**
claimed as a defect.

## Deliberately NOT covered

* **`%v` strength formatting.** The string `%v` does not occur anywhere in the
  offline LRM set (`grep` over all of `docs/*.html` returns nothing), and the
  strength encoding it prints lives in IEEE 1364-2005 §17.1.1.3, which is not in
  the offline set either. Writing the expected `St1`/`Pu0`/`HiZ` spellings from
  memory would be inventing a table. This needs the 1364 text in hand.
* **Four-state `%h`/`%o`/`%b`/`%d` collapse.** Already owned by
  `tests/pending/D09/02_display_unknown_radix.v`, derived there from the same
  inherited §17.1.1.2 sentence. Not duplicated. In the *analog* context the
  question does not arise: a Verilog-A operand is a real or an integer, and a
  four-state literal is refused by `E0130` at `src/ir/lower.zig:1171` — correctly,
  since §9.2 Table 9-1 does not make four-state values an analog-context concept.
* **`$debug` / `$fdebug` per solver iteration** (§9.4.1 "it displays its
  arguments for each iteration of the analog solver", §9.5.9 "if `$fdebug` is
  evaluated during an iteration, the write operation shall occur even if the
  evaluation occurred during an iteration that was rejected"). Not expressible as
  a fixture with the current oracle: every statement a fixture can use to *count*
  records — `$fopen`, `$ftell`, the `CHECK` macro's own `$strobe` — is itself an
  accepted-point statement under §9.5.9, so the bookkeeping cannot observe the
  iterations it is meant to count. What this needs is a runner-side oracle: the
  harness spawning the device, counting the records emitted between two accepted
  points, and asserting more than one. `07_strobe_writes_once_per_accepted_solution.va`
  pins the complementary half (`$fstrobe` must **not** do this) so that a future
  `$debug` implementation cannot be built by making every task print per
  iteration.
* **Per-instance scratch isolation.** `zSBuf` and `zf_slots` are file-scope, one
  table per device image, and both carry a `ponytail:` comment naming the ceiling.
  Two instances of the same module are evaluated *sequentially* in the display
  unit, and a formatted string is consumed before the next instance runs, so the
  sharing is not observable from source today — verified by instantiating the same
  leaf twice and reading both `$sformat` results. It becomes observable only when
  a host evaluates a device's units concurrently, which is a host-qualification
  case (Q03), not a `.va` fixture.
* **`$ferror` numeric codes.** §9.5.7 says only "an error code is returned" and
  fixes no value; `file_kernels.zfErrno` says the same in its comment. Nothing to
  pin.
* **Locale.** No clause in the AMS LRM mentions a locale, and no host path in
  `src/` calls `setlocale`. The nearest thing with a testable content — that the
  radix character and the digits of a real conversion are fixed by the standard
  rather than by an environment — is what fixture 03 pins via the rounding rule.
* **`$readmemb`/`$readmemh`, `$fgetc`/`$ungetc`/`$fread`, `$sdf_annotate`,
  multichannel-descriptor OR-ing beyond one channel.** §9.2 Table 9-2 marks these
  analog-context "No" and `Lower.isDigitalOnlySysFunc` refuses them; they belong
  to the digital runner and therefore to D09.

## Running these

Not wired into any build step — `zig build torture` walks `tests/fixtures/` only,
and adding these there would break the 1323/1323 gate on purpose. Each file runs
standalone with the CLI the harness uses in-process:

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build                       # produces zig-out/bin/vera
mkdir -p /tmp/s01 && cd /tmp/s01   # the fixtures write files into the cwd
for f in /home/omare/Documents/Projects/Zig/VerA/tests/pending/S01/*.va; do
  echo "=== $(basename "$f")"
  /home/omare/Documents/Projects/Zig/VerA/zig-out/bin/vera \
      --run --display=emit \
      -I /home/omare/Documents/Projects/Zig/VerA/tests/fixtures \
      --contract /home/omare/Documents/Projects/Zig/VerA/tools/contract.zig \
      "$f" 2>&1 | grep -E 'ok=|error'
done
```

`ok=1` on every line is the pass condition, exactly as in `tests/torture.zig`.
Captured from that loop after the review edits (`ok=1` / total assertions per
file; 11 and 12 do not reach an assertion at all):

```
01 0/4   02 1/4   03 2/5   04 0/9   05 0/4   06 0/4   07 1/1
08 6/13  09 3/7   10 3/6
11 error: expected integer type, found 'f64'   (device does not compile)
12 error[E0813] x5                              (%r, %m refused)
13 1/6
```

Only `07` is green end to end; every other file has at least one red line, and
the reds are the row's content. The partial greens in 02, 03, 08, 09, 10 and 13
are the controls each header names — they are there so that a fix cannot be
mistaken for a rewrite of the surrounding behaviour.
Once the row is implemented, moving these into
`tests/fixtures/ch09_system_tasks/` and running `zig build torture -- --strict`
is the whole of the wiring; the `//!` directives used here (`lrm`, `time`,
`wave`, `solve`, `print none`) are all ones `src/backend/tb.zig` already parses.
