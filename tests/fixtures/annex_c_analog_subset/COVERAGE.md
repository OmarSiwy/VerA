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
| C.4 Data types | Clause 3 applies except: discrete domain binding, `wreal`, `` `default_discipline `` | `08_wreal_rejected.va` (passes), `09_default_discipline_rejected.va` **xfail**, `18_no_discipline_rejected.va` **xfail** (the "each module shall have a discipline" half of bullet 3). Bullet 1 has **no fixture**: `07` used to demand it and was rewritten as `07_discrete_domain_binding_accepted.va`, the §7.2.1 rule, when the project settled that VerA targets Verilog-AMS and not the subset |
| C.5 Expressions | Clause 4 applies except `===` and `!==` | `10_case_equality_rejected.va` (`===`), `17_case_inequality.va` (`!==`). Both operands integer on purpose, so §4.2.1's real-operand rule cannot satisfy the arm instead |
| C.6 Analog signals | §5.4 applies, no exception | `01_analog_only_device.va` — an inclusion with no carve-out can only be stated as a §5.4.1 access that must work, so the two-argument probe `V(p, n)` is the fixture |
| C.7 Analog behavior | Clause 5 applies except digital behavior/events and `casex`/`casez` | `11_casex_rejected.va` **xfail**, `12_casez_rejected.va` **xfail**, `13_digital_initial_rejected.va`, `14_digital_always_rejected.va`, `21_digital_event_control_rejected.va` (`posedge`, `negedge`), `22_nonblocking_assign_rejected.va` (`<=`), `23_continuous_assign_rejected.va` (`assign`), `25_digital_procedural_rejected.va` (`fork`, `join`, `wait`). Positive side: `05_analog_event.va` and `19_named_event_in_subset.va` — the §5.10.4 named event is on the analog side of the C.7 line and now works |
| C.8 Hierarchical structures | Clause 6 applies except real value ports (§6.5.3) | `15_real_value_port_rejected.va` (`input wreal`), `28_real_value_output_port_rejected.va`, `29_real_value_inout_port_rejected.va`. One file per direction because the diagnostic reads "found wreal" and cannot tell them apart. The hierarchy C.8 *keeps* has no fixture here; `annex_a_syntax/11_module_instantiation.va` and `ch07_mixed_signal/hierarchy_unsupported.va` cite C.8 for it |
| C.9 Mixed signal | Clause 7 applies to Verilog-AMS HDL only | `24_connectrules_rejected.va` (the `connectrules … endconnectrules` declaration), `26_connectmodule_rejected.va` (the `connectmodule` compilation unit). Two files because the parser does not recover past either declaration. The rest of Clause 7 is `ch07_mixed_signal`, which cites C.9 from ten fixtures |
| C.10 Scheduling semantics | analog simulation cycle applies; §8.2 mixed-signal cycle does not | none here. `ch08_scheduling/analog_digital_initial_order_unsupported.va` is the only fixture in the tree that cites C.10 |
| C.11 System tasks and functions | Clause 9 tasks applicable in the analog context apply | none here, and no fixture anywhere cites C.11. No `$`-task appears in this directory outside a comment |
| C.12 Compiler directives | Clause 10 applies to both | none here, and no fixture anywhere cites C.12. The only directive in this directory is the *forbidden* `` `default_discipline `` of `09` |
| C.13 Using VPI routines | Clause 11 applies to both | none, and no fixture anywhere cites C.13 |
| C.14 VPI routine definitions | Clause 12 applies to both | none, and no fixture anywhere cites C.14 |
| C.15 Analog language subset | self-reference: this annex is the AMS/Verilog-A diff, Annex A is the BNF | none, and no fixture cites C.15. The section states no testable rule of its own |
| C.16 List of keywords | ten keywords unused by Verilog-A; all AMS keywords are reserved words | `16_unused_ams_words_rejected.va` (`connectmodule`, `driver_update`, `endconnectrules`, `merged`, `resolveto`, `split`, `wreal` — seven separate arms), `20_net_resolution_reserved.va` **xfail**, `30_connect_reserved.va`, `31_connectrules_reserved.va`. Nine of the ten words are proven; the tenth is not testable — see below |
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

