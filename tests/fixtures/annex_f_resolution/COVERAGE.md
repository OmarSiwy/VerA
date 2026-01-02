# Annex F coverage

Source: `docs/annex-f-resolution.html`, read section by section.

HTML section-ID audit: `sF-1` `sF-2` `sF-2-1` `sF-2-2`. Four sections, and Annex F
is normative.

Seven fixtures live in this folder: 3 carry a `//! reject` arm, 4 run and assert, and
**exactly one is `//! xfail`** — grep-measured, `unknown_discipline_mixed_port.va`. Two
of the seven — `continuous_discipline.va` and `in_context_declaration.va` — cite no Annex
F clause at all and are counted at the bottom, not in the table.

This paragraph used to read "all five cite Annex F and all five are `//! xfail` … not one
sentence of this annex is currently met", and the reason it gave for four of the five was
that resolution needs an elaborated *signal* while VerA was a flat single-module compiler
refusing `module instantiation is not supported` (E0204, now retired). Both halves are
dead: `ir/elaborate.zig` flattens the instance tree, so a signal's segments collapse into
one node and F.2's parent/child relation *is* the port binding, and `Elaborate.resolveDiscipline`
gives an undeclared parent its declared child's discipline. Four of the five are green.
The one that is left needs neither hierarchy nor a digital engine — see its row.

| HTML id | Rule | Fixtures |
|---|---|---|
| `sF-1` | resolution semantics are 7.4's; this annex prints *a possible* algorithm, and other conforming algorithms are allowed | `hierarchy_resolution.va` (`//! lrm F.1`) — green. F.1 states no rule that can fail on its own; the cite is the fixture's argument that its design is one where F.2.1 and F.2.2 provably cannot disagree, so the assertion is about 7.4's semantics and not about an algorithm choice |
| `sF-2` | parent = upper connection, child = lower connection; post-order depth-first traversal; continuous passed up the hierarchy | `hierarchy_resolution.va` (`//! lrm F.2`) — green. Three segments deep, one declaration at the leaf, `Hpot`/`Hflw` access names so the top segment cannot resolve by accident. Post-order only; the top-down traversal *definition* in the same section has no fixture |
| `sF-2-1` | default algorithm: elaborate → in-context declarations → out-of-context declarations → conflict is an error → depth-first classify and resolve → insert converters | step 3 error, both halves: `conflicting_declarations.va` (in-context, lowering's own E0902) and `conflicting_ooc_declarations.va` (out-of-context, elaboration's — a duplicate KEY in the out-of-context table, since §3.10 makes two declarations at one precedence level illegal whether or not the disciplines are compatible), both `//! reject E0902`, both green. Step 3 legal override: `out_of_context_declaration.va` — green. Step 4.b single-discipline bullet: `hierarchy_resolution.va` — green. Step 4.b unknown-with-mixed-port bullet: `unknown_discipline_mixed_port.va` (`//! reject E0903`) — still **`//! xfail`**, and NOT for want of a second simulation domain — it demands an error, not an execution. What is missing is a resolution rule: `resolveDiscipline` keeps the FIRST declared discipline of a signal's segments instead of collecting the SET, so "more than one candidate whose domain matches" is never decided. E0903 is reserved for it. Steps 1, 2 and the final insertion step have no fixture of their own |
| `sF-2-2` | alternate expanded analog algorithm: same first pass, then a *top-down* pass over nets left unknown or marked digital by step 4, then insertion | shared text only. `conflicting_declarations.va`, `conflicting_ooc_declarations.va`, `out_of_context_declaration.va` and `unknown_discipline_mixed_port.va` each carry `//! lrm F.2.2` because the steps they pin are printed word-for-word in both algorithms — each header says so. **F.2.2 step 5, the top-down pass that is the entire difference between the two algorithms, has no fixture.** Three of the four cites are green now; `unknown_discipline_mixed_port.va` is the exception |

Fixture-name audit, 7 files, all mapped above or below: `conflicting_declarations.va`,
`conflicting_ooc_declarations.va`, `continuous_discipline.va`,
`hierarchy_resolution.va`, `in_context_declaration.va`,
`out_of_context_declaration.va`, `unknown_discipline_mixed_port.va`.

## The xfail ledger

One Annex F fixture in this folder still runs and fails. The rest of this ledger is
kept, struck through in prose, because the reason each row gave was the reason it closed.

