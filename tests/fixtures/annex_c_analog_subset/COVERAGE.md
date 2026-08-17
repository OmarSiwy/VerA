# Annex C coverage

Source: `docs/VAMS-LRM/annex-c-veriloga.html`, read in full.

HTML section-ID audit: `sC-1` `sC-2` `sC-3` `sC-4` `sC-5` `sC-6` `sC-7` `sC-8` `sC-9` `sC-10` `sC-11` `sC-12` `sC-13` `sC-14` `sC-15` `sC-16` `sC-17` `sC-18` `sC-19` `sC-20`.

Annex C is almost entirely a subtraction list: it names the Verilog-AMS clauses that
Verilog-A keeps and the handful of constructs it drops. So most of this directory is
`//! reject` fixtures, and the ones that pass exist to hold the other side of a line
down. Nine of the twenty sections have a fixture here; the other eleven are listed
below with what they actually have, which for six of them is nothing anywhere.

Every entry was checked against the file's `//! lrm` cites and its source, not against
its filename. Sections with no fixture in this directory say so.

| Annex section | Rule | Fixtures in this directory |
|---|---|---|
| C.1 Verilog-A overview | descriptive: conservative and signal-flow systems, KPL/KFL, nodes/branches/terminals | none — no fixture cites C.1, and the section states no rule a source can violate. `01`/`02` happen to be conservative electrical devices, which is illustration, not proof |
| C.2 Verilog-A language features | the nine features the subset provides | `01_analog_only_device.va` (analog block, range limit, contribution), `02_named_branch.va` (named branch), `03_parameter_range.va` (inclusive range bound), `04_analog_operators.va` (`limexp`, `ddt`), `05_analog_event.va` (`initial_step`, `cross`), `19_named_event_in_subset.va` (§5.10.4 named event, declared, triggered and detected inside the analog block). Three of the nine bullets have no fixture here — see below |
| C.3 Lexical conventions | Clause 2 applies; x/z and `?` limited to the mixed-signal context | `06_xz_rejected.va` (`4'b0x1z` and `4'b01?1`, one `//! reject` arm each). Clause 2 proper is `ch02_lexical`, which cites C.3 from `05_xz_integer_rejected.va` and `24_question_digit_rejected.va` |
| C.4 Data types | Clause 3 applies except: discrete domain binding, `wreal`, `` `default_discipline `` | `08_wreal_rejected.va` (passes). Bullets 1 and 3 both had their verdicts INVERTED once the project settled that VerA targets Verilog-AMS and not the subset: `07_discrete_domain_binding_accepted.va` (was `07_..._rejected`, now the §7.2.1 rule) and `09_default_discipline_accepted.va` (was `09_..._rejected`, now §10.2's own binding — the directive is the module's only source of a discipline, so a tool that parses and discards it reaches E0337 and asserts nothing). What survives of bullet 3 is `18_no_discipline_rejected.va` — green, `//! reject discipline`: a module that declares *no* discipline anywhere has no potential to probe under any dialect |
| C.5 Expressions | Clause 4 applies except `===` and `!==` | `10_case_equality_rejected.va` (`===`), `17_case_inequality.va` (`!==`). Both operands integer on purpose, so §4.2.1's real-operand rule cannot satisfy the arm instead |
| C.6 Analog signals | §5.4 applies, no exception | `01_analog_only_device.va` — an inclusion with no carve-out can only be stated as a §5.4.1 access that must work, so the two-argument probe `V(p, n)` is the fixture |
| C.7 Analog behavior | Clause 5 applies except digital behavior/events and `casex`/`casez` | `11_casex_rejected.va` and `12_casez_rejected.va` (both green, `//! reject E0416` — the C.7-specific code, reachable now), `13_digital_initial_rejected.va`, `14_digital_always_rejected.va`, `21_digital_event_control_rejected.va` (`posedge`, `negedge`), `22_nonblocking_assign_rejected.va` (`<=`), `23_continuous_assign_rejected.va` (`assign`), `25_digital_procedural_rejected.va` (`fork`, `join`, `wait`). Positive side: `05_analog_event.va` and `19_named_event_in_subset.va` — the §5.10.4 named event is on the analog side of the C.7 line and now works |
| C.8 Hierarchical structures | Clause 6 applies except real value ports (§6.5.3) | `15_real_value_port_rejected.va` (`input wreal`), `28_real_value_output_port_rejected.va`, `29_real_value_inout_port_rejected.va`. One file per direction because the diagnostic reads "found wreal" and cannot tell them apart. The hierarchy C.8 *keeps* has no fixture here; `annex_a_syntax/11_module_instantiation.va` and `ch07_mixed_signal/hierarchy_unsupported.va` cite C.8 for it |
| C.9 Mixed signal | Clause 7 applies to Verilog-AMS HDL only | `24_connectrules_rejected.va` (the `connectrules … endconnectrules` declaration) — still E0201, legitimately: `connectrules` has no parser. `26_connectmodule_is_not_a_device.va` (was `26_connectmodule_rejected.va`) **no longer cites C.9 at all**: the same settlement that rewrote `07` applies here, so A.1.2's `module_keyword ::= module | macromodule | connectmodule` binds VerA and the declaration is ACCEPTED. What is left of that file is a §6.2 verdict — a source_text of one connect module declares no device, E1001 — and it says so in full. The rest of Clause 7 is `ch07_mixed_signal`, which cites C.9 from ten fixtures, two of which (`connectmodule_accepted.va`, `supply_hierarchical_connectmodule.va`) were inverted for the same reason |
| C.10 Scheduling semantics | analog simulation cycle applies; §8.2 mixed-signal cycle does not | none here. `ch08_scheduling/analog_digital_initial_order_unsupported.va` is the only fixture in the tree that cites C.10 |
| C.11 System tasks and functions | Clause 9 tasks applicable in the analog context apply | none here, and no fixture anywhere cites C.11. No `$`-task appears in this directory outside a comment |
| C.12 Compiler directives | Clause 10 applies to both | none here, and no fixture anywhere cites C.12. The only directive in this directory is the *forbidden* `` `default_discipline `` of `09` |
| C.13 Using VPI routines | Clause 11 applies to both | none, and no fixture anywhere cites C.13 |
| C.14 VPI routine definitions | Clause 12 applies to both | none, and no fixture anywhere cites C.14 |
| C.15 Analog language subset | self-reference: this annex is the AMS/Verilog-A diff, Annex A is the BNF | none, and no fixture cites C.15. The section states no testable rule of its own |
| C.16 List of keywords | ten keywords unused by Verilog-A; all AMS keywords are reserved words | `16_unused_ams_words_rejected.va` (`connectmodule`, `driver_update`, `endconnectrules`, `merged`, `resolveto`, `split`, `wreal` — seven separate arms), `20_net_resolution_reserved.va`, `30_connect_reserved.va`, `31_connectrules_reserved.va`. Nine of the ten words are proven; the tenth is not testable — see below |
| C.17 Standard definitions | Annex D applies, except a discipline with `domain discrete`, which shall be *silently ignored* | none here. `ch07_mixed_signal/discrete_discipline.va` is the only fixture that cites C.17 |
| C.18 SPICE compatibility | Annex E applies to both | none, and no fixture cites C.18 |
| C.19 Changes from previous versions | Annex G describes them | none, and no fixture cites C.19 |
| C.20 Obsolete functionality | Annex G also describes what is no longer supported | none, and no fixture cites C.20 |

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

## The debt ledger

EMPTY — grep finds no `//! xfail` in this directory: 31 files, 23 with a `//! reject`
arm, 8 that run and assert. The five rows it held closed three different ways, and the
distinction matters more than the count, because two of them closed by being WRONG:

