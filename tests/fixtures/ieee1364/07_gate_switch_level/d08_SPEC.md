# D08 — Gates, switches and UDPs

Twelve fixtures (ten positive, two reject) for the primitive families and the
user-defined primitive, written against `vera --run` — the digital source
execution path, since none of this has any analog meaning.

## Ground truth as of `ddt-capform` @ 45b505d

Verified by reading the source, not the plan or the COVERAGE files.

**Nothing in D08 is implemented, with one partial exception.**

| what | where | state |
|---|---|---|
| `and nand or nor xor xnor buf not bufif0/1 notif0/1 nmos pmos cmos rnmos rpmos rcmos rtranif0/1 tranif0/1 pullup pulldown pull0 pull1 weak0 weak1 strong0/1 highz0/1 supply0/1 primitive table endtable endprimitive` | `lib/frontend/token.zig:755-800` (`reserved_keywords`) | lexed as `.kw_reserved`, no tag, no production → **E0205** at the first module item |
| `tran`, `rtran` | `token.zig:194-200` (`kw_tran`, `kw_rtran`), `parser.zig:1010`, `parser.zig:1229` `parsePassSwitch` | **the one exception.** A `pass_switch_instance` parses, both terminals are checked to be net references, and then `W0250` says out loud that the connection carries nothing. The comment on the function is explicit: "ACCEPTED AND NOT MODELLED". In digital mode (`--run`) the same function fails immediately with `E1100 switch primitives are not implemented by digital execution`. Nothing is recorded in the AST. |
| UDPs | nowhere | `primitive` is not even in `reserved_keywords`' rejection path at module scope; it hits **E0201** `construct is not in the supported subset: \`primitive\`` |
| strength lattice, strength reduction, charge storage, bidirectional solver, UDP table evaluator | nowhere | `src/sim/digital.zig:99-104` states the ceiling itself: "every driver here is at the SAME strength, so §7.10's eight drive strengths and §7.11's strength resolution are not implemented". `docs/digital-source-execution.md` repeats it and lists "primitives" under open conformance work. |

Every one of the twelve files below therefore fails today, and the failure is a
front-end refusal at the first primitive or `primitive` keyword — confirmed by
running `zig-out/bin/vera --run` on all twelve. The unmerged branch `w2/gates`
adds nothing (empty diff, identical tree to HEAD).

## Where the rules come from

The gate/switch/UDP **syntax** is in the offline LRM HTML and is quoted verbatim
in each fixture header:

| clause | file | what it supplies |
|---|---|---|
| §1.1 | `docs/ch1-intro.html` | "Verilog-AMS HDL consists of the complete IEEE Std 1364 Verilog specification" — the incorporation that makes 1364's clause 7 (gate and switch level modelling) and clause 8 (UDPs) the normative value tables here |
| A.2.2.2 | `docs/annex-a-syntax.html` | `drive_strength`, `strength0`, `strength1`, `charge_strength` |
| A.3.1 | `docs/annex-a-syntax.html` | `gate_instantiation` and all seven instance shapes, including the terminal order of each |
| A.3.2 | `docs/annex-a-syntax.html` | `pullup_strength`, `pulldown_strength` |
| A.3.3 | `docs/annex-a-syntax.html` | `inout_terminal ::= net_lvalue`, `output_terminal`, `input_terminal`, `enable_terminal`, `ncontrol_terminal`, `pcontrol_terminal` |
| A.3.4 | `docs/annex-a-syntax.html` | the seven gate/switch type families |
| A.5.1–A.5.4 | `docs/annex-a-syntax.html` | `udp_declaration`, port list, `combinational_body`/`sequential_body`, `udp_initial_statement`, `edge_indicator`, `edge_symbol`, `output_symbol`, `udp_instantiation` |
| §7.8.5.1 | `docs/ch7-mixed-signal.html` | "Port names for Verilog built-in primitives" — normatively fixes the left-to-right terminal order of the n-input, n-output, 3-port MOS, 4-port CMOS, pass-switch and pull families |
| §8.5.3.5 | `docs/ch8-scheduling.html` | "Switch (transistor) processing": switches "provide bi-directional signal flow and require coordinated processing of nodes connected by switches ... shall consider all the devices in a bidirectional switch-connected net before it can determine the appropriate value for any node on the net" |

