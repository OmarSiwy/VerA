// Legal definition-only neighbor of digital/d08_reject_udp_comb_edge.v.
// IEEE8.1.4: rows have disjoint inputs; missing combinations, including xx,
// default to x. This is parsing evidence, not UDP runtime execution.
primitive udp_good_level (o, a, b);
  output o;
  input a, b;
  table
    1 0 : 1;
    1 1 : 0;
  endtable
endprimitive
module audit_definition;
  initial begin $display("definition accepted"); $finish(0); end
endmodule
