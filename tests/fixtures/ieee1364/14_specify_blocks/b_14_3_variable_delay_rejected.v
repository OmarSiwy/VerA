// IEEE 1364-2005 §14.3, p. 222: "The delay values shall be constant
// expressions containing literals or specparams, and there may be a delay
// expression of the form min:typ:max."
//
// (a => q) = r takes its delay from r, a reg variable. Legal neighbour:
// b_14_3_path_delay_values.v, whose delays are literals and specparams.
// digital-runner: reject
//! inherited IEEE 1364-2005 14.3
//! reject constant
//! xfail VerA does not check that a module path delay is constant: a delay read from a reg variable is accepted (W0251 only)
`timescale 1ns/1ns
module b_14_3_variable_delay_rejected(a, q);
  input a;
  output q;
  reg [3:0] r;
  assign q = a;
  initial r = 4'd3;
  specify
    (a => q) = r;
  endspecify
endmodule
