# Inherited user-defined primitive audit

Reviewed 2026-09-23: complete IEEE 1364-2005 **Clause8, User-defined
primitives (UDPs)**, printed105–115 / physical135–145. Read every paragraph,
syntax production, table, example and caption; individually inspected every
page rendered at1400 pixels. Visual review includes Syntax8-1/8-2, every
Table8-1/8-2/8-3 cell, and Figure8-1's schematic, shaded unknown intervals,
time0 UDP initialization and time3/time5 fanout propagation. This is full
Clause8 source/visual review, **not** exhaustive implementation/test closure.
Licensed source provenance is recorded in `conformance-ieee1364.md`.

Also read complete extracted IEEE §5.1.13, printed53–54 / physical83–84,
including Table5-21, to verify a misleading existing UDP fixture rationale.
That additional subsection has text review only here. Clause8's §7.1 instance
connection dependency and broader strength/delay semantics remain dependencies,
not implicitly source-verified by reading their cross-references.

## Atomic obligation groups and evidence

| ID | IEEE clause | Obligation / evidence boundary |
|---|---|---|
| UDP-001 | 8 introduction | One output; only0/1/x output states; sequential output equals internal state. Existing comb/latch/dff transcripts are intended behavior, not evidence of implemented UDP execution. |
| UDP-002 | 8 / 8.1.5 | External inputz behaves asx, while literalz is forbidden in table syntax. Existing comb test covers runtime intention; new isolated input-z rejection has a legal input-x declaration control. |
| UDP-003 | 8.1 | Definitions exist outside modules, before or after use. No declaration-inside-module negative or definition-after-use runtime witness here. |
| UDP-004 | 8.1 | Implementations must support at least256 definitions even if imposing a limit. No generated stress witness supplied. |
| UDP-005 | 8.1.1 / Syntax8-1 | Both header styles, closing syntax and declaration/body forms are permitted. Parser tests record acceptance; runtime instantiation remains absent. |
| UDP-006 | 8.1.1 | Scalar-only ports; exactly one output, first; no inout. Shape-specific invalid declarations remain open. |
| UDP-007 | 8.1.2 | Sequential output must be reg; combinational output must not be reg. Parser discards parts of declaration information; complete validation not established. |
| UDP-008 | 8.1.2 | At least9 sequential and10 combinational inputs supported. Boundary runtime/stress evidence missing. |
| UDP-009 | 8.1.3 / 8.5 | Optional sequential initializer targets the output reg and uses the permitted literal forms; no delay or general block. Parser currently parses a general expression and discards target identity; invalid matrix needed. |
| UDP-010 | 8.1.4 | Row input ordering follows header, not port-declaration order. New asymmetric reversed-declaration runtime fixture is blocked at instantiation. |
| UDP-011 | 8.1.4 | Combinational row has input fields plus output; sequential adds exactly one current-state field. Parser checks colon count, but not complete field cardinality/port consistency. |
| UDP-012 | 8.1.4 / 8.4 | At most one input edge descriptor per sequential row. New isolated two-edge definition control is incorrectly accepted; matching one-edge control is accepted. |
| UDP-013 | 8.1.4 | Specifying all inputs asx requires outputx. No isolated rejection/positive pair for this requirement here. Do not conflate an initial state before an input event with a matching explicit all-x row. |
| UDP-014 | 8.1.4 / 8.2 / 8.4 | Unspecified input combinations/transitions producex, not retained state. Existing comb/latch tests intend this; sparse new header-order test also includes missing00. |
| UDP-015 | 8.1.4 | Same input/edge combination must not specify conflicting outputs. Apply alongside the explicit mixed edge/level dominance rules, not as a blanket prohibition of their permitted overlap. Validation remains open. |
| UDP-016 | 8.1.6 Table8-1 | Level? expands0/1/x; b expands0/1; neither is an output symbol. Existing wildcard witness is not full symbol-position matrix. |
| UDP-017 | 8.1.6 Table8-1 | Hyphen means retained state only in sequential next-state field. Existing latch/dff intended observations remain blocked. |
| UDP-018 | 8.1.6 / 8.4 | Parenthesized edges describe value changes; r/f are01/10, star is any change, p/n include their stated unknown transitions. New p/n fixture includes0z andz1 after z→x conversion. Complete expansion/state matrix missing. |
| UDP-019 | Syntax8-1 | Uppercase X/B/R/F/P/N alternatives are permitted; syntax allows exactly one edge indicator surrounded by levels. Alphabet acceptance is weaker than structured edge parsing. |
| UDP-020 | 8.2 | Combinational output depends only on current inputs and reevaluates on changes. Existing mux fixture is useful despite its incorrect ternary comparison rationale. |
| UDP-021 | 8.3 | Sequential levels use current state to derive next state; stored state must persist between input changes. No new independent level-only runtime oracle here. |
| UDP-022 | 8.4 | Non-output-changing edges require explicit hold rows; absent transitions lose state tox. Do not invent an implicit hold/default retention. Existing dff's table deliberately adds holds, not a universal flop requirement. |
| UDP-023 | 8.5 | UDP instance delay does not delay initial state assignment. New delayed-instance positive expects seeded1 before delay5, but parser fails legal scalar delay spelling. |
| UDP-024 | 8.5 Figure8-1 | Initial output propagates through connected gate delays separately. Figure demonstrates3/5 delays; no exact new host/runtime witness here. |
| UDP-025 | 8.6 Syntax8-2 | Optional instance names, drive strengths, at most two delays, multiple instances and ranges; connection rules inherit7.1. Named UDP instances currently take module-resolution path and fail. |
| UDP-026 | 8.7 / 8.8 | Edge cases process before levels; conflicting permitted edge/level behavior resolves to the level case. New fixture explicitly distinguishes this from first-matching-row selection. |

