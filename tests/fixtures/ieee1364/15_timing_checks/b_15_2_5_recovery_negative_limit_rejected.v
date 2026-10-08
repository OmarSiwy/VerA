// IEEE 1364-2005 §15.2.5, Table 15-5 (p. 246): $recovery's limit is a
// "Non-negative constant expression".
//
// $recovery(posedge clr, posedge clk, -3, ntfr) gives $recovery a limit of
// -3. Legal neighbour: b_15_2_5_recovery.v, the same check with the limit 3.
// digital-runner: reject
//! inherited IEEE 1364-2005 15.2.5
//! reject-only E1148
//! neighbour b_15_2_5_recovery.v
`timescale 1ns/1ns
module b_15_2_5_recovery_negative_limit_rejected(clr, clk);
  input clr, clk;
  reg ntfr;
  specify
    $recovery(posedge clr, posedge clk, -3, ntfr);
  endspecify
endmodule
