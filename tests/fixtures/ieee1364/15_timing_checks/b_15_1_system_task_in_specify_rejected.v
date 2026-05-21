// IEEE 1364-2005 §15.1, p. 240: "Although they begin with a $, timing checks
// are not system tasks. The leading $ is present because of historical
// reasons, and timing checks shall not be confused with system tasks. In
// particular, no system task can appear in a specify block, and no timing
// check can appear in procedural code."
//
// $display inside a specify block. Legal neighbour:
// b_15_1_timing_check_forms.v, whose block holds only timing checks.
// digital-runner: reject
//! inherited IEEE 1364-2005 15.1
//! reject E0207
//! reject timing checks inside a specify block
`timescale 1ns/1ns
module b_15_1_system_task_in_specify_rejected(clk, d);
  input clk, d;
  specify
    $display("in a specify block");
  endspecify
endmodule
