# Installing

VerA is one executable, `vera`. To build devices it runs the Zig compiler,
so whatever you install, `vera` needs **Zig 0.17.0** on its `PATH` (or named
with `--zig PATH`) for `--check`, `--emit-exe`, `--run` and `--emit-so`. The
front-end modes (`--lint`, `--emit-zig`, `--emit-verilog`, `--explain`) need
nothing but `vera`.

## With Nix

> **Not yet verified on `main`.** The commands below are the interface of the
> flake being prepared on branch `nix-package`. Until it is merged, use one of
> the other two ways.

```sh
nix run github:OmarSiwy/VerA -- model.va --lint      # build from source and run
nix profile install github:OmarSiwy/VerA             # install the latest source build
nix profile install 'github:OmarSiwy/VerA#"1.0.0"'   # a release binary, pinned
```

The packaged `vera` is wrapped with the Zig 0.17.0 it generates code for, so
`--run` and `--emit-so` work with no Zig of your own. As a flake input, take
`vera.packages.${system}.default` (or `."1.0.0"`, `latest`), or apply
`vera.overlays.default` to get `pkgs.vera` and `pkgs.veraPackages.<version>`.

## A release binary

Each GitHub release attaches a `vera` for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-macos`, `aarch64-macos` and `x86_64-windows`,
with a `SHA256SUMS` file:

```sh
curl -LO https://github.com/OmarSiwy/VerA/releases/download/v1.0.0/vera-v1.0.0-x86_64-linux-gnu.tar.gz
tar xzf vera-v1.0.0-x86_64-linux-gnu.tar.gz      # one file: vera
./vera --help
```

Install Zig 0.17.0 from <https://ziglang.org/download/> beside it.

## From source

```sh
git clone https://github.com/OmarSiwy/VerA && cd VerA
zig build -Doptimize=ReleaseFast
```

The binary is `zig-out/bin/vera`. The build also installs the device
contract your simulator compiles against at
`zig-out/share/vera/contract.zig` (`--prefix DIR` installs both under
`DIR`). The repository's `nix develop` shell has the exact Zig.

## Checking the install

`vera --help` lists every flag ([the command line](cli.md) explains them).
A model with no errors lints silently and exits 0; the [first chapter of the
tutorial](../learn/getting-started.md) goes on from there.

## Editor support

There is no VerA language server. Verilog-AMS editor modes that highlight
`.va` files work unchanged, and `vera --lint --diagnostics=json` gives a
machine-readable list of diagnostics for an editor integration
([Diagnostics](diagnostics.md)).
