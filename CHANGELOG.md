# Updates past v1.0.0, bugs & performance

One short bullet per change, newest first. A fix names its GitHub issue as `(#123)`.

## Unreleased

- Fix: a device built for a simulator no longer drops its `$strobe`/`$display`/`$write`/`$debug`/`$warning`/`$info` (W0850): it publishes `say_sites` and `say`, which a host calls once per accepted point to collect records into a buffer it lends (`contract.Say`) and prints with `contract.formatSay`; VerA's testbench (`--display=record`) and `sim.spice` print them, `--display=drop` keeps the old device, and W0850 now names only what is still dropped (`$monitor`, `$finish`/`$stop`, file tasks) (#10).
- Fix: a `--spice` `.subckt` may hold M, Q, J and D cards: each instantiates its model, a `.model`'s Verilog-A module type (BSIM-CMG, BSIM4, ...) with the card's parameters over the model card's and `M=` as `$mfactor`, or a module of that name; `.include`, `.lib file entry` and `.hdl` are read, netlist names match the design's regardless of case, and a card whose model is a behaviourless Table E.1 `nmos`/`npn`/`d` is refused at the card (E0953) (#9).
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