| Fixture | Section it serves | Reason |
|---|---|---|
| `conflicting_declarations.va` | `sF-2-1`, `sF-2-2` step 3 (in-context half) | Green: E0902 exists and lowering emits it for one net with two declarations |
| `conflicting_ooc_declarations.va` | `sF-2-1`, `sF-2-2` step 3 (out-of-context half) | Green: a dotted net declaration parses (interned as one path string) and elaboration refuses a second one for the same segment with E0902 — the same code as the in-context half, because it is one sentence and one rule |
| `out_of_context_declaration.va` | `sF-2-1` step 3, legal override | Green, and it built rather than passing by accident: `annex_f_x` names `Xpot`/`Xflw`, `annex_f_y` names `Ypot`/`Yflw`, and the assertion calls `Ypot`, which only exists if §3.10 order 1 really replaced the leaf's local declaration |
| `hierarchy_resolution.va` | `sF-1`, `sF-2`, `sF-2-1` step 4.b | Green. Flattening collapses every segment of one signal into a single node, so F.2's parent/child relation IS the port binding: a segment that declares a discipline gives it to the signal and an undeclared parent inherits it (`Elaborate.resolveDiscipline`). The known ceiling is TWO declared segments of one signal, which is §3.11's compatibility rule and not this one |
| `unknown_discipline_mixed_port.va` | `sF-2-1` 4.b bullet 4, `sF-2-2` 4.b and 5.b | Still xfail, and the blocker has moved: the `connectmodule` halves PARSE and are accepted now (§7.6, A.1.2 — `ch07_mixed_signal/connectmodule_accepted.va`), so the keyword is not it, and neither is a discrete-time domain — this fixture demands an error, not an execution. What is missing is a RESOLUTION rule: `Elaborate.resolveDiscipline` keeps the FIRST declared discipline of a signal's segments and never builds the SET, so step 4.b's "more than one candidate whose domain matches, no `resolveto` for it, therefore UNKNOWN" is never decided and the mixed-port test over it never fires. `connectrules` is also still E0201. E0903 stays reserved for the rule |

One reserved code left, E0903, and one fixture behind it. E0902 was the other and it
exists now — which is what reserving a code rather than betting the fixture on a
message fragment is for: the fixture's `//! reject` line never had to change.

## What this annex needs that no fixture supplies

An empty cell above is a real gap, and these are the gaps:

- **F.2 top-down traversal, as a definition.** F.2 defines both orders. Only
  post-order is exercised.
- **F.2 continuous-over-discrete precedence, resolved rather than rejected.** The
  one fixture with a discrete segment (`unknown_discipline_mixed_port.va`) makes
  that segment an *error* case. No fixture shows the continuous domain winning at a
  level where both domains are present and the answer is legal.
- **F.2.1 step 1 (elaborate) and step 2 (in-context declarations), inside a
  hierarchy.** `in_context_declaration.va` is one flat module and its own header
  says Annex F never runs on it.
- **F.2.1 step 4.a digital classification.** No fixture in this folder contains
  digital behavioral code — no `always`, no `initial`, no `reg`. Neither the "used
  in digital behavioral code" clause nor the "all child nets digital" clause is
  exercised.
- **F.2.1 step 4.b bullet 1, the `` `default_discipline`` fallback.** The directive
  does not appear in any source here. `ch10_directives/35_default_discipline_reset_leaves_no_default.va`
  and `ch10_directives/36_resetall_clears_default_discipline.va` pin the directive's
  own precedence and are green now (both `//! reject E0337` — the directive is applied,
  and *resetting* it leaves the net with no discipline); neither reaches resolution,
  which is what this bullet is about.
- **F.2.1 step 4.b bullet 3, the resolution `connect` statement.** `resolveto`
  appears exactly once in this folder, in a comment in
  `unknown_discipline_mixed_port.va` explaining that its own `connect` statements
  are §7.7.1 *insertion* and deliberately not resolution. No source matches a
  discipline list against a resolution statement.
- **F.2.1 step 4.b bullet 4, the legal half.** Unknown-and-legal (unknown discipline
  with no mixed-port connection) has no fixture; only the error half does.
- **F.2.1 / F.2.2 final step, converter selection and insertion (7.7, 7.8).**
  `unknown_discipline_mixed_port.va` is the only source here with a `connectmodule` or a
  `connectrules` block (the connect modules are accepted; the `connectrules` is E0201),
  and it never reaches insertion by construction — §7.6 puts
  insertion after resolution and this fixture demands that resolution error out
  first. Insertion itself belongs to `ch07_mixed_signal/`.
- **F.2.2 step 5 in full.** The top-down re-classification pass, the re-examination
  of nets assigned a digital domain in step 4, and the parent-discipline list of
  5.b are the only content unique to the alternate algorithm, and nothing here
  touches any of it.

Selecting F.2.2 over F.2.1 "shall be controlled by a simulator option" and is not
Verilog-AMS source syntax. That row is a language boundary, not a debt — but the
step-5 semantics behind it are a debt, and the two should not be confused.

## Fixtures in this folder that cite Chapter 3, not Annex F

Two fixtures pass. Neither is Annex F coverage, and both say so in their own
headers. Annex F resolves the discipline of *undeclared* interconnect; in both of
these the net carries an explicit discipline in the module it belongs to, so no
Annex F sentence is reached.

- `continuous_discipline.va` (`3.6.2.2`, `3.6.3`) — a user-declared conservative
  discipline binding both natures, read back through the access functions its
  natures name.
- `in_context_declaration.va` (`3.10`, `3.6.2.2`, `3.6.3`) — §3.10 precedence order 2
  written with the §3.6.3 `discipline_identifier list_of_net_identifiers ;` form,
  with distinct access names (`Fpot`/`Fflw`) so the binding is observable rather
  than assumed. This is the local declaration that `out_of_context_declaration.va`
  exists to override.

Both are dc: four fixtures carry `//! bias`, none carries `//! analysis`.
