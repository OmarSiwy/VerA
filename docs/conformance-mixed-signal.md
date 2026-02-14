# Chapter 7 parallel source and oracle review

## Main integration checkpoint, 2026-09-23

The historical parallel report below is retained as provenance. Main has now
integrated all seven syntax boxes' literal-terminal markup and direct source
crops for Figures 7-1 through 7-11. Main inspected every crop; the empty 7-8
caption and 7-9 drawing intentionally share one image. The extractor reproduces
the inspected assets, with source-page coordinates and structural regression
tests. The editorial timer argument number, Example 3/4 page/parenthesis note,
and §7.8.5.1 wording corrections are also integrated. These changes supersede
the report's pending HTML repair statements, not its runtime gaps.

The corrected MIX-LOCAL-001 fixtures were run in the full strict suite:
`/tmp/vera-local-discipline-strict.log` ended with exit 1. Comparing normalized
FAIL/XFAIL names against `/tmp/vera-replication-retry-strict.names` added only:

- `XFAIL ch07_mixed_signal/audit_child_wrong_flow_rejected.va`
- `XFAIL ch07_mixed_signal/audit_child_wrong_potential_rejected.va`
- `XFAIL ch07_mixed_signal/lrm_7_4_4_3.va`

The existing FAIL membership did not change. These are newly exposed conformance
defects, including withdrawal of the old invalid positive oracle, not newly
implemented behavior. No compiler fix or local-discipline closure is claimed.
`tools/conformance.sh` regenerated `conformance-measurement.md` using that strict
log and `/tmp/vera-local-discipline-coverage.log`; its fresh unit gate passed
and digital device gate failed. Any static citation gain is not runtime closure.

Reviewed 2026-09-23 against the current main worktree, not this detached
worktree's historical HTML. Source: `VAMS-LRM-2023.pdf`, SHA256
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.

Complete Chapter 7 text, examples and grammar were read from physical pages
177–212 (printed 164–199) and compared with current
`docs/ch7-mixed-signal.html`. The complete mechanical `--section 7 --diff`
worklist was inspected. Tables 7-1 and 7-2 and Syntax 7-1 through 7-7 were
visually checked on physical pages 180, 183–184 and 191–194. Physical pages
203–205 were rendered for the example and generated-name discrepancies below.
All figure-containing pages were rendered and their proposed crops inspected.

This is a first complete Chapter 7 source reading and an initial rule grouping,
not an atomic denominator or proof of implementation conformance. No Zig suite
was run by this agent; no current runtime result is inferred from old headers or
COVERAGE.md. No main-worktree source, fixture, measurement or compiler was edited.
Historical status claims in ROADMAP/PLAN/COVERAGE do not supersede the main
agent's current generated report.

## Source fidelity findings

1. **Figures remain link-only.** Figures 7-1 through 7-11 are represented by
   PDF-page links, so hierarchy edges, driver directions, grouping and node
   relationships are not present in the HTML itself. Direct PDF crops are
   supplied below. Figure 7-8 is an empty caption immediately above the same
   drawing that ends with Figure 7-9's caption; preserve both rather than
   inventing another drawing.
2. **Grammar loses literal/metasyntax distinction.** All seven syntax boxes
   render terminals and nonterminals without the PDF's terminal distinction.
   Most importantly Syntax 7-1 has literal square brackets around `expression`
   and `range_expression` nested inside metasyntactic optional/repetition
   brackets. Restore bold literal brackets and parentheses. In Syntax 7-2/3
   distinguish literal `@`, parentheses, quotation marks, commas, semicolon,
   `posedge`, `negedge`, `initial_step`, `final_step`, `or`, event function
   names and `driver_update`. In Syntax 7-4–7 distinguish keywords and literal
   semicolons/commas from optional/repetition grammar delimiters. Token equality
   alone did not detect this loss.
