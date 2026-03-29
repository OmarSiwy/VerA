# Annex B coverage

The source-based audit in [`docs/conformance-keywords.md`](../../../docs/conformance-keywords.md)
supplements and supersedes the historical inventory below. In particular,
`audit_all_escaped_keywords.va` and `audit_all_case_keywords.va` now exercise the
complete corrected table as escaped variables and two non-lowercase variable
spellings. Other identifier contexts and diagnostic independence remain open.
The historical file/arm counts below predate these additions.

Source: `docs/annex-b-keywords.html`, read in full — both printed halves of
Table B.1.

HTML section-ID audit: **none.** The file carries zero `id=` attributes: one `<h1>`, one
paragraph, and Table B.1 split across two `<table>` elements for printing. There is
nothing to key a section table on, so the table below is keyed on the annex's three
normative sentences and on the table itself. All four rows have fixtures in this folder.

Annex B is one rule wearing three sentences: a keyword is a *spelling*, reserved
everywhere the grammar wants an identifier. It states no behaviour, so nothing here can
be proved by running a module — twenty-three of the twenty-six fixtures are `//! reject`
fixtures and the three that compile exist to hold down the permissive side of the escape
and case rules. Table B.1 has **215 spellings**, counted from the corrected HTML; 206 of
them carry a `//! reject` arm in this folder and the other nine are censused in
`annex_c_analog_subset/` (below). Every fixture cites `//! lrm B`. The count was 217 and
207 while this file was keyed on an HTML transcription that had been contaminated with
Verilog-AMS 2.4 text; two of those spellings, `assert` and `net_resolution`, are not in
the 2023 table, and the fixtures that pinned them are recorded in the ledger below.

| Claim | Rule | Fixtures in this directory |
|---|---|---|
| Sentence 1 | "Keywords are predefined nonescaped identifiers that define Verilog-AMS language constructs." | The *reserved* half is the whole census, 23 files. The *nonescaped* half is sentence 2's row. **"Define language constructs" has no fixture here and should not**: that each keyword does its job is the chapter folders' business, and this folder never calls one |
| Sentence 2 | "An escaped identifier shall not be treated as a keyword." Two-sided: the escaped spelling *may* be an identifier, and it *shall not* act as the keyword | Permissive side: `01_escaped_keyword.va` (`\if ` as a real variable, read back as `total` per §2.8.1, `CHECKX` 6.0) and `21_escaped_keyword_port.va` (`\sin ` as a port, `//! bias V(sin) = 0.75, V(n) = 0.25`, `CHECKX` 0.5 — a compiler that resolved it to the sine function never gets a branch probe). Prohibitive side: `12_escaped_keyword_is_not_the_keyword.va`, `\analog begin ... end` → `//! reject E0240` (not a module item) |
| Sentence 3 | "Verilog-AMS reserves the keywords listed in Table B.1." | `03_reserved_module_rejected.va` (declaration-name position, `module module;`), `04_reserved_if_rejected.va` (variable-name position). Plus §2.8.2's "all keywords are defined in lowercase only", both sides: `02_keyword_case.va` (`Analog` and `ANALOG` are two distinct variables) and `15_uppercase_keyword_rejected.va` (`ANALOG begin ... end` → `//! reject E0205`) |
| Table B.1 | The 215 spellings themselves | The census: `05`–`11`, `14`, `16`–`20`, `22`–`25`. 206 arms here, 9 in `annex_c_analog_subset/`. Broken down below |

## The census, and what a `//! reject` arm actually proves

Every census file is the same shape: `real <keyword>;` one per line so the parser
resynchronises at each `;` and reports each spelling separately, and one `//! reject
<spelling>` arm per declaration so a spelling is proved individually instead of the file
passing on whichever token the parser tripped over first.

