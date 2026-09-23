# Chapter 1 source and evidence review

Main integration checkpoint, 2026-09-23: source HTML, three figures, grammar
color conventions, six diagnostic/header corrections and this ledger are
integrated. Main inspected all three crops and source page 21, regenerated
the figures and confirmed byte identity with the reviewed handoff. Main also
read the signal-flow/probe restriction passages, independently reproduced all
six intended rejections and all six legal-control acceptances, and retained
the controls under `tools/ch1-audit-controls/`. Acceptance controls are not
runtime behavior evidence. Full-suite verification is pending.

Reviewed 2026-09-23 against AMS-2023 printed pages 1–10, physical PDF pages
14–23, from the Chapter 1 heading through the complete §1.5 Annex H entry.
Read all prose, examples and §1.4 conventions against current root
`docs/ch1-intro.html`. Source SHA256:
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
The authoritative digest is the one pinned in `tools/extract_lrm_figures.py`;
the PDF, not this review, controls interpretation.

This is a full Chapter 1 source review, not full evidence closure. The groups
below are an obligation worklist, not a measured conformance denominator.
Finite fixtures cannot guarantee all programs or all host integrations.

## Source fidelity

The mechanical `python3 tools/lrm_audit.py --section 1 --diff` worklist was
read in full. Differences other than figures were line-wrap hyphenation,
list markers, typography and layout; no missing normative prose was found.
Visually inspected physical pages 15–17 (every Chapter 1 figure) and page 21
(all six §1.4 convention examples). Original Figure 1-1 includes the containing
module boundary; Figure 1-2 associates positive flow with the positive-potential
terminal; Figure 1-3 preserves every branch polarity and the signed KPL sum.
All three had previously been replaced by prose. Direct PDF crops now replace
those substitutes and retain the source captions, with separately labeled HTML
source links and accessibility descriptions.

Reproducible crop coordinates, in PDF points from each physical page's top left:

| Figure | Physical page | Left | Top | Width | Height |
|---|---|---|---|---|---|
| 1-1 | 15 | 152 | 349 | 310 | 150 |
| 1-2 | 16 | 163 | 403 | 285 | 104 |
| 1-3 | 17 | 88 | 312 | 436 | 262 |

All final crops were individually viewed and compared with source page renders.
Section 1.4 now renders literal bold characters red and the connectrules
extension production blue, while its literals remain red. Optional/repetition
brackets and alternative bars remain nonliteral. The colors convey the stated
distinction; they do not claim exact PDF RGB reproduction. No numbered syntax
boxes occur in this chapter. No prose correction was silently applied to source
oddities: §1.3.4.2's charge/potential wording and §1.3.5's “signals types” remain
as printed. Main-text/example keyword boldness is not completely normalized;
this is a residual presentational difference, not missing language text.

## Obligation groups and evidence boundaries

| Stable group | Source / physical pages | Evidence and remaining boundary |
|---|---|---|
| INTRO-SCOPE-001 | §§1.1, 1.5 / 14, 21–23 | Full AMS inherits the complete IEEE 1364 specification; Annex C defines the analog subset. IEEE §§17–18 measure B alone is not all inherited obligations. Normative annexes A–F and informative G/H have different roles. |
| INTRO-CONTEXT-001 | §1.2 / 14–15 | `lrm_1_2.va` asserts initial-to-analog integer transfer, not all reads from both contexts, all write restrictions, always scheduling, discipline extension or connect insertion. Those require separate Chapters 5–8 evidence and production host scheduling. |
| INTRO-NODE-001 | §1.3 / 15 | `lrm_1_3.va` checks one all-analog parent/child connection. One shared node across interspersed digital/analog hierarchy remains a separate elaboration/host obligation. |
| INTRO-CONSERVE-001 | §§1.3.1, 1.3.2 / 15–17 | Existing resistor, polarity and KPL examples give finite behavioral witnesses. `04_kirchhoff_flow_sum.va` tests branch accumulation, not KFL at a free shared node. Do not credit it as a node-level solver oracle. |
| INTRO-GROUND-001 | §1.3.1.1 / 16 | Existing 02/24/26 exercise zero reference, shared ground and non-electrical ground. Arbitrary continuous disciplines and hierarchical ground binding remain obligation variants. |
| INTRO-DIRECTION-001 | §1.3.1.2 / 16 | Existing 03/06/23 exercise terminal reversal and flow sign; retained source diagram now supports reviewing polarity derivations. |
| INTRO-NATURE-001 | §1.3.3 / 17 | Units, tolerance, access naming and discipline compatibility refer to Chapter 3; declaration acceptance alone cannot demonstrate tolerance/convergence behavior. |
| INTRO-SF-MISSING-001 | §1.3.4 / 18 | 14 and 19 reject contribution to the missing nature; 22 covers a missing-flow read. Typed and generic access variants, missing-potential reads and connected-node cases need independent evidence. |
| INTRO-SF-DIRECTION-001 | §§1.3.4.1–2 / 18–19 | 15/16 reject inout single-nature ports; 17/18 reject input contributions. 11/12 exercise corresponding potential/flow examples. Conservative-connected source/probe interpretation is not established by a standalone single-nature module. |
| INTRO-LOCAL-001 | §1.3.5 / 19–20 | Source declares only accessed types necessary and only declared types accessible. Cross-reference MIX-LOCAL-001 rather than count it twice: parent custom accessors do not replace an explicitly electrical child's local accessors. Structural-only unspecified natures remain a hierarchy/resolution obligation. |
| INTRO-PROBE-001 | §1.3.1 reference to §5.4.2; actual prohibition §5.4.2.1 / 113 | Fixture20's old quotation was not in §1.3.1. Primary tag moved to §5.4.2.1; same negative evidence retained. §5.4.2.2 allows switching source kind, so a fixture merely containing both potential and flow contributions is not automatically invalid. |
| INTRO-NOTATION-001 | §1.4 / 21 | Documentation convention; test HTML presentation rather than invent runtime language behavior. |
| INTRO-INDEX-001 | §1.5 / 21–23 | Index and annex status, not an independently executable language rule. G/H source fidelity still belongs to the documentation audit. |

