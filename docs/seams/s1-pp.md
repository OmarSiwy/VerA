# Seam notes: s1-pp (UNITS.md U41, U11, U12)

Step-1 agent for `lib/frontend/preprocessor.zig`, `lib/frontend/pp/**` and
`lib/frontend/spice_cards.zig`. Base `64357568`. Nothing outside that set was
edited; every proposal below is for the seam agents.

## Spine and ownership after step 1

`process` (preprocessor.zig) is the spine: register the compilation unit as
`.root` → seed the §10.5 predefined macros → replay the annex D/E prelude
snapshot (`pp/prelude.zig`) → annex E.2 netlist (`spice_cards.synthesize`,
then `runFile`) → `runFile(source)` → `runFile` per `Options.more` → E0101 if
a conditional is still open → publish. `runFile` registers a file, strips it
(`pp/comments.zig`) and calls `scan`, the byte loop; `scan` hands every '`'
to `pp/directive.zig`'s `directive`, which dispatches to the conditionals and
the operand handlers in the same file or to `pp/macro.zig` (`handleDefine`,
`removeDefine`, `expand`, which rescans through `scan`).

| table | lifetime | written by | read by |
|---|---|---|---|
| `Pp.out`, `Pp.segs` | scratch, copied exact to the caller's arena at publish | `scan`, `directive.zig` (passthrough words, newlines), `macro.zig` (`__LINE__`/`__FILE__`, expansion segments) | `process` (publish), `prelude.zig` (capture) |
| `Pp.events` (six `Directives` lists) | scratch, copied exact at publish | `directive.zig` only | `process`, `prelude.zig` (asserts empty) |
| `Pp.macros` | scratch | `macro.zig` (`define/`undef), `process`/`replayStdDefs` (seeding) | `macro.zig`, `directive.zig` (`ifdef) |
| `Pp.conds`, `includes`, `line_*`, `file_override` | scratch / scalars | `directive.zig` (`runFile` saves and restores the `line state) | `Pp.emitting`, `macro.zig` |
| `Pp.expanding`, `expand_depth`, `expand_site` | scratch / scalars | `macro.zig` | `Pp.spanAt`, `resync` |
| file text, marks, include bytes and names | caller's arena (the bag keeps them) | `runFile`, `comments.zig`, `directive.zig` | `diag.Bag` |
| `Prelude` | process lifetime, built once | `prelude.zig` | `process`, `Lexer`/`Parser` seeding |

Structural changes: `directive`, `conditional` and `logicalLineEnd` moved
from preprocessor.zig to pp/directive.zig, so every event writer is one
file; `indexOfString` moved to its one caller in pp/macro.zig; the six event
lists became one `Events` struct, named field for field like `Directives`
and published (and asserted empty by the prelude) by a comptime loop. The
root keeps the external API, the `process` spine, `Pp` and `scan` (with the
`findStop` vector scan, untouched).

## Seam proposals

