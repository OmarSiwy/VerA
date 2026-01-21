# Parser and preprocessor review

Both owned files were read in full, including tests and embedded standard definitions. This is a static review: no build, test, benchmark, or profiler was run. Rankings below are provisional expected opportunities for large, macro-heavy inputs; relative payoff needs measurement. All performance findings are proposals, not implemented optimizations.

| File | Review and applied simplifications |
| --- | --- |
| `src/frontend/parser.zig` | Reviewed and changed: replaced private `containsStr` with the repository's existing `std.mem.indexOfScalar(Ast.StrId, ...)` pattern; merged identical dotted-terminal parsing after ordinary and system-name prefixes. |
| `src/frontend/preprocessor.zig` | Reviewed and changed: shared three identical string scans, reused stdlib ASCII predicates, and replaced the fixed prelude's handwritten module count with `std.mem.count`, retaining its `u32` type. |

Public declarations and exposed fields were retained. No embedded equations, literal values, numeric decoders, bounds checks, or diagnostic guards were changed. The string helper preserves the preprocessor's existing escaped-newline behavior; the lexer and `substitute` have different newline rules and cannot replace it without a behavior change. `isSpace` also stays local: stdlib whitespace includes vertical tab, which this predicate excludes.

Two further reuse candidates were deferred. `Parser.constIndex` duplicates the private `Flatten.constInt` in `src/ir/elaborate.zig`; a shared frontend constant-folder would require a coordinated change outside the owned files and must retain the existing integer operations and division guard. The test-only `expectDeepEqual` overlaps `std.testing.expectEqualDeep`, but the stdlib implementation changes mismatch output and accepts pointer shapes the local helper rejects. Neither replacement is an exact drop-in under this task's behavior constraint. `Parser.kw_stack`'s stored `tok` is not read by the current parser, but its element fields are externally nameable, so it was retained.

These paths preprocess and parse on the CPU. The embedded SPICE definitions feed later compilation, but neither file produces or launches a GPU kernel; there are no GPU findings here.

## Prepare macro substitutions once per definition

- **Where**: `src/frontend/preprocessor.zig:577-585`, `Macro`; `src/frontend/preprocessor.zig:1291-1433`, `expand`; `src/frontend/preprocessor.zig:1503-1551`, `substitute`.
- **Now**: Every function-like invocation scans the same body again, classifies each identifier, and calls `indexOfString` across all formals. It allocates a fresh substitution buffer and then rescans the result in `scan`. The costs are redundant classification and string comparisons across invocations, allocation inside the expansion loop, and copying intermediate text.
- **Change**: At `handleDefine`, record a private flat substitution plan containing literal body spans and formal indices. Preserve first-match lookup for duplicate formal names. Make `substitute` traverse that plan, calculate the expanded length with checked arithmetic, reserve once, and copy spans and actuals. Continue running the existing `scan` on the joined output.
- **Why it is faster**: Identifier classification and formal lookup happen once per definition instead of once per invocation. Reserving the exact output size removes growth and recopying when actual arguments exceed the body length.
- **Est. payoff**: Potentially severalfold on substitution for long bodies reused many times; needs measurement. For U uses, B body bytes and F formals, repeated formal matching can approach O(U B F); a plan removes that repeated F factor. Substitution's fraction of total compilation time is unknown, needs profiling.
- **Risk**: Preserve quoted and escaped identifiers, backtick-prefixed macro names, argument pre-expansion, redefinitions, recursion/depth checks, and source-map segments. Do not pre-expand nested macro names at definition time: their definitions can change before use. Exact-size allocation changes OOM timing, so this was deferred.
- **CPU / GPU / both**: CPU.

## Index declaration names for large modules

