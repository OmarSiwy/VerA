# TODO — what stands between VerA and 100% conformance

Scored by `zig build torture` against `tests/fixtures`, which states what the
**LRM** requires rather than what VerA does. Measured on this tree, at the end of
wave 7:

```
1158/1161 pass · 3 XFAIL · 0 FAIL · 0 CANNOT RUN
0 fixtures compile and assert NOTHING
zig build test: 219/219
```

The waves are done; `git log` carries the per-wave history. This file is the
register of what is left and — mostly — of the ceilings the waves shipped
**deliberately**, which no `//! xfail` line can state because no fixture fails
on them.

Two things to know about how to read it. Every number above is a measurement, not
a carry-forward: re-run the suite rather than trusting this paragraph. And
`tools/contract.zig` has three times cited a gap register by a path that did not
resolve — `VerA/TODO.md` before this file existed, then `tests/lrm-rules/*.tsv`
with a `zig build ledger` step that never existed, then "there is no such
register" after this one was committed. If you delete this file, delete the
pointer to it too.

---

## 1. The remaining XFAILs — deliberately left, with their blast radius

All are real requirements VerA does not meet. None was missed; each was costed
and the cost lands outside a chapter.

### `annex_f_resolution/unknown_discipline_mixed_port.va`

Annex F.2 step 4.b's **multi-candidate** arm. `resolveDiscipline`
(`src/ir/elaborate.zig`) keeps the FIRST declared discipline of a signal's
segments; F.2 needs the SET, so "more than one candidate whose domain matches, no
`resolveto` for it, therefore UNKNOWN" is never decided and the mixed-port error
over it never fires. `E0903` is reserved and unemitted for exactly this verdict —
do not reuse the code.

**Blast radius:** per-net discipline SETS in the elaboration core, plus a
`connectrules` parser (`connectrules` is still `E0201`). Discipline resolution is
consulted at port bindings today (§3.11, see §3 below); a set-valued resolution
changes what every one of those bindings compares. The `connectmodule`s in the
fixture parse and are accepted since wave 6, so the parse half is done and the
resolution half is the work.

### `ch05_analog_behavior/two_named_branches.va`

Branch identity is fixed — each named branch retains its own value. What is left
is that VerA lowers a branch-flow READ at its statement position, and this
fixture's CHECKs precede its two `<+` lines, so §5.6.1.2's "previously retained
value" is genuinely nothing there and `I(a)`/`I(b)` read 0. §5.4.2.2 says a branch
is "accessible … anywhere in the module", which for a display operand means
§9.4.1 converged reporting: the operand is evaluated after the analog block, not
where it is written.

**Blast radius:** every §9.4 task in the suite. 751 fixtures print through one,
746 of them via `CHECK`, and each transcript is an assertion — so moving operand
evaluation to the end of the block re-times what two thirds of the suite prints. This is the one gap where closing it correctly is
cheaper than closing it safely, and that is why it is still open. Its sibling
`two_named_branches_retain_separately.va` pins the part that IS fixed, so a
regression in branch identity still fails loudly.

### `ch05_analog_behavior/net_named_gnd_is_not_ground.va`

Added deliberately, ahead of the fix rather than after the discovery: a net
*named* `gnd` that is not *declared* `ground` aliases two different branches onto
one solver unknown. `flowUnknown` (`src/ir/lower.zig`) builds the key by
formatting `nodeName(hi)` and `nodeName(lo)` into `flow(<hi>,<lo>)`, `nodeName`
spells the §1.3.1.1 reference node `gnd`, and `internNode` dedupes by that
string — so `I(a)` and `I(a,gnd)` intern to one `u16` and the second read
returns the first branch's current. Wrong Jacobian, exit 0, no diagnostic.

