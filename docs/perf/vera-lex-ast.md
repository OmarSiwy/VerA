# Lexical frontend and AST review

Read the supplied standards, README.md, CONSUMING.md, and all four assigned
source files in full. Reviewed callers and reuse candidates across the repository
and inspected the installed Zig 0.16.0 stdlib. No build, test, benchmark, or
profiler was run. Historical measurements in source comments were not remeasured
and are not estimates for this change.

| File | Review result |
| --- | --- |
| `src/frontend/ast.zig` | Reviewed and clean; unchanged. |
| `src/frontend/token.zig` | Reviewed and clean; unchanged. |
| `src/frontend/lexer.zig` | Removed the duplicate backslash/quote escape arm; the existing fallback performs the identical store and cursor increment. |
| `src/frontend/spice_cards.zig` | Reused `std.ascii.allocLowerString` and `token.lookupKeyword`; retained validation, spelling, allocation ownership, and output ordering. |

Public declarations, fields, enum variants, numeric decoding, and guards are
unchanged. The simplifications have `ponytail:` comments. Everything below is an
unimplemented proposal, ordered by expected compilation payoff: repeated frontend
work first, then costs requiring larger SPICE inputs. Actual payoff and ordering
need profiling. These are CPU compiler routines used during parsing and lowering
toward MIR/SSA, proof, and code generation; none runs in a device kernel.
There is no GPU finding for these files and no
claimed improvement to device evaluation.

## Skip keyword classification when recovering token ends

- **Where**: `src/frontend/lexer.zig:109-167`, `Lexer.next`, `tokenEnd`, and `tokenText`; `src/frontend/lexer.zig:289-295`, `lexIdentOrKeyword`; `src/frontend/token.zig:512-550`, `lookupKeyword` and its scalar fallback.
- **Now**: `tokenEnd` calls `next` and discards its token, so source-level execution classifies an identifier again even though only the final cursor is needed. Parser name reads, numeric adjacency checks, and diagnostic spans call this path. The mechanism is redundant recomputation: repeated keyword-table loads and candidate string comparisons after scanning the identifier bytes. Whether all that work survives optimization is unknown.
- **Change**: First inspect the optimized `tokenEnd` path when centralized verification permits it. If the lookup remains, share `next`'s implementation through a private scanner with a comptime keyword-classification flag. Public `next` selects classification; `tokenEnd` selects extent-only scanning. Both use the same identifier-byte loop and all existing scanners, with the flag bypassing only `token.lookupKeyword`. Preserve the public signatures and the two-column `Stored` representation.
- **Why it is faster**: An extent-only scan needs the identifier boundary but no keyword-table result. Removing the unused classification avoids repeated table and string work without adding a length column or a second grammar implementation.
- **Est. payoff**: Unknown, needs profiling; zero if the compiler already removes the lookup. Otherwise it removes one lookup per identifier extent request. The share of total compilation time spent on those requests is unknown, needs profiling; this contributes no direct device-evaluation cost.
- **Risk**: Scanner divergence could change token spans and diagnostics, especially around malformed input, comments, escaped names, and whitespace inside based literals. Preserve shared scanning and all guards. Compare extent results against the current scanner before adopting. No floating-point operation or GPU ABI change is needed.
- **CPU / GPU / both**: CPU.

## Emit each completed SPICE card before reusing its buffer

- **Where**: `src/frontend/spice_cards.zig:97-148`, `synthesize`; `src/frontend/spice_cards.zig:161-237`, `emitCard`.
- **Now**: `synthesize` lowercases the entire netlist, copies every logical card into a growable buffer, duplicates each completed card except the last, and retains a `cards` array before emitting anything. Even device cards and directives that `emitCard` immediately ignores are copied and retained. The mechanisms are allocation inside the line loop, extra memory writes, and rereading retained card buffers.
- **Change**: Keep one `logical` buffer. When a new non-continuation line arrives, pass the completed buffer to `emitCard`, update `count`, and then clear the buffer while retaining capacity. Flush it once more at EOF. Remove the `cards` array and per-card `arena.dupe`. Before reusing the buffer, copy each successfully emitted bare name into stable arena storage for `seen`; its current entries borrow card text. Keep the lowercase input allocation in this first step.
- **Why it is faster**: This removes one retained copy of nearly every logical card and the array of card slices. Ignored device cards no longer occupy arena storage until compilation ends, and emission reads the recently assembled buffer.
- **Est. payoff**: Unknown, needs profiling. The benefit grows with total logical-card bytes, particularly netlists dominated by ignored device cards; tiny `//! spice` snippets may see no useful change. `synthesize`'s fraction of total compilation time is unknown, needs profiling, and it does no work for empty netlist input beyond the early return.
- **Risk**: Reusing `logical` without owning `seen` names would corrupt duplicate detection. Preserve continuation joining across blank/comment lines, orphan `+` handling, first successful card precedence, exact emitted text, and the empty result when no card is emitted. Allocation order and OOM sites change, so this is deferred rather than claimed as an identical-behavior cleanup. No numerical computation or GPU layout is involved.
- **CPU / GPU / both**: CPU.

## Index emitted SPICE names when declaration counts justify it

- **Where**: `src/frontend/spice_cards.zig:113-118`, `synthesize`'s `seen` list; `src/frontend/spice_cards.zig:174-176` and `src/frontend/spice_cards.zig:235-236`, `emitCard`'s duplicate check and insertion.
- **Now**: Every candidate declaration compares its name with all previously emitted names. For N distinct accepted declarations this performs N(N-1)/2 equality checks. The mechanism is redundant scans and repeated string loads; the list is not used to determine output order.
- **Change**: If profiles show large declaration sets make this scan material, replace the private `seen` list with `std.StringHashMapUnmanaged(void)`, already used for name membership in `parser.zig`. Query membership before emission and insert only after a card has successfully emitted. Continue emitting in input order, never by hash iteration. Retain stable borrowed card storage, or own the key bytes if combined with streaming above.
- **Why it is faster**: Expected constant-time membership replaces a growing scan for each declaration. The current compact list can still win for small N, where hashing and a larger table add cost.
- **Est. payoff**: Expected membership work changes from quadratic to linear in the number of distinct declarations, assuming bounded name lengths and ordinary hash behavior. The cardinality crossover and wall-time improvement are unknown, needs profiling. Its share of total compilation runtime is also unknown, needs profiling; ordinary fixtures may have too few cards to benefit.
- **Risk**: Inserting an unsupported or malformed card would wrongly suppress a later valid card with the same name. Names must remain lowercased and unescaped in the set; `.MODEL` and `.SUBCKT` share the same namespace. Hash growth changes allocation behavior and OOM sites. No numeric or device ABI changes are required.
- **CPU / GPU / both**: CPU.

## Nothing to do

- `src/frontend/ast.zig`: expression SoA, `u32` handles, literal side tables, shared payload storage, and the interner reused by MIR already fit their consumers; retain the bounded nature walk and public declaration layouts without a profile justifying changes.
- `src/frontend/token.zig`: keyword spellings already derive from the enum, and lookup already has a padded SIMD first-byte scan plus scalar reference; retain its bounds masks, early exits before full comparisons, and compact token columns.
