# A08-nodeset — §3.6.3.2 net discipline initial (nodeset) values

## LRM clauses covered

**Accellera Verilog-AMS LRM §3.6.3.2 "Net Discipline Initial (Nodeset)
Values"** (`docs/ch3-datatypes.html`; the tree's `docs/` is the Accellera
Std VAMS-2023 transcription — see `docs/index.html`, "full transcription of
Accellera Std VAMS-2023 (Feb 14, 2024)" — and the same clause text and
numbering is in `docs/VAMS-LRM-2-4.pdf`). An earlier revision of this file
attributed the clause to "IEEE 1800.2". That is the UVM standard and has
nothing to do with nodesets; the misattribution is corrected here and nowhere
else in the row repeats it.

Quoted in full for the two sentences these fixtures pin:

> Nets with continuous disciplines are allowed to have initializers on their net
> discipline declarations; however, nets of non-continuous disciplines are not.
>
> ```
> electrical a = 5.0;
> electrical [0:4] bus = '{2.3,4.5,,6.0};
> mechanical top.foo.w = 250.0;
> ```
>
> The initializer shall be a *constant_expression* and **will be used as a
> nodeset value for the potential of the net by the analog solver**. In the case
> of analog buses, a constant array expression is used as an initializer. **A
> null value in the constant array indicates that no nodeset value is being
> specified for this element of the bus.**
>
> If different nets of a node have conflicting initializers, then initializers
> on hierarchical net declarations win. […] If the multiple conflicting
> initializers are not hierarchical, then it is also a race condition for which
> the initializer wins.

Supporting clause for the syntax: **Syntax 3-6 / A.2.4** `net_decl_assignment ::=
ams_net_identifier = expression`.

### What Annex A does and does not say about the null element

The `'{...}` initializer reaches, from `net_decl_assignment`'s `expression`,
the A.8.1 production

```
constant_assignment_pattern ::=
        '{ constant_expression { , constant_expression } }
      | '{ constant_expression { constant_expression { , constant_expression } } }
```

**Neither alternative admits an empty element.** A.8.3 separately defines
`constant_expression_or_null ::= [ constant_expression ]` — the shape a
corrected A.8.1 would use — but no A.8.1 production references it. So Annex A
**cannot settle** whether `'{2.75, }` is legal, and the normative authority for
this row is §3.6.3.2's sentence plus its own printed example `'{2.3,4.5,,6.0}`,
which the grammar as published cannot derive. This is an internal inconsistency
in the LRM, recorded here rather than resolved.

An earlier revision of this file wrote "(annex A.8.3)" as though the grammar
were the authority for the refusal. It is not: `A.8.3` is the static `.lrm` tag
that `lib/diag_code.zig:1198` attaches to **every** E0209 "expected an
expression", generic to the code and not chosen for this construct.
`lib/frontend/parser.zig:4264` already carries a comment quoting §3.6.3.2's
null-element sentence next to the code that refuses it.

## The defect, confirmed independently

### (a) What VerA emits

`lib/backend/codegen.zig:1743` `emitNodesets` writes one module-level constant:

```zig
pub const u_nodeset = [n_u]?f64{ 2.75, null };
```

Type `[n_u]?f64`, indexed by the `U` unknown enum (ports first, then internal
nets, then §5.4.2 branch-flow unknowns). `null` means "no opinion" — both for an
unknown that is not a declared net and for the LRM's null bus element.
Semantics per the emitted doc comment: *"the initial guess the source states for
each unknown's potential. A HINT to the solver — not an initial condition and
not a clamp."* Emitted only when the module declares at least one nodeset
(`lib/ir/lower.zig:316`, `lower.nodesets`); absent otherwise. Reproduced:

```
$ ./zig-out/bin/vera --emit-zig --contract tools/contract.zig -I tests/fixtures \
      tests/pending/A08-nodeset/01_nodeset_is_the_dc_initial_guess.va | grep -A3 u_nodeset
pub const u_nodeset = [n_u]?f64{
    2.75,
    null,
};
```

**Second, separate defect found while confirming this:** the table is emitted
for a SCALAR net only. A vector net initializer is silently dropped. Reproduced
by taking fixture 02 and substituting `'{2.75, 0.5}` for the hole:

```
$ ./zig-out/bin/vera --emit-zig … /tmp/a08_nohole.va | grep -c u_nodeset
0
$ "$(./zig-out/bin/vera --emit-exe … /tmp/a08_nohole.va)"
  x[nZ5b0Z5d] = 1.000000e0
  x[nZ5b1Z5d] = 1.000000e0
```

versus `1` occurrence for the scalar form. And the LRM's own null-element
spelling `'{2.75, }` does not parse at all: `error[E0209]: expected an
expression: found `}``.

### (b) Nothing consumes it

```
$ grep -rn u_nodeset /home/omare/Documents/Projects/Zig/ARPice/src \
                     /home/omare/Documents/Projects/Zig/ARPice/include
(no output)
```

VerA's own analog testbench does not read it either —
`lib/backend/tb.zig:688` opens every operating point with

```zig
var x: [n_u]f64 = @splat(0.0);
```

so the dead export is dead on both sides of the interface, and the VerA-side
fixtures below are runnable proof of that without needing the host at all.

### Where the host WOULD have to consume it

The DC initial-guess seeding path in ARPice is:

| file:line | what it is |
|---|---|
| `/home/omare/Documents/Projects/Zig/ARPice/src/analysis/dc/op.zig:24-27` | **`pub fn coldStart(ckt, x)` — THE call site.** Body is `root.zeroSimd(x); ckt.seedJunctions(x);`. This is the only place the solution vector is given its pre-Newton value; every rung of the OP ladder routes through it (`op.zig:42, 106, 150, 158, 194, 223`) and so do `dc.zig:18` and `dc.zig:238`. A `u_nodeset` write belongs **between** the `zeroSimd` and the `seedJunctions` line — after the zero fill so it is not erased, before junction seeding so a device's `vcrit` seed still wins on the branches it owns. |
| `/home/omare/Documents/Projects/Zig/ARPice/src/analysis/Circuit.zig:617-620` | `pub fn seedJunctions(self, x)` — the per-batch fan-out `coldStart` already calls. The lazy wiring is to extend this hook rather than add a second one. |
| `/home/omare/Documents/Projects/Zig/ARPice/src/analysis/eval.zig:1284` | `.seed = if (@hasDecl(D, "seed")) seedFn else null` — the existing device-level seed protocol, `D.seed(model, inst) -> [n_u]?f64`. **`u_nodeset` is already exactly that type**, so the whole host-side change is one `@hasDecl(D, "u_nodeset")` arm here. |
| `/home/omare/Documents/Projects/Zig/ARPice/src/analysis/eval.zig:1392-1406` | `fn seedFn(ctx, x)` — and the reason the existing hook is not sufficient as written: its entire body is under `if (comptime has_limit)`, and it writes `self.lim_x[…]`, **never `x`**. A nodeset has to reach the solution vector through `self.gath[id * n_u + u]`, and it has to do so for devices with no limiting at all. |

Conflict rule for the host: §3.6.3.2 gives hierarchical declarations priority
and calls the flat-conflict case a race, so "last writer wins" across batches is
conforming; VerA already applies that rule within a module
(`codegen.zig` `emitNodesets`, LAST declaration wins).

## Fixtures

| fixture | pins | expected value | derivation |
|---|---|---|---|
| `01_nodeset_is_the_dc_initial_guess.va` | The positive half of "will be used as a nodeset value … by the analog solver": the declared number is the DC initial guess. Its single number also refuses a clamp, since 3.0 ≠ 2.75. | `V(p,g) = 3.0` | One net carrying `I = (V-1)(V-2)(V-3)`, whose three DC operating points are `V = 1, 2, 3`. Newton on `f(V)=V³-6V²+11V-6`, `f'(V)=3V²-12V+11` — the exact residual/Jacobian the device stamps. From the harness's cold start `V=0`: `0 → 0.545455 → 0.848953 → 0.974674 → 0.999092 → 1.0`. From the declared nodeset `V=2.75`: `2.75 → 3.227273 → 3.050713 → 3.003450 → 3.000018 → 3.0`. **3.0 is reachable only from the nodeset.** Iterates re-derived for this revision; three residual/derivative digits in the file header were wrong and are corrected there, the iterates and the conclusion are unchanged. |
| `02_nodeset_bus_null_element.va` | "A null value in the constant array indicates that no nodeset value is being specified for this element of the bus." | `V(n[0],g) = 3.0`, `V(n[1],g) = 1.0` | Same cubic, twice, on `electrical [0:1] n = '{2.75, };`. Identical behaviour on both elements; the only difference is the initializer. `n[0]` seeded 2.75 → root 3.0 (basin above); `n[1]` null → no nodeset → cold start 0.0 → root 1.0. Filling the hole with 0.0, or with the neighbour's 2.75, or dropping the table, each gives a different pair. |

