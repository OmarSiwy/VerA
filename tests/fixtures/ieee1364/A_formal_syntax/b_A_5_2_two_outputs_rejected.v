// IEEE 1364-2005 A.5.2, p. 496:
//   udp_declaration_port_list ::= udp_output_declaration , udp_input_declaration
//     { , udp_input_declaration }
// Exactly one udp_output_declaration, first; every later declaration is an
// input.
//
// `(output y, output z, input a)` declares a second output. Legal
// neighbour: b_A_5_1_udp_declarations.v
// (`(output reg q = 1'b0, input d, input en)`).
// digital-runner: reject
//! inherited IEEE 1364-2005 A.5.2
//! reject E0207
//! xfail VerA accepts a UDP declaration port list with two output declarations
primitive b_A_5_2_two (output y, output z, input a);
  table
    0 : 1;
    1 : 0;
  endtable
endprimitive
module b_A_5_2_two_outputs_rejected;
  initial $display("unreachable");
endmodule