**Blast radius:** `node_voltages` is one string key space holding four kinds of
name (user nets, §5.4.2 branch flows, §5.4.3 port flows, §6.5.2 vector elements,
plus §6.7 flattened paths), and the fix is to key it on `{kind, name}` rather
than on `name`. The narrow repair — spelling ground `"0"` instead of `"gnd"` —
is a one-line change that passes this fixture and is still wrong: it respells
every emitted `U` member, `nodeName` has ~20 callers that are user-facing
diagnostic text, and it churns `tb.zig`'s directive parser and the two fixtures
that already write `flowZ28pZ2cgndZ29` by hand. The spellings a key split must
leave byte-identical are pinned in codegen.zig's "the `U` block is the SPELLING
contract" test and in tb.zig's `//! bias`/`//! sweep` test.

---

## 2. Will not do — and the reason, so it is not re-litigated

### Digital execution — a discrete-time domain, not a conformance gap

`connectmodule` bodies with `always` blocks, `#delay`, non-blocking assignment
and delta cycles need a discrete event scheduler. VerA is a compiler; the host
simulator runs the device, so **driver access does not need a scheduler inside
VerA** — the §9.22 family is nine *reject* fixtures and E0818 is the conforming
answer. What genuinely needs a scheduler is *executing* a digital process, and
that only arises because `zig build torture` makes VerA its own host.

Wave 7 went as far as this can honestly go without one: a digital `initial` block
whose body is constant assignments lowers to initial state, through the same
A.2.2.1 declaration-assignment seam `integer x = 3;` uses (`collectInitialState`
in `src/ir/lower.zig`). A loop, a delay, an event control, a non-constant rhs, an
array target or a block-local declaration is refused with **E0433**. `always` is
still E0205, and for a non-dialect reason: an `always` block re-runs on an event,
so its value is a function of §8.5's simulation cycle and there is no discrete
kernel for it to be a function of.

Not in scope beyond that. If it is ever wanted it is a second code generator, and
the fixtures that would grade it do not exist yet (see the §9.22.6 note in
`ch09_system_tasks/38_driver_update_connectmodule.va`).

### Do not take ARPice's netlist parser

Settled in wave 7, when VerA gained a SPICE **card** reader
(`src/frontend/spice_cards.zig`) rather than a netlist frontend. ARPice
(`../ARPice`) has a competent multi-dialect netlist frontend and it is still the
wrong tool here, for two checkable reasons:

```zig
// ARPice/src/frontend/types.zig:25
pub const SubcktType = struct { name, n_ports: u16, n_internal_nodes, device_count };
```

A port **count**, not names — subcircuits are flattened at parse time, which is
right for a simulator and useless for `spice_subcircuit.va`, which needs
`osc1.out` resolved by name. And the dependency runs the other way: ARPice depends
on VerA (`ARPice/build.zig.zon` → `.vera = .{ .path = "../VerA" }`), so VerA
importing ARPice is a cycle. **ARPice parses netlists to simulate; VerA reads
model/subckt cards to resolve names.** The overlap is comment-stripping and `+`
continuation joining — a shared shape, not shared behaviour.

### The mixed-signal driver template — a host-facing promise, no fixture forces it

The contract *can* carry real driver access, and should if the goal is that a
simulator embedding VerA inherits one template. The shape is established three
times over — an optional comptime table plus a hook filling position `k`
(`noise_gens`/`noisePsd`, `ac_stamps`/`acStamp`, `op_vars`/`opValues`):

- a positional `d_nets` table naming the digital nets a device observes;
- a query hook indexed into it, covering §9.22.1–.3 and §9.23's `next_*`;
- sensitivity metadata for §9.22.4 `@(driver_update)`.

**Positional, not name-keyed.** A `[]const u8` signal name is a runtime lookup and
cannot be comptime-validated, which every other table in that file can. Two
invariants any such design must keep:

1. **It stays out of `eval`/`q`.** A residual must be a pure function of `x` or the
   host's Newton iteration cannot converge. This is why §9.5 file I/O and
   `$random` both live in the per-accepted-point phase — see
   `src/backend/rng_kernels.zig`, which latches a variate precisely because a draw
   inside the residual destroys convergence.
2. **4-state values do not go in `U`.** A logic value is not a number; putting it
   there forces `eval` to branch on `S.val()`, which the contract forbids.

