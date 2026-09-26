# IEEE Annex A grammar cross-review

Review date 2026-09-23. Read every IEEE 1364-2005 production from the Annex A
preamble through A.5.4, printed 487–497 / physical 517–527, stopping at A.6.
Visually checked physical 517, 519–527; A.1.3 continuation/A.1.4 on physical
518 was text-reviewed but not visually certified in this pass. Source hash:
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.

Compared these groups against current AMS `annex-a-syntax.html` and the prior
complete AMS source/visual review in `conformance-annex-a-review.md`. Reread
AMS source preamble/A.1.1–3 and relevant declarations/instantiations from
printed 355–367; specifically visually checked AMS A.1.3 on physical 369 to
resolve the empty-port difference. This is a cross-source production review,
not a second claim of full AMS visual certification. No syntax HTML was changed.

## First-group checkpoint (superseded by completion below)

**Not completed at the first checkpoint:** IEEE A.6 behavioral statements,
A.7 specify/timing, A.8 expressions, A.9 general/attributes/identifiers and
the final unnumbered Details,
printed 497–509 / physical 527–539. Prior chapter audits inspected selected
productions in those groups, but do not substitute for complete Annex A
traversal. Full alternative/optional/repetition boundary enumeration and
behavioral/invalid-input evidence remain incomplete even for A.1–A.5 below.

Edition correction: the earlier handoff called the last group A.10, matching
AMS numbering. IEEE 1364-2005 has **no A.10 heading**: Details 1–5 follow A.9.4.
Use edition-correct citations rather than silently inventing IEEE A.10.

## Inheritance and extension register

