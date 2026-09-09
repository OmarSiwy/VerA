# Diagnostic performance review

Read both owned files in full, including the catalogue and existing tests, and
searched repository callers and the installed Zig 0.16 stdlib. No build, test,
benchmark, or profiler was run. Rankings are provisional, based on how much work
each proposal could avoid in its stated workload; all timing payoffs need measurement.
These files execute in the CPU compiler and renderer, not in emitted device kernels.

Applied cleanup: `src/diag.zig` now reuses `std.mem.indexOfScalarPos` to find
newlines, drops an unused snippet-loop index, and initializes the private
`renderToString` writer directly instead of transferring through a discarded
`ArrayList`. The newline search retains the initial zero, every newline's following
offset, checked `u32` casts, append order, and allocation error propagation. The
installed stdlib supplies the search's vector path and scalar fallback. No speedup
is claimed. Public declarations, fields, pool encodings, diagnostic text, and
numeric limits are unchanged. The findings below are proposals only.

## Avoid formatting diagnostics that will be dropped

- **Where**: `src/diag.zig:987-1079`, `Builder.msg`, `point`, `label`, `pushNote`;
  `src/diag.zig:1084-1129`, `Builder.emit`.
- **Now**: Builder methods format and append strings before `emit` checks lint
  level, the 64-entry cap, and deduplication. Each discarded attempt can therefore
  perform redundant formatting, grow `string_bytes`, and leave bytes that `detach`
  later copies. The cap bounds accepted records, not attempted messages or string
  storage; the existing comment claiming bounded waste does not establish a bound.
- **Change**: Start with a preflight in the single-call `Bag.add` path before
  `build`/`msg`: consult the level, cap, and existing dedupe key, in the same order
  as `emit`, and account for the appropriate dropped diagnostic exactly once.
  Extend to multi-call builders only with an explicit decision about when their
  mutable code, span, and lint configuration become fixed. Do not truncate the
  shared pool across interleaved builders.
- **Why it is faster**: Rejected attempts avoid formatting and pool growth;
  detachment also avoids copying their unused strings.
- **Est. payoff**: Potentially large for thousands of repeated or suppressed
  attempts; no benefit when every attempt is accepted. Kernel speedup and share
  of total compilation time are unknown, needs profiling.
- **Risk**: This changes observable pool contents and when allocation failures
  occur. Formatting arguments can have custom formatters, and builders expose
  mutable fields. Preserve cap-before-dedupe precedence, counters, and promotion
  rules. These compatibility questions prevent treating it as a safe cleanup.
- **CPU / GPU / both**: CPU.

## Pool detached provenance allocations

- **Where**: `src/diag.zig:876-927`, `Bag.detach` and `Bag.deinit`.
- **Now**: `detach` separately duplicates every file's name, stripped text,
  original text, and strip marks, plus each segment's macro name. Up to four
  nonempty allocations per file and one per named macro segment create allocator
  overhead and scattered storage, followed by matching frees. `root.finish`
  invokes detachment even for successful compilations when diagnostics are
  requested, so this cost is not restricted to failures.
- **Change**: In a future ownership change, size one aligned provenance backing
  allocation in `detach`, then copy file payloads, strip marks, segments, and macro
  names into it and point the existing views at their slices. Record ownership
  explicitly and make `deinit` release that backing allocation once. Keep the
  existing message/string pools separately growable for post-detach diagnostics.
- **Why it is faster**: Allocation/free calls scale with backing blocks rather
  than file and segment count. This does not eliminate the required source-byte
  copies, so a bandwidth-bound detach may see little improvement.
- **Est. payoff**: Relevant to large include trees or many macro segments; timing
  and total-runtime share are unknown, needs profiling. Little expected benefit
  for a single small source file.
- **Risk**: Interior slices must no longer be individually freed. Alignment,
  partial-allocation cleanup, and detached lifetimes must remain correct. Explicit
  ownership bookkeeping may affect the public `Bag` layout and needs a separate
  API decision. Never discard provenance for an empty bag: codegen can add its
  first diagnostic after detachment. No device ABI or floating-point work is involved.
- **CPU / GPU / both**: CPU.

## Tighten typo-search cutoffs after finding a candidate

- **Where**: `src/diag.zig:1148-1184`, `editDistance`;
  `src/diag.zig:1231-1240`, `Nearest.offer`.
- **Now**: Every candidate uses the original `self.limit`, even after a closer
  candidate sets `best_d`. The row recurrence has a serialized dependency on
  `cur[j]`, and it computes additional rows for candidates that can no longer
  beat or tie the best result. Symbol and macro maps can contain many candidates
  despite the cap on accepted diagnostics.
- **Change**: Pass `@min(self.limit, self.best_d)` from `Nearest.offer` to
  `editDistance`. Keep the cutoff inclusive so equal-distance candidates still
  reach the lexicographic tie-break. Retain the distance recurrence, transposition
  checks, empty-input behavior, and 64-byte cap.
