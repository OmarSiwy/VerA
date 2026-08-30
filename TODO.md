# TODO — what stands between VerA and 100% conformance

RESURRECTED 2026-08-30: this file was deleted as collateral of `3ba7dde`'s
dirty-tree commit (its own message records the mixup) while six source comments
and the README still pointed here. Sections 2–4 are restored as written before
the deletion; ceilings closed by the 2026-08-30 audit wave are no longer
re-listed here — the tree's `ponytail:` comments are the live register for
per-site ceilings, and this file carries the cross-cutting ones.

## 1. The remaining XFAILs — none

**0 XFAIL as of this tree** (`zig build torture -- --strict` passes:
1234/1234). The last three closed in the 2026-08-30 wave:

- `annex_f_resolution/unknown_discipline_mixed_port.va` — annex F.2.1 step 4.b
  multi-candidate resolution landed with `connectrules` parsing (A.1.8),
  `resolveto`/`exclude`, and E0903 on an unknown-discipline mixed port.
- `ch05_analog_behavior/two_named_branches.va` — §9.4 display operands that
  read a branch-flow source now evaluate at the converged end-of-block state
  (§9.4.1); statement-position retention (§5.6.1.2) is unchanged everywhere
  else.
- `ch03_data_types/lrm_3_6_2_7.va` — discipline user-defined attributes are
  accepted: §3.6.2.7's prose governs and A.1.7's grammar is treated as a
  non-exhaustive erratum. The decision is recorded in the fixture header.

The suite still carries 3 `DEBT` banners (rejections the LRM does not
sanction, each naming its rule): `annex_c_analog_subset/08_wreal_rejected.va`,
`annex_g_change_history/06_obsolete_generate.va`,
`ch09_system_tasks/150_rdist_domain_rejected.va`.

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

### The incremental frontend cache — removed for having no consumer, not for being wrong

`root.Compilation` was a session-scoped whole-unit cache: `update(name, source,
target, opts)` ran stage 1, BLAKE3'd the preprocessed bytes plus the target byte,
and skipped stages 2–6 on a match, replaying the unit's stored diagnostics so a
cached success could not lose its W0650. ~214 lines plus `Unit`/`Update`/
`UpdateStatus`, deleted in wave 12. Nothing in the tree ever called it — not
`src/cli.zig`, which compiles one file and exits, not the suites, and its
`rebuilds` counter (`// Benchmarks read it.`) had no reader anywhere, including
the benchmark wave 8 actually built.

**This is the seam an incremental frontend would be rebuilt on, so record what
it was.** A compiler cannot beat O(N) on a fresh compile — it must read every
byte — so the only route to sub-linear *edit* latency is a cache like this one,
and the design questions it had already answered are the expensive part:

