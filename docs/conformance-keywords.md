# Reserved-keyword audit

Read Annex B's PDF text, both rendered Table B.1 pages (physical pages 400–401)
and the complete HTML on 2026-09-23. The corrected PDF and HTML spelling sets
match (`python3 tools/lrm_keywords.py`). The PDF prints `negedgenmos` together;
the HTML explicitly documents splitting it into `negedge` and `nmos`, whose
grammar uses are separately specified. Table column reflow changes no membership.
This audit does not silently add keywords from another language edition.

## Evidence groups

| ID | Source / obligation | Evidence and remaining scope |
|---|---|---|
| KEY-001 | B, Table B.1: every listed unescaped lowercase spelling is reserved | Existing grouped rejection census in `annex_b_keywords` and the Annex C fixtures. Its diagnostic-substring matching and parser recovery need independent per-keyword mutation checks; a citation or a comment is not proof that each declaration caused its own error. |
| KEY-002 | B, 2.8.1, 2.8.2: escaped spellings are identifiers, not keywords | New `audit_all_escaped_keywords.va` declares, assigns and observes every corrected Table B.1 spelling as an escaped real variable. Assignments precede observations, distinguishing accidental aliasing. Module/parameter/port/function/branch/discipline/nature/block-label/instance positions remain separate obligations. |
| KEY-003 | 2.8.2: keywords are lowercase only | New `audit_all_case_keywords.va` uses every table spelling in all-uppercase and initial-uppercase form, with distinct stored values for each. This is not every possible mixed-case permutation or every identifier context. |
| KEY-004 | 2.8.1: escape syntax does not change the identifier's identity | Existing `01_escaped_keyword.va` observes plain `total` after declaring escaped `total`; all whitespace terminators and hierarchy contexts still need review. |
| KEY-005 | Annex C.16: keywords unused by the analog subset remain reserved | Retain the AMS spellings in the analog-profile census. Their lack of analog implementation is not permission to use them as unescaped identifiers. |
| KEY-006 | A keyword's language construct has its specified behavior | Separate chapter obligations. Identifier tests cannot establish implementation of a construct. |

The generator reads the PDF inventory and checks the HTML set; it does not read
the compiler's token table. Expected values are distinct one-based enumeration
indices, exactly representable as the fixture's real literals. Regenerate source
with `python3 tools/lrm_keywords.py --fixture escaped` or `--fixture case`, and
check drift with `--check-fixtures`. These are behavioral positive tests, not
merely declarations that happen to compile. Actual execution results are recorded
below after the targeted run; no exhaustive full-language claim follows.

Both fixtures pass the targeted strict runner on 2026-09-23. They declare exact
runtime observation counts with `//! checks`: one observation per escaped
spelling and two per case-variant spelling, at the single default operating
point. The harness now refuses a missing or duplicated observation count rather
than accepting any nonempty subset. Unit tests exercise both mismatches. Counts
alone still cannot detect one omitted check replaced by a duplicate of another;
per-rule transcript identity and mutation testing remain additional evidence.

## KEY-MACRO-001: inherited-source review and regression

The first escaped-name test placed an escaped identifier directly in a macro
argument: `` `CHECKX("escaped above", \above , 1.0) ``. VerA reported E0207
after expansion. Inspection shows macro actual arguments are whitespace-trimmed
in `lib/frontend/preprocessor.zig`; replacing `GOT` in the macro's `(GOT)` loses
the escaped identifier's terminating whitespace. The declarations and ordinary
assignments are not what that failure diagnoses.

The spelling test now reads into a plain temporary before invoking its assertion
macro, so this interaction cannot mask the keyword checks. The macro-whitespace
claim moves to **KEY-MACRO-001**, not to a claim of implementation or a blanket
rejection expectation. After receiving `1364-2005.pdf`, IEEE §19.3.1 (physical
pages 380–382) was read in full: actual expressions are substituted literally
and in their entirety. IEEE §3.7.1 (physical page 44), also VAMS §2.8.1,
requires whitespace to terminate an escaped identifier. Trimming it so a
replacement body's closing parenthesis becomes part of the identifier changes
the expression, not merely its formatting.

`ch10_directives/audit_macro_escaped_actual.va` now isolates that interaction
with a parenthesizing identity macro and a simple-identifier control. Its
assertions use plain temporaries so the assertion helper cannot mask the
target. It remains a positive expectation with an XFAIL marker naming this
limitation; there is no rejection expectation and no compiler fix in this audit.
The marker must be removed only as part of implementing and verifying the
behavior: XPASS is a failure in the strict runner.
