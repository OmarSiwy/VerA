# Vague decisions

Each entry below is a point where the Verilog-AMS LRM (`docs/*.html`,
`docs/VAMS-LRM-2023.pdf`) or IEEE 1364-2005 is vague, silent or contradicts
itself, and VerA has to choose a reading. Every entry records that choice,
marked `DECIDED`.

The items come from three places:

- `docs/ROADMAP.md` §5.1 (decisions) and §5.6 (readings the standards leave open);
- `docs/IMPLEMENTATION.md` §1 and §3, for choices that had no recorded rationale;
- `docs/CLAUSE-AUDIT.md` §7.5 (open questions).

A citation with `at 8b1514d4` points to a removed audit note. Read it with
`git show 8b1514d4:<path>`.

Some items in §5.1 and §7.5 are house-rule questions rather than readings of a
standard. They are kept here so that every source item has an answer. Each one
says "not an LRM reading" in its **Rule** line.

How to read an entry:

- **Rule** quotes the clause. IEEE 1364-2005 is licensed, so it is quoted at
  most a sentence or two per entry.
- **Decision** is the reading VerA takes. It is grounded in the normative text,
  in the intent of other clauses, and in what VerA already does. A tool's
  behaviour is cited only where it is known; otherwise the entry says it was
  not established.
- **VerA today** describes the code and fixtures as read on 2026-10-04 at
  `3de6b009`. When the decision differs from the code or the documents, the
  entry says `CHANGE NEEDED` and gives the semver class from AGENTS.md §3:
  minor when source is newly accepted or refused or emitted device text
  changes, patch otherwise.
- **Measure impact** names the measures (A, B or C, AGENTS.md §2) the change
  would move. No count is given, because counts are measured, not typed.

This document changes no code and no fixture. 51 of the 90
entries need a change. Those marked `yes (doc)` need only a document
correction.

## Summary

| ID | Clause | Decision | Change needed |
|---|---|---|---|
| VD-001 | AGENTS.md §2, §6 (house rule) | A green fixture with teeth is an ordinary fixture; its header names the wrong implementation it catches | yes |
| VD-002 | VAMS 9.21, Syntax 9-16, Table 9-32 | `";2"` is legal; a null head defaults every dimension, dependent = N + ignored + selector | no |
| VD-003 | AGENTS.md §6 (house rule); VAMS 9.17.2 | Delete invented quotes (done); ship the 9.17.2 smallest-bound fixture | yes |
| VD-004 | AGENTS.md §0 rule 1 (house rule) | Re-measure figures that gate an assertion; delete prose-only ones | yes |
| VD-005 | IEEE 1364-2005 17.10; VAMS 9.12 Table 9-9 | No 17.10-03 row; re-score 17.10-01/-02 on the existing digital fixtures | yes |
| VD-006 | AGENTS.md §2 (house rule) | A passing `.v` transcript is runtime evidence and may support `verified` | yes |
| VD-007 | VAMS 6.5.7, 7.8.4 rule 3 | A mixed port matching zero connect statements is a named error | yes |
| VD-008 | VAMS 7.4.4, 7.4.4.2 | Basic is the testable normative default; detail mode is required, so its absence is `missing` | yes |
| VD-009 | IEEE 1364-2005 13.2.1.1 vs 4.11 | Last same-named module wins with W1152, in both the `.v` and `.va` paths | yes |
| VD-010 | VAMS 5.6.1.3, A.6.5 | Contributions made before an event-triggered `disable` stand | yes |
| VD-011 | VAMS 3.4.5, 6.3.3; IEEE 12.2.2.1 | `#(.lp())` on a localparam is E0907 | yes |
| VD-012 | VAMS E.1.2 | Claim SPICE3 `.MODEL` + flat numeric `.SUBCKT`; refuse unreadable body cards, `PARAMS:`, `{}`, nesting | yes |
| VD-013 | VAMS F.2.2, F.1 | Provide `--discipline-resolution=basic\|detail`; a folded pass is fine if results are equal | yes |
| VD-014 | VAMS A.8.8; IEEE 1364-2005 3.6 | Accept bytes above 0x7F as opaque 8-bit characters, one byte each | yes |
| VD-015 | VAMS 9.17.3, Syntax 9-12 | A non-access first argument is E0891 (already implemented) | yes |
| VD-016 | ROADMAP §5.1 (scope) | `.v` contract device: implemented | no |
| VD-017 | VAMS 7.3.2; IEEE 1364-2005 17.1.1.4 | An x/z analog display operand is an error; fix E0130's explanation, add a fixture | yes |
| VD-018 | IEEE 1364-2005 17.2.9 | Excess `$readmem` data: warning, load continues (implemented, W1150) | yes |
| VD-019 | CLAUSE-AUDIT §2 (house rule) | A parsed AST path is not `partial`; re-score AMS-06 on executing fixtures | yes |
| VD-020 | AGENTS.md §2 (house rule) | A kernel unit test never carries `verified` alone | yes |
| VD-021 | VAMS 2.7, A.8.8, G change 2535 | A string stays on one line; a raw newline or continuation is E0138 | no |
| VD-022 | VAMS 2.3, 2.7 Table 2-2 | A raw TAB in a string is legal and is byte 9 | no |
| VD-023 | VAMS 2.9.2 (`op`) | An absent `op` means included; only `"no"` excludes | no |
| VD-024 | VAMS 2.9 Syntax 2-4, A.9.1, Annex B | Only `units` is exempt as a keyword attribute name; other keywords are refused | yes |
| VD-025 | VAMS 3.4; IEEE 1364-2005 4.10.1 | "Previously defined" means textual order; a forward reference is E0314 | no |
| VD-026 | VAMS 4.3.1 Table 4-14 | `min`/`max` use the conditional form for value and derivative, folding included | yes |
| VD-027 | VAMS 8.2 vs 8.4.1 | Nodeset vs `analog initial` order is unobservable; follow 8.2, assert neither | no |
| VD-028 | VAMS 5.10.3.3, 8.3.3 | An `@()` body's effects are committed once per accepted timepoint | no |
| VD-029 | VAMS 8.4.4 example; IEEE 1364-2005 9.2.2 | 9.2.2 governs; the "cancel" is the D2A's driver look-ahead | no |
| VD-030 | VAMS 9.16 | Run-time `$simprobe` names should resolve; until then, refuse by name, never fall back silently | yes |
| VD-031 | VAMS 9.21, 9.21.1 | Refuse a duplicate abscissa only when the conflict is proven; otherwise check at capture | no |
| VD-032 | VAMS 3.7; IEEE 1364-2005 9.7.2, 6.1.2 | A real "change" is IEEE 754 `!=`; the new bits are still stored | yes |
| VD-033 | VAMS 3.7; IEEE 1364-2005 11.3 | `m04_01`'s time-0 read of a declaration-assigned wreal is a race; sample after `#0` | yes |
| VD-034 | VAMS 5.10 Syntax 5-13, 5.10.5, 7.3.6.2 | `posedge`/`negedge` on a continuous operand is E0704; use `cross` | no |
| VD-035 | VAMS 3.3 vs A.2.1.3/A.2.8 | A module-level `string` variable is legal (3.3 governs) | no |
| VD-036 | VAMS 2.7 Table 2-2; IEEE 1364-2005 3.6.3 | An undefined escape keeps the character and drops the backslash, with a named warning | yes |
| VD-037 | IEEE 1364-2005 5.5.4 | Signed x/z gives all-x for arithmetic and resizing only; bitwise and `?:` keep their bit tables | yes |
| VD-038 | IEEE 1364-2005 6.1.3, 4.3 | A 1-bit `[0:0]` LHS takes the scalar (gate) delay rule: width decides | yes |
| VD-039 | IEEE 1364-2005 13.2.2 vs A.1.1 | A `config` in a lib.map is refused (E0244); the prose beats the grammar superset | yes |
| VD-040 | IEEE 1364-2005 17.2.9 | File address outside the declared memory with no task bounds: named warning, words skipped | yes |
| VD-041 | IEEE 1364-2005 17.2.9, 3.5.1 | Address: hex digits plus `_` after the first char (trailing included); x/z/? malformed | yes |
| VD-042 | IEEE 1364-2005 18.4.3.2 | Strength 5..7 is the strong range by number; "(large)" is a slip | yes |
| VD-043 | IEEE 1364-2005 19.6, 19.11 | `` `resetall `` does not touch the `` `begin_keywords `` region | yes |
| VD-044 | IEEE 1364-2005 26.2.4 vs 27.34.2 / VAMS 12.33.2 | Startup routines may only register; VerA refuses other routines then; fixtures walk at cbEndOfCompile | yes |
| VD-045 | IEEE 1364-2005 26.3.5 vs Annex G | `vpiIsProtected` = `vpiProtected` (10), FALSE on every object | yes |
| VD-046 | IEEE 1364-2005 26.6.40(c) vs VAMS 11.6.25 note 5 | Current queue listed iff a pending event precedes read-only sync | yes |
| VD-047 | VAMS 11.6.25, 12.31.2 | A callback-only time is a vpiTimeQueue entry | no |
| VD-048 | VAMS 12.27 / IEEE 27.26 | `vpi_mcd_printf` returns one expansion's length, regardless of channel count | no |
| VD-049 | VAMS 12.16 / IEEE 27.14 | `vpiIntVal` of a wide object is its low 32 bits | yes |
| VD-050 | IEEE 1364-2005 17.6.5, 17.6.6 | Unknown `q_stat_code`: constant refused; run time gives status 2, value unchanged | yes |
| VD-051 | IEEE 1364-2005 17.6.5 | Code 3 is the observed peak length | yes |
| VD-052 | IEEE 1364-2005 17.6.5, 3.5.3 | Means are rounded to nearest (real-to-integer rule), not truncated | yes |
| VD-053 | VAMS 2.7 | Octal escape above \377 is refused with a named error (the LRM permits it) | DONE |
| VD-054 | VAMS 2.8 | No identifier length limit | no |
| VD-055 | VAMS 4.2.4 | Integer % by zero: E0601 at compile time if provable, runtime report or trap otherwise | no |
| VD-056 | VAMS 4.2.4 | Real % by a runtime zero reports E0601 like the integer path, not NaN | yes |
| VD-057 | VAMS 4.5.4 | idt without ic: c from the feedback loop when the argument reads an unknown, else 0 (row rewording) | yes (doc) |
| VD-058 | VAMS 4.5.5 | idtmod c = 0 is required by the prose; not implementation-defined | yes (doc) |
| VD-059 | VAMS 4.5.5 | idtmod integrates inside the device, wrapped each accepted step | no |
| VD-060 | VAMS 4.5.7 | absdelay linear interpolation is required; vera_interp=2 is an extension | yes (doc) |
| VD-061 | VAMS 4.5.11 | Pole at s = 0: DC value 0 (in-device state, no loop reading) | no |
| VD-062 | VAMS 4.5.11, 4.5.12 | Card root vectors pair at runtime (1e-9 rel.); an unpaired root gives NaN | no |
| VD-063 | VAMS 4.6.1 | No analysis names beyond Table 4-21; others are false, silently | no |
| VD-064 | VAMS 4.6.3 | The small-signal analysis is named "ac" | no |
| VD-065 | VAMS 5.10.3.1, 7.8 | .v device crossing ttol = card ttol, default min(trise,tfall)/50 | no |
| VD-066 | VAMS 5.10.3.1, 5.10.3.3 | Fixed-grid testbench fires at the next grid point with W0750 | no |
| VD-067 | VAMS 5.10.3.4 | absdelta defaults: time_tol 1 ps (at least the precision), expr_tol 1e-12 | no |
| VD-068 | VAMS 7.4.4 | Basic resolution mode only; see VD-008 | no |
| VD-069 | VAMS 9.5.7, IEEE 17.2.7 | $ferror returns fixed C errno values on every host | no |
| VD-070 | VAMS 9.7.2 | $stop in a batch run prints and exits 0 | no |
| VD-071 | VAMS 9.13.1 | Omitted seed: deterministic 1 + 7919k per site | no |
| VD-072 | VAMS 9.15 | gmin and sourceScaleFactor become host-written Model fields | yes |
| VD-073 | VAMS 9.17.3, E.3.4 | Six $limit built-ins; an unknown name returns the probe with W0853 | no |
| VD-074 | VAMS 9.17.3 | Extra $limit args: frame sign, then seed; more declines (W0853) | no |
| VD-075 | VAMS 12.36 | vpiRejectTransientStep = 730 | no |
| VD-076 | VAMS E.1, E.2 | SPICE flavour; see VD-012 | no |
| VD-077 | VAMS E.3.3 | No primitive-shadow warning; W0951 for model/subckt (stale ROADMAP row) | yes (doc) |
| VD-078 | VAMS 9.15 | Temperature per Model row; IMPLEMENTATION cite §9.10 -> §9.15 | yes (doc) |
| VD-079 | VAMS 9.18, Table 9-29 | Card-time domain check for host-set hierarchical system parameters | yes |
| VD-080 | IEEE 1364-2005 8.1.2 | 64 UDP inputs for both kinds, E1017 past it | no |
| VD-081 | IEEE 1364-2005 11.4.2 | Source-order FIFO active events; resume in suspend order; interpreter = native | no |
| VD-082 | IEEE 1364-2005 5.1.4, 11.4.2, 11.5, 12.3.10.x (CLAUSE-AUDIT §5.5) | Tagged fixtures assert only the permitted set; VerA's choice pinned untagged | yes |
| VD-083 | IEEE 1364-2005 13.4.4, 13.3.2 | The config no `use` clause names sets the top; zero or several is E0243 | yes |
| VD-084 | IEEE 1364-2005 17.2.4.1 | 16-deep pushback, EOF past it; every read routine sees it | yes |
| VD-085 | IEEE 1364-2005 17.2.1, 27.25; VAMS 12.24, 12.27 | Lowest free mcd bit from 1; from channel 4 under VPI, one shared table | no |
| VD-086 | IEEE 1364-2005 17.9.1 | One hidden per-run seed from 0 for seedless digital `$random` | no |
| VD-087 | IEEE 1364-2005 19.8 | No `timescale: 1 s / 1 s | no |
| VD-088 | IEEE 1364-2005 5.2.2, 4.8.2 | Invalid real-array read gives +0.0 | no |
| VD-089 | IEEE 1364-2005 17.11.1, 4.10.1; VAMS 9.14 | Host number is an unsized integer for `$clog2` unless a range/type fixes width | yes |
| VD-090 | VAMS 9.18, 6.3.6, 3.4.7 | Top-level system parameter values via a top `aliasparam` card slot | no |

## 1. Open decisions (ROADMAP §5.1, CLAUSE-AUDIT §7.5)

### VD-001: A labelled regression gate in a row whose job is to fail
- **Source**: ROADMAP §5.1 item 1 (`tests/fixtures/MANIFEST.md` §5.8 items 1 and 12 at 8b1514d4).
- **Rule**: not an LRM reading. House rules: AGENTS.md §2 ("A rejection fixture is not positive coverage"; "XFAIL markers are implemented, never deleted") and §6 ("The trap that produces confidently wrong work").
- **Why vague**: X01's two `.op` decks, `a05_07_file_multiple_dependents.va`, `a04_09_slew_small_signal_transfer.va`, `a01_06_invalid_index_write_preserves.va`, `a01_07_discontinuity_real_degree.va` and A10's three host decks (`a10_bound_step.sp`, `a10_cross_timestep.sp`, `a10_timer_breakpoints.sp`) pass today and exist to catch a named wrong implementation. MANIFEST §5.8 item 12 records that A01 06/07 were measured to go red under the wrong implementations they name.
- **Options**: (a) delete them as non-discriminating; (b) keep them as ordinary fixtures under their `//! lrm` tags; (c) keep them, labelled as regression gates.
- **Decision**: `DECIDED:` (b). A fixture is kept if its expected value is derived from the clause and some wrong implementation fails it. Whether VerA passes today does not matter. A green fixture with teeth is the normal case, not a defect. The test is the one MANIFEST §5.8 item 12 applied: show, in the header, the named wrong implementation and what it prints (`got=... ok=0`). A fixture that no plausible wrong implementation fails is deleted. "Regression gate" is not a separate category and gets no separate counting rule.
- **VerA today**: the `.va` files above exist and carry no `//! xfail`. The `.sp` decks are compile-checked only (`zig build test-spice`, `build.zig`), not executed (ARPice). No change to code. CHANGE NEEDED: a header line in each of the six `.va` files naming the wrong implementation it catches and the value that implementation prints, where the header does not already say so. Patch, documentation only.
- **Measure impact**: none. These files already count in A and C.

### VD-002: Can `";2"` carry a dependent selector with no interpolation control?
- **Source**: ROADMAP §5.1 item 2; MANIFEST §5.8 item 8 at 8b1514d4.
- **Rule**: VAMS 9.21, Syntax 9-16: `table_control_string ::= "[interp_control[;dependent_selector]]"`, `interp_control ::= 1st_dim_table_ctrl_substr_or_null [, ...]`. Table 9-32, first row: `""` or omitted means "Dimensionality of the data is assumed to be N. Column N+1 is taken as the dependent."
- **Why vague**: the bracket nesting makes the selector optional inside a present `interp_control`. Since `interp_control` can be a single null sub-string, `";2"` can be read in two ways. In the first, it is a null control plus selector 2, so the dependent is column N+2. In the second, it is one null sub-string spent on one column plus selector 2, so it is column 1+2 = 3 on a 2-D call. `a05_06` and `a05_07` disagree on this.
- **Options**: (a) one null sub-string is one consumed column (the dependent is column 3 on a 2-D table); (b) an empty head means every dimension takes the default and N comes from `table_inputs` (column N+selector).
- **Decision**: `DECIDED:` (b). Every dimension must consume a column. In Syntax 9-16 a sub-string that is null still controls its dimension with the defaults. It never removes a dimension. Reading (a) would give a 2-D lookup only one independent column, which contradicts Table 9-32's first row ("Column N+1 is taken as the dependent"). The rule is: leading columns = N + number of `I` sub-strings, and dependent = leading + selector. Both of Table 9-32's `I` examples come out right under this rule (`"I,1CC,1CC;3"` gives column 6, `"3,D,I,1;3"` gives column 7).
- **VerA today**: matches. `lib/ir/lower/table_model.zig:336-419` `parseTableCtl` gives undeclared trailing dimensions their own columns (`while (d < nd)`, `:408`) and returns `col + sel - 1` (`:418`). The headers of `ch09_system_tasks/a05_06_ignored_column_and_selector.va` and `a05_07_file_multiple_dependents.va` already give the two-arm rule. CLAUSE-AUDIT AMS-09 is `verified`. No change.
- **Measure impact**: none.

