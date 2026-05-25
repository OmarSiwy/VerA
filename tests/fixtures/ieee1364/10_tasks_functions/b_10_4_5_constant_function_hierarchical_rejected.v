// IEEE 1364-2005 §10.4.5, p. 156: "Constant functions are a subset of normal
// Verilog functions that shall meet the following constraints: — They shall
// contain no hierarchical references."
//
// g reads the hierarchical name top.q and is called in a localparam value,
// which requires a constant function (§5, §10.4.5). Legal neighbour:
// b_10_4_5_constant_function_clogb2.v, whose constant function names only its
// own input and return variable.
// digital-runner: reject
//! inherited IEEE 1364-2005 10.4.5
//! reject E1100
//! reject hierarchical
//! xfail refused, but as "undeclared function": no constant function call is accepted, so the refusal does not name the hierarchical reference
module b_10_4_5_constant_function_hierarchical_rejected;
  reg [7:0] q;
  function integer g;
    input integer a;
    g = a + b_10_4_5_constant_function_hierarchical_rejected.q;
  endfunction
  localparam P = g(1);
  initial $display("%0d", P);
endmodule
