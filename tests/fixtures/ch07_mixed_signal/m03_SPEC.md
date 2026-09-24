# M03 — Connectmodule insertion

> **Status (names-wave1, 2026-09-24).** The analog half of §7.8 insertion
> landed in `lib/ir/elaborate/insert.zig`. 01–06, 08, 13 and the new 14 pass;
> 07 was corrected (its net `b` made `u2.din` match two statements under
> §3.11.1, which §7.8.4 refuses) and passes; 09–11 are inserted but still
> XFAIL on the digital half (E1100 / E0920); 12 is unchanged. The ground truth
> below is the state BEFORE that, kept as the audit record.

Pending conformance fixtures for the Verilog-AMS §7.8 connect-module
auto-insertion phase. Nothing here is wired into `zig build torture` yet, and
every file is expected to FAIL today. That is the deliverable.

## Ground truth (audited, not taken from the plan or COVERAGE.md)

The plan's M03 row says "parsing a `connectrules` declaration does not establish
insertion support". That is exactly the state of the tree.

What VerA **does** have, verified by reading the source:

| thing | where | what it does |
|---|---|---|
| `connectmodule` keyword | `lib/frontend/token.zig:117`, `parser.zig:206` | parses as A.1.2's third `module_keyword`; sets `Ast.Module.is_connect` |
| `connectrules` block | `lib/frontend/parser.zig:248`, `ast.zig:868-940` | parses into `Ast.ConnectRulesDecl` (`ConnectInsertion`, `ConnectResolution`) |
| connect_mode / `#(...)` / port overrides | `lib/frontend/ast.zig:884-900` | parsed into fields whose own doc comment says they are carried for round-tripping and have no consumer |
| `E0915` | `lib/ir/elaborate.zig:1646-1657` | the ONLY semantic check on a `connect_insertion`: the named identifier must exist and must be declared `connectmodule` |
| `connect … resolveto` | `lib/ir/elaborate.zig:1610-1638` | genuinely implemented — exact/subset matching, source-order tie-break, `exclude` (E0916); unit tests at `elaborate.zig:2591-2695` |

What VerA **does not** have — insertion itself is declared absent in the file's
own header, `lib/ir/elaborate.zig:54-58`:

> "The §7.8 connect-module INSERTION phase is also not here, deliberately and
> without a fixture owed: VerA emits ONE analog device, §7.6 puts insertion
> after the resolution this file performs, and a bridge needs the digital kernel
> the artifact does not contain — so §7.7.1 insertion statements are validated
> (E0915) and then configure nothing."

**Module instantiation is NOT a blocker and this document used to say it was.**
`tests/fixtures/ch06_hierarchy/module_instantiation_unsupported.va` keeps its
legacy filename but its own header says it is "no longer a `//! reject`", and
measured: 9 of the 11 positive fixtures here elaborate their hierarchy, solve,
and print a failing `ok=0` on their own assertion. `$analog_node_alias` is not a
blocker either — §9.20 is implemented at `lib/ir/lower.zig:8352` and
`:8861-9000`; fixture 10's alias call simply never runs because the connect
module that contains it is never instantiated.

