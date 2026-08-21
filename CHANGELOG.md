# Updates past v1.0.0, bugs & performance

One short bullet per change, newest first. A fix names its GitHub issue as `(#123)`.

## Unreleased

- Fix: a digital task enable with arguments no longer reads freed memory once later source grows the parser's expression pool (a panic in `digital.compile.infer`) (#7).
- Fix: digital selects with an index wider than 64 bits now work under `--run` and `--emit-exe` (#2).
- Fix: native digital keeps a formatted scan's state across nested output calls (#3).
- Digital engine, runtime, VPI and IR lists are sized before they fill (no behaviour change).
- Commits carry no Co-Authored-By trailers (AGENTS.md §8).
- One changelog: `CHANGELOG.md`, starting after v1.0.0.
- `nix develop .#benchmarking` carries the reference tools for accuracy checks: iverilog, verilator, yosys, ngspice, Xyce, gnucap and OpenVAF-Reloaded.
- License: Apache 2.0 (was MIT). Third-party notices are in `NOTICE`.
