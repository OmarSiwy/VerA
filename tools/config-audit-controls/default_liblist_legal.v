// IEEE13.3.1.2: matching legal neighbor for default/use rejection.
// Declaration acceptance only; binding does not distinguish this config.
config config_legal;
  design config_host;
  default liblist work;
endconfig
module config_host;
  initial begin $display("accepted"); $finish(0); end
endmodule
