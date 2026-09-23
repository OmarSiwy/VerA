# Chapter12 source and VPI evidence review

Reviewed 2026-09-23. Source: AMS2023 PDF SHA256
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
Complete Chapter12 prose, routine argument tables, examples and HTML read:
printed309–354 / physical322–367. HTML baseline SHA256
`41c4f8c6dce6778d2e3d62db1e7147973d0ae9cf78bad60f1b63dd2c7230a78f`.
This is a source/evidence audit, not a runtime conformance closure.

## Main integration checkpoint

Integrated 2026-09-23 after reading this report, reviewing the HTML patch and
checking the literal entity spellings against the PDF extraction. Main
mechanically verified that all 38 numbered fixture changes alter only Chapter12
tags, evidence-boundary comments and empty lines; executable HDL and other
machine directives are unchanged. The source regression suite passed all 23
tests. Worker visual inspection remains explicitly bounded as recorded below.

The separate C patch is now linked and executed: `zig build test-vpi` exited0.
Direct execution of the resulting application exited0 with census
`scopes=5 ports=11 nets=6 regs=2 params=8 checks=711` and exactly the three named
XFAIL probes below. This preserves regression checks while exposing missing
required-positive capabilities; it does not close those obligations. Main also
checked the §12.20/12.23 source wording, IEEE constant definition, instance
source line and non-clearing error-read implementation. Full suite and generated
measurement checkpoints are recorded separately; no A/C number is hand-entered.

Subsequent main gates: `zig build test` exited0; strict-suite exit1 reflects the
existing debt, with its nonempty sorted FAIL/XFAIL name list byte-identical to
the preceding plusargs/introduction checkpoint. No new behavioral failure was
introduced by the Chapter12 metadata changes. The newly exposed C API XFAILs
are separate host probes, not hidden additions to that fixture name list.

## Visual review boundaries

Rendered original PDF with `pdftoppm -f 322 -l 367 -scale-to 1550 -png`.
Visually inspected physical323,325,327–330,332–333,335–339,341,343–345,
349–350,352–354,358–363,365,367. These include every numbered Figure12-1
through12-19 and Table12-1 through12-6, the derivative structure, and complete
UDP/resistor/sampler/startup examples. Other pages were text-reviewed, not
independently visually certified. No graphics were regenerated or substituted.

## Corrections prepared

| ID | Anchor/source | Repair and boundary |
|---|---|---|
|VPI12-TEXT-001|s12-33-2 / printed352|PDF literally prints `&amp;` and `-&gt;` in its C sample. HTML decoded them into C punctuation. Restore literal source spelling using double escaping; add explicitly editorial warning about this and the missing initializer comma/array semicolon.|
|VPI12-NOTE-001|s12-6 / printed312,340–342|Explain inconsistent callback struct layouts: Figure12-2 omits index, Figure12-17 includes it and12.31.1 requires it. Preserve both listings.|
|VPI12-NOTE-002|s12-22-2 / printed330–332|Warn that literal resistor example is not compilable/correct C; do not normalize source defects into presumed normative behavior.|
|VPI12-NOTE-003|s12-32-3 / printed347–349|Warn about unallocated sampler, pointer/member/name defects and failure to assign held value; runtime oracle must be independently derived.|
|VPI12-NOTE-004|s12-36 / printed354|Preserve introductory 'three' and all six operations, explicitly explain count mismatch so analog operations are not dropped.|

The remaining source prose and source-code defects listed below were retained.
This review did not find another definite missing normative paragraph in the
HTML; this does not certify all styling, glyphs, cross-links or source errata.

## Source anomalies requiring explicit resolution before test oracles

