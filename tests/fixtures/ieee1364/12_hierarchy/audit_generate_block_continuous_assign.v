// Verilog-AMS §6.6: a generate block may hold every module item except
// ports, parameters, specify blocks and specparams; A.1.4
// module_or_generate_item lists continuous_assign (A.6.1). IEEE 1364-2005
// 12.4.2: "The selected generate block, if any, is instantiated into the
// model." With `if (1)` the block is selected, so the assignment below exists
// and drives `y` from `a`.
//
// HAND DERIVATION: t=0 a<-1, so `assign y = a` drives y to 1; at t=1 the
// display reads y = 1.
//
// VerA has no generate scope for a continuous assignment and refuses this
// legal source with E0235, "not supported inside a generate block" (it used to
// drop the assignment silently). That refusal is VerA's gap, hence the xfail;
// this file was audit_generate_block_continuous_assign_rejected.v, a
// `//! reject E0235` pin of the refusal.
//
//! inherited IEEE 1364-2005 12.4.2
//! xfail VerA refuses a continuous assignment inside a generate block (E0235) instead of instantiating it
`timescale 1ns/1ns
module audit_generate_block_continuous_assign;
  wire y;
  reg a;
  generate
    if (1) begin : g
      assign y = a;
    end
  endgenerate
  initial begin a = 1; #1 $display("%b", y); $finish(0); end
endmodule
