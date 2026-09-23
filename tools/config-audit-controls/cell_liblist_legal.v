// IEEE13.3.1.4: unqualified cell selector may pair with liblist.
// Declaration acceptance only, not binding behavior.
config config_legal;
  design config_host;
  cell config_host liblist work;
endconfig
module config_host;
  initial begin $display("accepted"); $finish(0); end
endmodule
