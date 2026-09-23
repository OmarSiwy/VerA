# Nature and discipline source/evidence worklist

Review date: 2026-09-23. Complete AMS §3.6 introduction and §§3.6.1–3.6.1.3
(physical pages 47–50) read against the HTML. Syntax 3-4 on physical page 47
was visually checked; literal colon, optional semicolon, member dot, assignment
and attribute semicolon now have explicit HTML markup. A follow-up reads the
complete §3.6.2 introduction and §§3.6.2.1–3.6.2.4 (physical pages 50–53),
including the motor example, then completes §§3.6.2.5–3.6.2.7 on physical
pages 53–54. Syntax 3-5 was visually checked on page 50; literal punctuation
now has explicit markup. §3.6.3 and following material remain pending complete
review at that checkpoint. The later §§3.8–3.11.1 source review is recorded
below; no complete compatibility evidence matrix is claimed.

## Partial rule inventory

| ID | Source | Obligation and evidence boundary |
|---|---|---|
| NAT-001 | 3.6 | Contiguous analog/mixed net segments share a physical node governed by simultaneous conservation equations. Declaration acceptance cannot prove node collapsing, hierarchy or coupled KCL/KPL behavior. See the scheduling ledger for solved-node evidence. |
| NAT-002 | 3.6.1 | Nature declarations are top-level, non-nesting, uniquely named and delimited by nature/endnature. Each nesting context and duplicate-name case needs its own source-valid negative; cross-kind namespace collision is not the same rule. |
| NAT-003 | 3.6.1.1 | A derived nature inherits from an already declared parent, can add attributes and can override only permitted attributes. `36_derived_nature_inheritance.va` observes inherited access on a biased net; it does not observe every inherited attribute. Forward parents, cycles, multi-level inheritance and discipline-member parents need separate mapping. |
| NAT-004 | 3.6.1.2 abstol | Base natures require a real constant tolerance; derived natures may replace it or inherit it. `10_nature_declarations.va` declares a replacement but only asserts access-function values, not solver tolerance selection. Numeric attribute access and actual convergence use are separate evidence requirements. |
| NAT-005 | 3.6.1.2 access | Base natures require an identifier access name; derived natures inherit and may not change it. `65_nature_access_as_string.va` pins E0340 for the string form. Existing inherited-access positives do not prove every invalid override or potential/flow binding. |
| NAT-006 | 3.6.1.2 idt_nature | Optional reference defaults to the nature itself; explicit self-reference is legal. Other references name defined natures, not strings. Derived overrides must share the base nature of the parent's integral reference. The reference-name, resolution, default, ancestry and solver-tolerance observations are distinct cases. |
| NAT-007 | 3.6.1.2 ddt_nature | The analogous derivative-reference rules apply independently. Integral-reference fixtures cannot establish derivative-reference handling merely because source wording is parallel. |
| NAT-008 | 3.6.1.2 units | Base natures require a string; derived natures cannot define or change it. `65_nature_units_as_identifier.va` pins E0340 for the identifier form. Unit inheritance, compatibility and simulator annotations are not proved by access-function numeric values. |
| NAT-009 | 3.6.1.3 | User-defined attribute names are unique within the nature being defined. `68_duplicate_user_attribute.va` pins E0343 for duplicate declarations; overriding an inherited user attribute is a different, permitted case under §3.6.1.1. |
| NAT-010 | 3.6.1.3 | User-defined values are constant expressions. `68_nonconstant_user_attribute.va` pins E0340 for an unresolved name. That is one invalid-expression form, not the complete constant-expression matrix. Valid computed constants and inherited/replaced values need behavioral observations. |

Fixture names without chapter prefixes refer to `tests/fixtures/ch03_data_types`.
This inventory is deliberately split by externally observable rule. Existence
of a source declaration or a clause citation is not a recorded behavioral result.

## Discipline requirement groups still requiring evidence mapping

