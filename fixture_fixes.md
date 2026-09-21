# Remaining fixture fixes

Written 2026-09-21 at `a4b4396`. This is the per-row REGISTER of what is still
red and what each row is actually waiting on — the diagnosis, not the symptom.
`PLAN.md` is the work plan and says how to split the work; this file says what
the work is. `tests/fixtures/MANIFEST.md` remains the historical defect record.

Every diagnosis below was measured, not inferred. Where a row is blocked on a
specific line, the line is named.

## How to measure

```sh
zig build test                   # 113/113 — the GATE
zig build benchmark -- --strict  # 1495 pass / 35 FAIL / 28 XFAIL of 1558 .va
./.zig-cache/o/*/vera-suite <path-to-vera> devices   # 47/66, 18 FAIL
```

Three traps, each of which has already cost a session:

- **`zig build test-devices` interleaves and truncates.** It silently drops
  `d04_09`, so any count taken through it is short by one. Run the suite binary
  directly, as above. Every device number in this file is the direct one.
- **The suite compiles `.va` IN-PROCESS**, so `zig build` alone does not
  refresh `vera-suite`. A stale binary will report the previous revision's
  results with no indication that it has.
- **The denominator is not stable across checkouts.** The working tree carries
  untracked fixtures that agent worktrees do not, so the same revision measures
  1558 rows here and ~1538 there. **Diff NAMES, never counts.** Three separate
  regressions this session were invisible to a count and caught by a name diff.

---

## 1. ch07 mixed-signal — 31 FAIL

All 31 share ONE gate and it is three tokens:

```
E0205  unsupported module item: found `always`     12 rows
E0205  unsupported module item: found `assign`      8 rows
E0209  expected an expression: found `#`           11 rows
```

Nothing past the gate has ever been reached by a fixture, because nothing past
it has ever been reached by the parser. Treat every estimate for steps 3-7 of
`PLAN.md` §3 as unevidenced.

`always` is ALREADY PARSED — `parser.zig`'s `parseDiscrete` builds the
`Ast.DiscreteBlock` and appends it; the E0205 beside it is `reportItem`, the
non-fatal spelling, gated on `!self.in_connect_module and !self.digital`. So
for `always` the gate is one condition. `#` delay and `assign` as a module item
are genuine missing productions.

**Do not simply open it.** Accepting `always` in an analog-context module with
no executor turns "refused" into "compiled, and the block silently did nothing"
— a wrong number with no diagnostic, strictly worse than the E0205 it replaces.
The pattern to copy is `f4f76fd`'s: parse in full, refuse BY CLAUSE. Both
rejection rows in this chapter were fixed exactly that way in `12e154c`.

| rows | what they want |
|---|---|
| m01_01 .. m01_11 | A2D delivery, analog probes in digital expressions, cross/absdelta events |
| m02_01 .. m02_13 | D2A, tick quantization, the §8.4.3.3 rounding, DC settle |
| m04_10 .. m04_16 | §7.6 driver/receiver queries across a connectmodule |

Past the gate this needs the design work `PLAN.md` §3 lists: a runner that can
insert a solver-chosen timepoint (`tb.zig` is a fixed-grid evaluator over the
declared `//! time` points and several m01/m02 rationales assume mid-step
observation), a coordinator that can call the solver (`tb.zig`'s solver is a
source TEMPLATE, a Zig string literal emitted into each testbench, so nothing
in `src/sim/` can call it), and production callers for `src/sim/scheduler.zig`,
which is complete and unit-tested with zero of them.

---

## 2. Digital `.v` transcripts — 18 FAIL

The AST for four of these five groups landed in `6a4ba9d`. **All eighteen are
now engine work in `src/sim/digital.zig`.** The groups touch different parts of
that file and can be taken in any order, but only one at a time — two agents
rewriting it in parallel is a merge nobody should have to do.

### 2.1 UDPs — 3 rows (`d08_udp_comb`, `d08_udp_dff`, `d08_udp_latch`)

`Ast.UdpDecl`/`Ast.UdpRow` now survive onto `SourceFile`, with the row columns
kept as CHARACTERS and `( … )` grouping intact, and `is_sequential` taken from
the table rather than from `reg`.

The diagnostic is now `E1100: undeclared module in instantiation` from
`findModule` (`digital.zig:2505`), which searches `r.file.modules` only. It must
also search `r.file.udps` — a named UDP instance reaches it as a
`module_instance` by design, and `parseUdpInst`'s docstring explains why one
token cannot tell them apart.

