// IEEE13.3.1.4: INVALID library-qualified cell selector with liblist.
// Currently accepted; not a broad-error or invented-diagnostic reject test.
config config_invalid;
  design config_host;
  cell work.config_host liblist work;
endconfig
module config_host;
  initial begin $display("accepted"); $finish(0); end
endmodule
