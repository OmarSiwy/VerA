// IEEE 1364-2005 §15.8: "Both the $setuphold and $recrem timing checks can
// accept negative values when the negative timing check option is enabled",
// the window shifted off the reference edge through the delayed signals of
// 15.5.1.
//
// VerA's digital engine does not evaluate it, so it refuses the design by name
// (E1149) rather than run a check that would never report; CLAUSES.tsv keeps
// §15.8 not-supported. Legal neighbour: b_15_2_3_setuphold.v, the same cell
// shape with a check the engine evaluates.
// digital-runner: reject
//! reject-only E1149
//! reject negative limit
//! neighbour b_15_2_3_setuphold.v
`timescale 1ns/1ns
module b_15_8_negative_limit_refused(clk, clkb, d);
  input clk, clkb, d;
  reg ntfr;
  specify
    $setuphold(posedge clk, d, -2, 5, ntfr);
  endspecify
endmodule
