// An engine limit, not a language rule. IEEE 1364-2005 §17.1.1.3 sizes a %d
// field for any operand width. VerA prints a known decimal value of at most 64
// bits (specification/Vague_Decisions.md) and refuses a wider one with E1100 rather than
// print a truncated number. r is 65 bits. %b and %h of the same operand print
// in full (b_17_1_1_3_wide_operand_prints_every_digit.v).
// digital-runner: reject
//! reject E1100
//! reject decimal display of an operand wider than 64 bits
//! neighbour b_17_1_1_3_wide_operand_prints_every_digit.v
module b_17_1_1_4_decimal_over_64_bits_rejected;
  reg [64:0] r;
  initial begin
    r = 1;
    $display("%d", r);
  end
endmodule
