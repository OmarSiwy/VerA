// IEEE 1364-2005 §17.1.1.5, p. 283: "The %v format specification is used to
// display the strength of scalar nets. For each %v specification that
// appears in a string, a corresponding scalar reference shall follow the
// string in the argument list."
//
// v is a 4-bit vector net, so the argument that follows %v is not a scalar
// reference. Legal neighbour: b_17_1_1_5_strength_format.v, which gives %v
// only scalar nets.
// digital-runner: reject
//! inherited IEEE 1364-2005 17.1.1.5
//! reject E1100
//! reject scalar
//! xfail VerA refuses every %v as unimplemented ("only the §9.4.3 Table 9-22 conversions ... are implemented"), not because the argument is a vector
module b_17_1_1_5_strength_vector_rejected;
  wire [3:0] v;
  assign v = 4'b1010;
  initial $display("%v", v);
endmodule
