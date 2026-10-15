// IEEE 1364-2005 §10.4.2 lets an automatic function call itself; a call
// that never stops recursing has no value to return. VerA runs a design on a
// stack reserved for it (b_10_4_recursion_past_1024.v nests 5001 calls) and
// refuses the call that exhausts it with a named E1100, not a crash.
// f(n) calls f(n + 1) with no base case.
// digital-runner: reject
//! reject E1100
//! reject nesting here exhausts the
//! neighbour b_10_4_recursion_past_1024.v
module b_10_4_recursion_without_end_rejected;
  function automatic integer f(input integer n);
    f = f(n + 1);
  endfunction
  initial $display("%0d", f(0));
endmodule