The one adjacent gap that is real: a digital process item (`always`, `assign`)
in a module that also has an analog block is E0205, and there is no digital
kernel in the emitted device. That is load-bearing for exactly two fixtures
(09's `assign d = 1'b1` and 11's two `always` blocks, which are the digital
halves the fixtures are about). It used to stop eight more at E0205 through
scaffolding none of them read — see "Corrected after review" item 7.

So `discipline resolution` (§7.7.2, the input to insertion) is real and tested;
`insertion` (§7.8, the output) is greenfield. The existing ch07 fixtures
`connect_mode_accepted.va`, `connect_parameter_accepted.va`,
`connectmodule_accepted.va`, `supply_hierarchical_connectmodule.va` and
`connect_generated_defparam_unsupported.va` each say in their own headers that
they pin PARSING only and explicitly disclaim the behavior. This row supplies
the behavior.

## LRM clauses covered

| clause | subject |
|---|---|
| §7.5 | connect modules exist and are inserted by the tool |
| §7.6 | connect module descriptions; Table 7-2 direction pairs; Examples 1–3. **Example 1 is the `d2a`** (ddiscrete `input in`, electrical `output out`) and covers a mixed *output* port whose upper connection is electrical; **Example 2 is the `a2d`** (electrical `input in`, ddiscrete `output out`) and covers a mixed *input* port whose upper connection is electrical; Example 3 is the inout/inout `bidir` |
| §7.7.1 | `connect_insertion`; `connect_port_overrides` (discipline and direction) |
| §7.7.3 | parameter passing attribute on a connect statement |
| §7.7.4 | `connect_mode` |
| §7.8 | automatic insertion; "one shall be discrete and the other continuous" |
| §7.8.1 | selection is hierarchical, per level |
| §7.8.2 | signal segmentation; "there shall never be more than one analog node representing a signal"; Figure 7-7 port loading |
| §7.8.3 | `connect_mode` parameter; "the default is merged" |
| §7.8.3.1 | merged: one instance, "provided the module is the same" |
| §7.8.3.2 | split: one instance per port |
| §7.8.4 | the four insertion rules; single analog node; upper-connection context; "one (and only one) connect statement" |
| §7.8.5 | generated instance names, both spellings; defparam reachability |
| §7.8.5.1 | cited by 05 for its first two sentences only — "in the cases of instances of modules … the port name is the name of the signal at the lower connection of the port", which is what fixes `PortName` in `SigName__InstName__PortName`. The clause's six bullets (built-in primitive port names) are **not** claimed by this row |
| §7.8.6 | supply-sensitive connect modules; string parameter set via connect rules |
| §9.20 | `$analog_node_alias`, "shall refer to the same circuit matrix position" |
| §6.3.1 | `defparam` targets an instance anywhere in the design |
| §6.7.1 | hierarchical access-function terminals |
| §3.11.1 | Natureless / Domain Incompatibility discipline rules |

## How an insertion count is turned into a number

An inserted instance is invisible from source. Fixtures 01–08 therefore make the
insertion count the only free variable in a resistive DC solve:

* the connect module's analog half is §7.8.2 Figure 7-7's port-loading model —
  one `rin` to ground per inserted instance;
* the top module supplies a 1 kΩ shunt and a 1 mA source.

KCL at the analog node with `N` bridges of 1 kΩ:
`V/1000 − 1e−3 + N·V/1000 = 0`, i.e. **V = 1/(N+1) volts**.

The shunt is there so a compiler that inserts nothing yields a finite *wrong*
answer (1.0 V) rather than a singular matrix — the fixture must fail on its
assertion, not on a solver crash.

## Fixtures

| file | pins | expected value and derivation |
|---|---|---|
| `01_merged_is_the_default_one_instance.va` | §7.8.3 "the default is merged"; §7.8.4 merged sharing | two `ddiscrete` input ports on one `electrical` signal, no `connect_mode` written → N=1 → **V(a)=0.5**. Wrong answers: 0.333 (split), 1.0 (no insertion) |
| `02_split_one_instance_per_port.va` | §7.8.3.2 / §7.8.4 "one connect module instance per port" | byte-for-byte identical to 01 except the word `split` → N=2 → **V(a)=1/3=0.33333333333333331** |
| `03_merged_groups_per_connect_module.va` | §7.8.3.1 "provided the module is the same"; the digital state reaching the bridge | 2 `ddiscrete` inputs (a2d, 1 kΩ, merged into one) + 1 `ddiscrete` output (d2a, 2 kΩ, its own instance, **digital value 1**, so a 2 V Thevenin behind 2 kΩ). `V·(1/1000+1/1000+1/2000) = 1e−3 + 2.0/2000`, i.e. `V·2.5e−3 = 2.0e−3` → **V(a)=0.8**. A bridge blind to the digital state (x, or an `initial` that never ran) reads 0.4; one merged a2d for the whole net 0.5; one merged d2a 1.333…; three instances 0.5714285714285714; nothing inserted 1.0 |
| `04_merged_generated_name_defparam.va` | §7.8.5 `SigName__ModuleName__BottomDiscipline`; §6.3.1 defparam into a generated instance | `defparam a__m03_a2d__ddiscrete.rin = 2000` on the single merged bridge. `V·(1/1000+1/2000)=1e−3` → **V(a)=2/3=0.66666666666666663**. A misspelled generated name is a defparam onto a nonexistent target, i.e. a compile error, so it cannot pass silently |
| `05_split_generated_names_defparam.va` | §7.8.5 `SigName__InstName__PortName`; the two split names must be DISTINCT | `defparam a__u1__din.rin = 3000`, `a__u2__din` left at 1000. `V·(3+1+3)/3000=1e−3` → **V(a)=3/7=0.42857142857142855**. Field order taken from §7.8.5.1's first two sentences — port name = the name of the signal at the port's lower connection, i.e. the formal port name — plus §7.8.4's definition of the upper connection for `SigName` |
| `06_connect_rule_parameter_is_applied.va` | §7.7.3 — the override must REACH the inserted instance, not merely parse | one port, merged, `connect m03_a2d #(.rin(2500.0));`. `V·(1/1000+1/2500)=1e−3` → **V(a)=5/7=0.71428571428571430**. Dropped override → 0.5 |
| `07_discipline_and_direction_overrides.va` | §7.7.1 the discipline `connect_port_overrides` form | net `a`: `inout electrical, inout m03_cmos_io`, rio=4000 → **V(a)=0.8**. Nothing inserted → 1.0. The override does not change which port matches (m03_cmos_io is §3.11.1-compatible with ddiscrete), and the header says so. **Corrected:** net `b` used to share this file; the inout/inout statement also matched `u2.din` (all natureless discrete disciplines are compatible), so the port matched two statements and a conforming tool refuses the file (§7.8.4, E0922). Moved to 14 |
| `14_direction_override_redirects_a_bridge.va` | §7.7.1 the direction `connect_port_overrides` form; §7.7.3 | `m03_a2d` (a2d role) re-directed `output electrical, input ddiscrete` into the d2a role bridges an OUTPUT port, rin=1500 → **V(b)=0.6**. Override ignored → no match → 1.0; parameter list dropped → 0.5 |
| `08_inserted_at_upper_connection_level.va` | §7.8.4 "instantiated in the context of the port's upper connection"; §7.8.1 per-level insertion | `top → mid → leaf`; only `leaf.d` is mixed, so the bridge lands in `mid`. `defparam mid.n__m03_a2d__ddiscrete.rin = 3000;` — the leading `mid.` and the SigName `n` (not `a`) are both assertions. `V·(1/1000+1/3000)=1e−3` → **V(a)=0.75** |
| `09_analog_signal_is_never_segmented.va` | §7.8.2 / §7.8.4 "a mixed signal is represented in the analog domain by a single node" | `ddiscrete` signal at top, two `electrical` input ports loaded 1 kΩ and 3 kΩ, one merged d2a (2 V behind 1 kΩ). One node: `(V−2)/1000+V/1000+V/3000=0` → **V(u1.p)=V(u2.p)=6/7=0.85714285714285710**. Segmented would give 1.0 and 1.5 — both the common value and the equality are the assertion |
| `10_supply_sensitive_bridge_via_connect_rule.va` | §7.8.6 + §9.20: string parameter set by the connect rule, `$analog_node_alias` to a hierarchical supply, **and the aliased node being the same matrix position rather than the same value** | supply is 3.0 V behind `rs=100 Ω`; the bridge's pull-up is a branch `I(el,vdd) <+ V(el,vdd)/1000` through the aliased node, so its current is drawn from the supply. `V_vdd = 2·V_a` and `10(V_vdd−3)+(V_vdd−V_vdd/2)=0` → **V($root.m03_top.sup.vdd)=20/7=2.857142857142857** and **V(a)=10/7=1.4285714285714286**. Alias failed → 0.0 / 3.0; alias by value instead of by matrix position → 1.5 / 3.0; nothing inserted → 0.0 / 3.0 |
| `11_both_halves_of_the_bridge_execute.va` | §7.8/§7.5 "the connect module defines the conversion" — the inserted instance's discrete AND continuous halves must run | the bridge's analog contribution reads `lvl`, a reg only its own `always @(cm)` sets, and drives `vlow + (vsup−vlow)·lvl` with **`vlow = 0.5`** behind 1 kΩ into 1 kΩ. chain 1 `~0=1` → **V(y1)=1.0**; chain 2 `~1=0` → **V(y2)=0.25**. Nothing inserted → 0.0/0.0; stuck bridge or a never-run inverter → 0.25/0.25; dropped inversion → 0.25/1.0 |
| `12_reject_two_continuous_disciplines.va` (reject) | §7.8 "when two disciplines are specified in a connect statement, one shall be discrete and the other continuous" | `connect m03_cm electrical, m03_elec2;` with both continuous. §7.7.2's `resolveto` form is the one that legitimately names two same-domain disciplines, so the two `connectrules_item` forms cannot be collapsed |
| `13_reject_ambiguous_connect_statements.va` (reject) | §7.8.4 "the port shall match one (and only one) connect statement" | two connect modules with identical port disciplines and directions, both matching `u1.din`. Their `rin` differ (1 kΩ vs 4 kΩ) on purpose: silently picking one makes the node voltage depend on source order. §7.7.2.1's "first match wins with a warning" is stated for discipline RESOLUTION and does not reach the selection step |

12 positive fixtures, 2 reject fixtures.

### Reject-fixture expectation text

VerA has no diagnostic code for either rule — `E0915` only checks that the
identifier a `connect_insertion` names is a declared `connectmodule`. Both files
carry the RULE as the `//! reject` substring and say so in their headers. When
the selection step is implemented, replace those substrings with the allocated
codes. Do not replace them with an incidental parse error: both files are
grammatical and every identifier in them is declared, so the refusal must come
from §7.8 / §7.8.4 and nothing else.

Neither is a bare `//! reject`: each names a substring of the rule it expects,
so it cannot be satisfied by an unrelated diagnostic. Re-measured today — `vera
--check` on **both** files exits 0 with no diagnostic at all (13 lost its
incidental E0205 when the dead scaffolding went, so neither file can now be
satisfied by an accident of the front end). That is the row's genuine gap.

## Corrected after review

An adversarial review of this row found six defects (items 1–5 below; item 6
records what it did not dispute). Items 7 and 8 are two more found while
checking its findings against the clause and against a run. Every number below
was re-derived by hand and then re-run against VerA's own residual/Jacobian dump
for the explicit post-insertion topology — see "Arithmetic check" — rather than
copied from the review.

1. **§7.6 Examples 1 and 2 were swapped in four files** (`01`, `03`, `11`, `13`;
   `09` already had it right). Opening §7.6: Example 1 is the `d2a` — ddiscrete
   `input in`, electrical `output out` — and it is the one that bridges "a mixed
   output port whose upper connection is compatible with discipline electrical
   and whose lower connection is compatible with ddiscrete". Example 2 is the
   `a2d` and is the one that bridges the mirror *input* port. `01`, `05`'s
   neighbours and `13` all bridge a ddiscrete INPUT port on an electrical
   signal, so their cite is Example **2**; `11`'s is a ddiscrete OUTPUT port, so
   its cite is Example **1**; `03` has one of each and had both backwards. Each
   header now quotes the sentence it relies on and says the old number was wrong.
   A fifth instance the review did not list was found with the clause open:
   `07:50` called the re-directed a2d role "§7.6 Example 1"; it is Example 2, and
   is corrected the same way. `07:31`'s Example 3 (inout/inout `bidir`),
   `09:14`'s Example 1 and `06:8`/`09:47`'s §7.8.3.2 Example 3 were all already
   right and are unchanged.
2. **`05`'s §7.8.5.1 worked example was fabricated and is withdrawn.** §7.8.5.1
   contains no `and gate_instance(y, a, b)` and no `a__gate_instance__in1`; it is
   one paragraph plus six bullets naming ports of *built-in digital primitives*,
   and `grep -rn gate_instance docs/` matches only Annex A nonterminals. The
   conclusion (`a__u1__din`, `a__u2__din`) is unchanged and the `//! lrm 7.8.5.1`
   cite is kept, but on different evidence: §7.8.5.1's first two sentences, "in
   the cases of instances of modules and instances of UDPs, port names are well
   defined … the port name is the name of the signal at the lower connection of
   the port", which fix `PortName` as the formal port name; §7.8.4's upper/lower
   connection definition fixes `SigName`; `InstName` is then the only field left.
   **Where the withdrawn claim went:** §7.8.5.1's actual content — generated port
   names for built-in gates, switches and pass transistors — is claimed by NO row
   in this batch. It stays with the digital-primitive work
   (`tests/fixtures/ch07_mixed_signal/primitive_generated_ports_unsupported.va`)
   and can return here only once a gate primitive can be instantiated, at which
   point one fixture per naming bullet becomes writable.
3. **`10`'s first assertion had no teeth and now does.** `V($root.m03_top.sup.vdd)
   == 3.0` against `analog V(vdd) <+ 3.0;` is true of every implementation —
   captured at HEAD as `got=3 want=3 ok=1` with insertion, aliasing and the
   digital kernel all absent. It also tested the wrong thing: §9.20 says an
   aliased node "shall refer to the same circuit **matrix position**", which is a
   claim about current, and a value-copying alias would have satisfied the old
   check. The supply is now `I(vdd) <+ (V(vdd) − 3.0)/rs` with `rs = 100 Ω` and
   the bridge's pull-up is a branch `I(el, vdd) <+ V(el, vdd)/rout` *through* the
   aliased node. Re-derived: `V_a = V_vdd/2` from KCL at `a`, substituted into
   KCL at `vdd` gives `10(V_vdd − 3) + V_vdd/2 = 0`, `10.5·V_vdd = 30`,
   **`V_vdd = 20/7 = 2.857142857142857`**, **`V_a = 10/7 = 1.4285714285714286`**.
   3.0 — the old want — is now exactly the feature-absent reading. Both checks
   report `ok=0` at HEAD.
4. **`11`'s `V(y2) = 0.0` had no teeth and now reads 0.25.** Zero is what a stuck
   bridge, a bridge whose digital half never ran, and no insertion at all all
   produce, because the top's 1 kΩ shunt pulls an undriven net to 0. The d2a's
   output-low level is the connect module's own behavior — §7.6 and §7.8 fix no
   levels — so it is now `vlow = 0.5 V`, making the low state a value only a
   real bridge produces: `(V − 0.5)/1000 + V/1000 = 0` → **`V(y2) = 0.25`**.
   `V(y1) = 1.0` is unchanged. Disclosed in the header: `y2` still cannot
   separate "the `always` ran and wrote 0" from "the 1'b0 seed stands"; that is
   `y1`'s job and the pair is the fixture.
5. **`03`'s stated claim was false and the design is changed to make it true.**
   The header said its 0.4 "asserts that the inserted bridge SEES the digital
   state"; it did not — 0.4 is also what `cm` at x and an `initial` that never
   ran produce. `u3` now drives `1'b1`, so the d2a injects `2.0/2000 = 1 mA`:
   `V·2.5e−3 = 1e−3 + 1e−3` → **`V(a) = 0.8`**, and 0.4 becomes a failing value.
   The separating table is re-derived with the new source term: one merged a2d
   for the net 0.5, one merged d2a 1.333…, three instances `2e−3/3.5e−3 =
   0.5714285714285714`, nothing inserted 1.0.
6. **No expected value was changed except the three above.** `01`, `02`, `04`,
   `05`, `06`, `07`, `08`, `09`, `12` keep their expected values; the review did
   not dispute them and re-deriving them reproduced the printed digits (the
   transcript below is the re-derivation, run rather than asserted).
7. **Dead digital scaffolding removed from eight fixtures** (`01`, `02`, `03`,
   `04`, `05`, `06`, `07` ×2, `08`, `13`). Each child module carried
   `reg seen; initial seen = 1'b0; always @(port) seen = 1'b1;` that nothing
   read. Its only effect was E0205 ("unsupported module item: found `always`"),
   which stopped the file before it reached the assertion the fixture exists to
   make — a fixture that fails on an unrelated missing feature pins nothing.
   Insertion is selected from the two connections' disciplines and the port
   direction (§7.8.4); no digital process is required to make a `ddiscrete` port
   a receiver. With the scaffolding gone, all eight elaborate and **fail on their
   own numbers** (captured below); `09`'s `assign` and `11`'s two `always` blocks
   are kept because they ARE those fixtures' subject.
8. **Four `//! xfail` reasons stated a blocker that does not exist.** `01`, `02`,
   `03` and `08` said "no module instantiation", `01` citing
   `ch06_hierarchy/module_instantiation_unsupported.va` — a file whose own header
   says it is no longer a rejection, and whose feature demonstrably works here.
   `10` said "no `$analog_node_alias`"; §9.20 is implemented
   (`lib/ir/lower.zig:8352`). All five now name the single real blocker, §7.8
   insertion, and quote the value the fixture reads without it.

Where the review and this row **agree but the wording mattered**: the review
called `05`'s conclusion survivable "via §7.8.5's template". It is not quite —
§7.8.5's split sentence literally swaps its own two nouns ("InstName and
PortName are the local instance name of the port and its instance respectively"),
so §7.8.5 alone cannot settle field order. §7.8.5.1's first two sentences can,
and that is what the file now cites.

### Arithmetic check — captured, not asserted

Every expected value in the table was re-derived by hand and then re-run: each
post-insertion topology was written out explicitly (the bridge as ordinary
`analog I(...) <+ ...` contributions, since insertion is what is missing) and
solved. Command, verbatim:

```sh
./zig-out/bin/vera --emit-exe --contract tools/contract.zig -I tests/fixtures /tmp/m03chk/x10.va
```

```
10 vdd got=2.857142857142857 want=2.857142857142857 ok=1
10 a   got=1.4285714285714286 want=1.4285714285714286 ok=1
  res[a]   = 0.000000e0   d res[a]/d x[a]     = 2.000000e-3   d res[a]/d x[vdd]   = -1.000000e-3
  res[vdd] = 6.505213e-19  d res[vdd]/d x[a]  = -1.000000e-3  d res[vdd]/d x[vdd] = 1.100000e-2
03 got=0.8  want=0.8  ok=1      (d res[a]/d x[a] = 2.500000e-3, res = -2e-3 at x=0)
11 y1 got=1    want=1    ok=1
11 y2 got=0.25 want=0.25 ok=1
01 got=0.5                want=0.5                ok=1
02 got=0.3333333333333333 want=0.3333333333333333 ok=1
04 got=0.6666666666666666 want=0.6666666666666666 ok=1
05 got=0.4285714285714286 want=0.42857142857142855 ok=1
06 got=0.7142857142857143 want=0.7142857142857143 ok=1
07b got=0.6000000000000001 want=0.6              ok=1
08 got=0.75               want=0.75              ok=1
09 got=0.8571428571428571 want=0.8571428571428571 ok=1
```

The Jacobian rows are the linear systems the headers derive:
`1.1e−2·V_vdd − 1e−3·V_a = 3e−2` with `−1e−3·V_vdd + 2e−3·V_a = 0` gives 20/7 and
10/7; `2.5e−3·V = 2e−3` gives 0.8; `2e−3·V = 2e−3` gives 1.0; `2e−3·V = 5e−4`
gives 0.25. Two wants are 1 ULP from the solver's digits (`05`, `07`'s net `b`);
both tolerances are 1e−12, four orders above that, so no want is tightened to a
bit pattern.

