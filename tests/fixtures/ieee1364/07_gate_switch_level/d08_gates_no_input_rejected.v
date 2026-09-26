// Annex A.3.1:
//     n_input_gate_instance ::= [ name_of_gate_instance ]
//         ( output_terminal , input_terminal { , input_terminal } )
// One input terminal is mandatory, and IEEE 1364-2005 §7.2 asks for "one
// output and one or more inputs". `and g (y);` has the output and no input, so
// it is not derivable.
//
// The legal neighbour, one input, is d08_gates_one_input.v.
//
// digital-runner: reject
//! lrm A.3.1
//! reject at least one input
module d08_gates_no_input_rejected;
  wire y;
  and g (y);
endmodule
