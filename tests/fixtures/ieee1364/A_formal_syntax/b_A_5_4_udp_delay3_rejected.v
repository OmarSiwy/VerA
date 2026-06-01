// IEEE 1364-2005 A.5.4, p. 497:
//   udp_instantiation ::= udp_identifier [ drive_strength ] [ delay2 ]
//     udp_instance { , udp_instance } ;
// A.2.2.3, p. 491: delay2 ::= # delay_value | # ( mintypmax_expression [ , mintypmax_expression ] )
// A UDP instance takes at most two delays; §8.6, p. 113 (quoted for
// context): "Only two delays may be specified because z is not supported for
// UDPs."
//
// `#(1, 2, 3)` is a delay3 on a UDP instance. Legal neighbour:
// b_A_5_4_udp_instances.v (`#(2, 3)`).
// digital-runner: reject
//! inherited IEEE 1364-2005 A.5.4
//! reject E0207
//! xfail VerA accepts a three-value delay on a UDP instance
primitive b_A_5_4_buf (y, a);
  output y;
  input a;
  table
    0 : 0;
    1 : 1;
  endtable
endprimitive
module b_A_5_4_udp_delay3_rejected;
  wire y;
  b_A_5_4_buf #(1, 2, 3) u (y, 1'b1);
  initial $display("unreachable");
endmodule
