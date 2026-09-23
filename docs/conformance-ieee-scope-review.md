# Inherited scope and elaboration source review

Review date: 2026-09-23. This bounded source/evidence inventory does not close
measure B, alter any measured result, or claim exhaustive behavioral coverage.
The source is the licensed IEEE 1364-2005 PDF identified in
`conformance-ieee1364.md`; it is not redistributed here.

Main integration checkpoint (2026-09-23): main read the complete report,
independently read IEEE12.7–12.8 and reviewed the probe derivations. Both controls
were reproduced in the main tree: the same E0907 rejects both legal and invalid
inputs, so the invalid result remains masked. The new digital shadowing
transcript is integrated; its full digital-suite result is recorded separately.

The completed main digital suite reproduces the lexical-shadowing failure at
the unsupported local declaration. Its expected transcript is unchanged; the
new failure is explicit evidence debt, while previous failure membership is
unchanged. The source review is not credited as runtime scope conformance.

## Source boundaries and edition-correct references

Read the complete extracted text of IEEE §12.6, printed 193–195 / physical
223–225; §12.7, printed 195–197 / physical 225–227; and §12.8 including
§§12.8.1–12.8.2, printed 197–198 / physical 227–228. Visually inspected
physical pages 224, 226, 227 and 228: Syntax 12-7 punctuation and alternatives,
Figure 12-3 lexical nesting, elaboration algorithm steps and early-resolution
example. Physical pages 223 and 225 have text review only, not full visual
certification. Renderings used `pdftoppm -scale-to 1400 -png`.

Read AMS physical 175–176 / printed 162–163, covering the end of §6.7.1,
§6.8 and §§6.9–6.9.4, against current Chapter 6 HTML and the hierarchy ledger.
IEEE **12.7 is scope rules; 12.8 is elaboration**, not interchangeable numbering.
AMS §6.7.1 explicitly inherits IEEE §12.6 and restricts `scope_name` to a
hierarchical instance identifier. IEEE §12.6 delegates the defparam exception
to §12.8. AMS §6.8 adds analog-function scope, while the inherited digital
task/function rules remain applicable. AMS elaboration also includes discipline
resolution and connection insertion: IEEE expansion alone cannot certify it.
The known AMS §6.9.4 step-3 self-reference remains HIER-SRC-005; this review
does not silently substitute a different algorithm for the supplied source.

## Obligation/evidence register

These IDs separate observable rule groups; they are not a completeness
denominator. Every row remains open for complete positive/invalid evidence.

| ID | IEEE clause | Source-derived obligation and evidence boundary |
|---|---|---|
| SCOPE-001 | 12.6 | Upward hierarchical references can use module or instance names; search enclosing modules for task/function/block items, not a search through arbitrary sibling instances. Existing AMS hierarchical tests do not establish all digital item kinds. |
| SCOPE-002 | 12.6 | Resolve the first path component from current lexical scope through enclosing module, then parent modules; after finding it, resolve the remaining path downward. Defparam has the 12.8 exception. Legal control below fails before that exception can be tested. |
| SCOPE-003 | 12.7 | Identifiers are unique within a scope, including uninstantiated generated scopes; conditional-generate exception is 12.4.3. Duplicate-name diagnostics alone do not cover that exception. |
| SCOPE-004 | 12.7 | Unqualified variable lookup uses enclosing lexical scopes and stops at module boundary. Existing analog local-shadow fixtures cover two cases; new digital shadow transcript is blocked by unsupported block declarations. Parent-module variable leakage remains untested here. |
| SCOPE-005 | 12.7 | Unqualified task/function/named-block/generated-block lookup may continue through higher modules. This differs from variables; no new runtime evidence here. |
| SCOPE-006 | 12.7 | Hierarchical paths may begin with several scope kinds; instance-name matching takes precedence over module-name matching. AMS restrictions must be applied separately; no complete precedence matrix here. |
| ELAB-001 | 12.8.1 | Establish top-module worklist, expand nongenerate hierarchy and finalize applicable parameter values before evaluating generate constructs. Existing simple defparam precedence test is narrower. |
| ELAB-002 | 12.8.1 | Defer unresolved defparam targets to subsequent expansion iterations. Generated-scope defparam restrictions preserve finality of values before generate evaluation. Generated-target deferral needs a dedicated runtime witness. |
| ELAB-003 | 12.8.2 | A defparam resolved early must produce an error if full hierarchy would resolve its name to a different object. The source's early/late target mismatch, not arbitrary retargeting, is the invalid premise. Current negative control is masked by failure of its matching legal control. |

