# AMS lexical core candidate rule ledger

Reviewed2026-09-23. New ledger: `rules/ams-lexical-core.json`. Scope is complete
source text of2.2–2.4 and2.8–2.8.2, not the whole Chapter2. Original PDF
printed11/17 (physical24/30) was read and visually inspected, including Syntax2-1.
Source SHA256 `e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
Read corresponding root HTML sections (SHA256
`57f908645c240926e1a0a4181648817bb890188dc7ee36b242019456a5adb64f`);
no missing prose or syntax production found in these bounded sections. Every
row records an exact HTML anchor; no HTML modifications made.

## Applicability and decomposition

AnnexC.3 printed389–390 was independently read. It makes Clause2 applicable to
both profiles, with exceptions about numerical X/Z context and keyword use.
These do not exclude whitespace, comment or identifier spelling rules. Keyword
reservation is distinct from permission to use every keyword's language construct.
The ledger therefore marks these spelling rules applicable to both profiles,
not based on which runner happens to execute the evidence.

The generated candidate contains41 rows (counted from the JSON array), covering
token layout/categories, each whitespace character, string space/tab retention,
comment delimiters/nonnesting/content, identifier characters/initial-position/
case/length policy, escaped terminators/content/identity and keyword spelling.
Each separates source class, precondition, invalid-input disposition, oracle,
proposed wrong implementation, HTML trace and evidence limitations. These are
candidate atomic obligations, not a certified denominator. Category inventories
remain structural rows; detailed AnnexA/B grammar and every keyword are not
silently claimed enumerated. The free-format and whitespace rows overlap in
source motivation; independent atomicity/deduplication review is still pending.

Existing fixtures were source-inspected, not rerun; their ledger entries say
not-run/citation. No historical passing result is inferred from fixture presence.
The source expressly requires an error over an implementation-specified identifier
limit, but permits limits larger than1024; no arbitrary1025 rejection is invented.
The actual finite implementation limit remains unidentified. Other malformed
syntax rows leave diagnostic authority/severity unresolved rather than deriving
it from today's compiler code. Nonnesting means the first closer wins, not that
the second opener automatically requires a nested-comment diagnostic.

## New independently derived behavioral cases

All run with current root `zig-out/bin/vera --run` from the worker directory.
CLI SHA256 `0439a27f71562b347f5be260d01e378677ed102d46dee2fc0845df39acb73a51`.
These digital observations cannot establish analog runtime coverage merely
because the lexical rule applies to both profiles.

| Fixture under tests/fixtures/digital | Source/oracle | Actual |
|---|---|---|
|audit_ams_lexical_long_distinct|2.8: two1024-character names differ only at character1024; separately assigned3/7 must remain distinct.|exit0;3 7|
|audit_ams_lexical_escaped_terminators|2.8.1: space,tab,newline,formfeed terminate escaped names and are excluded from identity; four distinct assignments/readbacks.|exit0;1 2 3 4|
|audit_ams_lexical_escaped_ascii|2.8.1: one name contains all printableASCII33..126 in order; set9/read9.|exit1;E1100 undeclared digital variable at assignment; legal expected9 retained|

The escaped ASCII program contains literal punctuation, including backslash,
grave accent and period, within its name. The whitespace terminator is present;
this is not a missing-terminator rejection test. The failure does not identify
which punctuation/context triggers the implementation defect. Per-character
isolation, combinations and symbol-resolution-path analysis remain future work.
No XFAIL or implementation repair is introduced here.

Important existing-oracle limitation: `28_identifier_1024_chars.va` claims a
single long identifier catches prefix truncation. Consistently truncating its
declaration and references could still pass that single-object test. Its expected
value is not wrong and was not changed; the new two-name case supplies the
missing alias discriminator under AMS-LEX-ID-LIMIT-MIN.

## Explicit remaining boundaries

No full Chapter2 review, system-name/directive grammar, attribute rule, number
rule, complete string rule or macro-substitution closure is claimed. General
scope uniqueness and duplicate declarations require Clause6 dependencies.
Comment character coverage, EOF without newline, unterminated comments,
escaped empty names and nonprintable bytes require further AnnexA and diagnostic
decomposition. Existing `12_unclosed_comment.va` was inspected but is not
misrepresented as a newly executed negative. The nonnesting negative's legal
neighbor still needs a dedicated observation. A failed legal ASCII case and all
unexecuted boundaries remain open; executed rows are at most partial.

Ledger validator exit0 means schema consistency only. No durable complete
source/fixture/runner/output bundle was archived, no mutation was executed, and
no row is marked verified. No full suite/build, compiler changes, A/C measurement
or denominator certification was performed.