Then: a table matcher over `Ast.UdpRow` (split `inputs` on `( … )` into one
field per `ports[1..]`, and check the count — A.5.3 forbids a mismatch and the
parser deliberately does not diagnose it, because splitting needs the port
count); a `Driver` variant for a UDP output; edge detection against the previous
input vector for the sequential body; `init` from the `udp_initial_statement`.

### 2.2 Switches — 4 rows (`d08_switch_mos`, `_cmos`, `_strength_reduction`, `_bidirectional`)

`d08_strength_reduction` is `nmos`, not the strength model — the strength model
(`Pair`, `netPull`) is already complete.

A.3.1's arms all parse now and are refused by clause. What is missing is a
CONDUCTION model, which is not a gate: §7.10 strength reduction (the
`r`-prefixed switches drop one level), bidirectional flow for `tran`/`tranif`,
and an x/z gate reading as "may or may not conduct".

Also needs a `Body.switches` list — the parser records nothing today and
`parseSwitch`'s `ponytail:` comment says so. Land the storage and the model
together, and drop `parseSwitch`'s `if (self.digital) … E1100` in that commit.

`Ast.GateKind` was deliberately NOT given the MOS members: `digital.gateBit`'s
`switch (kind)` is exhaustive with no `else`, so a new member breaks the build
until the evaluator handles it — and conduction is not a function of the input
bits, which is all `gateBit` computes.

### 2.3 `wreal` — 6 rows (`m04_01` .. `m04_06`)

`NetKind.wreal` exists and A.2.1.3's two arms parse. Two contexts, two answers:
in a `.va` it stays refused (annex C.4 bullet 2 / C.8 make that a language rule,
and three `annex_c_analog_subset` fixtures pin it); under `--run` it parses in
full and is then E1100.

Needs a real-valued lane in the net storage — `undriven` → 0.0 not z, `filled`
→ 0.0 not z, `wired` → single-driver pass-through — and §3.7's port merge:
"When the two nets connected by a port are of net type wreal and wire/tri, the
resulting single net will be assigned as wreal". `m04_02`/`m04_06` additionally
want `%g` in `$display` and `$realtobits`/`$bitstoreal`.

Delete the two `wreal_unimplemented` E1100 lines in `parser.zig` in that commit
— **not before**.

### 2.4 Tasks, functions, fork/join — 5 rows (`d04_09` .. `d04_13`)

Frontend AND engine, in that order, and the only group whose grammar is still
closed. `PLAN.md` §2 records why this was mis-scoped twice.

