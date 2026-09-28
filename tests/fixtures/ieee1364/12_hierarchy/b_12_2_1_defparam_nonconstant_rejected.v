// IEEE 1364-2005 §12.2.1, p. 169: "The expression on the right-hand side of the
// defparam assignments shall be a constant expression involving only numbers
// and references to parameters."
//
// The right-hand side is the reg r. Legal neighbour:
// b_12_2_1_defparam_last_wins.v (numbers on every right-hand side).
// digital-runner: reject
//! inherited IEEE 1364-2005 12.2.1
//! reject E1100
//! reject a constant expression is required here
module leaf;
  parameter p = 0;
  initial $display("%0d", p);
endmodule
module b_12_2_1_defparam_nonconstant_rejected;
  reg r;
  leaf l();
  defparam l.p = r;
endmodule
