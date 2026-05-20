// IEEE 1364-2005 §12.3.6, p. 177: "The two types of module port connections
// shall not be mixed; connections to the ports of a particular module instance
// shall be all by order or all by name." §12.1.2, p. 167, of its Example 2:
// "// ff3(.q(out3),.clear(in1),,,); is illegal".
//
// u connects a by name and y by order. Legal neighbour:
// b_12_1_2_ffnand_instances.v (ff1 all by order, ff2 all by name).
// digital-runner: reject
//! inherited IEEE 1364-2005 12.3.6
//! reject E1100
//! reject mixes ordered and named port connections
//! xfail VerA accepts an instance that connects some ports by name and others by order
module m(a, y);
  input a;
  output y;
  assign y = a;
endmodule
module b_12_3_6_mixed_order_and_name_rejected;
  reg r;
  wire w;
  m u(.a(r), w);
endmodule