| Source | Observed anomaly / required interpretation work |
|---|---|
|12.5 p312|NULL vpiTimeUnit/vpiTimePrecision returns simulation time unit; compare11.6.1's smallest precision wording.|
|12.7–12.9 p313–314|Return descriptions include stray success/failureDescription text; frequency table says elapsed time. Use routine-specific body, record discrepancy.|
|12.10 p314–315|Argument type p_vpi_value conflicts with s_vpi_analog_value body/figure; Table12-2 says vpExpStrVal but body/figure vpiExpStrVal.|
|12.11 p316–317;12.29 p337|Prose calls allocated array s_vpi_delay although da points to s_vpi_time; examples use pointer-to-array, and get-delays has `prim;t2` and missing comma.|
|12.13 p319;12.32 p345–346|Analog/digital structure names, tag spellings and task/function constants differ across prose and figures; resolve ABI names, do not compile literal examples as acceptance oracle.|
|12.16 p321–325|vpiObjTypeVal versus Table12-4 vpiObjectVal, scalar/strength result constant spellings; UDP byte/half-byte and abit/bbit description conflicts with usual field names and example decoding. The same printed input table has differing example outputs. Prefix-name prose but strcmp exact-match code.|
|12.19 p328|Driven-primitive example switches on primitive types after obtaining a load terminal; needs independent object-graph oracle.|
|12.22.1 p329–330|Argument2 is derivative target, but following example prose calls it returned value despite argHandle2.12.32.2 distinguishes return index0 from argument indices1+.|
|12.22.2 p330–332|Uninitialized v_handle, wrong existence guard, out-of-scope r_handle, undeclared t_vpi_stf_partials typedef usage, derivative_to versus derivative_wrt, differing task constant and callback signatures.|
|12.24/12.26/12.27 p333–335|First two call log descriptor3;12.27 assigns channel3 bitmask4. Keep channel number distinct from mask and resolve wording.|
|12.31 p340|Introduces three categories but12.31.3 adds analog callbacks; missing category in overview is not permission to omit analog reasons.|
|12.32.2 p346|vpi_handl_multi typo; declaration tag/typedef names vary.|
|12.32.3 p347–349|Sampler lacks allocated data at first use, periodHandle member, appropriate pointer accesses, consistent routine/time constants, held-value update; final registration uses digital structure with extra derivative field.|
|12.33 p350–352|Figure type comments differ from prose constants; startup array called a C function; sample literal entities and missing punctuation preserved with note.|
|12.36 p354|Three/six operation mismatch; inherited reset and local stop/finish cross-references need edition-aware resolution, not guessed renumbering.|

## Executable evidence repair

Separate `tests/vpi_app.c` patch based on root SHA256
`f38cde9e40ee58ee4e9ae4f13b5b63ea0a1b63ae5b301a913720a4487acb09fb`:

- `VPI-LINE-INSTANCE`: §11.6.1/12.5, location property constant6 from
  IEEE1364-2005 AnnexG. Use the u1 instance at design line38, not the definition
  at48 or an ambiguous top-level use site. Expected38 and no error.
- `VPI-INDEX-VALID-BIT`: §11.6.8 NOTE1/12.20; bus declared[0:3], so index0
  requires a nonNULL/no-error handle. This is only availability, not all bit
  properties or all index cases.
- `VPI-PORT-EMPTY-RELATION`: §11.6.8/12.23; vpiPort low-connection relation
  from internal mid is valid but empty. Child high-connections are vpiPortInst,
  not parent low-connections. ExpectedNULL/no-error, not invalid-request error.

Each is a named XFAIL with XPASS exit1. Former return/error assertions remain
as implementation regression guards in the expected-limitation branch, rather
than successful conformance-negative tests. Unexpected intermediate results
hard-fail. Other invalid requests and foreign-handle robustness remain intact.
No production implementation or build graph changed. C99 Wall/Werror syntax
check passes (Nix compiler wrapper needs Wno-unused-command-line-argument for
syntax-only). Parent must run linked test; this agent did not run a full build.

## Fixture evidence withdrawal and open obligations

Numbered Chapter12 HDL fixtures previously credited unknown-function rejection
or unobserved system callbacks as12.* evidence. Their machine tags are removed;
source cross-references, executable HDL and all other directives remain. The
retained sequencing/parameter assertions cannot distinguish a real registered
callback from a dropped/stubbed call. No rejection expectation was changed.

`tests/fixtures/ch12_vpi_routines/COVERAGE.md` now records explicit groups from
VPI12-ARGS through VPI12-CONTROL covering every routine section. Each still
needs atomic expansion, applicable positive/negative/boundary cases and actual
recorded C-host execution. P03 decks/plugins and expected transcripts remain
draft host tests; compile-only build integration is not their execution.
Existing startup-linked hierarchy evidence does not close simulation timing,
dynamic registration or the entirety of12.33.2. No conformance measure computed.

P03 source review is not complete here: notably the derivative fixture's header
claims numerical differences cannot reproduce exact derivative12, which is not
a reliable discriminator by itself; direct readback of a plugin-written
derivative also does not alone prove the solver consumed it. A perturbation or
instrumented Jacobian oracle is needed. Absent host execution remains open.
