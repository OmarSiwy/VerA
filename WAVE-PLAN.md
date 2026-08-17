# VerA — Wave Plan 8–13

Successor to TODO.md's roadmap. Every number below is marked **MEASURED** (I ran it on this
tree) or **ESTIMATED** (I did not). Every file:line was opened before it was cited — the rule
`tools/contract.zig:19-28` states after four burns.

## Thesis

Seven waves bought conformance: 1150/1152 fixtures, 415 of them conforming by refusing. What
the suite cannot see is now the whole remaining defect surface — the suite grades VerA's own
testbench, so every bug that lives in the *artifact handed to a host* (a `>256`-unknown device
that cannot compile, an `i64` slot holding `S.con(0.0)`, an inductor with no KCL stamp, a
Jacobian with two branches aliased onto one unknown) is structurally invisible to it, and every
performance claim is unfalsifiable because `tests/bench.zig` does not exist. So: re-baseline and
build the instrument (wave 8), fix the five reproduced host-visible bugs and buy the tests that
protect the rewrites (waves 9–10), then land the two structural seams that make everything after
them a two-line change — node identity split from node spelling, and one discipline table serving
both the flatten hot loop and Annex F.2 (waves 11, 13). Deletion is the harvest, not the goal:
~975 lines go, in a fixed order, because the cheap items must run last or they do work twice.

## Waves

| # | Name | Thesis | Cost | Acceptance |
|---|------|--------|------|------------|
| 8 | Re-baseline + instrument | Seven options grade themselves against three different test counts, none of which is this tree. Buy the right to measure. | days | `zig build test` green at a printed N; `zig build bench` emits a 5-point curve and its assertions can fail |
| 9 | The five host-visible bugs | All five exit 0 and break in the host's build or the emitted numbers. Highest value, zero speculation. | week | torture `1150+k / 1152+k`, 0 FAIL, each fixture demonstrated FAILing pre-fix |
| 10 | Characterization | Waves 11/13 rewrite code nothing pins. A refactor graded by a suite proven blind to the path is not graded. | days | each new fixture flips FAIL under a *named* one-line mutation, recorded in the commit message |
| 11 | Node identity | One string namespace holds four kinds of name; three "cannot collide" comments are false. Key on `{kind,name}`, keep spellings byte-identical. | week | wave-10 fixtures flip; **zero transcript diffs** outside the fixtures under test |
| 12 | Surface deletion | Four options edit `src/root.zig`; cheapest-first does the cheap one three times. Fixed order + two guards so it is unrepeatable. | days | −975 lines MEASURED-at-landing; 2 new contract checks, each demonstrated FAILing on a planted violation |
| 13 | The device the host gets | Physics, graded by wave 8's curve and wave 11's seam. | week | +3 fixtures; XFAIL 2→1 *or* an explicit re-cost |

---

## Wave 8 — Re-baseline and build the instrument

**Nothing else may start.** Dependencies: none.

1. **`src/frontend/parser.zig` is dirty** (MEASURED: `git status --short` = one `M`, +5 lines).
   It is a half-done T0.6 routing real-literal parsing through `lexer.parseReal` with the old
   body renamed `deadParseReal`. Land it or stash it.
   - `zig build test` on the working tree: **204/205 MEASURED**, failing at
     `src/backend/codegen.zig:5526` — `transition(...)` pins `0.0000000022000000000000003`,
     the reroute emits `0.0000000022`.
   - `TODO.md:10` says `207/207`. Stale against both columns.
   - **The bless is a decision, not a rubber stamp**: is `2.2n` mantissa×scale (`2.2 * 1e-9`,
     0x…5271) or one `parseFloat("2.2e-9")` (0x…5270)? §2.6.2's own words ("24.7K, which
     indicates 24.7 multiplied by 10 to the third power") say the former; `lexer.zig:586`
     rounds once, which is the latter. `src/backend/codegen.zig:5502` is the tree's **only**
     pin on that decode (MEASURED: grep). Whoever lands T0.6 writes one asserted case naming
     the chosen rule, then re-blesses. Silent re-blessing is how a numeric regression ships.
2. **`tests/external.zig:247` runs in no step.** `build.zig` has three `test_step.dependOn`
   calls (run_va_test, run_contract_test, run_torture_test); external is built only as the
   `conformance` executable. One line after the conformance block, matching the shape already
   used for contract. If the file has bit-rotted against the current `vera` module, this is
   where it surfaces. ESTIMATED: 205→206.
3. **`tests/bench.zig` + `b.step("bench", ...)`**, mirroring the torture block in `build.zig`.
   See "Measurement first" below for the full spec. It exists in wave 8, not wave 13, because
   waves 11 and 13 are the ones it grades.
