// IEEE 1364-2005 §15.3.3: "$fullskew is similar to $timeskew except that the
// reference and data events can transition in either order", one limit for
// each order.
//
// VerA's digital engine does not evaluate it, so it refuses the design by name
// (E1149) rather than run a check that would never report; CLAUSES.tsv keeps
// §15.3.3 not-supported. Legal neighbour: b_15_2_1_setup.v, the same cell
// shape with a check the engine evaluates.
// digital-runner: reject
//! reject-only E1149
//! reject `$fullskew`
//! neighbour b_15_2_1_setup.v
`timescale 1ns/1ns
module b_15_3_3_fullskew_refused(clk, clkb, d);
  input clk, clkb, d;
  reg ntfr;
  specify
    $fullskew(posedge clk, negedge clkb, 50, 70, ntfr);
  endspecify
endmodule
