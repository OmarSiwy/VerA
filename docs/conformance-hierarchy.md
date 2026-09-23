# Chapter 6 source and evidence review

Review date: 2026-09-23. This independent review read the complete extracted
AMS Chapter 6 text, printed pages 134–163 (physical PDF pages 147–176), against
the current root checkout's `docs/ch6-hierarchy.html`, including every syntax
production and example. The root checkout, not this detached worktree's older
HTML, was the comparison target. The source hash is
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.

This completes a first chapter text reading, not certification of all visual
details or an exhaustive atomic-rule denominator. No compiler or fixture was
changed or executed by this review. Existing green claims below are historical
claims, not freshly verified runtime results. Measures A/C must still be written
only by the measurement script. The work improves source and evidence accounting;
it does not close inherited measure B or change architecture D.

## Review boundaries and visual evidence

Grammar follow-up: the parallel reviewer visually checked every page carrying
Syntax 6-1–6-9: physical pages 147–150, 152, 156, 160–161, 166–167 and 173.
Main reviewed the complete markup patch and independently verified all nine
syntax-box bodies are unchanged after removing the added bold tags. The
literal/metasyntax distinction is now integrated, closing HIER-BNF-001's
presentation repair. This supersedes the selected-page-only limit below for
these boxes, not the remaining figure or behavioral obligations.

Complete HTML was read with the full PDF text. Mechanical per-section token
differences were inspected as an aid; condensed prose, rearranged examples,
missing BNF source cross-references and line-wrap differences prevent treating
token equality as the criterion. Visual checks were made on physical pages:

- 148: Syntax 6-1 continuation, including literal concatenation braces and
  select brackets versus repetition/optional notation.
- 161: complete Syntax 6-6/6-7, including literal range brackets, assignment,
  separators and keywords.
- 167: Syntax 6-8 continuation, including the null-block semicolon, optional
  default colon, conditional tokens and generate delimiters.
- 151: Figure 6-1 and accompanying instantiation/override prose.
- 174: Figures 6-2/6-3 and start of the OOMR restrictions.
- 176: complete final elaboration algorithm and its printed numbering.

Other syntax-box pages have text review only. Figures 6-1 and 6-2 are currently
links to the source rather than embedded reproductions. Figure 6-3's HTML table
preserves the inspected source's row associations and names; it is a text
transcription, not an image. The opening HTML note should not imply that all BNF
typography or figures have already been faithfully reproduced.

## Actionable HTML fidelity repairs

Integration follow-up: HIER-TEXT-004 through HIER-TEXT-009 have now been
applied after main-review comparison with the source passages and confirmation
that the patch base matches the current HTML. Together with the earlier batch,
the listed prose repairs are integrated. The table retains the findings for
provenance, not as a claim they remain pending. HIER-BNF-001 and figure
embedding remain open; no runtime obligation is closed by these edits.

These differences were found in the root HTML at the start of this review,
separate from source defects. During integration the parent independently read
and repaired HIER-TEXT-001, HIER-TEXT-002 and HIER-TEXT-003, recording the bounded
changes in the source-review log. Those three are no longer pending repairs;
their evidence is retained below for provenance. Other rows remain proposals.

