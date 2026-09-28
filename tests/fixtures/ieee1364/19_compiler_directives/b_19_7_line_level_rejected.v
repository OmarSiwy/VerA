// IEEE 1364-2005 §19.7, p. 357: "The level parameter shall be 0, 1, or 2."
//
// The level here is 3. Legal neighbour: b_19_7_line_directive.v uses levels
// 2, 1 and 0.
// digital-runner: reject
//! inherited IEEE 1364-2005 19.7
//! reject E0128
//! reject the level must be 0, 1 or 2
`line 10 "orig.v" 3
module b_19_7_line_level_rejected;
  initial $display("accepted");
endmodule
