// IEEE 1364-2005 Annex B, p. 510: unsigned is in the keyword list, with the
// note "unsigned is reserved for possible future usage." A reserved keyword
// is a keyword: not an identifier, though no construct uses it yet.
//
// `reg unsigned;` names a variable unsigned. Legal neighbour:
// b_B_keywords.v (`\unsigned `, escaped).
// digital-runner: --std=1364-2005
// digital-runner: reject
//! inherited IEEE 1364-2005 B
//! reject E0208
//! reject found `unsigned`
module b_B_unsigned_reserved_rejected;
  reg unsigned;
  initial $display("unreachable");
endmodule
