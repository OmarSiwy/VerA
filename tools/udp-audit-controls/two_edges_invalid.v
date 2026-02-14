// IEEE8.1.4/8.4 prohibits more than one input transition descriptor per row.
// Matching legal definition replaces only the second (10) with level0.
primitive shape_udp(q, a, b);
  output q; reg q;
  input a, b;
  table
    (01) (10) : ? : 1;
  endtable
endprimitive
module audit_definition;
  initial begin $display("definition accepted"); $finish(0); end
endmodule
