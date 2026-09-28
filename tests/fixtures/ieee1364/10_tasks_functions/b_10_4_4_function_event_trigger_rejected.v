// IEEE 1364-2005 §10.4.4, p. 155: "f) A function shall not have any event
// triggers."
//
// f triggers the named event e with `-> e`. Legal neighbour:
// b_10_4_4_factorial.v, whose function triggers nothing.
// digital-runner: reject
//! inherited IEEE 1364-2005 10.4.4
//! reject E1100
//! reject event trigger
//! xfail accepted: a function containing an event trigger compiles and runs
module b_10_4_4_function_event_trigger_rejected;
  reg x;
  event e;
  function f;
    input a;
    begin
      f = a;
      -> e;
    end
  endfunction
  initial x = f(1'b1);
endmodule
