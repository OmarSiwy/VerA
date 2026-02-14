// IEEE and AMS A.1.3 name parameter_declaration, not local_parameter_declaration.
module localparam_header_invalid #(localparam P=7) ();
  initial begin $display("%0d",P); $finish(0); end
endmodule