### VD-003: The quotations and mechanism claims the repair pass invented
- **Source**: ROADMAP §5.1 item 3; MANIFEST §5.1(b) at 8b1514d4; ROADMAP §5.5.
- **Rule**: not an LRM reading. House rule: AGENTS.md §6 (the header quotes the LRM sentence) and §0 rule 1.
- **Why vague**: five quotations and two mechanism claims in fixture headers were fabricated. One of them, A10's claim that VerA refuses a second `$bound_step`, was given as the reason no fixture was shipped for VAMS 9.17.2's "smallest currently active" rule.
- **Options**: (a) delete the fabrications; (b) delete them and also ship the coverage the fabrication excused.
- **Decision**: `DECIDED:` (b). Quoted text in a header must be found verbatim in `docs/`, or the quotation is deleted. VAMS 9.17.2 needs a positive fixture: two `$bound_step` calls in one evaluation, where the smaller bound must win.
- **VerA today**: none of the invented strings remains in `tests/fixtures`. I grepped for "selected after generate", "is active on the first point", "paramset for each instance" and "default to the unknown value", and ROADMAP §5.5 records the 2026-09-29 corrections. No fixture tests the smallest-bound rule: `25_bound_step.va`, `216_kernel_control_tasks_together.va` and `a10_host.assets_a10_vsine.va` each have one call. CHANGE NEEDED: add `ch09_system_tasks/bound_step_smallest_active_wins.va` (or a host test that reads `inst.bound_step`) with two calls and a hand-derived bound. Patch. It moves A by one fixture and gives 9.17.2 more evidence in C.
- **Measure impact**: A (+1 fixture), C (9.17.2 evidence).

### VD-004: Published figures that do not reproduce
- **Source**: ROADMAP §5.1 item 4; MANIFEST §5.1(d) at 8b1514d4; ROADMAP §5.5.
- **Rule**: not an LRM reading. House rule: AGENTS.md §0 rule 1 ("Never type a conformance number. Measure it.") and §9's last item.
- **Why vague**: headers state some numbers (accepted-point counts, ngspice digits, bounds) as measured, and re-running them does not reproduce those numbers.
- **Options**: (a) re-measure each one; (b) delete each one; (c) re-measure the ones an assertion depends on and delete the prose-only ones.
- **Decision**: `DECIDED:` (c). A figure that sets a tolerance or a `//! checks` count is re-measured by a command named in the header. A figure that only appears in prose is deleted. A header that is not re-measured in the same commit may not keep a measured figure.
- **VerA today**: the remaining items are those listed in ROADMAP §5.5. I did not re-check each one here. CHANGE NEEDED: work through the ROADMAP §5.5 list. Patch, fixture headers only.
- **Measure impact**: none.

### VD-005: Does §17.10 get its own digital row?
- **Source**: ROADMAP §5.1 item 5; CLAUSE-AUDIT §7.5 item 2.
- **Rule**: IEEE 1364-2005 17.10 (`$test$plusargs`, `$value$plusargs`), inherited through VAMS 9.12, whose Table 9-9 marks both functions `Yes` in both contexts. House rule: CLAUSE-AUDIT §7.1, where the weaker context sets a split row.
- **Why vague**: §17.9 and §17.11 each have a separate digital row (17.9-14, 17.11-24) and §17.10 does not. The digital gap therefore scored 17.10-01/-02 as `missing (digital)`.
- **Options**: (a) add a `17.10-03 digital` row (total 128); (b) keep one row per function and score both contexts in it.
- **Decision**: `DECIDED:` (b), and the 17.9/17.11 split is not copied. Table 9-9 puts both contexts in one row per function. Measure B is per clause (`tests/fixtures/ieee1364/CLAUSES.tsv` rows 17.10, 17.10.1, 17.10.2), not per CLAUSE-AUDIT ledger row. The digital half now exists, so the original question is moot. Both rows are re-scored on today's evidence.
- **VerA today**: the digital plusargs are implemented (`src/sim/digital/evaluate.zig`, `compile.zig`). They have positive and refusal `.v` fixtures: `ieee1364/17_system_tasks/b_17_10_1_plusargs_variable_query.v`, `audit_test_plusargs_absent.v`, `audit_value_plusargs_absent.v`, `b_17_10_1_test_plusargs_real_rejected.v`, `b_17_10_1_test_plusargs_arguments_rejected.v`, `b_17_10_2_value_plusargs_format_rejected.v` and `b_17_10_2_value_plusargs_arguments_rejected.v`. CLAUSE-AUDIT rows 17.10-01/-02 still read `missing (digital)`. CHANGE NEEDED: re-score CLAUSE-AUDIT 17.10-01/-02 against these fixtures and close §7.5 item 2. Documentation only.
- **Measure impact**: none from the document. Measure B already counts these from CLAUSES.tsv.

