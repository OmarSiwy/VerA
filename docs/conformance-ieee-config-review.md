# Inherited IEEE configuration and library review

Reviewed 2026-09-23 against licensed `docs/1364-2005.pdf`, SHA-256
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
Edition title: **13. Configuring the contents of a design**. Read complete
Clause13 text, printed199–210 / physical229–240, including all syntax and
examples through13.7.3. Visually checked physical231–235 and238: library-map
syntax/resolution, duplicate cells, config syntax and rule combinations,
hierarchical ownership, and library binding display. No figures or tables
occur in this clause; other pages are text-read, not visual-certified.

Checked existing root inherited/scope/Annex-A ledgers before adding this review.
The existing Annex-A A-EVID-002 row identifies ignored configurations but does
not constitute a complete source audit of Clause13. Scope review covers
12.6–12.8 and explicitly leaves configurations open. This report extends
inherited full-AMS accounting beyond measure B's §§17–18 denominator. No measured
A/C value or whole-clause closure is claimed.

## Obligation register

Source page numbers below are printed. OPEN denotes incomplete behavioral and
invalid-input evidence, not an excluded feature. Host-dependent interfaces are
separate from normative behavior; unsupported legal source is not rejection
coverage.

| ID | Source | Obligation and evidence |
|---|---|---|
| CFG-001 | 13.1/.1, pp199–200 | Config is a design element specifying bindings; cell name is design-element name within a symbolic library. Explicit :config disambiguates a config from same-named module/primitive. OPEN: namespace, same-name and rebinding evidence. |
| CFG-002 | 13.2.1, pp200–201 | Map information is read before source; mechanism for one or more maps is required, filename/interface tool-specific. Multiple maps are read in invocation order. No documented root CLI mechanism found; OPEN host seam, not exemption. |
| CFG-003 | 13.2.1, p201;13.7.2, p209 | Path grammar supports ?/*/hierarchical.../parent../current.; trailing slash includes directory files. Relative paths are map-relative, not caller-CWD-relative. OPEN: filesystem corpus and actual map consumer. |
| CFG-004 | 13.2.1.1, pp201–202;13.7.3, pp209–210 | Explicit filename outranks wildcard filename, which outranks directory. Equal-priority cross-library matches error; unmatched file belongs to work. New display oracle uses unmatched work fallback but runtime lacks format support; mapping precedence OPEN. |
| CFG-005 | 13.2.1.1, p202 | Last same-name cell in same library replaces earlier; same-invocation duplicate module requires warning. Do not substitute unconditional duplicate-name rejection. OPEN: ordered compile/library state and diagnostic evidence. |
| CFG-006 | 13.2.2/.3, p202 | Map include is textual insertion; paths resolve relative to containing map; source filename determines cell-library mapping. Provider supplies local map. OPEN: include ordering/nesting and per-file origin tracking. |
| CFG-007 | 13.3.1.1, pp202–203;13.4.4, p206 | Exactly one design statement, before rules; may list multiple top modules but not configurations. Omitted library uses config's library. Design determines top even with other uninstantiated cells. New selected-top witness FAILs as unsupported legal program. Remaining validation and multiple-top behavior OPEN. |
| CFG-008 | 13.3.1.2, p203 | Default applies only without more-specific selection; may pair with liblist, not use; duplicate defaults for same expansion forbidden. New default/use invalid gets specific E0207; matching legal default/liblist accepted. Precedence/duplicate validation OPEN. |
| CFG-009 | 13.3.1.3, p203 | Instance selector is hierarchical name beginning at config design's top cell. More-specific instance selection overrides default. OPEN: selection-sensitive runtime witness, not unused syntax. |
| CFG-010 | 13.3.1.4, p204 | Cell selector may be qualified, but qualified selector plus liblist is explicitly an error. Qualified binding selection applies to matching library/cell under consideration. Isolated invalid wrongly accepted with legal unqualified neighbor. OPEN enforcement and selection behavior. |
| CFG-011 | 13.3.1.5, p204 | Ordered liblist inherited downward; first suitable cell chosen unless explicit binding applies. Missing/empty selected list falls back to parent cell's library. OPEN: competing implementations, inheritance and empty-list reset. |
| CFG-012 | 13.3.1.6, pp204–205 | Use with instance/cell binds exact target, possibly differently named; it does not change current liblist. Omitted library is parent cell's library. OPEN: target/name differences, list persistence and local-library provenance. |
| CFG-013 | 13.3.2, p205 | Binding to nested config uses its design for replacement instance and its rules for descendants. Outer config cannot select a descendant inside another config's hierarchy; explicit error required. OPEN positive and isolated invalid with legal neighbor. |
| CFG-014 | 13.4.1/.2, pp205–206 | Source-file single-pass strategies can precompile every supplied cell or compile on elaboration demand; persistent cache is not required for either. OPEN: chosen supported workflow, not a requirement to expose identical internal algorithm. |
| CFG-015 | 13.4.3/.4, p206 | Separate-compilation model needs persistent vendor-specific compiled forms and all cells precompiled before binding; config itself precompiled when used. OPEN host/workflow capability. Do not mistake tool-specific format for permission to omit binding semantics. |
| CFG-016 | 13.5.1–.5, pp207–208 | Examples substantiate map-order defaults, explicit liblist override, cell binding, instance list inheritance, and nested config-relative instance paths. These are separate traces still needing selection-dependent values. OPEN, not closed by one config parse. |
| CFG-017 | 13.6, pp208–209 | %l/%L prints library.cell of containing module instance, not %m hierarchy. VPI module properties vpiLibrary/vpiCell/vpiConfig are strings describing actual binding. New display witness FAILs unsupported formatting; VPI values remain OPEN separately. |
| CFG-018 | 13.7/.1, p209 | Without config, required command-line library-name search-order mechanism overrides map order; config overrides this mechanism. -L spelling is a recommendation, not required literal interface. OPEN actual CLI and precedence tests. |

## New fixtures, derivations and actual results

All observations are direct calls to the current root `zig-out/bin/vera --run`
from the agent worktree, on the review date. No full suite ran. Files with
expected transcripts are legal behavioral programs, not expected rejections:

- `digital/audit_config_design_select.v` defines selected and unselected modules,
  both otherwise uninstantiated, and a config whose design is
  `work.config_selected`. Unmapped source defaults to work. The config makes
  only selected module a top, hence transcript is exactly `selected`; the other
  module must not execute. Actual exit1, W0253 followed by E1100 requiring exactly
  one top-level module. There are no child instances, so hierarchy elaboration
  cannot explain away the selected-top requirement. Unsupported legal program,
  not an invalid-top test.
- `digital/audit_config_binding_display.v` has one unmapped module and prints
  both binding formats. Expected both are `work.audit_config_binding_display`,
  without argument consumption. Actual exit1/E1100 unsupported conversions.
  This isolates the display capability without configuration selection,
  hierarchy or library-map loading prerequisites. The oracle presumes the
  stated no-map/no-library-override invocation; future runner mapping changes
  must preserve that controlled premise, not silently alter the expected library.
- `digital/audit_config_default_use_rejected.v` explicitly opts into the digital
  rejection runner. The source forbids default/use. Actual exit1 has E0207 and
  header phrase `a default pairs with ` followed by `liblist` in backticks;
  both machine-readable patterns require this rule-specific diagnostic, not
  a comment/source excerpt. `tools/config-audit-controls/default_liblist_legal.v`
  changes expansion to liblist work: exit0, prints `accepted`, W0253. This is
  bounded syntax validation, not positive binding behavior or whole-row closure.

`tools/config-audit-controls/cell_liblist_legal.v` and
`qualified_cell_liblist_invalid.v` isolate CFG-010: unqualified cell selector
versus library-qualified selector, same liblist work. Both actual calls exit0,
print `accepted`, and emit W0253. The invalid is retained as a demonstrated
unmet diagnostic, not given a made-up expected diagnostic or broad any-error
test. No XFAIL markers added to legal digital failures.

## Existing evidence and implementation boundary

`annex_a_syntax/47_configuration_source_text.va` has only three of five rule
alternatives, as its revised opening header and Annex-A review already record.
Its later prose still says four statements. More importantly, its analog
voltage assertion does not observe binding, and its selected top cell is not
defined in the standalone fixture. Such a config can name an externally
provided library cell, but no library setup in this carrier supplies it.
Acceptance under discarded configuration is therefore neither successful
binding nor evidence that a complete configured design was legally elaborated.
Existing files are unchanged; these withdrawn coverage claims belong to
CFG-007/009/010/011/012, with actual selection-sensitive evidence introduced above.

`parseConfigDecl` requires initial design syntax, reads rules and emits W0253
without recording any binding state. `parseConfigRule` enforces default/liblist
pairing but parses qualified cell names with the same unrestricted dotted-name
routine before accepting liblist. It cannot establish library lookup, hierarchy
ownership, default uniqueness or actual selected top. The current CLI help has
no map-file or configured-top/library-search interface; this records an open
integration seam, not a claim about exact future option spelling.

Do not classify syntax fixtures containing library declarations in ordinary
source_text as successful library-map operation: map language and ordinary
source language have different starting symbols. The required library-map
input mechanism is the missing positive neighbor, not merely another .v
whose parser rejects `library`.

## Source cautions and remaining work

Syntax13-2 includes config declarations in library_text, whereas §13.2.2's
prose list of permitted map contents omits configs. Preserve both provenance
points rather than fabricate a config-in-map rejection oracle. The example
config header in13.5.4 lacks its required semicolon; actual Syntax13-4 supplies
the grammar. No example typo is copied into a new legal fixture.

Library-map fixtures still need a real host harness that can supply maps,
multiple files, nested path roots, library search order, and repeat invocations.
VPI binding properties require an actual configured hierarchy and property
reader, not only header constants. Separate-compilation lifecycle, duplicate
cell warning and all five binding-rule alternatives remain open. Main
integration must run its focused/full digital gates and compare FAIL name
membership; direct diagnostics here do not claim the new rejection has already
passed the integrated suite. No compiler edits, shared harness edits, full
builds or measured conformance runs were made in this handoff.

## Root integration boundary

Main read this report on 2026-09-23 and retained its source/evidence register.
The new fixtures and controls are now integrated. Main independently checked
13.3.1.1,13.4.4 and13.6: the selected-top test uses the stated single-pass
source-file invocation, not an invented configuration-selection flag. Independent
root gate results remain pending; worker observations are not silently promoted
to measured root results. This report does not change A/C measures.
