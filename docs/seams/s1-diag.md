# s1-diag: the diagnostic system (U22, U09)

Step-1 notes for `lib/diag.zig`, `lib/diag/*.zig` and `lib/diag_code.zig`,
written 2026-10-03 against base `64357568`.

## Spine and ownership after step 1

One diagnostic: `Bag.build` -> `Builder` parts (`msg`, `point`, `label`,
`note`/`help`/`suggest`) -> `Builder.emit` (level, cap, dedupe) -> one
`Record` row plus its strings in the pool. Once per compilation:
`Bag.detach` (optional) -> `render`/`renderJson`, which sort the rows and
resolve every span through `Bag.map` and `Bag.files`.

| File | Owns (writes) | Readers |
|---|---|---|
| `diag.zig` | nothing: aliases only (the module API) | 37 files |
| `diag_code.zig` | `Code`, the comptime `table` of `Info` | `render`, `level` |
| `diag/level.zig` | `Severity`, `Level`, `Levels` (the override list) | `bag`, CLI |
| `diag/location.zig` | `Span`, `FileId`, `Segment`, `File`, `StripMark`, `SourceMap`, `LineIndex` | everything |
| `diag/entry.zig` | `Record`/`LabelRec`/`NoteRec` (stored), `Entry`/`Label`/`Note`/`Fix` (views) | `bag`, `render` |
| `diag/bag.zig` | `Bag.records`, `.string_bytes`, `.files`, the counters; `Builder` | `render`, every stage |
| `diag/suggest.zig` | nothing (pure): `editDistance`, `didYouMean`, `didYouMeanMap` | lower, parser |
| `diag/render.zig` | nothing persistent; line-index scratch per call | CLI, sim, tests |

Two tables have a second writer outside the unit (seam 2 below):
`Bag.map` (the preprocessor assigns it) and `Bag.levels` (root.zig and
main.zig assign it).

## What changed

- `diag.zig` now only aliases. `Severity`, `severityOf`, `Level` and
  `Levels` moved to `diag/level.zig`; the did-you-mean code moved from
  `diag/bag.zig`, which it never touched, to `diag/suggest.zig`. Public
  names unchanged; `pub const Allocator` dropped from the root (no caller
  outside the unit used it).
- `Bag.build` returns a builder already marked `dropped` when the code is at
  `allow` or the bag is at `max_entries`. Such a builder formats nothing:
  `emit` drops it anyway, and rows only grow, so the decision cannot change
  between `build` and `emit`. Counting (`suppressed`) is unchanged.
- `Bag.detach` copies every borrowed byte into ONE gpa buffer
  (`detached_bytes`) and every strip mark into another (`detached_marks`):
  six allocations in all, instead of four per file and one per macro
  segment. `deinit` frees the two buffers instead of walking files and
  segments. The errdefer ladder is gone with it.
- `LineIndex.build` counts the newlines, then fills one exact slice, instead
  of growing a list line by line in the render scratch arena.
- Comptime size budgets: `Record` 156, `Span` 8, `StripMark` 8, `Segment`
  32, `Info` 48.
- Doc comments on every `pub` declaration that lacked one, carrying the fact
  (precondition, borrow, empty/unknown cases, panic). Stale `entries.len`
  in `Bag.failed` fixed; the Builder ponytail note no longer claims the cap
  bounds pool waste.

Goldens IDENTICAL (3,228 fixtures).

## Memory

Counts are from a temporary probe in `Bag.detach` on ReleaseFast `vera
--emit-zig` (psp103 / bsim4va / hisimhv_va), removed before commit.

| type | size before -> after | count (psp103) | bytes saved | what changed or why not |
|---|---|---|---|---|
| `Record` | 156 -> 156 | 20 (bsim4va, hisimhv_va: 64, the cap) | 0 | Children inline. At most 64 rows (10 KB); out-of-line children save at most 8 KB and cost `detach` a fix-up. Pinned at 156. |
| `LabelRec` / `NoteRec` | 12 / 20 | inline in `Record` | 0 | Already offsets into the pool, no slices. |
| `Bag.string_bytes` (pool) | psp103 5,091 B; bsim4va 8,208 B; hisimhv_va 13,652 B -> 5,091 / 5,108 / 9,683 B | 1 | 0 / 3.1 KB / 4.0 KB | Strings of diagnostics dropped at the cap (310 on bsim4va, 441 on hisimhv_va) are no longer formatted. A diagnostic deduped at `emit` still leaves its strings (needs an interleaving-safe truncate; not worth it at these sizes). |
| `Builder` | 168 -> 168 | stack, 1 live per report site | 0 | `dropped: bool` fits the padding. |
| `Bag` | 176 -> 208 | 1 | -32 | Two buffer slices for `detach`. |
| `detach` allocations | 4/file + 1/macro segment + 4 -> 6 | psp103 1,587 -> 6; hisimhv_va 2,408 -> 6 | allocator headers only | One byte buffer, one mark buffer. Bytes copied are unchanged (psp103 0.81 MB, hisimhv_va 1.15 MB); see seam 1 for removing the copy. |
| `Segment` | 32 -> 32 | 5,325 (hisimhv_va 7,769) | 0 | The preprocessor builds it field by field; the 16 B `macro` slice is seam 3. Pinned at 32. |
| `File` | 64 | 4 | 0 | Four rows. |
| `StripMark` | 8 | 1,271 (hisimhv_va 3,703) | 0 | Two u32s, already minimal. Pinned. |
| `Span` | 8 | up to 9 per `Record` | 0 | u32 pair: offsets in preprocessed text, which `Segment.out_start` already caps at 4 GiB. Pinned. |
| `?FileId` | 4 | 1 per `Record` | 0 | A sentinel would save 2 B that `Record` padding eats; `Entry.file` is public as `?FileId`. |
| `LineIndex.starts` | growth list -> exact slice | 1 per rendered file | dead list prefixes in the render arena | Render path only. |
| `Levels` rows | 4 | number of `--allow`/`--deny` flags | 0 | Linear scan over a handful of rows. |
| `Entry`/`Note`/`Label`/`Fix` | 64 / 56 / 24 / 24 | by-value views, never stored | 0 | Public views; not tables. |
| `Palette` / `RenderOptions` | 128 / 136 | 1 per `render` call | 0 | Public, set by callers (`.palette = .on`). |
| `Info` table (`diag_code.zig`) | 48 x 370 = 17.8 KB `.rodata` | static | 0 | Data, not code: the 6.6k-line switch runs only at comptime, lookup is one index (`table[@backingInt(c)]`). The executable is static, so no relocations and no startup cost; pages fault in only when a diagnostic renders. u32 offsets into one blob would save ~14 KB of binary and no RSS. Each code's name is written twice (enum field and switch arm) on purpose: the exhaustive switch is what makes a missing entry a compile error. 21 of 370 codes are retired; they keep their slot so the table stays dense. Text: 14.7 KB titles, 1.8 KB citations, 197 KB `--explain`. Pinned at 48. |

