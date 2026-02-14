// IEEE1364-2005 13.3.1.2/13.3.1.6: default can pair only with liblist,
// never use. Legal neighboring default/liblist declaration is in controls.
// digital-runner: reject
//! inherited IEEE 1364-2005 13.3.1.2 13.3.1.6
//! reject E0207
//! reject a default pairs with `liblist`
config config_invalid;
  design config_host;
  default use config_host;
endconfig
module config_host;
  initial begin $display("accepted"); $finish(0); end
endmodule
