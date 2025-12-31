# Chapter 10 coverage

Source: `docs/VAMS-LRM/ch10-directives.html`, read section by section.

HTML section-ID audit: `s10-1` `s10-2` `s10-3` `s10-4` `s10-5` `s10-6` `s10-7`.
Seven ids, seven with at least one fixture. 47 files, numbered 01–48 with 20
missing — `20_resetall_clears_macro.va` was deleted, not renamed, because it
asserted that `resetall` undefines a text macro and nothing in the LRM says so
(`resetall` appears exactly twice: the 10.1 table row and 10.2's reset
sentence). A conforming tool failed it. `36`'s header records the reasoning.

Every section has a fixture, so the interesting number here is not the section
count. It is 13: the fixtures that state a rule this compiler does not meet.
Chapter 10 is where VerA's preprocessor is thinnest — it lexes
`` `default_discipline `` and `` `default_transition `` and marks them
`.ignored`, and it rejects `` `__FILE__ ``/`` `__LINE__ `` outright — so the
xfail ledger below, not the table, is the real content of this folder.

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
| `s10-2` | the positive effect: a default reaches an UNDECLARED net | `41_default_discipline_undeclared_net.va` — passes today **without discriminating**, and its header says so: delete the directive and the file still compiles |
| `s10-2` | two qualifiers in force at once; more specific wins | `42_default_discipline_two_qualifiers.va` (`wire` claims the ports, `reg` must not) — same honest limit as `41` |
| `s10-2` | the qualifier slot is a closed 15-way alternation | `45_default_discipline_qualifier_grammar.va` — **`//! xfail`** |
| `s10-2` | the bare form withdraws the default for later nets | `35_default_discipline_reset_leaves_no_default.va` — **`//! xfail`** |
| `s10-2` | `` `resetall `` withdraws it too ("In addition to `resetall") | `36_resetall_clears_default_discipline.va` — **`//! xfail`** |
| `s10-3` | the directive is accepted; §4.5.8 DC pass-through survives it | `03_default_transition.va` — the 1n itself is deliberately not pinned, and the header says why |
| `s10-3` | the default IS the rise/fall time of an argument-free filter | `38_default_transition_ramp.va` — **`//! xfail`** |
| `s10-3` | a later directive supersedes an earlier one | `39_default_transition_supersedes.va` — **`//! xfail`** |
| `s10-3` | explicit filter arguments beat the directive | `40_transition_arguments_override_default.va` — **`//! xfail`** |
| `s10-3` | Syntax 10-2's operand is mandatory (no brackets) | `48_default_transition_requires_an_operand.va` — **`//! xfail`** |
| `s10-4` | object-like `` `define `` | `04_define_object.va` |
| `s10-4` | `list_of_formal_arguments`, actual-argument text substitution | `05_define_function.va` (compound actual, bracketing pinned by 2.25 vs 2.0) |
| `s10-4` | backslash-newline continuation of the macro text | `06_define_multiline.va` |
| `s10-4` | a macro text may itself use a macro | `07_nested_macros.va` |
| `s10-4` | `` `undef `` removes a user macro | `08_undef_conditional.va` |
| `s10-4` | use of an undefined macro is illegal (1364 §19.3.1) | `23_undefined_macro.va` (`//! reject E0115`) |
| `s10-4` | Syntax 10-3: the NAME is `identifier`, so unrestricted by prefix | `15_define_vams_prefixed_name.va` — a hard must-compile on a **contested reading**, bet deliberately against `34`; no xfail to hide behind |
| `s10-4` | Syntax 10-3: the FORMAL is `simple_identifier`, escapes barred | `46_macro_formal_must_be_simple_identifier.va` (`//! reject E0110`) |
| `s10-4` | Syntax 10-3: the NAME may be escaped (`identifier` is wider) | `47_escaped_macro_name.va` — **`//! xfail`** |
| `s10-4` | the macro TEXT shall not begin with `__VAMS_` | `34_define_vams_macro_text.va` — **`//! xfail`** |
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
| `s10-6` | an UNTERMINATED `` `begin_keywords `` is not an error; the set carries on | `31_begin_keywords_unterminated.va` — **`//! xfail`** |
| `s10-6` | the set is not over-broad: `logic` is not reserved in VAMS-2023 | `43_logic_is_an_identifier_vams_2023.va` — the only fixture testing the set from the permissive side, aimed at a Verilog-AMS front end grown on a SystemVerilog parser |
| `s10-6` | with no directive, the set is "the implementation's default set" | — not testable: any verdict tests one implementation's choice of default. `33`'s header works through why, and names its outer `"VAMS-2023"` explicitly to avoid depending on it |
| `s10-7` | `` `__FILE__ `` expands to a string literal | `21_file_macro.va` — **`//! xfail`** |
| `s10-7` | `` `__LINE__ `` expands to the decimal line number | `22_line_macro.va` — **`//! xfail`** |
| `s10-7` | `` `line `` remaps `` `__LINE__ ``; `` `include `` remaps it and reverts +1 | `44_line_macro_remapping.va` — **`//! xfail`** |

