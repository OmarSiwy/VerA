// IEEE 1364-2005 §14.2.4.1, p. 215: "Table 14-1 contains a list of valid
// operators that may be used in conditional expressions." Table 14-1 (p. 216)
// has no arithmetic operator, and A.8.6 (p. 506) says the same in the
// grammar:
//   binary_module_path_operator ::=
//     == | != | && | || | & | | | ^ | ^~ | ~^
//
// (§14.3.3's Example 2, p. 225, writes `if (MODE < 5)`, an operator neither
// Table 14-1 nor the grammar admits; no example writes +.)
//
// if (a + b) conditions the path on an addition. Legal neighbour:
// b_14_2_4_state_dependent_paths.v, whose conditions use every Table 14-1
// operator.
// digital-runner: reject
//! inherited IEEE 1364-2005 14.2.4.1
//! reject condition
//! xfail VerA does not check a state-dependent path's condition: an operator outside Table 14-1 (+) is accepted (W0251 only)
`timescale 1ns/1ns
module b_14_2_4_1_condition_operator_rejected(a, b, y);
  input a, b;
  output y;
  assign y = a ^ b;
  specify
    if (a + b) (a => y) = 1;
  endspecify
endmodule
