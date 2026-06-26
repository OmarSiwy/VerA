# Roadmap to v1.0.0

This file defines v1.0.0, says how to see where VerA stands, lays out the
releases that remain, and lists what is still open. It holds no measured
numbers. The commands in §2 produce them, and `CHANGELOG.md` records them for
each release (`AGENTS.md` §0 rule 1).

An earlier version of this file carried a 26-rung release ladder, per-release
detail and three appendices of reconciled numbers. Most of those rungs landed on
`main` out of order and without a release being cut. `v0.9.0` is now tagged;
`FUTURE_PLANS.md` tracks the remaining integration queue after it. The old version, and the audit
notes this file's open items came from, are at git revision `8b1514d4` (local
tag `audit-docs-2026-09`). Read one with `git show 8b1514d4:<path>`.

---

## 1. What v1.0.0 means

All of these hold at one commit, and a reader can reproduce each one.

**A. The fixture suite passes over every fixture in the tree.**
`zig build benchmark -- --strict` reports 0 FAIL, 0 unasserted and 0 XFAIL.
`zig build test`, `test-devices`, `test-1364`, `test-vpi-fixtures` and
`test-spice` exit 0. `test-spice` only proves that each deck pairs with its
oracle and compiles. Running a deck needs ARPice (§4).

Zero XFAIL means every marker's gap is implemented. If a marker's fixture is one
that a conforming implementation would also fail, fix the fixture and write the
derivation in its header. Never loosen the compiler to fit it.

**B. Every IEEE 1364-2005 clause VerA implements has two-way evidence; the
rest are classified.** `zig build test-1364 -- --coverage` lists no uncited or
one-way clause that is not classified. In scope: chapters 3 to 13, 14 and 15
as far as VerA models them (specify paths and timing checks are parsed and
visible to VPI), 17 to 20, 26 and 27 (VPI) and Annex A. Out of scope, each
classified `not-supported` in `tests/fixtures/ieee1364/CLAUSES.tsv`
(`CLAUSE-AUDIT.md` §5.7) and refused with a named diagnostic: 16 and §17.2.10
(SDF back-annotation, E1102) and 28 (protected envelopes, E0146). The PLI 1.0
`tf_` and `acc_` routines, 21 to 25, have no text in 1364-2005 (§1.6 removed
it), so they stay `non-normative`, and no source construct reaches them to
refuse. 20, the PLI overview, is VPI's as much as PLI 1.0's and is in scope. The §§17-18 obligations in
`CLAUSE-AUDIT.md` §7.1 are all closed. A closed obligation has a positive
behavioural test, an invalid-input test and a recorded result. "It compiles"
closes nothing.

**C. Every LRM clause has two-way evidence or a classification.**
Every clause that `zig build benchmark -- --coverage` finds in `docs/` is either
tested both ways (a positive fixture that runs and asserts, and a `//! reject`
that pins the prohibition) or classified under `CLAUSE-AUDIT.md` §5 as optional,
implementation-defined, a resource limit, unspecified or non-normative. A
rejection fixture is not positive coverage of the rule it refuses.

**D. All nine `ARCHITECTURE.md` §6 phases have landed**
(`git show 297e97d^:ARCHITECTURE.md`).

**E. The non-mandatory classes carry what `CLAUSE-AUDIT.md` §5 requires.**
Each implementation-defined choice has a document and a test. Each resource
limit is stated and fails loudly with a named diagnostic; the RNG row is the
template. No test asserts one outcome for unspecified behaviour. The list is
`docs/IMPLEMENTATION.md`; its §4 is what remains open.

**F. The binary builds for every supported target.** `publish.yaml`
cross-compiles `x86_64-linux`, `aarch64-linux`, `x86_64-macos`,
`aarch64-macos` and `x86_64-windows`. Every target reads its arguments through
`iterateAllocator`, the one path Zig 0.16 allows on Windows, and a testbench
lands at `<work_dir>/<module>.exe` there. Nothing is run on Windows in CI: the
binary is cross-compiled only. The VPI runtime (`src/vpi/`) does not compile
for Windows: its variadic exports (`vpi_sim_control`, `vpi_printf`, ...) use
`@cVaStart`, which Zig 0.16 disables on `x86_64-windows`, so `zig build test
-Dtarget=x86_64-windows` fails in `vpi` and `vera-vpi-host` alone.

**G. The release names the configuration it was measured on**: the supported
host, API and analyses.

**Not required.** SystemVerilog. IEEE 1364 Annex C utilities. A Verilog-A-only
subset mode (Annex C defines a subset for tools that choose one; VerA does not).
Any ARPice change. Conformance claims for a simulator VerA does not ship.

---

## 2. Where VerA stands

Run these. Do not copy their output into a document.

| | Measure | Command |
|---|---|---|
| A | fixtures behaving as stated | `zig build benchmark -- --strict` |
| B | IEEE 1364-2005 clauses | `zig build test-1364 -- --coverage`, and `CLAUSE-AUDIT.md` §7.1 for §§17-18 |
| C | LRM clauses | `zig build benchmark -- --coverage` |
| D | architecture phases | hand-read; `AGENTS.md` §1 records all nine as landed |

`grep -rl '^//! xfail' tests/fixtures` lists every gap VerA owns and a fixture
pins. §5 lists the ones no fixture pins yet.

Measured by `tools/conformance.sh` on 2026-09-29 at `8bfbc528`, superseding
the 2026-09-27 inventory previously recorded here:

