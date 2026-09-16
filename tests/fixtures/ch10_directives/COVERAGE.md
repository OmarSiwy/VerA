# Chapter 10 coverage

Source: `docs/ch10-directives.html`, read section by section.

HTML section-ID audit: `s10-1` `s10-2` `s10-3` `s10-4` `s10-5` `s10-6` `s10-7`.
Seven ids, seven with at least one fixture. 50 files, numbered 01–51 with 20
missing — `20_resetall_clears_macro.va` was deleted, not renamed, because it
asserted that `resetall` undefines a text macro and nothing in the LRM says so
(`resetall` appears exactly twice: the 10.1 table row and 10.2's reset
sentence). A conforming tool failed it. `36`'s header records the reasoning.

Every section has a fixture, so the interesting number here is not the section
count but the fixtures that state a rule this compiler does not meet. §10.2,
§10.3 and §10.7 are implemented: `` `default_discipline `` is parsed and fed to
§7.4 discipline resolution, `` `default_transition `` is parsed (operand
included — E0129) and published as a positional event list that §4.5.8's
rise/fall defaulting consults, and `` `__FILE__ ``/`` `__LINE__ ``/`` `line ``
expand and remap. The four `` `default_transition `` fixtures that used to lead
this paragraph closed together with §4.5.8's piecewise-linear ramp, which was
the second half of their one cause.

