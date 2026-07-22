# s1-frontcore: the frontend core (U10, U13, U35-U39, U42)

Step-1 notes for `lib/frontend/{token,lexer,integer,ast,ast_expr,ast_decl,
ast_stmt,constfold,wreal,libmap,root}.zig`, written 2026-10-03 against base
`64357568`.

## Spine and ownership after step 1

The frontend core has no spine of its own; it is the tables the parser's spine
(`parseSourceFile`) fills and every later stage reads.

| Table | Owner (file) | Written by | Read by |
|---|---|---|---|
| keyword tables (`keyword_map`, `kw_first`, `kw_len_start`, `keyword_intro`) | token.zig, comptime | nobody at run time | `Lexer.next`, parser (`isReserved`) |
| `TokenList` (`.tag`, `.start` columns) | lexer.zig | `Lexer.tokenizeSeeded` | parser, diagnostics (`tokenSpan`) |
| `StringInterner` (`strings`, `map`) | ast.zig | parser, elaboration, lowering (MIR's own copy) | everyone |
| `ExprStore` (`nodes` SoA, `pool`, `reals`, `ints`, `logic`) | ast_expr.zig | parser, elaboration's clones | everyone |
| statement pool (`stmts`, `stmt_toks`) | ast.zig (rows: ast_stmt.zig) | `SourceFile.addStmt` only | everyone, through `stmt(id)` |
| declaration slices (`ModuleDecl` and below) | ast_decl.zig (layout) | parser (arena slices), elaboration's clones | everyone |
| `Integer.Literal` planes | integer.zig | `integer.parse`, the operators | `ExprStore.logic`, digital sim |
| `libmap.Map` | libmap.zig | `libmap.load` | lib/root.zig |

`constfold.zig` and `wreal.zig` own no table: one is a pure fold over
`ExprStore`, the other a check over the declaration slices that writes only
the diagnostic bag.

## Structural changes

- `ast.zig` (2,076 lines) is split by table. `ast.zig` keeps the handles,
  `StringInterner` and `SourceFile` and aliases every row type (that alias list
  is the module's API, so no caller changed). `ast_expr.zig` holds the
  expression table, `ast_decl.zig` the declaration rows (UDPs and configs
  included) and `natureAttrExpr`, `ast_stmt.zig` the statement rows and the
  statement walks (`stmtEdges`, `stmtWrites`, `lvalueBase`). `SourceFile`
  aliases the walks, so `file.stmtEdges(...)` reads as before. Tests moved with
  their tables; the test-only `SourceFile.addExpr` wrapper is gone.
- `token.isBuiltinFunction` had no caller outside its own test; deleted.
- Doc comments: `integer.parse`'s comment sat on `radixOf` and is back on
  `parse`; the integer operator enums, `KeywordSet.specifier`, `MathFn`,
  `IntContext`, `IntPlan`, `LiteralEnv`, libmap's `Map`/`Library`/
  `declares`/`Error`, the `ExprStore` column reads and `AttributeBinding` now
  say what they are for. References to parser functions name their files.

## Seam proposals

1. **Statement rows without the inline `SeqBlock` (contract pending; all
   owners confirmed).** `Stmt` is 112 bytes because `.block` carries the
   104-byte `SeqBlock`; every other arm is at most 24 bytes. The pool now
   stores a `StmtRow` (32 bytes): the same arms with `.block` holding a
   `BlockId` into a new `SourceFile.blocks` table. `file.stmt(id)` still
   returns the full `Stmt` and `addStmt` still takes one, so every
   `switch (file.stmt(id)) { .block => |b| ... }` and every
   `addStmt(.., .{ .block = blk }, ..)` stays as it is. Only raw access to
   `stmts.items` changes, and that went through two accessors added here:
   `seqBlockMut(id)` and `seqBlocks()`.
   - Expand: `e0e61f89` (this branch).
   - Consumers switched: s1-lower `427b671b` (`lib/ir/lower/param.zig`'s two
     loops, now in `var.zig`), s1-parser `35f31d84`
     (`lib/frontend/parser/generate.zig:277`). No other file reads
     `stmts.items` except `pp/test.zig`, whose deep compare keeps compiling.
   - Contract: `docs/seams/s1-frontcore-contract.patch` (ast.zig and
     ast_stmt.zig only). Apply it after merging both consumer branches; this
     branch cannot carry it, because its own copies of param.zig and
     generate.zig still read the raw rows. Verified on this tree with those
     two consumer edits applied by hand: `zig build`, `zig build test`,
     `test-frontend` exit 0, goldens IDENTICAL.
   - Optional follow-up for s1-pp (told): `pp/test.zig`'s seeded-prelude
     check could also compare `blocks.items`.
   - Measured with the contract applied, against base: peak RSS psp103
     31.54 → 31.11 MB, bsim4va 23.02 → 22.48 MB, hisimhv_va 48.26 →
     47.40 MB; peak mapped memory −0.80 / −1.05 / −2.22 MB; instructions
     unchanged against this branch's head (tables under Memory).
2. **Token lengths: measured, declined.** `tokenText`/`tokenEnd` re-lex a
   token per call. On psp103 `Lexer.next` costs 25.8 M instructions
   inclusive, 16.8 M of it the 107,512-token scan, so re-lexing is about
   9 M of 1,361 M (0.66 %). A length column costs 2-4 bytes a token
   (215-430 KB on psp103), and the parser asks by byte offset, not token
   index, so it would also change `tokenText`'s signature. Not worth it.
3. **`TokenList` capacity guess.** `tokenizeSeeded` reserves one row per 4
   source bytes; the models run at 4.7-6.3 bytes a token (psp103: 541,842
   bytes, 107,512 tokens, 202,779 rows reserved). The unused tail of each
   column is never written, so its pages never become resident (the buffer
   is a `BigArena` large block): virtual size only, no RSS. Left alone.
4. **`SeqBlock`'s generate-only lists.** `events`, `instances` and `gen`
   are empty in every block that is not a generate block (or a digital
   parse's named block, for `events`): 40 of its 104 bytes. Folding them behind the
   existing `gen` pointer would save 40 bytes a block (72 KB on psp103) after
   proposal 1, and touches sim/digital and elaboration. Deferred.
5. **Declaration slices as `u32` start/len.** `ParamDecl` (64 B) and
   `VarDecl` (48 B) carry two and one 16-byte slices. Pool offsets (and a
   `.none` sentinel for `packed_range`) would make them about 44 and 36
   bytes, saving about 36 KB on psp103 (948 + 1,549 rows), against an edit
   at every reader of `dims`/`ranges` in lowering, elaboration, codegen and
   the simulator. Not worth it.
6. **`seedFrom` copies neither `lte_attrs` nor `udps`/`configs`.** The annex
   D/E prelude declares none of them, so nothing is lost today; a prelude
   that grew a vendor attribute or a UDP would lose it silently. Noted, not
   changed.
7. **Parser seam 8 (`ParamDecl`/`VarDecl` arena slack) is the parser's.**
   `ast_decl.zig` only requires decl slices to live in the compile arena;
   an exact-size dupe from a reusable buffer keeps that. s1-parser deferred
   it to step 3 (the module and generate-block lists grow interleaved).

## Memory

Sizes are `@sizeOf` on x86_64; counts are from a throwaway counter (removed)
on `vera --emit-zig psp103.va`.

| type | size before → after | count on psp103 | bytes saved | what changed or why not |
|---|---|---|---|---|
| `StringInterner.map` slot | 21 → 5 B | 8,192 slots (3,640 names) | 131 KB, per table (the AST's and the MIR's) | Keyed by the 4-byte `StrId` through an adapted context instead of a copy of the 16-byte slice `strings` already holds. |
| `Stmt` pool row | 112 → 32 B (`StmtRow`) | 8,239 rows (9,364 capacity) | about 0.56 MB (0.75 MB of rows less a 1,806-row `blocks` table) | Contract pending, see seam 1. |
| `SeqBlock` | 104 B, unchanged | 1,806 | 0 | Moves to its own table in seam 1; its digital-only lists are seam 4. |
| `ExprStore` row (`Node`, SoA) | 21 B, unchanged | 50,875 (53,132 capacity) | 0 | Already SoA. `extra` and `str` are both used by the call tags and `branch_access`; `main_tok` carries every diagnostic. Pinned at 21. |
| `ExprStore.reals` / `ints` / `logic` | 8 / 16 / 24 B | 8,133 / 306 / 0 | 0 | Side tables, already out of the row. `IntLiteral` pinned at 16. |
| `ExprStore.pool` | 4 B | 3,318 words | 0 | `[len, items...]` lists, already flat. |
| `token.Stored` (`TokenList`, SoA) | 5 B a row, unchanged | 107,512 (202,779 capacity) | 0 | See seams 2 and 3. |
| `ParamDecl` | 64 B, unchanged | 948 | 0 | Seam 5. Pinned at <= 64. |
| `VarDecl` | 48 B, unchanged | 1,549 | 0 | Seam 5. Pinned at <= 48. |
| `ModuleDecl` | 352 B, unchanged | 20 | 0 | One per module; 21 slices of declaration lists. |
| `Port` / `NetDecl` / `BranchDecl` | 56 / 64 / 32 B | 54 / 8 / 3 | 0 | Too few to matter. |
| `Instance`, `GateInst`, `SpecPath`, `Subroutine`, `UdpDecl`, ... | 72 / 56 / 72 / 128 / 56 B | 0 on psp103 | 0 | Digital or hierarchical; no rows on the compact models. |
| `AttributeBinding` | 24 B | 2,148 | 0 | One per attribute instance; the slice points into the parser's arena copy. |
| `LteAttr` | 20 B | 0 | 0 | Scanned linearly by `stmtLte`/`exprLte`; few enough. |
| `Integer.Literal` | 24 B | 0 on psp103 | 0 | Planes are one allocation per literal, owned by the store. |
| `lexer.Lexer` | 24 B | 1 per scan | 0 | Stack value. |
| `constfold.Const` / `IntPlan` / `UnsignedCompare` | 24 / 52 / 40 B | stack only | 0 | Values of a pure fold, never stored. |
| `libmap.Map` / `Library` / `Spec` | 32 / 32 / 24 B | 0 without `-libmap` | 0 | Read once per compile. |

Instructions (callgrind, ReleaseFast `-Dcpu=x86_64_v2`, `vera --emit-zig`):

| model | before (`64357568`) | after (this branch, head) | contract applied |
|---|---|---|---|
| psp103 | 1,361.4 M | 1,361.9 M (+0.04 %) | 1,361.9 M (+0.04 %) |
| bsim4va | 988.0 M | 988.2 M (+0.03 %) | 988.2 M (+0.02 %) |
| hisimhv_va | 2,129.2 M | 2,129.8 M (+0.03 %) | 2,129.8 M (+0.03 %) |

The +0.04 % is not the interner (its inclusive cost moved by 15 k
instructions) and is the same with and without the contract; it is within
what a code-layout change moves. The frontend core is not a hot spot:
`Lexer.next` is 1.4 % of psp103 self cost. `stmtEdges` is generic over its
visitor and is inlined into lowering's walks, so callgrind files e.g.
`lower.context.markDiscreteExprs` (2.5 % inclusive) under ast_stmt.zig;
that walk's cost is the visitor's.

Peak mapped memory (massif `--pages-as-heap`, the `-Dcpu=x86_64_v2`
binaries; deterministic, but it counts reserved pages that never become
resident, so it overstates what RSS sees):

| model | before | after (head) | contract applied |
|---|---|---|---|
| psp103 | 50.72 MB | 50.41 MB (−315 KB) | 49.93 MB (−795 KB) |
| bsim4va | 40.98 MB | 40.92 MB (−61 KB) | 39.94 MB (−1.05 MB) |
| hisimhv_va | 69.62 MB | 69.02 MB (−606 KB) | 67.40 MB (−2.22 MB) |

Wall time and peak RSS (ReleaseFast native, `vera --emit-zig -I $M $M/<m>.va`,
7 interleaved runs; time is the best run, RSS the median; the same binary
spreads by about ±0.5 MB run to run, so the head column's RSS is noise):

| model | before | after (head) | contract applied |
|---|---|---|---|
| psp103 | 0.13 s, 31.54 MB | 0.13 s, 31.81 MB | 0.14 s, 31.11 MB |
| bsim4va | 0.10 s, 23.02 MB | 0.09 s, 23.06 MB | 0.09 s, 22.48 MB |
| hisimhv_va | 0.21 s, 48.26 MB | 0.22 s, 48.05 MB | 0.23 s, 47.40 MB |

## Bugs found

None. Seam 6 (`seedFrom` leaving `lte_attrs`, `udps` and `configs` behind)
is latent, not reachable with today's prelude.