4. **TODO.md score block** rewritten from what this wave measures. Fold §3's
   `tools/contract.zig` row into the §4 CANNOT RUN bullet — same event from two sides, and the
   row describes a *resolved bug* (the stale `num_ports >= 1` guard), not a ceiling. Drop the
   "14-of-14 named files" framing: `TODO.md:145` says "the file is the authority, this is the
   index", and an index may be incomplete.

---

## Wave 9 — The five reproduced host-visible bugs

Depends on wave 8 (needs a green baseline to claim "unchanged"). Execution order below is the
commit order; items 1 and 4 have ordering constraints called out.

1. **`>256` unknowns emits an artifact no host can compile.** `src/backend/codegen.zig:861` is
   `try self.w("pub const U = enum(u8) {{\n", .{})` (MEASURED, opened). `tools/contract.zig`
   makes the dense `enum(u8)` normative and `isDenseEnum` rejects any other tag type. Nothing
   in VerA bounds `u_names.len` (MEASURED: no `255`/`256` guard in codegen.zig). `--emit-zig`
   exits 0; the *host's* build dies on `enum tag value '256' too large for type 'u8'`.
   One check in `emitTopology` before the loop + one reject fixture. If 256 is meant to be
   permanent instead, a `ponytail:` at `:861` and a §3 row — today it is **neither**, which is
   the one state the doctrine forbids.
2. **`--display=drop` puts an `S` value in an `i64` slot.** `codegen.zig:2938` gates
   `Lower.isFileCall` on `self.display == .emit`; in `.drop` the eight §9.5 descriptor names
   fall through to `void_tasks` (`codegen.zig:3127-3141`) and get `S.con(0.0)`, while
   `analysis.zig:580-603` types every one of them `.int`. `emitFileCallDropped`
   (`codegen.zig:3202-3215`) already switches on `callTy` and does the right thing.
   Fix: drop the mode from the guard; delete the 8 now-unreachable strings from `void_tasks`.
   Net-negative diff. Ships with one `--display=drop` fixture (`integer fd = $fopen(...)`
   feeding an equation) — which then guards the §9.4 re-timing later.
   **Order:** before TODO.md:57-64's re-timing, which rewrites this same `emitting_display` seam.
3. **SPICE node names that are keywords hard-fail in a file the user never wrote.**
   `src/frontend/spice_cards.zig:163` and the `.SUBCKT` port push (`:196`) gate synthesized
   names through `isIdent`, which checks §2.7 *shape* only. SPICE has no reserved words, so
   `.SUBCKT AMP (INPUT OUTPUT)` synthesizes `module amp(input, output);` → E0208 at a column
   with no source, against this file's own premise (`:11-19`: "a line this does not understand
   contributes nothing"). Wrap both sites in a §2.8.1 escape when `token.keyword_map` hits;
   E.3 connects by ORDER, so the spelling is never typed. MEASURED by the reviewer: probe
   fixture FAIL→pass, `annex_e_spice` stays 42/42.
4. **Parameter defaults silently fold to 0.** `src/ir/analysis.zig:697` is `else => null`
   (MEASURED, opened) — it covers `%`, `<<`/`>>`, all six relationals, `&`/`|`/`^`, `&&`/`||`,
   and the ternary arm below it. `lower.foldBinary` is complete. Measured by the reviewer:
   `parameter integer a2 = (1 << w) - 1` emits `0`, and a real `hfet2.va` ships 4 wrong
   parameters, one of which then violates its own `from (0:inf)`.
   Lift the arms out of `lower.foldBinary`; decide what `codegen.zig:1113` does when the fold
   genuinely cannot fold (rendering 0 for a non-constant default is the root cause; blanket
   refusal breaks defaults over `$temperature`/`$simparam`, so it needs a guard).
   **Order:** fill this *before* un-gating the `is_override` range check in `lower.zig`, or
   the fix converts silent-wrong-0 into a false reject on models whose real default is in range.
5. **`sysFuncTy` / `callTy` — the pair whose comment says "MUST agree" — disagree on two rows.**
   `analysis.zig:595` types `$analog_node_alias`/`$analog_port_alias` `.int`;
   `lower.zig:7708-7737` does not list them, so lowering types them `.real`. One false E0322 on
   legal §9.20 + §4.1.9 code, and an `i64` storage slot for a §3.2.1 real. Two rows at
   `lower.zig:7726` + a test looping one canonical list asserting
   `callTy(n) == tyOfParam(Lower.sysFuncTy(n))`. Skip the `mir.zig` hoist — one table move for
   two rows. **This changes MIR (if_cast) for ~6 fixtures**, which is why the wave needs a full
   torture run rather than spot checks.