3. **§7.8.3.2 editorial page attribution is wrong.** Examples 3/4 are printed
   page 190 / physical 203, not printed 189. Both examples actually contain
   `.r(30k)` / `.r(15k)` but omit the outer parameter-assignment closing `)`;
   the note saying closing parentheses after `.r(30k` are missing is imprecise.
   Example 4 also changes `cmos04u` to `cmos4u` in its explanatory text, in the
   source itself. Preserve this discrepancy; do not silently change source code.
4. **§7.8.5.1 small prose substitution.** N-output gates say “and so forth” in
   the PDF but “and so on” in HTML. Meaning is unchanged; restore exact prose.
5. **§7.3.4 existing typo note misnumbers the argument.** The PDF's
   `analogt_expression_or_null` is the third `timer` argument (second optional
   argument), not the second argument. Current HTML explicitly normalizes it
   and records the source spelling; keep that distinction but fix the numbering.
   Its claim every tolerance is literally `analog_expression_or_null` also
   needs to acknowledge that printed typo.

No other substantive prose omission was found in the full text comparison.
Remaining mechanical differences were PDF line-wrap hyphenation, list markers,
table reading order, figure contents and labeled editorial notes. This statement
does not certify every presentation attribute or inherited reference.

### Source issues to preserve, not repair as transcription errors

- EXPR-XZ-001 is already documented: §7.3.2 permits case comparison but its
  converter example labels `dnet === 1'bx` an error. Do not make that annotation
  a rejection oracle.
- Syntax 7-7 requires comma-separated discipline identifiers, whereas examples
  in §7.7.2 and Figures 7-2–6 omit commas. Figure 7-6's directed connect example
  also omits the comma required by Syntax 7-6. These source examples are not
  evidence that whitespace-separated grammar is legal.
- §7.8.5's `InstName`/`PortName` prose says “local instance name of the port
  and its instance respectively,” which appears reversed relative to the
  metavariable names. `m03_SPEC.md` already records this; preserve the PDF.
- §7.8.5.1 lists `rtranif` without a suffix, and names a gate terminal even
  for two-terminal `tran`/`rtran`. Both are present on rendered page 205.
  The inherited primitive declarations must be reconciled before creating a
  naming oracle for those alternatives. Do not silently invent a third port.
- §7.3.6 refers to synchronization §8.2, and §7.3.6.1 references §8.3.3 for
  digital event timing, while those Chapter 8 headings concern analog
  initialization/nonlinear solution in this edition. Keep the references and
  use the separately reviewed §8.4.3.3 timing text for interpretation.

## High-risk fixture claims

Integration checkpoint: MIX-LOCAL-001's corrected positive and its two
isolated negative fixtures are now in the main tree. Main independently read
the accessor declaration rule and associated-node/local-discipline clauses,
then directly reproduced the inverse acceptance pattern below. The proposed
replacement text is retained as provenance; these particular fixtures are no
longer only proposals. The other findings remain open.

### MIX-LOCAL-001: declared child discipline is incorrectly overwritten

`ch07_mixed_signal/lrm_7_4_4_3.va` declares child `port` as `electrical` but
uses custom `Va(port)` and `Ia(port)`, asserting the parent declaration changes
the child's available accessors. Its header explicitly demands refusal of a
compiler that keeps the child's declared V/I accessors. This reverses the rule:

- §7.4 defines discipline resolution for nets whose discipline is undeclared.
- §7.2.3 distinguishes each locally declared net discipline from the whole
  signal/node and uses the local discipline for driver/receiver association.
- §6.5.8, physical 165 / printed 152, explicitly allows one analog node to be
  associated with multiple nets and multiple continuous disciplines.
- §4.4, physical 76–77 / printed 63–64, takes access names from the associated
  net/port/branch discipline and requires the name to match its declaration.

Those cross-reference passages were read directly from the PDF in this review.
Preserving a parent's declared discipline does not redeclare an already declared
child port. The present fixture therefore cannot be treated as valid positive
evidence. The main agent independently confirmed that its current strict baseline
passes this fixture; that result suggests a local-discipline/flattening defect,
not source authority for the expectation. This agent did not execute it.

