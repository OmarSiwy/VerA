// IEEE 1364-2005 §15.3.2: "The default behavior for $timeskew is timer-based.
// A violation shall be reported immediately upon an elapse of time after the
// reference event equal to the limit", altered by its event_based_flag and
// remain_active_flag.
//
// VerA's digital engine does not evaluate it, so it refuses the design by name
// (E1149) rather than run a check that would never report; CLAUSES.tsv keeps
// §15.3.2 not-supported. Legal neighbour: b_15_2_1_setup.v, the same cell
// shape with a check the engine evaluates.
// digital-runner: reject
//! reject-only E1149
//! reject `$timeskew`
//! neighbour b_15_2_1_setup.v
`timescale 1ns/1ns
module b_15_3_2_timeskew_refused(clk, clkb, d);
  input clk, clkb, d;
  reg ntfr;
  specify
    $timeskew(posedge clk, negedge clkb, 50, ntfr);
  endspecify
endmodule