The **value tables** themselves are IEEE 1364-2005 clause 7 / clause 8 text,
which is not in the offline HTML. Nothing below cites a 1364 sub-clause number
by guess: each expected cell is derived in its fixture header from rules that
are stated there in full (controlling values, gate-vs-switch z handling, the
eight-level strength lattice and its reduction rule, the UDP wildcard/z/no-match
rules), so a reviewer checks the derivation rather than a section number. The
repo already cites 1364 at this level — `tests/ieee1364/09_behavioral_modeling/control.v` opens with
"IEEE1364-2005 §§9.4–9.6".

## One interpretive choice, stated once

IEEE 1364's tri-state and switch tables use the symbols **L** ("0 or z") and
**H** ("1 or z") for the cells where conduction is unknown. Neither is a member
of the four-state value set `{0,1,x,z}`: L is not 0 (it might be z) and not z
(it might be 0). Every fixture below projects L and H onto **x** in its `%b`
column, which is the only sound projection and is stated in each header where it
is used. Distinguishing L from H needs the `%v` strength format — see "not
covered".

## One line per fixture

All ten positive fixtures print `got=` beside a literal `want=` on every line,
so the assertion lives in the `.v` and not only in the `.expected.txt`.

1. **`d08_gates_ninput.v`** (A.3.1, A.3.4, §7.8.5.1) — the full 4×4 input table
   for `and nand or nor xor xnor`, 16 rows × 6 gates, plus a 3-input `and` and a
   4-input `xor`. Derivation: a gate transmits a logic value, so z on an input
   is x; then and/or have controlling values and xor does not. The
   discriminating cells are `and(0,x)=0` and `or(1,x)=1` against `xor(0,x)=x` —
   a compiler that propagates unknowns uniformly fails the eight rows where one
   input is controlling. Arity rows: `and3(1,1,x)=x`, `xor4(1,1,0,1)=1`.
2. **`d08_gates_noutput.v`** (A.3.1, A.3.4, §7.8.5.1) — `buf b1 (o1,o2,o3,in)`
   and `not n1 (q1,q2,in)`. Expected `buf=000/111/xxx/xxx` and `not=11/00/xx/xx`
   for `in = 0/1/x/z`. Pins the reversed terminal order: buf/not are the only
   primitives whose LAST terminal is the input, so a compiler reusing the
   n-input shape leaves `o1` undriven at z and fails column one on every row.
3. **`d08_gates_enable.v`** (A.3.1, A.3.4) — the full 4×4 data×control table for
   `bufif0 bufif1 notif0 notif1`, 16 rows × 4 gates. Derivation: off-value
   control → z; on-value control → the gate function of the data with z coerced
   to x (so `bufif1(z,1) = x`, **not** z); x/z control → L or H → x. The row
   `d=1 c=0` gives `1 z 0 z`, four different outputs, which is what separates
   the four types from each other.
4. **`d08_switch_mos.v`** (A.3.1, A.3.4, §7.8.5.1) — 4×4 for `nmos pmos rnmos
   rpmos`. Same shape as fixture 3 with one deliberate difference: a switch is a
   connection, so the four `d=z` rows are `z z z z` where the corresponding
   bufif rows are x. That contrast is the fixture. The r- columns equal the
   non-r columns on every cell, pinning that resistance changes strength and
   never value.
