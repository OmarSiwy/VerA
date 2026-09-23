# Inherited IEEE 1364-2005 source audit

Status: source obtained; rule enumeration and behavioral audit **in progress**.
Acquisition does not close measure B, and B's historical §§17–18 inventory does
not exhaust the inherited standard.

## Provenance and reproduction

On 2026-09-23 the user supplied `/home/omare/Downloads/1364-2005.pdf` and asked
that it be moved to `docs/1364-2005.pdf`. The move completed without overwriting
an existing destination. The original Downloads path is no longer the working
copy. `pdfinfo` identifies IEEE Std 1364-2005, revision of 1364-2001; the title
page gives publication date 7 April 2006. That publication date does not make
this a different language edition.

- File size from `pdfinfo`: 6512924 bytes; 590 physical pages; unencrypted PDF.
- SHA256 from `sha256sum`:
  `3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
- Local extraction: `pdftotext -layout docs/1364-2005.pdf /tmp/vera-ieee-1364-2005.txt`.
- Printed Arabic page 1 begins on physical PDF page 31. Body page anchors use
  printed page plus 30; front matter uses its own numbering. Confirm an anchor
  against its body heading before attaching evidence to it.

The supplied copy carries a restricted institutional-use notice. It is a local
audit reference, explicitly ignored by Git; neither the PDF nor a full-text
extraction is to be committed or bundled in releases by this audit. Future
reviewers need their own authorized copy. A different licensed copy may have a
different hash or wrapper pagination: verify edition and anchors rather than
silently replacing this provenance record. Repository documentation records
paraphrased obligations and clause citations, not a republication of the book.

## Authority and applicability

VAMS-2023 §1.1 incorporates the complete IEEE 1364-2005 specification plus its
analog/mixed-signal extensions. Every inherited area therefore needs an explicit
disposition; absence from the AMS HTML's expanded prose is not an exclusion.
Record the base rule, AMS modification and analog-profile exception separately.
Do not treat identically numbered clauses in the two standards as the same rule.

IEEE §1.5 distinguishes normative clauses and Annexes A/B/G from informative
Annexes C/D/H/I. §§1.5–1.6 also identify removed, deprecated TF/ACC material
(Clauses 21–25, Annexes E/F), referring readers to the 2001 edition. Record that
dependency and resolve whether any applicable AMS obligation requires it;
do not invent the removed text or silently substitute SystemVerilog.
The 2001 source is not currently supplied. IEEE §2's other normative references
also require a dependency disposition where an applicable rule uses them.

IEEE §1.2's distinction between a tool implementor and a model author matters:
permission for the author to use a language feature is not, by itself, permission
for an implementation to omit that feature. §1.8 makes examples informative;
extract rules from the associated normative syntax/semantics, not every example
as an independent obligation. §1.3's BNF typography needs visual review.

## Work areas, not a completeness denominator

| IEEE area | AMS relationship / audit work |
|---|---|
| §§1–2 | Authority, BNF conventions, dependencies, normative/informative distinctions. |
| §§3–5 | Lexical rules, four-state types and expressions; reconcile AMS §§2–4 and Annex C. |
| §§6–10 | Assignments, primitive/UDP modeling, behavioral statements and tasks/functions; separate digital from analog-context extensions. |
| §11 | Digital event scheduling; reconcile AMS §8 and mixed-signal synchronization. Kernel-only tests do not prove production scheduling. |
| §§12–13 | Hierarchy, elaboration, generate constructs, configurations and libraries; account for AMS §6 extensions. |
| §§14–16 | Specify blocks, timing checks and SDF. Keep in the full AMS scope even where analog-only fixtures cannot exercise them. |
| §17 | System tasks/functions; refine historical `CLAUSE-AUDIT.md` rows against source, including arguments, error cases, output bytes and event-region effects. |
| §18 | VCD controls and file formats; validate actual artifacts, not merely accepted task names. |
| §19 | Preprocessor/directives; reconcile AMS §10, keyword versions, includes and source-location state. |
| §20, §§26–27, Annex G | PLI/VPI binding, object models, routines and headers; reconcile AMS §§11–12. Host and C ABI evidence is necessary. |
| §§21–25, Annexes E/F | Deprecated/removed text: explicit dependency/applicability decision pending, not silently scored closed. |
| §28 | Protected source regions and encryption semantics; separate mandatory rules from optional mechanisms using the actual clauses. |
| Annexes A/B | Normative grammar and keyword inventory; reconcile AMS additions and keyword-version directives. |
| Annexes C/D/H/I | Informative material, not standalone mandatory feature requirements; follow normative cross-references where present. |

## Read log

| Scope | Review performed on 2026-09-23 | Evidence status |
|---|---|---|
| Title/copyright and metadata | Edition, publication date, license notice and hash checked. | Source acquired only; no behavioral credit. |
| §4.10 introduction and §§4.10.1–4.10.2, printed pages 35–37 (physical 65–67) | Complete extracted text read, including header/body locality, parameter type/range inference and non-real selections. Syntax 4-4 typography still needs visual review. | PAR-020/021 in the parameter ledger separate inherited requirements; PARAM-HEADER-001 records illegal body override acceptance. §4.10.3 is not included. |
| §12.2.2 introduction and complete §12.2.2.1, printed pages 170–171 (physical 200–201) | Read ordered/named separation, nested-scope restrictions, ordered binding and explicit exclusion of locals from positions. | Supports the ordered-localparam fixture; other instance-binding cases remain open. Adjacent §12.2.1 and §12.2.2.2 were only partially read. |
| §1, physical pages 31–35 | Complete extracted text read, including conventions, deprecation and header-file status. | Source scoping recorded above; BNF visual review remains open. |
| §17 introduction and opening §17.1.1, physical pages 307–308 | Initial read of task families, display/write differences and null arguments. | Partial source review, not a closed rule group. Tables and remaining subclauses pending. |
| §19 introduction and §§19.1–19.3.2, physical pages 379–382 | Complete extracted text read: directive scope, cell/default-net state, macro definition/use and undefinition. | Macro escaped-actual gap isolated as KEY-MACRO-001; remaining atomic rules and fixture mapping pending. |
| §§19.3–19.3.2, follow-up | Source reread against directive fixtures and preprocessor behavior. | `conformance-macros.md` records partial rule mapping and MAC-RESET-001, plus added positive and isolated negative cases. No complete Clause 19 claim. |
| §3.7.1, physical page 44 | Complete extracted text read for escaped-identifier termination. | Supports KEY-MACRO-001 alongside §19.3.1; not a complete lexical audit. |
| §9.2.2, printed pages 120–122 (physical 150–152) | Read the later NBA discussion and examples, including ordered updates and assignments without cancellation. Earlier syntax/introductory material was only partially reviewed. | Prevents generalizing the AMS §8.4.4 glitch example into a universal NBA-cancellation rule; reconciliation remains open in `conformance-scheduling.md`. |
| §9.2.2, follow-up, printed pages 118–122 (physical 148–152) | Completed the earlier syntax and introductory extracted-text read; the full subclause text has now been read. Syntax 9-2 on physical page 149 was visually checked, including delimiters, alternatives, optional/repeated forms and keyword terminals. | Added passing queued-update and failing indexed-target positive transcripts; NBA-TARGET-001 and the partial rule mapping are recorded in `conformance-scheduling.md`. |
| §11.6.5, printed pages 161–162 (physical 191–192) | Complete extracted switch-processing text read. | Supplies the x value omitted from the final AMS §8.5.3.5 sentence. No switch-network runtime closure claimed. |
| §§11.1–11.6.7, printed pages 158–162 (physical 188–192), follow-up | Read the remaining scheduling text, including event regions, permitted nondeterminism, guaranteed NBA ordering, continuous-assignment initialization, port connections and task/function argument transfer. | Same-time NBA intermediate-update fixture passes; strobe callback-order overconstraint withdrawn. Source review does not close continuous assignment, port or argument-transfer obligations. |
| §17.1.2, printed pages 285–286 (physical 315–316) | Complete extracted strobed-monitoring subsection read. | Supports end-of-step sampling, not a FIFO callback claim. Corrected `d09_03_strobe_scheduling.v` retains independent multiplicity/value checks; STROBE-ORDER-001 records the withdrawn claim. |
| §17.1.3, printed page 286 (physical 316) | Complete extracted continuous-monitoring subsection read. | Display-list replacement, coalescing, time-function exceptions and monitor enable/disable behavior remain to be mapped to independent fixtures. No closure claimed. |
| §17.1.3, follow-up | Reread against the digital monitor executor and existing combined fixture, keeping AMS 9.4.1's analog rule separate. | `conformance-monitor.md` records four newly exposed failures and corrects the older digital verification claims in historical rows 17.1-12/13. Rule enumeration and invalid-input coverage remain incomplete. |

Syntax 4-4 was subsequently visually checked on physical page 66: keyword
terminals, optional signed/range forms, repeated comma-separated assignments,
literal assignment and range delimiters are distinct in the source. The
header/body-locality paragraph was also checked directly on that rendering.

All unlisted source portions remain pending full review. Searching a reference,
reading a table of contents or extracting all text does not constitute reading
the standard. The AMS HTML fidelity audit remains against the AMS PDF; inherited
IEEE obligations need this separate source namespace and must not inflate the
AMS clause-citation denominator.

Follow-up, 2026-09-23: complete extracted §17.1.1.3 (printed pages 281–282,
physical pages 311–312) read for automatic expression field sizing, decimal
spaces, radix zero filling and the explicit zero override. FMT-WIDTH-001 in
`conformance-display.md` records the failing positive evidence and removal of
deviation-based expectations from the argument-run fixture. The adjacent
unknown/high-impedance subsection was only partially read here, not closed.

## Reproducible navigation worklist

`python3 tools/ieee1364_audit.py` extracts the contents entries, attaches
`IEEE1364-2005:` identifiers, classifies normative/informative/deprecated areas,
and checks that each heading identifier occurs on its expected body page.
`--json` includes both the contents page and verified body-page anchor. Only
heading metadata is emitted; source body text is not copied into the repository.
The pinned hash prevents a different edition or PDF wrapper from silently
reusing these page anchors. Absence of the licensed PDF is reported as a missing
input, not as zero outstanding inherited requirements.

The first run identified a contents error: §14.2.1 is listed on printed page
212, but the body heading occurs on 213 (physical page 243). Pages 242–244 were
read to establish that correction; the tool explicitly records it and retains
the original contents page. This review only located the heading, not verified
its module-path requirements or all of Chapter 14.

Synthetic regression tests in `tools/test_lrm_ieee1364.py` run without the
licensed PDF, so CI need not distribute it. The worklist is a navigation aid:
it neither inventories every atomic rule nor populates behavioral verdicts.

Equality follow-up, 2026-09-23: complete extracted §5.1.8, printed page 49
(physical page 79), read in response to AMS §7.3.2's explicit reference.
The comparison rules distinguish known case-equality outcomes from ambiguous
logical-equality outcomes, and prescribe operand extension/conversion.
Table 5-11 received text review only. EXPR-XZ-001 in the expression ledger
records the conflicting AMS example annotation; this reading adds no verified
runtime row or inherited-obligation closure to measure B.

Reduction follow-up, 2026-09-23: complete extracted §5.1.11, printed pages
51–52 (physical pages 81–82), read including Tables 5-17–20. This is text
review, not visual certification. It specifies bit-folding to one-bit results
and inversion for the complemented reductions. The expression ledger maps
existing digital known/unknown observations separately from the AMS analog
ban; neither matrix is exhaustive, and no measure B closure is claimed.

Conversion follow-up, 2026-09-23: main read complete extracted §17.8,
printed pages 310–311 (physical pages 340–341), including the port-transport
example. The parallel Chapter 9 review independently read the same source.
This is text review, not visual certification. Constant-expression permission,
truncation versus ordinary rounding and sized representation evidence are
tracked in `conformance-ch9-review.md`. The new constant-default XFAIL leaves
an explicit inherited obligation open; successful runtime cases do not close
the whole conversion family or measure B.
