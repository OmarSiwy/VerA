// IEEE 1364-2005 §15.3.6: "The $nochange timing check reports a timing
// violation if the data event occurs during the specified level of the control
// signal", the window from the leading to the trailing reference edge moved by
// its two offsets.
//
// VerA's digital engine does not evaluate it, so it refuses the design by name
// (E1149) rather than run a check that would never report; CLAUSES.tsv keeps
// §15.3.6 not-supported. Legal neighbour: b_15_2_1_setup.v, the same cell
// shape with a check the engine evaluates.
// digital-runner: reject
//! reject-only E1149
//! reject `$nochange`
//! neighbour b_15_2_1_setup.v
`timescale 1ns/1ns
module b_15_3_6_nochange_refused(clk, clkb, d);
  input clk, clkb, d;
  reg ntfr;
  specify
    $nochange(posedge clk, d, 0, 0, ntfr);
  endspecify
endmodule
