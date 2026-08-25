// IEEE 1364-2005 §15.5.1: "Delayed data and reference signals can be declared
// within the timing check so they can be used in the model's functional
// implementation": $setuphold's and $recrem's delayed_reference and
// delayed_data arguments, and 15.5.2's stamptime and checktime conditions that
// pair with them, all for negative timing checks.
//
// VerA's digital engine does not evaluate it, so it refuses the design by name
// (E1149) rather than run a check that would never report; CLAUSES.tsv keeps
// §15.5.1 not-supported. Legal neighbour: b_15_2_3_setuphold.v, the same cell
// shape with a check the engine evaluates.
// digital-runner: reject
//! reject-only E1149
//! reject argument 8
//! neighbour b_15_2_3_setuphold.v
`timescale 1ns/1ns
module b_15_5_1_delayed_signal_refused(clk, clkb, d);
  input clk, clkb, d;
  reg ntfr;
  wire dclk;
  specify
    $setuphold(posedge clk, d, 2, 5, ntfr, , , dclk);
  endspecify
endmodule