## The xfail ledger

Thirteen of the 47 fixtures run and fail. Each names a concrete defect in a
named file, so the row disappears the day the defect does. Five of the
thirteen are `` `default_discipline ``/`` `default_transition `` fixtures
blocked by the same one-line cause — the preprocessor marks both directives
`.ignored` — which is why this chapter's debt looks larger than it is.

| Fixture | Rule it states | Why it fails today |
|---|---|---|
| `21_file_macro.va` | 10.7 `` `__FILE__ `` expands to a string literal | VerA rejects it with E0114 "unsupported compiler directive"; §10.7 is unimplemented in the preprocessor |
| `22_line_macro.va` | 10.7 `` `__LINE__ `` expands to a decimal | Same E0114 |
| `44_line_macro_remapping.va` | 10.7 `` `line `` and `` `include `` remap `` `__LINE__ `` | Same E0114, plus `` `line `` handling is a no-op that remaps nothing |
| `31_begin_keywords_unterminated.va` | 10.6 an unclosed `` `begin_keywords `` carries across file boundaries | VerA raises E0137 at end of parse. The fixture used to DEMAND that rejection, which inverted the clause: it failed every compiler implementing the sentence and passed only one that did not |
| `34_define_vams_macro_text.va` | 10.4 macro text shall not begin with `__VAMS_` | `preprocessor.zig` protects only the two predefined NAMES; it never inspects macro text, so a `__VAMS_` body is defined silently |
| `47_escaped_macro_name.va` | Syntax 10-3 `text_macro_identifier ::= identifier`, so escapes are legal | VerA's `` `define `` name lexer accepts only a simple identifier and raises E0109; the restriction belongs to the FORMAL, not the name |
| `35_default_discipline_reset_leaves_no_default.va` | 10.2 the bare directive withdraws the default | `` `default_discipline `` is `.ignored` and discipline resolution never runs, so there is no default to withhold — `V()` resolves on a bare port either way |
| `36_resetall_clears_default_discipline.va` | 10.2 `` `resetall `` withdraws it too | Same, via the other mechanism: nothing to clear |
| `45_default_discipline_qualifier_grammar.va` | Syntax 10-1's 15-way qualifier alternation | The directive is consumed to end of line without parsing operands, so any text after it is accepted |
| `48_default_transition_requires_an_operand.va` | Syntax 10-2's operand is mandatory | Same shape: consumed to end of line, so the operand-less form is silently accepted |
| `38_default_transition_ramp.va` | 10.3 the directive sets the filter's rise/fall time | Two gaps stacked. `` `default_transition `` is `.ignored` so the 4n is discarded; and `codegen.zig` implements `transition()` as a first-order lag (`zTransition`/`transitionTau`), not §4.5.8's linear ramp. Fixing the directive alone leaves the slope bound failing on the §4.5.8 residue |
| `39_default_transition_supersedes.va` | 10.3 a later directive supersedes an earlier one | Both values discarded, so there is nothing to supersede; same §4.5.8 residue underneath |
| `40_transition_arguments_override_default.va` | 10.3 explicit filter arguments beat the directive | The 8n is discarded, so the argument-free filter falls back to a simulator default; same §4.5.8 residue |

## Fixtures that pass without discriminating

Two files are green and prove nothing today. Both say so in their own headers,
and neither is credited above as a live check:

- `41_default_discipline_undeclared_net.va` — the positive half of §10.2.
  VerA resolves an access function against a bare port regardless of any
  discipline, so deleting the directive from the file changes no verdict.
- `42_default_discipline_two_qualifiers.va` — the qualifier-precedence half.
  Passes whichever qualifier rule a tool implements, including none.

They are the spec record of rules whose discriminating (negative) halves are
`35`, `36` and `45` in the ledger above. When discipline resolution lands, both
start doing work with no edit.

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
  goes silently missing. `15` is a hard must-compile with no xfail.
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
  which Annex C.7 puts outside Verilog-A. The rule is tested on analog nets
  instead.
- **Qualifier coverage is a sample, not the alternation.** Syntax 10-1 lists
  fifteen; `02` uses `real`, `42` uses `wire` and `reg`. `45` pins that the slot
  is closed at all, which is the rule that matters, and is xfail.
