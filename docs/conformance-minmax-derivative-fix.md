# Min/max derivative selection at equality

## Source and oracle

AMS 2023 §4.3.1, printed page 62 / physical PDF page 75, was read as text
and visually checked against the source page. The paragraph explicitly defines
the functions **at derivative discontinuities** using `min(x,y) = (x<y)?x:y`
and `max(x,y) = (x>y)?x:y`. Table 4-14 lists both traditional and system
spellings. Therefore equal independent inputs select the second argument:
the first partial is zero and the second is one. Swapping the arguments swaps
the selected partial; a constant selected argument has zero partial. Section
4.5.6 supplies the hold-other-unknowns-fixed derivative interpretation.

This is not an assumption that a generic numerical min/max library must have
a particular tie rule. The AMS source expressly supplies one for derivatives.

## Repair and host boundary

`lib/backend/codegen.zig` now routes floating min/max opcodes and its legacy
system-call path through generated `zMin`/`zMax`. These compose existing
contract primitives: `a.lt(b).sel(a,b)` and `b.lt(a).sel(a,b)`. The current
`tools/contract.zig` specifies a per-lane comparison mask and selection that
carries the winning operand's derivative. No new API, import, or scalar
method is required. Helper names were checked against existing generated
helpers before adding them.

The runner's embedded Dual methods also use strict comparisons, including
the constant-second-operand forms. Changing the runner alone would not fix
generated production models: their derivative scalar comes from an external
host. The generated selection helpers enforce the source rule independently
of the host's min/max methods, provided its existing comparison/select
contract is satisfied.

Equality selects the second value intact, including its signed-zero bit and
derivatives. For unordered comparisons, false `lt` also selects the second
operand, exactly as these literal conditional expressions do. The regression
tests that behavior of the helper; it does not assert an independently
specified AMS NaN conformance obligation. Integer lowering, integer min/max,
the value-only P/R scalar helpers, and precomputed value expressions are not
modified. This bounded patch does not establish all signed-zero/NaN behavior
across those separate value-only paths.

## Provenance

Files were copied from the current root tree before editing; root changes to
the runner's directives are preserved.

| File | Root base SHA-256 | Patch SHA-256 |
|---|---|---|
| `lib/backend/codegen.zig` | `cd803298f1411f4f3fcbf8ccf3c876e9b9d6d568c3a063efc4019fc029051b34` | `bb931b0f6f801be5bc7d1908d2b5861630cbb1900bfdf8acfb5de12e3562cb23` |
| `lib/backend/tb.zig` | `f3adc164ba5ff4f719be56a44d16cefead3e433dec865e4c98b25e84c450f7eb` | `aa9236b1fec1cc27c92262744de7d1b34dbc6c09bb34fbc7990d5f1f49325fbf` |

No `lower.zig` edits are part of this patch. The separately integrated
system-math typing repair remains prerequisite to integer result-type support.

## Evidence and limits

The focused backend test `minmax tie derivatives` passed for all four
spellings. It verifies emitted call routing and the strict selection helper
definitions, not just presence of min/max in a source fixture.

`python3 tools/test_minmax_generated_helpers.py` passed. It extracts the actual
emitted helper and runner Dual source, compiles it with Zig, and executes two
Zig tests. The production-helper test uses a host with no min/max methods and
checks equal inputs, swapped arguments, constant second input, unequal
neighbors, signed-zero selection, and an unordered comparison. The runner
test checks its actual min/max/minC/maxC tie derivatives. This is not a full
external-simulator integration test.

`audit_minmax_source_selection.va` adds runtime checks for both spellings,
swapped arguments, both constant positions, and unequal neighbors. Before the
repair, the isolated compiler produced 24 equality failures and eight passing
unequal observations. These numbers describe that exact execution, not a
conformance measure. The older `audit_minmax_tie_derivatives.va` remains
unchanged. Both markers remain for independent main-agent verification before
removal as implemented support; neither fixture should be deleted.

After the isolated `zig build -Doptimize=ReleaseFast` exited zero, running
the new fixture with `--emit-exe` and executing its generated testbench
produced all 32 observations `ok=1`. The unchanged older tie fixture produced
all four observations `ok=1`. Individual observations were checked; a zero
testbench process exit alone does not establish success.
The previous result-type fixtures were rerun: all six traditional and all
eight system-style observations remained `ok=1`. The tested isolated CLI
SHA-256 was `ba46cdb3ed248686b7d60651a11c06cce8205baed46e4536e2597c9ca4d0ff3b`.

Full-suite gates, FAIL/XFAIL name-list comparisons, generated-size accounting,
and measured A/C changes remain root integration work. This repair does not
close §4.3.1 generally or the separate `abs` derivative at zero obligation.

Main checkpoint (2026-09-23): independently checked the source's conditional
identities and the existing host mask/select contract, reviewed all routing
changes, and reran the actual-helper Python/Zig test successfully. Rebuilt root
CLI execution passes all32 extended observations and all4 original tie checks;
their XFAIL markers were retired with every assertion retained. Exact check
counts are now pinned in the headers.

The first full unit run exposed the expected generated-size golden change.
An independent temporary measurement test compiled every existing shape and
printed actual device/MIR sizes. Every device grows by418 shared helper bytes;
all MIR definition/instruction counts match the prior table. The full table
in `tests/bench.zig` was updated from these observations, not by blessing a
failing behavioral oracle. The temporary measurement test was removed and the
original size assertions retained. The fresh unit gate exits0. The completed
strict FAIL/XFAIL name list is byte-identical to the math-fixes baseline;
all new implemented fixtures pass. Existing suite debt still causes exit1.