5. **`d08_switch_cmos.v`** (A.3.1, A.3.4, §7.8.5.1) — 16 rows of
   `cmos/rcmos (out, data, ncontrol, pcontrol)`. Derived by applying the
   definition literally: `combine(nmos(data,nc), pmos(data,pc))`. Only
   `nc=0, pc=1` isolates (both transistors off) → z; the other three control
   pairs pass the data, including `nc=1, pc=0` where BOTH arms conduct the same
   value and must resolve to it rather than conflict to x. Expected `d=1` row:
   `1 z 1 1`.
6. **`d08_strength_reduction.v`** (A.3.1, A.2.2.2, §7.8.5.1) — four contests
   decided by strength alone, read out as ordinary values. Headline row: a
   `pullup` against an `nmos` passing a reg's 0 gives **0** (St0 beats Pu1),
   while the same `pullup` against an `rnmos` gives **x** (the r- switch reduces
   strong to pull, so Pu0 meets Pu1 at equal strength). A build with one
   strength for all drivers cannot produce two different answers from those two
   nets. Also: `pulldown` + `bufif1` driving strong 1 → 1; `pullup` +
   `buf (weak0, weak1)` driving 0 → **1**, the reverse outcome, so the pair pins
   that the lattice and not "gate beats pull" decides. Depends on D03, which the
   plan (line 60) still records as open.
7. **`d08_bidirectional.v`** (A.3.1, A.3.3, A.3.4, §8.5.3.5) — a `tran` joining
   two tri-state drivers and a `tranif1` gating an isolated net. Expected
   `na nb` = `z z` (both off), `1 1` (value travels left→right), `0 0` (travels
   right→left), `x x` (two strong opposite drivers on ONE node — §8.5.3.5's
   "the inputs and outputs interact"). Rows 2 and 3 are opposite in direction so
   a one-way implementation fails exactly one of them. `tranif1`: `gt=0` →
   `nc=1 nd=z`, `gt=1` → `1 1`, `gt=x` → `1 x` (nd is H; nc keeps its own strong
   1 either way). This is the fixture that fails against today's `W0250`
   accept-and-drop `tran`, which leaves `nb` at z in row 2.
8. **`d08_udp_comb.v`** (A.5.1–A.5.4) — a 2:1 mux UDP, nine stimulus rows each
   naming the table entry it selects. Pins: `?` covers x as well as 0/1
   (`sel=0 a=1 b=x` → 1); z on a UDP input is converted to x *before* lookup,
   including against a literal `x` symbol (`sel=z a=1 b=1` → 1 via the `x 1 1`
   entry); no matching entry → **x** (`sel=x a=0 b=1`); and that unmatched
   result is x and not z.
9. **`d08_udp_latch.v`** (A.5.1–A.5.3) — level-sensitive sequential UDP, a
   transparent-low D latch, nine steps. Pins `initial q = 1'b0` (step s1 samples
   at t=1 before any input event has occurred, so the seeded 0 must stand where
   a bare reg would read x), `-` as no-change (s2/s5/s6), history-dependent
   state (s3→s4→s7), and no-match destroying a good state to x (s8, `clk=x`)
   followed by recovery to 1 (s9). Transcript: `0 0 1 0 0 0 1 x 1`.
10. **`d08_udp_dff.v`** (A.5.1–A.5.3) — edge-sensitive sequential UDP, a
    rising-edge D flip-flop, ten steps, exactly one input changed per step so no
    step depends on simultaneous-change ordering. Pins `(01)` firing on that
    transition only (s4 loads 1, s7 loads 0), `? (??)` holding across d changes
    (s3/s5/s8 — s5 is the discriminator: d falls while q is 1 and q must stay
    1), `(10)` holding on the falling edge (s6), and `(x0)` handling the edge out
    of the initial x (s2). Transcript: `0 0 0 1 1 1 0 0 0 1` — q changes only at
    the three rising edges.

Two rejects, both on invalid UDP tables, both citing A.5.3 verbatim:

11. **`d08_reject_udp_z_output.v`** (`//! reject output symbol`) — `... : z ;` in
    a combinational entry. A.5.3: `output_symbol ::= 0 | 1 | x | X`. Nothing
    else in the primitive is malformed. This is the rule that makes fixture 8's
    "unmatched → x, not z" assertion mean something.