| ID / IEEE source | Relationship to AMS | Obligation/evidence boundary |
|---|---|---|
| GRAM-01 A.1.1 | Same library start symbol and three description alternatives; AMS adds explicit file-path indirection. | Library maps are not design source; preserve separate runner/interface obligation from configuration report. Existing mixed-map carrier is not legal positive evidence. |
| GRAM-02 A.1.2 | IEEE module/UDP/config descriptions retained; AMS adds paramset/nature/discipline/connectrules and connectmodule keyword. | Repeated descriptions, attribute prefixes, module header alternatives and matching end keyword need context checks. Added AMS descriptions do not eliminate digital alternatives. |
| GRAM-03 A.1.3 | Parameter header production retained; IEEE explicit empty ANSI-port alternative absent in AMS source. | Empty module `()` is still derivable through non-ANSI `list_of_ports` with a nullable `port`; do not reject it or repair faithful AMS HTML by copying an IEEE-only arm. `#()` is not similarly nullable. |
| GRAM-04 A.1.3 | Port references, named external port aliases, concatenations and ANSI direction declarations retained. | Null port versus absent port list versus empty named expression differ. Named alias shape must not imply named parameter/connection semantics. Hierarchy ledger owns behavioral binding. |
| GRAM-05 A.1.4 | All digital module/generate item alternatives retained; AMS adds analog construct, branch/analog-function declaration and aliasparam. | Distinguish module-only parameters/specparams/specify/generate-region from items admitted directly inside generate. Syntax acceptance cannot certify execution of discarded items. |
| GRAM-06 A.1.5 | Five configuration rule alternatives retained. | Clause 13 semantic restriction can narrow a syntactically derivable cell/liblist form; map/design distinction and configuration binding remain in the config ledger. |
| GRAM-07 A.2.1.1 | Parameter/localparam/specparam preserved; string type and aliasparam added. | Header references parameter declaration, not localparam declaration. Signed/range alternatives versus explicit type, nonempty assignments and semicolon ownership need distinct evidence. |
| GRAM-08 A.2.1.2 | In/out/inout net forms retained with optional discipline/wreal additions; output-reg discipline extension; output integer/time retained. | Do not import SystemVerilog input-variable/output-real alternatives without another applicable AMS rule. Output initializers and declaration context require semantic cross-check. |
| GRAM-09 A.2.1.3 | Eight IEEE net/trireg alternatives retained; discipline placement and discipline-only/wreal/ground forms added. | Strength with declaration assignment versus charge strength without assignment, vectored/scalared requiring range, signed/range/delay ordering and repetitions are separate boundaries. |
| GRAM-10 A.2.2.1 | Net-type and output-variable-type sets retained. AMS expands dimensioned variable/real forms with optional constant assignment patterns. | IEEE scalar expression initializer versus array declaration are not interchangeable; AMS array-pattern extension supersedes any blanket inherited no-array-initialization claim where applicable. Array dimensions still require semantic type/size rules. |
| GRAM-11 A.2.2.2 | Six drive-strength shapes and charge strengths retained. | Opposite 0/1 strength classes, highz alternatives and pull-specific strengths are not a generic free-form tuple. Existing strengths report owns resolution behavior. |
| GRAM-12 A.2.2.3 | delay2/delay3 and restricted unparenthesized delay-value alternatives retained. | Parenthesized min/typ/max, arity and expression context matter; acceptance alone cannot establish transport/inertial behavior or scheduling. |
| GRAM-13 A.2.3 | Declaration lists retained; AMS branch list added and net list delegates to ams_net_identifier. | This delegation does not delete inherited net arrays: AMS A.9.3 includes net_identifier followed by dimensions, plus hierarchical net name. List cardinality and per-item dimensions/initializers must be checked independently. |
| GRAM-14 A.2.4 | Defparam/specparam/pulse-control retained. AMS param assignments add ranges/patterns and value constraints; net assignment delegates to ams_net_identifier. | PATHPULSE punctuation is literal, not an arbitrary identifier matching rule; semantic limits belong in Clause 14 ledger. Empty named override is A.4.1, not an empty declaration assignment. |
| GRAM-15 A.2.5 | Constant dimension/range shapes retained; AMS adds from/exclude interval/string constraints. | Square brackets in dimension/range are literal, not optional delimiters. Direction/constant sizing and legal AMS exclusions need chapter evidence. |
| GRAM-16 A.2.6 | Both digital function forms retained, including mandatory legacy declaration and nonempty ANSI input list; analog functions are separate additions. | Automatic flag, return type/range, declaration placement, function restrictions/copy semantics depend on Clause 10. No silent import of analog output/inout function arguments into digital functions. |
| GRAM-17 A.2.7 | Both task forms and optional ANSI port list retained; tf reg-form ports add discipline. | Empty task ports differ from nonempty function ports; single statement_or_null, allowed directions and typed ports require phase-specific evidence. |
| GRAM-18 A.2.8 | All digital block declarations retained with reg discipline; separate analog block declarations added. | Digital block variables have dimensions but no declaration-initializer alternative here. AMS analog string_declaration remains undefined within the annex, as prior source report records. |
| GRAM-19 A.3.1–4 | All gate/switch families, arities, strengths/delays, terminal categories and optional names retained. | Mandatory module-instance name must not be imposed on gates/UDPs. pass switches have no strength/delay slot, unlike enabled pass switches. Gate output/inout is net_lvalue, not arbitrary expression. Gate/switch behavioral ledger remains necessary. |
| GRAM-20 A.4.1 | Module identifier widened to module_or_paramset_identifier; named system parameter alternative added; other instantiation grammar retained. | Repeated instances share prefix; positional/named parameter lists and connections are separate alternatives. Instance name mandatory, port expressions optional, parameter list nonempty if hash is present, named parameter expression optional. See existing empty-named-parameter repair, not a claim every empty syntax is equivalent. |
| GRAM-21 A.4.2 | Digital generate productions retained; AMS analog loop form added. | Genvar initialization/iteration grammar, unary/binary/conditional expressions, optional else/default colon, nullable selected blocks and optional block names differ. Clause 12 naming/elaboration restrictions still constrain grammar. |
| GRAM-22 A.5.1–2 | Both UDP declaration forms retained; AMS adds optional discipline on output-reg and reg declaration. | Output first and at least one input; legacy declaration list nonempty; attributes at specified sites. Full Clause 8 report owns port/order/initial-state semantics. |
| GRAM-23 A.5.3 | UDP body grammar retained unchanged. | Nonempty tables/input lists, exact single current/next symbols, parenthesized pairs, at most one edge indicator, restricted initialization literals. Existing multi-edge parser repair closes only its bounded restriction, not complete table grammar or UDP execution. |
| GRAM-24 A.5.4 | UDP instance grammar retained. | Optional name/array, drive strength and delay2 must not be confused with module grammar. Legal positive runtime UDP fixtures still fail at unsupported execution; accepted definitions are not behavior. |

## Targeted parameter-header evidence