- **A** passes the AMS strict and digital fixture gates. VPI's known gaps
  remain pinned in `build.zig`, and §5 still contains unmarked defects.
- **B and C** have no unclassified citation gaps. Their static inventories
  do not establish runtime conformance for every rule in a cited clause.
- **F** was reported passing for the binary in the preceding session
  (`FUTURE_PLANS.md`, 2026-09-29); final release validation must build it
  again. The VPI runtime on Windows waits on Zig's C varargs there.

**How the long pole gets done.** Each B or C clause needs the clause read, an
expected value derived by hand, and usually the missing half of a pair. The
cheapest way to make such a fixture pass is to break the compiler, and two
adversarial reviews of the earlier repair work each found fresh fabricated
quotations and measurements that did not reproduce. So every new fixture carries
its derivation in its header and is reviewed by someone who opened the clause.

---

## 3. Releases

Every version is a published tag, made with the ritual in `AGENTS.md` §3.
`publish.yaml` re-measures on a clean runner and refuses a tag whose
`CHANGELOG.md` entry disagrees with the tree. `tools/conformance.sh` writes each
entry's numbers; this table never carries them.

Semver, applied literally. A **minor** (`0.N.0`) changes something a consumer can
observe: source VerA newly accepts or refuses, device text it emits, or a row in
`build.zig`'s `module_specs`. A **patch** (`0.N.M`) closes rows without changing
any of those. A refactor that keeps goldens byte-identical is a patch.

### 3.1 The ladder

v0.9.0 is the tree as it stands (§3.2). Each row after it comes from §5 and is
ordered by dependency. A consumer-visible change needs a minor (§3), so the
releases after 0.9 count 0.10, 0.11 and so on; a row with no consumer-visible
change ships as a patch of the minor before it.

| Version | Content | Closes | Gate |
|---|---|---|---|
| **v0.9.0** | The current tree (§3.2) | the old ladder, except what §5 lists | `tools/conformance.sh --changelog v0.9.0`; every `build.zig` step green |
| v0.9.1 | Hygiene: the §5.5 fixture headers, `CLAUSE-AUDIT.md` refreshed (§5.8), the passing fixtures on branch `audit-wip/ch5`, the rollback host wired or deleted, CI builds amdgcn beside nvptx | §5.4 harness rows, §5.5, §5.8 | `--strict` name list unchanged except added fixtures; goldens byte-identical |
| v0.10.0 | Native `.v`: the second static-schedule fork fix, then build time | §5.3 native rows | `test-1364 -- --native` in every mode; `tools/vs-verilator.sh` |
| v0.11.0 | Measure B scoped: the out-of-scope 1364 chapters classified and refused with named diagnostics (§1 B) | the classification half of §1 B | `test-1364 -- --coverage`: no unclassified clause outside the §1 B scope |
| v0.12.0 | Measure A to zero: the AMS and digital XFAILs implemented, and the AMS rows of §5.2 and §5.3 | §1 A; §5.2, §5.3 AMS rows | `--strict` exits 0 |
| v0.13.0 | IEEE 1364 language gaps: net arrays, upward hierarchical references, continuous assignment in a generate block, then §5.2 and §5.3's IEEE rows | §5.2, §5.3 IEEE rows | `test-1364`, `--strict` |
| v0.13.x | Measure B evidence: positive and reject pairs for every in-scope clause. Fixtures only; a defect they find ships in the next minor | §1 B | `test-1364 -- --coverage` |
| v0.14.0 | The Windows port, alone | §1 F | `zig build -Dtarget=x86_64-windows` |
| v0.14.x | Measure C's tail, the §5.7 untested obligations, the implementation-defined list and the resource-limit table | §1 C, §1 E, §5.7 | `benchmark -- --coverage`; each limit fails with a named diagnostic |
| **v1.0.0** | The conformance statement | nothing new | every §1 item holds at one commit |

### 3.2 What v0.9.0 contains

Each line names the file or command that shows it in the tree, and the merge
that landed it.

- **Contract ABI 5**, the only ABI: sparse scalar families, `SimState` by value,
  `batch_ok`. `tools/contract.zig` (`abi_version = 5`); merge `5fe6d9c7`.
- **Native executables for IEEE 1364 designs**, phases P0 to P6, with
  `--schedule=static|fifo`, `--two-state` and `--state=auto|2|4`. Designs the
  native path cannot express fall back to the interpreter with a stated reason
  (`src/sim/digital/emit.zig`). Merges `78e1c8f0`, `3d2cdcfe`, `eb1191c7`,
  `d16aab30`, `51bd3e57`, `5537c634`, `8b1514d4`.
- **Language and build selection**: `--std=SPEC`, `-Dlanguage=verilog|ams`,
  `--zig-backend=auto|llvm|native`, `--optimize`. `vera --help`, `build.zig`;
  merges `7187908c`, `9495baa4`.
- **Digital runtime**: procedural code, file I/O, `$readmem`, PLA,
  force/release, `$random` and `$dist_*` (`src/sim/digital/system.zig`), VCD
  (`src/sim/digital/vcd.zig`), wired-net strength resolution. Merges
  `d16aab30`, `39c71b61`.
- **Mixed signal**: the coordinator and the ch07 steps (`src/sim/mixed.zig`),
  §7.8 connect modules, §9.22 driver access. `AGENTS.md` §7 lists what is not
  done.
- **VPI**: every `.c` fixture compiles, and the ones in `build.zig`'s
  `vpi_runs` run in-process, analog routines included. Merge `7d6c6a9e`.
