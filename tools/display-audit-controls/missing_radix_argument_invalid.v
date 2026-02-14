// IEEE17.1.1.2: INVALID, each %h requires a corresponding expression.
module missing_radix_argument_invalid;
  initial begin $display("%h"); $finish(0); end
endmodule
