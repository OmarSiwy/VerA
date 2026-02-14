# Successful digital runs can require warnings

2026-09-23. IEEE1364-2005 §17.2.9 requires a warning, not an error, when a
sequential memory data file's word count differs from the requested range.
The old d09_91 rejection oracle contradicted that source. Main independently
read the complete load-memory subsection and verified the corrected loaded
values against the root CLI before changing the fixture.

The fixture now enters the positive digital runner with exact stdout and an
exit-zero requirement. Additional `// digital-runner: warning PATTERN` lines
require each pattern to occur in an actual `warning[...]` stderr header.
Diagnostic source excerpts, arbitrary stderr text, error headers, bare empty
patterns and successful runs without the required warning do not satisfy it.
Positive runs with error diagnostic headers also fail, even if their process
status is incorrectly zero. Tests without warning directives retain their
existing stdout oracle and may emit unrelated warnings.

`tests/harness.zig` tests these distinctions; `tests/bench.zig` applies the
warning check only after successful exit and still requires exact stdout.
The helper does not make warnings select a fixture: positive cases still need
their expected transcript. This is bounded observation support, not complete
stderr/count/order/absence checking.

The memory overflow fixture requires W1150 and the specific count-mismatch
phrase reserved for its pending compiler repair. No unsupported-feature error
can satisfy it. The original refusal obligation is withdrawn to
IEEE-FILE-MEM-002 in `conformance-ieee-fileio-review.md`; the genuine mandatory
warning is now executable evidence instead of a prose-only open item.
Root build and post-repair gate results remain pending.