New `tests/fixtures/ieee1364/A_formal_syntax/audit_grammar_parameter_header.v` with expected
transcript `3 7` derives a legal repeated parameter header and empty port list.
Actual root CLI `--run` exits 1 with E1100: digital execution does not support
these module contents. This is a legal positive failure, not a parser rejection
requirement or evidence that empty module ports are illegal.

Two diagnostic controls outside suite coverage:

- `tools/grammar-audit-controls/empty_parameter_header_invalid.v`: `#()`
  lacks the required first parameter declaration. Actual `--run` exits 0 and
  prints its marker. This exposes acceptance of invalid inherited/AMS syntax.
- `tools/grammar-audit-controls/localparam_header_invalid.v`: localparam is
  not the referenced parameter_declaration alternative. Parser source accepts
  it in its loop, but actual `--run` exits 1 with the same unsupported-module
  E1100 as the legal neighbor, not a rule-specific syntax diagnostic. Do not
  count that exit as correct invalid-input coverage.

No reject directive was invented from the generic E1100; the controls remain
open evidence until a rule-specific rejection contract and runner result exist.
Root must integrate and gate the positive pair separately. No XFAIL was added.

## Existing evidence corrections and parser leads

Root `parseModule` currently loops over both parameter and localparam and accepts
an immediate closing parenthesis. `parseParamValueAssignment` also accepts an
empty hash list. The latter is a separate A.4.1 boundary, not newly executed
here and not automatically equivalent to the legal `.P()` default-preserving
case. No compiler edits were made.

`annex_a_syntax/01_source_text.va` says its empty module ports use an AMS
`list_of_port_declarations ::= ()` arm. That arm exists in IEEE but not AMS;
the legal AMS derivation is the nullable non-ANSI port above. Its executable
expectation remains legal and should not change. Historical COVERAGE's count
of four descriptions while listing two natures, one discipline and two modules
is also incorrect. These are documentary provenance issues, not compiler fixes.

Inherited syntax boxes in previously read IEEE Clauses 7/8/10/12/13/14 supply
semantic links, not an independent full production-coverage certificate.
The AMS grammar preamble explicitly requires chapter semantic restrictions.
Whitespace/token-set equality cannot establish grouping, optionality, valid
contexts, rejection of invalid programs, elaboration, or simulation behavior.

No full suite/build or conformance measurement ran; source traversal and the
open rule register, rather than a percentage, are the deliverable of this group.

## Completion group: A.6–A.9.4 and final Details

Read all remaining IEEE Annex A text through the Annex B boundary, printed
497–509, and visually inspected every physical page 527–539. Also inspected
physical 518, filling the earlier first-group visual gap. Thus every page of
IEEE Annex A, physical 517–539, has now been read in text and visually checked.
This does not promote every production to closed behavioral coverage. Comparison
used current AMS A.6–A.10 HTML and the prior full AMS source review; specifically
rechecked AMS source string production and numbering, not a new full AMS visual
pass. First-group tests and findings above remain unchanged.