## Independently isolated probes and recorded results

`tools/scope-audit-controls/early_defparam_legal.va` and
`early_defparam_invalid.va` differ only in the generated block name.
Before generation, `scope_root.slot.select` denotes the child parameter;
changing it from 2 to 1 instantiates the conditional block. In the invalid
case, the new local `scope_root` block contains a leaf instance `slot`, whose
`select` parameter is a different object (default 3). IEEE §12.8.2 requires
an error. In the legal control the block is named `different_name`, so the
original hierarchical target remains unchanged. The source example's incidental
identifiers and its prose/code naming typo are not additional obligations.

Executed both with the current root `zig-out/bin/vera --check`, absolute root
contract and fixture include path, from the separate agent worktree. Both exit
1 with E0907: the compiler seeks `slot.scope_root.slot.select` as a nonexistent
parameter. Therefore rejection of the invalid control does **not** demonstrate
ELAB-003 enforcement. The legal upward target is itself rejected. These remain
diagnostic controls outside the measured fixture suite: there is no fabricated
specific early-resolution diagnostic or broad rejection oracle to bless this
masked result. Compiler acceptance would still not establish runtime behavior.

`tests/fixtures/digital/audit_scope_lexical_shadow.v` adds a derived behavioral
oracle: module variable 11; same-named inner variable starts at 23, increments
to 24; exiting leaves module variable 11. Its expected transcript is
`inner=24`, then `outer=11`. Direct root `vera --run` exits 1 with E1100,
`block-local declarations are not implemented`, before producing the transcript.
No expected transcript was weakened to match that limitation. This is digital
runtime evidence debt distinct from the existing analog shadow cases.

## Remaining inherited-source inventory

This is a reconciliation against current `conformance-ieee1364.md`, hierarchy,
scheduling, display/monitor and parallel source reports, not a claim that an
unlisted clause was secretly reviewed. Navigation tools locate headings but
cannot turn them into source verification.

- §§1–2: §1 text reviewed; typography and external normative dependencies
  remain. §2 dependency disposition is not completed.
- §§3–5: isolated identifier, parameter, equality and reduction reads do not
  cover the full lexical/type/operator rules, tables or sizing interactions.
- §§6–10: full assignments, primitives, UDPs, behavioral constructs and
  task/function rules remain beyond the bounded NBA and analog comparisons.
- §11: scheduling text reviewed; production event regions, ports, continuous
  assignments and argument transfer still need evidence.
- §§12–13: this read closes the previously unread *source text* boundary for
  12.8 only. Parameter binding, generate exceptions, configuration/library
  clauses and their complete visual/runtime matrices remain incomplete.
- §§14–16: heading location correction is not specify/timing-check/SDF review.
- §17: display/monitor, time 17.7, conversion 17.8 and command-line 17.10
  reports are bounded. §17.6 queue text was read independently, but Table
  17-14–16 visual review and behavioral mapping remain open; the historical
  queue description's “total queued” is not one of Table 17-15's statistics.
  Other system-task subclauses need individual disposition, not chapter closure.
- §18: complete text read and a bounded four-state semantic comparator are
  recorded in `conformance-vcd-review.md`. Visual certification, actual emitted
  artifacts, real/event and extended-VCD profiles remain open.
- §19: macro/directive follow-ups do not exhaust all directive state and
  keyword-version interactions.
- §20, §§26–27 and normative Annex G: AMS VPI reviews do not by themselves
  certify inherited routines, objects, properties, C headers or ABI behavior.
- Removed §§21–25 and Annexes E/F: retain the missing 2001 dependency and
  applicability decision; no replacement text is inferred.
- §28 and Annexes A/B: protected-source semantics and complete inherited
  grammar/keyword reconciliation remain separate source obligations.
- Informative IEEE Annexes C/D/H/I must not be confused with the similarly
  lettered AMS annexes; informative-source fidelity is distinct from normative
  runtime requirements.

No shared Chapter 6 HTML or hierarchy ledger was edited. Main integration owns
suite gates and FAIL/XFAIL name-list comparisons; no full build was run here.
