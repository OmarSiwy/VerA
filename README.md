# VerA

VerA is a compiler for Verilog-AMS, the language analog and mixed-signal
device models are written in. It turns a Verilog-A model (a resistor, a
diode, a BSIM4 or PSP transistor) into Zig source that a circuit simulator
compiles into its own solver: the model's currents and charges with exact
derivatives, its noise, and its state.

It is for two kinds of user. Simulator authors get compact models as source
code their solver compiles and inlines, with the arithmetic (f64 or f32
derivative lanes, SIMD vectors of operating points) chosen by the simulator.
Model authors get a strict checker whose every diagnostic names the clause
of the standard behind it. VerA also runs digital IEEE 1364 Verilog, and
designs that mix the two.

- **Documentation:** <https://omarsiwy.github.io/VerA/>: a tutorial on
  Verilog-AMS, the `vera` reference, and the device contract for simulator
  authors
- **Measured conformance and speed:** <https://omarsiwy.github.io/VerA/report/>,
  rebuilt on every push to `main`
- **Developer documentation:** <https://deepwiki.com/OmarSiwy/VerA/>

## What it does

- **Exact Jacobians.** Derivatives propagate through the same arithmetic as
  the residual, so one `eval` call returns both and they cannot disagree.
- **The simulator picks the arithmetic.** `eval` and the device's other
  evaluation entry points are generic over a *scalar family* the host passes
  at compile time.
- **One emitted file, several targets.** The device imports only `std` and
  the contract, so it builds into a CPU host, a shared library
  (`--emit-so`), an OSDI 0.4 library for ngspice (`--emit-osdi`), and NVPTX
  or AMDGCN code.
- **Diagnostics with clause numbers.** Every diagnostic has a code, the
  clause of the standard behind it where there is one, and a long form under
  `vera --explain CODE`.
- **A finiteness proof.** A math function whose argument is provably outside
  its domain is an error; a unit the prover cannot show finite still
  compiles, in strict float mode, and warning W0650 says which.
- **Testbenches from comments.** `//!` lines in a model's header describe
  bias points and checks; `vera --run` builds the testbench and runs it.
- **Digital and mixed-signal.** `.v` designs run on an event-driven engine,
  and connect modules join the digital and analog halves.

## Quick start

Needs `vera` and, for anything that builds a device, Zig 0.17.0 on `PATH`.
The Nix packages bring their own Zig.

```sh
nix profile add github:OmarSiwy/VerA          # or build from source, below
cat > resistor.va <<'EOF'
`include "disciplines.vams"

module resistor(p, n);
  inout p, n;
  electrical p, n;
  parameter real r = 1k from (0:inf);
  analog I(p, n) <+ V(p, n) / r;
