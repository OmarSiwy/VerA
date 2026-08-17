# TODO — what stands between VerA and 100% conformance

Scored by `zig build torture` against `tests/fixtures`, which states what the
**LRM** requires rather than what VerA does. As of `241f09a` (wave 5):

```
1108/1150 pass · 25 XFAIL · 1 CANNOT RUN · 0 FAIL
16 fixtures compile and assert NOTHING (`--strict` fails on these)
```

Wave 6 is the last conformance wave and targets 22 of the 25 plus all 16 hollow
passes. This file is the register of what it does **not** close, and of the
ceilings the waves shipped deliberately. `docs/conformance-plan.md` has the
per-epic history.

A note on why this file exists at all: `tools/contract.zig` has twice cited a
gap register that did not exist — first a `VerA/TODO.md`, then a
`tests/lrm-rules/*.tsv` with a `zig build ledger` step, neither of which was ever
committed. If you delete this file, delete the pointer to it too.

---

## 1. Will not do — and the reason, so it is not re-litigated

### SPICE `.MODEL`/`.SUBCKT` cards — DECISION REVERSED, now planned

An earlier revision of this file recorded
`annex_e_spice/{spice_model,spice_subcircuit,spice_case_lookup}.va` as permanent
non-goals, on the grounds that Annex E.1.1 guards the family with a conditional
("**if** a simulator … is also able to read SPICE netlists") whose antecedent is
false for VerA, and that closing them meant writing a second input language.

**The clause reading was right; the cost estimate was wrong.** These fixtures do
not need a netlist parser. They need three names to resolve to a module
declaration with the right ports — and every piece of machinery that consumes such
a declaration already shipped:

- `preprocessor.zig:244` already injects Table E.1 as prepended Verilog-AMS module
  TEXT (`spice_primitives`), and its own docstring argues at length why a
  primitive is a real module rather than a name in a table;
- `elaborate.zig findModule` already implements E.3.3 precedence over that prelude;
- `elaborate.zig checkConnectionShape` already permits a short connection list, so
  `bjt`'s optional `s` port works;
- `annex_e_spice/spice_network_primitives.va` already PASSES using the exact shape
  all three need — a §6.7.1 hierarchical probe of an instance port on a
  prelude-supplied module.

So the plan is a **card reader**, not a netlist reader: read `.MODEL` and
`.SUBCKT` declarations, synthesize prelude module text, and let the existing path
do the rest. About 190 lines in a new `src/frontend/spice_cards.zig` plus ~30 lines
of plumbing across `preprocessor.zig`, `root.zig`, `ast.zig` and `elaborate.zig`,
and one `//! spice` directive in `tb.zig`.

The directive must be a **transparent netlist channel**, not a resolved tuple — the
fixture carries the annex's card verbatim, continuations and all:

```
//! spice .MODEL VERTNPN NPN BF=80 IS=1E-18 RB=100 VAF=50
//! spice + CJE=3PF CJC=2PF CJS=2PF TF=0.3NS TR=6NS
```

That is what makes VerA the reader and lets the fixture cite E.2 honestly. Handing
it a pre-digested `("ecposc", ["out","gnd"])` would close the fixtures while
skipping E.1.1's premise, and would add a public interface type with one producer.

**What this buys, precisely:** VerA reads SPICE *model and subcircuit statements*,
which is E.2's literal noun phrase. It does NOT buy device cards, subcircuit
bodies, `.param` expressions, `.INCLUDE`/`.LIB`, or dialect tokenizers. A
synthesized `.SUBCKT` module contributes no equations, so under `//! solve` it is
an open circuit — a ceiling to write at the site, not a bug.

### Do not take ARPice's netlist parser

ARPice (`../ARPice`, EGSpice) has a competent multi-dialect netlist frontend,
generic over a tokenizer trait bundle, uncoupled from its `Circuit`/`RunCtx`
types — and it is the wrong tool here, for a checkable reason:

```zig
// ARPice/src/frontend/types.zig:25
pub const SubcktType = struct { name, n_ports: u16, n_internal_nodes, device_count };
```