## Rejection repairs and controls

No compiler body or fixture semantic body changed. Historical generic
`DiagnosticsReported` matching could pass on an unrelated parser failure.
Six fixtures now require the intended diagnostic text. Obsolete headers claiming
the matching codes were unallocated were removed. Fixture20's invented §1.3.1
quotation and tag moved to the actual rule as recorded above.

| Fixture prefix | Matched diagnostic text | Observed code | Legal-control change |
|---|---|---|---|
| 14 | `binds no flow nature` | E0501 | Contribute V(vonly), not I(vonly). |
| 17 | ``contribution to an `input` signal-flow port`` | E0425 | Read V(inp), contribute only V(outp). |
| 18 | same contribution diagnostic | E0425 | Read I(inp), contribute only I(outp). |
| 19 | `binds no potential nature` | E0501 | Contribute I(ionly), not V(ionly). |
| 20 | `both quantities of a probe branch are read` | E0423 | Read only V(prb). |
| 22 | `binds no flow nature` | E0501 | Read V(vonly), not I(vonly). |

Controls are preserved under `tools/ch1-audit-controls/`, outside the measured
fixture suite. They isolate acceptance, not behavior. Direct root binary checks
from the isolated worktree rejected every repaired fixture with exit 1 and the
intended message; each of the six final controls exited 0. Initial controls 14/19
accidentally sliced a comment's word “module”; this audit-setup error produced
E0207, was corrected to select the actual module declaration, and both reruns
accepted. It supplied no rule evidence. Root source fixture results were also
recorded before changing headers: same six intended diagnostic results.

Reproduction uses root `zig-out/bin/vera --check --contract tools/contract.zig`
with absolute root contract/include paths and absolute worktree fixture paths.
No runtime assertions were executed for this bounded diagnostic repair; no full
Zig builds or strict suites were run by this agent. Main integration owns full
gates and FAIL/XFAIL name-list comparison. No A/C percentage is claimed; the
change improves source fidelity and diagnostic specificity, not closure counts.

`python3 -m unittest discover -s tools -p test_lrm_figures.py` exited 0 with
six tests; `git diff --check` exited 0. The structural tests do not substitute
for the visual inspection described above.

## Handoff

Integrate `docs/ch1-intro.html`, this review, Chapter 1 figure assets, six repaired
fixture headers, `tests/fixtures/ch01_intro/COVERAGE.md`, and the optional control
artifacts. Apply only the three new Chapter 1 entries/test/README paragraph to
the shared figure tools, preserving any newer root edits. Other worktree chapter
files are previous handoffs or test setup and must not overwrite current root.
Chapter 7 and the pending IEEE17.7 handoffs remain unchanged.

Verified asset SHA256:

```text
4be257d6d74105c39c25316f845d4848b1a3be699f0cb7d78436a9290e8845e8  lrm-figure-1-1.png
f0048f13101866c4a7b706081a711c6407620be3df9dc1aa474a2e574e29be9e  lrm-figure-1-2.png
d9e0cdd8ebe19b601b03468ee771b4c3062cf3ef7ae62b3a67732485eec4484f  lrm-figure-1-3.png
```