Do not add members ahead of a consumer. The contract's own header is the rule: *"a
member with no LRM justification and no consumer is not a roadmap item — it is
deleted."*

---

## 3. Ceilings shipped deliberately

Every one is marked `ponytail:` at its site with an upgrade path, and none has a
fixture standing OVER it — a fixture that fails because of one of these turns it
from a ceiling into a bug. A `//! reject` fixture standing ON one is the opposite
and is welcome: it pins that the ceiling is diagnosed against the `.va` rather
than left to the host, which is the only thing that makes "deliberate" checkable.
Exactly one row has one today (`|U| ≤ 256`, below).
Grouped by area; the file is the authority, this is the index.

### Solver / testbench (`src/backend/tb.zig`)
- No gmin stepping, no source stepping, no continuation. Nothing needed it.
- The Newton solve factors the **resistive** residual only; §5.6.1.2's reactive
  half needs `q(x)` plus the `q` of the last accepted step.
- `//! solve` is opt-in, so most fixtures still run at a forced operating point and
  the solver is exercised by a few dozen. Small evidence base.

### SPICE cards (`src/frontend/spice_cards.zig`)
- `.MODEL` and `.SUBCKT` **statements** only, which is E.2's literal noun phrase.
  No device cards, no subcircuit bodies, no `.param` expressions, no
  `.INCLUDE`/`.LIB`, no dialect tokenizers — everything else on a card line is
  skipped in silence rather than diagnosed.
- A `.MODEL`'s parameters are read and dropped: Table E.1 declares no such
  parameters, and E.2.2.1 says the ports and parameters come from the primitive
  and "not by the model statement".
- A synthesized `.SUBCKT` module has an EMPTY body, so under `//! solve` it is an
  open circuit. Written at the site and in the fixture.
- Whether a netlist `.MODEL` should shadow a same-named Table E.1 primitive is
  UNSPECIFIED by the annex (E.3.3 orders user-module against SPICE object, not two
  SPICE objects). The exact-match pass finds the primitive first. No fixture pins
  it.

### Analog operators (`src/backend/codegen.zig`, `cg_filters.zig`)
- `absdelay`: fixed 32-sample history with linear interpolation.
- No `noisePsd` hook emitted; thermal-off-the-Jacobian fallback only.
- §5.10.3.3 `enable` honoured only where it folds.
- The residual is real, so a matching small-signal analysis contributes the
  phasor's real part.

### `$random` (`src/backend/rng_kernels.zig`)
- Lehmer 16807, **not** IEEE 1364 §17.9.3's reference listing. No fixture pins a
  digit today; the day one does, all 25 RNG fixtures break together and this file
  is the single place to fix.
- 4096 degrees of freedom ceiling on the distributions.

### File I/O and strings (`file_kernels.zig`, `str_kernels.zig`)
- `$fscanf` consumes a whole **line** where C consumes only the match. §9.5.4.2
  fixes the return and the assignments and says nothing about position, and
  `$ungetc` is analog-context "No" in Table 9-2, so there is no conformant fix.
- One positional read per byte.
- 512 bytes per `$sformat` site, file scope — two threads evaluating the *same*
  site would collide.

### Elaboration (`src/ir/elaborate.zig`)
- §6.4.2 paramset tie-breaking: first survivor wins.
- A bound that cannot be folded counts as admissible.
- §3.11 discipline compatibility consulted at **port bindings only**.
- Two declarations of one identifier: first wins.
- An undeclared net used only in a child body is **not renamed**, so two instances
  would share it.
- §6.5.7.1 vector-net distribution across an instance array: absent.
- §6.3.6 automatic flow scaling of a flattened child's contributions: absent, and
  `E0912` misses a child whose ancestor specified `.$mfactor(...)`.

