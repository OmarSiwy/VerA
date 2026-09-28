// IEEE 1364-2005 §12.4, p. 181: "If the generate keyword is used, it shall be
// matched by an endgenerate keyword."
//
// The region opened by generate reaches endmodule unclosed. Legal neighbour:
// b_12_4_generate_region_optional.v.
// digital-runner: reject
//! inherited IEEE 1364-2005 12.4
//! reject E0207
//! reject found `endmodule`
module b_12_4_generate_without_endgenerate_rejected;
  generate
    if (1) begin : g
      initial $display("x");
    end
endmodule
