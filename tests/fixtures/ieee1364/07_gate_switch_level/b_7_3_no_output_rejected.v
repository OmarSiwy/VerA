// IEEE 1364-2005 §7.3, p. 81: "These two logic gates shall have one input and
// one or more outputs. The last terminal in the terminal list shall connect to
// the input of the logic gate, and the other terminals shall connect to the
// outputs of the logic gate."
//
// A buf with a single terminal: that terminal is the last, so it is the
// input, and the gate has no output. Legal neighbour:
// buf (o_buf, a) in b_7_1_1_every_primitive.v.
// digital-runner: reject
//! inherited IEEE 1364-2005 7.3
//! reject E0209
//! reject a buf/not gate needs at least one output and one input
module b_7_3_no_output_rejected;
  wire o;
  buf g(o);
  initial $finish(0);
endmodule
