// IEEE 1364-2005 §8.1.1, p. 107: "All ports of a UDP shall be scalar; vector
// ports are not permitted."
//
// Input a is declared [1:0]. Legal neighbour: b_8_1_definition_placement.v,
// the same inverter table on a scalar input.
// digital-runner: reject
//! inherited IEEE 1364-2005 8.1.1
//! reject E0208
//! reject found `[`
primitive vec_in(q, a);
  output q;
  input [1:0] a;
  table
    0 : 1;
    1 : 0;
  endtable
endprimitive

module b_8_1_1_vector_port_rejected;
  initial $finish(0);
endmodule
