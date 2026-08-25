// IEEE 1364-2005 §15.2.4, Table 15-4 (p. 245): $removal's limit is a
// "Non-negative constant expression".
//
// $removal(posedge clr, posedge clk, -3, ntfr) gives $removal a limit of -3.
// Legal neighbour: b_15_2_4_removal.v, the same check with the limit 3.
// digital-runner: reject
//! inherited IEEE 1364-2005 15.2.4
//! reject-only E1148
//! neighbour b_15_2_4_removal.v
`timescale 1ns/1ns
module b_15_2_4_removal_negative_limit_rejected(clr, clk);
  input clr, clk;
  reg ntfr;
  specify
    $removal(posedge clr, posedge clk, -3, ntfr);
  endspecify
endmodule
