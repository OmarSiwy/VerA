# Named-block self/ancestor disable implementation

Source: IEEE 1364-2005 §10.3, printed150 / physical180, explicitly permits
self-disable and requires execution to continue after the disabled target.
The complete source/evidence boundary is in `conformance-ieee-disable-review.md`.

## Root cause and bounded repair

The interpreter already retired queued target resumptions and removed target
waiters. The actively executing process, however, has no pending continuation
row, and its disable instruction always incremented its program counter. Thus
self-disable and disabling an enclosing ancestor continued inside the target.

After existing suspended-target cleanup, the dispatch now tests whether its
current PC lies in the target's half-open instruction range. If so, it jumps
to the target end; otherwise it continues to the next disabling-process
instruction as before. The existing suspension cleanup is unchanged. No task
implementation, NBA write policy, host API, or scheduler region changes are
part of this patch.

The file was copied from current root before editing, preserving the recent
wide `$clog2` and constant-wait fixes:

- File: `src/sim/digital.zig`.
- Root base SHA-256: `8d415e635b30de8dfa63b5656974d1272239e9e585668c261a552337ed73caa8`.
- Result SHA-256: `fa222b97a1db17c01d64146816d90951fad2db25689bc63ab85400d61ef547f7`.

## Actual-executor evidence

```sh
zig test --dep diag --dep frontend -Mroot=src/sim/root.zig \
  -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig \
  --test-filter disable
```

The command exited zero: root discovery plus four executor tests passed.
These use `expectRun`, which parses, validates, schedules and executes Verilog
source and compares its actual stdout, rather than testing a helper in isolation.

- Existing suspended-sibling cancellation/continuation test remains passing.
- New nested inner self-disable preserves the enclosing continuation and gives3;
  disabling an ancestor instead skips both tails and gives5.
- New loop-ancestor disable after timed suspension exits on the second iteration,
  executes only one loop tail, resumes its caller, and preserves an unrelated
  process that completes at a later time.
- New repeated entry into a named block works after self-disable; subsequently
  disabling that inactive block does not spuriously resume or reexecute it.

A second focused run with `--test-filter wait --test-filter clog2` exited zero
with eight tests, including root discovery, preserving the current-root wait
and arbitrary-width `$clog2` checks. `git diff --check` passed. `zig fmt --check`
reports this file on both the unmodified root baseline and the patch; no broad
format rewrite was applied to unrelated source.

Prior digital fixtures and review docs are unchanged. Their expected transcripts
remain authoritative; root must run them against its integrated CLI. No new
CLI was built for this bounded fix. Full-suite gates, exact FAIL/XFAIL name-list
comparison, and A/C measures remain integration work. Task disable, recursive
task activation handling, fork/join accounting, hierarchical target resolution,
and unspecified disabled-task output/NBA results remain outside this patch.

Root integration (2026-09-23): after independently reviewing §10.3 and installing
the patched CLI, self-block, ancestor-block and sibling-block fixtures all
exit zero and match their expected transcripts exactly. Root also corrected
the implementation's old source-clause comment. The file hashes above identify
the worker handoff, not the later root file with that comment and vector-delay
repair. Root unit gate exits zero. Final digital name comparison adds the three
new task-disable failures alongside separately documented assignment gaps;
all pre-existing failure names are unchanged. The three new block-disable
transcripts pass. Task limitations remain open.
