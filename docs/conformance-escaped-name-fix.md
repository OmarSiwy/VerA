# Escaped identifier normalization repair

Source AMS2.8.1 printed17/physical30 was fully read and visually inspected for
the lexical ledger. Every printable ASCII33..126 is permitted within an escaped
name; delimiters are excluded from its identity. The all-ASCII fixture's expected9
is retained unchanged, not narrowed to punctuation the implementation accepts.

Current root parser baseline SHA256:
`2475e0cd931ae32757872bfa418e22d0edfb822f57c8fc27515fff4a7949804a`.
Own parser was cmp-identical to this baseline before work, including integrated
UDP row-edge changes. Only `lib/frontend/parser.zig` production code is changed.

## Isolation and cause

Root CLI SHA256 `0439a27f71562b347f5be260d01e378677ed102d46dee2fc0845df39acb73a51`:
scratch controls under `tools/escaped-name-controls/` individually assign/read9.
Dot spelling a.b exits1 E1100 undeclared digital variable; slash, backslash,
grave accent, ordinary simple name and escaped keyword each exit0/output9.
These controls were run with actual root CLI, not a stub. The full printable
range fixture has the same failure. No claim that all combinations were isolated.

Declarations use Parser.internTok, which represents a dot inside an escaped name
with a space sentinel to keep it distinct from an actual hierarchical separator.
The expression's first identifier used raw file.intern instead. Thus declaration
and reference had different interned IDs. Subsequent hierarchical components
already use expectIdent/internTok; only the expression head bypassed it.

The fix uses internTok for the expression head too. Nature access-name lookup
must use the resulting normalized name: nature access declarations are parsed
through the same expression arm, so keeping raw lookup text would create a new
inconsistency for access names containing dots. No new encoding convention or
runtime-specific workaround is introduced.

## Focused tests and boundaries

New parser tests compare declaration/reference StrIds for a.b, a..b, dot alone,
slash, backslash, grave accent, simple/escaped keyword and the entire permitted
ASCII range. A second test compares escaped instance declaration and first
hierarchical path component. Both were executed against unmodified production
logic first: each exit1 with differing expected/found StrIds. After the repair,
both pass. Nature access normalization gets its own branch-access AST test.

`zig test --dep diag -Mroot=lib/frontend/parser.zig -Mdiag=lib/diag.zig
--test-filter 'escaped '` exits0: all four matched tests pass, including existing
lexer escaped/system-name coverage. The existing UDP single-transition focused
test also exits0. An initial new test named a nonexistent ExprTag.access; it was
corrected to the actual branch_access AST tag before the successful run.

New digital `audit_ams_lexical_escaped_hierarchy` pair observes9/9 through escaped
and ordinary instance heads at time1. This and the previously handed-off all-ASCII,
terminator and long-name fixtures need production execution against a rebuilt
patched CLI at main integration. This worker has not rebuilt the CLI or run full
gates; unit AST normalization evidence does not itself establish digital/analog
execution closure. Existing analog hierarchy/escaped-net fixtures are relevant
regression targets for main, especially escaped_period_is_not_a_path.va.

Earlier ledger failure is historical evidence and remains unchanged until
integration records the actual patched execution. No conformance measure computed.

## Root integration checkpoint

Main reread AMS2.8.1 and the declaration/reference normalization paths, then
integrated the patch and four digital fixture pairs. The focused parser command
passes all four matched tests. `zig build test -j2` exits0; log:
`/tmp/vera-escaped-unit.log`. The full digital run exits1, with FAIL/XFAIL
names identical to the datatype baseline (`/tmp/vera-escaped-devices.names`
versus `/tmp/vera-escaped-before-devices.names`). Strict regression subsequently
exits1, with the normalized FAIL/XFAIL name list identical to the preceding
datatype/PLI checkpoint (`/tmp/vera-escaped-strict.names` versus
`/tmp/vera-types-pli-strict.names`). Existing failures remain open.

The build-produced CLI SHA256 is
`6b6e9b28b46620533350a062c8a454330b5ff0ff4ab6fc14a01775c9df45e4ce`.
Direct execution of all four new digital fixtures exits0, matches each expected
transcript byte-for-byte, and produces empty stderr. Root logs use
`/tmp/vera-lexical-{escaped_ascii,escaped_hierarchy,escaped_terminators,long_distinct}.{out,err}`.
The patched CLI's analog escaped-period regression also exits0 with both
checks ok=1 (`/tmp/vera-escaped-analog-patched.stderr`). An earlier run used
the stale installed zig-out binary; only this explicitly patched run is repair
evidence. Build targets do not necessarily refresh that installed binary.

Independent ledger review identifies a remaining discriminator limitation:
assigning and reading one all-ASCII name does not catch consistently stripping
punctuation from both spellings. The fixture establishes bounded legal-name
execution, not complete identity preservation. Separate collision controls
remain required. No entire lexical rule is promoted to verified.