1. **`diag.Segment` 32 B → 16 B** (owner: diag). `macro: []const u8` is
   always a slice of the file text at the segment's own `in_start`: only the
   outermost expansion gets a `.macro` segment, and it is outermost exactly
   when the scan is in file text (`expand_site == null`), so the name is
   `fileText(file)[in_start + 1 ..][0..len]` (`+ 2` for a `` `\name ``
   escaped use). Sketch: `out_start: u32, in_start: u32, parent: u32,
   file: FileId (u16), kind: u1, name_len: u15`. psp103 has 5,325 segments
   (170 KB → 85 KB); hisimhv_va 7,769. Callers: `pp/macro.zig` (`expand`),
   `pp/prelude.zig` (`Prelude.segs`), diag's renderer.
2. **`Parser.atRest()`** (s1-parser's proposal 1): endorsed.
   `pp/prelude.zig:166-172` asserts a dozen `Parser` fields one by one; with
   `atRest()` it becomes one `std.debug.assert(parser.atRest())`. The
   `access_names` key iteration at `pp/prelude.zig:175` is s1-parser's
   proposal 7.
3. **`frontend.spice_cards` has no code caller outside the preprocessor.**
   `lib/frontend/root.zig:17-19` exports it "so a caller can synthesize
   without running the preprocessor", but the only mentions elsewhere are
   comments (`lib/root.zig:91`, `lib/backend/tb.zig:92`,
   `src/main.zig:483`). Either drop the export or point those comments at
   `Preprocessor.Options.spice_netlist`, the path the text actually takes.
4. **The prelude is captured by copying, then copied again per
   compilation.** `replayStdDefs` copies `Prelude.text` (12,244 B) and its
   165 segments into every compilation's output, and `process` copies the
   whole output once more at publish. Since the prelude is a byte-exact
   prefix (`preludeTokens` relies on it), `Output.text` could be published
   as two slices, or the lexer could take the prefix by reference. Small
   (12 KB per compile) and it touches `lib/root.zig` and the lexer, so not
   worth a seam change unless the prelude grows.

## Bugs found

Not fixed (step 3). Both reproduced with throwaway `process` calls.

1. **A directive inside a macro's actual argument records its event at the
   wrong offset.** `pp/macro.zig` `expandArg` swaps `pp.out` for a fresh
   list while it pre-expands an argument, and `Pp.mark` stamps events with
   `pp.out.items.len`, so the offset is into the temporary buffer.
   Trigger: `module a; endmodule` / `` `define ID(x) x `` /
   `module b; endmodule` / `` `ID(`celldefine) `` / `module c; endmodule`.
   Expected: one `cells` event at the use (output offset 42 here), so only
   `c` is a cell. Actual: `at = 0`, so `a` and `b` are cells too (IEEE 1364
   §19.1, LRM §10.1). The same holds for every `mark`-ed directive and for
   `default_discipline`'s event.
2. **`include inside a macro body reports diagnostics at the wrong place,
   and stops resyncing the source map.** `expand_site` stays set while the
   included file is scanned (`directive.zig` `handleInclude` → `runFile`),
   so `Pp.spanAt` returns the invocation offset in the *parent* file while
   `failWith` names the *included* file, and `Pp.resync` returns early for
   every directive in the included file. Trigger: `` `define INC
   `include "bad.vh" `` / (blank) / `` `INC ``, with `bad.vh` = `// line 1` /
   `` `undef ``. Expected: E0113 at `bad.vh` 1..7. Actual: E0113 at
   `bad.vh` 31..31, past the end of that file's 8 stripped bytes. A plain
   `` `include "bad.vh" `` reports 1..7 correctly.

Also noted, not bugs: `Pp.physicalLine` counts newlines from the file start
on every `__LINE__` (O(n) per use, O(n²) for a file of them), and
`Region.inForce` scans backwards linearly (already marked `ponytail:`).

## Memory

Audit of every type, container and allocation in the unit, 2026-10-03.
Sizes are `@sizeOf` on x86_64 from a throwaway test; counts from throwaway
counters and callgrind call counts on psp103 (`--emit-zig -I models`),
removed before commit.

The headline change is lifetime, not row width: before, every growable the
preprocessor touched lived on the compilation arena, which is freed only when
the compile ends, so each regrowth of `out`, `segs`, the macro table and
every expansion's temporaries stayed resident through lowering and codegen.
Now they live on a scratch arena `process` frees on return, and the outputs
are copied to the caller's arena once, exactly sized.

Whole-compile effect (ReleaseFast `vera --emit-zig -I models`, 9 runs each,
interleaved, on a machine shared with other agents' builds, so times are
min-of-9 and RSS is the median):

| model | peak RSS before → after | time before → after |
|---|---|---|
| psp103 | 31,928 → 30,872 KB | 0.14 → 0.15 s (noise) |
| bsim4va | 23,028 → 23,064 KB (noise) | 0.11 → 0.11 s |
| hisimhv_va | 48,484 → 47,592 KB | 0.24 → 0.25 s (noise) |

Callgrind (`-Dcpu=x86_64_v2`, psp103): `preprocessor.process` inclusive
41,066,724 → 40,938,314 Ir; `substitute` 25.14 M → 25.10 M Ir. The CPU
cost is the byte loops (`substitute` appends per byte and per word), which
is step 3's.

