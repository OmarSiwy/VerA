// IEEE 1364-2005 §17.1.1.2: "The format specifications in Table 17-3 are used
// with real numbers and have the full formatting capabilities available in the
// C language." C bounds no precision. VerA prints up to 4096 fractional digits
// (docs/IMPLEMENTATION.md; b_17_1_1_2_field_width_over_4096_rejected.v is the
// bound). It used to clamp every precision to 60 silently.
//
// HAND DERIVATION. 0.5 is exact in binary, so %.100f of it is "0.5" and 99
// more zeros: 102 characters between the brackets.
//! inherited IEEE 1364-2005 17.1.1.2
//! expect stdout b_17_1_1_2_real_precision_100.expected.txt
module b_17_1_1_2_real_precision_100;
  initial $display("[%.100f]", 0.5);
endmodule