- **Where**: `src/frontend/parser.zig:1522-1560`, `checkGenBlockNames` and `nameIn`; `src/frontend/parser.zig:1563-1601`, `parsePortDecl` and `findPort`; `src/frontend/parser.zig:1700-1752`, `parseNetNames`.
- **Now**: Each body port/net declaration searches the entire port array by name. Each generate-block name searches six declaration arrays, genvars, aliases, and earlier generate blocks. This repeats O(P²) port work and O(G D + G²) collision work, while name-only passes pull larger declaration records into cache.
- **Change**: Keep the source-ordered declaration arrays and add a private `Ast.StrId`-to-port-index lookup in `Body`, preserving the first port with each name. For generate checks, build a set from exactly the declaration categories currently checked, and map each block name to its first construct or a mixed-construct state. A name conflicts when its recorded construct differs from the current one, or it already spans multiple constructs. Keep the linear path for small modules until measurements establish a crossover.
- **Why it is faster**: Repeated full-array scans become indexed lookups, and collision checks read compact IDs instead of unrelated declaration payloads. Indices remain valid when the port list grows.
- **Est. payoff**: Potentially an order-of-magnitude improvement in name checks at thousands of ports or named blocks; needs measurement. Little benefit is expected for the small prelude modules. The checks' fraction of total runtime is unknown, needs profiling.
- **Risk**: Preserve first-match port binding, same-construct duplicate permissions, declaration categories, and E0230 order. Do not turn these tables into new semantic validation or alter `Ast.Port`/`ModuleDecl` layouts. Extra allocations and their failure order require validation.
- **CPU / GPU / both**: CPU.

## Reuse temporary expression argument storage

- **Where**: `src/frontend/parser.zig:2769-3025`, `parsePrimary`; `src/frontend/parser.zig:3105-3122`, `parseCallArgs`.
- **Now**: Each call builds a fresh `ArrayList(ExprId)`. Expression-call paths then copy that list into `ExprStore.pool` through `addExprList`. The temporary backing storage remains in the compilation arena. Nested calls repeat these allocations, capacity growth, and intermediate copies.
- **Change**: Give expression-call parsing a reusable `ExprId` scratch list with nested length marks. Parse each nested call into its own suffix, copy the completed suffix through the existing `addExprList`, and restore the mark. Keep arena-owned argument slices for `parseSysTask`, whose AST statement retains the returned slice directly. Preserve the public parser surface when introducing the internal scratch owner.
- **Why it is faster**: Temporary list capacity is reused across completed calls, reducing allocator traffic and retained arena memory. The persistent pool still receives lists in the existing completion order.
- **Est. payoff**: A few percent of parsing is a plausible target for call-heavy models, but needs measurement; it may be negligible on small inputs. Parsing's share of total compilation runtime is unknown, needs profiling.
- **Risk**: Nested expressions must not invalidate a live scratch slice. Restore marks on parse errors and OOM, preserve omitted `.none` slots and pool offsets, and never store a borrowed scratch slice in a persistent statement. Writing directly into the pool during recursive parsing would interleave parent and child arguments.
- **CPU / GPU / both**: CPU.

## Index physical lines instead of recounting every prefix

- **Where**: `src/frontend/preprocessor.zig:688-701`, `Pp.physicalLine` and `currentLine`; `src/frontend/preprocessor.zig:780-821`, `runFile`.
- **Now**: Each `__LINE__` expansion and `line` remap counts newlines from the start of the stripped file to the invocation offset. R requests spread through N bytes cause O(R N) repeated reads, even though `std.mem.count` already vectorizes each individual scan.
- **Change**: Lazily build the existing `diag.LineIndex` over `bag.fileText(cur_file_id)` on the first physical-line request in a file context. Cache it in private preprocessor state, save/restore that state in `runFile`, and use `loc(min(off, text.len)).line`. Continue selecting `expand_site` before lookup and applying the existing `line_from`/`line_to` remap afterwards.
- **Why it is faster**: One O(N) index build replaces repeated prefix scans with O(log L) queries over L line starts. Lazy creation avoids adding a scan to sources that never request a line number.
- **Est. payoff**: Potentially an order of magnitude on line lookup in large files with many `__LINE__` uses; needs measurement. With no such uses the gain is zero. Its fraction of total preprocessing and compilation time is unknown, needs profiling.
- **Risk**: The index must use stripped-file offsets, not raw-file or preprocessed-output offsets. Preserve EOF clamping, include-context restoration, macro invocation anchoring, and remap arithmetic. A lazy allocation adds a failure path and needs separate validation.
- **CPU / GPU / both**: CPU.