Table 10-1 in §10.1 lists 23 directives. All 23 appear in some fixture in this
folder; that is checkable by grep and it is checked. The previous version of
this file claimed the table was not exhausted and named four directives
(decay/strength, delay-mode, protect, `` `unconnected_drive ``) as missing —
three of those are not in Table 10-1 at all, and the fourth is in `19`.

| HTML id | Rule | Fixtures |
|---|---|---|
| `s10-1` | accent grave (0x60) is not the apostrophe (0x27) | `37_apostrophe_is_not_accent_grave.va` (`'define GAIN 3.0` one character off `04`; `//! reject E0201`) |
| `s10-1` | conditional compilation, deferred to IEEE Std 1364 §19.4 | `09_ifdef_else.va`, `10_ifndef.va`, `11_elsif.va`, `12_nested_conditionals.va` — each arm asserts its own coefficient, so the surviving arm names itself in the digit |
| `s10-1` | `` `include ``, deferred to IEEE Std 1364 | `18_include_constants.va` (`constants.vams`, self-guarded, annex D.2 default selection pinned by the product `P_K*P_C`) |
| `s10-1` | the digital carry-over directives, and the scope sentence | `19_ignored_standard_directives.va`: `` `timescale ``, `` `default_nettype ``, `` `celldefine ``/`` `endcelldefine ``, `` `pragma ``, `` `line ``, `` `unconnected_drive ``/`` `nounconnected_drive ``. Pins that `` `timescale `` does not rescale `$abstime` (2.5e-9 s, not 2.5 ticks) and that none of them moves the branch potential. The `pull1` pair is written open-before/close-after the module, the way the scope sentence reads |
| `s10-2` | the directive is accepted, base and qualified forms | `01_default_discipline.va`, `02_default_discipline_qualified.va` (`real` qualifier, deliberately inapplicable) |
| `s10-2` | the bare form is legal (Syntax 10-1 brackets) and is not retroactive | `24_default_discipline_empty_reset.va` |
| `s10-2` | the positive effect: a default reaches an UNDECLARED net | `41_default_discipline_undeclared_net.va` — discriminating: delete the directive and the module dies at E0337 |
| `s10-2` | two qualifiers in force at once; more specific wins | `42_default_discipline_two_qualifiers.va` (`wire` claims the ports, `reg` must not) — discriminating: swap the qualifiers and `V()` dies at E0501 on `ddiscrete` |
| `s10-2` | the qualifier slot is a closed 15-way alternation | `45_default_discipline_qualifier_grammar.va` (E0127) |
| `s10-2` | the bare form withdraws the default for later nets | `35_default_discipline_reset_leaves_no_default.va` — green, `//! reject E0337`: the fixture used to guess E0501 |
| `s10-2` | `` `resetall `` withdraws it too ("In addition to `resetall") | `36_resetall_clears_default_discipline.va` — green, `//! reject E0337`, same corrected code as `35` |
| `s10-3` | the directive is accepted; §4.5.8 DC pass-through survives it | `03_default_transition.va` — the 1n itself is deliberately not pinned, and the header says why |
| `s10-3` | the default IS the rise/fall time of an argument-free filter | `38_default_transition_ramp.va` |
| `s10-3` | a later directive supersedes an earlier one | `39_default_transition_supersedes.va` |
| `s10-3` | explicit filter arguments beat the directive | `40_transition_arguments_override_default.va` |
| `s10-3` | Syntax 10-2's operand is mandatory (no brackets) | `48_default_transition_requires_an_operand.va` (`//! reject E0129`, upgraded from the substring it carried while no code existed) |
| `s10-4` | object-like `` `define `` | `04_define_object.va` |
| `s10-4` | `list_of_formal_arguments`, actual-argument text substitution | `05_define_function.va` (compound actual, bracketing pinned by 2.25 vs 2.0) |
| `s10-4` | backslash-newline continuation of the macro text | `06_define_multiline.va` |
| `s10-4` | a macro text may itself use a macro | `07_nested_macros.va` |
| `s10-4` | a nested invocation in an ACTUAL argument is not recursion (1364's rule is about the TEXT) | `49_nested_macro_argument.va` — arguments expand before substitution; used to be a false E0118 "MAX -> MAX" |
| `s10-4` | actual-argument brackets must MATCH their openers; `]` cannot close `(` | `51_mismatched_macro_argument_bracket.va` (`//! reject E0120`; one shared depth counter used to accept it) |
| `s10-4` | the escaped-name production reaches `` `undef ``/`` `ifdef ``/`` `ifndef ``/`` `elsif `` (and 10.2's discipline slot), not just `` `define `` | `50_escaped_names_in_directives.va` — also cites 10.2 |
| `s10-4` | `` `undef `` removes a user macro | `08_undef_conditional.va` |
| `s10-4` | use of an undefined macro is illegal (1364 §19.3.1) | `23_undefined_macro.va` (`//! reject E0115`) |
| `s10-4` | Syntax 10-3: the NAME is `identifier`, so unrestricted by prefix | `15_define_vams_prefixed_name.va` — a hard must-compile on a **contested reading**, bet deliberately against `34`; no xfail to hide behind |
| `s10-4` | Syntax 10-3: the FORMAL is `simple_identifier`, escapes barred | `46_macro_formal_must_be_simple_identifier.va` (`//! reject E0110`) |
| `s10-4` | Syntax 10-3: the NAME may be escaped (`identifier` is wider) | `47_escaped_macro_name.va` — green, and it runs: the `` `define `` name takes an escaped identifier |
| `s10-4` | the macro TEXT shall not begin with `__VAMS_` | `34_define_vams_macro_text.va` — green, `//! reject E0139` |
| `s10-4` | `` `undef `` has no effect on a predefined macro | `28_undef_predefined_macro.va` (also cites 10.5; crosses `` `resetall `` and `` `undef `` against `__VAMS_ENABLE__`, which `13` and `08` never crossed) |
| `s10-5` | `__VAMS_ENABLE__` is always defined | `13_predefined_vams_enable.va` (gain witness: 1.0 from the surviving arm, 2.0 from the dead one), `28_undef_predefined_macro.va` |
| `s10-5` | `__VAMS_COMPACT_MODELING__`, and the `ddx` values §4.5.6 fixes for the arm it guards | `14_predefined_compact_modeling.va` — whether the macro is defined is an implementation fact and is not asserted in either direction; the `else` arm carries no §10.5 claim |
| `s10-5` | the tool-specific predefined macro ("shall be documented in the ... simulator manual") | — unnameable in a portable fixture |
| `s10-6` | `"1364-1995"` selects the 1364-1995 keywords; `sin` is a legal port name | `25_begin_keywords_1364_1995.va` |
| `s10-6` | `"1364-2001"` | `26_begin_keywords_1364_2001.va` |
| `s10-6` | `"1364-2005"` — §10.6's own worked example, verbatim | `16_begin_keywords_verilog.va` |
| `s10-6` | `"VAMS-2023"` — "shall result in an error" for `sin` | `17_begin_keywords_vams.va` (`//! reject E0208`) |
| `s10-6` | `"VAMS-2.3"` selects a Verilog-AMS list, not a Verilog one | `27_begin_keywords_vams_2_3.va` (`//! reject E0208`) — the pair with `17` catches a front end that recognises the string and maps it to a 1364 list |
| `s10-6` | the enumeration is closed | `32_begin_keywords_bad_specifier.va` (`"1800-2017"`, the specifier most likely to be accepted by accident; `//! reject E0135`) |
| `s10-6` | outside a design element only | `29_begin_keywords_inside_module.va` (`//! reject E0202`) — every other keyword fixture uses the legal placement, so nothing else catches a front end that ignores position |
| `s10-6` | "until the MATCHING `end_keywords": the pairs nest and restore | `33_end_keywords_restores_previous_set.va` (`//! reject E0208` on the outer module; a no-op `` `end_keywords `` passes `16`/`25`/`26` and fails only this) |
| `s10-6` | a stray `` `end_keywords `` has nothing to match | `30_end_keywords_unmatched.va` (`//! reject E0136`) — the header writes down that §10.6 states no diagnostic and that the explicit form is 1364 §19.11 |
| `s10-6` | an UNTERMINATED `` `begin_keywords `` is not an error; the set carries on | `31_begin_keywords_unterminated.va` — green, and it runs: E0137 is retired and the file no longer demands a rejection |
| `s10-6` | the set is not over-broad: `logic` is not reserved in VAMS-2023 | `43_logic_is_an_identifier_vams_2023.va` — the only fixture testing the set from the permissive side, aimed at a Verilog-AMS front end grown on a SystemVerilog parser |
| `s10-6` | with no directive, the set is "the implementation's default set" | — not testable: any verdict tests one implementation's choice of default. `33`'s header works through why, and names its outer `"VAMS-2023"` explicitly to avoid depending on it |
| `s10-7` | `` `__FILE__ `` expands to a string literal | `21_file_macro.va` |
| `s10-7` | `` `__LINE__ `` expands to the decimal line number | `22_line_macro.va` |
| `s10-7` | `` `line `` remaps `` `__LINE__ ``; `` `include `` remaps it and reverts +1 | `44_line_macro_remapping.va` |

## The xfail ledger

EMPTY — grep finds no `//! xfail` in this directory: 47 files, 14 with a `//! reject` arm,
33 that run and assert. Each row named a concrete defect in a named file, so each
disappeared the day its defect did. Four rows sat here for `` `default_transition ``,
blocked by one cause in two halves — the preprocessor marked the directive `.ignored`, and
`codegen.zig` implemented `transition()` as a first-order lag rather than §4.5.8's ramp —
and both halves landed together, so all four went at once. The remaining five are below
with what closed them; two of them closed by the FIXTURE being corrected, not the compiler,
which is the part worth reading.

| Fixture | Rule it states | Disposition |
|---|---|---|
| `31_begin_keywords_unterminated.va` | 10.6 an unclosed `` `begin_keywords `` carries across file boundaries | Green, and it now RUNS: E0137 is retired and the fixture no longer demands a rejection. It used to, which inverted the clause — it failed every compiler implementing the sentence and passed only one that did not |
| `34_define_vams_macro_text.va` | 10.4 macro text shall not begin with `__VAMS_` | Green, `//! reject E0139`: macro TEXT is inspected now. `preprocessor.zig` used to protect only the two predefined NAMES |
| `47_escaped_macro_name.va` | Syntax 10-3 `text_macro_identifier ::= identifier`, so escapes are legal | Green, and it RUNS: the `` `define `` name lexer takes an escaped identifier, so E0109 no longer fires here. The restriction belongs to the FORMAL, not the name |
| `35_default_discipline_reset_leaves_no_default.va` | 10.2 the bare directive withdraws the default | Green. The default IS withdrawn and the module IS rejected; the fixture's `//! reject` line was a stated GUESS at the code (E0501) and has been corrected to the code VerA actually prints, E0337 "net has no declared discipline", which is the code wave 1 added for exactly this condition. Whether to retarget the fixture or to widen E0501 is a fixture decision |
| `36_resetall_clears_default_discipline.va` | 10.2 `` `resetall `` withdraws it too | Green, via the other mechanism, and the same corrected code (E0337) |


## Readings this chapter takes, and where they are argued

Three places where §10.6 and §10.4 are ambiguous enough that a conforming tool
could fail a fixture. Each is argued in a fixture header rather than assumed:

- **`analog` inside a 1364-set region.** `16`, `25`, `26`, `29`, `31` and `33`
  all write `analog` and `<+` under a `"1364-*"` specifier. The reading taken is
  §10.6's own next paragraph — the directives "only specify the set of
  identifiers that are reserved as keywords" and "do not affect the semantics,
  tokens, and other aspects of the Verilog-AMS language". `16`'s header carries
  the full argument, including that the narrow reading leaves the rule
  untestable. The other five point at it.
- **`__VAMS_`: name or text?** `15` accepts a prefixed NAME and `34` rejects a
  prefixed BODY. The bet is deliberately placed in both directions, so whichever
  way the ambiguity resolves exactly one of the two files moves and neither half
  goes silently missing. `15` is a hard must-compile, and both halves of the bet are green: `34` pins E0139 on the prefixed body.
- **No "shall be an error" in §10.6.** `30` and `32` demand diagnostics for
  rules §10.6 states as enumerations. Both headers cite IEEE Std 1364 §19.11 as
  the explicit form, which §10.6 extends rather than replaces.

## Not covered, and why

- **Cross-file scope.** §10.1's scope sentence, §10.2's "even across source file
  boundaries" and §10.6's "even across source code file boundaries" all describe
  behaviour spanning a compilation unit of several files. The runner compiles one
  file per invocation, so no fixture can observe it. `30`'s header spells out the
  consequence: a stray `` `end_keywords `` that this suite must reject would be
  legitimate for a tool handed several files at once.
- **The default keyword set** (§10.6, module `m1`) — untestable without testing
  an implementation's choice of default.
- **The tool-specific predefined macro** (§10.5, last paragraph) — its name is
  documented per simulator, so there is nothing portable to write.
- **`` `__FILE__ ``'s text** (§10.7) — "implementation dependent" by the clause
  itself. `21` stops at "it expands, and it is a string literal a `%s` consumes",
  and its header names the one case a compile cannot catch: expansion to `""`.
- **§10.2's own example** uses `always`/`reg` and the `ddiscrete` discipline,
  and remains untested in its digital context. Analog-net tests do not
  establish this required full-AMS behavior.
- **Qualifier coverage is a sample, not the alternation.** Syntax 10-1 lists
  fifteen; `02` uses `real`, `42` uses `wire` and `reg`. `45` pins that the slot
  is closed at all, which is the rule that matters, and is green (`//! reject qualifier`).
