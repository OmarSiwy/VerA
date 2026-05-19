// IEEE 1364-2005 §10.4.3, p. 155: "A function call is an operand within an
// expression." Syntax 10-2 (§10.2.2, p. 147) enables only a task:
// task_enable ::= hierarchical_task_identifier [ ( expression { , expression }
// ) ] ;
//
// `f(1'b1);` stands as a statement, not an operand. Legal neighbour:
// b_10_4_3_function_call_operand.v calls functions as operands.
// digital-runner: reject
//! inherited IEEE 1364-2005 10.4.3
//! reject E1100
//! reject a function is called in an expression, not enabled
module b_10_4_3_function_call_statement_rejected;
  function f;
    input a;
    f = a;
  endfunction
  initial f(1'b1);
endmodule
