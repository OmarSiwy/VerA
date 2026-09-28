// IEEE 1364-2005 §10.3, p. 150: "The disable statement can be used to disable
// named blocks within a function, but cannot be used to disable functions."
//
// `disable f` names the function f. Legal neighbour:
// b_10_3_disable_block_in_function.v disables a named block inside a
// function.
// digital-runner: reject
//! inherited IEEE 1364-2005 10.3
//! reject E1100
//! reject disable
//! reject function
//! xfail accepted: `disable` naming a function compiles and runs
module b_10_3_disable_function_rejected;
  reg x;
  function f;
    input a;
    f = a;
  endfunction
  initial begin
    disable f;
    x = f(1'b1);
  end
endmodule