| File | Family | Arms |
|---|---|---|
| `05_config_library_keywords.va` | IEEE 1364-2005 A.1.1 config/library | 8 |
| `06_udp_keywords.va` | A.5.1 UDP | 2 |
| `07_gate_primitive_keywords.va` | A.3.1 gate primitives | 4 |
| `07b_switch_primitive_keywords.va` | A.3.1 MOS/CMOS switches, pull gates, `nor`/`notif*` | 8 |
| `07c_pass_logic_primitive_keywords.va` | A.3.1 pass transistors and XOR gates | 4 |
| `08_net_strength_keywords.va` | A.2.1.3 / A.2.2.2 net types and strengths | 24 |
| `09_specify_keywords.va` | A.7.1 specify blocks | 7 |
| `10_task_control_keywords.va` | A.2.7 / A.6 task, process, procedural control | 12 |
| `11_macromodule_keyword.va` | `macromodule` alone | 1 |
| `14_include_reserved.va` | `include` alone, bare rather than post-backtick | 1 |
| `16_reserved_math_functions.va` | §4.3.1 / §4.3.2 math | 15 |
| `17_reserved_analog_operators.va` | §4.5 operators, §5.10 events, §4.4/§4.6 noise and analysis | 26 |
| `18_reserved_discipline_nature.va` | §3.4 / §3.5 discipline and nature, §3.4.3/§3.4.4 range words | 18 |
| `19_reserved_core_keywords.va` | core structural, declarative and control | 31 |
| `20_reserved_2023_additions.va` | the five spellings this HTML table carries that the 2.4.0 printing does not (`break`, `continue`, `expm1`, `ln1p`, `return`) | 5 |
| `22_shadowed_spellings.va` | the spellings that are substrings of a sibling in 05–10 and 16–19 | 34 |
| `23_shadowed_spellings_inner.va` | `cos`, `sin`, `tan`, `tran`, `table` — substrings of spellings in 22 | 5 |
| `24_reserved_exp.va` | `exp` alone | 1 |
| `25_reserved_or.va` | `or` alone | 1 |

`22`–`25` exist because of the matcher, not because of the LRM. `failureContains`
(`tests/torture.zig:634`) tests a `//! reject` pattern as a substring of *every*
diagnostic of the file, plus the catalogue title, the notes and the failure's error name.
So where keyword A is a substring of keyword B declared in the same file, A's arm is
satisfied by B's diagnostic and proves nothing — `//! reject tri` beside `real trireg;`
passes whether or not `tri` is reserved. Splitting the containment graph into
non-containing layers is what `22` and `23` are; `24` and `25` go further because `exp`
is a substring of E0208's own title ("**exp**ected an identifier") and `or` of every
phase label the suite can report (`ParseErr**or**`, `DiagnosticsRep**or**ted`,
`GeneratedCompileErr**or**`).

Replayed against the real compiler, that split holds: for every arm in this folder except
three, the spelling occurs in exactly one diagnostic — the E0208 naming that declaration.
The three exceptions are `if` (04), `exp` (24) and `or` (25), each in a file that declares
exactly one thing, so `//! reject E0208` is the proof and the name arm is bookkeeping.
Their headers say so.

Two mechanical notes a reader will otherwise trip on:

- The `end*` spellings cost an extra diagnostic. `real enddiscipline;` and `real
  endnature;` (18), `real end;` (22) and `real endcase;`/`endfunction;`/`endgenerate;`
  (19) each also raise E0205 "unsupported module item" when the parser resynchronises
  onto the token, and 19 additionally raises E0201 on the trailing stray `;` its
  deliberately-last `real endmodule;` leaves behind. The name arms still match; the
  fixtures do not pin the extra codes.
- `05`'s header used to spell the C.16 word `resolvedto`. Every corrected source — Table
  B.1, C.16's own list and `annex_c_analog_subset/16_unused_ams_words_rejected.va` —
  spells it `resolveto`, and the header has been corrected against them. The fixture
  tests nothing with that name, so it was a comment typo, not a coverage hole.

## Where the other nine spellings are

Set difference between Table B.1 and the `//! reject` arms in this folder is exactly the
nine words Annex C.16 marks "not used by Verilog-A": `connect`, `connectmodule`,
`connectrules`, `driver_update`, `endconnectrules`, `merged`, `resolveto`, `split`,
`wreal`. They are censused where that clause lives —
`annex_c_analog_subset/16_unused_ams_words_rejected.va` (seven) and
`.../30_connect_reserved.va` and `.../31_connectrules_reserved.va` (the two `16` cannot
prove without shadowing). All three cite `//! lrm B`, so every Table B.1 spelling is
pinned somewhere in the suite. A tenth word used to close this list, `net_resolution`,
and it is no longer a spelling in either list: the 2023 edition removed it from Annex B
and C.16 together (Annex G item 5027), which is why its Annex B arm and its Annex C
fixture were both deleted rather than repaired.

## The xfail ledger

EMPTY — grep finds no `//! xfail` in this directory, and all 215 spellings of Table B.1
are reserved. The two rows this section held are kept because they name the shape of the
defect, which is the one an implementation re-introduces by adding a keyword to the
grammar and forgetting the lexer table — and the first of them is now also the record of
what happens when the table the census was keyed on is the wrong edition:

| Fixture | Spelling | What was wrong |
|---|---|---|
| `13_assert_reserved.va` | `assert` | **REMOVED, and the claim is WITHDRAWN rather than re-homed: `assert` is not in the 2023 Table B.1.** The fixture was authored from an HTML transcription contaminated with Verilog-AMS 2.4 text. In the published table the run reads `asinh`, then `assign`, with nothing between (physical p.400), so `real assert;` is a legal declaration under the 2023 standard and the fixture's `//! reject E0208` demanded a diagnostic the standard does not support. The defect the row described was real against the contaminated table — VerA did not reserve the spelling then — but reservedness was only ever the test because 2.4 reserved a word it never spent; 2023 stopped reserving it. The over-reservation this row left behind is **gone**: `assert` has been deleted from `reserved_keywords` (`lib/frontend/token.zig`) and `ch10_directives/d10_11_assert_is_an_ordinary_identifier.va` now pins the positive direction — a port and a net named `assert`, read across — which is the evidence the withdrawn rejection never was |
| (`annex_c_analog_subset/20_net_resolution_reserved.va`) | `net_resolution` | Same transcription error, same outcome, different folder: the word is in neither the 2023 Table B.1 nor the 2023 C.16 — Annex G item 5027 removed it from both — so its fixture was deleted with the claim withdrawn, and `net_resolution` is not a spelling this folder has to census. Listed here because this ledger would otherwise read as if the word were still a requirement |

All 26 fixtures in this folder are green (27/27 under `zig build torture -- annex_b_keywords`
when the folder still held `13`, whose removal touches no other file).
A green census row is worth what it costs — near zero for `endmodule`,
rather more for `abstol`, `access`, `units`, `from`, `exclude` and `inf`, which read
perfectly well as ordinary identifiers and which an implementation is tempted to look up
ad hoc inside a `nature` body instead of reserving in the lexer.

## What no fixture here supplies

Every one of these is a real gap, not a cross-reference:

- **Reservedness is tested in three grammar positions only**: module name (`03`),
  variable-declaration name (`04` and all 22 census files), and — escaped — port name
  (`21`). Untested positions where a compiler could plausibly leak a keyword through:
  parameter name, `localparam` name, block label (`begin : name`), analog-function name
  and its argument names, discipline and nature names, named branch, genvar, and
  instance name. A front end that routes only `real`/`integer` declarations through the
  keyword check passes this entire folder.
- **The escape rule is tested on three spellings** — `\if `, `\analog `, `\sin ` — and
  the prohibitive half on one, `\analog `. Nothing tests an escaped keyword as a module
  name, a parameter name, or a hierarchical reference, and nothing tests the interaction
  the other way: that `` `include `` still works while `real include;` does not (`14`
  pins only the bare-position half; ch10 owns the directive).
- **The case rule is tested on one keyword.** `02` and `15` both use `analog`. A
  case-folding lexer that special-cased only the words it lowers would still be caught,
  but a partial fold would not.
- **No fixture asserts the E0205/E0201 resynchronisation noise** described above, so the
  census files' diagnostic *counts* are unpinned — a compiler that emitted one diagnostic
  for a 24-declaration file and named every spelling in it would pass `08`.
- **Nothing here proves a keyword works.** By design, and worth writing down: this folder
  proves 206 of Table B.1's 215 spellings are unavailable as identifiers and proves nothing
  about whether any of them is implemented. `absdelta`, `ac_stim`, `noise_table_log`, the four
  `laplace_*` and the four `zi_*` are reserved here and their *semantics* live or die in
  ch04/ch05.

## Fixture-name audit

Twenty-six files, all mapped above:
`01_escaped_keyword.va`, `02_keyword_case.va`, `03_reserved_module_rejected.va`,
`04_reserved_if_rejected.va`, `05_config_library_keywords.va`, `06_udp_keywords.va`,
`07_gate_primitive_keywords.va`, `07b_switch_primitive_keywords.va`,
`07c_pass_logic_primitive_keywords.va`, `08_net_strength_keywords.va`,
`09_specify_keywords.va`, `10_task_control_keywords.va`, `11_macromodule_keyword.va`,
`12_escaped_keyword_is_not_the_keyword.va`,
`14_include_reserved.va`, `15_uppercase_keyword_rejected.va`,
`16_reserved_math_functions.va`, `17_reserved_analog_operators.va`,
`18_reserved_discipline_nature.va`, `19_reserved_core_keywords.va`,
`20_reserved_2023_additions.va`, `21_escaped_keyword_port.va`,
`22_shadowed_spellings.va`, `23_shadowed_spellings_inner.va`, `24_reserved_exp.va`,
`25_reserved_or.va`.

Analysis split: three fixtures compile and assert — `01` and `02` at the default
operating point, `21` under `//! bias`, one `CHECKX` each. The other twenty-three never
reach a solve.