- **Measure B as a command**: the IEEE 1364 suite split into
  `tests/fixtures/ieee1364/` with its own `CLAUSES.tsv`,
  `zig build test-1364 -- --coverage`, and `//! xfail` on `.v` fixtures.
  Merges `622fae8a`, `63133e1d`.
- **Measure C's bulk**: `zig build benchmark -- --coverage` reports no
  refused-only clause and lists the few one-way and uncited ones by name.
- **Fixture directives and vendor attributes**: `//! warn`, `//! nowarn`,
  `vera_interp`, `vera_nodiff`, and `$limit` seeds (`AGENTS.md` §6). Merges
  `401db13b`, `e73cbb94`, `c6b3a5c7`.
- **All nine `ARCHITECTURE.md` §6 phases** (§1 D).

---

## 4. Blocked on ARPice

ARPice's halves are out of scope and no VerA release waits on them. VerA
emits `u_nodeset` and `noise_tables`, `tools/contract.zig` carries
`PsdTerm.coeff`, and `--spice` reads Annex E decks.

| Item | What ARPice lacks |
|---|---|
| `u_nodeset` (§3.6.3.2) | Nothing reads it (`grep -rn u_nodeset ARPice/src` found 0 hits). Needs `src/analysis/dc/op.zig` and a `seedFn` rewrite in `eval.zig`, so a nodeset reaches `x` and not `lim_x`. |
| `noise_tables` (§4.6.4.3) | Nothing reads it. Five sites: `device_ir.zig`, `eval.zig`, `ac/noise.zig`, `pss/pnoise.zig` and `analysis/tran/tran_noise.zig`. |
| `PsdTerm.coeff` (§4.6.4.6) | ARPice must learn the field, or it keeps reading output noise low by `coeff²` against a default of 1. |
| LTRA / TXL (X01) | No AC stamp. `ltra_native.zig` (CAP 8192) and `txl_native.zig` (CAP 2048) drop samples past capacity. Past CAP a sine deck diverges from ngspice-44.2 by 0.852 V on a 0.5 V signal; under CAP it agrees to 6.3e-5. Needs growable history and the AC stamp. |
| P03 `SystfHost` | ARPice binds none. VerA's own host runs most P03 fixtures in-process (`build.zig`, `vpi_runs`). |
| A10 host decks | The deck runner. |
| ARPice circuit suite | Not a gate. One unchanged tree scored 492, 494 and 518 across runs with byte-identical device code. Do not use it as a conformance signal for either repo. |

---

## 5. Open items

Each row cites where it was found. A cited `conformance-*.md`, `rules/*.json`,
`MANIFEST.md`, `COVERAGE.md` or `*_SPEC.md` is a removed audit note at revision
`8b1514d4`; `git ls-tree -r --name-only 8b1514d4 | grep <name>` gives its full
path. "Found 2026-09-27" means the item was reproduced against that revision
while this list was written. A row with a hand-derivable expected value can
become an `//! xfail` fixture; the rest need a decision or a host first.

### 5.1 Decisions

These need a call, not another agent pass.

1. **Does a labelled regression gate belong in a row whose job is to fail?**
   X01's two `.op` decks, A05 fixture 07, A04 fixture 09, A01 fixtures 06/07 and
   A10's three host decks all pass today and exist to catch a named wrong
   implementation. Answer once for all of them.
   (`tests/fixtures/MANIFEST.md` §5.8 items 1 and 12; items 2 to 6 concern X01
   and A09 files kept in ARPice.)
2. **Can `";2"` carry a dependent selector with no interpolation control?**
   (§9.21, Syntax 9-16.) Fixtures `a05_06` and `a05_07` read the grammar
   differently; an implementer following 06 literally breaks 07. The compiler
   side is settled (`CLAUSE-AUDIT.md` AMS-09).
   (`MANIFEST.md` §5.8 item 8.)
3. **The quotations and mechanism claims the repair pass invented.** Delete
   them, and for A10 ship the §9.17.2 fixture the invention excused. The
   headers still carrying them are listed in §5.5. (`MANIFEST.md` §5.1(b).)
4. **Figures published as measured that do not reproduce.** Re-measure or
   delete. Listed in §5.5. (`MANIFEST.md` §5.1(d).)
5. **Does §17.10 get its own digital row?** §17.9 and §17.11 have one (17.9-14,
   17.11-24) and §17.10 does not, so `$test$plusargs` and `$value$plusargs`
   count as `missing (digital)`. Adding a `17.10-03` row changes B's §17
   denominator. (`CLAUSE-AUDIT.md` §7.5 item 2.)
6. **May `.v` transcript evidence support `verified`?** Four verdicts (17.3-01,
   17.7-01, the digital half of 17.11-01, 17.11-24) rest on
   `zig build test-devices`. (`CLAUSE-AUDIT.md` §7.5 item 6.)
7. **§6.5.7 / §7.8.4: discrete and electrical ports on one undeclared net with no
   connect statement** are accepted. Error, or legal when nothing crosses
   domains? `lrm_7_4_4_1.va` relies on acceptance.
   (`conformance-mixed-signal.md:211-215`.)
8. **§7.4.4 detail discipline resolution.** VerA has basic mode only. Is detail
   mode testable with a mode-selecting runner, or not at all (as
   `lrm_7_4_5.va:6-7` says)? (`conformance-mixed-signal.md:193-201`.)