12. **`d08_reject_udp_comb_edge.v`** (`//! reject combinational` **and**
    `//! reject edge`) — `(01) 0 : 1 ;` in a combinational body. A.5.3:
    `combinational_entry ::= level_input_list : output_symbol ;` and
    `level_input_list ::= level_symbol { level_symbol }`; `edge_indicator`
    reaches only `sequential_entry`. The primitive has no `output reg` and no
    current-state column, so there is no history for an edge to compare against.

**Neither reject names a diagnostic code, on purpose.** `lib/diag_code.zig` has
no code for a UDP table alphabet or table shape violation, and a fixtures-only
row may not mint one in `src/`. The patterns above are message substrings, which
`tests/torture.zig:235-243` matches against a diagnostic's message, its caret
label, its notes and its catalogue title. Multiple `//! reject` lines are a
CONJUNCTION (`verifyRejected`, torture.zig:142-150), which is what gives fixture
12 its teeth: a "combinational UDPs are not supported" refusal matches
`combinational` and not `edge`, so a sequential-only implementation cannot claim
it. Prose pins wording where a code pins the rule; both fixture headers say so
and instruct the implementer to allocate the code and *replace* the line rather
than delete it.

**Both rejects fail today, and now for a stated reason.** `vera --run` refuses
them with `E0201 construct is not in the supported subset: \`primitive\``, whose
message, point and catalogue title contain none of `output symbol`,
`combinational` or `edge`. Before the review they carried
`//! reject DiagnosticsReported`, which E0201 satisfies outright — so they
passed vacuously then and do not now. They become real evidence once `primitive`
parses at all, which is why the count is two against ten positives and not the
reverse.

## Deliberately NOT covered

- **Gate and net delays** (`delay2`/`delay3` on a primitive, `#(rise,fall,turnoff)`,
  min:typ:max, trireg charge decay). Every fixture here is zero-delay and
  samples after `#1`. Delays belong with D09's timing row and would make each
  transcript depend on the scheduler's inertial-vs-transport rule, which is a
  separate decision.
- **L vs H as distinct values.** Both project to x in `%b`. Telling them apart
  needs `$display("%v", ...)` (strength format), which the digital executor does
  not have and whose output spelling is itself a separate conformance item.
- **The rest of the strength lattice.** Fixture 6 exercises strong/pull/weak and
  the strong→pull reduction. `supply0/supply1`, `large`/`medium`/`small`,
  `highz0/highz1` drive strengths, the pull→weak→medium→small reduction chain
  and ambiguous-strength combination (§7.10.2-style ranges) are untouched.
- **`charge_strength` and `trireg`** (A.2.2.2 `( small ) | ( medium ) | ( large )`).
  Charge retention through a switch network is named in the plan's D08 line and
  is not here; `docs/digital-source-execution.md` already records that `trireg`
  holds its last value with no strength model behind it.
- **`rtran`, `rtranif0`, `rtranif1`, `tranif0`.** Fixture 7 uses `tran` and
  `tranif1` only. The r- pass switches would need fixture 6's strength contest
  wrapped around a bidirectional node, which is a strictly larger step than
  either fixture takes alone.
- **Instance arrays** (`name_of_gate_instance ::= gate_instance_identifier
  [ range ]`) and multiple instances per statement. That is D07 elaboration
  applied to primitives.
- **UDP `drive_strength` and `delay2` on the instantiation** (A.5.4), UDP
  instance arrays, and `b`/`B` level symbols, `r R f F p P n N *` shorthand edge
  symbols (fixture 10 uses only the explicit `( level level )` form).
- **UDP port-shape diagnostics**: more than one output, an output that is not
  the first port, a UDP port declared `inout`, a sequential body without
  `output reg`, an entry whose input count does not match the port count,
  overlapping entries with contradictory outputs. All are real
  "invalid-table diagnostics" from the plan's D08 line; two rejects is the cap
  set by the positive count.
