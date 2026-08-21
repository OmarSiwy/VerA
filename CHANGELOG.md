# Updates past v1.0.0, bugs & performance

One short bullet per change, newest first. A fix names its GitHub issue as `(#123)`.

## Unreleased

- Nix: `nix run github:OmarSiwy/VerA`, release binaries as `.#"1.0.0"`/`latest` (`sources.json`), `overlays.default`, and `nix flake check` in CI.
- Fix: digital selects with an index wider than 64 bits now work under `--run` and `--emit-exe` (#2).
- Fix: native digital keeps a formatted scan's state across nested output calls (#3).
- Digital engine, runtime, VPI and IR lists are sized before they fill (no behaviour change).
- Commits carry no Co-Authored-By trailers (AGENTS.md §8).
- One changelog: `CHANGELOG.md`, starting after v1.0.0.
- `nix develop .#benchmarking` carries the reference tools for accuracy checks: iverilog, verilator, yosys, ngspice, Xyce, gnucap and OpenVAF-Reloaded.
- License: Apache 2.0 (was MIT). Third-party notices are in `NOTICE`.