A port **count**, not names. The struct holding subcircuit port names is private
inside the `Parser` generic, because subcircuits are flattened at parse time —
right for a simulator, useless for `spice_subcircuit.va`, which needs `osc1.out`
resolved by name. Importing it closes ONE of the three fixtures, brings ~1845
lines at 3 tests, and still requires changing ARPice's public IR.

Also note the dependency direction: ARPice depends on VerA
(`ARPice/build.zig.zon` → `.vera = .{ .path = "../VerA" }`), so VerA importing
ARPice is a cycle. The boundary that works is two readers with two purposes:
**ARPice parses netlists to simulate; VerA reads model/subckt cards to resolve
names.** The overlap is ~60 lines of comment-stripping and `+` continuation
joining — a shared shape, not shared behaviour, and stable since SPICE2g6.

### Digital execution — a discrete-time domain, not a conformance gap

`connectmodule` bodies with real `always` blocks, `#delay`, non-blocking
assignment and delta cycles need a discrete event scheduler. VerA is a compiler;
the host simulator runs the device, so **driver access does not need a scheduler
inside VerA** — see §3 below. What genuinely needs one is *executing* a digital
process, and that only arises because `zig build torture` makes VerA its own host.

Not in scope. If it is ever wanted, it is a second code generator, and the
fixtures that would grade it do not exist yet (see §9.22.6 note in
`ch09_system_tasks/38_driver_update_connectmodule.va`).

---

## 2. Open contract decisions — small, real, and blocking a verdict

### `num_ports == 0` — the single CANNOT RUN

`tools/contract.zig:214` refuses `num_ports must be in 1..|U|`, so a module with
no port list cannot run even though VerA compiles it correctly.
`ch06_hierarchy/module_definition.va` pins the word *optional* in §6.2, and Annex
A.1.2 admits `module identifier ;`:

```verilog
module ch6_definition;
  electrical p;          // an internal node, the only kind such a module can have
  analog I(p) <+ V(p);
endmodule
```

That guard is now **stale rather than wrong**. It predates two things: the
testbench gained a real Newton solve (wave 4), so a device with zero terminals and
one internal node has a residual something can actually solve; and elaboration
(wave 5) makes such a module instantiable as a child contributing internal
equations. Relaxing to `np > n` only is the change, and it closes the last
CANNOT RUN.

Do **not** add a port to the fixture. That deletes the only test of "optional".

### The mixed-signal template — a host-facing promise, no fixture forces it

`contract.zig:256-262` currently asserts as design that codegen hardwires the
§9.22 `$driver_*` family to `0`. Wave 6 makes those calls a diagnostic, which is
the conforming behaviour for a compiler with no connectmodule, and that comment
must change with it.

Beyond that, the contract *can* carry real driver access, and should if the goal
is that a simulator embedding VerA inherits one template. The shape is already
established three times over — an optional comptime table plus a hook filling
position `k` (`noise_gens`/`noisePsd`, `ac_stamps`/`acStamp`,
`op_vars`/`opValues`):

- a positional `d_nets` table naming the digital nets a device observes;
- a query hook indexed into it, covering §9.22.1–.3 and §9.23's `next_*`;
- sensitivity metadata for §9.22.4 `@(driver_update)`.

**Positional, not name-keyed.** A `[]const u8` signal name is a runtime lookup and
cannot be comptime-validated, which every other table in that file can.

Two invariants any such design must keep:

1. **It stays out of `eval`/`q`.** A residual must be a pure function of `x` or
   the host's Newton iteration cannot converge. This is why §9.5 file I/O and
   `$random` both live in the per-accepted-point phase — see
   `src/backend/rng_kernels.zig:31`, which latches a variate precisely because a
   draw inside the residual destroys convergence.
2. **4-state values do not go in `U`.** A logic value is not a number; putting it
   there forces `eval` to branch on `S.val()`, which `contract.zig:34` forbids.

Do not add members ahead of a consumer. The contract's own header is the rule:
*"a member with no LRM justification and no consumer is not a roadmap item — it is
deleted."*

---

## 3. Stale in-source documentation

- **`src/ir/lower.zig:7809`** — a deferral list claiming "§6.2.2 module
  instantiation — rejected by the parser" and "§3.12 branch arrays and §6.5.2
  vector ports/nets — the parser already rejects the declarations". Waves 2 and 5
  implemented all three. The remaining entries (§4.4.2 port probes, §3.2.2 runtime
  array indices, §4.7.2 function-local `parameter` shadowing) are still accurate.