### Observed today (captured, not typed)

```
$ for f in tests/pending/A08-nodeset/*.va; do
    echo "##### $(basename $f)"
    P=$(./zig-out/bin/vera --emit-exe --contract tools/contract.zig -I tests/fixtures "$f" 2>/tmp/e) \
      && [ -n "$P" ] && "$P" || cat /tmp/e
  done
##### 01_nodeset_is_the_dc_initial_guess.va
=== 01_nodeset_is_the_dc_initial_guess ===
--- point 0 ---
  x[p] = 1.000000e0
  x[g] = 0.000000e0
the nodeset seeds Newton, so it lands on the high root got=1 want=3 ok=0
##### 02_nodeset_bus_null_element.va
error[E0209]: expected an expression: found `}`
  --> tests/pending/A08-nodeset/02_nodeset_bus_null_element.va:72:34
   |
72 |     electrical [0:1] n = '{2.75, };
   |                                  ^
   |
   = note: LRM annex A.8.3
   = help: run `vera --explain E0209` for a detailed explanation

error: could not compile due to 1 previous error(s)
```

Both fixtures fail today and both must pass once §3.6.3.2 is honoured. There is
no third fixture; see below.

## Corrected after review

1. **`IEEE 1800.2` removed.** §3.6.3.2 is Accellera Verilog-AMS (the `docs/`
   transcription is Std VAMS-2023; `docs/VAMS-LRM-2-4.pdf` carries the same
   clause). IEEE 1800.2 is UVM. Fixed here and named explicitly in both fixture
   headers so the wrong attribution cannot be copied forward.
2. **"annex A.8.3" withdrawn as the authority for refusing `'{2.75, }`.**
   Opened: A.8.3 is *Expressions* and contains no array-element production at
   all. The production that governs is A.8.1 `constant_assignment_pattern`,
   which has no null alternative either — so the grammar cannot settle the
   question in either direction, and the authority is §3.6.3.2's normative
   sentence plus its own printed example. The `A.8.3` string turned out to be
   the generic `.lrm` tag `lib/diag_code.zig:1198` hangs on every E0209, not a
   citation anyone chose. Both the fixture header and the section above now say
   this, and the fixture's `//! lrm` cites only 3.6.3.2.
3. **Fixture 01's second assertion deleted.** `CHECK(V(p,g) − 2.75, 0.25, 1e-9)`
   is the first assertion rearranged at the same tolerance and could not fail
   independently of it. The anti-clamp claim it was carrying did not disappear:
   it is now carried by fixture 01's single number (a clamp reads 2.75, the
   assertion wants 3.0) and, on a circuit where clamping is the *only* failure
   mode, by the already-green `tests/fixtures/ch03_data_types/21_net_nodeset.va`.
4. **`03_nodeset_is_not_a_clamp.va` deleted.** It asserted `V(m,g)=0.5` and
   `V(p,m)=0.5` on a 1 kΩ+1 kΩ divider whose nodeset was 2.75 — the values a
   solver produces with §3.6.3.2 wholly unimplemented, which is why it ran 2/2
   green at HEAD. On a unique-solution circuit the seed cannot change the
   answer, so this fixture could not be given teeth without turning into
   fixture 01; and its content near-duplicated the already-green
   `21_net_nodeset.va` (same divider shape, same claim, already wired into
   `zig build torture`). **Where the claim went:** `21_net_nodeset.va` in
   `ch03_data_types` owns it, and fixture 01 above refuses a clamp as a side
   effect of wanting 3.0. **What would bring it back:** a circuit where
   clamping and seeding differ *and* the nodeset changes the answer — i.e. a
   multi-solution circuit whose nodeset picks a root a clamp would not sit on.
   That is fixture 01, so the file would come back only as a second root
   (e.g. seeding the V=2 root) if the solver's basin behaviour there is ever
   worth pinning.
