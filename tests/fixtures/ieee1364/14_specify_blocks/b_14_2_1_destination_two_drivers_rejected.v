// IEEE 1364-2005 §14.2.1, p. 213: "The module path destination shall have
// only one driver inside the module."
//
// q is a wor net with two continuous assignments inside the module, and the
// path (a => q) ends at it. Legal neighbour: b_14_2_module_paths.v, where
// every destination has one driver.
// digital-runner: reject
//! inherited IEEE 1364-2005 14.2.1
//! reject one driver
//! xfail VerA does not check a module path's destination: one with two drivers inside the module is accepted (W0251 only)
`timescale 1ns/1ns
module b_14_2_1_destination_two_drivers_rejected(a, b, q);
  input a, b;
  output q;
  wor q;
  assign q = a;
  assign q = b;
  specify
    (a => q) = 1;
  endspecify
endmodule