### VD-006: May `.v` transcript evidence support `verified`?
- **Source**: ROADMAP §5.1 item 6; CLAUSE-AUDIT §7.5 item 6.
- **Rule**: not an LRM reading. House rule: AGENTS.md §2 (an obligation needs a positive behavioural test, an invalid-input test and a recorded result) and CLAUSE-AUDIT §2.
- **Why vague**: four verdicts (17.3-01, 17.7-01, the digital half of 17.11-01, 17.11-24) rest on `zig build test-devices`. That step is outside measure A, and CLAUSE-AUDIT recorded it as failing at 47/66.
- **Options**: (a) only evidence inside `zig build test` counts; (b) any executed transcript suite with a recorded result counts.
- **Decision**: `DECIDED:` (b). A `.v` transcript is the compiler's output run in a host, with its result diffed against a recorded `.expected.txt`. That is exactly the runtime evidence AGENTS.md §2 asks for. Measure B (`zig build test-1364 -- --coverage`) is itself built from these transcripts. The condition is that the step passes: a verdict rests on a transcript only while its step is green, and the name-list diff in AGENTS.md §0 rule 3 applies to it as well.
- **VerA today**: AGENTS.md §0 records every `test-devices` case passing as of 2026-09-24, so the "47/66" in CLAUSE-AUDIT §7.5 item 6 is stale. CHANGE NEEDED: update CLAUSE-AUDIT §7.5 item 6 (documentation only). No verdict changes.
- **Measure impact**: none (confirms B's basis).

### VD-007: Discrete and electrical ports on one undeclared net with no connect statement
- **Source**: ROADMAP §5.1 item 7; `docs/conformance-mixed-signal.md:211-215` at 8b1514d4.
- **Rule**: VAMS 6.5.7: "Ports of both analog and digital discipline may be connected to a net provided the appropriate connect statements exist (see 7.7)." VAMS 7.8.4 rule 3: "A connection shall be selected for a port only if one of the connections to the port is digital and the other is analog. In this case, the port shall match one (and only one) connect statement."
- **Why vague**: neither clause names a diagnostic for zero matching statements, and someone could argue the case is legal when nothing actually crosses domains. VerA accepts it.
- **Options**: (a) accept when no behaviour crosses domains; (b) accept silently (today); (c) refuse with a named error.
- **Decision**: `DECIDED:` (c). 7.8.4 defines a mixed signal by the disciplines of its segments, not by activity. Once the net resolves continuous (7.4.4.1) and a port's lower segment is discrete, the port is mixed. "Shall match one (and only one)" is then violated by zero matches as much as by two. 6.5.7's "provided" makes the connection conditional. The new diagnostic is the zero-match counterpart of E0922.
- **VerA today**: `lib/ir/elaborate/insert.zig:61-62`: "A mixed port no statement matches is left joined". E0922 covers only `count > 1` (`:94-99`). `ch07_mixed_signal/lrm_7_4_4_1.va` relies on this acceptance. CHANGE NEEDED: a new E09xx error for a mixed port that matches no connect statement, citing 6.5.7/7.8.4. `lrm_7_4_4_1.va` gets a `connectrules` block (or a trivial connect module), so it still tests 7.4.4.1 resolution. Add a reject fixture with that legal neighbour. Minor: source that was accepted is now refused.
- **Measure impact**: A (one fixture edited, one added), C (7.8.4 and 6.5.7 become two-way).

### VD-008: Detail discipline resolution is testable, and its absence is a gap
- **Source**: ROADMAP §5.1 item 8; `docs/conformance-mixed-signal.md:193-201` at 8b1514d4; IMPLEMENTATION §1 row "AMS 7.4.4.2".
- **Rule**: VAMS 7.4.4: "There are two modes for this method of resolution, basic (the default) and detail ... The selection of these discipline resolution modes shall be vendor-specific." VAMS 7.4.4.2 (detail mode).
- **Why vague**: "vendor-specific selection" can be read as permission to offer only one mode. `lrm_7_4_5.va:6-12` reads it that way and argues that a fixture for either mode would fail a conforming compiler.
- **Options**: (a) detail mode is optional, and basic-only conforms; (b) both modes are required, only the selection mechanism is vendor-specific, and basic is the normative default.
- **Decision**: `DECIDED:` (b). The clause defines two modes and makes basic the default. Only how a user selects a mode is left to the vendor. So a fixture that pins basic mode without any selection is not vendor-specific. It tests the normative default. Detail mode is testable once a selector exists, by a fixture that selects it and asserts the Figure 7-4 result. Until then, 7.4.4.2 is `missing`, not implementation-defined. See VD-013 for the selector.
- **VerA today**: basic only (`lib/ir/elaborate/resolve.zig`; IMPLEMENTATION §1 row "AMS 7.4.4.2 ... basic only"). `lrm_7_4_4_1.va` pins basic. CHANGE NEEDED: (1) correct the `lrm_7_4_5.va:6-12` header so it says basic is the testable default and detail is not implemented; (2) re-file IMPLEMENTATION's 7.4.4.2 row as a gap under ROADMAP §5.3 rather than a choice; (3) when VD-013 lands, add a detail-mode fixture. Patch for (1) and (2). Minor for (3), because it adds a CLI option and new resolution results.
- **Measure impact**: C (7.4.4.2 stays one-way until detail mode lands; no change from the documentation fix).

### VD-009: Two modules with one name
- **Source**: ROADMAP §5.1 item 9; `docs/conformance-ieee-config-review.md:32` (CFG-005) at 8b1514d4.
- **Rule**: IEEE 1364-2005 13.2.1.1: "If multiple cells with the same name map to the same library, then the LAST cell encountered shall be written to the library. ... a warning message shall be issued." IEEE 1364-2005 4.11: "Once a name is used to define a module or primitive, the name shall not be used again to declare another module or primitive."
- **Why vague**: the two clauses contradict each other. 4.11 forbids reuse, and 13.2.1.1 prescribes last-wins with a warning for exactly this case (same name, one library, one compiler invocation).
- **Options**: (a) error under 4.11; (b) last wins with a warning under 13.2.1.1; (c) first wins silently.
- **Decision**: `DECIDED:` (b) in both languages. 13.2.1.1 is the specific rule: it names the case and gives a reason (the separate-compile model). 4.11 predates libraries. Option (c) satisfies neither clause. The `.va` path must agree with the `.v` path, so that one design does not elaborate differently depending on which engine reads it.
- **VerA today**: the digital path already conforms. `src/sim/digital/bind.zig:28-51` emits W1152 and binds the later cell, and `ieee1364/13_configuration/b_13_2_1_1_same_name_cell_last_wins.v` pins it. The analog elaborator does not conform: `lib/ir/elaborate/names.zig:131-132` `findModule` returns the first match and does not warn. CHANGE NEEDED: make `findModule` (and the module list it scans) take the last same-named user module, emit W1152, and add a `.va` fixture with two `module leaf` declarations whose behaviour differs. Minor: device text changes for source that is already accepted.
- **Measure impact**: A (+1 fixture), C (13.2.1.1 evidence in the analog path). B already counts the `.v` fixture.

### VD-010: A disabled block's contributions already made
- **Source**: ROADMAP §5.1 item 10; `a03_SPEC.md:170-177` at 8b1514d4.
- **Rule**: VAMS 5.6.1.3: "When solving an analog block during an iteration, multiple contributions to the same potential branch or same flow branch will be additive." VAMS A.6.5 `disable_statement`. In VerA's analog subset only `@(event) disable blk;` is legal (E0401).
- **Why vague**: no clause says whether `disable` withdraws contributions that the block already executed in the same iteration.
- **Options**: (a) contributions executed before the `disable` stand; (b) they are withdrawn.
- **Decision**: `DECIDED:` (a). `disable` transfers control out of the block (IEEE 1364-2005 9.6.2, inherited). It is not a rollback, and no clause describes undoing a statement's effect. 5.6.1.3 makes contributions accumulate as the iteration executes. A contribution that ran therefore added to the branch, and the next iteration starts from nothing anyway (5.6.1.3, "only valid for the current iteration").
- **VerA today**: matches. `lib/ir/lower/stmt.zig:134-162` `lowerDisable` jumps to the block exit (`gotoBlock(nb.exit)`), so earlier contributions stay in the accumulated row. No fixture tests it: every `a03_*` disable fixture contributes outside the disabled block. CHANGE NEEDED: add a fixture with `begin : b I(p,n) <+ x; @(initial_step) disable b; I(p,n) <+ y; end` that asserts the branch carries x and not x+y at the event point. Patch, since behaviour is unchanged.
- **Measure impact**: A (+1), C (5.6.1.3 and A.6.5 positive evidence).

### VD-011: `#(.locked())` on a localparam
- **Source**: ROADMAP §5.1 item 11; `docs/conformance-empty-parameter-fix.md` at 8b1514d4 (the cited lines 184-191 are past the file's 102 lines, so the citation is stale).
- **Rule**: VAMS 3.4.5: local parameters "cannot directly be modified with the defparam statement or by the ordered or named parameter value assignment". VAMS 6.3.3: "The parameter expression is optional so the instantiating module can document the existence of a parameter without assigning anything to it." IEEE 1364-2005 12.2.2.1: "Local parameters cannot be overridden".
- **Why vague**: an empty `.name()` modifies nothing, so 3.4.5's prohibition does not strictly apply. But 6.3.3's purpose is documenting a parameter that the instantiator could assign.
- **Options**: (a) accept, because nothing is modified; (b) refuse, because a localparam is not part of the instance's parameter interface.
- **Decision**: `DECIDED:` (b), E0907. Both standards keep localparams out of the parameter value assignment lists entirely (1364 12.2.2.1 says they "are not considered part of the ordered list"). The name list in 6.3.3 names the instantiated module's overridable parameters. Rejecting the name keeps a later edit to `.locked(3)` from becoming the first moment the error appears, and the rejection is also the portable choice.
- **VerA today**: matches. `lib/ir/elaborate/override.zig:176-178` refuses a localparam by name before the empty-value check (`:259-263`, "Validate the name/localparam above even when no value is given"). No fixture pins the empty form: `ch03_data_types/audit_localparam_override_rejected.va` gives a value. CHANGE NEEDED: add `reject_localparam_empty_named_override.va` (`//! reject E0907`) next to a legal `#(.p())` on a plain parameter. Patch.
- **Measure impact**: A (+1), C (3.4.5 refusal paired with its legal neighbour).

### VD-012: Which SPICE flavour VerA claims
- **Source**: ROADMAP §5.1 item 12; `h04_SPEC.md:116-119` at 8b1514d4; IMPLEMENTATION §1 row "AMS E.1, E.2".
- **Rule**: VAMS E.1.2 item 1: "whether a particular Verilog-AMS simulator is SPICE compatible, and with which particular variant of SPICE it is compatible, is solely determined by the authors of the simulator."
- **Why vague**: the standard leaves the dialect to the tool. VerA has stated parse limits but no claim, and it skips every card it cannot read without saying so.
- **Options**: (a) claim nothing and skip silently (today); (b) claim a named subset and refuse what falls outside it inside a definition; (c) adopt a full dialect (HSPICE/Spectre `PARAMS:`, `{expr}`, nested `.SUBCKT`).
- **Decision**: `DECIDED:` (b). VerA claims SPICE3 card syntax for `.MODEL` and for flat `.SUBCKT` bodies made of numeric-valued R/C/L/V/I/E/F/G/H cards. `PARAMS:`, `{expr}` values, nested `.SUBCKT`, `.INCLUDE`/`.LIB` and model-referenced body devices (`R1 A B RMOD`) are not claimed. Cards outside a definition (`.tran`, top-level devices) are not module definitions and may still be skipped. A card that cannot be read inside a `.SUBCKT` body is refused with a named E.1.2 diagnostic. Skipping it changes the circuit, for example a dropped R becomes an open, and that is the silent wrong answer AGENTS.md §4 forbids.
- **VerA today**: `lib/frontend/spice_cards.zig:1-4` ("every other card is skipped without a diagnostic"), `:254-260` (an unreadable body card "contributes nothing and is not diagnosed"), `:123-125` (a nested `.SUBCKT` closes early), `:186` (`params:` ends the port list and is ignored). CHANGE NEEDED: (1) a new error for an unreadable card inside a `.SUBCKT` body, for `PARAMS:`/`{}`, and for a nested `.SUBCKT`; (2) state the claim in IMPLEMENTATION §1; (3) add reject fixtures with legal neighbours in `annex_e_spice/`. Minor: netlists that were accepted are now refused. The `.MODEL X SW` E0904 mis-blame (ROADMAP §5.3) is fixed by the same diagnostic.
- **Measure impact**: A (new fixtures), C (E.1.2 refusal evidence).

### VD-013: "Shall be controlled by a simulator option" (F.2.2)
- **Source**: ROADMAP §5.1 item 13; `annex_f_resolution/COVERAGE.md:16-21` at 8b1514d4.
- **Rule**: VAMS F.2.2 (Annex F is normative): "The selection of this algorithm instead of the default shall be controlled by a simulator option." VAMS F.1: "This annex provides a possible algorithm for achieving the semantics of" 7.4.
- **Why vague**: VerA is a compiler, not a simulator, so the standard does not say what form a "simulator option" takes for it. F.1 also lets an implementation use a different algorithm, which raises the question of whether VerA's single fold of step 5's top-down re-pass is allowed.
- **Options**: (a) declare F.2.2 out of scope; (b) add a compiler option.
- **Decision**: `DECIDED:` (b). The option is `--discipline-resolution=basic|detail` (default `basic`), recorded in the device's metadata. The obligation does not depend on how VerA is packaged. Folding the passes is acceptable under F.1 as long as the results equal the two-pass algorithm. That is an evidence obligation, a distinguishing hierarchical fixture, not a defect. Until the option exists, F.2.2 and 7.4.4.2 are `missing` (VD-008).
- **VerA today**: no such option. Basic mode only (`lib/ir/elaborate/resolve.zig`). CHANGE NEEDED: add the option and detail mode, plus a mode-selecting fixture directive and a Figure 7-4 fixture. Minor. Until then, record F.2.2 as `missing` in CLAUSE-AUDIT.
- **Measure impact**: C (F.2.2 and 7.4.4.2 stay one-way until the option lands).

### VD-014: UTF-8 bytes above 0x7F in string literals
- **Source**: ROADMAP §5.1 item 14; `annex_a_syntax/COVERAGE.md:332-335` at 8b1514d4.
- **Rule**: VAMS A.8.8: `string_literal ::= " { Any_ASCII_Characters } "`. IEEE 1364-2005 3.6: a string is "a sequence of 8-bit ASCII values, with one 8-bit ASCII value representing one character".
- **Why vague**: ASCII is 7-bit, but 1364 3.6 describes strings as "8-bit ASCII values". Bytes 0x80-0xFF are therefore excluded by the production and included by the storage model.
- **Options**: (a) refuse bytes above 0x7F; (b) accept them as opaque bytes, one byte per character; (c) decode UTF-8 so that a code point is one character.
- **Decision**: `DECIDED:` (b). 1364 3.6 defines a string's value as its bytes, 8 bits each, so a byte above 0x7F has a well-defined value and length. Refusing would break real models that write unit strings like `"°C"` for no semantic gain. Decoding would contradict "one 8-bit ... value representing one character". `"°C"` is three characters to `len()`/`$strlen`-style operations. This is an implementation-defined choice and belongs in IMPLEMENTATION §1.
- **VerA today**: accepted without a diagnostic (COVERAGE note). I found no fixture that asserts the value or length of a non-ASCII string. CHANGE NEEDED: an IMPLEMENTATION §1 row, and a fixture that asserts the byte count of `"°C"` is 3. Patch.
- **Measure impact**: A (+1). C none, since it is implementation-defined.

### VD-015: `$limit(typ*V(a,k), ...)`
- **Source**: ROADMAP §5.1 item 15 (found 2026-09-27).
- **Rule**: VAMS 9.17.3, Syntax 9-12: every form is `$limit ( access_function_reference ... )`. The prose says it "returns a real value that is derived from its first argument (the access function reference, such as a branch voltage)".
- **Why vague**: A.8.2's generic `analog_system_function_call` takes any expression, while Syntax 9-12 narrows the first argument. The question was whether to refuse or to warn (W0853).
- **Options**: (a) W0853, with the site declined; (b) an error.
- **Decision**: `DECIDED:` (b). The clause's own syntax is the narrower and more specific rule. The legal way to write it is `$limit(V(a,k), "pnjlim", vte, vcrit, typ)`, with the polarity as VerA's frame-sign argument (AGENTS.md §6), so no expressible model loses anything.
- **VerA today**: already decided and implemented as E0891. `lib/ir/lower/sysfunc.zig:160` enforces it, `ch09_system_tasks/232_limit_scaled_probe_rejected.va` pins it (`//! reject E0891`), and `231_limit_polarity_sign_argument_honoured.va` is the legal neighbour. ROADMAP §5.1 item 15 is stale. CHANGE NEEDED: close the ROADMAP row only (documentation).
- **Measure impact**: none (already counted).

### VD-016: A `.v` design as a contract device
- **Source**: ROADMAP §5.1 item 16.
- **Rule**: not an LRM reading. Project scope (ROADMAP §5.1).
- **Why vague**: it was an open product decision, not a reading of the standard.
- **Options**: n/a.
- **Decision**: `DECIDED:` implemented, as recorded in ROADMAP §5.1 item 16. The device runtime is in `src/sim/rt/device.zig`, and host tests pass at `15bb97ca` (2026-09-29). Remaining extensions are tracked elsewhere (`FUTURE_PLANS.md` §4).
- **VerA today**: `src/sim/rt/device.zig`, `tests/vdev_host.zig`, `tests/vdev_so_host.zig`. No change.
- **Measure impact**: none.

### VD-017: x/z as an analog display operand (17.1-06's analog half)
- **Source**: CLAUSE-AUDIT §7.5 item 1.
- **Rule**: VAMS 7.3.2: "Accessing digital net and digital binary constant operands are supported within analog context expressions. It is an error if these operands return x or z bit values when solved." x/z are admitted only through `===`, `!==`, `case`/`casex`/`casez` and x/z digit constants used in those comparisons. IEEE 1364-2005 17.1.1.4 (x/z display formatting) is inherited through VAMS 9.4.
- **Why vague**: CLAUSE-AUDIT §4.1 read 7.3.2 as making x/z legal analog display operands, which would make E0130 a refusal of legal source. `s01_SPEC.md` read the refusal as correct.
- **Options**: (a) x/z display operands are legal in analog, so the row is `missing`; (b) an x/z value reaching an analog operand other than a 7.3.2 comparison is an error, so the row is `verified on the prohibition`.
- **Decision**: `DECIDED:` (b). 7.3.2 lists the only constructs through which x/z may be accessed, and says any other operand that yields x/z "is an error". Its own `converter` example marks `var1 = 1'bx;` and `V(anet) <+ 1'bz;` as errors. A `$display` argument is an ordinary operand. 17.1.1.4 still governs the digital context.
- **VerA today**: the refusal matches (E0130, `lib/ir/lower.zig:500`, `lib/ir/lower/expr.zig:105`; `ch07_mixed_signal/x_literal_unsupported.va`, `xz_contribution_rejected.va`). But E0130's explanation (`lib/diag_code.zig:819-829`) says it is "not a claim that the literal is forbidden by full Verilog-AMS", which contradicts this reading. No fixture tests a display operand. CHANGE NEEDED: (1) rewrite E0130's explanation so that it cites 7.3.2 as a prohibition when the operand is not a 7.3.2 comparison; (2) add `reject_display_x_operand_analog.va` (`$display("%b", 1'bx)`, `//! reject E0130`) with a legal `1'b1` neighbour; (3) re-score CLAUSE-AUDIT 17.1-06 and close §7.5 item 1. Patch, since diagnostic wording is not in AGENTS.md §3's minor list.
- **Measure impact**: A (+1), C (7.3.2 refusal paired with its legal neighbour). B row 17.1.1.4 is unaffected because it is digital.

### VD-018: `d09_91` and excess `$readmem` data
- **Source**: CLAUSE-AUDIT §7.5 item 3.
- **Rule**: IEEE 1364-2005 17.2.9: "A warning message shall be issued if the number of data words in the file differs from the number of words in the range implied by the start through finish addresses and no address specifications appear within the data file."
- **Why vague**: the question was recorded as needing the 1364 text, namely whether excess data is an error. The text answers it: excess data gets a warning, and the load continues.
- **Options**: (a) error; (b) warning, with the excess dropped.
- **Decision**: `DECIDED:` (b), as the clause says. Loading stops at the finish address, and the warning is required.
- **VerA today**: matches. `ieee1364/17_system_tasks/d09_91_readmem_overflow_rejected.v` is now a positive fixture. It requires W1150 ("memory file data word count does not match load range"), its data file `91_readmem_overflow_rejected.hex` sits beside it, and `.expected.txt` is `11 22 33 44`. CHANGE NEEDED: update CLAUSE-AUDIT 17.2-21 and §7.5 item 3, which still say excess data is dropped silently and that `d09_91` "is run by nothing" (documentation only). Optional: rename the file to drop the misleading `_rejected`. Patch.
- **Measure impact**: none (B already counts it).

### VD-019: A parsed AST path is not `partial` (AMS-06 `driver_update`)
- **Source**: CLAUSE-AUDIT §7.5 item 4.
- **Rule**: not an LRM reading. House rule: CLAUSE-AUDIT §2 verdict definitions and AGENTS.md §2 ("Compiler acceptance is not runtime evidence").
- **Why vague**: CLAUSE-AUDIT §2 does not say whether a construct that parses and survives elaboration counts as "some of the clause".
- **Options**: (a) a surviving AST path counts as `partial`; (b) `partial` requires at least one of the clause's obligations executed with a recorded result.
- **Decision**: `DECIDED:` (b). Parsing is not an obligation of VAMS 9.22.5. The clause's obligation is that the statement executes on every driver update. This is the same line AGENTS.md §2 draws for "it compiles".
- **VerA today**: the premise is stale. `driver_update` now executes (`src/sim/digital/driver.zig`; AGENTS.md §7). `ch07_mixed_signal/m04_12_driver_update_without_resolved_change.va` asserts that it fires without a change in the resolved value, and `ch09_system_tasks/213_driver_update_in_analog_event_rejected.va` is the refusal. CLAUSE-AUDIT row AMS-06 still says `missing`. CHANGE NEEDED: re-score AMS-06 on today's fixtures (at least `partial`, `verified` if both directions hold) and close §7.5 item 4. Documentation only.
- **Measure impact**: none from the document (C is measured by `benchmark -- --coverage`).

### VD-020: Can a kernel unit test support `verified`?
- **Source**: CLAUSE-AUDIT §7.5 item 5.
- **Rule**: not an LRM reading. House rule: AGENTS.md §2: "Neither does a kernel unit test alone, a compiled `.c` file, or a SPICE deck paired with a JSON file: none of them runs the compiler's output in a host."
- **Why vague**: `zMonitor` (17.1-12) and `zCReal` (17.1-04) have unit tests at the exact boundary the device calls. CLAUSE-AUDIT counted those tests as enough in one row and not enough in another.
- **Options**: (a) a kernel test counts where the observable is rendered text; (b) a kernel test never counts alone.
- **Decision**: `DECIDED:` (b), which AGENTS.md §2 already settles. A kernel test can add to a verdict but never carries one.
- **VerA today**: 17.1-12 now has fixture evidence that runs the emitted device. `ch09_system_tasks/s01_05_monitor_suppresses_an_unchanged_step.va` and `s01_06_monitor_reports_every_change.va` carry no `//! xfail`, whereas CLAUSE-AUDIT recorded them as failing. 17.1-04 rests on `171_display_c_format_flags.va` and `s01_01`-`s01_04`. CHANGE NEEDED: re-score 17.1-12 on s01_05/s01_06 (confirm they pass in the FAIL name list first), and re-check that no other row rests on a kernel test alone. Documentation only.
- **Measure impact**: none (documentation).

## 2. Readings the standards leave open: Verilog-AMS (ROADMAP §5.6)

### VD-021: Multiline string literals
- **Source**: ROADMAP §5.6 bullet 1 (`conformance-strings-ledger-independent-review.md` at 8b1514d4, STR-REVIEW-01).
- **Rule**: VAMS 2.7: "A string literal is a sequence of characters enclosed by double quotes (") and contained on a single line." VAMS A.8.8: `string_literal ::= " { Any_ASCII_Characters } "`. Annex G change 2535: "Corrected definition for multiline strings" (A.8.8). IEEE 1364-2005 3.6 has the same single-line sentence, and its A.8.8 reads `Any_ASCII_Characters_except_new_line`.
- **Why vague**: the AMS prose keeps the inherited single-line rule, while the AMS production dropped the `_except_new_line` qualifier, and the change log calls that a correction "for multiline strings" without saying which direction it corrects in. Neither text says it overrides the other.
- **Options**: (a) refuse a raw newline inside a string (2.7, 1364 3.6); (b) accept it (A.8.8 as printed); (c) also accept the IEEE 1800 `\`-newline continuation.
- **Decision**: `DECIDED:` (a). A raw newline or a `\`-newline continuation inside a string is an error. The prose is the normative sentence that states the rule. The inherited 1364 text agrees with it in both prose and grammar. `Any_ASCII_Characters` is a placeholder that A.8.8 never defines. Change 2535 is informative and does not say what it allowed. Refusing is also the portable choice: what VerA accepts, a 1364-based tool accepts too. If an erratum later allows multiline strings, the rejection fixtures flip and nothing else changes.
- **VerA today**: refused, E0138 (`lib/frontend/lexer.zig` `stringRunaway`, test at :652); the continuation is refused too (lexer.zig:424-434). Fixtures: `ch02_lexical/19_multiline_string_rejected.va`, `38_string_line_continuation_rejected.va`, `annex_a_syntax/reject_A_8_8_string_spans_lines.va`, `ieee1364/03_lexical_conventions/b_3_6_string_spans_lines_rejected.v`. No change.
- **Measure impact**: none (pins existing behaviour; the fixtures' headers may cite this entry).

### VD-022: A raw TAB inside a string literal
- **Source**: ROADMAP §5.6 bullet 2 (STR-REVIEW-02).
- **Rule**: VAMS 2.3: "However, spaces and tabs shall be considered significant characters in strings (see 2.7)." VAMS 2.7: "Certain characters can only be used in a string literal when preceded by an introductory character called an escape character", and Table 2-2 lists `\t`.
- **Why vague**: read literally, 2.7 would require a tab to be escaped. 2.3 says that a literal tab in a string is significant, which assumes a literal tab can appear there.
- **Options**: (a) a raw TAB is legal and stands for byte 9; (b) a raw TAB is an error that requires `\t`.
- **Decision**: `DECIDED:` (a). 2.3 is the clause about white space and addresses tabs in strings by name. 2.3 would mean nothing if tabs could not appear unescaped. Table 2-2 shows how to write a tab, not a ban on the raw byte; the same table lists `\n`, and a raw newline is excluded separately by the single-line rule (VD-021). The 1364 parent text gives the same reading. Every mainstream Verilog front end accepts a raw tab in a string, though no specific tool was checked here.
- **VerA today**: accepted, value 9 (`lib/frontend/lexer.zig` `stringContents` copies non-backslash bytes). Fixtures: `ch02_lexical/audit_string_literal_tab_positions.va` (leading, interior and trailing tab, 3 checks), `68_string_whitespace_significant.va`. No change.
- **Measure impact**: none.

### VD-023: `op` attribute absent: is the value in the operating-point report?
- **Source**: ROADMAP §5.6 bullet 3, first question (`conformance-attributes-ledger-independent-review.md` ATTR-IR-03).
- **Rule**: VAMS 2.9.2: "If the attribute is specified with the value "no", then the parameter or variable will be omitted from the short report; otherwise, the parameter or variable will be included."
- **Why vague**: the word "otherwise" covers both an explicit "yes" and no `op` attribute at all. The clause also does not say which objects are eligible for the report.
- **Options**: (a) absent means included; (b) absent means excluded and only `op="yes"` is reported; (c) left to the tool.
- **Decision**: `DECIDED:` (a). The sentence makes "no" the only value that excludes, so everything else, absence included, is included. Eligibility is a separate question: the report covers §3.2.1 output variables (module-scope variables carrying `desc` or `units`) and parameters, and `op` only removes items from that set.
- **VerA today**: VerA checks the value domain only (`lib/ir/lower/param.zig` `checkAttributes`, E0358; `ch02_lexical/71_op_attribute_numeric_rejected.va`, `52_standard_attribute_domain_rejected.va`). The device publishes no operating-point report (no such table in `tools/contract.zig`), so there is nothing to change today. When a report table is added, its default must follow (a).
- **Measure impact**: none now; C (2.9) once a report exists and a fixture compares absent, "yes" and "no".

### VD-024: Keywords as attribute names (`units` is reserved)
- **Source**: ROADMAP §5.6 bullet 3, second question (ATTR-IR-04).
- **Rule**: VAMS 2.9 Syntax 2-4 and A.9.1: `attr_name ::= identifier`. Annex B reserves `units`. VAMS 2.9.2 standardizes "The units attribute", and its example writes `(* ... units="Ohms" ... *)` unescaped.
- **Why vague**: the standard's own attribute name is a keyword the grammar does not allow as `attr_name`. Read literally, the example is ungrammatical. The text does not say whether the exception covers only `units` or all keywords.
- **Options**: (a) only `units` is exempt and any other keyword is an error; (b) every keyword is accepted as a name; (c) `units` must be escaped.
- **Decision**: `DECIDED:` (a). `units` is legal because 2.9.2 standardizes it and prints it unescaped. Nothing grants the same exception to any other keyword, and IEEE 1364-2005 A.9.1 gives the same `attr_name ::= identifier`. A keyword used as an attribute name is refused with a named diagnostic; the legal form is an escaped identifier (`(* \module = 1 *)`). This keeps VerA's accepted set inside what a 1364/1800 front end accepts.
- **VerA today**: every keyword is accepted as an attribute name (`lib/frontend/parser.zig:580-585`: "every keyword is taken as a name"). CHANGE NEEDED: in `parseAttributes`, accept identifiers, escaped identifiers and `kw_units` only, and refuse any other keyword with E0208 (or a dedicated code) citing 2.9/A.9.1. Add a rejection fixture (`(* module *)`) with its legal neighbours (`(* \module *)`, `(* units = "V" *)`). Semver: minor (VerA newly refuses source).
- **Measure impact**: A (+2 fixtures); C (2.9 gains a refusal with a legal neighbour).

### VD-025: Forward parameter references
- **Source**: ROADMAP §5.6 bullet 4 (`conformance-parameter-core-ledger-review.md:43-45`).
- **Rule**: VAMS 3.4: the initializer "shall be a constant expression, that is, an expression containing only constant numbers and previously defined parameters." IEEE 1364-2005 4.10.1 uses the same words.
- **Why vague**: "previously defined" could mean earlier in the source text or earlier in dependency order. Some tools resolve parameters lazily and accept a forward reference.
- **Options**: (a) textual order, and a forward reference is an error; (b) dependency order, with only cycles refused.
- **Decision**: `DECIDED:` (a). Both standards say "previously", and a parameter port list or an earlier declaration is the only meaning that word has in a one-pass reading. Refusing keeps sources portable to strict tools. Whether Icarus, VCS or OpenVAF accept forward references was not established here.
- **VerA today**: refused, E0314. `ch03_data_types/58_forward_parameter_reference.va` pins it, and its header shows that swapping the two declarations makes the file legal. No change.
- **Measure impact**: none.

### VD-026: `min`/`max` with NaN or signed zero
- **Source**: ROADMAP §5.6 bullet 5 (`conformance-minmax-ledger-review.md:97-102`).
- **Rule**: VAMS 4.3.1, Table 4-14: `min(x, y)` has the "Equivalent C function" `fmin(x,y)` and the domain "All x, all y". The same clause says "these functions are defined so: min(x,y) is equivalent to (x < y) ? x : y; max(x,y) is equivalent to (x > y) ? x : y".
- **Why vague**: C `fmin(NaN, 1)` and `fmin(1, NaN)` both return 1, and C leaves the sign of `fmin(-0, +0)` open. The conditional form returns 1 for `min(NaN, 1)`, NaN for `min(1, NaN)`, and +0 for `min(-0, +0)`. The table and the prose disagree on unordered and signed-zero inputs.
- **Options**: (a) the conditional form for value and derivative alike; (b) C `fmin`/`fmax` for the value and the conditional form for the derivative only.
- **Decision**: `DECIDED:` (a). The conditional form is the only one of the two the clause states as a definition ("are defined so"), and it is exact on every input. Taking the value from one rule and the derivative from another could select one operand's value and the other's partials. The "Equivalent C function" column names a function family, not a bit-exact oracle. Constant folding must give the same bits as run time.
- **VerA today**: at run time, `zMin`/`zMax` use `a.lt(b).sel(a, b)` and `b.lt(a).sel(a, b)` (`lib/backend/codegen/kernel_text.zig:50-51`), which matches (a). The constant folder uses Zig's `@min`/`@max` for reals (`lib/frontend/constfold.zig:401-402`). Those return the non-NaN operand and leave the sign of a zero result unspecified, so a folded `min(1.0, NaN)` or `max(-0.0, 0.0)` can differ from the same expression at run time. CHANGE NEEDED: fold reals with `if (x < y) x else y` and `if (x > y) x else y`. Add a fixture comparing a folded and an unfolded `min`/`max` on NaN and ±0 operands with `CHECKEQ`/`CHECKX` against `1/x` signs. Semver: patch, or minor if a golden's emitted constant moves.
- **Measure impact**: A (+1 fixture); C (4.3.1 corner cases).

### VD-027: Nodesets before or after `analog initial`
- **Source**: ROADMAP §5.6 bullet 6 (`conformance-scheduling.md:35`).
- **Rule**: VAMS 8.2: "Once analog initial blocks are evaluated, analog net declaration assignments and simulator nodeset values are then applied." VAMS 8.4.1: "It is a one time execution of nodeset statements (3.6.3.2), then the procedural statements in analog initial block, and then the procedural statements in the Verilog initial block".
- **Why vague**: the two clauses give opposite orders for nodesets and `analog initial`.
- **Options**: (a) follow 8.2; (b) follow 8.4.1; (c) establish that the order cannot be observed.
- **Decision**: `DECIDED:` (c), and VerA follows 8.2 where it has to pick. A conforming source cannot observe the order. A 3.6.3.2 initializer "shall be a constant_expression", so it cannot read anything `analog initial` computes. Under 5.2.1, `analog initial` may not contain access functions, so it cannot read a nodeset. Both clauses agree that `analog initial` runs before the digital `initial` blocks. No fixture may assert an order between nodesets and `analog initial`.
- **VerA today**: nodesets are a comptime device table, `u_nodeset: [n]?f64` (`tools/contract.zig:3181-3185`), which the host applies at its solve. `analog initial` runs in `initState`. No change.
- **Measure impact**: none.

### VD-028: Does an `@()` body run once per timepoint or once per Newton iteration?
- **Source**: ROADMAP §5.6 bullet 7 (`a03_SPEC.md:284-291` at 8b1514d4).
- **Rule**: VAMS 5.10.3.3: "At that time point, the event evaluates to True." VAMS 8.3.3: "the behavioral description is evaluated iteratively until the NR method converges."
- **Why vague**: the event is true for the whole timepoint, and the analog block runs once per iteration, so the body could run several times at one timepoint. The text does not say whether its effects (a held counter, a file write) accumulate per iteration.
- **Options**: (a) the body's effects take effect once per accepted timepoint; (b) the effects accumulate per iteration.
- **Decision**: `DECIDED:` (a). The body may run on every iteration of the event timepoint, but each run starts from the last accepted state, and only the converged iteration's assignments and side effects are committed. The standard's own 5.10.2 `bitErrorRate` example counts bits and would give no usable count under (b). Reading (a) also makes the result independent of how many iterations the solver needs, which no source can control.
- **VerA today**: matches (a). Held variables are written back only in `updateState` ("writing from `eval` would latch a Newton iterate the solver may discard", `lib/backend/codegen/state.zig:512-525`). Display and file tasks run in the accepted-point phase. Fixtures `ch05_analog_behavior/a03_04`, `a03_05`, `a03_07`, `a03_10` and `a03_12` assume (a). No change.
- **Measure impact**: none.

### VD-029: Chapter 8's "canceling previous event" vs IEEE 9.2.2
- **Source**: ROADMAP §5.6 bullet 8 (`docs/ch8-scheduling.html` editorial note).
- **Rule**: VAMS 8.4.4 Figure 8-6 walkthrough: the nonblocking assign "schedules the actual assignment for 6ns (rounded 1ns delay), canceling previous event." IEEE 1364-2005 9.2.2 performs every queued nonblocking update in order.
- **Why vague**: the AMS example describes a second nonblocking assignment as cancelling the first, which 1364 never does. The example's inverter source is not printed.
- **Options**: (a) the example overrides 9.2.2 for this case; (b) 9.2.2 governs, and "canceling" describes what the D2A sees.
- **Decision**: `DECIDED:` (b). The text is an informative walkthrough, and AMS 1.1 inherits 1364's digital semantics whole. Read under 9.2.2, both updates are queued for 6 ns and performed in order, so B ends at the second value and the walkthrough's final line holds: "Value of B doesn't change". The "cancellation" is the D2A's driver look-ahead (`$driver_next_state`, 9.22) seeing the newer queued value before the transition filter ever starts, so no analog edge appears. No kernel event is removed.
- **VerA today**: the digital kernel performs both nonblocking updates. An earlier fixture that assumed cancellation was withdrawn (AGENTS.md §6, "The second NBA cancels the first"). Driver look-ahead is in `src/sim/digital/driver.zig`. No change.
- **Measure impact**: none.

### VD-030: `$simprobe` with a name built at run time
- **Source**: ROADMAP §5.6 bullet 9 (`conformance-ch9-review.md:313-316`).
- **Rule**: VAMS 9.16: "The arguments inst_name and param_name are string values, either a string literal, string parameter, or a string variable." Also: "If either the inst_name or param_name cannot be resolved, and the optional expression is not supplied, then an error shall be generated. If the optional expression is supplied, its value will be returned in lieu of raising an error."
- **Why vague**: a string variable's value is known only at run time. The clause does not say whether a tool may treat a name it cannot fold at compile time as "cannot be resolved" and return the fallback.
- **Options**: (a) resolve at run time against the sibling's output variables; (b) treat a non-constant name as unresolved and return the fallback, which is VerA today; (c) refuse a non-constant name with a named implementation-limit diagnostic.
- **Decision**: `DECIDED:` (a) is the reading of the clause. Until VerA implements it, (c) applies. "Cannot be resolved" is about whether the name exists, not about when the tool learns it, so returning the fallback for a valid run-time name gives a wrong answer with no diagnostic. A refusal that names the limit is better (AGENTS.md §4, "never open a gate without an executor").
- **VerA today**: `lib/ir/lower/hier_name.zig` (the `$simprobe` lowering, around :360-395) resolves only names that `constStrArg` folds. Otherwise it returns the third argument silently. With no third argument it reports E0817 "names no parameter of the elaborated design", which is misleading for a valid run-time name. CHANGE NEEDED: when either name does not fold, refuse with a dedicated diagnostic citing 9.16 ("a run-time $simprobe name is not supported"), whether or not a fallback is given, and record it as a limit in IMPLEMENTATION §2. Add a rejection fixture (a string variable name with a fallback) with a legal string-parameter neighbour. Semver: minor (VerA newly refuses source).
- **Measure impact**: A (+2 fixtures); C (9.16, refusal with a legal neighbour; the clause stays partial until (a) exists).

### VD-031: `$table_model` duplicate abscissa that cannot be proved equal
- **Source**: ROADMAP §5.6 bullet 10 (`MANIFEST.md:529-532` at 8b1514d4).
- **Rule**: VAMS 9.21: "Within the data set, each point shall be distinct in terms of its independent variable values. If there are two or more data points with the same independent and dependent values, then the duplicates shall be ignored ... If there are two or more data points with the same independent values but different dependent values then an error is generated."
- **Why vague**: the clause does not say when the error is diagnosed. A tool might refuse at elaboration any duplicate abscissa whose dependents it cannot prove equal.
- **Options**: (a) refuse at elaboration whenever equality is unproven; (b) refuse at elaboration only a proven conflict and check the rest when the data is captured (9.21.1, first call); (c) always check at capture.
- **Decision**: `DECIDED:` (b) and (c) both conform, and (a) does not. Under (a), a table whose duplicates turn out identical is refused, even though the clause says those duplicates "shall be ignored". Refusing at compile time is allowed only when both dependents fold and differ. Every other case is checked when the data source is captured.
- **VerA today**: (c). The conflict is checked at the call (`lib/backend/kernels/table_kernels.zig:447-463`, `ztDuplicateError`), and identical duplicates are dropped. `ch09_system_tasks/a05_13_duplicate_points.va` makes the conflicting dependent `94.0 + V(p,n)` so that no tool can decide it at elaboration. No change.
- **Measure impact**: none.

### VD-032: What counts as a change of a real value (0.0 to -0.0, NaN)
- **Source**: ROADMAP §5.6 bullet 11, first question (`conformance-wreal.md:15`, WR-006).
- **Rule**: VAMS 3.7 (wreal is a net, and 1.1 inherits 1364). IEEE 1364-2005 9.7.2: "An implicit event shall be detected on any change in the value of the expression." IEEE 1364-2005 6.1.2: "If the new value is different from the previous value, then the new value shall be assigned".
- **Why vague**: 1364 defines "change" for four-state bits only. For a real, "different" could be an IEEE 754 `!=` or a bit-pattern compare. The two differ for ±0, where `==` is true but the bits differ, and for NaN, which is unequal to itself.
- **Options**: (a) IEEE 754 `!=`: ±0 is no change, and a NaN written over a NaN is a change; (b) a bit compare.
- **Decision**: `DECIDED:` (a). It is the language's own real `!=` (1364 4.1.7), so `@(w)` fires exactly when `w != old` would be true in source. "Not a change" governs events only. The variable or net still holds the new bit pattern, so `1.0/w` after writing `-0.0` is `-inf`.
- **VerA today**: events follow (a) (`src/sim/digital/waiters.zig:134-137`; `tests/fixtures/digital/m04_03_wreal_event_on_change.v`). The new bits are copied only `if (changed)` (waiters.zig:140), so writing `-0.0` over `+0.0` leaves `+0.0` stored. CHANGE NEEDED: store the planes whenever they differ bitwise, and suppress only the event. Add a `.v` fixture: `r = 0.0; r = -0.0; $display("%g", 1.0/r)` prints `-inf`, and `@(r)` stays silent. Semver: patch (runtime value fix; no accepted/refused source or device text changes).
- **Measure impact**: B (1364 9.7.2 / 4.1.7 evidence); `test-devices` +1 case.

### VD-033: `m04_01` samples a declaration-assigned wreal at time 0
- **Source**: ROADMAP §5.6 bullet 11, second question (`conformance-wreal.md:29-34`).
- **Rule**: VAMS 3.7: "wreal nets shall have an initial value of zero." IEEE 1364-2005 11.3 (event regions): "Active events occur at the current simulation time and can be processed in any order." Those active events include a net declaration assignment's first evaluation and an `initial` block.
- **Why vague**: at time 0, `wreal seeded = 2.5;` reads 0.0 until its continuous assignment has run. An `initial` that `$display`s it at time 0 races with that assignment.
- **Options**: (a) keep the fixture's time-0 `2.5` expectation; (b) sample after `#0` (inactive region), when every active continuous-assignment update has been applied.
- **Decision**: `DECIDED:` (b). The fixture as written fails a conforming tool that runs the `initial` first and prints `0`. The undriven-wreal and plain-wire lines have no race and stay at time 0.
- **VerA today**: `tests/fixtures/digital/m04_01_wreal_undriven_zero.v` prints `decl_assigned_wreal_at_time_zero 2.5` from the first statement of the `initial`, with no delay, and VerA happens to order it after the assignment. CHANGE NEEDED (fixture only): put `#0;` before the `seeded` time-0 display (the two race-free lines may stay before it), and record the race in the header. Semver: patch (test only).
- **Measure impact**: none (a `test-devices` transcript; the expected output text is unchanged).

### VD-034: `posedge V(p)` in an analog event control
- **Source**: ROADMAP §5.6 bullet 12 (`annex_c_analog_subset/COVERAGE.md:192-196`).
- **Rule**: VAMS 5.10, Syntax 5-13: `analog_event_expression ::= expression | posedge expression | negedge expression | ...`. VAMS 5.10.5: "analog behavior can be made sensitive to digital events, including posedge events, negedge events". VAMS 7.3.6.2 times the "digital event, such as posedge or negedge".
- **Why vague**: the grammar derives `posedge` with any operand, including a continuous `V(p)`, but no sentence gives an edge of a continuous signal a meaning. 1364 9.7.2 defines edges only as four-state transitions (0 to 1, x, z and so on).
- **Options**: (a) refuse an edge whose operand is not discrete; (b) define it as a `cross` with direction ±1 at some threshold; (c) apply 1364's real-to-bit conversion to the operand.
- **Decision**: `DECIDED:` (a). 5.10.5 and 7.3.6.2 place `posedge`/`negedge` among the digital events, and the analog way to detect an edge is `cross` (5.10.3.1), which has a threshold and tolerances that a bare edge cannot express. Options (b) and (c) would each invent a threshold the standard never gives. A grammatical construct with no semantics is refused by name rather than given an invented meaning.
- **VerA today**: E0704 "posedge/negedge is digital-only" (`lib/ir/lower/event.zig:191-193`, `lib/diag_code.zig:4781`). `annex_c_analog_subset/21_digital_event_control_rejected.va` and `ch07_mixed_signal/contribution_under_a_digital_event_rejected.va` pin it, and the legal digital-operand neighbour is `ch07_mixed_signal/m01_04_posedge_in_an_analog_event_control.va`. No change.
- **Measure impact**: none.

### VD-035: A module-level `string` variable
- **Source**: ROADMAP §5.6 bullet 13 (`annex_a_syntax/COVERAGE.md:349-358`).
- **Rule**: VAMS A.2.8: `string_declaration` appears only as an arm of `analog_block_item_declaration`. A.2.1.3's `module_or_generate_item_declaration` does not list it. VAMS 3.3 gives "string variable_name [ = initial_value ] ;" and the example `parameter string default_name = "John Smith"; string myName = default_name;`.
- **Why vague**: Annex A derives no module-level string variable, while 3.3 grants one, and 3.3's example places it at module level next to a parameter.
- **Options**: (a) legal (3.3 governs, and the Annex A omission is a defect); (b) refused per Annex A.
- **Decision**: `DECIDED:` (a). 3.3 is the normative clause that introduces the type, and its example cannot be written inside a block. `real` and `integer` variables are module items, and nothing in the text suggests `string` is meant to be different. Refusing would reject the standard's own example.
- **VerA today**: accepted. `annex_a_syntax/03_declarations.va` writes `string label = "declarations";` at module level. No change.
- **Measure impact**: none.

### VD-036: An undefined escape such as `"\q"`
- **Source**: ROADMAP §5.6 last bullet, AMS part (`conformance-ams-lexical-core-review.md:170-172`; that file has 82 lines at 8b1514d4, so the cited lines no longer exist and the item is taken from the ROADMAP text).
- **Rule**: VAMS 2.7 / Table 2-2 lists `\n`, `\t`, `\\`, `\"` and `\ddd` only. IEEE 1364-2005 3.6.3, Table 3-1, lists the same five.
- **Why vague**: neither standard says what a backslash followed by any other character means, or whether it is an error.
- **Options**: (a) error; (b) accept, drop the backslash and keep the character; (c) accept and keep both bytes; (d) (b) plus a warning.
- **Decision**: `DECIDED:` (d). The source is lexically a string under A.8.8, so refusing it would reject models that write `"\%"` or similar by habit. Dropping the backslash is the C-family convention and keeps the literal's visible text. Since the meaning is VerA's choice and other tools may differ, a warning names it, so a portability hazard is never silent. What IEEE 1800, Icarus and VCS do with an undefined escape was not established here.
- **VerA today**: (b) with no diagnostic (`lib/frontend/lexer.zig:551-556`, "undefined escapes pass through"). No fixture pins it, and IMPLEMENTATION §1 has no row. CHANGE NEEDED: add a named warning for an escape outside Table 2-2. Add `ch02_lexical/` fixture `//! warn <code>` with `CHECKI("\q", 113)`, and an IMPLEMENTATION §1 row. Semver: patch (warning only; acceptance and device text unchanged).
- **Measure impact**: A (+1 fixture); none of B/C (implementation-defined, AGENTS.md: "a fixture here tests VerA's choice").

## 3. Readings the standards leave open: IEEE 1364 and VPI (ROADMAP §5.6)

### VD-037: A signed x/z operand under bitwise and conditional operators
- **Source**: ROADMAP §5.6, "IEEE 5.5.4" bullet (`conformance-ieee-expression-width-review.md` at 8b1514d4, "Source tensions").
- **Rule**: IEEE 1364-2005 5.5.4: "If any bit of a signed value is X or Z, then any nonlogical operation involving the value shall result in the entire resultant value being an X". Against 5.1.10 (bitwise truth tables) and 5.1.13 / Table 5-21 (ambiguous condition results).
- **Why vague**: "nonlogical" is not defined. Read broadly, it covers `&`, `|`, `^` and `?:`, which would make `4'sb10x1 & 4'sb0000` all x even though 5.1.10's bit tables give 0000. The bitwise and conditional clauses give bit-by-bit rules and do not mention signedness.
- **Options**: (a) all x for every non-logical operator, bitwise and conditional included; (b) arithmetic, relational and resizing operations get all x, while bitwise, reduction and conditional operators keep their per-bit tables.
- **Decision**: `DECIDED:` (b). The specific clauses (5.1.10's tables, 5.1.13's Table 5-21) govern their operators. 5.5.4 sits in 5.5 "Signed expressions", whose subject is evaluating arithmetic in a signed type. Its first two sentences cover resizing, so its third sentence covers arithmetic on that resized value. A bitwise operator works on bits, and signedness does not change those bits. Under (a), `0 & x` would give a different answer depending only on whether the operand was declared signed, and nothing else in Clause 5 depends on signedness that way. Icarus/VCS behaviour: not established.
- **VerA today**: Bitwise operators use the bit tables with no signedness check (`src/sim/digital/evaluate.zig:584`). An x/z condition combines both arms through Table 5-21 (`evaluate.zig:602`). Arithmetic gives all x (`ieee1364/05_expressions/b_5_5_4_signed_unknown_bits.v`, `audit_expr_unknown_extension.v`). No fixture pins a signed bitwise or conditional case. `CHANGE NEEDED:` add a positive `.v` fixture, for example `4'sb10x1 & 4'sb0000` -> `0000`, `4'sb10x1 | 4'sb0000` -> `10x1`, and `1'bx ? 4'sb10x1 : 4'sb10x1` -> `10x1`. Fixture only, so a patch.
- **Measure impact**: B: adds positive evidence to 5.5.4 (already `no-prohibition`), so no verdict change. A: +1 fixture.

### VD-038: Delay rule for a singleton `[0:0]` vector continuous assignment
- **Source**: ROADMAP §5.6, "IEEE 6.1.3" bullet (`conformance-vector-delay-fix.md` at 8b1514d4).
- **Rule**: IEEE 1364-2005 6.1.3: "If the left-hand references a scalar net, then the delay shall be treated in the same way as for gate delays", and "If the left-hand references a vector net, then up to three delays can be applied" (nonzero-to-zero falling, to z turn-off, otherwise rising). 4.3 (p. 28): "A net or reg declaration without a range specification shall be considered 1 bit wide and is known as a scalar. Multibit net and reg data types shall be declared by specifying a range, which is known as a vector."
- **Why vague**: `wire [0:0] w` is declared with a range, which suggests vector, but it is 1 bit wide, not "multibit". The two rules differ on a transition to x: the gate rule takes the minimum delay, the vector rule takes the rising delay.
- **Options**: (a) the declaration decides: any range makes it a vector; (b) the width decides: 1 bit takes the scalar (gate) rule.
- **Decision**: `DECIDED:` (b), width. 4.3 defines a vector by being "Multibit", and declaring a range is only how multibit nets are written. IEEE 26.6.5 (Ports, detail c) uses the same test: "vpiScalar and vpiVector shall indicate if the port is 1 bit or more than 1 bit". A 1-bit net has exactly one bit to which gate rise/fall/x/z semantics apply, so the vector rule's coarse "all other cases rising" approximation is not needed.
- **VerA today**: The driver metadata records width only, and width 1 keeps the scalar rule. This is already the decision (`conformance-vector-delay-fix.md` at 8b1514d4: "width1 keeps the scalar rule"). It is uncredited because no fixture covers `[0:0]`. `CHANGE NEEDED:` add a positive fixture with `wire [0:0] w; assign #(7,5,2) w = r;` where 0 -> x waits min = 2, next to a `wire [1:0]` neighbour where the same transition waits 7. Fixture only, so a patch.
- **Measure impact**: B: 6.1.3 gains a pinned case. A: +1 fixture.

### VD-039: A `config` declaration inside a lib.map file
- **Source**: ROADMAP §5.6, "IEEE 13.2.2 vs A.1.1 and Syntax 13-2" bullet.
- **Rule**: IEEE 1364-2005 13.2.2: "The syntax of a lib.map file is limited to library specifications, include statements, and standard Verilog comment syntax." Against A.1.1 / Syntax 13-2: `library_description ::= library_declaration | include_statement | config_declaration`.
- **Why vague**: The prose excludes configs from a map file, but the grammar derives one there.
- **Options**: (a) follow the grammar and accept a config in a map; (b) follow the prose and refuse it.
- **Decision**: `DECIDED:` (b). The prose is the specific normative statement about lib.map files. The grammar box is a superset that also serves `library_text` in general. 13.3 places configs in source text, where they are design elements (19.11 lists "module, primitive, or configuration" as design elements). Refusing loses nothing portable, since the config can move to a source file, while accepting it would create map files other tools may reject. Other tools: not established.
- **VerA today**: `lib/frontend/libmap.zig:161` refuses any keyword other than `library`/`include` with E0244 ("a library map holds `library` and `include` statements only (IEEE 1364-2005 §13.2.2)"). Pinned for a `module` by `ieee1364/13_configuration/b_13_2_2_source_text_in_map_rejected.v`, with legal neighbour `b_13_2_2_include_map.v`. No fixture puts a `config` in a map. `CHANGE NEEDED:` add a rejection fixture whose map holds `config cfg; design work.top; endconfig`, `//! reject E0244` and `found \`config\``. Fixture only, so a patch.
- **Measure impact**: B: 13.2.2 rejection evidence for the contested construct. A: +1 fixture.

### VD-040: A `$readmem` file address outside the memory when the task gives no bounds
- **Source**: ROADMAP §5.6, "IEEE 17.2.9" bullet, first question (`conformance-readmem-validation-edges.md:66-70` at 8b1514d4).
- **Rule**: IEEE 1364-2005 17.2.9: "When addressing information is specified both in the system task and in the data file, the addresses in the data file shall be within the address range specified by the system task arguments; otherwise, an error message is issued, and the load operation is terminated."
- **Why vague**: The error rule applies only when the task call also gives addresses. With no task bounds, `@8` into `reg [7:0] m[0:3]` matches no rule.
- **Options**: (a) silently drop the words; (b) treat the declared range as the implied range and apply the error, terminating the load; (c) warn, drop the out-of-range words, and keep loading at later in-range addresses.
- **Decision**: `DECIDED:` (c). A named run-time warning gives the address and the declared range, and words outside the declaration are skipped. (b) would extend an error rule the text explicitly conditions on task arguments, which would turn a run that is legal by the letter into a failure. (a) is a wrong answer with no diagnostic. The clause already uses a warning for the closest sibling case: "A warning message shall be issued if the number of data words in the file differs from the number of words in the range". Other tools: not established.
- **VerA today**: `src/sim/digital/display.zig:215` drops a word outside `low..high` with no message. `mismatch` (`:229`) is suppressed once the file has an address, so the case is entirely silent. `CHANGE NEEDED:` warn (a new W11xx or a W1150 variant) the first time an unbounded load's file address falls outside the declared range. Add a fixture `reg [7:0] m[0:3]` + `@8` that expects the warning and expects in-range words still loaded. Patch: no source acceptance or device text changes; a run-time warning appears.
- **Measure impact**: B: 17.2.9 (currently `-`) gains a pinned edge. A: +1 fixture.

### VD-041: x, z and `_` in a `$readmem` file address
- **Source**: ROADMAP §5.6, "IEEE 17.2.9" bullet, second question.
- **Rule**: IEEE 1364-2005 17.2.9: "the format is an at character (@) followed by a hexadecimal number ... @hh...h". For data words: "The unknown value (x or X), the high-impedance value (z or Z), and the underscore (_) can be used in specifying a number as in a Verilog HDL source description." 3.5.1: "The underscore character (_) shall be legal anywhere in a number except as the first character."
- **Why vague**: The x/z/_ permission is stated for data numbers. Addresses are "a hexadecimal number" with no statement either way.
- **Options**: (a) accept x/z/_ in addresses as in data; (b) accept `_` only, under 3.5.1; (c) hex digits only.
- **Decision**: `DECIDED:` (b). An address names one word, and an x or z address names none, so refuse it with the malformed-address error. An address is still "a hexadecimal number", and 3.5.1 makes `_` legal anywhere but first, including last. That gives: `@1_0` and `@10_` are legal, `@_10`, `@x` and `@?` are malformed.
- **VerA today**: `src/sim/digital/display.zig:192` parses with `std.fmt.parseInt(i64, .., 16)`. Measured 2026-10-04: `1_0` -> 16 and `1__0` -> 16 are accepted, `_10`, `x` -> InvalidCharacter, but **`10_` -> InvalidCharacter**, which 3.5.1 allows. Pinned: `ieee1364/17_system_tasks/audit_readmem_edge_address_bad_digit_rejected.v` (`@g`). `CHANGE NEEDED:` accept a trailing `_` in an address (strip underscores after the first character before parsing). Add fixtures: `@x` rejected (malformed address), and `@1_` legal next to it. Patch.
- **Measure impact**: B: 17.2.9 two-way evidence on address spelling. A: +2 fixtures.

### VD-042: Extended VCD strength 5, "large" or "pull"
- **Source**: ROADMAP §5.6, "IEEE 18.4.3.2" bullet (`conformance-vcd-review.md:137`, EVCD-017).
- **Rule**: IEEE 1364-2005 18.4.3.2: "Strength supply 7 to 5 (large): strong strength / Strength 4 to 1: weak strength". 18.4.3's list: "4 large, 5 pull, 6 strong, 7 supply".
- **Why vague**: The parenthetical calls 5 "large", while the numeric list makes 5 pull and 4 large.
- **Options**: (a) the numbers rule: 5..7 (pull, strong, supply) is the strong range and 1..4 weak; (b) the name rules: large (4) joins the strong range.
- **Decision**: `DECIDED:` (a). The boundary is given numerically twice ("7 to 5", "4 to 1"), and the label is a slip. 18.4.3.2 also limits drivers to "primitives, continuous assignments, and procedural continuous assignments", which drive only the 7.9 driving strengths (supply, strong, pull, weak). large is a trireg charge strength (Table 7-7) and can never appear as a driver's strength, so the name reading has nothing to apply to.
- **VerA today**: `src/sim/digital/evcd.zig:392-393` uses `>= 5`, the decision. The unit test `evcd.zig:426` covers only strong (6) against weak (3), and no case sits on the 5/4 boundary. `CHANGE NEEDED:` add a pull-vs-weak case to that test (`portState(.inout, pull0, weak0)` -> `d`) or to `ieee1364/18_vcd/b_18_4_3_port_value_changes.v`. Test only, so a patch.
- **Measure impact**: B: 18.4.3.2 boundary pinned. Otherwise none.

### VD-043: Does `` `resetall `` reset `` `begin_keywords ``?
- **Source**: ROADMAP §5.6, "IEEE 19.6, 19.11" bullet (`d10_SPEC.md:192-194` at 8b1514d4).
- **Rule**: IEEE 1364-2005 19.6: "When `resetall compiler directive is encountered during compilation, all compiler directives are set to the default values." 19.11: "Each `begin_keywords directive must be paired with an `end_keywords directive. The pair of directives define a region of source code".
- **Why vague**: "all compiler directives" would include the keyword version, but 19.11 defines `` `begin_keywords `` as a paired, nested region. A reset in the middle would leave the following `` `end_keywords `` unmatched.
- **Options**: (a) `` `resetall `` pops the keyword stack to the default; (b) the keyword region is unaffected.
- **Decision**: `DECIDED:` (b). 19.11 says "The `begin_keywords and `end_keywords directives only specify the set of identifiers that are reserved as keywords", and the reserved set holds "until the matching `end_keywords directive is encountered". A region closed only by its matching directive is not a directive setting with a "default value". Under (a), 19.6's recommended usage ("place `resetall at the beginning of each source text file") inside a `` `begin_keywords "1364-1995" `` region would break the pairing rule. VAMS 10.6 inherits this.
- **VerA today**: The parser skips `` `resetall `` at file level (`lib/frontend/parser/source.zig:70`), and the keyword stack (`source.zig:64`, `keywordsDirective`) is untouched. That is the decision, but no fixture pins it. `CHANGE NEEDED:` add a positive fixture: `` `begin_keywords "1364-1995" `` / `` `resetall `` / a module using `uwire` (2005-only) as an identifier / `` `end_keywords ``, compiles. Fixture only, so a patch.
- **Measure impact**: B: 19.6 and 19.11 (both `-`) gain a pinned interaction. A: +1 fixture.

### VD-044: Walking the design inside `vlog_startup_routines`
- **Source**: ROADMAP §5.6, "IEEE 26.2.4 vs AMS 12.33.2" bullet (`conformance-ieee-vpi-interface-review.md:24-31` at 8b1514d4).
- **Rule**: IEEE 1364-2005 26.2.4: "when the routines within the vlog_startup_routines[ ] array are executed, there is very little functionality available. Only two routines can be called at this time: vpi_register_systf() [and] vpi_register_cb()". VAMS 12.33.2 (= IEEE 27.34.2): "A means of initializing system task/function callbacks and performing any other desired task just after the simulator is invoked shall be provided by placing routines in ... vlog_startup_routines."
- **Why vague**: "any other desired task" reads as permission, while 26.2.4 restricts the same phase. The same sentence appears in IEEE 27.34.2, so the clash is inside 1364, not an AMS relaxation. VAMS 12.33.2 adds "This array of C functions shall be for registering system tasks and functions."
- **Options**: (a) allow every routine at startup (VerA today); (b) require phase-correct applications (register at startup, walk at `cbEndOfCompile`/`cbStartOfSimulation`), and have VerA refuse other routines during startup with an error status.
- **Decision**: `DECIDED:` (b). 26.2.4 is the specific rule for the phase. "Any other desired task" is satisfied by registering a callback that runs the task later, which is exactly what VAMS's own example does (`setup_report_cpu` registers a callback). A fixture that walks at startup passes only on tools that build the model early, so it is not portable. VerA should make the misuse visible: in the startup phase, any routine other than `vpi_register_systf`/`vpi_register_cb` (and `vpi_chk_error`) fails with a named `vpi_chk_error` message citing 26.2.4, and `vpi_register_cb` accepts only the four reasons listed there.
- **VerA today**: `src/vpi/root.zig:697` (`runStartupRoutines`) runs the array after the model is built, and every routine works. `tests/fixtures/ch11_vpi/vpi_app.c:501` does its whole walk in `vlog_startup_routines`. Of 77 `.c` fixtures, 42 mention `cbEndOfCompile`/`cbStartOfSimulation`, and the rest work at startup (not each re-read). `CHANGE NEEDED:` (1) move every `.c` fixture's work into a `cbEndOfCompile`/`cbStartOfSimulation` callback; (2) add a startup-phase gate in `src/vpi/root.zig` with an `lrm-reject`/`inherited-reject IEEE 1364-2005 26.2.4` fixture whose legal neighbour is `ieee_pli/b_26_1_systf.c`; (3) reclassify the 26.2.4 row in `ieee1364/CLAUSES.tsv` from `unspecified`. By AGENTS.md §3's list this is a patch (no source, device text or module_specs change), but it makes previously working applications fail, so release it as a minor.
- **Measure impact**: B: 26.2.4 gains two-way evidence. C: AMS 12.33.2 fixtures become portable. A: every `vpi_runs` fixture touched.

### VD-045: `vpiIsProtected` (prose) vs `vpiProtected` (Annex G)
- **Source**: ROADMAP §5.6, "IEEE 26.3.5 vs Annex G" bullet.
- **Rule**: IEEE 1364-2005 26.3.5: "All objects have a vpiIsProtected property ... Access to the vpiType property and the vpiIsProtected property of a protected object shall be permitted for all objects." Annex G vpi_user.h: `#define vpiProtected 10 /* source protected module (boolean) */`, and there is no `vpiIsProtected`. 26.6.1 lists `vpiProtected` as a module property.
- **Why vague**: The property every object must answer has no number in the normative header. The only number belongs to a differently named module property.
- **Options**: (a) leave it undefined and answer only on modules; (b) invent a new constant; (c) treat `vpiIsProtected` as `vpiProtected` (10) and answer it on every object.
- **Decision**: `DECIDED:` (c). Annex G is the ABI, and a made-up number (b) would make applications non-portable. A module "in a decryption envelope" is exactly a "source protected module", so the two coincide where both apply, and (c) makes 26.3.5's "all objects" true. VerA refuses `pragma protect` (E0146), so every object answers FALSE.
- **VerA today**: `src/vpi/vpi_user.h:381` defines `vpiProtected 10` (ROADMAP's "Neither is declared" is stale). `src/vpi/property.zig:158-161` answers 0 for modules and `propFail`s every other kind. `CHANGE NEEDED:` add `#define vpiIsProtected vpiProtected` (with a comment citing 26.3.5/Annex G) to `vpi_user.h`. Make `property.zig` answer 0 for every object kind. Add a `.c` fixture asserting `vpi_get(vpiIsProtected, h) == 0` on a net, a reg, a port and a module, and move the 26.3.5 `CLAUSES.tsv` row off `not-supported` for its FALSE half. Patch by AGENTS.md §3 (VPI result, not source or device text).
- **Measure impact**: B: 26.3.5 `not-supported` -> partial/verified for the FALSE half.

### VD-046: Is the current time queue in a `vpiTimeQueue` iteration?
- **Source**: ROADMAP §5.6, "IEEE 26.6.40(c) vs AMS 11.6.25 note 5" bullet (`conformance-ieee-vpi-objects-review.md:179-186` at 8b1514d4).
- **Rule**: IEEE 1364-2005 26.6.40(c): "The current time queue shall only be returned as part of the iteration if there are events that precede read only sync." VAMS 11.6.25 NOTE 5: "If any events after read only sync remain in the current queue, then it shall not be returned as part of the iteration."
- **Why vague**: The two conditions differ when the current time holds both an active-region event and a `cbReadOnlySynch`. IEEE returns the queue, while VAMS read literally does not.
- **Options**: (a) IEEE: return the queue iff some pending current-time event precedes read-only sync; (b) VAMS literal: omit the queue iff any read-only-sync-or-later item is pending.
- **Decision**: `DECIDED:` (a). It is the positive form of the source rule that VAMS paraphrases. Both agree that a current queue holding only read-only-sync work is omitted, and (a) answers the mixed case the useful way: the simulator still has work to do at this time. Read NOTE 5 as "if only events after read only sync remain".
- **VerA today**: `src/vpi/run.zig:313-343` (`timeQueues`) keeps `t == clock` whenever any scheduler event or time callback is pending at the current time. `src/vpi/callback.zig:187` counts `cbReadOnlySynch` (and `cbReadWriteSynch`) as time callbacks, so a lone pending `cbReadOnlySynch` puts the current queue in the iteration, which is wrong under both readings. `ch11_vpi/p02_05_cb_time_regions.c` asserts only times strictly greater than now. `CHANGE NEEDED:` at `t == clock`, count only scheduler events and pre-read-only callbacks (`cbReadWriteSynch`), not `cbReadOnlySynch`. Add a `.c` case for each side: only RO-sync pending, so the current queue is absent; an active event pending, so it is present. Patch.
- **Measure impact**: B: 26.6.40 (`-`) gains evidence. C: VAMS 11.6.25 NOTE 5 pinned.

### VD-047: A callback wake-up at an eventless time is a `vpiTimeQueue` entry
- **Source**: ROADMAP §5.6, "AMS 11.6.25, 12.16, 12.27: p02 conventions", the time-33 entry (`p02_SPEC.md:382-395` at 8b1514d4).
- **Rule**: VAMS 11.6.25 NOTE 4: "vpi_iterate() shall return NULL if there is nothing left in the simulation queue", and the diagram relates callback to time queue (`vpiParent`). VAMS 12.31.2: "A callback can be set for any time, even if no event is present."
- **Why vague**: No sentence says whether a time that holds only a callback is a time queue.
- **Options**: (a) yes, a time callback is a scheduled wake-up and its time is a queue; (b) only HDL events make a queue.
- **Decision**: `DECIDED:` (a). The simulator must stop at that time to run the callback, so it is in "the simulation queue". The data model gives a callback a time-queue parent, which (b) would leave dangling. Other tools: not established.
- **VerA today**: Matches. `src/vpi/callback.zig:557` (`pendingTimes`) feeds `run.zig:322`. `ch11_vpi/p02_05_cb_time_regions.c` asserts the t=33 entry. No change.
- **Measure impact**: none.

### VD-048: `vpi_mcd_printf`'s return value for a multi-channel write
- **Source**: ROADMAP §5.6, p02 conventions, `vpi_mcd_printf` (`p02_SPEC.md:341-343` at 8b1514d4).
- **Rule**: VAMS 12.27 / IEEE 1364-2005 27.26: "Returns: PLI_INT32 The number of characters written." and "Several channels can be written to simultaneously".
- **Why vague**: For an mcd with k channels, the characters "written" could be one expansion or k times it.
- **Options**: (a) the length of the formatted text, once; (b) the length times the number of channels written.
- **Decision**: `DECIDED:` (a). The routine is defined as the C `fprintf` analogue ("A format string using the C fprintf() format"). Its count describes the message, so a caller can compare it with its own `vsnprintf` length whatever the mcd. Under (b), the same call returns different values as files open and close. A failed channel is reported through EOF and `vpi_chk_error`, not through the count.
- **VerA today**: Matches. `src/vpi/print.zig:746` expects 6 for `"alpha\n"` to two channels, `print.zig:751` expects EOF on failure, and `ch11_vpi/p02_09_printf_mcd.c` covers it. No change.
- **Measure impact**: none.

### VD-049: `vpiIntVal` read of an object wider than 32 bits
- **Source**: ROADMAP §5.6, p02 conventions, `vpiIntVal` on a 64-bit object (`p02_SPEC.md:426-427` at 8b1514d4).
- **Rule**: VAMS 12.16 Table 12-4 / IEEE 1364-2005 27.14: "vpiIntVal ... Integer value of the handle. Any bits x or z in the value of the object are mapped to a 0". `value.integer` is `PLI_INT32`.
- **Why vague**: Nothing says what a 64-bit `time` or `reg [63:0]` gives when it does not fit in a `PLI_INT32`.
- **Options**: (a) the low 32 bits, two's complement; (b) an error (`vpiBadFormat`); (c) saturate.
- **Decision**: `DECIDED:` (a). This is the language's own rule for putting a wide value in a 32-bit integer: IEEE 5.6, where truncation of the high bits happens without a diagnostic. It is also how the integer-valued C fields are documented, and `vpiVectorVal`/`vpiTimeVal` remain for the full value. (b) would refuse reads of every `time` variable.
- **VerA today**: `src/vpi/value.zig:321` does `@truncate(b.low64())` to u32 and bitcasts it, which matches the decision. No fixture asserts it. `CHANGE NEEDED:` add a `.c` assertion: `reg [63:0] r = 64'h1_8000_0001` reads `vpiIntVal == (PLI_INT32)0x80000001`. Patch.
- **Measure impact**: B/C: 27.14 / 12.16 gain a pinned edge.

### VD-050: `$q_exam` with a `q_stat_code` outside Table 17-15
- **Source**: ROADMAP §5.6, last bullet (`conformance-ieee-queue-review.md:26-47` at 8b1514d4). ROADMAP cites "17.6.4", but `$q_exam` is IEEE 1364-2005 17.6.5 and its status table is 17.6.6.
- **Rule**: IEEE 1364-2005 17.6.5, Table 17-15 defines codes 1-6. 17.6.6: "All of the queue management tasks and functions return an output status code", and Table 17-16 (0-7) has no "bad statistic code" row.
- **Why vague**: An unknown code has no defined status and no defined value.
- **Options**: (a) status 2 "Undefined q_id"; (b) a new status 8; (c) status 0 with no value; (d) refuse a constant out-of-range code at compile time and give a nonzero status at run time.
- **Decision**: `DECIDED:` (d). A constant `q_stat_code` outside 1..6 is refused with a named diagnostic citing Table 17-15. A run-time value outside it returns status 2 and leaves `q_stat_value` unchanged. 2 is the nearest Table 17-16 row (the request names nothing the queue defines), it stays inside the table every portable caller checks, and a nonzero status is the observable failure. (b) invents a code no other tool knows. (c) reports success for a request that has no answer.
- **VerA today**: `src/sim/digital/system.zig:128` returns `undefined_id` (2) at run time for any other code and assigns no value (`out[1]` null). A constant bad code is not refused at compile time. `CHANGE NEEDED:` refuse a constant code outside 1..6 (E1100-style, citing Table 17-15), with a rejection fixture whose legal neighbour is `ieee1364/17_system_tasks/b_17_6_5_q_exam.v`. Add a run-time fixture (code from a variable = 7) expecting status 2 and an unchanged value. Minor (newly refused source).
- **Measure impact**: B: 17.6.5 (`-`) gains two-way evidence. A: +2 fixtures.

### VD-051: `$q_exam` code 3, "Maximum queue length"
- **Source**: ROADMAP §5.6, last bullet ("code 3 reports the observed peak").
- **Rule**: IEEE 1364-2005 17.6.5, Table 17-15: "3 Maximum queue length". The clause introduces the task as providing "statistical information about activity at the queue q_id".
- **Why vague**: "Maximum queue length" may mean the `max_length` given to `$q_initialize` or the largest length the queue has reached.
- **Options**: (a) the configured `max_length`; (b) the observed peak.
- **Decision**: `DECIDED:` (b). The task reports "statistical information about activity", and its siblings (codes 2, 4, 5, 6) are all measurements of history. The configured limit is an input the caller already passed and can read back through `$q_full`'s behaviour, so returning it would not be a statistic.
- **VerA today**: Matches: `system.zig:103` tracks `q.peak` and `:122` returns it. `ieee1364/17_system_tasks/audit_queue_capacity_stats.v` cannot tell the readings apart (both are 2). `CHANGE NEEDED:` add a fixture with `max_length` 4 and a peak of 2 that expects 2. Fixture only, so a patch.
- **Measure impact**: B: 17.6.5 gains a discriminating case. A: +1 fixture.

### VD-052: `$q_exam` mean statistics (codes 2 and 6) in an integer result
- **Source**: ROADMAP §5.6, last bullet ("means use integer division").
- **Rule**: IEEE 1364-2005 17.6.5, Table 17-15: "2 Mean interarrival time", "6 Average wait time in the queue". No rounding rule is given. IEEE 1364-2005 3.5.3: "Real numbers shall be converted to integers by rounding the real number to the nearest integer, rather than by truncating it."
- **Why vague**: A mean is generally not an integer, but `q_stat_value` is an integer argument, and the clause gives no conversion.
- **Options**: (a) truncating integer division (VerA today); (b) the exact mean converted by the language's real-to-integer rule, rounding to nearest with ties away from zero.
- **Decision**: `DECIDED:` (b). When the language puts a non-integral value into an integer it rounds, and it says so explicitly "rather than by truncating it". Truncation is an artefact of computing in integers. An empty population (no interarrivals, no completed waits) stays 0.
- **VerA today**: `src/sim/digital/system.zig:121` (`interarrival_sum / interarrivals`) and `:127` (`wait_sum / waits`) truncate. No fixture asks codes 2 or 6 (`b_17_6_5_q_exam.v` deliberately skips them). `CHANGE NEEDED:` compute `(2*sum + n) / (2*n)` (non-negative round half up, which equals ties away from zero here). Add a fixture whose mean is x.5 (for example, arrivals at 0, 2, 5 give a mean interarrival of 2.5, so 3). Patch (run-time value, no source or device text change).
- **Measure impact**: B: 17.6.5 statistics pinned. A: +1 fixture.

## 4. Implementation-defined choices: Verilog-AMS (IMPLEMENTATION.md §1)

### VD-053: Octal escape above `\377`
- **Source**: IMPLEMENTATION §1 row "AMS 2.7"
- **Rule**: VAMS 2.7, Table 2-2 (and IEEE 1364-2005 3.6.3, same text): "Implementations may issue an error if the character represented is greater than \377."
- **Why vague**: the clause permits an error and says nothing about what a tool that does not issue one should produce. `\400`..`\777` names no byte.
- **Options**: (a) accept and keep the low 8 bits silently (today); (b) accept with a warning; (c) refuse with a named error.
- **Decision**: `DECIDED:` (c), refuse with a named lexer error that cites §2.7. The clause itself offers the error. Any value VerA picks for a 9-bit escape is VerA's own invention, and keeping it silently is a wrong answer with no diagnostic. Source that is legal on every tool cannot use such an escape anyway, because some tool may refuse it, so refusing it costs portable designs nothing. Legal neighbour: `\377`.
- **VerA today**: `lib/frontend/lexer.zig:542-549` accumulates into a u16 and `@truncate`s with no diagnostic (the IMPLEMENTATION row cites 532-539, which is stale). `ch02_lexical/octal_escape_above_377_keeps_low_byte.va` pins the acceptance.
  `CHANGE NEEDED:` a new E01xx "octal escape above \377" diagnostic. Turn the fixture into `//! reject <code>` and add a `\377` legal neighbour. Update the IMPLEMENTATION row. **Minor**, because source that VerA accepted is now refused.
- **Measure impact**: A (the fixture flips to a rejection and a neighbour is added). C: §2.7 gains a pinned invalid form.
- **Status**: DONE: E0148, `ch02_lexical/octal_escape_above_377_rejected.va` and its neighbour `octal_escape_377_largest_byte.va`.

### VD-054: Identifier length limit
- **Source**: IMPLEMENTATION §1 row "AMS 2.8"
- **Rule**: VAMS 2.8: "Implementations may set a limit on the maximum length of identifiers, but the limit shall be at least 1024 characters."
- **Why vague**: the limit is the tool's choice, and an error is required only past whatever limit the tool sets.
- **Options**: a fixed limit of 1024 or more with an error past it; no limit.
- **Decision**: `DECIDED:` no limit. VerA stores identifiers as slices of the source, so no buffer imposes a bound. The only real ceiling is the filesystem's file-name length for build products, and `fileStem` hashes the name to get under it. No limit satisfies "at least 1024", and the error obligation never triggers.
- **VerA today**: `src/main.zig` `fileStem`. Fixtures `ch02_lexical/28_identifier_1024_chars.va` and `identifier_1024_char_module_name.va`. No change.
- **Measure impact**: none.

### VD-055: How the integer-modulus zero-divisor error is reported
- **Source**: IMPLEMENTATION §1 row "AMS 4.2.4"
- **Rule**: VAMS 4.2.4: "It shall be an error to pass zero (0) as the second argument to the modulus operator."
- **Why vague**: the clause gives no phase (compile or run time) and no form for the error. A compiled device has no I/O channel.
- **Options**: compile-time only, which misses runtime zeros; a runtime result such as 0 or the dividend, which is silent; a runtime report or trap.
- **Decision**: `DECIDED:` a divisor that is provably zero is E0601 at compile time. A zero found at run time is E0601 plus exit 1 in an executable, and a trap in a device with no host I/O. This is the only reading in which "shall be an error" is never silent. An operand that is never evaluated does not fail.
- **VerA today**: `lib/ir/proof/prover.zig`, `lib/backend/codegen/render.zig` `imodFn`, E0601 text at `lib/diag_code.zig:4526`. Fixtures `ch04_expressions/111_modulus_by_zero_rejected.va`, `modulo_integer_dynamic_zero.va`, `modulo_integer_unused_zero.va` and the legal neighbours. No change.
- **Measure impact**: none.

### VD-056: Real modulus by a runtime zero yields NaN
- **Source**: IMPLEMENTATION §1, the prose note under "Host math" ("Modulus with real operands retains its existing NaN behavior")
- **Rule**: VAMS 4.2.4: "It shall be an error to pass zero (0) as the second argument to the modulus operator." The same clause then gives the real-operand formula `a % b = ((a/b) < 0) ? ... : (a - floor(a/b)*b)`.
- **Why vague**: the error sentence names no operand type. The real formula divides by b, so IEEE arithmetic gives NaN, and that makes NaN look like an acceptable "defined" result.
- **Options**: (a) NaN at run time (today), with W0650 only for losing the finiteness proof; (b) the same runtime report or trap as the integer path.
- **Decision**: `DECIDED:` (b). The error sentence comes before the real formula and covers both types, and VerA already reads it that way at compile time: `audit_real_modulus_zero_rejected.va` pins E0601 for `5.5 % 0.0`. Treating a runtime real zero differently from a compile-time one is a silent wrong answer, and a NaN in a Newton residual surfaces far from its cause.
- **VerA today**: E0601's explain text (`lib/diag_code.zig:4541-4542`) says "real `%`: x % 0.0 is NaN, IEEE-defined". `CHANGE NEEDED:` route a real `%` whose divisor is not provably nonzero through the same runtime E0601 report or trap as `imodFn`. Add a `modulo_real_dynamic_zero.va` rejection-at-run-time fixture beside a legal real-modulus neighbour. Update E0601's explain text and the IMPLEMENTATION note. **Minor**, because emitted device text changes.
- **Measure impact**: A (one new fixture). C: §4.2.4's real half becomes two-way at run time.

### VD-057: `idt` with no `ic`: the starting constant c
- **Source**: IMPLEMENTATION §1 row "AMS 4.5.4, 4.5.5"
- **Rule**: VAMS 4.5.4, Table 4-18: "c is the initial starting point as determined by the simulator and is generally the DC value (the value that makes expr equal to zero)". The prose adds that without ic "the idt operator must be contained within a negative feedback loop that forces its argument to zero. Otherwise the output of the idt operator is undefined."
- **Why vague**: c is left to the simulator, and the output is undefined when no loop exists.
- **Options**: c = 0 always; let the static solve choose c so that expr = 0, which is the DC reading the table says is "generally" used; a mix of the two.
- **Decision**: `DECIDED:` the mix VerA already implements. When the argument reads an unknown, the static solve keeps the row `-x`, so c is whatever the feedback loop forces, as the table and prose describe. When the argument reads no unknown, there is no loop and the output is undefined; VerA takes 0, the value an ic of 0 gives, which keeps the static Jacobian regular. "c = 0" in the IMPLEMENTATION row describes only the second case.
- **VerA today**: `lib/ir/lower/analog_op.zig:199-226` (`opIdt`, `readsUnknown`). Fixtures `exhaustive/062_idt_integral.va` and `ch04_expressions/idt_no_ic_dc_feedback.va`. `CHANGE NEEDED:` documentation only. Reword the IMPLEMENTATION row to say: "argument reads an unknown: the static solve forces it to zero (c from the loop); otherwise c = 0", and cite `idt_no_ic_dc_feedback.va`. Patch.
- **Measure impact**: none.

### VD-058: `idtmod` with no `ic`: the table and the prose disagree
- **Source**: IMPLEMENTATION §1 row "AMS 4.5.4, 4.5.5"
- **Rule**: VAMS 4.5.5, Table 4-19, `idtmod(expr)`: "c is the initial starting point as determined by the simulator". The prose below the table says: "If the initial condition is not specified, it defaults to zero (0). Regardless, the initial condition shall force the DC solution to the system."
- **Why vague**: the table makes c a tool choice, and the prose fixes it at 0.
- **Options**: (a) treat c as tool-defined, as the table does; (b) treat it as 0, as the prose does.
- **Decision**: `DECIDED:` (b). The prose is the more specific normative sentence ("defaults to zero") and is the only one with "shall". VerA's c = 0 is therefore required by the clause, not chosen.
- **VerA today**: `zIdtmod` (`lib/backend/codegen/kernel_text.zig:504`) starts at ic, and the ic is 0 when omitted. The header of `ch04_expressions/idtmod_one_argument_starts_at_zero.va` calls the starting point "the tool's choice", and `17_idtmod.va` "declines" to assert it. `CHANGE NEEDED:` documentation and fixture headers only. Move idtmod out of the implementation-defined row. Rewrite the `idtmod_one_argument_starts_at_zero.va` header to quote the prose sentence as the requirement. Patch.
- **Measure impact**: C. The fixture now evidences a §4.5.5 requirement instead of a tool choice; whether the count moves depends on the §4.5.5 row in `CLAUSE-AUDIT.md`.

### VD-059: Where `idtmod` integrates
- **Source**: IMPLEMENTATION §1 row "AMS 4.5.5" (where)
- **Rule**: VAMS 4.5.5 gives the mathematical integral and the wrap range (`offset <= idtmod < offset+modulus`) and says nothing about numerical method or ownership.
- **Why vague**: the clause does not say whether the integrator is a solver unknown (as `idt` is under §4.5.2) or internal state.
- **Options**: (a) a host unknown, as for `idt`; (b) state inside the device, wrapped on each accepted step.
- **Decision**: `DECIDED:` (b). As a host unknown the unwrapped state grows without bound, and a free-running VCO's phase loses precision with the rounding of |s|. That defeats the operator's purpose (the `ponytail:` note at `lib/ir/lower/analog_op.zig:206-209`). Known ceiling: the device integrates with a first-order rule (`zIdtAcc`: `acc + v*dt`) outside the host's truncation-error control. The upgrade is a host unknown that re-bases on each wrap.
- **VerA today**: `lib/backend/codegen/kernel_text.zig:500-511` (`zIdtAcc`, `zIdtmod`; the row's `:434` is stale). Fixtures `ch04_expressions/17_idtmod.va` and `a04_08_idtmod_offset_window_negative_integrand.va`. No change.
- **Measure impact**: none.

### VD-060: `absdelay` interpolation is not implementation-defined
- **Source**: IMPLEMENTATION §1 row "AMS 4.5.7"
- **Rule**: VAMS 4.5.7: "When calculating the output at time t, the absdelay() operator will use linear interpolation as needed to determine the input around time" max(t - td, 0).
- **Why vague**: it is not vague. The IMPLEMENTATION row lists interpolation as left open, but the clause names linear interpolation.
- **Options**: the row has none to offer; linear is the clause's answer.
- **Decision**: `DECIDED:` linear interpolation is required. `(* vera_interp = 2 *)` (quadratic) is a §2.9 vendor extension that deliberately departs from §4.5.7 on the author's request, and it is not a choice the clause leaves open.
- **VerA today**: linear by default (`lib/backend/codegen/kernel_text.zig`, the `absdelay` kernels; `absdelay_vera_interp_linear.va`, `absdelay_vera_interp_quadratic.va`). `CHANGE NEEDED:` documentation only. Move the row's interpolation entry under the `vera_*` attribute row, labelled "departs from §4.5.7 when set", and let `absdelay_vera_interp_linear.va` cite §4.5.7 as a requirement. Patch.
- **Measure impact**: C, if the linear fixture becomes §4.5.7 evidence.

### VD-061: DC value of a `laplace_*` filter with a pole at s = 0
- **Source**: IMPLEMENTATION §1 row "AMS 4.5.11" (DC)
- **Rule**: VAMS 4.5.11 gives H(s) for each form and says a zero root "is implemented as s". It has no DC rule (unlike §4.5.4's `idt` and §4.5.7's `absdelay`).
- **Why vague**: H(0) is infinite, and the clause gives no initial-state or feedback reading.
- **Options**: (a) 0, the state starting at 0; (b) the `idt` feedback reading, where the static solve forces the input to 0; (c) refuse.
- **Decision**: `DECIDED:` (a). The filter's states live in the device (`filter_kernels`), so no host unknown exists for the static solve to choose. 0 is what §4.5.4 gives an `idt` whose argument has no loop, and refusing a legal filter would be wrong. A common power of s cancels first, so `s/(s + s^2)` is 1. Known divergence: an `idt` in a feedback loop takes its DC from the loop (VD-057), and a `laplace_nd(x, {1}, {0,1})` in the same loop does not. A model needing that should use `idt`.
- **VerA today**: `lib/backend/kernels/filter_kernels.zig:95-111` (`zH0`; the row cites the stale `lib/backend/filter_kernels.zig`). Fixture `ch04_expressions/laplace_nd_pole_at_origin.va`. No change beyond the path fix, which goes with VD-057's row edit.
- **Measure impact**: none.

### VD-062: Root vectors from the model card: pairing conjugates at run time
- **Source**: IMPLEMENTATION §1 row "AMS 4.5.11, 4.5.12"
- **Rule**: VAMS 4.5.11.1-4.5.11.3 and 4.5.12.1-4.5.12.3: "If a root is complex, its conjugate shall also be present." 4.5.11 also says a vector "may be represented as ... a reference to a vector parameter".
- **Why vague**: a parameter vector's values arrive with the card, so "shall also be present" cannot be checked at compile time. The clause gives no pairing tolerance and no runtime outcome.
- **Options**: (a) refuse every parameter root vector; (b) pair at run time with a tolerance and give a defined failure for an unpaired root; (c) pair blindly.
- **Decision**: `DECIDED:` (b). A complex root pairs with the first unused root within 1e-9·|a+jb| of its conjugate. An unpaired root makes every coefficient NaN, so the output is visibly wrong in every analysis, never a different filter reported as this one. An odd-length vector is refused at compile time (E0540). Refusing (a) would reject legal designs the clause explicitly allows. 1e-9 relative absorbs card round-off from text such as `1.0e3` against `1000` without merging distinct roots.
- **VerA today**: `lib/backend/cg_filters.zig` `filterSide`/`runtimeRoots`, `lib/backend/kernels/filter_kernels.zig:127-165` (`zRootSecs`, `zroot_tol`). Fixtures `laplace_zp_parameter_roots_step.va`, `laplace_np_parameter_roots_unpaired_is_nan.va`, `reject_4_5_11_1_laplace_zp_parameter_roots.va`. No change, apart from fixing the stale `filter_kernels.zig` path in the row.
- **Measure impact**: none.

### VD-063: Analysis names beyond Table 4-21
- **Source**: IMPLEMENTATION §1 row "AMS 4.6.1"
- **Rule**: VAMS 4.6.1: "Any unsupported type names are assumed to not be a match."
- **Why vague**: which names a tool supports beyond the table is the tool's choice.
- **Options**: support vendor names (`pss`, `hb`, `pac`); none.
- **Decision**: `DECIDED:` none. VerA's hosts run only Table 4-22's columns. Any other name is false, as the sentence requires, with no diagnostic: a Spectre-only branch such as `analysis("pss")` is portable source and must compile quietly.
- **VerA today**: `lib/backend/codegen/call.zig:896-920` (`analysisMatch`). Fixture `ch04_expressions/143_analysis_transient.va`. A non-literal argument is already E-coded (`lib/diag_code.zig:4511`). No change.
- **Measure impact**: none.

### VD-064: The small-signal analysis name
- **Source**: IMPLEMENTATION §1 row "AMS 4.6.3"
- **Rule**: VAMS 4.6.3: "The name of a small-signal analysis is implementation dependent, although the expected name (of the equivalent of a SPICE AC analysis) is “ac”, which is the default value of analysis_name."
- **Why vague**: the name is explicitly implementation-dependent.
- **Options**: "ac"; a vendor name.
- **Decision**: `DECIDED:` "ac", the name the clause expects and the default of `ac_stim`, so `ac_stim()` with no name is active in VerA's only small-signal analysis.
- **VerA today**: `lib/ir/lower/contrib.zig` (the `ac_stim` lowering), fixture `ch04_expressions/a06_ac_stim_ac_analysis.va`. No change.
- **Measure impact**: none.

### VD-065: `time_tol` of a `.v` contract device's A2D bridge
- **Source**: IMPLEMENTATION §1 row "AMS 5.10.3.1" (`.v` device)
- **Rule**: VAMS 5.10.3.1: time_tol and expr_tol "represent the maximum allowable error between the true crossing point and when the event triggers". Clause 7.8 supplies connect modules but gives a bare `.v` device none.
- **Why vague**: a `.v` device has no connect module, so no source states the crossing's time_tol.
- **Options**: a fixed absolute value; a fraction of the edge time; none (crossings at step ends).
- **Decision**: `DECIDED:` the card's `ttol`, defaulting to min(trise, tfall)/50. Scaling with the edge keeps the timing error proportionate on both nanosecond and microsecond pins, where a fixed absolute value is too tight on one and too loose on the other. The host can override it through the card, and only a step where some process wakes is held to it.
- **VerA today**: `src/sim/rt/device.zig:461-462`. Covered by `tests/vdev_host.zig` ("v_edge and v_any"). No change.
- **Measure impact**: none.

### VD-066: Event tolerances on the fixed-grid testbench
- **Source**: IMPLEMENTATION §1 row "AMS 5.10.3.1, 5.10.3.3"
- **Rule**: VAMS 5.10.3.1 requires the event inside the box set by time_tol and expr_tol. VAMS 5.10.3.3: "If time_tol is not specified, the default time point is at, or just beyond, the time of the event."
- **Why vague**: the tolerances, when absent, are the tool's, and a fixed-grid harness cannot insert a point.
- **Options**: insert points (a variable-step solver); fire at the next grid point with a warning; refuse such fixtures.
- **Decision**: `DECIDED:` the pure analog testbench is a harness, not a host. It fires at the first `//! time` point past the event and says so with W0750. A grid with no `//! analysis` line is `tran`. The device still publishes the event and its breakpoint correctly, and a fixture whose reasoning needs an inserted point runs on the mixed path (AGENTS.md §7).
- **VerA today**: `lib/backend/tb/runner.zig:83` (`warnGridEvents`). Fixture `ch05_analog_behavior/event_cross_fires_on_a_time_grid.va`. No change.
- **Measure impact**: none.

### VD-067: `absdelta` default tolerances
- **Source**: IMPLEMENTATION §1 row "AMS 5.10.3.4"
- **Rule**: VAMS 5.10.3.4: "If a value of zero (0.0) is specified, the simulator shall apply a suitable value." "If the tolerances are not specified, then the tool (e.g., the simulator) sets them." Also: "A specified time_tol that is smaller than the time precision is ignored and the time precision is used instead."
- **Why vague**: "suitable" is undefined.
- **Options**: tolerances from the expression's nature abstol; small fixed constants.
- **Decision**: `DECIDED:` time_tol 1 ps, at least the digital time precision; expr_tol 1e-12 in the expression's units. The expression may be dimensionless or of any nature, so no nature tolerance applies in general. A tiny expr_tol never suppresses an event the clause requires, and it only lets more reversal events through. The interpolated delta crossing is used where eligible, and otherwise the first time outside the time_tol exclusion, both of which the clause permits.
- **VerA today**: `src/sim/mixed.zig:161-163` (`default_time_tol`, `default_expr_tol`), `absdeltaArgs`. Fixtures `ch07_mixed_signal/absdelta_runtime_default_tolerances.va`, `absdelta_runtime_time_precision.va`, `absdelta_runtime_time_tol.va`, `absdelta_runtime_reversal.va`. No change.
- **Measure impact**: none.

### VD-068: Discipline resolution mode (basic only)
- **Source**: IMPLEMENTATION §1 row "AMS 7.4.4.2"
- **Rule**: VAMS 7.4.4. This one is decided in VD-008, so see that entry.
- **Decision**: `DECIDED:` as in VD-008. This row only records that `lib/ir/elaborate/resolve.zig` implements basic mode and `ch07_mixed_signal/lrm_7_4_4_1.va` pins it.
- **VerA today**: no change from this row.
- **Measure impact**: see VD-008.

### VD-069: `$ferror` error codes
- **Source**: IMPLEMENTATION §1 row "AMS 9.5.7, 1364 17.2.7"
- **Rule**: VAMS 9.5.7 (and IEEE 1364-2005 17.2.7): "The integral value of the error code is returned in errno. If the most recent operation did not result in an error, then the value returned shall be zero".
- **Why vague**: only zero is defined. Nonzero values and the text are the tool's.
- **Options**: host errno passed through (varies by OS); fixed C/POSIX values; one generic code.
- **Decision**: `DECIDED:` fixed C errno values (ENOENT 2, EIO 5, EBADF 9, EACCES 13, EISDIR 21, EINVAL 22, EMFILE 24, ENOSPC 28), the same numbers on every host. The clause's own example names the variable `errno`, and the file tasks mirror C stdio. Fixing the numbers keeps a design's output identical across hosts, which a pass-through would not. Fixtures assert only "nonzero", so another tool's codes also conform.
- **VerA today**: `lib/backend/kernels/file_kernels.zig:227` (the row's `lib/backend/file_kernels.zig:216` is stale). Fixtures `ch09_system_tasks/053_ferror.va` and `write_mode_path_65_fails_open.va`. No change beyond the path fix.
- **Measure impact**: none.

### VD-070: `$stop` in a batch run
- **Source**: IMPLEMENTATION §1 row "AMS 9.7.2"
- **Rule**: VAMS 9.7.2 inherits IEEE 1364-2005 17.4.2: `$stop` "causes simulation to be suspended". VerA's artifacts have no interactive mode to suspend into.
- **Why vague**: the clause assumes an interactive simulator and is silent on batch runs.
- **Options**: exit 0 after the diagnostic; exit nonzero; ignore and continue.
- **Decision**: `DECIDED:` print the `$stop` diagnostic and exit 0, the same as `$finish`. Continuing would run past a point the author asked to halt at, and a nonzero exit would report a deliberate stop as a failure. Icarus `vvp -n` makes `$stop` act like `$finish` in the same way.
- **VerA today**: `lib/backend/cg_display.zig:266-272` and the test at `:1109`. Fixture `ch09_system_tasks/174_stop_terminates.va`. No change. Out of scope here: §12.36 says compliant simulators "must support" `vpiStop`/`vpiReset`, and `src/vpi/vpi_user.h:909-911` leaves them out deliberately. That needs its own entry.
- **Measure impact**: none.

### VD-071: Seed of an omitted-seed analog `$random`/`$arandom`
- **Source**: IMPLEMENTATION §1 row "AMS 9.13.1"
- **Rule**: VAMS 9.13.1: the seed "may be omitted, in which case the simulator picks a seed."
- **Why vague**: the clause gives no value, no rule for per-site independence, and no reproducibility rule.
- **Options**: one shared stream; a time- or entropy-based seed; a distinct deterministic seed per site.
- **Decision**: `DECIDED:` a distinct deterministic seed per site, `1 + 7919*k`, where k numbers the non-variable-seed sites in lowering order. Determinism makes reruns reproducible, which fixtures and regression decks need. Distinct sites do not share or correlate a stream, and 7919 is prime and spreads the seeds. Known ceiling: adding a site earlier in the source renumbers later sites' streams.
- **VerA today**: `lib/ir/lower/random.zig:127` (the row cites `lib/ir/lower/event.zig` `lowerRandom`, which is stale). Covered by `tests/revert_host.zig` and `ch09_system_tasks/115_random_no_seed.va`. No change beyond the path fix.
- **Measure impact**: none.

### VD-072: Which `$simparam` names exist, and whether `gmin` and `sourceScaleFactor` are constants
- **Source**: IMPLEMENTATION §1 row "AMS 9.15"
- **Rule**: VAMS 9.15: "There is no fixed list of simulation parameters. However, simulators shall accept the strings in Table 9-27 to access commonly-known simulation parameters, if they support the parameter." Table 9-27 describes `gmin` as "Minimum conductance placed in parallel with nonlinear branches" and `sourceScaleFactor` as the "Multiplicative factor for independent sources for source stepping homotopy".
- **Why vague**: the list is open, and the supported set and the values are the tool's.
- **Options**: per name, either a compile-time constant, a host-written `Model` field, or unknown (E0811 when no fallback is given).
- **Decision**: `DECIDED:` keep the list (Table 9-27's `gmin`, `tnom`, `scale`, `shrink`, `sourceScaleFactor`, `iteration`, `timeUnit`/`timePrecision`, plus SPICE's `reltol`/`abstol`/`vntol` and `dt`). Make `gmin` and `sourceScaleFactor` host-written, as `tnom` and the three tolerances already are. Both are host solver settings that a host changes during a run: gmin stepping and source-stepping homotopy are exactly what the table describes them for. A compile-time 1e-12 or 1.0 is the value VerA assumes, not the one the host is using. `scale` and `shrink` stay 1.0, because geometry scaling is applied when the card is built. Unsupported table names (`gdev`, `imax`, `imelt`, `simulatorVersion`) stay unknown, as "if they support the parameter" allows.
- **VerA today**: `lib/ir/lower/sysfunc.zig:519-537` returns `gmin` = 1e-12 and `sourceScaleFactor` = 1.0 as constants, with the comment "a device compiled here is never being stepped". `host_simparams` at `:556-561` lists only tnom, reltol, abstol and vntol. `CHANGE NEEDED:` add `gmin__` (default 1e-12) and `source_scale__` (default 1) rows to `host_simparams`, and add a host-written fixture beside `simparam_newton_tolerances_host_written.va`. **Minor**, because emitted device text and `Model` fields change.
- **Measure impact**: A (one new fixture). C: no change.

### VD-073: Which `$limit` built-ins exist, and what an unknown name does
- **Source**: IMPLEMENTATION §1 row "AMS 9.17.3" (built-ins)
- **Rule**: VAMS 9.17.3: "Simulators may support other built-in functions and need not support pnjlim or fetlim. If the string refers to an unknown or unsupported function, the simulator is responsible for determining the appropriate limiting algorithm, just as if no string had been supplied." Also: "the simulator may simply choose to have $limit() return the value of its first argument". Table E.2 lists the preferred names.
- **Why vague**: the set of names and the fallback algorithm are both the tool's.
- **Options**: refuse unknown names; return the probe silently; return the probe with a warning.
- **Decision**: `DECIDED:` support `pnjlim`, `pnjlimds`, `fetlim`, `fetlimds`, `limvds` and `steplim`, which cover Table E.2's names and the compact models' usual calls. An unknown name, or a bare `$limit(x)`, returns the probe, as the clause allows, and warns W0853 naming the reason. A misspelt algorithm silently losing its limiting is a convergence bug the author needs to see. Refusing it would reject legal source.
- **VerA today**: `lib/backend/codegen/plan/limit.zig`. Fixture `ch09_system_tasks/227_limit_unknown_algorithm_returns_probe.va` (`//! warn W0853`) and the `annex_e_spice/limit_*.va` set. No change.
- **Measure impact**: none.

### VD-074: `$limit` arguments past the algorithm's own (sign, seed) and the initial junction seed
- **Source**: IMPLEMENTATION §1 rows "AMS 9.17.3" (arguments; starting value)
- **Rule**: VAMS 9.17.3: "Two additional arguments to the $limit() function are required when the second argument to the limit function is the string “pnjlim”", and one for "fetlim". Nothing is said about further arguments or about the first iteration's value.
- **Why vague**: arguments after the required ones are not addressed, and neither is the starting value of the limiter's state. SPICE's MODEINITJCT, which compact models rely on, has no Verilog-AMS spelling.
- **Options**: refuse extra arguments; ignore them; give them a defined meaning.
- **Decision**: `DECIDED:` an optional frame sign, then an optional seed, both documented in AGENTS.md §6. More arguments decline the site with W0853. Unseeded `pnjlim` legs start at vcrit, which is what SPICE's junction initialisation does. A seed that reads the solution is E0527, and one the tree cannot take is W0854. This is VerA's extension in a slot the clause leaves empty. Portability note: another tool may treat the extra arguments differently, so a model meant to be portable should keep to the required arguments and accept the default seeding.
- **VerA today**: `lib/backend/codegen/plan/limit.zig`. Fixtures `231_limit_polarity_sign_argument_honoured.va`, `limit_too_many_arguments_returns_probe.va`, `annex_e_spice/limit_seed_*.va` and `reject_limit_seed_reads_solution.va`. No change.
- **Measure impact**: none.

### VD-075: The number of `vpiRejectTransientStep`
- **Source**: IMPLEMENTATION §1 row "AMS 12.36"
- **Rule**: VAMS 12.36 defines `vpiRejectTransientStep` ("cause the current analog simulation time point to be rejected"). The LRM prints no `#define` for it, and the other AMS constants in `vpi_user.h` are not from the LRM text either.
- **Why vague**: there is no normative number.
- **Options**: any value outside 1364's `vpi_sim_control` operations (`vpiStop` 66 through `vpiSetInteractiveScope` 69).
- **Decision**: `DECIDED:` 730, the free slot in VerA's AMS constant block (720-744, between `vpiFlowNature` 729 and `vpiPotentialNature` 731). It cannot collide with a 1364 operation. A portable application uses the symbol, never the number.
- **VerA today**: `src/vpi/vpi_user.h:915-918`. Fixture `ch12_vpi_routines/p03_12_sim_control_reject_step.c`. No change. Note: `vpiTransientFailConverge` (same clause) has no definition, which is a gap outside this entry.
- **Measure impact**: none.

### VD-076: SPICE flavour and primitive behaviour (E.1, E.2)
- **Source**: IMPLEMENTATION §1 row "AMS E.1, E.2"
- **Rule**: VAMS E.1/E.2. This one is decided in VD-012, so see that entry.
- **Decision**: `DECIDED:` as in VD-012. This row records only today's `.MODEL`/`.SUBCKT`-only reader (`lib/frontend/spice_cards.zig`).
- **VerA today**: no change from this row.
- **Measure impact**: see VD-012.

### VD-077: No warning when a module shadows an always-available SPICE primitive
- **Source**: IMPLEMENTATION §1 row "AMS E.3.3"
- **Rule**: VAMS E.3.3: for a primitive, "The Verilog-AMS simulator may issue a warning stating that the Verilog-AMS module or paramset is used instead of the SPICE primitive." For a model or subcircuit it "shall issue an warning message".
- **Why vague**: the primitive warning is optional.
- **Options**: warn; stay silent.
- **Decision**: `DECIDED:` silent for primitives, and W0951 for the required model/subcircuit case. Writing one's own `resistor` or `capacitor` module is routine Verilog-AMS (the LRM's own examples do it), so a warning would fire on ordinary libraries and teach users to ignore warnings. The required half is already implemented.
- **VerA today**: `lib/ir/elaborate/names.zig` `warnSpiceShadows`. Fixtures `annex_e_spice/spice_paramset_primitive_shadow.va`, `spice_module_shadow_warning.va` and `spice_paramset_shadow_warning.va`. No change in code. `CHANGE NEEDED:` documentation only. ROADMAP §5.2's AMS E.3.3 row ("No warning when a module shadows a SPICE model or subcircuit") is stale now that W0951 exists; delete it. Patch.
- **Measure impact**: none.

### VD-078: Where a device's temperature lives (ABI 6: the Model row)
- **Source**: IMPLEMENTATION §1 "Device ABI 6" (cites "§9.10")
- **Rule**: VAMS 9.15: "$temperature does not take any input arguments and returns the circuit’s ambient temperature in Kelvin units." §9.10 is "Simulator time system functions" and says nothing about temperature, so the IMPLEMENTATION cite is wrong.
- **Why vague**: "the circuit's ambient temperature" suggests one value per circuit. Per-instance temperature (SPICE `dtemp`/`temp`) is a host feature the LRM does not mention.
- **Options**: per circuit (global); per instance; per Model row.
- **Decision**: `DECIDED:` per Model row. It is a superset of the per-circuit reading the clause describes, and it still lets a host give one instance its own temperature by giving it its own row. It also keeps the whole solve-invariant cache a function of the row: measured `Instance` shrink of 3,520 to 200 bytes on bsim4va.
- **VerA today**: `Model.temperature__`, `contract.host_model_fields` (`tools/contract.zig`). `CHANGE NEEDED:` documentation only. The IMPLEMENTATION "Device ABI 6" prose should cite VAMS §9.15, not §9.10. Patch.
- **Measure impact**: none.

### VD-079: Host-supplied hierarchical system parameters outside Table 9-29's domains
- **Source**: IMPLEMENTATION §1 prose note "For AMS §9.18, E0890 ..." (dynamic domains not validated)
- **Rule**: VAMS 9.18, Table 9-29, column "Allowed values": `$mfactor > 0`, `$hflip`/`$vflip` = +1 or -1, `0 <= $angle < 360`.
- **Why vague**: the table states allowed values but no "shall be an error" and no point at which a value is checked. A value set on a host card is known only at card time.
- **Options**: check only literals at compile time (today); check card-dependent values when the host writes the card; trust the host.
- **Decision**: `DECIDED:` check at card time. An "allowed values" column is a constraint, and a value outside it, such as `$mfactor = 0`, silently zeroes or flips a device. Card time (`derive`, which runs once per card write) costs nothing per `eval`. The device should report the offending name in the way `checkShape` already reports one, and a host that ignores the report stays the host's choice. The same entry point would carry §3.4.2 `from` range checks for host-written cards, which are also unchecked today; that is outside this entry.
- **VerA today**: E0890 for literals only (`lib/diag_code.zig:5003`). There is no card-time check: `lib/backend/codegen/file.zig:583` `derive` and `:645` `checkShape` validate nothing about domains. `CHANGE NEEDED:` emit a card-time domain check, either a `checkCard(model) ?[]const u8` returning the first parameter out of Table 9-29's domain or the same check inside `derive`, together with a host test such as `tests/geometry_host.zig` that writes `$mfactor = 0` and expects the name back. **Minor**, because emitted device text changes.
- **Measure impact**: A (a new host test, under `zig build test`). C: §9.18 gains a runtime invalid-input test.

## 5. Implementation-defined choices: IEEE 1364 (IMPLEMENTATION.md §1, §3)

### VD-080: UDP input limit
- **Source**: IMPLEMENTATION §1 row "1364 8.1.2"; §2 row "UDP inputs".
- **Rule**: IEEE 1364-2005 8.1.2: "Implementations may limit the maximum number of inputs to a UDP, but they shall allow at least 9 inputs for sequential UDPs and 10 inputs for combinational UDPs."
- **Why vague**: the clause sets a floor and leaves the ceiling to the tool.
- **Options**: (a) the floors, 9/10; (b) a fixed larger cap with a named refusal; (c) no cap.
- **Decision**: `DECIDED:` (b), 64 inputs for both kinds, refused past it with E1017. 64 is above both floors by a wide margin (a full table over 64 inputs is not a practical design) and keeps a row's input column a fixed-size array; (a) would refuse portable designs other tools take, (c) buys nothing and gives no diagnostic to name.
- **VerA today**: `lib/frontend/parser/udp.zig:171` `max_udp_inputs = 64`, refused at `:85` (E1017). Fixtures `ieee1364/08_udp/b_8_1_2_input_minimums.v`, `b_8_1_2_sequential_64_inputs.v`, `b_8_1_2_udp_more_than_64_inputs_rejected.v`. No change. (IMPLEMENTATION cites `lib/frontend/parser/source.zig`; the constant is in `parser/udp.zig`: a doc path fix.)
- **Measure impact**: none.

### VD-081: Order of active events
- **Source**: IMPLEMENTATION §1 row "1364 11.4.2".
- **Rule**: IEEE 1364-2005 11.4.2: "active events can be taken off the queue and processed in any order."
- **Why vague**: the order is explicitly nondeterministic; a tool must still run them in some order, and a user sees it in any race.
- **Options**: (a) source-order FIFO; (b) LIFO; (c) randomised order (to flush out races).
- **Decision**: `DECIDED:` (a) processes start in source order from a FIFO queue, and woken processes resume in the order they suspended; the interpreter and native code agree. It is the order users of event-driven simulators expect from a deterministic run (and what Icarus does in the common cases, though no tool's order is a contract), it makes runs reproducible, and the native/interpreter agreement means `--state`/backend choice never changes a racy design's output. Randomising (c) is a debugging aid, not a default.
- **VerA today**: `src/sim/scheduler.zig`, `src/sim/digital/exec.zig`; `ieee1364/11_scheduling/audit_sched_fork_arm_chain_order.v`, `audit_sched_fork_arm_wake_order.v`, `audit_sched_node_wake_order.v` pin it and cite no clause, as they must (VD-082). No change.
- **Measure impact**: none.

### VD-082: Tests over clauses that permit several outcomes
- **Source**: IMPLEMENTATION §3 "Unspecified behaviour" (1364 5.1.4, 11.4.2, 11.5, 12.3.10.1, 12.3.10.2).
- **Rule**: e.g. IEEE 1364-2005 11.5: "The simulator is correct in displaying either a 1 or a 0."; 5.1.4: "the entire expression need not be evaluated"; 12.3.10: merging dissimilar nets is permitted, not required.
- **Why vague**: these clauses permit a set of outcomes; a fixture asserting one of them tests the tool, not the standard.
- **Options**: (a) assert VerA's outcome under the clause tag; (b) assert membership in the permitted set, or pick inputs where every permitted outcome agrees, and pin VerA's own order only in untagged fixtures; (c) leave the clause untested.
- **Decision**: `DECIDED:` (b), as CLAUSE-AUDIT §5.5 already says. A clause-tagged fixture may assert only what every conforming tool prints; VerA's particular choice is pinned by a fixture that cites no clause and is listed in IMPLEMENTATION §1.
- **VerA today**: followed: `ieee1364/11_scheduling/audit_sched_allowed_active_race.v` (membership), `ieee1364/12_hierarchy/b_12_3_10_net_type_warning.v` (merge-independent cells). But `tests/fixtures/ieee1364/CLAUSES.tsv` has 13 `unspecified` rows (5.1.4, 11.4.2, 11.5, 12.3.10.1, 12.3.10.2, 20.2, 26.1, 26.2.4, 26.6.16, 26.6.21, 27.20, 27.34, 27.34.1) and IMPLEMENTATION §3 lists five. `CHANGE NEEDED:` IMPLEMENTATION §3 should list all 13 (or say "every `unspecified` row of CLAUSES.tsv") and name each row's fixture policy. Doc only, patch.
- **Measure impact**: none (B's `unspecified` rows are already classified).

### VD-083: Which of several configs configures the design
- **Source**: IMPLEMENTATION §1 row "1364 13.4.4".
- **Rule**: IEEE 1364-2005 13.4.4: "In the case where the config includes a design statement, then the specified cell shall be the top-level module, regardless of the presence of any uninstantiated cells in the rest of the source files."
- **Why vague**: the clause speaks of "the config" as if there were one. With several configs in the compiled source (13.3.2 hierarchical configs reach a second config only through a `use ... :config` clause), nothing says which one sets the top, and the command-line mechanism 13.4.4 assumes is tool-specific.
- **Options**: (a) the first config in source order; (b) the last; (c) the config no other config's `use` clause names, refusing when there are zero or several such; (d) require a CLI flag naming the config.
- **Decision**: `DECIDED:` (c). It is the configuration analogue of 12.1.1's "uninstantiated module is a top", it needs no flag VerA does not have, and it never silently picks between two candidates: two unreferenced configs, or none, is E0243 naming 13.4.4. (d) is what commercial tools do through their command line, but VerA's CLI table (ARCHITECTURE §4.7) was declined; (a)/(b) make the design depend on file order without a diagnostic.
- **VerA today**: implemented: `src/sim/digital/bind.zig:107-117` `top` (E0243, "configurations `a` and `b` are both unreferenced", "every configuration is named by another's `use` clause"). `ieee1364/13_configuration/b_13_3_2_hierarchical_config.v` passes and is no longer an xfail. `CHANGE NEEDED:` (1) IMPLEMENTATION §1's row still says "not implemented ... (xfail)": correct it; (2) no fixture pins either E0243 refusal (grep finds neither phrase under `tests/fixtures`): add `b_13_4_4_two_unreferenced_configs_rejected.v` and `b_13_4_4_every_config_referenced_rejected.v`, each with `//! reject` on its distinctive phrase, legal neighbour `b_13_3_2_hierarchical_config.v`. Fixtures and docs only: patch.
- **Measure impact**: A (+2 fixtures); B: gives 13.4.4 its rejection half if the row is not already two-way.

### VD-084: `$ungetc` pushback depth, and which reads see it
- **Source**: IMPLEMENTATION §1 row "1364 17.2.4.1".
- **Rule**: IEEE 1364-2005 17.2.4.1: `$ungetc` "inserts the character specified by c into the buffer specified by file descriptor fd. The character c shall be returned by the next $fgetc call on that file descriptor." NOTE: "The features of the underlying implementation of file I/O on the host system limit the number of characters that can be pushed back onto a stream."
- **Why vague**: the depth is left to the host; the clause names only `$fgetc` as the reader of a pushed character, though it says the character goes into the descriptor's buffer, which every read routine (17.2.4.2-17.2.4.4) reads.
- **Options**: depth: 1 (C's only guarantee), a fixed N with EOF past it, unbounded. Readers: `$fgetc` only, or every read routine (C `ungetc` semantics).
- **Decision**: `DECIDED:` depth 16 per descriptor, the 17th push returns EOF (the clause's own error value), never a silently dropped character. Every read routine reads the pushback before the file: "the buffer specified by fd" is the descriptor's buffer, and 17.2's routines are modelled on C stdio, where `fgets`/`fscanf`/`fread` after `ungetc` read the pushed character. A push at file position 0 may stay refused (EOF): the NOTE leaves pushback to the host, and C leaves the position after it indeterminate; document it.
- **VerA today**: `lib/backend/kernels/file_kernels.zig:77` `back: [16]u8`, `zFUngetc` at `:518` (EOF when full or at `pos == 0`); the comment at `:75-76` says "`$fgets`/`$fscanf` after an `$ungetc` read the file". Fixture `ieee1364/17_system_tasks/b_17_2_4_1_ungetc_pushback_limit.v`. `CHANGE NEEDED:` (1) `$fgets`, `$fscanf` and `$fread` consume `back` before the file, with a fixture (`b_17_2_4_1_ungetc_then_fgets.v`: push "Z", `$fgets` returns a line starting "Z"); this changes the run-time file kernel every generated program links, so minor; (2) IMPLEMENTATION's row should state the position-0 refusal and give the path `lib/backend/kernels/file_kernels.zig` (it says `lib/backend/file_kernels.zig:74`); (3) the doc comment at `file_kernels.zig:514` cites §17.2.4.2 for `$ungetc`, which is 17.2.4.1.
- **Measure impact**: A (+1 fixture); B: strengthens 17.2.4.1.

### VD-085: Which bit an mcd `$fopen` returns
- **Source**: IMPLEMENTATION §1 row "1364 17.2.1, 27.25".
- **Rule**: IEEE 1364-2005 17.2.1: "The multichannel descriptor mcd is a 32-bit reg in which a single bit is set indicating which file is opened. The least significant bit (bit 0) of an mcd always refers to the standard output." 27.25: the mcds of `vpi_mcd_open()` and `$fopen` "may be shared". VAMS 12.24/12.27 predefine channel 2 (stderr) and channel 3 (the log file), i.e. mcd bits 1 and 2.
- **Why vague**: 1364 reserves bits 0 and 31 only and says nothing about allocation order; the AMS VPI clauses reserve two more channels that 1364's `$fopen` does not know about.
- **Options**: (a) lowest free bit from 1, always; (b) lowest free bit from 3, always (AMS channels kept free even without VPI); (c) (a) without a VPI application, (b) under one, with one table shared between `$fopen` and `vpi_mcd_open`.
- **Decision**: `DECIDED:` (c). An mcd is an opaque handle: a portable design ORs and passes descriptors and never depends on which bit it got, so the only obligations are "one bit, never 0 or 31, reused after close, shared with VPI". Under VPI the AMS channels must stay distinct, so allocation starts at channel 4; without VPI nothing claims bits 1-2 and (a) keeps the full 30 channels.
- **VerA today**: `lib/backend/kernels/file_kernels.zig` `zFOpen` (first free slot, 30 slots shared by mcds and fds), `src/vpi/print.zig` `share`, `openChannel` (`first_user = 3`, channel 4). Fixture `ieee_pli/b_27_mcd.c`. No change. (IMPLEMENTATION cites `lib/backend/file_kernels.zig`; the file is `lib/backend/kernels/file_kernels.zig`.)
- **Measure impact**: none.

### VD-086: The stream of a seedless digital `$random`
- **Source**: IMPLEMENTATION §1 row "1364 17.9.1".
- **Rule**: IEEE 1364-2005 17.9.1, Syntax 17-17 `$random [ ( seed ) ]`: "The seed argument controls the numbers that $random returns so that different seeds generate different random streams."
- **Why vague**: the seed is optional and the clause says nothing about where a seedless call's stream starts, or whether call sites share it.
- **Options**: (a) one hidden seed per run starting at 0, shared by all seedless calls, advanced by the 17.9.3 listing; (b) one hidden seed per call site; (c) a time- or entropy-based seed.
- **Decision**: `DECIDED:` (a). It is reproducible run to run (which (c) is not, and a testbench must be), it uses the 17.9.3 algorithm the standard does give, and a single per-run stream is the common simulator reading (and that of Icarus, to the best of current knowledge: not re-checked). The analog `$random` (VAMS 9.13.1) chooses differently, one seed per omitted-seed site; that is another clause and is decided separately.
- **VerA today**: `src/sim/digital/root.zig:571` `random_seed: i32 = 0`, advanced in `src/sim/digital/system.zig:201-205`; unit test `system.zig:860`; fixture `ieee1364/17_system_tasks/b_17_9_1_seedless_random_starts_at_seed_0.v`. No change.
- **Measure impact**: none.

### VD-087: Time unit and precision with no `` `timescale ``
- **Source**: IMPLEMENTATION §1 row "1364 19.8".
- **Rule**: IEEE 1364-2005 19.8: "If there is no `timescale specified or it has been reset by a `resetall directive, the time unit and precision are simulator-specific. It shall be an error if some modules have a `timescale specified and others do not."
- **Why vague**: explicitly simulator-specific.
- **Options**: 1 s / 1 s; 1 ns / 1 ns; 1 ns / 1 ps; the finest precision in the design.
- **Decision**: `DECIDED:` 1 s / 1 s. It is the conventional Verilog default (Icarus uses it), and with the second sentence (a mix is an error) a design with no `` `timescale `` anywhere is self-consistent in whatever unit it picks, so the least surprising choice is the one most tools share.
- **VerA today**: `src/sim/digital/root.zig:1248` `default_quantum = .s`; the mix error at `:1362`. Fixtures `ieee1364/19_compiler_directives/b_19_8_no_timescale_is_1s_1s.v` and `b_19_8_some_modules_without_rejected.v`. No change.
- **Measure impact**: none.

### VD-088: A digital real array read with an out-of-range or x/z index
- **Source**: IMPLEMENTATION §1 prose after "Host math".
- **Rule**: IEEE 1364-2005 5.2.2: "If the index is out of the address bounds or if any bit in the address is x or z, then the value of the reference shall be x." 4.8.2: "Individual bits that are x or z in the net or the variable shall be treated as zero upon conversion."
- **Why vague**: 5.2.2 demands "x", but a real has no x encoding (4.8 gives reals no unknown value); the standard does not say what an x-valued real reads as.
- **Options**: (a) +0.0, applying 4.8.2's x/z-to-zero at the real boundary; (b) NaN; (c) refuse such reads.
- **Decision**: `DECIDED:` (a). It is the only reading built from text 1364 does have (4.8.2), it is what IEEE 1800 later wrote down for an invalid read of a `real` array element (0.0), and NaN (b) would invent an encoding that leaks into `$realtobits`. (c) cannot be done for run-time indices.
- **VerA today**: as decided: `ieee1364/04_data_types/native_real_arrays.v` checks invalid indices beside valid elements in the interpreter and the native executable; explicit NaNs from `$bitstoreal` keep their bits. No change.
- **Measure impact**: none.

### VD-089: `$clog2` of a host-bound parameter that carries no width
- **Source**: IMPLEMENTATION §1 row "none (host ABI)", `$clog2`.
- **Rule**: IEEE 1364-2005 17.11.1 (VAMS 9.14 defers to it): "The argument shall be treated as an unsigned value." 4.10.1: "A parameter declaration with no type or range specification shall default to the type and range of the final value assigned to the parameter, after any value overrides have been applied."
- **Why vague**: a host card value (a model-card number written into `Model` at run time) has no Verilog type or width, so 4.10.1's "range of the final value" has no answer for it, and `$clog2` of a value depends on the width it is viewed in only when that width truncates it.
- **Options**: (a) keep the elaborated declaration's width (today: a 4-bit default truncates a host 255 to 15, `$clog2` = 4); (b) treat a host number as an unsized integer literal (3.5.1: at least 32 bits, signed), so the declaration's range applies only where 4.10.1 says overrides cannot change it (a declared range or `integer`).
- **Decision**: `DECIDED:` (b). Under (a) the same parameter reads 255 in arithmetic and 15 in `$clog2`, a silent inconsistency no source text asks for; a host writing `knob = 255` means the number 255, which is exactly what an unsized decimal literal override means in HDL. A declared range (`parameter [3:0] p`) or type (`integer`) still fixes the width, because 4.10.1 says overrides do not change it.
- **VerA today**: (a): `lib/ir/lower/constfold.zig:180-186` `clog2Width`, `clog2Signed`; `ch09_system_tasks/clog2_inferred_parameter_width.va:35-43` asserts `$clog2(knob) == 4` for `parameter knob = 4'd1` with `//! param knob = 255`. `CHANGE NEEDED:` untyped, unranged parameters take a host value's `$clog2` width as 32 (64 when the value needs it); change that fixture's two `knob` checks to 8 with the derivation in its header, and add a ranged neighbour (`parameter [3:0] knob2`, host 255, `$clog2` = 4) to keep the truncating case pinned. Emitted device text changes: minor.
- **Measure impact**: A (fixture expectation); C: VAMS 9.14 evidence becomes consistent with 1364 4.10.1.

### VD-090: Top-level values of the hierarchical system parameters
- **Source**: IMPLEMENTATION §1 row "none (host ABI)", geometric system parameters.
- **Rule**: VAMS 9.18: "The top-level value is the starting value at the top of the hierarchy." 6.3.6 lists the overrides (defparam, instance parameter assignment, paramset), all from inside the design.
- **Why vague**: the LRM gives Table 9-29's top-level starting values but no way for a simulator (a SPICE instance line's `m=`, a placement tool's coordinates) to supply a different starting value for the top module the host instantiates.
- **Options**: (a) the top is always Table 9-29's identities; (b) every top module gets six hidden host-written fields; (c) a top-level §3.4.7 `aliasparam` of the system parameter is a model-card slot the host writes, defaulting to the identity.
- **Decision**: `DECIDED:` (c). It uses a construct 9.18 itself names ("can also be used as targets in parameter alias declarations"), costs nothing in devices that do not declare one, and is what a compact model author already writes (`aliasparam m = $mfactor`) to accept a netlist `m=`. Descendants keep the dependency so the 9.18 combination rules still apply below the top.
- **VerA today**: `lib/ir/hier_param.zig`, `lib/ir/lower/param.zig` `aliasSystemParam`; fixture `ch09_system_tasks/geometry_top_alias_host.va`. No change.
- **Measure impact**: none.
