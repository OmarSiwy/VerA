# H01 — Parameters, paramsets and elaborated identity

Twelve fixtures: **eleven positive** (each asserts a hand-derived value) and
**one rejection**. Ten of the positives pass against VerA today. The two open
rows are fixture 10 (E1004 — a string comparison in a host-derived parameter,
which `lib/backend/codegen.zig` cannot render) and fixture 12, the rejection,
which is carried as an `//! xfail`.

Four of the ten passed from the start and are here because the row claimed them
with no fixture behind the claim — each still discriminates, see *The fixtures
that pass today* below.

## LRM clauses covered

| Clause | Sentence being pinned | Fixture |
|---|---|---|
| §2.8.1 | escaped identifiers: the backslash and the terminating white space are not part of the identifier | 07 |
| §3.2 | an integer variable holds −2³¹ … 2³¹−1 | 08, 12 |
| §3.4.1 | a value conflicting with the declared type is converted per §4.2.1.1 | 09, 12; 06 (a default shall be specified) |
| §3.4.2 | range checking applies to the value **for the instance**, not to the declared default; string ranges are written `from '{…}'` | 01, 11 |
| §3.4.4 | an array's range may depend on a parameter; resizing requires a new array from the same override list | 11 |
| §3.4.6 | string parameters as flags; the `ebersmoll` ±1 mapping | 01, 10 |
| §3.6.3 | a net declared with a range is a vector net — one declared name | 07 |
| §4.2.1.1 | real→integer rounds to nearest, ties away from zero | 09, 12 |
| §4.2.5 / §4.2.7 / §4.2.9 | one unsigned operand makes the whole comparison unsigned, with zero-extension (the sentence is printed after the bitwise tables in the 2.4 text) | 08 |
| §4.2.11 | `>>` fills vacated positions with zero | 08 (control) |
| §6.3.4 | a dependent parameter follows the final value of what it reads | 05, 10, 11 |
| §6.4 | a paramset's second identifier **may be another paramset**; a chain ends at a module, and the link associated with the module delivers its statements there | 02 |
| §6.4 | a paramset collects values so an instance "need only provide overrides for a smaller number of parameters" — an un-overridden paramset parameter is still an input | 06 |
| §6.4.1 | `.module_param = expr;` may read an out-of-module reference to another module's **localparam** | 03, 05 |
| §6.4.2 | selection rules 1–2 and the three tie-breaks; the clause's own four-`nch` table | 01, 04 |
| §6.9.2 | paramset selection happens during elaboration | 05 |
| §8.2 | elaboration is re-evaluated at every sweep sub-task | 05 |
| §9.19 | `$param_given` is 0 when nothing overrode the parameter, and 1 for a **module instance parameter value assignment** — the two bindings the clause's normative sentence names. Not asserted for a paramset statement; see *Withdrawn* below | 06 |

## One line per fixture

