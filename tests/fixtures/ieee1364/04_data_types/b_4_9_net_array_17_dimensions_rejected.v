// An engine limit, not a language rule. IEEE 1364-2005 §4.9: "Arrays can be
// used to group elements of the declared element type into multidimensional
// objects. ... Each dimension shall be represented by an address range." No
// dimension count is stated. The digital runner gathers one index per
// dimension in a 16-entry table, so it refuses a 17th dimension at the
// declaration (E1100) rather than index past the table. It already did for a
// variable array; a net array reached the table and panicked.
//
// Legal neighbour: audit_type_net_array.v runs a net array.
// digital-runner: reject
//! inherited IEEE 1364-2005 4.9.1
//! reject E1100
//! reject arrays of more than 16 dimensions
module b_4_9_net_array_17_dimensions_rejected;
  wire w [0:0][0:0][0:0][0:0][0:0][0:0][0:0][0:0][0:0][0:0][0:0][0:0][0:0][0:0][0:0][0:0][0:0];
  assign w[0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0] = 1'b1;
  initial #1 $display("accepted");
endmodule