| ID | Source and HTML anchor | Difference / recommended repair |
|---|---|---|
| HIER-TEXT-001 | 6.4.3; physical 160 / printed 147; `s6.4.3`, third bullet | Source says the value may be computed from values of any **output parameters** of the module. HTML silently substitutes **module output variables**. Restore source wording, then label the apparent terminology inconsistency editorially: the surrounding rule, dotted identifier syntax and example describe output variables. Do not use the substitution as independent authority. |
| HIER-TEXT-002 | 6.6.2; physical 170 / printed 157; `s6.6.2`, ordinary-declaration collision bullet | HTML omits the explicit qualifier that collision is forbidden even when that block is not selected for instantiation. Restore it. The neighboring block/block collision bullet retaining the qualifier does not replace it. |
| HIER-TEXT-003 | 6.5.4; physical 163 / printed 150; `s6.5.4`, opening | HTML says ports listed in a module instantiation shall be in definition order, dropping the source's explicit ordered-list applicability. Restore the ordered-list condition so the standalone sentence cannot be read as restricting named connections. |
| HIER-TEXT-004 | 6.9.4; physical 176 / printed 163; `s6.9.4`, algorithm introduction | Source defines **an order that produces the correct hierarchy**; HTML asserts **the correct order**. Restore the source's wording rather than imply all implementation scheduling must be identical. |
| HIER-TEXT-005 | 6.9.4; physical 176 / printed 163; algorithm step 3 | HTML drops **of this step** after the deferred target's **next iteration** and drops **In other words** linking this step to the preceding expansion. Restore these, retaining the source's separate numbering ambiguity below. |
| HIER-TEXT-006 | 6.6.1; physical 168 / printed 155; unnamed-block bullet | Replace shorthand **cannot be referenced hierarchically from outside** with the exact exception boundary: other than from within the hierarchy instantiated by the generate block itself. Descendant scopes matter, not only the block's lexical body. |
| HIER-TEXT-007 | 6.4.1; physical 158 / printed 145; dotted assignment paragraph | Restore **of a different module** to the non-local OOMR prohibition for direct fidelity. The current shortened sentence can be understood through OOMR, but omits an explicit scope condition. |
| HIER-TEXT-008 | 6.4.2; physical 159 / printed 146; local-range selection bullet | Restore **specified in the paramset** after allowed ranges. It distinguishes eligibility ranges from the underlying module's ranges, whose failure must not silently trigger fallback selection. |
| HIER-TEXT-009 | 6.3.4 and 6.4.3; physical 154 and 160 | HTML replaces the source's curly macro introducers with ASCII backticks without identifying those normalizations. Existing `.rb` correction is already labeled and should not be reported as newly undiscovered. |
| HIER-BNF-001 | Syntax 6-1 through 6-9 | Plain monospace boxes erase literal-versus-meta token distinctions. Confirmed visually for Syntax 6-1 continuation, 6-6/7 and 6-8 continuation. Restore literal-token markup after checking each remaining page; do not mechanically bold every brace/bracket. Particularly `port_expression` has literal outer concatenation braces and metasyntax inner repetition braces; `port_reference` and `hierarchical_identifier` have optional outer brackets and literal inner select brackets. |

Several harmless reductions remain (for example expanded I/O wording, moved
syntax captions, and condensed example introductions). They are not individually
claimed to change semantics. If the document promises a transcription rather
than a descriptive reference, identify editorial condensation explicitly or
restore original prose; do not label the present chapter verbatim.

## Source issues to preserve, not silently fix

- **HIER-SRC-001, 6.3.6, physical 154–155 / printed 141–142:** general prose
  requires a warning if double-scaling misuse is detected; the following
  `badres` example says an error will be generated. Both occur in the PDF and
  HTML. The existing rejection fixture chooses the example's error outcome.
  Keep that evidence with this qualification instead of claiming an unambiguous
  universal rejection obligation. Merely reading `$mfactor` is permitted, and
  the simulator cannot disable automatic scaling.
- **HIER-SRC-002, 6.4.3, physical 160 / printed 147:** the PDF prints `rb=145`
  without the leading dot, and uses a curly introducer before `M_TWO_PI`.
  The HTML already discloses its `.rb` correction; extend the normalization note
  to the macro punctuation and the output-parameters terminology discrepancy.
- **HIER-SRC-003, 6.6.2, physical 170–171 / printed 157–158:** `nlres` offers
  a `res == 0.0` branch while declaring `res` with an open lower bound `(0:inf)`.
  A test of legal zero-resistance selection needs an independently legal range;
  the informative example cannot override the parameter-range rule.
- **HIER-SRC-004, 6.8, physical 175 / printed 162:** the conditional-generate
  naming exception refers to 6.6.3, although the permission itself is described
  in 6.6.2. Retain the printed cross-reference and label the explanatory link.
- **HIER-SRC-005, 6.9.4, physical 176 / printed 163:** numbered step 3 ends by
  saying parameter values are final before going to step 3. This is in the
  rendered PDF, not extraction corruption. Preserve it and disclose the
  numbering inconsistency; do not silently renumber or derive an extra pass
  requirement from the self-reference.

## Requirement groups and evidence limits

This is a refinement worklist, not a complete atomic inventory. Grammar arms,
types, contexts and interactions still need separate rows and results.