9. **IEEE §13.2.1.1 vs §4.11: two modules with one name** are accepted and the
   first wins. §13.2.1.1 says the last wins with a warning; §4.11 forbids reuse.
   (`conformance-ieee-config-review.md:32`.)
10. **§5.6.1.3 / A.6.5: a disabled block's contributions already made.** VerA
    keeps them. Nothing decides or pins it. (`a03_SPEC.md:170-177`.)
11. **§3.4.5 vs §6.3.3: is `#(.locked())` on a localparam an error?** VerA gives
    E0907. The only record is
    `tools/parameter-audit-controls/empty_localparam_unresolved.va`.
    (`conformance-empty-parameter-fix.md:184-191`.)
12. **§E.1.2: which SPICE flavour VerA claims** (`PARAMS:`, `{expr}`, nested
    `.SUBCKT`). Only parse limits are recorded, in `lib/frontend/spice_cards.zig`.
    (`h04_SPEC.md:116-119`.)
13. **§F.2.2 "shall be controlled by a simulator option"**: no such option
    exists, and step 5's top-down re-pass is folded into one pass.
    (`annex_f_resolution/COVERAGE.md:16-21`.)
14. **§A.8.8: UTF-8 bytes above 0x7F** are accepted in string literals.
    (`annex_a_syntax/COVERAGE.md:332-335`.)
15. **§9.17.3, Syntax 9-12: `$limit(typ*V(a,k), ...)`**, whose first argument is
    not an access function reference. Error, or the W0853 warning VerA gives
    today? A refusal makes it a minor. (found 2026-09-27.)
16. **A `.v` design as a contract device: implemented.** The device runtime
    is in `src/sim/rt/device.zig`; generated-device host tests pass at
    `15bb97ca` (2026-09-29). Remaining consumer extensions are listed in
    `FUTURE_PLANS.md` §4.

### 5.2 Accepted source the standard forbids

Reconciled on 2026-09-29: the contribution `ddt` tolerance lookup is fixed
(`2bd8ee3e`, E0314 observed for an unknown nature); library-qualified
`liblist` is refused (`461573d2`); function restrictions and automatic-task
NBA/monitor restrictions are enforced (`7bef88f7`, `6d1bf86d`). Their fixture
cases pass in the integrated digital suite. The remaining rows below retain
the unfixed half where an older row combined distinct paths or rules.

| Clause | Item | Source |
|---|---|---|
| AMS 2.6.2 | A scale factor in a digital delay (`#5u`) is accepted and runs as zero delay. | `conformance-lexical.md:158`; found 2026-09-27 |
| AMS 3.4.7 | An `aliasparam` name used in an equation is accepted. | `conformance-parameters.md:36`; found 2026-09-27 |
| AMS 5.10.3.1 | `cross` with `expr_tol` but no `time_tol` is accepted. The `a10_11` header implies the rule is covered. | `conformance-analog-behavior.md:184-193`; found 2026-09-27 |
| AMS 5.10.3.4 | `absdelta` with a negative delta or tolerance, or a non-integer enable, is accepted. `cross` refuses the same (E0516, E0517). | `ch05_analog_behavior/COVERAGE.md:82` |
| AMS 6.4 | A paramset over a module that holds a `defparam` is accepted. | `h01_SPEC.md:133-135` |
| AMS E.3.3 | No warning when a module shadows a SPICE model or subcircuit ("shall issue a warning"); `lib/ir/elaborate/names.zig` calls it optional. | `h04_SPEC.md:120-122` |
| IEEE A.1.3, A.4.1 | An empty `#()` is accepted in a module parameter header and in an instantiation; `#(localparam P=7)` is accepted in a header. | `conformance-ieee-grammar-review.md:69-76,84-87`; found 2026-09-27 |
| IEEE 12.2.2 | Mixed ordered and named parameter overrides (`#(5, .q(7))`) still need verification on the analog path. The digital override/port restrictions are fixed by `b35ab357`. | `conformance-ieee-hierarchy-review.md:42,124`; found 2026-09-27 |
| IEEE 8.1.4 | A UDP table mapping one input combination to two outputs remains to verify. The output-first declaration rule is enforced by `9854a214`. | `d08_SPEC.md:199-204` |

### 5.3 Valid source refused or computed wrong

The named-block `reg` parser restriction is fixed by `4347d32c`, and native
static-schedule fork hangs by `9ac6848b`/`808eb30e`. Their interpreter and
native regression cases pass at `4e90fcdd`.