Also here, because it is two one-liners and rides the same run:
`parser.zig:1582`'s `assert(kind == .exclude)` → the existing E0210 `failAt` (`parameter real p
= 1 from 5;` currently panics; in ReleaseFast that assert is `unreachable`, i.e. UB at a trust
boundary), and `proof.zig:1562` gains `if (pinfo.ty == .string) return;` (kills 2 spurious W0651
on the green `ch03_data_types/17_string_parameter_range.va`).
**Order:** both touch `parser.zig`/`proof.zig`, so after item 1 of wave 8.

---

## Wave 10 — Characterization only

Depends on wave 9 (shares torture runs). Buy the tests *before* spending the structure.

- **`gnd` alias fixture, fixture only.** `src/ir/lower.zig:2368` returns the bare identifier
  `"gnd"` for ground (MEASURED, opened), and `flowUnknown` (`:2392-2394`) formats it into the
  branch key, which `internNode` dedupes by name. A net *named* `gnd` that is not *declared*
  `ground` aliases `I(p)` and `I(p,gnd)` onto one unknown, silently — a wrong Jacobian.
  Ship the two-current fixture now. **Do not ship the `"gnd"`→`"0"` sentinel rename**: it
  re-spells emitted `U` members and `nodeName` has ~20 callers, most of them user-facing
  diagnostic text. That is wave 11's job, done a different way.
- **Inductor DC fixture.** MEASURED: `grep -rn "ddt(I(" tests/fixtures` = 0.
  `codegen.zig:3511`'s `if (val == .f_zero) continue;` means a purely reactive potential
  contribution emits **no eval row at all**. Fixture must be **DC-only and say so in its
  header** — `TODO.md:143-145` says a fixture standing over a §3 row converts a ceiling into a
  bug, and TODO.md:149-150 is "the Newton solve factors the resistive residual only". At DC
  `zDdt` returns 0 and the row is `V(hi)-V(lo)=0`, correctly a short.
  **The fix ships in wave 13 in the same commit as this fixture is un-XFAILed** — see below.
- **`cg_limit.zig` → `limit_kernels.zig`.** `cg_limit.zig:351`'s `helpers_txt` is a raw string
  literal, the only kernel block in the tree that is not a real file; `str_`/`rng_`/`table_`/
  `file_kernels` are all `@embedFile`d *and* `@import`ed so "the rows checked here are
  byte-for-byte the code that runs there" (`codegen.zig:5733-5739`). Rung 2 — the pattern
  exists four times. Then `cg_limit.zig:283`'s `if (vl != vn) ok = false;` becomes testable
  against ngspice `devsup.c` with 6 asserts. Nothing in the tree executes `D.limit` today
  (`tb.zig` calls `updateState`/`display`/`eval`/`q` only).
- **`zBilin` D≥2 test**, 10 lines at codegen.zig's existing kernel-test seam. Retires the
  orphan registered at `src/root.zig:28-30` (MEASURED: `filter_kernels.zig` is the sole entry).
  The reviewer hand-checked D=2 multiply-out and the D=3 DC identity `Σq = p0·2^D` — the kernel
  is correct, so this is characterization, not a fix.
- **`cloneExpr` ternary else-arm fixture**, ~15 lines under `ch06_hierarchy`: a ternary ELSE
  operand reading a child parameter overridden at the instance. MEASURED by the reviewer: the
  mutation `n.extra = @intFromEnum(third)` (dropping the clone) leaves all 1152 fixtures green.
  Cut the 22-arm visitor test: `hier_ident` is already fixture-guarded (dropping its rename
  measures 1149/1152) and the literal/event arms are empty `{}`.
- **Batch the one-token behavior fixes into this wave's single torture run**, each with a
  fixture: `%l` (`cg_display.zig:413` consumes an operand, `lower.zig:5219` skips it — widen the
  `'m'` arm to include `'l'`, drop the dead `'l'` from the verb group at `:449`); `$sscanf`'s
  `toLower` (`lower.zig:5532` case-folds so `%D` passes E0813, `str_kernels.zig:80` does not, so
  it silently scans 0 items — delete the `toLower` **and** correct `str_kernels.zig:174`'s
  "unreachable" comment, which stays false for non-literal formats either way).

---

## Wave 11 — Split node identity from node spelling

Depends on wave 10 (its fixtures are the grader) and wave 9 (codegen churn).

`src/ir/lower.zig:208`'s `node_voltages: StringHashMapUnmanaged(u16)` is one key space for four
kinds of name: user nets (`internNode`, `:2170`), §5.4.2 branch flows (`:2392`), §5.4.3 port
flows (`:2402`), §6.5.2 vector elements (`:2264`), plus §6.7 flattened paths joined by
`Elaborate.sep`. Three comments claim collisions are impossible; §2.8.1 strips the backslash, so
`\flow(p,n)` **is** the identifier `flow(p,n)`. Reviewer reproduced three distinct miscompiles.

- Add `node_kind: ArrayList(enum { net, branch_flow, port_flow })` filled by `internNode`; key
  `node_voltages` on `{kind, name}`. `node_order` keeps the pretty name — the spelling is
  fixture-visible (`ch05_analog_behavior/controlled_sources.va:38` reads
  `//! sweep flowZ28cpZ2ccnZ29`).
