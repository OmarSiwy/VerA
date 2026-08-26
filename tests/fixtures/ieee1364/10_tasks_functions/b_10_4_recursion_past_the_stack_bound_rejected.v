// An engine limit, not a language rule. IEEE 1364-2005 §10.4.2 lets an
// automatic function call itself and bounds nothing about the depth. The
// digital interpreter runs each activation on the host thread's stack, so it
// stops at 1024 nested activations or 4 MiB of stack, whichever comes first
// (specification/Vague_Decisions.md), and refuses the call there with E1100 rather than
// overflow the stack. f(5000) passes both bounds.
// digital-runner: reject
//! reject E1100
//! reject task and function calls nested deeper than 1024
module b_10_4_recursion_past_the_stack_bound_rejected;
  function automatic integer f(input integer n);
    begin
      if (n == 0) f = 0; else f = 1 + f(n - 1);
    end
  endfunction
  initial $display("%0d", f(5000));
endmodule
