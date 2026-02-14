# Lexical identity discriminator follow-up

Reviewed2026-09-23 after reading the complete independent review at
`conformance-lexical-ledger-independent-review.md`. This handoff addresses
LEX-REVIEW-002 and LEX-REVIEW-007 only; it does not dispose of the other review
findings or certify the candidate denominator. Source basis remains AMS2.8 and
2.8.1 printed17/physical30, already fully text/visually reviewed.

## Punctuation identity

`audit_ams_lexical_punctuation_identity.v` declares plain `ab` and distinct
escaped names `a.b`, `a/b`, `a+b`, `.ab`, `ab.`, `!ab`, `ab!`, `~ab`, `ab~`,
`1ab`, `$ab`, `\ab`, `a/*b`, `a//b`, `a*/b`. Each gets its own value1 through16,
then every object is read after all assignments. Expected transcript is the
ordered sequence1 through16. These spellings are distinct source identifiers;
escaping permits their punctuation but does not delete it from identity.

Unlike the single all-ASCII name fixture, consistently stripping punctuation
from declarations and references now creates collisions. A compiler either
rejecting those legal distinct declarations as duplicates or merging storage
would fail this required-positive case. The first and last printable characters
(! and ~) are covered in leading/trailing positions, period also in each
position, and leading digit/dollar/backslash and embedded comment-like sequences
are preserved. This is a bounded collision set, not every possible substitution
or every character/context combination. No mutation was actually executed.

## Escaped minimum-length identity

`audit_ams_lexical_escaped_length_identity.v` uses two names beginning `!`, then
1022 copies of `x`, then distinct `a`/`b`. Each content has1024 characters;
the backslash and following whitespace are delimiters, not counted identity
characters. Independently assigned3/7 must print3 7. The differing final character
catches consistent truncation, while the required escaping exposes incorrectly
charging delimiter bytes against a1024 limit. No1025 rejection is invented.
An independent awk scan of the actual declaration tokens reported1024 twice
(field length minus the leading backslash). Perl was unavailable; no Perl
validation succeeded or is relied upon.

## Actual execution

Both commands used the supplied integrated cached CLI:
`/home/omare/Documents/Projects/Zig/VerA/.zig-cache/o/a10b1de8b23e4ac042c82f9415cfe87a/vera`
with `--run tests/fixtures/digital/NAME.v`, own-worktree cwd. CLI SHA256
`6b6e9b28b46620533350a062c8a454330b5ff0ff4ab6fc14a01775c9df45e4ce`.
Each exits0 and matches its independently derived transcript exactly.

| Fixture | Source SHA256 | Expected SHA256 |
|---|---|---|
|audit_ams_lexical_punctuation_identity|5791572f43b27ec4df733b2bb347c9bba24c978ef87f433b99144028af89bddb|0619baeba1031a46dd7b7441ddda55534bac06b7ade0973a97c9f54e21fd6074|
|audit_ams_lexical_escaped_length_identity|305a0552dac967ff87e00c76c91fb70fcb02b5c5924b3152da67a9c4f7f8fe17|c3ae8e12d0891aa8d4363f1c26baa0226806566f16fce94852d176e7976cfa8c|

No compiler, shared ledger or existing fixture changes in this handoff. No
build/full gate was run. These are digital runtime observations, not proof of
analog execution, exhaustive lexical conformance or verified ledger status.

Root integration: main reviewed the fixtures and derivations, independently
measured both escaped contents as1024 characters with awk, and reran both
programs with the same hashed CLI. Each exits0, matches its expected transcript
byte-for-byte and has empty stderr. Logs are
`/tmp/vera-lexical-{punctuation_identity,escaped_length_identity}.{out,err}`.
These add bounded identity evidence; untested punctuation substitutions and
positions remain open. They do not supersede the original single-name test.