| ID | Source | Obligation / distinction |
|---|---|---|
| DISC-001 | 3.6.2 | Unique top-level discipline declarations do not nest. Behavioral analog nodes require a discipline; interconnect/digital declarations have different rules. Hierarchical overrides of explicit disciplines require compatibility, not merely an existing target. |
| DISC-002 | 3.6.2.1 | Potential and flow bindings select their nature's respective access functions and conservation laws. Conservative disciplines cannot bind the same nature to both roles. Either single role creates a signal-flow discipline; potential-only and flow-only behavior require independent evidence. |
| DISC-003 | 3.6.2.2 | Domain is discrete or continuous; nature bindings imply continuous when omitted and prohibit explicit discrete. Continuous real-valued semantics and discrete four-state/integer/real semantics require runtime tests beyond attribute acceptance. |
| DISC-004 | 3.6.2.3 | Natureless disciplines may have a domain; domainless ones have neither domain nor nature bindings. Deprecated/discouraged does not mean illegal in this edition. Connectivity determines unresolved domains under §7.4/Annex F, which remain separate audit dependencies. |
| DISC-005 | 3.6.2.4 | Undeclared interconnect and behavioral references have distinct net-type/domain defaults. An interconnect wire type still participates in inherited net-type resolution if its resolved domain is discrete. Mixed/continuous unresolved discipline and domain require resolution, not arbitrary electrical/discrete defaults. |
| DISC-006 | 3.6.2.5 | Discipline overrides require a defined bound nature and attribute and retain §3.6.1.2 restrictions. Potential and flow overrides must affect the selected binding, not globally mutate the source nature or its other consumers. |
| DISC-007 | 3.6.2.6 | A nature derived from a discipline's potential/flow inherits that binding's attributes, including discipline overrides, and follows changes to the bound nature. Its own permitted replacements remain distinct. An inherited access probe cannot alone verify inherited modified tolerance. |
| DISC-008 | 3.6.2.7 | Disciplines may have user-defined attributes, with §3.6.1.3 referenced for their purpose. Attribute storage, lookup and inherited/default behavior need separate grammar and evidence mapping; nature-only tests do not prove discipline handling. |

The motor example's equations and units are retained from the source, not used
as an independently validated physics oracle. Its `vsine` dependency is not
defined in that example. Independent multi-discipline fixtures must derive
their observations from the applicable language and conservation rules.

## Rejection oracle correction

Direct `--check --contract` execution independently reports E0340 at the access
string, units identifier and unresolved user-attribute value, and E0343 at the
duplicate user attribute. Each process exits 1 for the intended attribute.
The four fixtures now pin those codes instead of `DiagnosticsReported`, and
their obsolete assertions that no relevant diagnostic exists are removed.
No compiler behavior or valid-language expectation is changed.

## Positive evidence limits

`36_derived_nature_inheritance.va` uses ParentV on a net bound to the child
nature and observes the host's 0.75 bias. This tests inherited access lookup
and probe binding, not inherited abstol or units. Its imposed bias also must
not be credited as a solver response to its zero contribution.

`10_nature_declarations.va` declares an abstol override and an added maxval,
but asserts only a voltage difference through inherited access. Those extra
declarations are accepted syntax, not independent observations of their values
or use. Removing maxval would leave its assertion unchanged. The full
attribute/compatibility/tolerance matrix remains open.

The missing-base-attribute fixtures `35_base_nature_required_attributes.va`
and `57_base_nature_missing_{access,units}.va` previously also declared
potential-only signal-flow ports as `inout`, contrary to §1.3.4.1. Their ports
are now `output`, which permits their potential contributions. Their E0332
expectations and missing attributes are unchanged. Direct execution reports
only the intended missing abstol, access or units diagnostic in each case.

Independent temporary source controls add only the respective missing attribute
to each corrected program: abstol=1u, access=PresentV or units="V". All compile
with exit 0. This verifies the negative cases are not still failing because of
another required declaration error. These acceptance controls are not credited
as runtime evidence for tolerance use, access binding or units compatibility.
Repository fixtures retain their missing attributes and rejection expectations.

`66_idt_nature_self_reference.va` accepts explicit integral self-reference and
observes access and the DC initial condition. Its header correctly distinguishes
the numeric initial-condition result from tolerance selection. Deleting the
self-reference attribute would leave those numbers unchanged, since the source
default is self-reference; this case is legal explicit-syntax evidence with
behavioral controls, not a discriminator for default/reference resolution.

