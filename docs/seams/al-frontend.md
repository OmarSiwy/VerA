# al-frontend: ArrayList audit of the frontend and diag

Files: `lib/frontend/**`, `lib/diag.zig`, `lib/diag/**`, `lib/big_arena.zig`.
Written 2026-10-03 against base `5968850a`.

## ArrayList

Lists another unit fills or reads by field keep their shape:

| List | Read by | Why it stays a list |
|---|---|---|
| `Bag.records` | `lib/ir/lower/test.zig` (`bag.records.items`), `detach` (`fromOwnedSlice`) | Bounded by `max_entries` (64); now reserved once at 64 on the first row instead of grown. A fixed `[64]Record` would put 10 KB in every `Bag` by value. |
| `Bag.string_bytes`, `Bag.files` | `render`, `detach` | Input-driven (message text, `include count). |
| `Ast.SourceFile` tables (`strings`, `stmts`, `blocks`, `stmt_toks`, `lte_attrs`, `attributes`) and `Exprs` pools (`pool`, `reals`, `ints`, `logic`) | lowering, `src/vpi/` | Their length is the source's; no count exists before the parse. |
| `Pp.events.*`, `Pp.out`, `Pp.segs` | `process` publishes them; prelude asserts them empty | Input-driven. |
| `Parser.kw_stack`, `attrs`, `attr_at` | `pp/prelude.zig` asserts on them | `begin_keywords nesting has no declared limit. |
| `Levels.items` | CLI, copied into every `Bag` | Bounded by the `Code` count, but a `[n_codes]` table in a struct copied by value costs more than the 0-3 flags a user types. |

Seam changes that would move a C list to A or B:
- `Exprs.pool`/`SourceFile.stmts`: a token-count estimate already exists in
  the lexer (`ensureTotalCapacity(src.len / 4 + 8)`); a per-tag ratio
  measured over the fixtures could presize them, but it is an estimate, not a
  bound, so it is not class B.
- `Pp.conds` would be class A if `ifdef nesting got a declared limit and a
  diagnostic (it has neither; Vague_Decisions.md lists none).
