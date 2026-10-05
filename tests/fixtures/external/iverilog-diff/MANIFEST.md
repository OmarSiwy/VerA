# iverilog-diff: VerA against Icarus Verilog, transcript for transcript

- reference: Icarus Verilog 13.0 (`iverilog -g2005`, then `vvp -n`), from
  `nix develop .#benchmarking`
- second opinion: Verilator 5 `--lint-only --timing -Wno-fatal -Wno-lint
  -Wno-style` and Yosys `read_verilog`, consulted only where iverilog and VerA
  disagree on accepting a source; their answers are printed, never scored

No upstream files: the inputs are VerA's own fixtures plus the ivtest and
sv-tests selections (see their manifests).

## Inputs

1. Every `.v` under `tests/fixtures/ieee1364/` and `tests/fixtures/digital/`
   that is a `zig build test-devices` case (a `.expected.txt` beside it, or
   `// digital-runner: reject`), with its `// digital-runner:` flags and
   extra files. A case run through a 13.2 library map (`--libmap`, `-L`) is
   skipped: iverilog has no library map.
2. Every selected ivtest test, with its `--std`.
3. Every selected sv-tests test, `--std=1364-2005`.

## Verdict

Agree when both refuse the source, or both accept it, exit alike (zero or
nonzero), and print the same stdout after the normalisation the ivtest
manifest describes (`TOOL_LINE`). "Refuses" is iverilog's compile failing,
and VerA printing `could not compile`. A source whose `vvp` run outlives the
20 s timeout is skipped.

An agreement is not evidence that either tool is right, and a disagreement is
not evidence VerA is wrong: IEEE 1364-2005 decides (AGENTS.md §6). Each
disagreement's verdict is a row in `TRIAGE.md`.
