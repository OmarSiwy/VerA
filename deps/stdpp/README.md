# Zig libraries, tested against Rust and LLVM

This implements the first experiments in [the research handoff](zig_rust_llvm_research_handoff.md): reusable Zig iterator and buffer libraries, Rust equivalents, independent correctness checks, and native kernel timings. See [REPORT.md](REPORT.md) for measured findings.

A follow-up [vectorization experiment](experiments/vectorization/README.md) enables the loop vectorizer through Zig's bundled Clang optimizer, with paired on/off results and correctness checks. The benchmark kernels pass, but the upstream bug reproducer **returns 103 instead of 100** with this enabled pipeline and our CPU target. The experiment documents the failure and the reason for Zig's workaround.

A [locally built compiler](toolchains/README.md) now backports the upstream fix to LLVM 22.1.8 and restores normal Zig loop vectorization. It has rebuilt itself, passes the original reproducer and the regression suites, and vectorizes the reusable Zig libraries through ordinary `zig build-obj`. Select it with `nix-shell --pure --argstr zigVersion patched`. The [repair results](REPORT.md#13-local-compiler-repair) include correctness, code generation, and fresh timings.

The default compiler is **Zig 0.17.0-dev.2338+b46a7f3a2**, supplied by [Mitchell Hashimoto's zig-overlay](https://github.com/mitchellh/zig-overlay). The overlay revision and source hash are pinned in [nix/zig-overlay.json](nix/zig-overlay.json). Zig 0.16.0 is a separate comparison from the same overlay.

## Run everything through shell.nix

The current harness targets Linux. `shell.nix` supplies Zig, Rust/Cargo, Clang/LLD/LLVM 21, Python, binutils, inspection utilities, and local compiler caches. There are no external Rust crates, Zig packages, or Python packages.

```sh
# Enter the master development environment.
nix-shell --pure

# Or run a complete build, correctness suite, benchmark, and summary directly.
# Use a fresh directory: the runner protects completed evidence from overwrite.
nix-shell --pure --run 'python3 scripts/study.py all --out results/reproduction --cpu x86-64-v3'

# Repeat with released Zig, keeping artifacts separate.
nix-shell --pure --argstr zigVersion 0.16.0 --run \
  'python3 scripts/study.py all --out results/reproduction-stable --cpu x86-64-v3'

# Diagnostic: remove Rust loop vectorization; retain all other Rust settings.
nix-shell --pure --run \
  'python3 scripts/study.py all --out results/reproduction-diagnostic --cpu x86-64-v3 --rust-no-loop-vectorize'
```

`x86-64-v3` requires compatible hardware, including AVX2. Omit `--cpu` for the x86-64 baseline; `--cpu native` is available but requires reviewing the recorded effective target features. The measured machine supported x86-64-v3. Benchmark defaults are 25 randomized timed batches per variant/length, calibrated to at least 5 ms. Inputs and scratch are prepared outside the timed region. CPU affinity is applied where allowed; system settings are not changed.

For library tests only:

```sh
nix-shell --pure --run 'zig build --build-file zig/build.zig test'
nix-shell --pure --run 'cargo test --manifest-path rust/Cargo.toml --offline'
```

`--arg withProfiling true` adds `perf`, Valgrind, and Hyperfine on Linux. The recorded runs did not use these profilers. The shell does not modify perf permissions.

**Dependency pin boundary:** the Zig overlay is fixed; the other packages come from the caller's `<nixpkgs>`. Each run records its resolved Nix store source, compiler paths, versions, executable hashes, arguments, and effective target attributes. The included runs used the same package set. To reproduce that exact environment on this machine, pass `--arg pkgs 'import /nix/store/3a2vdn5i7vd2wl654xs8nb52jf1v6cbh-source {}'`. On another machine, supply the same package set or treat a different one as a new configuration. This is not a claim that all of nixpkgs is pinned by `shell.nix`.

LLVM 21 tools inspect the native objects in this suite. Master's bundled Clang reports 22.1.8; do not assume LLVM 21 `opt`/`llvm-dis` can process its IR or bitcode. No cross-version IR reoptimization is performed here.

## Use the Zig libraries

[zig/src/iter.zig](zig/src/iter.zig) implements borrowed slice sources, `map`, `filter`, `take`, `fold`, `foldDirect`, `count`, size hints, and separately named `zipExact`/`zipShortest` slice sources. Callback types are known statically and can hold runtime state; no function-pointer dispatch or allocation is hidden in the adapters.

```zig
const patterns = @import("patterns"); // module exported by zig/build.zig
const iter = patterns.iter;

var pipeline = iter.fromSlice(u32, input)
    .map(iter.AffineU32{ .multiplier = multiplier, .offset = offset })
    .take(limit);
const total = pipeline.fold(@as(u64, 0), iter.SumU64{});
```

Adapters copy their state when constructed. `next`, `fold`, and `foldDirect` mutate/consume the receiver. Copying a pipeline copies its cursor and value captures; pointer captures still reference the same borrowed objects. Inputs and captures must outlive consumption. This is not a move-only ownership system.

`fold` consumes via `next()`. `foldDirect` composes map/filter operations into the source consumer; a `take` boundary falls back to pulling so callbacks cannot run past the requested prefix. Both preserve callback order and mutation. The type's `description` exposes its stage sequence, including pull boundaries. Size hints are not unsafe trusted-length guarantees. Fallible iteration, general iterator zip, collection allocation, explicit SIMD, and normalized plans remain future work.

[zig/src/buffers.zig](zig/src/buffers.zig) offers ordinary and `noalias` wrapping addition plus `mapInto` for caller-owned output. Slice APIs reject unequal lengths before writing. Disjoint APIs require output/input non-overlap; read-only inputs may overlap. `noalias` expresses a caller obligation and does not validate addresses.

## Evidence and scope

| Artifact | Purpose |
|---|---|
| [cases.json](cases.json) | Arithmetic, input generation, FFI, aliasing, and measurement contracts |
| [scripts/study.py](scripts/study.py) | Build/check/bench/analyze entrypoints; Python standard library only |
| [harness/timing.c](harness/timing.c) | Native timed batches; ctypes stays outside the timed region |
| [results/master](results/master) | Default master comparison, raw samples, correctness, IR, assembly, and summary |
| [results/master-no-loop-vectorize](results/master-no-loop-vectorize) | Rust loop-vectorizer diagnostic |
| [results/stable](results/stable) | Zig 0.16.0 comparison |
| [results/provenance](results/provenance) | Pinned compiler-source evidence and codegen inspection source |
| [toolchains](toolchains/README.md) | Pinned local Zig/LLVM sources, saved patches, and reproducible compiler build |
| [results/patched-compiler-validation](results/patched-compiler-validation) | Reproducer, compiler regression tests, and normal Zig library compilation with the repair |
| [toolchains.lock.json](toolchains.lock.json) | Inventory of the toolchains used in the included runs |

Each run retains `manifest.json`, `correctness.json`, `samples.csv`, `summary.json`, `summary.md`, text IR/assembly, command logs, and `codegen.json`. Rebuildable `.so`, object/archive files, and test executables live in its ignored `build/` directory. Run `python3 results/provenance/inspect.py results/<run>` inside the shell to reproduce the linked-function inspection while the binaries are present.

E01 covers disjoint buffer addition; E03 covers wrapping map/reduce. Filter/take/stateful-callback behavior is correctness-tested but not yet performance-measured. The materialization control uses preallocated scratch and forced separate passes; it does not measure allocation cost. No claims are made about the remaining experiment catalog.
