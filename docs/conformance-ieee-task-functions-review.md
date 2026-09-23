# Inherited IEEE tasks and functions — source/evidence audit

## Reviewed boundary

Read the complete IEEE 1364-2005 Clause 10 introduction and §§10.1–10.4.5,
including examples: printed pages 145–157, physical PDF pages 175–187.
Visually inspected all five syntax displays: Syntax 10-1 on physical 176,
10-2 on 177, 10-3 on 180, 10-4 on 183, and 10-5 on 185. The source is the
licensed `docs/1364-2005.pdf`; no source-page assets or PDF copies are added.
Review date: 2026-09-23.

AMS §1.1 inherits these digital semantics. AMS Annex A grammar and analog
function §4.7 are not substitutes for the inherited task/function rules.
In particular, an ordinary digital function must not be tested using analog
function formal-type restrictions. This ledger supplements the HTML inheritance
boundary; it is not a complete republication of the licensed IEEE chapter.

Source wording caveats: §10.1 says a function executes in one simulation time
unit, while §10.4.4 expressly prohibits time-controlled statements. This audit
does not infer permission for a function `#1`. Also, §10.2.1's second-form prose
omits mention of `automatic`, although Syntax 10-1 expressly permits it in
both forms. Fixtures follow the explicit syntax, without silently editing
source wording.

## Rule groups and remaining evidence obligations

Every row below remains open unless a narrower recorded result says otherwise.
Reading all source paragraphs is not exhaustive behavioral coverage.

| ID | Source | Obligation and evidence boundary |
|---|---|---|
| TF-001 | 10.1, p145 | Function/task expression-versus-statement use; task has no return value, function returns one value. Invalid cross-use cases still needed. |
| TF-002 | 10.1/10.2, p145 | Tasks may consume time and nest; control returns only after descendants complete. New copy-timing fixture covers one timed task, not nesting. |
| TF-003 | 10.2.1, pp146–147 | Both declaration styles; automatic option; directions; supported data types, signed/range forms, local declarations, attributes. New fixtures exercise a subset, not the syntax product. |
| TF-004 | 10.2.1, p147 | Static shared storage versus per-activation automatic storage. New concurrent fixture distinguishes them. |
| TF-005 | 10.2.1, p147 | Automatic items cannot be accessed hierarchically; automatic task invocation itself may use a hierarchical name. Both directions still need isolated controls. |
| TF-006 | 10.2.2, p147 | No argument list for zero-argument tasks; otherwise exact positional count/order; no null actual. New null negative covers only the last rule. |
| TF-007 | 10.2.2, p147 | Input accepts arbitrary expressions; output/inout actual must be procedural lvalue, including listed memory/select/concatenation forms. New output-expression negative is not complete shape coverage. |
| TF-EVID-001 | 10.2.2, pp147–148 | Copy input/inout at enable, copy output/inout only at return, pass by value. New timing/input-mutation fixture owns the withdrawn strong claim from d04_09. |
| TF-008 | 10.2.2, p147 | Argument-expression evaluation order is undefined. Do not require a particular order of side effects. |
| TF-009 | 10.2.3, p149 | Static variables/formals retain values, initialize once to type defaults; automatic locals/outputs initialize per invocation, inputs/inouts from actuals. New output-lifetime fixture distinguishes retention and output-not-copy-in; more data types remain. |
| TF-010 | 10.2.3, p149 | Separate module instances have separate static-task storage. Current concurrent fixture uses one instance only; multi-instance evidence remains open. |
| TF-011 | 10.2.3, pp149–150 | Automatic items cannot be NBA/PCA assignment targets, PCA/force references, intra-assignment NBA event references, or monitor/dump traces. Isolated negatives and static legal counterparts remain open. |
| TF-012 | 10.3, pp150–152 | Disable terminates target and descendants, resumes caller/following block, and terminates all concurrent activations including automatic ones. Task-specific runtime cases remain open. |
| TF-013 | 10.3, p150 | After task disable, output/inout results, pending NBAs and procedural continuous assignment results are unspecified. No single result should be asserted. |
| TF-014 | 10.3, p150 | Named block inside function can be disabled; function itself cannot. Disabling an ancestor caller from a function is undefined. Legal/invalid/undefined cases must remain separate. |
| TF-015 | 10.4.1, pp153–154 | Both function declaration styles, at least one input, default scalar return and explicit real/integer/time/realtime/vector types. New return-variable fixture covers default scalar and a vector only. |
| TF-016 | 10.4.1, p154 | Automatic functions are reentrant; hierarchical invocation allowed, hierarchical item access forbidden. Existing recursion row is only one positive design, currently unexecuted. |
| TF-017 | 10.4.2, p154 | Implicit return variable has specified/default type, is writable/readable in function; duplicate function-name objects forbidden in function and enclosing declaration scope. New positive covers reading return variable; duplicate negatives remain. |
| TF-018 | 10.4.3, p155 | Function is expression operand with nonempty arguments; hierarchical names and call attributes. Argument evaluation order undefined. Not exhausted by one arithmetic function. |
| TF-019 | 10.4.4(a), p155 | No #, @ or wait in function. New # negative only; @ and wait remain. Legal timed task is a contrasting context. |
| TF-020 | 10.4.4(b–d), p155 | No task enabling; at least one input; no output/inout. All isolated rule negatives remain open. |
| TF-021 | 10.4.4(e–f), p155 | No NBA, procedural continuous assignment or event trigger. New NBA negative only. Blocking function-return control remains unsupported. |
| TF-022 | 10.4.5, p156 | Constant call is local, uses constant actuals, no hierarchical references, and only local constant-function callees. Positive/negative context controls needed. |
| TF-023 | 10.4.5, p156 | Only system functions allowed in constant expressions; system tasks ignored. Distinguish these from ordinary user-task enabling prohibition. No artifact/side-effect evidence yet. |
| TF-024 | 10.4.5, p156 | Parameters used must precede invoking constant call; other identifiers local to function; defparam-affected parameter result undefined. Do not assert one outcome for undefined case. |
| TF-025 | 10.4.5, p156 | Constant functions cannot be declared in generate blocks or themselves use constant-function calls in constant-expression-required contexts. Targeted negatives remain. |
| TF-026 | 10.4.5, pp156–157 | Elaboration calls do not affect later runtime or other elaboration-call variable initial values. Independent elaboration/runtime state-isolation oracle remains open. |