The full strict run passes all four strengthened attribute rejection fixtures.
Its exit remains 1, and its nonempty normalized FAIL/XFAIL name list is identical
to the genvar checkpoint. The measurement script refreshes A/C; these oracle
improvements do not add behavioral closure for inherited B or architecture D.

After the missing-attribute isolation edits, all three E0332 fixtures pass in
the full strict run. Its nonempty normalized FAIL/XFAIL name list is identical
to the attribute-pin checkpoint, and strict still exits 1 for existing gaps.
The script refreshes A/C; isolated invalid-input evidence is stronger without
changing the behavioral pass count or closing the broader attribute matrix.

## Defaults, precedence and compatibility follow-up

Complete §§3.8–3.11.1 text (physical pages 58–61), including the compatibility
examples and observations, was read against HTML. The two-column declaration
example on page 60 was visually checked. The PDF's missing closing parenthesis
in the Discrete Domain Rule remains visible in the transcription; it is not a
reason to invent a different compatibility rule.

| ID | Source | Obligation / evidence boundary |
|---|---|---|
| RES-001 | 3.8 | Default discipline applies to discrete nets lacking an explicit discipline as part of resolution. `ch10_directives/01_default_discipline.va` and `02_default_discipline_qualified.va` deliberately use explicit electrical nets, so they observe noninterference, not assignment of defaults to unresolved digital nets. |
| RES-002 | 3.9 | Digital primitive lower connections require known discrete disciplines; unresolved mixed-net digital connections require a specified default or an error. VPI connection identity and resolution evidence are needed, not just directive parsing. |
| RES-003 | 3.9 | Analog primitive discipline priority is instance port_discipline, then compatible connected continuous disciplines, then electrical fallback when none are connected. Follow E.3.2.2 separately; module-net tests do not establish primitive behavior. |
| RES-004 | 3.10 | Out-of-module declarations outrank local declarations, which outrank resolution. Two different disciplines at the same precedence level are illegal. This ordering does not waive §3.6.2's compatibility requirement for an explicit discipline override. |
| COMP-001 | 3.11 | Discrete signal-value type and discipline compatibility both matter. Cross-domain connections need an applicable connect statement; same-domain incompatible connections are errors. Resolution/connection semantics need §7.4 and inherited digital evidence. |
| COMP-002 | 3.11.1 | Disciplines are self-compatible; natureless disciplines are compatible within their domain; domainless disciplines are compatible absent nature/domain conflict. Distinguish these cases from merely identical concrete bindings. |
| COMP-003 | 3.11.1 | Domain mismatch, potential incompatibility and flow incompatibility are separate reasons for discipline incompatibility. `54_incompatible_nets_access.va` now pins E0355 for the potential case; `audit_incompatible_flow_natures_rejected.va` isolates the flow case with identical potential bindings and valid V access at both endpoints. |
| COMP-004 | 3.11.1 | Nature compatibility includes self, missing binding, base/derived relationship, common base and equal units. `76_nature_compatibility_rules.va` maps base/sibling/equal-potential-units cases. The new `audit_compatible_flow_units.va` separately tests unrelated flow bases with equal units through legal common potential access. Missing-binding and all connectivity contexts remain independently open. |

The flow negative uses Current versus an unrelated nature with units "s";
direct execution reports E0355 and explicitly identifies Flow Incompatibility
at V(p,other). The positive uses an unrelated base with units "A", distinct
access name OtherCurrent, and the same Voltage potential binding. Its biased
node difference must be 1.25 and reverse -1.25. This observes legal access over
compatible disciplines, not solved mixed-domain connectivity or unit conversion.

The old negative's generic `DiagnosticsReported` and claim that no compatibility
diagnostic exists are removed. The expected incompatibility is unchanged; no
compiler behavior changes in this checkpoint.

Targeted execution of the legal equal-flow-units fixture reports `ok=1` for
both forward and reversed potential access. The invalid-flow fixture exits 1
with the intended E0355. These results establish the isolated pair, not the
remaining resolution/precedence matrix; the full-suite comparison is pending.

The completed full strict run passes both new flow cases and the tightened
potential-incompatibility rejection. Its nonempty normalized FAIL/XFAIL name
list is identical to the ground checkpoint; strict exits 1 for existing gaps.
The measurement script refreshes A/C. This closes the pending run comparison,
not the remaining compatibility, primitive or precedence requirements.
