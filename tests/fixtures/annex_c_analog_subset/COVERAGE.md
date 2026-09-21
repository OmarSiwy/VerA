# Annex C coverage

Source: `docs/annex-c-veriloga.html`, read in full.

HTML section-ID audit: `sC-1` `sC-2` `sC-3` `sC-4` `sC-5` `sC-6` `sC-7` `sC-8` `sC-9` `sC-10` `sC-11` `sC-12` `sC-13` `sC-14` `sC-15` `sC-16` `sC-17` `sC-18` `sC-19` `sC-20`.

Annex C is almost entirely a subtraction list: it names the Verilog-AMS clauses that
Verilog-A keeps and the handful of constructs it drops. So most of this directory is
`//! reject` fixtures, and the ones that pass exist to hold the other side of a line
down. Nine of the twenty sections have a fixture here; the other eleven are listed
below with what they actually have, which for six of them is nothing anywhere.

Annex C defines the optional Verilog-A subset, not VerA’s full-AMS target.
Rejection of a legal AMS construct records an implementation gap, not conformance.
Invalid analog-context uses and reserved words used as identifiers still require
rejection under the applicable AMS grammar.

Every entry was checked against the file's `//! lrm` cites and its source, not against
its filename. Sections with no fixture in this directory say so.

| Annex section | Rule | Fixtures in this directory |
|---|---|---|
| `C` (the annex title itself) | scope: "This annex defines a working subset of Verilog-AMS HDL for analog-only products" | none, and none is owed — a title-level scope sentence with no construct of its own. `tests/harness.zig` reads the bare letter out of `Annex C (normative) …` as a clause, which is why it appears in `--coverage` at all; no fixture cites bare `C` |
| C.1 Verilog-A overview | descriptive: conservative and signal-flow systems, KPL/KFL, nodes/branches/terminals | none — no fixture cites C.1, and the section states no rule a source can violate. `01`/`02` happen to be conservative electrical devices, which is illustration, not proof |
| C.2 Verilog-A language features | the nine features the subset provides | `01_analog_only_device.va` (analog block, range limit, contribution), `02_named_branch.va` (named branch), `03_parameter_range.va` (inclusive range bound), `04_analog_operators.va` (`limexp`, `ddt`), `05_analog_event.va` (`initial_step`, `cross`), `19_named_event_in_subset.va` (§5.10.4 named event, declared, triggered and detected inside the analog block). Three of the nine bullets have no fixture here — see below |
| C.3 Lexical conventions | Clause 2 applies; x/z and `?` limited to the mixed-signal context | `06_xz_rejected.va` (`4'b0x1z` and `4'b01?1`, one `//! reject` arm each). Clause 2 proper is `ch02_lexical`, which cites C.3 from `05_xz_integer_rejected.va` and `24_question_digit_rejected.va` |
| C.4 Data types | Clause 3 applies except: discrete domain binding, `wreal`, `` `default_discipline `` | `08_wreal_rejected.va` (passing unsupported-feature diagnostic; full-AMS `wreal` remains open). Bullets 1 and 3 both had their verdicts INVERTED once the project settled that VerA targets Verilog-AMS and not the subset: `07_discrete_domain_binding_accepted.va` (was `07_..._rejected`, now the §7.2.1 rule) and `09_default_discipline_accepted.va` (was `09_..._rejected`, now §10.2's own binding — the directive is the module's only source of a discipline, so a tool that parses and discards it reaches E0337 and asserts nothing). What survives of bullet 3 is `18_no_discipline_rejected.va` — green, `//! reject discipline`: a module that declares *no* discipline anywhere has no potential to probe under any dialect |
| C.5 Expressions | Clause 4 applies except `===` and `!==` | `10_case_equality_rejected.va` (`===`), `17_case_inequality.va` (`!==`). Both operands integer on purpose, so §4.2.1's real-operand rule cannot satisfy the arm instead |
| C.6 Analog signals | §5.4 applies, no exception | `01_analog_only_device.va` — an inclusion with no carve-out can only be stated as a §5.4.1 access that must work, so the two-argument probe `V(p, n)` is the fixture |
| C.7 Analog behavior | Clause 5 applies except digital behavior/events and `casex`/`casez` | `11_casex_rejected.va` and `12_casez_rejected.va` (both green, `//! reject E0416` — historical subset diagnostics, not full-AMS behavioral coverage). Bullet 1's `initial` half was INVERTED and has been re-verdicted, for the reason bullets C.4/1 and C.4/3 were: `13_digital_initial_accepted.va` (was `13_..._rejected`) now asserts §7.2.2's own first sentence instead of demanding a diagnostic no conforming AMS compiler may emit. Its `always` half stays a rejection but no longer on C.7's authority — `14_digital_always_rejected.va` pins VerA's ceiling, an `always` block whose value would be a function of §8.5's simulation cycle. Then `21_digital_event_control_rejected.va` (`posedge`, `negedge`), `22_nonblocking_assign_rejected.va` (`<=`), `23_continuous_assign_rejected.va` (`assign`), `25_digital_procedural_rejected.va` (`fork`, `join`, `wait`). Positive side: `05_analog_event.va` and `19_named_event_in_subset.va` — the §5.10.4 named event is on the analog side of the C.7 line and now works |
| C.8 Hierarchical structures | Clause 6 applies except real value ports (§6.5.3) | `15_real_value_port_rejected.va` (`input wreal`), `28_real_value_output_port_rejected.va`, `29_real_value_inout_port_rejected.va`. One file per direction because the diagnostic reads "found wreal" and cannot tell them apart. The hierarchy C.8 *keeps* has no fixture here; `annex_a_syntax/11_module_instantiation.va` and `ch07_mixed_signal/hierarchy_unsupported.va` cite C.8 for it |
| C.9 Mixed signal | Clause 7 applies to Verilog-AMS HDL only | `24_connectrules_is_not_a_device.va` (was `24_connectrules_rejected.va`) **no longer cites C.9 at all**: the settlement that rewrote `26` reached it — the `connectrules` declaration PARSES now (A.1.8, §7.7; its resolution statements feed annex F.2 step 4.b in `ir/elaborate.zig`), so the E0201-on-the-keyword verdict had no clause left behind it. What is left of that file is the same §6.2 verdict as `26`: a source_text whose only description is configuration for the insertion phase declares no device, E1001. `26_connectmodule_is_not_a_device.va` (was `26_connectmodule_rejected.va`) is that argument for the construct one level down: A.1.2's `module_keyword ::= module | macromodule | connectmodule` binds VerA and the declaration is ACCEPTED. The rest of Clause 7 is `ch07_mixed_signal`, where the five old E0201-wall fixtures were inverted into `*_accepted.va` acceptance fixtures for the same reason |
| C.10 Scheduling semantics | analog simulation cycle applies; §8.2 mixed-signal cycle does not | none here. `ch08_scheduling/analog_digital_initial_order.va` (was `_unsupported`) is the only fixture in the tree that cites C.10, and it is green and positive now: both initial constructs run, the analog block reads 1.0 + 1 |
| C.11 System tasks and functions | Clause 9 tasks applicable in the analog context apply | none, and none is owed — a cross-reference whose qualifier is §9's own table, and the exclusions it implies are already measured by the fixtures that cite §9 directly: `ch09_system_tasks/148` (`$realtime` — "analog context: No" in Table 9-7), `149` (`$time`, `$stime`) and `154` (the PLA and queue tasks), each of which rejects on the §9 rule without C.11's help. A C.11 arm here would be a second cite on one of those, or it would lean on E0806, and E0806 is not a measure of this clause: `ch04_expressions/a01_09` and `a01_10` record it firing on `$rtoi` and `$itor`, which Table 9-11 admits. No `$`-task appears in this directory outside a comment |
| C.12 Compiler directives | Clause 10 applies to both | none, and none is owed — an inclusion with no exception, and the thing included is already exercised everywhere: every `check.vh`-including fixture in the tree runs `` `define `` (§10.4), `disciplines_vams_guard_idempotent.va` in annex D `` `include ``s a file twice, and the directive this directory was going to argue about, `` `default_discipline ``, is accepted under §10.2's own rule in `09`. A C.12 cite would be a second name on behaviour §10 already owns |
| C.13 Using VPI routines | Clause 11 applies to both | none, and none is owed — Clause 11 is `Using VPI routines` and Clause 12 is `VPI routine definitions`, a C interface a simulation TOOL exports. Nothing a `.va` source can say is accepted or refused by it, so it is unobservable from a fixture and no fixture cites C.13 |
| C.14 VPI routine definitions | Clause 12 applies to both | none, and none is owed — same boundary as C.13, one clause further: VPI routine definitions are the tool's side of the interface, and no source file can violate or satisfy them |
| C.15 Analog language subset | self-reference: this annex is the AMS/Verilog-A diff, Annex A is the BNF | none, and no fixture cites C.15. The section states no testable rule of its own |
| C.16 List of keywords | **nine** keywords unused by Verilog-A; all AMS keywords are reserved words | `16_unused_ams_words_rejected.va` (`connectmodule`, `driver_update`, `endconnectrules`, `merged`, `resolveto`, `split`, `wreal` — seven separate arms), `30_connect_reserved.va`, `31_connectrules_reserved.va`. All nine words are proven. **`20_net_resolution_reserved.va` is REMOVED and its claim is WITHDRAWN, not moved** — the word is not in the corrected C.16 at all; see the ledger and the structural note below |
| C.17 Standard definitions | Annex D applies, except a discipline with `domain discrete`, which shall be *silently ignored* | none here. `ch07_mixed_signal/discrete_discipline.va` is the only fixture that cites C.17 |
| C.18 SPICE compatibility | Annex E applies to both | none, and none is owed — a pure cross-reference to Annex E, every clause of which is cited from `annex_e_spice/` (E.1 through E.4.2, forty-odd `//! lrm` lines). No fixture cites C.18 |
| C.19 Changes from previous versions | Annex G describes them | none, and none is owed — a pure cross-reference to an INFORMATIVE annex, which cannot carry a requirement on its own. No fixture cites C.19 |
| C.20 Obsolete functionality | Annex G also describes what is no longer supported | none, and none is owed — the same cross-reference one subclause further, and what it points at is Annex G.2's four statements, all four of which have green fixtures in `annex_g_change_history/` (`04`–`07`). No fixture cites C.20 |

