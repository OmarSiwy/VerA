// IEEE 1364-2005 17.2.9: an address is "an index into the array that models
// the memory", and the clause gives an address no x or z digit. A variable
// start bound that still holds its 4.2.2 start x at the call names no
// address, so the load is refused rather than quietly started at the lowest
// one. b_17_2_9_readmem_variable_bounds.v is the legal neighbour: the same
// call with the bounds assigned first loads.
// digital-runner: reject
//! inherited IEEE 1364-2005 17.2.9
//! reject start or finish address evaluates to x or z
module b_17_2_9_readmem_unknown_bound_rejected;
  reg [3:0] m [0:7];
  integer first;
  initial $readmemb("09_readmemb_range.bin", m, first);
endmodule
