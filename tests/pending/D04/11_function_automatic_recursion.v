// A.2.6 Function declarations:
//
//     function_declaration ::= function [ automatic ] [ function_range_or_type ]
//         function_identifier ( function_port_list ) ;
//         { block_item_declaration } function_statement endfunction
//     function_port_list ::= tf_input_declaration { , tf_input_declaration }
//     function_range_or_type ::= [ signed ] [ range ] | integer | real
//                              | realtime | time
//
// Note what the grammar allows and does not: a function takes INPUTS only (no
// tf_output_declaration in function_port_list, unlike A.2.7's task_port_item),
// and returns through its own identifier. `automatic` gives each invocation its
// own copy of the arguments and locals, which is the precondition for a function
// to call itself — with the default static storage the recursive call would
// overwrite the caller's `n` and the recursion would not terminate correctly.
//
// This is the mirror of fixture 10: same keyword, opposite setting, and the
// observable is the one that only per-call storage can produce.
//
// HAND DERIVATION — 5! by the textbook recursion, all arithmetic 16 bits wide.
//   fact(5) = 5 * fact(4)
//   fact(4) = 4 * fact(3)
//   fact(3) = 3 * fact(2)
//   fact(2) = 2 * fact(1)
//   fact(1) = 1                      (n <= 1)
//   => 2, 6, 24, 120
//   120 = 64 + 32 + 16 + 8, so in sixteen bits 0000000001111000.
//   -> "fact 0000000001111000"
//
// 120 also fits in 7 bits, so no wrap is involved and the width chosen cannot
// mask a wrong product. Static storage that clobbers `n` on the inner call
// yields 1 * 1 * ... = 0000000000000001 or a hang, neither of which matches.
//
//! lrm A.2.6
//! lrm 1.1
module d04_function_automatic_recursion;
  reg [15:0] r;

  function automatic [15:0] fact(input [15:0] n);
    begin
      if (n <= 16'd1) fact = 16'd1;
      else fact = n * fact(n - 16'd1);
    end
  endfunction

  initial begin
    r = fact(16'd5);
    $display("fact %b", r);
    $finish(0);
  end
endmodule
