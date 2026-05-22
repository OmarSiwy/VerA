// IEEE 1364-2005 §18.3.1, p. 339: "Each scope specified in the scope_list
// shall be unique. If multiple calls to $dumpports are specified, the
// scope_list values in these calls shall also be unique."
//
// The one call lists the instance u twice. Legal neighbour: one scope, as in
// b_18_3_2_dumpports_control_tasks.v.
// digital-runner: reject
//! inherited IEEE 1364-2005 18.3.1
//! reject E1100
//! reject unique
//! xfail extended VCD is not implemented: every $dumpports-family call is refused as "not implemented", not for this rule
`timescale 1ns/1ns
module b_18_3_1_dumpports_duplicate_scope_rejected_dev(a, y);
  input a;
  output y;
  assign y = ~a;
endmodule

module b_18_3_1_dumpports_duplicate_scope_rejected;
  reg a;
  wire y, w;
  b_18_3_1_dumpports_duplicate_scope_rejected_dev u(a, y);
  b_18_3_1_dumpports_duplicate_scope_rejected_dev v(a, w);
  initial begin
    a = 1'b0;
    $dumpports(u, u, "b_18_3_1_duplicate.evcd");
    #1 a = 1'b1;
  end
endmodule
