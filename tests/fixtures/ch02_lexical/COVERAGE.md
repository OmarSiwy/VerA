# Chapter 2 coverage

**Historical fixture inventory, not exhaustive rule coverage.** The source-based
audit and current gaps are recorded in
[`docs/conformance-lexical.md`](../../../docs/conformance-lexical.md).
That audit supersedes closure claims below: fixture 22 does not observe the
minimum unsized width; 20/29 do not observe attribute metadata; fixture 52 tests
only `op="maybe"`, not the other standard attribute domains. Fixtures 69–72
now isolate those other invalid values. Fixtures 67/68 extend octal-escape and
string-whitespace evidence. The historical counts below predate these additions.
Digital sized four-state observations and the failing unsized-context-fill
case live in `../ieee1364/03_lexical_conventions/lexical_*.v`; an empty local XFAIL list is not closure
of full-AMS lexical obligations.

Source: `docs/ch2-lexical.html`, read section by section including every
syntax box and both tables.

HTML section-ID audit: `s2-1` `s2-2` `s2-3` `s2-4` `s2-5` `s2-6` `s2-6-1` `s2-6-2`
`s2-7` `s2-8` `s2-8-1` `s2-8-2` `s2-8-3` `s2-8-4` `s2-9` `s2-9-1` `s2-9-2`.

Sixty-six `.va` files. Thirty-five carry a `//! reject` arm, thirty-one run; NONE
carries `//! xfail` any more (grep-measured: `grep -lc '//! xfail' *.va` is empty).
Sixteen of the seventeen sections have a fixture that exercises the rule.
One does not — `s2-1` — and the table says so with a dash rather than a
plausible name.

Every row below was checked against the file's `//! lrm` cites *and* its source, not
against its filename. The previous version of this file credited fixtures with
constructs they never mention, credited two files under names they no longer carry,
and listed three that had since been renamed away from `_rejected`. None of that is
repeated here: a fixture appears in a row only if grep finds the construct in it.

