# Full-token validation before memory-word truncation

Follow-up to READMEM-TOKEN-VALIDATE-001 in
`conformance-readmem-diagnostic-refinement.md`, reviewed2026-09-23.
IEEE1364-2005 §17.2.9 printed296 forbids length/base prefixes and requires data
digits in the selected radix; §1.2(a) printed2 requires an error for input that
violates a mandatory requirement. Source PDF SHA256:
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
The distinction between error observation and simulation termination remains
as recorded in the diagnostic review.

## Minimal fix

Only `src/sim/digital.zig` changes. The current root baseline was byte-identical
to the agent file before editing:
`3a46db92587cc6fd1079d295384da4ef9b420a5f6bd8ef9088c4d1d3e21ef3c0`.
Final SHA256:
`a1cf2ddd90606d160900d739650957b26d435995db7a9285a993fc70aa116dfa`.

`memWord` now scans to the beginning of every token even after destination bits
are full. Its existing digit/unknown/separator checks therefore validate high
characters too. The inner write loop still stops at the destination width,
preserving low-bit truncation for valid oversized data. No allocation scheme,
radix policy, unknown encoding, warning logic or other production path changed.
The added comment explains why validation and stored-bit limits differ.

## Red/green evidence

The new unit test was first run against unchanged production logic. After
correcting a test-only enum spelling typo, it compiled and failed with actual
`TestExpectedError`: forbidden `8'h11` returned an 8-bit value17 instead of
BadDigit. This is the behavioral pre-fix failure, not the preceding compile
typo. The production one-condition fix was then applied.

```sh
zig test --dep diag --dep frontend -Mroot=src/sim/root.zig -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig --test-filter 'readmem validates high'
zig test --dep diag --dep frontend -Mroot=src/sim/root.zig -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig --test-filter readmem
```

Pre-fix focused command exits1 with the failure above. Post-fix readmem command
exits0: six discovered tests including the module import. The new unit checks
forbidden prefixes and high invalid characters in both hexadecimal and binary
tokens, including illegal binary digit2 outside the retained low8bits. Legal
`aB_11` and `10_00010001` each still yield17 in an8-bit word. Existing runtime
tests for warnings, address relocation, start-only calls and formfeeds also pass.
Scoped `git diff --check -- src/sim/digital.zig` exits0. No full build or rebuilt
CLI was run in the agent.

## Additional fixture controls

New files under `tests/fixtures/digital/`:

- `audit_readmem_invalid_high_hex_rejected.v` and data
  `audit_readmem_invalid_high_hex.txt` (`g11`).
- `audit_readmem_invalid_high_binary_rejected.v` and data
  `audit_readmem_invalid_high_binary.txt` (`200010001`).
- `audit_readmem_oversized_legal.v`, expected transcript and `.hex`/`.bin` data:
  valid oversized words retain low8bits and print `11,11`.

Both negatives explicitly opt into the digital negative runner and preserve the
distinctive malformed-data-word error expectation. The legal neighbor follows
memory-word assignment/truncation semantics (IEEE§17.2.9 with §5.6) and protects
against repairing validation by rejecting all oversized words.

The parent's pre-fix cached CLI, SHA256
`6b6e9b28b46620533350a062c8a454330b5ff0ff4ab6fc14a01775c9df45e4ce`,
incorrectly exits0 on both high-invalid cases; the legal oversized control
exits0 with the exact expected transcript. Parent must rerun these and the
earlier forbidden-prefix fixtures using the integrated rebuilt CLI. Post-fix
CLI success is not claimed here. The seven isolated warning fixtures and
earlier malformed-input controls are a separate preceding handoff, unchanged.

This repair does not validate malformed tokens beyond a completed load range,
resolve every accepted numeric spelling, or close all readmem obligations.
No conformance number, new verified ledger status or full-gate result is claimed.

## Root integration checkpoint

Main reviewed the source dependencies and complete production/test diff, then
integrated the repair, both reports and the isolated warning/malformed/legal
fixture batch. Root focused readmem tests exit0: all six discovered tests pass.
The rebuilt CLI SHA256 is
`ea2c724c744b0d0c810128ed1a1013cfa18d07b78fccf9f3ab5483c2acaef3e8`.
Direct root runs now reject both forbidden-prefix8-bit cases and both high-
invalid-digit cases with exit1 and the expected malformed-data error. The
oversized legal neighbor exits0 and matches `11,11` exactly. Captures are
`/tmp/audit_readmem_{malformed_width_rejected,malformed_base_rejected,invalid_high_hex_rejected,invalid_high_binary_rejected,oversized_legal}.{out,err}`.

Full digital execution exits1 with the same sorted FAIL/XFAIL names as the
escaped checkpoint: `/tmp/vera-readmem-token-devices.names` compares identically
to `/tmp/vera-escaped-devices.names`. This preserves existing unresolved
failures rather than reporting the suite green. Full unit/strict gates remain
running at this checkpoint; no new A/C measurement has been generated yet.
The readmem ledger now cites IEEE1.2(a) error authority and separates binary
legal behavior from its invalid-digit case. It remains unverified.

Subsequent root gate completion: unit exits0; strict exits1 with an identical
FAIL/XFAIL name list to the escaped checkpoint. The three new analog lexical
fixtures pass, including their declared check counts. Coverage exits0.
Measurement generation is running from `/tmp/vera-readmem-token-{strict,coverage}.log`;
these gate results do not close remaining numeric-spelling/load-range gaps.
