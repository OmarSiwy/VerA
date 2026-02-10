# CHANGELOG

Every tag is a release, and every release states how far VerA is from v1.0.0.
`ROADMAP.md §1` defines v1.0.0 as four measures; each entry below reports all
four, and the two that a command can answer are **measured, never typed**.

Entries are written by `tools/conformance.sh --changelog vX.Y.Z`, which runs
the suites and fills in the table. `.github/workflows/publish.yaml` re-measures
on the runner and refuses to publish a tag whose entry disagrees with the tree,
so a percentage here cannot go stale without the release failing.

Read a row as: *measure · where it stands · what is left · the command that
says so.* A number with no command beside it is hand-entered, and the entry
says which document it came from.

## v0.0.1 — 2026-09-21

| Measure | Number | Remaining to v1.0.0 | Command |
|---|---|---|---|
| **A** — fixtures behaving as stated | **1495 / 1558 — 96.0%** | 63 rows | `zig build benchmark -- --strict` |
| &nbsp;&nbsp;↳ FAIL · unasserted · XFAIL | 35 · 0 · 28 | all three to 0 | same run |
| **C** — clauses with two-way evidence | **196 / 612 — 32.0%** | 416 clauses | `zig build benchmark -- --coverage` |
| &nbsp;&nbsp;↳ accepted-only · refused-only · uncited | 257 · 76 · 83 | all three to 0 or classified | same run |
| **B** — IEEE 1364 §§17–18 obligations | hand-entered: **36 / 119 closed** (83 open; only 30 `verified`) | 83 rows | `docs/CLAUSE-AUDIT.md` §7.1, measured 2026-09-16 |
| **D** — `ARCHITECTURE.md` §6 phases landed | hand-entered: **2 / 9** (phases 0–1) | 7 phases | `ARCHITECTURE.md` §8, 2026-09-20 |
| `zig build test` | **pass** | pass | `zig build test` |
| `zig build test-devices` | **FAIL** | pass | `zig build test-devices` |

`--strict` exit code **1** — 0 only when FAIL, unasserted and XFAIL are all 0.
A and C are measured by this script and nothing else may write them. B and D are
hand-entered against their source documents; if you change one, say which
document you read.

**The re-baseline.** `build.zig.zon` said `0.9.0` and nothing had ever been
tagged — 323 commits, zero tags. This is the first release VerA ships and it
ships honestly: 96.0% of fixtures behave as stated, but only 32.0% of LRM
clauses carry evidence in both directions, which is the number that governs
v1.0.0. See `ROADMAP.md §5`.

**Measure B and C are unverifiable at this tag.** `docs/CLAUSE-AUDIT.md` is
deleted from the working tree (recoverable at `git show
55e5117:docs/CLAUSE-AUDIT.md`) and its 2026-09-16 numbers were taken on a
1301-fixture tree. The `--coverage` run above already contradicts them: it
measures 612 clauses and 196/257/76/83 where the audit recorded 611 and
148/208/99/156. Restoring and re-deriving it is release v0.0.2.

