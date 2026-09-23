# Inherited IEEE Clause 7 primitive audit

2026-09-23. Source docs/1364-2005.pdf SHA256
3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e.
First bounded group: complete §§7.1–7.8, printed74–86 (physical104–116),
including declaration syntax, connection rules, truth tables and CMOS
equivalence. Visually inspected physical111–114 Tables7-3/4/5/6. Syntax7-1,
Tables7-1/2 and array schematic Figure7-1 have text review only at this
checkpoint. Second group completes text review of §§7.9–7.14.2.2,
printed86–104 (physical116–134), through the boundary before Clause8.
Additional visual checks: physical117 Table7-7; physical120 Figures7-6/7/8;
physical122 Figures7-12/13/14; physical130 Table7-8; physical131–132
Table7-9 including its continuation. This does not claim visual inspection
of every Clause7 figure or source-fidelity closure of inherited prose.

## Source distinctions

Primitive arrays require an instance name, constant continuous range and
abs(left-right)+1 instances. Equal single-instance terminal widths broadcast;
larger expressions partition from the right-hand range index; mismatched
width is an error. Nonzero/ascending bounds are expressly permitted.

N-input gates have one output and at least one input; buf/not have at least
one output and one final input. Enabled gates and MOS switches differ on
z data: enabled bufif produces x whereas conducting nmos passes z. L/H
represent strength-ambiguous0-or-z/1-or-z outcomes, not license to choose a
random definite output. Four-state-only observation does not close their
strength-sensitive resolution behavior.

Bidirectional tran/rtran have no delay specification; controlled variants'
delays control switching, not propagation of data while conducting. Their
terminals must be scalar nets or bit-selects. CMOS is parallel nmos/pmos;
nc=0,pc=1 turns both off, while either conducting arm can pass data.
Pull sources default to pull strength, ignore the opposite-polarity strength
if present, and cannot have delay specifications.

## Evidence

All paths below are tests/fixtures/digital. Current root vera --run was used;
positive expected transcripts remain normative when execution rejects them.
No working digital XFAIL mechanism is assumed.

| ID / fixture | Source obligation | Observed result |
|---|---|---|
| PRIM-ARRAY-001 / audit_primitive_array_broadcast.v | §§7.1.5/6 ascending[4:7] and descending[7:4] arrays partition data, broadcast scalar enable. | E0207 rejects legal array bracket at parsing. Three-line positive transcript retained. |
| PRIM-TRAN-001 / audit_primitive_tran_both_directions.v | §7.6 bidirectional conduction from either endpoint; both undriven givesz. | E1100 switch unsupported before behavior. Three-line positive transcript retained. |
| PRIM-PULL-001 / audit_primitive_pull_delay_rejected.v | §§7.1.3/7.8 prohibit pull delay. | E0207 at forbidden#, exit1. Rejection substring pins that token error, not generic unsupported execution. |

Fresh existing runs compared byte-for-byte with current-root expected files:
d08_gates_ninput (20lines), d08_gates_noutput (4lines), d08_gates_enable
(16lines) all exit0 and match. Existing d08_switch_mos and d08_switch_cmos
exit1 E1100 unsupported switches before behavior. Their source truth-table
derivations were read; they supply intended oracles, not measured success.
Assertions that resistive versions never change value apply only to these
isolated outputs; competing drivers can make strength reduction change the
resolved value. No broad strength claim is accepted from matching columns.

## Remaining independent cases in this group

- Syntax7-1 gate-class terminal arities; permitted strength/delay classes;
  both strength polarity orders, illegal dualhighz; pull optional irrelevant
  polarity; anonymous single instances versus required array names.
- Shared strength/delay across comma-listed instances; all array directions,
  equal-bound singleton, nonconstant bounds, same-name disjoint ranges,
  scalar broadcast/partition/too-few/too-many terminals.
- Complete four-state truth cells, higher arities and unchanged delay versus
  input count; multiple buf outputs; independent delays for rise/fall/z/x/H/L.
- MOS resistance and strength transfer, bidirectional conflicts, controlled
  turn-on/off timing and no conducting-data propagation delay; unknown enable
  with strength-aware resolution; CMOS/rcmos equivalence under all controls.
- Pull defaults and explicit strength, ignored opposite polarity; separate
  invalid pull/tran delays and illegal strength on switch-only classes.

This is source/evidence accounting, not an exhaustive denominator. No compiler
implementation or shared chapter HTML was changed. Earlier assignment and
scanner handoffs remain separate.

## Strength and delay source review: §§7.9–7.14

Table7-7 orders supply7, strong6, pull5, large4, weak3, medium2, small1,
highz0. Charge strengths are not legal drive-strength spellings. Resolution
of defined unequal strengths chooses the stronger value; equal opposite
values give x on ordinary nets. Wired logic has its own equal-strength rule.
H/L are strength ranges, not ordinary x: definite pull1 combined with strong
H remains known1 (range5..6), and the complementary case remains known0.
The interval-combination rules in §7.10.3 must retain possible strength
endpoints; testing only isolated four-state truth-table cells misses this.

