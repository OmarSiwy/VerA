// IEEE8.1.4/8.4: one edge descriptor, then level input. Uninstantiated
// declaration isolates definition validation, not execution evidence.
primitive shape_udp(q, a, b);
  output q; reg q;
  input a, b;
  table
    (01) 0 : ? : 1;
  endtable
endprimitive
module audit_definition;
  initial begin $display("definition accepted"); $finish(0); end
endmodule
