# IEEE informative and removed-material disposition

Source review on 2026-09-23, against the supplied licensed IEEE1364-2005
PDF. This is an applicability inventory, not executed conformance evidence
and not an exclusion based on the present implementation's capabilities.
Read the main authority inventory in `conformance-ieee-authority-review.md`
alongside this report. IEEE and AMS annex letters must always be qualified:
they name different content and carry different authority.

## Exact source boundaries

Complete text AND every original PDF page visually reviewed at 1000-pixel
rendering for these complete units:

| IEEE unit | Printed pages | Physical PDF pages | Status in source |
|---|---|---|---|
| Clauses21–25 | 369–373 | 399–403 | Deprecated headings and references only |
| AnnexC, C.1–C.13 | 511–517 | 541–547 | Informative system tasks/functions |
| AnnexD, D.1–D.6 | 518–519 | 548–549 | Informative compiler directives |
| AnnexE | 520 | 550 | acc_user.h, normative heading retained, deprecated contents removed |
| AnnexF | 521 | 551 | veriuser.h, normative heading retained, deprecated contents removed |
| AnnexH, H.1–H.3.2 | 537–541 | 567–571 | Informative encryption/decryption flows |
| AnnexI | 542 | 572 | Informative bibliography, single B1 entry |

Supplementary text read: IEEE1.5–1.8,20.1,27.3 reset-control definition;
AMS AnnexC in full and AMS12.5/12.36 relevant inherited references.
Those supplementary readings are not a fresh visual audit or a complete
audit of IEEE27/AMS12. No licensed source was copied into Git.

## Authority and profile boundaries

IEEE AnnexesC/D explicitly state that their contents are not part of the
standard and need not be available in all implementations. Their internal
use of mandatory-sounding language does not override that scope statement.
Standalone support claims belong to an explicitly advertised extension
profile, unless a normative clause separately incorporates a behavior.
Absence of support is not a reason to invent a required-rejection fixture:
an implementation can provide extensions, and user-defined system tasks
have a separate normative PLI registration mechanism.

The user's full AMS goal is not restricted to the analog subset. AMS
AnnexC defines a separate normative Verilog-A profile: C.11 includes
analog-context Clause9 tasks, C.12 Clause10 directives, and C.13–C.14 the
analog behavior of the VPI chapters. Therefore neither the analog profile
nor IEEE informative status is a blanket exclusion for host behavior.
Digital and mixed-signal obligations still belong to the full AMS inventory.
AMS AnnexC's explicit exclusions and its reserved-keyword rules must not be
replaced by an implementation's current unsupported-feature list.

| ID | Source | Disposition and retained boundary |
|---|---|---|
| DISP-001 | IEEE C.1 | `$countdrivers` is an informative extension: scalar/bit net selection, contention result, force status and optional separate 0/1/x driver counts. Not a substitute for mandatory AMS9.20 driver-access functions or VPI driver/load relationships. |
| DISP-002 | IEEE C.2 | `$getpattern` is an informative memory-element-to-scalar-concatenation continuous-assignment accelerator. Mandatory `$readmemb`/`$readmemh` and ordinary continuous-assignment semantics remain independent. |
| DISP-003 | IEEE C.3–C.6 | `$input`, `$key`/`$nokey`, `$list`, `$log`/`$nolog` describe interactive command input, input recording, source listing and output logging. Do not require these source-language task names merely because normative VPI output/flush APIs mention output channels or log buffers. Audit the API contract itself. |
| DISP-004 | IEEE C.7 | Standalone `$reset`, `$reset_count`, `$reset_value` are informative. However IEEE27.3 and AMS12.36 explicitly specify reset control behavior; that normative dependency remains OPEN, as detailed below. |
| DISP-005 | IEEE C.8 | `$save`, `$restart`, `$incsave` describe complete and incremental checkpoint extensions, dependency on the last full save, and changed/missing-file limitations. No general mandatory checkpoint implementation follows from this annex. |
| DISP-006 | IEEE C.9–C.12 | `$scale`, `$scope`, `$showscopes`, `$showvars` are informative time-unit conversion and interactive scope/introspection helpers. Normative timescale conversion, hierarchy and VPI scope/property operations remain in scope independently. |
| DISP-007 | IEEE C.13 | `$sreadmemb`/`$sreadmemh` are informative string-based memory initialization tasks, distinct from required file-based memory tasks. Sharing a data format does not promote these names to required built-ins. |
| DISP-008 | IEEE D.1–D.2 | `default_decay_time` and `default_trireg_strength` are informative overrides. The described infinite-decay option and integer strength range do not remove normal normative trireg/charge-storage requirements or create required rejection tests for these extensions. |
| DISP-009 | IEEE D.3–D.6 | `delay_mode_distributed`, `delay_mode_path`, `delay_mode_unit`, `delay_mode_zero` are informative source-order/module delay-mode controls. Mandatory specify/distributed delay behavior remains governed by the normative clauses, not conditional on implementing these directive spellings. |
| DISP-010 | IEEE H.1 | Tool-vendor embedded-secret-key scenario, its input/output pragmas and optional metadata/license/digest fields are informative workflow guidance. Not a mandate for a vendor-specific key database. Normative Clause28 protection-envelope rules remain separately required where applicable. |
| DISP-011 | IEEE H.2 | IP-author public/private-key scenario and example output are informative. Do not turn an example's particular distribution of private keys into a universal implementation/security requirement. Resolve actual algorithms, syntax and licensing against Clause28. |
| DISP-012 | IEEE H.3 | Digital envelopes explain symmetric data encryption, encrypted key blocks and multi-recipient packaging, including alternative named/raw data-key approaches. These are not exact golden ciphertexts or an independent exhaustive cryptographic specification; external algorithm and normative pragma obligations remain open. |
| DISP-013 | IEEE I | B1 is IEEE1497-2001 SDF. Bibliographic placement is informative, not a Clause2 normative-reference entry. Required behavior must be traced through Clause16 and the relevant annotation task/routine clauses; lack of the external source is a verification gap, not an SDF exemption. |
| DISP-014 | IEEE1.6,20.1,21–25,E/F | TF/ACC text was removed and redirected to the2001 edition. Retained normative annex headings do not provide current ABI/behavior definitions. No TF/ACC completion claim or requirement to reject such extensions follows. Any historical compatibility promise needs the2001 source and separate audit. Current VPI Clauses26/27/AnnexG remain normative. |