§7.11 nonresistive devices preserve strength EXCEPT supply becomes strong.
Table7-8 resistive reduction is supply/strong→pull, pull→weak,
large/weak→medium, medium→small, small→small, highz→highz. Thus neither
"unchanged for all nonresistive inputs" nor "every resistive input loses
at least one level" is a correct general rule. §7.13 supplies tri0/tri1
pull defaults, trireg medium default charge, and supply-net strengths.

§7.14 and Table7-9 distinguish rise/fall/turn-off and all twelve four-state
transitions. With three delays, a transition to x uses their minimum;
with two, x and z transitions use min(rise,fall). Strength changes do not
alter the delay. §7.14.1 permits mintypmax expressions without requiring
numerically ordered min≤typ≤max. §7.14.2 assigns a trireg's third delay to
charge decay, not turn-off; its first two delays cannot be omitted. Decay
starts on entering the capacitive state, expires to x, and is interrupted
by re-driving 0,1 or x. Only initialization or force can leave stored z.

| ID / fixture | Independent source-derived observation | Current root execution |
|---|---|---|
| PRIM-RANGE-001 / audit_primitive_ambiguous_same_polarity.v | §§7.10.2/3 strong H + definite pull1 =>1, strong L + definite pull0 =>0, for x and z controls. Continuous pull-strength drivers isolate this from pull-source primitive support. | Exit0, both lines x,x instead of1,0. Normative expected transcript retained. |
| PRIM-PULL-002 / audit_primitive_pull_ignored_polarity.v | §7.8 explicit pullup strength1 competes with default pulldown pull0; optional strength0 does not affect output. | Exit0, resolved=z,z instead of1,0. This does not by itself isolate whether pull sources are absent or strength selection is wrong. |
| PRIM-DELAY-001 / audit_primitive_three_delay_unknown.v | §7.14/Table7-9 #(5,7,2) bufif1: z→0 after7, 0→1 after5, 1→x after2, x→z after2. Samples avoid event-time races. | Exit0, exact six-line transcript. This is one trajectory, not all transition cells. |

All new positive primitive fixtures explicitly declare 1ns/1ns timescale.
The first group's array/tran files were updated to include this declaration
before final handoff, keeping missing timescale separate from primitive
support. No digital XFAIL marker disguises failed positive transcripts.

Fresh existing executions additionally matched d03_08_trireg_charge_decay
(seven lines), d03_09_trireg_capacitive_hold (six lines), and d06_net_delay
(eight lines), each exit0. The two trireg bodies were inspected: decay is
sampled before/after t60 and after the restarted deadline t112; the no-decay
test retains both driven values after release, including a long hold.
These do not test charge-strength competition or capacitive-network sharing.
The net-delay match is regression evidence only here, not a new independent
certification of every expectation in that fixture.

Existing d08_strength_reduction still exits1 E1100 at unsupported switches.
Its selected strong→pull competition is a valid intended oracle, but the
header overgeneralizes nonresistive preservation (omits supply→strong) and
resistive reduction (small/highz unchanged). Its historical assertion that
the current simulator ignores all strengths is not a current measurement.
Existing trireg headers likewise say declaration/decay support is missing,
contrary to these fresh runs. d03_08's prose calls t49 nine ns before t60
(actually eleven), and says adjacent samples pin the transition exactly to
t60; they bracket it, not prove the exact instant. Expectations remain
unchanged; these prose claims are recorded for scoped maintenance.

## Independent obligations still open after complete text traversal

- All strength-range combinations and order-independent multi-driver
  resolution, including the separate wired-net cases and correlated endpoints.
- Supply degradation through every nonresistive class and every Table7-8
  resistive input level, both polarities and ambiguous ranges.
- tri0/tri1/supply interactions, stored charge strength, connected capacitive
  nets, no spurious z storage and re-drive/decay cancellation by x.
- Every Table7-9 transition for one/two/three delays, controlled-switch
  connection delay versus zero data propagation, and strength-only events.
- Min/typ/max selection and unordered expressions; invalid delay arities
  and omitted trireg rise/fall before decay.

This bounded work adds intended positive and negative evidence, including
measured failures. It does not produce a conformance measure or close Clause7.

## Root integration boundary

2026-09-23: the report and its new primitive fixtures are retained at root.
The pull-delay negative explicitly opts into the digital runner and requires
E0207 plus the forbidden-token diagnostic. The main agent independently reread IEEE sections7.11–7.14
and Table7-8/7-9 text and checked the three legacy fixture headers discussed
above. The supply-to-strong exception, unchanged small/highz strengths, and
the eleven-nanosecond t49-to-t60 interval corroborate the proposed prose
corrections. Those header-only corrections are now applied; executable bodies
and expected transcripts are unchanged. Fresh root unit/digital gates are
complete: root unit gate passes; digital gate adds precisely the four expected
new primitive failures (array, tran, ambiguous same-polarity strength, ignored
pull polarity). The three-delay positive and pull-delay negative pass. No
pre-existing digital failure changes membership. Root logs are
`/tmp/vera-primitives-grammar-{unit,devices}.log`; strict remains running.
