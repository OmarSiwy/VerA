# Text macros: inherited-source obligation worklist

Source read: IEEE 1364-2005 §§19.3–19.3.2, physical PDF pages 380–382,
2026-09-23, inherited by VAMS §10.4. Escaped-name interaction also uses
IEEE §3.7.1, physical page 44, and VAMS §2.8.1. Both AMS and its analog
profile require these preprocessing behaviors. This is a partial worklist,
not a certified atomic inventory of Clause 19.

Fixture paths below are relative to `tests/fixtures/ch10_directives`.
“Observed” means the named case supplies evidence, not all possible uses.
Ordinary macro semantics do not require invented invalid neighbors; specific
prohibitions and syntax constraints do require isolated negative cases.

| ID | Source | Obligation and discriminating evidence |
|---|---|---|
| MAC-001 | 19.3 / p380 | `resetall` preserves the text macro facility. `audit_macro_resetall_preserves_user.va` expects definedness and value to survive. **Known failure MAC-RESET-001**, detailed below. Predefined-only fixture `28` did not test user macros. |
| MAC-002 | 19.3.1 / p380 | Definition works inside and outside modules; no module scope restriction. `audit_macro_late_binding.va` defines its outer macro outside and inner macro inside. Cross-module and separate input-file lifetime remain open. |
| MAC-003 | 19.3.1 / p380 | Compiler directive names cannot be redefined as macro names. Isolated negative fixtures for the directive-name set remain open; ordinary-identifier permission is a different rule. |
| MAC-004 | Syntax 19-2 / p380 | Macro names are identifiers; formal names are simple identifiers. `47_escaped_macro_name.va`, `46_macro_formal_must_be_simple_identifier.va` and `50_escaped_names_in_directives.va` are existing cases; boundary/context inventory remains open. |
| MAC-005 | 19.3.1 / p380 | An uncontinued newline terminates the definition; a continued newline is retained without its backslash. `06_define_multiline.va` observes the continued arithmetic body, not newline preservation itself. Its misleading newline-removal comment was corrected; a newline-sensitive oracle remains open. |
| MAC-006 | 19.3.1 / pp380–381 | Formal substitution is confined to the replacement body and uses identifier boundaries. Substring/string/comment/escaped-token interactions require separate cases. Existing compound-expression `05` is not exhaustive here. |
| MAC-007 | 19.3.1 / p381 | Definition parentheses must immediately follow the macro name to make a parameterized macro. `audit_macro_empty_and_spacing.va` distinguishes a spaced object body from a function macro; malformed formal-list alternatives remain open. |
| MAC-008 | 19.3.1 / p381 | Line comments in macro text are not substituted. `audit_macro_empty_and_spacing.va` observes a complete assignment after invoking a macro with a trailing comment. Multiline/comment-boundary interactions remain open. |
| MAC-009 | 19.3.1 / p381 | Empty replacement text is legal and does not undefine the macro. The same fixture observes empty expansion in an expression and conditional definedness separately. |
| MAC-010 | 19.3.1 / p381 | Object replacement and actual-expression substitution preserve the specified text rather than adding implicit parentheses. `04` and `05` cover basic substitution; precedence without user parentheses and side-effect multiplicity need dedicated cases. |
| MAC-011 | 19.3.1 / p381 | Invocation permits whitespace before its argument list. `audit_macro_empty_and_spacing.va` observes a spaced call; tab/newline and comments at the boundary remain open. |
| MAC-012 | 19.3.1 / p381 | Actual count matches formal count. Separate `audit_macro_too_few_actuals_rejected.va` and `audit_macro_too_many_actuals_rejected.va` pin E0117; the spaced two-argument positive call is a legal neighbor. Missing list/empty expressions and nested separator cases need separate dispositions. |
| MAC-013 | 19.3.1 / p381 | Macro replacement cannot split lexical tokens. The published list includes comments, numbers, strings, identifiers, keywords and operators. Enumerating those boundaries and invalid split cases remains open. |
| MAC-014 | 19.3.1 / p382 | Entire actual expressions are substituted literally. `audit_macro_escaped_actual.va` isolates a lost lexical terminator; **known failure KEY-MACRO-001**. The simple control in that file does not execute while compilation fails; `05` supplies independent basic positive evidence. |
| MAC-015 | 19.3.1 / p382 | Repeating a formal can evaluate an actual expression repeatedly. No independent side-effect-count oracle identified in this pass. Arithmetic equality alone cannot prove evaluation multiplicity. |
| MAC-016 | 19.3.1 / p382 | Directive keywords can be ordinary identifiers; macro names and ordinary identifiers occupy distinct namespaces. `audit_macro_empty_and_spacing.va` uses a variable named `define`; same-name macro/variable interaction and the other directive spellings remain open. |
| MAC-017 | 19.3.1 / p382 | Redefinition is permitted and the latest definition governs subsequent uses. `audit_macro_late_binding.va` observes its nested value changing from 2 to 5. Redefinition shape/arity transitions remain open. |
| MAC-018 | 19.3.1 / p382 | Nested macros are expanded at use, not when the outer macro is defined. The late-binding fixture defines the outer before the inner exists and observes subsequent redefinition; eager capture cannot satisfy this sequence. |
| MAC-019 | 19.3.1 / p382 | Direct recursive replacement is an error. `audit_macro_direct_recursion_rejected.va` isolates E0118; it does not rely on a process timeout or generic compile failure. |
| MAC-020 | 19.3.1 / p382 | Indirect recursive replacement is also an error. `audit_macro_indirect_recursion_rejected.va` supplies a two-name cycle. Existing `49_nested_macro_argument.va` is the non-cycle counterpart; preprocessor unit tests alone were previously the negative evidence. |
| MAC-021 | 19.3.2 / p382 | Undefinition removes the user macro. `08_undef_conditional.va` and the late-binding fixture observe the absent branch; expansion after undefinition should also have an isolated negative case. |
| MAC-022 | 19.3.2 / p382 | Undefining a previously undefined name may warn; an optional warning must not become a required test outcome. A dedicated no-fatal-error case remains open. |

