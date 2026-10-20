# sv-tests: triage

Every disagreement `tools/external_digital.py` reports for this suite, one row
per root cause. A row lists the exact names it covers (fnmatch patterns; a
name's `[`, `]`, `*`, `?` are bracket-escaped), so a new disagreement is never
swallowed by an old row, and a name that stops disagreeing turns its pattern
`STALE`: delete it, and the row with its last pattern.

Verdicts, judged by IEEE 1364-2005 (the Verilog-AMS LRM for VerA's AMS
fixtures), never by either tool's say-so:

- `vera-bug`: VerA is wrong (output, a hang, accepting an error, refusing legal source by a rule the standard does not have).
- `vera-unimplemented`: legal 1364-2005 VerA refuses with a diagnostic that says it is not implemented.
- `vera-correct`: VerA follows the standard; the reference (iverilog, its gold file, the test's expectation) does not.
- `implementation-defined`: both behaviours conform; the cited clause leaves the choice open.
- `out-of-scope`: not a 1364-2005 question (SystemVerilog, Verilog-AMS, SDF files, an Icarus-only behaviour).
- `flaky`: nondeterministic; the reason says what varies.

Measured against `vera` at 05438e97 on 2026-10-20 (1 disagreements).

| names | verdict | reason |
|---|---|---|
| `chapter-5/5.6.4--compiler-directives-pragma.sv` | vera-unimplemented | §28 protected envelopes: VerA refuses `pragma protect by name (E0146) instead of honouring or ignoring it; iverilog ignores the pragma |
