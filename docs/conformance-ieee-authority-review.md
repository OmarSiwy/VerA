# IEEE source authority and dependency disposition

Main-agent review, 2026-09-23. Read complete IEEE 1364-2005 Clauses1–2,
printed pages1–7, physical pages31–37, from the supplied PDF text extraction.
Source SHA256: `3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
This is text review, not a complete visual verification or atomic closure.

## Authority rules

| ID / source | Disposition for this audit |
|---|---|
| AUTH-001 / 1.1 | Scope includes syntax, semantics, scheduling tasks, directives and PLI/VPI; compiler acceptance cannot substitute for the full scope. AMS inheritance and the separate analog-only profile must still be recorded for individual obligations. |
| AUTH-002 / 1.2 | Mandatory input constraints require enforcement and errors. A model-author option is not automatically an implementation option: permitted source features retain their specified semantics when used. Do not classify every occurrence of “may” as optional implementation support. |
| AUTH-003 / 1.3 | BNF font distinctions separate literal punctuation from metasyntax. Repetition is zero-or-more in left-to-right order; italic category prefixes carry semantic qualifications. Plain-text token equality cannot certify grammar fidelity. |
| AUTH-004 / 1.4 | Color is nonessential; typography that distinguishes grammar notation remains important. A visual check is still needed where extraction loses those distinctions. |
| AUTH-005 / 1.5–1.6 | Annexes A/B/G are normative. C/D/H/I are informative. Deprecated Clauses21–25 and AnnexesE/F retain headings, with their text removed and referred to the 2001 edition. Do not invent requirements from the empty headings or automatically treat historical APIs as audited. |
| AUTH-006 / 1.7 | AnnexG's declarations, constants and structures are the normative header reference. A local header compiling a selected probe does not prove complete API/ABI agreement. |
| AUTH-007 / 1.8 | Examples are informative and do not define full syntax. Expected fixture behavior must be derived from governing rules, not merely copied from an example. |
| AUTH-008 / 1.9 | C familiarity is a prerequisite for PLI/VPI chapters, not an exemption from their obligations. |
| AUTH-009 / 2 | Dated external references use the cited edition; undated references require edition resolution. Missing referenced texts remain verification gaps, not implicit exclusions. |

## Referenced-source inventory

Clause2 identifies the following dependencies. This inventory records source
presence in the clause, not a claim that every dependency creates an
unconditional implementation feature. Link each use to its governing rule,
especially the mandatory/optional algorithm distinctions in Clause28.

| Dependency group | Editions identified by Clause2 | Verification boundary |
|---|---|---|
| Floating point | IEEE754-1985 | Exact inherited numeric requirements need the cited source; modern hardware behavior alone is not a source verification. |
| Operating-system interface | IEEE1003.1, undated | Applicable edition and specific call/format dependencies remain to be resolved. |
| Historical Verilog | IEEE1364-2001 | Referenced for deprecated TF/ACC text. Its source has not been supplied or reviewed here. Historical support requirements must be reconciled with AMS and Clause20, not inferred from headings. |
| Encryption standards | ANSI X9.52-1998; FIPS46-3 October1999; FIPS197 November2001 | Algorithm and encoding source verification remains separate from source-envelope parsing. |
| Hash standards | FIPS180-2 August2002; ISO/IEC10118-3:2004 | Clause28 applicability and exact algorithm contracts remain required. |
| IETF documents | RFC1319 April1992; RFC1321 April1992; RFC2045 November1996; RFC2144 May1997; RFC2437 October1998; RFC2440 November1998 | Do not substitute later protocol/algorithm revisions without source authority. |
| Algorithm publications | Serpent proposal1998; ElGamal1985; Blowfish1994; Twofish first edition1999 | Source acquisition and algorithm-specific obligations remain open where applicable. |

IEEE1497-2001 is **not listed in Clause2**. Clause16 refers to it as
bibliography item B1, which appears in informative AnnexI. The SDF review
correctly records an unresolved external source dependency, but that must not
be misstated as a Clause2 normative-reference entry. The required SDF scope
still needs reconciliation with Clause16 and the task-specific rules; this
distinction does not justify dropping SDF behavior from the audit.

## Remaining work

Visually verify the reviewed pages, reconcile all AMS authority/profile rules,
map external dependencies to individual obligations, and review the content of
informative annexes for explicit dispositions. No fixture pass, percentage,
or complete dependency closure is asserted by this report.