| Clause | Item | Source |
|---|---|---|
| AMS 9.14, IEEE 17.11.1 | Analog `$clog2` of a negative integer returns 0. The argument is unsigned, so `$clog2(-1)` on a 32-bit integer is 32. | `conformance-ch9-review.md:486-492`; found 2026-09-27 |
| AMS 9.13.1 | `$arandom(7)` gives a different sequence from `$random` seeded with 7; the review derives -2146999808, then 1181502348. | `conformance-ch9-review.md:419-425,452-454` |
| AMS 9.18 | `#(.$xposition(2))` and the other geometry overrides are refused (E0907). The LRM's own example uses this form. | `conformance-ch9-review.md:344-350` |
| AMS 4.2.4 | Integer `%` with a probe-dependent divisor is refused (E0601). | `conformance-expressions.md:77-79` |
| AMS 7.3.1 | E0222 checks the declared bus width, so a legal 31-bit part-select of a wider `reg` is refused. | `conformance-mixed-signal.md:206-210` |
| AMS 3.6.3.2 | A hierarchical nodeset (`electrical top.foo.w = 2.75;`) is ignored without a diagnostic. | `a08_nodeset_SPEC.md:264-269`; found 2026-09-27 |
| AMS 4.6.4.3, A.8.2 | `noise_table` on a parameter slice (`tbl[0:3]`) is refused (E0329). | `a06_SPEC.md:250-252` |
| AMS 4.6.4 | `real w = white_noise(...)` as a declaration initializer exports no noise generator. The assignment form does. | `ch04_expressions/COVERAGE.md:108` |
| AMS 9.20 | A whole-vector analog net reference is refused (E0812). | `a02_SPEC.md:261-264` |
| AMS 5.6.8.2, 6.7.1 | Two instances between the same two nodes share one branch: `I(r1.branch(p,n))` reads the parallel sum. | `h04_SPEC.md:284-292`; found 2026-09-27 |
| AMS 5.10, 3.3 | A string written inside an event body is not held. `lib/ir/lower/param.zig` says nothing can observe it; `$strobe` does. | `a03_SPEC.md:186-189` |
| AMS 5.10.3.4 | The mixed runner reads only `absdelta`'s delta: it ignores `time_tol`, `expr_tol`, enable and the direction-change trigger, and delivers initialization unconditionally. Argument validation alone will not close this runtime gap. | `src/sim/mixed.zig` monitor initialization and `.absdelta` dispatch; read 2026-09-29 |
| AMS 6.6.3 | Same-named instances in two generate blocks collide (E0362). | `ch06_hierarchy/COVERAGE.md:191-193` |
| AMS 6.9.2 | A paramset override that reads a generate block's localparam is refused (E0914). | `ch06_hierarchy/COVERAGE.md:195-197` |
| AMS 7.3.2 | The LRM's `a2d` example with an undriven `dnet` is refused (E0315, E0369). | `ch07_mixed_signal/COVERAGE.md:155-159` |
| AMS 9.15 | `$simparam$str("cwd")` and `("analysis_name")` return `""`. | `a10_SPEC.md:71-73,210-215` |
| AMS E.1.2 | `.MODEL X SW` is skipped and the instance line gets E0904. | `h04_SPEC.md:125-128` |
| IEEE 4.3.1, 5.5.3 | An analog assignment to `reg [3:0]` is not truncated: `~4'b0101` reads -6, not 10. | `annex_a_syntax/COVERAGE.md:416-427`; found 2026-09-27 |
| IEEE 12.2.1, 12.8.2 | A `defparam` path that starts at a module name is refused (E0907) by the analog path. The digital upward/indexed resolution is fixed by `b700311a`. | `conformance-ieee-scope-review.md:47-76` |
| IEEE 17.5.4 | A PLA personality bit `x` is treated as "ignore"; the standard says "worst case". | `conformance-ieee-pla-review.md:58` |
| IEEE 9.7.5 | `@*` over a statement that reads nothing is refused with an E1100 that cites §9.7.5, which has no such rule. | `conformance-ieee-scheduling-review.md:95-98` |
| IEEE A.6.5 | A hierarchical event trigger (`-> u.ev;`) does not parse. | `d04_SPEC.md:211-213` |
| IEEE 17.2.9 | `$readmem` refuses a variable file name and variable start/finish addresses (E1100). | `conformance-readmem-validation-edges.md:66-70` |

### 5.4 Diagnostics and harness

W0651's closed-infinity range check is fixed by `4b87e373`; its warning and
no-warning fixtures pass in the strict suite at `4e90fcdd`.

| Clause | Item | Source |
|---|---|---|
| AMS 3.2 | E0311 cites "LRM 3.2.2", which does not exist, and its explain text says every array access must resolve at compile time. | `a01_SPEC.md:61-62` |
| AMS 9.11 | E0806's explain text, and `134_signed_analog_rejected.va:1-4`, quote the pre-2023 §9.11. | `a01_SPEC.md:405-414` |
| AMS 6.3.3 | Overriding an ordinary parameter twice reports the aliasparam message (E0908). | `conformance-empty-parameter-fix.md:134-135` |
| AMS 5.9.3 | `break` in an analog `for` is refused as "outside a loop" (E0404). | `ch05_analog_behavior/COVERAGE.md:85` |
| AMS A.6.4 | `force`, `fork`, `wait`, `#5` and analog `forever` all get the generic E0209. | `annex_a_syntax/COVERAGE.md:278-282` |
| AMS 4.5.12 | A non-zero τ or t0 on `zi_*` gets the generic "codegen refused". | `ch04_expressions/COVERAGE.md:93` |
| harness | A second `//! analysis` line silently replaces the first. | `ch09_system_tasks/COVERAGE.md:56,67` |
| IEEE 18.1.5 | `vcdTokens` drops `$version` and `$comment`, so the `$dumplimit` comment and version text are never checked; a semantic VCD comparison would have to be added to `harness.vcdTokens`. | `conformance-vcd-review.md:39-42,155-159` |
| fixtures | Branch `audit-wip/ch5` (`59da3dcd`) holds ch09 fixtures that were never merged, including ones for the `$arandom`, `$clog2` and geometry rows above. | found 2026-09-27 |

### 5.5 Fixture headers to correct

Test data, not compiler work. Each header claims something false or stale.

- `s01_05` and `s01_06` quote "the initial_step event is active on the first
  point of an analysis", which is not in the LRM. `m02_04:77-78` misquotes §3.2.
  `p03_vpi_analog.h:52-53` says §12.2 defers to Annex G; only §12.31 does.
  `a08_nodeset_02:39-47` carries an invented grammar path. (`MANIFEST.md` §5.1(b),
  :372-395.)
