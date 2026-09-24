// Verilog-AMS §6.6: a generate block may hold every module item except
// ports, parameters, specify blocks and specparams; A.1.4
// module_or_generate_item lists continuous_assign (A.6.1). IEEE 1364-2005
// §12.4: a conditional generate instantiates at most one of its blocks, so
// with `if (1)` the assignment below exists and drives `y` from `a`.
//
// VerA has no generate scope for a continuous assignment. It used to drop
// this one without a word, leaving `y` undriven; it now refuses it with
// E0235, "not supported inside a generate block". A limitation of VerA, not
// an error in the source. A continuous assignment is digital-only, so the
// claim is about the `--run` path.
//
// digital-runner: reject
//! lrm 6.6
//! reject E0235
`timescale 1ns/1ns
module audit_generate_block_continuous_assign_rejected;
  wire y;
  reg a;
  generate
    if (1) begin : g
      assign y = a;
    end
  endgenerate
  initial begin a = 1; #1 $display("%b", y); $finish(0); end
endmodule