- Then `codegen.isFlowUnknown` (`:938-940`) is an array read, not `startsWith("flow(")`;
  `abstolOf` (`:967-987`) reads a recorded index instead of re-parsing `flow(a,b)`.
- **`tb.zig:310-320` is a third site, not a risk note.** It re-formats a fixture's `//! probe
  I(a)` into `flow({s},gnd)` under a 20-line doc paragraph arguing the convention. It asks
  lowering for the unknown, or ground-referenced probes stop resolving.
- `Elaborate.flat` escapes `sep` inside a leaf identifier before joining, and again when
  interning a `Defparam.path` (`elaborate.zig:658-663` documents the reliance on the raw `.`).
- The vector-element namespace is a **separate decision**, not a free rider (`\b[0]` currently
  raises a false E0902 for a net declared once). Schedule it or write it down as a ceiling.
- `lower.zig:8695-8707` and `:8760-8765` assert the literal `"flow(<"` / `"flow(p,n)"` spellings.
  They must assert the **kind tag**, or the key split passes while the old predicate stays pinned.

**Acceptance is the invariant, and it is checkable:** `diff` of every emitted `device.zig`
before/after is empty except the fixtures under test. That is what "byte-identical spellings"
means and it is why this shape beats the sentinel rename.

---

## Wave 12 — Delete the surface, in the one order that does not do work twice

Depends on wave 11 (it rewrites `proof.zig`/`root.zig` comments). Four options edit
`src/root.zig`; a cheapest-first sort runs the citation sweep first and it must run **last**.

1. **`pub const` → `const` at `src/root.zig:56-76`**, keeping `pub` on `diag`, `codegen`,
   `orchestrator`, `tb` (MEASURED: those four are the only module names reachable from
   `src/cli.zig` + `tests/`). **Add `pub const FloatMode = proof.FloatMode;`** — `root.zig:835`
   uses it, and without this line the commit does not compile. `root.zig:975`'s `inline for`
   names the consts directly and keeps type-checking every stage.
   This retires the *only* stated risk in steps 2 and 3 ("`pub` on the library module, an
   out-of-tree embedder could reference it") before either is argued.
2. **Delete `src/backend/eval_batch.zig`** (MEASURED: 702 lines) + `root.zig:74`, `:766`, its
   element of the `:975` list. It publishes a **second, incompatible device ABI** —
   `n_terminals`/`n_regions`/`region(comptime N,...)`, none of which `tools/contract.zig`
   declares and none of which codegen emits, so `Batch(D)` can never be instantiated with a
   VerA device. Its only client is its own `TestDiode`.
   **Take the 6-site comment list**, not the 4-site one: `root.zig:21` (the architecture map
   literally advertises it), `lexer.zig:7`, `str_kernels.zig:220`, `proof.zig:16`,
   `proof.zig:1506`, `orchestrator.zig:86`. The last is a §3 ceiling's stated justification and
   needs a §3 reword too.
   **Preserve the measured prose** — gather/add/scatter over the stamp loop produced 14 wrong
   CSR cells and was not faster; prefetch measured slower (`eval_batch.zig:415-429`) — as a
   TODO.md §2 will-not-do **with its numbers**, or the next person re-derives it wrong.
3. **Delete `root.Compilation`** (`src/root.zig:510-720`, MEASURED 273 lines by executing the
   deletion: 978→705) + its two tests. Keep `:953`'s determinism test (it is the invariant, and
   it does not need the cache) and `Bag.detach` (live at `:316`). Its own docstring at `:540-543`
   states the case against it. This also deletes `rebuilds: u64 = 0, // Cache misses since init.
   Benchmarks read it.` at `:550` (MEASURED: opened; no reader or writer anywhere).
4. **Then** the citation sweep. MEASURED: `docs/` holds 22 files, all LRM chapters and annexes —
   `03-codegen.html`, `02-incremental.html`, `05-build-artifact.html` are **not** among them, and
   `git log --all` shows they never were. 18 sites across 6 files; three of them live inside the
   block step 3 just deleted, which is why this runs fourth. Retarget each to the in-tree file
   that argues the point (`naming.zig`'s ABSOLUTE RULE header, `unit_plan.zig`'s header,
   `proof.zig`); delete the five `(ch.N)` parentheticals — each sentence reads fine without them,
   and `root.zig:541`'s "(ch.2)" *resolves*, to LRM lexical conventions, which is worse than
   dangling. **Do not delete `orchestrator.zig:206`'s `tests/bench.zig` citation** — wave 8 makes
   it true, which is cheaper than the rewrite. Do not batch-sed.
5. **`// CORPUS:` lines**, same sweep, same doctrine: eight sites quote load-bearing MEASURED
   numbers against models that are not in the tree (`ssa.zig:79-91` 2,114,902 live cells,
   `ssa.zig:258` 4.6 GB, `codegen.zig:404-441` hisimhv_va 440,124→59,986 lines and vbic13_4t
   30 core calls→1, `unit_plan.zig:252/:458/:563/:601`). The dangling citation is a *dataset*.
   One line each naming where the model came from (VBIC and BSIM-SOI are public). The
   `eval_batch.zig:425` one dies with the file — its numbers move to §2 per step 2.
