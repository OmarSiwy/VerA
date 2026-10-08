# Design review: #61, analog `%d` automatic sizing

§10.1: a bug fix runs R6 and R7 (the missing oracle, Principle 19.4).

- **Change**: a bare or `%d` number in an analog display, `$sformat`,
  `$swrite` or file task prints in IEEE 1364 §17.1.1.3's automatic field:
  lowering records the operand's width and sign
  (`$display$width(value, bits, signed)`, `lower/systask.zig`
  `decimalWidth`), codegen pads to the largest value's columns
  (`cg_display.decimalField`); a device's `say` records the same field.
- **Domain skill(s)**: `compiler-construction`.
- **Hot/cold**: cold. The sizing runs once per display operand at compile
  time; the emitted print runs only at an accepted point.
- **Reading**: VAMS §9.1: "Verilog-AMS HDL is a superset of IEEE Std 1364
  Verilog and hence all the system tasks in IEEE Std 1364 Verilog are
  supported"; §9.4.1: "Verilog-AMS extends the display tasks so that they
  can be used in the analog context"; §9.4.3 Table 9-22 gives `%d` no width
  rule of its own. So 17.1.1.3 applies, as fixture 197 already read it for
  `%h`. The integer half is the clause, not a choice, so it gets no new VD
  entry; the real's 20 columns are VD-120's, now in both contexts.

## Data (R2)

No table. `$display$width` gains an optional third argument (signed, 0 or
1); its width is 1..64 bits (`widthRecord` asserts it).

## Containment (R6)

| Module | Error set | Boundary validation | Check budget | Bounds |
| ------ | --------- | ------------------- | ------------ | ------ |
| `analog` `lower/systask.zig` | `Oom` (unchanged) | none new: the operand is already lowered and typed | none | `decimalSize` recurses on `+x` and `?:`, as `formatBits` does |
| `backend` `cg_display.zig` | `Error` (unchanged) | none: only lowering mints `$display$width` | `assert(args.len == 2 or 3)`, `assert(1 <= bits <= 64)`, `assert(cols <= 20)` | none |

A leading operand that is not message text (§9.5.2's descriptor, §9.7.3's
finish_number) is never wrapped (`messageStart`): `finishLevel` reads the
finish_number as a constant, and a wrapped one would have read as 1.

## Test plan (R7)

| Bug class | Oracle | Layer | Tier | Harness / file |
| --------- | ------ | ----- | ---- | -------------- |
| field width wrong for a width/sign | hand-written largest values (-2147483648, 4095, ...) | unit | merge | `cg_display.zig` test `fieldCols` |
| analog `%d` minimal-width again | hand-derived `$sformat` text: integer, parameter, unsized literal, bare, real (both signs), comparison, `%0d`, `%h` | fixture | merge | `ch09_system_tasks/analog_decimal_is_auto_sized.va` |
| emitted format text | the Zig format string (`{s:>11}`) | unit | merge | `cg_display.zig` tests "§9.4.1 every string argument ...", "§9.7.3 $fatal's finish_number ..." |
| a host renders a different field | `say_sites` fmt `%11d` and its rendered text | host | merge | `tests/say_host.zig` |
| `$fatal(2, ...)` exits 1 | exit status | fixture | merge | `b6_fatal_finish_number_2_exit_status.va` (unchanged) |

The missing oracle was an analog fixture comparing a `%d` of an `integer`
with the 11-column text; every existing one used `%0d`, a sized literal or
a comparison. The digital twin (iverilog, VerA digital) prints the same.

Exit criteria: `zig build test` exits 0; the fixture suite's FAIL list is
unchanged plus nothing; `tools/doctest.py` passes (the user book's examples
now write `%0d`, so their transcripts do not move).
