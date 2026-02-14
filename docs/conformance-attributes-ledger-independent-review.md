# Independent review: AMS attribute rule candidate

Review date: 2026-09-23. This is a source/oracle review, not an execution report or completeness certification. No compiler, fixture, shared ledger, or root-checkout file was changed. No builds or conformance gates were run.

## Reviewed boundary and provenance

Read complete AMS §2.9–§2.9.2 extracted text (printed 19–23, physical 32–36), including Syntax 2-4 through 2-10. Independently rendered and viewed physical page 36, including the standard-attribute paragraph and final UDP productions; this review does **not** independently certify typography on physical pages 32–35. Read identifier dependencies §2.8–§2.8.2, A.9.1, A.9.3, A.10 identifier detail, Annex B introduction/keyword table; consumer dependencies §3.2.1 and §3.4.3; profile dependencies C.3–C.8 and C.16. No complete transitive Annex A grammar review is claimed.

Root snapshots reviewed:

| File | SHA-256 |
| --- | --- |
| `docs/rules/ams-attributes.json` | `7ba522972063aefe4f71fc1d036ef9041b26c4ccdd66f5ff51a3da4396a2eb50` |
| `docs/conformance-ams-attributes-review.md` | `c97d1fe9022cb77fc554753076775665afff67404d721fa9dbb4273ec7d559d0` |
| `docs/ch2-lexical.html` | `18895b02032089133182fda149c0f3dae000973bcebc621fd207d718f71a5597` |

The rule-list review used complete compact projections of IDs, obligations, proposed expected results, mutations, analog applicability, and HTML anchors; selected full records were inspected for name, reporting, and consumer questions. This is not a claim that every serialized evidence field was independently authenticated. The existing report was read in full. The candidate correctly retains open status and citation-only fixture evidence rather than asserting production behavior.

## Required corrections before independent completeness approval

### ATTR-IR-01: an oracle's mutation must actually fail that oracle

`AMS-ATTR-MULT-NONE` and `AMS-ATTR-MULT-ABSENT` expect raw 12, yet propose “always report raw12” as a wrong implementation. That implementation passes these cases correctly. Replace with erroneous multiply (24) and divide (6) behavior at effective `$mfactor=2`; retain raw-12 as the mutant for MULTIPLY and DIVIDE. A four-policy comparison helps, but does not make an individual nondiscriminator discriminating. Check the stored variable remains 12 separately from report output.

NONEMPTY, CONSTANT, NO-NEST, NO-MIDDECL, DESC-STRING, UNITS-STRING, OP-REQUIRED, OP-DOMAIN and MULT-DOMAIN reuse metadata-discard/wrong-owner mutations for diagnostic cases. Rejection cannot observe that mutation. Each invalid case needs its actual accept-invalid mutant; each legal neighbor needs reject-legal and, only if independently observable, wrong-value/owner mutants. Do not require one generic metadata consumer to prove a pure syntax rejection.

### ATTR-IR-02: output-variable access is not optional help

§3.2.1 (printed 25, physical 38) requires simulator access to values of module-scope variables carrying desc, units, or both. It also requires ignoring desc/units on block-level variables. §3.4.3 (printed 30, physical 43) makes help generation optional for parameters and requires ignoring block-level parameter metadata. These are different objects and consumers.

Add an explicit dependency boundary from DESC-HELP/UNITS-DOC to §3.2.1, with separate pending obligations for desc-only, units-only, both, and block-level variable controls. Either enumerate these as dependency rows with direct traces to `docs/ch3-datatypes.html#s3-2-1`, or explicitly assign them to a future data-type ledger. Do not silently expand the §2.9 denominator. Preserve `#s3-4-3` for parameter-only documentary semantics. Lack of help UI does not excuse missing required output-variable access. Conversely, the illustrative SPICE display is not a mandatory exact report format or proof every simulator must implement that UI.

### ATTR-IR-03: absent op has a source-derived conditional interpretation

Physical page 36 states the exclusion condition is that op **is specified with value no**, then says otherwise the parameter or variable is included. The natural conditional reading includes absence, not just explicit yes. Syntax 2-4 permits zero attribute instances on a declaration; its omitted-value rule concerns a *present attr_spec without an assignment*, not an absent attribute. Neither bare `(* op *)` (default 1, outside the standard yes/no domain) nor parser representation settles absent-op behavior.