6. **Two guards in `zig build test-contract`**, both greps over `src/`:
   (a) no `.html` anchor or `tests/*.zig` path that does not resolve;
   (b) every `src/backend/*.zig` is reachable from `src/root.zig`'s import graph **or** named in
   the orphan block at `root.zig:28-30` (MEASURED: exactly one entry today). That block is
   already the declared allowlist. Guard (b) is what makes a 702-line orphan unrepeatable;
   without it this wave is a one-time cleanup. Each guard demonstrated FAILing on a planted
   violation before the commit lands.

---

## Wave 13 — The device the host actually gets

Depends on wave 11 (SPICE must not start minting escaped names before the escaped-identifier
path is collision-safe) and wave 8's bench (it grades the perf half).

1. **The one shared table: `disc_of`, built two-slot.** `elaborate.declaredDiscipline`
   (`elaborate.zig:1118-1126`, MEASURED, opened) is a linear scan of `self.nets`, which grows
   with every inlined instance port — four append sites. Replace with
   `StrId → struct { first: StrId, other: StrId = .none, tok }`.
   - **Two slots, not `getOrPut`.** First-wins is XFAIL-1's blocker verbatim:
     `resolveDiscipline` early-returns on `declaredDiscipline(bound) != .none` and throws away
     exactly the candidate list Annex F.2 step 4.b needs ("more than one candidate whose domain
     matches"), which is what `annex_f_resolution/unknown_discipline_mixed_port.va:47-56` builds.
     Same O(1), same ~10 lines. Shipping `getOrPut` spends the edit and keeps the blocker.
   - **Re-cost XFAIL-1 as a wave item, not a rider.** With `other` the UNKNOWN arm is decidable
     and reserved `E0903` fires — but it also needs `connectrules` accepted-and-dropped past
     E0201 (conformant here: §7.7.1 insertion cannot match either way, per the fixture's own
     header) **and** a mixed-port domain predicate that has no implementation in `elaborate.zig`
     today. ESTIMATED: days, not the ten-line map change it looks like.
   - Two §3 elaboration rows retire at the same insertion point: "§3.11 compatibility consulted
     at port bindings only" (its stated upgrade path *is* the child-net loop, one of the four
     sites) and "two declarations of one identifier: first wins".
2. **`proof.verdict`'s per-contribution `@memset`.** `src/ir/proof.zig:1655-1660` (MEASURED,
   opened): `seen` is allocated once, then `@memset(seen, false)` is the first statement inside
   `for (self.lower.contributions.items, 0..) |c, u|`. Generation-stamp on `u`, which is already
   the unique loop index — 4 lines, deletes work, provably cannot change the verdict.
   **Do not write "6.9×" in the commit.** That number is from a netlist where units *and* values
   both scale; on the corpus this repo actually cites (`codegen.zig:404`: 58 units, 1.2M values)
   units are near-fixed and the reset is linear-ish. Quote wave 8's curve or quote nothing.
