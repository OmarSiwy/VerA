# Whole-vector continuous-assignment delay correction

2026-09-23. Source: IEEE1364-2005 §6.1.3, printed71/physical101,
docs/1364-2005.pdf SHA256
3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e.
Tracks ASSIGN-VECTOR-001 in conformance-ieee-assignments-review.md.

The source separates scalar gate delay selection from whole-vector continuous
assignments: nonzero-to-zero takes falling delay, all-z takes turn-off, and
other transitions take rising delay. The former implementation selected
from destination bit0 in every case. Thus01→10 incorrectly took falling
delay, and0x/1z incorrectly took scalar minimum/turn-off delay.

The patch adds a continuous-assignment selector and applies it only to
expression drivers. Scalar, primitive, bridge and net-delay paths remain
unchanged. Classification examines the entire width, including upper limbs;
logical truth identifies a definitely nonzero previous value and all-zero
destination. The selector uses the published driver's value, not its pending
target. The scheduler's pending-target comparison and generation cancellation
are untouched. This is not a fix for vector net-delay per-bit scheduling,
strength resolution, or all source subtleties of multi-driver delay selection.
The existing driver metadata distinguishes width, not declared scalar versus
singleton [0:0] vector identity; width1 keeps the scalar rule. Singleton
vector delay policy remains open and is not credited by these tests.

Baseline src/sim/digital.zig SHA256:
2923894df75c615de9b84885539ffd04f582f78cedb737da3c7a47c360b3ff84.
This includes the coordinated self/ancestor disable correction; that code
was not changed. Only this compiler file is changed by the fix.

New fixture audit_assignment_vector_delay_unknown.v retains source-derived
expected bytes. With #(7,5,2), transitions00→0x and0x→1z wait7, whereas
1z→zz waits2. Before the fix the first two sampled updates occurred early.
Original audit_assignment_vector_delay.v retains its six-line oracle.
No rejection or XFAIL expectation was weakened.

Focused commands, from the agent worktree:

```sh
zig test --dep diag --dep frontend -Mroot=src/sim/root.zig -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig --test-filter 'continuous vector delay'
zig test --dep diag --dep frontend -Mroot=src/sim/root.zig -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig --test-filter 'delay'
zig test --dep diag --dep frontend -Mroot=src/sim/root.zig -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig --test-filter 'disable'
```

All exited0: respectively five, fourteen and five tests including import
tests. New tests cover original timing, mixed unknown timing, preservation of
same pending value,129-bit classification and scalar selector equivalence.
The broader focused delay run includes scalar inertial pulse suppression.
The disable run preserves the previously integrated control-flow fixes.

CLI-only `zig build -Doptimize=ReleaseFast` exited0. Fresh local CLI runs
all exited0 and matched expected bytes: audit_assignment_vector_delay,
audit_assignment_vector_delay_unknown, audit_assignment_pending_same_value,
d06_assign_delay_single, d06_assign_delay_rise_fall,
d06_assign_delay_turnoff, d06_assign_delay_inertial, d06_net_delay and
d06_net_decl_assign_delay. These preserve their existing normative oracles.

Root integration (2026-09-23): independently read §6.1.3, inspected the patch
and fixture derivations, and reproduced all nine exact transcript comparisons
after a successful CLI install. Root unit gate exits zero. Final strict and
digital name comparisons preserve all pre-existing failure names; additions
are the separately documented maxdelay XFAIL and new unsupported/invalid digital
cases. The vector-delay cases remain passing. No conformance measure is
manually inferred from these checks.