### What the row reads at HEAD

Captured with the command in "Build / run" below, so the "expected to FAIL" claim
is a measurement rather than a plan. Each line is the fixture failing on its own
assertion, not on a missing unrelated feature:

```
01 merged is the default …                      got=1 want=0.5                ok=0
02 split inserts one a2d PER PORT …             got=1 want=0.3333333333333333 ok=0
03 merged groups per SELECTED MODULE …          got=1 want=0.8                ok=0
06 §7.7.3 #(.rin(2500)) … reaches the a2d       got=1 want=0.7142857142857143 ok=0
07 discipline override … rio=4k                 got=1 want=0.8                ok=0
07 direction override … rio=1.5k                got=1 want=0.6                ok=0
10 current drawn from the SUPPLY NODE itself    got=3 want=2.857142857142857  ok=0
10 the connect rule's string parameter aliases  got=0 want=1.4285714285714286 ok=0
```

`04`, `05` and `08` stop earlier, at `E0907: override names no parameter of the
module: 'a__m03_a2d__ddiscrete.rin' names no parameter of the elaborated design`
— the §7.8.5 generated name does not exist, which is precisely what they pin.
`09` and `11` stop at `E0205: unsupported module item` on the digital process
that is their subject. `12` and `13` are refused by nothing: `vera --check` exits
**0 with no diagnostic at all**.