| ID | Clause / physical pages | Obligations and existing evidence leads |
|---|---|---|
| HIER-001 | 6.1–6.2 / 147–149 | Standalone module definitions; header forms; parameter/port ordering; no ANSI port redeclaration; module/macromodule permission; help-description use. Existing module/header/port fixtures provide leads, but no module help-message observation was located in this review. Header/body locality is already PAR-020, not new work. |
| HIER-002 | 6.2.1 / 149 | Top-level selection depends on textual instantiation, even unselected generate branches. `$root` disambiguates local precedence. `root_reference_unsupported.va` exercises distinct local/root parameter values, but `top_level_module.va` does not establish unselected-instantiation exclusion. |
| HIER-003 | 6.2.2 / 149–151 | One/multiple instances; instance arrays; required parentheses; ordered/named/blank connections; digital-input expressions. `instance_array_unsupported.va` uses identical observations per element without `//! checks`, so a dropped element is invisible. `defparam_instance_array_element.va` assigns both elements the same value, so cannot establish indexed isolation. Add asymmetric values and expected transcript multiplicity. |
| HIER-004 | 6.3–6.3.5 / 151–154 | Defparam precedence over inline override and over paramset selection; same-module constant RHS; no cross-sibling/outward override under generate or instance array; no defparam under paramsets; ordered skip rules; named default-preserving empty assignments; duplicates; dependent values and override detection. `defparam_unsupported.va` discriminates inline-versus-defparam values but not deferred generate targets or paramset selection. Existing local/alias work must be reused, not treated as closure of all paths. |
| HIER-005 | 6.3.6 / 154–156 | Non-unit flow contributions, flow probes including indirect assignments, flow-noise and potential-noise power scaling, descendant multiplicity; geometry propagation and absence of automatic geometry effects. `mfactor_propagation_unsupported.va` observes multiplicity arithmetic, not automatic stamping; top-level unit-factor probes/noise tests cannot discriminate multiplication, division and omission. Non-unit solved-flow/noise oracles remain necessary. |
| HIER-006 | 6.4–6.4.1 / 156–158 | Chains terminate at modules; restricted statements/access/events/named blocks; local versus non-local OOMR; constant stochastic arguments; variable values cannot feed module parameters; help descriptions. `h01_03_paramset_oomr_localparam.va` covers permitted local access only. The H01 spec's rejection-budget rationale is not a conformance exemption. |
| HIER-007 | 6.4.2 / 158–160 | Independently exercise every eligibility condition, all tie-breaks in priority order, residual ambiguity, and underlying-module range failure without fallback. `h01_04_paramset_overload_lrm_table.va` covers two selection outcomes and first tie-break, not all three tie-breaks. It has no observation-count pin for both instances. A later-declaration winner is useful but does not establish the other priorities. |
| HIER-008 | 6.4.3 / 160 | Report described paramset variable; replace same-name module output; hide module output when same-name paramset variable lacks description; compute from dotted module output. `paramset_output_unsupported.va` observes input values only, never reported `ft`; its base module has no same-named `ft`, so replacement is not exercised even structurally. Reporting/evaluation/export remain open. |
| HIER-009 | 6.5.1–6.5.2.2 / 160–162 | Port expression grammar (including internal empty ports), discipline and direction forms, folded matching endpoints and direction, minimum supported port count. `vector_ports_range_equal.va` plus `vector_ports.va` test a valid/invalid range pair, not the whole clause as COVERAGE claims. A rejected contract unknown limit is implementation-bound evidence, not the minimum-port obligation. |
| HIER-010 | 6.5.3–6.5.7.2 / 162–165 | Real-valued single-driver ports; ordered/named bindings and prohibited mixed forms; omitted versus empty connections; scalar/vector/concatenation width; discipline compatibility and implicit resolution. `port_connected.va` discriminates a dangling connected net from an unconnected port. `lrm_6_5_7_1.va` still has generic phase rejection. Cross-reconcile wreal, nature and implicit-net ledgers. |
| HIER-011 | 6.5.8 / 165 | Associated node must use independently minimal potential and flow tolerances across connected compatible disciplines. COVERAGE correctly admits no fixture. Separate nodes with different disciplines or accepted metadata cannot prove minimum selection or solver consumption. |
| HIER-012 | 6.6–6.6.1 / 165–170 | Generate-only legal items; optional region and nesting restrictions; elaboration-constant schemes; implicit localparam; zero/sparse/descending arrays; finite nonrepeated known genvar values; named array collision even empty. Existing descending and two-loop digit accumulators discriminate order. They do not cover sparse hierarchical indexing, empty-array declaration collisions or all illegal item classes. |
| HIER-013 | 6.6.2–6.6.2.1 / 170–172 | Conditional selected/unselected names, direct nesting versus begin/end scope, recursive instantiation, top-level exclusion, structural sweep limitation as optional latitude. `generate_block_shadows_declaration_rejected.va` intentionally selects its colliding block; add independently unselected block-versus-ordinary-declaration case. Do not require structural sweep support where source permits restriction. |
| HIER-014 | 6.6.3 / 172–173 | External names increment for every construct, named or unnamed, reset by scope, and add leading zeros on collisions. `external_genblk_reference_unsupported.va` is only an HDL prohibition, not evidence of externally reported names. Need VPI/interface enumeration plus HDL legal internal access controls. |
| HIER-015 | 6.7–6.8 / 173–175 | Hierarchical identifier grammar; allowed branch/parameter/function access and contributions in analog/digital contexts; forbidden analog-variable read/write and OOMR parameter defaults; local/upward scope search; implicit-net discipline precondition. Current three negative fixtures use undeclared `device`/`other` names, so their rejection is not isolated evidence for the intended restrictions. Build real child instances and legal neighboring parameter/function/branch controls. |
| HIER-016 | 6.9–6.9.4 / 175–176 | Post-generate source-order concatenation; paramset selection after generated values/connections; discipline resolution after topology and selected module; deferred defparams resolved before dependent generate expansion. `multiple_analog_blocks.va`, descending/two-loop fixtures discriminate concatenation. `h01_05_paramset_under_parameter_sweep.va` has one paramset and no generate: it observes recomputed dependent values, not overloaded selection or §6.9.2 ordering. Add competing bins/topologies, generated override inputs and deferred defparam targets. |

