# Distribution reference behavior

VerA's integral-count chi-square, Student-t, and Erlang kernels follow IEEE
1364-2005 §17.9.3 without the former 4096-count substitution. Values and final
seeds are checked against a separately compiled C transcription in
`tests/rng_reference.c` (`zig build test-rng-reference`). The oracle uses
explicit 32-bit seed wrapping and disables floating-point contraction.

AMS 2023 §9.13.2 requires positive mean/df/stages for exponential, Poisson,
chi-square, Student-t and Erlang, and ordered real-uniform bounds. Constant
violations receive E0816; runtime violations report an error on both the value
and seed-update paths. Erlang checks its mean as well as its stage count.
A guarded source effect retains runtime validation even when the result and
updated seed are unused. Generated-device tests exercise skipped branches,
short-circuit operands, loops, and source-ordered errors (`zig build
test-rng-effects`); an unused variate does not force its draw loop.
Numeric diagnostics are eager only for proven unconditional constant calls.
Parameter defaults may be overridden, and short-circuit/conditional operands
must not report errors when skipped. Static signature and seed rules still
apply. Integer uniform's advisory bound ordering retains the reference behavior;
real uniform's mandatory ordering receives an error when violated.

Remaining limits:

- AMS accepts real df/stages, while the referenced C listing takes integer
  counts. Fractional counts and counts outside 1..2147483647 receive an explicit
  unsupported diagnostic, never truncation or substitution. Their legal AMS
  semantics remain unimplemented.
- The reference Erlang product can underflow to zero and produce infinity;
  Student-t can produce NaN or infinity. VerA preserves the listed operations
  and seed progression and no longer proves distribution calls finite by name.
- Poisson's reference `exp(-mean)` and cumulative product lose precision and
  underflow for large means. No alternate distribution algorithm is supplied.
- Integer wrapper results outside signed-32 range remain a separate limitation.
  Paramset folding diagnoses them before converting rather than crashing the
  compiler. General integer argument conversion and Monte Carlo scheduling are
  outside this change.
- Paramset cloning still folds random calls in unselected expression arms.
  Its short-circuit evaluation and seed sequencing require a separate fix.

These changes preserve the reference numerical sequence within this supported
scope; they do not close all of A07.
