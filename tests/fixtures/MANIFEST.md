# Approval Manifest — fixtures-only phase

**Status: NOT APPROVED. Of 26 reviewed rows, 3 are clean and 23 are partial. A repair pass fixed
every row that carried a charge; all 26 have since been re-verified by opening the files. No row is
unsound and none returns `needs-work` — but twenty-one carry defects in their own supporting
evidence, seven of them written by the repair itself (§5.1). The scope gate passes (§5.6).**

## 1. What this is

This is the deliverable of a fixtures-only workflow. **No feature was implemented.** Every
artifact under `/home/omare/Documents/Projects/Zig/VerA/tests/pending/` and
`/home/omare/Documents/Projects/Zig/ARPice/tests/pending/` is a test that encodes expected
Verilog-AMS behavior and, in the intended case, fails against HEAD (`45b505d`). Nothing is
wired into `zig build torture` or ARPice's `tests/fixture_catalog.zig`; the existing green
gate is untouched and re-run (1323/1323). **VerA shows only `?? tests/pending/`.** ARPice shows
that plus four `src/` files carrying the deliberate, tested Q03 build fix — not a scope violation
(§5.6), but uncommitted, which is the one thing to settle before approving anything that cites a
buildable HEAD.

Approving this commits you to three things: (a) the **expected values** in these files become
the definition of correct for the rows they cover — an implementer will change the compiler
until they go green, so a wrong value here becomes a wrong implementation; (b) the **clause
citations** become the project's record of why each value is correct; (c) the
**implementation order** in §6 becomes the plan. It does *not* commit you to the 13 `w2/*`
branches, which are empty (§2), nor to the two infrastructure fixes in §3 that are still
specified-but-not-applied. The third, `Q03`, **is** applied and is why ARPice compiles at all.

Three rows are clean: `A06-noisetables` (never charged, re-verified anyway), `D03` and `D06`. The
other twenty-three are partial, which here means one specific thing: **every defect charged to the
row is genuinely fixed in the fixture files — not confessed in prose — and the repair then left, or
introduced, a defect in the evidence that justifies the row's expected values.** `D08`, `A06`, `M01`
and `M02` were called sound in the previous revision and are not; re-checking the citations the
first pass had passed is what moved them. §5 is the section that matters, and §5.1 is the part of
§5 that matters.

## 2. Merge table — the 13 `w2/*` branches

All thirteen `w2/*` branches resolve to `45b505dadc54983264da12026c93f194536267f2` — the exact
tip of `ddt-capform`. Each reflog contains one entry, `branch: Created from HEAD`. Every
worktree under `/home/omare/Documents/Projects/Zig/vera-wt/` is `git status --porcelain`-clean
with no stashes. `git merge-tree --write-tree ddt-capform w2/<x>` returns tree
`21f7961afd2219f4c2453ee1033299c969cd4330`, which is `ddt-capform^{tree}`. There is nothing to
merge and nothing to salvage. The table is ordered merge-first as requested; no branch reaches
the merge tier.

| Branch | Rows | Recommendation | Conflicts | Still uncovered |
|---|---|---|---|---|
| `w2/elab` | D07 | **abandon** | none — tip *is* the integration tip; merge is a no-op fast-forward | All of D07: digital instance arrays, full parameter/defparam binding, hierarchical name resolution and generated names, tasks/functions scope rules, library/config declarations and top selection, mixed Verilog/AMS compilation units, `.v` acceptance through a real execution path (frontend deleted; extension rejected by name). D07 gates M03/M04 via plan line 71. |
| `w2/hier` | H01–H04 | **abandon** | none. **Caveat:** ref is checked out in `/home/omare/Documents/Projects/Zig/vera-wt/hier`; `git branch -d` will be refused until the worktree is removed. | All of H01–H04: final instance parameter values and sweeps, unoverridden defaults, string-aware paramset selection, constant-function control flow, context width/signedness propagation, paramset output-variable preservation, port audit, discipline propagation and coercion, Annex E naming/binding and model-card parameters. Blocks M03/M04. |
| `w2/mixed` | M01–M04 | **abandon** | none | All of M01–M04. What exists on `ddt-capform` is lexical only — `connect`/`connectrules` appear as reserved-word rejection fixtures, which does not establish insertion. |
| `w2/sync` | D05, M02 | **abandon** | none | D05's analog macro-process region (scheduler has the six-region enum and heap but no solver connection), region-trace / delta-cycle / far-future / removal-during-dispatch tests; D04 sync primitives (`wait`, named events, `->`, fork/join, `disable`) absent from `src/`; all of M02. |
| `w2/procedural` | D04 (+D05) | **abandon** | none | D04's open bullets: `@*`, named events, intra-assignment event controls, `wait`, tasks/functions with argument passing, automatic/static lifetimes, `disable`, fork/join, procedural assign/deassign and force/release. |
| `w2/selects` | D02 | **abandon** | none | Bit/part selects, indexed part selects `+:`/`-:`, select direction for `[7:0]` and `[0:7]`, out-of-range and X/Z index behavior, lvalue selects, constant folding that agrees with runtime. `docs/CONFORMANCE-GAPS.md:25` still lists these; grep for `partSelect`/`bit_select` over `src/` returns nothing. |
| `w2/gates` | D08 | **abandon** | none | All of D08. `lib/frontend/token.zig` (~194-196, ~755-828) lexes the entire gate vocabulary as `kw_reserved` — deliberate rejection, not support. No parser production, no strength lattice, no switch solver, no UDP evaluator. Also depends on D03 drive strengths, still open. |
| `w2/stateful` | A04 (+A03) | **abandon** | none | A04's argument-complete operator audit across DC/transient/AC/noise, removal of fixed history capacities, rollback rollback, initialization/reset values, pole/zero forms, explicit resource-failure diagnostics. Re-baseline against `ddt-capform`, which already carries some `ddt` capacitor-form work. |
| `w2/tables` | A05 | **abandon** | none | A05: quadratic/cubic spline modes, fatal (`E`) extrapolation at runtime rather than E0815 at compile time, full Table 9-31 control-string coverage, file-backed tables loaded on first *executed* call, derivative correctness through the lookup. Existing `$table_model` fixtures predate this branch. |
| `w2/fileio` | S01, D09 | **abandon** | none | b/h/o radix file tasks, `$fgetc`/`$ungetc`/`$fread`, `$readmemb`/`$readmemh`, `$sdf_annotate` (no digital-context impl at all); the `zFRead` over-consumption deviation admitted at `lib/backend/file_kernels.zig:298`; digital/procedural-context file I/O; format-conversion audit; scratch-buffer isolation. |
| `w2/systasks` | D09, S01 | **abandon** | none | `src/sim/digital.zig` dispatches exactly four names (`$signed`, `$unsigned`, `$display`, `$finish` at :138/:140/:1473). All of IEEE 1364-2005 §§17–18 in the digital runner. Analog-side `file_kernels.zig`/`cg_display.zig` are reusable components, **not** evidence the digital row is closed. |
| `w2/vcd` | D09 (§18) | **abandon** | none | All of §18.1–18.4. `grep -rn "dumpvars\|dumpfile" tests/` = 0 hits, matching `docs/CLAUSE-AUDIT.md:357`. Extended VCD §18.3 strength encoding is additionally blocked on D03 drive strengths. |
| `w2/vpi2` | P02, P03 | **abandon** | none | `src/vpi/root.zig` exports 11 routines; the entire value and callback surface is absent. All of P02 and P03. P01 is already merged via the `vpi` worktree and is unaffected. |

Three older worktrees (`wt-noisekind`, `wt-tnom`, `wt-width`) sit on unrelated older commits and
are prunable. Two dangling commits in the object store (a 2026-09-16 "WIP on conf/nets" and a
2026-08-31 `$limit` commit) are unrelated to any `w2/*` branch; no work was lost.

**Net: nothing to merge. Reuse the worktree slots or prune them; either is destruction-free.**

## 3. Three infrastructure defects — one fixed, two confirmed and not fixed

All three were investigated independently and reproduced. **`Q03` is now fixed** — the fix sits
uncommitted in ARPice's working tree as four modified `src/` files, and it is the reason anything
host-side in this manifest is measurable (§5.6). The other two are specified and **not applied**.
`build.zig` and both `tests/fixtures/` trees are untouched in both repos; VerA's `src/` is
untouched.

### Q03 — the tree did not compile, and the test counter hid it — **fixed, uncommitted**

**Site 1.** `/home/omare/Documents/Projects/Zig/ARPice/src/analysis/pss/hb.zig:286` calls
`std.posix.getenv("ESPICE_HB_TRACE")`. `getenv` does not exist in Zig 0.16's `std.posix`. It
kills three compile steps — `compile exe espice`, `compile lib espice`, `compile test`
(problem_tests) — which transitively block `test-problem`, `test-c-api`, `test-correctness`.

*The ticket's framing is wrong:* this is **not** a ReleaseFast issue. Sema is optimize-mode
independent; a minimal probe errors identically under Debug, ReleaseSafe and ReleaseFast. What
hid it is **lazy analysis** — `src/analysis/root.zig`'s `test { … }` aggregator (lines 7-20)
lists twelve `tests/*.zig` files and zero `pss/*`, so `zig build test-analysis` never
sema-checks `hb.zig`.

*Fix, applied:* `std.c.getenv`, which this repo already uses correctly at
`src/analysis/solvers/converger.zig:50` and `:80`. Root-cause shape is a third flag beside
`opdbg()`/`newtonDbg()` reusing the existing private `envFlag` + `std.atomic.Value(u8)` cache
(`converger.zig:77-83`); `hb.zig:17` already imports `converger`. This also removes a second
real bug — `hb.zig` re-reads the environment once per Newton iteration. `link_libc` is already
true on every artifact that reaches `hb.zig` (`build.zig:299`, `:361`, `:210`/`:228`).

**Site 2** (found by the sweep, same structural cause). `lib/frontend/tests/prepared.zig:38,
:51, :54` call `buildJob(dir, node_id, sources, cards)` with 4 arguments;
`lib/frontend/prepare.zig:702` declares 6 (`node_neg: u32, ports: [4]u32` were added) and the
only production caller, `prepare.zig:338`, was updated while the test file was not. `zig build
test-prepared` → "expected 6 argument(s), found 4". Internal drift, not a Zig API removal.

**The guard, not applied.** Honest answer first: a step that compiles the ReleaseFast lib
already exists and already fires — `test-c-api` (`build.zig:409`) does
`c_api_test_mod.linkLibrary(c_api_lib)` and is wired into `test` at `:453-454`. Another
lib-compiling step catches nothing new. The two real gaps:

- **(5a) Ten declared test steps are unreachable from `test`.** `test_step` (`build.zig:399`)
  depends on only five things (`:454, :496, :503, :520, :560`), orphaning `test-app`,
  `test-numerics`, `test-prepared`, `test-output`, `test-frontend`, `test-eval`,
  `test-builder`, `test-solvers`, `test-devices`, `test-benchmark` — which is exactly how
  Site 2 rotted, while `AGENTS.md:131` prescribes `zig build && zig build test` as the gate.
  Minimal diff: one `test_step.dependOn(&run.step);` inside the suite loop
  (`build.zig:542-546`) covers six, plus four lines for `run_exe_tests` (`:433`),
  `run_numerical_tests` (`:459`), `run_prepared` (`:477`), `run_bench_tests` (`:579`).
- **(5b) Gate on the process exit code, not the `N/N tests passed` clause.** That clause counts
  only tests that were *built and ran*; three dead compiles removed 31 tests from both sides of
  the fraction and printed a green `266/266`. `zig build test` does exit 1. If a textual signal
  is required, match the `steps succeeded` clause for a non-zero `(N failed)`.

*Measured with the fix in the tree:* **297/297 unit tests** and **351/353 build steps**, against a
tree that previously compiled in no optimize mode at all. The two gaps above (5a and 5b) are still
unapplied, so the ten orphan steps remain unreachable from `test`.