- Figures and transcripts that do not reproduce: `h04_03:79-80`, `h04_04:38`,
  `a01_08:29`, `a02_01:51`, `h01_06:67`, `h04_10:43-45`, `m01_05:50-52`,
  `m01_08:50-51`. Overreaching quotes: `d04_04_named_event_has_no_memory.v:4`,
  `a10_12:7`, `a10_04:19`. Wrong clause: `s01_01:72` (§4.2.5 for a string `==`),
  `a06_ac_stim_ac_analysis.va:26` (`M_PI` is D.2). (`MANIFEST.md:426-485`.)
- `m01_10` tags `//! lrm 7.3.4` for an `always @(absdelta ...)`, which is §7.3.5,
  and calls itself latitude-free although a tool may choose `time_tol`.
  (`MANIFEST.md:416-418,520-524`.)
- `a03_01`, `a03_02`, `a03_03` and `a03_11` rest on IEEE 1364 §10.3 `disable`
  and carry no `//! inherited`. ch10 fixtures 58 to 61 lack
  `//! inherited 19.9`, and several files cite `` `unconnected_drive `` as
  §19.10 (it is §19.9). `d10_11` cites §7.11 and §3.7 wrongly. `d03_10:20-29`
  cites §12.3.6 (port connection by name) for the port-size rule.
  (`MANIFEST.md:572-583`; `d10_SPEC.md:210-231`; `d03_SPEC.md:133-143`.)
- Tables 9-1, 9-2, 9-3, 9-7 and 9-11 sit in §9.2, but fixtures file them under
  §9.4.1, §9.5, §9.6, §9.10 and §9.14. (`MANIFEST.md:585-587`.)
- Checks that cannot fail: `a06_psd_white_flicker_export.va:63,66` and
  `a06_noise_table_array_parameter.va:67-68`. (`MANIFEST.md:729-733`.)
- `a04_10` applies §4.5.12's "unity transfer function ... exhibits no delay" to
  `1/(1-0.5z^-1)` without saying it extends the sentence. (`MANIFEST.md` §5.8
  item 9.)
- `s01_01` says its two `%g` derivations agree; under §9.4.3's own example gloss
  ("three fractional digits") row 1 is `1234.5678`, which VerA prints. Decide the
  reading, then fix the header. (`MANIFEST.md` §5.8 item 10.)
- Fixtures 177 to 180 and 184 assert VerA-specific `$limit` trajectories under
  normative `//! lrm` tags; callbacks 177 to 180 skip `$discontinuity(-1)`.
  (`conformance-ch9-review.md:376-394`.)
- `a03_04:23-24` and `a10_03:29-30` claim timer times exact to the step; §5.10.3.3
  allows "at or just beyond". `event_cross_falling.va` starts on the threshold,
  `event_cross_any.va` runs DC only, `analog_initial.va` cannot tell once per
  analysis from once per evaluation, and `nature_attribute_unsupported.va`
  still tags `lrm 11.6.2`. (`conformance-analog-behavior.md:147-215`.)
- `lrm_7_2_4.va:8` says p and q are "on the same signal"; a resistor joins two
  nodes. (`conformance-mixed-signal.md:178-191`.)
- `abstol_override_branches.va:20-29` says `p.potential.abstol` does not parse;
  it does. (`conformance-standard-definitions.md:23`.)
- `025_type_conversions.va` and `122_bit_conversions.va` say VerA implements
  neither `$rtoi` nor `$itor`; it implements both. (`exhaustive/COVERAGE.md:83`.)
- `09_nonlinear_nr_relationship.va:21-23` says VerA "adds" NIST2018; D.2 already
  has it. (`annex_h_glossary/COVERAGE.md:14-15`.)
- `14_predefined_compact_modeling.va:17-21` says a tool that never defines the
  macro conforms, against §10.5's "if and only if". (`d10_SPEC.md:355-372`.)