Proposed replacement evidence, before changing compiler behavior:

1. Keep the parent `ch7443_alt shared` and child `electrical port`, but change
   the child's behavioral accesses to `V(port)` / `I(port)`. The parent uses
   `Va(shared)` / `Ia(shared)`. Retain the independently derived KFL equation
   `0 + (V - 0.5) = 0`; both local probes must observe 0.5 through their own
   declared accessors. Keep the unrelated undeclared-net contrast separately.
2. Add distinct attributes to the two compatible potential natures and observe
   the parent and child's **own** attributes (e.g. a non-tolerance user marker)
   in each scope. This distinguishes local declarations from shared unknown
   identity without confusing a node's minimum tolerance with local metadata.
3. Add an isolated invalid-access fixture: compatible custom parent and
   electrical child; only the child attempts `Va(port)`. Pin the eventual
   accessor/discipline diagnostic after observing it, not a guessed code. Pair
   with the legal child V/I case. Conversely, parent `V(shared)` must not be
   justified by its child's electrical declaration.
4. If the corrected legal fixture fails now, record the exposed implementation
   defect with the source derivation. Do not keep the wrong child accessor to
   preserve a green fixture; do not silently delete an XFAIL marker.

The old header also wrongly says the `resolveto` exception is exclusively an
inserted-connect-module statement. Discipline resolution precedes insertion;
that exception requires resolution evidence and cannot be discarded merely
because no bridge is inserted.

MIX-LOCAL-001 execution record: corrected `lrm_7_4_4_3.va` exits 1 with
E0501 at legal child V/I accesses. Each new
`audit_child_wrong_{potential,flow}_rejected.va` exits 0 despite its single
invalid Va/Ia read on the explicitly electrical child. All three now carry
explicit MIX-LOCAL-001 XFAIL reasons. No pre-existing marker was removed.
The positive retains its voltage derivation and requires four observations;
it has not reached runtime, so no behavioral success is claimed. The old
child-accessor acceptance assertion is withdrawn and assigned to these
negative cases, not silently preserved to keep the suite green.

Inspection of `lib/ir/lower.zig`'s `checkAccessMatch` shows the check reads
`node_disciplines.items[node]`, consistent with the observed loss of local
declaration identity. A fix needs to preserve local provenance while sharing
the physical node; exempting all mismatches would not satisfy §4.4.

### MIX-TOL-001: the minimum-abstol fixture never constructs one shared node

`lrm_7_2_4.va` declares `p` and `q` in the same flat module and joins them by
`I(p,q) <+ V(p,q) * 0.0001`. A resistor connects two nodes; it does not make
them hierarchical segments of one signal. Its only CHECK reads the harness's
prescribed `V(p)=1.5`. Neither a minimum attribute nor solver use is observed.
Its comment “both nets on the same signal” is false. Keep acceptance evidence
distinct from the untested §7.2.4/§6.5.8 node-tolerance requirement.

Replace that claim with an actual parent/child shared node carrying distinct
compatible disciplines. A host-visible effective-tolerance check is needed;
reading a local `net.potential.abstol` only observes local metadata. A behavioral
convergence discriminator also needs to control solver residuals and tolerance
policy, not merely compare a pinned voltage.

### MIX-MODE-001: vendor-specific selection does not make detail mode untestable

`COVERAGE.md` says no §7.4.4.2 fixture is possible and infers implementing only
basic is conforming from vendor-specific selection. §7.4.4 explicitly defines
two modes, basic default, with vendor-specific **selection**. That is not an
explicit permission to omit one mode or a reason to forbid a fixture whose
runner selects and records the mode. A mode-conditioned host test can assert
the Figure 7-4 result. Separate implementation-selected controls from an
unconditional source-only oracle. The default basic behavior is itself testable.

### Other evidence limits

