// IEEE 1364-2005 §3.4, p. 8: "Unary operators shall appear to the left of
// their operand."
//
// `a ~` puts the unary ~ to the right of its operand. Legal neighbour:
// b_3_4_operator_positions.v, which writes ~a.
// digital-runner: reject
//! inherited IEEE 1364-2005 3.4
//! reject E0207
//! reject unexpected token: found `~`
module b_3_4_postfix_unary_rejected;
  reg a, b;
  initial begin
    a = 1;
    b = a ~;
    $display("%b", b);
  end
endmodule