| ID / IEEE source | AMS relationship and important boundaries | Evidence / disposition |
|---|---|---|
| GRAM-25 A.6.1–2 | Continuous/procedural assignment families retained; AMS adds analog and analog-initial constructs. Procedural assignment does not acquire continuous-assignment strength/delay syntax. | Assignment/scheduling reports remain required. No inferred analog/digital equivalence. |
| GRAM-26 A.6.3 | Digital sequential/parallel blocks retained; AMS adds analog block variants. Statement repetitions permit empty blocks; declarations are nested under the optional named-block arm. | New nullable-statement fixture observes continuation and unchanged state through empty begin/end. Declaration-context invalid matrix remains open. |
| GRAM-27 A.6.4 | All inherited statement alternatives retained; AMS adds jump statements and separate analog/event/function sets. statement_or_null has an explicit semicolon arm distinct from statement. | Do not infer every parent accepting statement also accepts a null statement solely from grammar; numbered-clause restrictions/permissions must be reconciled. Function statement superscript references IEEE10.4.4, not a production named function_statement1. |
| GRAM-28 A.6.5 | Digital timing, disable, event trigger, event-expression and wait forms retained. AMS adds analog event functions, driver_update and analog references; analog event-control family is separate. | @*, @(*), named event and parenthesized expressions have different syntax; repeat event control is not standalone repeat-loop equivalence. Existing wait/scheduler ledgers, not parser acceptance, establish bounded behavior. |
| GRAM-29 A.6.6–7 | if chains and case/casez/casex retained. Each case requires an item; default colon optional; item body can be null. | New legal nullable-statement transcript and isolated empty-case rejection form a bounded pair. Wildcard precedence/first matching branch still depend on semantic ledgers. |
| GRAM-30 A.6.8 | All digital loops retained; AMS adds analog/function-loop counterparts. Digital for explicitly contains initialization, expression and iteration; no arbitrary SystemVerilog shorthand is inherited from these productions. | No new rejection inferred for chapter-permitted exceptions. Runtime loop bounds, four-state tests and break/continue are separate. |
| GRAM-31 A.6.9 | Digital system/user task forms retained; AMS analog system-task form added. Generic system-task syntax permits null arguments; user task parentheses contain a nonempty expression list when present. | Per-task semantic arity can narrow generic system-task grammar. Do not make $time/$display/user task interchangeable based on token prefix. |
| GRAM-32 A.7.1–3 | Specify item families, parallel/full paths and terminal categories retained. | Specify block may be empty; input/output lists in paths are nonempty. Inout ports qualify as either terminal category. Ordering/source restrictions in Clause14 still apply. |
| GRAM-33 A.7.4 | All five path-delay arities, optional outer parentheses, edge-sensitive/state-dependent forms retained. ifnone reaches simple paths only. | Allowed delay-list lengths are1,2,3,6,12, not an arbitrary comma list; edge path has nested parentheses/data source. Existing path ledger owns observed timing failures and source ambiguities. |
| GRAM-34 A.7.5.1 | Twelve timing-check families and nested optional/null arguments retained. | Width threshold cannot be skipped like setuphold's optional intermediate operands. Controlled-reference event mandatory for period/width. Existing timing-check negatives and legal neighbors reused, no duplicate claim. |
| GRAM-35 A.7.5.2–3 | Argument aliases, mandatory/optional control distinction, edge lists, &&& and scalar constants retained. | Edge-list square brackets are literal; nonempty descriptors, no embedded spaces within a descriptor (Details2). Notifier is variable identifier; limit expression still has numeric/context restrictions from Clause15. |
| GRAM-36 A.8.1 | All inherited concatenation families retained; AMS adds analog concatenations and assignment patterns. | Literal braces do not make an empty concatenation; repeated concatenation requires count and nested concatenation. Expression sizing/zero-repeat semantic exceptions require Clause5; no unsupported grammar-only oracle. |
| GRAM-37 A.8.2 | Constant/function/system-function calls retained; AMS analog/operator/probe/filter families are additions. | Nonempty user-function arguments, constant versus runtime arguments, optional whole system-call parentheses versus null slots differ. Analog system-function nullable form does not automatically replace digital one. |
| GRAM-38 A.8.3 | Digital/constant/module-path expression families retained with AMS analog and analysis/indirect forms. | Both indexed range directions preserve constant width while base may be variable; min/typ/max has three expressions. Grammar recursion does not encode all precedence/signedness/sizing restrictions. |
| GRAM-39 A.8.4–5 | Digital primaries/lvalues retained; AMS adds analog/probe/nature/constant analog calls and system parameters. | Net-lvalue indexes are constant where variable-lvalue indexes need not be. Bracket nesting in the printed productions distinguishes optional selection from literal brackets. Whole arrays and analog lvalues need AMS chapter restrictions, not extrapolation from digital scalar grammar. |
| GRAM-40 A.8.6 | Inherited operator sets retained. | Module-path operators are restricted relative to general expressions; unary minus is not a number-token sign, and alternate XNOR spellings are distinct legal tokens. Operator semantics remain Clause5 obligations. |
| GRAM-41 A.8.7 | All IEEE numeric alternatives retained; AMS adds scale factors. | Signed-base optional s/S, unknown-only decimal digits, nonzero sizes and no embedded whitespace in marked components follow lexical rules. Superscript2 is a footnote, not a nonterminal suffix. Existing lexical and wide-value fixtures are selected evidence only. |
| GRAM-42 A.8.8 | IEEE string excludes newline; AMS grammar uses Any_ASCII_Characters but AMS2.7 still specifies a single line. No normative precedence resolving that conflict has been established. | Neither unconditional raw-newline acceptance nor rejection is certified. Remaining uses of string after AMS rename require lexical/type interpretation; see conformance-strings-ledger-independent-review.md. |
| GRAM-43 A.9.1–2 | Attributes and comment forms retained. | Attribute list nonempty, optional value constant; comment termination/embedding governed by lexical chapter. Any_ASCII placeholder does not permit premature closing delimiters to be ignored. No attribute effect inferred from token acceptance. |
| GRAM-44 A.9.3 | Identifier aliases and escaped/simple/system categories retained. AMS extends hierarchical form with optional $root and adds analog/type/system-parameter names. | New escaped-$time witness proves ordinary variable name and genuine system function remain separate. Existing undeclared escaped-$vt rejection does not forbid declared escaped names. Character-class brackets are not optional empty identifiers. |
| GRAM-45 A.9.4 / Details1–5 | Whitespace and restrictions retained; AMS numbers Details as A.10, changes function restriction reference and includes system parameters in dollar-spacing rule. | EOF terminator is explicit; embedded-space restrictions apply to marked productions, not all source. Class/range rendering, function semantic restrictions and system identifier no-escape distinction must survive extraction. |

