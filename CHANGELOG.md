# Updates past v1.0.0, bugs & performance

One short bullet per change, newest first. A fix names its GitHub issue as `(#123)`.

## Unreleased

- Fix: a hosted `.v` device prints its `$display` output (to stderr) for each step the host accepts; a rejected step prints nothing, and a step past 4096 bytes is cut (#8).
- Fix: a `.v` device holds up to 65535 pins (was 256), and past 64 its `deriv_reads`/`ddx_reads`/`jac_pattern` are declared in `contract.MaskOf(|U|)`: one derivative lane per output row instead of a dense Jacobian. The contract accepts any unsigned `U` tag of 8 bits or more; `contract.Mask(D)` is a device's mask type (u64 for every device that declares no wide mask) (#5).
- Fix: an `output reg` port connected to a bit-select, part-select or concatenation drives exactly those bits (IEEE 1364-2005 §12.3.9.2), no longer E1100 (#6).
- Fix: a digital task enable with arguments no longer reads freed memory once later source grows the parser's expression pool (a panic in `digital.compile.infer`) (#7).
- Fix: digital selects with an index wider than 64 bits now work under `--run` and `--emit-exe` (#2).
- Fix: native digital keeps a formatted scan's state across nested output calls (#3).
- Digital engine, runtime, VPI and IR lists are sized before they fill (no behaviour change).
- Commits carry no Co-Authored-By trailers (AGENTS.md §8).
- One changelog: `CHANGELOG.md`, starting after v1.0.0.
- `nix develop .#benchmarking` carries the reference tools for accuracy checks: iverilog, verilator, yosys, ngspice, Xyce, gnucap and OpenVAF-Reloaded.
- License: Apache 2.0 (was MIT). Third-party notices are in `NOTICE`.