## Deliberately NOT covered

* **`split` instance count when the ports are analog.** §7.8.3.2 Example 3 says
  only that "there is no segmentation of the signal between these ports, since
  the ports have discipline electrical", which constrains the NODE count and
  leaves the INSTANCE count unstated. Fixture 09 therefore uses `merged`, where
  §7.8.4 fixes the count at one.
* **The a2d direction's digital half at a DC operating point.** §7.8's own
  `elect_to_logic` derives its state from `@(cross(…))`, and a crossing does not
  occur in a DC solve. What the discrete side holds at time zero is mixed-signal
  initialization (rows M01/M02), not insertion. The a2d direction's *analog*
  half is pinned by 01–08.
* **§7.8.5.1 generated port names for built-in primitives.** The convention lives
  entirely in identifier text; `tests/fixtures/ch07_mixed_signal/primitive_generated_ports_unsupported.va`
  already argues why one fixture per gate family would be the same test six
  times, and no digital primitive can be instantiated yet anyway.
* **§7.8.1 Figure 7-6's basic-vs-detail coercion cases.** The clause itself says
  "the selection of these discipline resolution modes shall be vendor-specific"
  (§7.4.4), so the two- vs three- vs five-bridge answers are not portable
  requirements. Fixture 08 pins the part that is: the level a bridge lands at.
