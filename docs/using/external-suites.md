# External accuracy suites

VerA's own fixtures check VerA against values derived by hand from the
standard. The external suites check it against other people's tests and
other people's tools: published QA references for compact models, the
Icarus Verilog regression suite, and the simulators the industry already
trusts. Where VerA and a reference disagree, one of them is wrong, and the
suite prints the case by name so someone can find out which.

None of the external code is stored in the repository. Each suite is a
folder under
[`tests/fixtures/external/`](https://github.com/OmarSiwy/VerA/tree/main/tests/fixtures/external)
holding a manifest that pins what is fetched (a URL and a commit, or a file
and its SHA-256) and states its license. The scripts fetch it at run time
into `.zig-cache/external/`, which git ignores.

## The tools they need

The reference tools come from one Nix shell:

```sh
nix develop .#benchmarking
```

It carries Icarus Verilog, Verilator and Yosys (IEEE 1364), ngspice (which
loads VerA's devices as OSDI libraries), Xyce, gnucap, and OpenVAF-Reloaded
(`openvaf-r`, x86_64 Linux only). Build `vera` in the shell first:
`zig build -Doptimize=ReleaseFast`.

## Analog: `tools/external_analog.py`

```sh
python3 tools/external_analog.py                 # every suite
python3 tools/external_analog.py osdi va-models  # some of them
```

| Suite | What it compares |
|---|---|
| `osdi` | small decks whose answers are derived by hand, run in ngspice over `vera --emit-osdi` libraries: the proof that ngspice loads a VerA device and gets the right numbers |
| `va-models` | the compact models of [dwarning/VA-Models](https://github.com/dwarning/VA-Models), compiled by VerA and by OpenVAF-Reloaded, the same QA tests run on both in one ngspice, every output compared |
| `cmcqa` | the CMC QA test specifications and their published reference results ([ominux/cmcqa](https://github.com/ominux/cmcqa)), through ngspice and VerA |
| `hicum-qa` | TU Dresden's HICUM/L2 QA tests and their published references |
| `xyce` | VerA in ngspice against Xyce's own built-in model of the same version: a third opinion |

Two numbers are compared with the CMC's rule (from cmcqa's
`compareSimulationResults.pl`): they match when both are below a clip
value, when they agree to a number of significant digits, or when their
relative error is under a tolerance. The script's header lists the values
for DC, AC and noise.

It prints `PASS <name>` or `FAIL <name>: <why>` per model, analysis and
quantity, writes the sorted FAIL names to `fail.txt` in its output
directory (`--out DIR`), and exits 1 if anything failed. CI runs it in the
`external-analog` job on every push to `main` and every pull request, which
reports the FAIL names without failing the build.

## Digital: `tools/external_digital.py`

```sh
python3 tools/external_digital.py zig-out/bin/vera
python3 tools/external_digital.py zig-out/bin/vera --only ivtest
```

| Suite | What it compares |
|---|---|
| `ivtest` | the Icarus Verilog regression suite, with its own gold files and PASSED convention |
| `sv-tests` | the Verilog-2005 subset of [chipsalliance/sv-tests](https://github.com/chipsalliance/sv-tests) |
| `iverilog-diff` | `iverilog -g2005` and `vvp` against `vera --run`, transcript for transcript, over VerA's own `.v` fixtures and the two selections above. Where the two disagree on whether a source is legal, Verilator and Yosys are asked as a second opinion; their answers are printed, never scored |

Every disagreement prints as `FAIL <suite>/<name>: why`. A suite whose tool
is missing is reported as skipped.

## Reading a FAIL

A FAIL is a question, not a verdict. The reference can be wrong, or two
readings of the standard can both be legal; VerA's choices where the
standard leaves one open are in [Implementation-defined
choices](implementation.md). When you compare two runs, compare the FAIL
*names*, not their count: a count can stay the same while one case is fixed
and another breaks.