| HTML id | Rule | Fixtures |
|---|---|---|
| `s2-1` | overview prose | — states no rule a source can violate, and no fixture cites 2.1 |
| `s2-2` | source is a stream of lexical tokens; a comment is one of the seven token types, so it separates | `39_block_comment_separates_tokens.va` (`//! reject E0207`) — `1/*c*/2` must not weld into `12`; the header records the preprocessor regression it pins. Free format itself is carried implicitly: `27`, `28`, `29`, `31`, `33` each write a whole module on one physical line |
| `s2-3` | white space is space, tab, newline, formfeed; ignored except as separators | `27_form_feed_whitespace.va` — every separator in the module header is a literal U+000C. The other half of the sentence, "spaces and tabs shall be considered significant characters in strings", is `08_string_escapes.va`'s `" "` == 32 |
| `s2-4` | `//` to newline, `/*`…`*/`, no nesting, `//` inert inside a block comment | `01_whitespace_comments.va` (`2.0 /* // */ + 3.0`, and a `` `define `` inside each comment form that must not reach the preprocessor), `12_unclosed_comment.va` (`//! reject E0102`), `13_nested_comment_rejected.va` (`//! reject E0240`, the leftover `still_outer */`) |
| `s2-5` | operators are one-, two- or three-character sequences; unary left, binary infix, conditional two characters over three operands | `65_operator_arity.va` — one check per sentence, each an ARITY claim with a hand-derived value, so nothing here restates a meaning: `- -2.0` = 2.0 (unary, left of the expression `-2.0`), `3.0 - -2.0` = 5.0, `3.0 + +2.0` = 5.0, `!0` = 1, `!!1` = 1, `2.0 ** 3.0` = 8.0 (the double-character row: a lexer that stops at the first `*` has `2.0 * * 3.0`, and `*` is not unary), `1 ? 10.0 : 20.0` = 10.0 and `0 ? 10.0 : 20.0` = 20.0 (two operator characters, three operands). The single-character pairs carry the file: `--`, `++` and `!!` are not in §4.2's Table 4-1, so a lexer that fuses them does not have a token to fuse them into. The TRIPLE-character class is deliberately absent: the language's only two such operators are `===`/`!==`, which `annex_a_syntax/66_case_equality_in_analog.va` runs in an analog block (and `ch04_expressions/29_case_equality.va` refuses on real operands, E0369), and the file's header says so. `ch04_expressions` still owns what each operator MEANS (`4.2.1`–`4.2.14`); `21` and `33` still contain `+`, `*` and `?:` only as attribute carriers |
| `s2-6` | Syntax 2-2, the number grammar | `66_number_positions.va` is the bare-`2.6` cite this row used to say did not exist. It puts one arm of `number ::= decimal_number \| octal_number \| binary_number \| hex_number \| real_number` in `constant_primary` — a module-level `parameter <type> x = <number>;`, the position A.8.4 reaches `number` from — where every child fixture puts its literals in an analog expression instead: 659, `'o7460` = 3888, `4'b1001` = 9, `8'hA5` = 165, `24.7K` = 24700, `1.30e-2` = 0.013, all six hand-derived in the header. That is the union the parent production states and the children do not: one nonterminal serves the constant-expression grammar and the analog one, so an integer-only constant folder, or a lexer that ends a number at a letter (`24.7K` → 24.7 then the name `K`), fails here while passing `04`/`06`/`07`. `51` cites the `size ::= non_zero_unsigned_number` box, `56`/`58` the `scale_factor` and `real_number1` boxes |
| `s2-6-1` | integer constants: bases, size, sign, underscores, truncation/padding, macro substitution | Positives: `04_integer_bases.va` (all four bases, underscores), `22_unsized_based_number.va` (`'h837ff`, `'o7460`, the 32-bit floor), `23_signed_based_number.va` (`4'shf`, `4'hf`, `-4'sd15`, `-8'd6`), `35_uppercase_bases_hex.va` (all eight base spellings, mixed-case hex digits), `40_size_truncation_and_padding.va` (five literals, three of them with the top bit set after truncation). Negatives: `25` (sign between base and digits), `41` (space between `'` and base letter), `49` (base letter outside the eight), `50` (`4af`, no apostrophe), `42` (multi-digit decimal x), `05`/`24` (historical x/z and `?` capability rejections, not full-AMS conformance). The historical xfail ledger is empty; four-state source execution remains open. `36_based_number_digit_whitespace.va`, `37_macro_based_number_tokens.va` and `51_zero_size_rejected.va` were the three `//! xfail` rows and all three are green — the last of them (`37`, macro-substituted tokens) closed when `lexNumber` learned to join the size to the base format across white space |
| `s2-6-2` | real constants: 754 conversion, three notations, Table 2-1, underscores, the six invalid dotted forms | Positives: `06_real_notation.va` (decimal vs scientific vs dot-less exponent, `CHECKX` throughout), `07_si_scale_factors.va` (all eleven Table 2-1 symbols plus `24.7K` and `1.3u`), `34_real_underscores.va`, `01_whitespace_comments.va` (`1_000.0`). Negatives: the six invalid forms one file each — `14` (`.12`), `15` (`9.`), `16` (`4.E3`), `43` (`.2e-7`), `44` (`.1p`), `45` (`34.M`) — plus `46` (space before the scale symbol), `56` (`1g`: the alphabet is closed and case-bearing), `57` (`1._5`), `58` (`1.0e3K`: exponent and scale factor are different arms of one choice) |
| `s2-7` | a string literal is single-line; as an operand it is a base-256 unsigned integer; Table 2-2 escapes | `19_multiline_string_rejected.va` and `38_string_line_continuation_rejected.va` (both `//! reject E0138`; `38` is `bsim4va.va:3658` verbatim, so it pins that VerA does *not* adopt the SystemVerilog `\`-continuation). Everything else in 2.7 — the operand semantics and all five rows of Table 2-2 — is in `08_string_escapes.va` alone, and it is green: seven `CHECKI`s, one per escape plus the multi-character `"AB"` == 16706 that pins the base-256 ORDER |
| `s2-8` | simple identifiers, first character, `$` and `_`, case sensitivity, 1024-character floor | `02_simple_identifiers.va` (`gain_factor` vs `Gain_Factor` differ by 1.0, and the ports are `_port0` and the LRM's own `n$657`), `28_identifier_1024_chars.va` (exactly 1024 characters, written and read back through the full spelling), `59_uppercase_keyword_is_identifier.va` (also `//! lrm 2.8.2`), `17_identifier_digit_rejected.va` (`2gain`), `47_identifier_dollar_first_rejected.va` (`$gain`) |
| `s2-8-1` | escaped identifiers: any printable ASCII 33–126, terminated by white space, neither delimiter part of the name | `03_escaped_identifiers.va` (`\gain+trim`, `\trim` read back as plain `trim`, a tab terminator, `\{a,b}`), `26_escaped_keyword.va` (`\cpu3` and `cpu3` are one object), `48_escaped_system_identifier_rejected.va` (`\$vt` names a plain object, so `//! reject E0314` is the *conforming* answer) |
| `s2-8-2` | keywords are lowercase-only predefined simple identifiers; an escaped keyword is not a keyword | `26_escaped_keyword.va` (`real \analog ;`), `59_uppercase_keyword_is_identifier.va` (`REAL`, `MODULE`, `BEGIN` as three distinct reals summing to 7.0). Annex B's inventory is `annex_b_keywords`, not here |
| `s2-8-3` | `$` introduces a system name; the `$` may not be followed by white space and may not be escaped | `09_system_identifiers.va` (`//! temp 300`; `$temperature` exact, `$vt` against the NIST1998 pair in a 1e-4 band), `18_system_whitespace_rejected.va` (`$ vt`), `60_bare_dollar_rejected.va` (the character class after `$` is mandatory), `48_escaped_system_identifier_rejected.va` |
| `s2-8-4` | the grave accent introduces a compiler directive; a directive takes effect when read and holds for the rest of the compilation | `10_compiler_directive_macro.va` (`` `define `` with an argument; the argument is a sum so a dropped parameter paren shows as 5.0 instead of 6.0). `01_whitespace_comments.va` proves the complement — a directive written inside either comment form is comment text — but cites 2.4 for it, which is where that sentence lives |
| `s2-9` | Syntax 2-4; where an attribute may appear; default value 1; last duplicate wins; no nesting; value is a constant expression | `11_attributes.va` (module, port, discipline and parameter prefixes; the decorated parameter still holds `1m`), `20_duplicate_attributes.va` (repeated name is legal and inert), `29_attribute_default_and_multiple.va` (valueless, `=1`, `=0` in one instance), `31_analog_statement_attributes.va` (statement prefix), `21_operator_attribute.va` (Example 6, suffix on a binary operator), `33_conditional_attribute.va` (Example 8, both arms of `?:`), `30_nested_attribute_rejected.va` (E0357 — the nesting ban, now the rule rather than a desynchronized token skip), `53_attribute_value_not_constant_rejected.va` (E0357 — the same code, the same sentence pair, from the constant-expression side), `54_attribute_illegal_placement_rejected.va` (`parameter real (* q *) x` — the bound on the two parser widenings). Debt: none — `32_function_call_attribute.va` (Example 7) was the `//! xfail` row and is green |
| `s2-9-1` | Syntax 2-5 … 2-10, the exact `{ attribute_instance }` slots | `55_attribute_block_item_and_function_port.va` (Syntax 2-8 / A.2.8: attributed `real` and `parameter` inside a named analog block, attributed `real` inside an analog function body — two places nothing else in this chapter reaches), `30_nested_attribute_rejected.va` (Syntax 2-7's `{ attribute_instance } parameter_declaration ;` slot, which is what makes the nesting the only fault in the file). Syntax 2-9 and 2-10 have no fixture — see below |
| `s2-9-2` | `desc`, `units`, `op`, `multiplicity` and their value domains | `11_attributes.va` supplies all four names with in-domain values on one parameter and proves the declaration is untouched (it cites 2.9, not 2.9.2). The domain rule itself is `52_standard_attribute_domain_rejected.va` (E0358), which covers all four names — a non-string `desc`, and an `op`/`multiplicity` outside the listed sets. The `$mfactor` reporting behaviour the four attributes control is a simulator output, not anything a generated device exposes |

## The xfail ledger

EMPTY, and measured rather than asserted: no `.va` in this folder carries a
`//! xfail` line. The table used to hold four rows and every one of them is closed.

The three based-number rows were one defect wearing three hats — `36`, `37` and
`51` were all `lib/frontend/lexer.zig` treating a based constant as a single
indivisible scan, which is what 2.6.1 denies in the same sentence that describes
it ("composed of up to three tokens … It shall be legal to macro substitute these
three tokens"). `36` (white space before the digits) and `51` (a zero size
constant is not the unsized sentinel) were closed by earlier waves; `37` closed
when `lexNumber` learned to skip white space between the SIZE and the apostrophe,
which is the one join a macro-substituted number cannot avoid — a macro body
cannot be pasted onto its call site, so ``8 `BASE `DIGITS`` reaches the lexer as
`8 'h A5`. The clause forbids white space in exactly one place, between the
apostrophe and the base character, and that is still refused (`41`).

`32` — A.8.2's `{ attribute_instance }` slot between a function name and its
argument list — was closed by an earlier wave too.

The two attribute rows that used to close this table are gone for a different
reason: attribute values are parsed as expressions and collected into the AST, so
§2.9's constant-expression rule is E0357 and §2.9.2's four value domains are
E0358. Every ENFORCEMENT row is gone — `52` and `53` were the two, and both
pinned the phase label `DiagnosticsReported` rather than a code precisely so that
they could be retargeted the day one existed; they now pin E0358 and E0357.

## What is not covered

**2.1.** Descriptive; nothing to violate.

**Table 2-2 and the string-as-integer rule.** Held by `08_string_escapes.va` alone —
every escape and every character value in this directory is that one file, so a
regression in `Lower.strToInt` or in the lexer's escape decode shows up in exactly
one place. `19` and `38` pin the single-line rule and nothing else.

**The identifier length *limit*.** 2.8 has two halves: at least 1024 characters shall
be accepted, and "if an identifier exceeds the implementation-specified length limit,
an error shall be reported". `28` pins the first. The second has no fixture, and
cannot get a portable one — the limit is implementation-specified, so there is no
length a conforming compiler must refuse.

**Syntax 2-9, port connection attributes.** No fixture. There is no module
instantiation attribute fixture in this directory. Hierarchy support elsewhere
does not establish this attribute placement.

**Syntax 2-10, UDP attributes.** No fixture; `grep -l primitive *.va` is empty. UDPs
remain an open full-AMS implementation and attribute-coverage requirement.

**Syntax 2-8's `function_port_list` arm.** Uncovered digital-function syntax required by full AMS.
`55_attribute_block_item_and_function_port.va` argues this in its own header:
`function_port_list ::= { attribute_instance } tf_input_declaration …` belongs to a
digital `function_declaration`, and A.2.6's `analog_function_item_declaration` carries
no attribute slot on its `input_declaration` arm at all. The file covers the
`block_item_declaration` half of Syntax 2-8 and says so; its name promises a function
port it does not test; a digital-function fixture is still needed.

**Most of Syntax 2-7's arms.** `continuous_assign`, `gate_instantiation`,
`udp_instantiation`, `module_instantiation`, `initial_construct`, `always_construct`
and the two generate constructs each carry an attribute slot. These positions
are untested here; Annex C does not remove them from the full-AMS target.
What these fixtures prove is limited to three arms:
`analog_construct` (via `11`), `parameter_declaration` (via `11`, `20`, `30`, `53`,
`54`) and the declaration arms of `module_or_generate_item_declaration` (via `11`).

## Structural notes

**One invalid form per file.** A `//! reject` fixture stops at its first diagnostic,
so 2.6.2's six invalid dotted forms cannot share a module. `14`/`15`/`16`/`43`/`44`/`45`
are that list, one file each, in the LRM's own order. The same constraint is why
`52`'s sibling domain violations now have independent fixtures 69–72; the
comments in `52` themselves never provided coverage.

**Reject is not always debt.** `05`, `24` and `42` refuse x, z and `?`, and `48`
refuses `\$vt`. The legal four-state literals in `05`/`24` are unsupported-feature
regressions, not full-AMS conformance. §2.8.1 makes `\$vt` an ordinary user name
that resolves to nothing; rejecting that unresolved name remains correct. `42` is the one to read carefully — its
own header says that against VerA today it fires on the `x` (E0130, the C.3 rejection)
rather than on the two-digit arity that 2.6.1 actually prohibits, so it proves nothing
`05` does not. The cite carries the claim; the diagnostic does not yet.

**Positive/negative pairs.** Several rules are only closed by both halves, and the
headers cross-reference each other: `07` ↔ `46`/`56`/`58` (scale factors), `35` ↔ `49`/`50`
(base alphabet, and that the apostrophe is required at all), `22` ↔ `51` (omitted size
vs zero size), `23` ↔ `40` (the `s` designator vs plain unsigned truncation), `17` ↔ `47`
(the two halves of one sentence about an identifier's first character), `18` ↔ `60` ↔ `48`
(the `$` may not be separated from its name, the name may not be absent, the pair may
not be escaped), `11` ↔ `52` (in-domain vs out-of-domain standard attributes),
`29`/`21`/`32`/`33` ↔ `54` (how far the attribute slots go, and where they stop).

## Full-AMS literal boundary repair

The frontend now retains exact packed four-state literals, arbitrary declared
widths within the AST's u32 address space, explicit signedness and whether a
size was present. Lexer/parser unit tests cover X/Z/? in all legal bases,
unknown padding, truncation, 65/85/128/65536-bit values, and AST prefix cloning.
Known analog literals retain their source width/sign rather than just an i64.
Fixture `61` exercises required truncation after digit strings exceeding 64
bits, including decimal carry and signed interpretation.

Fixtures `62` and `63` document the current execution boundary: legal wide or
four-state literals parse, then diagnose E0130 before analog lowering. These
rejections are implementation debt, not positive full-AMS conformance evidence.
Fixture `42` now diagnoses illegal multi-digit decimal X/Z syntax with E0133.
The earlier “Debt: none” description applies only to its historical analog
fixture inventory. Four-state operators, context sizing/extension, digital
storage, nets/drivers and procedural execution remain required.