Bytes `process` takes from the caller's arena (counting allocator over the
arena, one call, prelude snapshot warm):

| model | before | after | allocations |
|---|---|---|---|
| psp103 | 4,971,563 B | 1,341,550 B | 7,432 → 6 |
| bsim4va | 3,243,128 B | 1,214,855 B | 2,942 → 6 |
| hisimhv_va | 5,217,061 B | 1,819,603 B | 5,616 → 6 |

| type | size before → after | count on psp103 | bytes saved | what changed or why not |
|---|---|---|---|---|
| `Pp.out` (`ArrayList(u8)`) | grown on the caller's arena → scratch, reserved `source.len` once, copied exact | 1, 541,842 B final | its regrowth garbage (part of the totals above; not measured per table) | Every arena regrowth left the old buffer behind; now only the exact copy stays. |
| `Pp.segs` (`ArrayList(diag.Segment)`) | as `out` | 5,325 rows × 32 B | its regrowth garbage | Scratch, then one exact copy into `bag.map`. Row width is diag's (seam 1). |
| `diag.Segment` | 32 B, unchanged | 5,325 | 0 here | diag-owned; 16 B proposed (seam 1). |
| `Events` (six lists) | 6 loose fields → one 192 B struct | 1; 0 events on the three models | regrowth garbage | Scratch + exact copies; published and asserted empty by a comptime loop over `Directives`' field names. |
| `DefaultDiscipline` | 24 B, unchanged | 0 on the models | 0 | Frozen row (elaborate reads it). `discipline` is now copied to the arena, because it can slice a macro body on scratch. |
| `Region(?f64)` / `Region(?Timescale)` | 24 B / 32 B, unchanged | 0 on the models | 0 | Frozen generic rows; a NaN sentinel would make the first 16 B, not worth a boundary change for a handful of events. |
| `Region(NetType/bool/Drive)` | 8 B, unchanged | 0 on the models | 0 | Already minimal. |
| `Macro` | 40 B, unchanged; pinned | 204 (45 prelude, 156 own, 3 predefined) | the table (204 × 56 B of key and value, plus map metadata) off the caller's arena | Two slices + two flags. Pool offsets would save < 4 KB; not worth it. Comptime-asserted. |
| `Pp.macros` (`StringHashMapUnmanaged(Macro)`) | caller's arena → scratch | 204 entries | its rehash garbage | Keys borrow the defining text; never copied. |
| `Cond` | 16 B, unchanged; pinned | ≤ nesting depth (56 `ifdef`s, a few open at once) | 0 | Four bools could pack to 12 B; a handful of rows. Comptime-asserted. |
| `Pp` | 520 → 536 B | 1 per compile | −16 B | Gained `scratch: Allocator`. |
| expansion temporaries (`macroArgs` lists and bracket stack, argument copies, `expandArg` buffers, `substitute` output) | per expansion on the caller's arena → scratch | 1,780 expansions, 1,444 substitutions | the bulk of the 3.6 MB above | All die with the expansion; scratch frees them with the call. A per-outermost-expansion reset would also bound scratch, but needs the macro-body-borrowing sites (`define`, `line`, builtin `include path) copied out first; not done. |
| stripped file text | `src.len` reserved, slack kept → shrunk in place | 1 per file | the comment bytes (the buffer is the arena's last allocation when it shrinks) | |
| `diag.StripMark` list | grown on the caller's arena → scratch + exact copy | 1 per comment | regrowth garbage | 8 B rows, diag-owned. |
| `Rest` | 24 B | stack only | 0 | A cursor, never stored. |
| `Options` / `Output` / `Directives` / `File` | 80 / 136 / 96 / 32 B | 1 per compile / per `more` file | 0 | Frozen API, one instance. |
| `Prelude` | unchanged | 1 per process: 12,244 B text, 165 segs, 45 macros, 2,758 tokens | 0 | Built once, never freed by design (see seam 4). |
| `spice_cards` working copies (lowered netlist, joined cards, per-card strings) | caller's arena → own scratch, text copied exact | 0 on the models (no netlist) | all of it, on `//! spice` fixtures | `model_types`, `device_cards`, `controlled` are comptime tables, untouched. |
