| Measure | Number | Remaining to v1.0.0 | Command |
|---|---|---|---|
| **A** — fixtures behaving as stated | **1564 / 1659 — 94.3%** | 95 rows | `zig build benchmark -- --strict` |
| &nbsp;&nbsp;↳ FAIL · unasserted · XFAIL | 44 · 0 · 51 | all three to 0 | same run |
| **C** — clauses with both citation polarities (static) | **203 / 612 — 33.2%** | 409 clauses | `zig build benchmark -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited | 235 · 39 · 135 | requires rule-level review | same run |
| **B** — IEEE 1364 §§17–18 obligations | hand-entered, see `docs/CLAUSE-AUDIT.md` §7.1 | not measured by this script | source and evidence review required |
| **D** — `ARCHITECTURE.md` §6 phases landed | hand-entered, see `ARCHITECTURE.md` §8 | not measured by this script | architecture review required |
| `zig build test` | **pass** | pass | `zig build test` |
| `zig build test-devices` | **FAIL** | pass | `zig build test-devices` |

`--strict` exit code **1** — 0 only when FAIL, unasserted and XFAIL are all 0.
A and C are measured by this script and nothing else may write them. B and D are
hand-entered against their source documents; if you change one, say which
document you read.

C counts citations without executing fixtures. It is not a conformance score:
XFAILs and implementation-limit rejections can supply citations, and a clause
can contain multiple untested rules. See `docs/CONFORMANCE.md`.
