# Design review: #41, the §9.4.3 '#' flag

- **Change**: lowering, the display translation and the run-time `$sformat`
  read '#' as a flag through one owner (`str_kernels.zcFlag`); `%#e/%#f/%#g`
  print C's alternative form; '#' elsewhere is E0825.
- **Domain skill(s)**: `compiler-construction` (FIXTURES.md).
- **Hot/cold**: cold — evidence: none. Format scanning runs once per display
  call at compile time; `zCReal` runs when a device prints.
- **Stages run**: R6, R7 (bug fix, §10.1).

## Containment (R6)

| Module | Error set | Boundary validation | Check budget (Principle 17.10) | Bounds |
| ------ | --------- | ------------------- | ------------------------------ | ------ |
| `ir` `lower/systask.zig` | `Oom` (unchanged) | the format literal is source input: '#' on a conversion `zcAltOk` refuses is E0825, a diagnostic, never an assert | no new assert | `nextConv` advances `i` past every byte it reads; one call per conversion |
| `backend` `cg_display.zig` | `Error` (unchanged) | none new: lowering has refused every '#' `zCReal` cannot render | the `zcFlag` switch's `else => unreachable` is the five-bit contract of `zcFlag` | unchanged |
| `kernels` `str_kernels.zig` | none (pure) | `zSFormatRt`, whose format is run-time data, warns and copies a '#' specification it cannot render, as it does an unknown letter | none | `zCReal`'s '#' adds one byte; the scratch already has 8 bytes of slack |

## Test plan (R7)

| Bug class | Oracle | Layer | Tier | Harness / file |
| --------- | ------ | ----- | ---- | -------------- |
| a flag read as the conversion letter (#41) | hand table of formats → (letter, '#') | unit | merge | `systask.zig` test "§9.4.3 nextConv" |
| '#' rendered unlike C | glibc `snprintf`, 32 flag sets × 6 letters × specials, ties and 10^5 random doubles | differential | merge (Linux) | `tests/printf_reference.zig` |
| '#' lost between lowering and the kernel | emitted text pins flag 16 | unit | merge | `cg_display.zig` test "Table 9-23" |
| device output | hand-derived C11 text | fixture | merge | `s01_14`, `s01_15`, `s01_16` |
| type pairing escapes under '#' (a) | E0819 fixture, reject-only | fixture | merge | `s01_17` |
| '#' on a conversion with no C form, false E0810 (b, c) | E0825 fixture, reject-only | fixture | merge | `s01_18` |
| host rendering of a `.record` device | hand rows | unit | merge | `tools/contract.zig` test "formatC: the C11 7.21.6.1 corners" |

The missing oracle (Principle 19.4) was `printf_reference.zig`'s flag sweep,
which stopped at 16 sets and so never asked '#'.

Exit criteria: `zig build test` exits 0; the five fixtures pass and their
VERDICTS.tsv rows match.