* **Driver/receiver segregation** (§7.8.4 bullet 2, §7.9) — that is row M04.
* **Timing.** Every fixture is a DC operating point. `transition()` ramps,
  `cross()` thresholds and bridge delays need the mixed-signal scheduler
  (rows M01/M02) and would make these fixtures test that instead.
* **Undeclared-net discipline resolution feeding insertion** (§7.4.4.1/§7.4.4.2).
  Every net here has an explicit discipline, so the fixtures isolate insertion
  from resolution. Resolution already has fixtures and unit tests.
* **Error when a connect statement names a parameter the connect module does not
  declare.** §7.7.3 implies it but names no diagnostic.

## Build / run

No move is needed to run one file — `-I tests/fixtures` is what resolves
`check.vh`, and this is how every transcript in this document was captured:

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build install
./zig-out/bin/vera --check --contract tools/contract.zig -I tests/fixtures \
    tests/pending/M03/01_merged_is_the_default_one_instance.va
P=$(./zig-out/bin/vera --emit-exe --contract tools/contract.zig -I tests/fixtures \
    tests/pending/M03/01_merged_is_the_default_one_instance.va 2>/dev/null); "$P"
```

(`--emit-exe` prints the binary path on stdout and diagnostics on stderr, so the
two must be captured separately.)

`options.fixture_root` is hard-wired to `tests/fixtures` in `build.zig:428`, so
the *torture runner* — the thing that reads `//! reject` and `//! xfail` — only
sees these once moved:

```sh
cd /home/omare/Documents/Projects/Zig/VerA
cp tests/pending/M03/*.va tests/fixtures/ch07_mixed_signal/
zig build torture -- ch07_mixed_signal --strict
```

Every one of the 13 is expected to FAIL there today. **Do not commit that copy**
until they pass — `zig build torture -- --strict` is currently green at
1323/1323 and these would break the gate.

To run one at a time while implementing:

```sh
zig build torture -- 01_merged_is_the_default -j1
```

Each positive fixture also carries an `//! xfail <reason>` line naming the
missing capability, so if they are landed before the feature is complete they
report as known gaps under a non-strict run rather than as regressions.