### Parser (`src/frontend/parser.zig`)
- A concatenated port becomes N terminals, not one N-bit port.
- A `net_decl_assignment`'s §3.6.3.2 nodeset value is parsed and **dropped**:
  the solver is the host's and a nodeset is an input to it. Two rules of that
  clause therefore have no consumer and are unchecked — "shall be a
  constant_expression", and that a non-continuous discipline may not carry one.
  The upgrade path is the optional-contract-decl shape (`display`, `u_abstol`):
  one `nodeset` decl the host may read. `ch03_data_types/21_net_nodeset.va` is
  green and pins the part that matters — the net is NOT clamped to the value.
- Vector ranges fold literals only; `[W-1:0]` does not.
- No `$root` prefix and no index inside a hierarchical path (`u[0].a`).
- Instance-array unrolling capped at 32 bits — a guard, not a rule.

### Lowering (`src/ir/lower.zig`)
- A digital `initial` block is constant assignments only (E0433 above); no event
  queue, no delta cycles, no drivers.
- Runtime array index: one dimension only; N selects per assignment.
- `$simprobe` cannot take a computed name (§9.16 arguments are strings).
- A reactive flow contribution's branch current reads the resistive half only.
- Voltage limiters are declined, not inlined.
- Output variables are module-level only; a §5.3.2 named-block variable is not one.
- A `discardOpposite` under a conditional survives as a phi.
- §4.7.2 function-local `parameter` declarations fold into `consts` and are not
  restored on exit, so a module parameter of the same name stays shadowed for the
  rest of the module. This is the file's one deferral with no site of its own.

### Proof / range analysis (`src/ir/proof.zig`)
- Immediate widening loses loop-carried bounds.

### Lexer (`src/frontend/lexer.zig`)
- Left padding with `x`/`z` is unrepresentable.

### Preprocessor (`src/frontend/preprocessor.zig`)
- A malformed `` `timescale `` operand leaves the timescale **unset** rather than
  diagnosing.
- One `timescale` per compilation, last one wins, shared by every module in the
  file. Two modules with a directive between them both see the second.

### Device contract (`tools/contract.zig`)
- **`|U| ≤ 256`**, because `U` is an `enum(u8)` and `isDenseEnum` requires that
  tag type. `emitTopology` refuses past it with **E1003** rather than emitting an
  artifact whose 257th member is `enum tag value '256' too large for type 'u8'`
  in the *host's* build. Upgrade path is `enum(u16)`, and it is an ABI break: the
  tag type and `isDenseEnum` move together and every linked host recompiles.
  `ch06_hierarchy/vector_port_unknown_ceiling_rejected.va` stands ON this row,
  not over it — it asserts the refusal, which is the ceiling working. Boundary
  measured exact: 256 unknowns emit and type-check, 257 is E1003.
- `num_ports` is bounded above by `|U|` and no longer below by 1: §6.2 makes the
  port list optional. `zig build test-contract` is where its tests run — they ran
  nowhere until wave 7 wired the step, which is how the old guard survived two
  waves of the engine growing past it.

### Orchestrator (`src/backend/orchestrator.zig`)
- GPU emission list is always empty; emission lives in the host.
- O(files × units) membership scan.
- A workaround for a Zig 0.16.0 resident-compiler SIGSEGV on the second build.

---

## 4. Suite machinery

- 415 of 1152 fixtures are `reject` fixtures. Where a feature's only fixtures are
  negative, VerA conforms by **refusing** it and never implements it — true of
  `$simprobe`, the `zi_*` non-zero-tau forms, Table 9-30/9-31's `D`/`2`/`3`/`I`/`E`
  schemes and the whole §9.22 family. A high score is not the same as a complete
  implementation, and the positive fixtures are what keep that honest.
- The `CANNOT RUN` verdict is **retired**, with its counter and its `--strict`
  arm: it had exactly one producer and that producer was a stale guard. See
  `tests/fixtures/README.md`. If a genuine host limitation ever reappears, re-add
  it rather than reporting it as FAIL.
- `checkAssertions`'s old fragility — it scanned for a `CHECK` macro and then the
  next `(` anywhere in the file, so a fixture's lint verdict could depend on
  unrelated prose downstream — is fixed. It uses `MacroScan` + `matchParen` and is
  bounded to the call site.
