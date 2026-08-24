// IEEE 1364-2005 §4.9.3, p. 35: "An n-bit reg can be assigned a value in a
// single assignment, but a complete memory cannot. To assign a value to a
// memory word, an index shall be specified." §4.9.3.1.2, p. 35:
// "mema = 0;        // Illegal syntax- Attempt to write to entire array".
//
// mema is the clause's memory; the assignment names it with no index. Legal
// neighbour: b_4_9_3_1_1_array_declarations.v (mema[1] = 0).
// digital-runner: reject
//! inherited IEEE 1364-2005 4.9.3 4.9.3.1.2
//! reject E1100
//! reject requires an element index
//! neighbour b_4_9_3_1_1_array_declarations.v
module b_4_9_3_1_2_whole_memory_write_rejected;
  reg [7:0] mema[0:255];
  initial mema = 0;
endmodule
