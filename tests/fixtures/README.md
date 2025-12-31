# The torture suite

857 `.va` files. One runner, `tests/torture.zig`. No sidecar files.

A fixture states its own expected behavior, in the file, in one of exactly two
forms. Nothing else is needed to read it, and there is no second file to drift
out of step with it.

## A fixture that must be rejected

```verilog
//! reject E0130
```

Must NOT compile, and every `//! reject` substring must appear in the resulting
diagnostic. A line is either a diagnostic CODE (`E0130`, `W0650`), a phase label
(`ParseError`, `DiagnosticsReported`), or a message substring.

Codes are the preferred form: they are stable, so the prose of a diagnostic can
be improved without touching 301 fixtures, and they pin WHICH rule fired rather
than how it happened to be worded.

## A fixture that must run

Everything else. It compiles, becomes a native testbench binary, runs, and must
print `ok=1` for every assertion it makes.

```verilog
`include "check.vh"
module ex042_trigonometric(p, n);
  inout p, n;
  electrical p, n;
  analog begin
    `CHECKR("sin(0.5)", sin(0.5), 0.479425538604203, 1e-15);
    I(p, n) <+ 0.0;
  end
endmodule
```

```
sin(0.5) got=0.479425538604203 want=0.479425538604203 ok=1
```

### The `want` is a literal, and that is the whole design

This suite replaced one whose oracle was VerA's own recorded output. A wrong
answer, once recorded, was frozen as correct forever — and a reviewer's only job
was to accept a diff they had no way to check.

So the assertion is not a recorded transcript. It is the `ok=` column the fixture
computes itself, against a number a human derived from the LRM. `torture.zig`
enforces this mechanically:

- the `want` must be a **numeric literal** — no `` `M_PI ``, no `1.0/3.0`, no
  identifiers. Write the digits. An expression lets VerA supply its own
  expectation, which is the failure mode this exists to kill.
- `got` and `want` must not be the same expression. That cannot fail.
- a fixture that asserts nothing is reported, and fails under `--strict`.

A reviewer checks the digits once, against the LRM, without running anything.
After that a regression turns `ok=1` into `ok=0`.

### Macros — `check.vh`

| Macro | Use |
|---|---|
| `` `CHECK(NAME, GOT, WANT, TOL) `` | absolute tolerance; values near zero |
| `` `CHECKR(NAME, GOT, WANT, RTOL) `` | relative tolerance; magnitudes spanning decades |
| `` `CHECKX(NAME, GOT, WANT) `` | exact equality, reals the LRM defines to the last bit |
| `` `CHECKI(NAME, GOT, WANT) `` | exact equality, integers |
| `` `CHECKEQ(NAME, GOT, WANT, TOL) `` | **relational** — two VerA expressions must agree |

`CHECKEQ` is the only form whose want may be an expression, and it is a weaker
claim: an error common to both sides passes it. It exists for rules the LRM
states as an identity with no value to write down — `V(br)` must equal
`V(a,b)`, `$ln(x)` must equal `ln(x)`, an `aliasparam` must name the same
storage. It is a separate macro rather than a relaxation of `CHECK` so the
weaker claims stay greppable. If you can write digits, write digits.

Assertions must be **unconditional**. VerA hoists display tasks into one
straight-line unit, so a task under an `if` is dropped with W0851. A comparison
is an integer in Verilog-A (§4.2.5), so the verdict is an operand, never a branch.

### Operating points — `//!` directives

A device's inputs are node voltages the host supplies; nothing in the source says
which ones are interesting. `//!` comment lines say. They survive the
preprocessor untouched (§2.4 makes them comments) and leave the `.va` compilable
by any other tool.

```
//! bias V(p) = 0.7
//! sweep V(in) = 0, 0.5, 1.0     cartesian product, last line varies fastest
//! param w = 1e-6
//! temp 300.15                    §9.10 $temperature, kelvin
//! time 0, 1n, 2n                 §4.5 stateful operators need a history
//! wave V(in) = 0, 1, 1           one entry per `time`; a short list holds
//! analysis dc                    §4.6.1
//! print none                     drop the residual dump; for §9.4 format tests
```

Every field has a default, so a `.va` with no directives is still runnable: one
operating point, every unknown at zero, every parameter at its §3.4 default. The
grammar is `src/backend/tb.zig`.

## Running

```
zig build torture                 # every fixture
zig build torture -- ch04         # only paths matching `ch04`
zig build torture -- --strict     # unasserted and CANNOT RUN fixtures FAIL instead of warn
```

## Known blocker — the `CANNOT RUN` verdict

A module with **no port list** is legal per Annex A.1.2 and VerA compiles it, but
the emitted device has zero terminals, and `contract.validate` refuses it with
`num_ports must be in 1..|U|` — a device with nothing to stamp is a real design
question, not a test problem. So those fixtures cannot be run at all.

They get their own verdict, `CANNOT RUN`, printed with its count and reason:

- it is **not** a pass — nothing was proved;
- it is **not** a FAIL — the fixture is right and its author has no move to make,
  and reporting it as FAIL buries the real conformance bugs in noise;
- `--strict` fails on it, so a limitation carried for free is not one forgotten.

The runner matches that one contract message and nothing else. Every other way
the generated testbench can fail to compile is a genuine codegen bug and still
FAILs loudly.

Do not add ports to work around it — that changes what the fixture tests.
