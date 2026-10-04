// An engine limit, not a language rule. IEEE 1364-2005 §3.5.1 lets a sized
// constant give its size in bits and bounds nothing about it. VerA takes a
// size up to 2^24 = 16777216 bits (docs/Vague_Decisions.md) and refuses a
// larger one with E1019 before it allocates the value; a 2^32 - 1 bit
// literal used to allocate 1 GiB. b_3_5_1_literal_size_65536.v is the legal
// neighbour.
// digital-runner: reject
//! reject E1019
module b_3_5_1_literal_size_over_2_24_rejected;
  initial $display("%0d", 4294967295'h0 == 0);
endmodule