- **Why it is faster**: The existing length and row-minimum exits can reject
  hopeless candidates earlier, reducing dependent cell calculations without
  changing the candidate collection or allocating another table.
- **Est. payoff**: Relevant when a close candidate is found early in a large
  symbol map; little benefit for tiny maps or similarly close names. Speedup and
  total compilation share are unknown, needs profiling.
- **Risk**: A strict cutoff at `best_d - 1` would lose lexicographic ties. Verify
  order independence and adjacent transpositions before implementing; the public
  distance function returns a cutoff sentinel rather than an exact distance for
  some inputs. No floating-point or device-layout effects.
- **CPU / GPU / both**: CPU.

## Allocate the line-start table once

- **Where**: `src/diag.zig:299-308`, `LineIndex.build`.
- **Now**: The search now reuses the stdlib, but every newline still appends to a
  growing `ArrayList`. Growth may allocate and copy earlier offsets; an arena can
  retain superseded backing allocations until the rendering scratch is released.
  The index is already lazy and cached once per file within a render.
- **Change**: If this appears in a profile, count newlines with
  `std.mem.count(u8, text, "\n")`, allocate exactly count-plus-one `u32` entries,
  and fill them using the current stdlib search. Preserve entry zero and a final
  start at `text.len` when the input ends in a newline.
- **Why it is faster**: One allocation replaces capacity checks and possible
  growth copies. The tradeoff is an extra pass over the source bytes.
- **Est. payoff**: Plausibly useful for files with tens of thousands of lines;
  unknown, needs profiling. Total-runtime share depends on how often large files
  actually appear in rendered diagnostics and is also unknown.
- **Risk**: The second scan can cost more than the avoided growth. Allocation
  failure timing changes. Retain checked offset conversions, consecutive empty
  lines, CRLF handling, and the trailing-empty-line convention. No GPU effects.
- **CPU / GPU / both**: CPU.

## Write ordinary text in contiguous runs

- **Where**: `src/diag.zig:1315-1319`, `writeExpanded`;
  `src/diag.zig:1760-1771`, `writeJsonString`.
- **Now**: Both helpers call writer methods per byte for ordinary text. This
  repeatedly updates the writer cursor and checks capacity, creating a serialized
  dependency chain. These are buffered calls, not one syscall per character.
- **Change**: In `writeExpanded`, search for tabs with `indexOfScalarPos`, write
  the preceding slice with `writeAll`, then emit the existing four spaces. In
  `writeJsonString`, track an ordinary-run start, flush it on a quote, backslash,
  or byte below `0x20`, and retain the current switch for that exceptional byte.
  Flush the trailing run before the closing quote.
- **Why it is faster**: Writer overhead scales with escaped runs rather than
  total bytes; ordinary snippets and messages become bulk copies. Keep branches
  around exceptional output, since doing both writes would change the output.
- **Est. payoff**: Most relevant to long source lines and verbose JSON output;
  kernel and total-runtime payoffs are unknown, needs profiling. Rendering is
  capped at 64 entries and does not affect solver evaluation throughput.
- **Risk**: Preserve every byte, including malformed UTF-8 and control-character
  escapes. Direct substitution with `std.json.Stringify.encodeJsonString` is not
  byte-equivalent: it spells backspace/form-feed as `\b`/`\f`, while this helper
  spells them `\u0008`/`\u000c`. Batching can also change writer callback boundaries
  and partial output on failure, so it requires separate validation.
- **CPU / GPU / both**: CPU.

## Track explanation hints with an enum bitset

- **Where**: `src/diag.zig:1356-1359`, `render`;
  `src/diag.zig:1524-1532`, `renderOne`.
- **Now**: The once-per-code explanation hint uses an
  `AutoHashMapUnmanaged(Code, void)`, allocating and hashing in the rendering loop
  for membership in a fixed, dense enum domain. `diag_code.zig` already checks
  that domain's density at compile time.
- **Change**: Replace the private `explained` set and `renderOne` parameter with
  `std.EnumSet(Code)`, initialized empty. Check containment and insert before
  writing the first hint, preserving the current output order. Leave the public
  `Bag.seen` dedupe table alone: its key also includes a source offset.
- **Why it is faster**: A small fixed bitset avoids hashing, growth, and allocator
  calls for explanation-hint tracking.
- **Est. payoff**: Small and limited to rendering with `explain_hint` enabled;
  timing and total-runtime share are unknown, needs profiling. At most 64 entries
  are rendered, so this is a lower priority than the preceding findings.
- **Risk**: Removing allocation changes possible rendering failures, though
  successful output should match. Keep this set local to each render so repeat
  renders still print their hints. No public enum ordinals, pool format, numerics,
  or device ABI need change.
- **CPU / GPU / both**: CPU.

## Nothing to do

- `src/diag_code.zig`: reviewed and clean; immutable documentation already uses a dense compile-time table with exhaustive coverage and density guards.
