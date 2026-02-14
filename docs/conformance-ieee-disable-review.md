# IEEE disable lifecycle and scheduling dependencies

## Source boundary

Disable semantics belong to IEEE 1364-2005 **§10.3**, not Clause11. Read the
complete §10.3 text and examples, printed150–152 / physical180–182, as part
of the preceding Clause10 audit; Syntax10-3 and normative text on physical180
were visually checked. For this follow-up, read complete §9.8 through9.8.4,
printed139–143 / physical169–173, plus the opening §9.9 process-order text
on printed143. Syntax9-13/14 on physical170/171 were visually checked.

Read complete Clause11, §§11.1–11.6.7, printed158–162 / physical188–192;
all those pages were visually checked, including the reference scheduling
algorithm. These are source-review boundaries, not a claim of complete
scheduler behavioral evidence. Licensed IEEE source pages are not copied
into the repository. Review date: 2026-09-23.

## Rules and derived distinctions

| ID | Source | Obligation / boundary |
|---|---|---|
| DIS-001 | 10.3 p150 | Terminate target block/task; resume after that block or task enable. Self-disable must leave the current block, not just cancel scheduled work. |
| DIS-002 | 10.3 p150 | Terminate activities enabled within target, including descendants down a task chain. Disabling an ancestor skips the inner and outer remaining statements. |
| DIS-003 | 10.3 p150 | All current activations of a named task are disabled, including automatic-task activations. This is not an ordinary per-invocation return. |
| DIS-004 | 10.3 pp150–152 | A distinct sibling target can be disabled while the caller and unrelated sibling remain alive. Observe after the target's original wakeup time. |
| DIS-005 | 10.3 p150 | Named blocks inside functions may be disabled; functions themselves may not. Disabling a function's ancestor caller is undefined. These separate legal/illegal/undefined contexts remain without targeted cases here. |
| DIS-006 | 10.3 p150 | Disabled task output/inout results, scheduled-but-unexecuted NBAs, and procedural continuous assignments have unspecified results. Do not impose cancellation or completion as a single normative oracle. |
| DIS-007 | 9.8–9.8.4 pp139–143 | Sequential order, concurrent fork branches, block start/finish, named-block identity and nesting determine continuation. Tests here do not exhaust fork/join completion accounting. |
| DIS-008 | 11.3–11.5 pp158–160 | Active-event interleaving is nondeterministic; same-time arbitrary order must not decide an oracle. Tests use ordered statements or distinct times. |
| DIS-009 | 11.6.3/11.6.4 p161 | Blocking suspension differs from independently scheduled NBA update; target/RHS capture rules differ. Killing a process resumption is not evidence that every queued write must disappear. |
| DIS-010 | 11.6.7 p162 | Normal task argument copy-out behaves like blocking assignment. This does not override §10.3's explicit unspecified copy-out result after disable. |

The rest of Clause11 was read for context, including continuous and procedural
continuous assignment startup/update, bidirectional switch processing, and
port/primitive connection scheduling. Existing scheduling evidence remains
in the main IEEE ledger; this follow-up does not close those groups.

## Existing evidence

`d04_14_disable_named_block.v` has a valid suspended-block oracle and still
produces its expected `disabled 0001 0000`. Its historical comment saying named
blocks are rejected is stale, but its executable source and expected transcript
are preserved. The case does not test a currently executing self/ancestor
disable, task activations, output copy-out, or pending NBA disposition.

Existing ordinary-NBA fixtures remain ordinary-NBA obligations. Their results
must not be extrapolated to disabled-task NBAs. No existing expectation was
changed in this handoff.

## Added cases and measured observations

All six `.v` cases have discoverable expected transcripts and source-derived
headers. They were run directly with current root `vera --run`; CLI SHA-256
was checked before and after the batch and remained
`28bc440e46b31048097aabb9473f96a542b56332db765c4985d378508209b843`.

| New fixture stem | Required result | Observed |
|---|---|---|
| `audit_disable_self_block` | `self=3` | Exit0, `self=101`: skipped assignment99 executed. |
| `audit_disable_ancestor_block` | `ancestor=5` | Exit0, `ancestor=92`: enclosing tail88 executed. |
| `audit_disable_sibling_block` | `sibling-block resumed=1 late=0 sibling=1` | Exit0, exact transcript match. |
| `audit_disable_sibling_task` | `sibling-task resumed=1 late=0 sibling=1` | Exit1, E0205 unsupported task declaration; no runtime evidence. |
| `audit_disable_ancestor_task` | `task-chain resumed=1 tails=0,0,0` | Exit1, E0205; no runtime evidence. |
| `audit_disable_recursive_task` | `recursive tails=0 resumed=1` | Exit1, E0205; no runtime evidence. |

The ancestor-task fixture schedules an NBA inside the leaf before disabling
the ancestor. Its destination is deliberately never printed or asserted: the
fixture only requires the defined lifecycle result. It does not manufacture
a rule that the pending NBA must be canceled or must survive. No task fixture
uses output/inout values as a post-disable oracle.

Read-only cause inspection finds that `src/sim/digital.zig`'s `disableRange`
only retires suspended continuations and the dispatch arm unconditionally
advances its current PC. Its own comment acknowledges containing-block
disable is currently a no-op. This explains DIS-001/002 failures, but no
compiler implementation change is included or claimed.

Missing boundaries include function-local named blocks, illegal function
targets, hierarchical target lookup, concurrent nonrecursive activations,
automatic-task inner blocks, named fork termination/join handling, wait/event
subscriptions, reactivation after disable, and per-instance target isolation.
The passing sibling row does not close these obligations.

Digital fixtures have no implemented XFAIL semantics; failing new cases are
retained as required failures. Full digital suite/name-list reconciliation and
A/C measurement remain root integration work. No conformance percentage or
exhaustive closure is claimed.
