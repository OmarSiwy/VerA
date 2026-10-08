// IEEE 1364-2005 §17.4.1, Syntax 17-11, p. 302:
//   finish_task ::= $finish [ ( n ) ] ;
// The task takes at most one argument, n.
//
// $finish(0, 1) passes two. Legal neighbour: b_17_4_1_finish_exits.v's
// $finish(0).
// digital-runner: reject
//! inherited IEEE 1364-2005 17.4.1
//! reject E1100
//! reject $finish accepts zero or one argument
//! neighbour b_17_4_1_finish_exits.v
`timescale 1 ns / 1 ns
module b_17_4_1_finish_two_arguments_rejected;
  initial $finish(0, 1);
endmodule
