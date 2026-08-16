# TODO — LRM non-conformance, and the fixtures that cannot run

Everything the torture suite currently reports against `docs/VAMS-LRM/`. Each
item names the clause it violates, the code that violates it, and the fixture
that catches it, so nothing here rests on memory.

```
zig build torture            # 857 fixtures
zig build torture -- ch09    # one group
zig build torture -- --strict
```

Today: **816 pass · 19 FAIL · 24 CANNOT RUN**, of 859.

The three buckets are different claims. A FAIL means a fixture states an
expectation, derived from the LRM by a human, that VerA does not meet. CANNOT
RUN means the fixture is right and there is no move its author can make — the
device contract refuses the module before any assertion can execute. A pass
means the `ok=1` column came out, nothing more.

None of this was visible before the suite was rewritten: three of the four old
runners never executed a device, and the fourth compared against `.expected.txt`
transcripts generated from VerA's own output, so any answer that had been wrong
since the recording passed.

---

## 1. Not implemented, and not declared — §9.5 file I/O (6 fixtures)

`$fopen` `$fclose` `$fdisplay` `$fwrite` `$fstrobe` `$fmonitor` `$fflush`
`$fgets` `$fscanf` `$ftell` `$fseek` `$rewind` `$feof` `$ferror` all sit in the
`void_tasks` array at `src/backend/codegen.zig:2671` and evaluate to
`S.con(0.0)`. `src/ir/lower.zig`'s `isDisplayTask` excludes the family on the
grounds that "it needs a descriptor the compiled device has no way to own".

That reasoning holds for a `.so` loaded by a host, but `--emit-exe` produces an
ordinary program with a filesystem, and the `--display=drop|emit` split is
exactly the knob that already distinguishes those two worlds.

**The real defect is the silence.** `$random` is refused with `E0801` and a
dropped display task warns with `W0850`; the §9.5 family returns zero with no
diagnostic at all. A model that opens a log and writes to it compiles clean,
runs, and produces no file and no warning. Table 9-2 marks every one of these
"Supported in analog context: **Yes**", so this is not a digital-only surface
being correctly ignored.

Fixtures: `ch09_system_tasks/039_fdisplay`, `052_fflush`, `053_ferror`,
`07_file_open_close`, `08_file_output`,
`combined/08_file_and_display_side_effects`.