- **Primitives in the analog domain.** Everything here is `--run` digital.
  Auto-inserted connect modules around primitive terminals (§7.8.5.1's actual
  subject) are D06/D10 territory.
- **Host (ARPice) behaviour.** D08 is entirely a VerA-side row; nothing was
  written under `ARPice/tests/pending/`.

## How to run these

Today, by hand — all twelve already run and all twelve already refuse:

```
cd /home/omare/Documents/Projects/Zig/VerA
zig build                     # produces zig-out/bin/vera
for f in tests/pending/D08/*.v; do zig-out/bin/vera --run "$f"; done
```

Wired up, the ten positive fixtures follow the existing `tests/digital`
convention exactly (`build.zig:140-165`): one `b.addRunArtifact(vera)` per file
with `addFileArg(b.path("tests/digital/<name>.v"))` and
`expectStdOutEqual(@embedFile("tests/digital/<name>.expected.txt"))`, all hung
off the `test-digital` step. So:

```
git mv tests/pending/D08/d08_*.v tests/pending/D08/d08_*.expected.txt tests/digital/
# add one run-artifact pair per fixture in build.zig next to control_cli
zig build test-digital
```

The two reject fixtures do not fit `expectStdOutEqual` — they need a nonzero
exit and a diagnostic match, which `test-digital` has no shape for today. Either
give them `expectExitCode(1)` plus `expectStdErrEqual`-style substring checks in
the same step — one per `//! reject` line, ALL of them required, since the
runner treats the list as a conjunction — or move them to
`tests/fixtures/annex_a_syntax/` once UDPs parse, where `//! reject` is already
the harness's own verb (`tests/torture.zig:7-8`) and `zig build torture --
--strict` will run them. Note that `tests/harness.zig:787` collects `.va` only,
so the move is also a rename; nothing in either file is analog, and `.va` is
just the extension the collector accepts.
Do not move anything into `tests/fixtures/` before the feature exists: that
suite is green at 1323/1323 and a fixture that cannot pass would break the gate.

## Corrected after review

The review returned one defect against D08 (approval manifest §5.4: "the two
reject fixtures stay weak after the feature lands"). It is fixed here. §5.2
records D08's citations as verified clean and §5.5 records no scope violation;
A.5.3 was re-opened in `docs/annex-a-syntax.html` while making this change and
both fixtures quote it verbatim, including `output_symbol ::= 0 | 1 | x | X`,
`level_symbol ::= 0 | 1 | x | X | ? | b | B` and the `edge_input_list`-only
reachability of `edge_indicator`. No expected value in the ten positive fixtures
was disputed and none is changed.

- **`d08_reject_udp_z_output.v`**: `//! reject DiagnosticsReported` →
  `//! reject output symbol`. The old directive is satisfied by any diagnostic
  at all (`tests/torture.zig:223`), so after `primitive` parses, a UDP parser
  choking on the port list or the table width would still have marked it green.
- **`d08_reject_udp_comb_edge.v`**: `//! reject DiagnosticsReported` →
  `//! reject combinational` **plus** `//! reject edge`. Two lines rather than
  one because a single `combinational` pattern is satisfied by an
  implementation that supports sequential UDPs and refuses combinational bodies
  wholesale — the inverse of the rule under test.
- Both headers gained a paragraph stating what the directive demands, why the
  pattern is prose and not an `E0xxx` code (no code exists for either condition
  and this row may not add one to `src/`), and the instruction to allocate a
  code and *replace* the line when UDPs land.
- The "Both rejects currently pass vacuously" paragraph above was true and is
  now false; it is rewritten to record that E0201's message, point and title
  contain none of the three patterns, so both files now fail today for a reason
  the fixture states. Re-verified by running `zig-out/bin/vera --run` over all
  twelve files after the edit — output unchanged, no `//!`-directive complaint.

Nothing was withdrawn, so no claim moved to another row.
