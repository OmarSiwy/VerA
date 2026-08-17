# Annex F coverage

Source: `docs/VAMS-LRM/annex-f-resolution.html`, read section by section.

HTML section-ID audit: `sF-1` `sF-2` `sF-2-1` `sF-2-2`. Four sections, and Annex F
is normative.

Seven fixtures live in this folder. Two of them — `continuous_discipline.va` and
`in_context_declaration.va` — cite no Annex F clause at all and are counted at the
bottom, not in the table. The other five cite Annex F and **all five are
`//! xfail`**. That is the honest headline: not one sentence of this annex is
currently met by the compiler under test, and the reason is the same in four of
the five files. Discipline resolution operates on an elaborated *signal* — a chain
of net segments joined through ports — and VerA is a flat single-module compiler
that refuses `module instantiation is not supported` (E0204) before any hierarchy
exists. The fifth (`conflicting_declarations.va`) needs no hierarchy and still
fails: the conflict is accepted silently.

| HTML id | Rule | Fixtures |
|---|---|---|
| `sF-1` | resolution semantics are 7.4's; this annex prints *a possible* algorithm, and other conforming algorithms are allowed | `hierarchy_resolution.va` (`//! lrm F.1`) — **`//! xfail`**. F.1 states no rule that can fail on its own; the cite is the fixture's argument that its design is one where F.2.1 and F.2.2 provably cannot disagree, so the assertion is about 7.4's semantics and not about an algorithm choice |
| `sF-2` | parent = upper connection, child = lower connection; post-order depth-first traversal; continuous passed up the hierarchy | `hierarchy_resolution.va` (`//! lrm F.2`) — **`//! xfail`**. Three segments deep, one declaration at the leaf, `Hpot`/`Hflw` access names so the top segment cannot resolve by accident. Post-order only; the top-down traversal *definition* in the same section has no fixture |
| `sF-2-1` | default algorithm: elaborate → in-context declarations → out-of-context declarations → conflict is an error → depth-first classify and resolve → insert converters | step 3 error, both halves: `conflicting_declarations.va` (in-context) and `conflicting_ooc_declarations.va` (out-of-context), both `//! reject E0902`, both **`//! xfail`**. Step 3 legal override: `out_of_context_declaration.va` — **`//! xfail`**. Step 4.b single-discipline bullet: `hierarchy_resolution.va` — **`//! xfail`**. Step 4.b unknown-with-mixed-port bullet: `unknown_discipline_mixed_port.va` (`//! reject E0903`) — **`//! xfail`**. Steps 1, 2 and the final insertion step have no fixture of their own |
| `sF-2-2` | alternate expanded analog algorithm: same first pass, then a *top-down* pass over nets left unknown or marked digital by step 4, then insertion | shared text only. `conflicting_declarations.va`, `conflicting_ooc_declarations.va`, `out_of_context_declaration.va` and `unknown_discipline_mixed_port.va` each carry `//! lrm F.2.2` because the steps they pin are printed word-for-word in both algorithms — each header says so. **F.2.2 step 5, the top-down pass that is the entire difference between the two algorithms, has no fixture.** All four cites are xfail besides |

Fixture-name audit, 7 files, all mapped above or below: `conflicting_declarations.va`,
`conflicting_ooc_declarations.va`, `continuous_discipline.va`,
`hierarchy_resolution.va`, `in_context_declaration.va`,
`out_of_context_declaration.va`, `unknown_discipline_mixed_port.va`.

## The xfail ledger

Every Annex F fixture in this folder runs and fails. Each names a concrete defect,
so the row disappears the day the defect does.

| Fixture | Section it serves | Reason |
|---|---|---|
| `conflicting_declarations.va` | `sF-2-1`, `sF-2-2` step 3 (in-context half) | VerA has no conflicting-discipline diagnostic. Two declarations for one net are accepted silently — zero diagnostics, exit 0. E0902 is *reserved* for this rule in class 9 of `src/diag_code.zig`; E0901 is the last code implemented, so nothing emits it. The reject line is a code and not `DiagnosticsReported` on purpose: a generic pattern would XPASS on the first unrelated diagnostic VerA ever learns to emit here |
| `conflicting_ooc_declarations.va` | `sF-2-1`, `sF-2-2` step 3 (out-of-context half) | The parser stops at the `.` of a dotted net declaration with E0207 "expected `;`" and refuses the instances with E0204, so no hierarchy is elaborated. Both the out-of-context declaration *form* and the step-3 conflict check are missing. Shares the reserved E0902 — the two halves of one sentence are one rule |
| `out_of_context_declaration.va` | `sF-2-1` step 3, legal override | Same parser wall: E0207 on the dotted name, E0204 on the instances. §3.10 precedence order 1 is not implemented. The fixture is built so a compiler that silently keeps the order-2 local declaration fails to *build* rather than passing by accident — `annex_f_x` names `Xpot`/`Xflw`, `annex_f_y` names `Ypot`/`Yflw`, and the assertion calls `Ypot` |
| `hierarchy_resolution.va` | `sF-1`, `sF-2`, `sF-2-1` step 4.b | `annex_f_h_mid ma(a)` is refused with E0204, so no signal hierarchy is ever built and the traversal never runs |
| `unknown_discipline_mixed_port.va` | `sF-2-1` 4.b bullet 4, `sF-2-2` 4.b and 5.b | E0204 on the instantiations plus E0201/E1001 on the `connectmodule` and `connectrules` design elements, so step 4 never runs. E0903 is reserved for the unresolvable-plus-mixed-port error next to E0902; nothing emits it |

Two reserved codes, three `//! reject` fixtures. Neither code exists in
`src/diag_code.zig` yet — that is the point of reserving them rather than betting
the fixture on a message fragment.

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
  own precedence and are themselves xfail (the preprocessor marks it `.ignored`);
  neither reaches resolution, which is what this bullet is about.
- **F.2.1 step 4.b bullet 3, the resolution `connect` statement.** `resolveto`
  appears exactly once in this folder, in a comment in
  `unknown_discipline_mixed_port.va` explaining that its own `connect` statements
  are §7.7.1 *insertion* and deliberately not resolution. No source matches a
  discipline list against a resolution statement.
- **F.2.1 step 4.b bullet 4, the legal half.** Unknown-and-legal (unknown discipline
  with no mixed-port connection) has no fixture; only the error half does.
- **F.2.1 / F.2.2 final step, converter selection and insertion (7.7, 7.8).**
  `unknown_discipline_mixed_port.va` is the only source with a `connectmodule` or a
  `connectrules` block, and it never reaches insertion by construction — §7.6 puts
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