- `discrete_bus_31.va` and `discrete_bus_narrow.va` observe all-ones values.
  These distinguish zero/sign extension but cannot distinguish bit reversal or
  mapping of nonzero/ascending declared ranges. The >31 rejection is on a whole
  accessed grouping; a legal 31-bit part-select of a larger digital bus must not
  be rejected merely because the declaration is wide. Current headers say the
  parser decides declaration width; investigate that separate legal boundary.
- `lrm_7_4_4_1.va` connects a digital and analog port but supplies no connect
  statement. §6.5.7 expressly permits mixed port connections provided appropriate
  connect statements exist, and §7.8.4 requires exactly one match. Its assertion
  is only prescribed voltage access. Before giving it full-design conformance
  credit, isolate discipline-resolution inspection or add the required bridge.
- `resolution_connect_accepted.va` names electrical/thermal in a resolution
  list but constructs no affected shared net and tests only pinned V(p).
  Syntax acceptance does not prove compatibility, resolution or exclusion.
- Current COVERAGE claims about no runtime NaN check being possible because
  “every comparison against a NaN is false” are unsound: inequality and explicit
  host finiteness checks exist. The source prohibits nonfinite contributions;
  it does not require every nonfinite value be statically diagnosable.
- `m03_12`'s two-continuous override rejection and `m03_13`'s ambiguous insertion
  rejection are source-backed distinct obligations. Insertion matching must
  not borrow resolution's first-match-with-warning policy. They remain expected
  failures, not evidence that rejection semantics currently work.
- `m03_09` is a useful written one-node discriminator: asymmetric loads give
  6/7 on the shared node versus 1 and 1.5 on wrongly separated nodes. Its current
  XFAIL does not constitute execution evidence. Instance count and analog node
  count remain separate requirements, as its header correctly warns.

## Initial obligation groups

All Chapter 7 obligations remain in full AMS scope; Annex C.9 excludes this
chapter from the separately tracked Verilog-A profile. Analog-only dependencies
such as local access and node tolerances remain requirements through their own
chapters. The following are grouping IDs, not a complete atomic-rule inventory.