The assertions are §9.5.1's own bit rules — `(fd & 32'h8000_0000) != 0` for
"bit 31 … shall always be set", and `(fd & 32'h7fff_ffff) > 2` for "three file
descriptors are pre-opened". Neither is a guess.

`053_ferror` is worth reading on its own: it fails because **two stubs
contradict each other**. `$fopen` returning 0 means "the open failed" (§9.5.1);
`$ferror` returning 0 means "no error" (§9.5.7). The pair is the violation, not
either member. Implementing `$fopen` alone makes it pass.

**Minimum honest fix if the feature is not wanted:** a diagnostic. The silence
is the bug; an unimplemented task that says so is defensible.

---

## 2. `$sscanf` cannot work without an out-argument mechanism (3 fixtures)

`$sscanf` is in the same `void_tasks` array, so `code` is 0. The deeper problem
is that its output argument can never be written: `lowerSysArg` in
`src/ir/lower.zig` lowers **every** argument through `lowerExpr`, i.e. as a
**read**. The MIR has no by-reference or call-writes-a-variable concept.

So this is not a value swap like §1 — it needs a new argument mode in
`Lower`/`Mir` before `$sscanf`, `$fscanf` or `$swrite` can be more than a stub.
`$sformat` is absent from `src/` entirely and survives in `09_string_formatting`
only because its result is unused, so codegen never reaches the call.

LRM §9.5.4.2: "The number of successfully matched and assigned input items is
returned in `code`." Table 9-2 marks `$swrite`/`$sformat`/`$sscanf` **Yes** in
the analog context.

Fixtures: `ch09_system_tasks/048_sscanf`, `10_file_read_scan`,
`09_string_formatting`.

---

## 3. `ln1p` and `expm1` are computed naively — §4.3.1 (3 fixtures)

In `src/backend/codegen.zig`:

```zig
fn zExpm1(comptime S: type, a: S) S { return a.exp().addC(-1.0); }
fn zLn1p(comptime S: type, a: S) S { return a.addC(1.0).log(); }
```

These are the two formulas the functions exist to avoid. Verified bit-exact:

| | |
|---|---|
| `ln1p(5e-16)` returns | `4.440892098500625e-16` |
| naive `ln(1+x)` | `4.440892098500625e-16` — identical |
| correct `log1p(x)` | `4.999999999999999e-16` |

`1 + 5e-16` rounds to a value whose logarithm has lost every digit the clause
was written to preserve. `expm1` is the same story through `exp(x) - 1`.

**Why it is not a one-line fix.** The scalar type's `map(a, value, derivative)`
— the one thing that would set a precise value without disturbing the autodiff
derivative — is **not `pub`**, and the device's `S` comes from
`tools/contract.zig`, not from codegen. The fix is to add `ln1p`/`expm1` as
primitives on the scalar interface, the way `exp`/`log` already are, in all
three definitions: the dual `S` in `tools/contract.zig`, the value-only `R` in
`src/backend/codegen.zig`, and `T` in `src/backend/tb.zig`. That is a device-ABI
change and wants its own review.

Derivatives are unaffected — `d/dx ln1p(x) = 1/(1+x)`, `d/dx expm1(x) = exp(x)`.
Only the value needs the careful path.

Fixtures: `ch04_expressions/33_ln1p_expm1`, `ch09_system_tasks/092_ln1p`,
`093_expm1`.

---

## 4. Three rules the LRM makes errors, and VerA accepts (3 fixtures)

Each compiles cleanly today. The other eleven rules in this family were closed
(`E0332`–`E0336` for the §3.6/§3.13 nature and access rules, and §4.7.3
recursion via a declaration-time call-graph check); these three were not.

| fixture | clause | the normative words |
|---|---|---|
| `annex_f_resolution/conflicting_declarations` | **§7.4.4** | "More than one conflicting discipline declaration … for the same hierarchical segment of a signal **is an error** … conflicting simply means an attempt to declare more than one discipline regardless of whether the disciplines are compatible or not." |
| `ch06_hierarchy/generate_nested_region_rejected` | **§6.6** | "Generate regions **do not nest**, and they **may only** occur directly within a module." |
| `ch06_hierarchy/generate_nonconstant_rejected` | **§6.6** | "all expressions in generate schemes **shall be constant expressions**, deterministic at elaboration time." |

§7.4.4 is the body clause and is stronger than the Annex F restatement, which
F.1 hedges as "a *possible* algorithm". Both generate rules are also enforced by
the Annex A grammar: `generate_region` appears only in `non_port_module_item`,
never in `module_or_generate_item`, and `if_generate_construct` takes a
`constant_expression`, which admits no `integer` variable.

Secondary defect in both generate fixtures: their bodies (`if (1) I(p) <+ V(p);`)
are ungrammatical too — `generate_block ::= module_or_generate_item | begin … end`,
and a bare contribution is not a `module_or_generate_item`.

---

## 5. `%c` breaks the generated testbench — §9.4.2 (1 fixture)

`ch09_system_tasks/06_display_formats` does not compile:

```
std/Io/Writer.zig:1086: error: expected type 'u8', found 'i64'
    'c' => return w.printAsciiChar(value, options),
```

The `%c` conversion hands an `i64` to `printAsciiChar(c: u8)`; it needs a
truncating cast at the emit site. Unlike everything in §1–§4 this is a plain
codegen bug, not a policy question.

---

## 6. A fixture the compiler outgrew (1 fixture)

`ch04_expressions/87_wrong_discipline_access` is a **positive** fixture that
contains `V(p)` where `p`'s discipline declares `access = CustomV`. The new §4.4
check (`E0501`, the same work that closed `ch03_data_types/42`) now correctly
rejects that line, so the whole file fails to compile and its `CustomV`
assertion never runs.

Its own comment says the `V(p)` contribution "is left exactly as it was" — it
was authored while VerA still wrongly accepted it.

**The compiler is right and the fixture is wrong.** It needs splitting: the
legal `CustomV` half stays a positive fixture, the `V(p)` half becomes a
`//! reject E0501`.

---

## 7. Parameter dependence stops at arithmetic — §6.3.4 (1 fixture)

`derive()` recomputes a dependent parameter from the current model card, but the
renderer behind it (`f64Const` in `src/backend/codegen.zig`) only knows
arithmetic, `abs`, `sqrt`, `min`, `max` and `pow`. A default it cannot render
gets **no derive line at all** and keeps the initializer folded against the
declared defaults, so an override never reaches it. §6.3.4 puts no such limit on
the dependent expression.

Generated `Model` for `parameter real a = 2.0; parameter real x = exp(a);
parameter real y = 2.0*a;`:

```zig
a: f64 = 2.0,
x: f64 = 7.38905609893065,   // exp(2.0) — frozen, no derive line
y: f64 = 4.0,
pub fn derive(model: *Model) void { model.y = (2.0) * (model.a); }
```

The silence is the hazard: two parameters sit side by side, one tracks and one
does not, and nothing in the source or the diagnostics says which.

Fixture: `ch06_hierarchy/dependent_parameter_transcendental`, which asserts both
so a fix that repaired one by breaking the other still fails.

---

## 8. `analog initial` does not re-run on a parametric sweep — §5.2.1 (1 fixture)

`src/ir/lower.zig` lowers an `analog initial` block as its body guarded on a
synthetic `initial_step`. The two coincide everywhere the suite previously
looked, and diverge on a sweep. §5.2.1:

> "The analog initial block is executed once for each analysis, and can be
> executed for each sub-task of parameter sweep analysis (such as dc sweep). …
> If a parameter or variable that is referenced from an analog initial block is
> changed during a sub-task of a parameter sweep analysis, then the analog
> initial block **shall be re-executed** so that the new value is taken into
> account."

`initial_step` never re-runs — Table 5-1 makes it the *first point* of an
analysis, and a dc sweep is one analysis whose points are its sub-tasks.

The observed behaviour is worse than a stale value: **10 at the first sub-task,
then 0**, because the block does not re-run *and* a module variable is
re-initialised from its declaration each evaluation, so nothing re-seeds it. A
model doing `analog initial` setup on a sweep gets zero, not a slightly outdated
number, and zero is much likelier to divide.

Fixture: `ch08_scheduling/analog_initial_parameter_sweep`.

Writing it needed a new harness directive. §5.2.1 forbids access functions
inside an analog initial block, so a node voltage can never be what the block
reads — only a parameter change is observable, and `//! sweep` sweeps unknowns.
`//! psweep <param> = …` (`src/backend/tb.zig`) gives each point its own model
card and its own `derive()` call, which is what §8.2 sub-tasks are. It is gated:
with no `psweep` line the runner emits exactly what it did before.

---

## 9. Known non-conformance that no `.va` fixture can express

Real, and deliberately left uncovered — a fixture for these would have to assert
something the LRM does not fix, or something no Verilog-A source can observe.
Recorded so they are not rediscovered and not "fixed" with a fake test.

- **`$simparam$str("cwd" | "instance" | "path")`** returns `""`. §9.15 says
  Table 9-28 "**shall be supported**", with none of the "if they support the
  parameter" hedge Table 9-27 carries — but the LRM assigns these no value, so
  there is no literal a fixture could name. (`analysis_type` and `module` *are*
  implemented; those are the two a flat elaborated device can answer honestly.)
- **`localparam` is enforced by overwrite, not by absence.** §3.4.5 says a local
  parameter "shall not be directly modified". `derive()` overwrites any host
  write, so behaviour conforms; what does not is the generated `Model`, which
  still exposes the field as writable. No `.va` can write to a `Model` field, so
  this needs a Zig-side test against `tools/contract.zig`, not a fixture.
- **`$driver_next_state` / `$driver_state` / `$driver_strength`** — one blanket
  `return @as(i64, 0)` in `src/backend/codegen.zig` covers seven functions with
  different specified behaviours. Zero is genuinely right for the *counts*
  (`$driver_count`, `$receiver_count`: a flat analog device has no digital
  drivers) and for `$driver_type` (0 = `DRIVER_UNKNOWN`), but §9.23.2 says
  `$driver_next_state` "returns the *current state*" when there is no pending
  state. `$driver_delay` has been split out — §9.23.1 types it **real** and
  gives it a `-1.0` sentinel, and leaving it in the integer list stopped
  generated devices compiling at all.
- **`$simparam$str`** answers only `analysis_type` and `module`. The remaining
  Table 9-28 names (`cwd`, `instance`, `path`) return `""`, which is the honest
  answer for a flat elaborated device with no view of the host's filesystem or
  instance hierarchy — but §9.15 says Table 9-28 "**shall be supported**", with
  none of the "if they support the parameter" hedge Table 9-27 carries.
- **`analog initial` is modelled as a guard on `initial_step`**
  (`src/ir/lower.zig`). Observationally identical today, but §5.2.1 ("executed
  once for each analysis") and §5.10.2 (Table 5-1: `initial_step` is the *first
  point* of an analysis) diverge on a dc **sweep**, where §5.2.1/§8.2 require
  re-execution per sweep point and `initial_step` does not fire.
- **`localparam` is enforced by overwrite, not by absence.** §3.4.5 says a local
  parameter "shall not be directly modified"; the generated `Model` still
  exposes it as a writable field and `derive()` overwrites any host write. The
  field has to stay, because unit bodies render a `param_ref` as `model.<name>`.
- **String-typed and non-arithmetic derived parameters get no `derive` line.** A
  default like `parameter real x = exp(a);` is outside `f64Const`'s op set
  (arithmetic, `abs`, `sqrt`, `min`, `max`, `pow`) and keeps its folded
  initializer, so §6.3.4 propagation silently does not apply to it.

---

## 8. CANNOT RUN — 24 fixtures blocked by the device contract

A module with **no port list** is legal (Annex A.1.2 makes the port list
optional) and VerA compiles it correctly. The emitted device then has zero
terminals and `tools/contract.zig` refuses it:

```
<name>.device.num_ports must be in 1..|U|
```

No testbench links, so no assertion can execute. These are **not** fixture
defects and **not** compiler conformance bugs — a device with nothing to stamp
is a real design question. They get their own verdict so they neither inflate
the pass count nor bury the genuine failures above, and `--strict` fails on
them, so the limitation cannot be carried for free and forgotten.

**Do not add ports to make them run** — that changes what the fixture tests.

`annex_a_syntax/01_source_text.va` is blocked twice over. It puts four
descriptions in one file to exercise `source_text ::= { description }`, but
`lowerFile` in `src/ir/lower.zig` elaborates only `modules[0]` — documented as
deliberate ("One flat module is the whole scope today", §6.2.2 instantiation
being rejected by the parser) — so the DUT becomes the port-less first module
and the only module with ports is never lowered.

```
annex_a_syntax/01_source_text.va
annex_c_analog_subset/07_discrete_discipline_current_behavior.va
annex_d_standard_definitions/discrete_disciplines.va
annex_d_standard_definitions/kinematic_definitions.va
annex_d_standard_definitions/literal_kinematic_disciplines.va
annex_d_standard_definitions/literal_logic_discipline.va
annex_d_standard_definitions/literal_magnetic_discipline.va
annex_d_standard_definitions/literal_rotational_disciplines.va
annex_d_standard_definitions/magnetic_definitions.va
annex_d_standard_definitions/rotational_definitions.va
annex_f_resolution/discrete_discipline.va
ch02_lexical/08_string_escapes.va
ch02_lexical/21_operator_attribute_rejected.va
ch02_lexical/22_unsized_based_rejected.va
ch02_lexical/23_signed_based_rejected.va
ch03_data_types/03_string_variables.va
ch03_data_types/17_string_parameter_range.va
ch03_data_types/19_discipline_override.va
ch03_data_types/20_derived_nature_from_discipline_rejected.va
ch03_data_types/30_natureless_discipline.va
ch03_data_types/31_domainless_discipline.va
ch06_hierarchy/module_definition.va
ch06_hierarchy/top_level_module.va
ch07_mixed_signal/discrete_discipline.va
```

Several `annex_d` entries need a second thing after the port question is
settled: `literal_kinematic_disciplines`, `literal_magnetic_discipline` and
`literal_rotational_disciplines` reference natures (`Position`, `Velocity`,
`Force`, `Magneto_Motive_Force`, `Flux`, `Angle`, `Angular_Velocity`,
`Angular_Force`) that are **not declared in the file**, so their access
functions would not resolve even with a port. `literal_logic_discipline` has
nothing numeric to assert at all — a `domain discrete` discipline has no
potential or flow access function, so its real content is "this parses and
elaborates", which the compile step already covers.
