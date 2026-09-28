// IEEE 1364-2005 §5.2.2, p. 58, the clause's own illegal example:
//   "threed_array[14][1][3:0]                       // Illegal"
// for "wire threed_array[0:255][0:255][0:7];", of which the clause says
// "the array threed_array accesses a single bit of the three-dimensional
// array". [3:0] is then a part-select of a scalar element, which §5.2.1
// (p. 56) makes illegal: "A bit-select or part-select of a scalar ... shall
// be illegal."
//
// Legal neighbour: b_5_2_2_element_selects.v part-selects the 8-bit words of
// twod_array.
// digital-runner: reject
//! inherited IEEE 1364-2005 5.2.2
//! reject E1100
//! reject a scalar has no bits to select
//! xfail VerA refuses the select only as unimplemented ("this digital expression form is not implemented"), not as illegal
module b_5_2_2_scalar_element_part_select_rejected;
  wire threed_array[0:255][0:255][0:7];
  initial $display("%b", threed_array[14][1][3:0]);
endmodule
