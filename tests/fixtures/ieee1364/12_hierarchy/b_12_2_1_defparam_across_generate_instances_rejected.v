// IEEE 1364-2005 §12.2.1, pp. 168-169: "a defparam statement in a hierarchy in
// or under a generate block instance ... shall not change a parameter value
// outside that hierarchy. Each instantiation of a generate block is considered
// to be a separate hierarchy scope. Therefore, this rule implies that a
// defparam statement in a generate block may not target a parameter in
// another instantiation of the same generate block, even when the other
// instantiation is created by the same loop generate construct. For example,
// the following code is not allowed:" (the somename loop below).
//
// somename[i]'s defparam targets somename[(i+1) % 8].my_flop. The clause's
// i+1 is wrapped so that somename[7] targets somename[0], not a somename[8]
// that does not exist: every target resolves, and targeting another instance
// of the block is the only error. Legal neighbour:
// b_12_2_1_defparam_inside_generate_block.v (each defparam targets its own
// block's instance; itself an xfail).
// digital-runner: reject
//! inherited IEEE 1364-2005 12.2.1
//! reject E1100
//! reject outside the generate block
//! xfail VerA refuses this only as unsupported (E0231 "hierarchical index is not a constant expression" on the constant (i+1) % 8; a defparam in a generate block is E0235), not for targeting another generate block instance
module flop;
  parameter xyz = 0;
endmodule
module b_12_2_1_defparam_across_generate_instances_rejected;
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : somename
      flop my_flop();
      defparam somename[(i+1) % 8].my_flop.xyz = i ;
    end
  endgenerate
endmodule