Peak RSS and time, ReleaseFast `vera --emit-zig`, best of 3 (before at
`64357568`, after at the final commit): see the report for the A/B table;
the changes here move peak RSS by under 1%, as the counts above predict.

## Seam proposals

1. **`detach` copies the whole source on every compilation.**
   `lib/root.zig:220` detaches the bag whenever `opts.diags` is set, so
   every compile copies every file's stripped text, original text and the
   segment table into gpa (psp103 0.81 MB + 170 KB; hisimhv_va 1.15 MB +
   249 KB), although `CompileResult` keeps the arena those slices borrow
   until `CompileResult.deinit` (`lib/root.zig:151-156`). The copy is only
   needed when the bag outlives the result. Better: detach on the failure
   path only, and have the success path hand the caller a bag that borrows
   the result's arena (documented as "valid until `result.deinit`"), or move
   the bag into `CompileResult`. Callers: `lib/root.zig` (compileSourceOpts),
   `src/main.zig` (renders after codegen). About 1.4 MB, 2.8% of hisimhv_va's
   peak, off every successful compile.
2. **Two `Bag` tables are written from outside the unit.**
   `lib/frontend/preprocessor.zig:363` assigns `opts.bag.map` directly, and
   `lib/root.zig:208` and `src/main.zig:437` assign `bag.levels`. Better:
   `Bag.setSourceMap(segs: []const Segment)` (asserting sorted `out_start`,
   which `resolve`'s binary search relies on), and `Bag.initLevels(arena,
   levels)` or a `levels` parameter to `init`, so each table has one writer
   and the "levels are borrowed, never freed by deinit" rule lives in one
   place. `lib/ir/lower/test.zig:134` reading `bag.records.items.len` should
   use `bag.count()`.
3. **`Segment.macro` is a 16-byte slice in a 32-byte row.** Segments are
   the unit's biggest table (psp103 5,325 rows, hisimhv_va 7,769), and it is
   stored twice when detached. Only `.macro` rows (1,567 / 2,388) use the
   name. Better: `macro: u32`, an index into a macro-name table the
   preprocessor already owns (its `macros` map keys), or into
   `Bag.string_bytes`; the row drops to 20 B (out, in, parent u32; file u16;
   kind u8). Saves 64 KB on psp103 and 93 KB on hisimhv_va per copy.
   Callers: `lib/frontend/pp/macro.zig:248-251`,
   `lib/frontend/preprocessor.zig:514,587` (construct), `pp/test.zig:1050`
   (reads `.macro`), and rustc-style expansion notes if ever rendered.
4. **`Palette` is eight slices (128 B) copied into every render call.** A
   `color: bool` in `RenderOptions` with the two palettes as comptime
   constants would carry the same choice in one byte. Callers:
   `src/main.zig:1190` (the only one that sets `.palette`), and the
   `explain` signature. Cosmetic; listed because the type is public.

## Bugs found

Latent, not reproduced by any fixture; step 3 should confirm with a trigger.

1. `lib/diag/render.zig` `lineIndexFor`: the cache slot is
   `@min(@backingInt(file), indices.len - 1)`, so a `FileId` past
   `bag.files` shares the LAST file's slot. If such an id is looked up first
   it caches an index built from `sourceText(unknown) = ""`, and a later
   lookup of the real last file gets that empty index: line 1, columns equal
   to the raw offset, the wrong snippet. Trigger: a `Builder.inFile(id)` with
   an id that was never registered, followed in sort order by a diagnostic in
   the last registered file. Expected: an unknown file renders no snippet and
   does not disturb the cache. Actual: the last file's snippet is wrong.
2. `lib/diag/location.zig` `Span.isNone` is `start == 0 and end == 0`, so a
   zero-width span at preprocessed offset 0 (`Span.at(0)`) renders as "no
   location": no `-->` line, no snippet, JSON `"span": null`. Trigger: any
   insertion-point diagnostic at the very first byte of the preprocessed text
   (for example an empty or whitespace-free file whose first token is
   wrong, reported zero-width). Expected: `--> file:1:1` and a caret.
3. `lib/diag/bag.zig` `Bag.str` ends a string at its first NUL byte. A
   message formatted from text containing a NUL (a decoded string literal
   with `\0`, or raw NUL bytes in a source file) is cut short in both the
   terminal and the JSON output. Expected: the full message (store lengths,
   or escape NUL when formatting).