*Deliberately out of scope, and now measured once:* the fix unmasks `run exe test-correctness` at
**518 passed / 98 failed of 616** — the one remaining failed build step. It has never had a
baseline because the exe has never compiled, and one run is one sample: the same suite has been
recorded at 492, 494 and 518 on an unchanged tree, so nothing here establishes determinism either
way. Sampled
failures are genuine numeric and device-catalog debt
(`fixtures/convergence/monotonic_cubic_1.sp` expects `6.8232780382802e-1`, gets `1e0`;
`fixtures/dc/device_b3soidd_output.sp` — "MOSFET LEVEL 56 needs model 'b3soidd', which is not in
the device catalog"). Separate rows. **Q03 is done when the tree COMPILES.**

*Not defects, recorded so the next sweep does not re-open them:* `zig build bench-frontend`
exits 1 with `error.MissingPath` — the step just wants a `-- <path>` argument
(`build.zig:123` supplies no default). And `src/analysis/solvers/dev_harness.zig:22-23` uses
`std.os.linux.clock_gettime`, which still exists in 0.16.

### A08 — `u_nodeset` is exported and read by nobody

VerA emits `pub const u_nodeset = [n_u]?f64{ … }` from
`/home/omare/Documents/Projects/Zig/VerA/lib/backend/codegen.zig:1743` (`emitNodesets`), fed by
`lower.nodesets` (`lib/ir/lower.zig:316`), indexed by the `U` unknown enum. `?f64` because
§3.6.3.2's "a null value … indicates that no nodeset value is being specified".

Nothing reads it. `grep -rn u_nodeset ARPice/src ARPice/include` → zero hits. VerA's own
testbench does not read it either: `lib/backend/tb.zig:688` opens every operating point with
`var x: [n_u]f64 = @splat(0.0);`. The defect is demonstrable entirely inside VerA.

*The call site that must consume it, unchanged:*
`/home/omare/Documents/Projects/Zig/ARPice/src/analysis/dc/op.zig:24-27`

```zig
pub fn coldStart(ckt: *root.Circuit, x: []f64) void {
    root.zeroSimd(x);
    ckt.seedJunctions(x);
}
```

This is the only place the solution vector gets its pre-Newton value; all five OP-ladder rungs
(`op.zig:42,106,150,158,194,223`) and `dc.zig:18,238` route through it. The nodeset write
belongs between the two lines. The device-level protocol already exists at `eval.zig:1284`
(`.seed = if (@hasDecl(D, "seed")) seedFn else null`) with signature
`D.seed(model, inst) -> [n_u]?f64` — `u_nodeset` is already exactly that type. **But
`eval.zig:1392-1406` `seedFn` as written is not sufficient:** its whole body is under
`if (comptime has_limit)` and it writes `self.lim_x[…]`, never `x`. A nodeset must reach `x`
through `self.gath[id * n_u + u]` and must work for devices with no limiting.

*Third defect, found while confirming:* vector-net nodesets are silently dropped.
`electrical [0:1] n = '{2.75, 0.5};` compiles clean and emits **no** `u_nodeset` table
(`--emit-zig | grep -c` → 0, vs 1 for the scalar form). And the LRM's own null-hole spelling
`'{2.75, }` does not parse: `error[E0209]` "expected an expression: found `}`".

### A06 — `noise_tables` is exported and read by nobody

Any circuit whose only noise generator is a `noise_table`/`noise_table_log` source measures an
output noise spectrum of identically `0.0 V/sqrt(Hz)` at every frequency.

The VerA half works. The generated device carries the table sorted, with the right interp tag
and back-reference (`ARPice/.zig-cache/espice-hdl/712bf75e…/device.zig:469-484`):

```zig
pub const noise_tables = [_]contract.NoiseTable{
    .{ .interp = .linear, .points = &.{ .{ 1000.0, 1e-18 }, .{ 5000.0, 9e-18 }, .{ 9000.0, 4e-18 } } },
};
pub const noise_gens = [_]contract.NoiseGen(Self){
    .{ .row = @intFromEnum(U.p), .col = @intFromEnum(U.n), .kind = .table, .source = 0, .table = 0 },
};
```

`grep -rn noise_tables ARPice/src ARPice/include` = 0 hits. **Four sites, not one:**

- `ARPice/src/problem/device_ir.zig:79-85` — `NoiseSource` is `{node_p, node_n, white, flicker, ef}`; there is no field a table could travel in, and `NoiseGenKind` has no `.table`.
- `ARPice/src/analysis/eval.zig:1703-1720` — `collectNoiseLocal` copies `D.noisePsd(...)[k]` only; never touches `D.noise_tables` despite `gen.table` naming the entry.
- `ARPice/src/analysis/ac/noise.zig:41-45` — `sourcePsd(src,f) = white + flicker/f^ef`, the site that must branch.
- `ARPice/src/analysis/pss/pnoise.zig:41` — a **second, independent copy** of the same formula. Fixing only `ac/noise.zig` leaves `.pnoise` silently zero. `tran/tran_noise.zig` is a third consumer of the same struct.

*Fix, not applied:* the evaluator already exists and is already in ARPice's import graph —
`contract.noiseTableAt` at `VerA/tools/contract.zig:730` implements both §4.6.4.3 and §4.6.4.4
including the clamp, and `ARPice/build.zig:34 → src/problem/device_ir.zig:5` imports that module.

## 4. Per-row fixture inventory

`Fx` = positive / reject. "Fails today" counts fixtures that actually go red against HEAD for
the reason claimed — the row's real pressure, which is often lower than the fixture count.

| Row | Title | Fx (pos/rej) | Fails today | Clauses covered | Verdict | Blocked on |
|---|---|---|---|---|---|---|
| **D08** | Gates, switches, UDPs | 12 (10/2) | 12 | §1.1, §7.8.5.1, §8.5.3.5, A.2.2.2, A.3.1–A.3.4, A.5.1–A.5.4 | partial | Gate/switch/UDP parsing (all `kw_reserved` today), UDP table evaluator, eight-level strength lattice + r-reduction, §8.5.3.5 relaxation solver. `.v` reject fixtures unreadable by `tests/harness.zig:787` (`.va` only). |
| **A06-noisetables** | Dead `noise_tables` export | 4 (4/0) | 4 | §4.6.4.3, §4.6.4.4, Figure 4-14, §4.6.4 | **clean** | The host feature (§3). Relocation into `ARPice/tests/fixtures/noise/` — no `build.zig` edit; the catalog walk is recursive. |
| A01 | Analog expressions, functions, conversions | 11 (8/3) | 9 | §3.2, §3.3, §3.4, §4.2.1, §4.2.1.1, §4.2.7, §4.3.2, §4.7.1–§4.7.2.4, §5.7, §9.17.1, §9.17.3, A.8.5 | partial | Nothing. All 11 reach the compiler today. |
| A02 | Branch equations and topology | 13 (12/1) | 8 | §5.4.1–§5.4.4, §5.5.1, §5.6.1.1–§5.6.1.3, §5.6.5, §5.6.6, §5.6.8.1, §5.6.8.2, A.8.9, §9.20, §5.2.1 | partial | Nothing; fixture 09 blocked only by the grammar production it tests. Fixture 90 only gradeable under `zig build torture`. |
| A03 | Analog control flow and held state | 12 (11/1) | 7 | §5.3, §5.3.2, §5.9, §5.10, §5.10.2, §5.10.3.3, §5.10.4, §4.7.1–§4.7.2.4, A.6.4, A.6.5, §6.7, §3.2 | partial | `lowerDisable` is a two-arm error stub (E0401/E0402); held-state re-keying from bare name onto (scope, name); hierarchical resolution of a named-block local (E0901). |
| A04 | Stateful analog operators | 13 (12/1) | 9 (8 of 12 `.va` + rollback) | §4.5.3–§4.5.9, §4.5.11, §4.5.12, §4.5.15, Table 4-20 | partial | Nothing structural. The documented `zig test` command for the rollback host does not compile (missing `--dep contract` on the device module). |
| A05 | Table-model lookup | 13 (11/2) | 12 | §9.21–§9.21.5, Tables 9-30/9-31/9-32, Syntax 9-16, §4.5.6 | partial | E0815 in `lib/ir/lower.zig:8660` (rejects `2`/`3`/`I`/`E`) and the eager `readTableFile` at `:8624`. |
| A06 | Small-signal and noise behavior | 13 (11/2) | 10 (6 + 4 directive-blocked) | §4.6, §4.6.1 (T4-21/4-22), §4.6.3, §4.6.4–§4.6.4.6, Table 4-20, A.8.2 | partial (thin) | `//! noise … name=/white=/flicker=/ef=/interp=/points=` — blocked at `lib/backend/tb.zig:341` `validNoiseEntry`; `//! acstim` directive absent; `//! reject` unenforced outside `zig build torture`. |
| A10 | Analog event scheduling and host queries | 15 (13/2) | 8 of 12 `.va`; 0 of 3 decks | §5.10.3.1–§5.10.3.3, §9.15 (T9-27/9-28), §9.16, §9.17.2, §4.5.14 (T4-20), §4.6.1 (T4-21) | partial | Nothing infrastructural — ARPice builds and all three decks were re-run from a fresh source build. The decks pass; that is a statement about the host, not about the decks. |
| D03 | Digital declarations, memories, ports, drivers | 13 (11/2) | 13 | A.2.1.3, A.2.2.1–A.2.2.3, A.6.1, A.4.1, §1.1, §6.5.7.1 | **clean** | Strength lexer/parser + `(strength0, strength1)` fold; net `delay3`; charge-decay timer. Fixtures 10/11 need D07 instance elaboration (E1100). |
| D04 | Procedural execution | 15 (14/1) | 15 | §1.1, §1.2, §5.10, §5.10.4, §8.5.1, §8.5.3.3, §8.5.3.4, A.2.1.3, A.2.6, A.2.7, A.6.2–A.6.5, A.8.2 | partial | Greenfield from the lexer up: `fork`/`join`/`task`/`endtask`/`wait`/`automatic` reserved-but-untagged; `@*` not lexed; intra-assignment `#`/`@` unaccepted; named blocks rejected; E1100 portless-module bail. |
| D06 | Continuous assignment and delay semantics | 12 (10/2) | 10 | §8.5.3.1, §8.5.3.3, §8.5.3.4, §8.5.2, §9.22.3, §6.2.2, A.6.1, A.6.2, A.6.5, A.2.1.3, A.2.2.2, A.2.2.3, A.2.4 | **clean** | `parser.zig` `.kw_assign` arm must learn `[drive_strength] [delay3]`; net decl must learn `[delay3]`; delayed drivers with rise/fall/turn-off + inertial supersession; `hier_delay.v` needs D07. |
| D09 | Timing constructs and digital system facilities | 14 (12/2) | 11 of 14 at the construct they pin | §9.4.1, §9.4.3 (T9-22/9-23), Table 9-1, §9.5 (T9-2), §9.6 (T9-3), §9.10 (T9-7), §9.14 (T9-11), §9.7.1 (T9-25) + inherited 1364 §17.1/§17.2.9/§17.3/§17.7/§17.11/§18.1/§18.2 | partial | Nothing to run them. Needs the `build.zig:143-163` `expectStdOutEqual` pattern, a temp-cwd VCD-diff step for 11/12, an exit-code+stderr-substring form for 90/91, and real procedural delays for 06. |
| D10 | Compiler directive semantics | 11 (10/1) | **2** | §10.1 (T10-1), §10.2, §10.5, §10.6, §6.2.2, Annex G T G.3, + 1364 §19.10, §7.9–§7.11, §3.7 | partial | Fixture 09: one string in `preprocessor.zig`'s `predefined_macros`. Fixture 11: strength model in `src/sim/digital.zig` `wired()`, multi-module `--run`, and a `--run`-path consumer for the preprocessor's `DriveRegion` list. |
| H01 | Parameters, paramsets, elaborated identity | 12 (11/1) | 8 | §2.8.1, §3.2, §3.4.1, §3.4.2, §3.4.4, §3.4.6, §3.6.3, §4.2.1.1, §4.2.9, §4.2.11, §6.3.4, §6.4, §6.4.1, §6.4.2, §6.9.2, §8.2, §9.19 | partial | Nothing. All 12 run today. |
| H04 | SPICE interoperability (Annex E) | 11 (10/1) | 10 | E.1, E.1.1, E.1.2, E.2, E.2.1, E.2.2.1–E.2.2.3, E.3 (Table E.1), E.3.3, E.4.1, E.4.2, §4.6.1–§4.6.3, §2.6.2, §6.7.1, §9.18 | partial | `build.zig:428` hardcodes `fixture_root` to `tests/fixtures` (pending is never collected); no `--spice` CLI flag, so 8 of 11 cannot be run singly; `spice_cards.zig` cannot parse the value half of a `k=v` card token; `.SUBCKT` bodies unread; §6.3.6 contribution scaling. |
| M01 | Reading and triggering across domains | 13 (11/2) | 13 | §7.2.1, §7.2.2, §7.3–§7.3.7 (Syntax 7-2/7-3), §5.10.3.1, §5.10.3.3, §5.10.3.4, §5.10.4, §5.10.5, §3.2 | partial | The two dialects must merge: `src/main.zig` sets `Parser.digital` only for `.v`; `parser.zig` gates `always` (:1265), `assign` (:966), `#` (:2324) on it. 11 of 13 need one or both. Fixture 01 also needs D06. 06/09/10 need the digital kernel joined to the analog testbench — `tb.zig:695` is a fixed-grid evaluator with no way to insert a solver timepoint. |
| M02 | Mixed-signal synchronization | 13 (13/0) | 13 | §8.4.1–§8.4.7, §8.5, §8.5.1, §8.5.3.1, §8.5.3.6, §8.5.3.7, §5.10.3.1, §5.10.3.4 | partial | `src/sim/digital.zig` (~:1023) refuses any module with ports, parameters, instances, branches, events, functions or an analog block. Parser accepts neither module-scope `always` nor `#` in `initial`. The seven-region queue exists but nothing posts `.analog` or `.explicit_d2a`. `absdelta` refused with E0513. |
| M03 | Connectmodule insertion | 13 (11/2) | 13 | §7.5, §7.6 (T7-2), §7.7.1–§7.7.4, §7.8–§7.8.6, §9.20, §3.11.1, §6.3.1, §6.7.1 | partial | (a) digital process items inside a module that also has an analog block (E0205) — dead scaffolding in 6 of them, load-bearing in 09/11; (b) the §7.8 insertion phase itself (`lib/ir/elaborate.zig:54-58` documents its absence; E0915 only checks the name); (c) §7.8.5 generated names as defparam targets (E0907). **Not** blocked on module instantiation — fixture 10 elaborates a two-instance hierarchy and solves. |
| M04 | Driver/receiver access and real nets | 14 (12/2) | 14 | §3.7 (Syntax 3-8), §6.5.2, §6.5.3, §7.9, §9.11, §9.22–§9.22.6, §9.23–§9.23.2, §1.1 | partial | `wreal` as net type and port net type (today `kw_reserved`); real variables and `%g` in the digital engine; `assign` as a connectmodule item; `#` delay in an ordinary module under `--run`; module instantiation under `--run` (E1100). 10–15 additionally need M03 insertion + an M01/M02 kernel. |
| S01 | Formatting, strings and files | 13 (13/0) | 12 | §2.6.2 (T2-1), §9.4.1, §9.4.3 (T9-23), §9.4.6, §9.5.1 (T9-24), §9.5.2, §9.5.3, §9.5.4.1, §9.5.4.2, §9.5.5, §9.5.8, §9.5.9 | partial | Nothing infrastructural. Fixture 11 needs the `$fscanf` real-destination lowering fixed (codegen type error); 12 needs `%r`/`%m` in the scan code set; 05/06 need reshaping before they specify §9.4.1 at all. |
| P02 | VPI values, scheduling, system tasks | 13 (12/1) | 13 (all at `cc`) | §11.6.16, §11.6.25, §12.6, §12.13–§12.16 (T12-4), §12.22.1/.2, §12.24–§12.28, §12.30, §12.31.1/.2/.4, §12.32/.1, §12.33.1/.2, §12.34, §12.36 | partial | `src/vpi/vpi_user.h` types/constants/17 declarations; the 17 routines in `root.zig` (11 exist, none of P02's); `tests/vpi_host.zig` must actually *run* the simulation (lint-only today) — 11 of 13 need a running scheduler; `p02_scales.v` cannot execute (E1100, one-ordinary-module) and `p02_systf.v` cannot (E1100, systf call form). |
| P03 | Analog VPI and accepted-point callbacks | 13 (11/2) | 13 (all at link) | §12.2 (T12-1), §12.6–§12.10 (T12-2, Fig 12-3), §12.13, §12.22/.1/.2, §12.30, §12.31 (Fig 12-17), §12.31.3, §12.32 (Fig 12-18), §12.32.2/.3, §12.33.2, §12.34, §11.6.6, §11.6.7, §11.6.25, §8.4.7 | partial | Everything. No `test-vpi-p03` step (`grep -c "P03\|p03" build.zig` = 0). Needs the whole P03 surface moved from `tests/pending/P03/p03_vpi_analog.h` into `src/vpi/vpi_user.h` with implementations, plus a host that can actually solve DC/transient/AC — `tests/vpi_host.zig` stops at `.lint` and `ARPice/src/analysis/eval.zig` binds no `SystfHost`. |
| A09 | Accepted/rejected state lifecycle | 9 (9/0) | **3** (measured, 6 pass) | §4.5.4 (T4-18), §4.5.7, §4.5.15, §5.2.1, §5.10.3/.1, §8.2, §8.3.2, §8.3.3, §8.4.7, §9.10, §9.17.1, §9.17.3 (§9.15 correctly dropped) | **partial** | Nothing — ARPice builds (§5.6). Then `git mv` into `tests/fixtures/` so `tests/fixture_catalog.zig` sees them. |
| A08-nodeset | Dead `u_nodeset` export | 2 (2/0) | **2** | §3.6.3.2, A.2.4, §4.2.14 | partial | Fixture 01: the one-line host change in §3. Fixture 02: parser must accept a null array element (no production in Annex A admits one, and §4.2.14's own context list excludes net declarations) **and** lowering must stop dropping vector-net initializers — two independent gaps plus an unresolved spec question. |
| X01 | LTRA, TXL, coupled transmission lines | 13 (13/0) | **4** (measured, 9 pass) | Annex E.1.1, E.3 (Table E.1) — and the load-bearing **negative** claim: `LTRA`, `TXL`, `CPL`, "coupled transmission" appear in **zero** `docs/*.html` | **partial** | Not discoverable — `tests/fixture_catalog.zig:6` opens `tests/fixtures` only. Upstream: the LTRA/TXL AC stamp does not exist at all; both native history buffers are fixed-size (`ltra_native.zig:61` CAP=8192, `txl_native.zig:42` CAP=2048) with no growable storage. |

**Thin rows, stated plainly.** `D10` ships 2 failing fixtures of 11, and one of those two is
satisfied by appending a string to an array. `A09` ships 3 failing of 9 (measured), and all three are the
same root cause seen three ways. `X01` ships 4 of 13 after repair (was 3), two of which are the
same AC defect. `A08-nodeset` ships 2 of 2, one of which cannot even parse. `A10` ships 8 of 15 and
none of its three host decks fail. `A02` and `A03` each keep 5 fixtures that already pass. `A06`
reaches 10 of 13 only by counting 4 fixtures that go red at the testbench directive parser rather
than at any compiler behaviour, and `D09` counts 3 that go red at the `$display` format string
before reaching the construct they pin. These are regression pins, not coverage; every one of them
is disclosed in its own SPEC.md, which is to the authors' credit, but the headline counts overstate
what is being delivered.

## 5. Defect register — twenty-three rows repaired, three untouched, all twenty-six re-verified

**Correction to an earlier revision of this section.** The previous text was headed "five rows
repaired, nineteen untouched" and told the reader that "every defect charged to them stands below
verbatim, unmodified and un-rechecked". **That was false and it understated the repair by a factor
of four.** All twenty-three rows that carried a charge were repaired on disk. The previous
revision was written from a workflow that lost twenty-one of its twenty-three verdicts to a
harness failure and recorded the missing verdicts as "not touched" rather than as "not measured".
A reviewer reading it today would believe nineteen rows still carry every original defect; they do
not. Every one of the twenty-three has now been re-verified by opening the files, re-running the
fixtures, mutating them to measure teeth, and re-opening every citation — including the ones the
first review passed. Three rows (`A06-noisetables`, `D04`, `P03`) were never charged with a
repairable defect and genuinely were not touched: their file mtimes are 13:27, 13:51 and 15:57
against a repair window of 17:14–17:54. Where this section now disagrees with the files, trust the
files.

**Verdicts: 3 clean, 23 partial, 0 unsound, 0 needs-work.** Clean: `A06-noisetables`, `D03`, `D06`.
Everything else is partial, including `D08`, `A06`, `M01` and `M02`, which the previous revision
called sound. "Partial" here has a specific and consistent meaning: **every defect charged to the
row is genuinely fixed in the fixture files, not confessed in prose — and the repair then left,
or introduced, defects in the supporting evidence.** No row regressed. No fixture was weakened
into a non-claim. But twenty-one rows now carry at least one wrong number, invented quotation or
false completeness claim in the document that exists to justify their expected values, and seven
of those were written by the repair pass itself.

**§5.1 is the section that matters, not the ledger.** A tolerance widened until nothing fails
reads as green and is more dangerous than the defect it replaced; a fabricated measurement used to
justify *not* shipping a fixture removes coverage silently. Both occurred.

### 5.0 Repair ledger

The parenthesised numbers in "Charged originally" are the class numbers as the *previous* revision
had them: (5.1) Class A, (5.2) Class B citations, (5.3) Class C values, (5.4) Class D teeth,
(5.5) scope, (5.6) reproduction. In this revision those are §5.2, §5.3, §5.4, §5.5, §5.6 and §5.7,
because §5.1 is now repair damage.

| Row | Charged originally | Fixed | Still open | Damage introduced by the repair |
|---|---|---|---|---|
| **A06-noisetables** *(clean)* | none — sound in pass 1; citations listed as "not re-checked since" | n/a, never touched. Re-verified anyway: every §4.6.4.3/§4.6.4.4 quote and Figure 4-14's caption verbatim; all 16 oracle values re-derived to ≤4.8e-16; all four `netlist_sha256` match; every ARPice `file:line` exact; the transfer-impedance control re-measured at 9.9999999999999995e-07 | hand-assembled transcript presented as captured (SPEC.md:47-57 — only its middle line is real output); the `device.zig:469` block is reformatted, not verbatim; `a06_noiseless_res.va:3-7` attributes a §4.6.4.3 sentence to §4.6.4 | none — not repaired |
| **D03** *(clean)* | 4 — fixture 10 pins a rule §6.5.7.1 forbids (5.1); its `zz01` is wrong for its own stimulus (5.3); one already-passing fixture (5.4); citations unrechecked (5.2) | 4, by deletion and replacement rather than annotation. `10_port_width_conversion.v` is gone; `10_port_concat_matching_width.v` quotes §6.5.7.1 verbatim and asserts the positively-testable half. `zz01` survives nowhere. Fixture 09 is now red, with teeth measured against a hand-built `trireg`→`wire` implementation (3 of 6 lines differ in 3 columns each). Both rejects carry real substrings the runner really matches | fixture 13 is over-pinned: `wire (small) w;` is ungrammatical for two independent reasons and the required substring pins only one, so a conforming tool that diagnoses the other is failed for a correct refusal (one-char fix: `w = a;`). Fixtures 10 and 11 go red for prerequisite reasons, not for the clause they pin (disclosed) | none of the four modes. One cosmetic slip: SPEC.md:112 says `held` is sampled 1000 ns after release; it is 1001 |
| **D06** *(clean)* | 2 — both reject fixtures carry a bare `//! reject` (5.1); `assign_drive_strength.v`'s stated discriminator is wrong (5.4) | 2. `//! reject E0210` and `//! reject E0209`, with `torture.zig:211-216` read to confirm a code pattern short-circuits before the substring fallback. The false t=11 claim is retracted **in the file** and a new t=21 stimulus added; teeth re-derived and measured (Pu0=5 beats We1=3 → `y=0`, unreproducible by strength-blind, last-driver-wins or wired-or) | none | one presentational: SPEC.md:188-202's block is labelled "Captured, not typed" and headed with a shell loop, but is a hand-formatted one-line-per-file summary. Every fact in it reproduces exactly; the adjacent blocks at :206-232 are byte-exact |
| **A01** | 3 — §4.2.5 miscite and a §3.4 paraphrase inside quote marks (5.2); 2 of 11 already-passing (5.4); hand-edited "Observed today" (5.6) | 3. Every live `//! lrm` and every prose reference reads §4.2.1; §4.2.5 survives only inside labelled correction blocks. §3.4's passage is now verbatim and byte-compared. The transcript was re-measured and reproduces line for line, including the two lines the review caught. Fixture 92's reject tightened `index` → `E0310`. No tolerance widened — the row has exactly one (1e-16) and it is provably sub-ulp | 2 of 11 still pass (06, 07) — disputed, with a measured argument (§5.8). Fixtures 90 and 91 still carry substring rejects while 92 was hardened to a code, inconsistent with the repair's own stated standard two files over | `want=0.523599` corrected in SPEC.md and left in the fixture it came from (`08_…va:29`); a correction note that contradicts itself about fixture 05 and inflates the miscite from four places to six; `lower.zig:800` paired with text at `:804` (repeated in 07:59, 90:27, 92:16); `converger.zig:294` now `:303`; `tb.zig:228` is `:226` |
| **A02** | 3 — ULP-floor tolerances in fixture 08 (5.3); disclosure-is-not-a-fix, 5 of 13 pass (5.4); citations unrechecked (5.2) | 2 of 3. Fixture 08's bands 1e-15/1e-18 → 1e-12, probed by mutation: both wrong topologies red 3 of 3 assertions with 5e8 tolerance widths of margin. Fixture 11's re-derived discriminator table measured exactly right at both sweep points. All 16 declared clauses re-opened, zero fabrications; two quotation-hygiene repairs are real. Fixture 12 gained six genuinely new crossed-spelling checks | 5.4 narrowed, not closed: 5 of 13 still pass, and only fixture 12 gained teeth — 03, 05 and 11 carry byte-identical assertions plus new prose. Fixture 90 cannot go red outside `zig build torture` | two undeclared clauses (§4.2.5 at 11:77, §4.5.3 at 04:49/06:48) against a SPEC that claims a complete citation audit; two charge-tape figures presented as observed that `//! print none` prevents the published recipe from printing, and that hold at 1 of 4 timepoints; a wholly wrong solver identifier in fixture 01's "OBSERVED TODAY" block that SPEC.md gets right; a new contradiction between SPEC.md's two tables for fixture 03; an unmarked elision in a §5.2.1 quotation |
| **A03** | 5 — fixture 08 pins a solver iteration count (5.1); §3.2.2 does not exist and §4.2.1.1 is the wrong direction (5.2); fixture 10's `m == 0` and fixtures 08/09's near-vacuous assertions (5.4) | 5, all in the files. `snap` is idempotent over every value the module reaches, so a second spine evaluation changes nothing, and the tolerance stayed `0.0`. §3.2 and §4.2.1.2 corrected in fixture, directive and SPEC. Fixture 10's toothless check is **deleted**, not disclosed. Fixture 09's body rewritten to read the output formal. Four mutation builds confirm every counterfactual the headers predict | uncharged and material: the row's entire `disable` side has no clause in the shipped LRM — 1364 §9.6.2 is not in `docs/` and is never cited, and it carries 4 of the row's 7 failing fixtures. Fixture 08's `w4` is a real claim at 1 of 5 timepoints (disclosed, tabulated) | SPEC.md:148-153's second line is presented as "Measured" and does not reproduce: `@(timer(1n, 2n))` is said to fire at 1n and 3.5n; measured 1n, 4n, 5n. Two dead repo paths (`tests/fixtures/ch05/…`, which is `ch05_analog_behavior/`) in a document that spells the directory correctly 170 lines later |
| **A04** | 6 — fabricated sample-and-hold quote and the Figure 4-4 claim (5.2); fixture 10's contestable instant, fixture 02's non-discriminating comment, fixture 05's off-by-one (5.3); fixture 09 as an active trap (5.4); the `zig test` command and the `@hasDecl` short-circuit (5.6) | 6. The unity-transfer-function precondition is restored byte-identical; Figure 4-4's claim withdrawn in the file. `tau = 0` passed explicitly, with the clause's own tau=0 restriction respected. Fixture 02 gained a new discriminator, measured to reject the naive reading by 0.5. Fixture 05 derives 3 and 512, confirmed from the transcript. The `||` trap is re-homed as a new fixture 12 under §4.5.15, failing 3 of 12; site B's values recovered by tolerance bisection. The rollback `zig test` runs; the `@hasDecl` guard moved into a shim so both test bodies compile. No tolerance widened | fixture 09 still passes 12/12 and is relabelled a regression floor — narrowed, not closed. Fixture 10's tau=0 repair extends a precondition stated for a unity filter to a non-unity filter without saying it is an extension. Fixtures 03, 04 and 07 die at E0515 before reaching what they are named for (structural, disclosed) | SPEC.md:39 says "five of the twelve pass today" — measured four, contradicted by its own following bullet list and its own transcript. §4.5.15 mischaracterised in three places as naming "`if`, `case` and `?:` and nothing else"; the clause carries five restriction sentences and the fixture's own quote block hides four of them behind a `…`. "0.25 is the midpoint of 1.0 and 1.5" (it is the half-gap). Fixture 11's tau=9 discrimination figure is neither the worst nor the closest case |
| **A05** | 5 — `ddx` cited to §4.5.14 (5.2); fixture 04's disputed wants, fixture 13's deferral requirement, the 06/07 column-rule contradiction (5.3); fixture 08 has no teeth and fixture 07 passes (5.4); the `//! bias`/`//! sweep` claim (5.6) | 4 of 5, with two counterfactuals that reproduce byte-exact when re-run independently. `//! lrm 4.5.6`, verified. All five of fixture 04's disputed digits are gone, both readings written out, and the `1CL`/`DCL` counterfactuals print exactly the strings SPEC.md publishes. Fixture 13's timing requirement is gone and its conflicting dependent is no longer constant-foldable. Fixture 08's second never-executed site fails in the guard-free build. The reproduction claim is corrected and the source line numbers the row inherited from this manifest were re-checked and re-published correctly | fixture 07 still passes 5/5 and was fixed by disclosure only — the file's own header says "Nothing in this file's wants changed". The 06/07 reconciliation rests on a Syntax 9-16 reading the grammar does not support (§5.8). Fixture 08's new content is still a negative claim. One conformant escape remains open on 13 | a new miscitation in repair-authored text: §9.21.2 body prose attributed to Table 9-31, twice (systemic in three untouched files too, but 04's instance is new and SPEC.md launders it); "BOTH MEASURED" for a cubic value that cannot be measured at HEAD (`3` is refused by E0815); a blanket "Every quotation in every header in this directory matches the HTML" that is wrong in at least five places, including a silent `2^N`-for-`2N` emendation inside quote marks; a repair-authored `CHECKEQ` with zero teeth sold as a discriminator — it passes under both counterfactuals the file says it separates |
| **A06** | 5 — `$vt` Class A (5.1); `//! lrm 4.5.10`→§4.5.6 and §9.10→§9.15 (5.2); the false ratio self-check (5.3); four fixtures that cannot fail (5.4) | 4 of 5. Both miscites gone from every live directive. All six ratios re-derived to the last digit and the false `CHECKR` on the doubling is replaced by an explicit "do NOT correct this" note. Class D closed on the four named files with §4.5.6 claims against non-zero wants, bands **tightened** to 1e-18 absolute against a 1e-3 want. `$vt` is now an identity, `` CHECKEQ($vt, $temperature * (`P_K / `P_Q), 1e-7) `` | Class A narrowed, not closed, and measured: a conforming tool on Annex D.2's `P_K_SPICE`/`P_Q_SPICE` or `PHYSICAL_CONSTANTS_OLD` still fails `a06_small_signal_linearization.va` **and** `a06_psd_bias_dependent.va`. 2 of 5 defensible constant sets fail, down from 4 of 5. Class D narrowed **selectively**: the byte-identical pinned-probe line survives in two files the repair never opened, as does a literal-against-itself `CHECKR` and a parameter-vs-parameter check | a fabricated citation **against source**, in three places: `failureContains` is said to match the pattern against `f.generated` "before it reaches any diagnostic". Measured: `f.generated` is non-null only in the `GeneratedCompileError` branch, neither fixture emits `@compileError`, so `failureContains` is never called and both rejects were already red. "Four decades above the 2.4e-5 spread" is 4.1×. A temperature-invariance claim attached to a check that is temperature-invariant by construction. `` `M_PI `` cited to Annex D.1 (it is D.2, as the row says correctly twelve other times). Table 4-20 misread as listing only operators with constant-expression arguments |
| **A08-nodeset** | 4 — "IEEE 1800.2" and the A.8.3 authority (5.2); fixture 03 asserts the feature-absent value and fixture 01's second assertion is implied by its first (5.4); `.zig-cache` spill (5.5) | 4. The 1800.2 misattribution is gone from both fixtures and independently confirmed against the 2.4 PDF by inflating its content streams. The A.8.3 authority is withdrawn **in the fixture**, with `diag_code.zig:1198` named as the real source of that string. Fixture 03 is deleted and its claim re-homed to a shipped green fixture that genuinely carries it. Fixture 01 is down to one `CHECK`. Spill gone; the directory is 36 KB. No tolerance widened — the only tolerance-bearing edit was a deletion | fixture 02's second assertion is green at HEAD and pins the harness's cold start (`@splat(0.0)`), not an LRM consequence — and unlike fixture 01 it got no conformance caveat. `01_…va:64-66` justifies its band by a "denormal off zero" the run does not show | a fabricated Annex A derivation, shipped **in the fixture body** as the audited correction for a fabricated citation: `net_decl_assignment` → `expression` → `constant_assignment_pattern` is not a path that exists in either half of the annex. SPEC.md's repair ledger says "A.8.3 … contains no array-element production at all" while its own body correctly locates `constant_expression_or_null` inside A.8.3. §4.2.14 — the clause with the enumerated list of contexts where an assignment pattern is allowed, which excludes net declarations — is cited nowhere |
| **A10** | 3 — §3.3.1 (self-found, does not exist) (5.2); fixtures 01 and 05 already passing (5.4); reproduction against a stale binary (5.6) | 3. §3.3.1 → §3.3/Table 3-3, with the dead subclause named as dead. Fixture 01 gained `@(timer(-1n, 0))` and moved pass→fail, demanding strictly **fewer** events than HEAD raises. Fixture 05's enable is now asserted in argument position 5 and was probed by flipping only that argument. Reproduction is better than claimed: ARPice was rebuilt ReleaseFast from source and every published deck figure reproduces, all three `netlist_sha256` match. No tolerance widened — every check is `CHECKX`/`CHECKI`/`CHECKEQ(…, 0.0)` | 7 of 15 still pass, including all three host decks; the `bound_step` deck is half-toothed (see damage). Two miscitations survive in untouched files: 04's "the LRM's own sample-and-hold spells exactly that" drops `exclude 0`, and 12's "the same sentence appears **verbatim**" is false of all three wordings and is contradicted by its own next clause. The host-number provenance block (path, sha256, mtime) identifies nothing on disk and the "ARPice does not build from source today" section is now false end to end | **a fabricated measurement, and it is load-bearing.** SPEC.md asserts twice, as a probe run 2026-09-19, that two `$bound_step` calls in one analog block are refused with `error[E0201]`. Measured: they compile, codegen and run; `lower.zig:6726-6748` implements the running minimum with §9.17.2 quoted in comment, `codegen.zig:7156` emits the `@min`, and `lower.zig:10502` is a unit test on exactly that source shape. The fabrication is the stated reason the row ships **no fixture** for §9.17.2's "smallest currently active" rule. Also: the cross-deck switch coordinate written `5.0000005117e-4` against a measured `5.0000051171875e-4`, self-contradicting the "0.51 ns" in the same sentence; the two decks' `dt` ceilings swapped (2e-5 for 2e-4); a 3 % band published against an enforced 5 % (`atol 0.02 + rtol 0.03`); a two-point discrimination claim that holds at one point |
| **D04** | 1 — citations listed as "verified clean in the first pass, not re-checked since" (5.2) | n/a, never touched (13:51). Re-verified: all 15 transcripts re-derived by hand including fixture 12's 4-bit-return / 8-bit-caller width case; every A-annex and ch1/ch5/ch8 quotation verbatim; 8 of 9 source anchors exact; all 15 fixtures red for the advertised reason | §5.10 is quoted as five bullets in both SPEC.md:86 and `04_…v:165-171`; the clause has **six** (the dropped one is "there can be both digital and analog events") and "in different parts of the model" is the LRM's "in different parts of the behavioral model". `function_port_list` and `task_port_item` are shown as grammar with every `{ attribute_instance }` silently removed. Ten `.v` files carry `//! timescale 1ns/1ps`, a directive spelling `tb.zig` rejects with `UnknownDirective` — inert here, but an invented mechanism written to look like a checked one. `digital.zig:1024` is `:1023` | none — not repaired. The row has no numeric tolerance anywhere, so the widening mode is structurally impossible in it |
| **D08** | 1 — both reject fixtures stay weak after the feature lands (5.4) | 1, and measured rather than described: `//! reject output symbol` and `//! reject combinational` + `//! reject edge`. Every field `failureContains` reads was inspected against today's only diagnostic (E0201, with an empty caret label and an `LRM annex C` note); none contains any of the three patterns, so both go red. Strictly tightening | SPEC.md:114-115 contradicts SPEC.md:16 about what happens today (`tran` is a hard E1100 under `--run`, not a W0250 warning, and the file dies earlier still at E0205). SPEC.md:17 says `primitive` is not in `reserved_keywords`; it is, at `token.zig:758`, and the same document lists it there two lines earlier. A.3.1 defines eight instance productions, not seven. §7.8.5.1 is called the clause that "normatively fixes the left-to-right terminal order" when it disclaims exactly that. Two in-quote alterations. Structurally: `harness.zig:787` collects `.va` only, so nothing in the repo reads these two `.v` directives today | SPEC.md:250 asserts that "§5.5 records no scope violation" when the §5.5 then in force was headed "This gate now fails" — the sentence stated the opposite of the section it cited. This revision's §5.6 makes it accidentally true; repoint it rather than leave it. And the new teeth claim is stronger than `torture.zig` enforces: multiple `//! reject` lines are a conjunction over the whole diagnostic bag, not a demand that one refusal name both halves of A.5.3's split |
| **D09** | 3 — six miscited inherited clauses (5.2); two refusals passing vacuously (5.4); the VCD normaliser (5.6) | 3. All six corrections landed in the fixture bodies, in the `//! inherited` directives **and** in SPEC.md's clause table, with every `CLAUSE-AUDIT.md` anchor re-opened. Both refusals now carry substrings today's diagnostics do not contain, measured. The normaliser was rebuilt against the hand VCD it describes and `diff` is silent; its discrimination was measured three ways (`b0`→`b0000`, `1ns`→`1ps`, `1 0 n s`) and all three still fail | SPEC.md's ground-truth bullet says `specify`/`specparam`/`$setup` "appear **nowhere** in `src/`" and its very next sentence depends on them being there (`token.zig:776/790/821`, `diag_code.zig:1534`, `parser.zig:75/846`). "All fourteen fail at the intended construct, none at parse time" is wrong for three: 05 and 10 die on the `$display` format string and never reach `$time`/`$clog2`. Tables 9-1/9-2/9-3/9-7/9-11 are filed under §9.4.1/§9.5/§9.6/§9.10/§9.14; all five live in §9.2 (a repo-wide convention, also in `lower.zig`, but the same class of error §5.3 charges elsewhere) | a new wrong number in repair-added text: "39 fixtures under `tests/fixtures` pin a code" — measured **363**. 39 is the `E0512` count, copied out of this manifest's D06 entry and silently relabelled. A new misattribution in the repair's own "what is verifiable from the corpus" paragraph: "§9.5 Table 9-2" (Table 9-2 is §9.2). And a loosening sold as a strengthening: the VCD `$timescale` body now has its whitespace **removed** rather than collapsed, which is strictly more permissive, and the repair calls it "slightly **stronger**" |
| **D10** | 4 — §10.5 misapplied to `` `ifdef `` arm selection (5.2); fixture 04's `−5e-4` sign, "fixture 58's answer" and fixture 08's "read 5 instead of 2" (5.3); fixtures 04/07 assert the feature-absent value and fixture 10 cannot fail for its own clause (5.4) | 4, and the repair is **better than the charge**: it correctly rebutted this manifest's own proposed replacement. §10.4 is `` `define ``/`` `undef `` and settles nothing about conditional compilation; the governing rule is IEEE 1364's, which is not in `docs/`, so the fixture names it by deferral and invents no subclause. 04 and 07 were rewritten to a two-child/two-wrapper shape with teeth measured in both directions; 10's unconditional check is now `§10.5: extensions supported, so the macro shall be defined` and reads `got=0 want=1 ok=0`; 08's fiction is retracted in the file. No tolerance exists in the row to widen — all 27 assertions are `CHECKX`/`CHECKI` | fixture 11 contradicts itself about which IEEE 1364 clause holds the resolution table (§7.9 at :28 versus §7.10/§7.11 at :32-33 and :56-57) and SPEC.md repeats both. Fixture 11 rests on four normative claims none of which can be opened against anything in `docs/`, in a row whose SPEC declines to guess in three other places. Fixture 08's "the second and third assertions die at E0115 rather than printing a number" overstates: nothing prints, the file does not compile | two wrong source cites in the SPEC's own "read from the source, not from the docs" table: `` `default_nettype `` at `preprocessor.zig:335` (it is `:339`) and `` `timescale `` at the same `:335` (it is `:333`); `:335` is a comment. A quotation presented as lifted — `` `pragma f harmless `` — where the file reads `` `pragma fixture harmless `` |
| **H01** | 3 — fixtures 02 and 06 pin interpretations presented as derivations (5.3); 4 of 12 already passing (5.4); citations listed as clean (5.2) | 2 of 3, in the live fixture text. Fixture 02's `.k` statement is gone, and with it the disputed near-link target and the 7.0 / 3.5 A pair; the near link is now the minimal legal body Syntax 6-4 requires. Fixture 06 no longer asserts `$param_given(k) == 1`; it asserts `$param_given(untouched) == 0` plus a `tdevice` override probe, both verified against §9.19's own worked example | 5.4 narrowed, not closed: 4 of 12 still pass, and one of them cannot detect the failure it is kept for (below). Fixture 05 carries an **invented** §6.9.2 quotation — "the paramset for each instance is selected after generate statements have been evaluated" — which occurs nowhere in `docs/`, and §6.9.2 does not reach the fixture in any case (no generate construct, non-overloaded paramset). SPEC.md's §3.4.4 gloss turns "from the same module" into "from the same override list". Fixture 04 carries one assertion algebraically implied by the one above it | a new false discrimination argument, measured false: SPEC.md's new "what each already-passing fixture would catch" says fixture 05's ratio reads 6/18 = 0.333 under a frozen elaboration. Both operands arrive through the same paramset from the same swept `k`, so a frozen elaboration reads 1.0 and the fixture passes 2/2 — confirmed by collapsing the sweep to a single point. The stated backstop is inert for the same reason. Fixture 06's header still says "green, all five" against six checks. Fixture 02 is now down to one independent claim (its second check is entailed by its first under `//! bias`), undisclosed. The new §9.19 probe largely re-states shipped green coverage (`ch09_system_tasks/165`), against the row's own stated rule for rejecting a third fixture on a covered clause. The repair's ledger paragraph cites §5.2 and §5.5 for the four-already-passing charge, which is §5.4 |
| **H04** | 6 — three wrong subclauses and fixture 11's invented normative claim (5.2); fixture 10 has no teeth (5.4); `.zig-cache` spill (5.5) | 6. `//! lrm 9.15`, `4.5.4`, `6.3.3`, each with the error named in-file; `defparam` appears nowhere in the row. Fixture 11 is **withdrawn**, not relocated: the `.MODEL` demand is gone, replaced by an override of a name that is genuinely not a parameter of the module, refused at `E0907` and pinned with `//! reject E0907`. Fixture 10 gained a second netlist and an in-row control whose 2.5e-4 was re-derived on a stand-in. Spill gone; torture re-run 1323/1323 | fixture 11's premise overstates E.3 — "required names" is not "exhaustive", and the reject is carried by §6.3.3's `shall` against VerA's own prelude, not by E.3. E.4.2 is used permissively in fixture 11 and normatively in fixture 05 without reconciliation. Fixture 11 is green by design (disclosed) | the parallel-pair experiment is misreported identically in the fixture and in SPEC.md: "the same experiment reads 7.692e-4 against 1.0e-3" welds two different runs together — the split of that pair measures 7.692e-4 against **5.0e-4**. Fixture 03's headline teeth claim holds only under the absolute-`T` reading; under the rise-above-`tnom` reading the same header calls equally defensible, both sides read 1.0e-3 and the `CHECKEQ` has zero teeth. An arithmetic error in fixture 04's "the digits, by hand" block (`2.5 − 0.9995` matches neither measured timepoint). A present-tense "Measured:" in fixture 10 describing the file as it was **before** the repair made it fail to compile. A new miscite: §9.18's `#(.$mfactor(2))` example attributed to §6.3.6 |
| **M01** | 8 — `delta = 0.5` and the M02-dependent 1e-12 bound (5.1); the §4.7.2 miscite and fixture 06's unearned `//! lrm 7.3.5` (5.2); fixture 09's 11.25n and fixture 06's false midpoint rationale (5.3); fixture 01 vacuous (5.4); the false "every diagnostic was reproduced" claim (5.6) | 7 of 8. `delta = 0.3` with the old bug named outright. The 0.6 band was mutation-tested: the feature-absent variant reds 3 of 5 points, exactly as the header claims and no more. §4.7.2 and the unearned §7.3.5 withdrawn (7.3.5 survives legitimately in fixture 09). 13.75n re-derived and correct. Fixture 06's rationale replaced with two verbatim §5.10.3.3 sentences. Fixture 01 leads with `CHECKI(code, 10)` against a verbatim Table 7-1 bit row, and the reg-half claim it rests on was re-measured green | 5.6 is repaired in substance and still wrong in the letter: `05_…va:52` pastes line 86 for a statement at 87 and `08_…va:51` pastes 77 for 78, in two blocks presented as verbatim. Fixture 10's "TWO CLAIMS, BOTH LATITUDE-FREE" is not true of claim 2 — the call specifies no `time_tol`, and §5.10.3.4 both excludes events within `time_tol` of the previous one and says the tool sets the tolerances when they are not given | a new miscite, and it is the exact inversion the repair withdrew from fixture 06: `//! lrm 7.3.4` on fixture 10, whose `always @(absdelta(…))` is a continuous event in a discrete context (§7.3.5). It is a bare directive with no supporting prose — the "shows as covered without anything covering it" shape §5.3 charged against 06. Two slack constants (0.2 V and 0.1) presented as "the clause's own scheduling window" and derived nowhere. Fixture 06's band went 0.0 → 1.0, LRM-justified with teeth surviving at two of four points, and was **omitted from the previous revision's damage ledger** |
| **M02** | 5 — seven digital-context `integer`s seeded against §3.2 and fixture 07 contradicting 1364 §9.2.2 (5.1); fixture 06's tolerance of exactly 0.0 and fixture 13's unforced fifth `absdelta` event (5.3); fixture 07 passing with zero D2A support (5.4) | 5. All thirteen carry `initial` seeds. Fixture 07 is rewritten against §9.2.2's actual rule and gained a `negedge` counter that a no-D2A and an NBA-coalescing tool both fail. Fixture 06's 1e-18 band was re-derived exactly — 1 ULP is 8.271806125530277e-25 s, the band is 1.2e6 ULP, and the error it rejects is 2e8 band-widths. Fixture 13's grid was rewritten so the fifth event sits 2 ns inside the run and the four records have four different lengths | fixture 12 depends on an undisclosed reading of §9.22.4 that fixture 10's own header contradicts: the connectmodule's `assign d = out;` is a driver of `d`, and §9.22 ¶3's exclusion is written for the driver *access functions*, not for the `driver_update` operator. Under the literal reading every `updates=` column shifts by one and all four `ok=` read 0 — a defensibly conforming tool fails the row's headline fixture (§5.8) | a new fabricated quotation in a repair-touched file: `04_…va:62-63` puts `"…default to the unknown value x"` in quote marks; §3.2 reads "default to an initial value of x". It is the only one of the seven seed comments written as a quotation. "It carries 12 Zig unit tests" in the Ground-truth section — measured 13. The new 4u band is justified against "the 0.05 V gap to the nearest wrong arm", which is 0.25 V; 0.05 V is the non-interpolating tool's error, counted twice under two labels. The previous revision's §5.7 says fixture 07 went "from one non-vacuous check to three"; honest count is one to two |
| **M03** | 5 — the fabricated §7.8.5.1 worked example and §7.6's Examples 1/2 swapped in four files (5.2); fixtures 10, 11 and 03 weak (5.4) | 5, and three of them by changing the design rather than the prose. The `a__gate_instance__in1` example is withdrawn and replaced by §7.8.5.1's real opening sentences. The §7.6 swap is corrected in all four charged files **plus a fifth the review missed**. Fixture 10's supply is now resistive and its pull-up is a branch through the aliased node, so 3.0 became the feature-absent reading (measured `got=3 want=2.857142857142857 ok=0`). Fixture 11's want moved 0.0 → 0.25. Fixture 03's `initial q` moved to `1'b1` and its want 0.4 → 0.8, making 0.4 a failing value. No tolerance moved — all 15 checks are 1e-12 — and every post-insertion topology was re-solved, reproducing SPEC.md's arithmetic block including two 1-ULP digits | SPEC.md lists §7.7.4 as covered; no fixture carries it. Both reject fixtures still have no allocated diagnostic code and pin rule prose rather than tool output — disclosed, and the row's genuine gap | SPEC.md:34 says "measured: 9 of the 11 positive fixtures … print a failing `ok=0` on their own assertion" — measured **six**, and its own transcript 250 lines later lists exactly those six. Repair item 7 says "all eight elaborate and fail on their own numbers" over a parenthetical listing nine files, of which five do. SPEC.md restates §7.6's Example 1/2 rule as a function of port direction alone; the rule is keyed on (direction, upper-connection discipline), and the restated version contradicts the row's own fixture 09, which the same paragraph calls "already right". The repair's own changes made two more fixtures depend on a digital kernel (03's `initial`, 10's `always @(cm)`) while SPEC.md still says that dependency is "load-bearing for exactly two fixtures". "An adversarial review of this row found six defects" over five items; the register charges five |
| **M04** | 2 — 16 of the row's transcript lines carry minimum-width `%b` (5.3); fixture 14's entire transcript is the feature-absent transcript (5.4) | 2. All 16 lines now hold the 32-digit zero-padded spelling, with the derivation written out in four headers and the green regression at `digital.zig:1163` named; a minimum-width implementation fails all 16. Fixture 14 gained `$driver_count(d) == 1` inside the connectmodule and a fourth expected line, so a tool that inserts nothing prints three lines where four are expected. No tolerance exists in the row — every assertion is an exact transcript or an `==` | fixture 12's expected counts depend on the same undisclosed §9.22.4 reading M02 carries (§5.8). Fixture 14's three bypass lines still have no independent teeth; the repaired claim now rests entirely on line 1 being *absent* from a non-inserting tool's stdout, which discriminates only under a whole-transcript compare that no build step performs yet. Fixtures 20/21 remain inert until `wreal` parses, and `torture.zig`'s catalog never reaches `tests/pending` | `$driver_type` is placed in "Table 9-19" and said to have "no subclause in the offline document"; it is Table 9-20 and §9.23.4, which supplies exactly the normative text the SPEC says does not exist — so the stated reason for shipping no fixture is unfounded. "39 fixtures pin a code, 48 pin the weaker `DiagnosticsReported`" in repair-added text: measured 381 files and 54. "16 of the row's 32 asserted transcript lines" — the numerator is right, the denominator is 54. Both fixture headers describe `failureContains` as matching message, point and title, omitting that it also matches every note |
| **P02** | 3 — fixture 05's self-polluted time queue (5.1); "LRM 2.5 scale factors" and "the three action reasons that shall occur in all VPI-compliant products" (5.2) | 3, and the Class A repair is a net strengthening rather than a relabel. The `t=30` registration is gone; the census moved to `cbEndOfSimulation`, which schedules no time queue. A callback-only time is now *declared* (`cbAtStartOfSimTime` at 33) and asserted, and the walk's expected set grew to `{5,6,7,33,40}` with a `t.high == 0` check and t=999-absence teeth. §2.6.2/Table 2-1 corrected at all four sites and the `1k`/`2k` values re-measured. §12.31.4's six action reasons are quoted whole, with the three the row does not cover moved into "Deliberately NOT covered" as named gaps | the Class A hazard is inverted rather than removed: fixture 05 now fails a tool that does *not* expose callback wake-ups in `vpiTimeQueue`. This is the reading the register itself asserted, and SPEC.md:382-392 flags it as the one assertion an implementer may contest — recorded so it is not rediscovered as drift | SPEC.md:592-596 says "Every clause this row cites was opened. **All 28**" over a parenthesised list of 29 entries, in the one paragraph whose whole value is that it was counted; §12.31 is cited in the coverage table and absent from the list. SPEC.md:597-602 says "**Two** deliberate departures from verbatim survive"; there are three — `11_systf_analog.c:21-23` deletes "(see also: `vpi_register_analog_systf()`)" from inside a §12.22.1 quotation with no ellipsis, three sentences before the same file elides correctly |
| **P03** | 1 — citations listed as "verified clean in the first pass, not re-checked since" (5.2) | n/a, never touched (15:57). Re-verified: all 29 clauses resolve to the right headings, every long quote from §12.7–§12.10, §12.31.3, §12.32/.1/.2/.3 and §8.4.7 verbatim, all 13 `.expected.txt` values re-derived, all five designs lint clean, all 13 fixtures compile with `-Wall -Wextra` and fail at link | `p03_vpi_analog.h:40-42` attributes to "§12.2 **and** §12.31" the deferral to "the `vpi_user.h` file listing in Annex G": only §12.31 says it; §12.2 defines its constants in situ with Table 12-1 and never mentions Annex G. The header announces "TWO INCONSISTENCIES IN THE LRM'S OWN TEXT" and lists three. SPEC.md:3-4 says every fixture "fails at the C compiler" and SPEC.md:181-182 says the opposite and is right — they compile, they do not link. Two census figures presented as captured do not reproduce (the `src/` prose-hit file list, and the `ch12_vpi_routines` 2/36 split, which is 3/35). "Ten positive fixtures, two rejections" against its own table of 11 + 2 | none — not repaired |
| **S01** | 4 — fixture 01's explicit-precision `%g` rows against the LRM's own worked example (5.3); fixtures 05 and 06 specify a synchronous `$fmonitor` (5.3); 2 of 13 already passing (5.4) | 3 of 4. The two explicit-precision rows are **removed** from fixture 01 and re-homed nowhere, with SPEC.md's replacement measurements (`E[1234.568] F[0.01]`) re-run and confirmed. Fixtures 05 and 06 now open the descriptor once under `@(initial_step)` and read `$ftell` at the top of the *next* step, so §9.4.1's end-of-step rule no longer defeats them; 06's wave was changed so its four records have four different lengths and it went from green to 4/4 red | fixture 01's surviving rows 1 and 4 still assert C's significant-digits reading behind a circular rationale — the header's "derived both ways and the two derivations agree" cross-check generates both candidates with C's precision, and under a uniform fractional-digits reading row 1's counterfactual is exactly what VerA prints today. §9.4.1 change detection is now pinned by **nothing**: both 05 and 06 fail with every measured value at `bytes = -1`, independent of whether change detection exists. (Diagnosed as W0851 dropping the event-guarded `$fopen` until 2026-09-20; W0851 is gone and the numbers did not move — the cause underneath is that a §9.5 call renders as the literal `0` outside the display unit, so `fd` is 0 in the core. See §S01 in the defects list.) Fixture 07 is still green. Fixture 12's 1e-24 and 1e-18 bands are 2.4 and 4.6 ULP — the same floor §5.4 charges to A02 — invisible today only because the file is refused at compile time. `§4.2.5` is cited for a string `==`, which is §4.2.7 / §3.3 Table 3-3 | a fabricated quotation attached to a **new** citation the repair introduced: §5.10.2 is quoted as "the initial_step event is active on the first point of an analysis"; the clause reads "initial_step and final_step generate global events on the first and the last point in an analysis respectively", and no `docs/` file contains the quoted string. The same new clause is then said to make `@(initial_step)` "a legal place for `$fopen` and `$fmonitor`" — §5.10.2 mentions no system task at all, and that sentence is the whole justification for calling W0851 a deviation. Fixture 07's Newton step is published as `+7.22e8 V` in a paragraph headed "Re-derived"; the file's own constants give 7.21e8. §5.10.2 appears in two `//! lrm` directives and in neither of SPEC.md's two clause lists, while §9.5.1 appears in the covered table with no fixture pinning it |
| **A09** *(previous pass, preserved)* | 5 — the invented half-volt `$limit` example, the §8.4.7 miscite and ".op gives exactly 1.0" (5.2); fixture 9's non-LRM premise plus its self-destroying seed, and `a09_idt_self_reject`'s t=0.6 fragility (5.3) | 5, in the files. Each withdrawn phrase survives only inside a labelled correction block; the §8.4.7 sentence was *relocated* to `M02/11_rejected_trials_deliver_once.va:10`. `.op` re-measured at `1.0000000574268284`. The self-destroying seed is gone, replaced by a branch-free clamp; `accepted=57 attempts=57 nr_iters=114`, no `TimestepTooSmall`, `itl4` untouched | 4 accuracy defects in SPEC.md's own evidence (§5.4) | fixture 9's band widened from rtol 1e-6 / atol 1e-7 to rtol 1e-3 / atol 1e-6, and the claim it makes is now one row wide (§5.1) |
| **X01** *(previous pass, preserved)* | 7 — `ltra_tran_long_run_past_8192` gating nothing (5.1); two wrong `.sp` numbers and "twelve complete, one errors" (5.3); the `.op` decks asserting the feature-absent value, 17 of 24 undiscriminating lossless rows, and `rejected_step_retry` duplicating `mismatched_load` (5.4) | 6. The 8192 deck is sine-driven and fails 6 of 14 values, every one sign-wrong, with a `tmax=10p` control isolating the cause to capacity; ngspice-44.2 gets every sign right on the same netlist. The lossless deck now fails 24 of 24, worst err/tol 98072. `\|v(b)\| = 0.45416048` corrected. `rejected_step_retry` is electrically distinct. Both `.op` decks gained a second, electrically distinct line | the `.op` decks: the fixer kept them and disagrees with the charge (§5.8). Plus 1 citation defect (§5.3) and 1 restated-not-remeasured count (§5.4) | the E.3/E.1.2 misattribution (§5.3) and the `1301`-vs-`1313` restatement (§5.4), both introduced by the repair in a row the first review certified clean |

### 5.1 Damage introduced by the repair pass — read this before the ledger

Twenty-three rows were repaired. **No row regressed, no fixture was weakened into a non-claim, and
the "honest DISPUTED section shipping an unchanged file" pattern does not occur anywhere** — every
withdrawn phrase survives only inside a labelled correction block and the live text was rewritten.
That is the good news and it is real. What follows is the cost, sorted by how much damage it can
do. Seven items are fabrications written by the repair itself, in rows the first review certified
clean. That is the same failure mode the repair was convened to remove.

**(a) Tolerances and expectations that moved. Every one was probed by mutation, not read off the
header.** A band widened until nothing fails reads as green and hides the defect it replaced.

- **A06 — the only widening that still mis-discriminates.** `$vt` went from a literal to
  `` CHECKEQ($vt, $temperature * (`P_K / `P_Q), 1e-7) ``, and the derived values to 1e-4 relative. That
  is the right shape, but a mutant built on Annex D.2's `` `P_K_SPICE ``/`` `P_Q_SPICE `` — a legal selection,
  and §9.15 supplies no number — measures `got=0.025851241113725592 want=0.025852026903638282 ok=0`
  and `id … ok=0`. `PHYSICAL_CONSTANTS_OLD` likewise. **2 of Annex D.2's 5 constant sets still fail
  a conforming tool**, down from 4 of 5. The Class A charge is narrowed, not closed, and the
  fixtures' own headers name only the two sets that pass. SPEC.md calls 1e-4 "four decades above
  the 2.4e-5 spread"; it is 4.1×.
- **A02 fixture 08**, 1e-15/1e-18 → 1e-12. Probed by deleting each contribution in turn: both wrong
  topologies red **3 of 3** assertions, with 5e11 and 5e8 tolerance widths of margin. Unlike the
  A09 widening this one keeps teeth at every assertion.
- **M01 fixture 06**, exactly 0.0 → 1.0. LRM-justified (a point placed exactly at 5n leaves the
  count genuinely unsettled) and teeth survive at 20n and 30n, measured. **It was omitted from the
  previous revision's damage ledger**, which simultaneously asserted that no fixture was weakened.
- **M01 fixture 10**, 1e-12 → 0.6. Correct call, disclosed in-file, teeth measured: the
  feature-absent variant reds 3 of 5 points, which is exactly what the header claims.
- **M02 fixture 13**, 1u → 4u. Justified (worst honest drift is 4 × `expr_tol`), teeth intact (the
  0.05 V discriminating error is 12500 band-widths), **argument wrong**: the "0.05 V gap to the
  nearest wrong arm" is 0.25 V; 0.05 V is the non-interpolating tool's error, counted twice under
  two labels.
- **H04 fixture 03**, `CHECKR(…, 1e-14)` relative → `CHECKEQ(…, 1e-14)` absolute amps, i.e. ~1.3e-11
  relative. Still discriminates on VerA by 2.3e-4; see (d) for the reading under which it does not
  discriminate at all.
- **A05 fixture 04**, a new 1e-3 band. Not a relaxation — it is a new absolute band on two new
  identity checks that replaced withdrawn digits, and its derivation is sound. But one of the two,
  the "extrapolation slope" check, **passes under both counterfactuals the file says it separates**
  and is sold as a discriminator in the fixture and in SPEC.md.
- **D09's VCD normaliser — a loosening sold as a strengthening.** The `$timescale` body now has its
  whitespace *removed* rather than collapsed, so `$timescale 1 ns $end` passes where it previously
  diffed. The change is defensible under §18.2 and the remaining teeth were measured intact; the
  repair calls it "slightly **stronger**", which inverts what it did.
- **Rows with nothing to widen, checked rather than assumed:** D03, D04, D06, D08, D09, D10, M04
  and P02 carry no numeric tolerance at all (exact transcripts, `CHECKX`/`CHECKI`, or four-state
  `%b`). A08-nodeset's only tolerance edit was a deletion. A10's twelve `.va` files are entirely
  `CHECKX`/`CHECKI`/`CHECKEQ(…, 0.0)`. A03 is entirely `CHECKEQ(…, 0.0)`. M03 is 15 × 1e-12,
  unchanged. A01 has exactly one non-trivial tolerance and it is provably sub-ulp.

**(b) Fabricated citations and fabricated mechanisms, written by the repair.** Five quotations that
exist nowhere in `docs/`, and two claims about this repository's own source that do not survive
opening the file.

- **H01 fixture 05** — `§6.9.2 … "the paramset for each instance is selected after generate
  statements have been evaluated"`. No `docs/` file contains that string, or 'selected after
  generate', or 'paramset for each instance'. §6.9.2 reads "**If a generate construct contains an
  instantiation of an overloaded paramset**, paramset selection is performed after the generate
  construct has been evaluated." The invented text drops both preconditions, and the fixture has no
  generate construct and no overloaded paramset, so the clause does not reach it at all. The
  directive `//! lrm 6.9.2` is on the file.
- **S01 fixtures 05 and 06** — `§5.10.2 … "the initial_step event is active on the first point of
  an analysis"`. The clause reads "initial_step and final_step generate global events on the first
  and the last point in an analysis respectively." Grepped for three fragments of the invented
  sentence across every `docs/*.html`: zero hits. §5.10.2 is a **new** citation the repair added to
  two `//! lrm` directives, and it is then made to say that `@(initial_step)` is "a legal place for
  `$fopen` and `$fmonitor`" — the clause mentions no system task of any kind, and that sentence is
  the entire justification for calling W0851 a deviation rather than a correct refusal. (W0851 was
  lifted on its own merits on 2026-09-20 — a guarded display is emitted inside its arm — which
  settles the behaviour but not the fabricated citation, still to be removed from both fixtures.)
- **M02 fixture 04** — `§3.2: "Integer variables whose values are assigned in a digital context
  default to the unknown value x"`. §3.2 reads "…default to an initial value of `x`." It is the
  only one of the repair's seven §3.2 seed comments written as a quotation; the other six paraphrase
  and are fine.
- **A08-nodeset fixture 02 and SPEC.md** — a fabricated *grammar derivation*, shipped as the
  audited correction for a fabricated citation. "The `'{…}` initializer reaches, from
  `net_decl_assignment`'s `expression`, the A.8.1 production `constant_assignment_pattern`." No
  `primary` or `constant_primary` reachable from `expression` admits an assignment pattern, and
  `constant_assignment_pattern` is referenced only from `noise_table_input_arg`, `real_type`,
  `variable_type` and a ranged `parameter_identifier`. The conclusion (Annex A cannot settle the
  question) is stronger than stated; the route to it is invented.
- **P03 `p03_vpi_analog.h:40-42`** — "§12.2 **and** §12.31 both defer to 'the `vpi_user.h` file
  listing in Annex G'". The chapter contains exactly one "Annex G" hit and it is in §12.31. §12.2
  defines its constants in situ with Table 12-1 and Figure 12-1. The joint attribution carries the
  whole numbering rationale.
- **A06 SPEC.md:376-382 and two fixture headers — a fabricated claim about `tests/torture.zig`.**
  "`failureContains` matches the pattern against `f.generated` — the generated Zig — *before* it
  reaches any diagnostic … So either fixture went green on **any** failure." Measured: `f.generated`
  is non-null only in the `GeneratedCompileError` branch (`torture.zig:187-193`), `--emit-zig` on
  both files yields zero `@compileError`, so `compileFixture` returns null, `verifyRejected` bails
  at the `orelse`, and `failureContains` is never called. Both fixtures were already red. The swap
  to `DiagnosticsReported` is harmless; the evidence printed for it in three places is not.
- **A10 SPEC.md — a fabricated measurement, and it removes coverage.** "Two calls in one analog
  block are **refused** by VerA: `error[E0201] … $bound_step` on the second call. That is a live gap
  against the clause's own wording", stated twice as a probe run 2026-09-19. Measured: the module
  passes `--check` with exit 0, builds and runs. `lower.zig:6726-6748` quotes §9.17.2 in comment and
  emits `.fmin` across calls, `codegen.zig:7156` emits `inst.bound_step = @min(inst.bound_step, in)`,
  and `lower.zig:10502` is a unit test named for exactly that rule. E0201 has one emission site in
  the tree and it is nowhere near this path. **This fabrication is the stated reason the row ships
  no fixture on §9.17.2's "smallest currently active" rule.**

**(c) New misattributions — real clauses, wrong container.** A05: §9.21.2 body prose attributed to
Table 9-31, twice, in repair-authored text (the same slip exists in three untouched files, so the
convention is systemic — but SPEC.md now launders it as "Table 9-31's `C`/`L`/`E` prose … opened").
D09: "§9.5 Table 9-2" — Table 9-2 is in §9.2. H04: §9.18's `#(.$mfactor(2))` example attributed to
§6.3.6, which prints no such example. M01: `//! lrm 7.3.4` on a fixture whose `always @(absdelta(…))`
is §7.3.5 — the exact inversion the repair withdrew from fixture 06 eight files earlier, and a bare
directive with no supporting prose, which is the "shows as covered without anything covering it"
shape §5.3 charged. M04: `$driver_type` placed in Table 9-19 and said to have "no subclause in the
offline document"; it is Table 9-20 and §9.23.4, and §9.23.4 supplies exactly the normative text the
SPEC says does not exist, so the stated reason for shipping no fixture is unfounded. M03: SPEC.md
restates §7.6's Example 1/2 rule as a function of port *direction* alone; the rule is keyed on
(direction, upper-connection discipline), and the restated form contradicts the row's own fixture 09
in the same paragraph that calls fixture 09 "already right".

**(d) Numbers restated as measured that do not reproduce.** Each of these sits in a document whose
value is that its numbers were run.

| Row | Published | Measured |
|---|---|---|
| A04 | "five of the twelve pass today" | four — contradicted by its own bullet list and its own transcript block |
| M03 | "measured: 9 of the 11 positive fixtures … print a failing `ok=0`" | six — its own transcript 250 lines later lists exactly those six |
| M03 | "all eight elaborate and fail on their own numbers", over a list of nine files | five; three stop at E0907, one is a reject fixture with no number |
| D09 | "39 fixtures under `tests/fixtures` pin a code" | 363. 39 is the `E0512` count, lifted from this manifest's D06 entry and relabelled |
| M04 | "39 fixtures pin a code, 48 pin the weaker `DiagnosticsReported`" | 381 files and 54 — the same lifted number, in a second row |
| M04 | "16 of the row's 32 asserted transcript lines" | numerator right, denominator 54 |
| A10 | `t = 5.0000005117e-4`, "0.51 ns past the crossing" | `5.0000051171875e-4`; the printed digits are 0.051 ns, contradicting the same sentence |
| A10 | the `a10_bound_step.sp` ceiling is `2e-5` | 2e-4; 2e-5 is the *other* deck's ceiling — the two are swapped |
| A10 | the `bound_step` deck's band is 3 % | 5 % enforced (`rtol 0.03` **+ `atol 0.02`**, `test_correctness.zig:347-349`) |
| A03 | "Measured: `@(timer(1n, 2n))` fires at 1n and 3.5n" | 1n, 4n and 5n — three firings, none at 3.5n. The companion line in the same two-line block reproduces exactly |
| M02 | "It carries 12 Zig unit tests" | 13 |
| P02 | "Every clause this row cites was opened. **All 28**" | the parenthesised list holds 29, and §12.31 is cited elsewhere and absent from it |
| P02 | "**Two** deliberate departures from verbatim survive and are correct" | three — `11_systf_analog.c:21-23` silently deletes "(see also: `vpi_register_analog_systf()`)" from a §12.22.1 quotation |
| P03 | Newton on `u³ = 8`: "…2.0000073, 2 — monotone" | 2.0000049; and it is not monotone across the first step |
| P03 | "it fails at the C compiler, not at an assertion" | all 13 compile clean under `-Wall -Wextra`; they fail at **link**. SPEC.md:181-182 says so and is right |
| P03 | the `src/` prose-hit census, and "38 `.va`, two positive, 36 `*_not_va.va`" | 3 files not 2, plus two omitted files; and the split is 3/35 |
| H04 | "the same experiment reads 7.692e-4 against 1.0e-3" | 7.692e-4 against **5.0e-4**; the 1.0e-3 is a different control run, welded into one sentence |
| H04 fixture 04 | "a tool that dropped the card's C … `2.5 - 0.9995` at t = 0.5" | 2.0005 at t=0.5 and 1.5010 at t=1.0 — the published figure matches neither |
| S01 | "Re-derived … first correction **+7.22e8 V**" | 7.21e8 from the file's own constants |
| A05 | fixture 04's cubic value "— BOTH MEASURED" | only the closest-point value is measurable at HEAD; `3` is refused by E0815. The cubic was re-*solved*, which the same document concedes 40 lines later |
| A02 | "the charge tape carries `q[p] = 1e-9` with the correct derivative" | `//! print none` means the published recipe prints no `q[…]` line at all; stripped and re-run, the tape is 0, 1e-9, 2e-9, 3e-9 — true at 1 of 4 timepoints |

Line-number restatements in the same class, all confirmed wrong and none load-bearing: A01
(`lower.zig:800` for text at `:804`, repeated in three fixtures; `tb.zig:228` is `:226`;
`converger.zig:294` is now `:303` after the Q03 fix), D10 (`preprocessor.zig:335` cited for two
different directives, which are at `:339` and `:333`; `:335` is a comment), A10
(`codegen.zig:5595`, one line early), D04 (`digital.zig:1024`, one line late), P02/M01 (paste-back
line numbers in blocks presented as verbatim: `05_…va:52` shows 86 for a statement at 87,
`08_…va:51` shows 77 for 78).

**(e) Claims narrowed in one artefact and left overstated in the other.** The pattern runs in both
directions, so neither file can be trusted as the corrected copy without checking the other.

- **A01 — inverted.** SPEC.md corrected `want=0.523599` to full precision; the fixture header it
  came from still carries the wrong string at `08_…va:29`.
- **A02 — inverted.** SPEC.md has the right solver identifier (`flowZ28sZ2cmZ29`); fixture
  `01_…va:51`'s "OBSERVED TODAY" block still prints `flowZ28pZ2cgZ29`, which is not an unknown in
  the model.
- **H04 — inverted.** Fixture `10_…va:44-47` says "Measured: … prints `got=0.5 want=0.5 ok=1`",
  present tense, describing the file as it was before the repair's own control made it fail to
  compile.
- **H01** — fixture 06's header still says "green, all five" after the repair took it to six checks.
- **M02** — the previous revision's damage ledger says fixture 07 went "from one non-vacuous check
  to three"; the honest count is one to two, and the check the original charge called vacuous is
  unchanged.
- **D08** — SPEC.md's new teeth claim ("a conjunction … is what gives fixture 12 its teeth: a
  refusal matching `combinational` and not `edge` cannot claim it") is stronger than `torture.zig`
  enforces: `failureContains` scans the whole diagnostic bag per pattern, so two separate
  diagnostics, or one sentence naming both, satisfy it.
- **A10** — "honoured, `h = 5e-5` … errs by 1.2 %; ignored, `h = 2e-4` errs by 20 %" is stated
  unqualified for a two-sample deck; measured, the second sample errs by 1.16 % and **passes**.
- **A06** — Class D was closed on the four charged files and left byte-identical in two files the
  repair never opened (`a06_psd_white_flicker_export.va:66`, `a06_noise_table_array_parameter.va:59`
  carry the exact line the repaired `a06_noise_source_name.va:56-58` now condemns in prose).

**(f) Self-contradictions introduced.** A01's correction note says the §4.2.5 miscite was in
"fixtures 02, 04, 05, 06 and 08 … six places" and then, eight lines later, that "fixture 05's prose
already cited §4.2.1 correctly" — 05 cannot both have carried it and have been right, and the
original finding named four places and exonerated 05. A02's new reject table gives fixture 03's
three measured values while its older fixture table gives two. A05's closing paragraph claims
"Every quotation in every header in this directory matches the HTML" and is wrong in at least five
places, one of them a silent `2^N`-for-`2N` emendation inside quote marks. A08-nodeset's repair
ledger says "A.8.3 … contains no array-element production at all" while its own body correctly
locates `constant_expression_or_null` inside A.8.3. D08 asserts that "§5.5 records no scope
violation" against a §5.5 then headed "This gate now fails". P03's shipped header announces "TWO
INCONSISTENCIES IN THE LRM'S OWN TEXT" and lists three. M03 says "an adversarial review of this row
found six defects" over five items and a register that charges five.

### 5.2 Class A — fixtures a conforming implementation fails

The dangerous class: the path of least resistance for an implementer is to make the compiler
non-conformant. **All nine of the original entries are repaired** — P02's polluted time queue, D03's
fixture 10, A03's solver-iteration count, D06's two bare rejects, plus A06's `$vt`, M01's `delta`,
M02's integer seeds and its fixture 07, and X01's 8192 deck. What remains is residue and newly
found, all of it narrower than what it replaces, none of it disclosed in the fixtures that carry it.

- **A06 — two of Annex D.2's five constant sets still fail.** Measured, not argued: a mutant whose
  `$vt` uses `` `P_K_SPICE ``/`` `P_Q_SPICE `` — a legal D.2 selection, and §9.15 supplies no number —
  fails `a06_small_signal_linearization.va` on both the `$vt` identity (off 7.9e-7 against a 1e-7
  band) and the junction current, and `a06_psd_bias_dependent.va` inherits the same trap one step
  deferred through its two `rtol=1e-4` directives. `PHYSICAL_CONSTANTS_OLD` is the same story. The
  shipped literal `1.2010369553128491e-4` is still one implementation's digits. The headers claim
  the band is "wide enough that BOTH defensible constant sets pass" and name only the two that do.
- **M02 fixture 12 and M04 fixture 12 — the §9.22.4 reading.** Both rows' headline driver-update
  fixtures assume `driver_update` does not fire for the connect module's own `assign d = out;`.
  M04's own fixture 10 argues the opposite at the netlist level, and §9.22 ¶3's exclusion is written
  for the driver *access functions* while §9.22 ¶1 introduces `driver_update` as an operator.
  Under the literal reading every `updates=` column shifts by one and all four `ok=` read 0. Both
  derivations are in §5.8; neither fixture discloses that there is a question.
- **M01 fixture 10 — an unspecified `time_tol`.** `absdelta(V(e_in), 0.3)` specifies no tolerances,
  and §5.10.3.4 both excludes events within `time_tol` of the previous one and says the tool sets
  the tolerances when they are not given. A conforming tool that picks a generous one suppresses
  every post-initialisation event and misses the 0.5 band by 2.0 at t = 20n. The fixture is headed
  "TWO CLAIMS, BOTH LATITUDE-FREE".
- **A08-nodeset fixture 02 — the cold-start basin.** `V(n[1],g) == 1.0` is whatever root Newton
  reaches from `tb.zig`'s `@splat(0.0)`, as the fixture's own :23-25 admits. A conforming tool whose
  cold start lands in the basin of 2 or 3 fails it. Fixture 01 got an "ON CONFORMANCE" caveat for a
  smaller exposure; fixture 02 did not.
- **A05 fixture 13 — a conformant compile-time refusal fails it.** §9.21's first sentence is a
  `shall` on the data set. A tool that refuses at elaboration any literal abscissa duplicate whose
  dependents are not provably equal passes the benign table and refuses 13's conflicting one,
  failing `//! exit 1`. Much narrower than the original charge, not closed.
- **Refusals that pin wording rather than behaviour.** `D03` fixture 13's substring names one of the
  two independent reasons `wire (small) w;` is ungrammatical, so a tool that diagnoses the other is
  failed for a correct refusal (one-character fix: `w = a;`). `D09` 90/91, `M03` 12/13 and
  `M04` 20/21 all pin invented phrasings for diagnostics that do not exist yet; `M04` 21's
  `net type` already occurs in four shipped diagnostic strings, and `D08`'s `output symbol` will not
  match a refusal that quotes A.5.3's `output_symbol` with the grammar's underscore. All are
  disclosed in their headers except `M04` 21's collision.

### 5.3 Class B — citations that do not survive being opened

Every citation in every repaired row was re-opened against `docs/`, including the ones the first
review passed — which is how most of what follows surfaced. **All twelve originally charged rows
are repaired**: A01's §4.2.5, A03's §3.2.2 and §4.2.1.1, A04's two, A05's §4.5.14, A06's two,
A08-nodeset's 1800.2 and A.8.3, D09's six, H04's three plus fixture 11's invented normative claim,
M01's §4.7.2 and §7.3.5, M03's §7.8.5.1 example and the §7.6 swap (in five files, not the four
charged), P02's §2.5 and its six-vs-three action reasons, A09's three, D10's `` `ifdef `` clause.
**D10's repair went further than the charge and was right to**: this manifest's own proposed
replacement ("which is §10.4") is itself wrong — §10.4 is `` `define ``/`` `undef `` and settles
nothing about conditional compilation; the governing rule is IEEE 1364's, which is not in `docs/`,
and the fixture now names it by deferral rather than inventing a subclause.

What is still open, after the repair:

- **X01 — the repair's own misattribution, carried forward.** SPEC.md's LRM bullet attributes to
  **E.3** the sentences "The mathematical description of the built-in primitives can differ…" and
  "Verilog-AMS HDL offers no solution in this case other than the possibility that if the model
  equations are known, the primitive can be rewritten as a module." Both live in **E.1.2**
  *Degree of incompatibility*: in `docs/annex-e-spice.html` the E.1.2 heading is at offset 3812 and
  E.2 at 5828, the two quoted strings sit at 5486 and 5681, and E.3 does not start until 10303.
  Everything else in the bullet checks out.
- **H01 fixture 05 — an invented §6.9.2 sentence**, and §6.9.2 does not reach the fixture. See
  §5.1(b). This is the most serious surviving citation defect in the set: it is a fabricated
  quotation carrying a `//! lrm` directive, in a row this register previously certified clean.
- **S01 fixtures 05/06 — an invented §5.10.2 sentence**, on a clause the repair itself added, doing
  load-bearing work (§5.1(b)). Separately, `01_…va:71-72` and SPEC.md cite **§4.2.5** for a string
  `==`: §4.2.5 is *Relational operators* (`< > <= >=`) and never says "integer". Equality is §4.2.7,
  and for string operands the governing text is §3.3's Table 3-3.
- **M02 fixture 04, A08-nodeset fixture 02, P03's header, A06's `torture.zig` claim** — the other
  four fabrications, all in §5.1(b).
- **A03 — the row's entire `disable` side has no clause in the shipped LRM.** `grep -i disable
  docs/*.html` returns only the A.6.4/A.6.5 productions and an Annex B keyword entry. Fixtures 01,
  02, 03 and the refusal 11 derive their semantics from §5.3's "the control shall pass out of the
  block after the last statement is executed" — a sentence about *normal completion*. The rule that
  actually settles fixture 03's `b = 1` vs `b = 101` is IEEE 1364 §9.6.2, which is not in `docs/`
  and is cited nowhere. This touches 4 of the row's 7 failing fixtures and no section of this
  register had charged it.
- **Inherited clauses carried by fixtures without being declared.** D06's rise/fall selection,
  x-takes-the-smaller-delay, turn-off and inertial supersession are IEEE 1364 §6.1.3, named in the
  fixtures and in neither SPEC.md's clause list nor this manifest's row. D10's fixture 11 rests on
  1364 §3.7, §7.10 and §7.11 — and contradicts itself about whether the resolution table is §7.9's
  or §7.11's, in the fixture and in SPEC.md. D04's §8.5.x work and D09's §17.x work are declared;
  these are not.
- **Real clause, wrong container, still live:** D09's Tables 9-1/9-2/9-3/9-7/9-11 filed under
  §9.4.1/§9.5/§9.6/§9.10/§9.14 when all five are in §9.2 (repo-wide convention, also in
  `lower.zig` — but it is the class of error this section exists for); A06-noisetables'
  `a06_noiseless_res.va` quoting a §4.6.4.3 sentence as §4.6.4; A06's `` `M_PI `` cited to Annex D.1
  when it is D.2 and the row says D.2 correctly twelve other times; plus the four new ones in
  §5.1(c).
- **Alterations inside quotation marks.** D04 prints §5.10's six bullets as five and drops
  "behavioral" from "in different parts of the behavioral model"; D04 also shows `function_port_list`
  and `task_port_item` with every `{ attribute_instance }` removed. D08 renders "and so on" as "and
  so forth" and "IEEE Std 1364 Verilog" as "IEEE Std 1364-2005 Verilog HDL". A05 prints `2^N` for
  the corpus's `2N`. A10 inserts an article into §9.15's "either a string literal, string parameter,
  or a string variable". A02's `10_…va:12-18` splices two §5.2.1 sentences with an intervening
  sentence removed and no ellipsis, in the same pass that fixed exactly this defect two files over.
- **Clause inventories that do not match the files.** M03's SPEC lists §7.7.4 as covered and no
  fixture cites it. A05 lists §9.5.1 in the covered table with no fixture pinning it; S01 does the
  same, while §5.10.2 sits in two `//! lrm` directives and in neither of its clause lists. A02
  declares a complete citation audit over 16 clauses while 18 are pinned. D08 counts A.3.1's
  instance productions as seven; there are eight. §4 of this manifest carried two of its own:
  `§4.2.14` against A06-noisetables and `§6.5.2` against M03, neither cited by any fixture — both
  removed in this revision.
- **Overreach.** D08 calls §7.8.5.1 the clause that "normatively fixes the left-to-right terminal
  order"; §7.8.5.1 says its names "do not define actual port names" and "may not be used to
  instantiate". A10's fixture 04 says the LRM's sample-and-hold "spells exactly that" while dropping
  `exclude 0` — the omission is what makes its motivating scenario coherent. A10's fixture 12 says
  the non-negative-tolerance sentence "appears **verbatim**" for §5.10.3.1 and §5.10.3.2; all three
  wordings differ, and the file's own next clause says so. H04's fixture 11 reads E.3's "required
  names" as "exhaustive".

### 5.4 Class C — disputed or wrong expected values

**Repaired and struck:** M04's 16 transcript lines, D03's `zz01`, A04's fixture 10 instant and its
two non-discriminating comments, A05's fixture 04 wants and its fixture 13 deferral, H01's fixtures
02 and 06, D10's three, S01's `%g` explicit-precision rows and its synchronous `$fmonitor` pair,
A02's ULP-floor tolerances, plus A06's, M01's, M02's, A09's and X01's entries. Every one was
re-derived independently rather than taken from the repaired header, and the counterfactuals
published by A02, A05, M03 and D06 reproduce byte-exact when re-run.

Still open:

- **A05 — fixtures 06 and 07 still encode two column rules, and the reconciliation rests on a
  reading the grammar does not support.** Both headers now assert a two-arm rule whose second arm is
  justified by "Syntax 9-16 makes the control string `"[interp_control[;dependent_selector]]"` —
  both halves optional". The nesting makes the *selector* optional inside a present `interp_control`;
  it does not make `interp_control` optional while the selector survives. §9.21's own grammar reads
  `interp_control ::= 1st_dim_table_ctrl_substr_or_null [, …]` — a null sub-string is still a
  sub-string — so `";2"` parses as one null sub-string plus selector 2, and 06's arm-1 rule gives
  column 3 = 2.0, which is the original charge. An implementer following 06 literally still breaks
  07. Defensible engineering, not derivable from the cited text. Both derivations in §5.8.
- **S01 fixture 01 — two of the four surviving `%g` rows are still the disputed reading, now behind
  a circular rationale.** The header says the rows are "derived both ways and the two derivations
  agree", but its cross-check generates both candidates with C's significant-digits precision and
  then applies Table 9-23's shorter-output rule, which fixes only the *format branch*. Under a
  uniform fractional-digits reading of §9.4.3's own worked example, row 1 is `1234.5678` — exactly
  what VerA prints today, i.e. the counterfactual is indistinguishable from a tool that follows the
  clause's example consistently. Rows 2 and 3 are genuinely double-derived and sound. Fix is one
  sentence: say the unglossed default precision is read as C's 6 significant digits.
- **S01 — §9.4.1 change detection is now pinned by nothing.** Both 05 and 06 still fail, and since
  W0851 was lifted (2026-09-20) the cause is a DIFFERENT one that the old diagnosis hid: the
  event-guarded `$fopen` now runs, but it runs in the display unit ONLY. Every other unit renders a
  §9.5 call through `codegen.emitFileCallDropped`, i.e. as the literal `@as(i64, 0)` — so the
  shared core computes `fd = 0`, `updateState` stores that 0 into the held slot, and `$ftell(fd)`
  reads -1 exactly as before. A descriptor assigned inside the analog block and read as a VALUE is
  unrepresentable until a file call's result can leave the display unit. Measured values unchanged
  (`bytes = -1, -3, -3, -3`), and they are still not a function of whether change detection exists.
  The row's headline clause has zero live coverage; SPEC.md concedes this in one place and still
  lists both fixtures under the §9.4.1 "pins" column.
- **D10 fixture 11 — an internal contradiction about which 1364 clause holds the resolution table**
  (§7.9 at :28 versus §7.10/§7.11 at :32-33 and :56-57), repeated in SPEC.md. At most one is right
  and neither is openable in this repo.
- **H04 fixture 03 — the teeth are reading-dependent and the header does not say so.** The
  "drop the card's TC1 and the two sides separate by 2.3e-4" claim holds only under the absolute-`T`
  reading. Under the rise-above-`tnom` reading, which the same header declares equally defensible,
  both sides read 1.0e-3 with or without `tc1` and the `CHECKEQ` has zero teeth. What survives on
  any reading is the name-binding `CHECKX(r1.tc1, 1.0e-3)`, not the equation claim.
- **A03 fixture 08's `w4`** carries a non-trivial claim at 1 of 5 timepoints, and **A10's
  `a10_bound_step.sp`** discriminates at 1 of 2 sample points. Both are tabulated honestly in the
  fixture; only A10's SPEC.md states it as if it held at both.
- **D09** — "All fourteen fail at the intended construct, none at parse time" is wrong for three:
  05 and 10 die on the `$display` format string and never reach `$time`/`$clog2`. **D08** — SPEC.md
  contradicts itself about whether today's `tran` is a W0250 warning or a hard E1100 (it is E1100
  under `--run`, which is the mode the row is written against).
- **A01** — `tests/fixtures/check.vh:22` carries the very miscite A01 just corrected ("A comparison
  is an integer in Verilog-A (§4.2.5)"). It is a tracked repo file, so the row cannot touch it
  without breaking the scope gate; the repo's shared header now disagrees with the corrected row.

**A09 and X01 — wrong numbers in the repaired rows' own supporting evidence.** Carried forward from
the previous pass unchanged. These are not fixture defects; they are defects in the argument the
fixture rests on, which is what a reviewer reads first.

- **A09 — the evidence for the row's one surviving defect names a function that does not exist.**
  SPEC.md:45-46: "`Hooks.update_state` is called from `converger.checkConverged`
  (`src/analysis/solvers/converger.zig:316`)". There is no `checkConverged` in that file. The call
  is `if (sys.updateStates(x)) |_| …` inside `finalizeStep` (fn at :255; the call is at HEAD line
  317, so the line number is right and only the name is wrong — probably confused with the
  `sys.checkConvergence(x)` device hook three lines above). Two sibling line cites in the same
  argument are also off: `:290` for the "`t_prev` … written by every generated device and read by
  none" comment is HEAD 287-288, and `:302` for "all 27 generated devices return `.ok`
  unconditionally" is HEAD 313-314. **This is the evidence for B1, the only defect A09 still
  claims.**
- **A09 — "error exactly 0" is false by 1 ULP at two of six samples.** SPEC.md:169 and :246 say
  `a09_absdelay_accepted_only`'s error is "exactly 0" / "worst error exactly 0". Measured from the
  rawfile: t=0.4 gives `0.30000000000000004` (err 5.55e-17) and t=0.8 gives `0.7000000000000001`
  (err 1.11e-16). Both pass comfortably, but §7 item 9's promise that every §4 number was produced
  by the build does not cover this derived line.
- **A09 — SPEC.md:190-204's reproduction recipe is stale by environment.** The
  `sed -i 's/std\.posix\.getenv("ESPICE_HB_TRACE")/std.c.getenv(…)/'` is a no-op against the
  current working tree (`hb.zig:286` now calls `converger.hbTrace()`), and "ARPice does not build
  on `main` today" is true of HEAD but not of the tree, which builds with plain `zig build`.
  Harmless — the recipe still succeeds — but it no longer describes what happens.
- **A09 and X01 — "built from source at HEAD" is not what happened.** Both SPECs state their
  numbers came from an `espice` built at HEAD with "ARPice's Q03 build fix having landed". The Q03
  fix has **not** landed; it is the uncommitted working-tree diff in §5.6. At true HEAD the tree
  does not compile, so every number in both rows was produced by HEAD + 4 uncommitted `src/` edits.
  The sentence should say so. (This is now the last substantive reason to commit that fix.)
- **X01 — a wrong number was re-asserted rather than re-measured.** SPEC item 3 and
  `txl_tran_long_run_past_2048.sp` both state the `tmax=10p` control run has "1301 accepted
  points". Measured **1313**, both with `.tran 10p 13n 0 10p` and with `.tran 10p 13n`. The rest
  of that claim is exact: the 1 ps run publishes the edge at 8.058500 ns and the 10 ps control at
  11.012000 ns. Not load-bearing — no checked-in deck pins it — but it is a number restated in a
  repaired SPEC without being re-run (§5.8 item 4).

### 5.5 Class D — fixtures with no teeth

Disclosure is still not a fix. **Repaired and struck:** A03's fixture 10 (deleted) and its 08/09,
A05's fixture 08, A06's four, A08-nodeset's fixture 03 (deleted) and its fixture 01, A10's 01 and
05, D03's fixture 09, D06's `assign_drive_strength`, D08's two rejects, D10's 04/07/10, H04's
fixture 10, M03's 10/11/03, M04's fixture 14, M02's fixture 07, A04's fixture 09 (re-homed as a new
fixture that fails 3 of 12), plus A09's and X01's. In every case the teeth were measured by building
the wrong implementation, not inferred from the header.

Still open:

- **The already-passing census, re-measured.** A10 7 of 15 (including all three host decks), A02 5
  of 13, A06 3 of 13 green plus 5 red only at the directive parser, H01 4 of 12, A04 4 of 13, A01 2
  of 11, S01 1 of 13, A05 1 of 13, D03 0 of 13, H04 1 of 11, M02 0 of 13, X01 9 of 13, A09 6 of 9.
  Every one is disclosed in its own SPEC.md. Two rows narrowed the charge by *argument* rather than
  by code and both arguments were measured and hold (A01's 06/07 anti-fix interlocks, A02's
  reject table); that is better than the previous state and still not a failing fixture.
- **A05 fixture 07 was closed by disclosure alone** — the file's own header says "Nothing in this
  file's wants changed", and it passes 5/5. SPEC.md labels it "Class D, already-green disclosure",
  which concedes the point.
- **A02 — three of the four fixtures charged gained prose, not pressure.** 03, 05 and 11 carry
  byte-identical assertions; what is new is SPEC.md's "what each already-passing fixture would
  reject" table, which is now verified true but is documentation, not a claim that can go red.
- **A06 — the narrowing skipped two files.** `a06_psd_white_flicker_export.va:66` and
  `a06_noise_table_array_parameter.va:59` still carry the pinned-probe line the repaired
  `a06_noise_source_name.va:56-58` condemns in prose; 63's `kf / pow(1.0, 1.25)` against `1e-20` is
  `kf` against `kf`, the same literal-against-itself shape the repair deleted elsewhere; and
  `tbl[1] / tbl[3]` is arithmetic over a parameter default declared three lines below it.
- **M04 fixture 14's three bypass lines** still have no independent teeth; the repaired claim rests
  on line 1 being *missing* from a non-inserting tool's stdout, which discriminates only under an
  exact whole-transcript compare that no build step performs.
- **A04 fixture 09** passes 12/12 and is now labelled a regression floor. Its remaining checks were
  measured to have teeth against the two regressions its header names (a pass-through operator reds
  3 checks, a laplace one-pole lowering reds 5) — a real gate, not a failing fixture.
- **Directives nothing reads.** A02's fixture 90, A05's fixture 13 and M03's two rejects are graded
  only by `zig build torture`, whose catalog walk (`build.zig:428`) never reaches `tests/pending`.
  D08's and M04's reject fixtures are `.v`, and `harness.zig:787` collects `.va` only, so **nothing
  in the repo reads their directives at all today**. P03's 13 fixtures have no build step. This is
  wiring, not fixture quality, but it means several "fails today" counts are statements about what
  *would* be graded.

### 5.6 Class E — scope. **This gate passes.**

The previous revision recorded this gate as failing. That was wrong, and it was wrong in a way
worth naming: the four modified files in ARPice are the **deliberate, tested Q03 build fix**, not a
scope violation. Any verdict that reported them as one was working from a stale instruction.

```
/home/omare/Documents/Projects/Zig/VerA     ?? tests/pending/
/home/omare/Documents/Projects/Zig/ARPice    M src/analysis/pss/hb.zig
                                             M src/analysis/root.zig
                                             M src/analysis/solvers/converger.zig
                                             M lib/frontend/tests/prepared.zig
                                             ?? tests/pending/
```

Nothing else is modified in either repo. `build.zig` and both `tests/fixtures/` trees are
byte-identical to `45b505d`; VerA's `src/` is too. Every one of the twenty-four rows checked this
pass confirmed this independently.

**What the Q03 fix bought.** ARPice went from *not compiling in any optimize mode* to **297/297
unit tests** and **351/353 build steps**. The one remaining failed step is the known-nondeterministic
circuit suite, which scored **518/616 on its first measurable run**. That figure establishes nothing
about determinism on its own: the same suite was previously recorded at 492, 494 and 518 on an
unchanged tree, so one run is one sample. It is a separate row, not a regression introduced here.

**Consequences for the rows that depend on it, now settled rather than open.** ARPice builds, so
A06-noisetables', A10's and X01's host numbers are reproducible from source and were re-derived from
a fresh build this pass — every published figure reproduced, and every `netlist_sha256` matches.
A09's and X01's SPECs still say their binaries were "built from source at HEAD"; they were built
from HEAD **plus** this fix, which is uncommitted. That sentence is the last honest reason to commit
the fix as its own change before approving anything that cites it.

**Hygiene.** The 46 MB of `.zig-cache` spill under `tests/pending/A06`, `tests/pending/H04` and
`tests/pending/A08-nodeset` is deleted. The verification pass recreated 19 MB under
`tests/pending/A05/.zig-cache`; that is deleted too. `VerA/tests/pending` is 3.0 MB and
`ARPice/tests/pending` 372 KB, with no `.zig-cache` anywhere under either.

`zig build torture -- --strict` is intact and re-run: **`vera: 1323/1323 fixtures behave as they say
they do`**.

### 5.7 Reproduction defects

**Repaired:** M01's "every diagnostic was reproduced" claim (in substance — see below for the
letter), A01's hand-edited "Observed today" block (re-measured and now reproducing line for line,
including the two lines the review caught and the previously-elided diagnostics), A04's `zig test`
command and its `@hasDecl` short-circuit (the guard now lives in a shim, so both test bodies compile
and only the single `D.stateCtl` call stays unanalysed), A05's `//! bias`/`//! sweep` claim (now
correctly narrowed to "only `//! exit` is unchecked outside the torture runner", with `tb.zig:228`
and `:230` and `torture.zig:361` all verified), D09's VCD normaliser (rebuilt against the hand VCD
it describes; `diff` silent, discrimination measured three ways).

Still open:

- **M01 — repaired in substance, still wrong in the letter.** SPEC.md says the headers were made by
  "pasting back what it printed, line numbers and all". `05_…va:52` pastes `86 | #10 d = 1'b1;` for
  a statement at line 87 and `08_…va:51` pastes `77` for `78`. The codes and ordering are now right
  for all thirteen, which was the charge; the two transcripts presented as verbatim still are not.
- **A10 — the provenance block is dead.** SPEC.md names "the one binary that exists" by path,
  sha256 and mtime; the path now holds a different binary with a different hash. The whole "ARPice
  does not build from source today" section, including its pasted `Build Summary: 328/333 steps
  succeeded (2 failed)`, is false end to end and should be retired rather than amended. Every figure
  it was protecting was independently re-derived from a fresh ReleaseFast build this pass.
- **A06-noisetables — a hand-assembled transcript presented as captured.** SPEC.md:47-57 is headed
  "Live proof, current build" with a shell command; the command writes a binary rawfile and prints
  three summary lines, only the middle of which appears in the block. The substance is true — all
  four rawfiles were decoded and every `onoise`/`inoise` value is 0.0 — so this is presentation,
  not a wrong number. Same family as the charge A01 just cleared. The `device.zig:469` block in the
  same document is reformatted (`1e-18` for the file's `0.000000000000000001`), with an exact line
  number, and offered as a quotation.
- **D06 — the same shape, one grade milder.** SPEC.md:188-202 is labelled "Captured, not typed" and
  headed with a literal loop; it is a hand-formatted summary of that loop's output, with per-file
  errors collapsed and a `(PASS)` annotation the tool never prints. Every fact in it reproduces, and
  the adjacent blocks at :206-232 are byte-exact.
- **P03 — the row's headline sentence is wrong about its own failure mode.** "Every one of them
  fails today, and it fails at the C compiler" (SPEC.md:3-4) versus "all thirteen compile clean
  today under `zig cc`; they do not *link*, which is the deliverable" (SPEC.md:181-182). The second
  is right; all 13 compile with `-Wall -Wextra` and produce only two unused-function warnings from
  the shared header.
- **D08 and M04 — reject fixtures no runner reads.** `harness.zig:787` collects `.va` only and
  `//! reject` is interpreted only by `tests/torture.zig`, so the teeth measured for D08's two and
  M04's two are the teeth they *would* have after the move-and-rename. Both SPECs say so.

### 5.8 Open questions — the fixer kept a number or reading the review disputed

Not adjudicated here. Each carries both derivations; pick one. Items 1-6 are carried forward from
the previous pass unchanged.

1. **X01 — are the two `.op` decks a fixture or a regression gate?**
   *Review:* they assert exactly the DC-resistance value the currently-broken path returns, they
   pass at HEAD, and a fixture satisfied by the absence of the feature buys nothing.
   *Fixer:* kept them, labelled them honestly as regression gates in SPEC.md, and added a second
   electrically distinct line to each so the assertion now forbids any Z0- or Td-dependent stamp —
   a constraint no fallback can meet by accident. Both statements are true. The question is
   whether a labelled regression gate belongs in a row whose job is to fail. **The same question
   now governs A05's fixture 07, A04's fixture 09, A01's fixtures 06/07 and A10's three host decks;
   answer it once.**
2. **X01 — the `rejected_step_retry` interpolation bound: 3.9e-6 or 5.8e-6?**
   *Fixer:* `(h²/8)|v''|` at h=20 ps with amplitude 0.5 → 3.9e-6, printed in the `.sp` header and
   in the oracle derivation. *Review:* the column the bound actually gates is `v(b)`, whose
   amplitude is `|0.5(1+Γ_L)| = 0.74992`, giving 5.8e-6. No practical effect — atol is 5e-5 and the
   measured worst residual is 5.36e-6 — but the stated arithmetic does not cover its own worst
   column.
3. **X01 — the ngspice cross-check digit: 9.5e-16 or 9.2e-16?**
   `ltra_ac_lossy_telegrapher.sp` says ≤ 9.5e-16; SPEC.md's oracle-policy paragraph and fixture
   table say 9.2e-16. One of them was not re-measured. Separately, neither figure is reproducible by
   the command the SPEC says produced it — `wrdata` with `filetype=ascii` prints ~9 digits.
4. **X01 — the `tmax=10p` TXL control run: 1301 or 1313 accepted points?**
   *Fixer:* 1301, restated in SPEC item 3 and in the `.sp` header without re-running.
   *Review:* 1313, measured twice. Nothing is pinned on it; it is prose in a document whose value is
   that its prose was measured.
5. **A09 — "250× to 500× the band": arithmetic or measurement?**
   *Fixer:* 0.5/1e-3 and 0.5/2e-3, correct arithmetic for the clamp magnitude against the tolerance.
   *Review:* measured, the clamp only engages during the initial DC solve, so the sentence describes
   t=0 and nothing else (§5.1). Both are right about different things; the sentence as written reads
   as a property of the whole sweep.
6. **A09 — does the codegen hoist break "any" model with a conditionally-assigned real?**
   *Fixer:* SPEC.md:99-100, "**any** model with a conditionally-assigned real fails to build."
   *Review:* a module-level `if`/`else` assigning a `real` in an analog block compiles and solves
   fine; the hoist fires only inside an *analog function*, reproduced verbatim. The branch-free
   spelling is genuinely forced, so the conclusion holds; only the scope word "any" is wrong.
7. **M02 / M04 — does `driver_update` fire for a connect module's own driver?**
   *Fixtures:* no. §9.22 ¶3 says the driver access functions "only access drivers found in ordinary
   modules and not to those found in connect modules", and both rows' expected counts assume that
   exclusion covers the operator.
   *Literal reading:* §9.22 ¶1 introduces `driver_update` as an **operator**, ¶3 is written for the
   **access functions**, and §9.22.4 says the statement executes "any time a driver of the signal is
   updated", unrestricted. M04's own fixture 10 argues at length that the connect module's
   `assign d = out;` *is* a driver at the netlist level. Under this reading every `updates=` column
   in both rows' fixture 12 shifts by one and all four `ok=` read 0.
   Either settle it or move `out = 1'b0;` out of the counting window. M02's fixture 13 is immune
   (its `always @(driver_update d)` body is idempotent); fixture 12 is not.
   **Settled 2026-09-24 by the user: no** — the fixtures' reading, on §9.22.6's separation of the
   connect module's driver (it drives the receivers) from the drivers of its digital port
   (`docs/ROADMAP.md §7` item 1). M04's fixture 12 now asserts it and passes.
8. **A05 — can `";2"` carry a dependent selector with no interpolation control?**
   *Fixer:* yes — Syntax 9-16 writes `"[interp_control[;dependent_selector]]"` and "both halves are
   optional", so 07's `";2"` selects dependent column 2 and 06's leading-column rule does not apply.
   *Review:* the nesting makes the selector optional *inside* a present `interp_control`, and
   §9.21's grammar has `interp_control ::= 1st_dim_table_ctrl_substr_or_null [, …]` — a null
   sub-string is still a sub-string, so `";2"` is one sub-string plus selector 2 and 06's rule gives
   column 3 = 2.0, which is what the original charge said. An implementer following 06 literally
   still breaks 07.
9. **A04 — does "exhibits no delay" extend to a non-unity filter?**
   *Fixer:* fixture 10 quotes the precondition honestly ("A filter with **unity transfer function**
   acts like a simple sample-and-hold … exhibits no delay") and then applies the conclusion to
   `H(z) = 1/(1 − 0.5z⁻¹)` with `tau = 0` passed explicitly.
   *Review:* that is an extension and the file does not say it is one. Much stronger than the
   unqualified version the review caught; not airtight.
10. **S01 — what does `%g`'s unglossed default precision mean?**
    *Fixture:* C's 6 **significant** digits, which is what every mainstream tool does.
    *Clause:* §9.4.3's own worked example glosses `%10.3g` as "three (3) **fractional** digits".
    Applied uniformly, the default gives `1234.5678` for row 1 — which is exactly what VerA prints
    today, so the row's counterfactual is indistinguishable from a tool that follows the clause's
    example consistently. Two of the four surviving rows are unaffected (trailing-zero stripping
    collapses both readings). The fixture currently claims the question does not arise; it does.
11. **Is a fixture allowed to rest on an inherited clause that is not in the shipped corpus?**
    Four rows do it in load-bearing positions: A03's `disable` semantics (1364 §9.6.2, uncited),
    D06's delay selection rules (§6.1.3, named but undeclared), D10's fixture 11 strength lattice
    (§3.7/§7.10/§7.11, and the row contradicts itself about which), M01/D04's §17.x and §8.5.x work
    (declared). §1.1 makes 1364 normative, so the citations are legitimate — but a reviewer cannot
    open them, and this register's own standard has been that a citation must survive being opened.
12. **A01 — do fixtures 06 and 07 earn their place as anti-fix interlocks?**
    *Fixer:* kept both, disputed the charge in SPEC.md:260-288 with reasoning rather than a silent
    edit. *Review, measured:* the reasoning holds — under an emulated clamp 06 goes red 2 of 3 and
    under modulus wrap 1 of 3; 07 with its veto deleted reads `got=1 want=2 ok=0` and with a second
    veto dies non-convergent. The fixtures have teeth against the wrong implementations they name.
    The row still ships two files that are green today. Same question as item 1.

**Settled this pass, recorded so it is not re-opened:** D10's `` `ifdef `` clause — this register's
proposed replacement (§10.4) was itself wrong, and the repair's deferral to the uncited 1364 rule is
the better answer. M03's §7.6 Example 1/2 discrimination — the fixtures are all correct; only
SPEC.md's restatement of the rule is wrong.

## 6. Implementation order

Derived from the `blocked_on` fields above and the plan's stated chain
(`D01 → D02/D03 → D04/D05 → D06–D09`; `D04/D05 + A09/A10 → M01/M02`;
`D03/D07 + H01–H04 → M03/M04`; object model + scheduler → `P01/P02/P03`).

**Phase 0 — commit the build fix. It is applied but uncommitted.**
`Q03`'s two sites are fixed in ARPice's working tree (`hb.zig:286` via `converger.hbTrace()`, the
`buildJob` arity in `lib/frontend/tests/prepared.zig`), and with them the tree compiles: 297/297
unit tests, 351/353 build steps. `A09`, `A10`'s three host decks, `X01` and `A06-noisetables` were
all re-measured from a fresh source build this pass and every published figure reproduced. What is
left is bookkeeping and the two unapplied guards: commit the fix as its own change so those rows can
honestly cite a buildable HEAD, then add the five `test_step.dependOn` lines and gate on `$?` so the
next Site 2 cannot rot unobserved.

**Phase 1 — analog rows that are blocked on nothing.**
`A01`, `A02`, `A03`, `A04`, `H01`. All run against HEAD today with the documented CLI. `A05`
joins as soon as `E0815` (`lib/ir/lower.zig:8660`) and the eager `readTableFile` (`:8624`) lift.
These are independent of the digital chain and can be worked in parallel with Phase 2.

**Phase 2 — the digital chain, in its stated order.**
`D02` (selects — nothing exists; `grep` for `partSelect`/`bit_select` over `src/` is empty) and
`D03` (strength lexer/parser + the `(strength0, strength1)` fold) first. Then `D04` (greenfield
from the lexer: `fork`/`join`/`task`/`wait`/`automatic`/`@*`/intra-assignment `#`/named blocks)
and `D05`. Then `D06` (needs D03's strength work for its one discriminating line), `D07`,
`D08` (needs D03 drive strengths), `D09`. `D10` is trivially unblocked (one string in
`predefined_macros`) except for fixture 11, which needs D03's strength model *and* D07's
multi-module `--run`.

**Phase 3 — infrastructure fixes that unblock host-side rows.**
`A08-nodeset` (one line in `ARPice/src/analysis/dc/op.zig:24`, plus the `seedFn` rewrite at
`eval.zig:1392-1406` so a nodeset reaches `x` and not `lim_x`). `A06-noisetables` (four sites:
`device_ir.zig:79`, `eval.zig:1714`, `ac/noise.zig:42` and — do not forget — `pss/pnoise.zig:41`).
`X01` (the LTRA/TXL AC stamp, which does not exist at all, and growable history for
`ltra_native.zig` CAP=8192 / `txl_native.zig` CAP=2048). `H04` (the `--spice` CLI flag and
`fixture_root` as a list, without which 8 of its 11 cannot even be run singly).

**Phase 4 — hierarchy.** `H01` (already runnable, place it in Phase 1 if convenient), then
`H02`, `H03`, `H04`. With `D03` and `D07` these gate M03/M04.

**Phase 5 — mixed-signal. Cannot start until the analog solver is connected to the scheduler.**
State this plainly: **`M01`, `M02`, `M03` and `M04` cannot begin in earnest today.**
`src/sim/scheduler.zig` already has the six-region enum (`active`, `explicit_d2a`, `inactive`,
`nba`, `analog`, `monitor`), the future heap, cancellation, the monitor-mutation guard and analog
request coalescing — **but the analog solver is not connected to the `.analog` macro-process
region, and nothing posts `.analog` or `.explicit_d2a` to the queue.** On top of that,
`src/sim/digital.zig` (~:1023) refuses any module with ports, parameters, instances, branches,
events, functions or an analog block, and `lib/backend/tb.zig:695` is a fixed-grid evaluator that
walks only the declared `//! time` list with no mechanism to insert a solver timepoint — which is
not merely a blocker but the reason M01's and M02's SPECs defer several claims to each other
(§5.0). Order within the phase, from M02's own analysis: (1) parser accepts `always` + `#` delay
+ `assign`; (2) `digital.zig` accepts modules with analog blocks and ports; (3) A2D delivery
(cross → digital tick with §8.4.3.3 half-precision-base rounding) unlocks M02 04/08/11;
(4) implicit D2A + region 3b unlocks 02/10/12; (5) explicit D2A + region 1b unlocks 03/05/06/09;
(6) `absdelta` interpolation unlocks 13; (7) §8.4.2 DC iteration unlocks 01. `M03` additionally
needs the §7.8 insertion phase (`lib/ir/elaborate.zig:54-58` documents its absence) and §7.8.5
generated names as defparam targets. `M04` additionally needs `wreal` as a net type and port net
type, and real variables + `%g` in the digital engine.

**Phase 6 — VPI.** `P02` needs the object model plus a *running* scheduler: `tests/vpi_host.zig`
is lint-only today and 11 of its 13 fixtures need a running simulation. `P03` needs all of that
plus a host that can solve DC/transient/AC with a bound `SystfHost` (`ARPice/src/analysis/eval.zig`
binds none) and a `test-vpi-p03` build step that does not exist. `P02` before `P03`.

**Parallelism that is safe:** Phase 1 and Phase 2 do not touch each other. Phase 3's three
infrastructure fixes are mutually independent and independent of Phases 1-2.

## 7. What this exercise does not establish

It does not establish conformance. It establishes that someone read a clause, wrote down what
they believed it required, and — in most cases — confirmed the current tool does not do that.
Concretely, none of the following follows from approving this:

1. **That the expected values are right.** The repair pass closed most of the originally disputed
   ones and every closure was re-derived rather than accepted. What replaced them is worse in kind
   if not in count: **twenty figures published as measured that do not reproduce**, plus a further nine
   restated line numbers (§5.1(d)),
   five fabricated quotations and two fabricated mechanism claims (§5.1(b)), across twenty-one of
   the twenty-six rows. Two adversarial passes have now each found a fresh crop. There is no reason
   to assume a third would not.
2. **That a passing fixture means a clause is satisfied.** Roughly forty fixtures across the
   twenty-six rows already pass against HEAD, and a further dozen assert values reachable by the
   existing fallback path (§5.5). Several "fails today" counts are also statements about a runner
   that does not read the file — `build.zig:428` never reaches `tests/pending`, and
   `harness.zig:787` reads `.va` only. A green count here is not a conformance count and must never
   be reported as one.
3. **That the failing fixtures cover their rows.** They cover the sub-clauses someone chose. Every
   SPEC.md carries a "Deliberately NOT covered" list, and those lists are long — §4.6.4.6
   correlation, `$driver_type`, min:typ:max selection, mixed interpolation dimensions, PLA tasks,
   the `$q_*` family, extended VCD, and more.
4. **That the citations are load-bearing.** Roughly twenty rows still carry a fabricated,
   misattributed, undeclared or silently altered citation (§5.3), and **seven of those were
   introduced by the repair pass, in rows an earlier review had certified clean**. Five fixtures
   quote sentences that exist nowhere in `docs/`. Four rows rest load-bearing weight on inherited
   IEEE 1364 clauses that are not in the shipped corpus at all, one of them uncited entirely.
5. **That anything is wired up.** Nothing runs in CI. `build.zig:428` pins `fixture_root` to
   `tests/fixtures`; `ARPice/tests/fixture_catalog.zig:6` opens `tests/fixtures` only;
   `tests/harness.zig:787` reads `.va` only, so every `.v` reject fixture is invisible. Until each
   row is moved and wired, approving this changes nothing observable.
6. **That the `w2/*` work was attempted.** It was not. Thirteen worktrees were provisioned on
   2026-09-16 and none was ever committed to (§2).
7. **That the three infrastructure defects are fixed.** `Q03` is — and it sits **uncommitted** in
   ARPice's working tree (§5.6), which is deliberate and tested, not a scope violation. `A08` and
   `A06-noisetables` are specified and untouched. `build.zig` and both `tests/fixtures/` trees are
   byte-identical to `45b505d`; VerA's `src/` is, ARPice's `src/` is not, on purpose.

**Minimum to re-review, in order of damage.** (1) Clear §5.1(b): delete the five fabricated
quotations and the two fabricated mechanism claims, and in A10's case ship the §9.17.2 fixture the
fabrication was used to excuse. (2) Re-measure or delete the twenty figures in §5.1(d); a
document whose value is that its numbers were run cannot carry a table of numbers that were not.
(3) Decide A06's `$vt` band — 2 of Annex D.2's 5 constant sets still fail a conforming tool
(§5.2). (4) Settle the twelve open questions in §5.8, starting with the two that change published
expected values (M02/M04's `driver_update`, A05's `";2"`). (5) Commit the Q03 fix as its own change
so the host rows can cite a buildable HEAD. The `.zig-cache` spill is gone.

**The fixtures themselves are in better shape than this register's length suggests.** Every defect
charged in the previous revision is fixed in the files; no tolerance was widened into a non-claim;
no row regressed. Three rows (`A06-noisetables`, `D03`, `D06`) can be approved as they stand. The
other twenty-three need their prose corrected, not their fixtures — with two exceptions where the
prose is load-bearing for a value: A06's constant-set band and the two §5.8 questions above.