3. **T0.5 in the same file, same commit.** `proof.zig:506-585` is a private Cooper/Harvey/Kennedy
   copy computing `idom`/`rpo_num` and nothing else; `analysis.zig:405-432` computes those **plus**
   `is_loop`/`loop_of` and exposes `inLoop`. Deleting the copy hands §3's only proof ceiling
   ("immediate widening loses loop-carried bounds", upgrade path at `proof.zig:1049-1051`) its
   missing input for free. Re-word `:1049` to name `analysis.inLoop` in the same commit.
4. **Purely reactive potential contribution emits no eval row.** `codegen.zig:3511`'s
   `if (val == .f_zero) continue;` — gate on **both** halves. §5.6.1.3 `discardOpposite`
   (`lower.zig:4215`) writes `.f_zero` to both `acc.resist` and `acc.react`, which is exactly why
   its "a zeroed accumulator emits NO row" contract survives untouched. Ships in the same commit
   as wave 10's DC-only inductor fixture, which flips FAIL→pass.
5. **§4.6.4 noise generators are keyed per contribution, not per call site.**
   `combined/13_noise_temperature_analysis.va` declares thermal + flicker on one branch and
   exports only `.flicker` — deleting the one generator the documented Jacobian fallback can
   compute. Make `noise_kind` a 2-bit set, OR at `lower.zig:3600`, loop at
   `codegen.zig:3653-3661`. +5/−3, no ABI change. **Write the exclusions into §3 rather than
   deferring them silently**: (a) the `.table` tag is blocked by `tools/contract.zig:137`'s "the
   two changes land together"; (b) refusing `noise_table` breaks fixture 27; (c) the
   assign-then-contribute form used by fixtures 27 and 38 exports zero generators today and
   still will. Amend `TODO.md:171` and `codegen.zig:3641` to say the fallback covers `.thermal`
   only.

---

## Will not do — with the reason, so it is not re-litigated

- **`RVec(N)` / N-wide SIMD batch eval.** The shipped `eval` takes scalar `*const Model` /
  `*const Instance` and codegen emits `S.con(inst.mfactor)`, `zDdt(S, .., inst.x__prev,
  inst.dt)` and real branches on `inst.analysis_kind`. An `RVec(N)` instantiation therefore gives
  N *bias points of one instance*, never N instances. ~90 lines with no consumer — deleted on
  sight by §2's own rule.
- **Wiring `n_terminals`/`n_regions`/`region` into `tools/contract.zig`.** Members ahead of a
  consumer. No fixture can grade it, and its order-of-magnitude estimate has no measurement.
- **`Ast.ValueRange` → tagged union.** MEASURED: the union removes **0** sentinel checks (it
  respells `r.strings != null` as `else => continue`), goes net-negative on lines once `?u32`
  pool offsets become `[]const StrId`, and delivers **0** progress on §3.4.2 membership — that is
  gated on the `is_override` check in `lower.zig`, not on the type. The two one-liners are in
  wave 9; the union is not.
- **`mir.foldBin` hoist for `sysFuncTy`/`callTy`.** One table move for two rows. Add the rows
  and the looping assert; hoist when a third consumer appears.
- **A 22-arm `cloneExpr` characterization test.** `hier_ident` is already fixture-guarded
  (MEASURED: dropping its rename gives 1149/1152), and the literal/event arms are empty `{}`.
  ~60 lines to cover arms that cannot be wrong. The one measured hole gets a 15-line fixture.
- **`tests/external.zig` pre-flight spawn.** 1152 `FileNotFound` lines → 1, on an opt-in dev
  step whose prerequisite is already at `README.md:94` and whose message at `harness.zig:214`
  already says "the runner itself failed". Add when someone actually loses time to it.
- **`primitiveAccess`'s discipline lookup** (`elaborate.zig:1258`). MEASURED below 0.05%.
- **`Lower.contributions`' full-table scans** (`lower.zig:3891` `checkProbeBranches`, `:3911`
  `contributedOn`, `:3925` `indirectOn`). MEASURED: max `<+` count across all 1152 fixtures is 8.
  The site's own `ponytail:` names its trigger — "if a MODEL ever makes this measurable".
  Reconsider **only** if wave 8's bench curve bends on a *PDK-shaped* input (one subckt, dozens
  of instances). Flat to n=512 and bending only at 4096 means it is a netlist, and TODO.md:92-110
  settles that scope. Note the proposed grouped fix does not help the instance-array shape
  (`res u[0:3999](a,b)` collapses to one contribution and leaves `O(reads²)` on one pair) — the
  correct shape is a per-pair 2-bit access set, if it is ever needed.