- `d10_07:34-40` says `` `resetall `` removes user macros (E0115). It does not,
  and IEEE §19.6 says it must not. (found 2026-09-27.)
- `p03_dc_divider.va:34` and `p03_ramp_load.va:36` say the circuit does not solve
  and an xfail records why; both solve and carry no xfail. The
  `a08_nodeset_01`/`02` "why it fails today" paragraphs describe passing files.
  (found 2026-09-27.)
- Reject substrings that pin wording, not behaviour: `d03_13` and
  `d08_reject_udp_z_output.v:49`. (`MANIFEST.md:533-539`.)

### 5.6 Readings the standards leave open

Settle each before a fixture asserts one side.

- AMS 2.7 vs A.8.8 and Annex G change 2535: are multiline strings legal? VerA
  refuses them (E0138) on §2.7 alone. (`conformance-strings-ledger-independent-review.md:30-61`.)
- AMS 2.3 vs 2.7: is a raw TAB legal inside a string? (same file :63-77.)
- AMS 2.9: with `op` absent, is the value in the operating-point report? Does
  `units` being reserved license other keywords as attribute names?
  (`conformance-attributes-ledger-independent-review.md:33-43`.)
- AMS 3.4: forward parameter reference. `58_forward_parameter_reference.va` pins
  E0314 as settled. (`conformance-parameter-core-ledger-review.md:43-45`.)
- AMS 4.3.1: `min`/`max` with NaN or signed zero. VerA picks the second operand
  when unordered. (`conformance-minmax-ledger-review.md:97-102`.)
- AMS 8.2 vs 8.4.1: §8.2 applies nodesets after `analog initial`, §8.4.1 before.
  (`conformance-scheduling.md:35`.)
- AMS 8.3.3 vs 5.10.3.3: does an `@()` body run once per timepoint or once per
  Newton iteration? `a03_04`, 05, 07, 10 and 12 assume per timepoint.
  (`a03_SPEC.md:284-291`.)
- AMS 8 example vs IEEE 9.2.2: the example's cancellation of a queued assignment
  against driver look-ahead and transition filtering (`ch8-scheduling.html` note).
- AMS 9.16: a `$simprobe` name built at run time never resolves. The fallback is
  not "the LRM's own cover" if the name is valid. (`conformance-ch9-review.md:313-316`.)
- AMS 9.21: may a tool refuse at elaboration a duplicate abscissa whose dependents
  it cannot prove equal? `a05_13` argues it out. (`MANIFEST.md:529-532`.)
- AMS 3.7: `m04_03` says 0.0 to -0.0 fires no event (IEEE-754 `==`); the inherited
  definition of a real "change" is unchecked. `m04_01` samples a wreal at time 0
  from an `initial` block, a possible race. (`conformance-wreal.md:15,29-34`.)
- AMS Syntax 5-13: `posedge V(p)` is refused (E0704) although the grammar
  derives it. (`annex_c_analog_subset/COVERAGE.md:192-196`.)
- AMS A.2.8: a module-level `string` is accepted with no Annex A derivation.
  (`annex_a_syntax/COVERAGE.md:349-358`.)
- IEEE 5.5.4: does "a signed x/z operand gives all-x" apply to bitwise and
  conditional operators? VerA follows the bitwise tables.
  (`conformance-ieee-expression-width-review.md:82-88`.)
- IEEE 6.1.3: which delay rule a singleton `[0:0]` vector continuous assignment
  takes. (`conformance-vector-delay-fix.md:20-24`.)
- IEEE 13.2.2 vs A.1.1 and Syntax 13-2: "The syntax of a lib.map file is
  limited to library specifications, include statements, and standard Verilog
  comment syntax", while both syntax boxes derive a config_declaration as a
  library_description. VerA refuses a config in a map (E0244).
- IEEE 17.2.9: `$readmem` address policy. `@8` into `[0:3]` with no task bounds
  loads nothing and says nothing; x/z/underscore in addresses is undecided.
  (`conformance-readmem-validation-edges.md:66-70`.)
- IEEE 18.4.3.2: strength 5 is "large" in the prose and "pull" in the list.
  (`conformance-vcd-review.md:137`.)
- IEEE 19.6, 19.11: does `` `resetall `` reset `` `begin_keywords ``? (`d10_SPEC.md:192-194`.)
- IEEE 26.2.4 vs AMS 12.33.2: `tests/vpi_app.c` walks the design inside
  `vlog_startup_routines`; IEEE allows only registration there.
  (`conformance-ieee-vpi-interface-review.md:24-31`.)
- IEEE 26.3.5 vs Annex G: `vpiIsProtected` or `vpiProtected`. Neither is
  declared. (`conformance-ieee-vpi-interface-review.md:65-70`.)
- IEEE 26.6.40(c) vs AMS 11.6.25 note 5: whether the current time queue comes
  before or after read-only synchronization. (`conformance-ieee-vpi-objects-review.md:179-186`.)
- AMS 11.6.25, 12.16, 12.27: `p02` conventions set by fiat. The time-33
  callback-only entry in `vpiTimeQueue`, `vpi_mcd_printf`'s return for a
  multi-channel write, and `vpiIntVal` on a 64-bit object (never asserted).
  (`p02_SPEC.md:341-343,382-395,426-427`.)
- Implementation choices still to add to `docs/IMPLEMENTATION.md` §1 with a
  fixture: `"\q"` is accepted (AMS 2.7); `$q_exam` returns status 2 for an
  unknown code, code 3 reports the observed peak, and means use integer
  division (IEEE 17.6.4). (`conformance-ams-lexical-core-review.md:170-172`;
  `conformance-ieee-queue-review.md:26-47`.)

### 5.7 Untested

No fixture pins these. Each is measure B or C work.

- AMS 1.3.4: a signal-flow net bound to a conservative node across an instance. (`ch01_intro/COVERAGE.md:69,73`.)
- AMS 2.9, 2.9.1: attributes on a continuous assign, `always`/`initial`, instance,
  port connection, generate block or function port. The attribute obligations
  AMS-ATTR-LAST, -DEFAULT, -DESC-HELP, -OP-YES and -MULT-NONE (report metadata).
  (`ch02_lexical/COVERAGE.md:95-116`; `docs/rules/ams-attributes.json`.)
- AMS 3.2.1, 3.4.3, 3.6.3.1: `(* desc, units *)` on a module variable,
  parameter or net; host-visible export of output variables. (`ch03_data_types/COVERAGE.md:227`; `conformance-types.md:35-36`.)
- AMS 3.11.1: the Domain, Domainless and Natureless rules (E0355 exists). (`ch03_data_types/COVERAGE.md:214`.)
- AMS 4.3.1: the derivative of `abs` at 0 is -1. (`conformance-minmax-derivative-fix.md:89`.)
- AMS 4.5.14: the other dynamic-argument slots and analysis restarts. (`ch04_expressions/COVERAGE.md:99`.)
- AMS 4.6.4.6: anti-correlation. `//! noise` has no `coeff=` field. (`a06_SPEC.md:253-255`.)
- AMS 7.2.4: smallest abstol over a node. (`conformance-mixed-signal.md:178-191`.)
- AMS 7.3.3, 7.3.6.3: a continuous variable read from a discrete context,
  interpolated, or exact after an analog event. (`m01_SPEC.md:199-203`.)