Recommend a proposed behavioral obligation: in an actually requested short operating-point report, a module-scope output variable established independently with desc or units and with no op is included. Compare otherwise identical explicit yes and no controls, using distinct names and values. This limits the test to an independently reportable object rather than inferring exposure of every undeclared/internal value. A remaining report-eligibility boundary should be named separately; labeling the whole absent-op conditional unknowable is unnecessarily weak. This is source interpretation, not an observed host capability, and must remain open until an actual report consumer executes it.

### ATTR-IR-04: separate identifier grammar from standard units exception

Syntax 2-4 and A.9.1 say `attr_name ::= identifier`; A.9.3 splits identifier into simple and escaped forms. Annex B reserves `units`, while §2.9.2 explicitly standardizes the units attribute and illustrates its unescaped spelling. By contrast, A.9.3's **nature_attribute_identifier** explicitly lists `units | identifier`; that different production cannot be imported into attr_name.

The source therefore supports legal standard `units` spelling, but exposes a grammar/keyword-reservation tension. Document that narrowly; it neither authorizes arbitrary keywords as attr_name nor makes the standard example illegal. Split unambiguous simple/escaped identifier obligations from this editorial inconsistency instead of classifying all attribute names as ambiguous. Test ordinary simple name, escaped punctuation name, and escaped keyword name independently; test standard unescaped units as its own specified case. Do not derive a negative for every other keyword without resolving its actual owning grammar. No implementation token enum is normative evidence for this decision.

## Atomicity and coverage boundaries

The syntax-arm enumeration usefully distinguishes declaration and connection owners, but most cases still combine parse acceptance with metadata ownership. Acceptance does not prove retained/default/last-wins metadata. Keep owner observation and ordinary construct execution separate in the eventual cases; a constant arithmetic result is not a metadata oracle. Generic user-defined attributes have tool-dependent meaning, so a mandatory consumer observation needs its own API/host contract rather than a blanket requirement that every tool expose all attributes.

Grammar repetition boundaries remain pending: zero, one, multiple adjacent attribute instances; one versus several comma-separated specs; duplicate names within one instance and across instances; same names on different owners; first versus subsequent function ports; UDP declaration attributes versus UDP output/input/register attributes. Existing LAST and COMMA-LIST intentions are appropriate but prose intentions are not executable witnesses. Existing report already records most of this; it should not be marked resolved by this review.

DESC-STRING's legal neighbor currently mentions parameters/variables but not the net declaration explicitly included by §2.9.2. Add a distinct net-owner case or an explicit residual. Similarly, retain parameter/variable owner separation for op and multiplicity instead of using one real variable to silently close both alternatives.

Annex C.3 includes the lexical rules in both profiles, subject to legal enclosing constructs. The digital-only initial/always/UDP exclusions are source-based, not fixture-based. Unresolved inherited reg/time/realtime/task/function reachability is conservative; do not resolve it from compiler acceptance. The common profile text for port rows must retain C.8's real-value-port exclusion when cases are instantiated. Generic attribute applicability does not legalize every type alternative of its enclosing production.

The Chapter 2 HTML anchors exist and are appropriate direct locations for §2.9, §2.9.1 and §2.9.2. An anchor is a trace, not proof of all dependent grammar or source typography. The report's acknowledged Syntax 2-4..10 literal/metasyntax styling gap remains pending; this review did not repair it.

## Disposition

Independent completeness approval remains pending the concrete oracle repairs, explicit consumer dependencies, and boundary decomposition above. No fixture execution, host report output, mutation run, conformance measure, or new closed rule is claimed. Measures A/C are unchanged by this report; it contributes source and evidence-quality review only.

Root follow-up: main read this entire report and the2.9.2 exclusion/otherwise
source paragraph. The absent-op case now uses the bounded conditional on an
independently eligible output variable, remaining open and unexecuted. Diagnostic
case mutants now describe accepting the invalid form instead of generic metadata
loss. The missing net-owner case is explicit; none/absent scaling mutants and
3.2.1 dependency corrections were already integrated. Name-grammar splitting,
consumer cases and completeness review remain pending.