## Production inspection and actual outcomes

Read current root parser `parseUdpDecl`, `parseUdpTable` and row checks, plus
the digital source executor/instance dispatch. Definition rows survive in the
AST, but no UDP table-matching execution path was found. Alphabet/colon checks
do not validate all table structure. Some declaration fields/initializer target
are consumed without retention. Avoid claiming the parser's comments prove
port/row shape checking: its character loop permits more than one edge, and
current-state storage uses the first character without enforcing one character.

New digital fixture/transcript pairs:

- `audit_udp_header_order`: header `(out,first,second)` but input declarations
  reverse the two inputs. Rows01→1 and10→0 distinguish ordering; absent00 and
  z0→x0 yieldx. Expected transcript1,0,x,x. Direct root `vera --run` exits1,
  E1100 `undeclared module in instantiation`, at the named UDP instance.
- `audit_udp_potential_edges_dominance`: p sets1, n sets0; gate0 level forces0,
  gatex forcesx. Drive one input per step. Clockx→0 gives0;0→z maps0→x and
  gives1;z→1 mapsx→1 and gives1;1→x gives0; finally0→1 with gate0 stays0
  by level dominance despite the p row. Expected0,1,1,0,0. Direct run exits1
  with the same E1100 instance-resolution failure, before transitions execute.
- `audit_udp_initial_instance_delay`: initializer1, untouched input regs,
  instance delay5; observe1 at time1. Direct run exits1/E0207 because the
  named instance's legal `#5` syntax is read as requiring a parenthesized
  module parameter override. This is parser-phase failure, not observed
  incorrect initialization timing.

New digital negative `audit_udp_input_z_rejected.v` is explicitly routed to
the digital runner and requires E0233 plus `not a UDP input symbol`. It defines
an uninstantiated primitive so unavailable UDP execution cannot mask syntax.
Direct run exits1 with that intended diagnostic. Single-symbol legal neighbor
`tools/udp-audit-controls/input_x_legal.v` exits0 and prints
`definition accepted`. This is definition-validation evidence only, not positive
UDP runtime coverage.

`tools/udp-audit-controls/one_edge_legal.v` and `two_edges_invalid.v` differ
only in the second input being level0 or edge(10), alongside first edge(01).
Both direct runs exit0 and print `definition accepted`. The invalid acceptance
directly exposes UDP-012; no unavailable-instance failure masks it. Kept these
as diagnostic controls because the digital-negative runner has no XFAIL support
and no rule-specific implemented rejection exists to assert. The obligation is
not silently dropped or called conformant.

## Existing fixture claims requiring correction

UDP-RATIONALE-001: `d08_udp_comb.v` claims a ternary with unknown selector
returnsx even when its two alternatives agree. IEEE5.1.13/Table5-21 preserve
matching known bits. Its table/transcript still exercise UDP matching; withdraw
only that claimed contrast, not the actual mux behavior.

UDP-SHAPE-001: `d08_reject_udp_comb_edge.v` claims its sole defect is an edge
in a combinational row, but its fallback `? ? : 0` also covers all-x with a
known output and overlaps the intended edge case with a different output.
Mechanically replacing `(01)` with a level does not create a legal neighbor.
Existing diagnostics may still isolate the edge spelling, but the rationale
must not claim all other rules are satisfied. A repaired fixture should use a
nonoverlapping legal fallback and a separately verified legal counterpart.

Existing negatives also refer to unavailable diagnostic codes despite current
E0233/E0234 declarations. They remain legacy analog-compilation-path fixtures,
not automatically digital rejection evidence. This handoff does not silently
change their expectations or migrate their runner.

The source's Table8-1 n expansion visibly omits the closing parenthesis after
x0; Syntax8-1 and the semantic expansion make the intended transition clear.
This is recorded as source typography, not copied as malformed fixture syntax.

## Remaining dependencies and handoff boundary

Default uninitialized sequential state, simultaneous changes/ordering, all
expanded wildcard/edge combinations, every illegal table shape, declarations,
capacity minima, arrays, strengths, propagation delays and module connection
rules still need evidence. A source-complete read is not an exhaustive test
matrix, and finite fixtures cannot be treated as a proof of all implementations.

Only this report, new `audit_udp_*` files and the three diagnostic controls are
part of this handoff. Existing fixtures and `src/sim/digital.zig` were unchanged.
No full builds/suites were run. Main integration owns complete FAIL-name
comparison and measured conformance outputs.

## Root review checkpoint

Main read this report, all new fixture/control sources and the complete extracted
IEEE Clause8 text on 2026-09-23. Main did not repeat the worker's full visual
inspection. Fixture integration, existing rationale corrections and independent
root suite execution remain pending. Main independently ran the three new
legal UDP positives: header-order and edge-dominance programs fail E1100 at
instantiation; initial-delay program fails E0207 at `#5`. The input-z negative
fails with both E0233 and its intended phrase. Legal input-x and one-edge
definition controls print `definition accepted`; the two-edge invalid also
prints that text and exits zero. These match the worker observations. They
remain targeted runs on worker fixture paths, not an integrated suite result.

The new UDP fixtures and controls are now integrated. The existing mux header's
false ternary contrast is corrected without changing its body or transcript.
The combinational-edge negative replaces its independent invalid wildcard
fallback with disjoint `1 1 : 0`; a new definition-only legal control replaces
only the edge by level1. Root runs confirm that control prints acceptance and
exits zero, while the repaired negative exits one with E0234 plus both existing
required phrases. Neither runtime UDP support nor full table validation is
credited by these parser controls.
