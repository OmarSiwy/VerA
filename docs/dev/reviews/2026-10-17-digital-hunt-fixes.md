# Design review: #55, #56, #58, #63, #64, #65, digital findings of the 2026-10-17 bug hunt

Six bug fixes, one commit each. §10.1: a bug fix runs R6 and R7 (the missing
oracle, Principle 19.4). Built and gated by the coordinator at the end of the
wave; every expected value below is derived by hand in its fixture's header.

- **Domain skill(s)**: `compiler-construction` (FIXTURES.md), `writing-perfect-verilog`.
- **Hot/cold**: cold, except #55's delay choice, which runs once per scheduled
  net transition (no loop added; one truth fold over the net's words instead of
  one bit read).
- **Engines**: every behaviour fix changes the interpreter (`src/sim/digital/`)
  and the native runtime (`src/sim/rt/`, `lib/digital/emit*.zig`) through one
  shared function, or is in the shared front end / elaboration both read.

| # | Change | Reading | One place |
| - | ------ | ------- | --------- |
| 55 | a vector net's own `delay3` picks rise/fall/off from the whole value | IEEE 1364-2005 §6.1.3 (declaration assignment: unambiguous); a net delay on a vector: VD-119 (new), the same whole-value rule | `Delay.continuous(from: Int.Bit, value)`, called by both engines' drivers and nets |
| 56 | a generate block's variables are declared in its scope, per iteration, with §6.2.1 initializers | §12.4.1/§12.4.2 scopes, §12.5 names | `elab.generate`'s `.block` arm; `root.initVars` shared with module variables |
| 58 | digital `$abstime`, `$ln1p`, `$expm1` run; the other digital-Yes names VerA does not run are E0829 | VAMS §9.2 tables, §9.10, §9.14 | `compile.vams_digital_unrun`; `time.secondsAt` for both engines |
| 63 | an unparenthesized `delay3` is one `delay_value`; a range after a net's delay is E0207 | A.2.1.3, A.2.2.3 | `parser/net.zig parseDelays` (as `stmt.zig parseDelay` already did) |
| 64 | `%t` of a real operand formats the real time | §17.3.2 (its example formats `$realtime`) | `fmt.time(out, t: f64, ...)`, `fmt.timeOperand` for integral operands |
| 65 | a file address outside the task's range ends the load (E1157), not the run | §17.2.9 "the load operation is terminated" | `MemLoad.out_of_range_text`; both engines report and return |

## Containment (R6)

| Module | Error set | Boundary validation | Check budget | Bounds |
| ------ | --------- | ------------------- | ------------ | ------ |
| `sim` `digital/net.zig` `Delay.continuous` | none (pure) | none: `from` is an engine value | none | one pass over the value's words |
| `sim` `rt/net.zig` `resolve` | `Error` (unchanged) | none | none | one pass over the net's words |
| `sim` `digital/elab.zig` `generate` | `Error` (unchanged) | an initialized generate-block array is refused as a module's is | none | one `mintVar` per declaration per iteration (the loop is already bounded by the genvar repeat test) |
| `sim` `digital/compile.zig` | `Error` (unchanged) | an unrun digital-Yes name is E0829 (`failWith`) at elaboration | none | static map |
| `sim` `time.zig` `secondsAt` | none (pure) | `assert` on `finest` in `Quantum`'s range: the caller passes the design's finest precision, never outside data | Debug | table of 16 powers |
| `frontend` `parser/net.zig` | `Error` (unchanged) | source input: E0207 on `[` after a net's delay | none | unchanged |
| `kernels` `fmt.zig` `time` | `std.Io.Writer.Error` (unchanged) | none | none | unchanged |
| `sim` `digital/display.zig`, `rt/root.zig` `readmem` | `Error` (unchanged) | the file is outside data: an out-of-range address is a reported error (E1157), never an assert; the run goes on and exits 1 | none | unchanged |

## Test plan (R7)

| Bug class | Oracle | Layer | Tier | Harness / file |
| --------- | ------ | ----- | ---- | -------------- |
| a vector net delay chosen from one bit | hand-derived transition times beside `assign #(3,5)` | fixture, both engines | merge | `ieee1364/06_assignments/b_6_1_3_vector_net_delay.v`; `net.zig` test "continuous vector delay" |
| a generate-scope declaration never declared | hand-derived values read and written by `g[i].r`, `c.v` | fixture, both engines | merge | `ieee1364/12_hierarchy/b_12_4_1_generate_block_variables.v` |
| a VAMS digital-Yes function refused as an unknown form | hand-derived `%g` text; E0829 with its table, legal neighbour | fixture, both engines | merge | `digital/vams_digital_abstime_math.v`, `digital/vams_digital_temperature_refused.v`; `time.zig` test `secondsAt` |
| a misplaced delay parsed as an expression | E0207 pinned with its phrase; legal neighbour with a transcript | fixture | merge | `ieee1364/A_formal_syntax/b_A_2_1_3_delay_before_range_rejected.v`, `b_A_2_1_3_range_then_delay.v` |
| a real `%t` operand rounded first | hand-derived `%t` text for a real, a literal and `$time` | fixture, both engines; unit | merge | `ieee1364/17_system_tasks/b_17_3_2_timeformat_real_operand.v`; `fmt.zig` test "%t scales" |
| a load error ending the run | E1157 and the transcript after it | fixture, both engines | merge | `ieee1364/17_system_tasks/b_17_2_9_readmem_address_outside_task_range.v` (a reject with an `.expected.txt`, which `devices.zig`/`native.zig` now compare) |

The missing oracles: no fixture put a vector on a net's own delay, a variable
in a generate block, a VAMS-only name in a `.v` process, a range after a
delay, a real under `%t`, or anything after a failed load. The harness could
not say "this run reports an error and keeps going"; a reject `.v` with an
`.expected.txt` now does.

## Checklist

| # | Check | Source | Verdict | Evidence |
| - | ----- | ------ | ------- | -------- |
| 1 | one rule, one place, both engines | AGENTS §4 "fix at the root" | pass | table above |
| 2 | refusal by clause with a named code and a legal neighbour | AGENTS §2, §4 | pass | E0829, E0207, E1157 fixtures and their neighbours |
| 3 | no new `else =>` over a boundary enum | AGENTS §4 | pass | `SysFn` additions fall in existing `else` prongs whose reasons still hold |
| 4 | fixture right before the compiler changes | AGENTS §6 | pass | each header derives its values; #55's net-delay case is a reading (VD-119), #65 changes `audit_readmem_address_range_rejected.v`'s pinned text only |

## Accepted exceptions

None. Open for the user: VD-119's choice (whole value, against a per-bit
reading of §6.1.3's last paragraph) and a declaration assignment's delay
still elaborated as the net's (VD-119 "VerA today").
