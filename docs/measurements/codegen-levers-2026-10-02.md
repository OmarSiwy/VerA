# Device build levers, second pass: addendum

Measured 2026-10-01/02, same method as
[codegen-levers-2026-10-01.md](codegen-levers-2026-10-01.md): retired user
instructions of the `zig` process tree (Gi = 10^9) from a fresh cache,
bench-host output hash at 64 bias points for numerics. The setup rows were
re-measured on 2026-10-02 against `e96948cd`, 3 rounds at load 11-15 on 32
threads (critical path = largest object, median; wall = minimum).

Measures A/B/C/D: none moved.

## Result

| Lever | Effect | Runtime | Status |
|---|---|---|---|
| Contract checks opt-in (`vera_validate_contract` in the root module; `vera --validate-contract`) | mos1 2.454 → 2.417 Gi, bsim4va eval part 8.100 → 7.958, psp103 eval part 14.183 → 14.125 (-0.4 to -1.8%) | none (comptime checks) | landed (`a43ffda8` on main). The 2026-10-01 note rejected it on speed; the user decided to land it because the checks are a development aid and VerA's devices follow the contract by construction. `zig build test`, the fixture suite and `vera --check` keep validation on; the `abi_version` check always runs. A host that wants `validateHost`'s obligation checks must opt in. |
| `setup` of at least 256 KiB emitted only as `zSetup<k>` chunks that a thin `setup` calls; a split build whose host declares `SetupValue(D)` compiles each chunk in its own object | psp103 critical path 20.3 → 13.1 Gi (now the eval part), wall 3.58 → 3.12 s; bsim4va 12.7 → 7.7 Gi, wall 2.29 → 1.84 s. Totals unchanged within 2% | `evalQ` instructions identical (psp103 6,609, bsim4va 6,081), cycles within 1.2%. `setup` (once per card/temperature): psp103 +18-22% cycles (16,105 → ≈19,400-19,900 instructions, ≈0.3 µs per call), bsim4va +6-10% | this branch |

Both are bit-exact: bench hashes identical on resistor, mos1, txl, bsim4va,
psp103 and coupled_ltra, with every host shape below.

## Setup split: hosts

| Model | Host | Critical path Gi (base → chunks) | Total Gi | Wall s (min of 3) |
|---|---|---|---|---|
| psp103 | split, `SetupValue` | 20.3 → 13.1 | 35.6 → 36.3 | 3.58 → 3.12 |
| psp103 | split, no `SetupValue` | 21.4 → 20.0 | 35.5 → 35.9 | 3.59 → 3.56 |
| psp103 | one piece (no `exportDevicePart`) | 33.7 → 33.2 | 35.1 → 35.3 | 6.21 → 6.69 (noise: the instructions did not grow) |
| bsim4va | split, `SetupValue` | 12.7 → 7.7 | 22.5 → 22.5 | 2.29 → 1.84 |
| bsim4va | split, no `SetupValue` | 12.7 → 11.7 | 22.5 → 21.8 | 2.32 → 2.31 |
| bsim4va | one piece | 21.4 → 20.3 | 22.0 → 21.2 | 4.00 → 4.10 |

At `-j1` the direct setup object is psp103 21.36 → 21.35 Gi, bsim4va 13.03 →
12.09; psp103's eval object 14.21 → 14.46. Emitted text: psp103 1.433 →
1.413 MB, bsim4va 0.819 → 0.844 MB.

## Setup split: notes

* The cut is a text transform over the relooper's fixed shape
  (`codegen/setup_chunk.zig`): tail-break blocks are opened, two-armed
  self-contained `if`s become a stored guard, and values crossing a cut are
  kept in a scratch struct `zSetupZ`. Every statement runs once, in order, on
  the same values.
* The first version (`a49f0955`, not landed) also kept the whole function
  for hosts that do not split, which grew psp103's text 1.43 → 2.26 MB and a
  direct build by up to 10%. Emitting only the chunks removes both.
* The setup runtime cost is the scratch struct's memory traffic. Calling the
  chunks `@call(.always_inline)` brought it back to base (psp103 15,853
  instructions) but took the direct setup object to 24.6 Gi (+15%), so the
  chunks stay calls.
* It declines (one function, as before) on a `return` before the last piece,
  `zs_stop`/`zs_done` bodies, fewer than two chunks, or a cut with more than
  3/4 of the text in one chunk. mos1, txl and resistor are below 256 KiB.
  coupled_ltra declines on `zs_stop`; not handled, because its 5.7 MB setup
  (mostly indentation) compiles to 0.7-2.6 Gi and is never its critical path
  (state and eval, 15-17 Gi each).

## Next

psp103's longest object is the eval part again (≈13 Gi): one `evalQ`
function, whose LLVM time no flag measured here splits. The remaining
lever is host-side (ARPice instantiates the model body 5-7 times per
device; see the 2026-09-30 study, lever 2).
