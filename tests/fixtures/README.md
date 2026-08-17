# The torture suite

859 `.va` files. No sidecar files. One judge, `tests/harness.zig`, and two
runners that plug into it:

| runner | compiler | step | depth |
|---|---|---|---|
| `tests/torture.zig` | VerA, in-process | `zig build torture` | compiles, builds a testbench, RUNS it, checks every `ok=` |
| `tests/external.zig` | any compiler taking a `.va` path | `zig build conformance` | accept / reject only |

The fixtures state what the **LRM** requires, not what VerA does, so they are a
conformance suite for any Verilog-AMS compiler. `zig build conformance` defaults
to OpenVAF (`nix develop .#conformance` puts it on `PATH`); `--cc="…"` names any
other. Comparing the two runs is `diff` — same walk, same order, same verdict
vocabulary — and that comparison only means anything because both scores come
from the same judge.

Two things do **not** cross to a foreign compiler, and the harness knows it:

- the `//! reject` substrings are VerA's diagnostic codes, which nobody else
  prints, so `conformance` only requires that the compiler refused the file at
  all — the LRM claim ("§5.8 says this must not compile"), minus the wording;
- `//! xfail` is a statement about **VerA**, so it is ignored for anyone else.
  Honouring it would excuse another compiler for VerA's gaps *and* fail it for
  closing them.

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
be improved without touching 312 fixtures, and they pin WHICH rule fired rather
than how it happened to be worded.

## Citing the rule — `//! lrm`

```verilog
//! lrm 4.5.11
//! lrm A.8.3
```

One or more, naming the normative clause the fixture pins. A chapter number or
an annex letter, then dotted numbers. It is **not** an expectation and changes no
verdict — it does two things:

- a failing fixture prints its cites, so the report says which RULE broke and not
  only which file;
- `zig build torture -- --coverage` prints every cited section, sorted, with the
  fixtures citing it. That cannot prove a clause is *un*cited — nothing in the
  runner has the LRM's table of contents — but it makes the cited set greppable,
  diffable and countable, which is the only mechanical backing a "chapter 4 is
  covered" claim can have.

A cite that is not a section number is a fixture error and FAILs.

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
//! solve                          §5.6 the unknowns nothing above names are the
//!                                DEVICE's to determine, not the harness's
```

Every field has a default, so a `.va` with no directives is still runnable: one
operating point, every unknown at zero, every parameter at its §3.4 default. The
grammar is `src/backend/tb.zig`.

### `//! solve` — who determines an unknown nothing names

The testbench runs a real Newton-Raphson on the residual the device stamps, with
the Jacobian its own dual arithmetic carries and a dense LU under it. It has to:
§5.6.7's indirect contribution is a CONSTRAINT the simulator satisfies, not an
assignment, so `V(out): V(in) == 0` cannot be expressed by evaluating anything,
and §5.4.2.2's "the potential of a source branch may be read" is a question about
what the solver settled on.

What is NOT automatic is the netlist. A `.va` compiled alone is not a circuit —
nothing says what its terminals connect to — so by default the harness supplies
the only netlist it can and ties every unknown no `//!` line names to the
reference. That is why

```verilog
//! bias V(p) = 0.5
I(p,n) <+ V(p,n)/2000;
`CHECKX("Ohm's law at 0.5 V", V(p,n)/resistance, 2.5e-4);
```

means 0.5 V *across* the resistor. Solve the isolated device instead and `n` is
an open lead: KCL through it is zero current, so `n` follows `p` and `V(p,n)`
comes out 0. A hundred fixtures state a rule in that shape.

`//! solve` unties the rest. It composes with `bias` — `bias` still pins what it
names, `solve` frees only what nothing names — so a fixture needing one terminal
grounded and another determined writes both lines. Reach for it when the digit
under test is one the solver produces:
`ch05_analog_behavior/indirect_contribution.va`,
`annex_g_change_history/22_input_port_contribution_honoured.va`.

An unknown the device's own equations leave undetermined even then — the common
mode of a module that never references ground, or the row `I(p,n) <+ 0.0` stamps
— gets no pivot, holds its initial guess, and is excluded from the convergence
test. A testbench that genuinely fails to converge exits nonzero naming the
unknown that would not settle, so the fixture FAILs loudly instead of asserting
against a half-iterated number.

## Running