- **`src/frontend/preprocessor.zig:330`** — "make it an event list the day VerA
  compiles two modules at once." That day was wave 5.
- **`tools/contract.zig:11-16`** — cites `tests/lrm-rules/*.tsv` and `zig build
  ledger`. Neither exists in any commit and there is no `ledger` build step.
- **`tests/fixtures/README.md`** opens with "859 `.va` files"; there are 1150.
- The `COVERAGE.md` aggregates drifted across every wave and are re-censused in
  wave 6's last batch. Until that lands, do not trust a total in them.

---

## 4. Ceilings shipped deliberately

Every one is marked `ponytail:` at its site with an upgrade path, and none has a
fixture behind it — a fixture appearing over any of these turns it from a ceiling
into a bug. Grouped by area; the file is the authority, this is the index.

### Solver / testbench (`src/backend/tb.zig`)
- No gmin stepping, no source stepping, no continuation. Nothing needed it.
- The Newton solve factors the **resistive** residual only; §5.6.1.2's reactive
  half needs `q(x)` plus the `q` of the last accepted step.
- `//! solve` is opt-in, so ~1100 fixtures still run at a forced operating point
  and the solver is exercised by a handful. Small evidence base.

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
- An undeclared net used only in a child body is **not renamed**, so two
  instances would share it.
- §6.5.7.1 vector-net distribution across an instance array: absent.
- §6.3.6 automatic flow scaling of a flattened child's contributions: absent, and
  `E0912` misses a child whose ancestor specified `.$mfactor(...)`.

### Parser (`src/frontend/parser.zig`)
- A concatenated port becomes N terminals, not one N-bit port.
- No `net_decl_assignment` (`electrical n = 5.0;`) — this is xfail
  `ch03_data_types/21_net_nodeset.va`, i.e. a real gap, not a ceiling.
- Vector ranges fold literals only; `[W-1:0]` does not.
- No `$root` prefix and no index inside a hierarchical path (`u[0].a`).
- Instance-array unrolling capped at 32 bits — a guard, not a rule.

### Lowering (`src/ir/lower.zig`)
- Branch-array elements share one `(hi, lo)` accumulator key.
- Runtime array index: one dimension only; N selects per assignment.
- `$simprobe` cannot take a computed name (§9.16 arguments are strings).
- A reactive flow contribution's branch current reads the resistive half only.
- Voltage limiters are declined, not inlined.
- Output variables are module-level only; a §5.3.2 named-block variable is not one.
- A `discardOpposite` under a conditional survives as a phi.

### Proof / range analysis (`src/ir/proof.zig`)
- Immediate widening loses loop-carried bounds.

### Lexer (`src/frontend/lexer.zig`)
- Left padding with `x`/`z` is unrepresentable.

### Preprocessor (`src/frontend/preprocessor.zig`)
- A malformed `` `timescale `` operand leaves the timescale **unset** rather than
  diagnosing.

### Orchestrator (`src/backend/orchestrator.zig`)
- GPU emission list is always empty; emission lives in the host.
- O(files × units) membership scan.
- A workaround for a Zig 0.16.0 resident-compiler SIGSEGV on the second build.

---

## 5. Suite machinery

- **`tests/harness.zig checkAssertions`** scans for a `CHECK` macro and then the
  next `(` **anywhere in the file**, so a fixture's lint verdict can depend on
  unrelated prose downstream. Wave 5 flipped six fixtures' verdicts merely by
  lengthening an `//! xfail` string. This is the component that enforces "the want
  is a literal", so its fragility undermines every assertion claim in the suite.
  Wave 6 fixes it; if you are reading this and it is still true, that batch failed.
- 421 of 1150 fixtures are `reject` fixtures. Where a feature's only fixtures are
  negative, VerA conforms by **refusing** it and never implements it — true of
  `$simprobe`, the `zi_*` non-zero-tau forms, Table 9-30/9-31's `D`/`2`/`3`/`I`/`E`
  schemes and the whole §9.22 family. A high score is not the same as a complete
  implementation, and the positive fixtures are what keep that honest.