- **The `"gnd"` → `"0"` sentinel rename.** Renames emitted `U` members; `nodeName` has ~20
  callers, most of them user-facing diagnostic text; churns `codegen.zig:5031/5055/5089`,
  `tb.zig:320`, and `ch05_analog_behavior/single_terminal_branch.va:14`'s
  `//! sweep flowZ28pZ2cgndZ29`. Wave 11's key split closes the same hole with byte-identical
  spellings.
- **§9.4 display operand re-timing (XFAIL-2), still last.** `finishDisplays`
  (`lower.zig:1274-1283`) already defers the display *unit*; the cost is that `Display.val` is a
  `Mir.Value` lowered at statement position, so the *operands* are not. TODO.md:59-61's "751
  fixtures print" is an **at-risk bound, not a change bound** (independently counted: 742
  display-bearing fixtures, 35 with a flow access on a task line). Fix that sentence in wave 12's
  sweep. The value-patch shortcut is refuted: patching `c.resist_val` into the barrier's operand
  does not move the definition, and it was MEASURED to break
  `ch04_expressions/145_ddt_idt_nature_tolerance.va` with `use of undeclared identifier 't4'`.
- **`torture` wall time as a perf signal.** `build.zig` spawns a `zig build-exe` per fixture; any
  timing read off it measures the child Zig compiler.
