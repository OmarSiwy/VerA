# Repair of reviewed readmem validation edges

Follow-up to `conformance-readmem-validation-edges.md`, 2026-09-23. Parent
accepted the source conclusions and authorized this bounded production repair.
IEEE1364-2005 §§17.2.9,3.5 Syntax3-1,3.5.1 and1.2(a) supply the requirements;
source details, exact page boundaries and pre-fix CLI observations remain in
that preceding report. Address-token underscore/signed/unknown semantics remain
separate and are not changed here.

## Implementation

Only production file: `src/sim/digital.zig`. Current root and agent baseline
were byte-identical before edits:
`a1cf2ddd90606d160900d739650957b26d435995db7a9285a993fc70aa116dfa`.
Final handoff SHA256:
`bd17558bf7c338a4a6dce95f79778539db4d753145ebebb8a7868f6a5bebd8d7`.

- `memDigit` centralizes radix validation and four-state digit interpretation;
  question mark is now z, not x.
- `validateMemWord` requires an initial digit and validates every character,
  ignoring only legal subsequent underscores.
- `memWord` validates the entire token first, then constructs only the retained
  low bits. This preserves the earlier high-prefix validation repair and valid
  oversized-value truncation; the conversion loop may stop at the destination
  width only because validation has already traversed the complete token.
- After the requested range is filled, `readMemory` still validates subsequent
  data tokens before skipping their assignment. This validation allocates no
  destination-sized value. Valid excess words continue to count for W1150;
  later addresses still suppress count warnings and restart loading.
- Address parsing and declared-range policy are unchanged.

## Focused red/green evidence

New tests were added before production edits. The existing readmem filter then
exited1 with three actual behavioral failures:

- question mark expected z, observed x;
- underscore-only token expected BadDigit, returned zero;
- malformed token after final destination expected DigitalFailed, returned
  success with a count warning.

After the repair, the same command exits0 with all nine discovered tests
passing, including the module import and previous readmem regression tests:

```sh
zig test --dep diag --dep frontend -Mroot=src/sim/root.zig -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig --test-filter readmem
```

The new tests cover both radices for question-mark and leading/standalone
underscore cases, valid repeated/trailing underscores, invalid excess tokens,
valid excess-word warning, and later-address restart. Previous tests continue
to cover forbidden high prefixes, oversized legal truncation, individual
warning counts, explicit address errors, start-only traversal and formfeeds.
`git diff --check -- src/sim/digital.zig` exits0. No full build was run.

The production CLI fixtures from the preceding edge review are unchanged and
ready for parent integration. The parent must rebuild and rerun them before
recording post-fix CLI evidence. This handoff claims focused unit/runtime-helper
success, not an unperformed rebuilt-CLI gate, complete rule closure or a measured
conformance percentage.

Residual: data following a file address outside the declaration when no task
bounds were supplied is still outside this bounded repair, along with the
address-format questions explicitly deferred in the source review. No silently
expanded address policy is included.

## Root integration checkpoint

Main read both full reports, checked the source-number question-mark and
underscore dependencies and file-wide17.2.9 constraints, and reviewed the
complete code/fixture patch. The repair and all new controls are integrated.
Root focused readmem command exits0 with all nine tests passing. Full unit,
digital and strict gates are running under `/tmp/vera-readmem-edges-*` logs;
post-fix production CLI observations remain pending. The preceding measurement
still describes the readmem-token checkpoint, not this unmeasured change.

The full digital run subsequently exits1 with FAIL/XFAIL names identical to
the expression/operator checkpoint (`/tmp/vera-readmem-edges-devices.names`
versus `/tmp/vera-expression-operators-devices.names`). Rebuilt CLI SHA256
`56b8abf7683ff7cc3c6a6a245e66f460ea36269e8eb8d5de859c1fbfefe3392a`
directly reproduces the four positive transcripts: question-mark z values,
legal repeated/trailing underscores, zero-padded address and valid excess data.
The first three have empty stderr; valid excess data retains W1150. Leading/
standalone underscores and malformed data beyond the load range each now
exit1 with the intended malformed-data error. Captures use each fixture's
basename under `/tmp` with `.out`/`.err`. Unit/strict gates remain running;
these observations do not settle the deferred address-format cases.

Subsequent unit and coverage commands exit0. Strict exits1 with failure-name
membership identical to the readmem-token checkpoint; no existing FAIL/XFAIL
name changes. Measurement generation is running from the completed
`/tmp/vera-readmem-edges-{strict,coverage}.log` inputs.
