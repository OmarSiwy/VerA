# Annex F coverage

Source: `docs/annex-f-resolution.html`, read section by section.

HTML section-ID audit: `sF-1` `sF-2` `sF-2-1` `sF-2-2`. Four sections, and Annex F
is normative.

The bare `F` clause that `tests/harness.zig` reads out of `Annex F (normative) Discipline
resolution methods` is untestable, and no fixture cites it. The annex title carries no body
text of its own in `docs/annex-f-resolution.html` — the page goes from the heading straight
to F.1 — so there is no sentence to exercise; F.1's and F.2's rows below are where the
content is.

Eleven fixtures live in this folder: 4 carry a `//! reject` arm, 7 run and assert, and
**none is `//! xfail`** — grep-measured. Two of the eleven — `continuous_discipline.va`
and `in_context_declaration.va` — cite no Annex F clause at all and are counted at the
bottom, not in the table.

This paragraph used to read "exactly one is `//! xfail`", and before that "all five cite
Annex F and all five are `//! xfail` … not one sentence of this annex is currently met".
Both stages closed the same way: the first when `ir/elaborate.zig` flattened the instance
tree — a signal's segments collapse into one node, F.2's parent/child relation *is* the
port binding, and `Elaborate.resolveDiscipline` gives an undeclared parent its declared
child's discipline — and the last when step 4.b's multi-candidate arm landed
(`Elaborate.resolveMultiCandidates`): the walk now also collects the SET of a signal's
segment disciplines, partitions it by domain (4.a), matches it against the parsed
`connectrules` block's §7.7.2 resolution statements (4.b bullet 3, set equality;
`resolveto exclude` refuses instead, E0917), and fires the fourth bullet's mixed-port
error (E0903) where no statement matches. `connectrules` itself parses since the same
wave (A.1.8; it was E0201).

