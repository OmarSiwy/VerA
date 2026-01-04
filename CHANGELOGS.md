# CHANGELOGS

Running log of autonomous work. Newest section at the top of each list. Written to be read cold
over coffee: the things that need a human are first, then what landed, then what I decided
without asking, then where I was wrong.

Every number here is **MEASURED** on the tree at the stated commit unless it says ESTIMATED.
The rule is TODO.md's: re-run the suite rather than trusting this file.

---

## ⚠ Needs your eye — nothing here is blocking, all of it is reversible

1. **`docs/conformance-plan.md` (745 lines) is deleted, and its deletion rode in `6bb63ba`.**
   It was already staged as deleted in your working tree before I started, so I did not decide
   this — but I did bundle it into a commit about `ifconv`, which is not where a reader would
   look for it. `git revert` or a split is one command if you want it back or want it separate.
   Four dangling pointers to it are fixed (TODO.md, tests/fixtures/TODO.md, tools/contract.zig).

2. **An unmerged worktree exists: `worktree-agent-a0033e63105e5f22e` at `6afca59`**, subject
   "Device fixes: inductor flux sign, kinduc M, tline Bergeron, switch edges, diode pnjlim,
   LTRA sections". Not mine, not merged into `refactor/frontend-ir-backend`. It overlaps wave
   13's device-physics items (specifically the inductor work), so if it is real work you want,
   tell me and I will merge it BEFORE wave 13 rather than have an agent redo it.

3. **You asked about sub-linear complexity; wave 12 deletes the only thing that could deliver
   it.** A compiler cannot beat O(N) on a fresh compile — it must read every byte. The only
   route to sub-linear *per edit* is an incremental frontend cache, and that is `root.Compilation`
   (`src/root.zig`, ~273 lines), which wave 12 deletes as having no consumer. I am proceeding
   with the deletion (doctrine: no member without a consumer; its own docstring argues against
   itself), but recording it here because rebuilding it later against the new bench would be a
   deliberate wave, not an accident.

4. **The largest measured win found so far is not scheduled in any wave.** A ~200-byte one-module
   `.va` costs 0.69 ms of preprocessing and emits 11,791 bytes, nearly all of it Annex D.2 + D.1
   + Table E.1 re-expanded from scratch every compilation. Across the fixture batch that is
   **909 ms of the 2.58 s to MIR — 35% of the frontend on small files is a byte-identical
   prelude.** This is a constant-factor win, which is the only kind available (see §3). I intend
   to schedule it as its own wave once the current sequence lands. Not started.

---

## Landed

### Wave 9 — the five host-visible bugs (IN FLIGHT at time of writing)

Dispatched to four disjoint worktrees. See "In flight" below.

### Wave 8 — the instrument, and the number decode — `b47ed53`

**Suite: 209/209 · torture 1150/1152 (2 XFAIL, 0 FAIL) · test-contract green.**

