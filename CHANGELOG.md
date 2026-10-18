# Changelog

What a user of VerA notices, newest release first. A fix names its GitHub issue as `(#123)`.

## Unreleased

The first release. VerA compiles Verilog-AMS models into Zig device code for any circuit simulator, and runs IEEE 1364-2005 Verilog and mixed-signal designs.

### New

- `vera --emit-osdi`: an OSDI 0.4 library ngspice loads, from a `.va` model or a `.v` design.
- `vera --lsp`: a language server (diagnostics and quick fixes as `--lint` reports them); `editors/` has Neovim and VS Code configurations.
- `vera --version`. Every device declares `vera_version`, and a host compiled against another VerA release refuses it at compile time.
- `vera --run` runs a `.v` design's timing checks (`$setup`, `$hold`, `$setuphold`, `$removal`, `$recovery`, `$recrem`, `$width`, `$period`; IEEE 1364-2005 §15).
- A device publishes more to its host:
  - its `desc` and `units` attributes (`decl_meta`);
  - its `$display`, `$strobe` and `$debug` output, for the host to print (`say`), at every Newton iteration for `$debug`;
  - a check of host-written model-card values against their `from`/`exclude` ranges (`checkRange`, E0377).
- `--spice` netlists: subcircuit parameters, `{expr}` values, X cards that instantiate a subcircuit or a module, and M/Q/J/D cards inside `.subckt`.
- VPI: a host that solves the circuit itself can run a VPI application's analog system functions. It can attach several device libraries, each with several instances (`vpi.analog_run.Binding`).
- `$simparam$str`, and `ac_stim` sources active in a named small-signal analysis.
- User documentation: an mdBook site, `docs/`.
- Nix: `nix run github:OmarSiwy/VerA`, an overlay, release packages and `nix flake check`.

### Changed

- VerA builds with Zig master (0.18.0-dev), and `vera` builds devices with the same Zig.
- `limexp(x)` is `exp(x)` at every argument, as §4.5.13 requires at a converged point (#52).
- A run-time argument outside a math function's domain (`ln(0)`, `sqrt(-1)`, `pow(-0.5, 2.5)`) is an error in the executable, not a silent NaN (#59).
- `asinh`, `acosh`, `atanh`, `log`, `asin`, `acos` and `atan2` compute what their C functions do, and a folded constant equals the run-time value bit for bit (#60).
- Analog `%d`, `%h`, `%o` and `%b` size an integer as IEEE 1364 §17.1.1.3 does: an `integer` prints 11 decimal columns or 32 bits (#61, #77).
- GPU device code:
  - the lossy-line models (txl, coupled_ltra) fit the GPU stack, with frames of 165–612 KB down to under 26 KB (#82);
  - a strict device's core is branch-free on NVPTX and AMDGCN, which avoids an LLVM crash on L-UTSOI 102 (#81).
- Limits lifted: more than 256 solver unknowns, any nesting or instance depth, and any number of format conversions.
- For embedders: the compiler is one call, `vera.compile`, and its modules are `base`, `kernels`, `frontend`, `elab`, `ir`, `analog`, `prove`, `device`, `verilog`, `exe`, `zigbuild` and `digital`.
- License: Apache 2.0.

### Fixed

- Model cards:
  - a value written through an `aliasparam` sets the parameter and its `$param_given` (#76);
  - a `$simparam` default answers as the analog block does (#51).
- A device no longer claims a constant Jacobian when a `?:` or `if` on the solution picks its conductance (#78).
- `--emit-osdi` builds a module with no parameters (#79).
- `last_crossing()` reports the crossing at the point that creates it (#54).
- A port with no direction (E0376) or no discipline (E0337) is refused in every module (#73, #74).
- Elaboration is linear in the instance count: 2048 instances take 0.03 s, not 34 s (#75).
- Digital engine:
  - net delays apply to the whole vector (#55);
  - a declaration assignment's delay times that assignment only;
  - a `$readmem` address out of range ends the load, not the run (#65);
  - `%t` of a real is exact;
  - `$abstime`, `$ln1p` and `$expm1` run (#58).
- Refused by name instead of hanging or crashing:
  - an attribute before a list's closer (#48, #49, #50);
  - an empty path flag (#47);
  - an untimed loop, or a VPI reset loop (#37);
  - an out-of-range format width (E0828).
- Format details: C's `#`, `-`, `+` and `0` flags on real formats, `%%`, and null arguments.
- VPI: §12 analog routines, callbacks, `vpiReset` and Annex G constants.
- Hierarchy: upward names and `defparam`s, generate scopes and connect modules on every primitive.
- Noise: `ddx()` inside a noise power, and `$mfactor` on named branches.