Every `.va` in the directory is mapped above except `27_disable_rejected.va`, which is
here by neighbourhood and not by chapter: its cites are `A.6.4` and `A.6.5`, no `C.x` at
all. Its header argues the point deliberately — C.7 does *not* reach `disable`, because
`analog_event_statement` explicitly admits `@(evt) disable blk;`. What it rejects is the
bare form, which `analog_statement` does not derive. A correct fixture filed in the
wrong directory.

## What C.2 does not cover

C.2's feature list has nine bullets. Grep confirms three of them are exercised by nothing
in this directory:

- **waveform filters** — `transition`, `slew`, Laplace and Z-domain. No occurrence of any
  filter name in any file here. `ch04_expressions` owns them.
- **selection of the simulation time step** — no `$bound_step`, no `$discontinuity`.
- **accessing SPICE primitives** — nothing; `annex_e_spice` owns them.

A fourth is only partial: "a full set of operators including trigonometric functions,
integrals, and derivatives" is represented by `04_analog_operators.va`, which exercises
`limexp` and `ddt` — a derivative, but no trigonometric function and no `idt`. Both are
covered exhaustively in `ch04_expressions`; the point is that C.2's own row does not
prove them.

## The fixture xfail ledger

EMPTY — grep finds no `//! xfail` in this directory: 30 files, 21 with a `//! reject`
arm, 9 that run and assert. This is a fixture inventory, not an empty full-AMS
implementation backlog. The six historical fixture changes below include diagnostic
changes that do not implement the rejected constructs:

| Fixture | Rule stated | Historical fixture change |
|---|---|---|
| `11_casex_rejected.va` | C.7 bullet 2 — `casex` is not supported | The gap was real and was mis-described: `casex` never reached E0416 because `parseStmt` had no arm for the token at all, so the file died in parser recovery on E0209. E0416 now fires and the fixture pins it by code; legal AMS `casex` execution remains open |
| `12_casez_rejected.va` | C.7 bullet 2 — `casez` is not supported | E0416 now fires; legal AMS `casez` execution remains open |
| `18_no_discipline_rejected.va` | C.4 bullet 3 / §3.8 — every Verilog-A module shall have a discipline | Green: a net with no discipline referenced from behavioral code is E0337 (§3.6.2.4), which is a rule of Verilog-AMS too and needs no subset gate. The fixture asserts nothing on purpose — with no nature there is no `V` to probe, so the only conforming outcome is a diagnostic |
| `20_net_resolution_reserved.va` | C.16 + Annex B — `net_resolution` is a reserved word | **The fixture was wrong, not the compiler, and the fixture is gone.** It was authored from an HTML transcription of Annex B and C.16 that had been contaminated with Verilog-AMS 2.4 text. The 2023 edition removed the word from both lists — Annex G item 5027, verbatim "Removed unused keyword net_resolution \| B.1, C.16" — and the corrected Table B.1 (physical p.400) and C.16 both lack it. "This word is reserved" is therefore false for 2023 and there was never a rule behind the E0208 arm, so the file was deleted rather than repaired: a WITHDRAWN CLAIM, not a moved gap. The other nine C.16 words are still censused by `16`/`30`/`31`. The over-reservation this row left behind is **gone**: `net_resolution` has been deleted from VerA's `reserved_keywords` (`lib/frontend/token.zig`) and `ch10_directives/d10_12_net_resolution_is_an_ordinary_identifier.va` now pins the positive direction — a port and a net named `net_resolution`, read across. One loss is recorded there: the word *was* reserved under `"VAMS-2.3"`, and `token.isReserved` models §10.6's sets as a nesting chain with one introduction date per spelling, so it cannot express a word that leaves a later set |
| `09_default_discipline_rejected.va` | C.4 bullet 3 — `` `default_discipline `` is not supported | **The fixture was wrong, not the compiler.** VerA targets Verilog-AMS, where §10.2 makes the directive legal; demanding the diagnostic made the file passable only by a subset-only tool. Rewritten as `09_default_discipline_accepted.va`, which asserts the directive's own effect |

`19_named_event_in_subset.va` was the one entry here pointing the other way — a construct
VerA failed to *accept* rather than a rule it failed to *enforce* — and it closed first:
A.2.1.3 `event tick;` parses, A.6.5 `-> tick` lowers to a per-timepoint flag and `@(tick)`
reads it.

What the two inversions leave: Verilog-A's *subset* discipline requirement (C.4 bullets 1
and 3) is not enforced anywhere and deliberately is not, because this compiler implements
no `--std=verilog-a` gate. Each inverted file's header records where the subset half goes
back if one is ever added — as a second fixture, not as an inversion of the first.

## Structural notes

**Why C.16 is three files and not one.** A `//! reject` substring is matched against every
diagnostic the file produces (`tests/torture.zig`, `failureContains`), so a keyword that
is a *prefix* of another keyword in the same file has a non-load-bearing arm: `connect`
is a substring of `connectmodule`, `connectrules` and `endconnectrules`, and
`connectrules` is a substring of `endconnectrules`. Those two get files of their own
(`30`, `31`) where nothing longer is spelled, and their modules are named
`annex_c_reserved_spelling_30/31` rather than after the keyword so a diagnostic quoting
the module name cannot satisfy the arm either. A fourth file stood here for a tenth word
of the 2.4 list, `net_resolution`, and was deleted when the annex was corrected; the
ledger above records why. The nine words that remain are all the C.16 list has.