Two agents in parallel worktrees, merged and then verified on the union (neither had tested
against the other; the union count is 209, which is why neither agent's own number was right).

- **`tests/bench.zig` + a `bench` step now exist.** Four phase timers on existing seams, curve
  at n = 1/8/64/512/4096, TSV on stdout, N=25 report min. It **can fail**, demonstrated rather
  than assumed: reverting `writeIfChanged`'s content compare trips its `expected 0, found 4`
  assert. This is now the gate on every performance claim in the repo.
- **`tests/external.zig` was running in no step.** Wired into `test_step`. It had NOT bit-rotted
  (I predicted it might).
- **Round-once decode landed.** `2.2n` is now one `parseFloat` of the joined text. Deleted
  `siScale`, three duplicate scanners, and `TestLex` — a 104-line second lexer that the parser
  tests were running against instead of the real one. Net −247 lines.

**The measured curve — nothing in this compiler is quadratic:**

| axis | n=1 | 512 | 4096 | 512→4096 |
|---|---|---|---|---|
| contrib | 1.32M ns | 14.1M | 104M | 7.4× |
| vals | 1.30M ns | 10.5M | 84.5M | 8.0× |
| inst | 1.33M ns | 25.3M | 206M | 8.1× |

8× input → 7.4–8.1× time out to 4096, including elaboration-by-flattening (4096 instances =
206 ms, ~50 µs each). **This retroactively killed several O(n²) findings from the original
audit.** Evidence beat argument, which is what the bench was for.

### Tier 0 cleanup — `783259c`, `25286ba`, `6bb63ba`

- **`diag_code.info`: 16,848 B of Debug `.text` → 124 B** (136×), test binary 42 MB → 17 MB.
  The 233-arm switch is now evaluated at comptime into a `[235]Info` table. Kept BOTH properties
  the old code had: it still fails to compile on a missing arm, and still binds code→text by
  name (a hand-written array literal would bind by position, where one misplaced entry silently
  prints E0313's explanation under E0314).
- **Deleted `compilePreprocessed`** — a `pub fn` in the library API that **did not compile**
  (passed 7 args to a 10-param function). It survived because `root.zig` was absent from its own
  `refAllDecls` guard list. Fixed at the root: `@This()` joins the tuple.
- **Deleted `ifconv.zig`** (228 lines). `root.zig` called it "a complete MIR→MIR pass"; it was
  not complete. Its `terminatorOf` took the last instruction in a block, while `ssa.zig`'s
  consumer contract explicitly guarantees a `.phi` can sit *after* the terminator — so it saw
  1 of 428 branches.

---

## Decisions taken without asking

Per standing instruction. Each is reversible; each has a reason.

1. **Refined the "never allocate" rule to "never allocate for a KNOWN size"** (`14c3886`).
   Applied literally it would have broken two things this tree already gets right: the codegen
   output buffer is deliberately gpa-backed because an arena cannot regrow in place
   (`root.zig:46-48`), and a fixed buffer that can overflow is worse than the allocation it
   replaced (the 512-byte `$sformat` site is a registered ceiling with a collision hazard). The
   checkable form is now one question per site: *what is the bound, and where is it written
   down?*
2. **T0.6 was reclassified from "free deletion" to a decision.** It changes emitted device text.
   See "Where I was wrong" below.
3. **Agents are forbidden from running `zig build torture` in parallel.** It spawns a child
   `zig build-exe` per fixture across 1152 fixtures; four concurrent runs would thrash the
   machine and make every bench number worthless. Agents verify their own fixtures directly
   against `./zig-out/bin/vera`; I run one integration torture after merging.
4. **Deleted an audit agent's uncommitted experiment** rather than landing it. It was a
   half-finished T0.6 in `parser.zig` that broke `codegen.zig:5526`. The lesson it taught is
   recorded as wave 8 item 1, and the experiment itself was replaced by a correct
   implementation.

---

## Where I was wrong — corrections to things I asserted earlier

Kept because a plan whose errors are invisible is worse than one with none.

1. **"T0.6 is a free deletion, no behavior change."** Wrong twice over. Routing the parser
   through `lexer.parseReal` changes emitted device numbers, and `codegen.zig:5502` pins the old
   value. Worse, deleting the parser's over-scan **silently downgraded three normative §2.6.1
   reject fixtures** (`4' h5`, `8'y11`, `4af`) to a wrong diagnostic — first torture run was
   1147/1152 with 3 FAIL. Each of those fixtures *argues its clause*; re-blessing them would
   have traded a §2.6.1 message for a fix-it offering to insert a semicolon inside a number.
   Fixed in the parser (`gluedNumberText`), and the first cut of *that* broke a fourth fixture
   (`1g`, which the fixture states outright is "the integer 1 followed by an identifier").
2. **"TODO.md's 207/207 is stale."** It was accurate at wave 7. *I* made it stale by deleting
   exactly two tests and not updating the number. Now 209/209, measured on the merge.
3. **"`zig build test` is green"** — asserted while the tree was dirty with an agent's edit. It
   was 204/205. The clean tree was green, but I had not checked the tree was clean.
4. **I specified `std.time.Timer` in the bench spec. It does not exist in Zig 0.16.** The agent
   replaced it with `Io.Timestamp.now(io, .awake)`.
5. **I specified four disjoint phase timers.** They cannot be disjoint without adding entry
   points that exist only to be timed — the API the doctrine deletes. Each row is a prefix of
   the next; the reader subtracts.
6. **I suggested `ifconv` might be "part of the SIMD story."** It is the opposite: its own header
   insists arms stay lazy, and a lazy select is still a branch. It cannot produce branch-free
   code.

---

## In flight

- **Wave 9** (`wo713y9ei`) — four worktrees: codegen emit bugs (`|U|>256` uncompilable artifact,
  `--display=drop` type mismatch), SPICE keyword node names, the parameter-default fold
  miscompile + `sysFuncTy`/`callTy` disagreement, and two trust-boundary one-liners.

**Verified miscompiles being fixed in wave 9** (both reproduced by hand on this tree):

```verilog
parameter integer w   = 4;
parameter integer a2  = (1 << w) - 1;   // expect 15 → emits 0
parameter integer cmp = (w > 2);        // expect 1  → emits 0
```
Exit 0, no diagnostic. `analysis.zig:697`'s `else => null` covers shifts, all six relationals,
bitwise and logical ops. A real `hfet2.va` ships 4 wrong parameters this way.

And `codegen.zig:861` emits `pub const U = enum(u8)` with nothing bounding `u_names.len`, so a
>256-unknown model compiles clean here and dies in the *host's* build.

Both were invisible to the suite for seven waves because **the suite grades VerA's own
testbench** — bugs living in the artifact handed to a host are structurally outside its view.

---

## Queue

10 characterization → 11 node identity → 12 surface deletion (~975 lines) → 13 device physics →
14 allocation sweep → MIR row 25 B → 9 B (Air-style `tags`+`data`+`Ref`).

Plus the unscheduled prelude-caching wave from §4 above, which is the largest measured win
currently known.