| ID | Source / physical pages | Evidence needed and boundary |
|---|---|---|
| MIX-001 | 7.1–7.2.1 / 177–178 | Both manual and automatic bridge paths; resolution before insertion; discrete ticks versus continuous time. Overview examples are not executed integration. |
| MIX-002 | 7.2.2 / 178 | Analog, analog-initial, digital initial/always/assign contexts; declaration initialization context-free; error for both-context writes. Undefined unassigned domain and optional warning must not be fixed to one mandatory result. |
| MIX-003 | 7.2.3 / 178–179 | Preserve formal/actual net identity, local disciplines, driver/contribution write ownership, contiguous hierarchy and mixed classification. Local accessor evidence is MIX-LOCAL-001. |
| MIX-004 | 7.2.3–7.2.4 / 179 | One analog node, digital-to-analog contributions, analog-resolved receivers, shared conversion of same-module assigns; smallest node abstol and explicit compatible-discipline resolution. MIX-TOL-001 invalidates current claimed observation. |
| MIX-005 | 7.3 / 179 | Multiple blocks and cross-domain reads legal; writes domain-owned. Context-correct legal neighbors required for each rejection. |
| MIX-006 | 7.3.1 / 180–181 | Table 7-1 real/integer arrays, scalar bits, buses, part-selects, zero/sign extension and 31-bit access boundary. Add nonsymmetric patterns and legal narrow access to wide declaration. |
| MIX-007 | 7.3.2 / 181–182 | Each x/z conversion operator and case-family form; arithmetic/result x/z errors versus known comparison result. EXPR-XZ-001 prevents treating the contradictory annotation as an oracle. |
| MIX-008 | 7.3.2.1 / 182 | Digital special values legal versus positive/negative infinity/NaN analog contributions illegal. Separate constant and runtime-derived cases; no blanket finite-expression rule inferred. |
| MIX-009 | 7.3.3 / 182–183 | Every analog probe form legal digitally; analog continuous-variable reads interpolate unless last assigned in an analog event, in which case hold exactly. Probes, free variables and held variables need separate observations. |
| MIX-010 | 7.3.4 / 183–184 | Digital event arguments use digital context, analog event control is nonblocking; grammar alternatives include bare/hierarchical events, expression changes, both edges, event-or and analog functions. Nonblocking is not a Verilog NBA assignment. |
| MIX-011 | 7.3.5 / 184–185 | Analog event arguments use analog context and block the digital process; cross/above/timer/absdelta, event lists and driver_update paths remain distinct. |
| MIX-012 | 7.3.6–7.3.6.1 / 185 | Global smallest precision tick, rounding without scheduling into digital past; zero-delay round-trip retains analog time. Coordinate with SCH-018. |
| MIX-013 | 7.3.6.1 / 185 | Analog variable assigned only under analog events triggers digital event on every assignment, even equal value. Named-event tests do not establish this variable-event rule. Search found no isolated same-value reassignment fixture in the m01/m02 families. |
| MIX-014 | 7.3.6.2 / 185–186 | Digital event control executes at real-promoted tick; distinguish edge time from a later prescribed grid point. |
| MIX-015 | 7.3.6.3 / 186 | Analog primary in digital expression evaluated at promoted digital time, including interpolation/held-value exception. Neither constant bias nor kernel unit test proves crossing-time sampling. |
| MIX-016 | 7.3.6.4 / 186 | Analog event-only assigned variables can drive wreal and traditional wire families. Need both value updates and same-value handling through actual continuous assignments. |
| MIX-017 | 7.3.6.5 / 186 | Digital primary analog reads use greatest tick <= analog time. m01_11 proposes before/at/after values but remains a mixed execution lead, not a passing integration result. |
| MIX-018 | 7.3.7 / 186 | Digital function from analog and analog function from digital are independently prohibited; declarations must parse so the call-context diagnostic is reached. |
| MIX-019 | 7.4–7.4.1 / 186–187 | Resolve undeclared segments from declarations/defaults/hierarchy before insertion; same lower discipline needs no rule; multiple compatible disciplines use resolution rules. |
| MIX-020 | 7.4.2–7.4.3 / 187–188 | Discrete connections inherit IEEE and wreal rules; continuous connections enforce compatibility at actual ports, not only two nets in a flat expression. |
| MIX-021 | 7.4.4 / 188 | Conflicting declarations even when compatible; basic default and documented vendor selection. Both in-context and remote declaration scenarios matter. |
| MIX-022 | 7.4.4.1–7.4.4.2 / 188–189 | Basic upward propagation and analog precedence; detail continuous up/down, no discrete upward propagation, exception for coercion. MIX-MODE-001 records the false untestability claim. |
| MIX-023 | 7.4.4.3–7.4.5 / 190 | Declared-interconnect retention, resolveto override, continuous-only agreement between algorithms. Do not overwrite separately declared child discipline. |
| MIX-024 | 7.5–7.6 / 191–192 | Both module declaration grammar arms, port discipline/direction matching, all three Table 7-2 direction pairs and both hierarchy orientations. Uninstantiated connectmodule acceptance is not bridge execution. |
| MIX-025 | 7.7–7.7.1 / 192–193 | Both rule item forms, multiple declarations, compatible override discipline pairs and all direction-override grammar alternatives. Grammar, compatibility, selection and behavior are separate. |
| MIX-026 | 7.7.2 / 193–194 | Compatible-list resolution, exclude for discrete and continuous families, and errors only on an affected net. Preserve comma grammar despite bad examples. |
| MIX-027 | 7.7.2.1 / 194 | Exact match beats fallback; multiple exact or subset matches warn and use first; result may be outside input list; no primitive discipline setting. Source-level fixtures should observe diagnostics plus resulting behavior, not merely internal matcher tests. |
| MIX-028 | 7.7.3–7.7.4 / 195 | Parameter overrides actually applied to inserted bridges; split/merged selection operates per hierarchy level. Parsed unused attributes do not close these rules. |
| MIX-029 | 7.8–7.8.1 / 195–197 | Mixed port insertion, one continuous/one discrete override, post-elaboration hierarchy-dependent matching, coercion and level-local grouping. Pure analog/digital neighbors must avoid insertion. |
| MIX-030 | 7.8.2–7.8.3 / 198–200 | Digital segmentation only, analog node never segmented, default merged and grouping conditioned on common connector module. m03_09 is a written but unexecuted discriminator. |
| MIX-031 | 7.8.3.1–7.8.3.2 / 200–203 | Merged can group different port directions when same module; split is per matching digital port. Independent analog load counts and digital state are needed, not only inferred instance names. |
| MIX-032 | 7.8.4 / 203–204 | Exactly one match, upper-connection insertion context, same-upper-signal/module/merged sharing, otherwise per-port instance, and driver-receiver segregation. Preserve resolution-vs-insertion ambiguity-policy difference. |
| MIX-033 | 7.8.5 / 204 | Merged and split generated names, double underscores and instance-specific defparam effects. Current missing-instance rejection alone cannot establish naming. |
| MIX-034 | 7.8.5.1 / 204–205 | Every primitive family positional generated-port name; forbid using synthetic names for actual primitive instantiation/access. Resolve source's rtranif/two-port inconsistencies first. |
| MIX-035 | 7.8.6 / 205–210 | Runtime supply dependence versus constant parameter; string alias binding; multiple supply disciplines; absolute versus relative search from actual insertion point. Parsed but uninstantiated supply examples prove none of these runtime behaviors. |
| MIX-036 | 7.9 / 211–212 | Separate state for noncontiguous digital segments; drivers routed through analog solution before receivers; opposite grouping for connectmodule drivers/receivers; pure-domain behavior unchanged. Need delayed/parasitic analog observation to catch direct digital bypass. |

