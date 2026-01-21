# VerA performance findings

CPU and GPU performance improvements identified across the whole compiler by an 18-way parallel Codex (gpt-6-astra) audit, September 2026. Findings separate two distinct axes: the speed of the compiler itself, and the speed of the device code it emits — the second matters far more, since emitted code sits in the simulator's inner loop.

## How to read this

Findings were produced by reading the code, **not by running a profiler**.
No timing measurement backs any entry here. Every payoff estimate is a
work-count argument or an order-of-magnitude guess, and the reports say so
per finding. Treat this as a ranked list of *hypotheses to measure*, not a
list of known wins.

Per-area detail — mechanism, proposed change, risk, and payoff reasoning —
lives in `docs/perf/<area>.md`. This file is the index.

**53 findings across 9 areas; 6 touch the GPU path.**

The repo rule still applies: a performance claim ships with a
`zig build bench` before/after in the commit message. Nothing below has one.

---

## IR lowering (`src/ir/lower.zig`)

Detail: [`docs/perf/vera-ir-lower.md`](docs/perf/vera-ir-lower.md)

- Memoize repeated finiteness scans — `src/ir/lower.zig:4186-4251` · CPU
- Index branch reads before checking mixed probes — `src/ir/lower.zig:4336-4361` · CPU
- Index direct contribution accumulators — `src/ir/lower.zig:4642-4682` · CPU
- Pack inlined argument scratch into flat buffers — `src/ir/lower.zig:9032-9079` · CPU
- Cache structural ddt membership — `src/ir/lower.zig:4737-4794` · CPU

## Code generation (`src/backend/codegen.zig`)

Detail: [`docs/perf/vera-codegen.md`](docs/perf/vera-codegen.md)

- Choose chunk boundaries with fewer live values — `src/backend/codegen.zig:2714-2934` · CPU+GPU
- Prepare literal table permutations once — `src/backend/codegen.zig:4007-4034` · CPU+GPU
- Search deep delay history by logical time index — `src/backend/codegen.zig:7051-7105` · CPU
- Render f64 expressions into one temporary buffer — `src/backend/codegen.zig:4148-4266` · CPU
- Index operator instructions by unit — `src/backend/codegen.zig:896-923` · CPU

## Parser and preprocessor

Detail: [`docs/perf/vera-parse.md`](docs/perf/vera-parse.md)

- Prepare macro substitutions once per definition — `src/frontend/preprocessor.zig:577-585` · CPU
- Index declaration names for large modules — `src/frontend/parser.zig:1522-1560` · CPU
- Reuse temporary expression argument storage — `src/frontend/parser.zig:2769-3025` · CPU
- Index physical lines instead of recounting every prefix — `src/frontend/preprocessor.zig:688-701` · CPU
- Search block-comment terminators in byte batches — `src/frontend/preprocessor.zig:887-912` · CPU
- Avoid repeated sized-literal decoding during concatenation — `src/frontend/parser.zig:3390-3428` · CPU

## Lexer, tokens, AST

Detail: [`docs/perf/vera-lex-ast.md`](docs/perf/vera-lex-ast.md)

- Skip keyword classification when recovering token ends — `src/frontend/lexer.zig:109-167` · CPU
- Emit each completed SPICE card before reusing its buffer — `src/frontend/spice_cards.zig:97-148` · CPU
- Index emitted SPICE names when declaration counts justify it — `src/frontend/spice_cards.zig:113-118` · CPU

## IR passes (elaborate, proof, analysis, MIR, SSA, if-conversion)

Detail: [`docs/perf/vera-ir-rest.md`](docs/perf/vera-ir-rest.md)

- Exclude zero-derivative operations from Jacobian dependencies — `src/ir/analysis.zig:735-776` · CPU+GPU
- Cache finite backward slices shared by contribution units — `src/ir/proof.zig:1639-1698` · CPU
- Revisit only affected branches between if-conversion rounds — `src/ir/ifconv.zig:47-131` · CPU
- Index module lookup and incoming instance names once — `src/ir/elaborate.zig:184-231` · CPU
- Reuse the structural analysis across proof and code generation — `src/ir/analysis.zig:179-217` · CPU
- Propagate derivative facts only to affected users — `src/ir/analysis.zig:631-697` · CPU
- Reuse argument-cloning scratch across expression calls — `src/ir/elaborate.zig:1940-2010` · CPU

## Diagnostics

Detail: [`docs/perf/vera-diag.md`](docs/perf/vera-diag.md)

- Avoid formatting diagnostics that will be dropped — `src/diag.zig:987-1079` · CPU
- Pool detached provenance allocations — `src/diag.zig:876-927` · CPU
- Tighten typo-search cutoffs after finding a candidate — `src/diag.zig:1148-1184` · CPU
- Allocate the line-start table once — `src/diag.zig:299-308` · CPU
- Write ordinary text in contiguous runs — `src/diag.zig:1315-1319` · CPU
- Track explanation hints with an enum bitset — `src/diag.zig:1356-1359` · CPU

## Backend codegen helpers (tb, limit, display, orchestrator)

Detail: [`docs/perf/vera-backend-cg.md`](docs/perf/vera-backend-cg.md)

- Emit sweep data once and iterate over it — `src/backend/tb.zig:643-757` · CPU
- Slice the unresolved limiter arguments out of the full core — `src/backend/cg_limit.zig:688-718` · CPU+GPU
- Index eager consumers before fusing statements — `src/backend/unit_plan.zig:553-614` · CPU
- Retain one filter plan per call site — `src/backend/cg_filters.zig:72-146` · CPU
- Reuse split evaluations between differential checks — `src/backend/tb.zig:1060-1090` · CPU
- Stream discarded compiler messages without allocating their bodies — `src/backend/orchestrator.zig:489-523` · CPU
- Resolve limiter ladders once per stable limit list — `src/backend/cg_limit.zig:194-219` · CPU
- Copy literal format runs in bulk — `src/backend/cg_display.zig:477-505` · CPU

## Runtime kernels and CLI

Detail: [`docs/perf/vera-kernels-cli.md`](docs/perf/vera-kernels-cli.md)

- Prepare immutable table ordering and isoline offsets once — `src/backend/table_kernels.zig:48-90` · CPU
- Read file lines in positional chunks — `src/backend/file_kernels.zig:248-282` · CPU
- Reuse bilinear coefficients across Newton evaluations — `src/backend/filter_kernels.zig:19-39` · CPU
- Share each random draw with its seed write-back — `src/backend/rng_kernels.zig:127-188` · CPU
- Trial a GPU guard around inactive junction damping — `src/backend/limit_kernels.zig:60-65` · GPU
- Parse each scan once for all assigned destinations — `src/backend/str_kernels.zig:45-215` · CPU
- Preserve unchanged check-source files for Zig cache reuse — `src/cli.zig:413-421` · CPU

## Tools and test harness

Detail: [`docs/perf/vera-tools-tests.md`](docs/perf/vera-tools-tests.md)

- Drain both compiler pipes concurrently — `tests/external.zig:204-236` · CPU
- Reset scratch memory between sequential fixtures — `tests/harness.zig:238-286` · CPU
- Release each generated benchmark result after its timed sample — `tests/bench.zig:391-415` · CPU
- Share sin and cos range reduction in device tangent evaluation — `tools/contract.zig:307-385` · GPU
- Copy ordinary HTML text in spans — `tests/harness.zig:697-745` · CPU
- Transfer generated failure text instead of copying it — `tests/torture.zig:199-218` · CPU
