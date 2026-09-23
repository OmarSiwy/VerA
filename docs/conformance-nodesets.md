# Net declarations and nodeset evidence

Review date: 2026-09-23. Complete AMS §§3.6.3–3.6.3.2 text read against
HTML on physical pages 54–56. Syntax 3-6 was visually checked on pages 54–55;
its literal range brackets, colon, separators and assignment now have explicit
HTML markup. This is a partial rule/evidence ledger, not solver certification.

| ID | Source | Obligation / evidence boundary |
|---|---|---|
| NET-001 | 3.6.3 | Scalar/vector declarations refer to already declared disciplines. Bounds, declaration order, net/port associations and inherited digital net rules need independent mapping. |
| NET-002 | 3.6.3 | Conservative behavior requires potential and flow access; unresolved natureless nets are structural rather than directly analog-behavioral. Resolution through connected ports remains distinct from declaration acceptance. |
| NET-003 | 3.6.3.1 | Net and port descriptions may both occur; the last attribute value wins, and a duplicate warning is optional. Internal signal values do not observe exported descriptions or precedence. |
| NODE-001 | 3.6.3.2 | Initializers are allowed only on continuous-discipline nets. `91_nodeset_non_continuous.va` pins E0366, separating this requirement from analog-profile domain restrictions. |
| NODE-002 | 3.6.3.2 | Initializers are constant expressions; parameter expressions are permitted. `91_nodeset_not_constant.va` pins E0365 for a probe expression. Other invalid forms, converted values and parameter override paths remain open. |
| NODE-003 | 3.6.3.2 | The analog solver uses declared nodesets for potentials. Exporting a table is not proof that the active host consumes it. Seed capture or instrumented solver/API evidence is needed independently of the final solution. |
| NODE-004 | 3.6.3.2 | A nodeset is not a permanent potential constraint. `audit_nodeset_unclamped_solution.va` leaves a divider midpoint free and expects its unique KCL solution, 1.5 rather than the nodeset 5. It does not prove initial-guess consumption. |
| NODE-005 | 3.6.3.2 | Null bus entries specify no nodeset. A zero cold start cannot distinguish a null entry from an explicit zero. Inspect optional-value propagation and use an independent nonzero host fallback to test the distinction. |
| NODE-006 | 3.6.3.2 | Hierarchical initializers win over nonhierarchical ones; highest hierarchical level wins. Same-level hierarchical conflicts and nonhierarchical conflicts permit races. Do not require one arbitrary source order for those races. Node collapsing and hierarchy must be part of the test. |

## Evidence corrections

`21_net_nodeset.va` prescribes its internal node at 2 between equal resistors
with terminals 3 and 0. It observes device evaluation under that supplied bias,
not a KCL solution. The new free-node fixture solves (mid-3)/1000+mid/1000=0,
giving mid=1.5. Ignoring its nodeset also reaches 1.5: that limits its claim to
non-clamping, but does not invalidate the independent obligation it tests.

The a08 cubic tests expect particular final roots under the generated harness's
Newton/cold-start policy. Those are useful implementation regressions, not
portable proof that every conforming solver must choose the same root. An
implementation can use a nodeset and then apply continuation or different
iteration choices; the quoted source does not specify those choices. The bus
test's zero cold start also cannot distinguish a null from explicit zero.
Their historical spec is marked superseded on these points, with numeric
expectations retained as harness-specific regressions, not weakened to green.

## Source reconciliation still open

The §3.6.3 sentence mentioning only potential access for signal-flow systems
must be read alongside §3.6.2.1's explicit permission for either potential-only
or flow-only disciplines and §1.3.4.2's flow systems. The HTML preserves the
source sentence; this audit does not turn it into a blanket flow-only ban.

A.8.1's pattern productions (physical pages 389–390) were read in extraction
against HTML. They use expressions between commas, not optional individual
elements. The optional whole-pattern production is not an optional-element
production. The older a08 spec's assertion that A.8.3 defines a symbol named
`constant_expression_or_null` is not supported by the supplied PDF extraction
or HTML. The explicit nodeset-null permission remains authoritative; full
grammar reconciliation and a visual Annex A review remain open.

## Recorded execution

The full strict run passes the new free-node non-clamping fixture and both
existing a08 harness-policy regressions. Those current passes supersede their
historical "fails today" statements. The nonempty normalized FAIL/XFAIL name
list is unchanged from the missing-attribute-isolation checkpoint; strict exits
1 for existing gaps. The measurement script refreshes A/C. No closure is claimed
for null-versus-zero discrimination, arbitrary host consumption, precedence,
inherited B or architecture D.

## Ground and implicit-net follow-up

Complete AMS §§3.6.4–3.6.5 text was read against HTML on physical pages 56–57.
Syntax 3-7 was visually checked on page 56; its literal semicolon now has
explicit markup, separate from the optional discipline/range notation.

| ID | Source | Obligation / evidence boundary |
|---|---|---|
| GND-001 | 3.6.4 | Ground applies to an already declared continuous-discipline net. `62_ground_non_continuous.va` now pins E0344 at the ground statement, not a generic failure that could be an analog-profile restriction. Prior-declaration, domainless and range forms remain separate cases. |
| GND-002 | 3.6.4 | The associated node is the global reference, not an independent initially zero unknown. `audit_ground_reference_solution.va` leaves p and the declared reference unprescribed while a separate load-return terminal is fixed at zero; if the named reference were floating, the source/resistor solution would differ. Other disciplines, multiple reference names and hierarchical ground identity remain open. |
| IMP-001 | 3.6.5 | Structural nets may be undeclared and acquire discipline/domain through resolution. `audit_implicit_net_solution.va` probes the corresponding declared child port, so its observation depends on the implicit connection without illegally referencing it behaviorally in the parent. Mixed bindings and the §7.4/Annex F resolution matrix remain open. |

The ground case has a source of 1.5 between p and the declared reference and a
resistor from p to a separate load-return terminal held at zero. With ground identity, p is 1.5.
With a separate floating reference, supernode KCL gives p/1000=0, so p=0 and
the separate reference is -1.5. Neither p nor local_reference is supplied as a bias.

The implicit-net case connects the undeclared parent net to child port b,
with a resistor to child port a connected to the parent's prescribed p=1.5.
KCL at the free endpoint gives b=1.5. `34_implicit_nets.va` remains legal
acceptance evidence but only reads the parent's prescribed p, so it does not
independently establish the implicit net's resolved value.

A temporary source mutation removes only the ground declaration from the new
ground circuit (with a distinct top name for execution). It solves to p=0 and
local_reference=-1.5, and both retained assertions report `ok=0`. This confirms
the fixture distinguishes a floating reference from ground identity under the
test harness. It is a source mutation, not proof against every compiler defect.

The first draft mistakenly used I(p) for the resistor alongside
V(p,local_reference). After ground resolution those name the same branch,
so it did not describe the intended independent source and load. Generated
device inspection showed only the flow contribution surviving; the observed
p=0 was not sufficient evidence of a ground defect. The corrected fixture
uses a distinct load_return terminal. Direct execution then passes both
assertions, and the corrected no-ground mutation still fails both. No compiler
change or relaxation of the expected ground solution was made. The original
draft's full-run result is superseded by a fresh run of the corrected source.

The corrected full strict run passes both new solved-node fixtures and the
pinned E0344 rejection. Its nonempty normalized FAIL/XFAIL name list is identical
to the nodeset checkpoint; strict exits 1 for existing gaps. This supersedes
the interrupted first run and the run containing the invalid ground-test
topology. The measurement script refreshes A/C from the corrected run only.