## Normative dependency that survives informative placement

IEEE27.3, printed421, defines `vpi_control(vpiReset, ...)`: reset occurs
after the application routine returns, with three extra integer arguments
corresponding to C.7. Consequently classifying all reset behavior as optional
because C is informative would drop an explicit normative API obligation.
C.7 supplies the referenced reset meaning: stop concurrent activity and
scheduled events, restore time-zero initial state and restart initial/always
processing; the stop argument determines interactive versus immediate
processing, while reset value communicates across reset and diagnostic
level controls messages. API timing, lifecycle, value preservation channel
and legal controls need phase-correct host evidence. This review does not
claim that every standalone source task in C.7 thereby becomes required.

AMS12.36 similarly lists `vpiReset` in `vpi_sim_control` but cites IEEE
F.7. In the2005 edition F is the removed veriuser.h annex; the matching
reset description is C.7. Preserve the source citation and flag its stale
edition mapping rather than pretending F.7 exists. The existing Chapter12
review already records this reference problem; this report supplies the
verified2005 target and applicability consequence.

AMS12.5 also refers to IEEE AnnexC for integer VPI property values. IEEE2005
AnnexC has no such definitions; its normative VPI header is AnnexG.
This is another edition-sensitive source-reference defect, not a reason to
source property constants from the informative tasks annex or discard the
mandatory property return-value contract. Keep source text distinct from
editorial cross-reference resolution.

## Source examples are not normative test oracles

Visually checked potential traps, without silently correcting the source:

- C.2's illustrative memory range starts at1 but the loop uses
  `index < patterns`; copying that example does not prove loading every
  pattern or complete `$readmem` behavior.
- C.8 comments mention increments of10000 and recycling after40000, while
  the statements show `#100000`. No runtime golden is derived from the
  contradictory comments.
- TableC.1's caption says `$countdriver` singular; the actual function
  heading and syntax say `$countdrivers`.
- H output lists include `encrypt_license`, while the optional-input lists
  include `runtime_license`. H.3 prose uses `key_keymethod` once and
  `key_method` elsewhere; H.3.2 prose spells `data_key_owner`, unlike
  `data_keyowner`. Treat these as informative-source anomalies and verify
  normative token spellings in Clause28 before writing acceptance/rejection
  cases. Do not create new pragma names from a prose typo.

## AMS annex identities are independent

IEEE C/D/E/F/H/I must not be conflated with AMS annexes of the same letters.
AMS C is the normative analog subset; D contains normative standard
definitions; E normative SPICE compatibility; F normative discipline
resolution. AMS H is a glossary, not IEEE encryption-flow guidance.
AMS C.17 applies D to both profiles except discrete-domain definitions
(silently ignored in the analog subset), and C.18 applies SPICE compatibility
to both. IEEE TF/ACC removal therefore does not remove AMS E/F obligations.

No production code or fixture bodies were changed. No new unsupported-name
negative tests were added: these dispositions do not establish such an
oracle. No full builds, A/C measurements, host execution or exhaustive
dependency closure is claimed. Remaining work: integrate these authority
rows into the normative ledger; maintain the explicit reset/VPI and
SDF/cryptography dependencies; acquire historical or external sources only
where their particular applicable obligations require verification.

## Root handoff boundary

The main agent read this complete report and retained it on 2026-09-23.
Complete visual traversals above remain attributed to the worker; root source
authority text review is recorded separately. These disposition rows do not
constitute executable evidence or a finished atomic obligation ledger.
