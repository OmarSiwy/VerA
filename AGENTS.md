# AGENTS.md

Read this before touching anything. It is short because the long documents are
listed in §1 and you are going to read those too.

VerA is a Verilog-AMS compiler in Zig. It compiles Verilog-A into Zig device
code that an external simulator links and calls inside a Newton loop.
`lib/` is the compiler, `src/` is everything that runs after it.

---

## 0. The three rules that are not negotiable

**1. Never type a conformance number. Measure it.**
`tools/conformance.py` is the only thing that may write measures A, B and C.
At a release it writes them into `CHANGELOG.md` (§3). `.github/workflows/publish.yaml` re-measures on
the runner and refuses any tag whose entry disagrees with the tree. If you find
yourself about to write a percentage into a document, run the script instead.

**2. Gate on `$?`, never on the tail of a log.**
`zig build test 2>&1 | tail` swallows the exit code. This has produced a green
report over a failing build in this repository before (`TODO.md §2.1`). In a
pipeline, `exit "${PIPESTATUS[0]}"`.

**3. Diff FAIL *name lists*, not counts.**
A count can stay still while the membership changes. Two agents were only able
to claim "no regressions" honestly because they compared names.
Before and after any change:

```sh
# The build runner TRUNCATES a failed step's output, so grepping `zig build
# benchmark` finds 0 names and reads as a pass. Run the suite binary itself:
cmd=$(zig build benchmark -- --strict zzz-none 2>&1 | grep '^failed command:' | sed 's/^failed command: //')
set -- $cmd; "$1" "$2" --strict > out.txt 2> err.txt      # suite, vera
grep -E '^(FAIL|XFAIL) ' err.txt | sed 's|^\(X\?FAIL\) .*/tests/fixtures/|\1 |; s|:.*||' | sort > after.txt
diff before.txt after.txt          # 0 names means the capture broke, not a pass
```

The same trick applies to `zig build test-devices` (the digital transcripts;
all cases pass as of 2026-09-24 and must keep passing).

---

## 1. Read these, in this order

| Document | What it is | Use it for |
|---|---|---|
| `git show ae9633f1:docs/ROADMAP.md` | the old v1.0.0 roadmap (deleted 2026-10-04 as outdated; a citation of `ROADMAP.md` means this revision) | history only. v1.0.0 is §2 below; open decisions and their work items are `specification/Vague_Decisions.md` |
| `CHANGELOG.md` | every change since v1.0.0, one bullet each (fixes cite their GitHub issue); at each release, `tools/conformance.py`'s measured table under the version heading | what changed and where the project stands; where to add your own bullet (§9) |
| `git show 297e97d^:ARCHITECTURE.md` | target architecture (deleted from the tree); §6 is a 9-phase migration | where a new file goes, and why. All §6 phases have landed (4 and 5 on 2026-09-24: `codegen/plan/`, `codegen/float/`); §4.7's CLI flag table was measured and declined |
| `git show d16471b^:TODO.md` §2 and §4 | expensive knowledge and ground rules (deleted from the tree) | how to run a fixture; the traps |
| `specification/*.html`, `specification/VAMS-LRM-2023.pdf` | the LRM: 20 chapter and annex files | the normative text. Cite by clause number |
| `specification/1364-2005.pdf` | IEEE 1364-2005, a licensed local copy. Gitignored: never commit it, a text extraction of it, or bundle it in a release | the inherited clauses; `tests/fixtures/ieee1364/CLAUSES.tsv` lists its headings |
| `specification/CLAUSE-AUDIT.md` | the clause audit | the definition of `verified` / `partial` / `missing`, and measure B |
| `specification/Vague_Decisions.md` | every implementation-defined choice, every resource limit and its diagnostic, and the open limit defects | what VerA picks where the LRM leaves it open; what to name when you add a buffer or a cap |
| `git show 8b1514d4:<path>` (local tag `audit-docs-2026-09`) | removed audit notes: `docs/conformance-*.md`, `docs/CONFORMANCE.md`, `docs/PLAN.md`, `docs/rules/*.json`, `tests/fixtures/MANIFEST.md`, and each fixture directory's `COVERAGE.md` and `*_SPEC.md` | the history behind a comment that cites one (`<path> at 8b1514d4`). Their open items were carried into `ROADMAP.md` §5 (at ae9633f1) and from there into `specification/Vague_Decisions.md` |

Measurements in older documents are superseded by the latest `CHANGELOG.md`
entry, or by running the commands in §2. When two disagree, the newest wins and
**you say so** rather than picking silently.

---

## 2. The four measures

v1.0.0 is not "the tests pass". It is four independent numbers, and none
reduces to another. Every change you make should say which one it moves.

| | Measure | Command |
|---|---|---|
| **A** | Fixtures behaving as stated | `zig build benchmark -- --strict` |
| **B** | IEEE 1364-2005 clauses with **two-way** evidence; out-of-scope chapters `not-supported` (`CLAUSE-AUDIT.md` §5.7) | `zig build test-1364 -- --coverage` (§§17-18 obligation detail: `CLAUSE-AUDIT.md` §7.1) |
| **C** | LRM clauses with **two-way** evidence | `zig build benchmark -- --coverage` |
| **D** | `ARCHITECTURE.md` §6 phases landed | hand-read against its §6/§8 (`git show 297e97d^:ARCHITECTURE.md`) |

Three consequences you will get wrong if you skip them:

- **A rejection fixture is not positive coverage.** Measure C is the large
  half and most of it is writing *positive* fixtures for rules that already
  work. A clause with only a `//! reject` fixture is one-way.
- **Compiler acceptance is not runtime evidence.** An obligation needs a
  positive behavioural test, an invalid-input test, and a recorded result.
  "It compiles" is the weakest of the three and closes nothing. Neither does a
  kernel unit test alone, a compiled `.c` file, or a SPICE deck paired with a
  JSON file: none of them runs the compiler's output in a host.
- **A refusal needs a legal neighbour.** Isolate the invalid construct, pin its
  named diagnostic, and show a legal variant compiles, so the fixture tells a
  real restriction from a blanket refusal. A rule with no invalid form needs no
  invented rejection; say why in the header.
- **XFAIL markers are implemented, never deleted.** The harness FAILs on XPASS
  specifically so a marker cannot outlive its limitation.

---

## 3. The release ritual

Every version increment is a published GitHub release. There is no other way to
release, and there is no releasing without a measurement.

```sh
# 1. Land your work. Gates green, name lists diffed.
zig build test                       # must pass. This is the gate.
zig build benchmark -- --strict      # must exit 0 (it has since ae9633f1): read the names

# 2. Write the entry. This RUNS the suites; it does not ask you for numbers.
tools/conformance.py --changelog v0.1.0

# 3. Fill in D by hand: the one row the script marks `hand-entered`.
#    Name the document and the date you read. Do not guess.

# 4. Commit, tag, push the tag. CI does the rest.
git add CHANGELOG.md && git commit -m "release: v0.1.0"
git tag v0.1.0 && git push origin v0.1.0
```

`publish.yaml` then re-runs `tools/conformance.py --check v0.1.0` on a clean
runner. **If the tree measures something different from what you committed, the
release fails.** That is the feature. Re-measure, amend, re-tag.

Semver, applied literally: a **minor** (`0.N.0`) changes something a consumer
observes: source VerA newly accepts or refuses, device text it emits, or a row
in `build.zig`'s `module_specs`. A **patch** (`0.N.M`) closes rows without
changing any of those. Every `ARCHITECTURE.md §6` refactor phase is therefore a
patch, because it is byte-identical by construction.

`.github/workflows/bench.yaml` runs on every push and PR. It writes the
torture suite, clause coverage, digital transcripts and the footprint/speed
sweep into the job summary, and uploads the verdicts as an artifact. It **gates** on `zig build test`, `test-1364`, `test-devices`,
`test-vpi-fixtures`, `test-spice`, the cross builds, and the fixture suite
with 0 FAIL and 0 unasserted. Every verdict is gated by **name**: the
ratchet (`tools/conformance.py ratchet`) compares each fixture's verdict with
`tests/fixtures/VERDICTS.tsv`, so a new failure fails, and so does a fixed one
until `ratchet --update` records it. Only the
sweep and the audit-tool self-tests report without gating.

**Nix.** `flake.nix` exports `packages.<system>.default` (`vera`, built from
this tree in ReleaseFast with `-Dcpu=baseline`, as `publish.yaml` builds the
release), one package per release binary (`."1.0.0"`, `latest`),
`overlays.default` (`pkgs.vera`, `pkgs.veraPackages.<version>`),
`apps.default`, `checks` (each package plus a resistor through `vera --check`
in the sandbox) and `formatter` (`nix fmt`), on x86_64/aarch64 Linux and
Darwin (x86_64-darwin imports nixpkgs 26.05). Every package is wrapped with
the Zig its generated code targets and installs its own
`share/vera/contract.zig`; `vera` reads nothing else at run time (the
contract and the `sim` tree are embedded, `sim_sources`). `sources.json` is
written only by `tools/update-sources.py` from the releases and their
`SHA256SUMS`; `publish.yaml`'s `sources` job reruns it and commits to main
after each release. Do not edit it by hand.

---

## 4. Working on the code

**The edit loop is `zig build --watch -fincremental`** (only what changed is re-analysed; never `-fincremental` without `--watch`, which rebuilds everything, nor with a tmpfs `.zig-cache`, which leaves `zig-out/bin/vera` stale).

**Where a file goes** is decided by what it must *import*, not by what it is
about. That rule was learned the expensive way: `ARCHITECTURE.md §8` records a
planned `support/contract.zig` that could not exist, because the assertion it
held needed three modules a bottom-of-stack file cannot import.

`build.zig`'s `module_specs` is the module graph and `defineModules` **panics on
a cycle**. Dependency order is enforced by the build, not by review.

**How a big file is split** (lower/, codegen/, parser/, pp/, proof/, diag/,
elaborate/, tb/, sim/digital/): a sub-file holds free functions that keep
`self: *T` and are called directly, `lower_expr.lowerExpr(self, e)`, the
pattern of Zig's own `src/Sema/*.zig`. The root file aliases ONLY what other
modules call; that alias list IS the module's API. Every file opens with a
`//!` header: its transformation (in → out) and the LRM clauses its code cites.

**Stage outputs are narrow values.** Lowering returns `Lowered`
(`lib/ir/lower/tables.zig`); everything downstream takes `*const Lowered` and
cannot reach lowering's symbol tables. Calls carry a `Mir.Callee` enum
(`lib/ir/callee.zig`); per-opcode facts are columns of `lib/ir/opcode.zig` and
`lib/backend/codegen/opcode_zig.zig`. Add a variant and the compiler names every
site that needs a decision. Never add a string compare or a silent default.

**Exhaustiveness is enforced, not reviewed.** `tests/exhaustive.zig` (part of
`zig build test`) parses lib/ and src/ and fails on any `else =>` over a
boundary enum (Ast/Mir/Callee/token/...) unless the line carries
`// else: <why this is right for every present and future variant>`.

**Refactor phases keep goldens byte-identical.**

```sh
zig build golden -- before     # on the pre-change tree
# ... your phase ...
zig build golden -- after
zig build golden -- diff       # prints IDENTICAL, or exits 1 naming each file that differs
```

One phase = one branch = one PR. Never two phases in flight in `lib/`. No
behaviour changes, no bug fixes, no "while I'm here" inside a phase. Those are
separate commits before or after. **A phase that cannot keep goldens
byte-identical stops and gets re-scoped.**

**Tests move with the code they test, in the same commit.** A split that leaves
tests behind is how coverage silently drops.

**Fix at the root.** `asInt` had ten callers; guarding the crash site would have
left nine able to abort.

**Parse in full, then refuse by clause.** When VerA cannot execute a construct
yet, parse all of it and refuse it with a named diagnostic that cites the
clause. Never open a gate without an executor: "compiled, and the block silently
did nothing" is a wrong answer with no diagnostic, which is worse than a
refusal.

---

**Two dev shells.** `nix develop` is the build shell (Zig 0.17.0, the GPU
toolchains, iverilog and verilator for `test-beh-verilog`).
`nix develop .#benchmarking` adds profiling (perf, flamegraph, inferno) and
the **reference tools** VerA's accuracy is checked against: iverilog,
verilator and yosys (IEEE 1364), ngspice (an OSDI host: VerA's `.osdi` and
OpenVAF's run in the same deck), Xyce, gnucap, and OpenVAF-Reloaded
(`openvaf-r`, wrapped from its release binary in `flake.nix`, x86_64-linux
only). The external suites under `tests/fixtures/external/` run in this
shell; each folder's manifest pins the suite's URL, commit and license.

## 5. SIMD: read this before you optimise anything

**The compiler is not a SIMD target and you are not to make it one.**
Every backend walk is a chain: a dominator-tree walk, a data-dependent output
length, recursive SSA construction. `lib/ir/proof/lattice.zig` carries a measurement
table where a `@Vector` attempt **loses** at every size up to 24578.
`ARCHITECTURE.md §7` lists adding SIMD to the compiler as
deliberately-not-doing.

The compiler's two `@Vector` uses are the right two and are not touched:
`frontend/token.zig` (accumulator over the fixed keyword table) and
`frontend/preprocessor.zig` (single-needle byte scan). A 2026-09-23 re-triage
measured those scans again: nothing else pays.

**SIMD-first applies to the emitted device.** The generated `eval` runs millions
of times inside a host Newton loop; that is the hot loop this project exists to
make fast. The device's SIMD is the scalar family's DERIVATIVE lanes: every
value is `S.Of(mask)`, carrying exactly the lanes of the unknowns it depends
on, and `tools/contract.zig`'s `RefFamily` runs them as
`@Vector(popcount(mask), L)`. The lane decisions (`pinLanes`, `lane_pinned`,
`batch_ok`, `jac_f32`, `cur_strict`) live in `lib/backend/codegen/float/`
(`mode.zig`, `lanes.zig`), whose header says what makes a lane dirty and what
`batch_ok` promises: a family whose value type `V` is a vector of operating
points evaluates a `batch_ok` device exactly per point, which the
testbench's batch family (`tb/runner_text.zig`, `@Vector(NL, f64)`) asserts.

Measured and not built (2026-09):
- Instance lanes (several operating points per SIMD register, `batch_ok`),
  re-measured 2026-10-01 with vector exp/log/pow
  (docs/measurements/batched-instances-2026-10-01.md): when every point of a
  batch takes the same branches, 1.2-2.1× per instance on AVX2 (diode 1.35×,
  mos1 1.42×, bsim4va 1.58×, psp103 2.11× at W = 4; W = 8 spills its tiles
  and gains less). With points spread over regions, divergence and per-point
  value collapses make mos1 and bsim4va 0.37-0.55× and psp103 about 1.0×.
  Since 2026-10-02 diode, mos1, bsim4va and psp103 are `batch_ok` through
  the lead protocol (`batch_lead`, exact per point, divergent batches
  included). The batch key is the `Model` row and the `SimState` only: each
  point has its own `Instance`, read per point through the family's
  `instLane` when the device declares `batch_inst` (held values, `$prev`
  latches; mos1, bsim4va, psp103). A host buckets on the region signatures
  the previous batched call returned (docs/measurements/batched-lead-2026-10-02.md:
  1.06-1.30 runs per W = 4 batch on ARPice's generated decks; coherent
  batches 1.5-1.8× in instructions with per-point instances, mos1 about
  1.0-1.1× in cycles). AVX-512 W = 8 is estimated (llvm-mca,
  calibrated) at about 1.2-1.8×, NEON W = 2 at about 0.8-1.1×. The ABI keeps
  `S.V` and `batch_ok` for it.
- Liveness-coloured hoist slots: bsim4 33% slower (they defeat SROA).
- A no-inline core on the GPU: eval 2× slower.
- `strict` → `optimized` float mode: 0%.

**The hardware knobs stay.** `--unknown-bound=`, `jac_f32` and the `abstol`
table are physical-world tuning. Do not simplify them away. (`--outline-chunk`
was removed 2026-09-23 at the user's request: its GPU motive was DWARF, and
chunking measured 2.8x slower at runtime. See the commit that removed it.)

---

## 6. Fixtures

Run one by hand. `--check` needs **both** flags, and the fixture's own
directory must be on the include path:

```sh
./zig-out/bin/vera --check --contract tools/contract.zig \
    -I tests/fixtures -I <the fixture's dir> <file.va>

# the self-checking testbench, which prints the ok=0/ok=1 lines:
P=$(./zig-out/bin/vera --emit-exe --contract tools/contract.zig \
      -I tests/fixtures -I <fixture dir> <file.va> 2>/dev/null)
"$P"
```

`--emit-exe` prints the path on **stdout** and diagnostics on **stderr**.
Capture them separately or you get an empty path.

**The contract's conformance checks are opt-in.** `contract.validate`,
`validateHost`'s obligations, `checkFamily` and the Debug `su_ok` assert run
only where the root module declares `pub const vera_validate_contract = true`
(`contract.validating`). `zig build test` (`tools/zrunner.zig`), the fixture
suite and `vera --check` always turn them on; a hand-built testbench needs
`--validate-contract`. The ABI check always runs. **A host gets no obligation
checks unless it opts in:** declare the decl in the program's root module, or,
for an `--emit-so` build, in the `dyn` module (the generated shim forwards it).

The header quotes the LRM sentence, derives the expected value **by hand**, then
carries the machine-readable tags:

```
//! lrm 9.4.1
//! bias V(p) = 0.75, V(n) = 0.25
//! reject E0310     <- a SUBSTRING. A bare `//! reject` matches ANY diagnostic.
//!                     Always name the code or a distinctive phrase.
//! reject-run E0816 <- a RUN-TIME refusal: the fixture compiles and runs, and
//!                     the run must exit nonzero (1 unless `//! exit` says) with
//!                     an `error[` line holding each substring, and no other
//!                     `error[` line (always `reject-only`'s rule). Takes a
//!                     `//! neighbour`, `//! checks` and the checks before it.
//! warn W0853       <- the fixture still compiles and runs; each substring must
//!                     match a WARNING. Unnamed warnings pass (W0650 is off
//!                     unless named). `//! nowarn`: this source warns nothing.
//! xfail <reason>   <- "the fixture is right and VerA is not". FAILs on XPASS.
//! checks 6         <- exactly this many ok= verdicts. Derive N from the
//!                     assertions and points, never from a buggy transcript.
//!                     Not allowed with `//! reject`.
```

A verdict is the whole token `ok=1`; `ok=10` fails. Without `//! checks` the
runner only needs a nonempty, all-passing transcript.

Device-table directives assert what a device PUBLISHES to a host, as
`got=/want= ok=` lines: `//! noise` (`corr=<j>:<rho>` states §4.6.4.6's
correlation coefficient with row j, from the rows' shared `source` and the
signs of their `coeff`; a table row's `points=` and `psd=<f>:<S>,...` are read
through `contract.noiseTable` on the derived card), `//! acstim`, `//! qsite` (one line
per §5.6.1.2 charge site, `<row><sign>... lte|nolte`, rows in `U` order),
`//! meta <kind> <name> [desc="..."] [units="..."]` (one per §2.9.2
`decl_meta` row, `contract.DeclMeta`; `//! meta none`), and
`//! abstol <unknown> = v` (the §3.6.1.2 `u_abstol` entry).

**Vendor attributes.** VerA reads five §2.9 attributes. `vera_lte` is a
prefix on an analog statement (`(* vera_lte = 0 *) I(b, s) <+ ddt(qbs);`)
or a suffix on a `ddt` name (`ddt (* vera_lte = 0 *) (q)`, a slot A.8.2 gives
only analog functions and VerA extends). It leaves those charge sites out of
the host's truncation-error check (`q_lte`, `contract.QStamp`). Innermost
wins; the value must fold without the model card (E0523). `vera_interp`, in
the same slots on `absdelay`, picks 1 = linear (default) or 2 = quadratic (E0524).
`(* vera_nodiff *)`, a statement prefix, stores every assignment inside with
no derivative (a SPICE frozen coefficient); `= 0` turns it off inside, the
value folds without the card (E0525), and a contribution inside is E0526.
`(* vera_timepoint *)`, a statement prefix, runs the statement once per
timepoint: the first evaluation at a (`$abstime`, analysis, step flags) runs
it, `eval` stores what it assigned in `Instance` (`tp<b>_*`; the device is
`mutable_eval`), and later iterations read that back. `initState`, `setupInstance`,
`updateState` and `stateCtl(.commit/.revert)` drop the cache, so a rejected
step recomputes it. `= 0` turns it off; the value folds without the card
(E0529). Inside, a probe, `$limit`, contribution, stateful operator, noise
function, event, system task or string assignment is E0530; a value read
from before it that an iteration can move (a probe in a variable, a branch
on one) is E0531; inside a loop, analog function or `analog initial` it is
E0532. Held (§5.10) reads see the accepted state.
`(* vera_scratch *)`, a prefix on a variable declaration (module or named
block; scalars and arrays, real or integer), makes the variable never held:
every evaluation starts it at its initializer, the §3.2 zero when there is
none, so an unwritten slot of a runtime-indexed array reads 0 instead of
what an earlier evaluation left. It is for stacks and scratch buffers the
retention analysis cannot prove written before read; a device whose only
state was such a variable drops to `state_class = .none`. `= 0` turns it
off; the value folds without the card (E0534). On anything but a variable
(parameter, net, genvar, statement) it is E0535; on a variable an `analog
initial` or `@(...)` body assigns and a later read may see, E0536; on one
an `initial`/`always` block or a task assigns (§7.2.2 digital-owned), E0537.
`(* vera_scratch = "uninit" *)` also drops that start: a runtime-indexed
(memory-backed) array gets no initialising store at all, which is what a
64-deep stack of 8-lane duals spends a large part of its eval on (measured
on a 4-op tape, ReleaseFast: 233 → 201 Ir/eval). The author promises every
element is written before it is read in the same evaluation; **a
read-before-write is the author's bug**. Debug/ReleaseSafe devices fill the
array with NaN, value and every derivative lane (minInt for an integer
array), so the bug shows as NaN in the outputs; ReleaseFast/ReleaseSmall
store nothing and the value read is unspecified but stable: an empty
`asm volatile` taking the array's address with a `memory` clobber (no
instructions, CPU and GPU) makes LLVM treat the contents as defined, so the
read is never undef/poison it could exploit. The barrier costs the array's
SROA (116 Ir/eval without it). A scalar or a scalarized array keeps the zero
start (free in SSA). Any other string is E0538; an initializer with `"uninit"` is E0539.

**`$vera_reject_step(t_retry)`.** A VerA system task in an analog block:
on a transient step's accepted solution, `updateState` returns
`.request_reject_at = t_retry` when `t_retry < $abstime` (the earliest of
several calls wins; a static solve ignores it). Such a device emits no
`acceptQ`. The analog testbench undoes the step, solves and accepts
`t_retry`, then solves the rejected time again (`runner_text.retry`); the
mixed and VPI runners refuse a request. In `analog initial` or an analog
function it is E0533.
`--emit-verilog` alone reads two more on declarations: `vera_pin`
(`"digital"`, `"analog"`, `"power"`, `"ground"`) and `vera_delay` (seconds);
`lib/backend/beh_verilog.zig`'s header has the rules.
Every other attribute is parsed and ignored, and every attribute value is a
§2.9 constant_expression (E0357).

**`$limit` arguments.** §9.17.3 names the arguments a string "requires" and
leaves the rest to the implementation. VerA reads, after the algorithm's own,
an optional frame **sign** (`type`; the clamp runs on `sign·v`) and then an
optional **seed**: the value the site's branch starts at in `seed` (SPICE
MODEINITJCT), in the frame of the sign. A seed needs a sign before it (write
`1` for none); more arguments decline the site (W0853).

| algorithm | full call (1-based position of the seed) |
|---|---|
| `pnjlim`, `pnjlimds` | `$limit(V(a,k), "pnjlim", vte, vcrit, sign, seed)` (6) |
| `fetlim`, `fetlimds` | `$limit(V(g,s), "fetlim", vto, sign, seed)` (5) |
| `steplim` | `$limit(V(a,b), "steplim", step, sign, seed)` (5) |
| `limvds` | `$limit(V(d,s), "limvds", sign, seed)` (4) |

Seeded branches are solved into node values from a 0 V root (ground, else the
lowest port, else the lowest net); a pnjlim/pnjlimds leg with no seed starts at
its vcrit, and a fetlimds vgd or pnjlimds vbd leg is never seeded. A seed may
read card-derived variables, never the solution (E0527); one the tree cannot
take is W0854.

`check.vh` gives you `CHECK` (absolute tol), `CHECKR` (relative), `CHECKX`
(exact), `CHECKI` (integer), `CHECKEQ` (two VerA expressions against each
other). **When the LRM states an identity with no digits, assert the identity
with `CHECKEQ`** and say in the header why no digits are written.

**`.c` VPI fixtures** cite with the same grammar, as C99 `//!` lines after the
header comment, with polarity **per line** (one application can assert both a
result and a refusal):

```
//! lrm 12.16          <- a result this clause requires is CHECKed
//! lrm-reject 12.34   <- the routine refusing invalid input is CHECKed
//!                       (error return, vpi_chk_error).
//! inherited IEEE 1364-2005 27.14         <- the same two polarities, for
//! inherited-reject IEEE 1364-2005 27.14  <- measure B. No other key exists.
```

`--coverage` (both `benchmark` and `test-1364`) counts them only for fixtures
in `build.zig`'s `vpi_runs` (they run in-process under `zig build test`). A
`vpi_runs` row with `.xfail = "<stderr text>"` is a known gap: it must exit 1
saying so. A compile-only `.c` is listed as `~`
and moves no number. Tag a clause only where an assertion stands behind it.

### The trap that produces confidently wrong work

**A fixture that a *conforming* implementation fails.** The cheapest way to make
one pass is to break the compiler. Four have been found and fixed here; assume
more exist. Worked examples in `TODO.md §2.4`:

- `$vt` pinned to VerA's own CODATA2018 constant while §9.15 supplies no number.
- `absdelta(V, 0.5)` against a wave stepping exactly 0.5, where §5.10.3.4 fires
  on "**more than** delta". The fixture tested for a bug.
- Seven fixtures assuming a digital-context `integer` starts at 0. §3.2 says
  **x**; only analog-context assignment defaults to zero.
- "The second NBA cancels the first." IEEE 1364 §9.2.2 performs **both**.

So: **before you change the compiler to make a fixture pass, establish that the
fixture is right.** If you withdraw a claim from a fixture, name the row it
moved to.

---

## 7. Things that look done and are not

Checked against the code on 2026-09-27.

- **The mixed-signal path runs, with known limits.** ch07 steps 5-9 landed
  (x/z inputs, A2D crossings with inserted points, named events across the
  boundary, `absdelta`), a flattened child's discrete processes reach the
  runner, §7.8 connect modules run both halves, and §9.22 driver access lives in
  `src/sim/digital/driver.zig`. Not done: an A2D write does not re-solve the
  finished analog point; the next point sees it (`src/sim/mixed.zig`,
  `settleA2d`). A driver's state is one bit, so a vector `signal_name` is
  refused rather than read. `driver_update` does not fire for a connect
  module's own driver: `cm_driver_updates = false` is the user's 2026-09-24
  reading of §9.22.6, and `m04_12` asserts it.
- **The testbench solver is text, not a library.**
  `lib/backend/tb/runner_text.zig` is Zig source emitted into each generated
  testbench, so `src/sim/` cannot call it; the mixed runner drives it through a
  comptime interface. It steps fixed-step backward Euler with no
  truncation-error control and no step rejection, so a fixture can check an
  LTE rule only through what the device publishes.
- **The pure analog testbench is a fixed grid** over the declared `//! time`
  points. It prints the device's next breakpoint but inserts no point. Only the
  mixed runner inserts solver-chosen points (crossings, and timers through the
  optional `pendingBreakpoint` hook). A fixture whose reasoning needs an
  inserted point runs on the mixed path or puts the event on a declared point.
  The exception is `zig build test-spice`: a deck's `//! tran` runs
  `src/sim/spice/` (ESPice's Newton, transient and noise, copied CPU-only):
  ngspice's LTE and breakpoint step control, `$bound_step`, a
  `cross`/`above` flip (`stateCtl(.query)`) cut to 5e-5·tmax, and
  `$vera_reject_step` retries. `//! onoise` is its small-signal noise.
  Both are for generated decks.
- **VPI.** Every `.c` fixture compiles against `src/vpi/vpi_user.h`
  (`zig build test-vpi-fixtures`), and every one runs in-process under
  `zig build test` (`build.zig`'s `vpi_runs`, and `vpi_app.c` under
  `test-vpi`), analog routines, analog task output arguments and `ac` sweeps
  included. The `.xfail` rows of `vpi_runs` are the known gaps.
- **Setup split** (`codegen/plan/setup.zig`) computes solve-invariant values
  once. Array operations are classified per evaluation, so an array filled
  once in `analog initial` is still recomputed every eval. A per-timepoint
  "step" tier was measured and not built: compact models gain 0-16 values each.
- **Known gaps are markers, in both trees.** `grep -rl '^//! xfail'
  tests/fixtures` lists them; `.v` fixtures under `tests/fixtures/ieee1364` carry
  them too. Decisions still to implement are the `CHANGE NEEDED` entries of `specification/Vague_Decisions.md` not marked `DONE`.

---

## 8. If you are running as one of several parallel agents

Learned expensively, and none of it is style preference:

- **Own worktree per agent.** Two in-tree agents plus a main session shared one
  checkout; one ran `git reset --hard` and destroyed uncommitted work.
- **No `Co-Authored-By:` trailers**, and no other AI attribution, in any commit
  message. Every commit is authored and committed by the repository's git user
  (`git config user.name` / `user.email`); never set `--author` to an agent.
- **Stage by explicit path. Never `git add -A` in a shared tree.** `git commit`
  commits the *index*: a docs commit once swept in three unrelated test-file
  deletions and nothing noticed for a session.
- **`cd` to the repo root before anything that writes.** A drifting shell cwd
  landed inside an agent worktree and made four merges appear to vanish.
- **Budget ~12 GB of `.zig-cache` per concurrent agent**, and delete a
  finished agent's cache before the next wave. Six parallel agents filled the
  filesystem and killed a run mid-flight.
- **Size goldens compose.** When two agents each move generated-device byte
  counts in `tests/bench.zig`, the conflict is **regenerated**, not resolved to
  one side. Both deltas are real.

---

## 9. Before you say you are done

- [ ] Your change has a bullet in `CHANGELOG.md` under `## Unreleased`
      (see below).

- [ ] `zig build test` exits 0. Checked `$?`, not a log tail.
- [ ] `zig build test` includes `zig fmt --check` (`zig build fmt-check` alone).
- [ ] FAIL/XFAIL **name lists** diffed (captured as §0 rule 3 shows, not from
      a build-runner log); nothing new entered either.
- [ ] `zig build test-devices` still passes every digital case, and
      `zig build test-vpi-fixtures` still compiles every `.c` fixture.
- [ ] `zig build` AND the suite runner compile, not only `zig build test`:
      `test` does not analyse every path of the CLI or the harness.
- [ ] Changed what `vera` prints, or the contract? `tools/doctest.py` passes:
      the user book (`docs/`) shows real transcripts and CI fails on drift.
      `--update` rewrites them; then re-read the prose around each one.
- [ ] No new `else =>` over a boundary enum without a `// else:` reason.
- [ ] Refactor phase? Goldens are byte-identical.
- [ ] Changed a fixture's expectation? The derivation is in its header and you
      established the fixture was wrong before changing the compiler.
- [ ] Said which of the four measures this moves, and by how much.
- [ ] Every number you wrote came from a command, or names the document and
      date it was read from.

### `CHANGELOG.md`

It starts after v1.0.0 (that release's numbers are its GitHub release notes
and `git show v1.0.0:CHANGELOG.md`). Every change adds one bullet under
`## Unreleased`, in the same commit as the change. Keep it light: one line
saying what a user of VerA would notice. A fix always names the GitHub issue
it closes, as `(#123)`; open the issue first if there isn't one. At a
release, `tools/conformance.py --changelog vX.Y.Z` turns `## Unreleased`
into `## vX.Y.Z — date`, puts the measured table under it above the bullets,
and opens a new empty `## Unreleased`. Only the script writes the table.
