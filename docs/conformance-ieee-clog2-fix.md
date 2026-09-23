# Digital arbitrary-width `$clog2` repair

Source verification on 2026-09-23: read the complete IEEE 1364-2005 §17.11
introductory paragraph and §17.11.1, printed323 / physical353. It permits
arbitrarily sized vector arguments, treats the argument as unsigned, prescribes
ceiling base-two logarithm, and makes zero return zero. This targeted read is
not a full math-family review or additional visual certification.

Root cause: `src/sim/digital.zig` evaluated the argument into the existing
arbitrary-width two-plane representation, then explicitly returned zero whenever
width exceeded64. This discarded valid high bits even though the frontend and
digital evaluation already preserved them. Signedness must not turn a high-bit
vector into a negative mathematical input for this function.

The replacement scans every value limb without allocation or narrowing.
For a positive integer with bit length L, ceiling(log2(n)) is L-1 exactly
when one bit is set, and L otherwise. An all-zero scan returns0. The scan
records both the highest nonzero limb and whether any second bit exists,
including in lower limbs; it is not specialized to tested widths. Existing
32-bit signed result normalization is unchanged. Existing unknown-input return0
is preserved as implementation policy, not newly asserted source conformance.

Only `src/sim/digital.zig` changes compiler behavior. It was copied from current
root with base SHA256
`29442f78e074d32295b384066437712aaa40628384fb726f1afe03180263e2cf`.
No shared runner, analog math implementation or AST integer helper was changed.

Focused command from the agent worktree:

```
zig test --dep frontend --dep diag -Mroot=src/sim/digital.zig \
  --dep diag -Mfrontend=lib/frontend/root.zig -Mdiag=lib/diag.zig \
  --test-filter clog2
```

Result: exit0, both tests pass. One executes actual digital source for65/129/257
bit operands below/at/above power boundaries, a signed129-bit high-bit operand,
wide zero/one/two/three, a signed32-bit all-ones input, an unsigned64-bit input
above2^63 and signed integer-result arithmetic. The other independently sweeps
every bit position0 through256 with exact-power and power-plus-one observations,
including cross-limb cases, and checks preservation of the unknown policy.
These are bounded tests, not exhaustive proof of all surrounding expression
sizing or constant-folding behavior.

Main integration must run the existing wide/unsigned transcript fixtures through
the rebuilt CLI and compare full FAIL/XFAIL name lists. No full build/suite was
run in this handoff, and no measured conformance number is claimed.

Main integration checkpoint (2026-09-23): independently reread §17.11.1 and
reviewed the all-limb algorithm. Both focused tests pass in the main tree.
After `zig build install` exited0, the existing wide and unsigned clog2 digital
fixtures both executed successfully and matched their expected transcripts
exactly. Main `zig build test` exited0. Full digital FAIL-name comparison against
the previous digital-negative batch removes only `audit_ieee_math_clog2_wide`;
no new failure name appears. Other digital debt keeps `test-devices` at exit1.
The strict analog-suite FAIL/XFAIL names are unchanged. This repairs a bounded
part of the inherited math evidence (measure B), not the whole math family.
