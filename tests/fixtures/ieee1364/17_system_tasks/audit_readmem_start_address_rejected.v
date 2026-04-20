// IEEE 1364-2005 17.2.9, printed297: file addresses must be inside the
// task-requested range. Start-only3 implies3..3, so @2 is outside even though
// it is inside the declared memory. This is an error, not a count warning.
// digital-runner: reject
//! inherited IEEE 1364-2005 17.2.9
//! reject memory file address is outside the requested load range
module audit_readmem_start_address_rejected;
  reg [7:0] mem[3:0];
  initial $readmemb("audit_readmem_formfeed_address.bin",mem,3);
endmodule