5. **Fixture 01's Newton arithmetic re-derived.** Three intermediate residuals
   in the old header were wrong: `1.622645` (correct `1.622840`),
   `0.374110/2.975028` (correct `0.373985/2.974726`), and `- 0.590…/7.211…`
   for the second step from 2.75 (correct `+0.621243/3.518595`, step
   `−0.176560`). The iterates `0.848953`, `0.974674`, `3.050713` and the
   asserted `3.0` were and remain correct; the header now prints
   V, f(V), f'(V) and the step on every line so this is checkable by eye.
6. **Conformance caveat added to fixture 01.** §3.6.3.2 does not say which of
   three DC solutions shall be reported; it says the declared value is used as
   the nodeset value by the solver. The header now states that the fixture
   asserts exactly that and nothing more.
7. **Transcript re-captured** by actually running the loop printed above, after
   all edits, against `zig-out/bin/vera`. The `--emit-zig` and vector-drop
   evidence in §(a) was re-run too; the line numbers in the E0209 output moved
   because the header grew.
8. **`.zig-cache` spill deleted** from this directory (528 K).

## Deliberately NOT covered

- **The hierarchical conflict rule.** "initializers on hierarchical net
  declarations win … the declaration on the highest level wins." VerA refuses
  module instantiation, so there is no second level to test from a single `.va`;
  this needs the host, where two `u_nodeset` tables meet on one solver node.
  `mechanical top.foo.w = 250.0;` — the clause's own hierarchical example — is
  in the same bucket.
- **The host side.** No ARPice fixture is written here. The consumption does not
  exist at any layer (`coldStart` cannot even express it — see the table above),
  so a `tests/fixtures/hdl/*.sp` + `.expected.json` pair would fail for the same
  single reason fixture 01 already fails for, one layer further out. Add it
  against `dc/op.zig:24` once the host reads the table: the netlist is fixture
  01's cubic as a `.hdl` model with `.op`, expecting `v(p) = 3.0`.
- **Non-electrical natures.** Only `electrical` is exercised; a nodeset on a
  `thermal`/`mechanical` net is the same code path with a different `abstol`.
- **Refusals.** None written — `tests/fixtures/ch03_data_types/91_nodeset_*.va`
  already cover non-constant, non-continuous-discipline and over-parameter
  rejections. This row is entirely positive coverage.
- **That a nodeset is not a clamp.** Owned by
  `tests/fixtures/ch03_data_types/21_net_nodeset.va`, already green and already
  in the torture gate. See item 4 above.
- **AC / transient.** §3.6.3.2 says "the analog solver"; only the DC operating
  point is pinned. A nodeset has no meaning for a transient continuation.

## Build / run

These live outside `tests/fixtures/`, so `zig build torture` does not see them.
Run them directly:

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build install                           # refresh zig-out/bin/vera
for f in tests/pending/A08-nodeset/*.va; do
  echo "##### $(basename "$f")"
  P=$(./zig-out/bin/vera --emit-exe --contract tools/contract.zig \
        -I tests/fixtures "$f" 2>/tmp/a08err)
  if [ -n "$P" ]; then "$P"; else cat /tmp/a08err; fi
done
```

`--emit-exe` prints the binary path on stdout and diagnostics on stderr, hence
the split. Every `ok=` column must read `ok=1` once §3.6.3.2 is implemented. To
wire them into the green gate then, move both into
`tests/fixtures/ch03_data_types/` (alongside the existing `21_net_nodeset.va`
and `91_nodeset_*.va`), add their one-liners to that directory's `COVERAGE.md`,
and they are picked up by:

```sh
zig build torture -- --strict ch03
```