**The tenth C.16 word is gone, and the misspelling it was named for is gone with it.**
The list this folder used to count had ten entries; the corrected C.16 has nine. The
missing one is `net_resolution`, removed by the 2023 edition (Annex G item 5027, verbatim
"Removed unused keyword net_resolution \| B.1, C.16") — which is why its fixture was
deleted rather than repaired. The other change is a spelling. These notes used to say
C.16 spells the ninth word `resolvedto` while the normative Table B.1 spells it
`resolveto`, making the C.16 spelling unpinnable; both corrected sources spell it
`resolveto` — C.16's own list and Table B.1 (physical p.400) — so
`16_unused_ams_words_rejected.va` pins `resolveto`, the spelling both clauses use, and
`resolvedto` appears nowhere in the 2023 text.

**Reserving a spelling is not refusing a construct, and that cuts the other way now.**
`16`/`30`/`31` reject `connectmodule`, `connect`, `connectrules` and the rest as
*identifiers* under C.16, and every one of those is still green: a keyword that a compiler
implements is still a keyword — the spellings moved from `token.zig`'s reserved-only list
to real keyword tags and E0208 fires on them exactly as before. Neither `24` nor `26`
rejects its *declaration* any more: a compiler can reserve every word in Table B.1 and
still parse a connectrules block and elaborate past a connect module, which is exactly
the position VerA is in. Both files now pin the E1001 no-device verdict instead.

**E0209 arms are recovery artifacts, not subset gates.** `21` and `25` pin E0209
("expected an expression", `.lrm A.8.3`), which names no C.7 rule — VerA simply does not
parse `posedge`, `fork` or `wait` there. Those arms record what VerA emits today; the
keyword arms alongside them identify the unsupported forms. Historical headers
propose replacing recovery errors with subset diagnostics; that is not the full-AMS
completion criterion. Legal AMS uses need acceptance and behavioral tests. Illegal
analog-context uses must still be rejected by their grammar/context rule. The
E0416 changes in `11`/`12` improved diagnostics but did not implement `casex`/`casez`.

**C.4 bullet 1 has no fixture, on purpose.** `07` used to demand the rejection that C.4
requires of a Verilog-A tool. VerA targets Verilog-AMS, where §7.2.1 makes a discrete
domain binding legal and meaningful, so the fixture was demanding a diagnostic a
conforming AMS compiler must not emit. It is now
`07_discrete_domain_binding_accepted.va`, stating the §7.2.1 rule and asserting that the
binding is accepted and leaves the electrical node beside it alone. The subset rule is
recorded in that file's header and is not tested, because this compiler does not
implement the subset. The C.17 "silently ignore" half is likewise unpinned: the file it
used to point at, `annex_d_standard_definitions/discrete_disciplines.va`, is a
`//! reject E0501` fixture and pins §3.6.3 instead.