VAMS §10.4's reserved-prefix and predefined-macro restrictions additionally
apply; this table does not replace them. The historical name-versus-body
ambiguity recorded in fixtures `15`/`34` remains explicit. Interactive macro
definition/use and multi-file compilation also need implementation-interface
and host dispositions; a single included file is not all such workflows.

## MAC-RESET-001: measured contradiction

The first late-binding test also crossed `resetall` and failed at its subsequent
`AUDIT_OUTER` use with E0115. The reset obligation was moved into
`audit_macro_resetall_preserves_user.va`, not removed or inverted. The separate
late-binding/redefinition/undefinition test now runs independently.

The isolated reset fixture includes assertion helpers after reset, and uses
conditional branches so the wrong implementation still emits observations:
definedness is 0 instead of 1, and the value witness is -1 instead of 7. Its
positive expectation is marked XFAIL. The compiler has not been modified.

`lib/frontend/preprocessor.zig`'s `.resetall` handler removes every macro without
the `predefined` flag. Its unit test named “§10.5 predefined macros survive
undef and resetall” explicitly expects a user macro to become undefined and
cites the deleted `20_resetall_clears_macro` fixture. That unit expectation
contradicts IEEE §19.3. A green unit suite therefore does not establish this
requirement; the future behavior fix must update that erroneous unit assertion
and the enum/comment claims along with preserving the other reset effects.

## Execution and remaining oracle limits

The targeted run `zig build benchmark -- --strict ch10_directives/audit_macro_`
exits 1 because of the documented positive XFAILs. The other newly added cases
pass. Direct execution of the reset fixture emits the two wrong-value witnesses
above; its process exit status alone is not the behavioral oracle. The strict
runner interprets the `ok=` verdicts and enforces each positive fixture's
declared observation total.

The subsequent full strict run exits 1. Its nonempty, normalized FAIL/XFAIL
name-list diff against the preceding IEEE-source checkpoint contains only the
new `audit_macro_resetall_preserves_user.va` XFAIL; all existing names remain.
`tools/conformance.sh` regenerated the measurement report from this full run
and reran the gates: unit tests pass, digital tests remain failing. No overall
green-suite or conformance claim follows from the new passing macro cases.

No claim is made that these tests exhaust preprocessing, source maps, expansion
limits or token-boundary combinations. This work adds evidence to A, while C
still merely counts existing clause citations. B's historical §§17–18 tally
does not count Clause 19, so full-AMS inherited coverage needs this additional
inventory even if B were eventually closed. Architecture measure D is unchanged.
