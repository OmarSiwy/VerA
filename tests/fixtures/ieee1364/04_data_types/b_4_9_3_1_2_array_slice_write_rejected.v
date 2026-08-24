// IEEE 1364-2005 §4.9.3.1.2, p. 35: "arrayb[1][12:31] = 0; // Illegal Syntax -
// Attempt to write to elements [1][12]..[1][31]".
//
// arrayb is the clause's reg arrayb[7:0][0:255]; [12:31] is a range of its
// second dimension, several elements, not one. Legal neighbour:
// b_4_9_3_1_1_array_declarations.v (arrayb[1][0] = 0).
// digital-runner: reject
//! inherited IEEE 1364-2005 4.9.3.1.2
//! reject E1100
//! reject each array dimension takes an index
//! neighbour b_4_9_3_1_1_array_declarations.v
module b_4_9_3_1_2_array_slice_write_rejected;
  reg arrayb[7:0][0:255];
  initial arrayb[1][12:31] = 0;
endmodule