- **Dirtiness is decided on the PREPROCESSED bytes**, so a macro or an
  `` `include`` change invalidates even when the `.va` file is untouched.
- **A cached unit must replay its diagnostics.** Stages 2–6 do not run on a hit,
  so without a replay a warning would blink out whenever an unrelated file was
  edited. A cached ERROR cannot happen — a failed update drops the result — but a
  cached SUCCESS carrying warnings is the normal case.
- **Whole-unit, not per-declaration**, deliberately: fine-grained change
  detection is delegated to `zig` through stable naming, and `naming.zig`'s
  ABSOLUTE RULE header is that argument.

Its own docstring is why it went: *"All this layer buys is skipping a frontend
that already runs in microseconds — its real job is proving the no-op-edit
determinism invariant."* That invariant is not the cache's, and it stayed: the
`determinism: a no-op recompile reproduces identical device.zig` test in
`src/root.zig` compiles the same source twice through the ordinary path and
requires byte-identical output. Rebuild the cache the day an edit-latency number
exists to beat; that is a deliberate wave, not a rediscovery.

### A batch/SIMD evaluator inside VerA — and the measurement that outlived it

`src/backend/eval_batch.zig` was 702 lines of classify→bucket→evaluate→stamp
SIMD driver, deleted in wave 12. It was not slow or wrong; it was
**uninstantiable**. It duck-typed a device `D` on `n_terminals`, `n_regions` and
`region(comptime N, ...)` — a SECOND device ABI, none of whose members
`tools/contract.zig` declares or `codegen.zig` emits — so `Batch(D)` could only
ever be built from the `TestDiode` defined in the same file. VerA's job ends at
the artifact; §8.3's simulation cycle is the host's, and a batch driver here can
only race the host's own. `tools/source_guards.zig`'s reachability test is what
makes a 702-line orphan unrepeatable.

**What must not be re-derived, because the file measured it and the file is
gone.** On a 100 k-instance random netlist, replacing the scalar stamp loop
(scatter-accumulate into CSR) with a gather/add/scatter over N lanes:

- **14 real CSR cells silently wrong**, up to **14 % relative error** in a
  Jacobian entry — two lanes hitting one slot drop every update but the last;
- **not faster: 3.05 ms vs 3.04 ms scalar.** The loop is bound by random-access
  memory latency, not by ALU width.
- **Prefetching the target cell also measured slower.**

The aliasing is by design and does not go away with a better index: every
terminal on ground maps to ONE shared sink cell (~44 % of entries for a
4-terminal device with a quarter of its terminals grounded), two instances
bridging the same node pair share a CSR slot, and the residual index IS the node
index, so a node with k devices takes k contributions. That shared summation is
the whole reason the stamp is `+=`. Scalar is the answer; if a host ever asks,
this paragraph is the starting point, not a blank page.

### An Air-shaped `Mir.InstRow` — measured, and it is three orders of magnitude off

The proposal was to replace `mir.zig`'s 7-column `InstRow` with Zig's `Air`
shape (`tags: []Opcode` + an 8-byte `data` union + `extra: []u32`, `tok` split
out cold, `Ref = enum(u32)` folding the Value space into the instruction index).
The sizes it quoted are right. **The conclusion does not follow**, and
`zig build bench` is why.

**What a row costs** (`@sizeOf` per column, this tree): `InstRow` is 25 B/inst in
its `MultiArrayList` (28 as a struct); `ValueRow` is 9 B plus a 4 B `alias` slot.
The bench prints it — `zig build bench` now emits a footprint table before the
timing table, and `insts` joined `defs`/`device` in `expected`, so the number
cannot drift unsigned.

**What VerA actually compiles.** MEASURED, whole fixture corpus in one line:

    case      n     insts   defs    blocks  extra   mir_bytes
    fixtures  1164  20804   27924   2195    22800   991872
    # largest single fixture MIR: 44432 bytes

All 1,164 fixtures together are **992 KB** of MIR and the largest single one is
**44 KB**. This machine's L2 is 32 MB. The whole corpus is 3 % of L2; one fixture
is L1-resident. There is no bandwidth problem to fix. The audit's "553 KB for a
6,007-line model" reproduces (the bench's `contrib n=4096`, ~4,100 lines, is
520 KB) — but that model is a *bench input*, twelve times larger than anything
in the tree, which is the synthetic-only measurement this file already burned
two waves on.

**What the time is.** MEASURED, `bench -- gen`, min of 25, ReleaseFast, `lint`
minus `pp` (= lex+parse+lower+prove):

| axis | n=1 | n=4096 | insts at 4096 | marginal |
|---|---|---|---|---|
| contrib | 177.5 µs | 8.41 ms | 12,290 | **670 ns/inst** |
| vals | 191.0 µs | 10.35 ms | 8,195 | **1,241 ns/inst** |
| inst | 187.6 µs | 19.47 ms | 20,480 | **942 ns/inst** |

Linear in instruction count on all three axes (contrib 512→4096 is 8.0× the
instructions for 7.3× the time), so the shape is settled and only the constant is
in question — and the constant is ~0.7–1.2 µs, i.e. several thousand cycles, per
38 B of MIR. Take the most generous possible accounting of the row layout: 30
full sequential passes over every byte at L2 bandwidth is ≈7 ns/inst, **1 % of
lint**, and the Air shape removes at most 45 % of that. Run-to-run noise on the
fixture batch is 1.3 % (lint 1969.0 ms **(Debug)** in wave 14, 1994.2 ms **(Debug)**
re-measured here on an unchanged tree — both taken before `bench` printed its mode;
the ReleaseFast batch is 247.0 ms). **The entire theoretical win is below the
instrument's noise floor.**

For the workload the project's scope guarantees it is worse than that. A fixture
is a *fixed cost*: n=1 is 177 µs of lint producing **237 bytes** of MIR, and the
batch divides out to 211.7 µs/fixture (ReleaseFast, lint 246.4 ms / 1,164)
against an n=1 constant of 183.3 µs — **87 % of fixture-batch lint is a
per-compilation constant that no MIR layout can touch** (Debug agrees: 1,164 ×
1.51 ms = 1.76 s of a measured 1.99 s). If lint is ever to get faster, that
constant is the target:
wave 14 cached the prelude's *preprocessing* (`pp` 902.5 → 181.9 ms, **both Debug**;
ReleaseFast `pp` on this tree is 19.5 ms) but every
compilation still lexes, parses and lowers the same ~11.8 KB of expanded Annex
D/E text.

**Corrected by wave 16 — the `vera --lint` figures that stood here (3,189 µs,
2,235 µs with `--no-std-defs`) were process wall times and are withdrawn.** They
measure `fork`+`execve`+`ld.so`: re-run with `hyperfine -N`, `/bin/true` spawns
in 2.0 ms and `vera --lint` in 1.6 ms, so the compiler "measured" faster than the
empty program. IN-PROCESS, ReleaseFast, min of 500, `root.zig`'s 6-line resistor:
`.lint` was **155.3 µs** with the prelude against **8.9 µs** with `--no-std-defs`,
so the cacheable constant was **146.4 µs = 69% of the 211.7 µs/fixture batch**,
not 87% — the 87% counts the n=1 model's own cost as constant too, which it is,
but nothing can cache it. Split of the 146.4 µs: pp 2.7, lex 47.6, parse 91.9,
lower+prove ~4. Wave 16 took the lex half; **wave 19 took the parse half**, and
the whole prelude constant is now once per process — batch `lint` 170.3 → 77.0 ms
(ReleaseFast, `bench -- fixtures`, 1164), 146.3 → 66.2 µs per fixture. The row
this paragraph is arguing against is unaffected either way: the MIR layout's
theoretical win was below the noise floor when the constant was 146 µs and it
still is now that it is gone.

**And `Ref` folding is not the local change it looks like.** The Value space is
the index of nine side arrays *outside* `mir.zig`, every one sized
`nv = mir.defs.len + Value.first_dynamic`: `analysis.alias`/`vty`/`def_block`,
`unit_plan.needed`/`eager_use`/`arm_use`/`inlined`/`slot`, `codegen.lo_idx` —
27 B per Value, **twice** the 13 B (`ValueRow` + alias slot) the fold sets out to
delete. Renumbering Values renumbers all nine, and `codegen.zig:2261-2262` is
`if (i < self.an.nv and self.plan.slot[i] != none_u32) return self.b("c.f{d}",
...)`: an off-by-one in the fold does not trap, it names a different cached slot
in the emitted device. Silent miscompile, in the artifact the host builds.

**The `tok` column split is half-true and the wrong half.** `instRow` really is
`insts.get`, which reads all 7 columns (`mir.zig:673-675`) — but the hot walks
already do not use it: `analysis.zig:103-106` hoists `i_op`/`i_res` as raw column
slices with a comment saying exactly why. The only remaining all-column reader is
`instData`, which decodes one instruction and immediately switches on its class.
`tok` also has a job — class-6 diagnostics report at a real line and column
because of it, and fixtures pin those locations.

**Decision: do not refactor.** Reconsider only if the bench's footprint line ever
shows a single compilation whose MIR exceeds L2 — at 44 KB today that is a
700-fold change in what VerA is asked to compile, and it would arrive as a
netlist, which `TODO.md` §2 already puts out of scope.

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
- `absdelay`: fixed 32-sample history with linear interpolation. (The short-td
  stale-sample hole and the missing `bound_step = min(.., td)` closed
  2026-08-30; the 32-sample depth is the remaining ceiling.)
- No `noisePsd` hook emitted, so the host is left with the fallback that reads
  4kT·g off the Jacobian it already has — which covers **`.thermal` only**.
  Nothing in a Jacobian yields §4.6.4.2's `kf·I^af / f^ef`, so a `.flicker` row
  in `noise_gens` is topology the host is told about and a PSD it must decline.
  Three §4.6.4 shapes reach `noise_gens` as NOTHING, deliberately:
  - §4.6.4.3/.4 `noise_table`/`noise_table_log` have no `NoiseGen.kind` tag.
    Adding one is blocked from the other end: `tools/contract.zig`'s `PsdTerm`
    is a parametric white/flicker form that "cannot express" a piecewise
    PSD-vs-frequency table, and its own note says the tag and the replacement
    hook "land together". Refusing the call instead is not available either —
    `ch04_expressions/27_noise_sources.va` asserts all four are accepted and
    read zero outside a small-signal analysis.
  - A source assigned to a variable and then contributed
    (`x = white_noise(k); I(a,b) <+ x;`) exports nothing: `noiseKindsOf` walks
    the contributed EXPRESSION, and by then the source is an ident.
    `ch04_expressions/27_noise_sources.va` and `38_correlated_noise.va` are
    both that shape, and 38 is §4.6.4.6 CORRELATED noise, which is precisely
    what the table's shared-`source` design exists to express — so this is the
    one of the three worth paying for. It needs the noise source tracked as a
    value through lowering, not a tag on the contribution.
  - A generator on a branch both of whose ends are ground, since §1.3.1.1
    leaves it no row or column to name.
  What is FIXED as of wave 13: the generators are a SET per contribution
  (`Lower.NoiseKinds`), so a branch carrying a thermal source and a flicker
  source exports both. It used to export whichever `<+` came last.
- §5.10.3.3 `enable` honoured only where it folds.
- The residual is real, so a matching small-signal analysis contributes the
  phasor's real part.

### `$random` (`src/backend/rng_kernels.zig`)
- ~~Lehmer 16807, **not** IEEE 1364 §17.9.3's reference listing.~~ CLOSED
  2026-08-30: the kernels are the §17.9.3 listing (LCG `69069·s+1` on a
  wrapping 32-bit word), ported from Icarus `vpi/sys_random.c` cross-checked
  against Verilator `verilated_probdist.cpp`, verified bit-exact against the
  compiled C; `171_random_ieee1364_digits.va` and codegen's §9.13 unit test
  pin the digits. Per-distribution `_next` write-backs keep the inout seed on
  the reference stream across successive calls.
- 4096 degrees of freedom ceiling on the distributions — the one deliberate
  departure from the listing, plus defined 0-answers (seed untouched) where
  `rtl_dist_*` warns and returns 0 on a non-positive df/k/mean.

### File I/O and strings (`file_kernels.zig`, `str_kernels.zig`)
- `$fscanf` consumes a whole **line** where C consumes only the match. §9.5.4.2
  fixes the return and the assignments and says nothing about position, and
  `$ungetc` is analog-context "No" in Table 9-2, so there is no conformant fix.
- One positional read per byte.
- 512 bytes per `$sformat` site, file scope — two threads evaluating the *same*
  site would collide.

### Elaboration (`src/ir/elaborate.zig`)
- ~~§6.4.2 paramset tie-breaking: first survivor wins.~~ CLOSED 2026-08-30:
  all enforced selection rules + the clause's three tie-breaks land, residual
  tie is E0914.
- A bound that cannot be folded counts as admissible.
- Two declarations of one identifier: **first wins** for the walk; since
  2026-08-30 `resolveMultiCandidates` runs F.2.1 step 4.b over the segment SET
  after the walk (resolveto/exclude/E0903), so first-wins now decides only the
  single-candidate case. A second
  declared segment of one signal is never compared against the first. §7.4.4's
  duplicate-declaration half is caught downstream (E0902, in lowering); what is
  missing is Annex F.2.1 step 4.b's multi-candidate arm, and that is XFAIL-1 in
  §1 above, with its cost. Wave 13's `Flatten.disc_of` map replaced the linear
  scan under this and deliberately did **not** widen the value: two
  arrival-ordered slots do not decide 4.b either (see §1).
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
- ~~**The annex D/E prelude is re-parsed on every compilation.**~~ **CLOSED by
  wave 19** (`Preprocessor.preludeAst`), and the three stages of the prelude
  constant — text, tokens, AST — are now all once-per-process. MEASURED,
  ReleaseFast, `bench -- fixtures`, 1164 fixtures, every byte column and the
  whole footprint table identical: `lint` **170.3 → 77.0 ms** (−54.8%),
  146.3 → 66.2 µs per fixture. Two things this row USED to say were wrong and are
  recorded here because they were the reasons it was costed as hard:
  the `StrId` prefix needed no engineering (ids are `id = column.len` at insert
  and the prelude is parsed first, so they are already 0..N-1 identically), and
  the decls are not cloned into the compilation arena at all — nothing below the
  parser writes one, so they are SHARED, which `tools/source_guards.zig`'s third
  guard now keeps true. What IS copied per compilation is the append-only stores,
  ~13 µs of the 82.7 µs parse it replaces. Remaining headroom on this seam: none
  worth a wave — what is left of `.lint` on a 6-line model is the model.
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
- §4.7.2 function-local `parameter` declarations: the in-body half is CLOSED
  2026-08-30 (a local shadows the module parameter inside the function,
  `funcParamShadows`); what remains deferred is the after-call `consts`
  pollution the block comment near `foldExpr` documents.
- §6.5.2 a vector element and a §2.8.1 escaped identifier share the NET
  namespace. `vecElem` scalarises `electrical [1:0] b` into nets literally named
  `b[1]`/`b[0]` — the spelling the source uses, deliberately, so a diagnostic, a
  `//!` binding and the emitted `U` member all name the same thing — and the LRM
  gives an element no name of its own to use instead. So `electrical [0:0] b;
  electrical \b[0] ;` declares two nets and gets one, reported as a false E0902
  (§7.4.4 second discipline declaration). Wave 11 split branch flows out of this
  key space and deliberately did **not** split elements out: they ARE nets under
  §3.6.3, every consumer downstream of scalarisation treats them as nets, and the
  only cheap repair is a spelling change — which the same wave was forbidden to
  make, since `b[0]` is pinned from both ends by codegen.zig's "the `U` block is
  the SPELLING contract" test and tb.zig's `//! bias V(d[1])`.
  **Upgrade path:** a `vec_elem` discriminator alongside `NodeKind`, keying
  `node_voltages` on `{is_element, name}`; the cost is not the key, it is
  threading "am I an element?" through the eight sites that intern or look up a
  net name, and it buys one diagnostic on a program nobody writes.