```
zig build torture                 # every fixture
zig build torture -- ch04         # only paths matching `ch04`
zig build torture -- --strict     # unasserted, CANNOT RUN and XFAIL fixtures FAIL instead of warn
zig build torture -- --coverage   # every cited LRM section and who cites it
zig build torture -- -j1          # one at a time, streaming; the debugging path
zig build torture -- --fixture-opt=ReleaseFast

zig build conformance             # the same fixtures against OpenVAF
zig build conformance -- ch04     # every flag above works here too, except
                                  # --fixture-opt, which is VerA's
zig build -Dconformance-cc="timeout 30 openvaf-r --dry-run" conformance
```

`-Dconformance-cc` is a whole command line, which is also where a timeout goes:
a foreign compiler that hangs is not the harness's problem to solve twice. It is
a build option and not a run-time flag because it names the compiler in the
report header, which is built before the arguments are walked.

A fixture is a `zig build-exe`, so the suite runs one per core by default (`-jN`
/ `--jobs=N` to change it). Workers finish in any order; the OUTPUT does not —
each buffers its whole report into the slot for its position in the sorted walk,
and the report is printed from those slots afterwards. A parallel run is
byte-for-byte the output of `-j1`. `-j1` keeps the fully sequential path, which
prints as it goes and is therefore the one to use when a run is stuck.

The fixture binaries are built `-ODebug`, and not out of caution about floats:
Zig has no `-ffast-math`, so float arithmetic is strict IEEE in every optimize
mode unless the code asks for `@setFloatMode(.optimized)`, which a generated
device does not. Debug is the default because a testbench compiles for seconds
and runs for microseconds — compile time *is* the run time, and ReleaseFast makes
the whole suite slower — and because Debug keeps the safety checks on, so a
codegen bug traps loudly instead of returning a plausible wrong number.
`--fixture-opt=<mode>` (or `-Dfixture-optimize=<mode>` at build time) is there to
ask the separate question "does this still pass under optimization?".

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

## Known gap — the `XFAIL` verdict

`CANNOT RUN` is the fixture being right and the *host* being unable. `XFAIL` is
the fixture being right and **VerA** being wrong. It marks either expectation,
because the gap comes in both directions.

Deleting such a fixture loses the requirement. Leaving it FAILing buries the
regressions. So it gets its own verdict, on exactly the terms `CANNOT RUN` gets:

- it is **not** a pass — nothing was proved;
- it is **not** a FAIL — the gap is known and written down, with its reason;
- `--strict` fails on it.

### On a `reject` fixture — VerA does not diagnose it

```verilog
//! lrm 3.6.2
//! reject E0421
//! xfail VerA does not check the discipline of a branch port yet
```

The LRM says the construct is an error, the fixture demands the diagnostic, and
VerA compiles it happily. The verdict is `XFAIL` instead of FAIL.

### On a run fixture — VerA does not compile it

```verilog
//! lrm 4.7.2.4
//! xfail VerA rejects an array formal in an analog function (E0511)
```

No `//! reject` line, so the fixture must compile, run, and print `ok=1` — that
is what the LRM says, because the LRM *prints this example*. VerA cannot get
there yet. Any failure at all is the one the fixture predicted: it did not
compile, codegen refused a construct, the testbench would not build, the binary
exited nonzero, or an assertion came back `ok=0`. All of them are `XFAIL`.

This direction is the common one, and it is why the marker has to work here.
Written the other way — `//! reject`, because VerA happens to refuse the
construct today — the fixture is **inverted**: it now demands a diagnostic the
LRM never asked for, a conforming compiler fails it, and only VerA passes. The
honest form is "this must run green" plus "we know it does not yet".

`CANNOT RUN` keeps priority over `XFAIL`. A fixture with no port list is refused
by the host whatever VerA does, and reporting that as a VerA gap loses which of
the two it was.

### Write the reason so it can be triaged

The reason is the only thing a reader gets — the failing output is not printed,
because for a known gap it is not news. So say **what VerA does not do**, not
that something is wrong:

- good: `xfail VerA rejects an array formal in an analog function (E0511)`
- bad: `xfail not supported yet`

A reason with a diagnostic code or a construct name is greppable, and tells the
next person whether their change closed this gap. "Not supported yet" makes them
rerun the suite to find out what was even being tested.

### XPASS is a hard FAIL

The day VerA does meet the rule, that fixture FAILs — both directions:

```
FAIL …/branch_discipline.va: XPASS — marked `//! xfail`, but VerA now rejects it
  exactly as the LRM says it must. Delete the `//! xfail` line: …

FAIL …/arrayadd.va: XPASS — marked `//! xfail`, but it compiled, ran, and printed
  ok=1 for every assertion. Delete the `//! xfail` line: …
```

That is the point of the verdict. A marker left on a rule VerA now meets stops
the fixture from ever being reported again, so the next regression there is
silent. The fix is one deleted line.
