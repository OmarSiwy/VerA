## v0.9.0 — 2026-09-27

| Measure | Number | Remaining to v1.0.0 | Command |
|---|---|---|---|
| **A** — fixtures behaving as stated | **1986 / 1992 — 99.7%** | 6 rows | `zig build benchmark -- --strict` |
| &nbsp;&nbsp;↳ FAIL · unasserted · XFAIL | 0 · 0 · 6 | all three to 0 | same run |
| **C** — clauses with both citation polarities (static) | **487 / 612 — 79.6%** | 4 clauses | `zig build benchmark -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited | 3 · 0 · 1 | requires rule-level review | same run |
| &nbsp;&nbsp;↳ classified under `CLAUSE-AUDIT.md` §5 (`CLAUSES.tsv`) | 121 | reviewed claims, not evidence | same run |
| **B** — IEEE 1364-2005 clauses with both citation polarities (static) | **25 / 808 — 3.1%** | 733 clauses | `zig build test-1364 -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited · classified | 147 · 8 · 578 · 50 | §§17–18 obligation detail: `docs/CLAUSE-AUDIT.md` §7.1 | same run |
| **D** — `ARCHITECTURE.md` §6 phases landed | **9 / 9** (hand-entered: `git show 297e97d^:ARCHITECTURE.md` §6, read 2026-09-27 against the tree; phase 0's `support/contract.zig` is `tools/contract.zig` per its §8, and phase 7's `cli/args.zig` was measured and declined per `AGENTS.md` §1) | 0 | architecture review required |
| `zig build test` | **pass** | pass | `zig build test` |
| `zig build test-devices` | **pass** | pass | `zig build test-devices` |

`--strict` exit code **1** — 0 only when FAIL, unasserted and XFAIL are all 0.
A, B and C are measured by this script and nothing else may write them. D is
hand-entered against its source document; if you change it, say which document
you read.

B and C count citations without executing fixtures. It is not a conformance score:
XFAILs and implementation-limit rejections can supply citations, and a clause
can contain multiple untested rules. See `docs/CLAUSE-AUDIT.md`.