| HTML id | Rule | Fixtures |
|---|---|---|
| `sF-1` | resolution semantics are 7.4's; this annex prints *a possible* algorithm, and other conforming algorithms are allowed | `hierarchy_resolution.va` (`//! lrm F.1`) — green. F.1 states no rule that can fail on its own; the cite is the fixture's argument that its design is one where F.2.1 and F.2.2 provably cannot disagree, so the assertion is about 7.4's semantics and not about an algorithm choice |
| `sF-2` | parent = upper connection, child = lower connection; post-order depth-first traversal; continuous passed up the hierarchy | `hierarchy_resolution.va` (`//! lrm F.2`) — green. Three segments deep, one declaration at the leaf, `Hpot`/`Hflw` access names so the top segment cannot resolve by accident. Post-order only; the top-down traversal *definition* in the same section has no fixture |
| `sF-2-1` | default algorithm: elaborate → in-context declarations → out-of-context declarations → conflict is an error → depth-first classify and resolve → insert converters | step 3 error, both halves: `conflicting_declarations.va` (in-context, lowering's own E0902) and `conflicting_ooc_declarations.va` (out-of-context, elaboration's — a duplicate KEY in the out-of-context table, since §3.10 makes two declarations at one precedence level illegal whether or not the disciplines are compatible), both `//! reject E0902`, both green. Step 3 legal override: `out_of_context_declaration.va` — green. Step 4.b single-discipline bullet: `hierarchy_resolution.va` — green. Step 4.b resolution-statement bullet: `resolveto_resolution.va` — green, a two-candidate net resolved by its matching `connect ... resolveto` statement to a discipline that is NEITHER candidate (§7.7.2.1 allows that, and it is what makes the assertion observable: the resolved discipline's own access function). Step 4.b unknown-with-mixed-port bullet: `unknown_discipline_mixed_port.va` (`//! reject E0903`) — **green**, the folder's last xfail closed: `Elaborate.resolveMultiCandidates` collects the SET of segment disciplines, finds {annex_f_a, annex_f_b} unmatched by any resolution statement, and errors on the discrete crossing. The §7.7.2 `exclude` refusal that rides the same arm: `exclude_resolution.va` (`//! reject E0917`) — green. Steps 1, 2 and the final insertion step have no fixture of their own |
| `sF-2-2` | alternate expanded analog algorithm: same first pass, then a *top-down* pass over nets left unknown or marked digital by step 4, then insertion | shared text only. `conflicting_declarations.va`, `conflicting_ooc_declarations.va`, `out_of_context_declaration.va`, `resolveto_resolution.va`, `exclude_resolution.va` and `unknown_discipline_mixed_port.va` each carry `//! lrm F.2.2` because the steps they pin are printed word-for-word in both algorithms — each header says so. **F.2.2 step 5, the top-down pass that is the entire difference between the two algorithms, has no fixture** (in the flattened design both traversals see the same one-node segment set, which is why `resolveMultiCandidates` implements them as one pass — its doc says so). All six cites are green |

Fixture-name audit, 11 files, all mapped above or below: `conflicting_declarations.va`,
`conflicting_ooc_declarations.va`, `continuous_discipline.va`, `exclude_resolution.va`,
`hierarchy_resolution.va`, `in_context_declaration.va`,
`out_of_context_declaration.va`, `out_of_context_internal_net.va`,
`out_of_context_long_path.va`, `resolveto_resolution.va`,
`unknown_discipline_mixed_port.va`.

## The xfail ledger

NO Annex F fixture runs and fails any more. The ledger is kept, struck through in
prose, because the reason each row gave was the reason it closed.

| Fixture | Section it serves | Reason |
|---|---|---|
| `conflicting_declarations.va` | `sF-2-1`, `sF-2-2` step 3 (in-context half) | Green: E0902 exists and lowering emits it for one net with two declarations |
| `conflicting_ooc_declarations.va` | `sF-2-1`, `sF-2-2` step 3 (out-of-context half) | Green: a dotted net declaration parses (interned as one path string) and elaboration refuses a second one for the same segment with E0902 — the same code as the in-context half, because it is one sentence and one rule |
| `out_of_context_declaration.va` | `sF-2-1` step 3, legal override | Green, and it built rather than passing by accident: `annex_f_x` names `Xpot`/`Xflw`, `annex_f_y` names `Ypot`/`Yflw`, and the assertion calls `Ypot`, which only exists if §3.10 order 1 really replaced the leaf's local declaration |
| `out_of_context_long_path.va` | `sF-2-1` step 3, past 256 path bytes | Green. `out_of_context_internal_net.va` with a 270-character instance identifier: `Elaborate.oocDiscipline` used to build its lookup key in a fixed 256-byte buffer and swallow the overflow, so a long path silently KEPT its local declaration — order-1 precedence inverted for long names only. The key join allocates now, like every sibling |
| `hierarchy_resolution.va` | `sF-1`, `sF-2`, `sF-2-1` step 4.b | Green. Flattening collapses every segment of one signal into a single node, so F.2's parent/child relation IS the port binding: a segment that declares a discipline gives it to the signal and an undeclared parent inherits it (`Elaborate.resolveDiscipline`). The known ceiling is TWO declared segments of one signal, which is §3.11's compatibility rule and not this one |
| `unknown_discipline_mixed_port.va` | `sF-2-1` 4.b bullet 4, `sF-2-2` 4.b and 5.b | Green, and it closed exactly along the line its last update drew: the blocker was a RESOLUTION rule, not a design element. `connectrules` parses (A.1.8; the file's block is two §7.7.1 insertions, which name real connect modules and resolve nothing — the distinction its header stands on), and `Elaborate.resolveMultiCandidates` now builds the SET of segment disciplines, decides "more than one candidate whose domain matches, no `resolveto` for it, therefore UNKNOWN", and fires the mixed-port test over it. E0903 emitted for the first time |

No reserved codes left in class 9. E0902 closed first, E0903 last — which is what
reserving a code rather than betting the fixture on a message fragment is for: neither
fixture's `//! reject` line ever had to change.

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
- **F.2.1 step 4.b / §7.7.2.1 matching:** exact-match precedence, subset fallback and first-match warnings (W0950) are now implemented and checked in `lib/ir/elaborate.zig` tests.

- **F.2.1 step 4.b bullet 4, the legal half.** Unknown-and-legal (unknown discipline
  with no mixed-port connection) has no fixture; the error half does, and the legal
  half is pinned by a unit test in `lib/ir/elaborate.zig` (the net keeps its first
  arrival and the design elaborates).
- **F.2.1 / F.2.2 final step, converter selection and insertion (7.7, 7.8).**
  `connectmodule` declarations and `connectrules` blocks are accepted and validated
  (E0915/E0916 name the checks), but no fixture reaches insertion because VerA has
  no insertion phase at all — §7.6 puts it after resolution, and the two reject
  fixtures here error out in resolution by construction. Insertion itself belongs
  to `ch07_mixed_signal/`.
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

Both are dc: seven fixtures carry `//! bias`, none carries `//! analysis`.