## Existing fixture audit

- `d04_09_task_argument_passing.v`: valid final-value oracle, but its original
  prose falsely said assigning output `o` could modify input actual `p` via
  input formal `i`. It never assigns `i`, and it never observes outputs during
  the call. Comment-only correction withdraws value-versus-reference and
  return-timing discrimination to TF-EVID-001. Executable source and expected
  transcript are unchanged. Base SHA-256 was
  `f2582a064f30be37d0eb04a06642f7a41824df9f8119a6a406b8432edb14da3e`.
- `d04_10_task_static_lifetime.v`: sequential local retention oracle is valid;
  it does not establish concurrent sharing, automatic task initialization, or
  per-module-instance separation.
- `d04_11_function_automatic_recursion.v`: automatic factorial expected120 is
  valid. Its claim that static storage necessarily yields1 or hangs is too
  strong: evaluation of the multiplication's left operand before recursion
  can preserve the needed value even with static storage. Do not equate this
  oracle with all reentrant-lifetime obligations. Its overstrong comments were
  corrected; no executable source or expectation was changed.
- `d04_12_function_return_width_is_the_boundary.v`: validates selected return
  truncation before caller extension; not all return types, signedness, or
  implicit-variable rules. Oracle unchanged.

Current root compiler rejected all four before execution. Task forms start
with E0205; ordinary function forms are routed through inappropriate analog
function parsing or unsupported digital validation. These are not runtime
passes and are not evidence of legal function/task restrictions.

## Added fixtures and recorded results

Root CLI used for bounded runs had SHA-256
`69a150f7b649e58606997dd345ca7715838043dc4a988d66c29efb735d9c1389`.
Each new source was run with that binary's `--run` in the isolated worktree.

| Fixture stem | Independent oracle | Observed result |
|---|---|---|
| `audit_task_copy_timing` | During: output9/inout11. Return: input7/output4/inout13; input-formal mutation99 must not escape. | Exit1, E0205 at task declaration; no runtime transcript. |
| `audit_task_output_lifetime` | First static/automatic outputs0101; second static0101/automaticxxxx despite caller actual1010. | Exit1, E0205; no runtime transcript. |
| `audit_task_concurrent_storage` | Static20,20; automatic10,20 from distinct-time activations. | Exit1, E0205; no runtime transcript. |
| `audit_function_return_variable` | Default scalar returns0 and1; explicit vector return reread yields0101. | Exit1, E0225 analog formal-type diagnostic; no runtime transcript. |
| `audit_task_output_expression_rejected` | Output actual expression must be refused for lacking lvalue. | Exit1, unrelated E0205; intended diagnostic not matched. |
| `audit_task_null_argument_rejected` | Null task actual must be refused. | Exit1, unrelated E0205; intended diagnostic not matched. |
| `audit_function_time_control_rejected` | Function # delay must be refused. | Exit1, unrelated E0225; intended diagnostic not matched. |
| `audit_function_nonblocking_rejected` | Function NBA must be refused. | Exit1, unrelated E0225; intended diagnostic not matched. |

Each negative contains one intended illegal feature and names its legal
control. Reject phrases are explicitly proposed rule-specific diagnostics,
not claims that those diagnostics already exist. Generic rejection of the
enclosing legal declaration cannot satisfy the intended negative. Positive
transcripts are derived by hand from the cited rules, not copied from current
implementation behavior. No external reference simulator was available for
an additional syntax/runtime cross-check.

The digital runner does not implement `//! xfail`; no ineffective marker was
added. These are required failing cases, not exclusions. New `.expected.txt`
files make positive cases discoverable; `digital-runner: reject` selects
negatives. Full digital gates/name-list reconciliation and A/C measurement
remain main integration work. No compiler files changed for this audit, no
percentage is asserted, and Clause10 is not behaviorally closed.

## Root review boundary

Main read this complete report and all eight proposed fixtures on 2026-09-23,
and independently reread the source argument-passing, task-storage and function
restriction rules. The full chapter traversal remains worker evidence.
All eight fixtures and the two scoped legacy-header corrections are now
integrated. Legacy executable bodies and expected transcripts are unchanged.
Fresh root gates remain pending at this checkpoint. Proposed negative phrases
remain future rule-specific contracts, not observed diagnostics or passes.

Root digital run completed: all eight newly added cases fail for the recorded
unsupported-context/wrong-diagnostic reasons. Exact failure-name comparison
against `/tmp/vera-readmem-start-devices.names` adds only these eight names;
every pre-existing failure remains unchanged. Log:
`/tmp/vera-task-functions-devices.log`. These are four legal-input failures
and four intended-invalid cases whose specific diagnostic is still missing,
not eight new correct-rejection results. Full unit/strict checks follow the
combined task/header batch.