Host coupling remains an explicit obligation. The fixed-grid emitted testbench
and separately unit-tested scheduler cannot close adaptive synchronization,
rollback, bridge insertion or segregation merely by existing. See the main
`conformance-scheduling.md` ledger for that established limitation.

## Reproducible figure crop proposals

`tools/extract_ch7_audit_figures.py` in this worktree uses the existing extractor's
physical-page/top-left-PDF-point convention and direct 216 dpi Poppler rasterization.
It writes only `docs/ch7-audit-figures/` in this worktree. All generated crops
were viewed against their full source pages; captions and diagram boundaries are
included. The 7-9 asset deliberately contains both the empty 7-8 caption and
the actual 7-9 caption. No redrawing or synthetic reconstruction was used.

| Asset | Physical page | Left | Top | Width | Height |
|---|---:|---:|---:|---:|---:|
| 7-1 | 178 | 105 | 390 | 402 | 206 |
| 7-2 | 187 | 111 | 294 | 390 | 242 |
| 7-3 | 188 | 87 | 463 | 500 | 258 |
| 7-4 | 189 | 87 | 258 | 500 | 258 |
| 7-5 | 190 | 87 | 162 | 500 | 260 |
| 7-6 | 197 | 87 | 150 | 500 | 262 |
| 7-7 | 199 | 152 | 78 | 308 | 600 |
| 7-9 (includes 7-8) | 201 | 119 | 67 | 374 | 465 |
| 7-10 | 202 | 117 | 210 | 378 | 458 |
| 7-11 | 212 | 87 | 78 | 438 | 380 |

Integration should add these entries to the main extractor, regenerate there,
inspect the main result and replace link-only callouts with image elements while
retaining exact-source links and clearly editorial descriptions. B/D and runtime
A/C are not moved by this source-only report; measurement remains the main
agent's separate responsibility.
