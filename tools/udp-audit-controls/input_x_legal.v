// Legal single-symbol neighbor of audit_udp_input_z_rejected.v.
primitive alphabet_udp(q, a, b);
  output q;
  input a, b;
  table
    x 0 : x;
  endtable
endprimitive
module audit_definition;
  initial begin $display("definition accepted"); $finish(0); end
endmodule
