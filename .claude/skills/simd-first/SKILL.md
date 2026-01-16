---
name: simd-first
description: SIMD kernel design and the Zig vector API for this repo. Use when writing or optimizing a vector loop, when lanes stop being independent (neighbour-dependent bytes, prefix/parity state), when output length depends on the data, when you need a runtime table lookup or a bitmask trick, or when verifying vector code against a scalar oracle.
---

# SIMD-First

Reference lives in `ref/SIMD-Strategies/`. Read the file the wall points to
before writing the kernel.

## Which wall

Vector code works while **lanes are independent** and **output has the same shape
as input**. Every technique here exists to break one of those.

| Symptom | Wall | Read |
|---|---|---|
| Predicate is a messy set of byte values | need a primitive | `01-techniques.md` T1 |
| A byte's meaning depends on its neighbours | lane independence | `01-techniques.md` T2–T4 |
| Depends on *everything* before it | lane independence, badly | `01-techniques.md` T5 |
| Output length depends on the data | output shape | `01-techniques.md` T6 |
| Works, but the branch predictor thrashes | control flow | `01-techniques.md` T7 |
| "What is the Zig spelling of X?" | — | `02-zig-simd-api.md` |
| "Why did this compile/behave strangely?" | — | `03-gotchas.md` |

## Non-negotiables

- **Oracle first.** Write the scalar version before the vector version. It is the
  test oracle, the fallback for targets without the feature, and the loop tail.
  Keep it after the intrinsic ships.
- **Bit *i* ↔ byte *i*, lane 0 is the low bit.** What `@bitCast` on a bool vector
  produces, and what makes `@ctz` return a lane index.
- **Accumulate errors, test once.** `|=` into an accumulator across the whole
  loop; check after. Branching per block hands the predictor data-dependent work.
- **Read the asm.** `-femit-asm` and confirm the instruction you expected is
  there. Instruction count is not throughput — measure throughput.
- Every new kernel adds its case to `ref/SIMD-Strategies/verify.zig`, which
  differential-tests the vector path against the oracle on random data including
  block-boundary placements.

## This repo's compiler

Pinned to `0.16.0` via the root flake — the same version the reference tables
were verified on. If the pin moves, re-run `verify.zig` before trusting the
tables.

VerA-specific: the hot loop is the *emitted device code*, generic over the
contract scalar `S` (tools/contract.zig). A kernel that branches on data or
calls `.val()` for a per-value decision pins the whole eval scalar — use the
S select/clamp primitives instead. proof.zig's guard facts are the license:
a branch that guards a domain (`x > 0 ? ln(x) : 0`) may only become a select
if the guarded op's input is clamped into its domain first.

The `extern fn @"llvm.*"` trick (the only way to get a runtime `pshufb`/`tbl`,
since `@shuffle` needs a comptime mask) **requires the LLVM backend**. Under the
default self-hosted x86_64 backend it fails at link time:

```
error: undefined symbol: llvm.x86.ssse3.pshuf.b.128
```

Build such code with `-O ReleaseFast` or pass `-fllvm`.
