// IEEE 1364-2005 §15.3.1: $skew reports "(timecheck time) - (timestamp time) >
// limit" at each data event after a reference event, and "A second consecutive
// reference event shall cancel the old wait for the data event and begin a new
// one."
//
// VerA's digital engine does not evaluate it, so it refuses the design by name
// (E1149) rather than run a check that would never report; CLAUSES.tsv keeps
// §15.3.1 not-supported. Legal neighbour: b_15_2_1_setup.v, the same cell
// shape with a check the engine evaluates.
// digital-runner: reject
//! reject-only E1149
//! reject `$skew`
//! neighbour b_15_2_1_setup.v
`timescale 1ns/1ns
module b_15_3_1_skew_refused(clk, clkb, d);
  input clk, clkb, d;
  reg ntfr;
  specify
    $skew(posedge clk, negedge clkb, 50, ntfr);
  endspecify
endmodule
