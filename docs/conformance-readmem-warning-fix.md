# Sequential memory-file count warning

## Source and boundary

IEEE 1364-2005 §17.2.9, printed pp296–297 (PDF pages326–327), reread
2026-09-23. Source SHA256:
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
This is a bounded implementation follow-up to IEEE-FILE-MEM-002 in
`conformance-ieee-fileio-review.md`, not closure of §17.2.9.

Without file address specifications, a data-word count different from the
requested start-through-finish range requires a warning. It does not require
refusal. Explicit task bounds determine traversal direction, including after
an address specification. When task and file both specify addresses, file
addresses outside the requested range require an error and termination of the
load. Ordinary excess sequential words are not that address error.

## Implementation

`src/sim/digital.zig` now retains a completed-range state while continuing to
scan the already-read file. This counts excess words and detects address
specifications after the last loaded element. A later valid address restarts
loading with the original direction. Comments are excluded by the existing
tokenizer. Only a successful, address-free load with a mismatching count emits
new diagnostic W1150, with message prefix:

`memory file data word count does not match load range`

The message includes observed and expected counts. Loaded values are preserved;
short files leave unfilled elements unchanged. Explicit out-of-range addresses
use E1100 with `memory file address is outside the requested load range`.
No harness changes are included here; the parent separately owns successful
digital warning observation. The CLI already renders the diagnostic bag after
successful execution.

Both compiler files were byte-identical to the current root baseline before
editing; prior vector-delay, disable, clog2 and wait changes are preserved.

| File | Baseline SHA256 | Handoff SHA256 |
|---|---|---|
| src/sim/digital.zig | d896afbcc66ed2a2974b236fed913c500ba6410e02b1686b7f4050d87cf703b3 | dca6d32c886e04be6fc7e20b70b66e2894649c02238a31bf8ae7bee7a41320a0 |
| lib/diag_code.zig | 2f383235b9ad5f75fc51bdb14b4a6eb8817849f4e6ecfac60ffd20386b72887f | 27e3661823996e00d903be917b7e464e8e4054ad05c829c009fa1d4d2cd18470 |

## Evidence

Focused command exits zero (three discovered tests, including module import):

```sh
zig test --dep diag --dep frontend -Mroot=src/sim/root.zig -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig --test-filter readmem
```

The unit tests assert successful execution, exact loaded values and diagnostic
warning counts for empty/comment-only, short, excess and exact files; ascending
and descending explicit ranges; address suppression including an address after
the selected range was filled; restarted loading in the original direction;
and E1100 rather than W1150 for explicit address-range errors. Error cases
assert termination before the following display; they do not externally inspect
partially loaded internal memory after termination.

New digital fixtures in `tests/fixtures/digital/`:

- `audit_readmem_count_warning.v`: independently derived short/excess values
  in both directions, with warning-observation directives.
- `audit_readmem_address_restart.v`: relocation after filling the range,
  descending direction preserved. Warning absence is asserted by unit tests.
- `audit_readmem_address_range_rejected.v`: address inside the declaration
  but outside the task range; explicit digital-negative opt-in and distinctive
  diagnostic expectation.
- Data: `audit_readmem_short.hex`, `audit_readmem_excess.hex`,
  `audit_readmem_restart.hex`; positive expected transcripts accompany fixtures.

CLI-only `zig build -Doptimize=ReleaseFast` exits zero. Separate stdout/stderr
captures verify exact transcript equality and exit zero for both new positives,
`audit_readmem_lowest_descending` and the historical
`d09_91_readmem_overflow_rejected` positive. The count-warning fixture emits four
W1150 headers; restart and lowest-address fixtures emit none; historical
overflow emits one. The new address-range negative exits one with the intended
E1100 phrase. `zig fmt --check` and scoped `git diff --check` pass.

No conformance measures were generated. This changes bounded behavioral
evidence, not a claim of complete coverage. Full gates and FAIL/XFAIL name-list
comparison are the parent's integration responsibility.

Root integration checkpoint, 2026-09-23: reread the source addressing and
warning rules and integrated the implementation without unrelated formatting
changes. The focused readmem command above passes all three discovered tests
in the root tree. Root full unit gate exits zero. The digital gate exits one
with existing obligations still failing; compared with the pre-fix baseline,
only `d09_91_readmem_overflow_rejected` leaves the failure-name list, and no
new name enters it. The new readmem fixtures pass. Logs are
`/tmp/vera-readmem-unit.log` and `/tmp/vera-readmem-devices.log`.
The strict suite exits one with outstanding failures; its name list removes
only the historical overflow row versus the UDP/parameter checkpoint. That
row also moved from the old analog rejection intake into the positive digital
runner, so its strict removal is not independent behavioral proof. The digital
warning-plus-values result above supplies that behavioral evidence. Coverage
collection exits zero; `tools/conformance.sh` completed successfully and wrote
the checkpoint to `conformance-measurement.md` (unit pass, digital FAIL). The earlier
pre-fix digital baseline is `/tmp/vera-fileio-warning-before-devices.log`;
its failure-name comparison preserves every pre-existing failure and exposes
the missing warning on the historical overflow fixture. No measured percentage
is inferred from these focused checks.

## Residuals

Legal start-only invocations remain unsupported by preflight. Existing memory
tokenization does not handle the clause's formfeed separator. Other malformed
data/address cases, binary-specific parsing, declaration-bound behavior outside
the requested range, lint-level overrides and warning-location richness are
not closed by this patch. W1150 tests target default warning behavior.