- AMS 7.3.5: a same-value reassignment of an analog-event variable still fires. (`conformance-mixed-signal.md:252-253`.)
- AMS 8.4.4 (Figure 8-6), 9.23: an analog `@(b_dig)` across one tick's 1-0-1
  transit. (`m02_SPEC.md:242-250`; `m04_SPEC.md:209-228`.)
- AMS 8.4, 8.5: `#0` deltas across the A/D boundary, `$monitor` against analog
  solves, and §8.5.3.7's one-evaluation-per-tick count. (`m02_SPEC.md:234-259`.)
- AMS 9.17.2: `$bound_step(1.0/0.0)` compiles. Refuse it, or read it as no bound? (`a01_SPEC.md:193-195`.)
- AMS 9.21.1: a per-instance table snapshot, and capture around a rejected step
  (needs a host netlist). (`a05_SPEC.md:109-112`.)
- AMS D.1, D.3: the standard natures' abstol and units defaults, `Acc`/`Imp`/`Alpha`,
  the `idt`/`ddt` nature links, guard idempotence. (`annex_d_standard_definitions/COVERAGE.md:38-59,109-133`.)
- AMS Annex B: keywords used as parameter, label, genvar, branch, function,
  nature or instance names (E0208 today). (`annex_b_keywords/COVERAGE.md:133-150`.)
- AMS E.2.2.1, E.3: default `inout` direction; the `Q2` omitted-port form. (`annex_e_spice/COVERAGE.md:270-299`.)
- AMS F.2.1 step 4.a: the continuous domain winning; digital behavioural code
  classifying a net digital. (`annex_f_resolution/COVERAGE.md:90-100`.)
- AMS G.2 item 12: the retired `real [0:3] x;` spelling (E0208 today). (`annex_g_change_history/COVERAGE.md:161-163`.)
- AMS A.1: a library map binding an analog (`.va`) design. `vera --libmap`
  binds a `.v` design's cells (IEEE 1364 §13); an analog compile reads no map
  and its configurations bind nothing (W0253) (A-EVID-001).
  (`annex_a_syntax/COVERAGE.md:83`.)
- AMS 11, 12: the VPI obligation backlog (VPI12-* rows).
  (`conformance-ch11-review-draft.md`, `conformance-ch12-review-draft.md`.)
- IEEE Annex G: declarations absent from `src/vpi/vpi_user.h`: the
  `PLI_*`/`PROTO_PARAMS`/`XXTERN`/`EETERN` macros, the `VPI_USER_H` guard, and
  the constant names `ieee_pli/b_G_vpi_user.c` counts.
  (`conformance-ieee-annex-g-review.md:28,41`.)
- IEEE net initialization: a net reads `z` before its only delayed driver
  delivers. (`d06_SPEC.md:128-132`.)
- IEEE 7: `tranif0`, `rtranif0`, `rtranif1` and resistive weak-to-medium
  reduction. (`d08_SPEC.md:181-192`.)

### 5.8 Documents to correct

- `CLAUSE-AUDIT.md` §4.4 rows 18.1-01 to 18.2-07 say "missing", but
  `src/sim/digital/vcd.zig` exists and `d09_11`/`d09_12` pass. Row 17.2-21 says
  excess `$readmem` data is silent; W1150 now warns. (found 2026-09-27.)
- LRM HTML: Syntax 2-4 to 2-10 lack the literal-vs-metasyntax markup
  (`conformance-ams-attributes-review.md:17-19`). Table 5-1's
  `final_step("tran")` DC-sweep cell has no note
  (`conformance-analog-behavior.md:130-134`). Chapter 12's source anomalies
  (type and constant spellings, `s_vpi_delay` vs `s_vpi_time`, channel vs mask,
  the NULL `vpiTimeUnit` conflict with §11.6.1) have only five notes
  (`conformance-ch12-review-draft.md:59-75`). AMS §12.36 sends `vpiReset` to IEEE
  "F.7" (it is C.7) and §12.5 says "Annex C" for Annex G
  (`conformance-ieee-informative-disposition.md:81-93`).
- IEEE 1364-2005 errata that change how a fixture is written: `vpiObjectVal`
  vs `vpiObjTypeVal` (27.14); `vpiIndex` vs `vpiPortIndex` (26.6.5(d));
  `vpiPorts` (26.6.6(d)); the `vpi_get(vpiExpr)` example (26.2.5); r/r+ vs
  Table 17-7 (17.2.4); a "synchronous" example calling `$async$and$array`
  (17.5); config in `library_text` (Syntax 13-2); a missing colon (Syntax 5-2)
  and parenthesis (Table 8-1, Syntax 12-1); 300,000 for `3E6` (6.2.1 Example 4);
  Annex H typos. (`conformance-ieee-vpi-routines-review.md:87-97` and the review
  files it lists.)
- Normative sources not in the repository: IEEE 1497-2001 (SDF, behind IEEE §16),
  the IEEE 1800 edition AMS §4.2.14 and §5.7 import, and the FIPS and RFC
  documents behind IEEE §28. (`conformance-audit-queue.md:75,162`;
  `conformance-ieee-authority-review.md:29-44`.)