Seven of the thirty-one fixtures carry `//! xfail`: the rule as written is right, and
VerA is known not to meet it. These are the interesting rows in the whole chapter,
because each is a subset gate that does not exist. Reasons verbatim:

| Fixture | Rule stated | Why it fails today |
|---|---|---|
| `09_default_discipline_rejected.va` | C.4 bullet 3 / §3.8 — `` `default_discipline `` is not supported | VerA implements `` `default_discipline `` as an ordinary Clause 10 directive and has no Verilog-A subset gate, so this module compiles clean (rc=0, no diagnostic) |
| `11_casex_rejected.va` | C.7 bullet 2 — `casex` is not supported | VerA reaches `casex` only through parser recovery: `parseStmt` does not dispatch it, so the source dies on E0209 ("expected an expression: found `casex`") and E0416 — the C.7 code that exists for this rule — never fires |
| `12_casez_rejected.va` | C.7 bullet 2 — `casez` is not supported | same shape as `casex`: E0209 out of parser recovery, and E0416 never fires |
| `18_no_discipline_rejected.va` | C.4 bullet 3 / §3.8 — every Verilog-A module shall have a discipline | VerA gives an undeclared analog net an implicit discipline instead of diagnosing; `module m(p); inout p; … V(p)` compiles clean (rc=0) |
| `20_net_resolution_reserved.va` | C.16 + Annex B — `net_resolution` is a reserved word | VerA's keyword table (`src/frontend/token.zig`) reserves the other nine C.16 words but not `net_resolution`, so `real net_resolution;` compiles clean (rc=0) |

`19_named_event_in_subset.va` used to be listed here, and it was the only entry
pointing the other way: every other xfail in this directory is a rule VerA fails to
*enforce*, while `19` was a construct VerA failed to *accept*. It now passes —
A.2.1.3 `event tick;` parses, A.6.5 `-> tick` lowers to a per-timepoint flag and
`@(tick)` reads it — so every remaining xfail here is a missing subset gate.

Two of the four C.4 xfails (`09` and `18`) are the same LRM sentence approached from
opposite ends, and both are open: Verilog-A's discipline requirement is today entirely
unenforced.

## Structural notes

**Why C.16 is four files and not one.** A `//! reject` substring is matched against every
diagnostic the file produces (`tests/torture.zig`, `failureContains`), so a keyword that
is a *prefix* of another keyword in the same file has a non-load-bearing arm: `connect`
is a substring of `connectmodule`, `connectrules` and `endconnectrules`, and
`connectrules` is a substring of `endconnectrules`. Those two get files of their own
(`30`, `31`) where nothing longer is spelled, and their modules are named
`annex_c_reserved_spelling_30/31` rather than after the keyword so a diagnostic quoting
the module name cannot satisfy the arm either. `net_resolution` is split out for a
different reason: it needs `//! xfail`, and folding it in would turn a seven-keyword
proof into a known gap.

**The tenth C.16 word is untestable as written.** The C.16 list spells it `resolvedto`.
Annex B Table B.1 — the normative reserved-word list — spells it `resolveto`. Since
`resolvedto` appears nowhere in Annex B it is not a reserved word and cannot be tested as
one; `16_unused_ams_words_rejected.va` pins the Annex B spelling.

**Reserving a spelling is not refusing a construct.** `24`/`26` reject the `connectrules`
and `connectmodule` *declarations* under C.9; `16`/`30`/`31` reject the same spellings as
*identifiers* under C.16. A compiler could reserve every word in Table B.1 and still
elaborate a connect module, so both halves are needed.

**E0209 arms are recovery artifacts, not subset gates.** `21` and `25` pin E0209
("expected an expression", `.lrm A.8.3`), which names no C.7 rule — VerA simply does not
parse `posedge`, `fork` or `wait` there. Those arms record what VerA emits today; the
keyword arms alongside them are the load-bearing ones. Both headers say that if VerA ever
learns to parse these constructs the cite must move to E0201 ("construct is not in the
supported subset", `.lrm C`), which already exists, rather than be deleted. `11`/`12` are
the same situation named honestly as xfail instead, because the C.7-specific code (E0416)
does exist and is merely unreachable.

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