| Fixture | Rule stated | How it closed |
|---|---|---|
| `11_casex_rejected.va` | C.7 bullet 2 — `casex` is not supported | The gap was real and was mis-described: `casex` never reached E0416 because `parseStmt` had no arm for the token at all, so the file died in parser recovery on E0209. E0416 — the C.7 code that already existed for this rule — fires now, and the fixture pins it by code |
| `12_casez_rejected.va` | C.7 bullet 2 — `casez` is not supported | Same shape, same close |
| `18_no_discipline_rejected.va` | C.4 bullet 3 / §3.8 — every Verilog-A module shall have a discipline | Green: a net with no discipline referenced from behavioral code is E0337 (§3.6.2.4), which is a rule of Verilog-AMS too and needs no subset gate. The fixture asserts nothing on purpose — with no nature there is no `V` to probe, so the only conforming outcome is a diagnostic |
| `20_net_resolution_reserved.va` | C.16 + Annex B — `net_resolution` is a reserved word | Green: the spelling is in `reserved_keywords` (`src/frontend/token.zig`) with the other nine, so `real net_resolution;` is E0208 |
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

**Why C.16 is four files and not one.** A `//! reject` substring is matched against every
diagnostic the file produces (`tests/torture.zig`, `failureContains`), so a keyword that
is a *prefix* of another keyword in the same file has a non-load-bearing arm: `connect`
is a substring of `connectmodule`, `connectrules` and `endconnectrules`, and
`connectrules` is a substring of `endconnectrules`. Those two get files of their own
(`30`, `31`) where nothing longer is spelled, and their modules are named
`annex_c_reserved_spelling_30/31` rather than after the keyword so a diagnostic quoting
the module name cannot satisfy the arm either. `net_resolution` is split out for a
different reason: it was the last of the ten to be reserved, and while it was open,
folding it in would have turned a seven-keyword proof into a known gap. It is green now
and the split is kept — a single file per gap is what made the gap visible.

**The tenth C.16 word is untestable as written.** The C.16 list spells it `resolvedto`.
Annex B Table B.1 — the normative reserved-word list — spells it `resolveto`. Since
`resolvedto` appears nowhere in Annex B it is not a reserved word and cannot be tested as
one; `16_unused_ams_words_rejected.va` pins the Annex B spelling.

**Reserving a spelling is not refusing a construct, and that cuts the other way now.**
`16`/`30`/`31` reject `connectmodule`, `connect`, `connectrules` and the rest as
*identifiers* under C.16, and every one of those is still green: a keyword that a compiler
implements is still a keyword. `24` rejects the `connectrules` *declaration*. `26` no
longer rejects the `connectmodule` declaration — a compiler can reserve every word in
Table B.1 and elaborate a connect module, which is exactly the position VerA is in.

**E0209 arms are recovery artifacts, not subset gates.** `21` and `25` pin E0209
("expected an expression", `.lrm A.8.3`), which names no C.7 rule — VerA simply does not
parse `posedge`, `fork` or `wait` there. Those arms record what VerA emits today; the
keyword arms alongside them are the load-bearing ones. Both headers say that if VerA ever
learns to parse these constructs the cite must move to E0201 ("construct is not in the
supported subset", `.lrm C`), which already exists, rather than be deleted. `11`/`12` were
the same situation and are the precedent for that move: E0416 existed all along and was
merely unreachable, and closing the gap meant giving `casex`/`casez` a parser arm so the
C.7 code could fire instead of the recovery code. `21`/`25` are the two that have not had
that done yet.

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
