# VerA

**A Verilog-AMS compiler: analog device models in, exact and fast Zig device code out, for any circuit simulator.**

[![CI](https://github.com/OmarSiwy/VerA/actions/workflows/bench.yaml/badge.svg?branch=main)](https://github.com/OmarSiwy/VerA/actions/workflows/bench.yaml)
[![Release](https://img.shields.io/github/v/release/OmarSiwy/VerA)](https://github.com/OmarSiwy/VerA/releases/latest)
[![Docs](https://img.shields.io/badge/docs-book-blue)](https://omarsiwy.github.io/VerA/)
[![Conformance](https://img.shields.io/badge/conformance-live%20report-brightgreen)](https://omarsiwy.github.io/VerA/report/)
[![Zig](https://img.shields.io/badge/zig-0.17.0-f7a41d)](https://ziglang.org/download/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

VerA compiles a Verilog-A model (a resistor, a diode, a BSIM4 or PSP
transistor) into Zig source that a simulator compiles into its own solver:
currents, charges, exact derivatives, noise and state. It also runs digital
IEEE 1364 Verilog and designs that mix the two, and every diagnostic names the
clause of the standard behind it.

- **Exact Jacobians**: derivatives come out of the same arithmetic as the residual.
- **Your arithmetic**: `eval` is generic over the scalar type the host picks (f64, f32, SIMD lanes).
- **Many targets**: a CPU host, a shared library (`--emit-so`), an OSDI 0.4 library for ngspice (`--emit-osdi`), NVPTX or AMDGCN.
- **Testbenches from comments**: `//!` lines in a model's header describe bias points and checks; `vera --run` runs them.

## Quick start

```sh
nix profile add github:OmarSiwy/VerA          # or a release binary / source build, below
cat > resistor.va <<'EOF'
`include "disciplines.vams"
module resistor(p, n);
  inout p, n;
  electrical p, n;
  parameter real r = 1k from (0:inf);
  analog I(p, n) <+ V(p, n) / r;
endmodule
EOF
vera --lint resistor.va                       # a legal model prints nothing, exits 0
vera --emit-zig resistor.va -o resistor.zig   # the device
```

`resistor.zig` is the whole device; its entry point
([`docs/examples/getting-started/emit.out`](docs/examples/getting-started/emit.out)):

```zig
pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {
```

The [tutorial](https://omarsiwy.github.io/VerA/learn/getting-started.html) continues from here.

## Install

| How | Command |
|---|---|
| Nix (from source) | `nix profile add github:OmarSiwy/VerA` |
| Nix (release binary) | `nix profile add 'github:OmarSiwy/VerA#"1.0.0"'` |
| Release tarball | [GitHub releases](https://github.com/OmarSiwy/VerA/releases): x86_64/aarch64 Linux, x86_64/aarch64 macOS, x86_64 Windows, with `SHA256SUMS` |
| From source | `git clone https://github.com/OmarSiwy/VerA && cd VerA && zig build -Doptimize=ReleaseFast` |

Building a device needs Zig 0.17.0 on `PATH`; the Nix packages bring their
own. Every install also ships the device contract, `share/vera/contract.zig`.

## Usage

```sh
vera model.va --emit-zig -o device.zig                   # Zig source a host compiles in
vera model.va --run                                      # run the testbench its //! lines describe
vera model.va --emit-so --dyn dyn.zig --work-dir build   # a shared library
vera model.va --emit-osdi -o model.osdi                  # an OSDI 0.4 library for ngspice
vera --run design.v                                      # an IEEE 1364 design
vera --explain W0650                                     # the long form of a diagnostic
```

Exit status: 0 on success, 1 on a diagnosed error, 2 on a usage error.
[The command line](https://omarsiwy.github.io/VerA/using/cli.html) covers every
flag; [VerA devices in your own simulator](https://omarsiwy.github.io/VerA/host/why.html)
builds a host step by step.

## Scope

- **`vera --run` checks models; it is not a circuit simulator.** It steps
  fixed-step backward Euler over the time points a fixture declares, so an
  event lands on the next declared point (W0750). For transient analysis, load
  the device into a simulator (ESPice, or ngspice through `--emit-osdi`).
- **`--emit-osdi` carries what the OSDI 0.4 interface can describe.** OSDI's
  model struct has no field for a request to reject a time step, correlated
  noise, a step-accepted callback or printed output, so VerA refuses the first
  (E1099) and warns on the second (W1098) rather than drop them silently.
  VerA's own device contract carries all four.
- **Languages:** Verilog-AMS and IEEE 1364-2005 Verilog. SystemVerilog (E1104)
  and VHDL are out of scope.
- **Open bugs** are `//! xfail` fixtures, each naming its clause; CI's verdict
  ratchet ([`tests/fixtures/VERDICTS.tsv`](tests/fixtures/VERDICTS.tsv)) fails
  on any verdict change. Operating-point variables are not exported to OSDI yet.

## Conformance

Every fixture under `tests/fixtures/` names the LRM clause or sentence it
tests. `tools/conformance.py` measures the evidence for each normative sentence;
the numbers are in
[`CHANGELOG.md`](CHANGELOG.md) and the [live report](https://omarsiwy.github.io/VerA/report/).

## Contributing

Read [`AGENTS.md`](AGENTS.md) first, then make `zig build test` exit 0.
Questions and bugs go to [GitHub issues](https://github.com/OmarSiwy/VerA/issues).

## License

Apache 2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE).
