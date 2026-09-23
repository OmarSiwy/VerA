# Inherited display tasks: source and evidence review

Reviewed 2026-09-23. This is an IEEE 1364-2005 §17.1 supplement to
`conformance-display.md` and `conformance-monitor.md`, not an exhaustive-coverage
or conformance claim. Complete extracted §17.1 was read through the §17.2
boundary, printed 278–286 / PDF 308–316. Visually inspected PDF pages 308–310,
312–315: Syntax 17-1/17-2, Tables 17-1/17-2 and 17-4/17-5/17-6, field examples,
unknown rendering, strength, hierarchy and string prose. Table 17-3 real-format
layout was not newly visually verified. Source is the licensed local
`1364-2005.pdf`, SHA-256
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.

## Obligation register

The identifiers below are bounded groups requiring further atomic expansion;
one transcript does not cover every width, entry point or invalid input.

| ID | Source | Obligation and evidence boundary |
|---|---|---|
| DISP-001 | 17.1.1 | Argument order, newline only for display, empty display newline, empty write no bytes, null argument one space. New `audit_display_write_runs` observes write concatenation, argument runs, null and empty calls; existing `d09_01_display_radix` complements it. |
| DISP-002 | 17.1.1.1, Table 17-1 | Literal percent; newline, tab, slash, quote and one-to-three octal digits. Octal above 377 permits an error; it does not mandate rejection. All entry-point/escape combinations remain open; Clause 3 packed-string evidence is not display escape execution. |
| DISP-003 | 17.1.1.2, Table 17-2 | Each consuming format needs an expression; unformatted expressions use task radix. New write-radix transcript and missing-argument rejection provide a bounded pair, not complete arity/type validation. |
| DISP-004 | 17.1.1.2 | Lower/uppercase h/d/o/b/c/s/t/u/z/v, plus non-consuming m/l. New ASCII and hierarchy fixtures expose unsupported legal formats. Binding format is separately `audit_config_binding_display`; time format is in the control/time review. |
| DISP-005 | 17.1.1.3 | Automatic expression-width fields, decimal space padding, nondecimal zero padding, zero modifier minimal width, explicit field widths, real e/f/g. Existing field-size ledger remains authoritative; FMT-G-001 interpretation issue is not resolved by current implementation. |
| DISP-006 | 17.1.1.4 | Decimal all-x/all-z lowercase versus partial-X/partial-Z uppercase, with X precedence; decimal field alignment. New `audit_display_decimal_states` independently checks five classes at unsigned width 12 and %0d. |
| DISP-007 | 17.1.1.4 | Hex groups of four and octal groups of three classify all/partial unknown similarly; binary preserves each bit. Existing `d09_02_display_unknown_radix` is selected evidence, not exhaustive partial-leading-group/sign/width coverage. |
| DISP-008 | 17.1.1.5 | %v takes scalar net references, three-character strength output; equal-strength mnemonic versus ranges, different rules for known/X/L/H, high-impedance restriction. Tables 17-4–17-6 fully inspected. No new strength oracle; runtime and invalid scalar/net/type boundaries remain open. |
| DISP-009 | 17.1.1.6 | %m has no operand and names invoking module/task/function/named block. New module/named-block fixture fails before first output. Tasks/functions, nested instances and escaped-name spelling remain open. |
| DISP-010 | 17.1.1.7 | %s interprets packed 8-bit ASCII, ignores leading zero bytes, requires no terminator. New literal-based ASCII fixture avoids string-assignment dependency but fails at first %s. Later %S and %c/%C cases are unexecuted, not separate observed failures. |
| DISP-011 | 17.1.1.2 | %u writes native-endian 32-bit words, least-significant word first, x/z zeroed; %z writes native-endian s_vpi_vecval structures in that order. Requires binary capture with host ABI/endian-aware independent oracle; portable text golden cannot certify it. See file-I/O review. |
| DISP-012 | 17.1.2 | Strobe samples end of time step, not a promised callback FIFO. Existing scheduling ledger and revised strobe evidence apply; no duplicate closure claim. |
| DISP-013 | 17.1.3 | Monitor replacement, coalescing, time-function exceptions, on/off behavior. Existing monitor ledger records failures; no new lifecycle closure here. |

## Derivations and observed execution

Ran each new positive with the actual root `zig-out/bin/vera --run` from the
worker worktree; no mocked compiler and no full suite. All filenames below are
under `tests/fixtures/digital/` with a same-stem `.expected.txt` for positives.

| Fixture | Independent oracle | Observed result |
|---|---|---|
| `audit_display_decimal_states.v` | 12-bit unsigned maximum 4095 needs four decimal columns; one state letter has three leading spaces, %0d none. | Exit 0; exact expected five-line transcript. |
| `audit_display_write_runs.v` | Ordered strings/expressions/null give `A3B0a C`; writeh 8-bit 0a, writeb four bits 0101, writeo six bits 07 concatenate without newline until display. | Exit 0; exact expected two-line transcript. |
| `audit_display_packed_ascii.v` | 00414243 gives ABC with leading zero omitted, 444546 gives DEF; 5a and 21 give Z and !. | Exit 1, E1100 unsupported format at first %s; no later calls executed. |
| `audit_display_named_scope.v` | %m/%M consumes no operand; following %0d prints 7; block path adds `.inner`. | Exit 1, E1100 unsupported format at first %m; block call unexecuted. |
| `audit_display_missing_argument_rejected.v` | %h has no required expression; legal matching %h case exists in write-runs. | Equivalent isolated control exit 1, E1100 header `missing display argument`; opted-in digital rejection added, not analog rejection coverage. |

The invalid control is retained in `tools/display-audit-controls/` as provenance.
No XFAIL was added to hide unsupported legal programs. Root must integrate and
run its digital suite before claiming suite results.

## Source and scope cautions

The generic operand-exception prose mentions %m and %% but omits %l; Table 17-2
and §13.6 establish library binding output, so this omission must not produce a
spurious required operand test. %g precision/selection ambiguity remains
FMT-G-001, not an implementation-derived golden. Binary stream format is
explicitly host dependent; strength values depend on source net driving and
resolution, not arbitrary formatted integers. Default time format is governed
by §17.3.2 and design timescales, not an assumed universal decimal output.

These are inherited **digital** obligations. AMS §9.4 changes analog display
execution timing and extends formats (including engineering notation); analog
acceptance does not prove digital support, and the digital E1100 diagnostic's
reference to the narrower AMS table does not make IEEE %s/%m illegal. Existing
`d09_01_display_radix` commentary about analog minimal-width behavior cannot
justify a source deviation; the separate field-width ledger tracks that gap.

This expands source-review and evidence inventories for measures B/C, without
re-measuring either, changing compiler behavior, or claiming exhaustive closure.

Root integration, 2026-09-23: main read this complete report and each new fixture,
retained the independent transcript derivations, and integrated the files and
diagnostic control. Full source rereading/visual ownership remains as stated
above; main has not silently claimed the worker's visual review as its own.
Independent root execution and full gate results are pending.