### Source anomalies and supersession

AMS A.8.8 differs from the inherited newline-excluding grammar. Informative
AnnexG2535 records a multiline-string correction, and7891 a later nonterminal
rename, but neither establishes precedence over AMS2.7's single-line prose.
The earlier categorical supersession claim is withdrawn: preserve and flag the
normative conflict, not a guessed acceptance/rejection rule. Do not normalize
either source passage away or call the faithful transcription an omission.
AMS-specific undefined analog lvalue nonterminals/double-semicolon issue remains
the prior AMS review's source anomaly, not an inherited IEEE grammar defect.

The IEEE numeric-base printing makes the signed-base meta-notation difficult
to infer from bold text alone. Its §3 numeric rules and the corresponding AMS
editorial note determine that s/S is optional and the brackets/bar are not
literal bytes. Superscripts attached to function statements, edge descriptors,
numbers, identifiers and EOF link to Details; none adds a new language token.

### New executable observations

Actual root CLI `--run` results from the worker worktree:

- `audit_grammar_escaped_system_name.v` / expected pair: exit0, exact
  `ordinary=9 system=0`. The escaped variable is assigned9, while actual $time
  at time0 stays0. An explicit timescale isolates this test from the current
  runtime's timescale-required preflight (initial no-timescale probe hit that
  restriction, not a name-binding failure).
- `audit_grammar_nullable_statement.v` / expected pair: exit0, exact `3`.
  Empty begin/end, null if arms, and default case items with/without colon
  preserve value3. This witnesses legal syntax and continuation, not all null
  contexts or branch semantics.
- `audit_grammar_empty_case_rejected.v`: explicit digital rejection, exit1,
  E1100 header `a case statement requires at least one item`. This is a
  rule-specific digital preflight rejection, not an analog parser diagnostic.
  Matching legal default/null items are in the positive witness. The isolated
  original probe remains at `tools/grammar-audit-controls/empty_case_invalid.v`.

There are now no unread **text** groups remaining in IEEE Annex A for this
review. Remaining work is obligation-level closure: independent alternatives,
boundaries/context matrices, source ambiguity resolution, cross-clause semantic
constraints, host runners and actual positive/invalid execution. Full suites
and measures were not run, no compiler/HTML/shared harness was changed, and no
full-language conformance claim follows from this completed source traversal.

## Root handoff boundary

The main agent read this complete report on 2026-09-23 and retained it in the
root documentation. Source traversal and visual checks above are worker
evidence; they are not represented as a new independent main-agent full-source
review. New grammar fixtures and separate diagnostic controls are integrated.
The controls remain outside suite intake and carry no coverage tags. The existing
source-text header now correctly cites the nullable non-ANSI port derivation;
its legal executable expectation is unchanged. COVERAGE's description count
is corrected from four to five by inspecting the declarations. This report establishes
the source-review boundary, not a certified atomic grammar denominator.

Root unit gate now passes. The digital gate adds the legal parameter-header
failure, while nullable statements, escaped system-like names and the isolated
empty-case rejection pass. Exact name comparison preserves every pre-existing
failure. Logs are `/tmp/vera-primitives-grammar-{unit,devices}.log`; strict is
still running, so no fresh A/C measurement is claimed.
