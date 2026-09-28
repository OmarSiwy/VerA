// IEEE 1364-2005 §7.2, p. 80: "The delay specification shall be zero, one, or
// two delays." Syntax 7-1: n_input_gatetype [drive_strength] [delay2].
//
// An and gate with three delays. Legal neighbour: and #(10,12) in
// b_7_1_3_gate_delays.v.
// digital-runner: reject
//! inherited IEEE 1364-2005 7.2
//! reject E0210
//! reject expected ')'
module b_7_2_three_delays_rejected;
  reg a, b;
  wire o;
  and #(1,2,3) g(o, a, b);
  initial $finish(0);
endmodule
