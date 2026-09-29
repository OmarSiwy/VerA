// IEEE 1364-2005 A.2.2.3, p. 491:
//   delay3 ::= # delay_value
//     | # ( mintypmax_expression [ , mintypmax_expression [ , mintypmax_expression ] ] )
// A.8.3, p. 505: mintypmax_expression ::= expression | expression : expression : expression
// §5.3, p. 61 (quoted for context): "This is intended to represent minimum,
// typical, and maximum values—in that order."
//
// §5.3 names no default corner, so nothing below depends on which of 1, 8, 9
// the tool picks for `assign #(1:8:9) n = r;`. r rises at t=10: at t=10
// (after #0) no corner has elapsed, so n = 0; at t=19 every corner has, so
// n = 1. Output: "10: 0" then "19: 1".
//! inherited IEEE 1364-2005 A.2.2.3
`timescale 1ns/1ns
module b_A_2_2_3_mintypmax_delay;
  reg r;
  wire n;
  assign #(1:8:9) n = r;
  initial begin
    r = 0;
    #10 r = 1;
    #0 $display("%0d: %b", $time, n);
    #9 $display("%0d: %b", $time, n);
    $finish(0);
  end
endmodule
