// IEEE 1364-2005 §12.3.2, p. 174: "Once a port has been defined, there shall not
// be another port definition with this same name."
//
// m defines the explicit port p twice. Legal neighbour:
// b_12_3_2_explicit_port_names.v (explicit ports a and e, each defined once).
// digital-runner: reject
//! inherited IEEE 1364-2005 12.3.2
//! reject E1100
//! reject port defined twice
//! xfail VerA accepts two explicit ports with the same name
module m(.p(a), .p(b));
  input a, b;
endmodule
module b_12_3_2_duplicate_port_name_rejected;
  wire x, y;
  m u(x, y);
endmodule