- **A second machine-readable side channel for assertion counts** (`assertions.tsv` + `--bless`).
  Banned twice at the site: `harness.zig:31-34` ("There is deliberately no machine-readable side
  channel") and `torture.zig:33-38` ("THERE IS NO GOLDEN FILE... deliberately"). The expected
  floor is derivable from the fixture source, which `checkAssertions` already walks — one
  `count += 1` in an existing loop if it is ever wanted.
- **A central `ponytail:` register in TODO.md §3.** `lower.zig:8283-8291` is a written verdict on
  exactly this: a five-entry central list was tried, four of the five had shipped and gone stale,
  and it was deleted. MEASURED: 85 markers across `src/`+`tools/` against 46 §3 bullets — the
  relation is not and was never 1:1. §3 is an index; `TODO.md:145` says so.
- **A `Mir.verify()`.** Three of its six proposed invariants are already enforced for free:
  `emit` is the only builder (grep: zero external `.result =` writers), `MultiArrayList.get`
  bounds-checks under the Debug default that every fixture testbench uses, and
  `mir.zig:509`'s `assert(hops <= parent.len)` is the alias-forest termination check already
  running. One proposed invariant ("each block ends in exactly one terminator") is **false** for
  current MIR — `analysis.zig:206` tolerates `.none` — so a verifier to spec would panic on every
  module.

---

## Measurement first

`tests/bench.zig` does not exist (MEASURED: `tests/` = `external.zig  fixtures  harness.zig
torture.zig`). **No performance claim lands in a commit message, a comment, or TODO.md before
this step exists and prints the number.** Two waves already carry claims (6.9×, 28.2%) measured
against a synthetic the panel graded *both* ways — SURVIVED for `proof.verdict` and
`declaredDiscipline`, KILLED for the `contributions` scans. One instrument settles it.

Spec, all seams existing, no new API:

- **Phases:** `Preprocessor.process` → `vera.compileSourceOpts(gpa, src, .lint, .{})` →
  `result.generateDevice()` → orchestrator no-op rewrite. Four timers.
- **Inputs, two kinds:** (a) the 1152 fixtures as one batch — the "small files stay fast" case,
  the only one the project's scope guarantees exists; (b) an in-file
  `fn gen(w, n_contrib, n_vals, n_inst)` emitting `.va` text at n = 1/8/64/512/4096.
  **Report the curve, never a single number.** A slope is what settles scope arguments: if
  `declaredDiscipline` is flat to 512 and only bends at 4096, it is a netlist and dies on
  evidence rather than on argument.
- **Defeating the optimizer:** results are heap-owned across the timed region;
  `std.mem.doNotOptimizeAway` on `result.mir` and `device.text.len` after each phase;
  `defer result.deinit()` outside the timer. `std.time.Timer`, N=25, report **min**.
- **Output:** one TSV line per `(case, n, phase)`: `case⇥n⇥phase⇥min_ns⇥bytes`. Plain text on
  stdout, so `diff` works. Not a second machine-readable format in the sense harness.zig bans —
  no committed artifact, no `--bless`.
- **It must be able to fail**, or it is the step the panel already killed ("a step that asserts
  nothing prevents nothing"). Timings print; the *deterministic* quantities are `expect`ed in the
  same pass: no-op rewrite writes **0 bytes** (this is `orchestrator.zig:206`'s claim, made
  true), `device.text.len` per generated shape, MIR value count per generated shape. Those cannot
  drift with the machine, so the bench doubles as a size-regression test.
- **build.zig:** `bench_mod` with `.imports = &.{.{ .name = "vera", .module = vera_mod }}`, an
  options object carrying `fixture_root`, `b.step("bench", ...)`. **Not** in `test_step` (it takes
  seconds), but `test_step.dependOn` its own unit tests, exactly as torture already does.

---

## Decisions — settled by the repo owner, 2026-08-17

All five were put as open questions with a recommended default; every default was adopted. They
are decisions now, not suggestions: a wave that contradicts one is wrong, and re-opening one
needs a reason written down here, in TODO.md §2's style.

1. **`2.2n` decodes ROUND-ONCE** — one `parseFloat` of the joined text, not mantissa×scale.
   `codegen.zig:5502` is re-blessed and gains an asserted case naming the rule, so the decision
   is visible to whoever hits it next. Unblocks T0.6, which is not a free deletion: it changes
   emitted device text.
2. **`|U| ≤ 256` is a PERMANENT ceiling.** `emitTopology` refuses past it with a new diag code
   and a reject fixture; `codegen.zig:861` gets a `ponytail:` and TODO.md §3 gets a row naming
   `enum(u16)` as the upgrade path. Silent emission of an uncompilable artifact was the one
   option wrong under every reading.
3. **A 4096-instance flattened netlist is a BENCH INPUT, not a fixture.** Wave 8's curve decides
   each performance item on evidence; no fixture stands over a §3 row.
4. **No out-of-tree embedder is assumed beyond ARPice** (checked: it uses only `compileSource`,
   `orchestrator.Module`, `buildArtifact`). Wave 12 privatizes; a loud compile error is the
   desired signal and one grep reverts it.
5. **`--check`'s COMMENT gets fixed, not the code.** `src/cli.zig:349` overstates what it does:
   `eval` is generic over `comptime S`, so Zig never analyses the body. Routing `--check`
   through the existing `renderRunner`/`buildExe` path is the honest upgrade if it is ever
   wanted; a hand-written second instantiation probe is a second surface that must track what
   the engine calls — the exact drift `tools/contract.zig`'s header records three revisions of.

The original framing of each, with the evidence that produced the recommendation:

1. **What is the correct decode of `2.2n`?** Mantissa×scale (`2.2 * 1e-9`) or one `parseFloat`
   of the joined text? They differ by 1 ULP, `codegen.zig:5502` is the only pin, and T0.6 changes
   the answer. §2.6.2's wording ("24.7 multiplied by 10 to the third power") supports
   mantissa×scale; `lexer.zig:586`'s round-once is the stronger numeric.
   **Default: adopt round-once, re-bless `:5502`, and add one asserted case naming the rule** —
   it is a strengthening the LRM does not forbid, and it deletes a second decoder.
2. **Is `|U| ≤ 256` a permanent ceiling or a bug?** `codegen.zig:861` hardcodes `enum(u8)` and
   `tools/contract.zig` makes it normative, so widening is an ABI change to a shipped promise.
   **Default: permanent — refuse at `emitTopology` with a new diag code and a reject fixture**,
   plus a `ponytail:` at `:861` and a §3 row naming `enum(u16)` as the upgrade path. Silent
   emission of an uncompilable artifact is the one option that is wrong either way.
3. **Is a 4096-instance flattened netlist in scope for grading?** TODO.md:92-110 excludes netlist
   *parsing*, but VerA's own `Flatten` produces this shape from §6.2.2 instantiation.
   **Default: admit it as a bench input, not as a fixture** — wave 8's curve decides each perf
   item individually, and no fixture stands over a §3 row.
4. **Does an out-of-tree embedder other than ARPice exist?** Wave 12 step 1 breaks
   `vera.Mir`/`vera.Lower`/`vera.eval_batch` loudly at compile time. ARPice was checked and uses
   only `compileSource`/`orchestrator.Module`/`buildArtifact`.
   **Default: assume not; privatize.** A loud compile error is the desired signal and one grep
   reverts it.
5. **`--check` currently type-checks declaration shapes only** — `eval` is generic over `comptime
   S`, so Zig never analyzes the body, and both wave-9 items 2 and 5 exit 0 under it.
   **Default: fix the comment at `src/cli.zig:349`, not the code.** Routing `--check` through the
   existing `renderRunner`/`buildExe` path is the honest upgrade if it is ever wanted; a
   hand-written second instantiation probe is a second surface that must track what the engine
   calls, which is the exact drift `tools/contract.zig`'s header records three revisions of.
