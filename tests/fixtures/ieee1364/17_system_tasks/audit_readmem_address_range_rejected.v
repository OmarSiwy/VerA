// IEEE 1364-2005 §17.2.9: when both the task and file specify addresses,
// an address outside the task's requested range is an error, ending the load.
// @2 is within the declared memory but outside requested indices 1..0.
// digital-runner: reject
//! inherited IEEE 1364-2005 17.2.9
//! reject memory file address is outside the requested load range
module audit_readmem_address_range_rejected;
  reg [7:0] mem[3:0];
  initial $readmemh("audit_readmem_restart.hex",mem,1,0);
endmodule