endmodule
EOF
vera --lint resistor.va                       # a legal model prints nothing and exits 0
vera --emit-zig resistor.va -o resistor.zig   # the device
vera --check resistor.va                      # type-check it against the contract with Zig
```

`resistor.zig` is the whole device. Its entry point, as
[`docs/examples/getting-started/emit.out`](docs/examples/getting-started/emit.out)
shows it:

```zig
pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {
```

`flake.nix`'s `smoke` check runs `--emit-zig` and `--check` on this
resistor in the Nix sandbox on every CI run. To watch a model compute, put a
`//! bias V(p) = 2.0` line at the top and run `vera --run resistor.va`;
[Getting started](https://omarsiwy.github.io/VerA/learn/getting-started.html)
walks through it with the real output.

## Install

### Nix

```sh
nix run github:OmarSiwy/VerA -- --help            # build from source and run
nix profile add github:OmarSiwy/VerA              # `nix profile install` on older Nix
nix profile add 'github:OmarSiwy/VerA#"1.0.0"'    # a release binary, pinned (or #latest)
```

Every package wraps `vera` with the Zig release its generated code targets,
so it runs from any directory with no checkout, and installs
`share/vera/contract.zig`, the device contract of its own version. Systems:
x86_64-linux, aarch64-linux, aarch64-darwin, and x86_64-darwin (from
nixpkgs 26.05, the last release that builds it).

<details>
<summary>As a flake input, in a sandbox, or coming from EDA-Packaged</summary>

```nix
{
  inputs.vera.url = "github:OmarSiwy/VerA";
  outputs = { nixpkgs, vera, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; overlays = [ vera.overlays.default ]; };
    in {
      # the package: .default from source, ."1.0.0" or .latest a release binary
      packages.${system}.vera = vera.packages.${system}.default;
      # the overlay: pkgs.vera, pkgs.veraPackages."1.0.0", pkgs.veraPackages.latest
      devShells.${system}.default = pkgs.mkShell { packages = [ pkgs.vera ]; };
    };
}
```

`vera` writes its scratch tree under `.zig-cache/` in the working directory
and uses Zig's global cache, so in a derivation's sandbox (no `$HOME`) run it
in a writable directory with `export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.

The EDA-Packaged flake's `packages.<system>.vera` is this flake's
`packages.<system>.default` at whatever revision its lock pinned. Take
`github:OmarSiwy/VerA` as an input and use `vera.packages.${system}.default`
(or the overlay's `pkgs.vera`) instead.

</details>

### Release binary

Each [GitHub release](https://github.com/OmarSiwy/VerA/releases) attaches a
`vera` for x86_64-linux-gnu, aarch64-linux-gnu, x86_64-macos, aarch64-macos
and x86_64-windows, with a `SHA256SUMS` file. The tarball holds the binary
alone; install the Zig release it targets (0.17.0 for v1.0.0) from
<https://ziglang.org/download/> beside it.

```sh
curl -LO https://github.com/OmarSiwy/VerA/releases/download/v1.0.0/vera-v1.0.0-x86_64-linux-gnu.tar.gz
tar xzf vera-v1.0.0-x86_64-linux-gnu.tar.gz      # one file: vera
./vera --help
```

### From source

```sh
git clone https://github.com/OmarSiwy/VerA && cd VerA
zig build -Doptimize=ReleaseFast                 # Zig 0.17.0; `nix develop` has it
zig-out/bin/vera --help
```

The build installs `zig-out/bin/vera` and the contract a host compiles
against, `zig-out/share/vera/contract.zig` (`--prefix DIR` installs both
under `DIR`). `-Dlanguage=verilog` builds an IEEE 1364-2005 `vera` without
the analog backend.

## Usage

```sh
vera model.va                                       # same as --lint: check it, write nothing
vera model.va --emit-zig -o device.zig              # the device, for a host that compiles it in
vera model.va --run                                 # build and run the testbench its //! lines describe
vera model.va --emit-so --dyn dyn.zig --work-dir build   # a shared library your dyn.zig exports
vera model.va --emit-osdi -o model.osdi             # an OSDI 0.4 library (ngspice `pre_osdi`)
vera model.va --emit-verilog -o model_beh.v         # a behavioural Verilog stand-in
vera --run design.v                                 # an IEEE 1364 design on the event-driven engine
vera --explain W0650                                # the long form of a diagnostic
```

Exit status: 0 on success (warnings do not fail), 1 on a diagnosed error or
a failed build, 2 on a usage error. `--run` exits with the testbench's
status. `vera --help` lists every flag, and
[The command line](https://omarsiwy.github.io/VerA/using/cli.html) explains
them.

## For simulator authors

The device is Zig source compiled against one file, `tools/contract.zig`
(installed as `share/vera/contract.zig`). Your host allocates the device's
`Model`, `Instance` and `State` structs, calls its card-time hooks once, and
calls `eval` in its Newton loop; each row `eval` returns carries the residual
and that row of the Jacobian. Declaring `pub const vera_validate_contract =
true` in the host's root module turns on the contract's compile-time checks
of the host against what each device needs. A host not written in Zig loads
the device through `--emit-so` (a small Zig `dyn` module exports the C
functions it wants) or `--emit-osdi`.

[VerA devices in your own simulator](https://omarsiwy.github.io/VerA/host/why.html)
compares the contract with OSDI and builds a minimal host step by step.

## Limitations

- **`vera --run` checks models; it is not a circuit simulator.** For a
  model with no digital half, its testbench steps fixed-step backward Euler
  over the time points the header declares, with no truncation-error control and no step rejection, so a
  `cross`, `above` or `timer` event fires at the first declared point past
  its own time (W0750).
- **Mixed signal:** a value the analog side writes into the digital side
  does not re-solve the analog point already finished; the next analog point
  sees it.
- **OSDI output** has no slot for operating-point variables, correlated
  noise, a device's request to reject a time step, or an acceptance
  callback (`tools/osdi_dyn.zig`).
- **Compiled with the host:** a large model adds its compile time to your
  build, and a device is regenerated when the contract's `abi_version`
  changes.
- **`--emit-verilog`** refuses event-driven models (`@(cross ...)`, held
  variables); `lib/backend/beh_verilog.zig` lists every refusal.
- **Other languages:** SystemVerilog (`.sv`, E1104) and VHDL are refused.
- **Open decisions** are the `CHANGE NEEDED` entries of
  [`docs/Vague_Decisions.md`](docs/Vague_Decisions.md), and the known gaps
  are listed by name in [`docs/known-gaps.txt`](docs/known-gaps.txt); CI
  fails if that list changes.

## Conformance

VerA's progress toward v1.0.0 is four measured numbers (`AGENTS.md` §2):
**A**, fixtures behaving as their header states; **B** and **C**, IEEE
1364-2005 and Verilog-AMS LRM clauses cited by both a passing fixture and a
rejection fixture; **D**, architecture phases landed. `tools/conformance.py`
is the only thing that writes A, B and C, into each release's entry in
[`CHANGELOG.md`](CHANGELOG.md); v1.0.0's are on its
[GitHub release](https://github.com/OmarSiwy/VerA/releases/tag/v1.0.0). B and
C count citations, not verified rules
([`docs/CLAUSE-AUDIT.md`](docs/CLAUSE-AUDIT.md) §5).

Each chart is drawn from suite output by `tools/report.py`, with the commit
and date in its subtitle (`tools/report.py --models <ARPice models> --svg
docs/img` regenerates them). The
[live report](https://omarsiwy.github.io/VerA/report/) adds the
clause-by-clause rule map and the open gaps.

![Conformance: measures A, B and C](docs/img/conformance.svg)

![Building ARPice's compact models to a loadable .so](docs/img/model-build.svg)

To measure it yourself:

| What | Command |
|---|---|
| `.va` and `.v` fixtures (A) | `zig build -Doptimize=ReleaseFast benchmark -- --strict` |
| IEEE 1364-2005 clause coverage (B) | `zig build test-1364 -- --coverage` |
| LRM clause coverage (C) | `zig build benchmark -- --coverage` |
| digital transcripts | `zig build test-devices` |
| VPI `.c` fixtures | `zig build test-vpi-fixtures` |
| SPICE decks against their oracles | `zig build test-spice` |

## Contributing

Read [`AGENTS.md`](AGENTS.md) first: its rules (never type a conformance
number, gate on `$?`, diff FAIL name lists rather than counts) hold for every
change. While editing, `zig build --watch -fincremental`
rebuilds `zig-out/bin/vera` from only what changed. Before a pull request,
`zig build test` must exit 0. Fixtures live under `tests/fixtures/`, each
naming the clause it tests; [`docs/TESTING.md`](docs/TESTING.md) lists
their `//!` directives. The 2023 LRM is in the repository as
[`docs/VAMS-LRM-2023.pdf`](docs/VAMS-LRM-2023.pdf) and per chapter as
[`docs/index.html`](docs/index.html).

Report bugs and ask questions in
[GitHub issues](https://github.com/OmarSiwy/VerA/issues).

## License

Apache 2.0: see [LICENSE](LICENSE) and, for third-party material,
[NOTICE](NOTICE). Changes since v1.0.0 are in [CHANGELOG.md](CHANGELOG.md).