## Highest-priority documentation corrections around existing fixtures

1. Withdraw the H01 sweep fixture's claim to observe paramset **identity**
   recomputation. It cannot distinguish reevaluation of an expression with a
   fixed selected module from actual reselection. Keep its useful dependent-value
   assertion; move the selection claim to HIER-016 pending a new discriminator.
2. Withdraw the OOMR negatives' rule-isolation claim until referenced objects
   actually exist. `oomr_variable_read_rejected.va` uses `device.local_value`,
   `oomr_variable_assign_rejected.va` likewise, and
   `oomr_in_parameter_declaration_rejected.va` uses `other.gain`; none declares
   those instances. Their current diagnostics cannot prove the target rules.
3. The array fixture's claim that the runner has no observation-count mechanism
   is now stale: `//! checks` exists. Pin multiplicity and prefer asymmetric
   observations so missing, duplicate and misbound instances do not share one
   indistinguishable transcript.
4. Keep paramset output reporting explicitly open. The existing fixture's claim
   that wrong `ft` would necessarily be a reporting-path-only defect is too
   narrow: expression evaluation or dropped paramset statements could also fail.
5. `COVERAGE.md` and `h01_SPEC.md` contain historical paths, stale diagnostic
   codes, unexecuted closure claims and exclusion-by-budget reasoning. They
   should defer to this rule worklist and fresh measured results, not claim that
   a pair of range fixtures proves the whole direction clause.

## Inherited IEEE follow-up

AMS 6.7.1 explicitly inherits IEEE 1364-2005 12.6 while restricting
`scope_name` to `hierarchical_inst_identifier`. Complete extracted IEEE 12.6,
printed pages 193–195 (physical 223–225), was read during this review. It
distinguishes local/downward scope lookup from iterative parent-module lookup,
and explicitly points to a defparam-LHS exception in 12.8. Syntax 12-7 received
text review only. IEEE 12.8 was not read here and remains an inherited dependency.
No inherited runtime rule is closed by this reading, and the IEEE source text
is not reproduced in this draft.
