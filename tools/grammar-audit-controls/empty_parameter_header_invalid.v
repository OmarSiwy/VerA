// IEEE and AMS A.1.3 require at least one parameter_declaration after #(.
// Unlike empty module ports, no nullable production makes this list empty.
module empty_parameter_header_invalid #() ();
  initial begin $display("accepted empty parameter header"); $finish(0); end
endmodule
