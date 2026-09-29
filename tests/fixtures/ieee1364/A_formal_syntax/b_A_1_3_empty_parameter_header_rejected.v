// IEEE 1364-2005 A.1.3 requires the first parameter_declaration inside #(...).
// Empty ports () are independent and legal, as the runtime neighbour
// audit_grammar_parameter_header.v demonstrates with a nonempty header.
// digital-runner: reject
//! inherited IEEE 1364-2005 A.1.3
//! reject E0246
module b_A_1_3_empty_parameter_header #() ();
  initial $display("invalid header was accepted");
endmodule
