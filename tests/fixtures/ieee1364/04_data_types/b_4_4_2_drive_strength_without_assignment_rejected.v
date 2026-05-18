// IEEE 1364-2005 §4.4, p. 25: "Drive strength shall only be used when placing
// a continuous assignment on a net in the same statement that declares the
// net." Syntax 4-1 (p. 22) has drive_strength only in the alternatives that
// end in list_of_net_decl_assignments.
//
// `wire (strong1, strong0) w;` declares no assignment. Legal neighbour:
// b_4_4_2_net_declaration_drive_strength.v's `wire (pull1, pull0) w = a;`.
// digital-runner: reject
//! inherited IEEE 1364-2005 4.4.2 4.4
//! reject E1100
//! reject drive strength
//! xfail VerA accepts a drive strength on a net declaration that has no assignment
module b_4_4_2_drive_strength_without_assignment_rejected;
  wire (strong1, strong0) w;
  initial $display("%b", w);
endmodule
