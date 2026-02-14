# System-style operand-sensitive math typing

Source: AMS 2023 §4.3/§4.3.1, Table 4-14, printed pages 61–63;
integer division follows §4.2.4. Both traditional and system spellings are
listed, and integer operands retain integer results for `abs`, `min`, `max`.

## Defect and bounded repair

`lowerSysCall` previously emitted a generic `$abs`/`$min`/`$max` call;
`sysFuncTy`, which knows only the name, defaulted to real. Consequently
`$min(3,5)/2`, `$max(1,3)/2`, and `$abs(-3)/2` all yielded 1.5 instead
of integer quotient 1. This is a result-type defect, not a numeric tolerance
question; assigning the result to an integer would conceal it.

The repair routes exactly those three names through the operand-sensitive
builtin lowering after the existing system-call context checks. Integer
operands select `iabs`/`imin`/`imax`; real or mixed-real operands select
`fabs`/`fmin`/`fmax`. The downstream integer/real division selection then
receives the correct type. No backend helpers, differentiation rules, or
name-only return-type table entries change.

Compiler file: `lib/ir/lower.zig`.

- Current-root base SHA-256: `79972badbecdf1d8274e831ace9f1e6e8306618d1ab4c91403425443d12d8d67`.
- Patch SHA-256: `b91439183f119fb3355ba4401524a255ec940f353014fb19098e2537aed5734e`.

## Focused evidence

The following command exited zero in the isolated worktree, including after
formatting the added tests:

```sh
zig test --dep diag --dep frontend --dep kernels \
  -Mroot=lib/ir/root.zig -Mdiag=lib/diag.zig \
  --dep diag -Mfrontend=lib/frontend/root.zig \
  -Mkernels=lib/backend/kernels.zig --test-filter 'system math aliases'
```

It ran the root discovery test and two added tests: fourteen expression cases
check both the selected arithmetic opcode and the subsequent division opcode;
six wrong-arity expressions require E0506. Expressions cover traditional and
system spellings, integer operands, real absolute value, and both mixed-real
binary operand positions. These are lowering tests, not runtime execution.

Runtime oracle: `tests/fixtures/ch04_expressions/audit_system_math_result_type_division.va`.
Its three integer quotients must equal 1; five real/mixed-real neighbors must
equal 1.5. The companion traditional fixture must remain passing. The XFAIL
marker is deliberately retained for independent main-agent implementation
verification, after which it must be removed as implemented support without
deleting the fixture.

The isolated `zig build -Doptimize=ReleaseFast` exited zero. Running each
fixture through that compiler's `--emit-exe`, then executing the returned
testbench path, yielded all eight system observations `ok=1` and all six
traditional observations `ok=1`. The pre-fix root binary yielded three
integer `ok=0` observations (1.5 instead of 1), while all five system real
neighbors already had `ok=1`. Testbench exit zero alone was not treated as
the oracle: the individual `ok` observations were inspected. These isolated
results do not include other pending root changes or replace root integration
gates.

Full test-suite gates, FAIL/XFAIL name-list comparisons, and measured A/C
remain main-agent integration work. The separate min/max equality derivative
defect remains open; this patch does not repair or close it. Parameter constant
folding, digital interpreter behavior, integer-width boundaries, and arbitrary
nested/type combinations are not established by this bounded evidence.

Main integration checkpoint (2026-09-23): independently checked the source
typing rule and patch, then rebuilt the root CLI (`zig build install`, exit0).
The focused lowering tests passed, and all eight system-spelling runtime
observations reported `ok=1`. The fixture's XFAIL was retired as implemented
support; its checks were retained. Main `zig build test` exited0. The completed
strict-suite FAIL/XFAIL name list is byte-identical to the digital-negative
baseline; the new system-math fixture passes without weakening any old row.
The suite still exits1 for recorded existing debt. Measures A/C are regenerated
only by `tools/conformance.sh` in `conformance-measurement.md`.

Later bounded follow-up: the separately implemented tie-derivative repair and
its root runtime evidence are in `conformance-minmax-derivative-fix.md`.