| # | File | Pins | Expected value and derivation | Today |
|---|---|---|---|---|
| 01 | `01_paramset_string_range_selection.va` | §6.4.2 selection rule 2 applied to a §3.4.2 **string** range | `sign = −1.0`, current `−0.5 A`. Two paramsets named `h01_type_ps`; the instance overrides `t` with `"PMOS"`, which only the second one's `from '{"PMOS"}'` admits, and that one writes `.sign = −1.0`; at `V=0.5` the contribution is `−1.0 × 0.5`. | passes, 2/2. Was E0914 (2 applicable): `inRanges` folded reals only and ignored `ValueRange.strings`, so both bins admitted and the tie-breaks could not separate them. It now has the string arm. |
| 02 | `02_paramset_chain.va` | §6.4 chained paramsets | `j = 2.0` from the far link (the one whose own second identifier is the module), so `j·V = 1.0 A` at 0.5 V; the module default is 0.0. The instance names the near link, which is not a module, so no path that skips the chain produces 2.0. The near link now carries only a paramset-variable declaration and assignment (Syntax 6-4's minimum body) — see *Withdrawn* below. | passes, 2/2. Was E0904 at line 68: `ps.target` was resolved with `findModule` only. `Flatten.paramsetChain` walks the chain; the links' statements are applied far-first, a precedence §6.4 does not state and nothing here asserts. |
| 03 | `03_paramset_oomr_localparam.va` | §6.4.1's permitted out-of-module read of a localparam | `k = h01_lib.tox × w = 3.0 × 2.0 = 6.0`, current `3.0 A`. The clause's own `semicoCMOS` example, with the `$rdist_` draws removed. | passes, 2/2. Was E0901: a path was resolved through the instance tree and the library module is never instantiated. `Flatten.paramsetOomr` substitutes the declared default inside a paramset expression, and §6.4.1's next sentence is now refused with E0907. |
| 04 | `04_paramset_overload_lrm_table.va` | §6.4.2's printed table, rows m3 and m4 | m3 `#(.l(1u),.w(10u))` → default bin: `u0=650`, `nfs=0.8e12`, `ad = w·0.5u = 5.0e−12`. m4 `#(.l(3u),.w(5u),.ad(1.2p),.as(1.3p))` → long-channel bin: `u0=640`, `nfs=0.7e12`, `ad=1.2e−12`. Mismatch bin excluded (default `mm=0` outside `(0:1]`), short-channel excluded by `l`, default beats long-channel on tie-break 1 (0 vs 2 un-overridden). One predicate keyed on `l`, verdict 1. | passes |
| 05 | `05_paramset_under_parameter_sweep.va` | §8.2 re-elaboration + §6.9.2 + §6.4.1 under a host `psweep` | `g = 3·w = 3·(2k) = 6k`, so `g/(6k) = 1.0` at every sub-task (k = 1 → g = 6; k = 3 → g = 18). Backstop: `k>2 ⇒ g>17`. | passes |
| 06 | `06_paramset_unoverridden_defaults.va` | §6.4 + §3.4.1 + §9.19: final values when nothing overrides | `k = 3.0 × w = 6.0` from the paramset's **un-overridden** default `w=2.0`; `untouched = 7.5` (module default, named by nobody — the "unused model default" that must not be rejected); current `3.0 A`. §9.19 on a second instance, `h01_given_probe #(.tdevice(27.0))`: `$param_given(tdevice)=1` where the override **equals** the declared default (§9.19's own `tdevice`/27 example) against `$param_given(untouched)=0` in the paramset instance. The pair rejects a constant-0, a constant-1 and a compare-value-to-default implementation. | passes, 6/6 |
| 07 | `07_escaped_name_vs_vector_element.va` | §2.8.1 vs §3.6.3: `\bus[0]` is a scalar net, `bus[0]` is a select on the vector | `V(bus[0]) = 3·(1/2) = 1.5 V`, `V(\bus[0]) = 3·(2/3) = 2.0 V`. Merged onto one node the four resistors parallel to `3·(2/3.5) = 1.714… V` and both checks miss. | passes, 2/2, with two separate unknowns in the solve. Was E0902: the escaped scalar was read as a second discipline declaration of the vector element, the node table being keyed on the printed form. `Lower.netKey` discriminates at the token and restores the `\` for a net name ending in `]`. |
| 08 | `08_mixed_sign_comparison_context.va` | context signedness across a compound expression | `a=−1`: `(a<1)=1`, `(a<32'd1)=0`, `((a+0)<32'd1)=0`, `(a==32'hFFFFFFFF)=1`, `(a>>1)=2147483647`. Rows 1 and 5 are controls for the rules that already hold. | passes, 5/5. Rows 2, 3, 4 used to answer 1, 1, 0 — the i64 carrier was compared signed, and E0364 refuses only the shift-versus-unsigned-comparison shape, which none of these is. `Lower.unsignedCompareMask` masks both operands to the wider width first. |
| 09 | `09_integer_parameter_host_override_rounding.va` | §4.2.1.1 on the **host override** path | `−1.5 → −2`, `35.5 → 36`, `35.2 → 35` (the clause's own examples), sum `69`. | passes, 4/4. The override used to be written verbatim into the model card, so `zig build-exe` died on "fractional component prevents float value '-1.5' from coercion to type 'i64'". `tb.cardValue` is §4.2.1.1's conversion, at both card-write sites. |
| 10 | `10_string_derived_parameter.va` | §6.3.4 dependence with a §3.4.6 string operand | `mk = (mode=="fast") ? 2.0 : 3.0` with `.mode("slow")` → `3.0`, current `1.5 A`; frozen at the default it reads 2.0. | **FAILS** — E1004, and the remaining open row of the twelve. Conditionals, short-circuit logic, `%`, `**`, shifts and the real math builtins all derive correctly (each checked while writing this); the string comparison is the single missing operand type. It is `lib/backend/codegen.zig`'s `f64Const`/`hostConditionalExpr` that cannot render one — `Lower`'s own folder was separately wrong about string comparison and has been fixed (`foldStrBinary`), but that path is shadowed by this refusal. |
| 11 | `11_dependent_range_and_array_override.va` | §3.4.2 instance-final range bound + §3.4.4 dependent array size | `hi→40`, `x→20` ⇒ `x/hi = 0.5` (the declared ceiling 10 would have refused it); `nn→3`, `c→'{2,4,8}` ⇒ `c[nn−1] = 8.0` and `c[0]+3c[1]+5c[2] = 54.0`, a weighting no permutation of {2,4,8} repeats. | passes |
| 12 | `12_nonfinite_real_to_integer_rejected.va` | §4.2.1.1 + §3.2: an infinity has no nearest integer and no §3.2-range answer | must be **refused**. The expectation is `//! reject LRM 4.2.1.1` — the clause the diagnostic must cite — because no code exists for this yet and naming one would pin an implementation choice. | **FAILS** — accepted, and the parameter comes out `9223372036854775807`, outside §3.2's range for the type, so a host cannot tell it from a real value. |

## The fixtures that pass today, and what each would catch

Passing at HEAD is not the same as having no teeth; a fixture is worthless only
if its asserted value is reachable without the rule. For each of the four that
already passed when this file was written:

- **04** — `u0`/`nfs`/`ad` differ between the candidate bins (650/0.8e12/5.0e-12
  vs 640/0.7e12/1.2e-12). Selecting the wrong paramset, or applying the tie-breaks
  in the wrong order, changes all three. Delete the selection logic and neither
  instance gets a value at all.
- **05** — the ratio `g/(6k)` is 1.0 only if elaboration is re-run per sweep
  sub-task; an elaboration frozen at the first point answers `6/18 = 0.333` at the
  second. The second line (`k > 2 ⇒ g > 17`) catches the opposite failure, a
  re-elaboration that reuses a stale override. Neither is reachable without §8.2.
- **06** — `k = 6.0` fails for any implementation that propagates only *overridden*
  paramset parameters (it reads 0.0, an open circuit). The `$param_given` pair is
  constructed so that no constant answer and no value-vs-default comparison passes
  both, because the probe's override and its declared default are the same number.
- **11** — `x/hi = 0.5` is wrong under the declared-default ceiling (2.0) and wrong
  again if the override is dropped (0.025); `c[0]+3·c[1]+5·c[2] = 54.0` is unique to
  `{2,4,8}` in that order, so a wrongly-sized or wrongly-filled array shows up.

## Withdrawn after review — claims this row no longer makes

Neither of these is asserted anywhere else in the suite; **no row owns them**, and
they are not counted as covered in the clause table above.

- **A near link's `.module_parameter` statement reaching the end module** (was
  fixture 02's `k = 5.0` and the 7.0 / 3.5 A sum). §6.4 says a chain may exist and
  must end at a module; it does not say what `.k = 5.0` targets when the near
  link's associated thing is a paramset with no parameter `k`, and Syntax 6-4
  offers no production for assigning a nested paramset's parameter either. The
  grammar's `module_parameter_identifier` argues the module; §6.4.1's "parameters
  of the **associated** module" argues the near link may only refine the far link,
  under which reading the old file was ill-formed. Comes back when §6.4/§6.4.1 (or
  an erratum) names the target, and settles precedence when both links assign the
  same parameter. VerA now walks the chain and applies the links far-first, so
  the NEARER link wins — a precedence chosen for the implementation, recorded at
  `paramsetOverrides`, and asserted by no fixture.
- **`$param_given` = 1 for a value supplied by a paramset statement** (was fixture
  06). §9.19's normative sentence lists `defparam` and module instance parameter
  value assignment; a paramset statement is neither, while the clause's descriptive
  sentence ("obtained from the default value in its declaration statement or …
  overridden") points the other way. Observation, not a claim: VerA answers 1 —
  the reading this row would have taken. Comes back if §9.19's list grows a third
  item.

## Deliberately NOT covered

- **Paramset output variables (§6.4.3) and the `analog_function_statement` body
  the parser drops.** Unreachable from this suite's oracle. A paramset output
  variable is a value the simulator *reports* for the instance; §6.4.3 gives no
  way to read it back inside the module, and there is no `//!` directive for an
  operating-point table the way `//! noise` exists for §4.6.4's generators. The
  parser's skip (`Parser.parseParamset`, the `else` arm) was confirmed by reading
  it, and a paramset carrying an `if`/`else` over its own variables beside a
  `.module_param =` statement was confirmed to compile with the statement dropped
  and the parameter unharmed. Closing this needs an output-variable table on the
  emitted device plus a directive to assert it — the same shape `//! noise` took.
  Until then any fixture here would assert only acceptance.
- **Host-override range checking (§3.4.2's "error … during simulation").** A
  `//! param x = 20.0` against `from [0:10]` is accepted and runs, for both
  literal and parameter-dependent bounds. The instance-line equivalent *is*
  diagnosed (E0361), so the gap is the model-card path only. Left out because
  the device ABI exports no per-parameter range table for a host to check
  against and no exit-status contract for "the card is invalid" — the fixture
  would be asserting a mechanism that does not exist yet rather than a rule.
  Noted in 11's header.
- **`W0651` on `from [0:hi]`.** A range whose bound is a parameter is reported as
  "parameter range admits infinity". Cosmetic, not a conformance break, so no
  fixture.
- **§6.4.1's prohibition** on an out-of-module reference to a *non-local*
  parameter. It is a rejection and 03 already covers the permission; the row's
  rejection budget went to 12.
- **`aliasparam` on a paramset parameter** (`#(.trise(5.0))` reaching `dtemp`
  declared in the paramset) — verified working, but `ch03_data_types/
  07_parameter_alias.va` and `78_alias_double_override.va` already own §3.4.7,
  so it would be a third fixture on a covered clause.
- **§6.4.2's m1/m2 rows** (the mismatch paramset), which need §9.13's
  `$rdist_normal` with a `type_string` and belong to that row's coverage.
- **`defparam` interacting with paramsets.** §6.4 forbids it outright ("the only
  restriction on the associated module is that it does not contain a defparam
  statement in or under its hierarchy"); that is a rejection and out of budget.

## Running these

Not wired into any build step — `zig build torture` walks `tests/fixtures` only
(`build.zig`, `suite_opts.fixture_root`). One file at a time:

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build            # refresh zig-out/bin/vera
zig-out/bin/vera --run \
  -I tests/fixtures \
  --contract tools/contract.zig \
  tests/pending/H01/01_paramset_string_range_selection.va
```

The whole directory, with the verdict column pulled out:

```sh
for f in tests/pending/H01/*.va; do
  echo "== $(basename "$f")"
  zig-out/bin/vera --run -I tests/fixtures --contract tools/contract.zig "$f" 2>&1 |
    grep -E 'got=|^error'
done
```

Once the row lands, move the files into `tests/fixtures/ch06_hierarchy/`
(01–06), `ch03_data_types/` (09, 11, 12), `ch04_expressions/` (08),
`ch02_lexical/` (07) and re-run `zig build torture -- --strict`; the `//!`
headers are already in the suite's format and need no edit.

`--run` was re-checked against every file in this directory while writing the
section below; the verdict column above is that run, not a recollection. Note
that `--run` does not enforce `//! reject`, so 12 prints a solved point (with the
saturated `9.223372e18` derivative) rather than a verdict — only `zig build
torture` grades it.

## Corrected after review

The audit found two fixtures in this row "pinning interpretations presented as
derivations" (MANIFEST §5.3) and noted the row keeps four already-passing
fixtures (§5.2 records the row's citations as clean, and §5.5/§5.6 name no H01
defect). What changed:

1. **Fixture 02 no longer asserts the near link's `.k = 5.0`.** §6.4 was opened
   and quoted in full: it licenses the chain and requires it to end at a module,
   and says nothing about the target of a near-link statement. The file now
   asserts only the far link's `.j = 2.0` and the 1.0 A it produces at the biased
   0.5 V — still unreachable without walking the chain, since the instance names a
   paramset. The near link keeps the smallest body Syntax 6-4 admits (one `real`
   declaration, one assignment to it), which is legal under both readings of
   §6.4.1. The withdrawal, both readings, and what would bring the claim back are
   in the file header and in *Withdrawn after review* above. (At the time of the
   repair this still stopped at E0904, line 68; the chain has since been
   implemented and the fixture is green, 2/2.)
2. **Fixture 06 no longer asserts `$param_given(k) == 1` for a paramset
   statement.** §9.19 was opened: the normative sentence names `defparam` and
   module instance parameter value assignment only. The `0` half is kept (nothing
   overrides `untouched`, so every reading answers 0) and the `1` half is now made
   where §9.19 makes it — on a second instance
   `h01_given_probe #(.tdevice(27.0))`, the clause's own `tdevice`/27 example,
   where the override carries exactly the declared default. That pairing is what
   keeps the check from being satisfiable by a constant or by comparing the final
   value with the declaration default. Re-checked: 6/6 `ok=1`.
3. **The four passing fixtures now carry their discrimination argument** in *The
   fixtures that pass today* rather than a bare disclosure that they pass.
   None was found vacuous, so none was deleted; 04, 05 and 11 are unchanged.

Not changed, and why: fixture 12's `//! reject LRM 4.2.1.1` is deliberately a
clause substring rather than a code. It is not a bare `//! reject` — `torture.zig`
`failureContains` searches each diagnostic's notes, and every VerA diagnostic
renders `= note: LRM <section>` (verified on E0904 and W0850), so the directive
demands a refusal that cites §4.2.1.1 specifically. A code would pin an
implementation choice for a diagnostic that does not exist yet.
