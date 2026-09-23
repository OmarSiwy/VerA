# Source fidelity review log

Lexical typography follow-up (2026-09-23): main visually inspected original
physical24/printed11 and restored the bold literal delimiters in Syntax2-1
(`//`, `/*`, `*/`). The newline notation, repetition braces and alternative
bar remain unbold, as in the source. Removing only the new bold tags preserves
the syntax text. `test_lrm_ch2_syntax.py` guards these exact distinctions;
all33 source-document tests pass. This resolves LEX-REVIEW-003 only, not the
remaining Chapter2 typography or lexical behavior matrix.

Audit started 2026-09-23. Source: `VAMS-LRM-2023.pdf`, SHA256
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`
(computed by `tools/lrm_audit.py`). Page references below are physical PDF pages.

This log records review scope, not a conformance score. A section absent from
both the table and its explicit follow-up records is **unreviewed**. Later
follow-ups supersede earlier scope limits only for the portions they name.
Token comparison is not visual review.

Chapter9 remaining-source integration (2026-09-23): the bounded text/visual
inventory and outstanding runtime groups are in `conformance-ch9-review.md`.
Main read the full HTML patch and report, inspected Figures9-1 through9-4,
regenerated their direct PDF crops and confirmed byte equality with the reviewed
worker assets. All source-document Python guards pass. Remaining fixture
handoffs are explicitly distinguished from integrated evidence in that report.

Inherited IEEE §§17.3–17.6 (2026-09-23): complete worker source-review
boundaries and independent rule derivations are preserved in
`conformance-ieee-control-time-review.md`, `conformance-ieee-pla-review.md`
and `conformance-ieee-queue-review.md`. Main independently read those complete
source sections and §19.8, the reports and proposed fixture/transcript files.
No additional main visual certification is implied. Digital runtime integration
now reproduces the reports' legal-input failures and passing delay-rounding
witness; exact failure-name comparison identifies only the new intended cases.
Source review does not close those behavior obligations.

Bounded implementation follow-up (2026-09-23): AMS §4.3.1 operand-sensitive
system-style math typing and IEEE §17.11.1 arbitrary-width unsigned clog2
now have source-reviewed fixes and root runtime evidence, recorded in
`conformance-system-math-fix.md` and `conformance-ieee-clog2-fix.md`.
The unit gate passes; strict FAIL/XFAIL membership is unchanged and the digital
failure list removes only the wide-clog2 case. Neither closes a whole chapter.

Chapter 1 integration (2026-09-23): the complete parallel source review of
physical pages 14–23 is in `conformance-introduction-review.md`. Main checked
all three figure crops, the visual conventions on page 21, and the source
restrictions supporting the six diagnostic repairs. The source images and
notation colors are integrated, with six independently rerun legal controls
kept outside the measured fixture collection. No positive runtime closure is
inferred from those controls. This supersedes the earlier Chapter 1 token-only
status below, not the still-open rule/evidence inventory.

Chapter 11 integration (2026-09-23): the parallel complete text/visual source
review is preserved in `conformance-ch11-review-draft.md`. Main reviewed the
patch and representative relationship diagrams, regenerated every source crop
and compared all resulting assets byte-for-byte with the reviewed handoff.
The original diagrams now replace erroneous prose paraphrases. Main also
verified that withdrawing Chapter 11 tags from HDL-only fixtures changes no
executable text or other directives. These are source/evidence corrections,
not executed VPI conformance; the host's startup-only scope remains explicit.

Chapter 9 follow-up (2026-09-23): main read complete §9.19 on physical
pages 264–265 and visually checked Syntax 9-14 on page 264, independently of
the parallel review. Literal-function/parenthesis markup and explicitly labeled
punctuation normalizations are integrated. Main also read complete §9.11 on
physical page 250 and inherited IEEE §17.8. Runtime versus constant-path
evidence is recorded in `conformance-ch9-review.md`, with defects left open.

Chapter 4 §4.2.14 (2026-09-23): complete text on physical pages 73–74 read
against HTML; Syntax 4-2 visually checked on physical page 73. Literal-terminal
markup restored without changing grammar text. All six context bullets and
the explicit IEEE 1800 restriction dependency are preserved. Evidence and
unresolved inherited restrictions are tracked as EXPR-019 in
`conformance-expressions.md`; this does not complete Chapter 4.

Chapter 7 integration (2026-09-23): direct crops now reproduce Figures 7-1
through 7-11, with both source captions 7-8/7-9 retained around their shared
drawing. Main inspected every crop. All seven visually reviewed syntax boxes
now distinguish literal terminals; the identified editorial timer-argument and
example-page/parenthesis notes are corrected. See `conformance-mixed-signal.md`
for scope, provenance and the separate still-open behavioral findings. This
supersedes the pending figure/grammar integration statements below.

Chapter 5 typography integration (2026-09-23): the parallel reviewer visually
checked Syntax 5-1 through 5-22, including continuation pages, against physical
pages 110–146. Main independently confirmed that all 22 syntax boxes are
byte-identical after removing only the added bold tags. The HTML now separates
literal terminals from optional/repetition notation and preserves the nested
applicability lists in §5.7. Explicit editorial warnings retain the source's
Syntax 5-7 naming/semicolon anomalies and Syntax 5-20 missing outer brace.
This supersedes the pending Chapter 5 syntax review below, but establishes
neither exhaustive rule enumeration nor runtime coverage.

Parameter follow-up, 2026-09-23: §3.4 and §§3.4.1–3.4.2, physical pages
40–42, were read against the HTML. The parameter syntax on page 41 was
rendered; its opening on page 40 was already rendered in the string review.
Literal delimiters and assignment-pattern tokens are now distinguished from
optional/repeated grammar notation in the HTML. The source's `:: =`
normalization remains labeled. The partial rule map and tightened rejection
diagnostics are recorded in `conformance-parameters.md`.

String follow-up, 2026-09-23: §3.3 was read in full against the HTML, with
rendered physical pages 39–40 used for its declaration syntax, examples and
Table 3-3. The literal-token markup was restored for equals and semicolon.
The table's integral-literal/string-typed context distinctions are present in
the HTML but not all are implemented; STR-LITERAL-001 and the independent
passing comparison evidence are recorded in `conformance-types.md`.

Comparator hardening, 2026-09-23: automatic end-of-line hyphen deletion was
removed after it erased the genuine hyphens in Chapter 10's wrapped names.
Unicode compatibility folding was also replaced by canonical normalization:
superscripts, ligatures and soft hyphens now remain visible for review instead
of being silently collapsed. Earlier “matching tokens” observations below
describe the comparator at that checkpoint, not proof that these distinctions
were absent. New runs may flag additional presentation-only differences; those
must be classified explicitly. Whitespace tokenization still cannot certify
escaped-identifier boundaries, table layout or BNF typography.

The bench workflow now reports the audit tooling's Python self-tests and keeps
their log as an artifact. They use the checked-in AMS source/assets and
synthetic IEEE input, not the licensed IEEE PDF. These tests guard the tooling
and asset references; they neither certify HTML semantics nor change the
project's unit-only gating policy. The workflow edit has been checked locally,
not executed on a remote CI runner by this audit.

| Scope | Review performed | Finding / remaining work |
|---|---|---|
| C, C.1–C.20; pages 402–405 | Read extracted PDF text and complete HTML; examined per-section token diff | Prose and keyword list match. Lists use HTML bullets; C.9 explicitly labels its added space in the source's `7only`. Annex heading is combined in HTML. No substantive text repair identified. Applicability is recorded in `CONFORMANCE.md`; reconciling C.4/C.17 and C.10 with their referenced clauses remains open. |
| 2, 2.1–2.9.2; pages 24–36 | Read PDF text including Syntax 2-1 through 2-10 and both tables; compared HTML token differences | No substantive prose omission identified. Syntax 2-2's `hex_base :=` is explicitly normalized and labeled in HTML. Syntax 2-3's footnote is moved from the page bottom into its owning syntax box. Table 2-1's continuation is combined. Table 2-2's column wrapping and extracted inequality glyphs need visual confirmation. Rule/fixture audit is in `conformance-lexical.md`. |
| Entire chapter/annex heading set | Mechanical PDF/HTML heading comparison | No unmatched heading in the initial run. This establishes neither complete body text nor diagram/table fidelity; run the tool again after edits. |
| Chapters 1 and 3 | Inspected token differences only | Mostly list markers, table reflow and textual descriptions replacing diagrams. Full semantic and visual review is still open. |
| B; physical pages 400–401 | Read complete PDF text and HTML; visually inspected both keyword tables; compared spelling sets mechanically | The sets match after the explicitly labeled `negedgenmos` split. HTML column reflow changes no membership. Keyword behavior and remaining context coverage are tracked in `conformance-keywords.md`. |
| D; physical pages 406–413 | Read complete PDF text and HTML; inspected token diff and rendered pages 412–413 | D.1 tokens match. D.2/D.3 quote normalization is now explicitly labeled in HTML; the previous blanket “verbatim” claim was too strong. Macro availability, guards and metadata evidence are separated in `conformance-standard-definitions.md`. |
| 10, 10.1–10.7; physical pages 281–286 | Read complete PDF text and HTML; compared all token differences; inspected rendered pages 282–284 for Syntax 10-1/2/3 and wrapped spellings | No prose omission identified. ASCII punctuation normalization is now labeled. Genuine hyphens in wrapped `Verilog-AMS`/`VAMS-2.3` are preserved; the comparator had removed them as presumed line-break hyphens. Restored bold literal terminals in the three syntax boxes, including macro parentheses/comma distinct from grammar brackets/braces. The source example's `\logic;` lacks required terminating whitespace and is retained with an editorial warning. Inherited directive behavior remains open beyond the partial macro audit. |
| 8.1–8.5.3.7; physical pages 213–230 | Read PDF text and corresponding HTML in the scheduling passes; visually checked every chapter figure and the convergence equations | Replaced Figures 8-1 through 8-7 redraws with original crops. Source scheduling discrepancies are explicitly retained and recorded; no blanket implementation claim. See the continuation record below and `conformance-scheduling.md`. |
| 9.4.1; physical pages 238–239 | Read complete subsection text against HTML; visually checked Syntax 9-1 and the monitor paragraph on page 239 | No substantive prose omission identified. Literal task names and delimiters now use bold markup to preserve the source's colored terminal/nonterminal distinction. Digital IEEE 17.1.3 behavior must not be replaced by this analog-context subsection. Remaining Chapter 9 sections and syntax boxes are not covered by this review. |

Every other chapter/annex remains pending full review. In particular, formulas,
figure descriptions, VPI object diagrams, grammar typography and inherited IEEE
1364 references must not be certified by matching ordinary text.

Follow-up: §§3.1–3.2.1, physical pages 37–38, were read in full against the
HTML. Page 37 was rendered to check Syntax 3-1 and integer-range superscripts.
The syntax now preserves literal semicolons, commas, equals signs and dimension
brackets/colon as bold terminals, distinct from grammar optional/repetition
notation. The partial evidence map is in `conformance-types.md`; the remainder
of Chapter 3 still has only the earlier token/selected-figure review.

Follow-up: §§9.4.2–9.4.7 were read against the HTML and physical pages 240–241
visually checked, including all entries of Tables 9-21/22 and both parts of
Table 9-23. The omitted connective in §9.4.4 was restored. FMT-G-001 in
`conformance-display.md` records the source's g-precision discrepancy; the
published sentence is retained with an editorial warning. This does not close
the remainder of Chapter 9 or the runtime formatting matrix.

## Visual checks, 2026-09-23

- Table 2-2, physical page 29: inspected a rendered PDF page and the HTML table.
  All five escape rows, their column associations, the inclusive octal digit
  bounds, and the optional error above `\377` match. This closes the specific
  Table 2-2 visual question above, not all Chapter 2 grammar typography.
- Figure 4-4, physical page 85: the HTML description agrees with the delay
  changes and qualitative output shape. It omits the input's nonzero initial
  value and the plotted line styles/arrows; it is a description, not a
  reproduction. The following source paragraph itself says `input(max(t-td,0))`
  “returns 0” although the graph's `input(0)` is nonzero. Preserve source prose,
  but do not derive a zero-initialization requirement from that phrase: the
  operator formula and graph require the initial input value.
- Figure 4-5, physical page 85: the HTML description agrees with the delayed
  trapezoidal response and rise/fall labels. Full diagram reproduction remains
  open. Descriptions added by the transcription must be identified as editorial
  rather than silently presented as normative PDF prose.

The Chapter 4 HTML now explicitly labels its added figure descriptions as
editorial and links the source. This removes an attribution ambiguity; it does
not close the missing-diagram review.

## Restored source figures

Figures 3-1, 3-2 (physical page 62) and 4-3 through 4-14 are now
embedded in their owning HTML sections from direct PDF crops. Each crop was
rendered and inspected against its source page, including borders, captions,
terminal connections, curve styles, arrows and timing guides. Existing prose
descriptions are identified as editorial rather than substitutes for the images.
This closes reproduction of these figures only; other figures remain pending.

Chapter 4 physical page mapping: 4-3 → 81; 4-4/4-5 → 85; 4-6 → 86;
4-7 → 87; 4-8/4-9 → 88; 4-10/4-11 → 89; 4-12 → 90; 4-13 → 91;
4-14 → 104. These are the figure captions found in that chapter of the source;
the supplied PDF's numbering starts at 4-3, so no figures 4-1/4-2 were invented.
The interrupted-transition plots retain their original/revised destinations,
origins, slope constructions and timing guides, which prose alone cannot fully
reproduce. The noise graph retains the different interpolation curves and axis
scales. This visual restoration is not evidence that the simulator implements
any of those behaviors.

`tools/test_lrm_figures.py` checks the source hash, crop bounds, PNG dimensions,
owning HTML reference and accessible description. Those are structural checks,
not substitutes for the visual comparisons recorded above.

The first attempted SVG conversion visibly lost Figure 4-5's patterned vertical
guides when rendered with librsvg. Those generated SVGs were discarded, and
direct lossless PNG rendering from the PDF preserves the guides. The extraction
script pins the PDF hash, records page/crop coordinates and makes regeneration
repeatable; see `figures/README.md` and `tools/extract_lrm_figures.py`.

Figures 8-1 and 8-2 were subsequently restored from physical pages 214 and 216.
The crops preserve the nested elaboration outline, both iteration/acceptance
loops, every branch label and original captions. Both crops were visually
compared with full source pages; repeat extraction produced identical hashes.

The Chapter 8 review subsequently continued through §§8.4–8.5 (physical pages
218–230), reading the extracted source text against the HTML. Figures 8-3
through 8-7 were visually compared with full source pages 220, 221, 222, 224
and 225 and restored as direct crops. The crops retain the original captions,
time axes, patterned guides, assignment operator and numbered control-transfer
arrows. Editorial descriptions are labeled rather than attributed to the PDF.
The scheduling ledger now records provisional-solution acceptance, interrupted
events, digital/analog time distinctions, region ordering and assignment
sampling obligations as open evidence groups. Source discrepancies involving
D2A priority, cancellation and switch uncertainty are documented beside the
HTML passages and in `conformance-scheduling.md`; none is silently repaired or
used to justify a false passing test.

The parameter follow-up reads the complete text and HTML of §§3.4.3–3.4.7
(physical pages 43–45) on 2026-09-23. Requirements and worked examples are
retained. Editorial notes identify the restored space after `types.` and the
ASCII macro introducer substituted for the PDF's curly mark in the alias
example. The metadata, array resizing, local-parameter, string and alias
evidence boundaries are recorded in `conformance-parameters.md`; §3.4.8 is
not included in this completed reading.

The inherited parameter follow-up checks AMS §6.2's introductory prose
(physical page 147) alongside IEEE §4.10.1's body-parameter locality rule.
An explicitly editorial note beside the HTML heading links the inherited
obligation and PARAM-HEADER-001; it is not presented as missing AMS PDF prose.
The rest of Chapter 6 and the full Syntax 6-1 remain outside this source-review
checkpoint. IEEE reading and the visual Syntax 4-4 check are logged separately
in `conformance-ieee1364.md`.

The complete §3.4.8 text and code example (physical pages 45–46) were read
against the HTML on 2026-09-23. Nested assignment patterns, replication,
indexed reads/writes, contributions and final-step output are retained. The
0.1 comparison versus 0.5 label discrepancy is in the source itself and is
now explicitly noted without changing the example. Referenced external model
definitions are not supplied there; this is not a standalone executable test.

The §3.5 genvar text (physical pages 46–47) was read completely against the
HTML. Syntax 3-3 was visually checked on page 46, and its literal punctuation
is now distinguished from repetition syntax in the HTML. The source example
uses indexed analog contributions, not the accumulator previously attributed
to it by `09_genvar.va`. The corrected attribution and static-versus-runtime
evidence limits are recorded in `conformance-genvars.md`.

The §3.6 introduction and §§3.6.1–3.6.1.3 text (physical pages 47–50) were
read completely against the HTML. Syntax 3-4 was visually checked on page 47;
literal punctuation is now explicitly marked separately from optional/repeated
notation. Attribute requirements, inheritance restrictions and examples are
retained. §3.6.2 introductory text was read, but its syntax visual check and
subclauses remain pending. `conformance-natures.md` separates declaration
acceptance, access probes, inherited metadata and solver-level tolerance use.

The discipline follow-up reads the complete §3.6.2 introduction and
§§3.6.2.1–3.6.2.4 (physical pages 50–53), including the motor model and
domainless-discipline deprecation language. Syntax 3-5 was visually checked
on page 50 and its literal punctuation is now explicitly marked in HTML.
The HTML retains the source distinctions; discouraged domainless declarations
are not relabeled illegal. §3.6.2.5 was only partially read and remains pending.

The same follow-up then completes §§3.6.2.5–3.6.2.7 (physical pages 53–54):
discipline attribute overrides, deriving natures from the modified bindings
and user-defined discipline attributes. Text and examples match the HTML.
The nature ledger adds separate binding-locality and inherited-override
obligations. §3.6.3 and its syntax are not included in this completed review.

`tools/lrm_audit.py --section 3.6.2 --diff` independently reports matching
tokens for §§3.6.2.1 and 3.6.2.5; its remaining differences in this group are
PDF line-wrap word splits (for example `disci-pline` and `use-ful`) joined in
HTML. They were inspected rather than suppressed globally by normalization.

The complete §§3.6.3–3.6.3.2 text (physical pages 54–56) was read against
HTML, with Syntax 3-6 visually checked across pages 54–55. Literal range
delimiters and punctuation are explicitly marked. The nodeset-null sentence
and example are retained; an editorial note distinguishes them from the
general pattern grammar. Extracted A.8.1 on physical pages 389–390 was checked
against HTML for that limited question, not visually certified as a full
Annex A review. Source and test-evidence limits are in `conformance-nodesets.md`.

The complete §§3.6.4–3.6.5 text (physical pages 56–57) was read against HTML,
including both structural examples. Syntax 3-7 was visually checked on page
56 and its literal semicolon is now explicitly marked. Ground identity and
implicit structural-net observations are mapped separately in the net ledger;
this reading does not complete §7.4 or Annex F resolution semantics.

The mechanical `--diff` follow-up reports equal text tokens for §3.6.5 and
only the PDF line-wrap split `asso-ciated` for §3.6.4. These checks supplement,
not replace, the visual grammar and complete text review above.

The complete §3.7 real-net text/example (physical page 57) was read against
HTML and Syntax 3-8 visually checked. Literal semicolons now have explicit
markup. The real-net ledger separates profile exclusions, initialization,
driver propagation and port resolution; it withdraws an existing fixture's
unsupported claim that six-digit output establishes full real precision.

Complete §§3.8–3.11.1 text and examples (physical pages 58–61) were read
against HTML. The two-column compatibility declarations on page 60 were
visually checked, including the separate Position and Force bindings. The
mechanical §3.11 diff shows a line-wrap split and PDF list dashes rendered as
HTML list items, not dropped rules. The source's unmatched parenthesis in the
Discrete Domain Rule is retained. Default/primitive/precedence obligations and
separate flow/potential compatibility evidence are in `conformance-natures.md`.

Complete §§3.12–3.13.4 text and examples (physical pages 61–63) were read
against HTML. Syntax 3-9 was visually checked on page 61 and its literal
punctuation now has explicit markup. Earlier restored Figures 3-1/3-2 remain
linked to their source page. The branch/namespace evidence ledger distinguishes
identity, vector mapping, port flow, scope and inherited hierarchical access.

Taken together, the Chapter 3 follow-ups above cover its complete first text
reading against HTML. This supersedes the earlier token-only/remainder-pending
statements for Chapter 3, not Chapter 1. It does not certify an exhaustive
atomic-rule inventory, every visual detail, or implementation conformance.

The complete §§4.1–4.2.3 text and examples (physical pages 64–68) were read
against HTML. Table 4-3 was visually checked across physical pages 66–67.
The HTML merged its continuation but spanned the precedence-direction cell
over only the first twelve rows, leaving the conditional and concatenation
rows outside it. The span now includes all fourteen rows, matching the source's
highest-to-lowest direction. Tables 4-1/4-2 have received text comparison only
in this pass. Remaining expression obligations are in
`conformance-expressions.md`; this is not a complete Chapter 4 review.

Follow-up: Tables 4-1/4-2 were visually checked on rendered physical pages
64–65, including Table 4-1's continuation. Operator spellings and descriptions
match the HTML, and the real-operand subset is retained. This supersedes the
text-only limit for these two tables above.

The complete §4.2.4 text, formula and Tables 4-4–6 (physical pages 68–69)
were read against HTML. Table visual review remains pending; the source uses
a typographic dash in the subtraction row where HTML uses ASCII minus.
The expression ledger records the zero-modulus fixture's combined-diagnostic
weakness separately from positive sign/formula observations.

Subsequent visual review of physical pages 68–69 checks all rows of Tables
4-4–6 and the ceil/floor formula, including the continuation. This closes
their pending visual check above; the typographic subtraction normalization
does not change the operator or its meaning.

Complete §§4.2.5–4.2.8 text/examples (physical pages 69–70) were read against
HTML. Relational/equality tables, precedence prose, the case-equality inherited
reference and logical-negation rule are retained. The expression ledger keeps
IEEE four-state behavior and §7.3.2 reconciliation open rather than extrapolating
the two-state prose to full AMS.

The §4.2.6 cross-reference follow-up reads complete §§7.3.2–7.3.2.1 against
HTML (physical pages 181–182). Page 182 was rendered to verify the converter
example's conflicting case-comparison error annotation. The HTML preserves
the original and adds a labeled editorial warning. EXPR-XZ-001 records the
conflict and the separately read IEEE §5.1.8 semantics. No review of the
remainder of Chapter 7 is implied.

The Chapter 4 editorial source link now opens physical page 64, the actual
chapter opening, rather than page 61 in Chapter 3. The mechanical §4.2 diff
confirms the reviewed §§4.2.1.1–4.2.1.2 and §§4.2.5–4.2.7 match text tokens;
the other reviewed differences are continued-table headings, line-wrap word
splits, the recorded subtraction dash, and the merged precedence-direction
cell. Differences outside the reviewed range remain worklist items.

Complete §§4.2.9–4.2.12 text/examples (physical pages 70–72) were read against
HTML. Tables 4-9–13 were visually checked for every binary truth-table entry
and both XNOR spellings. Syntax 4-1's colored literal question mark and colon
now have bold markup, distinct from grammar repetition braces. The source's
bitwise “comparison” wording and punctuation are preserved. The expression
ledger separates bitwise width/extension, context-specific reduction/shift
restrictions, and conditional behavior; this does not complete Chapter 4.

Complete §4.2.13 text/examples (physical pages 72–73) were read against HTML,
including nested and zero-count replication and exactly-once evaluation.
No substantive omission was identified. The expression ledger records why
the existing numeric zero-count observation does not prove width or side effects.

Parallel Chapter 6 review, first independently checked repair batch: §6.4.3
(physical page 160) restores the source's “output parameters” wording with an
editorial terminology warning instead of silently substituting variables.
§6.5.4 (physical page 163) restores the ordered-list qualification omitted by
the condensed HTML; the source does not impose positional ordering on named
connections. §6.6.2 (physical page 170) restores the rule that a conflicting
generate-block name remains forbidden even when the block is not selected.
These targeted repairs do not certify the remaining Chapter 6 condensation.

The parallel Chapter 6 reviewer completed its first full text reading and
selected visual checks; details, source pages and outstanding repairs are
preserved in `conformance-hierarchy.md`. The main reviewer read that report
and independently checked the three repairs above. This is attributed review
evidence, not a claim that all proposals have been integrated or executed.

The parallel Chapter 5 report is preserved in `conformance-analog-behavior.md`.
It records complete text reading, bounded visual inspection and reproducible
crop coordinates. Main has read the complete report; figure restoration and
fixture-oracle changes still require integration and verification. The reported
topology-changing redraws must not be counted as faithful reproductions.

Chapter 6 second integration batch: HIER-TEXT-004–009 restores the source's
elaboration-order wording, deferred-defparam iteration scope, unnamed-generate
hierarchy exception, different-module OOMR qualifier and paramset-local ranges.
Macro punctuation normalizations and the source's step-3 self-reference are
explicitly editorial. The patch was compared against the unchanged current
HTML base and the cited source passages before applying. Grammar typography
and figure reproduction are still separate unfinished work.

Chapter 5 figure integration: main inspected all six direct crops and reviewed
the HTML patch. Figures 5-1–6 now reproduce the PDF, preserving open potential
probes, source arrows, switches, legends and the interior event dot. Crops were
regenerated with the hash-pinned shared extractor; figure-contained code has
explicitly editorial accessibility transcripts. The Verilog-AMS hyphen in
§5.4.2 is restored. Other Chapter 5 typography and behavioral gaps remain open.

The complete parallel Chapter 7 report is preserved in
`conformance-mixed-signal.md`, with its explicit text/visual review boundaries,
proposed crops and fixture-oracle findings. Main read the complete report and
independently checked the local-accessor source cross-references. No blanket
Chapter 7 runtime or source-fidelity closure follows; figure/grammar work and
the proposed replacement fixtures remain pending integration.

Chapter 6 grammar integration: all nine syntax boxes now distinguish literal
tokens from grammar optional/repetition notation. The parallel review visually
covered physical pages 147–150, 152, 156, 160–161, 166–167 and 173. Main read
the full patch and independently checked byte equality of all syntax bodies
after stripping only the newly added bold tags. No grammar token was changed;
this closes a presentation gap, not a compiler or fixture obligation.

Chapter 12 integration checkpoint (2026-09-23): complete worker text review and
bounded visual inventory are recorded in `conformance-ch12-review-draft.md`.
Main reviewed the patch, preserved literal source entities with editorial
warnings and checked metadata-only changes to numbered HDL fixtures. These
fixtures cannot establish C API execution. Linked VPI probes now expose missing
required capabilities explicitly; the unit gate passes and strict failure-name
membership is unchanged by this integration. API obligations remain open.

Annex E/F and G/H integration checkpoint (2026-09-23): reports are
`conformance-annex-ef-review-draft.md` and `conformance-informative-review.md`.
Main inspected and reproduced all four new Annex E crops, source-checked the
attribute boundary and independently reproduced its positive/invalid-input
results. Informative history/glossary inventories no longer manufacture
normative requirements or phantom source terms. Full semantic, host-mode and
atomic-evidence closure remains open; the reports state visual review ownership
and exact bounds rather than implying that main reread every worker source page.

Chapter6 source-figure follow-up (2026-09-23): Figures6-1 and6-2 are now
directly reproduced rather than only linked. Main inspected both crops and
regenerated them from the pinned PDF, comparing their bytes with the reviewed
handoff. Dedicated source/provenance/HTML tests pass. See
`conformance-ch6-figures.md`; Figure6-3 remains a labeled transcription.

Chapter4 remaining-source checkpoint (2026-09-23): the worker's complete
§§4.3–4.7.3 text/visual review is preserved in
`conformance-ch4-functions-review.md`. Main read the entire report and final
patch and independently checked the source passages supporting the implemented
math repairs and constant-slot sampling rule. Typography/editorial notes are
integrated; parsing actual HTML before collecting syntax text confirms equality
with the pre-markup root. The remaining fixture handoffs and source ambiguities
are named explicitly, not certified by that text-equivalence test.