Current first diagnostics: `d04_09`/`d04_10` E0205 `found task`; `d04_11` E0208
`found automatic`; `d04_12` E0208 `found [` (A.2.6's `function_range_or_type ::=
[signed] [range] | …`, where `parseFuncDecl` reads only `integer|real|string`);
`d04_13` E0209 `found fork`.

Frontend: `[ automatic ]` and `function_range_or_type` on `parseFuncDecl`;
`Ast.TaskDecl` plus A.2.7 `task_declaration`; a task-enable statement; A.6.3
`par_block`. A bare `function` is already a module item and `Ast.FuncDecl.
is_analog` already tells the two kinds apart (`12e154c`).

Engine: lift `digital.zig:2521`, which refuses any module with
`m.functions.len != 0` outright; a call frame in the pc-based interpreter
(static by default, `automatic` for `d04_11`'s recursion); output/inout
writeback for `d04_09`; return-width truncation at the call boundary for
`d04_12`; concurrent process spawn plus a join barrier for `d04_13`.

**Two `annex_a_syntax` fixtures pin the current refusals and must move in
whichever commit opens the grammar**, or they become XPASS: `20_task_enable.va`
pins `//! reject E0214` at the enable with the declaration refused, and
`32_fork_in_analog_rejected.va` pins `//! reject E0209` on `fork` in an analog
block. The second is still a real rule after the grammar opens — `fork` in an
ANALOG block stays illegal — so it wants a different code, not deletion.

---

## 3. ch09 — 2 FAIL (`s01_05`, `s01_06`)

**Two blockers. Fixing either alone flips neither row**, which is why they were
declined twice as end-of-session work. They want to land together.

1. **§9.4.1 change detection is implemented nowhere.** `Lower.isDisplayTask`
   lists `$monitor` beside `$display` and `cg_display.emitDisplayTask` gives it
   the same unconditional inline print. The clause's mechanism sentence — "if
   the variable or an expression in the argument list changes value compared
   with the last accepted step" — has no implementation.
2. **A §9.5 call renders as the literal `0` outside the display unit.**
   `codegen.emitFileCallDropped` answers every descriptor-returning name with
   `@as(i64, 0)` in any unit that is not the display one, so `fd = $fopen(...)`
   computed in the shared core is 0, `updateState` stores that 0 into the held
   slot, and `$ftell(fd)` is `$ftell(0)` = −1. The fix shape is a persistent
   `Instance` slot the display unit WRITES and the core READS — the shape
   `Lower.held_vars` already has.

With (2) fixed and (1) absent, `s01_05` reads 0,2,4,6 and answers 0,0,2,4 —
three of four rows still red — and `s01_06` reads 0,2,2,2 against 0,2,6,12.

This pair is instructive beyond itself: they were blamed on W0851 for a whole
session, W0851 was lifted, and they did not move. A diagnosis that has never
been tested by removing the thing it blames is a guess.

---

## 4. Structural — 2 FAIL

Both are the same root shape, and neither is a straggler-sized change.

**`ch04/a01_03_parameterized_dimension_override`** — fails `top = b[N] got=0
want=10`. Not a bug in `dimsBounds`: array cells are scalarised at codegen into
fixed compile-time slots while `N` is a RUNTIME `Model` field, because the card
is applied by the testbench runner after the device is built. `vera` has no
compile-time parameter-override flag at all. §3.4 says parameters are "modified
at COMPILATION TIME", so closing this needs either a compile-time override path
into codegen or runtime-sized arrays.

**`ch05/a02_10_node_alias_reevaluated_when_a_parameter_changes`** — `bindAlias`'s
own `ponytail:` note already states it: `$analog_node_alias` resolution is one
`node_voltages` write at lowering, i.e. a topology edit, and "making it move
needs a device whose topology is a function of its model card, which is not what
`U` is". With both arms of `if (sel)` lowered, §9.20's last-writer rule leaves
the `else` binding in place at both sweep points — hence `got=2` twice.

---

## 5. The 28 XFAILs

Honest markers, not noise. Each names a rule VerA does not meet; deleting one
without implementing its rule is a lie, and the harness fails on XPASS to make
sure nobody does it by accident.

| area | rows | note |
|---|---|---|
| ch07 mixed-signal | 13 | all `m03_*` — §7.8 connect-module insertion plus §7.8.5 generated names as defparam targets. A SEPARATE program: it neither gates nor is gated by §1 above. |
| ch09 system tasks | 4 | |
| ch04 expressions | 3 | |
| ch05 analog behavior | 2 | |
| ch08 scheduling | 2 | |
| annex A syntax | 2 | `46_library_source_text` needs a library-map reader — `library_text` is a starting symbol VerA is never handed, so the production is parsed and refused with E0232 rather than promised a subset that could grow. |
| ch06 hierarchy | 1 | |
| annex E SPICE | 1 | |

---

## 6. Not measured at all

26 `.c` VPI fixtures and 7 `.sp` decks. They are not failing — they are
INVISIBLE, because no build step walks them. Until they are wired, every
percentage in this repo is computed over a denominator that quietly excludes
them.

The `.sp` seven are not `//! spice` netlists. They are foreign-simulator decks —
`.hdl` plus instance cards plus `.tran`/`.noise`, paired with an
`.expected.json` — with no `.va` under compilation and no `ok=` assertions.
Reaching them needs a deck runner that loads the modules, builds the netlist,
runs the named analysis and compares against the JSON. That is
`tests/harness.zig` work, not a CLI flag.

---

## 7. What "0 FAIL" would and would not mean

Finishing everything above gets the fixture suite green. It does not make the
compiler conformant, and the gap is the larger half.

`docs/CLAUSE-AUDIT.md` §7.2 counts 463 clauses with ONE-WAY evidence: 208
accepted-only, 99 refused-only, 156 uncited. A clause with only a rejection
fixture is not covered — a refusal is not positive evidence that the accepted
form behaves. Only the ~148 tested both ways can support a `verified` verdict
under the plan's own completion rules, which want a positive behavioural test,
an invalid-input test, and a recorded result per obligation. "It compiles" is
the weakest of the three.

None of §1-§6 touches that. It is a separate program of writing positive
fixtures for rules that already work, and it is measured in quarters.
