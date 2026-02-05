# D10 — Compiler directive semantics

Scope of this row, from the plan
(`ARPice/docs/verilog-ams-conformance-plan.md` §"D10 — Compiler directive
semantics"): file-boundary scope and restoration, keyword-set transitions via
`` `begin_keywords ``/`` `end_keywords ``, predefined macros, pragma handling,
and the interaction of `` `unconnected_drive `` with the D03 strength model.

## Ground truth first: the plan understates this row badly

The plan's "Known gap" paragraph for D10 reads:

> `default_nettype`, `celldefine`, `endcelldefine`, `unconnected_drive` and
> `nounconnected_drive` are accepted-and-ignored entries.

**That is stale.** All five carry state today, and so do the three the plan does
not mention. Read from the source, not from the docs:

| directive | where it is handled | what consumes it |
|---|---|---|
| `` `default_nettype `` | `lib/frontend/preprocessor.zig:335` → `NetTypeRegion` | `lib/ir/lower.zig` `rejectImplicitNet` (E0367) |
| `` `celldefine ``/`` `endcelldefine `` | `preprocessor.zig:340-341` → `CellRegion` | `Mir.is_cell` |
| `` `unconnected_drive ``/`` `nounconnected_drive `` | `preprocessor.zig:342-343` → `DriveRegion` | `lib/ir/lower.zig:2523` `applyUnconnectedDrive` |
| `` `pragma `` | `preprocessor.zig:349` → `.ignored` | nothing, deliberately — comment cites IEEE 1364 §19.8 "shall ignore" |
| `` `begin_keywords ``/`` `end_keywords `` | `preprocessor.zig:324-325` → emitted verbatim, `dir_begin_keywords` | the parser, which nests and restores |
| `` `resetall `` | `preprocessor.zig:1227-1258` | appends a reset **event** to all four positional lists |
| `` `timescale `` | `preprocessor.zig:335` | §9.15 |

`tests/fixtures/ch10_directives/` already holds 62 fixtures covering all seven
HTML section ids of chapter 10. So this row is not greenfield in the way the
plan implies, and the honest deliverable is different from what was briefed:
**nine of the eleven fixtures below pass today and exist as evidence for
behaviour that had none; two fail and are the real gap.**

Everything in this directory was written against the compiler as it is, and
every expected number was derived by hand **before** it was run. The
"observed today" block at the bottom is the record, not the source, and it is
captured output rather than typed. Where review found a derivation wrong, the
arithmetic is redone in "Corrected after review" rather than the number being
copied from the reviewer.

### What actually fails

1. **§10.5's tool-specific predefined macro does not exist.** `predefined_macros`
   in `lib/frontend/preprocessor.zig` has exactly two entries,
   `__VAMS_ENABLE__` and `__VAMS_COMPACT_MODELING__`. §10.5's last paragraph is
   a "shall" and it is unmet. Fixture `09`.
2. **`` `unconnected_drive `` never meets a strength model**, because D03 has
   none: `src/sim/digital.zig` `wired()` says so in its own comment ("§7.10's
   eight drive strengths and §7.11's strength resolution are not implemented"),
   and the only consumer of the `DriveRegion` list is the analog lowering, which
   approximates a Pu1 driver as a 1 V potential source and skips any net whose
   discipline binds no potential. Fixture `11`.

Everything else the FOCUS names — file-boundary scope, restoration, keyword-set
transitions, pragma — works, and had no test proving it.

## LRM clauses covered

Read from the offline HTML in `VerA/docs/`, not from memory.

- **§10.1 Overview** (`ch10-directives.html`, `s10-1`) — Table 10-1 and the
  scope sentence: *"The scope of compiler directives extends from the point
  where it is processed, across all files processed, to the point where another
  compiler directive supersedes it or the processing completes."* Table 10-1
  defers `` `pragma ``, `` `resetall ``, `` `unconnected_drive `` and
  `` `nounconnected_drive `` to IEEE Std 1364.
- **§10.2 `` `default_discipline ``** (`s10-2`) — *"…until either the end of the
  text stream or another `default_discipline directive with the qualifier (if
  applicable) is found in the subsequent text, **even across source file
  boundaries**."*
- **§10.5 Predefined macros** (`s10-5`) — the `__VAMS_COMPACT_MODELING__`
  biconditional (*"shall be defined … **if and only if** all the compact
  modeling extensions are supported"*) and the last paragraph
  (*"Verilog-AMS simulators **shall also provide** a predefined macro so that
  the module can conditionally include (or exclude) portions of the source text
  specific to a particular simulator."*).
- **§10.6 `` `begin_keywords `` / `` `end_keywords ``** (`s10-6`) — *"The
  `begin_keywords directive affects all source code that follows the directive,
  **even across source code file boundaries**, until the **matching**
  `end_keywords directive is encountered."* Plus the clause's two worked
  examples, which supply the verdicts for `sin` under `"1364-2005"` and under
  `"VAMS-2023"`.
- **§6.2.2** (`ch6-hierarchy.html`) — *"A blank port connection shall represent
  the situation where the port is not to be connected"*, which is what makes a
  port §19.10's subject. Note what it does **not** say: it locates
  unconnectedness at the *connection*, so it is no authority for attaching
  `` `unconnected_drive `` at the module definition. See the withdrawal below.
- **§1.3.1 / §1.3.2** — branch potential and KCL, the oracle for every number in
  the `` `unconnected_drive `` family.
- **Annex G Table G.3** (`annex-g-changes.html`) — the normative "changes from
  v2.1 to v2.2" list, which is what "the compact modeling extensions" of §10.5
  denotes. Items 3, 8/10, 17, 18 are sampled by fixture `10`; item 26 is the
  macro itself. The table has **27** rows, numbered 1–28 with no item 13.

## Fixtures

One line each: what it pins, the expected value, the derivation.

| file | pins | expected | derivation |
|---|---|---|---|
| `01_default_discipline_crosses_a_file_boundary.va` | §10.2's own "even across source file boundaries", **positively** — `ch10_directives/57` pins the same rule for `` `default_nettype `` but only as a rejection. | `V(p,n) = 0.5` | Directive lives alone in `d10_default_discipline.vh`; the module here declares no discipline, so the default is the only thing that can give `p`/`n` a nature and `V` an access function (§3.6.1). §1.3.1: `0.75 − 0.25 = 0.5`, both operands binary-exact. Drop the directive at end-of-include and the module dies at E0337, as `ch10_directives/41` records. |
| `02_begin_keywords_region_survives_the_include_that_opened_it.va` | §10.6's "even across source code file boundaries": a region opened in an included file is still open after that file ends. | `V(sin,n) = 0.5` | Header opens `"1364-2005"` and leaves it open; the module using `sin` as a port name is in the parent. An enclosing `"VAMS-2023"` removes the implementation's-default escape (§10.6's own example is conditional on the default set for exactly this reason). §1.3.1: `0.75 − 0.25 = 0.5`. A tool that pops the keyword stack at end-of-include parses the module under VAMS-2023 and refuses it. |
| `03_end_keywords_closes_a_region_opened_in_another_file.va` | **reject E0208.** The same sentence's word "**matching**": an `` `end_keywords `` in a different file from its `` `begin_keywords `` closes that region and restores the *enclosing* one. | refusal on the OUTER module | Inner module is §10.6's worked example verbatim (`sin` legal under 1364-2005) and must compile; after the `` `end_keywords `` the set is the outer `"VAMS-2023"`, under which the clause's next example says `ERROR: "sin" is a keyword in Verilog-AMS`. `ch10_directives/33` is the one-file version and is satisfied by a stack that never crosses a boundary. |
| `04_unconnected_drive_region_closes_mid_compilation.va` | §10.1's scope sentence applied to `` `unconnected_drive `` **closing**. 58/59/60 each hold one region state for a whole file, so none of them observes the end of a region; a tool that latches the directive on first sighting is green on all three. Two identical children in one compilation, one on each side of a single `` `nounconnected_drive ``. | `V(mi.u.a) = 1.0`, `I(mi.u.a,mi.u.b) = +5e-4`; `V(mo.u.a) = 0.5`, `I(mo.u.a,mo.u.b) = 0` | Pulled: 58's argument for the level (1 of the potential nature's units), then Ohm on the child's 1 kΩ with `b` at `V(p) = 0.5`: `0.001 × (1.0 − 0.5) = +5.0e-4 A` a→b. Positive, because `a` is the high end — **−5e-4 is the pull0 case and is fixture 06's number, not this one's.** Unpulled: §1.3.2 KCL at `a` has one term ⇒ 0 A ⇒ §1.3.1 makes the branch potential 0 ⇒ `a` sits at `b` = `p` = 0.5 V. The first pair is unreachable without the directive, the second is unreachable with it latched, so neither half can be satisfied by ignoring chapter 10. Each child is paired with **its own instantiation inside a wrapper module** on one side of the boundary, so the definition-site/instantiation-site question below cannot affect either number. |
| `05_unconnected_drive_spares_an_unconnected_inout.va` | §19.10's subject is an unconnected **input** port. One child, two blanks, one `input` and one `inout`, one directive. | `V(u.a) = 1.0`, `V(u.c) = 0.5`, `I(u.c,u.b) = 0` | `a` is the clause's subject ⇒ held at 1 of the potential nature's units. `c` is an `inout` ⇒ not pulled ⇒ KCL at `c` has one term ⇒ 0 A ⇒ `c` sits at `b` = `p` = 0.5 V. Every existing 58/59/60 fixture has exactly one unconnected port and it is always an `input`, so all three are green under a tool that pulls every direction; this one is not. |
| `06_unconnected_drive_reaches_a_named_port_connection.va` | §6.2.2's blank port connection has three spellings, and 58/59/60 only test the ordered one. `.a()`, an omitted named port, and `( , p)` must agree. | `V(u1.a) = V(u2.a) = V(u3.a) = 0`, `I(u1.a,u1.b) = −5e-4` | `pull0` clamps `a` to 0; the 1 kΩ resistor then carries `0.001 × (0 − 0.5) = −5e-4 A` by Ohm's law. An unpulled port carries 0 A instead (`ch10_directives/60`'s number), so the current assertion is the one that separates "collected" from "not collected" for each spelling. |
| `07_resetall_restores_the_unconnected_drive_default.va` | IEEE 1364's `` `resetall `` is the second way out of a `` `unconnected_drive `` region — the way that does not name it. `ch10_directives` pins this for §10.2 (`36`) and §19.2 (`56`) but for neither IEEE 1364 region directive. | `V(mi.u.a) = 1.0`, `I = +5e-4` above the reset; `V(mo.u.a) = 0.5`, `I = 0` below it | Same two-child shape and the same derivations as `04`, with `` `resetall `` in place of `` `nounconnected_drive ``. **The first pair is why the file exists in this form:** "the region closed" is only ever observable as an absence, so without a child that IS pulled in the same compilation the file asserts 60's numbers and is green on a tool that never implemented the directive at all. `check.vh` is included *after* the reset because `` `resetall `` removes user macros — **measured, not cited**: no clause in `docs/` says so (§10.4 is `` `define ``/`` `undef `` and is silent on `` `resetall ``; §10.1 Table 10-1 marks `` `resetall `` "[IEEE Std 1364 Verilog]" and that text is not offline here), and moving the `` `include `` above the reset yields `error[E0115]: undefined macro: `CHECKX` at HEAD (the first child and wrapper are above it and use none), and every module declares `electrical` explicitly because it also withdraws any default discipline (§10.2, "In addition to `resetall"). Also pins that `` `resetall `` is implemented **positionally** (an appended reset event) and not by clearing the region list — the latter passes this file and breaks 58. |
| `08_pragma_is_directive_text_not_source_text.va` | §10.1 Table 10-1 makes `` `pragma `` a compiler *directive*, so its line is directive text; and the scope sentence's "from the point where it is processed" gives it no reach backwards and no reach past its own line. | `` `D10_GAIN `` = 2.0, `` `D10_SCALE `` = 3.0, product = 6.0, branch current `6.0 × 0.5 = 3.0 A` | The three literals are written by hand three lines apart and nothing supersedes them. `ch10_directives/19`'s `` `pragma f harmless `` has no punctuation and nothing after it, so it is green under a pragma that stops at the first accent grave, or runs past its own line, or macro-expands its arguments; this line is `` `pragma vera_row_d10 protect, key = `D10_GAIN, "literal text" ``. Two distinct failure modes, both read off the line as written: a pragma stopping at the first accent grave returns `` `D10_GAIN, "literal text" `` to the **source** stream at file scope, so the parser meets `` 2.0 , "literal text" `` where a module item belongs and the file does not compile at all; a pragma running past its own line eats `` `define D10_SCALE 3.0 `` and the second and third assertions die at E0115. The third mode (arguments macro-expanded before being discarded) is **not** discriminated here and the header now says so — see "Deliberately NOT covered". |
| `09_the_tool_specific_predefined_macro.va` | **FAILS TODAY.** §10.5 last paragraph: a simulator *shall* provide a documented tool-specific predefined macro. | witness = 1.0, `witness × V(p,n) = 0.5` | `ch10_directives/13`'s gain-witness shape: both arms define the same macro to different numbers, so the surviving arm names itself in the digit. **Two clauses, not one:** §10.5's last paragraph is the "shall" under test (the macro is *provided*); *which arm survives* is IEEE Std 1364's `` `ifdef ``/`` `else ``/`` `endif `` rule, three of the entries §10.1 Table 10-1 marks "[IEEE Std 1364 Verilog]", and that 1364 clause is not offline in `docs/`, so it is named by the deferral and no subclause number is invented. Arm selection itself is pinned by `ch10_directives/09` and `11`. Macro provided ⇒ 1.0 ⇒ the contribution is `1.0 × (0.75 − 0.25) = 0.5`; the dead arm gives 0.0, half a volt away. **Anchored, not portable**: the spelling `__VERA__` is the one VerA's manual would document; another implementation retargets the `ifdef` and changes nothing else. |
| `10_compact_modeling_macro_implies_its_extensions.va` | **Both directions** of §10.5's biconditional. Forward, in the `ifdef` arm: if `__VAMS_COMPACT_MODELING__` is defined, the extensions it advertises must work. Reverse, unconditionally: a tool conforming to the whole LRM supports them all, so "if and only if" requires the macro to be defined. `ch10_directives/14`'s header explicitly declines both. | unconditional `cm = 1.0`; then `ddx = 1.5`, `$mfactor = 1.0`, `$param_given(rser) = 0`, `fold[nslot−1] = 6.0`, `rser = 1.0` | "The compact modeling extensions" is read as Annex G Table G.3 (v2.1→v2.2), the version §10.5 names, whose item 26 adds this macro. Derivations: `d/dV(p)` of `1.5·(V(p)−V(n))` is the coefficient 1.5 exactly (§4.5.6 is symbolic, so a finite-difference stub misses it); `$mfactor` with no multiplicity above is the empty product 1 (§9.18); nothing overrides `rser` so `$param_given` is 0 (§6.3.5/§9.19) — a tool confusing "has a value" with "was given one" returns 1. **Item 3 now has teeth:** the two `localparam`s stand where only a constant expression may — an array bound and a parameter's default — so swapping either for a `real` stops the file compiling (measured: `E0308 array bound is not a constant expression`, `E0314` on the name in the default). The reverse-direction check is the unconditional one and is the only thing here a tool answering the `else` cannot dodge; its premise is argued in the file header and in "Disputed" below. |
| `11_unconnected_drive_pull_meets_the_strength_model.v` + `.expected.txt` | **BLOCKED, fails today.** §19.10's pull is a driver *at pull strength*, not a level — so on a four-state net it competes, and IEEE 1364 §7.10/§7.11 decide. (Every §7.x and §3.7 in this row is **IEEE 1364's**, not this LRM's, where §7.9 is *Driver-receiver segregation* and §3.7 is *Real net declarations*; the fixture header now says so on every use.) | `w=1 t=x s=0` | One `` `unconnected_drive pull1 `` over one child with three unconnected input ports of three net types. Strength levels: supply 7 > strong 6 > **pull 5** > large 4 > weak 3 > medium 2 > small 1 > highz 0. `wire` — no second driver, undriven value Z is the identity of 1364 §7.9's table ⇒ Pu1 alone ⇒ **1**. `tri0` — 1364 §3.7 pulls itself to 0 *at pull strength* ⇒ Pu0 vs Pu1, equal strength, opposite values ⇒ **x** (the case no potential-source approximation can ever produce). `supply0` — 1364 §3.7 drives at supply strength, two levels above pull ⇒ Su0 beats Pu1 ⇒ **0**. A tool with no strength model prints `w=1 t=x s=x` (everything conflicts to X) or `w=1 t=0 s=0` (net type simply wins); neither matches. |

Ten positive fixtures, one refusal. The refusal (`03`) is the closing half of a
positive (`02`) and is not standing in for feature coverage anywhere.

### Supporting headers (not fixtures — the harness walks `.va` only)

- `d10_default_discipline.vh` — one `` `default_discipline electrical `` line,
  so `01` has a file boundary to cross.
- `d10_keywords_1364_2005.vh` — one **unclosed** `` `begin_keywords "1364-2005" ``,
  so `02` and `03` have a region that has to survive one.

### Observed today

Captured, not typed — stdout of the loop under "Build / run" below, filtered to
`ok=`/`error[` lines, against `zig-out/bin/vera` built from HEAD.

```
##### 01_default_discipline_crosses_a_file_boundary.va
a default set in an included file still reaches this net got=0.5 want=0.5 ok=1
##### 02_begin_keywords_region_survives_the_include_that_opened_it.va
`sin` is an identifier under a region opened in another file got=0.5 want=0.5 ok=1
##### 03_end_keywords_closes_a_region_opened_in_another_file.va
error[E0208]: expected an identifier: found `sin`
##### 04_unconnected_drive_region_closes_mid_compilation.va
inside the region the blank input is pulled got=1 want=1 ok=1
and is driven: 0.001*(1.0 - 0.5) A flows a->b got=0.0005 want=0.0005 ok=1
`nounconnected_drive ended the region in the same compilation got=0.5 want=0.5 ok=1
so this one carries no current at all got=-0 want=0 ok=1
##### 05_unconnected_drive_spares_an_unconnected_inout.va
the unconnected `input` is pulled, as 58 already pins got=1 want=1 ok=1
the unconnected `inout` is not: §19.10 names input ports got=0.5 want=0.5 ok=1
so no current flows in the inout's branch got=-0 want=0 ok=1
##### 06_unconnected_drive_reaches_a_named_port_connection.va
an explicit `.a()` is a blank port connection got=0 want=0 ok=1
so is a port left out of the named list got=0 want=0 ok=1
and the ordered blank agrees, as it must got=0 want=0 ok=1
the named blank is DRIVEN: 0.001*(0 - 0.5) A flows a->b got=-0.0005 want=-0.0005 ok=1
##### 07_resetall_restores_the_unconnected_drive_default.va
above the `resetall the pull is in force got=1 want=1 ok=1
and drives: 0.001*(1.0 - 0.5) A flows a->b got=0.0005 want=0.0005 ok=1
`resetall put §19.10 back to its default, so this input floats got=0.5 want=0.5 ok=1
and no current flows into it got=-0 want=0 ok=1
##### 08_pragma_is_directive_text_not_source_text.va
the `define above the pragma is untouched got=2 want=2 ok=1
the `define below the pragma took effect got=3 want=3 ok=1
so the pragma line contributed nothing but itself got=6 want=6 ok=1
##### 09_the_tool_specific_predefined_macro.va
§10.5 requires a documented tool-specific predefined macro got=0 want=1 ok=0   <-- THE GAP
and the surviving arm is the one that scales this branch got=0 want=0.5 ok=0   <-- THE GAP
##### 10_compact_modeling_macro_implies_its_extensions.va
G.3 item 8: ddx is the symbolic derivative, so exactly 1.5 got=1.5 want=1.5 ok=1
G.3 item 18: $mfactor with no multiplicity above is 1 got=1 want=1 ok=1
G.3 item 17: nothing overrode rser, so $param_given is 0 got=0 want=0 ok=1
G.3 item 3: a localparam bounds this array, 2.0*3.0 got=6 want=6 ok=1
G.3 item 3: and folds into a parameter default, 2.0-1.0 got=1 want=1 ok=1
§10.5: extensions supported, so the macro shall be defined got=1 want=1 ok=1
##### 11_unconnected_drive_pull_meets_the_strength_model.v
error[E1100]: digital source execution failed: digital execution requires exactly one ordinary module
```

`09` and `11` are the deliverable. `01`–`08` and `10` pass and are kept: they
are the evidence this row had none of, and each one is a tripwire on a
behaviour a plausible "simplification" would break (pop the keyword stack at
end-of-include, clear the region list on `` `resetall ``, latch the drive region
once and never close it, pull every direction, collect blanks only from the
ordered form, stub an Annex G extension while still advertising it).

## Deliberately NOT covered, and why

- **Several files on one command line.** §10.1's "across all files processed"
  has two shapes and an `` `include `` only reaches one of them. The runner
  compiles one file per invocation, so the other — a directive left open at the
  end of file A governing file B — has no spelling here.
  `ch10_directives/30`'s header already records the consequence.
- **`` `resetall `` and §10.3 `` `default_transition ``.** `preprocessor.zig`'s
  `resetall` arm resets the discipline, timescale, nettype, cell and drive
  state and **does not** touch `pp.transitions`. That is a real asymmetry, but
  §10.3 says the post-reset state is "controlled by the simulator", so there is
  no number a fixture can demand. Recorded here rather than guessed at.
- **`` `resetall `` and the keyword set.** Whether IEEE 1364 §19.6's reset
  reaches `` `begin_keywords `` is a 1364 question and the 1364 text is not
  available offline in this repo. Not guessed.
- **§10.3's self-contradiction.** "it can be used only outside of module
  definitions" and "There are no scope restrictions for this directive" are two
  sentences of one paragraph. A conformance fixture on a self-contradictory
  clause tests the reader, not the tool.
- **`` `celldefine ``.** The tag changes no value a model can print; it is a
  unit test in `lib/root.zig` and `ch10_directives/COVERAGE.md` says so.
- **"*Not* defined if any extension is unsupported."** This is the half of
  §10.5's biconditional that stays out of reach: source text has no way to ask
  "is X missing?" except by using it, which is what fails to compile when it is
  missing. (The *other* half — all supported ⇒ defined — **is** now asserted by
  `10`; see "Disputed".)
- **Table G.3 exhaustively.** `10` samples four of its twenty-seven rows. The
  rest belong to the rows that own those features (A01, A04, A05, D-series),
  not here; `10` is a tripwire on the §10.5 biconditional, not a
  compact-modeling suite.
- **Whether `` `unconnected_drive `` attaches at the module DEFINITION or at the
  INSTANTIATION that leaves the terminal blank.** *Withdrawn*, and it was the
  whole subject of the old `04_unconnected_drive_follows_the_module_definition.va`.
  Nothing in `docs/` settles it: §6.2.2 is the nearest on-disk sentence and it
  points at the connection, and IEEE Std 1364 §19.10 — the clause §10.1 Table
  10-1 defers to — is not offline here, so neither reading has a citation that
  survives being opened. VerA hard-codes the definition-site reading with a
  comment at `lib/ir/elaborate.zig:663-667`; asserting it transcribed the
  implementation. **No other row owns this claim; it is parked here.** It comes
  back the day IEEE Std 1364 clause 19 lands in `docs/`, as a file in the
  *converse* arrangement — child defined inside the region, instantiated outside
  it — so that whichever way the clause reads, the asserted value is not the one
  a tool without the feature produces. Meanwhile `04` and `07` pair every child
  with its own instantiation on one side of the boundary, which makes both
  readings agree and removes the bet from both files.
  `05` and `06` keep `ch10_directives/58`'s arrangement — region around the
  child definition only, parent outside it — and so inherit the definition-site
  reading from the shipped green fixture they extend. That is deliberate:
  changing their shape would make them disagree with `58`/`59`/`60`, which are
  in `tests/fixtures/` and outside this row's scope. Neither file's *subject*
  (port direction; the three spellings of a blank) depends on the question, so
  if the clause ever resolves the other way all four files move together.
- **A pragma that macro-expands its arguments before discarding them.** `08`
  carries `` `D10_GAIN `` as a pragma argument in the `keyword = value` shape,
  but the name is *defined*, so expanding it changes nothing observable.
  Discriminating it needs an **undefined** name among the arguments, and whether
  a conforming preprocessor may diagnose that is an IEEE 1364 §19.11 question
  the offline docs cannot answer. Not guessed; `08`'s header says so.
- **`` `pragma protect ``/`` `endprotect ``.** IEEE 1364 defines pragma names
  with real semantics; §10.1 only defers to it, and the 1364 text is not
  offline here. `08` stays on the part §10.1 alone fixes.
- **`` `timescale `` beyond `ch10_directives/62`.** The ordering rule is pinned
  there; the analog kernel reports `$abstime` in seconds, so a timescale moves
  no analog number and the digital half belongs to D04's clock.
- **The refusal side of `` `unconnected_drive `` × strength.** `11` is positive
  only. A Pu1-vs-Pu1 or a `large`/`weak` case would just be more rows of the
  same table with no new rule.

## Corrected after review

An adversarial review found five defects in this row; a second pass over every
citation and every quotation in the directory found four more. All nine are
fixed here; nothing in `src/`, `build.zig` or `tests/fixtures/` was touched.
Items 1–5 are the review's, 6–9 are the second pass's, and the one place this
row **disagrees** with the review is item 10.

1. **`04` asserted the feature-absent value and rested on an unciteable claim**
   (review Class C and Class D). `04_unconnected_drive_follows_the_module_
   definition.va` is **deleted** and replaced by
   `04_unconnected_drive_region_closes_mid_compilation.va`.
   - Its old `V(u.a) = 0.5, I = 0` is exactly what a tool that ignores
     `` `unconnected_drive `` prints, so it could not fail for its own subject.
     The new file asserts `1.0` and `+5e-4` on a child inside the region as well
     as `0.5` and `0` on one outside it, in a single compilation.
   - The definition-site-vs-instantiation-site bet is **withdrawn** and where it
     went is recorded under "Deliberately NOT covered"; no other row owns it.
   - The old header and this SPEC said the counterfactual was "1.0 and
     **−5e-4**". Re-derived: with `pull1`, `a` is clamped at 1.0 and `b` sits at
     `V(p) = 0.5`, so `I(a,b) = 0.001 × (1.0 − 0.5) = +5.0e-4 A` a→b. The
     reviewer is right and the sign is positive; **−5e-4 is the `pull0` case**,
     which is fixture `06`'s number. Confirmed by running: `04` prints
     `got=0.0005` and `06` prints `got=-0.0005`.
   - Both files also claimed that counterfactual "is fixture 58's answer".
     `ch10_directives/58` asserts exactly one thing, `V(u.a) = 1.0`, and **no
     current at all**. Claim removed from both.
2. **`07` asserted the feature-absent value** (Class D). Rebuilt on the same
   two-child shape: a wrapper above the `` `resetall `` whose blank input is
   pulled to `1.0` / `+5e-4`, and one below it that floats at `0.5` / `0`. The
   `1.0` is what makes the `0.5` mean "the region closed" instead of "the
   directive was never implemented".
3. **`08`'s first failure mode was fiction** (Class C). The header claimed a
   truncating pragma "makes the first assertion read 5 instead of 2"; there is
   no `5.0` anywhere in the file and never was. Re-derived from the line as
   written: a pragma stopping at the first accent grave returns
   `` `D10_GAIN, "literal text" `` to the source stream at file scope, so the
   parser meets `` 2.0 , "literal text" `` where a module item belongs and the
   file does not compile at all. Also dropped the header's claim that a
   `` `define `` sits among the pragma's arguments — none does — and demoted the
   macro-expansion mode from "caught" to "not discriminated, and here is why".
4. **`09` attributed `` `ifdef `` arm selection to §10.5** (Class B). §10.5 is
   *Predefined macros*; it requires the tool-specific macro to exist and says
   nothing about conditional compilation. §10.1 Table 10-1 marks `` `ifdef ``,
   `` `else `` and `` `endif `` "[IEEE Std 1364 Verilog]", and that 1364 clause
   is not in `docs/` — so the header now names the deferral and invents no
   subclause number. Fixed in the fixture and in the `09` row above.
5. **`10` could not fail for its own clause's reason** (Class D). Its only
   unconditional check was `V(p,n) = 0.5`, true of anything that can subtract,
   and its `localparam` check (`kfold * 3.0 == 6.0`) held identically for a
   `parameter`, a `real` or a literal. Now: the unconditional check is the
   reverse direction of §10.5's biconditional (see "Disputed"), and the two
   `localparam`s stand where only a constant expression may — an array bound and
   a parameter default — so swapping either for a `real` stops the file
   compiling. Measured at HEAD: `E0308 array bound is not a constant
   expression`, `E0314 unknown identifier: kfold`.

6. **`10` cited §3.4.3 for `localparam`.** §3.4.3 is *Parameter units and
   descriptions*; local parameters are **§3.4.5**, whose own sentence is what
   the fixture needs: a localparam is "identical to parameters except that they
   cannot directly be modified with the defparam statement or by the ordered or
   named parameter value assignment", i.e. a constant wherever a parameter is
   one. Corrected in the fixture header (twice) and in "Disputed" below.
7. **`11` carried four bare IEEE 1364 clause numbers in a directory where a
   bare §-number means the LRM in `docs/`.** Opened against that LRM, §7.9 is
   *Driver-receiver segregation* and §3.7 is *Real net declarations* — neither
   has anything to do with strength resolution. Every one of them now reads
   "IEEE 1364 §…", and the one place they appear inside a quotation (the
   `wired()` comment from `src/sim/digital.zig`) keeps the quote verbatim with
   the qualification outside it.
8. **`11` put a sentence in quotation marks that no fixture contains.** It
   attributed to `ch10_directives/58`/`59`/`60` the words "§19.10 pulls a
   digital net to a logic level through a `pull`-strength driver. The analog
   kernel has neither logic levels nor strengths". `grep` finds it in none of
   the three. 58's actual sentence, now quoted exactly: "WHAT A PULL IS IN THE
   ANALOG KERNEL, since §19.10 describes a logic level and a drive STRENGTH,
   and this engine has neither."
9. **`10` stitched two of `ch10_directives/14`'s sentences into one quotation.**
   14 reads "Whether it is defined is therefore an implementation fact and NOT
   something this fixture may assert." (line 2) and "The `else arm carries no
   §10.5 claim" (line 17), three paragraphs apart. Both are now quoted
   separately and verbatim; the paraphrase that merged them is gone. The other
   quotation of 14, in "Disputed" below, was checked and is verbatim.
10. **Disagreement — the review's "which is §10.4" for `` `ifdef `` arm
    selection.** Opened: §10.4 is *`define and `undef*, it defers those two
    directives to IEEE Std 1364, and it says nothing about conditional
    compilation. §10.1 Table 10-1 marks `` `ifdef ``, `` `ifndef ``, `` `else ``
    and `` `endif `` "[IEEE Std 1364 Verilog]" while marking `` `undef ``
    "[10.4]" — so the review is right that §10.5 was the wrong clause and wrong
    that §10.4 is the right one. There is **no** on-disk clause that fixes arm
    selection. `09` therefore names the deferral and invents no subclause
    number, which is what it now does. Writing `//! lrm 10.4` would have passed
    `validSection` and been just as false as `//! lrm 10.5` was.

**Re-run after these edits** (the "Observed today" block above was re-captured
from the same loop; all nine `ok=` columns outside `09` still read `ok=1`, `03`
is still refused with E0208 and `11` still fails with E1100). The three
counterfactuals quoted above were run rather than reasoned:
`localparam integer nslot` → `real nslot` gives
`error[E0308]: array bound is not a constant expression: in the bounds of
`fold``, `localparam real kfold` → `real kfold` gives
`error[E0314]: unknown identifier: `kfold``, and the `` `include ``-before-
`` `resetall `` variant gives `error[E0115]: undefined macro: `CHECKX`.

Not from the review, found while fixing it: Table G.3 has 27 rows, not 28 —
it is numbered 1–28 with no item 13. Corrected above.

## Disputed

**`ch10_directives/14`'s header sentence "A tool that supports every extension
and never defines the macro is conforming and lands there" is wrong**, and `10`
now asserts the opposite. §10.5 says the macro "shall be defined … **if and only
if** all the compact modeling extensions are supported" — 14's own quotation,
two lines above its sentence. "If and only if" makes *supported ⇒ defined* as
binding as *defined ⇒ supported*. Every item in Table G.3 is normative text of
the LRM in `docs/` (ddx §4.5.6, `localparam` §3.4.5, `$param_given` §9.19,
`$mfactor` §9.18, paramsets §6.4, `$limit` §9.17, `above` §5.10.3.2, …), so a
tool conforming to that LRM supports all of them and must define the macro. The
only implementations `10`'s unconditional check fails are ones shipping a strict
subset, and for those it states something true.

`ch10_directives/14` does not *assert* the sentence — its `else` arm checks
`2.0*V(p,n) == 1.0`, which is true whichever arm compiled — so there is no
fixture conflict, only a prose one. The file carrying it is outside this row's
scope to edit; flagged here for whoever owns `ch10_directives/COVERAGE.md`.

## Build / run

These live outside `tests/fixtures/`, so `zig build torture` does not see them.

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build                                    # refresh zig-out/bin/vera

# the ten analog fixtures
for f in tests/pending/D10/*.va; do
  echo "##### $(basename "$f")"
  ./zig-out/bin/vera --run --display=emit \
    --contract tools/contract.zig \
    -I tests/fixtures -I tests/pending/D10 \
    --work-dir "/tmp/d10/$(basename "$f")" "$f"
done

# the digital one
./zig-out/bin/vera --run \
  tests/pending/D10/11_unconnected_drive_pull_meets_the_strength_model.v \
  | diff - tests/pending/D10/11_unconnected_drive_pull_meets_the_strength_model.expected.txt
```

Every `ok=` column must read `ok=1` **except `09`'s two**, which are the gap
this row ships and read `ok=0` until `predefined_macros` grows a third entry.
`03` must be refused with E0208 and print nothing else, and `11` must fail with
E1100 until D03's strength model and D07's `--run` instantiation land.

To wire them into the green gate once §10.5's tool macro exists, move
`01`–`10` and the two `.vh` headers into `tests/fixtures/ch10_directives/`
(they are numbered from 01 to avoid colliding with that directory's 01–63 —
**renumber to 64+ on the move**), add their one-liners to that directory's
`COVERAGE.md`, and they are picked up by:

```sh
zig build torture -- --strict ch10
```

`11` belongs in `tests/digital/` with a `build.zig` `addRunArtifact` +
`expectStdOutEqual` pair alongside `scheduling.v`, and only once D03's strength
model and `--run` module instantiation exist. It is blocked on both.

## Added later: `assert` and `net_resolution` are ordinary identifiers (`d10_11`, `d10_12`)

Two fixtures written after the row was assembled, for the 2023 reserved-word set.
They belong to the approved-but-unimplemented tree: VerA reserves both words.

### why these two live in D10

The row's scope, quoted from the plan above, includes **"keyword-set transitions
via `` `begin_keywords ``/`` `end_keywords ``"**. Both fixtures are exactly that:
a module wrapped in `` `begin_keywords "VAMS-2023" `` whose only claim is which
spellings that set reserves. They are not about `` `default_nettype ``, macros or
pragmas, and they do not belong to `annex_b_keywords` or
`annex_c_analog_subset` — those rows pin what the *annexes* say, and the switches
that put a named set into effect are §10.6, which is this row.

### clause

§2.8.2 ("All keywords are defined in lowercase only. Annex B lists all defined
Verilog-AMS HDL keywords."), §10.6 (`"VAMS-2023" specifies that only the
identifiers listed as reserved keywords in the Verilog-AMS HDL are considered to
be reserved words`), and Annex B's opening sentence making Table B.1 the closed
and complete list. Two spellings are not in it in 2023:

| spelling | what the edition says | fixture |
|---|---|---|
| `assert` | in neither printing; §10.6's own worked example makes the argument for `logic` ("not a keyword in Verilog-AMS 2023, whereas it is a keyword in the IEEE Std 1800") | `d10_11_assert_is_an_ordinary_identifier.va` |
| `net_resolution` | Annex G item 5027: "Removed unused keyword net_resolution — B.1, C.16"; the 2.4 edition's C.16 list had ten words, 2023's has nine | `d10_12_net_resolution_is_an_ordinary_identifier.va` |

Both are therefore ordinary identifiers, and `real assert;` / `real
net_resolution;` must compile. Both fixtures instead use them as a **port and a
net name** so the assertion is a reading of the potential across the net, not a
declaration that gets discarded.

`tests/fixtures/annex_b_keywords/13_assert_reserved.va` and
`tests/fixtures/annex_c_analog_subset/20_net_resolution_reserved.va` asserted
the opposite and are the two fixtures being withdrawn. The second read C.16 as
listing ten words — the 2.4 count — and its own header admits the word "was for
a long time the one word of the ten VerA did not reserve, so it carried
`//! xfail`", which is the shape of a fixture arguing an implementation into a
bug. Neither is edited here; both are elsewhere and neither is this row's.

### fixtures

| fixture | wants | derivation |
|---|---|---|
| `d10_11_assert_is_an_ordinary_identifier.va` | `V(assert, n) == 1.0` | `//! bias V(assert) = 1.25, V(n) = 0.25`; §1.3.1 makes the branch potential the difference of the node potentials, 1.25 − 0.25. Both operands are binary-exact, so the difference is, and the check is CHECKX rather than a tolerance |
| `d10_12_net_resolution_is_an_ordinary_identifier.va` | `V(net_resolution, n) == 1.0` | identical, with `net_resolution` in the branch |

Both use the `` `begin_keywords "VAMS-2023" `` wrapper on purpose. §10.6: with no
directive above it, the keyword set is "the implementation's default set", so an
unwrapped file would pass for an implementation defaulting to 1364-2005 (where
both words are free for reasons unrelated to this claim) and fail for one
defaulting to VAMS-2.3. Naming the set removes both escapes: the file compiles
if and only if the VAMS-2023 set really is the Annex B list.
`d10_02_begin_keywords_region_survives_the_include_that_opened_it.va` makes the
same argument at length.

### Observed today

Both pass.

```
##### d10_11_assert_is_an_ordinary_identifier.va
`assert` names an ordinary net under the VAMS-2023 keyword set got=1 want=1 ok=1
##### d10_12_net_resolution_is_an_ordinary_identifier.va
`net_resolution` names an ordinary net under VAMS-2023 got=1 want=1 ok=1
```

They did not. Until `lib/frontend/token.zig`'s `reserved_keywords` lost the two
spellings, the parser refused the port before it ever reached the analog block:

```
FAIL tests/fixtures/ch10_directives/d10_11_assert_is_an_ordinary_identifier.va: did not compile: NoModule
error[E0208]: expected an identifier: found assert
  = note: LRM 2.8
FAIL tests/fixtures/ch10_directives/d10_12_net_resolution_is_an_ordinary_identifier.va: did not compile: NoModule
error[E0208]: expected an identifier: found net_resolution
  = note: LRM 2.8
```

`NoModule` rather than `CompileFailed` was the phase, not a second problem: the
reservation was enforced in the parser, so the port list never became a module
declaration and elaboration had nothing to select. E0208 was the diagnostic, and
it cited §2.8.2 — the clause that makes Annex B the whole list, which does not
contain either word.

The reservation was specific to the AMS sets and not to the spelling — the
identical modules under `` `begin_keywords "1364-2005" `` compiled even then —
so the fix was one table entry per word and not a parsing change. `token.zig`'s
`keyword_map` test now pins both spellings' absence, since both are easy to
re-add from an older printing. `m04_SPEC.md` records the same list as the place
`wreal` is reserved, which is why `13`'s removal sentence in Table G.7 ("B.1,
C.16") names the two clauses a fix has to move together.

**One thing the fix gives up, recorded rather than hidden.** `net_resolution`
*was* reserved under `"VAMS-2.3"` and `token.isReserved` can no longer say so:
§10.6's five sets are modelled as a nesting chain with one introduction date per
spelling, which cannot express a word that LEAVES a later set — and the unit
test in `token.zig` asserts exactly that monotonicity. Expressing it needs a
retirement date beside the introduction one. Nothing in the suite asks for it: a
file under `` `begin_keywords "VAMS-2.3" `` naming a net `net_resolution` ought
to be refused and is not.