## Search block-comment terminators in byte batches

- **Where**: `src/frontend/preprocessor.zig:887-912`, `stripComments`; `src/frontend/preprocessor.zig:1854-1871`, `logicalLineEnd`.
- **Now**: Block comments scan every byte for `*/`, then scan the comment again to count newlines. Logical directive lines also advance byte by byte until backslash or newline. These are scalar searches with a serialized cursor dependency; the surrounding ordinary-text path already uses batched searches.
- **Change**: For comments, use `std.mem.indexOfScalarPos(u8, src, cursor, '*')` to jump between possible terminators, retaining the guarded slash check and existing newline count. For logical lines, reuse `findStop(text, cursor, "\\\n")` to skip ordinary runs, then execute the current backslash/continuation handling. Start with these existing primitives before designing a fused SIMD comment scanner.
- **Why it is faster**: Long runs move through vectorized byte searches instead of one classification per byte. Searching directly for `"*/"` with `std.mem.indexOfPos` does not provide that benefit in the installed stdlib: two-byte needles use its scalar linear path.
- **Est. payoff**: Potentially severalfold on long prose comments or long macro-definition lines; needs measurement. Short comments and frequent stars may see no benefit. These scans' fraction of total runtime is unknown, needs profiling.
- **Risk**: Keep first-terminator/non-nesting behavior, E0102's exact span, comment separator spaces, newline counts, strip marks, and continuation whitespace rules. Retain all bounds checks, especially a final `*` and truncated continuation. No new vector kernel was introduced during this cleanup.
- **CPU / GPU / both**: CPU.

## Avoid repeated sized-literal decoding during concatenation

- **Where**: `src/frontend/parser.zig:3390-3428`, `foldBitConcat` and `sizedLit`.
- **Now**: The first pass calls `sizedLit` for every integer operand merely to determine whether any is sized. The second pass calls it again to fold the bits. Each call rescans token text and invokes `lexer.parseInt`; `parseNumber` already decoded each literal earlier. Replicated operands can cause the same token to be decoded repeatedly.
- **Change**: First stop the detection pass at its first sized operand. If concatenation still profiles hot, retain decoded widths/values in temporary operand-order storage for the fold, or cache by token index for repeated operands. Continue using `lexer.parseInt` as the sole decoder and keep the fold's arithmetic unchanged.
- **Why it is faster**: Early exit removes needless detection work; temporary decode reuse avoids re-reading and re-decoding identical literal bytes. The benefit is confined to concatenation parsing.
- **Est. payoff**: Up to roughly half of the two-pass `sizedLit` calls can be eliminated for all-sized operands with reuse; elapsed-time improvement needs measurement. Total impact is likely small outside concatenation-heavy sources and is unknown, needs profiling.
- **Risk**: Do not diagnose an unsized operand when no operand is sized. Preserve the first E0216/E0217 diagnostic, the 32-bit width guard, signed-literal bits, replication ordering, and every shift/mask operation. A cache must not outlive the token/source storage or change frozen AST layouts.
- **CPU / GPU / both**: CPU.

## Nothing to do

No owned file is wholly without a performance proposal; both are accounted for above. Within `src/frontend/parser.zig`, the token SoA, indexed expression store, and shared numeric/string decoders need no cleanup. Within `src/frontend/preprocessor.zig`, the prelude snapshots, `findStop`, `putNewlines`, and directive tables already implement the relevant reuse and bulk-processing patterns. No additional branchless or GPU change is justified by this static review.