### Proof / range analysis (`src/ir/proof.zig`)
- Immediate widening loses loop-carried bounds. A phi operand arriving on a
  §5.9 back edge is still ⊤ when `walk` reads it, so a `while` body's values
  widen to ⊤ on sight. The missing input is no longer missing: proof consumes
  `analysis.zig`'s CFG now instead of carrying its own dominator copy, so
  `analysis.inLoop(b)` and `Analysis.loop_of` — which block is in a natural
  loop, and which header owns it — are in hand. The upgrade is the fixpoint
  (ascending-chain worklist over the loop body, widen after k rounds), not the
  structure it needs. Genvar loops (§6.6.1) unroll, so this bites `while` only.

### Lexer (`src/frontend/lexer.zig`)
- Left padding with `x`/`z` is unrepresentable.
- **A token is lexed more than once.** `next()` is pure in (src, pos), so
  `tokenEnd`/`tokenText` recover a token's extent by re-running the scanner —
  and `parser.zig` does that at 19 sites. The DOD trade is deliberate (`Stored`
  stays 5 bytes and no `len` column exists), but it means a per-identifier cost
  is paid several times per token: MEASURED, that is why cutting the keyword
  lookup moved `lint` by 5.8% when the lexer only scans ~450 bytes per
  compilation. Upgrade path is a `len` column, i.e. the thing the file header
  refuses; do not take it without a measurement that says the re-lex, not the
  lookup, is what costs.
- **The interner hashes what the lexer already walked, and the two cannot be
  merged cheaply.** `Ast.StringInterner.intern` wyhashes every identifier's text
  after the lexer has scanned it byte by byte. MEASURED (callgrind, ReleaseFast
  -Dcpu=x86_64_v3, a whole `--emit-zig` of `annex_e_spice/primitive_vpulse.va`):
  all of `Wyhash.hash` is 121,766 Ir of 7,618,237 — **1.6%**, and part of that is
  the preprocessor's macro map, not the interner. Note the keyword test hashes
  NOTHING (`std.StaticStringMap` computes no hash at all — see `token.zig`), so
  there is no second hash to eliminate; the only saving available is passing a
  hash from lexing to interning, which would make `lexer.zig` know about
  `ast.zig`. It knows nothing about it today and that is worth more than 1.6%.

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
