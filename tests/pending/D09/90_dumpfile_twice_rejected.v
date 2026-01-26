// REJECT. Inherited IEEE 1364-2005 §18.1: $dumpfile names the VCD file for the
// simulation, and there is exactly one such file — the task shall be invoked
// only once, before any $dumpvars, $dumpports or other dump task. A second
// $dumpfile has no defined meaning: the first call has already fixed the file
// the identifier codes and the $enddefinitions header belong to, so "redirect"
// would mean either silently discarding a header or writing two headers into
// one stream.
//
// The rule being broken here is exactly that one-call-per-simulation rule, and
// nothing else in this module is unusual: one scalar, one $dumpvars, one
// change, one $finish. A diagnostic that fires for any other reason (the
// second file name, the ordering relative to $dumpvars, the reg declaration)
// is fixing the wrong thing.
//
// This is a REFUSAL fixture and therefore does not count as positive coverage
// of the VCD row; 11_vcd_dumpvars.v and 12_vcd_dumpoff_on.v carry that.
//
// WHY THE DIRECTIVE NAMES A SUBSTRING. This file carried a bare `//! reject`
// until the review. `tests/torture.zig:223` returns true for ANY diagnostic, and
// this module already produces one today — verified, at 45b505d:
//   error[E1100]: digital source execution failed: digital system task
//   `$dumpfile` is not implemented
// so the bare form was satisfied by the feature being ABSENT and would stay
// satisfied by any unrelated parse error after it lands. The substring below is
// chosen so that today's refusal does NOT contain it: `$dumpfile`, `E1100` and
// `DiagnosticsReported` all match the not-implemented message, and none of them
// would have teeth. The implementation owes a diagnostic whose message contains
// "called more than once" (e.g. "`$dumpfile` called more than once"); when the
// VCD row lands and the message gets a catalogue code, replace the substring
// with that code, which is the stronger form (39 fixtures under tests/fixtures
// pin a code, 48 pin `DiagnosticsReported`).
//
//! reject called more than once
//! rule inherited IEEE 1364-2005 18.1 — $dumpfile shall be called at most once per simulation
`timescale 1ns/1ns
module d09_dumpfile_twice;
  reg a;
  initial begin
    $dumpfile("first.vcd");
    $dumpfile("second.vcd");
    $dumpvars(0, d09_dumpfile_twice);
    a = 1'b0;
    #1 a = 1'b1;
       $finish(0);
  end
endmodule
